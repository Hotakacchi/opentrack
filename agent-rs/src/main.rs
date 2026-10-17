//! OpenTrack agent — runs on YOUR OWN laptop to help you locate it if lost
//! or stolen. It periodically reports an approximate location to your own
//! Supabase project and, only while you have switched the device to "lost
//! mode" from your dashboard, shows a visible message and can take one
//! webcam photo.
//!
//! Only install this on devices you own or are authorized to manage.

#![windows_subsystem = "windows"]

mod tray;

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::io::Read;
use std::os::windows::process::CommandExt;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use windows::core::HSTRING;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::UI::WindowsAndMessaging::{
    MessageBoxW, MB_ICONINFORMATION, MB_OK, MB_TOPMOST,
};

const REPO: &str = "Hotakacchi/opentrack";
const VERSION: &str = env!("CARGO_PKG_VERSION");
const INSTALLER_PREFIX: &str = "OpenTrackSetup";
const UPDATE_EVERY: Duration = Duration::from_secs(6 * 3600);

/// Commands sent from the tray menu to the worker thread.
pub enum Cmd {
    SendNow,
    CheckUpdate,
}

/// What the tray menu shows. Updated by the worker thread.
pub struct Status {
    pub last_ok: Option<String>,
    pub last_err: Option<String>,
}
pub static STATUS: Mutex<Status> = Mutex::new(Status { last_ok: None, last_err: None });

const DEFAULT_DASHBOARD: &str = "https://opentrack-hotakacchi.vercel.app";

/// Set while the "lost" message box is on screen, so it is shown only once.
static MSG_SHOWN: AtomicBool = AtomicBool::new(false);

// --------------------------------------------------------------------------
//  Paths, config, logging
// --------------------------------------------------------------------------
fn exe_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn log(msg: &str) {
    let path = exe_dir().join("agent.log");
    // Keep the log tiny: start over once it passes 100 KB.
    if std::fs::metadata(&path).map(|m| m.len() > 100_000).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{}", msg);
    }
}

struct Config {
    url: String,
    anon_key: String,
    device_id: String,
    agent_key: String,
    interval: u64,
    use_windows_location: bool,
    enable_photo: bool,
    auto_update: bool,
    dashboard_url: String,
}

fn load_config() -> Result<Config, String> {
    let path = exe_dir().join("config.json");
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("cannot read {}: {}", path.display(), e))?;
    let v: Value = serde_json::from_str(&text).map_err(|e| format!("bad config.json: {}", e))?;
    let s = |k: &str| -> Result<String, String> {
        v[k].as_str()
            .map(|x| x.trim().trim_end_matches('/').to_string())
            .filter(|x| !x.is_empty())
            .ok_or_else(|| format!("config.json is missing \"{}\"", k))
    };
    Ok(Config {
        url: s("supabase_url")?,
        anon_key: s("supabase_anon_key")?,
        device_id: s("device_id")?,
        agent_key: s("agent_key")?,
        interval: v["interval_seconds"].as_u64().unwrap_or(900).max(30),
        use_windows_location: v["use_windows_location"].as_bool().unwrap_or(true),
        enable_photo: v["enable_photo"].as_bool().unwrap_or(true),
        auto_update: v["auto_update"].as_bool().unwrap_or(true),
        dashboard_url: v["dashboard_url"]
            .as_str()
            .filter(|u| u.starts_with("https://"))
            .unwrap_or(DEFAULT_DASHBOARD)
            .to_string(),
    })
}

// --------------------------------------------------------------------------
//  Location
// --------------------------------------------------------------------------
struct Fix {
    lat: f64,
    lng: f64,
    accuracy: Option<f64>,
    source: &'static str,
    public_ip: Option<String>,
}

/// Wi-Fi based position from the Windows Location API (needs Location access
/// enabled in Windows Settings > Privacy).
fn locate_windows() -> Result<Fix, String> {
    use windows::Devices::Geolocation::{Geolocator, PositionAccuracy};
    let loc = Geolocator::new().map_err(|e| e.to_string())?;
    loc.SetDesiredAccuracy(PositionAccuracy::High)
        .map_err(|e| e.to_string())?;
    let pos = loc
        .GetGeopositionAsync()
        .map_err(|e| e.to_string())?
        .get()
        .map_err(|e| e.to_string())?;
    let c = pos.Coordinate().map_err(|e| e.to_string())?;
    let p = c.Point().map_err(|e| e.to_string())?;
    let p = p.Position().map_err(|e| e.to_string())?;
    Ok(Fix {
        lat: p.Latitude,
        lng: p.Longitude,
        accuracy: c.Accuracy().ok(),
        source: "wifi",
        public_ip: None,
    })
}

/// City-level fallback. Plain HTTP on purpose (the free endpoint has no TLS).
fn locate_ip() -> Result<Fix, String> {
    let body = ureq::get("http://ip-api.com/json/?fields=status,lat,lon,query")
        .timeout(Duration::from_secs(15))
        .call()
        .map_err(|e| e.to_string())?
        .into_string()
        .map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    if v["status"] != "success" {
        return Err("ip lookup failed".into());
    }
    Ok(Fix {
        lat: v["lat"].as_f64().ok_or("no lat")?,
        lng: v["lon"].as_f64().ok_or("no lon")?,
        accuracy: Some(5000.0),
        source: "ip",
        public_ip: v["query"].as_str().map(String::from),
    })
}

fn battery_percent() -> Option<i64> {
    let mut s = SYSTEM_POWER_STATUS::default();
    unsafe { GetSystemPowerStatus(&mut s).ok()? };
    // 255 = unknown (also the value on desktops without a battery)
    if s.BatteryLifePercent <= 100 {
        Some(s.BatteryLifePercent as i64)
    } else {
        None
    }
}

// --------------------------------------------------------------------------
//  Lost-mode actions
// --------------------------------------------------------------------------
/// Show the owner's message once per lost-mode session. Runs on its own
/// thread because MessageBox blocks until dismissed.
fn show_lost_message(message: String) {
    if message.is_empty() || MSG_SHOWN.swap(true, Ordering::SeqCst) {
        return;
    }
    thread::spawn(move || unsafe {
        MessageBoxW(
            None,
            &HSTRING::from(message),
            &HSTRING::from("This device is being tracked by its owner"),
            MB_OK | MB_ICONINFORMATION | MB_TOPMOST,
        );
    });
}

/// Take one webcam frame, downscale to <=640px wide JPEG (free-tier friendly).
fn capture_photo() -> Result<String, String> {
    use windows::Graphics::Imaging::{BitmapDecoder, BitmapEncoder};
    use windows::Media::Capture::MediaCapture;
    use windows::Media::MediaProperties::ImageEncodingProperties;
    use windows::Storage::Streams::{DataReader, InMemoryRandomAccessStream};

    let e = |x: windows::core::Error| x.to_string();

    let cam = MediaCapture::new().map_err(e)?;
    cam.InitializeAsync().map_err(e)?.get().map_err(e)?;
    // let auto-exposure settle
    thread::sleep(Duration::from_millis(1000));

    let raw = InMemoryRandomAccessStream::new().map_err(e)?;
    let props = ImageEncodingProperties::CreateJpeg().map_err(e)?;
    cam.CapturePhotoToStreamAsync(&props, &raw)
        .map_err(e)?
        .get()
        .map_err(e)?;
    raw.Seek(0).map_err(e)?;

    let decoder = BitmapDecoder::CreateAsync(&raw).map_err(e)?.get().map_err(e)?;
    let (w, h) = (
        decoder.PixelWidth().map_err(e)?,
        decoder.PixelHeight().map_err(e)?,
    );

    let out = InMemoryRandomAccessStream::new().map_err(e)?;
    let enc = BitmapEncoder::CreateForTranscodingAsync(&out, &decoder)
        .map_err(e)?
        .get()
        .map_err(e)?;
    if w > 640 {
        let t = enc.BitmapTransform().map_err(e)?;
        t.SetScaledWidth(640).map_err(e)?;
        t.SetScaledHeight((h as u64 * 640 / w as u64) as u32).map_err(e)?;
    }
    enc.FlushAsync().map_err(e)?.get().map_err(e)?;

    let size = out.Size().map_err(e)? as u32;
    let reader = DataReader::CreateDataReader(&out.GetInputStreamAt(0).map_err(e)?).map_err(e)?;
    reader.LoadAsync(size).map_err(e)?.get().map_err(e)?;
    let mut buf = vec![0u8; size as usize];
    reader.ReadBytes(&mut buf).map_err(e)?;
    Ok(base64::engine::general_purpose::STANDARD.encode(buf))
}

// --------------------------------------------------------------------------
//  Self-update (GitHub Releases)
// --------------------------------------------------------------------------
fn parse_version(s: &str) -> Vec<u64> {
    s.trim_start_matches('v')
        .split('.')
        .map(|p| p.parse().unwrap_or(0))
        .collect()
}

fn http_get_string(agent: &ureq::Agent, url: &str) -> Result<String, String> {
    agent
        .get(url)
        .set("User-Agent", "opentrack-agent")
        .set("Accept", "application/vnd.github+json")
        .call()
        .map_err(|e| e.to_string())?
        .into_string()
        .map_err(|e| e.to_string())
}

/// Find a release asset by file-name prefix/suffix (names carry the version,
/// e.g. OpenTrackSetup-0.2.1.exe). Returns (name, download url).
fn find_asset(rel: &Value, prefix: &str, suffix: &str) -> Option<(String, String)> {
    rel["assets"].as_array()?.iter().find_map(|a| {
        let name = a["name"].as_str()?;
        if name.starts_with(prefix) && name.ends_with(suffix) {
            Some((name.to_string(), a["browser_download_url"].as_str()?.to_string()))
        } else {
            None
        }
    })
}

/// Look for a newer release; if found, download the installer, verify its
/// SHA-256 against the release's SHA256SUMS.txt and run it silently. The
/// installer stops this process, replaces the exe and starts the new one.
/// Settings in config.json are kept.
fn check_update(agent: &ureq::Agent) -> Result<(), String> {
    let rel: Value = serde_json::from_str(&http_get_string(
        agent,
        &format!("https://api.github.com/repos/{}/releases/latest", REPO),
    )?)
    .map_err(|e| e.to_string())?;
    let tag = rel["tag_name"].as_str().ok_or("no tag_name")?;
    if parse_version(tag) <= parse_version(VERSION) {
        return Ok(());
    }
    log(&format!("update available: {} (running {})", tag, VERSION));

    let (exe_name, exe_url) =
        find_asset(&rel, INSTALLER_PREFIX, ".exe").ok_or("installer asset missing")?;
    let (_, sums_url) = find_asset(&rel, "SHA256SUMS", ".txt").ok_or("SHA256SUMS.txt missing")?;
    let sums = http_get_string(agent, &sums_url)?;
    let expected = sums
        .lines()
        .find(|l| l.trim_end().ends_with(exe_name.as_str()))
        .and_then(|l| l.split_whitespace().next())
        .map(|h| h.to_lowercase())
        .ok_or("no checksum for installer")?;

    let mut bytes = Vec::new();
    agent
        .get(&exe_url)
        .set("User-Agent", "opentrack-agent")
        .call()
        .map_err(|e| e.to_string())?
        .into_reader()
        .take(50 * 1024 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;

    let actual = format!("{:x}", Sha256::digest(&bytes));
    if actual != expected {
        return Err(format!("checksum mismatch (got {})", actual));
    }

    let path = std::env::temp_dir().join("OpenTrackSetup-update.exe");
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    log(&format!("running installer for {}", tag));
    // DETACHED_PROCESS | CREATE_NO_WINDOW: must outlive this process
    std::process::Command::new(&path)
        .args(["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"])
        .creation_flags(0x0000_0008 | 0x0800_0000)
        .spawn()
        .map_err(|e| e.to_string())?;
    std::process::exit(0);
}

// --------------------------------------------------------------------------
//  Supabase RPC
// --------------------------------------------------------------------------
fn rpc(agent: &ureq::Agent, cfg: &Config, func: &str, body: Value) -> Result<Value, String> {
    let resp = agent
        .post(&format!("{}/rest/v1/rpc/{}", cfg.url, func))
        .set("apikey", &cfg.anon_key)
        .set("Authorization", &format!("Bearer {}", cfg.anon_key))
        .set("Content-Type", "application/json")
        .send_string(&body.to_string())
        .map_err(|e| e.to_string())?;
    let text = resp.into_string().map_err(|e| e.to_string())?;
    if text.is_empty() {
        Ok(Value::Null)
    } else {
        serde_json::from_str(&text).map_err(|e| e.to_string())
    }
}

fn tick(agent: &ureq::Agent, cfg: &Config) -> Result<(), String> {
    let fix = if cfg.use_windows_location {
        locate_windows().or_else(|e| {
            log(&format!("windows location unavailable ({}); using IP", e));
            locate_ip()
        })?
    } else {
        locate_ip()?
    };
    log(&format!("{} {:.4},{:.4}", fix.source, fix.lat, fix.lng));
    let t = unsafe { GetLocalTime() };
    let summary = format!(
        "Last report {:02}:{:02} ({}, {:.3},{:.3})",
        t.wHour, t.wMinute, fix.source, fix.lat, fix.lng
    );

    let state = rpc(
        agent,
        cfg,
        "report_location",
        json!({
            "p_device_id": cfg.device_id,
            "p_agent_key": cfg.agent_key,
            "p_lat": fix.lat,
            "p_lng": fix.lng,
            "p_accuracy": fix.accuracy,
            "p_source": fix.source,
            "p_battery": battery_percent(),
            "p_public_ip": fix.public_ip,
        }),
    )?;

    if state["lost_mode"].as_bool().unwrap_or(false) {
        show_lost_message(state["lost_message"].as_str().unwrap_or("").to_string());
        if state["want_photo"].as_bool().unwrap_or(false) && cfg.enable_photo {
            match capture_photo() {
                Ok(img) => {
                    rpc(
                        agent,
                        cfg,
                        "upload_photo",
                        json!({
                            "p_device_id": cfg.device_id,
                            "p_agent_key": cfg.agent_key,
                            "p_image": img,
                        }),
                    )?;
                    log("evidence photo uploaded");
                }
                Err(e) => log(&format!("photo failed: {}", e)),
            }
        }
    } else {
        MSG_SHOWN.store(false, Ordering::SeqCst);
    }
    let mut st = STATUS.lock().unwrap();
    st.last_ok = Some(summary);
    st.last_err = None;
    Ok(())
}

/// Reports the location on a timer and handles tray commands. Runs on its
/// own thread so the main thread can serve the tray icon.
fn worker(cfg: Config, rx: mpsc::Receiver<Cmd>) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let tls = native_tls::TlsConnector::new().expect("TLS init");
    let agent = ureq::AgentBuilder::new()
        .tls_connector(Arc::new(tls))
        .timeout(Duration::from_secs(30))
        .build();

    log(&format!("OpenTrack agent {} started, every {}s", VERSION, cfg.interval));
    let mut last_update_check: Option<Instant> = None;
    let mut force_update = false;
    loop {
        if let Err(e) = tick(&agent, &cfg) {
            log(&format!("tick failed: {}", e));
            STATUS.lock().unwrap().last_err = Some(e);
        }
        let due = last_update_check.map_or(true, |t| t.elapsed() >= UPDATE_EVERY);
        if force_update || (cfg.auto_update && due) {
            force_update = false;
            last_update_check = Some(Instant::now());
            if let Err(e) = check_update(&agent) {
                log(&format!("update check failed: {}", e));
            }
        }
        match rx.recv_timeout(Duration::from_secs(cfg.interval)) {
            Ok(Cmd::SendNow) | Err(RecvTimeoutError::Timeout) => {}
            Ok(Cmd::CheckUpdate) => force_update = true,
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

fn main() {
    let (tx, rx) = mpsc::channel::<Cmd>();
    let mut dashboard = DEFAULT_DASHBOARD.to_string();
    match load_config() {
        Ok(cfg) => {
            dashboard = cfg.dashboard_url.clone();
            thread::spawn(move || worker(cfg, rx));
        }
        Err(e) => {
            // keep the tray up so the problem is visible instead of a silent exit
            log(&format!("config error: {}", e));
            STATUS.lock().unwrap().last_err = Some(format!("config.json ({})", e));
        }
    }

    // one-time balloon so a new install shows that it is running
    let marker = exe_dir().join("first_run_done");
    let first_run = !marker.exists();
    if first_run {
        let _ = std::fs::write(&marker, VERSION);
    }
    tray::run(tx, dashboard, first_run);
}

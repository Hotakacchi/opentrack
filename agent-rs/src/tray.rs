//! Tray icon + menu. Deliberately has no "Quit" entry: if the laptop is
//! stolen, a thief should not be able to stop the agent with one click.
//! (Stop it from Task Manager, or uninstall it from Settings > Apps.)

use std::mem::size_of;
use std::sync::atomic::{AtomicIsize, AtomicU32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};

use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    ShellExecuteW, Shell_NotifyIconW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO,
    NIM_ADD, NIM_MODIFY, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreateIcon, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu,
    DispatchMessageW, GetCursorPos, GetMessageW, PostMessageW, RegisterClassW,
    RegisterWindowMessageW, SetForegroundWindow, TrackPopupMenu, TranslateMessage, HICON,
    MF_DISABLED, MF_GRAYED, MF_SEPARATOR, MF_STRING, MSG, SW_SHOWNORMAL, TPM_RETURNCMD,
    TPM_RIGHTBUTTON, WINDOW_EX_STYLE, WM_LBUTTONUP, WM_NULL, WM_RBUTTONUP, WM_USER, WNDCLASSW,
    WS_OVERLAPPED,
};

use crate::{exe_dir, Cmd, STATUS, VERSION};

const WM_TRAY: u32 = WM_USER + 1;
const ID_DASHBOARD: usize = 1;
const ID_LOG: usize = 2;
const ID_SEND_NOW: usize = 3;
const ID_UPDATE: usize = 4;

struct Ctx {
    tx: Mutex<Sender<Cmd>>,
    dashboard_url: String,
}

static CTX: OnceLock<Ctx> = OnceLock::new();
static ICON: AtomicIsize = AtomicIsize::new(0);
static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

fn set_wide<const N: usize>(dst: &mut [u16; N], s: &str) {
    for (i, c) in s.encode_utf16().take(N - 1).enumerate() {
        dst[i] = c;
    }
}

/// A 32x32 blue disc with a white centre — drawn here so no .ico file or
/// resource compiler is needed.
fn make_icon() -> HICON {
    const N: usize = 32;
    let mut xor = vec![0u8; N * N * 4]; // BGRA, transparent
    let c = (N as f32 - 1.0) / 2.0;
    for y in 0..N {
        for x in 0..N {
            let (dx, dy) = (x as f32 - c, y as f32 - c);
            let d = (dx * dx + dy * dy).sqrt();
            let px = &mut xor[(y * N + x) * 4..(y * N + x) * 4 + 4];
            if d <= 5.5 {
                px.copy_from_slice(&[0xff, 0xff, 0xff, 0xff]); // white centre
            } else if d <= 14.0 {
                px.copy_from_slice(&[0xff, 0x8c, 0x4f, 0xff]); // #4f8cff
            }
        }
    }
    let and_mask = vec![0u8; N * N / 8];
    unsafe {
        let hinst = GetModuleHandleW(None).map(|m| HINSTANCE(m.0)).unwrap_or_default();
        CreateIcon(hinst, N as i32, N as i32, 1, 32, and_mask.as_ptr(), xor.as_ptr())
            .unwrap_or_default()
    }
}

fn notify(hwnd: HWND, op: windows::Win32::UI::Shell::NOTIFY_ICON_MESSAGE, info: Option<(&str, &str)>) {
    let mut nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        ..Default::default()
    };
    match info {
        None => {
            nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
            nid.uCallbackMessage = WM_TRAY;
            nid.hIcon = HICON(ICON.load(Ordering::SeqCst) as *mut _);
            set_wide(&mut nid.szTip, "OpenTrack");
        }
        Some((title, text)) => {
            nid.uFlags = NIF_INFO;
            nid.dwInfoFlags = NIIF_INFO;
            set_wide(&mut nid.szInfoTitle, title);
            set_wide(&mut nid.szInfo, text);
        }
    }
    unsafe {
        let _ = Shell_NotifyIconW(op, &nid);
    }
}

fn open(target: &str) {
    unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            &HSTRING::from(target),
            PCWSTR::null(),
            PCWSTR::null(),
            SW_SHOWNORMAL,
        );
    }
}

fn status_lines() -> Vec<String> {
    let s = STATUS.lock().unwrap();
    let mut lines = vec![format!("OpenTrack {}", VERSION)];
    match (&s.last_ok, &s.last_err) {
        (Some(ok), None) => lines.push(ok.clone()),
        (ok, Some(err)) => {
            if let Some(ok) = ok {
                lines.push(ok.clone());
            }
            lines.push(format!("Problem: {}", err));
        }
        (None, None) => lines.push("Starting...".to_string()),
    }
    lines
}

unsafe fn show_menu(hwnd: HWND) {
    let Ok(menu) = CreatePopupMenu() else { return };
    for line in status_lines() {
        let _ = AppendMenuW(menu, MF_STRING | MF_DISABLED | MF_GRAYED, 0, &HSTRING::from(line));
    }
    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
    let _ = AppendMenuW(menu, MF_STRING, ID_DASHBOARD, w!("Open dashboard"));
    let _ = AppendMenuW(menu, MF_STRING, ID_SEND_NOW, w!("Report location now"));
    let _ = AppendMenuW(menu, MF_STRING, ID_UPDATE, w!("Check for updates"));
    let _ = AppendMenuW(menu, MF_STRING, ID_LOG, w!("Open log"));

    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    let _ = SetForegroundWindow(hwnd); // required so the menu closes on outside click
    let cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, None).0;
    let _ = PostMessageW(hwnd, WM_NULL, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(menu);

    let ctx = CTX.get().unwrap();
    match cmd as usize {
        ID_DASHBOARD => open(&ctx.dashboard_url),
        ID_LOG => open(&exe_dir().join("agent.log").to_string_lossy()),
        ID_SEND_NOW => {
            let _ = ctx.tx.lock().unwrap().send(Cmd::SendNow);
        }
        ID_UPDATE => {
            let _ = ctx.tx.lock().unwrap().send(Cmd::CheckUpdate);
        }
        _ => {}
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_TRAY {
        let ev = (lparam.0 as u32) & 0xFFFF;
        if ev == WM_LBUTTONUP || ev == WM_RBUTTONUP {
            show_menu(hwnd);
        }
        return LRESULT(0);
    }
    // Explorer restarted: the tray was rebuilt, so add our icon again.
    if msg != 0 && msg == TASKBAR_CREATED.load(Ordering::SeqCst) {
        notify(hwnd, NIM_ADD, None);
        return LRESULT(0);
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

/// Create the tray icon and run the message loop. Never returns.
pub fn run(tx: Sender<Cmd>, dashboard_url: String, first_run_hint: bool) {
    let _ = CTX.set(Ctx { tx: Mutex::new(tx), dashboard_url });
    unsafe {
        let hinst = GetModuleHandleW(None).map(|m| HINSTANCE(m.0)).unwrap_or_default();
        let class = w!("OpenTrackTray");
        let wc = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassW(&wc);
        TASKBAR_CREATED.store(RegisterWindowMessageW(w!("TaskbarCreated")), Ordering::SeqCst);

        // hidden top-level window (never shown) that receives tray messages
        let Ok(hwnd) = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!("OpenTrack"),
            WS_OVERLAPPED,
            0,
            0,
            0,
            0,
            None,
            None,
            hinst,
            None,
        ) else {
            return;
        };

        ICON.store(make_icon().0 as isize, Ordering::SeqCst);
        notify(hwnd, NIM_ADD, None);
        if first_run_hint {
            notify(
                hwnd,
                NIM_MODIFY,
                Some((
                    "OpenTrack is running",
                    "It runs in the background. Click the tray icon (it may be under ^) to see its status.",
                )),
            );
        }

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

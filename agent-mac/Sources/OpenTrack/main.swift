// OpenTrack agent for macOS — runs on YOUR OWN Mac to help you locate it if
// lost or stolen. It periodically reports an approximate location to your own
// Supabase project and, only while you have switched the device to "lost
// mode" from your dashboard, shows a visible message and can take one photo.
//
// Only install this on devices you own or are authorized to manage.

import Cocoa
import CoreLocation
import AVFoundation
import CryptoKit
import IOKit.ps
import ServiceManagement

let repo = "Hotakacchi/opentrack"
let dmgName = "OpenTrack-mac.dmg"
let updateEvery: TimeInterval = 6 * 3600

let appVersion: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

// MARK: - Paths and logging

let supportDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("OpenTrack", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
let configURL = supportDir.appendingPathComponent("config.json")
let logURL = supportDir.appendingPathComponent("agent.log")

func log(_ message: String) {
    // keep the log tiny: start over once it passes 100 KB
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? Int, size > 100_000 {
        try? FileManager.default.removeItem(at: logURL)
    }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Config

struct Config: Codable {
    var supabase_url: String
    var supabase_anon_key: String
    var device_id: String
    var agent_key: String
    var interval_seconds: Int?
    var use_location: Bool?
    var enable_photo: Bool?
    var auto_update: Bool?
}

func loadConfig() -> Config? {
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

func saveConfig(_ c: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(c) else { return }
    try? data.write(to: configURL)
    // contains the agent key: owner-only
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
}

/// First-run dialog that collects the values shown in the dashboard.
@MainActor
func askForConfig() -> Config? {
    let labels = ["Supabase URL (https://xxxx.supabase.co)", "Supabase anon key", "device_id", "agent_key"]
    let rowH: CGFloat = 46
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: rowH * CGFloat(labels.count)))
    var fields: [NSTextField] = []
    for (i, text) in labels.enumerated() {
        let y = view.frame.height - rowH * CGFloat(i + 1)
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 0, y: y + 24, width: 420, height: 17)
        let field = NSTextField(frame: NSRect(x: 0, y: y, width: 420, height: 22))
        view.addSubview(label)
        view.addSubview(field)
        fields.append(field)
    }
    var message = "Paste the values from your OpenTrack dashboard and Supabase project."
    while true {
        let alert = NSAlert()
        alert.messageText = "Connect OpenTrack"
        alert.informativeText = message
        alert.accessoryView = view
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() != .alertFirstButtonReturn { return nil }
        let v = fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        if v.contains(where: { $0.isEmpty }) {
            message = "Please fill in all four fields."
            continue
        }
        guard v[0].lowercased().hasPrefix("https://") else {
            message = "The Supabase URL must start with https://"
            continue
        }
        return Config(supabase_url: v[0].trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                      supabase_anon_key: v[1], device_id: v[2], agent_key: v[3],
                      interval_seconds: 900, use_location: true, enable_photo: true, auto_update: true)
    }
}

// MARK: - Location

struct Fix {
    var lat: Double
    var lng: Double
    var accuracy: Double?
    var source: String
    var publicIP: String?
}

@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Fix?, Never>?
    private var requested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Wi-Fi based position via CoreLocation (needs Location Services access).
    func locate() async -> Fix? {
        await withCheckedContinuation { (c: CheckedContinuation<Fix?, Never>) in
            continuation = c
            requested = false
            switch manager.authorizationStatus {
            case .notDetermined:
                NSApp.activate(ignoringOtherApps: true)
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(nil)
            default:
                request()
            }
            // never hang forever (e.g. a permission prompt nobody answers)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish(nil) }
        }
    }

    private func request() {
        guard !requested else { return }
        requested = true
        manager.requestLocation()
    }

    private func finish(_ fix: Fix?) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: fix)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.continuation != nil else { return }
            switch manager.authorizationStatus {
            case .denied, .restricted: self.finish(nil)
            case .notDetermined: break
            default: self.request()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let fix = Fix(lat: l.coordinate.latitude, lng: l.coordinate.longitude,
                      accuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy : nil,
                      source: "wifi", publicIP: nil)
        Task { @MainActor in self.finish(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            log("CoreLocation failed: \(error.localizedDescription)")
            self.finish(nil)
        }
    }
}

/// City-level fallback (HTTPS, no API key).
func locateByIP() async -> Fix? {
    guard let url = URL(string: "https://ipwho.is/?fields=success,latitude,longitude,ip") else { return nil }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              j["success"] as? Bool == true,
              let lat = j["latitude"] as? Double, let lng = j["longitude"] as? Double else { return nil }
        return Fix(lat: lat, lng: lng, accuracy: 5000, source: "ip", publicIP: j["ip"] as? String)
    } catch {
        log("ip lookup failed: \(error.localizedDescription)")
        return nil
    }
}

func batteryPercent() -> Int? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
           let cur = d[kIOPSCurrentCapacityKey] as? Int,
           let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
            return cur * 100 / max
        }
    }
    return nil
}

// MARK: - Lost mode

var messageShown = false

/// Visible owner message. Uses osascript so it never blocks this process.
func showLostMessage(_ text: String) {
    guard !text.isEmpty, !messageShown else { return }
    messageShown = true
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv",
                   "-e", "display alert (item 1 of argv) message (item 2 of argv) as critical",
                   "-e", "end run",
                   "This device is being tracked by its owner", text]
    try? p.run()
}

final class PhotoGrabber: NSObject, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var continuation: CheckedContinuation<Data?, Never>?

    /// One camera frame as a <=640px JPEG, or nil.
    func capture() async -> Data? {
        guard await AVCaptureDevice.requestAccess(for: .video) else { log("camera access denied"); return nil }
        guard let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev) else { log("no camera"); return nil }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // let exposure settle
        let raw: Data? = await withCheckedContinuation { c in
            self.continuation = c
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
        session.stopRunning()
        guard let raw = raw else { return nil }
        return downscaledJPEG(raw)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        continuation?.resume(returning: error == nil ? photo.fileDataRepresentation() : nil)
        continuation = nil
    }

    private func downscaledJPEG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let scale = min(1.0, 640.0 / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled,
                                   [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - Supabase RPC

func rpc(_ cfg: Config, _ function: String, _ body: [String: Any]) async throws -> Any? {
    guard let url = URL(string: "\(cfg.supabase_url)/rest/v1/rpc/\(function)") else {
        throw NSError(domain: "OpenTrack", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad URL"])
    }
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.httpMethod = "POST"
    req.setValue(cfg.supabase_anon_key, forHTTPHeaderField: "apikey")
    req.setValue("Bearer \(cfg.supabase_anon_key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw NSError(domain: "OpenTrack", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — check device_id / agent_key / URL"])
    }
    return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

// MARK: - Self-update (GitHub Releases)

func parseVersion(_ s: String) -> [Int] {
    s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
}

func isNewer(_ a: [Int], than b: [Int]) -> Bool {
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

func githubGet(_ url: URL) async throws -> Data {
    var req = URLRequest(url: url, timeoutInterval: 120)
    req.setValue("opentrack-agent", forHTTPHeaderField: "User-Agent")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return try await URLSession.shared.data(for: req).0
}

/// If a newer release exists: download the dmg, verify its SHA-256 against the
/// release's SHA256SUMS.txt, then swap the app bundle after this process exits
/// and relaunch. Settings in Application Support are untouched.
func checkForUpdate() async throws {
    let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    guard let rel = try JSONSerialization.jsonObject(with: try await githubGet(api)) as? [String: Any],
          let tag = rel["tag_name"] as? String else { return }
    guard isNewer(parseVersion(tag), than: parseVersion(appVersion)) else { return }
    log("update available: \(tag) (running \(appVersion))")

    let assets = rel["assets"] as? [[String: Any]] ?? []
    func assetURL(_ name: String) -> URL? {
        assets.first { $0["name"] as? String == name }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
    }
    guard let dmgURL = assetURL(dmgName), let sumsURL = assetURL("SHA256SUMS.txt") else {
        log("update skipped: release assets missing"); return
    }
    let sums = String(data: try await githubGet(sumsURL), encoding: .utf8) ?? ""
    guard let expected = sums.split(separator: "\n")
        .first(where: { $0.hasSuffix(dmgName) })?
        .split(whereSeparator: { $0 == " " || $0 == "\t" }).first?.lowercased() else {
        log("update skipped: no checksum for \(dmgName)"); return
    }

    let dmg = try await githubGet(dmgURL)
    let actual = SHA256.hash(data: dmg).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { log("update aborted: checksum mismatch"); return }

    let appPath = Bundle.main.bundlePath
    let parent = (appPath as NSString).deletingLastPathComponent
    guard appPath.hasSuffix(".app"), FileManager.default.isWritableFile(atPath: parent) else {
        log("update skipped: cannot write to \(parent)"); return
    }
    let dmgPath = NSTemporaryDirectory() + "OpenTrack-update.dmg"
    try dmg.write(to: URL(fileURLWithPath: dmgPath))

    // Runs after we exit: wait, mount, replace, unmount, relaunch.
    let script = """
    while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 1; done
    MNT=$(mktemp -d)
    /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$1" >/dev/null || exit 1
    if /usr/bin/ditto "$MNT/OpenTrack.app" "$2.new"; then
      rm -rf "$2" && mv "$2.new" "$2"
    fi
    /usr/bin/hdiutil detach "$MNT" >/dev/null
    rm -f "$1"
    /usr/bin/open "$2"
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "sh", dmgPath, appPath]
    try p.run()
    log("installing \(tag) and restarting")
    exit(0)
}

// MARK: - Main loop

@MainActor
func tick(_ cfg: Config, _ locator: Locator) async {
    var fix: Fix? = nil
    if cfg.use_location ?? true { fix = await locator.locate() }
    if fix == nil { fix = await locateByIP() }
    guard let f = fix else { log("no location this round"); return }
    log("\(f.source) \(String(format: "%.4f,%.4f", f.lat, f.lng))")

    var body: [String: Any] = [
        "p_device_id": cfg.device_id, "p_agent_key": cfg.agent_key,
        "p_lat": f.lat, "p_lng": f.lng, "p_source": f.source,
    ]
    body["p_accuracy"] = f.accuracy ?? NSNull()
    body["p_battery"] = batteryPercent() ?? NSNull()
    body["p_public_ip"] = f.publicIP ?? NSNull()

    do {
        guard let state = try await rpc(cfg, "report_location", body) as? [String: Any] else { return }
        if state["lost_mode"] as? Bool == true {
            showLostMessage(state["lost_message"] as? String ?? "")
            if state["want_photo"] as? Bool == true, cfg.enable_photo ?? true,
               let jpeg = await PhotoGrabber().capture() {
                _ = try await rpc(cfg, "upload_photo", [
                    "p_device_id": cfg.device_id, "p_agent_key": cfg.agent_key,
                    "p_image": jpeg.base64EncodedString(),
                ])
                log("evidence photo uploaded")
            }
        } else {
            messageShown = false
        }
    } catch {
        log("tick failed: \(error.localizedDescription)")
    }
}

@MainActor
func run() async {
    var cfg = loadConfig()
    if cfg == nil {
        guard let entered = askForConfig() else { exit(0) }
        saveConfig(entered)
        cfg = entered
    }
    guard let config = cfg else { return }

    // start at login (macOS 13+; the user can review it in Login Items)
    if #available(macOS 13.0, *), SMAppService.mainApp.status != .enabled {
        do { try SMAppService.mainApp.register() }
        catch { log("login item registration failed: \(error.localizedDescription)") }
    }

    log("OpenTrack agent \(appVersion) started, every \(config.interval_seconds ?? 900)s")
    let locator = Locator()
    var lastUpdateCheck = Date.distantPast
    while true {
        await tick(config, locator)
        if (config.auto_update ?? true), Date().timeIntervalSince(lastUpdateCheck) >= updateEvery {
            lastUpdateCheck = Date()
            do { try await checkForUpdate() } catch { log("update check failed: \(error.localizedDescription)") }
        }
        try? await Task.sleep(nanoseconds: UInt64(max(30, config.interval_seconds ?? 900)) * 1_000_000_000)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await run() }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

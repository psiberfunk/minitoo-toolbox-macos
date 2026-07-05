import AppKit
import Foundation
import Network

/// Native builder/sender for small single-frame raw opcodes (e.g. brightness),
/// talking directly to the already-running daemon's TCP job socket. Avoids the
/// process-spawn + venv-activation latency of shelling out to a Python helper
/// for commands where a snappy UI (like a live-dragged slider) matters.
enum DivoomRawFrame {
    /// Same envelope as PROTOCOL.md / send_divoom_image.py's frame():
    /// 0x01 <declared_len LE16> <cmd> <body...> <checksum LE16> 0x02
    static func build(cmd: UInt8, body: Data) -> Data {
        var frame = Data()
        frame.append(0x01)
        let declared = UInt16(3 + body.count)
        frame.append(UInt8(declared & 0xFF))
        frame.append(UInt8((declared >> 8) & 0xFF))
        frame.append(cmd)
        frame.append(body)
        var sum: UInt32 = 0
        for b in frame[1...] { sum &+= UInt32(b) }
        let chk = UInt16(sum & 0xFFFF)
        frame.append(UInt8(chk & 0xFF))
        frame.append(UInt8((chk >> 8) & 0xFF))
        frame.append(0x02)
        return frame
    }

    static func writePacketsFile(_ packet: Data, name: String, in dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(name)-packets-lenpref.bin")
        var out = Data()
        out.append(UInt8(packet.count & 0xFF))
        out.append(UInt8((packet.count >> 8) & 0xFF))
        out.append(packet)
        try? out.write(to: path)
        return path
    }

    static func submit(packetsPath: URL, port: UInt16, waitForReply: Double = 0, completion: @escaping (String) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion("bad port")
            return
        }
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var job: [String: Any] = ["packets": packetsPath.path, "delay": 0.012, "dryRun": false]
                if waitForReply > 0 { job["waitForReply"] = waitForReply }
                guard let data = try? JSONSerialization.data(withJSONObject: job) else {
                    completion("job encode error")
                    conn.cancel()
                    return
                }
                conn.send(content: data + Data([0x0a]), completion: .contentProcessed { _ in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { recvData, _, _, error in
                        if let recvData, let str = String(data: recvData, encoding: .utf8) {
                            completion(str.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else if let error {
                            completion("receive error: \(error)")
                        } else {
                            completion("")
                        }
                        conn.cancel()
                    }
                })
            case .failed(let err):
                completion("connection failed: \(err)")
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }
}

final class DivoomMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let repo: URL
    let toolRoot: URL
    let supportDir: URL
    var daemonProcess: Process?
    var statusItemViewTimer: Timer?
    var controlCenterWindow: NSWindow?
    var controlCenterModel: ControlCenterModel?
    var whiteNoiseModel: WhiteNoiseModel?
    var customFacesModel: CustomFacesModel?
    var lastMessage = "Ready"
    var lastBrightness: Int = 100

    let address = "B1:21:81:B1:F0:84"
    let channel = "1"
    let daemonPort = "40583"
    var menuLog: URL { supportDir.appendingPathComponent("divoom-menubar.log") }
    var daemonLog: URL { supportDir.appendingPathComponent("divoom-menubar-daemon.log") }
    var daemonPidFile: URL { supportDir.appendingPathComponent("divoom-menubar-daemon.pid") }
    var capturesDir: URL { supportDir.appendingPathComponent("captures/mac-send") }

    override init() {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let resources = Bundle.main.resourceURL
        let bundledTools = resources?.appendingPathComponent("tools")
        if let resources, let bundledTools, fm.fileExists(atPath: bundledTools.appendingPathComponent("divoom-daemon").path) {
            self.repo = resources
            self.toolRoot = bundledTools
        } else {
            self.repo = cwd
            self.toolRoot = cwd.appendingPathComponent("tools")
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? cwd
        self.supportDir = appSupport.appendingPathComponent("DivoomMiniToo", isDirectory: true)
        super.init()
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: capturesDir, withIntermediateDirectories: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appendLog("menubar started repo=\(repo.path)")
        statusItem.button?.title = "◈ Divoom"
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        statusItemViewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        refreshTitle()
        // Don't blindly disconnect+restart on every launch: if a daemon from a
        // prior app instance is already running and holding a live RFCOMM
        // channel, tearing down the Bluetooth connection out from under it
        // just breaks that working connection for no reason (its stale
        // isOpen()/write state doesn't reliably self-heal).
        if isDaemonRunning() {
            setStatus("Daemon already running")
        } else {
            startDaemon(disconnectFirst: true)
        }
    }

    func refreshTitle() {
        let running = isDaemonRunning()
        statusItem.button?.title = running ? "◆ Divoom" : "◇ Divoom"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitle()
        rebuildMenu()
    }

    func rebuildMenu() {
        let daemonRunning = isDaemonRunning()
        let audioConnected = isAudioConnected()
        menu.removeAllItems()
        menu.addItem(disabled("Daemon: \(daemonRunning ? "Running" : "Stopped")"))
        menu.addItem(disabled("Audio profile: \(audioConnected ? "Connected" : "Disconnected")"))
        menu.addItem(disabled("Last: \(shortStatus(lastMessage))"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Control Center…", #selector(openControlCenter)))
        menu.addItem(brightnessSliderItem(enabled: daemonRunning))
        menu.addItem(item("Screen On", #selector(screenOnMenu), enabled: daemonRunning))
        menu.addItem(item("Screen Off", #selector(screenOffMenu), enabled: daemonRunning))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Start Daemon (only if audio disconnected)", #selector(startDaemonMenu), enabled: !daemonRunning && !audioConnected))
        menu.addItem(item("Disconnect Audio + Start Daemon", #selector(disconnectAndStartMenu), enabled: !daemonRunning))
        menu.addItem(item("Stop Daemon", #selector(stopDaemonMenu), enabled: daemonRunning))
        menu.addItem(item("Restart Daemon", #selector(restartDaemonMenu), enabled: true))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Disconnect Divoom Audio", #selector(disconnectAudioMenu), enabled: audioConnected))
        menu.addItem(item("Reconnect Divoom Audio", #selector(reconnectAudioMenu), enabled: !audioConnected))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Captures Folder", #selector(openCaptures)))
        menu.addItem(item("Open Protocol Notes", #selector(openProtocol)))
        menu.addItem(item("Open Menu Log", #selector(openMenuLog)))
        menu.addItem(item("Open Daemon Log", #selector(openDaemonLog)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Quit", #selector(quit)))
    }

    func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled
        return i
    }

    func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func shortStatus(_ message: String, limit: Int = 72) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= limit { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }

    func pythonExecutable() -> String {
        let venvPy = repo.appendingPathComponent(".venv/bin/python").path
        return FileManager.default.isExecutableFile(atPath: venvPy) ? venvPy : (executablePath("python3") ?? "/usr/bin/python3")
    }

    func executablePath(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(_ executable: String, _ args: [String], wait: Bool = true) -> (Int32, String) {
        appendLog("run \(executable) \(args.joined(separator: " ")) wait=\(wait)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, String(describing: error)) }
        if wait { p.waitUntilExit() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if wait { appendLog("run exit=\(p.terminationStatus) out=\(String(out.suffix(500)))") }
        return (p.terminationStatus, out)
    }

    func isDaemonRunning() -> Bool {
        if let pidText = try? String(contentsOf: daemonPidFile, encoding: .utf8),
           let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0,
           kill(pid, 0) == 0 {
            return true
        }
        let (code, _) = run("/usr/bin/pgrep", ["-x", "divoom-daemon"], wait: true)
        return code == 0
    }

    func isAudioConnected() -> Bool {
        guard let blueutil = executablePath("blueutil") else { return false }
        let (code, out) = run(blueutil, ["--is-connected", address], wait: true)
        return code == 0 && out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func setStatus(_ message: String) {
        appendLog("status \(message)")
        DispatchQueue.main.async {
            self.lastMessage = self.shortStatus(message, limit: 160)
            self.refreshTitle()
            self.rebuildMenu()
        }
    }

    func startDaemon(disconnectFirst: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            if disconnectFirst, let blueutil = self.executablePath("blueutil") {
                _ = self.run(blueutil, ["--disconnect", self.address])
            }
            Thread.sleep(forTimeInterval: disconnectFirst ? 1.5 : 0.0)
            if self.isDaemonRunning() {
                self.setStatus("Daemon already running")
                return
            }
            let log = self.daemonLog
            let p = Process()
            p.executableURL = self.toolRoot.appendingPathComponent("divoom-daemon")
            p.arguments = [self.address, self.channel, self.daemonPort]
            p.currentDirectoryURL = self.repo
            let logHandle: FileHandle
            FileManager.default.createFile(atPath: log.path, contents: nil)
            do {
                logHandle = try FileHandle(forWritingTo: log)
                logHandle.truncateFile(atOffset: 0)
            } catch {
                self.notify("Failed to open daemon log: \(error)")
                return
            }
            p.standardOutput = logHandle
            p.standardError = logHandle
            do {
                try p.run()
                self.daemonProcess = p
                try? "\(p.processIdentifier)\n".write(to: self.daemonPidFile, atomically: true, encoding: .utf8)
                self.appendLog("daemon launched pid=\(p.processIdentifier) disconnectFirst=\(disconnectFirst)")
                Thread.sleep(forTimeInterval: 2.0)
                if self.isDaemonRunning() {
                    self.setStatus("Daemon started")
                } else {
                    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: self.daemonPidFile)
                    if logText.contains("0x-1ffffd44") {
                        self.setStatus("Start failed: audio/RFCOMM busy; use Disconnect Audio + Start")
                    } else {
                        self.setStatus("Daemon failed; see daemon log")
                    }
                }
            } catch {
                self.setStatus("Start failed: \(error)")
            }
        }
    }

    func stopDaemon() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.daemonProcess?.terminate()
            self.daemonProcess = nil
            _ = self.run("/usr/bin/pkill", ["-f", "divoom-daemon"])
            try? FileManager.default.removeItem(at: self.daemonPidFile)
            self.setStatus("Daemon stopped")
        }
    }

    @objc func startDaemonMenu() { startDaemon(disconnectFirst: false) }
    @objc func disconnectAndStartMenu() { startDaemon(disconnectFirst: true) }
    @objc func stopDaemonMenu() { stopDaemon() }
    @objc func restartDaemonMenu() {
        stopDaemon()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { self.startDaemon(disconnectFirst: true) }
    }

    @objc func disconnectAudioMenu() {
        DispatchQueue.global().async {
            guard let blueutil = self.executablePath("blueutil") else {
                self.setStatus("blueutil not found")
                return
            }
            let (_, out) = self.run(blueutil, ["--disconnect", self.address])
            self.setStatus(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Audio disconnected" : out)
        }
    }

    @objc func reconnectAudioMenu() {
        DispatchQueue.global().async {
            guard let blueutil = self.executablePath("blueutil") else {
                self.setStatus("blueutil not found")
                return
            }
            let (_, out) = self.run(blueutil, ["--connect", self.address])
            self.setStatus(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Audio reconnect requested" : out)
        }
    }

    func activateClock(_ shortcut: String, completion: ((Bool, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.isDaemonRunning() {
                self.setStatus("Daemon not running")
                completion?(false, "Daemon not running")
                return
            }
            let py = self.pythonExecutable()
            let client = self.toolRoot.appendingPathComponent("divoom_clock.py").path
            let (code, out) = self.run(py, [client, shortcut])
            let detail = String(out.suffix(700))
            self.setStatus(code == 0 ? "Activated custom face \(shortcut)" : "Clock issue: \(detail)")
            completion?(code == 0, detail)
        }
    }

    func setScreen(on: Bool) {
        let job: [String: Any] = [
            "Command": "Channel/OnOffScreen",
            "OnOff": on ? 1 : 0,
            "DeviceId": 600111083,
            "DevicePassword": 1777733348,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else {
            setStatus("Screen \(on ? "on" : "off"): JSON encode error")
            return
        }
        let packet = DivoomRawFrame.build(cmd: 0x01, body: body)
        let path = DivoomRawFrame.writePacketsFile(packet, name: "screen-\(on ? "on" : "off")", in: capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(daemonPort) ?? 40583) { [weak self] result in
            DispatchQueue.main.async {
                let hardFailure = result.contains("failed") || result.contains("error") || result.isEmpty
                self?.setStatus(hardFailure ? "Screen issue: \(result)" : "Screen \(on ? "on" : "off")")
            }
        }
    }

    @objc func screenOnMenu() { setScreen(on: true) }
    @objc func screenOffMenu() { setScreen(on: false) }

    func brightnessSliderItem(enabled: Bool) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))

        let label = NSTextField(labelWithString: "Brightness")
        label.frame = NSRect(x: 14, y: 8, width: 74, height: 18)
        label.font = NSFont.menuFont(ofSize: 0)
        label.isEnabled = enabled
        container.addSubview(label)

        let slider = NSSlider(value: Double(lastBrightness), minValue: 0, maxValue: 100, target: self, action: #selector(brightnessSliderChanged(_:)))
        slider.frame = NSRect(x: 92, y: 6, width: 116, height: 20)
        slider.isContinuous = false
        slider.isEnabled = enabled
        container.addSubview(slider)

        let menuItem = NSMenuItem()
        menuItem.view = container
        return menuItem
    }

    @objc func brightnessSliderChanged(_ sender: NSSlider) {
        setBrightness(Int(sender.intValue))
    }

    func setBrightness(_ level: Int) {
        lastBrightness = level
        let level = max(0, min(100, level))
        // Native fast-path: build the SPP_SET_SYSTEM_BRIGHT (0x74) frame directly
        // and talk to the daemon's TCP socket, skipping the Python/venv spin-up
        // cost that makes slider dragging feel sluggish through divoom_display.py.
        let packet = DivoomRawFrame.build(cmd: 0x74, body: Data([UInt8(level)]))
        let path = DivoomRawFrame.writePacketsFile(packet, name: "brightness-\(level)", in: capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(daemonPort) ?? 40583) { [weak self] result in
            DispatchQueue.main.async {
                // "sent but final ACK not observed" is expected/benign for
                // single-frame raw commands (only chunked GIF transfers get a
                // real ACK); only surface genuine transport-level failures.
                let hardFailure = result.contains("failed") || result.contains("error") || result.isEmpty
                self?.setStatus(hardFailure ? "Brightness issue: \(result)" : "Brightness set to \(level)%")
            }
        }
    }

    @objc func openCaptures() {
        NSWorkspace.shared.open(capturesDir)
    }

    @objc func openProtocol() {
        let bundled = repo.appendingPathComponent("PROTOCOL.md")
        if FileManager.default.fileExists(atPath: bundled.path) {
            NSWorkspace.shared.open(bundled)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("PROTOCOL.md"))
        }
    }

    @objc func openMenuLog() {
        NSWorkspace.shared.open(menuLog)
    }

    @objc func openDaemonLog() {
        NSWorkspace.shared.open(daemonLog)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func notify(_ title: String, detail: String = "") { setStatus(detail.isEmpty ? title : "\(title): \(detail)") }

    func appendLog(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let text = "[\(ts)] \(line)\n"
        if !FileManager.default.fileExists(atPath: menuLog.path) {
            FileManager.default.createFile(atPath: menuLog.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: menuLog) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }
}

@main
enum DivoomMenuBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = DivoomMenuBar()
        app.delegate = delegate
        app.run()
    }
}

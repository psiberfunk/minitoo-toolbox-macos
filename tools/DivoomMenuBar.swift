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
        writePacketsFile([packet], name: name, in: dir)
    }

    /// Multi-frame variant (e.g. a "Foo/Enter" frame followed by a
    /// "Foo/SetConfig" frame in the same job), same length-prefixed layout
    /// send_divoom_image.py's write_packets uses.
    static func writePacketsFile(_ packets: [Data], name: String, in dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(name)-packets-lenpref.bin")
        var out = Data()
        for packet in packets {
            out.append(UInt8(packet.count & 0xFF))
            out.append(UInt8((packet.count >> 8) & 0xFF))
            out.append(packet)
        }
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

enum DivoomControlState: Equatable {
    case stopped, checking, live, unavailable
    var label: String {
        switch self {
        case .stopped: return "Not running"
        case .checking: return "Checking…"
        case .live: return "Working"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Compact template images for the menu-bar's three MiniToo health tiers.
/// A custom partial glyph is necessary because Unicode/SF Symbols provide a
/// filled diamond and an outline, but not a bottom-half-filled diamond.
enum DivoomStatusGlyph {
    case ready, partial, disconnected

    static func image(_ state: DivoomStatusGlyph) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: 7, y: 13))
            diamond.line(to: NSPoint(x: 13, y: 7))
            diamond.line(to: NSPoint(x: 7, y: 1))
            diamond.line(to: NSPoint(x: 1, y: 7))
            diamond.close()
            switch state {
            case .ready:
                NSColor.labelColor.setFill()
                diamond.fill()
            case .partial:
                NSGraphicsContext.saveGraphicsState()
                diamond.addClip()
                NSColor.labelColor.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 14, height: 7)).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.labelColor.setStroke()
                diamond.lineWidth = 1.2
                diamond.stroke()
            case .disconnected:
                NSColor.labelColor.setStroke()
                diamond.lineWidth = 1.2
                diamond.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class DivoomMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let repo: URL
    let toolRoot: URL
    let supportDir: URL
    var daemonProcess: Process?
    var controlState: DivoomControlState = .stopped
    var lastControlProbe: Date?
    var statusItemViewTimer: Timer?
    var controlCenterWindow: NSWindow?
    var controlCenterModel: ControlCenterModel?
    var whiteNoiseModel: WhiteNoiseModel?
    var customFacesModel: CustomFacesModel?
    var deviceControlsModel: DeviceControlsModel?
    var photoAlbumModel: PhotoAlbumModel?
    var atmosphereModel: AtmosphereModel?
    var deviceSettingsModel: DeviceSettingsModel?
    var preferencesWindow: NSWindow?
    var preferencesModel: PreferencesModel?
    var deviceSetupWindow: NSWindow?
    var deviceSetupModel: DeviceSetupModel?
    let batteryMonitor = BatteryMonitorModel()
    let updateController = DivoomUpdateController()
    var lastMessage = "Ready"
    var lastBrightness: Int = 100

    // Persisted so no device MAC is ever hardcoded in source — discovered
    // via a one-time Bluetooth scan (DivoomDeviceSetup.swift) instead, and
    // cached here for every launch after that.
    var address: String {
        get { UserDefaults.standard.string(forKey: "DeviceAddress") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "DeviceAddress") }
    }
    // Cached alongside the address (from the scan result, or a best-effort
    // blueutil lookup for manual entry) purely for display — never used to
    // address the device, since the daemon only ever needs the MAC.
    var deviceName: String {
        get { UserDefaults.standard.string(forKey: "DeviceName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "DeviceName") }
    }
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

    // Persisted separately from Info.plist's LSUIElement (which only sets
    // the policy at first launch) — NSApp.setActivationPolicy can be changed
    // at any time afterward, which is what lets this be a live user toggle
    // instead of a build-time/Info.plist setting.
    var showDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: "ShowDockIcon") }
        set { UserDefaults.standard.set(newValue, forKey: "ShowDockIcon") }
    }

    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    // Standard Dock-icon-click hook: if the user shows the Dock icon and
    // clicks it with no window open, open Control Center instead of doing
    // nothing (a regular-policy app with zero windows looks broken
    // otherwise).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openControlCenter()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconPolicy()
        appendLog("menubar started repo=\(repo.path)")
        statusItem.button?.title = "◈ Divoom"
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        statusItemViewTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        refreshTitle()

        // Advanced/scripting override: `--address XX:XX:XX:XX:XX:XX` on the
        // app's own launch args re-caches a new address before anything else
        // runs, without needing the Preferences UI.
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--address"), args.count > flagIndex + 1 {
            address = DeviceScanModel.normalize(args[flagIndex + 1])
            appendLog("address overridden via --address launch arg")
        }

        guard !address.isEmpty else {
            setStatus("No MiniToo set up yet")
            openDeviceSetup { [weak self] in
                // A newly selected MiniToo should behave exactly like a
                // remembered one: begin the non-disruptive control-service
                // startup automatically.  There is no extra user action.
                self?.startDaemon(disconnectFirst: false)
            }
            if UserDefaults.standard.bool(forKey: "ShowBatteryStatus") {
                batteryMonitor.start(usePrivateAPI: UserDefaults.standard.bool(forKey: "UseBatteryPrivateAPI"))
            }
            return
        }

        // Don't blindly disconnect+restart on every launch: if a daemon from a
        // prior app instance is already running and holding a live RFCOMM
        // channel, tearing down the Bluetooth connection out from under it
        // just breaks that working connection for no reason (its stale
        // isOpen()/write state doesn't reliably self-heal).
        if isDaemonRunning() {
            setStatus("Daemon already running")
            scheduleInitialControlProbe()
        } else {
            // Starting the daemon does not disconnect the audio profile.
            // It opens its own RFCOMM control connection when possible.
            startDaemon(disconnectFirst: false)
        }
        if UserDefaults.standard.bool(forKey: "ShowBatteryStatus") {
            batteryMonitor.start(usePrivateAPI: UserDefaults.standard.bool(forKey: "UseBatteryPrivateAPI"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateController.startAfterConsentIfNeeded { [weak self] message in
                self?.setStatus(message)
            }
        }
    }

    func refreshTitle() {
        let linked = isAudioConnected()
        let audio = DivoomAudioRoute.state(exactDeviceName: currentBluetoothName())
        if controlState == .live && linked && (audio == .available || audio == .selected) {
            setStatusTitle(glyph: .ready)
        } else if !DivoomBluetooth.isPoweredOn() || address.isEmpty {
            // Bluetooth itself is unavailable, rather than merely an
            // incomplete MiniToo connection, so retain the explicit X.
            statusItem.button?.image = nil
            statusItem.button?.title = "× Divoom"
        } else if !linked {
            setStatusTitle(glyph: .disconnected)
        } else {
            setStatusTitle(glyph: .partial)
        }
    }

    func setStatusTitle(glyph: DivoomStatusGlyph) {
        statusItem.button?.image = DivoomStatusGlyph.image(glyph)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " Divoom"
    }

    /// The MAC is the device identity used for control. The human-readable
    /// Bluetooth name is only an audio-route correlation hint, so refresh it
    /// from that identity whenever macOS can provide a current value.
    func currentBluetoothName() -> String {
        guard !address.isEmpty else { return deviceName }
        let liveName = DivoomBluetooth.device(address: address)?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !liveName.isEmpty else { return deviceName }
        if liveName != deviceName { deviceName = liveName }
        return liveName
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitle()
        rebuildMenu()
        refreshControlStateIfNeeded()
    }

    func rebuildMenu() {
        let bluetoothPoweredOn = DivoomBluetooth.isPoweredOn()
        // When Bluetooth itself is off, do not make the user parse a
        // diagnostic matrix whose remaining rows cannot be meaningful.
        if !bluetoothPoweredOn {
            menu.removeAllItems()
            menu.addItem(disabled("Bluetooth is turned off"))
            menu.addItem(item("Open Bluetooth Settings…", #selector(openBluetoothSettings)))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item("Preferences…", #selector(openPreferences), keyEquivalent: ","))
            menu.addItem(item("Quit", #selector(quit)))
            return
        }
        let daemonRunning = isDaemonRunning()
        let bluetoothLinked = isAudioConnected()
        let audioRoute = DivoomAudioRoute.state(exactDeviceName: currentBluetoothName())
        let isReady = controlState == .live && bluetoothLinked && (audioRoute == .available || audioRoute == .selected)
        let overall: String
        if isReady {
            overall = "Ready"
        } else if address.isEmpty {
            overall = "Unavailable"
        } else if !bluetoothLinked {
            overall = "No MiniToo connection"
        } else if controlState == .live && audioRoute == .unavailable {
            overall = "Partial — audio unavailable"
        } else if controlState == .live && audioRoute == .unknown {
            overall = "Partial — audio unknown"
        } else {
            overall = "Partial / checking"
        }
        menu.removeAllItems()
        // A missing MiniToo link makes the individual transport, audio, and
        // control rows both unavailable and redundant. Keep this state to two
        // plain facts rather than exposing internal implementation layers.
        if !bluetoothLinked {
            menu.addItem(disabled("MiniToo: Not connected"))
            menu.addItem(disabled(daemonRunning ? "Control service: Waiting for MiniToo" : "Control service: Not running"))
            if shouldShowLastMessage { menu.addItem(disabled("Last: \(shortStatus(lastMessage))")) }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item("Open Control Center…", #selector(openControlCenter)))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(debuggingToolsSubmenu())
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item("Check for Updates…", #selector(checkForUpdatesMenu), enabled: updateController.isConfigured))
            menu.addItem(item("Preferences…", #selector(openPreferences), keyEquivalent: ","))
            menu.addItem(item("Quit", #selector(quit)))
            return
        }
        // The filled menu-bar diamond already summarizes Ready. In that
        // state, show only the three independent user-facing layers; daemon
        // lifecycle and an aggregate "MiniToo: Ready" add no information.
        if !isReady {
            menu.addItem(disabled("MiniToo: \(overall)"))
            menu.addItem(disabled("Daemon: \(daemonRunning ? "Running" : "Stopped")"))
        }
        menu.addItem(disabled("Bluetooth: \(bluetoothLinked ? "Connected" : "Disconnected")"))
        menu.addItem(disabled("Audio on this Mac: \(audioRoute.label)"))
        menu.addItem(disabled("Device control: \(controlState.label)"))
        if batteryMonitor.isEnabled {
            let chargingSuffix = (batteryMonitor.percent != nil && !batteryMonitor.isOnBattery) ? " (charging)" : ""
            let text = (batteryMonitor.percent.map { "Battery: \($0)%" } ?? "Battery: …") + chargingSuffix
            let iconName = BatteryMonitorModel.batteryIconName(percent: batteryMonitor.percent)
            menu.addItem(disabledBattery(text, image: NSImage(systemSymbolName: iconName, accessibilityDescription: nil)))
        }
        if shouldShowLastMessage { menu.addItem(disabled("Last: \(shortStatus(lastMessage))")) }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Open Control Center…", #selector(openControlCenter)))
        if controlState == .live {
            menu.addItem(brightnessSliderItem(enabled: true))
        }
        menu.addItem(NSMenuItem.separator())
        if daemonRunning && controlState == .live {
            menu.addItem(item("Stop Control Service", #selector(stopDaemonMenu)))
        } else if daemonRunning {
            menu.addItem(item("Retry Control Service", #selector(restartDaemonMenu)))
            menu.addItem(item("Stop Control Service", #selector(stopDaemonMenu)))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(debuggingToolsSubmenu())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Check for Updates…", #selector(checkForUpdatesMenu), enabled: updateController.isConfigured))
        menu.addItem(item("Preferences…", #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(item("Quit", #selector(quit)))
    }

    func debuggingToolsSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Debugging Tools", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(item("Open Captures Folder", #selector(openCaptures)))
        submenu.addItem(item("Open Protocol Notes", #selector(openProtocol)))
        submenu.addItem(item("Open Menu Log", #selector(openMenuLog)))
        submenu.addItem(item("Open Daemon Log", #selector(openDaemonLog)))
        // Debugging Tools is deliberately stable rather than context-pruned:
        // it is the user's escape hatch when our current status inference is
        // wrong or incomplete. Destructive recovery still asks for consent.
        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(item("Restart Control Service", #selector(restartDaemonMenu)))
        submenu.addItem(item("Disconnect MiniToo Bluetooth + Retry Control Service…", #selector(recoverBluetoothAndRestartControlService)))
        parent.submenu = submenu
        return parent
    }

    func item(_ title: String, _ action: Selector, enabled: Bool = true, keyEquivalent: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        i.target = self
        i.isEnabled = enabled
        return i
    }

    func disabled(_ title: String, image: NSImage? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        i.image = image
        return i
    }

    /// Keep NSMenuItem's native left alignment. The battery image is an inline
    /// attachment after the title, not a leading menu image and not a custom
    /// view with hand-tuned insets.
    func disabledBattery(_ title: String, image: NSImage?) -> NSMenuItem {
        let item = disabled(title)
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.disabledControlTextColor,
            ]
        )
        let attachment = NSTextAttachment()
        attachment.image = image
        text.append(NSAttributedString(string: " "))
        text.append(NSAttributedString(attachment: attachment))
        item.attributedTitle = text
        return item
    }

    func shortStatus(_ message: String, limit: Int = 72) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= limit { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }

    /// Routine lifecycle/update configuration text does not earn a permanent
    /// status row. Action results and errors still remain visible.
    var shouldShowLastMessage: Bool {
        let normalMessages = [
            "Ready",
            "Daemon already running",
            "Daemon started",
            "Starting control service…",
            "Updates are not configured in this build",
        ]
        return !normalMessages.contains(lastMessage)
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
        DivoomBluetooth.isConnected(address: address)
    }

    func setStatus(_ message: String) {
        appendLog("status \(message)")
        DispatchQueue.main.async {
            self.lastMessage = self.shortStatus(message, limit: 160)
            self.refreshTitle()
            self.rebuildMenu()
        }
    }

    /// A recent valid WhiteNoise/Get reply is an end-to-end RFCOMM proof. The
    /// query is capture-derived and read-only; it runs at most once per 15s
    /// while the menu is opened, never as a background heartbeat.
    func refreshControlStateIfNeeded() {
        guard isDaemonRunning() else { controlState = .stopped; return }
        guard isAudioConnected() else { controlState = .unavailable; return }
        if let lastControlProbe, Date().timeIntervalSince(lastControlProbe) < 15 { return }
        guard controlState != .checking else { return }
        controlState = .checking
        let job: [String: Any] = [
            "Command": "WhiteNoise/Get", "DeviceId": 600111083,
            "DevicePassword": 1777733348, "Token": 1777741943, "UserId": 404779143,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else { controlState = .unavailable; return }
        let packet = DivoomRawFrame.build(cmd: 0x01, body: body)
        let path = DivoomRawFrame.writePacketsFile(packet, name: "control-health", in: capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(daemonPort) ?? 40583, waitForReply: 1.5) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastControlProbe = Date()
                guard let data = result.data(using: .utf8),
                      let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reply = outer["reply"] as? String,
                      let replyData = reply.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: replyData)) != nil
                else {
                    self.controlState = .unavailable
                    self.rebuildMenu()
                    self.refreshTitle()
                    return
                }
                self.controlState = .live
                self.rebuildMenu()
                self.refreshTitle()
            }
        }
    }

    /// Establish the initial menu-bar health state without making the user
    /// open its menu. This is one existing, read-only WhiteNoise/Get probe
    /// after startup/reuse—not a continuous heartbeat or a new opcode.
    func scheduleInitialControlProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lastControlProbe = nil
            self.refreshControlStateIfNeeded()
        }
    }


    func startDaemon(disconnectFirst: Bool) {
        DispatchQueue.main.async {
            self.controlState = .checking
            self.setStatus("Starting control service…")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if disconnectFirst {
                _ = DivoomBluetooth.disconnect(address: self.address)
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
                    self.scheduleInitialControlProbe()
                } else {
                    self.controlState = .unavailable
                    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: self.daemonPidFile)
                    if logText.contains("0x-1ffffd44") {
                        self.setStatus("Control service could not start: Bluetooth/RFCOMM is busy; see daemon log")
                    } else {
                        self.setStatus("Daemon failed; see daemon log")
                    }
                }
            } catch {
                self.controlState = .unavailable
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

    @objc func stopDaemonMenu() { stopDaemon() }
    @objc func restartDaemonMenu() {
        stopDaemon()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { self.startDaemon(disconnectFirst: false) }
    }

    /// Last-resort recovery for the known RFCOMM-busy failure.  This is a
    /// generic Bluetooth link teardown, not a precise audio-profile command,
    /// so it must remain user-confirmed and never run as normal startup.
    @objc func recoverBluetoothAndRestartControlService() {
        let alert = NSAlert()
        alert.messageText = "Disconnect MiniToo Bluetooth and retry?"
        alert.informativeText = "This can interrupt MiniToo audio on this Mac and disconnect its current Bluetooth link. Use it only when the control service is unavailable or busy."
        alert.addButton(withTitle: "Disconnect and Retry")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        stopDaemon()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            self.startDaemon(disconnectFirst: true)
        }
    }

    func activateClock(_ shortcut: String, completion: ((Bool, String) -> Void)? = nil) {
        guard isDaemonRunning() else {
            setStatus("Daemon not running")
            completion?(false, "Daemon not running")
            return
        }
        guard let clockId = DivoomClockFrame.resolveClockId(shortcut) else {
            setStatus("Clock issue: unknown shortcut \(shortcut)")
            completion?(false, "unknown shortcut \(shortcut)")
            return
        }
        guard let packet = DivoomClockFrame.selectPacket(clockId: clockId) else {
            setStatus("Clock issue: JSON encode error")
            completion?(false, "JSON encode error")
            return
        }
        let path = DivoomRawFrame.writePacketsFile(packet, name: "clock-\(clockId)", in: capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(daemonPort) ?? 40583) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let detail = String(result.suffix(700))
                let hardFailure = result.lowercased().contains("failed") || result.lowercased().contains("error") || result.isEmpty
                self.setStatus(hardFailure ? "Clock issue: \(detail)" : "Activated custom face \(shortcut)")
                completion?(!hardFailure, detail)
            }
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

    @objc func checkForUpdatesMenu() {
        updateController.checkForUpdates { [weak self] message in self?.setStatus(message) }
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

    @objc func openBluetoothSettings() {
        // macOS's public System Settings URL route. It avoids guessing at a
        // preferences-pane filesystem path and lets the OS handle its own UI.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
        NSWorkspace.shared.open(url)
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

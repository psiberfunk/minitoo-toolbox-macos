import AppKit
import SwiftUI
import Foundation
import ObjectiveC

/// Reads the MiniToo's battery percentage. There is no public API for this;
/// two different private mechanisms were found and both work, offered here
/// as two opt-in strategies since either could break on a future macOS
/// update with no notice (that's the nature of private API/log format —
/// neither is documented or guaranteed stable):
///
/// 1. **Log parsing (default).** `bluetoothd` logs a plain, public text line
///    roughly once a minute:
///      ...CBPowerSource Nm 'Divoom MiniToo-...', ... VID 0x05D6 (?), ...
///      Battery -90%
///    The class that actually carries this data, CBPowerSource, lives inside
///    the public CoreBluetooth.framework binary but is entirely undocumented
///    (absent from every CoreBluetooth header in the Xcode SDK) and is
///    populated/consumed internally by bluetoothd over a private XPC channel
///    with no public entry point that hands a caller one of these objects —
///    so the log text is the only observable, public artifact of it. Matches
///    on Divoom's vendor/product ID rather than the device's paired display
///    name, since the name includes a per-pairing suffix (e.g.
///    "-Audio-<owner>") that varies per user/install.
///
/// 2. **Private CoreUtils API (opt-in).** `CoreUtils.framework` (private, not
///    part of any public SDK) defines `CUPowerSourceMonitor`/`CUPowerSource`,
///    reachable by `dlopen`-ing the framework directly and driving it via the
///    Objective-C runtime (no headers ship for this — everything here is
///    read from the class's own runtime metadata). This gives live,
///    event-driven updates with no subprocess at all. Confirmed working by
///    direct testing: `activateWithCompletion:` fires `powerSourceFoundHandler`
///    with a real `CUPowerSource` for `vendorID=1494 productID=10` (decimal
///    forms of Divoom's 0x05D6/0x000A) whose `chargeLevel`/`charging`
///    matched the device's actual state exactly.
final class BatteryMonitorModel: ObservableObject {
    // Reflects whether monitoring is turned on at all — kept separate from
    // `percent` so UI can reserve the battery indicator's layout space as
    // soon as the user enables it, rather than only once a first reading
    // arrives. Without this, the Control Center window resizes twice (once
    // when the icon slot first appears, again when the % text arrives),
    // which reads as jank.
    @Published var isEnabled: Bool = false
    @Published var percent: Int?
    @Published var isOnBattery: Bool = false
    @Published var lastUpdated: Date?

    private var logProcess: Process?
    private var lineBuffer = ""
    private var cuMonitor: AnyObject?

    func start(usePrivateAPI: Bool) {
        stop()
        isEnabled = true
        if usePrivateAPI {
            startViaPrivateAPI()
        } else {
            startViaLogParsing()
        }
    }

    func stop() {
        if let p = logProcess {
            if let pipe = p.standardOutput as? Pipe {
                pipe.fileHandleForReading.readabilityHandler = nil
            }
            p.terminate()
            logProcess = nil
        }
        if let monitor = cuMonitor as? NSObject {
            let sel = NSSelectorFromString("invalidate")
            if monitor.responds(to: sel) {
                monitor.perform(sel)
            }
            cuMonitor = nil
        }
        isEnabled = false
        percent = nil
        lastUpdated = nil
    }

    private func update(percent n: Int, onBattery: Bool) {
        DispatchQueue.main.async {
            self.percent = n
            self.isOnBattery = onBattery
            self.lastUpdated = Date()
        }
    }

    // MARK: - Strategy 1: log parsing

    private func startViaLogParsing() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--predicate", "process == \"bluetoothd\"", "--style", "compact"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.consumeLogChunk(text)
        }
        do {
            try p.run()
            logProcess = p
        } catch {
            // Battery status is a nice-to-have, not critical — fail silently
            // and just leave `percent` nil.
        }
    }

    private func consumeLogChunk(_ chunk: String) {
        lineBuffer += chunk
        let lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            parseLogLine(line)
        }
    }

    private func parseLogLine(_ line: String) {
        guard line.contains("CBPowerSource"), line.contains("VID 0x05D6"), line.contains("PID 0x000A") else { return }
        guard let batteryRange = line.range(of: "Battery ") else { return }
        let rest = line[batteryRange.upperBound...]
        guard let percentSign = rest.range(of: "%") else { return }
        let numStr = rest[rest.startIndex..<percentSign.lowerBound]
        guard let n = Int(numStr) else { return }
        // Inferred from observed samples, not documented anywhere:
        // bluetoothd appears to log a negative value while discharging and a
        // non-negative one (often with a parenthetical note like
        // "(FullyCharged)") while on/near a charger.
        update(percent: abs(n), onBattery: n < 0)
    }

    // SF Symbols' battery family only ships discrete tiers (0/25/50/75/100),
    // not a continuously-scaling glyph — round to the nearest tier rather
    // than always showing one fixed icon regardless of charge level.
    static func batteryIconName(percent: Int?) -> String {
        guard let percent else { return "battery.0" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: - Strategy 2: private CoreUtils API

    private static let divoomVendorID = 1494  // 0x05D6, decimal as CUPowerSource reports it
    private static let miniTooProductID = 10  // 0x000A

    private func startViaPrivateAPI() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreUtils.framework/Versions/A/CoreUtils", RTLD_NOW) != nil else { return }
        guard let monitorClass = NSClassFromString("CUPowerSourceMonitor") as? NSObject.Type else { return }
        let monitor = monitorClass.init()

        let handler: @convention(block) (AnyObject) -> Void = { [weak self] source in
            self?.handlePrivateAPISource(source)
        }
        monitor.setValue(handler, forKey: "powerSourceFoundHandler")
        monitor.setValue(handler, forKey: "powerSourceChangedHandler")
        monitor.setValue(DispatchQueue.main, forKey: "dispatchQueue")

        let sel = NSSelectorFromString("activateWithCompletion:")
        guard monitor.responds(to: sel) else { return }
        typealias ActivateFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let completion: @convention(block) (AnyObject?) -> Void = { _ in }
        let method = class_getInstanceMethod(monitorClass, sel)!
        let fn = unsafeBitCast(method_getImplementation(method), to: ActivateFn.self)
        fn(monitor, sel, completion as AnyObject)

        cuMonitor = monitor
    }

    private func handlePrivateAPISource(_ source: AnyObject) {
        guard let vendorID = source.value(forKey: "vendorID") as? NSNumber,
              let productID = source.value(forKey: "productID") as? NSNumber,
              vendorID.intValue == Self.divoomVendorID, productID.intValue == Self.miniTooProductID else { return }
        guard let chargeLevel = source.value(forKey: "chargeLevel") as? NSNumber else { return }
        let charging = (source.value(forKey: "charging") as? NSNumber)?.boolValue ?? false
        update(percent: Int((chargeLevel.doubleValue * 100).rounded()), onBattery: !charging)
    }
}

final class PreferencesModel: ObservableObject {
    unowned let app: DivoomMenuBar

    @Published var deviceAddress: String = ""
    @Published var deviceName: String = ""

    @Published var presentationMode: DivoomMenuBar.PresentationMode {
        didSet {
            if presentationMode == .menuBarOnly && !showMenuBarItem {
                showMenuBarItem = true
            }
            app.presentationMode = presentationMode
            app.applyPresentationMode()
            app.applyMenuBarItemVisibility()
            app.rebuildMenu()
        }
    }

    @Published var showMenuBarItem: Bool {
        didSet {
            app.showsMenuBarItem = showMenuBarItem
            app.applyMenuBarItemVisibility()
        }
    }

    @Published var showBatteryStatus: Bool {
        didSet {
            UserDefaults.standard.set(showBatteryStatus, forKey: "ShowBatteryStatus")
            restartBatteryMonitorIfNeeded()
        }
    }

    @Published var useBatteryPrivateAPI: Bool {
        didSet {
            UserDefaults.standard.set(useBatteryPrivateAPI, forKey: "UseBatteryPrivateAPI")
            restartBatteryMonitorIfNeeded()
        }
    }

    @Published var automaticallyCheckForUpdates: Bool {
        didSet { app.updateController.automaticallyChecks = automaticallyCheckForUpdates }
    }

    init(app: DivoomMenuBar) {
        self.app = app
        self.presentationMode = app.presentationMode
        self.showMenuBarItem = app.showsMenuBarItem
        self.showBatteryStatus = UserDefaults.standard.bool(forKey: "ShowBatteryStatus")
        self.useBatteryPrivateAPI = UserDefaults.standard.bool(forKey: "UseBatteryPrivateAPI")
        self.automaticallyCheckForUpdates = app.updateController.automaticallyChecks
        self.deviceAddress = app.address
        self.deviceName = app.deviceName
    }

    func refreshDeviceInfo() {
        deviceAddress = app.address
        deviceName = app.deviceName
    }

    private func restartBatteryMonitorIfNeeded() {
        if showBatteryStatus {
            app.batteryMonitor.start(usePrivateAPI: useBatteryPrivateAPI)
        } else {
            app.batteryMonitor.stop()
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @ObservedObject var batteryMonitor: BatteryMonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Device").font(.subheadline).bold()
                if model.deviceAddress.isEmpty {
                    Text("Not set up yet").foregroundColor(.secondary)
                } else {
                    Text(model.deviceName.isEmpty ? "(unnamed device)" : model.deviceName)
                        .font(.body)
                    Text(model.deviceAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Button(model.deviceAddress.isEmpty ? "Set Up Device…" : "Change Device…") {
                    model.app.openDeviceSetup { model.refreshDeviceInfo() }
                }
                .padding(.top, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("App Behavior").font(.subheadline).bold()
                Picker("App Behavior", selection: $model.presentationMode) {
                    Text("Normal app + menu bar").tag(DivoomMenuBar.PresentationMode.normalApp)
                    Text("Mostly background menu bar app").tag(DivoomMenuBar.PresentationMode.menuBarOnly)
                }
                .pickerStyle(.radioGroup)
                Text(model.presentationMode.isNormalApp
                    ? "Shows in the Dock, opens Control Center on launch, and uses the standard macOS menu bar."
                    : "Keeps running from the menu bar and stays out of the Dock; windows remain available from its menu.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show MiniToo menu bar item", isOn: $model.showMenuBarItem)
                .disabled(model.presentationMode == .menuBarOnly)
            if model.presentationMode == .menuBarOnly {
                Text("The menu bar item stays on in this mode so the background app remains accessible.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show Battery Status", isOn: $model.showBatteryStatus)
                Text("No official battery command exists for this device — this reads it by watching macOS's own Bluetooth diagnostic logs, which keeps a background log-reading process running while enabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.showBatteryStatus {
                    Toggle("Use private CoreUtils API instead (experimental)", isOn: $model.useBatteryPrivateAPI)
                        .padding(.top, 4)
                    Text("Reads live from an undocumented system framework instead of parsing logs — faster updates, but unsupported by Apple and could break on a future macOS update with no warning.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let percent = batteryMonitor.percent {
                        Text("Current reading: \(percent)%\(batteryMonitor.isOnBattery ? "" : " (charging/full)")")
                            .font(.caption)
                    } else {
                        Text("Waiting for a reading…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("About & Updates").font(.subheadline).bold()
                Text("Version \(DivoomBuildInfo.displayVersion)")
                    .font(.caption)
                if let sourceURL = DivoomBuildInfo.sourceURL {
                    Link(DivoomBuildInfo.sourceRepository, destination: sourceURL)
                        .font(.caption)
                } else {
                    Text(DivoomBuildInfo.sourceRepository).font(.caption)
                }
                Text("Branch: \(DivoomBuildInfo.sourceBranch) · channel: \(DivoomBuildInfo.updateChannel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Automatically check for updates", isOn: $model.automaticallyCheckForUpdates)
                    .disabled(!model.app.updateController.isConfigured)
                if model.app.updateController.isConfigured {
                    Button("Check for Updates…") { model.app.checkForUpdatesMenu() }
                } else {
                    Text("Updates are not configured in this build yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

extension DivoomMenuBar {
    @objc func openPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = PreferencesModel(app: self)
        self.preferencesModel = model
        let hosting = NSHostingController(rootView: PreferencesView(model: model, batteryMonitor: batteryMonitor))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        preferencesWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

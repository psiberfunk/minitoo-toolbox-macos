import AppKit
import SwiftUI
import Foundation

/// First-run (and "Change Device…") flow for discovering and caching the
/// MiniToo's Bluetooth MAC address, replacing the old hardcoded constant.
/// Uses `blueutil --paired`/`--inquiry` (already a dependency of this app)
/// rather than adding a separate IOBluetooth device-inquiry bridge.
struct DiscoveredDevice: Identifiable, Equatable {
    let address: String
    let name: String
    let paired: Bool
    var id: String { address }

    var looksLikeDivoom: Bool {
        let lower = name.lowercased()
        return lower.contains("divoom") || lower.contains("minitoo") || lower.contains("pixoo")
    }
}

final class DeviceScanModel: ObservableObject {
    @Published var results: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var scanStatus = ""

    private unowned let app: DivoomMenuBar
    init(app: DivoomMenuBar) { self.app = app }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanStatus = "Scanning for nearby Bluetooth devices (about 8 seconds)…"
        DispatchQueue.global(qos: .userInitiated).async { [app] in
            guard let blueutil = app.executablePath("blueutil") else {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.scanStatus = "blueutil not found — install it with 'brew install blueutil'."
                }
                return
            }
            var found: [String: DiscoveredDevice] = [:]
            // Already-paired devices show up instantly; inquiry (slower,
            // ~8s) then adds anything nearby but not yet paired.
            let (_, pairedOut) = app.run(blueutil, ["--paired", "--format", "json"], wait: true)
            Self.merge(pairedOut, into: &found)
            let (_, inquiryOut) = app.run(blueutil, ["--inquiry", "8", "--format", "json"], wait: true)
            Self.merge(inquiryOut, into: &found)

            let sorted = found.values.sorted { a, b in
                if a.looksLikeDivoom != b.looksLikeDivoom { return a.looksLikeDivoom }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                self.results = sorted
                self.isScanning = false
                self.scanStatus = sorted.isEmpty
                    ? "No devices found. Make sure the MiniToo is powered on and not already connected to another phone or tablet, then try again."
                    : "Found \(sorted.count) device\(sorted.count == 1 ? "" : "s")."
            }
        }
    }

    private static func merge(_ jsonText: String, into found: inout [String: DiscoveredDevice]) {
        guard let data = jsonText.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for entry in array {
            guard let rawAddress = entry["address"] as? String else { continue }
            let address = normalize(rawAddress)
            let name = (entry["name"] as? String) ?? "(unnamed device)"
            let paired = (entry["paired"] as? Bool) ?? false
            // Prefer a paired=true record over an unpaired one for the same
            // address if both listings happened to return it.
            if let existing = found[address], existing.paired, !paired { continue }
            found[address] = DiscoveredDevice(address: address, name: name, paired: paired)
        }
    }

    /// blueutil/IOBluetooth accept multiple separator styles; normalize to
    /// the colon-uppercase form the rest of this app's tooling expects.
    static func normalize(_ raw: String) -> String {
        let hex = raw.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        guard hex.count == 12 else { return raw.uppercased() }
        var pairs: [String] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            pairs.append(String(hex[idx..<next]))
            idx = next
        }
        return pairs.joined(separator: ":")
    }
}

final class DeviceSetupModel: ObservableObject {
    @Published var manualAddress: String = ""
    @Published var isWorking = false
    @Published var statusText = ""

    unowned let app: DivoomMenuBar
    let scan: DeviceScanModel
    var onComplete: (() -> Void)?

    init(app: DivoomMenuBar) {
        self.app = app
        self.scan = DeviceScanModel(app: app)
    }

    func choose(_ device: DiscoveredDevice) {
        commit(address: device.address, alreadyPaired: device.paired)
    }

    func chooseManual() {
        let normalized = DeviceScanModel.normalize(manualAddress.trimmingCharacters(in: .whitespaces))
        guard normalized.count == 17 else {
            statusText = "That doesn't look like a valid MAC address (expected e.g. B1:21:81:6F:4D:F0)."
            return
        }
        commit(address: normalized, alreadyPaired: false)
    }

    private func commit(address: String, alreadyPaired: Bool) {
        isWorking = true
        statusText = alreadyPaired ? "Using already-paired device…" : "Pairing…"
        DispatchQueue.global(qos: .userInitiated).async { [app] in
            // Best-effort: already-paired devices no-op here; unpaired ones
            // either complete silently (SSP "just works") or surface
            // macOS's own native pairing prompt.
            if !alreadyPaired, let blueutil = app.executablePath("blueutil") {
                _ = app.run(blueutil, ["--pair", address], wait: true)
            }
            DispatchQueue.main.async {
                self.app.address = address
                self.isWorking = false
                self.statusText = "Device set to \(address)."
                self.onComplete?()
            }
        }
    }
}

struct DeviceSetupView: View {
    @ObservedObject var model: DeviceSetupModel
    @ObservedObject var scan: DeviceScanModel
    @State private var showManualEntry = false

    init(model: DeviceSetupModel) {
        self.model = model
        self.scan = model.scan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Your MiniToo")
                .font(.headline)
            Text("Make sure the speaker is powered on and not already connected to another phone or tablet, then scan for it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(scan.isScanning ? "Scanning…" : "Scan for Devices") {
                    scan.scan()
                }
                .disabled(scan.isScanning)
                if scan.isScanning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if !scan.scanStatus.isEmpty {
                Text(scan.scanStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !scan.results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(scan.results) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.body)
                                    Text(device.address)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if device.paired {
                                    Text("Paired")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Button("Use This Device") { model.choose(device) }
                                    .disabled(model.isWorking)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(height: 220)
            }

            DisclosureGroup("Advanced: enter MAC address manually", isExpanded: $showManualEntry) {
                HStack {
                    TextField("B1:21:81:6F:4D:F0", text: $model.manualAddress)
                        .textFieldStyle(.roundedBorder)
                    Button("Use This Address") { model.chooseManual() }
                        .disabled(model.isWorking || model.manualAddress.isEmpty)
                }
                .padding(.top, 4)
            }

            if !model.statusText.isEmpty {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { if scan.results.isEmpty { scan.scan() } }
    }
}

extension DivoomMenuBar {
    /// Shown automatically on first launch (no cached address yet), and
    /// reachable anytime afterward from Preferences ("Change Device…").
    func openDeviceSetup(onComplete: (() -> Void)? = nil) {
        if let window = deviceSetupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = DeviceSetupModel(app: self)
        model.onComplete = { [weak self] in
            self?.deviceSetupWindow?.close()
            onComplete?()
        }
        self.deviceSetupModel = model
        let hosting = NSHostingController(rootView: DeviceSetupView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up MiniToo"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        deviceSetupWindow = window
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.deviceSetupWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

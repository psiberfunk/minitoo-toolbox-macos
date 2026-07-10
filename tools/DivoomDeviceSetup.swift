import AppKit
import SwiftUI
import Foundation
import IOBluetooth

/// First-run (and "Change Device…") flow for discovering and caching the
/// MiniToo's Bluetooth MAC address, replacing the old hardcoded constant.
/// Uses public IOBluetooth inquiry and pairing APIs; no external CLI is needed.
struct DiscoveredDevice: Identifiable, Equatable {
    let address: String
    let name: String
    let paired: Bool
    let nearby: Bool
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
        guard DivoomBluetooth.isPoweredOn() else {
            results = []
            scanStatus = "Bluetooth is off. Turn Bluetooth on in System Settings, then scan again."
            return
        }
        isScanning = true
        results = []
        scanStatus = "Scanning for nearby Bluetooth devices (about 8 seconds)…"
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [String: DiscoveredDevice] = [:]
            // Keep the system pairing registry separate from actual nearby
            // inquiry results; old pairing records are not evidence a device
            // is currently visible over Bluetooth.
            for device in DivoomBluetooth.pairedDevices() {
                let address = Self.normalize(device.addressString)
                guard !address.isEmpty else { continue }
                found[address] = DiscoveredDevice(address: address, name: device.name ?? "Unknown device", paired: true, nearby: false)
            }
            for device in DivoomBluetooth.nearbyDevices(seconds: 8) {
                let address = Self.normalize(device.addressString)
                guard !address.isEmpty else { continue }
                found[address] = DiscoveredDevice(address: address, name: device.name ?? "Unknown device", paired: device.isPaired(), nearby: true)
            }

            let sorted = found.values.sorted { a, b in
                if a.looksLikeDivoom != b.looksLikeDivoom { return a.looksLikeDivoom }
                if a.nearby != b.nearby { return a.nearby }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                self.results = sorted
                self.isScanning = false
                let nearby = sorted.filter(\.nearby).count
                let saved = sorted.count - nearby
                self.scanStatus = nearby == 0
                    ? "No nearby devices found. \(saved) saved pairing\(saved == 1 ? "" : "s") shown below; power on the MiniToo and make sure it is not connected to another phone or tablet, then scan again."
                    : "Nearby scan finished: \(nearby) nearby device\(nearby == 1 ? "" : "s"), plus \(saved) saved pairing\(saved == 1 ? "" : "s")."
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
            found[address] = DiscoveredDevice(address: address, name: name, paired: paired, nearby: false)
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
        commit(address: device.address, name: device.name, alreadyPaired: device.paired)
    }

    func chooseManual() {
        let normalized = DeviceScanModel.normalize(manualAddress.trimmingCharacters(in: .whitespaces))
        guard normalized.count == 17 else {
            statusText = "That doesn't look like a valid MAC address (expected e.g. B1:21:81:6F:4D:F0)."
            return
        }
        commit(address: normalized, name: nil, alreadyPaired: false)
    }

    private func commit(address: String, name: String?, alreadyPaired: Bool) {
        isWorking = true
        statusText = alreadyPaired ? "Using already-paired device…" : "Pairing…"
        DispatchQueue.global(qos: .userInitiated).async {
            // Best-effort: already-paired devices no-op here; unpaired ones
            // either complete silently (SSP "just works") or surface
            // macOS's own native pairing prompt.
            if !alreadyPaired {
                _ = DivoomBluetooth.pair(address: address)
            }
            // Manual entry doesn't come with a name from the scan list —
            // look it up the same way the scan does rather than leaving it
            // blank.
            var resolvedName = name
            if resolvedName == nil {
                resolvedName = DivoomBluetooth.device(address: address)?.name
            }
            DispatchQueue.main.async {
                self.app.address = address
                self.app.deviceName = resolvedName ?? ""
                self.isWorking = false
                self.statusText = "Device set to \(resolvedName ?? address)."
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
                                if device.nearby {
                                    Text(device.paired ? "Nearby · Paired" : "Nearby")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else if device.paired {
                                    Text("Saved pairing")
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

import AppKit
import SwiftUI

private struct ControlCenterSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// Resizes the Control Center window to this view's actual rendered
    /// size instead of a hand-picked constant — one fewer magic number to
    /// keep in sync with whatever the content really needs, and it stays
    /// correct automatically if the content ever changes.
    func sizesControlCenterWindow(_ app: DivoomMenuBar) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: ControlCenterSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(ControlCenterSizeKey.self) { size in
            guard size.width > 1, size.height > 1 else { return }
            app.resizeControlCenterWindow(to: size)
        }
    }
}

/// Builds a preview via divoom_send.py --build-only before committing to a
/// multi-second chunked upload, instead of sending media blind.
final class ControlCenterModel: ObservableObject {
    unowned let app: DivoomMenuBar
    @Published var mediaURL: URL?
    @Published var previewImage: NSImage?
    @Published var summary: String = ""
    @Published var status: String = "Choose an image, GIF, or video to preview it before sending."
    @Published var isBusy: Bool = false
    @Published var fullScreen: Bool = false {
        didSet {
            guard let mediaURL else { return }
            buildPreview(for: mediaURL)
        }
    }
    private var packetsPath: URL?
    // Bumped on every buildPreview() call so a slower/earlier build that
    // finishes after a newer one (e.g. toggling Full Screen right after
    // picking a file, before the first build finishes) can't clobber the
    // packetsPath/previewImage pairing set by the build actually in flight.
    // Each generation also gets its own output subdirectory so two
    // concurrent builds of the same file (same stem) never race on writing
    // the same *-packets-lenpref.bin path — a real hazard once the frozen
    // PyInstaller helper's slower onefile startup widened the window in
    // which a second build can start before the first one finishes writing.
    private var buildGeneration = 0

    init(app: DivoomMenuBar) {
        self.app = app
    }

    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .image, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mediaURL = url
        buildPreview(for: url)
    }

    func buildPreview(for url: URL) {
        isBusy = true
        status = "Building preview…"
        previewImage = nil
        packetsPath = nil
        summary = ""
        let wantsFullScreen = fullScreen
        buildGeneration += 1
        let generation = buildGeneration
        let outDir = app.capturesDir.appendingPathComponent("send-\(generation)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var args = [url.path, "--build-only", "--out-dir", outDir.path]
            if wantsFullScreen { args.append("--full-screen") }
            let (code, out) = self.app.runPythonTool("send", scriptName: "divoom_send.py", arguments: args)
            DispatchQueue.main.async {
                guard generation == self.buildGeneration else { return }
                self.isBusy = false
                guard code == 0 else {
                    self.status = "Build failed: \(String(out.suffix(500)))"
                    return
                }
                var previewPath: String?
                for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(line)
                    if line.hasPrefix("preview=") {
                        previewPath = String(line.dropFirst("preview=".count))
                    } else if line.hasPrefix("packets=") {
                        // "packets=<path, possibly containing spaces> count=<n> bytes=<n>"
                        // Split from the trailing " count=" marker rather than on every
                        // space, since paths under ~/Library/Application Support/... do
                        // contain spaces themselves.
                        if let countRange = line.range(of: " count=") {
                            let path = line[line.index(line.startIndex, offsetBy: "packets=".count)..<countRange.lowerBound]
                            self.packetsPath = URL(fileURLWithPath: String(path))
                        }
                    } else if line.hasPrefix("kind=") {
                        self.summary = line
                    }
                }
                if let previewPath {
                    self.previewImage = NSImage(contentsOfFile: previewPath)
                }
                self.status = self.packetsPath != nil && self.previewImage != nil
                    ? "Preview ready — review it, then send."
                    : "Build finished but couldn't parse preview/packets paths."
            }
        }
    }

    func send() {
        guard let packetsPath else { return }
        guard app.isDaemonRunning() else {
            status = "Daemon not running — start it from the menu first."
            return
        }
        isBusy = true
        status = "Sending…"
        DivoomRawFrame.submit(packetsPath: packetsPath, port: UInt16(app.daemonPort) ?? 40583) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.status = result.contains("\"ok\":true") ? "Sent to device." : "Send issue: \(String(result.suffix(500)))"
            }
        }
    }
}

struct SendMediaView: View {
    @ObservedObject var model: ControlCenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send Image / GIF / Video").font(.headline)

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                    if let image = model.previewImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        Text("No preview yet").foregroundColor(.secondary).font(.callout)
                    }
                }
                .frame(width: 220, height: 220)

                VStack(alignment: .leading, spacing: 10) {
                    Button("Choose Media…") { model.chooseMedia() }
                    if let url = model.mediaURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Toggle("Full Screen (160×128)", isOn: $model.fullScreen)
                        .toggleStyle(.checkbox)
                        .disabled(model.isBusy)
                        .help("Use the panel's full rectangular resolution instead of a square center-crop.")
                    if !model.summary.isEmpty {
                        Text(model.summary).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Send to Device") { model.send() }
                        .disabled(model.previewImage == nil || model.isBusy)
                }
                .frame(width: 200, alignment: .leading)
            }

            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

/// Native builder/sender for WhiteNoise/Set, same raw-frame fast path as
/// brightness: talks straight to the daemon's TCP job socket so dragging a
/// volume slider feels responsive instead of shelling out to Python per drag.
final class WhiteNoiseModel: ObservableObject {
    unowned let app: DivoomMenuBar
    static let channelNames = ["fan", "frogs", "fire", "waves", "rain", "river", "birdsong", "singingbowls"]
    static let autoRefreshInterval: TimeInterval = 3

    @Published var isOn: Bool = false
    @Published var volumes: [Int] = Array(repeating: 0, count: WhiteNoiseModel.channelNames.count)
    @Published var status: String = "Off"
    @Published var isBusy: Bool = false
    @Published var autoRefreshEnabled: Bool = true
    var isEditingSlider: Bool = false
    private var autoRefreshTimer: Timer?

    init(app: DivoomMenuBar) {
        self.app = app
    }

    // Only runs while the White Noise screen is actually visible (started/
    // stopped from its onAppear/onDisappear) so a physical button press on
    // the device itself is still noticed without polling in the background
    // the rest of the time. Ticks are silent (see refresh(silent:)) so a
    // routine poll that finds nothing changed doesn't visibly flicker the
    // status line every few seconds.
    func startAutoRefresh() {
        stopAutoRefresh()
        guard autoRefreshEnabled else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isBusy, !self.isEditingSlider else { return }
            self.refresh(silent: true)
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        if enabled {
            refresh(silent: true)
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    // Both mutations re-fetch the device's actual current state first and
    // apply the one change on top of *that*, instead of the in-memory
    // `volumes`/`isOn` this model last knew about. Without this, editing one
    // channel after the device changed underneath us (official app, or a
    // prior app session) would silently clobber every other channel back to
    // whatever this model last happened to hold.
    func setOn(_ on: Bool) {
        refresh { [weak self] in
            guard let self else { return }
            self.isOn = on
            self.send()
        }
    }

    func sliderChanged(index: Int, value: Int) {
        refresh { [weak self] in
            guard let self else { return }
            self.volumes[index] = value
            self.send()
        }
    }

    /// Queries the device's actual current state via WhiteNoise/Get instead
    /// of assuming whatever this model last set — the device may have been
    /// changed by the official app, or still be playing from a prior app
    /// session that no longer has this model in memory.
    ///
    /// `silent`, used by the auto-refresh timer: applies the fetched state
    /// with no "Checking…" busy flicker and no status-text update on
    /// success, so a routine poll that finds nothing different is
    /// invisible. A real problem (bad reply) still surfaces in `status`
    /// either way, per "update quietly unless there's a problem".
    func refresh(silent: Bool = false, completion: (() -> Void)? = nil) {
        if !silent {
            isBusy = true
            status = "Checking device state…"
        }
        let job: [String: Any] = [
            "Command": "WhiteNoise/Get",
            "DeviceId": 600111083,
            "DevicePassword": 1777733348,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else {
            if !silent {
                isBusy = false
                status = "JSON encode error"
            }
            completion?()
            return
        }
        let packet = DivoomRawFrame.build(cmd: 0x01, body: body)
        let path = DivoomRawFrame.writePacketsFile(packet, name: "whitenoise-get", in: app.capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(app.daemonPort) ?? 40583, waitForReply: 1.5) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if !silent { self.isBusy = false }
                guard
                    let outerData = result.data(using: .utf8),
                    let outer = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any],
                    let replyText = outer["reply"] as? String,
                    let replyData = replyText.data(using: .utf8),
                    let state = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any]
                else {
                    self.status = "Couldn't read device state; showing last-known values."
                    completion?()
                    return
                }
                if let onOff = state["OnOff"] as? Int {
                    self.isOn = onOff != 0
                }
                if let volumeArray = state["Volume"] as? [Int], volumeArray.count == self.volumes.count {
                    self.volumes = volumeArray
                }
                if !silent {
                    self.status = self.isOn ? "Playing" : "Off"
                }
                completion?()
            }
        }
    }

    func send() {
        isBusy = true
        status = isOn ? "Updating…" : "Turning off…"
        let job: [String: Any] = [
            "Command": "WhiteNoise/Set",
            "OnOff": isOn ? 1 : 0,
            "Time": 0,
            "EndStatus": 0,
            "Volume": volumes,
            "DeviceId": 600111083,
            "DevicePassword": 1777733348,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else {
            isBusy = false
            status = "JSON encode error"
            return
        }
        let packet = DivoomRawFrame.build(cmd: 0x01, body: body)
        let path = DivoomRawFrame.writePacketsFile(packet, name: "whitenoise-set", in: app.capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(app.daemonPort) ?? 40583) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                let hardFailure = result.lowercased().contains("failed") || result.lowercased().contains("error") || result.isEmpty
                self.status = hardFailure ? "White noise issue: \(result)" : (self.isOn ? "Playing" : "Off")
            }
        }
    }
}

/// A small "this screen is live" indicator/control, replacing a manual
/// "Check Current State" button: since auto-refresh runs by default, a
/// clickable manual refresh is redundant most of the time -- this instead
/// lets the user turn the background polling off (or back on) if they'd
/// rather it not talk to the device every few seconds while the screen is
/// open. Shared between White Noise and Atmosphere, the two screens whose
/// on-device state can change from outside this app (official app, or a
/// physical button).
struct AutoRefreshToggle: View {
    @Binding var isOn: Bool
    var interval: TimeInterval

    var body: some View {
        Toggle(isOn: $isOn) {
            Label("Auto-refresh (\(Int(interval))s)", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Periodically re-check the device's actual state while this screen is open, so changes made elsewhere (the official app, a physical button) still show up here.")
    }
}

struct WhiteNoiseView: View {
    @ObservedObject var model: WhiteNoiseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { model.isOn }, set: { model.setOn($0) })) {
                Text("White Noise").font(.headline)
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(WhiteNoiseModel.channelNames.enumerated()), id: \.offset) { index, name in
                    HStack {
                        Text(name.capitalized)
                            .frame(width: 90, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { Double(model.volumes[index]) },
                                set: { model.volumes[index] = Int($0) }
                            ),
                            in: 0...100,
                            onEditingChanged: { editing in
                                model.isEditingSlider = editing
                                if !editing { model.sliderChanged(index: index, value: model.volumes[index]) }
                            }
                        )
                        .frame(width: 220)
                        Text("\(model.volumes[index])")
                            .frame(width: 32, alignment: .trailing)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundColor(.secondary)
                Spacer()
                AutoRefreshToggle(
                    isOn: Binding(get: { model.autoRefreshEnabled }, set: { model.setAutoRefreshEnabled($0) }),
                    interval: WhiteNoiseModel.autoRefreshInterval
                )
            }
        }
        .padding(20)
        .onAppear {
            model.refresh()
            model.startAutoRefresh()
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
    }
}

/// Fast stateless toggles (brightness, screen on/off) that don't need their
/// own drill-down screen — pinned to the top of every Control Center screen
/// instead, per the same reasoning that used to keep them in the menu bar.
/// Reuses DivoomMenuBar's existing native fast-path senders rather than
/// duplicating the frame-building logic a third time.
final class DeviceControlsModel: ObservableObject {
    unowned let app: DivoomMenuBar
    @Published var brightness: Double
    // No confirmed way to read either value back from the device (see
    // brightnessChanged doc below), so this only ever reflects what *this
    // app* last told the device, seeded from DivoomMenuBar's own last-known
    // value — same limitation the old menu-bar slider had.
    @Published var screenOn: Bool = true

    init(app: DivoomMenuBar) {
        self.app = app
        self.brightness = Double(app.lastBrightness)
    }

    // Dragging to 0 turns the screen off (mirrors how dim-to-black behaves
    // elsewhere), and raising it back up implicitly means the user wants the
    // screen back on — otherwise the slider would show e.g. 50% while the
    // screen stayed dark with no visible explanation.
    func brightnessChanged(_ value: Int) {
        if value == 0 {
            screenOn = false
            app.setScreen(on: false)
        } else if !screenOn {
            screenOn = true
            app.setScreen(on: true)
        }
        app.setBrightness(value)
    }

    func toggleScreen() {
        screenOn.toggle()
        app.setScreen(on: screenOn)
    }
}

struct DeviceControlsBar: View {
    @ObservedObject var model: DeviceControlsModel
    @ObservedObject var batteryMonitor: BatteryMonitorModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { model.toggleScreen() }) {
                Image(systemName: model.screenOn ? "power.circle.fill" : "power.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .foregroundColor(model.screenOn ? .accentColor : .secondary)
            .help(model.screenOn ? "Turn screen off" : "Turn screen on")

            Divider().frame(height: 16)

            Image(systemName: "sun.max.fill")
                .foregroundColor(.secondary)
                .help("Brightness")
            Slider(
                value: Binding(
                    get: { model.brightness },
                    set: { model.brightness = $0 }
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    if !editing { model.brightnessChanged(Int(model.brightness)) }
                }
            )
            .frame(width: 130)
            Text("\(Int(model.brightness))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .leading)

            // Only appears once "Show Battery Status" is enabled in
            // Preferences — there's no official battery command for this
            // device, so this is read via bluetoothd's own diagnostic logs
            // or a private framework (see DivoomPreferences.swift). Reserves
            // this slot as soon as monitoring is enabled, not only once a
            // reading actually arrives, so the window only resizes once.
            if batteryMonitor.isEnabled {
                Divider().frame(height: 16)
                HStack(spacing: 1) {
                    Image(systemName: BatteryMonitorModel.batteryIconName(percent: batteryMonitor.percent))
                    if batteryMonitor.percent != nil, !batteryMonitor.isOnBattery {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                    }
                }
                .foregroundColor(.secondary)
                .help("Device battery")
                Text(batteryMonitor.percent.map { "\($0)%" } ?? "…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Mirrors the native Divoom app's navigation: a home grid of function icons,
/// tap one to drill into its controls, then back out to pick another.
enum ControlCenterFunction: String, CaseIterable, Identifiable {
    case sendMedia
    case whiteNoise
    case customFaces
    case photoAlbum
    case atmosphere
    case deviceSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sendMedia: return "Send Media"
        case .whiteNoise: return "White Noise"
        case .customFaces: return "Custom Faces"
        case .photoAlbum: return "Photo Album"
        case .atmosphere: return "Atmosphere"
        case .deviceSettings: return "Device Settings"
        }
    }

    var icon: String {
        switch self {
        case .sendMedia: return "photo"
        case .whiteNoise: return "waveform"
        case .customFaces: return "square.stack.3d.up"
        case .photoAlbum: return "photo.stack"
        case .atmosphere: return "square.grid.3x3.fill"
        case .deviceSettings: return "gearshape"
        }
    }
}

/// Thin wrapper over DivoomMenuBar.activateClock, giving the Control Center
/// its own live busy/status feedback instead of only updating the shared
/// menu-bar status line.
final class CustomFacesModel: ObservableObject {
    unowned let app: DivoomMenuBar
    static let faces = [("custom1", "Custom Face 1"), ("custom2", "Custom Face 2"), ("custom3", "Custom Face 3")]

    @Published var status: String = "Choose a custom face to activate."
    @Published var isBusy: Bool = false

    init(app: DivoomMenuBar) {
        self.app = app
    }

    func activate(shortcut: String, label: String) {
        isBusy = true
        status = "Activating \(label)…"
        app.activateClock(shortcut) { [weak self] success, detail in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.status = success ? "Activated \(label)." : "Issue: \(detail)"
            }
        }
    }
}

struct CustomFacesView: View {
    @ObservedObject var model: CustomFacesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom Faces").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CustomFacesModel.faces, id: \.0) { shortcut, label in
                    Button(label) { model.activate(shortcut: shortcut, label: label) }
                        .disabled(model.isBusy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

/// Uploads a photo into the MiniToo's persistent, single flat photo
/// gallery -- architecturally distinct from Send Media's live/ephemeral
/// 0x8b push (nothing here survives without this: this data is stored on
/// the device itself and persists across reboots/disconnects). Talks to
/// tools/divoom_album.py, same subprocess-and-parse-stdout pattern as
/// ControlCenterModel.
final class PhotoAlbumModel: ObservableObject {
    unowned let app: DivoomMenuBar
    @Published var mediaURL: URL?
    @Published var previewImage: NSImage?
    @Published var summary: String = ""
    @Published var status: String = "Choose a photo to add it to the device's photo album."
    @Published var isBusy: Bool = false

    init(app: DivoomMenuBar) {
        self.app = app
    }

    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mediaURL = url
        buildPreview(for: url)
    }

    func buildPreview(for url: URL) {
        isBusy = true
        status = "Building preview…"
        previewImage = nil
        summary = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (code, out) = self.app.runPythonTool("album", scriptName: "divoom_album.py", arguments: ["--out-dir", self.app.capturesDir.path, "--build-only", "add-photo", url.path])
            DispatchQueue.main.async {
                self.isBusy = false
                guard code == 0 else {
                    self.status = "Build failed: \(String(out.suffix(500)))"
                    return
                }
                var previewPath: String?
                for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(line)
                    if line.hasPrefix("preview=") {
                        previewPath = String(line.dropFirst("preview=".count))
                    } else if line.hasPrefix("jpeg=") {
                        self.summary = line
                    }
                }
                if let previewPath {
                    self.previewImage = NSImage(contentsOfFile: previewPath)
                }
                self.status = self.previewImage != nil
                    ? "Preview ready — review it, then add to the album."
                    : "Build finished but couldn't parse the preview path."
            }
        }
    }

    func send() {
        guard let mediaURL else { return }
        guard app.isDaemonRunning() else {
            status = "Daemon not running — start it from the menu first."
            return
        }
        isBusy = true
        status = "Adding to photo album…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (code, out) = self.app.runPythonTool("album", scriptName: "divoom_album.py", arguments: ["--out-dir", self.app.capturesDir.path, "add-photo", mediaURL.path])
            DispatchQueue.main.async {
                self.isBusy = false
                self.status = code == 0 ? "Added to photo album." : "Issue: \(String(out.suffix(500)))"
            }
        }
    }
}

struct PhotoAlbumView: View {
    @ObservedObject var model: PhotoAlbumModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Photo Album").font(.headline)
            Text("Adds a photo to the device's own persistent photo gallery — it stays there across reboots, unlike Send Media's live preview.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15))
                    if let image = model.previewImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        Text("No preview yet").foregroundColor(.secondary).font(.callout)
                    }
                }
                .frame(width: 220, height: 176)

                VStack(alignment: .leading, spacing: 10) {
                    Button("Choose Photo…") { model.chooseMedia() }
                    if let url = model.mediaURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !model.summary.isEmpty {
                        Text(model.summary).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Add to Album") { model.send() }
                        .disabled(model.previewImage == nil || model.isBusy)
                }
                .frame(width: 200, alignment: .leading)
            }

            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(20)
    }
}

/// Native builder/sender for Lyric/Enter + Lyric/SetConfig -- the
/// Atmosphere screen's background/text-effect selector, decoded from a
/// real BT capture rather than APK tracing (see PROTOCOL.md's Atmosphere
/// section). Background is a 0-indexed slot in the app's ~21-entry grid;
/// TextEffect is a separate 0-5 selector for the "Text effects" row, whose
/// real on-device names (see textEffectNames below) start at index 0
/// "Mix", not "Off" -- the actual off state is index 5, "None".
final class AtmosphereModel: ObservableObject {
    unowned let app: DivoomMenuBar
    static let backgroundCount = 21
    static let textEffectCount = 6
    static let autoRefreshInterval: TimeInterval = 3
    // Real on-device names, per the user checking the official app's UI.
    static let textEffectNames = ["Mix", "Dissolve", "Push Up", "Push Left", "Rotate", "None"]
    // Real on-device names for each Background slot, per the user reading
    // them directly off the device. Index 20 ("Photo Album") confirms the
    // earlier guess that this slot is a "use your own photo" tile rather
    // than a generated visual; index 16 ("Black Hole") retroactively
    // explains why an earlier stardust icon draft looked like a vortex --
    // that wasn't a rendering bug, it was accidentally on-theme.
    static let backgroundNames = [
        "Pulsation", "Vitality", "Sound Wave Ring", "Rhythm", "Melody", "The Album", "Pink Space",
        "Bubbles", "Blue Sky", "Vinyl", "Starlight", "Night View", "Sunset", "Quicksand", "Gradient",
        "Geometry", "Black Hole", "Imagination", "Vaporware", "Sunrise", "Photo Album",
    ]

    @Published var selectedBackground: Int = 0
    @Published var selectedTextEffect: Int = 0
    @Published var status: String = "Choose a background."
    @Published var isBusy: Bool = false
    @Published var autoRefreshEnabled: Bool = true
    private var autoRefreshTimer: Timer?

    init(app: DivoomMenuBar) {
        self.app = app
    }

    // Only runs while the Atmosphere screen is actually visible (started/
    // stopped from its onAppear/onDisappear), same pattern as White Noise's
    // auto-refresh, so a change made from the official app or a physical
    // button is still noticed without polling in the background otherwise.
    // Ticks are silent (see refresh(silent:)) so a routine poll that finds
    // nothing changed doesn't visibly flicker the status line every few
    // seconds.
    func startAutoRefresh() {
        stopAutoRefresh()
        guard autoRefreshEnabled else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isBusy else { return }
            self.refresh(silent: true)
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        if enabled {
            refresh(silent: true)
            startAutoRefresh()
        } else {
            stopAutoRefresh()
        }
    }

    private func enterPacket() -> Data {
        let job: [String: Any] = [
            "Command": "Lyric/Enter",
            "DeviceId": 600111083,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        let body = (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
        return DivoomRawFrame.build(cmd: 0x01, body: body)
    }

    private func setConfigPacket(background: Int, textEffect: Int) -> Data {
        let job: [String: Any] = [
            "Background": background,
            "Command": "Lyric/SetConfig",
            "DeviceId": 600111083,
            "TextEffect": textEffect,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        let body = (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
        return DivoomRawFrame.build(cmd: 0x01, body: body)
    }

    private func getConfigPacket() -> Data {
        let job: [String: Any] = [
            "Command": "Lyric/GetConfig",
            "DeviceId": 600111083,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        let body = (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
        return DivoomRawFrame.build(cmd: 0x01, body: body)
    }

    // Lyric/GetConfig does get a real reply -- {"Command":"Lyric/GetConfig",
    // "Background":N,"TextEffect":N} -- confirmed via a fresh BT capture
    // read; an earlier pass mistakenly concluded there was no reply because
    // it only checked the same L2CAP CID the outgoing command used, not the
    // (different) CID the device's reply arrived on.
    //
    // `silent`, used by the auto-refresh timer: applies the fetched state
    // (moving the highlighted icon / dropdown selection if it actually
    // changed) with no "Checking…" busy flicker and no status-text update
    // on success, so a routine poll that finds nothing different is
    // invisible. A real problem still surfaces in `status` either way, per
    // "update quietly unless there's a problem".
    func refresh(silent: Bool = false) {
        if !silent {
            isBusy = true
            status = "Checking device state…"
        }
        let port = UInt16(app.daemonPort) ?? 40583
        let enterPath = DivoomRawFrame.writePacketsFile(enterPacket(), name: "atmosphere-enter", in: app.capturesDir)
        DivoomRawFrame.submit(packetsPath: enterPath, port: port) { [weak self] _ in
            guard let self else { return }
            let getPath = DivoomRawFrame.writePacketsFile(self.getConfigPacket(), name: "atmosphere-getconfig", in: self.app.capturesDir)
            DivoomRawFrame.submit(packetsPath: getPath, port: port, waitForReply: 1.5) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !silent { self.isBusy = false }
                    guard
                        let outerData = result.data(using: .utf8),
                        let outer = try? JSONSerialization.jsonObject(with: outerData) as? [String: Any],
                        let replyText = outer["reply"] as? String,
                        let replyData = replyText.data(using: .utf8),
                        let state = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any]
                    else {
                        self.status = "Couldn't read device state; showing last-known values."
                        return
                    }
                    if let background = state["Background"] as? Int {
                        self.selectedBackground = background
                    }
                    if let textEffect = state["TextEffect"] as? Int {
                        self.selectedTextEffect = textEffect
                    }
                    if !silent {
                        self.status = "\(Self.backgroundNames[self.selectedBackground]), effect \(Self.textEffectNames[self.selectedTextEffect])."
                    }
                }
            }
        }
    }

    func selectBackground(_ index: Int) {
        selectedBackground = index
        apply()
    }

    func selectTextEffect(_ index: Int) {
        selectedTextEffect = index
        apply()
    }

    // Sends Lyric/Enter, then Lyric/SetConfig, as two separate single-packet
    // jobs -- same as the official app's own capture. Bundling both frames
    // into one multi-packet job routes through the daemon's chunked
    // image/photo-transfer ACK-wait path, which plain JSON commands never
    // satisfy, so the daemon falsely reports failure even though every
    // packet was still actually sent.
    private func apply() {
        isBusy = true
        status = "Sending…"
        let port = UInt16(app.daemonPort) ?? 40583
        let enterPath = DivoomRawFrame.writePacketsFile(enterPacket(), name: "atmosphere-enter", in: app.capturesDir)
        DivoomRawFrame.submit(packetsPath: enterPath, port: port) { [weak self] enterResult in
            guard let self else { return }
            let setPacket = self.setConfigPacket(background: self.selectedBackground, textEffect: self.selectedTextEffect)
            let setPath = DivoomRawFrame.writePacketsFile(setPacket, name: "atmosphere-set", in: self.app.capturesDir)
            DivoomRawFrame.submit(packetsPath: setPath, port: port) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    let hardFailure = result.lowercased().contains("failed") || result.lowercased().contains("error") || result.isEmpty
                    let backgroundLabel = Self.backgroundNames[self.selectedBackground]
                    let effectLabel = Self.textEffectNames[self.selectedTextEffect]
                    self.status = hardFailure ? "Atmosphere issue: \(result)" : "\(backgroundLabel), effect \(effectLabel)."
                }
            }
        }
    }
}

struct AtmosphereView: View {
    @ObservedObject var model: AtmosphereModel
    // 7 columns x 3 rows -- more compact than a 3x7 grid at this tile size.
    private let backgroundColumns = Array(repeating: GridItem(.fixed(36), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Atmosphere").font(.headline)

            Text("Background").font(.subheadline)
            LazyVGrid(columns: backgroundColumns, spacing: 6) {
                ForEach(0..<AtmosphereModel.backgroundCount, id: \.self) { index in
                    Button(action: { model.selectBackground(index) }) {
                        VStack(spacing: 2) {
                            AtmosphereBackgroundIcon(index: index, size: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.accentColor, lineWidth: model.selectedBackground == index ? 2 : 0)
                                )
                            Text("\(index)").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .help(AtmosphereModel.backgroundNames[index])
                }
            }

            Text("Text Effect").font(.subheadline)
            Picker("", selection: Binding(
                get: { model.selectedTextEffect },
                set: { model.selectTextEffect($0) }
            )) {
                ForEach(0..<AtmosphereModel.textEffectCount, id: \.self) { index in
                    Text(AtmosphereModel.textEffectNames[index]).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            .disabled(model.isBusy)

            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundColor(.secondary)
                Spacer()
                AutoRefreshToggle(
                    isOn: Binding(get: { model.autoRefreshEnabled }, set: { model.setAutoRefreshEnabled($0) }),
                    interval: AtmosphereModel.autoRefreshInterval
                )
            }
        }
        .padding(20)
        .onAppear {
            model.refresh()
            model.startAutoRefresh()
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
    }
}

// Miscellaneous device settings that all share one JSON command,
// Sys/SetConf -- there's no per-setting opcode. Decoded from a real BT
// capture (see PROTOCOL.md's "Device Settings" section): the official app
// keeps one large local settings object and re-sends the *entire* thing
// every time any single field changes. This model mirrors that: BASELINE
// holds every field seen in the capture, and each setter overrides just
// the one field the user touched before resending the whole object --
// avoids clobbering fields this project doesn't understand (they read
// like settings for other Divoom product lines sharing this same
// command, same situation as the "screen dir cfg" opcode elsewhere in
// PROTOCOL.md).
//
// No Sys/GetConf was ever observed in the capture -- the app never reads
// the config back, it just trusts its own cached state -- so unlike White
// Noise/Atmosphere there is no live device read-back here, only the
// in-memory state this screen itself has sent.
final class DeviceSettingsModel: ObservableObject {
    unowned let app: DivoomMenuBar

    // Same placeholder DeviceId/DevicePassword/Token/UserId trio already
    // used by every other JSON command in this codebase (Custom Faces,
    // Atmosphere, White Noise, etc.) -- confirmed to work against this
    // device, not tied to any real Divoom account.
    static let baseline: [String: Any] = [
        "AutoPowerOff": 0, "BluetoothAutoConnect": 0, "ColorTemp": 0,
        "Command": "Sys/SetConf", "DateFormat": 0, "DeviceAutoUpdate": 1,
        "DeviceId": 600111083, "DevicePassword": 1777733348, "DisableMic": 0,
        "GyrateAngle": 0, "HighLight": 0, "Language": 0, "Latitude": 0.0,
        "LcdImageArray": ["", "", "", "", ""], "LocationCityId": 0,
        "LocationCityName": "", "LocationMode": 0, "LockScreenTime": 600,
        "Longitude": 0.0, "MirrorFlag": 0, "NotificationSound": 30,
        "OnOffVolume": 1, "ScreenProtection": 0, "ShowGrid1632": 1,
        "StartupFileId": "", "TemperatureMode": 0, "Time24Flag": 1,
        "TimeZoneMode": 0, "TimeZoneName": "", "TimeZoneValue": "",
        "Token": 1777741943, "UserId": 404779143, "WhiteBalanceB": 100,
        "WhiteBalanceG": 100, "WhiteBalanceR": 100, "Wind": 0,
    ]

    // Confirmed 2026-07-07 by cycling all six in order and reading the
    // on-device labels directly.
    static let dateFormatNames = ["yyyy-mm-dd", "dd-mm-yyyy", "mm-dd-yyyy", "yyyy.mm.dd", "dd.mm.yyyy", "mm.dd.yyyy"]
    // Confirmed 2026-07-07 by cycling all six in order; the minute values
    // are confirmed, on-screen labels for the non-zero entries weren't
    // read directly so these are just the minute counts.
    static let autoPowerOffMinutes = [0, 30, 60, 180, 360, 720]

    @Published var notificationSound: Double
    @Published var temperatureMode: Int
    @Published var dateFormat: Int
    @Published var time24: Int
    @Published var bluetoothAutoConnect: Int
    @Published var rememberPowerOnVolume: Int
    @Published var autoPowerOff: Int
    @Published var status: String = "Change a setting to send it to the device."
    @Published var isBusy: Bool = false

    // No device-side read-back exists for Sys/SetConf -- confirmed by both
    // BT captures (the official app never sends a Get) and direct testing
    // from this daemon (a plain write gets no reply, and a probing
    // "Sys/GetConf" also gets no reply). So this only remembers the last
    // value *this app* sent, in UserDefaults, and seeds the UI from that
    // on next launch -- it is NOT a live device readback, and can drift
    // from the device's true state if changed from the official app or the
    // device's own physical controls. The UI caption makes this explicit.
    private static let defaults = UserDefaults.standard
    private static func cacheKey(_ field: String) -> String { "DeviceSettings.\(field)" }

    private static func cachedInt(_ field: String, default def: Int) -> Int {
        let key = cacheKey(field)
        return defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : def
    }

    private func cache(_ field: String, _ value: Int) {
        Self.defaults.set(value, forKey: Self.cacheKey(field))
    }

    init(app: DivoomMenuBar) {
        self.app = app
        notificationSound = Double(Self.cachedInt("NotificationSound", default: 30))
        temperatureMode = Self.cachedInt("TemperatureMode", default: 0)
        dateFormat = Self.cachedInt("DateFormat", default: 0)
        time24 = Self.cachedInt("Time24Flag", default: 1)
        bluetoothAutoConnect = Self.cachedInt("BluetoothAutoConnect", default: 0)
        rememberPowerOnVolume = Self.cachedInt("OnOffVolume", default: 1)
        autoPowerOff = Self.cachedInt("AutoPowerOff", default: 0)
    }

    private func setConfPacket(overrides: [String: Any]) -> Data {
        var job = Self.baseline
        for (k, v) in overrides { job[k] = v }
        let body = (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
        return DivoomRawFrame.build(cmd: 0x01, body: body)
    }

    private func send(_ overrides: [String: Any], statusOnSuccess: String) {
        isBusy = true
        status = "Sending…"
        let port = UInt16(app.daemonPort) ?? 40583
        let path = DivoomRawFrame.writePacketsFile(setConfPacket(overrides: overrides), name: "device-settings-setconf", in: app.capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: port) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                let hardFailure = result.lowercased().contains("failed") || result.lowercased().contains("error") || result.isEmpty
                self.status = hardFailure ? "Device settings issue: \(result)" : statusOnSuccess
            }
        }
    }

    func setNotificationSound(_ level: Int) {
        notificationSound = Double(level)
        cache("NotificationSound", level)
        send(["NotificationSound": level], statusOnSuccess: "Notification sound: \(level).")
    }

    // Confirmed by direct on-device observation: 0=Celsius, 1=Fahrenheit.
    func setTemperatureMode(_ mode: Int) {
        temperatureMode = mode
        cache("TemperatureMode", mode)
        send(["TemperatureMode": mode], statusOnSuccess: "Temperature unit: \(mode == 0 ? "Celsius" : "Fahrenheit").")
    }

    // Confirmed by a real capture cycling all 6 values in order and
    // reading the on-device labels.
    func setDateFormat(_ format: Int) {
        dateFormat = format
        cache("DateFormat", format)
        send(["DateFormat": format], statusOnSuccess: "Date format: \(Self.dateFormatNames[format]).")
    }

    // Confirmed by direct hardware testing (2026-07-07): 1=24-hour,
    // 0=12-hour, matching the field name.
    func setTime24(_ value: Int) {
        time24 = value
        cache("Time24Flag", value)
        send(["Time24Flag": value], statusOnSuccess: "Clock format: \(value == 1 ? "24-hour" : "12-hour").")
    }

    // Confirmed by a real capture: 0->1->0 while toggling "Bluetooth Audio
    // Reconnect" in the app. 1=enabled.
    func setBluetoothAutoConnect(_ value: Int) {
        bluetoothAutoConnect = value
        cache("BluetoothAutoConnect", value)
        send(["BluetoothAutoConnect": value], statusOnSuccess: "Bluetooth auto-reconnect: \(value == 1 ? "on" : "off").")
    }

    // Confirmed by a real capture: 1->0->1 while toggling "Remember
    // power-on volume" in the app (OnOffVolume field). 1=enabled.
    func setRememberPowerOnVolume(_ value: Int) {
        rememberPowerOnVolume = value
        cache("OnOffVolume", value)
        send(["OnOffVolume": value], statusOnSuccess: "Remember power-on volume: \(value == 1 ? "on" : "off").")
    }

    // Confirmed by a real capture cycling all 6 values in order
    // (0/30/60/180/360/720 minutes).
    func setAutoPowerOff(_ minutes: Int) {
        autoPowerOff = minutes
        cache("AutoPowerOff", minutes)
        send(["AutoPowerOff": minutes], statusOnSuccess: minutes == 0 ? "Auto power off: never." : "Auto power off: \(minutes) min.")
    }
}

/// One label+control row, sized to its content instead of a fixed frame --
/// keeps the label column tight regardless of a control's natural width.
private struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer(minLength: 12)
            content
        }
    }
}

struct DeviceSettingsView: View {
    @ObservedObject var model: DeviceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Device Settings").font(.headline)
                // Device-side note (not a bug in this app): after any of
                // these settings changes, the MiniToo's own on-screen menu
                // can show stale text until you back out and re-enter that
                // menu on the device -- confirmed hardware-tested
                // 2026-07-07, the setting itself does take effect
                // immediately, only the device's own menu redraw lags. Also
                // no live device read-back exists, so values below are only
                // ever "last one this app sent". See README.md
                // Troubleshooting.
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.secondary)
                    .help("Device menus may show stale text after a change until you back out and re-enter them on the device -- the setting itself still applies immediately. Values below are the last ones set from this app, not a live read of the device -- there's no way to query current device state for these settings.")
            }

            SettingRow(label: "Notification Sound") {
                Slider(
                    value: Binding(
                        get: { model.notificationSound },
                        set: { model.notificationSound = $0 }
                    ),
                    in: 0...100,
                    onEditingChanged: { editing in
                        if !editing { model.setNotificationSound(Int(model.notificationSound)) }
                    }
                )
                .frame(width: 140)
                .disabled(model.isBusy)
                Text("\(Int(model.notificationSound))").font(.caption).foregroundColor(.secondary).frame(width: 24, alignment: .trailing)
            }

            SettingRow(label: "Temperature Unit") {
                Picker("", selection: Binding(
                    get: { model.temperatureMode },
                    set: { model.setTemperatureMode($0) }
                )) {
                    Text("Celsius").tag(0)
                    Text("Fahrenheit").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            SettingRow(label: "Date Format") {
                Picker("", selection: Binding(
                    get: { model.dateFormat },
                    set: { model.setDateFormat($0) }
                )) {
                    ForEach(0..<DeviceSettingsModel.dateFormatNames.count, id: \.self) { index in
                        Text(DeviceSettingsModel.dateFormatNames[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            SettingRow(label: "Clock Format") {
                Picker("", selection: Binding(
                    get: { model.time24 },
                    set: { model.setTime24($0) }
                )) {
                    Text("12-hour").tag(0)
                    Text("24-hour").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            SettingRow(label: "Bluetooth Auto-Reconnect") {
                Toggle("", isOn: Binding(
                    get: { model.bluetoothAutoConnect == 1 },
                    set: { model.setBluetoothAutoConnect($0 ? 1 : 0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            SettingRow(label: "Remember Power-On Volume") {
                Toggle("", isOn: Binding(
                    get: { model.rememberPowerOnVolume == 1 },
                    set: { model.setRememberPowerOnVolume($0 ? 1 : 0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            SettingRow(label: "Auto Power Off") {
                Picker("", selection: Binding(
                    get: { model.autoPowerOff },
                    set: { model.setAutoPowerOff($0) }
                )) {
                    ForEach(DeviceSettingsModel.autoPowerOffMinutes, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .labelsHidden()
                .disabled(model.isBusy)
            }

            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
    }
}

struct ControlCenterView: View {
    @ObservedObject var sendModel: ControlCenterModel
    @ObservedObject var whiteNoiseModel: WhiteNoiseModel
    @ObservedObject var customFacesModel: CustomFacesModel
    @ObservedObject var deviceControlsModel: DeviceControlsModel
    @ObservedObject var batteryMonitor: BatteryMonitorModel
    @ObservedObject var photoAlbumModel: PhotoAlbumModel
    @ObservedObject var atmosphereModel: AtmosphereModel
    @ObservedObject var deviceSettingsModel: DeviceSettingsModel
    @State private var selection: ControlCenterFunction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeviceControlsBar(model: deviceControlsModel, batteryMonitor: batteryMonitor)
            Divider()
            Group {
                if let selection {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(action: { self.selection = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Functions")
                            }
                            // Padding goes *inside* the content shape so the
                            // clickable area is bigger than the glyphs
                            // themselves, not just their tight bounding box.
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .padding([.top, .horizontal], 8)

                        // fixedSize forces this screen to report its own
                        // true intrinsic width instead of greedily
                        // accepting whatever width the *previous* screen
                        // left the window at -- without it, a narrower
                        // screen opened right after a wider one (e.g.
                        // Device Settings after the icon grid) gets stuck
                        // at the old wider size, since a plain
                        // maxWidth:.infinity child just fills whatever's
                        // already proposed rather than reporting what it
                        // actually needs.
                        detailView(for: selection)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    functionGrid
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        // Measured once here, over the whole window's actual content (the
        // device-controls bar plus whichever screen is showing) — a single
        // source of truth instead of every screen resizing the window to
        // just its own subtree and silently omitting this bar's height.
        // Without this, every status label change still re-centers the
        // *whole* screen if it's only as wide as its widest child — see the
        // per-screen frame(alignment: .topLeading) calls above.
        .sizesControlCenterWindow(sendModel.app)
    }

    private var functionGrid: some View {
        HStack(spacing: 20) {
            ForEach(ControlCenterFunction.allCases) { function in
                Button(action: { selection = function }) {
                    VStack(spacing: 8) {
                        Image(systemName: function.icon)
                            .font(.system(size: 32))
                            .frame(width: 64, height: 64)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.12)))
                        Text(function.title).font(.callout)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func detailView(for function: ControlCenterFunction) -> some View {
        switch function {
        case .sendMedia: SendMediaView(model: sendModel)
        case .whiteNoise: WhiteNoiseView(model: whiteNoiseModel)
        case .customFaces: CustomFacesView(model: customFacesModel)
        case .photoAlbum: PhotoAlbumView(model: photoAlbumModel)
        case .atmosphere: AtmosphereView(model: atmosphereModel)
        case .deviceSettings: DeviceSettingsView(model: deviceSettingsModel)
        }
    }
}

extension DivoomMenuBar {
    @objc func openControlCenter() {
        var isNewWindow = false
        if controlCenterWindow == nil {
            isNewWindow = true
            let sendModel = ControlCenterModel(app: self)
            controlCenterModel = sendModel
            let whiteNoiseModel = WhiteNoiseModel(app: self)
            self.whiteNoiseModel = whiteNoiseModel
            let customFacesModel = CustomFacesModel(app: self)
            self.customFacesModel = customFacesModel
            let deviceControlsModel = DeviceControlsModel(app: self)
            self.deviceControlsModel = deviceControlsModel
            let photoAlbumModel = PhotoAlbumModel(app: self)
            self.photoAlbumModel = photoAlbumModel
            let atmosphereModel = AtmosphereModel(app: self)
            self.atmosphereModel = atmosphereModel
            let deviceSettingsModel = DeviceSettingsModel(app: self)
            self.deviceSettingsModel = deviceSettingsModel
            let hosting = NSHostingController(rootView: ControlCenterView(sendModel: sendModel, whiteNoiseModel: whiteNoiseModel, customFacesModel: customFacesModel, deviceControlsModel: deviceControlsModel, batteryMonitor: batteryMonitor, photoAlbumModel: photoAlbumModel, atmosphereModel: atmosphereModel, deviceSettingsModel: deviceSettingsModel))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Divoom Control Center"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Wide/tall enough that the title text and traffic-light buttons
            // never feel cramped, even when showing the small icon grid.
            window.contentMinSize = NSSize(width: 320, height: 150)
            controlCenterWindow = window
            // SwiftUI's onDisappear doesn't fire just from closing this window
            // (isReleasedWhenClosed=false keeps the view alive so the window
            // can be reused) — without this, closing the window while White
            // Noise's auto-refresh is running leaves it polling forever.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.whiteNoiseModel?.stopAutoRefresh()
                self?.atmosphereModel?.stopAutoRefresh()
            }
        }
        if isNewWindow {
            // Starts at the window's minimum size — comfortably wide enough
            // that the icon grid's very first layout pass doesn't truncate
            // any labels — and the size-reporting content immediately
            // corrects it to the icon grid's actual measured size a moment
            // later.
            controlCenterWindow?.setContentSize(controlCenterWindow?.contentMinSize ?? NSSize(width: 320, height: 150))
            controlCenterWindow?.center()
        }
        controlCenterWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Each screen (function grid vs. a drilled-into detail view) declares its
    // own natural size via onAppear, instead of the window being one fixed
    // size regardless of which screen is showing. Keeps the top-left corner
    // anchored while resizing, matching the rest of macOS's window behavior.
    func resizeControlCenterWindow(to contentSize: NSSize) {
        guard let window = controlCenterWindow else { return }
        let clamped = NSSize(
            width: max(contentSize.width, window.contentMinSize.width),
            height: max(contentSize.height, window.contentMinSize.height)
        )
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: clamped))
        var frame = window.frame
        frame.origin.y += frame.size.height - newFrame.size.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: true)
    }
}

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let py = self.app.pythonExecutable()
            let script = self.app.toolRoot.appendingPathComponent("divoom_send.py").path
            var args = [script, url.path, "--build-only", "--out-dir", self.app.capturesDir.path]
            if wantsFullScreen { args.append("--full-screen") }
            let (code, out) = self.app.run(py, args)
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
        guard let mediaURL else { return }
        guard app.isDaemonRunning() else {
            status = "Daemon not running — start it from the menu first."
            return
        }
        isBusy = true
        status = "Sending…"
        let wantsFullScreen = fullScreen
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // The preview build already ran once for display; re-running the
            // full pipeline here (instead of resubmitting the earlier packets
            // file) keeps this feature self-contained without depending on
            // the daemon's native TCP-submit helper, at the cost of
            // re-encoding — cheap relative to the multi-second BT transfer.
            let py = self.app.pythonExecutable()
            let script = self.app.toolRoot.appendingPathComponent("divoom_send.py").path
            var args = [script, mediaURL.path, "--out-dir", self.app.capturesDir.path]
            if wantsFullScreen { args.append("--full-screen") }
            let (code, out) = self.app.run(py, args)
            DispatchQueue.main.async {
                self.isBusy = false
                self.status = code == 0 ? "Sent to device." : "Send issue: \(String(out.suffix(500)))"
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

    @Published var isOn: Bool = false
    @Published var volumes: [Int] = Array(repeating: 0, count: WhiteNoiseModel.channelNames.count)
    @Published var status: String = "Off"
    @Published var isBusy: Bool = false
    var isEditingSlider: Bool = false
    private var autoRefreshTimer: Timer?

    init(app: DivoomMenuBar) {
        self.app = app
    }

    // Only runs while the White Noise screen is actually visible (started/
    // stopped from its onAppear/onDisappear) so a physical button press on
    // the device itself is still noticed without polling in the background
    // the rest of the time.
    func startAutoRefresh() {
        stopAutoRefresh()
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, !self.isBusy, !self.isEditingSlider else { return }
            self.refresh()
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
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
    /// session that no longer has this model in memory. Also called on its
    /// own from a manual "Refresh" button, since there's no push/polling —
    /// the UI only reflects the device's state as of the last query.
    func refresh(completion: (() -> Void)? = nil) {
        isBusy = true
        status = "Checking device state…"
        let job: [String: Any] = [
            "Command": "WhiteNoise/Get",
            "DeviceId": 600111083,
            "DevicePassword": 1777733348,
            "Token": 1777741943,
            "UserId": 404779143,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: job) else {
            isBusy = false
            status = "JSON encode error"
            completion?()
            return
        }
        let packet = DivoomRawFrame.build(cmd: 0x01, body: body)
        let path = DivoomRawFrame.writePacketsFile(packet, name: "whitenoise-get", in: app.capturesDir)
        DivoomRawFrame.submit(packetsPath: path, port: UInt16(app.daemonPort) ?? 40583, waitForReply: 1.5) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
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
                self.status = self.isOn ? "Playing" : "Off"
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

struct WhiteNoiseView: View {
    @ObservedObject var model: WhiteNoiseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle(isOn: Binding(get: { model.isOn }, set: { model.setOn($0) })) {
                    Text("White Noise").font(.headline)
                }
                .toggleStyle(.switch)
                Spacer()
                Button(action: { model.refresh() }) {
                    Label("Check Current State", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(model.isBusy)
                .help("Re-check the device's actual current state — this screen doesn't update live if something else changes it.")
            }

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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sendMedia: return "Send Media"
        case .whiteNoise: return "White Noise"
        case .customFaces: return "Custom Faces"
        case .photoAlbum: return "Photo Album"
        case .atmosphere: return "Atmosphere"
        }
    }

    var icon: String {
        switch self {
        case .sendMedia: return "photo"
        case .whiteNoise: return "waveform"
        case .customFaces: return "square.stack.3d.up"
        case .photoAlbum: return "photo.stack"
        case .atmosphere: return "square.grid.3x3.fill"
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
            let py = self.app.pythonExecutable()
            let script = self.app.toolRoot.appendingPathComponent("divoom_album.py").path
            let (code, out) = self.app.run(py, [script, "--out-dir", self.app.capturesDir.path, "--build-only", "add-photo", url.path])
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
            let py = self.app.pythonExecutable()
            let script = self.app.toolRoot.appendingPathComponent("divoom_album.py").path
            let (code, out) = self.app.run(py, [script, "--out-dir", self.app.capturesDir.path, "add-photo", mediaURL.path])
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
/// names (per the user cross-checking the real app's UI) are, in order:
/// Mixing, Fade Out, Fly Up, Fly Out to Left, Rotation, No Effect -- note
/// index 0 is "Mixing", not "Off"; the actual off state is index 5.
final class AtmosphereModel: ObservableObject {
    unowned let app: DivoomMenuBar
    static let backgroundCount = 21
    static let textEffectCount = 6
    static let textEffectNames = ["Mixing", "Fade Out", "Fly Up", "Fly Out to Left", "Rotation", "No Effect"]

    @Published var selectedBackground: Int = 0
    @Published var selectedTextEffect: Int = 0
    @Published var status: String = "Choose a background."
    @Published var isBusy: Bool = false

    init(app: DivoomMenuBar) {
        self.app = app
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
                    let effectLabel = Self.textEffectNames[self.selectedTextEffect]
                    self.status = hardFailure ? "Atmosphere issue: \(result)" : "Background \(self.selectedBackground), effect \(effectLabel)."
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

                        detailView(for: selection)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    functionGrid
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
            let hosting = NSHostingController(rootView: ControlCenterView(sendModel: sendModel, whiteNoiseModel: whiteNoiseModel, customFacesModel: customFacesModel, deviceControlsModel: deviceControlsModel, batteryMonitor: batteryMonitor, photoAlbumModel: photoAlbumModel, atmosphereModel: atmosphereModel))
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

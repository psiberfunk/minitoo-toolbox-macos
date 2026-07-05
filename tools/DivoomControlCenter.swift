import AppKit
import SwiftUI

/// Builds a preview via divoom_send.py --build-only before committing to a
/// multi-second chunked upload, instead of sending media blind.
final class ControlCenterModel: ObservableObject {
    unowned let app: DivoomMenuBar
    @Published var mediaURL: URL?
    @Published var previewImage: NSImage?
    @Published var summary: String = ""
    @Published var status: String = "Choose an image, GIF, or video to preview it before sending."
    @Published var isBusy: Bool = false
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let py = self.app.pythonExecutable()
            let script = self.app.toolRoot.appendingPathComponent("divoom_send.py").path
            let (code, out) = self.app.run(py, [script, url.path, "--build-only", "--out-dir", self.app.capturesDir.path])
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // The preview build already ran once for display; re-running the
            // full pipeline here (instead of resubmitting the earlier packets
            // file) keeps this feature self-contained without depending on
            // the daemon's native TCP-submit helper, at the cost of
            // re-encoding — cheap relative to the multi-second BT transfer.
            let py = self.app.pythonExecutable()
            let script = self.app.toolRoot.appendingPathComponent("divoom_send.py").path
            let (code, out) = self.app.run(py, [script, mediaURL.path, "--out-dir", self.app.capturesDir.path])
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
        .onAppear { model.app.resizeControlCenterWindow(to: NSSize(width: 480, height: 300)) }
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

    init(app: DivoomMenuBar) {
        self.app = app
    }

    func setOn(_ on: Bool) {
        isOn = on
        send()
    }

    func sliderChanged(index: Int, value: Int) {
        volumes[index] = value
        send()
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
        .onAppear { model.app.resizeControlCenterWindow(to: NSSize(width: 420, height: 400)) }
    }
}

/// Mirrors the native Divoom app's navigation: a home grid of function icons,
/// tap one to drill into its controls, then back out to pick another.
enum ControlCenterFunction: String, CaseIterable, Identifiable {
    case sendMedia
    case whiteNoise
    case customFaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sendMedia: return "Send Media"
        case .whiteNoise: return "White Noise"
        case .customFaces: return "Custom Faces"
        }
    }

    var icon: String {
        switch self {
        case .sendMedia: return "photo"
        case .whiteNoise: return "waveform"
        case .customFaces: return "square.stack.3d.up"
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
        .onAppear { model.app.resizeControlCenterWindow(to: NSSize(width: 320, height: 220)) }
    }
}

struct ControlCenterView: View {
    @ObservedObject var sendModel: ControlCenterModel
    @ObservedObject var whiteNoiseModel: WhiteNoiseModel
    @ObservedObject var customFacesModel: CustomFacesModel
    @State private var selection: ControlCenterFunction?

    var body: some View {
        Group {
            if let selection {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: { self.selection = nil }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Functions")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .padding([.top, .horizontal], 14)

                    detailView(for: selection)
                }
            } else {
                functionGrid
                    .onAppear { sendModel.app.resizeControlCenterWindow(to: NSSize(width: 360, height: 160)) }
            }
        }
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
            let hosting = NSHostingController(rootView: ControlCenterView(sendModel: sendModel, whiteNoiseModel: whiteNoiseModel, customFacesModel: customFacesModel))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Divoom Control Center"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Wide/tall enough that the title text and traffic-light buttons
            // never feel cramped, even when showing the small icon grid.
            window.contentMinSize = NSSize(width: 320, height: 150)
            controlCenterWindow = window
        }
        if isNewWindow {
            controlCenterWindow?.setContentSize(NSSize(width: 280, height: 160))
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

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

struct ControlCenterView: View {
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
        .frame(width: 480, height: 300)
    }
}

extension DivoomMenuBar {
    @objc func openControlCenter() {
        if controlCenterWindow == nil {
            let model = ControlCenterModel(app: self)
            controlCenterModel = model
            let hosting = NSHostingController(rootView: ControlCenterView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Divoom Control Center"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            controlCenterWindow = window
        }
        controlCenterWindow?.center()
        controlCenterWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

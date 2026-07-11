import AppKit
import Foundation
import Sparkle

/// Owns Sparkle configuration for the channel embedded in this particular app
/// build.  There is intentionally no generic GitHub "latest" lookup here:
/// the build's feed URL and Sparkle channel are the update trust boundary.
final class DivoomUpdateController: NSObject, SPUUpdaterDelegate {
    static let automaticChecksKey = "AutomaticallyCheckForUpdates"
    static let consentPresentedKey = "UpdateConsentPresented"

    private lazy var standardController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private(set) var didStart = false
    private var clearQuarantineOnRelaunch = false
    var isConfigured: Bool { DivoomBuildInfo.isUpdateConfigured }
    var automaticallyChecks: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.automaticChecksKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.automaticChecksKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.automaticChecksKey)
            guard didStart else { return }
            standardController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func startAfterConsentIfNeeded(status: @escaping (String) -> Void) {
        guard isConfigured else {
            status("Updates are not configured in this build")
            return
        }

        if UserDefaults.standard.bool(forKey: Self.consentPresentedKey) {
            start(status: status)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Keep Divoom MiniToo up to date?"
        alert.informativeText = "This app checks only the \(DivoomBuildInfo.updateChannel) channel from \(DivoomBuildInfo.sourceRepository). You can change this later in Preferences."
        alert.addButton(withTitle: "Enable Automatic Updates")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        automaticallyChecks = response == .alertFirstButtonReturn
        UserDefaults.standard.set(true, forKey: Self.consentPresentedKey)
        start(status: status)
    }

    func checkForUpdates(status: @escaping (String) -> Void) {
        guard isConfigured else {
            status("Updates are not configured in this build")
            return
        }
        if !didStart { start(status: status) }
        guard standardController.updater.canCheckForUpdates else {
            status("An update check is already in progress")
            return
        }
        standardController.updater.checkForUpdates()
    }

    private func start(status: @escaping (String) -> Void) {
        guard !didStart else { return }
        do {
            try standardController.updater.start()
            standardController.updater.automaticallyChecksForUpdates = automaticallyChecks
            // Until releases are Developer ID signed/notarized, always make
            // installation a visible user choice.  The explicit quarantine
            // option is added at the install/relaunch step, never silently.
            standardController.updater.automaticallyDownloadsUpdates = false
            didStart = true
            status(automaticallyChecks ? "Automatic updates enabled" : "Automatic updates disabled")
        } catch {
            status("Update setup issue: \(error.localizedDescription)")
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        DivoomBuildInfo.updateFeedURL
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [DivoomBuildInfo.updateChannel]
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .install else { return }

        // This supplementary confirmation is only for the temporary ad-hoc
        // release period. Sparkle still verifies the feed and archive before
        // it gets as far as installing/relaunching anything.
        let alert = NSAlert()
        alert.messageText = "Prepare \(updateItem.displayVersionString) for relaunch"
        alert.informativeText = "This verified \(DivoomBuildInfo.updateChannel) update is not yet notarized by Apple. macOS may otherwise show another Gatekeeper warning after restart."
        let checkbox = NSButton(checkboxWithTitle: "Remove macOS download quarantine from this verified update", target: nil, action: nil)
        checkbox.state = .on
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Continue Without This")
        let response = alert.runModal()
        clearQuarantineOnRelaunch = response == .alertFirstButtonReturn && checkbox.state == .on
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        guard clearQuarantineOnRelaunch else { return }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension == "app" else { return }

        // Scope the explicit user-approved operation to this just-installed
        // application bundle. Arguments are passed directly to Process, not
        // through a shell string.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", bundleURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Sparkle still performs the update/relaunch. The user can use
            // normal Gatekeeper approval if this optional bridge fails.
            NSLog("Divoom update quarantine-removal helper failed: %@", error.localizedDescription)
        }
    }
}

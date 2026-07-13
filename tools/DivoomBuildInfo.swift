import Foundation

/// Build provenance is embedded by tools/build-divoom-app.sh rather than
/// inferred from the machine running the app.  This keeps an installed app
/// locked to the repository/channel it was actually built from.
struct DivoomBuildInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static let version = info["CFBundleShortVersionString"] as? String ?? "development"
    static let build = info["CFBundleVersion"] as? String ?? "local"
    static let sourceRepository = info["DivoomSourceRepository"] as? String ?? "local build"
    static let sourceBranch = info["DivoomSourceBranch"] as? String ?? "local"
    static let updateChannel = info["DivoomUpdateChannel"] as? String ?? sourceBranch
    static let updateFeedURL = info["DivoomUpdateFeedURL"] as? String ?? ""
    static let sparklePublicKey = info["SUPublicEDKey"] as? String ?? ""
    static let commit = info["DivoomBuildCommit"] as? String ?? "local"
    static let buildRun = info["DivoomBuildRun"] as? String ?? build

    /// The About panel and Preferences deliberately share this exact label,
    /// so an installed build has one unambiguous version/build/commit
    /// identity everywhere it is shown.
    static var buildDescription: String {
        if buildRun.hasPrefix("local-") {
            return "local build \(buildRun.dropFirst("local-".count))"
        }
        return "build \(buildRun)"
    }

    static var displayVersion: String {
        "\(version) (\(buildDescription) · \(commit))"
    }

    static var sourceURL: URL? {
        URL(string: "https://github.com/\(sourceRepository)")
    }

    static var isUpdateConfigured: Bool {
        guard let url = URL(string: updateFeedURL) else { return false }
        return url.scheme == "https" && !updateChannel.isEmpty && !sourceRepository.isEmpty && !sparklePublicKey.isEmpty
    }
}

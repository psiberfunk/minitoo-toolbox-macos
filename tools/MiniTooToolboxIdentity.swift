import Foundation

/// Product identity and one-time migration from the former Divoom MiniToo app.
/// Device/protocol names intentionally remain Divoom-specific elsewhere.
enum MiniTooToolboxIdentity {
    static let legacyBundleIdentifier = "local.divoom.minitoo"
    static let supportDirectoryName = "MiniTooToolbox"
    private static let legacySupportDirectoryName = "DivoomMiniToo"
    private static let migrationKey = "MiniTooToolboxIdentityMigrationV1"

    static func migrateUserDataIfNeeded(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }

        if let legacy = UserDefaults(suiteName: legacyBundleIdentifier),
           let values = legacy.persistentDomain(forName: legacyBundleIdentifier) {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacyURL = applicationSupport.appendingPathComponent(legacySupportDirectoryName, isDirectory: true)
            let newURL = applicationSupport.appendingPathComponent(supportDirectoryName, isDirectory: true)
            if fileManager.fileExists(atPath: legacyURL.path), !fileManager.fileExists(atPath: newURL.path) {
                try? fileManager.moveItem(at: legacyURL, to: newURL)
            }
        }

        defaults.set(true, forKey: migrationKey)
    }
}

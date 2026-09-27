import Foundation

enum AppPaths {
    /// ~/Library/Application Support/MusicJournal: journal, taste cache, Claude working dir.
    static var support: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// One-time move from the app's old name, Spot Helper, so the rebrand keeps your journal,
/// settings, recent moods and taste profile.
enum LegacyMigration {
    static let oldBundleID = "com.doudou.spothelper"
    private static let doneKey = "migratedFromSpotHelper"

    static func run(
        defaults: UserDefaults = .standard,
        oldSettings: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldBundleID),
        baseDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }

        // Settings: copy the old app's preferences domain, without overwriting anything new.
        if let old = oldSettings {
            for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NSWindow Frame") {
                defaults.set(value, forKey: key)
            }
        }

        // Files: journal, taste cache and Claude's working folder.
        let oldDir = baseDirectory.appendingPathComponent("SpotHelper", isDirectory: true)
        let newDir = baseDirectory.appendingPathComponent("MusicJournal", isDirectory: true)
        if fileManager.fileExists(atPath: oldDir.path) {
            if !fileManager.fileExists(atPath: newDir.path) {
                try? fileManager.moveItem(at: oldDir, to: newDir)
            } else {
                // New folder already exists: move over only files it doesn't have yet.
                for name in (try? fileManager.contentsOfDirectory(atPath: oldDir.path)) ?? [] {
                    let target = newDir.appendingPathComponent(name)
                    if !fileManager.fileExists(atPath: target.path) {
                        try? fileManager.moveItem(at: oldDir.appendingPathComponent(name), to: target)
                    }
                }
                // Tidy up only if everything made it across.
                if (try? fileManager.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: oldDir)
                }
            }
        }

        defaults.set(true, forKey: doneKey)
    }
}

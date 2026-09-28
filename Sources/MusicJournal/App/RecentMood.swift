import Foundation

/// A mood you typed, with when you typed it. Moods saved before timestamps existed have no date.
struct RecentMood: Codable, Hashable, Identifiable, Sendable {
    let text: String
    let date: Date?

    var id: String { text.lowercased() }

    static func load(from defaults: UserDefaults, key: String, legacyKey: String) -> [RecentMood] {
        if let data = defaults.data(forKey: key),
           let moods = try? JSONDecoder().decode([RecentMood].self, from: data) {
            return moods
        }
        // Older builds stored plain strings.
        return (defaults.stringArray(forKey: legacyKey) ?? []).map { RecentMood(text: $0, date: nil) }
    }

    /// Combines lists, newest first, one entry per mood (the newest wins), at most `limit`.
    static func merged(_ lists: [RecentMood]..., limit: Int = 8) -> [RecentMood] {
        var seen = Set<String>()
        let all = lists.flatMap { $0 }.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        return Array(all.map(\.element).filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    static func save(_ moods: [RecentMood], to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(moods) {
            defaults.set(data, forKey: key)
        }
    }

    /// "5 min ago", "yesterday", in the user's locale. nil for undated legacy moods.
    func relativeTime(now: Date = Date()) -> String? {
        guard let date else { return nil }
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// Mood history that earlier builds kept unencrypted in the app's settings. It's moved into
/// the encrypted journal on the next unlock, then erased here and from the settings files of
/// earlier app IDs.
struct PlaintextMoodHistory {
    static let keys = ["recentMoodHistory", "recentMoods"]
    /// Off for sample and test journals, so only the real journal ever moves or erases these.
    var enabled = true
    var defaults: UserDefaults = .standard
    /// Settings files of earlier app IDs, found by how their names end.
    var legacyDomains: () -> [String] = {
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        return LegacyMigration.legacyDomains(in: names, currentID: Bundle.main.bundleIdentifier)
    }

    static var none: PlaintextMoodHistory { PlaintextMoodHistory(enabled: false) }

    func load() -> [RecentMood] {
        guard enabled else { return [] }
        return RecentMood.load(from: defaults, key: Self.keys[0], legacyKey: Self.keys[1])
    }

    func erase() {
        guard enabled else { return }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        for domain in legacyDomains() {
            guard var settings = defaults.persistentDomain(forName: domain),
                  Self.keys.contains(where: { settings[$0] != nil }) else { continue }
            for key in Self.keys { settings.removeValue(forKey: key) }
            defaults.setPersistentDomain(settings, forName: domain)
        }
    }
}

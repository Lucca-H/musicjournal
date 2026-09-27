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

import Foundation

/// How much recommendations should lean on the listener's taste. The mood always leads.
enum TasteInfluence: String, CaseIterable, Identifiable, Sendable {
    case off
    case subtle
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .strong: "Strong"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Picks go by your mood alone."
        case .subtle: "Your taste is a light hint. Mostly music you probably haven't heard."
        case .strong: "Leans on your favourites, still mixed with new music."
        }
    }

    /// What the brain is told to do with the taste information.
    var instruction: String {
        switch self {
        case .off:
            ""
        case .subtle:
            "Use this only as a light hint about style. Most songs should be ones the listener probably "
                + "doesn't know. At most 3 songs in total by the artists listed here, and don't include "
                + "the favourite songs listed."
        case .strong:
            "Lean on this: up to half the songs can come from these artists or close neighbours, and one "
                + "or two of the favourite songs are fine if they fit the mood."
        }
    }
}

/// Whether music should sit with the mood or nudge it somewhere better.
enum MoodApproach: String, CaseIterable, Identifiable, Sendable {
    case match
    case auto
    case lift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .match: "Match my mood"
        case .auto: "Let it decide"
        case .lift: "Lift my mood"
        }
    }

    /// Plain-language description shown under the switch.
    var caption: String {
        switch self {
        case .match: "Music that stays with how you feel."
        case .auto: "Claude reads your words and decides whether to match or lift."
        case .lift: "Starts where you are, then gently brightens across the mix."
        }
    }

    var instruction: String {
        switch self {
        case .match: "Match the mood. Stay with how they feel; don't try to cheer them up or change it."
        case .auto: "Decide from their words whether they want music that matches the mood or shifts it."
        case .lift: "Gently lift the mood: start close to how they feel, then move toward something warmer or more energised across the mix."
        }
    }
}

enum Discovery: String, CaseIterable, Identifiable, Sendable {
    case familiar
    case balanced
    case discover

    var id: String { rawValue }

    var label: String {
        switch self {
        case .familiar: "Familiar"
        case .balanced: "Balanced"
        case .discover: "Discover"
        }
    }

    var instruction: String? {
        switch self {
        case .familiar: "Favour well-known songs and hits."
        case .balanced: nil
        case .discover: "Favour lesser-known songs and deep cuts; skip the obvious hits."
        }
    }
}

enum VocalPreference: String, CaseIterable, Identifiable, Sendable {
    case any
    case instrumental
    case vocal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any"
        case .instrumental: "Mostly instrumental"
        case .vocal: "Mostly vocals"
        }
    }

    var instruction: String? {
        switch self {
        case .any: nil
        case .instrumental: "Mostly instrumental tracks."
        case .vocal: "Mostly songs with vocals."
        }
    }
}

/// A song written as "Title — Artist" (artist optional).
struct SongRef: Sendable, Equatable {
    let title: String
    let artist: String?

    init(title: String, artist: String?) {
        self.title = title
        self.artist = artist
    }

    /// Parses "Title — Artist", "Title - Artist" or "Title by Artist".
    init(line: String) {
        for separator in [" — ", " – ", " - ", " by "] {
            if let range = line.range(of: separator) {
                self.init(
                    title: String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                    artist: String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                )
                return
            }
        }
        self.init(title: line.trimmingCharacters(in: .whitespaces), artist: nil)
    }

    var line: String { artist.map { "\(title) — \($0)" } ?? title }

    private static func titleKey(_ title: String) -> String {
        let base = TrackMatcher.baseTitle(title).matchKey
        return base.isEmpty ? title.matchKey : base
    }

    /// Same song title, and same artist when we know it. Titles compare without decorations,
    /// so a thumbs-down saved as "Feather (feat. Cise Starr & Akin)" also catches "Feather".
    func matches(title otherTitle: String, artist otherArtist: String) -> Bool {
        let key = Self.titleKey(title)
        guard !key.isEmpty, key == Self.titleKey(otherTitle) else { return false }
        guard let artist, !artist.matchKey.isEmpty else { return true }
        let a = artist.matchKey, b = otherArtist.matchKey
        return a.contains(b) || b.contains(a)
    }
}

/// The listener's personalization profile from Settings. Everything is optional.
struct Personalization: Sendable, Equatable {
    // What they like (follows `influence`)
    var artists: [String] = []
    /// One per line, e.g. "Holocene — Bon Iver".
    var songs: [String] = []
    var genres: [String] = []
    var eras: [String] = []
    var languages: [String] = []
    /// Songs they gave a thumbs-up in earlier mixes.
    var likedSongs: [String] = []
    var influence: TasteInfluence = .subtle

    // How to pick (always applies)
    var approach: MoodApproach = .auto
    var discovery: Discovery = .balanced
    var vocals: VocalPreference = .any
    var cleanOnly = false
    var mixLength = 25

    // Not for me (always applies)
    /// Artists or genres to never suggest.
    var avoid: [String] = []
    /// Songs they gave a thumbs-down; never suggested again.
    var skippedSongs: [String] = []

    var hasTaste: Bool {
        !(artists.isEmpty && songs.isEmpty && genres.isEmpty && eras.isEmpty && languages.isEmpty && likedSongs.isEmpty)
    }

    /// Splits on new lines and semicolons (and commas unless `commas` is false, since song
    /// titles can contain commas), trims, and de-duplicates case-insensitively.
    /// Not capped: liked/skipped lists grow over time and the newest entries matter most.
    /// Prompt builders trim what they send instead.
    static func list(from text: String, commas: Bool = true) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0.isNewline || $0 == ";" || (commas && $0 == ",") })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Songs the mix must not contain: thumbs-downs always, and in Subtle mode your listed
    /// favourites and thumbs-ups (Subtle promises new music rather than replays).
    var excludedSongs: [SongRef] {
        var refs = skippedSongs.map(SongRef.init(line:))
        if influence == .subtle { refs += (songs + likedSongs).map(SongRef.init(line:)) }
        return refs
    }

    /// Prompt lines describing what they like (gated by `influence` by the caller).
    func tasteLines(compact: Bool) -> [String] {
        var lines: [String] = []
        if !artists.isEmpty {
            lines.append("Artists they like: " + artists.prefix(compact ? 10 : 25).joined(separator: "; "))
        }
        if !songs.isEmpty {
            lines.append("Favourite songs: " + songs.prefix(compact ? 6 : 20).joined(separator: "; "))
        }
        if !genres.isEmpty {
            lines.append("Genres and vibes they like: " + genres.prefix(15).joined(separator: "; "))
        }
        if !eras.isEmpty {
            lines.append("Eras they like: " + eras.prefix(10).joined(separator: "; "))
        }
        if !languages.isEmpty {
            lines.append("Languages they enjoy: " + languages.prefix(10).joined(separator: "; "))
        }
        if !likedSongs.isEmpty {
            lines.append("Songs they liked in earlier mixes (a hint for style, don't repeat them): "
                + likedSongs.suffix(compact ? 6 : 20).joined(separator: "; "))
        }
        return lines
    }

    /// Prompt lines for how to pick. These apply regardless of taste influence.
    func preferenceLines() -> [String] {
        var lines = [approach.instruction]
        if let d = discovery.instruction { lines.append(d) }
        if let v = vocals.instruction { lines.append(v) }
        if cleanOnly { lines.append("Only clean songs: no explicit lyrics.") }
        return lines
    }

    /// Lines for things to never suggest.
    func avoidLines(compact: Bool) -> [String] {
        var lines: [String] = []
        if !avoid.isEmpty {
            lines.append("Not for me (never suggest these artists or genres): " + avoid.prefix(40).joined(separator: "; "))
        }
        if !skippedSongs.isEmpty {
            lines.append("Never suggest these songs: " + skippedSongs.suffix(compact ? 10 : 40).joined(separator: "; "))
        }
        return lines
    }
}

import Foundation

/// Result of checking one suggested song against a catalog.
enum TrackLookup: Sendable, Hashable {
    case found(TrackSummary)
    /// The catalog answered and has no such song (likely a made-up suggestion).
    /// Only complete catalogs (Spotify) return this.
    case notFound
    /// We couldn't confirm it: network error, rate limit, or a gap in an incomplete
    /// catalog like iTunes. The song may well exist.
    case unverified

    var track: TrackSummary? {
        if case .found(let track) = self { return track }
        return nil
    }
}

/// Where the app verifies songs and finds playlists. Spotify needs a Premium-owned
/// developer app; iTunes is free and needs no login.
protocol MusicCatalog: Sendable {
    /// Shown in "not found on …" so users know which catalog was checked.
    var name: String { get }
    /// Whether this catalog can list real playlists. If not, the UI shows search phrases instead.
    var listsPlaylists: Bool { get }
    var lookupConcurrency: Int { get }
    func discoverPlaylists(queries: [String], excluding: Set<String>) async throws -> [PickedPlaylist]
    func lookup(_ idea: MoodPlan.TrackIdea) async -> TrackLookup
}

enum TrackMatcher {
    private static let variantWords = ["remix", "instrumental", "karaoke", "live", "originallyperformed", "inthestyleof", "acoustic", "cover"]

    /// How well a catalog track matches a suggestion, or nil if it doesn't.
    /// Requires the same primary artist (either name contains the other) and a title that
    /// starts the same way, so "Heroes - 2017 Remaster" matches "Heroes" but covers don't.
    /// Exact titles beat decorated ones, and remix/karaoke/live versions rank last.
    static func score(wantedTitle: String, wantedArtist: String, title: String, artists: [String]) -> Int? {
        let wantedArtistKey = wantedArtist.matchKey
        let wantedTitleKey = wantedTitle.matchKey
        let titleKey = title.matchKey
        guard !wantedTitleKey.isEmpty, !wantedArtistKey.isEmpty, !titleKey.isEmpty else { return nil }

        let artistOK = artists.contains { name in
            let key = name.matchKey
            return !key.isEmpty && (key.contains(wantedArtistKey) || wantedArtistKey.contains(key))
        }
        guard artistOK else { return nil }

        var score: Int
        if titleKey == wantedTitleKey {
            score = 4
        } else if baseTitle(title).matchKey == wantedTitleKey {
            score = 3
        } else if titleKey.hasPrefix(wantedTitleKey) || wantedTitleKey.hasPrefix(titleKey) {
            score = 2
        } else if !baseTitle(title).matchKey.isEmpty, baseTitle(title).matchKey == baseTitle(wantedTitle).matchKey {
            // Same title before any " - " or "(…)" decoration, e.g. "715 - CRΣΣKS" written with
            // Greek sigmas vs the catalog's "715 - CR∑∑KS" summation signs.
            score = 1
        } else {
            return nil
        }
        if variantWords.contains(where: { titleKey.contains($0) && !wantedTitleKey.contains($0) }) {
            score -= 3
        }
        return score
    }

    /// Title-only check, for when the artist isn't known (Spotify oEmbed gives just the title).
    static func titlesMatch(_ wanted: String, _ title: String) -> Bool {
        score(wantedTitle: wanted, wantedArtist: "x", title: title, artists: ["x"]) != nil
    }

    static func matches(wantedTitle: String, wantedArtist: String, title: String, artists: [String]) -> Bool {
        score(wantedTitle: wantedTitle, wantedArtist: wantedArtist, title: title, artists: artists) != nil
    }

    /// Best-scoring candidate, keeping catalog order for ties.
    static func best<C>(_ candidates: [C], for idea: MoodPlan.TrackIdea, title: (C) -> String?, artists: (C) -> [String]) -> C? {
        var best: (candidate: C, score: Int)?
        for candidate in candidates {
            guard let name = title(candidate),
                  let s = score(wantedTitle: idea.title, wantedArtist: idea.artist, title: name, artists: artists(candidate))
            else { continue }
            if best == nil || s > best!.score { best = (candidate, s) }
        }
        return best?.candidate
    }

    /// "Heroes - 2017 Remaster" → "Heroes"; "Feather (feat. Cise Starr)" → "Feather".
    static func baseTitle(_ title: String) -> String {
        var base = title
        for separator in [" (", " [", " - "] {
            if let range = base.range(of: separator) { base = String(base[..<range.lowerBound]) }
        }
        return base
    }
}

enum SpotifyLinks {
    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// Opens Spotify's search for `query`, in the desktop app or the web player.
    static func search(_ query: String) -> (uri: String, webURL: URL?) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return ("spotify:search:\(encoded)", URL(string: "https://open.spotify.com/search/\(encoded)"))
    }
}

/// Account mode: real Spotify search, which needs a signed-in, Premium-owned developer app.
struct SpotifyCatalog: MusicCatalog {
    let client: SpotifyClient
    let userID: String
    let name = "Spotify"
    let listsPlaylists = true
    let lookupConcurrency = 5

    /// Runs every search query, keeps the top few per query, and interleaves them so
    /// each query is represented near the top.
    func discoverPlaylists(queries: [String], excluding: Set<String>) async throws -> [PickedPlaylist] {
        let perQuery = try await concurrentMap(queries, limit: 4) { query in
            let results = (try? await client.searchPlaylists(query)) ?? []
            return results
                .filter { ($0.itemCount ?? 20) >= 8 }
                .prefix(5)
                .map { PickedPlaylist(playlist: PlaylistSummary($0, currentUserID: userID), reason: "“\(query)”") }
        }
        var seen = excluding
        var merged: [PickedPlaylist] = []
        for rank in 0..<5 {
            for list in perQuery where rank < list.count {
                if seen.insert(list[rank].id).inserted {
                    merged.append(list[rank])
                }
            }
        }
        return merged
    }

    func lookup(_ idea: MoodPlan.TrackIdea) async -> TrackLookup {
        do {
            if let track = try await client.findTrack(title: idea.title, artist: idea.artist) {
                return .found(TrackSummary(track))
            }
            return .notFound
        } catch {
            return .unverified
        }
    }
}

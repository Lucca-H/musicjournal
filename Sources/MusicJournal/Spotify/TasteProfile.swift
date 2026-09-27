import Foundation

/// A compact, cacheable summary of the listener's taste used to ground the mood brain.
struct TasteProfile: Codable, Sendable {
    struct ArtistInfo: Codable, Sendable, Hashable {
        let name: String
        let genres: [String]
    }

    let userID: String
    let displayName: String?
    let recentArtists: [ArtistInfo]      // top artists, short term (~4 weeks)
    let longTermArtists: [ArtistInfo]    // top artists, medium term (~6 months)
    let topTracks: [String]              // "Title — Artist"
    let recentlyPlayed: [String]
    let playlists: [PlaylistSummary]
    let builtAt: Date

    /// Free mode has no Spotify data; taste comes from the personalization profile instead.
    static let empty = TasteProfile(
        userID: "local", displayName: nil, recentArtists: [], longTermArtists: [],
        topTracks: [], recentlyPlayed: [], playlists: [], builtAt: .distantPast
    )

    /// Listening history for the prompt (account mode). Empty in free mode.
    /// `compact` fits the on-device model's small context window.
    func listeningSummary(compact: Bool) -> String {
        let artistLimit = compact ? 10 : 20
        let trackLimit = compact ? 8 : 20

        func artistLine(_ a: ArtistInfo) -> String {
            a.genres.isEmpty || compact ? a.name : "\(a.name) (\(a.genres.prefix(3).joined(separator: ", ")))"
        }

        var lines: [String] = []
        if !recentArtists.isEmpty {
            lines.append("Top artists lately: " + recentArtists.prefix(artistLimit).map(artistLine).joined(separator: "; "))
        }
        let longTerm = longTermArtists.filter { !recentArtists.prefix(artistLimit).contains($0) }
        if !longTerm.isEmpty {
            lines.append("Long-time favourite artists: " + longTerm.prefix(artistLimit).map(artistLine).joined(separator: "; "))
        }
        if !topTracks.isEmpty {
            lines.append("Top tracks: " + topTracks.prefix(trackLimit).joined(separator: "; "))
        }
        if !recentlyPlayed.isEmpty && !compact {
            lines.append("Recently played: " + recentlyPlayed.prefix(15).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// The listener's saved playlists, for "from your library" picks (account mode).
    func playlistSummary(compact: Bool) -> String {
        guard !playlists.isEmpty else { return "" }
        var lines = ["The listener's saved playlists (id | name | description):"]
        for p in playlists.prefix(compact ? 25 : 80) {
            let desc = compact ? "" : p.description.truncated(to: 90)
            lines.append("\(p.id) | \(p.name.truncated(to: 60)) | \(desc)")
        }
        return lines.joined(separator: "\n")
    }
}

enum TasteProfileBuilder {
    static let maxAge: TimeInterval = 24 * 60 * 60

    private static var cacheURL: URL {
        AppPaths.support.appendingPathComponent("taste.json")
    }

    static func cached() -> TasteProfile? {
        guard let data = try? Data(contentsOf: cacheURL),
              let profile = try? JSONDecoder().decode(TasteProfile.self, from: data),
              Date().timeIntervalSince(profile.builtAt) < maxAge else { return nil }
        return profile
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    static func load(using client: SpotifyClient, forceRefresh: Bool = false) async throws -> TasteProfile {
        if !forceRefresh, let cached = cached() { return cached }
        let profile = try await build(using: client)
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return profile
    }

    static func build(using client: SpotifyClient) async throws -> TasteProfile {
        let user = try await client.me()
        // Top items are empty for brand-new accounts; treat failures there as "no data".
        async let shortArtists = (try? await client.topArtists(range: "short_term")) ?? []
        async let mediumArtists = (try? await client.topArtists(range: "medium_term")) ?? []
        async let tracks = (try? await client.topTracks(range: "short_term")) ?? []
        async let recent = (try? await client.recentlyPlayed()) ?? []
        async let playlists = client.myPlaylists()

        func info(_ artists: [Artist]) -> [TasteProfile.ArtistInfo] {
            artists.map { .init(name: $0.name, genres: $0.genres ?? []) }
        }
        func label(_ t: Track) -> String {
            "\(t.name) — \(t.artists.first?.name ?? "?")"
        }

        return TasteProfile(
            userID: user.id,
            displayName: user.displayName,
            recentArtists: info(await shortArtists),
            longTermArtists: info(await mediumArtists),
            topTracks: await tracks.map(label),
            recentlyPlayed: Array(NSOrderedSet(array: await recent.map(label)).array as! [String]),
            playlists: try await playlists.map { PlaylistSummary($0, currentUserID: user.id) },
            builtAt: Date()
        )
    }
}

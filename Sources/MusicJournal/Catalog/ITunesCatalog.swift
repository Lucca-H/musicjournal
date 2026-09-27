import Foundation

/// Free mode: checks songs against Apple's public iTunes Search API (no key, no login).
/// It gives artwork, durations and 30-second previews. Songs then open in Spotify via search.
actor ITunesCatalog: MusicCatalog {
    nonisolated let name = "iTunes"
    nonisolated let listsPlaylists = false
    nonisolated let lookupConcurrency = 4

    /// Apple rate-limits around 20 requests/minute per IP. After a 403/429, stop
    /// checking for a minute and report songs as unverified instead of hammering it.
    private var pausedUntil: Date?
    private let session: URLSession
    private let country: String

    init(session: URLSession = .shared, country: String = Locale.current.region?.identifier ?? "US") {
        self.session = session
        self.country = country
    }

    func discoverPlaylists(queries: [String], excluding: Set<String>) async throws -> [PickedPlaylist] {
        []
    }

    private enum Response: Sendable {
        case ok(Data)
        case failed
    }

    /// One in-flight or finished "all songs by this artist" search per artist.
    private var artistSearches: [String: Task<Response, Never>] = [:]

    /// Pass 1 searches "artist title". iTunes ranks covers above some originals (it returns
    /// five "Holocene" covers before Bon Iver's), so pass 2 searches the artist's catalogue.
    func lookup(_ idea: MoodPlan.TrackIdea) async -> TrackLookup {
        guard case .ok(let data) = await search(term: "\(idea.artist) \(idea.title)", artistOnly: false, limit: 10) else {
            return .unverified
        }
        if let track = try? Self.bestMatch(in: data, for: idea) {
            return .found(track)
        }

        let key = idea.artist.matchKey
        let task: Task<Response, Never>
        if let existing = artistSearches[key] {
            task = existing
        } else {
            // Each response is a few hundred KB; don't let a long session pile them up.
            if artistSearches.count >= 40 { artistSearches.removeAll() }
            task = Task { await self.search(term: idea.artist, artistOnly: true, limit: 200) }
            artistSearches[key] = task
        }
        guard case .ok(let artistData) = await task.value else { return .unverified }
        if let track = try? Self.bestMatch(in: artistData, for: idea) {
            return .found(track)
        }
        // iTunes' index misses real songs (Bon Iver's "Holocene", FKA twigs' "Two Weeks"),
        // so a miss here isn't evidence the song is made up.
        return .unverified
    }

    private func search(term: String, artistOnly: Bool, limit: Int) async -> Response {
        if let pausedUntil, pausedUntil > Date() { return .failed }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "country", value: country),
        ] + (artistOnly ? [.init(name: "attribute", value: "artistTerm")] : [])
        do {
            let (data, response) = try await session.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if [403, 429, 503].contains(status) {
                pausedUntil = Date().addingTimeInterval(60)
                return .failed
            }
            return status == 200 ? .ok(data) : .failed
        } catch {
            return .failed
        }
    }

    struct SearchResponse: Decodable {
        struct Result: Decodable {
            let trackId: Int?
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
            let previewUrl: String?
            let trackTimeMillis: Int?
            /// "explicit", "cleaned" or "notExplicit".
            let trackExplicitness: String?
        }
        let results: [Result]
    }

    static func bestMatch(in data: Data, for idea: MoodPlan.TrackIdea) throws -> TrackSummary? {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let hit = TrackMatcher.best(response.results, for: idea, title: \.trackName, artists: { [$0.artistName ?? ""] }),
              let name = hit.trackName, let artist = hit.artistName else {
            return nil
        }
        let link = SpotifyLinks.search("\(name) \(artist)")
        return TrackSummary(
            id: hit.trackId.map { "itunes:\($0)" } ?? "itunes:\(name)|\(artist)",
            name: name,
            artist: artist,
            album: hit.collectionName,
            // Ask for a sharper thumbnail than the 100px default.
            imageURL: hit.artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "200x200bb")) },
            uri: link.uri,
            webURL: link.webURL,
            durationMs: hit.trackTimeMillis,
            previewURL: hit.previewUrl.flatMap(URL.init(string:)),
            isExplicit: hit.trackExplicitness.map { $0 == "explicit" }
        )
    }
}

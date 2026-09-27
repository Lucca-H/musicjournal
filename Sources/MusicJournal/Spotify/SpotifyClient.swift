import Foundation

enum SpotifyError: LocalizedError {
    case http(status: Int, message: String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            switch status {
            case 403: "Spotify refused the request (403). Dev-mode apps need the owner on Premium and your account added under User Management. \(message)"
            default: "Spotify error \(status): \(message)"
            }
        case .rateLimited:
            "Spotify is rate-limiting requests. Wait a minute and try again."
        }
    }
}

/// Thin async wrapper over the Spotify Web API. Refreshes on 401 and honours 429 Retry-After.
struct SpotifyClient: Sendable {
    let tokens: TokenStore
    private let baseURL = URL(string: "https://api.spotify.com/v1/")!

    init(tokens: TokenStore) {
        self.tokens = tokens
    }

    // MARK: Endpoints

    func me() async throws -> SpotifyUser {
        try await get("me")
    }

    func topArtists(range: String, limit: Int = 20) async throws -> [Artist] {
        let page: Paging<Artist> = try await get("me/top/artists", ["time_range": range, "limit": "\(limit)"])
        return page.items
    }

    func topTracks(range: String, limit: Int = 20) async throws -> [Track] {
        let page: Paging<Track> = try await get("me/top/tracks", ["time_range": range, "limit": "\(limit)"])
        return page.items
    }

    func recentlyPlayed(limit: Int = 30) async throws -> [Track] {
        let page: Paging<PlayHistory> = try await get("me/player/recently-played", ["limit": "\(limit)"])
        return page.items.map(\.track)
    }

    func myPlaylists(max: Int = 100) async throws -> [Playlist] {
        var result: [Playlist] = []
        var offset = 0
        while result.count < max {
            let page: Paging<Playlist> = try await get("me/playlists", ["limit": "50", "offset": "\(offset)"])
            result += page.items
            offset += 50
            if page.next == nil { break }
        }
        return Array(result.prefix(max))
    }

    func searchPlaylists(_ query: String, limit: Int = 10) async throws -> [Playlist] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let response: SearchResponse = try await get("search", ["q": q, "type": "playlist", "limit": "\(min(limit, 10))"])
        return response.playlists?.items ?? []
    }

    /// Finds a specific song. Only returns a match whose artist loosely matches,
    /// so hallucinated suggestions stay unresolved instead of becoming random tracks.
    func findTrack(title: String, artist: String) async throws -> Track? {
        let queries = ["track:\(title) artist:\(artist)", "\(title) \(artist)"]
        for q in queries {
            let response: SearchResponse = try await get("search", ["q": q, "type": "track", "limit": "5"])
            let match = TrackMatcher.best(
                response.tracks?.items ?? [],
                for: .init(title: title, artist: artist),
                title: \.name,
                artists: { $0.artists.map(\.name) }
            )
            if let match { return match }
        }
        return nil
    }

    func createPlaylist(name: String, description: String, isPublic: Bool = false) async throws -> Playlist {
        struct Body: Encodable { let name: String; let description: String; let `public`: Bool }
        return try await send("POST", "me/playlists", body: Body(name: name, description: description, public: isPublic))
    }

    func addItems(playlistID: String, uris: [String]) async throws {
        struct Body: Encodable { let uris: [String] }
        struct Snapshot: Decodable { let snapshotId: String? }
        for start in stride(from: 0, to: uris.count, by: 100) {
            let chunk = Array(uris[start..<min(start + 100, uris.count)])
            let _: Snapshot = try await send("POST", "playlists/\(playlistID)/items", body: Body(uris: chunk))
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try await send("GET", path, query: query, body: Optional<String>.none)
    }

    private func send<T: Decodable, B: Encodable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: B?
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        var refreshed = false
        for attempt in 0..<4 {
            request.setValue("Bearer \(try await tokens.validAccessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpotifyError.http(status: 0, message: "No HTTP response")
            }

            switch http.statusCode {
            case 200..<300:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
            case 401 where !refreshed:
                refreshed = true
                await tokens.forceExpire()
            case 429:
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(1 << attempt)
                guard wait <= 15, attempt < 3 else { throw SpotifyError.rateLimited }
                try await Task.sleep(for: .seconds(wait))
            case 500..<600 where attempt < 2:
                try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            default:
                let message = (try? JSONDecoder().decode(SpotifyErrorBody.self, from: data))?.error?.message
                    ?? String(data: data, encoding: .utf8) ?? ""
                throw SpotifyError.http(status: http.statusCode, message: message)
            }
        }
        throw SpotifyError.rateLimited
    }
}

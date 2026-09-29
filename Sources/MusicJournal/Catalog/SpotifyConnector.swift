import Foundation

/// A real Spotify track found for a mix entry.
struct SpotifyTrackRef: Sendable, Hashable {
    let id: String
    let title: String?
    let imageURL: URL?

    var uri: String { "spotify:track:\(id)" }
    var webURL: URL { URL(string: "https://open.spotify.com/track/\(id)")! }
}

enum SpotifyConnectorError: LocalizedError {
    case nothingFound

    var errorDescription: String? {
        switch self {
        case .nothingFound:
            "Couldn't reach Spotify through Claude. In claude.ai, open Settings → Connectors and make sure Spotify is connected."
        }
    }
}

/// Free mode's way to real Spotify track IDs: Spotify's official Claude connector, which
/// Claude Code can use. Its search tool works on free Spotify accounts (only its playlist
/// creation needs Premium), so we look songs up there and paste the links into a playlist.
/// Some labels block the connector (`RESULTS_FILTERED_LICENSING`), so a few songs per mix
/// come back empty even though they're on Spotify; the UI asks the user to add those by hand.
struct SpotifyConnectorResolver: Sendable {
    var executableOverride: String?
    var timeout: Duration = .seconds(240)

    private static let searchTool = "mcp__claude_ai_Spotify__search"

    static let systemPrompt = """
    You find songs on Spotify using the Spotify search tool. You must call the search tool for \
    every song before answering: search for each song separately, all in parallel. Return only \
    track URIs the tool returned for the right song by the right artist (spotify:track:…). Use \
    null only when a search found no match. Never invent or alter URIs.
    """

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["tracks"],"properties":{"tracks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["index","uri"],"properties":{"index":{"type":"integer"},"uri":{"type":["string","null"]}}}}}}
    """

    struct Response: Decodable {
        struct Item: Decodable {
            let index: Int
            let uri: String?
        }
        let tracks: [Item]
    }

    static func prompt(for ideas: [MoodPlan.TrackIdea]) -> String {
        ideas.enumerated().map { "\($0). \($1.title) — \($1.artist)" }.joined(separator: "\n")
    }

    /// Returns track IDs keyed by position in `ideas`. IDs are checked against Spotify's
    /// public oEmbed endpoint, so a made-up or mismatched ID is dropped.
    func resolve(_ ideas: [MoodPlan.TrackIdea]) async throws -> [Int: SpotifyTrackRef] {
        guard !ideas.isEmpty else { return [:] }
        // On low effort Claude occasionally answers "not found" for everything without
        // searching at all. An all-empty answer gets one retry with more effort.
        var candidates: [Int: String] = [:]
        for effort in ["low", "medium"] {
            let response = try await ClaudeCLI.structuredRequest(
                Response.self,
                prompt: Self.prompt(for: ideas),
                systemPrompt: Self.systemPrompt,
                schema: Self.schema,
                extraArguments: ["--tools", Self.searchTool, "--allowedTools", Self.searchTool],
                model: ProcessInfo.processInfo.environment["MJ_LOOKUP_MODEL"],
                effort: effort,
                executableOverride: executableOverride,
                timeout: timeout
            )
            candidates = Self.trackIDs(from: response, count: ideas.count)
            if !candidates.isEmpty || Task.isCancelled { break }
        }
        // If several songs went in and nothing came back, the connector is almost
        // certainly unavailable rather than every song missing.
        if candidates.isEmpty && ideas.count >= 3 {
            throw SpotifyConnectorError.nothingFound
        }

        let checked = try await concurrentMap(Array(candidates), limit: 6) { index, id in
            (index, await SpotifyOEmbed.check(trackID: id, expectedTitle: ideas[index].title))
        }
        var result: [Int: SpotifyTrackRef] = [:]
        for (index, ref) in checked {
            if let ref { result[index] = ref }
        }
        return result
    }

    /// Keeps well-formed `spotify:track:` URIs for valid indices, first one wins.
    static func trackIDs(from response: Response, count: Int) -> [Int: String] {
        var ids: [Int: String] = [:]
        for item in response.tracks where (0..<count).contains(item.index) && ids[item.index] == nil {
            guard let uri = item.uri, uri.hasPrefix("spotify:track:") else { continue }
            let id = String(uri.dropFirst("spotify:track:".count))
            if id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                ids[item.index] = id
            }
        }
        return ids
    }
}

/// Spotify's public oEmbed endpoint: no login, confirms a track ID exists and gives its
/// title and cover art.
enum SpotifyOEmbed {
    struct Response: Decodable {
        let title: String?
        let thumbnailUrl: String?
    }

    /// nil if the ID doesn't exist or is a different song. If Spotify can't be reached,
    /// the ID is kept (it came from Spotify's own search), just without a title check.
    static func check(trackID: String, expectedTitle: String) async -> SpotifyTrackRef? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [.init(name: "url", value: "https://open.spotify.com/track/\(trackID)")]
        guard let (data, response) = try? await URLSession.shared.data(from: components.url!),
              let status = (response as? HTTPURLResponse)?.statusCode else {
            return SpotifyTrackRef(id: trackID, title: nil, imageURL: nil)
        }
        if status == 404 || status == 400 { return nil }
        guard status == 200 else { return SpotifyTrackRef(id: trackID, title: nil, imageURL: nil) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let info = try? decoder.decode(Response.self, from: data)
        if let title = info?.title, !TrackMatcher.titlesMatch(expectedTitle, title) {
            return nil
        }
        return SpotifyTrackRef(id: trackID, title: info?.title, imageURL: info?.thumbnailUrl.flatMap(URL.init(string:)))
    }
}

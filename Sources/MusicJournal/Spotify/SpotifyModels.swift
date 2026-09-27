import Foundation

// Wire models for the Spotify Web API (post Feb-2026 shape). Decoded with
// `.convertFromSnakeCase`, so `display_name` → `displayName`, etc.

struct SpotifyImage: Codable, Sendable, Hashable {
    let url: String
    let width: Int?
    let height: Int?
}

struct ExternalURLs: Codable, Sendable, Hashable {
    let spotify: String?
}

struct SpotifyUser: Decodable, Sendable {
    let id: String
    let displayName: String?
}

struct SimpleArtist: Decodable, Sendable {
    let id: String?
    let name: String
}

struct Artist: Decodable, Sendable {
    let id: String
    let name: String
    let genres: [String]?
}

struct Album: Decodable, Sendable {
    let name: String
    let images: [SpotifyImage]?
}

struct Track: Decodable, Sendable {
    let id: String
    let name: String
    let uri: String
    let explicit: Bool?
    let artists: [SimpleArtist]
    let album: Album?
    let durationMs: Int?
    let externalUrls: ExternalURLs?
}

struct PlaylistOwner: Decodable, Sendable {
    let id: String
    let displayName: String?
}

struct Playlist: Decodable, Sendable {
    let id: String
    let name: String
    let description: String?
    let uri: String
    let images: [SpotifyImage]?
    let owner: PlaylistOwner?
    let externalUrls: ExternalURLs?
    let itemCount: Int?

    private struct ItemsRef: Decodable { let total: Int? }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, uri, images, owner, externalUrls, items, tracks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        uri = try c.decode(String.self, forKey: .uri)
        images = try c.decodeIfPresent([SpotifyImage].self, forKey: .images)
        owner = try c.decodeIfPresent(PlaylistOwner.self, forKey: .owner)
        externalUrls = try c.decodeIfPresent(ExternalURLs.self, forKey: .externalUrls)
        // Feb 2026 renamed `tracks` → `items`; accept either.
        let ref = (try? c.decodeIfPresent(ItemsRef.self, forKey: .items))
            ?? (try? c.decodeIfPresent(ItemsRef.self, forKey: .tracks))
        itemCount = ref?.total
    }
}

/// Spotify paging object. Search results can contain `null` or malformed
/// entries, so elements that fail to decode are dropped instead of failing the page.
struct Paging<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let next: String?
    let total: Int?

    private struct Lossy: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey { case items, next, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try c.decodeIfPresent([Lossy].self, forKey: .items) ?? []).compactMap(\.value)
        next = try c.decodeIfPresent(String.self, forKey: .next)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct SearchResponse: Decodable, Sendable {
    let tracks: Paging<Track>?
    let playlists: Paging<Playlist>?
}

struct PlayHistory: Decodable, Sendable {
    let track: Track
}

struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?
}

struct SpotifyErrorBody: Decodable {
    struct Inner: Decodable { let status: Int?; let message: String? }
    let error: Inner?
}

// MARK: - App-facing summaries (stable, Codable for caching and display)

struct PlaylistSummary: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String
    let ownerName: String?
    let ownedByUser: Bool
    let itemCount: Int?
    let imageURL: URL?
    let uri: String
    let webURL: URL?

    init(_ p: Playlist, currentUserID: String?) {
        id = p.id
        name = p.name
        description = (p.description ?? "").strippingHTML
        ownerName = p.owner?.displayName ?? p.owner?.id
        ownedByUser = p.owner?.id == currentUserID
        itemCount = p.itemCount
        imageURL = p.images?.first.flatMap { URL(string: $0.url) }
        uri = p.uri
        webURL = p.externalUrls?.spotify.flatMap(URL.init(string:))
    }
}

struct TrackSummary: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let artist: String
    let album: String?
    let imageURL: URL?
    /// A `spotify:` URI to open: the track itself, or a Spotify search in free mode.
    let uri: String
    let webURL: URL?
    let durationMs: Int?
    /// 30-second preview clip (free mode, from iTunes).
    let previewURL: URL?
    /// nil when the catalog didn't say.
    let isExplicit: Bool?

    init(
        id: String, name: String, artist: String, album: String?, imageURL: URL?,
        uri: String, webURL: URL?, durationMs: Int?, previewURL: URL?, isExplicit: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.imageURL = imageURL
        self.uri = uri
        self.webURL = webURL
        self.durationMs = durationMs
        self.previewURL = previewURL
        self.isExplicit = isExplicit
    }

    init(_ t: Track) {
        id = t.id
        name = t.name
        artist = t.artists.map(\.name).joined(separator: ", ")
        album = t.album?.name
        // Smallest image that is still ≥ 64px keeps row thumbnails light.
        let images = (t.album?.images ?? []).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        imageURL = (images.first { ($0.width ?? 0) >= 64 } ?? images.last).flatMap { URL(string: $0.url) }
        uri = t.uri
        webURL = t.externalUrls?.spotify.flatMap(URL.init(string:))
        durationMs = t.durationMs
        previewURL = nil
        isExplicit = t.explicit
    }
}

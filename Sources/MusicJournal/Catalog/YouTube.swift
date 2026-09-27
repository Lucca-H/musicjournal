import Foundation

/// A song found on YouTube.
struct YouTubeVideo: Sendable, Hashable {
    let id: String
    let title: String
    let channel: String
    let seconds: Int?
}

/// Finds songs on YouTube without an API key or login: it runs the same search the YouTube
/// website does, then picks the cleanest version of each song (official audio or the artist's own
/// upload, the right length, no live/cover/sped-up versions).
enum YouTubeFinder {
    struct Song: Sendable {
        let title: String
        let artist: String
        /// Length from iTunes, when known; helps pick the right version.
        let seconds: Int?
    }

    /// Video IDs keyed by position in `songs`. Songs that couldn't be found are left out.
    static func find(_ songs: [Song]) async -> [Int: YouTubeVideo] {
        let found = (try? await concurrentMap(Array(songs.enumerated()), limit: 4) { index, song in
            (index, await find(song))
        }) ?? []
        var result: [Int: YouTubeVideo] = [:]
        for (index, video) in found {
            if let video { result[index] = video }
        }
        return result
    }

    /// No cookies: a "slow down" flag YouTube sets on one request shouldn't follow the rest.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func find(_ song: Song) async -> YouTubeVideo? {
        // The same search the YouTube website runs behind the scenes. It needs no key and is
        // far lighter (and less rate-limited) than loading the results page.
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250925.01.00", "hl": "en", "gl": "US"]],
            "query": "\(song.artist) \(song.title)",
            "params": "EgIQAQ==",                                   // videos only
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700 * attempt)) }
            guard !Task.isCancelled else { return nil }
            let data: Data
            do {
                let (body, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    if debug { print("[\(song.title)] try \(attempt + 1): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
                    continue
                }
                data = body
            } catch {
                if debug { print("[\(song.title)] try \(attempt + 1) failed: \(error.localizedDescription)") }
                continue
            }
            let videos = parseSearch(data)
            if debug {
                print("[\(song.title)] try \(attempt + 1): \(data.count) bytes, \(videos.count) videos")
                for (rank, v) in videos.enumerated() { print("   \(score(v, for: song, rank: rank).map(String.init) ?? "–")  \(v.title) [\(v.channel)] \(v.seconds ?? 0)s") }
            }
            if !videos.isEmpty { return best(in: videos, for: song) }
        }
        return nil
    }

    private static let debug = ProcessInfo.processInfo.environment["MJ_YT_DEBUG"] != nil

    // MARK: Parsing

    /// The videos in a search response, in YouTube's order.
    static func parseSearch(_ data: Data) -> [YouTubeVideo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var videos: [YouTubeVideo] = []
        collect(json, into: &videos)
        return videos
    }

    private static func collect(_ node: Any, into videos: inout [YouTubeVideo]) {
        guard videos.count < 12 else { return }
        if let dict = node as? [String: Any] {
            if let renderer = dict["videoRenderer"] as? [String: Any], let video = video(from: renderer) {
                videos.append(video)
                return
            }
            for value in dict.values { collect(value, into: &videos) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &videos) }
        }
    }

    private static func video(from renderer: [String: Any]) -> YouTubeVideo? {
        guard let id = renderer["videoId"] as? String, id.count == 11 else { return nil }
        func text(_ key: String) -> String {
            guard let field = renderer[key] as? [String: Any] else { return "" }
            if let simple = field["simpleText"] as? String { return simple }
            return (field["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
        }
        return YouTubeVideo(id: id, title: text("title"), channel: text("ownerText"), seconds: seconds(from: text("lengthText")))
    }

    /// "5:44" → 344, "1:02:03" → 3723.
    static func seconds(from length: String) -> Int? {
        let parts = length.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Choosing

    private static let unwanted = ["live", "cover", "karaoke", "remix", "slowed", "spedup", "reverb", "8d",
                                   "nightcore", "instrumental", "reaction", "tutorial", "lesson", "1hour",
                                   "hourloop", "extended", "bassboosted", "pianoversion", "fullalbum", "greatesthits", "playlist",
                                   "mix2", "compilation"]

    /// The best match for `song`, or nil if nothing on the page is clearly that song.
    static func best(in videos: [YouTubeVideo], for song: Song) -> YouTubeVideo? {
        var best: (video: YouTubeVideo, score: Int)?
        for (rank, video) in videos.enumerated() {
            guard let s = score(video, for: song, rank: rank) else { continue }
            if best == nil || s > best!.score { best = (video, s) }
        }
        return best?.video
    }

    static func score(_ video: YouTubeVideo, for song: Song, rank: Int) -> Int? {
        let title = video.title.matchKey
        let channel = video.channel.matchKey
        let wantedTitle = TrackMatcher.baseTitle(song.title).matchKey
        let wantedArtist = song.artist.matchKey
        guard !wantedTitle.isEmpty, title.contains(wantedTitle) else { return nil }
        // "Artist - Topic" and "ArtistVEVO" channels count as the artist.
        let channelArtist = channel.replacingOccurrences(of: "topic", with: "").replacingOccurrences(of: "vevo", with: "")
        let byArtist = !wantedArtist.isEmpty && (channel.contains(wantedArtist)
            || (!channelArtist.isEmpty && wantedArtist.contains(channelArtist)))
        guard byArtist || title.contains(wantedArtist) else { return nil }

        var score = 3 - min(rank, 3)                    // YouTube's own ranking, lightly
        if byArtist { score += 3 }
        if video.channel.hasSuffix(" - Topic") { score += 3 }    // the plain studio recording
        if title.contains("officialaudio") { score += 3 }
        else if title.contains("officialvideo") || title.contains("officialmusicvideo") { score += 1 }
        if title.contains("lyric") { score += 1 }
        let wantedFull = song.title.matchKey
        if unwanted.contains(where: { title.contains($0.matchKey) && !wantedFull.contains($0.matchKey) }) { score -= 8 }
        if let have = video.seconds, have > 15 * 60 { score -= 8 }       // an album or a mix, not a song
        if let want = song.seconds, let have = video.seconds {
            let off = abs(want - have)
            if off <= 12 { score += 2 } else if off > 90 { score -= 4 }
        }
        return score > -2 ? score : nil
    }
}

enum YouTubeLinks {
    /// YouTube turns a list of video IDs into a temporary playlist that plays in order.
    /// It takes up to 50.
    static func queue(_ ids: [String]) -> URL? {
        let ids = Array(ids.prefix(50))
        guard !ids.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/watch_videos?video_ids=\(ids.joined(separator: ","))")
    }
}

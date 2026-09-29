import Foundation

struct MoodRequest: Sendable {
    let mood: String
    let taste: TasteProfile
    var personalization = Personalization()
    var date: Date = Date()
}

/// What the brain returns: an interpretation of the mood plus concrete things to look up on Spotify.
struct MoodPlan: Codable, Sendable, Equatable {
    struct Pick: Codable, Sendable, Equatable {
        let id: String
        let reason: String
    }

    struct TrackIdea: Codable, Sendable, Equatable, Hashable {
        let title: String
        let artist: String
    }

    var interpretation: String
    var energy: Double
    var valence: Double
    var keywords: [String]
    var ownedPlaylistPicks: [Pick]
    var playlistSearchQueries: [String]
    var trackSuggestions: [TrackIdea]
    var mixName: String
    var mixDescription: String

    /// Clamps numbers, drops picks for playlists we don't know, removes duplicates, keeps at most
    /// `maxPerArtist` songs per artist and `maxFromFavourites` songs by `favouriteArtists` in
    /// total, drops `excluded` songs, and caps the mix at `maxTracks`.
    func sanitized(
        validPlaylistIDs: Set<String>,
        maxPerArtist: Int = 2,
        excluded: [SongRef] = [],
        favouriteArtists: [String] = [],
        maxFromFavourites: Int = .max,
        maxTracks: Int = 40
    ) -> MoodPlan {
        var plan = self
        plan.energy = min(max(energy, 0), 1)
        plan.valence = min(max(valence, 0), 1)

        var seenPicks = Set<String>()
        plan.ownedPlaylistPicks = ownedPlaylistPicks
            .filter { validPlaylistIDs.contains($0.id) && seenPicks.insert($0.id).inserted }
            .prefix(6).map { $0 }

        var seenQueries = Set<String>()
        plan.playlistSearchQueries = playlistSearchQueries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenQueries.insert($0.lowercased()).inserted }
            .prefix(6).map { $0 }

        var seenTracks = Set<String>()
        var perArtist: [String: Int] = [:]
        let favouriteKeys = favouriteArtists.map(\.matchKey).filter { !$0.isEmpty }
        var fromFavourites = 0
        plan.trackSuggestions = trackSuggestions.filter { idea in
            guard !idea.title.matchKey.isEmpty else { return false }
            guard !excluded.contains(where: { $0.matches(title: idea.title, artist: idea.artist) }) else { return false }
            guard seenTracks.insert((idea.title + "|" + idea.artist).matchKey).inserted else { return false }
            let artistKey = idea.artist.matchKey
            guard perArtist[artistKey, default: 0] < maxPerArtist else { return false }
            let isFavourite = !artistKey.isEmpty
                && favouriteKeys.contains { artistKey.contains($0) || $0.contains(artistKey) }
            if isFavourite {
                guard fromFavourites < maxFromFavourites else { return false }
                fromFavourites += 1
            }
            perArtist[artistKey, default: 0] += 1
            return true
        }
        .prefix(maxTracks).map { $0 }

        plan.mixName = mixName.trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: 80)
        if plan.mixName.isEmpty { plan.mixName = "Mood mix" }
        plan.mixDescription = mixDescription.trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: 280)
        return plan
    }
}

enum BrainKind: String, Sendable {
    case claude
    case onDevice

    var label: String {
        switch self {
        case .claude: "Claude"
        case .onDevice: "on-device model"
        }
    }
}

enum BrainError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)
    case timedOut
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        case .failed(let why): why
        case .timedOut: "Claude didn't answer in time. Check Claude Code is installed and signed in: run claude -p \"hi\" in Terminal. If it asks you to log in, run claude and sign in."
        case .badOutput(let why): "The model returned something unexpected: \(why)"
        }
    }
}

protocol MoodBrain: Sendable {
    var kind: BrainKind { get }
    func interpret(_ request: MoodRequest) async throws -> MoodPlan
}

enum MoodPrompt {
    static let system = """
    You are a music curator inside a Spotify companion app. The listener describes how they feel \
    in their own words. You turn that into music that fits that moment.

    Guidelines:
    - The mood leads. Read it generously: combine the emotion, the energy level, and any situation \
    (activity, weather, time of day) the listener mentions or implies.
    - Keep it varied: at most 2 songs by any one artist. Unless the listener's preferences say \
    otherwise, mix well-known songs with ones they probably haven't heard.
    - Follow the taste guidance and listening preferences in the request exactly. With no taste \
    guidance, go by the mood alone.
    - Never suggest anything on the listener's "not for me" or "never suggest" lists.
    - Only suggest songs that really exist, with the exact title and primary artist as listed on Spotify.
    - ownedPlaylistPicks must use ids copied exactly from the listener's playlist list. Pick only \
    playlists whose name or description genuinely fits; an empty list is fine.
    - playlistSearchQueries are short (2–5 words) phrases phrased the way people name playlists on \
    Spotify, e.g. "rainy day jazz", "late night lofi", "sad indie folk". Make them varied.
    - energy and valence are numbers from 0 to 1 (valence: 0 = dark/sad, 1 = bright/happy).
    - mixName is evocative and under 40 characters; mixDescription is one sentence under 150 characters.
    """

    static func user(_ request: MoodRequest, compact: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        let length = min(max(request.personalization.mixLength, 5), 40)
        let trackCount = compact ? min(length, 12) : length
        let picks = request.taste.playlists.isEmpty
            ? "an empty ownedPlaylistPicks list (no saved playlists are available)"
            : "up to 5 ownedPlaylistPicks"
        return """
        Current mood, in the listener's words: "\(request.mood)"
        Local time: \(formatter.string(from: request.date)) (\(TimeOfDay.describe(request.date)))

        \(tasteSection(request, compact: compact))

        Return the plan with \(picks), 3–5 playlistSearchQueries, about \(trackCount) \
        trackSuggestions, a one-sentence interpretation of the mood, 3–6 keywords, energy, valence, \
        mixName and mixDescription.
        """
    }

    /// Taste guidance scaled by the listener's chosen influence, the "not for me" list, and
    /// their saved playlists (for library picks, which aren't taste-gated).
    static func tasteSection(_ request: MoodRequest, compact: Bool) -> String {
        let personalization = request.personalization
        let listening = request.taste.listeningSummary(compact: compact)
        let profile = personalization.tasteLines(compact: compact)

        var lines: [String] = []
        if personalization.influence != .off, !listening.isEmpty || !profile.isEmpty {
            lines.append("Taste guidance (\(personalization.influence.label.lowercased())): \(personalization.influence.instruction)")
            lines += profile
            if !listening.isEmpty { lines.append(listening) }
        } else {
            lines.append("Taste guidance: none. Choose by the mood alone.")
        }
        lines.append("")
        lines.append("Listening preferences:")
        lines += personalization.preferenceLines().map { "- \($0)" }
        lines += personalization.avoidLines(compact: compact)
        let playlists = request.taste.playlistSummary(compact: compact)
        if !playlists.isEmpty {
            lines.append("")
            lines.append(playlists)
        }
        return lines.joined(separator: "\n")
    }

    /// JSON Schema for Claude's structured output. Mirrors `MoodPlan`.
    static let jsonSchema: String = {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "interpretation", "energy", "valence", "keywords", "ownedPlaylistPicks",
                "playlistSearchQueries", "trackSuggestions", "mixName", "mixDescription",
            ],
            "properties": [
                "interpretation": ["type": "string", "description": "One sentence reading of the mood."],
                "energy": ["type": "number", "description": "0 (still) to 1 (intense)."],
                "valence": ["type": "number", "description": "0 (dark/sad) to 1 (bright/happy)."],
                "keywords": ["type": "array", "items": ["type": "string"]],
                "ownedPlaylistPicks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "reason"],
                        "properties": [
                            "id": ["type": "string", "description": "Playlist id copied from the list."],
                            "reason": ["type": "string", "description": "Why it fits, under 12 words."],
                        ],
                    ],
                ],
                "playlistSearchQueries": ["type": "array", "items": ["type": "string"]],
                "trackSuggestions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["title", "artist"],
                        "properties": [
                            "title": ["type": "string"],
                            "artist": ["type": "string"],
                        ],
                    ],
                ],
                "mixName": ["type": "string"],
                "mixDescription": ["type": "string"],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }()
}

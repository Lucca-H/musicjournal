import CryptoKit
import Foundation

/// A song attached to a journal entry. `stuck` marks the ones that stayed with you.
struct JournalSong: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var artist: String
    var imageURL: URL?
    /// Where a click goes: a Spotify track or a Spotify search.
    var spotifyURI: String
    var webURL: URL?
    var stuck: Bool
    /// The YouTube video for this song, once it's been looked up.
    var youtubeID: String?
}

/// One journal entry. Everything stays on this Mac, encrypted, and is never sent to Claude.
struct JournalEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    /// What you typed into the mood box, if the entry came from a mood.
    var mood: String?
    var text = ""
    var mixName: String?
    var valence: Double?
    var energy: Double?
    /// Up to three feeling IDs (see `Feeling.all`), most prominent first. Optional so journals
    /// saved before feelings existed still open.
    var feelingIDs: [String]?
    /// Claude's one-line reason, when it suggested the feelings.
    var feelingNote: String?
    var songs: [JournalSong] = []
    /// The mood result this entry came from, so saving twice opens the same entry.
    var recommendationID: UUID?

    var stuckSongs: [JournalSong] { songs.filter(\.stuck) }

    /// The entry's feelings. Older entries that only have a heavy-to-bright valence get the
    /// nearest feeling, so their colour carries over.
    var feelings: [Feeling] {
        if let ids = feelingIDs, !ids.isEmpty { return ids.compactMap(Feeling.named) }
        if let valence { return [Feeling.nearest(valence: valence, energy: energy)] }
        return []
    }

    /// First line of what you wrote, else the mood, else a placeholder.
    var title: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty { return firstLine }
        if let mood, !mood.isEmpty { return mood }
        return "Untitled entry"
    }
}

extension JournalEntry {
    /// An entry seeded from a mood's results: the mood, the mix, and every song you kept,
    /// with your thumbs-ups already marked as the ones that stuck.
    @MainActor
    static func from(_ recommendation: Recommendation, keptMix: [MixEntry], liked: (MixEntry) -> Bool,
                     spotifyLinks: [Int: SpotifyTrackRef], youtubeVideos: [Int: YouTubeVideo] = [:]) -> JournalEntry {
        let songs = keptMix.map { entry -> JournalSong in
            let title = entry.track?.name ?? entry.idea.title
            let artist = entry.track?.artist ?? entry.idea.artist
            let link = spotifyLinks[entry.id]
            let target = link.map { ($0.uri, Optional($0.webURL)) } ?? entry.openTarget
            return JournalSong(
                id: "\(title)|\(artist)".matchKey,
                title: title,
                artist: artist,
                imageURL: entry.track?.imageURL ?? link?.imageURL,
                spotifyURI: target.0,
                webURL: target.1,
                stuck: liked(entry),
                youtubeID: youtubeVideos[entry.id]?.id
            )
        }
        return JournalEntry(
            createdAt: recommendation.createdAt,
            updatedAt: Date(),
            mood: recommendation.mood,
            mixName: recommendation.plan.mixName,
            valence: recommendation.plan.valence,
            energy: recommendation.plan.energy,
            // A starting feeling from how Claude read the mood; no extra request.
            feelingIDs: [Feeling.nearest(valence: recommendation.plan.valence, energy: recommendation.plan.energy).id],
            songs: songs,
            recommendationID: recommendation.id
        )
    }
}

/// AES-GCM encryption for the journal file. The 256-bit key lives in the Keychain.
struct JournalCipher: Sendable {
    let key: SymmetricKey

    enum KeyError: LocalizedError {
        case unreadable
        case missing

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "macOS didn't allow access to the journal key. Try again and choose “Always Allow”."
            case .missing:
                "The journal key is missing from the Keychain, so existing entries can't be opened. Nothing was overwritten."
            }
        }
    }

    /// Loads the key. A new key is only ever created when there's no journal yet
    /// (`existingJournal` is nil), so a denied or missing key can never cause existing entries
    /// to be overwritten with a different key.
    ///
    /// A journal from an earlier build may have its key under an older keychain name. Such a
    /// key is only trusted if it actually opens `existingJournal`: any app could create an
    /// item with an old-looking name, and a key it planted must never be used for a journal.
    static func loadKey(account: String = "journal.key", existingJournal: Data?) throws -> SymmetricKey {
        let stored: String?
        do {
            stored = try Keychain.read(account)
        } catch {
            throw KeyError.unreadable
        }
        if let key = stored.flatMap(decodeKey) { return key }

        if let journal = existingJournal {
            let candidates: [String]
            do {
                candidates = try Keychain.legacyValues(account)
            } catch {
                throw KeyError.unreadable
            }
            if let (value, key) = firstKey(in: candidates, opening: journal) {
                Keychain.set(value, for: account)
                return key
            }
            throw KeyError.missing
        }
        let key = SymmetricKey(size: .bits256)
        Keychain.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: account)
        return key
    }

    static func decodeKey(_ stored: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: stored), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// The first candidate that decrypts `journal`. AES-GCM authenticates, so only the key the
    /// journal was really sealed with passes.
    static func firstKey(in candidates: [String], opening journal: Data) -> (String, SymmetricKey)? {
        for value in candidates {
            guard let key = decodeKey(value),
                  (try? JournalCipher(key: key).openData(journal)) != nil else { continue }
            return (value, key)
        }
        return nil
    }

    func seal(_ entries: [JournalEntry]) throws -> Data {
        // Default date encoding keeps full precision, so entries round-trip exactly.
        try sealData(JSONEncoder().encode(entries))
    }

    func open(_ data: Data) throws -> [JournalEntry] {
        try JSONDecoder().decode([JournalEntry].self, from: openData(data))
    }

    func sealData(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return combined
    }

    func openData(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

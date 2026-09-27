import AppKit
import Foundation

/// `MusicJournal --review <state>` opens the app straight into one screen with sample data,
/// so every screen can be captured and checked (see scripts/ui-review.sh). Review mode never
/// plays music, never calls Claude, and uses a throwaway journal, not yours.
@MainActor
enum UIReview {
    static let states = [
        "welcome-0", "welcome-1", "welcome-2", "welcome-3", "welcome-4", "welcome-5",
        "mood", "mood-working", "mood-results", "now-playing",
        "journal", "journal-locked", "zen", "settings",
    ]

    static var requested: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--review"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func configure(_ model: AppModel, state: String) async {
        model.showWelcome = false
        model.taste = .empty
        model.phase = .ready
        model.claudeCheck = .ready
        model.recentMoods = [
            RecentMood(text: "exhausted", date: Date().addingTimeInterval(-3_600 * 2)),
            RecentMood(text: "calm but a little restless", date: Date().addingTimeInterval(-86_400)),
            RecentMood(text: "sunday morning, slow and bright", date: Date().addingTimeInterval(-86_400 * 3)),
        ]

        if state.hasPrefix("welcome-"), let n = Int(state.dropFirst("welcome-".count)) {
            model.welcomeStep = n
            model.showWelcome = true
            return
        }
        switch state {
        case "mood-working":
            model.moodText = "exhausted"
            model.status = .working("Thinking with Claude…")
        case "mood-results", "now-playing":
            model.moodText = "exhausted"
            model.recommendation = sampleRecommendation
            if state == "now-playing", let rec = model.recommendation {
                let items = rec.mix.prefix(6).map {
                    SpotifyQueue.Item(id: "review\($0.id)", title: $0.idea.title, artist: $0.idea.artist, imageURL: nil)
                }
                model.queue.showForReview(Array(items), from: rec.plan.mixName, at: 2)
            }
        case "journal", "journal-locked":
            model.tab = .journal
            let store = await sampleJournal(unlocked: state == "journal")
            model.useJournalForReview(store)
        case "zen":
            model.tab = .zen
        case "settings":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            break
        }
    }

    private static var sampleRecommendation: Recommendation {
        let plan = MoodPlan(
            interpretation: "You're completely worn out on a Saturday night and need soft, warm music that asks nothing of you.",
            energy: 0.25, valence: 0.45,
            keywords: ["worn out", "gentle", "warm", "unwind"],
            ownedPlaylistPicks: [],
            playlistSearchQueries: ["late night wind down", "soft acoustic evening", "calm indie chill", "gentle piano rest"],
            trackSuggestions: [],
            mixName: "Running on Empty, Gently",
            mixDescription: "Soft, restful songs that slowly bring back some warmth."
        )
        let songs: [(String, String, Int?)] = [
            ("Re: Stacks", "Bon Iver", 401_000), ("Tired", "Adele", 258_000),
            ("Fade into You", "Mazzy Star", 295_000), ("Holocene", "Bon Iver", nil),
            ("The Night We Met", "Lord Huron", 208_000), ("Harvest Moon", "Neil Young", 303_000),
            ("Motion Sickness", "Phoebe Bridgers", 229_000), ("Pink Moon", "Nick Drake", 124_000),
        ]
        let mix = songs.enumerated().map { index, song in
            let lookup: TrackLookup = song.2.map {
                .found(TrackSummary(id: "s\(index)", name: song.0, artist: song.1, album: nil, imageURL: nil,
                                    uri: "spotify:search:x", webURL: nil, durationMs: $0, previewURL: nil))
            } ?? .unverified
            return MixEntry(id: index, idea: .init(title: song.0, artist: song.1), lookup: lookup)
        }
        return Recommendation(
            mood: "exhausted", plan: plan, brain: .claude, fallbackReason: nil, fromLibrary: [], discovered: [],
            searchPhrases: plan.playlistSearchQueries, mix: mix, canSaveMix: false, catalogName: "iTunes")
    }

    private static func sampleJournal(unlocked: Bool) async -> JournalStore {
        let cipher = JournalCipher(key: .init(size: .bits256))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mj-review-\(UUID().uuidString)")
        let store = JournalStore(fileURL: url, cipher: { _ in cipher }, authenticate: { .success(()) }, observeSystemEvents: false)
        guard unlocked else { return store }
        await store.unlock()

        let calendar = Calendar.current
        let feelings: [Double?] = [0.3, 0.5, nil, 0.7, 0.9, 0.1, 0.5, 0.7, 0.3, 0.5, 0.9, 0.7, 0.5]
        for (offset, valence) in feelings.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -offset - 1, to: Date()) else { continue }
            store.add(JournalEntry(createdAt: day, text: "A quieter day. Coffee, a long walk, rain later.", valence: valence))
        }
        var today = JournalEntry(
            createdAt: Date().addingTimeInterval(-1_800), mood: "exhausted",
            text: "Long week. Finally slowed down tonight and put on something soft.\nThe rain helped.",
            mixName: "Running on Empty, Gently", valence: 0.3, energy: 0.25)
        today.songs = [
            JournalSong(id: "a", title: "Holocene", artist: "Bon Iver", imageURL: nil, spotifyURI: "spotify:search:x", webURL: nil, stuck: true),
            JournalSong(id: "b", title: "Fade into You", artist: "Mazzy Star", imageURL: nil, spotifyURI: "spotify:search:x", webURL: nil, stuck: true),
            JournalSong(id: "c", title: "Tired", artist: "Adele", imageURL: nil, spotifyURI: "spotify:search:x", webURL: nil, stuck: false),
            JournalSong(id: "d", title: "Harvest Moon", artist: "Neil Young", imageURL: nil, spotifyURI: "spotify:search:x", webURL: nil, stuck: false),
        ]
        store.add(today)
        return store
    }
}

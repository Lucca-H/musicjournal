import Foundation

/// Command-line harness:
///   `MusicJournal --brain-test "<mood>" [claude|apple]` prints the brain's plan.
///   `MusicJournal --brain-test "<mood>" free "Artist A, Artist B"` runs the whole free-mode
///   pipeline (typed artists → Claude → iTunes checks) and prints the mix. Add `links` as a
///   final argument to also run the "Open in Spotify" lookup.
enum BrainTest {
    static func runBlocking(arguments: [String]) {
        let rest = Array(arguments.drop { $0 != "--brain-test" }.dropFirst())
        let mood = rest.first ?? "rainy sunday, a bit melancholy but cozy"
        let which = rest.dropFirst().first ?? "claude"
        let artists = rest.dropFirst(2).first ?? ""
        let withLinks = rest.dropFirst(3).first == "links"

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if which == "free" {
                await runFree(mood: mood, artists: artists, withLinks: withLinks)
            } else {
                await run(mood: mood, which: which)
            }
            done.signal()
        }
        done.wait()
    }

    /// `MusicJournal --resolve-test "Title — Artist" …` runs the Spotify lookup the journal's
    /// Play button uses (search only; nothing plays).
    static func runResolveBlocking(arguments: [String]) {
        let lines = Array(arguments.drop { $0 != "--resolve-test" }.dropFirst())
        let ideas = lines.map { line -> MoodPlan.TrackIdea in
            let ref = SongRef(line: line)
            return .init(title: ref.title, artist: ref.artist ?? "")
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let start = Date()
            do {
                let found = try await SpotifyConnectorResolver().resolve(ideas)
                for (i, idea) in ideas.enumerated() {
                    print("\(idea.title) — \(idea.artist): \(found[i]?.uri ?? "not found")")
                }
            } catch {
                print("error: \(error.localizedDescription)")
            }
            print(String(format: "took %.1fs", Date().timeIntervalSince(start)))
            done.signal()
        }
        done.wait()
    }

    /// `MusicJournal --youtube-test "Title — Artist" …` shows which YouTube video each song
    /// would play (search only; nothing opens).
    static func runYouTubeBlocking(arguments: [String]) {
        let songs = Array(arguments.drop { $0 != "--youtube-test" }.dropFirst()).map { line -> YouTubeFinder.Song in
            let ref = SongRef(line: line)
            return .init(title: ref.title, artist: ref.artist ?? "", seconds: nil)
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let start = Date()
            let found = await YouTubeFinder.find(songs)
            for (i, song) in songs.enumerated() {
                let v = found[i]
                print("\(song.title) — \(song.artist): \(v.map { "\($0.id)  \($0.title)  [\($0.channel)]" } ?? "not found")")
            }
            if let url = YouTubeLinks.queue(songs.indices.compactMap { found[$0]?.id }) { print(url) }
            print(String(format: "took %.1fs", Date().timeIntervalSince(start)))
            done.signal()
        }
        done.wait()
    }

    private static func runFree(mood: String, artists: String, withLinks: Bool) async {
        let names = artists.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let engine = RecommendationEngine(
            catalog: ITunesCatalog(),
            brain: FallbackBrain(primary: ClaudeCLIBrain(), fallback: AppleBrain(), preference: .auto)
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let influence = TasteInfluence(rawValue: ProcessInfo.processInfo.environment["SPOTHELPER_INFLUENCE"] ?? "") ?? .subtle
            let env = ProcessInfo.processInfo.environment
            var personalization = Personalization(artists: names, influence: influence)
            personalization.approach = MoodApproach(rawValue: env["SPOTHELPER_APPROACH"] ?? "") ?? .auto
            personalization.cleanOnly = env["SPOTHELPER_CLEAN"] == "1"
            let rec = try await engine.recommend(mood: mood, taste: .empty, personalization: personalization) { stage in
                print("[\(clock.now - start)] \(stage)")
            }
            print("\n[taste: \(influence.label), mood: \(personalization.approach.label), clean: \(personalization.cleanOnly)] \(rec.plan.mixName): \(rec.plan.interpretation)")
            print("Search phrases: \(rec.searchPhrases.joined(separator: " | "))")
            for entry in rec.mix {
                switch entry.lookup {
                case .found(let t):
                    print("  ✓ \(t.name) — \(t.artist)  [art: \(t.imageURL != nil ? "y" : "n"), preview: \(t.previewURL != nil ? "y" : "n")]")
                case .notFound:
                    print("  ✗ \(entry.idea.title) — \(entry.idea.artist)  (not found)")
                case .unverified:
                    print("  ? \(entry.idea.title) — \(entry.idea.artist)  (not verified)")
                }
            }
            print("elapsed=\(clock.now - start) brain=\(rec.brain.rawValue)")

            if withLinks {
                let linkStart = clock.now
                let ideas = rec.mix.map { entry in
                    entry.track.map { MoodPlan.TrackIdea(title: $0.name, artist: $0.artist) } ?? entry.idea
                }
                let links = try await SpotifyConnectorResolver().resolve(ideas)
                print("\nSpotify links (\(links.count) of \(ideas.count)) in \(clock.now - linkStart):")
                for (index, idea) in ideas.enumerated() {
                    let ref = links[index]
                    print("  \(ref == nil ? "✗" : "✓") \(idea.title) — \(idea.artist)  \(ref.map { "\($0.webURL.absoluteString) [\($0.title ?? "?")]" } ?? "")")
                }
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func run(mood: String, which: String) async {
        let taste = TasteProfileBuilder.cached() ?? sampleTaste
        let brain: any MoodBrain = which == "apple" ? AppleBrain() : ClaudeCLIBrain()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let plan = try await brain.interpret(MoodRequest(mood: mood, taste: taste))
                .sanitized(validPlaylistIDs: Set(taste.playlists.map(\.id)))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            print(String(data: try encoder.encode(plan), encoding: .utf8)!)
            print("brain=\(brain.kind.rawValue) elapsed=\(clock.now - start)")
        } catch {
            print("ERROR (\(brain.kind.rawValue)): \(error.localizedDescription)")
            exit(1)
        }
    }

    static let sampleTaste: TasteProfile = {
        func playlist(_ id: String, _ name: String, _ description: String) -> PlaylistSummary {
            let json = """
            {"id":"\(id)","name":"\(name)","description":"\(description)","uri":"spotify:playlist:\(id)",
             "owner":{"id":"me","display_name":"Me"},"items":{"total":40}}
            """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return PlaylistSummary(try! decoder.decode(Playlist.self, from: Data(json.utf8)), currentUserID: "me")
        }
        return TasteProfile(
            userID: "me",
            displayName: "Sample",
            recentArtists: [
                .init(name: "Phoebe Bridgers", genres: ["indie folk"]),
                .init(name: "Bon Iver", genres: ["indie folk", "chamber pop"]),
                .init(name: "Radiohead", genres: ["alternative rock"]),
                .init(name: "Nujabes", genres: ["jazz hip hop"]),
                .init(name: "Fred again..", genres: ["house"]),
            ],
            longTermArtists: [
                .init(name: "Frank Ocean", genres: ["r&b"]),
                .init(name: "Tame Impala", genres: ["psychedelic pop"]),
            ],
            topTracks: ["Motion Sickness — Phoebe Bridgers", "Holocene — Bon Iver", "Nights — Frank Ocean"],
            recentlyPlayed: ["Aruarian Dance — Nujabes", "Marea (we've lost dancing) — Fred again.."],
            playlists: [
                playlist("pl_focus", "deep work", "instrumental focus"),
                playlist("pl_gym", "LIFT", "loud and fast"),
                playlist("pl_rain", "rain on the window", "soft sad songs for grey days"),
                playlist("pl_summer", "summer 2025", ""),
            ],
            builtAt: Date()
        )
    }()
}

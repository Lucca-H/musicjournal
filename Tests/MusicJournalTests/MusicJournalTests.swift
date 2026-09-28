import CoreText
import CryptoKit
import Foundation
import Testing
import simd
@testable import MusicJournal

private let samplePlanJSON = """
{
  "interpretation": "Slow and wistful.",
  "energy": 1.4,
  "valence": -0.2,
  "keywords": ["rainy", "cozy"],
  "ownedPlaylistPicks": [
    {"id": "pl_rain", "reason": "fits"},
    {"id": "pl_rain", "reason": "duplicate"},
    {"id": "made_up", "reason": "hallucinated"}
  ],
  "playlistSearchQueries": ["rainy day jazz", "Rainy Day Jazz", "  ", "sad indie"],
  "trackSuggestions": [
    {"title": "Holocene", "artist": "Bon Iver"},
    {"title": "holocene", "artist": "bon iver"},
    {"title": "", "artist": "Nobody"}
  ],
  "mixName": "  ",
  "mixDescription": "Grey day songs."
}
"""

@Suite struct MoodPlanTests {
    @Test func decodesAndSanitizes() throws {
        let plan = try JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
        let clean = plan.sanitized(validPlaylistIDs: ["pl_rain", "pl_gym"])

        #expect(clean.energy == 1)
        #expect(clean.valence == 0)
        #expect(clean.ownedPlaylistPicks.map(\.id) == ["pl_rain"])
        #expect(clean.playlistSearchQueries == ["rainy day jazz", "sad indie"])
        #expect(clean.trackSuggestions == [.init(title: "Holocene", artist: "Bon Iver")])
        #expect(clean.mixName == "Mood mix")
    }

    @Test func jsonSchemaIsValidJSONAndCoversEveryField() throws {
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(MoodPrompt.jsonSchema.utf8)) as? [String: Any]
        )
        let required = Set(schema["required"] as? [String] ?? [])
        #expect(required == [
            "interpretation", "energy", "valence", "keywords", "ownedPlaylistPicks",
            "playlistSearchQueries", "trackSuggestions", "mixName", "mixDescription",
        ])
    }

    @Test func appleSchemaBuilds() throws {
        _ = try AppleBrain.makeSchema()
    }
}

@Suite struct PKCETests {
    @Test func matchesRFC7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierUsesUnreservedCharacters() {
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 64)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }
}

@Suite struct ClaudeEnvelopeTests {
    @Test func prefersStructuredOutput() throws {
        let envelope: [String: Any] = [
            "type": "result", "is_error": false, "result": "ignored",
            "structured_output": try JSONSerialization.jsonObject(with: Data(samplePlanJSON.utf8)),
        ]
        let plan = try ClaudeCLI.parseEnvelope(JSONSerialization.data(withJSONObject: envelope), as: MoodPlan.self)
        #expect(plan.interpretation == "Slow and wistful.")
    }

    @Test func fallsBackToFencedResultText() throws {
        let envelope: [String: Any] = [
            "type": "result", "is_error": false,
            "result": "Here you go:\n```json\n\(samplePlanJSON)\n```",
        ]
        let plan = try ClaudeCLI.parseEnvelope(JSONSerialization.data(withJSONObject: envelope), as: MoodPlan.self)
        #expect(plan.keywords == ["rainy", "cozy"])
    }

    @Test func toleratesLeadingNoise() throws {
        let envelope: [String: Any] = [
            "is_error": false,
            "structured_output": try JSONSerialization.jsonObject(with: Data(samplePlanJSON.utf8)),
        ]
        var data = Data("some warning line\n".utf8)
        data.append(try JSONSerialization.data(withJSONObject: envelope))
        #expect(try ClaudeCLI.parseEnvelope(data, as: MoodPlan.self).mixDescription == "Grey day songs.")
    }

    @Test func surfacesErrors() throws {
        let envelope: [String: Any] = ["is_error": true, "result": "Not logged in · Please run /login"]
        #expect(throws: BrainError.failed("Claude Code: Not logged in · Please run /login")) {
            try ClaudeCLI.parseEnvelope(JSONSerialization.data(withJSONObject: envelope), as: MoodPlan.self)
        }
    }
}

private struct StubBrain: MoodBrain {
    let kind: BrainKind
    let result: Result<MoodPlan, BrainError>
    func interpret(_ request: MoodRequest) async throws -> MoodPlan { try result.get() }
}

@Suite struct FallbackBrainTests {
    let plan = try! JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
    let request = MoodRequest(mood: "tired", taste: BrainTest.sampleTaste)

    @Test func usesFallbackWhenClaudeFails() async throws {
        let brain = FallbackBrain(
            primary: StubBrain(kind: .claude, result: .failure(.unavailable("no cli"))),
            fallback: StubBrain(kind: .onDevice, result: .success(plan)),
            preference: .auto
        )
        let result = try await brain.interpret(request)
        #expect(result.brain == .onDevice)
        #expect(result.fallbackReason == "no cli")
    }

    @Test func claudeOnlyDoesNotFallBack() async {
        let brain = FallbackBrain(
            primary: StubBrain(kind: .claude, result: .failure(.timedOut)),
            fallback: StubBrain(kind: .onDevice, result: .success(plan)),
            preference: .claudeOnly
        )
        await #expect(throws: BrainError.timedOut) { try await brain.interpret(request) }
    }

    @Test func reportsBothFailures() async {
        let brain = FallbackBrain(
            primary: StubBrain(kind: .claude, result: .failure(.unavailable("no cli"))),
            fallback: StubBrain(kind: .onDevice, result: .failure(.unavailable("AI off"))),
            preference: .auto
        )
        await #expect(throws: BrainError.failed("Claude: no cli\non-device model: AI off")) {
            try await brain.interpret(request)
        }
    }
}

@Suite struct SpotifyModelTests {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    @Test func playlistAcceptsNewAndOldItemCountFields() throws {
        let new = #"{"id":"a","name":"A","uri":"spotify:playlist:a","items":{"total":12}}"#
        let old = #"{"id":"b","name":"B","uri":"spotify:playlist:b","tracks":{"total":7}}"#
        #expect(try decoder().decode(Playlist.self, from: Data(new.utf8)).itemCount == 12)
        #expect(try decoder().decode(Playlist.self, from: Data(old.utf8)).itemCount == 7)
    }

    @Test func searchPagingDropsNullItems() throws {
        let json = #"""
        {"playlists":{"items":[null,{"id":"a","name":"A","uri":"spotify:playlist:a",
          "description":"Rainy &amp; <a href=\"x\">cozy</a>","owner":{"id":"u","display_name":"U"}}],"next":null,"total":2}}
        """#
        let response = try decoder().decode(SearchResponse.self, from: Data(json.utf8))
        let playlists = try #require(response.playlists?.items)
        #expect(playlists.count == 1)
        #expect(PlaylistSummary(playlists[0], currentUserID: "u").description == "Rainy & cozy")
        #expect(PlaylistSummary(playlists[0], currentUserID: "u").ownedByUser)
    }
}

@Suite struct PromptTests {
    @Test func compactPromptIsSmallerAndTrimsPlaylists() {
        let many = (0..<60).map { i in
            let json = #"{"id":"p\#(i)","name":"Playlist \#(i)","uri":"spotify:playlist:p\#(i)","description":"a fairly long description to pad things out"}"#
            return PlaylistSummary(try! JSONDecoder().decode(Playlist.self, from: Data(json.utf8)), currentUserID: nil)
        }
        let base = BrainTest.sampleTaste
        let taste = TasteProfile(
            userID: base.userID, displayName: nil, recentArtists: base.recentArtists,
            longTermArtists: base.longTermArtists, topTracks: base.topTracks,
            recentlyPlayed: base.recentlyPlayed, playlists: many, builtAt: Date()
        )
        let full = taste.playlistSummary(compact: false)
        let compact = taste.playlistSummary(compact: true)
        #expect(compact.count < full.count / 2)
        #expect(compact.contains("p24 |"))
        #expect(!compact.contains("p25 |"))
    }
}

@Suite struct ConcurrencyTests {
    @Test func concurrentMapPreservesOrder() async throws {
        let result = try await concurrentMap(Array(0..<20), limit: 3) { n in
            try await Task.sleep(for: .milliseconds(Int.random(in: 1...10)))
            return n * 2
        }
        #expect(result == (0..<20).map { $0 * 2 })
    }

    @Test func processRunnerCapturesOutputAndTimesOut() async throws {
        let echo = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], timeout: .seconds(5))
        #expect(String(data: echo.stdout, encoding: .utf8) == "hi\n")

        await #expect(throws: ProcessRunner.TimedOut.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(200))
        }
    }
}

// MARK: - Free mode

@Suite struct TrackMatcherTests {
    private let idea = MoodPlan.TrackIdea(title: "Holocene", artist: "Bon Iver")

    @Test func rejectsCoversByOtherArtists() {
        #expect(!TrackMatcher.matches(wantedTitle: "Holocene", wantedArtist: "Bon Iver",
                                      title: "Holocene", artists: ["Vitamin String Quartet"]))
    }

    @Test func prefersExactTitleOverRemix() {
        let candidates = [
            ("Luv(sic), Pt. 3 (Ta-ku Remix Instrumentals)", "Nujabes"),
            ("Luv(sic.) pt3", "Nujabes"),
        ]
        let best = TrackMatcher.best(candidates, for: .init(title: "Luv(sic.) pt3", artist: "Nujabes"),
                                     title: { $0.0 }, artists: { [$0.1] })
        #expect(best?.0 == "Luv(sic.) pt3")
    }

    @Test func acceptsDecoratedTitles() {
        #expect(TrackMatcher.matches(wantedTitle: "Heroes", wantedArtist: "David Bowie",
                                     title: "\"Heroes\" - 2017 Remaster", artists: ["David Bowie"]))
        #expect(TrackMatcher.matches(wantedTitle: "Feather", wantedArtist: "Nujabes",
                                     title: "Feather (feat. Cise Starr & Akin)", artists: ["Nujabes"]))
    }

    @Test func fallsBackToBaseTitleForLookalikeCharacters() {
        #expect(TrackMatcher.matches(wantedTitle: "715 - CRΣΣKS", wantedArtist: "Bon Iver",
                                     title: "715 - CR∑∑KS", artists: ["Bon Iver"]))
    }

    @Test func rejectsDifferentSongs() {
        #expect(!TrackMatcher.matches(wantedTitle: "Emotion Sickness", wantedArtist: "Julien Baker",
                                      title: "Sprained Ankle", artists: ["Julien Baker"]))
    }
}

@Suite struct ITunesTests {
    private let fixture = #"""
    {"resultCount":4,"results":[
      {"trackId":1,"trackName":"Holocene","artistName":"Vitamin String Quartet","artworkUrl100":"https://a/100x100bb.jpg"},
      {"trackId":2,"trackName":"Skinny Love","artistName":"Bon Iver"},
      {"trackId":3,"trackName":"Holocene (Live)","artistName":"Bon Iver"},
      {"trackId":4,"trackName":"Holocene","artistName":"Bon Iver","collectionName":"Bon Iver",
       "artworkUrl100":"https://is1.mzstatic.com/x/100x100bb.jpg","previewUrl":"https://audio/p.m4a","trackTimeMillis":336000}
    ]}
    """#

    @Test func picksTheOriginalAndBuildsSpotifyLinks() throws {
        let track = try #require(try ITunesCatalog.bestMatch(in: Data(fixture.utf8), for: .init(title: "Holocene", artist: "Bon Iver")))
        #expect(track.id == "itunes:4")
        #expect(track.imageURL?.absoluteString == "https://is1.mzstatic.com/x/200x200bb.jpg")
        #expect(track.previewURL?.absoluteString == "https://audio/p.m4a")
        #expect(track.durationMs == 336000)
        #expect(track.uri == "spotify:search:Holocene%20Bon%20Iver")
        #expect(track.webURL?.absoluteString == "https://open.spotify.com/search/Holocene%20Bon%20Iver")
    }

    @Test func returnsNilWhenOnlyCoversExist() throws {
        #expect(try ITunesCatalog.bestMatch(in: Data(fixture.utf8), for: .init(title: "Two Weeks", artist: "FKA twigs")) == nil)
    }

    @Test func spotifySearchLinksEscapeEverything() {
        let link = SpotifyLinks.search("sad & slow / rain?")
        #expect(link.uri == "spotify:search:sad%20%26%20slow%20%2F%20rain%3F")
    }
}

@Suite struct PersonalizationTests {
    private func prompt(_ p: Personalization, taste: TasteProfile = .empty) -> String {
        MoodPrompt.user(MoodRequest(mood: "exhausted", taste: taste, personalization: p), compact: false)
    }

    @Test func noProfileMeansMoodOnly() {
        let text = prompt(Personalization())
        #expect(text.contains("Taste guidance: none. Choose by the mood alone."))
        #expect(text.contains("an empty ownedPlaylistPicks list"))
    }

    @Test func offIgnoresTasteButKeepsNotForMe() {
        let text = prompt(Personalization(artists: ["The Velvet Hours"], influence: .off, avoid: ["country"]))
        #expect(!text.contains("The Velvet Hours"))
        #expect(text.contains("Taste guidance: none"))
        #expect(text.contains("Not for me (never suggest these artists or genres): country"))
    }

    @Test func subtleIsAHintAndStrongLeansIn() {
        let subtle = prompt(Personalization(artists: ["The Velvet Hours"], songs: ["Lantern — Harbor Lights"], influence: .subtle))
        #expect(subtle.contains("Taste guidance (subtle): Use this only as a light hint"))
        #expect(subtle.contains("Artists they like: The Velvet Hours"))
        #expect(subtle.contains("Favourite songs: Lantern — Harbor Lights"))
        let strong = prompt(Personalization(artists: ["The Velvet Hours"], influence: .strong))
        #expect(strong.contains("Taste guidance (strong): Lean on this"))
    }

    @Test func spotifyHistoryIsTasteGatedButPlaylistsAreNot() {
        let taste = BrainTest.sampleTaste
        let off = prompt(Personalization(influence: .off), taste: taste)
        #expect(!off.contains("Top artists lately"))
        #expect(off.contains("rain on the window"))       // library picks still possible
        let subtle = prompt(Personalization(influence: .subtle), taste: taste)
        #expect(subtle.contains("Top artists lately: Phoebe Bridgers"))
    }

    @Test func listsParseCommasAndLines() {
        #expect(Personalization.list(from: "a, b\nc,, A") == ["a", "b", "c"])
        #expect(Personalization.list(from: "Luv(sic), Pt. 3 — Nujabes\nLantern", commas: false) == ["Luv(sic), Pt. 3 — Nujabes", "Lantern"])
    }

    @Test func songRefsParseAndMatch() {
        #expect(SongRef(line: "Lantern — Harbor Lights") == SongRef(title: "Lantern", artist: "Harbor Lights"))
        #expect(SongRef(line: "Tidewater by Harbor Lights") == SongRef(title: "Tidewater", artist: "Harbor Lights"))
        #expect(SongRef(line: "Long Way Home") == SongRef(title: "Long Way Home", artist: nil))
        let lantern = SongRef(line: "Lantern — Harbor Lights")
        #expect(lantern.matches(title: "lantern", artist: "The Harbor Lights"))
        #expect(!lantern.matches(title: "Lantern", artist: "Hozier"))          // same title, different song
        #expect(SongRef(line: "Lantern").matches(title: "Lantern", artist: "Anyone"))
    }

    @Test func excludedSongsDependOnInfluence() {
        var p = Personalization(songs: ["Lantern — Harbor Lights"], skippedSongs: ["Nikes — Frank Ocean"])
        p.influence = .subtle
        #expect(p.excludedSongs.map(\.title) == ["Nikes", "Lantern"])
        p.influence = .strong
        #expect(p.excludedSongs.map(\.title) == ["Nikes"])
        p.influence = .off
        #expect(p.excludedSongs.map(\.title) == ["Nikes"])
    }

    @Test func sanitizeCapsArtistsDropsExcludedAndLimitsLength() throws {
        var plan = try JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
        plan.trackSuggestions = [
            .init(title: "A", artist: "The Velvet Hours"), .init(title: "B", artist: "The Velvet Hours"),
            .init(title: "C", artist: "the velvet hours"), .init(title: "Lantern", artist: "Harbor Lights"),
            .init(title: "Lantern", artist: "Hozier"), .init(title: "D", artist: "Other"), .init(title: "E", artist: "Other 2"),
        ]
        let clean = plan.sanitized(validPlaylistIDs: [], excluded: [SongRef(line: "Lantern — Harbor Lights")], maxTracks: 4)
        #expect(clean.trackSuggestions.map { "\($0.title)/\($0.artist)" } == ["A/The Velvet Hours", "B/The Velvet Hours", "Lantern/Hozier", "D/Other"])
    }

    @Test func preferencesAlwaysApplyEvenWithTasteOff() {
        let p = Personalization(artists: ["The Velvet Hours"], influence: .off, approach: .lift, discovery: .discover,
                                vocals: .instrumental, cleanOnly: true, mixLength: 15, skippedSongs: ["Nikes — Frank Ocean"])
        let text = prompt(p)
        #expect(!text.contains("The Velvet Hours"))
        #expect(text.contains("Gently lift the mood"))
        #expect(text.contains("Favour lesser-known songs"))
        #expect(text.contains("Mostly instrumental tracks."))
        #expect(text.contains("Only clean songs"))
        #expect(text.contains("Never suggest these songs: Nikes — Frank Ocean"))
        #expect(text.contains("about 15 trackSuggestions"))
    }

    @Test func likedSongsErasAndLanguagesAreTasteGated() {
        let p = Personalization(eras: ["90s"], languages: ["Spanish"], likedSongs: ["Holocene — Bon Iver"], influence: .subtle)
        let text = prompt(p)
        #expect(text.contains("Eras they like: 90s"))
        #expect(text.contains("Languages they enjoy: Spanish"))
        #expect(text.contains("Songs they liked in earlier mixes"))
        var off = p
        off.influence = .off
        #expect(!prompt(off).contains("Spanish"))
    }

    @Test func oldCachedProfilesStillDecode() throws {
        let json = #"{"userID":"u","recentArtists":[],"longTermArtists":[],"topTracks":[],"recentlyPlayed":[],"playlists":[],"builtAt":0,"selfReported":true}"#
        _ = try JSONDecoder().decode(TasteProfile.self, from: Data(json.utf8))
    }
}

private struct StubCatalog: MusicCatalog {
    let name = "iTunes"
    let listsPlaylists = false
    let lookupConcurrency = 2
    let results: [String: TrackLookup]

    func discoverPlaylists(queries: [String], excluding: Set<String>) async throws -> [PickedPlaylist] { [] }
    func lookup(_ idea: MoodPlan.TrackIdea) async -> TrackLookup { results[idea.title] ?? .unverified }
}

@Suite struct EngineTests {
    private func track(_ id: String) -> TrackSummary {
        TrackSummary(id: id, name: id, artist: "A", album: nil, imageURL: nil,
                     uri: "spotify:search:\(id)", webURL: nil, durationMs: nil, previewURL: nil)
    }

    @Test func freeModeShowsSearchPhrasesAndDropsDuplicateSongs() async throws {
        var plan = try JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
        plan.trackSuggestions = [.init(title: "One", artist: "A"), .init(title: "One (Remaster)", artist: "A"), .init(title: "Two", artist: "B")]
        let engine = RecommendationEngine(
            catalog: StubCatalog(results: ["One": .found(track("one")), "One (Remaster)": .found(track("one"))]),
            brain: FallbackBrain(
                primary: StubBrain(kind: .claude, result: .success(plan)),
                fallback: StubBrain(kind: .onDevice, result: .failure(.unavailable("off"))),
                preference: .auto
            )
        )
        let rec = try await engine.recommend(mood: "tired", taste: .empty) { _ in }

        #expect(rec.searchPhrases == ["rainy day jazz", "sad indie"])
        #expect(rec.discovered.isEmpty && rec.fromLibrary.isEmpty)
        #expect(!rec.canSaveMix)
        #expect(rec.catalogName == "iTunes")
        #expect(rec.mix.map(\.idea.title) == ["One", "Two"])
        #expect(rec.mix[1].lookup == .unverified)
        #expect(rec.mix[1].openTarget.uri == "spotify:search:Two%20B")
    }
}

@Suite struct SpotifyConnectorTests {
    @Test func keepsOnlyWellFormedTrackURIsForKnownIndices() {
        let response = SpotifyConnectorResolver.Response(tracks: [
            .init(index: 0, uri: "spotify:track:35KiiILklye1JRRctaLUb4"),
            .init(index: 0, uri: "spotify:track:7E66uxFz2NtHWAyiGXotha"),   // duplicate index: first wins
            .init(index: 1, uri: nil),
            .init(index: 2, uri: "spotify:album:2LpfNj3vB5rOXfaawLcOBg"),   // not a track
            .init(index: 3, uri: "spotify:track:short"),                    // malformed id
            .init(index: 9, uri: "spotify:track:19YKaevk2bce4odJkP5L22"),   // out of range
        ])
        #expect(SpotifyConnectorResolver.trackIDs(from: response, count: 4) == [0: "35KiiILklye1JRRctaLUb4"])
    }

    @Test func promptNumbersSongsFromZero() {
        let prompt = SpotifyConnectorResolver.prompt(for: [
            .init(title: "Holocene", artist: "Bon Iver"), .init(title: "Nikes", artist: "Frank Ocean"),
        ])
        #expect(prompt == "0. Holocene — Bon Iver\n1. Nikes — Frank Ocean")
    }

    @Test func schemaIsValidJSON() throws {
        _ = try JSONSerialization.jsonObject(with: Data(SpotifyConnectorResolver.schema.utf8))
    }

    @Test func titleOnlyMatching() {
        #expect(TrackMatcher.titlesMatch("Feather", "Feather (feat. Cise Starr & Akin)"))
        #expect(!TrackMatcher.titlesMatch("Holocene", "Skinny Love"))
    }

    @Test func trackRefLinks() {
        let ref = SpotifyTrackRef(id: "35KiiILklye1JRRctaLUb4", title: nil, imageURL: nil)
        #expect(ref.uri == "spotify:track:35KiiILklye1JRRctaLUb4")
        #expect(ref.webURL.absoluteString == "https://open.spotify.com/track/35KiiILklye1JRRctaLUb4")
    }
}

// MARK: - Regression tests from the bug review

@Suite struct ReviewRegressionTests {
    @Test func skippedSongMatchesDecoratedAndPlainTitles() {
        let skipped = SongRef(line: "Feather (feat. Cise Starr & Akin) — Nujabes")
        #expect(skipped.matches(title: "Feather", artist: "Nujabes"))
        #expect(SongRef(line: "Feather — Nujabes").matches(title: "Feather (feat. Cise Starr & Akin)", artist: "Nujabes"))
        #expect(!SongRef(line: "Nikes — Frank Ocean").matches(title: "Nikes on My Feet", artist: "Frank Ocean"))
    }

    @Test func subtleAlsoExcludesLikedSongs() {
        let p = Personalization(likedSongs: ["Holocene — Bon Iver"], influence: .subtle)
        #expect(p.excludedSongs.contains(SongRef(title: "Holocene", artist: "Bon Iver")))
        var strong = p
        strong.influence = .strong
        #expect(strong.excludedSongs.isEmpty)
    }

    @Test func listsAreNotCappedSoNewestFeedbackCounts() {
        let text = (1...100).map { "Song \($0) — Artist" }.joined(separator: "\n")
        let list = Personalization.list(from: text, commas: false)
        #expect(list.count == 100)
        let p = Personalization(skippedSongs: list)
        #expect(p.excludedSongs.contains(SongRef(title: "Song 100", artist: "Artist")))
    }

    @Test func subtleCapsSongsByYourArtistsAtThree() throws {
        var plan = try JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
        plan.trackSuggestions = [
            .init(title: "A", artist: "The Velvet Hours"), .init(title: "B", artist: "lumen drive"),
            .init(title: "C", artist: "The Velvet Hours"), .init(title: "D", artist: "Other"),
            .init(title: "E", artist: "lumen drive"), .init(title: "F", artist: "Else"),
        ]
        let clean = plan.sanitized(validPlaylistIDs: [], favouriteArtists: ["the velvet hours", "Lumen Drive"], maxFromFavourites: 3)
        #expect(clean.trackSuggestions.map(\.title) == ["A", "B", "C", "D", "F"])
    }

    @Test func processRunnerDoesNotLaunchWhenAlreadyCancelled() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .seconds(10))
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func processRunnerStopsWhenCancelledMidRun() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .seconds(10))
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        #expect(clock.now - start < .seconds(2))
    }

    @MainActor
    @Test func thumbsDownRemovesSongFromKeptMixAndToggles() throws {
        let model = AppModel()
        let savedLiked = model.likedSongsText, savedSkipped = model.skippedSongsText
        defer { model.likedSongsText = savedLiked; model.skippedSongsText = savedSkipped }
        model.likedSongsText = ""
        model.skippedSongsText = ""

        let plan = try JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
        let entries = [
            MixEntry(id: 0, idea: .init(title: "Holocene", artist: "Bon Iver"), lookup: .unverified),
            MixEntry(id: 1, idea: .init(title: "Nikes", artist: "Frank Ocean"), lookup: .unverified),
        ]
        model.recommendation = Recommendation(
            mood: "tired", plan: plan, brain: .claude, fallbackReason: nil, fromLibrary: [], discovered: [],
            searchPhrases: [], mix: entries, canSaveMix: false, catalogName: "iTunes")

        model.toggleFeedback(.skipped, for: entries[1])
        #expect(model.feedback(for: entries[1]) == .skipped)
        #expect(model.keptMix.map(\.id) == [0])

        // Liking a skipped song replaces the skip; pressing it again clears it.
        model.toggleFeedback(.liked, for: entries[1])
        #expect(model.feedback(for: entries[1]) == .liked)
        #expect(model.skippedSongsText.isEmpty)
        model.toggleFeedback(.liked, for: entries[1])
        #expect(model.feedback(for: entries[1]) == nil)
        #expect(model.keptMix.count == 2)
    }
}

@Suite struct TimeAndHistoryTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(weekdayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
        // 2026-09-25 is a Friday.
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 25 + weekdayOffset, hour: hour, minute: minute))!
    }

    @Test func specificPartsOfDay() {
        #expect(TimeOfDay.describe(date(hour: 6), calendar: calendar) == "Friday early morning")
        #expect(TimeOfDay.describe(date(weekdayOffset: 1, hour: 18), calendar: calendar) == "Saturday early evening")
        #expect(TimeOfDay.describe(date(weekdayOffset: 1, hour: 20), calendar: calendar) == "Saturday evening")
        #expect(TimeOfDay.describe(date(weekdayOffset: 1, hour: 22), calendar: calendar) == "Saturday night")
        #expect(TimeOfDay.describe(date(weekdayOffset: 2, hour: 1), calendar: calendar) == "Sunday late night")
        #expect(TimeOfDay.describe(date(hour: 16), calendar: calendar) == "Friday late afternoon")
    }

    @Test func everyHourHasAPart() {
        #expect((0..<24).allSatisfy { !TimeOfDay.part(forHour: $0).isEmpty })
        #expect(TimeOfDay.part(forHour: 4) == "small hours")
        #expect(TimeOfDay.part(forHour: 12) == "midday")
    }

    @Test func promptIncludesTimeOfDay() {
        let request = MoodRequest(mood: "tired", taste: .empty, date: date(hour: 6))
        // The prompt uses the Mac's own calendar and time zone.
        #expect(MoodPrompt.user(request, compact: false).contains("(\(TimeOfDay.describe(request.date)))"))
    }

    @Test func songListsAcceptSemicolons() {
        #expect(Personalization.list(from: "Lantern — Harbor Lights; Tidewater — Harbor Lights", commas: false)
                == ["Lantern — Harbor Lights", "Tidewater — Harbor Lights"])
        #expect(Personalization.list(from: "Luv(sic), Pt. 3 — Nujabes", commas: false) == ["Luv(sic), Pt. 3 — Nujabes"])
    }

    @Test func recentMoodsLoadLegacyStringsAndRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "MusicJournalTests-\(UUID().uuidString)"))
        defaults.set(["exhausted", "holding on"], forKey: "legacy")
        let legacy = RecentMood.load(from: defaults, key: "history", legacyKey: "legacy")
        #expect(legacy.map(\.text) == ["exhausted", "holding on"])
        #expect(legacy.allSatisfy { $0.date == nil && $0.relativeTime() == nil })

        let now = Date()
        RecentMood.save([RecentMood(text: "calm", date: now)], to: defaults, key: "history")
        let loaded = RecentMood.load(from: defaults, key: "history", legacyKey: "legacy")
        #expect(loaded == [RecentMood(text: "calm", date: now)])
        #expect(loaded[0].relativeTime(now: now) == "just now")
        #expect(loaded[0].relativeTime(now: now.addingTimeInterval(7200)) != nil)
    }
}

// MARK: - Journal

@Suite struct JournalCipherTests {
    @Test func roundTripsAndHidesPlaintext() throws {
        let cipher = JournalCipher(key: .init(size: .bits256))
        let entry = JournalEntry(mood: "exhausted", text: "a secret thought")
        let sealed = try cipher.seal([entry])
        #expect(String(data: sealed, encoding: .utf8)?.contains("secret") != true)
        #expect(try cipher.open(sealed) == [entry])
    }

    @Test func wrongKeyCannotOpen() throws {
        let sealed = try JournalCipher(key: .init(size: .bits256)).seal([JournalEntry(text: "x")])
        #expect(throws: (any Error).self) { try JournalCipher(key: .init(size: .bits256)).open(sealed) }
    }

    @Test func titleFallsBackFromTextToMood() {
        #expect(JournalEntry(mood: "tired", text: "\nFirst line\nmore").title == "First line")
        #expect(JournalEntry(mood: "tired").title == "tired")
        #expect(JournalEntry().title == "Untitled entry")
    }
}

@MainActor
@Suite struct JournalStoreTests {
    private let key = JournalCipher(key: .init(size: .bits256))

    private func makeStore(_ url: URL, allow: Bool = true) -> JournalStore {
        let cipher = key
        return JournalStore(
            fileURL: url, cipher: { _ in cipher },
            authenticate: { allow ? .success(()) : .failure(CancellationError()) },
            observeSystemEvents: false)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sealed")
    }

    @Test func startsLockedAndStaysLockedWhenAuthFails() async {
        let store = makeStore(tempURL(), allow: false)
        #expect(store.isLocked)
        await store.unlock()
        #expect(store.isLocked)
        #expect(store.lastError != nil)
    }

    @Test func savesEncryptedAndReloadsAfterLock() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore(url)
        await store.unlock()
        #expect(!store.isLocked && store.entries.isEmpty)

        let id = store.add(JournalEntry(mood: "calm"))
        store.update(id) { $0.text = "private words" }
        store.lock()                       // flushes before forgetting
        #expect(store.isLocked && store.entries.isEmpty)

        let raw = try Data(contentsOf: url)
        #expect(String(data: raw, encoding: .utf8)?.contains("private") != true)

        let reopened = makeStore(url)
        await reopened.unlock()
        #expect(reopened.entries.map(\.text) == ["private words"])
        #expect(reopened.selectedID == id)
    }

    @Test func lockedStoreNeverOverwritesTheFile() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore(url)
        await store.unlock()
        store.add(JournalEntry(text: "keep me"))
        store.lock()
        store.flush()                      // locked: must be a no-op
        let reopened = makeStore(url)
        await reopened.unlock()
        #expect(reopened.entries.map(\.text) == ["keep me"])
    }

    @Test func deleteMovesSelectionAndGroupsByDay() async {
        let store = makeStore(tempURL())
        await store.unlock()
        let older = store.add(JournalEntry(createdAt: Date().addingTimeInterval(-86_400 * 2), text: "older"))
        let newer = store.add(JournalEntry(text: "newer"))
        #expect(store.entriesByDay.count == 2)
        #expect(store.entriesByDay.first?.entries.first?.id == newer)
        store.delete(newer)
        #expect(store.selectedID == older)
    }

    @Test func entryFromRecommendationMarksLikedSongsAsStuck() throws {
        let plan = try JSONDecoder().decode(MoodPlan.self, from: Data(samplePlanJSON.utf8))
        let mix = [
            MixEntry(id: 0, idea: .init(title: "Holocene", artist: "Bon Iver"), lookup: .unverified),
            MixEntry(id: 1, idea: .init(title: "Nikes", artist: "Frank Ocean"), lookup: .unverified),
        ]
        let rec = Recommendation(
            mood: "tired", plan: plan, brain: .claude, fallbackReason: nil, fromLibrary: [], discovered: [],
            searchPhrases: [], mix: mix, canSaveMix: false, catalogName: "iTunes")
        let entry = JournalEntry.from(rec, keptMix: mix, liked: { $0.id == 1 }, spotifyLinks: [:])
        #expect(entry.mood == "tired")
        #expect(entry.recommendationID == rec.id)
        #expect(entry.stuckSongs.map(\.title) == ["Nikes"])
        #expect(entry.feelingIDs?.count == 1)          // starting feeling from the mood's reading
        #expect(entry.songs.count == 2)
    }
}

@MainActor
@Suite struct JournalFeelingTests {
    private func store() -> JournalStore {
        let cipher = JournalCipher(key: .init(size: .bits256))
        return JournalStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)"),
            cipher: { _ in cipher }, authenticate: { .success(()) }, observeSystemEvents: false)
    }

    @Test func fourteenDistinctFeelings() {
        #expect(Feeling.all.count == 14)
        #expect(Set(Feeling.all.map(\.id)).count == 14)
        let colours = Set(Feeling.all.map { "\($0.red),\($0.green),\($0.blue)" })
        #expect(colours.count == 14)
    }

    @Test func nearestFeelingUsesValenceAndEnergy() {
        #expect(Feeling.nearest(valence: 0.95, energy: 0.75).id == "joyful")
        #expect(Feeling.nearest(valence: 0.1, energy: 0.95).id == "angry")
        #expect(Feeling.nearest(valence: 0.4, energy: 0.05).id == "tired")
        #expect(Feeling.nearest(valence: 0.1).id == "angry" || Feeling.nearest(valence: 0.1).valence <= 0.15)
    }

    @Test func olderEntriesMapTheirValenceToAFeeling() {
        #expect(JournalEntry(valence: 0.9).feelings.count == 1)
        #expect(JournalEntry(valence: 0.9, feelingIDs: ["sad", "hopeful"]).feelings.map(\.id) == ["sad", "hopeful"])
        #expect(JournalEntry().feelings.isEmpty)
    }

    @Test func dayFeelingsAreMostFrequentFirst() async {
        let journal = store()
        await journal.unlock()
        // Anchor at midday so the test doesn't depend on the time it runs.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterday = noon.addingTimeInterval(-86_400)
        journal.add(JournalEntry(createdAt: noon.addingTimeInterval(-300), text: "a", feelingIDs: ["tired", "calm"]))
        journal.add(JournalEntry(createdAt: noon.addingTimeInterval(-200), text: "b", feelingIDs: ["calm"]))
        journal.add(JournalEntry(createdAt: noon.addingTimeInterval(-100), text: "c", feelingIDs: ["joyful", "loved", "sad"]))
        journal.add(JournalEntry(createdAt: yesterday, text: "y", feelingIDs: ["lonely"]))
        let today = journal.feelings(on: noon).map(\.id)
        #expect(today.count == 3)
        #expect(today.first == "calm")                   // appears twice
        #expect(journal.feelings(on: yesterday).map(\.id) == ["lonely"])
        #expect(journal.feelings(on: noon.addingTimeInterval(-86_400 * 6)).isEmpty)
    }

    @Test func suggestionOnlyKeepsKnownFeelings() {
        #expect(FeelingPrompt.validIDs(["Tired", "made-up", "tired", "hopeful", "calm", "sad"]) == ["tired", "hopeful", "calm"])
        let schema = try? JSONSerialization.jsonObject(with: Data(FeelingPrompt.schema.utf8))
        #expect(schema != nil)
        #expect(FeelingPrompt.user(text: "long day", mood: "exhausted").contains("Allowed feelings: joyful"))
    }

    @Test func todayOpensExistingOrStartsNew() async {
        let journal = store()
        await journal.unlock()
        journal.openToday()
        #expect(journal.entries.count == 1)
        let first = journal.selectedID
        journal.selectedID = nil
        journal.openToday()
        #expect(journal.entries.count == 1)
        #expect(journal.selectedID == first)
    }
}

@MainActor
@Suite struct JournalKeySafetyTests {
    @Test func unreadableKeyNeverOverwritesExistingJournal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let good = JournalCipher(key: .init(size: .bits256))
        let writer = JournalStore(fileURL: url, cipher: { _ in good }, authenticate: { .success(()) }, observeSystemEvents: false)
        await writer.unlock()
        writer.add(JournalEntry(text: "precious"))
        writer.lock()
        let before = try Data(contentsOf: url)

        // Simulates macOS denying Keychain access after a rebuild.
        let denied = JournalStore(
            fileURL: url,
            cipher: { existing in
                if existing != nil { throw JournalCipher.KeyError.unreadable }
                return JournalCipher(key: .init(size: .bits256))
            },
            authenticate: { .success(()) }, observeSystemEvents: false)
        await denied.unlock()
        #expect(denied.isLocked)
        #expect(denied.lastError?.contains("Always Allow") == true)
        #expect(try Data(contentsOf: url) == before)

        let reader = JournalStore(fileURL: url, cipher: { _ in good }, authenticate: { .success(()) }, observeSystemEvents: false)
        await reader.unlock()
        #expect(reader.entries.map(\.text) == ["precious"])
    }
}

@Suite struct RebrandMigrationTests {
    @Test func findsEarlierAppIDsByTheirEndingNewestFirst() {
        let files = ["a.b.spothelper.plist", "com.apple.finder.plist", "x.y.musicjournal.plist",
                     "com.musicjournal.app.plist", "notes.musicjournal.txt"]
        #expect(LegacyMigration.legacyDomains(in: files, currentID: "com.musicjournal.app")
                == ["x.y.musicjournal", "a.b.spothelper"])
    }

    @Test func movesOldDataAndCopiesSettingsOnce() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("mj-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let oldDir = base.appendingPathComponent("SpotHelper")
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("sealed".utf8).write(to: oldDir.appendingPathComponent("journal.sealed"))
        let defaults = try #require(UserDefaults(suiteName: "mj-\(UUID().uuidString)"))
        defaults.set("new value", forKey: "profileArtists")

        LegacyMigration.run(
            defaults: defaults,
            oldSettings: ["profileArtists": "old value", "tasteInfluence": "strong", "NSWindow Frame x": "junk"],
            baseDirectory: base)

        #expect(try Data(contentsOf: base.appendingPathComponent("MusicJournal/journal.sealed")) == Data("sealed".utf8))
        #expect(!fm.fileExists(atPath: oldDir.path))
        #expect(defaults.string(forKey: "profileArtists") == "new value")     // never overwrites
        #expect(defaults.string(forKey: "tasteInfluence") == "strong")
        #expect(defaults.object(forKey: "NSWindow Frame x") == nil)

        // Runs once: a later old folder is left alone.
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        LegacyMigration.run(defaults: defaults, oldSettings: ["cleanOnly": true], baseDirectory: base)
        #expect(fm.fileExists(atPath: oldDir.path))
        #expect(defaults.object(forKey: "cleanOnly") == nil)
    }
}

// MARK: - Spotify queue

@MainActor
@Suite struct NowPlayingTests {
    @Test func progressMovesSmoothlyBetweenChecksAndStopsAtTheEnd() {
        let queue = SpotifyQueue()
        queue.showForReview([.init(id: "a", title: "A", artist: "X", imageURL: nil)], from: "Mix", at: 0)
        let read = queue.positionReadAt
        #expect(abs(queue.displayedPosition(at: read.addingTimeInterval(10)) - 84) < 0.01)
        #expect(queue.displayedPosition(at: read.addingTimeInterval(10_000)) == queue.duration)
    }

    @Test func nextSongIsStartedASecondBeforeTheEnd() {
        // Far from the end: wait for a later check.
        #expect(SpotifyQueue.earlyStartDelay(position: 100, duration: 200, isPlaying: true) == nil)
        // Within reach of the next check: start exactly one second before the end.
        #expect(SpotifyQueue.earlyStartDelay(position: 197, duration: 200, isPlaying: true) == 2)
        #expect(SpotifyQueue.earlyStartDelay(position: 199.5, duration: 200, isPlaying: true) == 0)
        // Paused, finished, or no length known: never.
        #expect(SpotifyQueue.earlyStartDelay(position: 198, duration: 200, isPlaying: false) == nil)
        #expect(SpotifyQueue.earlyStartDelay(position: 200, duration: 200, isPlaying: true) == nil)
        #expect(SpotifyQueue.earlyStartDelay(position: 0, duration: 0, isPlaying: true) == nil)
    }

    @Test func repeatModesDecideWhatPlaysNext() {
        #expect(QueueOrder.next(after: 1, count: 3, repeat: .off, songEnded: true) == 2)
        #expect(QueueOrder.next(after: 2, count: 3, repeat: .off, songEnded: true) == nil)   // mix over
        #expect(QueueOrder.next(after: 2, count: 3, repeat: .all, songEnded: true) == 0)     // wraps
        #expect(QueueOrder.next(after: 1, count: 3, repeat: .one, songEnded: true) == 1)     // same song
        #expect(QueueOrder.next(after: 1, count: 3, repeat: .one, songEnded: false) == 2)    // Next still moves on
        #expect(QueueOrder.next(after: 2, count: 3, repeat: .one, songEnded: false) == 0)
    }

    @Test func shuffleKeepsWhatsPlayedAndCurrentInPlace() {
        var rng = SystemRandomNumberGenerator()
        let items = Array(0..<20)
        let (shuffled, index) = QueueOrder.shuffled(items, keeping: 4, using: &rng)
        #expect(index == 4)
        #expect(Array(shuffled[...4]) == [0, 1, 2, 3, 4])
        #expect(Set(shuffled) == Set(items) && shuffled.count == items.count)
    }

    @Test func recognisesItsOwnSongIncludingRelinks() {
        var tracker = QueueTracker(expectedID: "ours", expectedTitle: "Holocene", previousURI: "spotify:track:before")
        #expect(tracker.isOurs(PlayerObservation(trackURI: "spotify:track:ours")))
        #expect(!tracker.isOurs(PlayerObservation(trackURI: "spotify:track:relinked", name: "Holocene")))
        _ = tracker.observe(PlayerObservation(trackURI: "spotify:track:relinked", position: 1, durationMs: 200_000, name: "Holocene"))
        #expect(tracker.isOurs(PlayerObservation(trackURI: "spotify:track:relinked", name: "Holocene")))
    }
}

@Suite struct QueueTrackerTests {
    private let ours = "spotify:track:aaaaaaaaaaaaaaaaaaaaaa"
    private func obs(_ uri: String, _ position: Double, state: String = "playing", duration: Double = 200_000) -> PlayerObservation {
        PlayerObservation(running: true, state: state, trackURI: uri, position: position, durationMs: duration)
    }

    @Test func waitsWhilePlayingThenAdvancesWhenSpotifyAutoplaysSomethingElse() {
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa")
        #expect(t.observe(obs(ours, 10)) == .wait)
        #expect(t.observe(obs(ours, 198)) == .wait)
        #expect(t.observe(obs("spotify:track:other", 1)) == .advance)
    }

    @Test func advancesWhenSpotifyStopsAtTheEndOfOurSong() {
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa")
        _ = t.observe(obs(ours, 197.5))
        #expect(t.observe(obs(ours, 0, state: "paused")) == .advance)

        var u = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa")
        _ = u.observe(obs(ours, 150))
        #expect(u.observe(obs(ours, 199.6, state: "paused")) == .advance)
    }

    @Test func pausingMidSongJustWaits() {
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa")
        _ = t.observe(obs(ours, 60))
        #expect(t.observe(obs(ours, 61, state: "paused")) == .wait)
        #expect(t.observe(obs(ours, 61, state: "paused")) == .wait)
    }

    @Test func aDifferentSongMidwayIsReportedAsAChangeInSpotify() {
        // Spotify's Next button or a media key; the queue skips (or steps aside if repeated).
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa")
        _ = t.observe(obs(ours, 60))
        #expect(t.observe(obs("spotify:track:other", 5)) == .changedInSpotify)
    }

    @Test func adsAreWaitedOut() {
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa")
        _ = t.observe(obs(ours, 60))
        #expect(t.observe(obs("spotify:ad:123", 5)) == .wait)
        #expect(t.observe(obs(ours, 61)) == .wait)
    }

    @Test func skipsASongSpotifyNeverStarts() {
        // The previous song keeps playing: our request never took effect.
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa", previousURI: "spotify:track:previous")
        for _ in 0..<7 { #expect(t.observe(obs("spotify:track:previous", 30)) == .wait) }
        #expect(t.observe(obs("spotify:track:previous", 31)) == .skip)
    }

    @Test func spotifyQuittingStops() {
        var t = QueueTracker(expectedID: "x")
        if case .stop = t.observe(PlayerObservation(running: false)) {} else { Issue.record("expected stop") }
    }

    @Test func parsesScriptOutputIncludingCommaDecimals() {
        let o = SpotifyScript.parse("1\tplaying\tspotify:track:abc\t12,5\t201000")
        #expect(o == PlayerObservation(running: true, state: "playing", trackURI: "spotify:track:abc", position: 12.5, durationMs: 201_000))
        #expect(SpotifyScript.parse("0").running == false)
        #expect(SpotifyScript.parse("garbage").running == false)
    }
}

@Suite struct QueueLaunchTests {
    @Test func moreForgivingWhileSpotifyLaunches() {
        var t = QueueTracker(expectedID: "aaaaaaaaaaaaaaaaaaaaaa", patience: 25)
        let idle = PlayerObservation(running: true, state: "paused", trackURI: "", position: 0, durationMs: 0)
        for _ in 0..<24 { #expect(t.observe(idle) == .wait) }
        #expect(t.observe(idle) == .skip)
    }
}

@MainActor
@Suite struct WelcomeTests {
    @Test func finishingTheTourHidesItAndRemembers() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "welcomeDone")
        defer { defaults.set(saved, forKey: "welcomeDone") }
        defaults.removeObject(forKey: "welcomeDone")

        let model = AppModel()
        #expect(model.showWelcome)
        model.tab = .journal
        model.finishWelcome()
        #expect(!model.showWelcome)
        #expect(model.tab == .mood)
        #expect(!AppModel().showWelcome)
    }
}

@MainActor
@Suite struct JournalKeyCachingTests {
    @Test func keyIsReadOncePerUnlockNotOnEverySave() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = JournalCipher(key: .init(size: .bits256))
        var reads = 0
        let store = JournalStore(fileURL: url, cipher: { _ in reads += 1; return key },
                                 authenticate: { .success(()) }, observeSystemEvents: false)
        await store.unlock()
        let id = store.add(JournalEntry(text: "a"))
        for i in 0..<5 { store.update(id) { $0.text = "edit \(i)" }; store.flush() }
        #expect(reads == 1)
        store.lock()
        await store.unlock()
        #expect(reads == 2)
        #expect(store.entries.first?.text == "edit 4")
    }
}

/// Cases found by playing a real queue in Spotify.
@Suite struct QueueRealWorldTests {
    private let id = "aaaaaaaaaaaaaaaaaaaaaa"
    private var ours: String { "spotify:track:\(id)" }
    private func obs(_ uri: String, _ position: Double, state: String = "playing", name: String = "", duration: Double = 200_000) -> PlayerObservation {
        PlayerObservation(running: true, state: state, trackURI: uri, position: position, durationMs: duration, name: name)
    }

    @Test func briefJumpToStartBetweenSongsCountsAsFinished() {
        var t = QueueTracker(expectedID: id)
        _ = t.observe(obs(ours, 198))
        #expect(t.observe(obs(ours, 0)) == .advance)   // Spotify reports 0:00 for a moment
    }

    @Test func delayedPollsStillAdvanceWhenEnoughTimePassed() {
        var t = QueueTracker(expectedID: id)
        let start = Date()
        _ = t.observe(obs(ours, 100), now: start)
        // App was napping: next poll arrives 2 minutes later, song has long ended.
        #expect(t.observe(obs("spotify:track:autoplay", 20), now: start.addingTimeInterval(120)) == .advance)
    }

    @Test func realChangeMidSongIsNotMistakenForTheSongEnding() {
        var t = QueueTracker(expectedID: id)
        let start = Date()
        _ = t.observe(obs(ours, 60), now: start)
        #expect(t.observe(obs("spotify:track:other", 3), now: start.addingTimeInterval(1)) == .changedInSpotify)
    }

    @Test func acceptsSpotifysRelinkedVersionByName() {
        var t = QueueTracker(expectedID: id, expectedTitle: "Nikes", previousURI: "spotify:track:before")
        #expect(t.observe(obs("spotify:track:relinked", 1, name: "Nikes")) == .wait)
        #expect(t.observe(obs("spotify:track:relinked", 2, name: "Nikes")) == .wait)
        #expect(t.observe(obs("spotify:track:relinked", 198, name: "Nikes")) == .wait)
        #expect(t.observe(obs("spotify:track:next", 1, name: "Something")) == .advance)
    }

    @Test func skipsQuicklyWhenSpotifyPlaysAStandIn() {
        var t = QueueTracker(expectedID: id, expectedTitle: "Nikes", previousURI: "spotify:track:before")
        #expect(t.observe(obs("spotify:track:before", 50)) == .wait)          // our request not applied yet
        #expect(t.observe(obs("spotify:track:ivy", 0, name: "Ivy")) == .wait)
        #expect(t.observe(obs("spotify:track:ivy", 1, name: "Ivy")) == .skip)
    }

    @Test func parsesTrackName() {
        let o = SpotifyScript.parse("1\tplaying\tspotify:track:abc\t1.0\t2000\tHolocene")
        #expect(o.name == "Holocene")
    }
}

@MainActor
@Suite struct DayRatingTests {
    @Test func fiveStepsSnapToNearest() {
        #expect(DayRating.allCases.map(\.label) == ["Awful", "Rough", "Okay", "Good", "Great"])
        #expect(DayRating(valence: 0.0) == .awful)
        #expect(DayRating(valence: 0.52) == .okay)
        #expect(DayRating(valence: 1.0) == .great)
    }

    @Test func chartUsesTheDaysAverageRating() async {
        let cipher = JournalCipher(key: .init(size: .bits256))
        let journal = JournalStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)"),
            cipher: { _ in cipher }, authenticate: { .success(()) }, observeSystemEvents: false)
        await journal.unlock()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        journal.add(JournalEntry(createdAt: noon, text: "a", valence: DayRating.rough.valence))
        journal.add(JournalEntry(createdAt: noon.addingTimeInterval(60), text: "b", valence: DayRating.great.valence))
        journal.add(JournalEntry(createdAt: noon.addingTimeInterval(120), text: "no rating"))
        #expect(abs((journal.valence(on: noon) ?? 0) - 0.6) < 0.0001)
        #expect(journal.valence(on: noon.addingTimeInterval(-86_400 * 3)) == nil)
    }

    @Test func theDayIsAskedOnceAndHasOneAnswer() async {
        let cipher = JournalCipher(key: .init(size: .bits256))
        let journal = JournalStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)"),
            cipher: { _ in cipher }, authenticate: { .success(()) }, observeSystemEvents: false)
        await journal.unlock()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let first = journal.add(JournalEntry(createdAt: noon, text: "morning"))
        let second = journal.add(JournalEntry(createdAt: noon.addingTimeInterval(3_600), text: "later"))
        #expect(journal.isFirstOfDay(first))
        #expect(!journal.isFirstOfDay(second))
        #expect(journal.dayRating(on: noon) == nil)

        journal.setDayRating(.rough, from: first)
        #expect(journal.dayRating(on: noon) == .rough)

        // Changing it from a later entry replaces the answer rather than averaging two.
        journal.setDayRating(.great, from: second)
        #expect(journal.dayRating(on: noon) == .great)
        #expect(journal.entries.filter { $0.valence != nil }.count == 1)

        journal.setDayRating(nil, from: second)
        #expect(journal.dayRating(on: noon) == nil)
    }

    @Test func suggestionSchemaAsksForADayRating() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(FeelingPrompt.schema.utf8)) as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("day") == true)
    }
}

@MainActor
@Suite struct QuickLogTests {
    @Test func savesALogAndCelebratesQuietly() async {
        let model = AppModel()
        let cipher = JournalCipher(key: .init(size: .bits256))
        let store = JournalStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("j-\(UUID().uuidString)"),
            cipher: { _ in cipher }, authenticate: { .success(()) }, observeSystemEvents: false)
        await store.unlock()
        model.useJournalForReview(store)

        model.saveQuickLog(rating: nil, text: "   ")
        #expect(store.entries.isEmpty)                      // nothing to log

        model.saveQuickLog(rating: .good, text: "  walked by the river  ")
        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "walked by the river")
        #expect(store.entries[0].valence == DayRating.good.valence)
        #expect(model.toast?.hasPrefix("Logged") == true)
        #expect(model.logPulse == 1)
        #expect(model.lastLoggedDay != nil)

        // A second log with a new answer replaces the day's rating; one without leaves it be.
        model.saveQuickLog(rating: nil, text: "tea")
        #expect(store.dayRating(on: Date()) == .good)
        model.saveQuickLog(rating: .great, text: "good news")
        #expect(store.dayRating(on: Date()) == .great)
        #expect(store.entries.filter { $0.valence != nil }.count == 1)
    }
}

// MARK: - Zen garden

@Suite struct SandFieldTests {
    @Test func rakeLeavesGroovesUnderTinesAndRidgesBetween() {
        let field = SandField(width: 200, height: 120)
        field.placeStones([])
        field.smoothAll()
        // A horizontal pass along y = 60 with 3 tines, 8 cells apart: tines at y 52, 60, 68.
        for x in stride(from: Float(10), to: 190, by: 2) {
            field.rake(from: SIMD2(x, 60.5), to: SIMD2(x + 2, 60.5), tines: 3, spacing: 8)
        }
        let groove = field.height(atX: 100, y: 60)
        let ridge = field.height(atX: 100, y: 64)
        #expect(groove < -0.8)
        #expect(ridge > 0.8)
        #expect(field.height(atX: 100, y: 52) < -0.8)
        #expect(abs(field.height(atX: 100, y: 100)) < 0.1)   // far from the rake: untouched
    }

    @Test func stonesAreNeverCarvedAndSmoothingFlattens() {
        let field = SandField(width: 200, height: 120)
        field.placeStones([SandField.Stone(x: 100, y: 60, rx: 12, ry: 10, tone: 1)])
        for x in stride(from: Float(60), to: 140, by: 2) {
            field.rake(from: SIMD2(x, 60), to: SIMD2(x + 2, 60), tines: 5, spacing: 6)
        }
        #expect(field.isStone(atX: 100, y: 60))
        #expect(field.height(atX: 100, y: 60) == 0)
        #expect(field.height(atX: 70, y: 60) != 0)
        field.smoothAll()
        #expect(abs(field.height(atX: 70, y: 60)) < 0.05)
    }

    @Test func settlingMovesGravelWithoutMakingOrLosingAny() {
        let field = SandField(width: 160, height: 100)
        field.placeStones([])
        field.smoothAll()
        // Two crossing strokes leave steep edges where they meet.
        field.rake(from: SIMD2(10, 50), to: SIMD2(150, 50), tines: 5, spacing: 6)
        field.endStroke()
        field.rake(from: SIMD2(80, 5), to: SIMD2(80, 95), tines: 5, spacing: 6)
        func total() -> Double {
            var sum = 0.0
            for y in 0..<100 { for x in 0..<160 { sum += Double(field.height(atX: x, y: y)) } }
            return sum
        }
        let before = total()
        field.endStroke()
        #expect(abs(total() - before) < 0.01)
    }

    @Test func aStrokeRakesEachPatchOnceSoJointsLeaveNoMarks() {
        let whole = SandField(width: 200, height: 120)
        whole.placeStones([])
        whole.smoothAll()
        whole.rake(from: SIMD2(20, 60), to: SIMD2(180, 60), tines: 3, spacing: 8)
        whole.endStroke()

        let pieces = SandField(width: 200, height: 120)
        pieces.placeStones([])
        pieces.smoothAll()
        for x in stride(from: Float(20), to: 180, by: 7) {
            pieces.rake(from: SIMD2(x, 60), to: SIMD2(min(x + 7, 180), 60), tines: 3, spacing: 8)
        }
        pieces.endStroke()
        for x in stride(from: 25, to: 175, by: 3) {
            #expect(abs(whole.height(atX: x, y: 57) - pieces.height(atX: x, y: 57)) < 0.001)
        }
    }

    @Test func rendersOnePixelPerCell() throws {
        let field = SandField(width: 160, height: 100)
        let image = try #require(field.render(dark: false))
        #expect(image.width == 160 && image.height == 100)
        #expect(field.render(dark: true) != nil)
    }

    @Test func shuffledStonesDontOverlap() {
        let field = SandField(width: 300, height: 180, seed: 42)
        for _ in 0..<10 {
            field.shuffleStones()
            #expect((2...3).contains(field.stones.count))
            for (i, a) in field.stones.enumerated() {
                for b in field.stones.dropFirst(i + 1) {
                    #expect(simd_distance(SIMD2(a.x, a.y), SIMD2(b.x, b.y)) > a.rx + b.rx)
                }
            }
        }
    }
}

// MARK: - YouTube

@Suite struct YouTubeTests {
    private func video(_ title: String, _ channel: String, _ seconds: Int? = 240, id: String = "abcdefghijk") -> YouTubeVideo {
        YouTubeVideo(id: id, title: title, channel: channel, seconds: seconds)
    }

    @Test func picksTheCleanOfficialVersionOverLiveCoversAndAlbums() {
        let song = YouTubeFinder.Song(title: "Holocene", artist: "Bon Iver", seconds: 336)
        let videos = [
            video("Bon Iver - Holocene (Live at Rock the Garden)", "The Current", 375, id: "live0000000"),
            video("Holocene - Bon Iver (Sierra Eagleson Cover)", "Sierra Eagleson", 327, id: "cover000000"),
            video("Bon Iver Greatest Hits", "Some Mixes", 4154, id: "album000000"),
            video("Bon Iver - Holocene (Deluxe) - Official Audio", "Bon Iver", 332, id: "official000"),
        ]
        #expect(YouTubeFinder.best(in: videos, for: song)?.id == "official000")
    }

    @Test func topicChannelsCountAsTheArtist() {
        let song = YouTubeFinder.Song(title: "Re: Stacks", artist: "Bon Iver", seconds: nil)
        #expect(YouTubeFinder.best(in: [video("Re: Stacks", "Bon Iver - Topic")], for: song) != nil)
    }

    @Test func rejectsOtherSongsAndOtherArtists() {
        let song = YouTubeFinder.Song(title: "Ivy", artist: "Frank Ocean", seconds: nil)
        #expect(YouTubeFinder.best(in: [video("Frank Ocean - Nikes", "Blonded")], for: song) == nil)
        #expect(YouTubeFinder.best(in: [video("Ivy", "Someone Else")], for: song) == nil)
        // A remix only when you asked for the remix.
        let remix = YouTubeFinder.Song(title: "Ivy (Remix)", artist: "Frank Ocean", seconds: nil)
        #expect(YouTubeFinder.best(in: [video("Frank Ocean - Ivy (Remix)", "Blonded")], for: remix) != nil)
    }

    @Test func readsTheSearchResponse() throws {
        let json = """
        {"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
          {"videoRenderer":{"videoId":"TWcyIpul8OE","title":{"runs":[{"text":"Bon Iver - Holocene - Official Video"}]},
           "ownerText":{"runs":[{"text":"Bon Iver"}]},"lengthText":{"simpleText":"5:44"}}},
          {"adSlotRenderer":{}},
          {"videoRenderer":{"videoId":"short","title":{"runs":[{"text":"bad id"}]}}}
        ]}}]}}}
        """
        let videos = YouTubeFinder.parseSearch(Data(json.utf8))
        #expect(videos == [YouTubeVideo(id: "TWcyIpul8OE", title: "Bon Iver - Holocene - Official Video", channel: "Bon Iver", seconds: 344)])
        #expect(YouTubeFinder.seconds(from: "1:02:03") == 3723)
        #expect(YouTubeFinder.seconds(from: "") == nil)
    }

    @Test func queueLinkHoldsUpToFiftyVideos() throws {
        #expect(YouTubeLinks.queue([]) == nil)
        let url = try #require(YouTubeLinks.queue((0..<60).map { String(format: "v%010d", $0) }))
        #expect(url.absoluteString.hasPrefix("https://www.youtube.com/watch_videos?video_ids="))
        #expect(url.query?.split(separator: ",").count == 50)
    }

    @Test func olderJournalSongsWithoutAVideoStillOpen() throws {
        let old = #"{"id":"a","title":"Holocene","artist":"Bon Iver","spotifyURI":"spotify:search:x","stuck":true}"#
        let song = try JSONDecoder().decode(JournalSong.self, from: Data(old.utf8))
        #expect(song.youtubeID == nil)
    }
}

// MARK: - Security fixes

@MainActor
@Suite struct SecurityTests {
    @Test func onlyAKeyThatOpensTheJournalIsAdopted() throws {
        let real = SymmetricKey(size: .bits256)
        let planted = SymmetricKey(size: .bits256)
        func encode(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0) }.base64EncodedString() }
        let journal = try JournalCipher(key: real).seal([JournalEntry(text: "private")])

        #expect(JournalCipher.firstKey(in: [encode(planted), "not a key"], opening: journal) == nil)
        let (value, _) = try #require(JournalCipher.firstKey(in: [encode(planted), encode(real)], opening: journal))
        #expect(value == encode(real))
    }

    private func store(_ url: URL, _ cipher: JournalCipher, legacy: PlaintextMoodHistory = .none) -> JournalStore {
        JournalStore(fileURL: url, cipher: { _ in cipher }, authenticate: { .success(()) },
                     legacyMoods: legacy, observeSystemEvents: false)
    }

    @Test func moodsAreEncryptedHiddenWhileLockedAndOldPlaintextIsErased() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mj-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sealed")
        let cipher = JournalCipher(key: .init(size: .bits256))
        let defaults = try #require(UserDefaults(suiteName: "mj-sec-\(UUID().uuidString)"))
        RecentMood.save([RecentMood(text: "an old secret mood", date: Date().addingTimeInterval(-600))],
                        to: defaults, key: PlaintextMoodHistory.keys[0])
        let legacy = PlaintextMoodHistory(defaults: defaults, legacyDomains: { [] })

        let journal = store(url, cipher, legacy: legacy)
        journal.rememberMood("typed while locked")
        #expect(journal.visibleRecentMoods.map(\.text) == ["typed while locked"])   // memory only
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal-moods.sealed").path))

        await journal.unlock()
        #expect(journal.recentMoods.map(\.text) == ["typed while locked", "an old secret mood"])
        let sealed = try Data(contentsOf: dir.appendingPathComponent("journal-moods.sealed"))
        #expect(String(decoding: sealed, as: UTF8.self).contains("secret") == false)
        #expect(defaults.object(forKey: PlaintextMoodHistory.keys[0]) == nil)       // plaintext erased

        journal.lock()
        #expect(journal.visibleRecentMoods.isEmpty)

        let reopened = store(url, cipher)
        await reopened.unlock()
        #expect(reopened.recentMoods.map(\.text) == ["typed while locked", "an old secret mood"])
    }

    @Test func sampleJournalsNeverTouchRealSettings() {
        #expect(PlaintextMoodHistory.none.load().isEmpty)
        PlaintextMoodHistory.none.erase()   // no-op
    }

    @Test func mergedKeepsNewestOncePerMood() {
        let now = Date()
        let merged = RecentMood.merged(
            [RecentMood(text: "Tired", date: now)],
            [RecentMood(text: "tired", date: now.addingTimeInterval(-60)), RecentMood(text: "calm", date: now.addingTimeInterval(-30))],
            [RecentMood(text: "undated", date: nil)])
        #expect(merged.map(\.text) == ["Tired", "calm", "undated"])
        #expect(RecentMood.merged((0..<20).map { RecentMood(text: "m\($0)", date: now.addingTimeInterval(Double(-$0))) }).count == 8)
    }
}

// MARK: - Night sky

@Suite struct SkyTests {
    private func at(_ hour: Int, _ minute: Int = 0) -> Sky {
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        parts.hour = hour; parts.minute = minute
        return Sky.at(Calendar.current.date(from: parts)!)
    }

    @Test func sunsetGlowsAndMidnightIsOnlyMoonAndStars() {
        let sunset = at(19), late = at(1), noon = at(12)
        #expect(sunset.warm > 0.9 && sunset.stars < 0.05 && sunset.moon == 0)
        #expect(late.warm < 0.01 && late.horizon < 0.01)          // no warm glow at 1 am
        #expect(late.moon > 0.9 && late.stars > 0.9)              // just moonlight and stars
        #expect(noon.stars == 0 && noon.moon == 0 && noon.warm > 0)
        #expect(at(6, 30).stars < 0.05)                           // gone by dawn
    }
}

// MARK: - Type

@Suite struct FrauncesTests {
    @Test func bundledFrauncesLoadsLightSoftAndItalic() throws {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Fonts").standardizedFileURL
        Fraunces.register(directory: fonts)

        let upright = try #require(Fraunces.font(size: 34, italic: false))
        #expect(CTFontCopyFamilyName(upright) as String == "Fraunces")
        let axes = (CTFontCopyVariation(upright) as? [NSNumber: NSNumber]) ?? [:]
        let wght = NSNumber(value: "wght".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let soft = NSNumber(value: "SOFT".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        #expect(axes[wght]?.doubleValue == 300)
        #expect(axes[soft]?.doubleValue == 100)

        let italic = try #require(Fraunces.font(size: 15, italic: true))
        #expect(CTFontGetSymbolicTraits(italic).contains(.traitItalic))
    }

    @Test func dayRatingsLandExactlyOnTheSkyRamp() {
        for rating in DayRating.allCases {
            #expect(Theme.blend(valence: rating.valence) == Theme.moodTones[rating.rawValue - 1])
        }
    }
}

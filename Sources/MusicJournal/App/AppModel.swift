import AppKit
import Foundation
import Observation
import SwiftUI

enum AccessMode: String, CaseIterable, Identifiable, Sendable {
    /// No Spotify login. Songs are checked on iTunes and opened in Spotify via search.
    case free
    /// Spotify Web API. Needs a developer app owned by a Premium account.
    case spotifyAccount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: "Free (no login)"
        case .spotifyAccount: "Spotify account (Premium)"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case needsSetup     // free: first-run artists step; account: no Client ID yet
        case signedOut
        case loadingProfile
        case ready
    }

    enum Status: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case mood = "Mood"
        case journal = "Journal"
        case zen = "Zen"
        var id: String { rawValue }
    }

    /// Free mode "Open in Spotify": finding real Spotify links for the mix.
    enum LinkState: Equatable {
        case idle
        case finding
        case ready
    }

    private enum Keys {
        static let accessMode = "accessMode"
        static let legacyFavouriteArtists = "favouriteArtists"
        static let profileArtists = "profileArtists"
        static let profileSongs = "profileSongs"
        static let profileGenres = "profileGenres"
        static let profileEras = "profileEras"
        static let profileLanguages = "profileLanguages"
        static let profileAvoid = "profileAvoid"
        static let likedSongs = "likedSongs"
        static let skippedSongs = "skippedSongs"
        static let tasteInfluence = "tasteInfluence"
        static let moodApproach = "moodApproach"
        static let discovery = "discovery"
        static let vocals = "vocals"
        static let cleanOnly = "cleanOnly"
        static let mixLength = "mixLength"
        static let brainPreference = "brainPreference"
        static let claudeModel = "claudeModel"
        static let claudePath = "claudePath"
    }

    // MARK: State

    var phase: Phase = .needsSetup
    var status: Status = .idle
    var taste: TasteProfile?
    var moodText = ""
    var recommendation: Recommendation?
    var savedMix: PlaylistSummary?
    var isSavingMix = false
    var copiedMix = false
    /// Real Spotify tracks for the current mix, keyed by `MixEntry.id` (free mode).
    var spotifyLinks: [Int: SpotifyTrackRef] = [:]
    var linkState: LinkState = .idle
    /// YouTube videos for the current mix, keyed by `MixEntry.id`.
    var youtubeVideos: [Int: YouTubeVideo] = [:]
    var youtubeState: LinkState = .idle
    /// The journal entry whose songs are being looked up on YouTube, if any.
    var journalYouTubeID: JournalEntry.ID?
    /// Plays mixes and journal songs in the Spotify app, one after another.
    let queue = SpotifyQueue()
    /// The journal entry whose songs are being looked up on Spotify, if any.
    var journalLookupID: JournalEntry.ID?
    /// The journal entry Claude is reading to suggest feelings, if any.
    var feelingSuggestionID: JournalEntry.ID?
    var tab: Tab = .mood

    // MARK: Welcome tour (first run)

    private static let welcomeDoneKey = "welcomeDone"
    var showWelcome = !UserDefaults.standard.bool(forKey: AppModel.welcomeDoneKey)
    var welcomeStep = 0

    func replayWelcome() {
        welcomeStep = 0
        showWelcome = true
    }

    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey)
        showWelcome = false
        tab = .mood
    }

    enum ClaudeCheck: Equatable {
        case unchecked
        case checking
        case ready
        case notInstalled
        case problem(String)
    }

    var claudeCheck: ClaudeCheck = .unchecked

    var spotifyAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    /// Sends Claude Code one tiny request, so "ready" means installed *and* signed in.
    func checkClaude() async {
        claudeCheck = .checking
        let override = claudePath
        guard await Task.detached(operation: { ClaudeCLI.locate(override: override) }).value != nil else {
            claudeCheck = .notInstalled
            return
        }
        struct Pong: Decodable { let ok: Bool }
        do {
            let pong = try await ClaudeCLI.structuredRequest(
                Pong.self,
                prompt: "Reply with ok set to true.",
                systemPrompt: "You answer health checks.",
                schema: #"{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean"}}}"#,
                extraArguments: ["--tools", "", "--strict-mcp-config"],
                effort: "low",
                executableOverride: override,
                timeout: .seconds(60)
            )
            claudeCheck = pong.ok ? .ready : .problem("Claude Code answered, but not as expected.")
        } catch {
            claudeCheck = .problem(error.localizedDescription)
        }
    }
    /// The real journal: the only one that moves in (and erases) older unencrypted moods.
    private(set) var journal = JournalStore(legacyMoods: PlaintextMoodHistory())

    /// UI review only: swap in a sample journal that never touches the real one.
    func useJournalForReview(_ store: JournalStore) {
        journal = store
    }
    /// Recent moods live encrypted in the journal; see `JournalStore.recentMoods`.
    var recentMoods: [RecentMood] { journal.visibleRecentMoods }
    let player = PreviewPlayer()

    private(set) var accessMode: AccessMode =
        AccessMode(rawValue: UserDefaults.standard.string(forKey: Keys.accessMode) ?? "") ?? .free

    // MARK: Personalization (Settings › Personalization). All optional.

    // What you like: follows `tasteInfluence`.
    var profileArtistsText: String =
        UserDefaults.standard.string(forKey: Keys.profileArtists)
        ?? UserDefaults.standard.string(forKey: Keys.legacyFavouriteArtists) ?? "" {
        didSet { UserDefaults.standard.set(profileArtistsText, forKey: Keys.profileArtists) }
    }
    var profileSongsText: String = UserDefaults.standard.string(forKey: Keys.profileSongs) ?? "" {
        didSet { UserDefaults.standard.set(profileSongsText, forKey: Keys.profileSongs) }
    }
    var profileGenresText: String = UserDefaults.standard.string(forKey: Keys.profileGenres) ?? "" {
        didSet { UserDefaults.standard.set(profileGenresText, forKey: Keys.profileGenres) }
    }
    var profileErasText: String = UserDefaults.standard.string(forKey: Keys.profileEras) ?? "" {
        didSet { UserDefaults.standard.set(profileErasText, forKey: Keys.profileEras) }
    }
    var profileLanguagesText: String = UserDefaults.standard.string(forKey: Keys.profileLanguages) ?? "" {
        didSet { UserDefaults.standard.set(profileLanguagesText, forKey: Keys.profileLanguages) }
    }
    /// Thumbs-ups from mixes, one "Title — Artist" per line.
    var likedSongsText: String = UserDefaults.standard.string(forKey: Keys.likedSongs) ?? "" {
        didSet { UserDefaults.standard.set(likedSongsText, forKey: Keys.likedSongs) }
    }
    var tasteInfluence: TasteInfluence =
        TasteInfluence(rawValue: UserDefaults.standard.string(forKey: Keys.tasteInfluence) ?? "") ?? .subtle {
        didSet { UserDefaults.standard.set(tasteInfluence.rawValue, forKey: Keys.tasteInfluence) }
    }

    // How to pick: always applies.
    var moodApproach: MoodApproach =
        MoodApproach(rawValue: UserDefaults.standard.string(forKey: Keys.moodApproach) ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(moodApproach.rawValue, forKey: Keys.moodApproach) }
    }
    var discovery: Discovery =
        Discovery(rawValue: UserDefaults.standard.string(forKey: Keys.discovery) ?? "") ?? .balanced {
        didSet { UserDefaults.standard.set(discovery.rawValue, forKey: Keys.discovery) }
    }
    var vocals: VocalPreference =
        VocalPreference(rawValue: UserDefaults.standard.string(forKey: Keys.vocals) ?? "") ?? .any {
        didSet { UserDefaults.standard.set(vocals.rawValue, forKey: Keys.vocals) }
    }
    var cleanOnly: Bool = UserDefaults.standard.bool(forKey: Keys.cleanOnly) {
        didSet { UserDefaults.standard.set(cleanOnly, forKey: Keys.cleanOnly) }
    }
    static let mixLengths = [15, 25, 40]
    var mixLength: Int = {
        let saved = UserDefaults.standard.integer(forKey: Keys.mixLength)
        return AppModel.mixLengths.contains(saved) ? saved : 25
    }() {
        didSet { UserDefaults.standard.set(mixLength, forKey: Keys.mixLength) }
    }

    // Not for me: always applies.
    var profileAvoidText: String = UserDefaults.standard.string(forKey: Keys.profileAvoid) ?? "" {
        didSet { UserDefaults.standard.set(profileAvoidText, forKey: Keys.profileAvoid) }
    }
    /// Thumbs-downs from mixes, one "Title — Artist" per line. Never suggested again.
    var skippedSongsText: String = UserDefaults.standard.string(forKey: Keys.skippedSongs) ?? "" {
        didSet { UserDefaults.standard.set(skippedSongsText, forKey: Keys.skippedSongs) }
    }

    var personalization: Personalization {
        Personalization(
            artists: Personalization.list(from: profileArtistsText),
            // Song titles can contain commas, so song lists are one per line.
            songs: Personalization.list(from: profileSongsText, commas: false),
            genres: Personalization.list(from: profileGenresText),
            eras: Personalization.list(from: profileErasText),
            languages: Personalization.list(from: profileLanguagesText),
            likedSongs: Personalization.list(from: likedSongsText, commas: false),
            influence: tasteInfluence,
            approach: moodApproach,
            discovery: discovery,
            vocals: vocals,
            cleanOnly: cleanOnly,
            mixLength: mixLength,
            avoid: Personalization.list(from: profileAvoidText),
            skippedSongs: Personalization.list(from: skippedSongsText, commas: false)
        )
    }

    // MARK: Song feedback (thumbs up / down on mix songs)

    enum Feedback { case liked, skipped }

    func feedback(for entry: MixEntry) -> Feedback? {
        let ref = songRef(for: entry)
        if Self.lines(skippedSongsText).contains(where: { SongRef(line: $0).matches(title: ref.title, artist: ref.artist ?? "") }) {
            return .skipped
        }
        if Self.lines(likedSongsText).contains(where: { SongRef(line: $0).matches(title: ref.title, artist: ref.artist ?? "") }) {
            return .liked
        }
        return nil
    }

    /// Toggles a thumbs-up or thumbs-down. The two are exclusive.
    func toggleFeedback(_ kind: Feedback, for entry: MixEntry) {
        let ref = songRef(for: entry)
        let wasSet = feedback(for: entry) == kind
        likedSongsText = Self.removing(ref, from: likedSongsText)
        skippedSongsText = Self.removing(ref, from: skippedSongsText)
        guard !wasSet else { return }
        switch kind {
        case .liked: likedSongsText = Self.appending(ref, to: likedSongsText)
        case .skipped: skippedSongsText = Self.appending(ref, to: skippedSongsText)
        }
    }

    private func songRef(for entry: MixEntry) -> SongRef {
        SongRef(title: entry.track?.name ?? entry.idea.title, artist: entry.track?.artist ?? entry.idea.artist)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func removing(_ ref: SongRef, from text: String) -> String {
        lines(text).filter { !SongRef(line: $0).matches(title: ref.title, artist: ref.artist ?? "") }.joined(separator: "\n")
    }

    private static func appending(_ ref: SongRef, to text: String) -> String {
        (lines(text) + [ref.line]).joined(separator: "\n")
    }

    var clientID: String = SpotifyConfig.clientID ?? "" {
        didSet {
            UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: SpotifyConfig.clientIDKey)
            if accessMode == .spotifyAccount, phase == .needsSetup, SpotifyConfig.clientID != nil { phase = .signedOut }
        }
    }
    var brainPreference: BrainPreference =
        BrainPreference(rawValue: UserDefaults.standard.string(forKey: Keys.brainPreference) ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(brainPreference.rawValue, forKey: Keys.brainPreference) }
    }
    var claudeModel: String = UserDefaults.standard.string(forKey: Keys.claudeModel) ?? "" {
        didSet { UserDefaults.standard.set(claudeModel, forKey: Keys.claudeModel) }
    }
    var claudePath: String = UserDefaults.standard.string(forKey: Keys.claudePath) ?? "" {
        didSet { UserDefaults.standard.set(claudePath, forKey: Keys.claudePath) }
    }

    var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    // MARK: Dependencies

    private let tokens = TokenStore()
    private let auth = SpotifyAuth()
    private let iTunes = ITunesCatalog()
    private var client: SpotifyClient { SpotifyClient(tokens: tokens) }
    private var currentTask: Task<Void, Never>?
    private var linkTask: Task<Void, Never>?
    private var journalTask: Task<Void, Never>?
    private var youtubeTask: Task<Void, Never>?

    private var engine: RecommendationEngine {
        let catalog: any MusicCatalog = switch accessMode {
        case .free: iTunes
        case .spotifyAccount: SpotifyCatalog(client: client, userID: taste?.userID ?? "")
        }
        return RecommendationEngine(
            catalog: catalog,
            brain: FallbackBrain(
                primary: ClaudeCLIBrain(model: claudeModel, executableOverride: claudePath),
                fallback: AppleBrain(),
                preference: brainPreference
            )
        )
    }

    // MARK: Lifecycle

    func start() async {
        switch accessMode {
        case .free:
            // No setup needed: the mood box works straight away, and taste is optional in Settings.
            taste = .empty
            phase = .ready
        case .spotifyAccount:
            if SpotifyConfig.clientID == nil {
                phase = .needsSetup
            } else if await tokens.hasRefreshToken {
                await loadProfile(forceRefresh: false)
            } else {
                phase = .signedOut
            }
        }
    }

    func setAccessMode(_ mode: AccessMode) async {
        guard mode != accessMode else { return }
        currentTask?.cancel()
        player.stop()
        accessMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.accessMode)
        recommendation = nil
        savedMix = nil
        spotifyLinks = [:]
        linkTask?.cancel()
        linkState = .idle
        youtubeVideos = [:]
        youtubeTask?.cancel()
        youtubeState = .idle
        taste = nil
        status = .idle
        await start()
    }

    func signIn() async {
        status = .idle
        do {
            try await auth.signIn(into: tokens)
            await loadProfile(forceRefresh: true)
        } catch SpotifyAuthError.cancelled {
            // User closed the sheet; nothing to report.
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        currentTask?.cancel()
        linkTask?.cancel()
        await tokens.clear()
        TasteProfileBuilder.clearCache()
        taste = nil
        recommendation = nil
        savedMix = nil
        status = .idle
        phase = SpotifyConfig.clientID == nil ? .needsSetup : .signedOut
    }

    func loadProfile(forceRefresh: Bool) async {
        guard accessMode == .spotifyAccount else { return }
        phase = .loadingProfile
        do {
            taste = try await TasteProfileBuilder.load(using: client, forceRefresh: forceRefresh)
            phase = .ready
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
            phase = await tokens.hasRefreshToken ? .ready : .signedOut
        }
    }

    // MARK: Recommendations

    func recommend(_ mood: String? = nil) {
        let mood = (mood ?? moodText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mood.isEmpty, let taste else { return }
        moodText = mood
        rememberMood(mood)
        // Clean slate: clear the previous mood's results as soon as a new one starts, so nothing
        // on screen looks like it carried over while Claude is thinking.
        recommendation = nil
        savedMix = nil
        copiedMix = false
        spotifyLinks = [:]
        linkTask?.cancel()
        linkState = .idle
        youtubeVideos = [:]
        youtubeTask?.cancel()
        youtubeState = .idle
        player.stop()
        currentTask?.cancel()

        let engine = engine
        let personalization = personalization
        let preference = brainPreference
        let checking = accessMode == .free ? "Checking songs…" : "Finding music on Spotify…"
        currentTask = Task {
            do {
                let result = try await engine.recommend(mood: mood, taste: taste, personalization: personalization) { stage in
                    await MainActor.run {
                        // A superseded request must not overwrite the new one's status.
                        guard !Task.isCancelled else { return }
                        switch stage {
                        case .thinking:
                            self.status = .working(preference == .onDeviceOnly
                                ? "Thinking on-device…" : "Thinking with Claude…")
                        case .searching:
                            self.status = .working(checking)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                recommendation = result
                status = .idle
            } catch is CancellationError {
                // Superseded by a newer request.
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        status = .idle
    }

    // MARK: Add log

    var showQuickLog = false
    /// Short confirmation shown at the bottom ("Logged · Saturday night").
    var toast: String?
    /// Bumped on each log so the month chart can play its fill animation for that day.
    var logPulse = 0
    var lastLoggedDay: Date?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Opens the quick log, unlocking the journal first if needed.
    func beginQuickLog() async {
        if journal.isLocked { await journal.unlock() }
        guard !journal.isLocked else { return }
        showQuickLog = true
    }

    func saveQuickLog(rating: DayRating?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rating != nil || !trimmed.isEmpty else { return }
        let entry = JournalEntry(text: trimmed)
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
            journal.add(entry)
            if let rating { journal.setDayRating(rating, from: entry.id) }
        }
        celebrateLog("Logged · \(TimeOfDay.describe(entry.createdAt))", day: entry.createdAt)
    }

    /// The subtle payoff: a haptic, a toast, and the day's square filling in.
    func celebrateLog(_ message: String, day: Date) {
        Haptics.success()
        lastLoggedDay = day
        logPulse += 1
        showToast(message)
    }

    /// A quiet note that rises from the bottom for a couple of seconds.
    func showToast(_ message: String) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { toast = message }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { toast = nil }
        }
    }

    /// Saves the current mood, mix and your thumbs-ups as a journal entry, unlocking the
    /// journal first if needed, then opens it so you can write.
    func saveToJournal() async {
        guard let recommendation else { return }
        if journal.isLocked { await journal.unlock() }
        guard !journal.isLocked else { return }
        if let existing = journal.entries.first(where: { $0.recommendationID == recommendation.id }) {
            journal.selectedID = existing.id
        } else {
            journal.add(JournalEntry.from(
                recommendation, keptMix: keptMix,
                liked: { self.feedback(for: $0) == .liked },
                spotifyLinks: spotifyLinks,
                youtubeVideos: youtubeVideos
            ))
            celebrateLog("Saved to your journal", day: recommendation.createdAt)
        }
        tab = .journal
    }

    var isSavedToJournal: Bool {
        guard let id = recommendation?.id, !journal.isLocked else { return false }
        return journal.entries.contains { $0.recommendationID == id }
    }

    /// The current mix without songs you've given a thumbs-down. Everything that copies or
    /// saves the mix uses this, so a skipped song never ends up in a playlist.
    var keptMix: [MixEntry] {
        (recommendation?.mix ?? []).filter { feedback(for: $0) != .skipped }
    }

    /// Account mode only: creates a private playlist with every verified track you kept.
    func saveMix() async {
        let uris = keptMix.compactMap(\.track?.uri)
        guard let recommendation, recommendation.canSaveMix, !uris.isEmpty else { return }
        isSavingMix = true
        defer { isSavingMix = false }
        do {
            let plan = recommendation.plan
            let description = plan.mixDescription.isEmpty
                ? "Made by MusicJournal for: \(recommendation.mood)".truncated(to: 280)
                : plan.mixDescription
            let playlist = try await client.createPlaylist(name: plan.mixName, description: description)
            try await client.addItems(playlistID: playlist.id, uris: uris)
            savedMix = PlaylistSummary(playlist, currentUserID: nil)
        } catch {
            status = .failed("Couldn't save the mix: \(error.localizedDescription)")
        }
    }

    /// Free mode: puts "Title — Artist" lines on the clipboard, skipping songs that weren't
    /// found and songs you gave a thumbs-down.
    func copyMix() {
        guard let recommendation else { return }
        let lines = keptMix
            .filter { $0.lookup != .notFound }
            .map { entry in
                let name = entry.track?.name ?? entry.idea.title
                let artist = entry.track?.artist ?? entry.idea.artist
                return "\(name) — \(artist)"
            }
        let text = ([recommendation.plan.mixName, ""] + lines).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMix = true
    }

    /// Free mode: finds each song on Spotify (via Claude's Spotify connector, once per mix),
    /// then plays them in the Spotify app one after another through `queue`.
    /// Cancelled if you start a new mood, so a stale lookup doesn't keep using Claude.
    func playMixInSpotify(startingAt entryID: Int? = nil) {
        guard let recommendation, linkState != .finding else { return }
        if linkState == .ready {
            startMixQueue(at: entryID)
            return
        }
        linkState = .finding
        // Only look up songs you kept, using the verified iTunes spelling when we have it.
        let entries = keptMix
        let ideas = entries.map { entry in
            entry.track.map { MoodPlan.TrackIdea(title: $0.name, artist: $0.artist) } ?? entry.idea
        }
        let resolver = SpotifyConnectorResolver(executableOverride: claudePath)
        linkTask = Task {
            do {
                let found = try await resolver.resolve(ideas)
                guard !Task.isCancelled, self.recommendation?.id == recommendation.id else { return }
                spotifyLinks = Dictionary(uniqueKeysWithValues: found.map { (entries[$0.key].id, $0.value) })
                linkState = .ready
                startMixQueue(at: entryID)
            } catch {
                guard !Task.isCancelled, self.recommendation?.id == recommendation.id else { return }
                linkState = .idle
                status = .failed("Couldn't find the songs on Spotify: \(error.localizedDescription)")
            }
        }
    }

    // MARK: YouTube

    /// Queues the whole mix on YouTube (from `entryID` on, if given) and opens it in your
    /// browser. YouTube plays it as one playlist, in order, with its own next, shuffle and loop.
    func playMixOnYouTube(startingAt entryID: Int? = nil) {
        guard let recommendation, youtubeState != .finding else { return }
        if youtubeState == .ready {
            openMixOnYouTube(from: entryID)
            return
        }
        youtubeState = .finding
        let entries = keptMix
        let songs = entries.map { entry in
            YouTubeFinder.Song(
                title: entry.track?.name ?? entry.idea.title,
                artist: entry.track?.artist ?? entry.idea.artist,
                seconds: entry.track?.durationMs.map { $0 / 1000 })
        }
        youtubeTask = Task {
            let found = await YouTubeFinder.find(songs)
            guard !Task.isCancelled, self.recommendation?.id == recommendation.id else { return }
            youtubeVideos = Dictionary(uniqueKeysWithValues: found.map { (entries[$0.key].id, $0.value) })
            youtubeState = .ready
            openMixOnYouTube(from: entryID)
        }
    }

    private func openMixOnYouTube(from entryID: Int?) {
        var entries = keptMix
        if let entryID, let start = entries.firstIndex(where: { $0.id == entryID }) {
            entries = Array(entries[start...])
        }
        openOnYouTube(entries.compactMap { youtubeVideos[$0.id]?.id }, total: entries.count)
    }

    /// Plays a past entry's songs on YouTube, finding any it hasn't looked up before and
    /// remembering them for next time.
    func playJournalEntryOnYouTube(_ id: JournalEntry.ID, onlyStuck: Bool = false) {
        guard let entry = journal.entries.first(where: { $0.id == id }), journalYouTubeID == nil else { return }
        let songs = onlyStuck ? entry.stuckSongs : entry.songs
        guard !songs.isEmpty else { return }
        let missing = songs.filter { $0.youtubeID == nil }
        let play = { [weak self] in
            guard let self, let entry = self.journal.entries.first(where: { $0.id == id }) else { return }
            let songs = onlyStuck ? entry.stuckSongs : entry.songs
            self.openOnYouTube(songs.compactMap(\.youtubeID), total: songs.count)
        }
        guard !missing.isEmpty else {
            play()
            return
        }
        journalYouTubeID = id
        youtubeTask?.cancel()
        youtubeTask = Task {
            defer { journalYouTubeID = nil }
            let found = await YouTubeFinder.find(missing.map { .init(title: $0.title, artist: $0.artist, seconds: nil) })
            guard !Task.isCancelled else { return }
            journal.update(id) { entry in
                for (index, video) in found {
                    guard let i = entry.songs.firstIndex(where: { $0.id == missing[index].id }) else { continue }
                    entry.songs[i].youtubeID = video.id
                }
            }
            play()
        }
    }

    private func openOnYouTube(_ ids: [String], total: Int) {
        guard let url = YouTubeLinks.queue(ids) else {
            queue.message = "Couldn't find these songs on YouTube."
            return
        }
        // One thing at a time: stop the Spotify queue (and pause Spotify) and any preview.
        if queue.isActive { queue.stop() }
        player.stop()
        NSWorkspace.shared.open(url)
        let count = min(ids.count, 50)
        let missing = total - ids.count
        showToast("Queued \(count) \(count == 1 ? "song" : "songs") on YouTube" + (missing > 0 ? " · \(missing) not found" : ""))
    }

    private func startMixQueue(at entryID: Int?) {
        guard let recommendation else { return }
        let playable = keptMix.compactMap { entry -> (Int, SpotifyQueue.Item)? in
            guard let ref = spotifyLinks[entry.id] else { return nil }
            return (entry.id, SpotifyQueue.Item(
                id: ref.id,
                title: entry.track?.name ?? entry.idea.title,
                artist: entry.track?.artist ?? entry.idea.artist,
                imageURL: entry.track?.imageURL ?? ref.imageURL))
        }
        guard !playable.isEmpty else {
            status = .failed("None of these songs turned up on Spotify.")
            return
        }
        let start = entryID.flatMap { id in playable.firstIndex { $0.0 == id } } ?? 0
        player.stop()
        queue.start(playable.map(\.1), from: recommendation.plan.mixName, at: start)
    }

    /// Plays a journal entry's songs (the ones that stuck, or all of them). Songs without a
    /// Spotify track yet are looked up once and saved back to the entry, so replays are instant.
    /// Plays a past entry's songs in Spotify: the whole mix in its original order, or only the
    /// songs that stuck. Songs saved as a search are looked up first. Problems show in the
    /// bar at the bottom, which is visible from every tab.
    func playJournalEntry(_ id: JournalEntry.ID, onlyStuck: Bool = false) {
        guard let entry = journal.entries.first(where: { $0.id == id }), journalLookupID == nil else { return }
        let songs = onlyStuck ? entry.stuckSongs : entry.songs
        guard !songs.isEmpty else { return }
        queue.message = nil
        let missing = songs.filter { !$0.spotifyURI.hasPrefix("spotify:track:") }
        guard !missing.isEmpty else {
            startJournalQueue(entryID: id, onlyStuck: onlyStuck)
            return
        }
        journalLookupID = id
        let resolver = SpotifyConnectorResolver(executableOverride: claudePath)
        journalTask?.cancel()
        journalTask = Task {
            defer { journalLookupID = nil }
            do {
                let found = try await resolver.resolve(missing.map { .init(title: $0.title, artist: $0.artist) })
                guard !Task.isCancelled else { return }
                journal.update(id) { entry in
                    for (index, ref) in found {
                        guard let i = entry.songs.firstIndex(where: { $0.id == missing[index].id }) else { continue }
                        entry.songs[i].spotifyURI = ref.uri
                        entry.songs[i].webURL = ref.webURL
                        if entry.songs[i].imageURL == nil { entry.songs[i].imageURL = ref.imageURL }
                    }
                }
                startJournalQueue(entryID: id, onlyStuck: onlyStuck)
            } catch {
                guard !Task.isCancelled else { return }
                // Play whatever already has a Spotify link rather than nothing.
                if !startJournalQueue(entryID: id, onlyStuck: onlyStuck, quietIfEmpty: true) {
                    queue.message = "Couldn't find these songs on Spotify: \(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    private func startJournalQueue(entryID: JournalEntry.ID, onlyStuck: Bool, quietIfEmpty: Bool = false) -> Bool {
        guard let entry = journal.entries.first(where: { $0.id == entryID }) else { return false }
        let songs = onlyStuck ? entry.stuckSongs : entry.songs
        let items = songs.compactMap { song -> SpotifyQueue.Item? in
            guard song.spotifyURI.hasPrefix("spotify:track:") else { return nil }
            return SpotifyQueue.Item(
                id: String(song.spotifyURI.dropFirst("spotify:track:".count)),
                title: song.title, artist: song.artist, imageURL: song.imageURL)
        }
        guard !items.isEmpty else {
            if !quietIfEmpty { queue.message = "None of these songs turned up on Spotify." }
            return false
        }
        player.stop()
        let day = entry.createdAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        queue.start(items, from: entry.mixName.map { "\($0) · \(day)" } ?? day)
        return true
    }

    /// Asks Claude to pick up to three feelings from an entry's text. Only runs when you press
    /// "Suggest from my writing"; the entry is sent to Claude for this one request.
    func suggestFeelings(for id: JournalEntry.ID) {
        guard feelingSuggestionID == nil, let entry = journal.entries.first(where: { $0.id == id }) else { return }
        feelingSuggestionID = id
        let prompt = FeelingPrompt.user(text: entry.text, mood: entry.mood)
        let override = claudePath
        Task {
            defer { feelingSuggestionID = nil }
            do {
                let result = try await ClaudeCLI.structuredRequest(
                    FeelingPrompt.Response.self,
                    prompt: prompt,
                    systemPrompt: FeelingPrompt.system,
                    schema: FeelingPrompt.schema,
                    extraArguments: ["--tools", "", "--strict-mcp-config"],
                    effort: "low",
                    executableOverride: override,
                    timeout: .seconds(90)
                )
                let ids = FeelingPrompt.validIDs(result.feelings)
                guard !ids.isEmpty else {
                    status = .failed("Claude couldn't pick feelings from this entry.")
                    return
                }
                journal.update(id) { entry in
                    entry.feelingIDs = ids
                    entry.feelingNote = result.why.trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: 160)
                }
                // Claude only rates the day if you haven't: your own answer always stands.
                if journal.dayRating(on: entry.createdAt) == nil, let rating = DayRating(rawValue: result.day) {
                    journal.setDayRating(rating, from: id)
                }
                Haptics.success()
            } catch {
                status = .failed("Couldn't suggest feelings: \(error.localizedDescription)")
            }
        }
    }

    /// One Spotify track link per line, in mix order.
    func copySpotifyLinks() {
        let links = keptMix.compactMap { spotifyLinks[$0.id]?.webURL.absoluteString }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    private func rememberMood(_ mood: String) {
        journal.rememberMood(mood)
    }

    // MARK: Opening in Spotify

    /// Opens the Spotify desktop app if installed, otherwise the web player.
    func open(uri: String, webURL: URL?) {
        if let url = URL(string: uri), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let webURL {
            NSWorkspace.shared.open(webURL)
        }
    }

    func openSearch(_ query: String) {
        let link = SpotifyLinks.search(query)
        open(uri: link.uri, webURL: link.webURL)
    }

    // MARK: Debug

    func forceTokenExpiry() async {
        await tokens.forceExpire()
    }

    /// Brain diagnostics for Settings. Stored rather than computed because locating the CLI
    /// may spawn a login shell.
    var detectedClaudePath: String?
    var onDeviceStatus = ""

    func refreshDiagnostics() async {
        let override = claudePath
        detectedClaudePath = await Task.detached { ClaudeCLI.locate(override: override)?.path }.value
        onDeviceStatus = AppleBrain.unavailableReason ?? "Ready"
    }
}

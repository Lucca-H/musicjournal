import AppKit
import Foundation
import Observation

/// Plays a list of songs in the Spotify desktop app, one after another. Spotify's scripting
/// can play a specific track but has no "add to queue" (that's Premium-only through its API),
/// so MusicJournal acts as the queue: it starts a song, watches for it to end, and starts
/// the next. Works on free accounts. MusicJournal has to stay open while it plays.
@MainActor
@Observable
final class SpotifyQueue {
    struct Item: Identifiable, Hashable, Sendable {
        /// Spotify track ID (the part after `spotify:track:`).
        let id: String
        let title: String
        let artist: String
        let imageURL: URL?
    }

    enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
        var next: RepeatMode { self == .off ? .all : self == .all ? .one : .off }
    }

    private(set) var items: [Item] = []
    /// The mix in its own order, so turning shuffle off puts it back.
    @ObservationIgnored private var originalItems: [Item] = []
    /// Songs in a row that wouldn't play; a full lap of them ends the queue, even on repeat.
    @ObservationIgnored private var skipsInARow = 0
    private(set) var isShuffled = UserDefaults.standard.bool(forKey: "queue.shuffle")
    private(set) var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "queue.repeat") ?? "") ?? .off
    private(set) var index = 0
    private(set) var isActive = false
    /// Where the current queue came from, e.g. the mix name or a journal date.
    private(set) var sourceName = ""
    var message: String?
    /// Spotify's playback for the current song, refreshed on every check (about once a second).
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// When `position` was read, so the progress bar can move smoothly between checks.
    private(set) var positionReadAt = Date()

    @ObservationIgnored private var tracker = QueueTracker(expectedID: "")
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Keeps macOS's App Nap from slowing the once-a-second check while MusicJournal is in
    /// the background, which made the queue miss the end of a song.
    @ObservationIgnored private var activity: NSObjectProtocol?

    var current: Item? { isActive && items.indices.contains(index) ? items[index] : nil }

    func start(_ items: [Item], from sourceName: String, at start: Int = 0) {
        guard !items.isEmpty else { return }
        originalItems = items
        self.items = items
        self.sourceName = sourceName
        index = min(max(start, 0), items.count - 1)
        skipsInARow = 0
        if isShuffled {
            var rng = SystemRandomNumberGenerator()
            (self.items, index) = QueueOrder.shuffled(items, keeping: index, using: &rng)
        }
        isActive = true
        message = nil
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Playing your mix in Spotify")
        }
        playCurrent()
        startPolling()
    }

    /// UI review only: shows the queue as if it were playing, without touching Spotify.
    func showForReview(_ items: [Item], from sourceName: String, at index: Int) {
        self.items = items
        originalItems = items
        self.sourceName = sourceName
        self.index = index
        isActive = true
        isPlaying = true
        position = 74
        duration = 229
        positionReadAt = Date()
    }

    /// Plays a song further up or down the list.
    func jump(to newIndex: Int) {
        guard isActive, items.indices.contains(newIndex), newIndex != index else { return }
        index = newIndex
        playCurrent()
    }

    /// Pauses or resumes Spotify; the queue carries on from the same song.
    func togglePause() {
        guard isActive else { return }
        if case .failure(let error) = SpotifyScript.run("tell application \"Spotify\" to playpause") {
            message = error.localizedDescription
            return
        }
        if isPlaying { position = displayedPosition() }
        isPlaying.toggle()
        positionReadAt = Date()
    }

    /// Where the song is now, estimated from the last check.
    func displayedPosition(at now: Date = Date()) -> Double {
        let moved = isPlaying ? now.timeIntervalSince(positionReadAt) : 0
        return duration > 0 ? min(position + moved, duration) : position
    }

    /// Shuffles the songs after the current one (it keeps playing), or puts the mix back in order.
    func toggleShuffle() {
        isShuffled.toggle()
        UserDefaults.standard.set(isShuffled, forKey: "queue.shuffle")
        guard isActive, let current else { return }
        if isShuffled {
            var rng = SystemRandomNumberGenerator()
            (items, index) = QueueOrder.shuffled(items, keeping: index, using: &rng)
        } else {
            items = originalItems
            index = items.firstIndex(of: current) ?? 0
        }
    }

    /// Off → repeat the mix → repeat this song → off.
    func cycleRepeat() {
        repeatMode = repeatMode.next
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "queue.repeat")
    }

    /// The Next button: always moves on, even when repeating one song.
    func next() {
        move(to: QueueOrder.next(after: index, count: items.count, repeat: repeatMode, songEnded: false))
    }

    /// The Previous button: back to the start of this song if it's a few seconds in,
    /// otherwise the song before.
    func previous() {
        guard isActive else { return }
        if displayedPosition() > 3 || index == 0 {
            playCurrent()
        } else {
            index -= 1
            playCurrent()
        }
    }

    /// A song finished on its own (or couldn't play).
    private func songEnded() {
        move(to: QueueOrder.next(after: index, count: items.count, repeat: repeatMode, songEnded: true))
    }

    private func move(to newIndex: Int?) {
        guard isActive else { return }
        if let newIndex {
            index = newIndex
            playCurrent()
        } else {
            // Spotify would otherwise roll on into its own autoplay.
            pauseSpotify()
            finish("That's the end of the mix.")
        }
    }

    /// Stops the queue and pauses Spotify, so nothing keeps playing after you close it.
    func stop() {
        pauseSpotify()
        finish(nil)
    }

    private func pauseSpotify() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return }
        _ = SpotifyScript.run("tell application \"Spotify\" to pause")
    }

    private func finish(_ note: String?) {
        isActive = false
        isPlaying = false
        pollTask?.cancel()
        pollTask = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        message = note
    }

    private func playCurrent() {
        guard let item = current else { return }
        // If Spotify has to launch first, give the song longer to start before skipping it.
        let launching = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
        let before = launching ? nil : (try? SpotifyScript.observe().get())?.trackURI
        tracker = QueueTracker(expectedID: item.id, expectedTitle: item.title, previousURI: before,
                               patience: launching ? 25 : 8)
        position = 0
        duration = 0
        isPlaying = true
        positionReadAt = Date()
        let front = NSWorkspace.shared.frontmostApplication
        if case .failure(let error) = SpotifyScript.run("tell application \"Spotify\" to play track \"spotify:track:\(item.id)\"") {
            finish(error.localizedDescription)
            return
        }
        keepInBackground(returningTo: front)
    }

    /// Spotify brings itself to the front whenever it's told to play a track. If you were in
    /// another app, hand focus straight back so song changes don't interrupt you. macOS may
    /// refuse that hand-back (apps can't always activate others), so if Spotify is still in
    /// front a moment later it's hidden instead, which always works and leaves you where you were.
    private func keepInBackground(returningTo front: NSRunningApplication?) {
        guard let front, front.bundleIdentifier != SpotifyScript.bundleID else { return }
        Task { @MainActor in
            var triedActivating = false
            // Spotify can take a moment to come forward, so keep an eye out for ~1.5s.
            for delay in [80, 150, 250, 400, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let spotify = NSWorkspace.shared.frontmostApplication,
                      spotify.bundleIdentifier == SpotifyScript.bundleID else { continue }
                if !triedActivating {
                    triedActivating = true
                    if front == NSRunningApplication.current {
                        NSApp.activate()
                    } else {
                        front.activate()
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != SpotifyScript.bundleID { continue }
                }
                spotify.hide()
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isActive else { return }
                self.poll()
            }
        }
    }

    private static let debug = ProcessInfo.processInfo.environment["MJ_QUEUE_DEBUG"] != nil

    private func poll() {
        switch SpotifyScript.observe() {
        case .failure(let error):
            if Self.debug { print("  poll failed: \(error.localizedDescription)") }
            finish(error.localizedDescription)
        case .success(let observation):
            let decision = tracker.observe(observation)
            if decision == .wait, tracker.isOurs(observation) {
                isPlaying = observation.state == "playing"
                position = observation.position
                duration = observation.durationMs / 1000
                positionReadAt = Date()
            }
            if Self.debug { print("  poll: \(observation.state) \(observation.trackURI.suffix(8)) \(Int(observation.position))s → \(decision)") }
            switch decision {
            case .wait: break
            case .advance:
                skipsInARow = 0
                songEnded()
            case .skip:                 // a song that won't play is never repeated
                skipsInARow += 1
                if skipsInARow >= items.count {
                    finish("Spotify wouldn't play any of these songs.")
                } else {
                    next()
                }
            case .stop(let reason): finish(reason)
            }
        }
    }
}

/// What Spotify reports on each poll.
struct PlayerObservation: Equatable, Sendable {
    var running = true
    var state = "playing"
    var trackURI = ""
    var position: Double = 0
    var durationMs: Double = 0
    var name = ""
}

/// Decides, from successive observations, when the current song has finished.
struct QueueTracker {
    enum Decision: Equatable {
        case wait
        /// The song finished: play the next one.
        case advance
        /// Spotify never started the song (e.g. unavailable): move on.
        case skip
        case stop(String)
    }

    let expectedID: String
    let expectedTitle: String
    /// What was playing before we asked for this song, so a change can be recognised.
    let previousURI: String?
    /// Polls (~1s each) to wait for Spotify to start the song before skipping it.
    let patience: Int
    /// Spotify sometimes plays the same song under another track ID (its version for your
    /// country). When that happens this holds the ID it actually used.
    private var adoptedURI: String?
    /// Polls in a row where Spotify is playing some *other* new song instead of ours
    /// (it does this for songs your account or country can't play).
    private var substitutePolls = 0
    private var seenOurs = false
    private var lastPosition: Double = 0
    private var lastDuration: Double = 0
    private var lastSeenAt = Date.distantPast
    private var pollsWithoutOurs = 0

    init(expectedID: String, expectedTitle: String = "", previousURI: String? = nil, patience: Int = 8) {
        self.expectedID = expectedID
        self.expectedTitle = expectedTitle
        self.previousURI = previousURI
        self.patience = patience
    }

    /// Whether Spotify is playing (or paused on) the song this tracker is waiting for.
    func isOurs(_ o: PlayerObservation) -> Bool {
        o.trackURI == "spotify:track:\(expectedID)" || (adoptedURI != nil && o.trackURI == adoptedURI)
    }

    /// The song has had time to finish: it was in its last few seconds on the previous poll,
    /// or (if polls were delayed) enough real time has passed since then to reach its end.
    private func couldHaveFinished(now: Date) -> Bool {
        guard lastDuration > 0 else { return false }
        let remaining = lastDuration - lastPosition
        return remaining <= 3.5 || now.timeIntervalSince(lastSeenAt) >= remaining - 2
    }

    mutating func observe(_ o: PlayerObservation, now: Date = Date()) -> Decision {
        guard o.running else { return .stop("Spotify was closed, so the queue stopped.") }
        if o.trackURI.hasPrefix("spotify:ad:") { return .wait }

        // Accept Spotify's relinked version: the first new song it starts after our request,
        // when its name matches ours.
        if !seenOurs, adoptedURI == nil, o.state == "playing", o.trackURI.hasPrefix("spotify:track:"),
           o.trackURI != "spotify:track:\(expectedID)", o.trackURI != previousURI,
           !expectedTitle.isEmpty, TrackMatcher.titlesMatch(expectedTitle, o.name) {
            adoptedURI = o.trackURI
        }

        if o.trackURI == "spotify:track:\(expectedID)" || (adoptedURI != nil && o.trackURI == adoptedURI) {
            let duration = o.durationMs / 1000
            // Finished: it was ending and is now back at the start (Spotify briefly reports
            // this between songs), or Spotify stopped on its last second.
            if seenOurs, (couldHaveFinished(now: now) && o.position < 2)
                || (o.state != "playing" && duration > 0 && o.position >= duration - 1) {
                return .advance
            }
            seenOurs = true
            lastPosition = o.position
            lastDuration = duration
            lastSeenAt = now
            pollsWithoutOurs = 0
            return .wait
        }

        // Something else is playing.
        if seenOurs {
            return couldHaveFinished(now: now)
                ? .advance   // our song ended and Spotify autoplayed something
                : .stop("You played something else in Spotify, so the MusicJournal queue stopped.")
        }
        // Spotify started a different song in place of ours: it can't play this one. Skip it
        // quickly rather than letting the stand-in play.
        if o.state == "playing", o.trackURI.hasPrefix("spotify:track:"), o.trackURI != previousURI {
            substitutePolls += 1
            if substitutePolls >= 2 { return .skip }
        } else {
            substitutePolls = 0
        }
        pollsWithoutOurs += 1
        return pollsWithoutOurs >= patience ? .skip : .wait
    }
}

/// Talks to the Spotify app through its AppleScript dictionary.
@MainActor
enum SpotifyScript {
    static let bundleID = "com.spotify.client"

    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ source: String) -> Result<String, ScriptError> {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let number = error?[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 {
                return .failure(ScriptError(message:
                    "MusicJournal isn't allowed to control Spotify. Turn it on in System Settings → Privacy & Security → Automation → MusicJournal → Spotify."))
            }
            let detail = error?[NSAppleScript.errorMessage] as? String ?? "unknown error"
            return .failure(ScriptError(message: "Spotify didn't respond: \(detail)"))
        }
        return .success(result.stringValue ?? "")
    }

    /// Reads player state without launching Spotify if it isn't running.
    static func observe() -> Result<PlayerObservation, ScriptError> {
        let source = """
        if application "Spotify" is running then
            tell application "Spotify"
                set s to player state as string
                set u to ""
                set n to ""
                set p to 0
                set d to 0
                try
                    set u to id of current track
                    set d to duration of current track
                    set n to name of current track
                end try
                try
                    set p to player position
                end try
                return "1" & tab & s & tab & u & tab & (p as string) & tab & (d as string) & tab & n
            end tell
        else
            return "0"
        end if
        """
        return run(source).map(parse)
    }

    /// Parses "running⇥state⇥uri⇥position⇥duration". Numbers may use a comma decimal separator.
    nonisolated static func parse(_ text: String) -> PlayerObservation {
        let parts = text.components(separatedBy: "\t")
        guard parts.first == "1", parts.count >= 5 else { return PlayerObservation(running: false) }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return PlayerObservation(
            running: true, state: parts[1], trackURI: parts[2],
            position: number(parts[3]), durationMs: number(parts[4]),
            name: parts.count > 5 ? parts[5...].joined(separator: "\t") : ""
        )
    }
}

/// Where the queue goes next, and how it shuffles. Kept apart from Spotify so it can be tested.
enum QueueOrder {
    /// The index to play after `index`, or nil when the mix is over. Repeat-one only replays
    /// a song that ended by itself; pressing Next still moves on.
    static func next(after index: Int, count: Int, repeat mode: SpotifyQueue.RepeatMode, songEnded: Bool) -> Int? {
        if mode == .one && songEnded { return index }
        if index + 1 < count { return index + 1 }
        return mode == .off ? nil : 0
    }

    /// Keeps the songs already played and the current one in place and shuffles the rest.
    static func shuffled<T, R: RandomNumberGenerator>(_ items: [T], keeping index: Int, using rng: inout R) -> ([T], Int) {
        guard items.indices.contains(index) else { return (items, index) }
        let upcoming = Array(items[(index + 1)...]).shuffled(using: &rng)
        return (Array(items[...index]) + upcoming, index)
    }
}

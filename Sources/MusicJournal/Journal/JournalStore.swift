import AppKit
import Foundation
import LocalAuthentication
import Observation

/// The journal: locked until you unlock it with Touch ID or your Mac password, stored as one
/// AES-GCM encrypted file, and locked again when the Mac sleeps or after 5 minutes away.
@MainActor
@Observable
final class JournalStore {
    private(set) var isLocked = true
    private(set) var entries: [JournalEntry] = []
    var selectedID: JournalEntry.ID?
    private(set) var lastError: String?

    /// Asks the user to prove it's them. Replaced in tests.
    typealias Authenticator = @MainActor () async -> Result<Void, Error>

    private let fileURL: URL
    /// Given whether a journal file already exists (a new key may only be created if not).
    private let cipher: (_ journalExists: Bool) throws -> JournalCipher
    private let authenticate: Authenticator
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The key, read from the Keychain once per unlock and forgotten on lock. Saving reuses
    /// it, so typing doesn't trigger a Keychain prompt on every autosave.
    @ObservationIgnored private var activeCipher: JournalCipher?
    @ObservationIgnored private var resignedAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    static let idleLockAfter: TimeInterval = 5 * 60

    init(
        fileURL: URL = JournalStore.defaultFileURL,
        cipher: @escaping (_ journalExists: Bool) throws -> JournalCipher = { exists in
            JournalCipher(key: try JournalCipher.loadKey(allowCreate: !exists))
        },
        authenticate: @escaping Authenticator = JournalStore.deviceOwnerAuthentication,
        observeSystemEvents: Bool = true
    ) {
        self.fileURL = fileURL
        self.cipher = cipher
        self.authenticate = authenticate
        if observeSystemEvents { observeLockTriggers() }
    }

    static var defaultFileURL: URL {
        AppPaths.support.appendingPathComponent("journal.sealed")
    }

    var selectedEntry: JournalEntry? {
        entries.first { $0.id == selectedID }
    }

    /// Entries grouped by calendar day, newest first.
    var entriesByDay: [(day: Date, entries: [JournalEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// Entries written on a given calendar day, newest first.
    func entries(on day: Date, calendar: Calendar = .current) -> [JournalEntry] {
        entries.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// How the day went: the average rating of that day's entries that have one (0 awful … 1 great).
    func valence(on day: Date, calendar: Calendar = .current) -> Double? {
        let values = entries(on: day, calendar: calendar).compactMap(\.valence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The day's answer to "How was the day?", if it's been given in any of its entries.
    func dayRating(on day: Date, calendar: Calendar = .current) -> DayRating? {
        valence(on: day, calendar: calendar).map(DayRating.init(valence:))
    }

    /// Whether this is the day's first entry: the only one that asks how the day went.
    func isFirstOfDay(_ id: JournalEntry.ID, calendar: Calendar = .current) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return entries(on: entry.createdAt, calendar: calendar).last?.id == id
    }

    /// Rates the whole day from one of its entries. A day has one answer, so the rating
    /// moves to this entry and the day's other entries let go of theirs.
    func setDayRating(_ rating: DayRating?, from id: JournalEntry.ID, calendar: Calendar = .current) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        for other in entries(on: entry.createdAt, calendar: calendar) where other.id != id && other.valence != nil {
            update(other.id) { $0.valence = nil }
        }
        update(id) { $0.valence = rating?.valence }
    }

    /// How a day felt: up to three feelings across that day's entries, most frequent first
    /// (ties go to the most recent).
    func feelings(on day: Date, calendar: Calendar = .current, limit: Int = 3) -> [Feeling] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in entries(on: day, calendar: calendar) {   // newest first
            for feeling in entry.feelings {
                if counts[feeling.id] == nil { order.append(feeling.id) }
                counts[feeling.id, default: 0] += 1
            }
        }
        return order.enumerated()
            .sorted { a, b in
                let (ca, cb) = (counts[a.element]!, counts[b.element]!)
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .prefix(limit)
            .compactMap { Feeling.named($0.element) }
    }

    /// Opens today's newest entry, or starts one.
    func openToday() {
        if let today = entries(on: Date()).first {
            selectedID = today.id
        } else {
            newEntry()
        }
    }

    // MARK: Lock

    func unlock() async {
        guard isLocked else { return }
        lastError = nil
        switch await authenticate() {
        case .success:
            do {
                entries = try load()
                isLocked = false
                if selectedID == nil { selectedID = entries.max { $0.createdAt < $1.createdAt }?.id }
            } catch {
                lastError = "Couldn't open the journal: \(error.localizedDescription)"
            }
        case .failure(let error):
            if let la = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(la.code) { return }
            lastError = error.localizedDescription
        }
    }

    /// Saves any pending edits, then forgets the decrypted entries.
    func lock() {
        guard !isLocked else { return }
        flush()
        activeCipher = nil
        entries = []
        selectedID = nil
        isLocked = true
    }

    // MARK: Editing

    @discardableResult
    func add(_ entry: JournalEntry) -> JournalEntry.ID {
        entries.append(entry)
        selectedID = entry.id
        scheduleSave()
        return entry.id
    }

    func newEntry() {
        add(JournalEntry())
    }

    func update(_ id: JournalEntry.ID, _ change: (inout JournalEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        entries[index].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ id: JournalEntry.ID) {
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = entries.max { $0.createdAt < $1.createdAt }?.id }
        scheduleSave()
    }

    // MARK: Storage

    private func load() throws -> [JournalEntry] {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let active = try cipher(exists)
        activeCipher = active
        guard exists else { return [] }
        return try active.open(Data(contentsOf: fileURL))
    }

    /// Debounced so typing doesn't rewrite the file on every keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes now. Only ever writes while unlocked, so a locked store can't overwrite the file
    /// with an empty list.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !isLocked, let active = activeCipher else { return }
        do {
            let data = try active.seal(entries)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            lastError = nil
        } catch {
            lastError = "Couldn't save the journal: \(error.localizedDescription)"
        }
    }

    // MARK: Auto-lock

    private func observeLockTriggers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedAt = Date() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let away = self.resignedAt else { return }
                self.resignedAt = nil
                if Date().timeIntervalSince(away) > Self.idleLockAfter { self.lock() }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }

    /// Touch ID, or your Mac login password when Touch ID isn't available.
    static let deviceOwnerAuthentication: Authenticator = {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open your journal")
            return ok ? .success(()) : .failure(LAError(.authenticationFailed))
        } catch {
            return .failure(error)
        }
    }
}

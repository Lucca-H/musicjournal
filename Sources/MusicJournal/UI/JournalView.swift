import SwiftUI

struct JournalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.journal.isLocked {
            LockedJournal()
        } else {
            HStack(alignment: .top, spacing: 20) {
                JournalSidebar()
                    .frame(width: 290)
                Group {
                    if let id = model.journal.selectedID, model.journal.selectedEntry != nil {
                        JournalEntryEditor(entryID: id)
                            .id(id)
                    } else {
                        EmptyJournal()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
        }
    }
}

// MARK: Locked

private struct LockedJournal: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("Your journal is locked")
                    .font(.system(.title2, design: .serif))
                Text("Unlock with Touch ID or your Mac password. Entries are encrypted on this Mac and never sent to Claude.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                Task { await model.journal.unlock() }
            } label: {
                Label("Unlock", systemImage: "touchid")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if let error = model.journal.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.clay)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(36)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Sidebar

private struct JournalSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let journal = model.journal
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.beginQuickLog() }
                } label: {
                    Label("Add log", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .help("A quick log: how the day's going and a line (⇧⌘L)")
                Button {
                    journal.openToday()
                } label: {
                    Label("Write", systemImage: "square.and.pencil")
                }
                .buttonStyle(.glass)
                .help("Open today's page to write more (⌘N for a new one)")
                Spacer()
                Button {
                    journal.lock()
                } label: {
                    Image(systemName: "lock")
                }
                .buttonStyle(.glass)
                .help("Lock journal (⌘L)")
            }

            JournalMonthChart()
                .padding(.vertical, 4)

            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(journal.entriesByDay, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dayLabel(group.day).uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(1.1)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 10)
                            ForEach(group.entries) { entry in
                                EntryRow(entry: entry, selected: entry.id == journal.selectedID) {
                                    journal.selectedID = entry.id
                                }
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                                    removal: .opacity))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

private struct EntryRow: View {
    let entry: JournalEntry
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(entry.valence.map(Theme.blend(valence:)) ?? entry.feelings.first?.color ?? Color.primary.opacity(0.15))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .lineLimit(1)
                    Text("\(TimeOfDay.part(forHour: Calendar.current.component(.hour, from: entry.createdAt))) · \(entry.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !entry.stuckSongs.isEmpty {
                        Label("\(entry.stuckSongs.count) song\(entry.stuckSongs.count == 1 ? "" : "s") stuck", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.accent.opacity(0.2) : (hovering ? Color.primary.opacity(0.05) : .clear),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct EmptyJournal: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("Nothing here yet")
                .font(.system(.title2, design: .serif))
            Text("Write about today, or save a mood from its results.")
                .foregroundStyle(.secondary)
            Button("Write about today") { model.journal.openToday() }
                .buttonStyle(.glassProminent)
        }
    }
}

// MARK: Editor

private struct JournalEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let entryID: JournalEntry.ID
    @State private var newSong = ""
    @State private var confirmDelete = false
    @FocusState private var writing: Bool
    /// What you're typing. The box edits this directly and it's saved to the journal as you
    /// go, so keystrokes are never lost to a stale copy and the cursor stays put.
    @State private var draft = ""
    @State private var loadedDraft = false
    @State private var changingDay = false

    private var entry: JournalEntry? { model.journal.entries.first { $0.id == entryID } }

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header(entry)
                    dayRating(entry)
                    writingArea(entry)
                    feelingPicker(entry)
                    songs(entry)
                    HStack {
                        Spacer()
                        Button("Delete entry", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.glass)
                    }
                }
                .padding(30)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline(scheme)))
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.journal.delete(entryID) }
            } message: {
                Text("This can't be undone.")
            }
            .onAppear {
                if !loadedDraft {
                    draft = entry.text
                    loadedDraft = true
                }
                if entry.text.isEmpty && entry.mood == nil { writing = true }
            }
            .onChange(of: draft) { _, newValue in
                guard loadedDraft else { return }
                model.journal.update(entryID) { $0.text = newValue }
            }
        }
    }

    private func header(_ entry: JournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.createdAt, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.system(size: 28, weight: .regular, design: .serif))
            Text("\(TimeOfDay.describe(entry.createdAt)) · \(entry.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let mood = entry.mood {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.valence.map(Theme.blend(valence:)) ?? entry.feelings.first?.color ?? Color.primary.opacity(0.2))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“\(mood)”")
                            .font(.system(.title3, design: .serif).italic())
                        if let mix = entry.mixName {
                            Text("Mix: \(mix)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
    }

    /// One scale from awful to great, asked once a day. The day's first entry asks it; once
    /// it's answered (or on later entries) it shrinks to a quiet line you can change.
    /// This is what colours the day in the month chart.
    @ViewBuilder
    private func dayRating(_ entry: JournalEntry) -> some View {
        let current = model.journal.dayRating(on: entry.createdAt)
        let asking = changingDay || (current == nil && model.journal.isFirstOfDay(entryID))
        Group {
            if asking {
                DayRatingPicker(title: "How was the day?", current: current) { rating in
                    model.journal.setDayRating(rating, from: entryID)
                    changingDay = false
                }
            } else {
                DayRatingSummary(current: current) { changingDay = true }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: asking)
    }

    /// Optional detail: up to three of fourteen feelings, as colour chips that wrap.
    /// "Suggest from my writing" asks Claude to rate the day and pick them from the entry.
    private func feelingPicker(_ entry: JournalEntry) -> some View {
        let chosen = entry.feelings.map(\.id)
        let suggesting = model.feelingSuggestionID == entryID
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feelings")
                    .foregroundStyle(.secondary)
                Text("optional, up to \(Feeling.maxPerEntry)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    model.suggestFeelings(for: entryID)
                } label: {
                    if suggesting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading…") }
                    } else {
                        Label("Suggest from my writing", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(suggesting || (entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.mood == nil))
                .help("Sends this entry's text to Claude, which rates the day and picks up to three feelings. Nothing is sent unless you press this.")
            }

            CenteredFlowLayout(spacing: 6, alignLeading: true) {
                ForEach(Feeling.all) { feeling in
                    let selected = chosen.contains(feeling.id)
                    Button {
                        toggle(feeling, chosen: chosen)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(feeling.color).frame(width: 10, height: 10)
                            Text(feeling.label).font(.callout)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            selected ? feeling.color.opacity(0.35) : Theme.surface(scheme),
                            in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? feeling.color : Theme.hairline(scheme), lineWidth: selected ? 1.5 : 1))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!selected && chosen.count >= Feeling.maxPerEntry)
                    .animation(.snappy(duration: 0.15), value: selected)
                }
            }

            if let note = entry.feelingNote {
                Label(note, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggle(_ feeling: Feeling, chosen: [String]) {
        model.journal.update(entryID) { entry in
            var ids = chosen
            if let i = ids.firstIndex(of: feeling.id) { ids.remove(at: i) } else if ids.count < Feeling.maxPerEntry { ids.append(feeling.id) }
            entry.feelingIDs = ids
            entry.feelingNote = nil       // your pick now, not Claude's
        }
    }

    private func writingArea(_ entry: JournalEntry) -> some View {
        let font = Font.system(size: 16, design: .serif)
        // The invisible copy of the text sizes the box, so it grows as you write and only
        // the page scrolls (no box-inside-a-scroll-view).
        return ZStack(alignment: .topLeading) {
            Text(draft + "\n ")
                .font(font)
                .lineSpacing(4)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)
                .accessibilityHidden(true)
            TextEditor(text: $draft)
                .font(font)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused($writing)
        }
            .frame(minHeight: 200, alignment: .topLeading)
            .padding(12)
            .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(writing ? Theme.accent.opacity(0.5) : Theme.hairline(scheme))
            )
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(entry.mood == nil
                         ? "What happened today? Little details count."
                         : "How are you, really? What stayed with you?")
                        .font(.system(size: 16, design: .serif))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    private func songs(_ entry: JournalEntry) -> some View {
        let stuck = entry.songs.filter(\.stuck)
        let others = entry.songs.filter { !$0.stuck }
        return VStack(alignment: .leading, spacing: 16) {
            if !entry.songs.isEmpty {
                let finding = model.journalLookupID == entryID
                HStack(spacing: 10) {
                Button {
                    model.playJournalEntry(entryID)
                } label: {
                    if finding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finding songs on Spotify…")
                        }
                    } else {
                        Label(others.isEmpty ? "Play these songs in Spotify" : "Play this mix in Spotify",
                              systemImage: "play.fill")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(finding || model.journalLookupID != nil)
                .help("Plays every song from this entry, in order, the way you heard it")
                let findingVideos = model.journalYouTubeID == entryID
                Button {
                    model.playJournalEntryOnYouTube(entryID)
                } label: {
                    if findingVideos {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finding on YouTube…")
                        }
                    } else {
                        Label("YouTube", systemImage: "play.rectangle.fill")
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.journalYouTubeID != nil)
                .help("Queues this entry's songs on YouTube and opens them in your browser")
                if !stuck.isEmpty && !others.isEmpty && !finding {
                    Menu {
                        Button("In Spotify") { model.playJournalEntry(entryID, onlyStuck: true) }
                            .disabled(model.journalLookupID != nil)
                        Button("On YouTube") { model.playJournalEntryOnYouTube(entryID, onlyStuck: true) }
                            .disabled(model.journalYouTubeID != nil)
                    } label: {
                        Label("Only the \(stuck.count == 1 ? "song" : "\(stuck.count) songs") that stuck", systemImage: "star")
                    }
                    .buttonStyle(.glass)
                    .fixedSize()
                }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Songs that stuck")
                if stuck.isEmpty {
                    Text(others.isEmpty
                         ? "Add a song that stayed with you."
                         : "Star songs from the mix below, or add your own.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    songList(stuck)
                }
                TextField("Add a song: Title — Artist", text: $newSong)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit(addSong)
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("From the mix")
                    songList(others)
                }
            }
        }
    }

    private func songList(_ songs: [JournalSong]) -> some View {
        VStack(spacing: 0) {
            ForEach(songs) { song in
                JournalSongRow(song: song) {
                    model.journal.update(entryID) { entry in
                        if let i = entry.songs.firstIndex(where: { $0.id == song.id }) { entry.songs[i].stuck.toggle() }
                    }
                } open: {
                    model.open(uri: song.spotifyURI, webURL: song.webURL)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    private func addSong() {
        let ref = SongRef(line: newSong)
        guard !ref.title.isEmpty else { return }
        let artist = ref.artist ?? ""
        let link = SpotifyLinks.search("\(ref.title) \(artist)".trimmingCharacters(in: .whitespaces))
        let song = JournalSong(
            id: "\(ref.title)|\(artist)".matchKey, title: ref.title, artist: artist, imageURL: nil,
            spotifyURI: link.uri, webURL: link.webURL, stuck: true
        )
        model.journal.update(entryID) { entry in
            if let i = entry.songs.firstIndex(where: { $0.id == song.id }) {
                entry.songs[i].stuck = true
            } else {
                entry.songs.insert(song, at: 0)
            }
        }
        newSong = ""
    }
}

private struct JournalSongRow: View {
    let song: JournalSong
    let toggleStar: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: song.imageURL, symbol: "music.note")
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                if !song.artist.isEmpty {
                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if hovering {
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                toggleStar()
                Haptics.tap()
            } label: {
                Image(systemName: song.stuck ? "star.fill" : "star")
                    .foregroundStyle(song.stuck ? Theme.accent : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .symbolEffect(.bounce, value: song.stuck)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(song.stuck ? "Remove from songs that stuck" : "This one stuck")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}

// MARK: Day rating

/// The five circles, awful to great. Tapping the chosen one again clears it.
struct DayRatingPicker: View {
    let title: String
    let current: DayRating?
    var size: CGFloat = 24
    let choose: (DayRating?) -> Void

    var body: some View {
        HStack(spacing: 18) {
            Text(title)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(DayRating.allCases) { rating in
                    let selected = current == rating
                    Button {
                        choose(selected ? nil : rating)
                        if !selected { Haptics.tap() }
                    } label: {
                        VStack(spacing: 5) {
                            Circle()
                                .fill(rating.color)
                                .frame(width: size, height: size)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.75 : 0), lineWidth: 2).padding(-3))
                                .scaleEffect(selected ? 1.12 : 1)
                            Text(rating.label)
                                .font(.caption)
                                .foregroundStyle(selected ? .primary : .tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
                    .help(selected ? "Clear" : "\(rating.label) day")
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
    }
}

/// The day's answer as one quiet line ("A good day · Change"), or a small invitation if
/// the day hasn't been rated yet.
struct DayRatingSummary: View {
    let current: DayRating?
    let change: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let current {
                Circle().fill(current.color).frame(width: 10, height: 10)
                Text("\(current.article) \(current.label.lowercased()) day")
                    .foregroundStyle(.secondary)
                Button("Change", action: change)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            } else {
                Button(action: change) {
                    HStack(spacing: 8) {
                        Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .frame(width: 10, height: 10)
                        Text("Rate the day")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .transition(.opacity)
    }
}

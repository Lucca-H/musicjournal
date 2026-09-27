import SwiftUI

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let recommendation: Recommendation

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            header

            if !recommendation.fromLibrary.isEmpty {
                section("From your library") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(recommendation.fromLibrary) { PlaylistCard(picked: $0) }
                    }
                }
            }

            if !recommendation.discovered.isEmpty {
                section("Found on Spotify") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(recommendation.discovered) { PlaylistCard(picked: $0) }
                    }
                }
            }

            mixSection

            if !recommendation.searchPhrases.isEmpty {
                section("Playlists to find on Spotify") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(Array(recommendation.searchPhrases.enumerated()), id: \.element) { index, phrase in
                            SearchPhraseCard(
                                phrase: phrase,
                                index: index,
                                energy: recommendation.plan.energy,
                                valence: recommendation.plan.valence
                            )
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // When you asked, in your locale: "Saturday 10:04 PM · “exhausted”".
            HStack(spacing: 6) {
                Text(recommendation.createdAt, format: .dateTime.weekday(.wide).hour().minute())
                Text("·")
                Text("“\(recommendation.mood.truncated(to: 60))”")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(recommendation.createdAt.formatted(date: .complete, time: .standard))
            Text(recommendation.plan.interpretation)
                .font(.system(.title2, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(recommendation.plan.keywords, id: \.self) { keyword in
                    Text(keyword)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.surface(scheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline(scheme)))
                }
                Spacer()
                Button {
                    Task { await model.saveToJournal() }
                } label: {
                    Label(model.isSavedToJournal ? "In your journal" : "Save to journal",
                          systemImage: model.isSavedToJournal ? "book.fill" : "book")
                }
                .buttonStyle(.glass)
                .help("Save this mood and its songs as a journal entry")
                Label("via \(recommendation.brain.label)",
                      systemImage: recommendation.brain == .claude ? "sparkle" : "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(recommendation.fallbackReason.map { "Claude wasn't available: \($0)" } ?? "")
            }
            if recommendation.fallbackReason != nil {
                Text("Claude wasn't available, so this used Apple's on-device model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mixSection: some View {
        section("Custom mix") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recommendation.plan.mixName)
                            .font(.system(.title2, design: .serif).weight(.medium))
                        Text(recommendation.plan.mixDescription)
                            .foregroundStyle(.secondary)
                        Text(mixSummary)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    mixActions
                }

                VStack(spacing: 0) {
                    ForEach(recommendation.mix) { entry in
                        TrackRow(entry: entry, catalogName: recommendation.catalogName)
                        if entry.id != recommendation.mix.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline(scheme)))
            }
        }
    }

    private var mixSummary: String {
        let found = recommendation.mix.filter { $0.track != nil }.count
        let missing = recommendation.mix.filter { $0.lookup == .notFound }.count
        let unchecked = recommendation.mix.filter { $0.lookup == .unverified }.count
        var parts = ["\(found) songs verified"]
        if missing > 0 { parts.append("\(missing) not found") }
        if unchecked > 0 { parts.append("\(unchecked) not verified") }
        if model.linkState == .ready {
            let onSpotify = recommendation.mix.filter { model.spotifyLinks[$0.id] != nil }.count
            return "\(onSpotify) of \(recommendation.mix.count) songs linked to Spotify"
        }
        let hint = recommendation.canSaveMix ? "" : " · right-click a song to play from there"
        return parts.joined(separator: " · ") + hint
    }

    @ViewBuilder
    private var mixActions: some View {
        if !recommendation.canSaveMix {
            HStack(spacing: 8) {
                Menu {
                    Button(model.copiedMix ? "Copied" : "Copy song list as text") { model.copyMix() }
                    Button("Copy Spotify links") { model.copySpotifyLinks() }
                        .disabled(model.linkState != .ready)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .controlSize(.large)
                .fixedSize()
                .help("More")

                Button {
                    model.playMixOnYouTube()
                } label: {
                    if model.youtubeState == .finding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finding on YouTube…")
                        }
                    } else {
                        Label("YouTube", systemImage: "play.rectangle.fill")
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(model.youtubeState == .finding)
                .help("Queues the whole mix on YouTube and opens it in your browser")

                Button {
                    model.playMixInSpotify()
                } label: {
                    if model.linkState == .finding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Finding songs on Spotify…")
                        }
                    } else {
                        Label("Play in Spotify", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.linkState == .finding)
                .help("Plays the whole mix in the Spotify app, one song after another")
            }
        } else if let saved = model.savedMix {
            Button {
                model.open(uri: saved.uri, webURL: saved.webURL)
            } label: {
                Label("Open in Spotify", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            let found = model.keptMix.compactMap(\.track?.uri).count
            Button {
                Task { await model.saveMix() }
            } label: {
                if model.isSavingMix {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Save to Spotify", systemImage: "plus.circle")
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(found == 0 || model.isSavingMix)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Free mode stand-in for a playlist card: the search phrase set large on a mood-tinted
/// tile. Clicking runs that search in Spotify, where the real playlists are.
struct SearchPhraseCard: View {
    @Environment(AppModel.self) private var model
    let phrase: String
    let index: Int
    let energy: Double
    let valence: Double
    @State private var hovering = false

    var body: some View {
        // Walk the palette from the mood's tone so the row reads as a family, not clones.
        let start = Theme.moodTones.firstIndex(of: Theme.tone(forValence: valence)) ?? 0
        let tone = Theme.moodTones[(start + index) % Theme.moodTones.count]
        let top = tone
        let bottom = tone.mix(with: Theme.charcoal, by: 0.62 - energy * 0.15)

        Button {
            model.openSearch(phrase)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(phrase)
                        .font(.system(size: 20, weight: .medium, design: .serif))
                        .foregroundStyle(Color(red: 0.97, green: 0.95, blue: 0.92))
                        .lineLimit(4)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .padding(16)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 12 : 6, y: 4)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .padding(8)
                        .opacity(hovering ? 1 : 0)
                }
                Text("Search on Spotify")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help("Search Spotify for “\(phrase)”")
    }
}

struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    let picked: PickedPlaylist
    @State private var hovering = false

    var body: some View {
        let playlist = picked.playlist
        Button {
            model.open(uri: playlist.uri, webURL: playlist.webURL)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Artwork(url: playlist.imageURL, symbol: "music.note.list")
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 12 : 6, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.accent)
                            .padding(8)
                            .opacity(hovering ? 1 : 0)
                    }
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(picked.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help(playlist.description.isEmpty ? playlist.name : playlist.description)
    }
}

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let entry: MixEntry
    let catalogName: String
    @State private var hovering = false

    private var isMissing: Bool { entry.lookup == .notFound && spotify == nil }
    private var isNowPlaying: Bool {
        guard let current = model.queue.current, let spotify else { return false }
        return current.id == spotify.id
    }
    /// Real Spotify track, once "Open in Spotify" has looked the mix up (free mode).
    private var spotify: SpotifyTrackRef? { model.spotifyLinks[entry.id] }

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isNowPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    Text(entry.track?.name ?? entry.idea.title)
                        .lineLimit(1)
                        .fontWeight(isNowPlaying ? .semibold : .regular)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            feedbackButtons
            if hovering {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Open in Spotify")
            } else if let ms = entry.track?.durationMs {
                Text(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .opacity(isMissing || model.feedback(for: entry) == .skipped ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if model.recommendation?.canSaveMix == false {
                Button("Play from here in Spotify") { model.playMixInSpotify(startingAt: entry.id) }
                Button("Play from here on YouTube") { model.playMixOnYouTube(startingAt: entry.id) }
            }
            Button("Open in Spotify") { openInSpotify() }
        }
        .onTapGesture(perform: openInSpotify)
    }

    private func openInSpotify() {
        if let spotify {
            model.open(uri: spotify.uri, webURL: spotify.webURL)
        } else {
            let target = entry.openTarget
            model.open(uri: target.uri, webURL: target.webURL)
        }
    }

    /// Thumbs up/down. Shown on hover, and stay visible once set.
    @ViewBuilder
    private var feedbackButtons: some View {
        let current = model.feedback(for: entry)
        if hovering || current != nil {
            HStack(spacing: 2) {
                thumb(.liked, systemImage: current == .liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                      help: current == .liked ? "Remove from songs you liked" : "More like this")
                thumb(.skipped, systemImage: current == .skipped ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                      help: current == .skipped ? "Allow this song again" : "Never suggest this song")
            }
        }
    }

    private func thumb(_ kind: AppModel.Feedback, systemImage: String, help: String) -> some View {
        Button {
            model.toggleFeedback(kind, for: entry)
            Haptics.tap()
        } label: {
            Image(systemName: systemImage)
                .font(.caption)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .symbolEffect(.bounce, value: model.feedback(for: entry) == kind)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var subtitle: String {
        let artist = entry.track?.artist ?? entry.idea.artist
        if spotify != nil { return artist }
        // Usually a label that blocks the Claude connector, not a missing song.
        if model.linkState == .ready { return "\(artist) · add by hand" }
        switch entry.lookup {
        case .found: return artist
        case .notFound: return "\(artist) · not found on \(catalogName)"
        case .unverified: return "\(artist) · not verified"
        }
    }

    /// Artwork doubles as the preview button when a 30-second clip is available.
    @ViewBuilder
    private var artwork: some View {
        let playing = entry.track.map { model.player.playingID == $0.id } ?? false
        Artwork(url: entry.track?.imageURL ?? spotify?.imageURL, symbol: "music.note")
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if let track = entry.track, let preview = track.previewURL, hovering || playing {
                    Button {
                        model.player.toggle(id: track.id, url: preview)
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Stop preview" : "Play a 30-second preview")
                }
            }
    }
}

struct Artwork: View {
    let url: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(Image(systemName: symbol).foregroundStyle(.secondary))
            }
        }
    }
}


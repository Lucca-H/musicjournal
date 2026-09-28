import SwiftUI

/// Floating glass player shown while MusicJournal is feeding songs to Spotify:
/// song, the usual three controls, a thin progress line, what's up next, and stop.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingList = false

    var body: some View {
        let queue = model.queue
        if let item = queue.current {
            HStack(spacing: 14) {
                Button(action: showSpotify) {
                    HStack(spacing: 12) {
                        Artwork(url: item.imageURL, symbol: "music.note")
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            ProgressLine()
                                .padding(.top, 3)
                        }
                        .frame(width: 210, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show in Spotify")

                HStack(spacing: 2) {
                    toggle("shuffle", on: queue.isShuffled,
                           help: queue.isShuffled ? "Shuffle is on: turn it off to play in order" : "Shuffle the rest of the mix") {
                        queue.toggleShuffle()
                    }
                    control("backward.fill", help: "Previous song (or back to the start of this one)") { queue.previous() }
                    control(queue.isPlaying ? "pause.fill" : "play.fill",
                            help: queue.isPlaying ? "Pause" : "Play", size: 17) { queue.togglePause() }
                        .contentTransition(.symbolEffect(.replace))
                    control("forward.fill",
                            help: queue.index + 1 < queue.items.count || queue.repeatMode != .off ? "Next song" : "End the mix") { queue.next() }
                    toggle(queue.repeatMode == .one ? "repeat.1" : "repeat", on: queue.repeatMode != .off,
                           help: repeatHelp(queue.repeatMode)) {
                        queue.cycleRepeat()
                    }
                }

                Divider().frame(height: 24)

                Button {
                    showingList.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet")
                        Text("\(queue.index + 1) of \(queue.items.count)")
                            .font(Theme.smallPrint)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("See the whole mix and jump to any song")
                .popover(isPresented: $showingList, arrowEdge: .top) {
                    UpNextList()
                }

                control("stop.fill", help: "Stop the mix and pause Spotify") { queue.stop() }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let message = queue.message {
            HStack(spacing: 10) {
                Text(message).font(.callout)
                Button {
                    queue.message = nil
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity)
        }
    }

    private func showSpotify() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first?.activate()
    }

    private func repeatHelp(_ mode: SpotifyQueue.RepeatMode) -> String {
        switch mode {
        case .off: "Repeat the mix"
        case .all: "Repeating the mix. Click to repeat just this song"
        case .one: "Repeating this song. Click to turn repeat off"
        }
    }

    /// Shuffle and repeat: dim when off, accent-coloured with a small dot when on.
    private func toggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 30)
                .overlay(alignment: .bottom) {
                    Circle().fill(Theme.accent).frame(width: 3, height: 3)
                        .opacity(on ? 1 : 0)
                        .offset(y: -1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .animation(.snappy(duration: 0.2), value: on)
    }

    private func control(_ symbol: String, help: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// A hairline that fills as the song plays, moving smoothly between Spotify checks.
private struct ProgressLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.queue
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let fraction = queue.duration > 0 ? queue.displayedPosition(at: context.date) / queue.duration : 0
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Theme.accent)
                            .frame(width: geo.size.width * min(max(fraction, 0), 1))
                            .animation(.linear(duration: 0.25), value: fraction)
                    }
                }
                .frame(height: 3)
                Text(queue.duration > 0 ? Self.time(queue.displayedPosition(at: context.date)) : "–:––")
                    .font(Theme.smallPrint)
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// The whole mix: played songs dimmed, the current one marked, click any to play it.
private struct UpNextList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.queue
        VStack(alignment: .leading, spacing: 8) {
            Text(queue.sourceName)
                .font(Theme.Serif.small)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(queue.items.enumerated()), id: \.element.id) { i, item in
                            let isCurrent = i == queue.index
                            Button {
                                queue.jump(to: i)
                            } label: {
                                HStack(spacing: 10) {
                                    Group {
                                        if isCurrent {
                                            Image(systemName: queue.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                                .foregroundStyle(Theme.accent)
                                        } else {
                                            Text("\(i + 1)").font(Theme.smallPrint)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .fontWeight(isCurrent ? .semibold : .regular)
                                            .lineLimit(1)
                                        Text(item.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .opacity(i < queue.index ? 0.5 : 1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(isCurrent ? Theme.accent.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isCurrent ? "Playing now" : "Play this song")
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onAppear { proxy.scrollTo(queue.index, anchor: .center) }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 360)
    }
}

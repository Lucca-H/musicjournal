import SwiftUI

/// First-run welcome tour. Centred glass card, one idea per step, skippable at any point.
/// Replay it from Help › Welcome Tour.
struct WelcomeFlow: View {
    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable {
        case welcome, howItWorks, setup, taste, journal, done
    }

    @State private var forward = true

    /// The current step lives on the model so the tour can be replayed from the start
    /// (and opened at a given step for UI review).
    private var step: Step { Step(rawValue: model.welcomeStep) ?? .welcome }

    var body: some View {
        VStack(spacing: 26) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .howItWorks: HowItWorksStep()
                case .setup: SetupStep()
                case .taste: TasteStep()
                case .journal: JournalStep()
                case .done: DoneStep()
                }
            }
            // Each step fades with a short nudge in the direction of travel, and stays inside
            // the card: a fixed-height, clipped stage, so nothing flies across the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
                removal: .opacity.combined(with: .offset(x: forward ? -28 : 28))))
            .id(step)
            .frame(height: 400)
            .clipped()

            footer
        }
        .padding(36)
        .frame(width: 580)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.28), value: step)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Theme.accent : Color.primary.opacity(0.18))
                        .frame(width: s == step ? 18 : 7, height: 7)
                }
            }
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            HStack {
                if step != .welcome {
                    Button("Back") { go(-1) }
                        .buttonStyle(.glass)
                } else {
                    Button("Skip tour") { model.finishWelcome() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if step == .done {
                    Button {
                        model.finishWelcome()
                    } label: {
                        Text("Start").frame(minWidth: 110)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        go(1)
                    } label: {
                        Text(step == .taste ? "Continue" : "Next").frame(minWidth: 110)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        model.welcomeStep = next.rawValue
    }
}

// MARK: Steps

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .regular, design: .serif))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            VStack(spacing: 10) {
                Text("MusicJournal")
                    .font(.system(size: 40, weight: .regular, design: .serif))
                Text("Tell it how you feel. Get the music for it.\nKeep the days that mattered.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 10)
    }
}

private struct HowItWorksStep: View {
    var body: some View {
        VStack(spacing: 26) {
            StepHeader(title: "How it works", subtitle: "All on your Mac.")
            VStack(alignment: .leading, spacing: 20) {
                row("text.bubble", "Say how you feel",
                    "In your own words. Claude reads the mood and picks a mix, with playlists to explore.")
                row("play.circle", "Play it in Spotify",
                    "MusicJournal plays the mix in the Spotify app, one song after another. A free account is fine.")
                row("book.closed", "Keep a journal",
                    "Add a quick log or write more, save the songs that stuck, and watch your month fill with colour.")
                row("leaf", "Take a breath",
                    "The Zen corner has a sand garden and a rake, for when you just need a minute.")
            }
            .frame(maxWidth: 420)
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Check your setup", subtitle: "MusicJournal uses the apps you already have. No API keys, no extra accounts.")
            VStack(alignment: .leading, spacing: 16) {
                claudeRow
                statusRow(
                    ok: model.spotifyAppInstalled,
                    title: "Spotify app",
                    detail: model.spotifyAppInstalled
                        ? "Installed. Mixes play here."
                        : "Not found. Install the Spotify desktop app to play mixes. Songs will open on the web until then.")
                statusRow(
                    ok: nil,
                    title: "Spotify in Claude",
                    detail: "For Play in Spotify: in claude.ai, open Settings → Connectors and connect Spotify.")
            }
            .frame(maxWidth: 440)
        }
        .task {
            if model.claudeCheck == .unchecked { await model.checkClaude() }
        }
    }

    private var claudeRow: some View {
        let (ok, detail): (Bool?, String) = switch model.claudeCheck {
        case .unchecked, .checking: (nil, "Checking…")
        case .ready: (true, "Signed in and ready. Picks music using your Claude plan.")
        case .notInstalled: (false, "Not found. Install Claude Code and sign in, then check again.")
        case .problem(let message): (false, message.truncated(to: 160))
        }
        return HStack(alignment: .top) {
            statusRow(ok: ok, title: "Claude Code", detail: detail, busy: model.claudeCheck == .checking)
            if model.claudeCheck != .checking && model.claudeCheck != .ready {
                Button("Check again") { Task { await model.checkClaude() } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    private func statusRow(ok: Bool?, title: String, detail: String, busy: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundStyle(ok == true ? Theme.accent : ok == false ? Theme.clay : Color.secondary)
                }
            }
            .font(.title3)
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TasteStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 22) {
            StepHeader(title: "Your taste, if you like",
                       subtitle: "Your mood always leads. This just nudges the picks. Skip it, or change it any time in Settings.")
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Use my taste", selection: $model.tasteInfluence) {
                        ForEach(TasteInfluence.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.tasteInfluence.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                MultilineField(title: "Artists you like", text: $model.profileArtistsText,
                               placeholder: "Separated by commas or new lines")
                    .disabled(model.tasteInfluence == .off)
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct JournalStep: View {
    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Your journal is private", subtitle: "Write about today, keep the songs that stuck, and see your month in colour.")
            VStack(alignment: .leading, spacing: 16) {
                row("touchid", "Locked", "Opens with Touch ID or your Mac password.")
                row("lock.shield", "Encrypted on this Mac", "Entries are never sent to Claude or anywhere else.")
                row("moon.zzz", "Locks itself", "When your Mac sleeps, the screen locks, or you're away for 5 minutes. ⌘L locks it now.")
                row("paintpalette", "Your month at a glance", "Rate each day from awful to great and the calendar fills in. Add feelings too, or let Claude suggest them from what you wrote.")
            }
            .frame(maxWidth: 420)
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "You're set", subtitle: "A few shortcuts worth knowing.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                shortcut("⌘↩", "Find music for your mood")
                shortcut("⌘N", "New journal entry")
                shortcut("⌘L", "Lock the journal")
                shortcut("⌘,", "Personalize")
            }
            .frame(maxWidth: 360)
        }
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        GridRow {
            Text(keys)
                .font(.body.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .gridColumnAlignment(.trailing)
            Text(what).foregroundStyle(.secondary)
        }
    }
}

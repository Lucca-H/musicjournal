import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            DuskBackground(
                energy: model.recommendation?.plan.energy ?? 0.4,
                valence: model.recommendation?.plan.valence ?? 0.5
            )
            .ignoresSafeArea()

            if model.showWelcome {
                WelcomeFlow()
            } else {
                switch model.phase {
                case .needsSetup, .signedOut:
                    OnboardingView()
                case .loadingProfile:
                    ProgressView("Reading your Spotify taste…")
                        .controlSize(.large)
                        .padding(28)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                case .ready:
                    switch model.tab {
                    case .mood: MainScreen()
                    case .journal: JournalView()
                    case .zen: ZenView()
                    }
                }
            }
        }
        // The player takes its own space at the bottom, so it never covers the songs.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar()
                .padding(.bottom, model.queue.current == nil && model.queue.message == nil ? 0 : 16)
                .animation(.smooth(duration: 0.3), value: model.queue.current?.id)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                LoggedToast(text: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        // Warm text, never pure white or black; .secondary and .tertiary follow it.
        .foregroundStyle(Theme.text(scheme))
        .sheet(isPresented: Bindable(model).showQuickLog) {
            QuickLogSheet()
        }
        .tint(Theme.accent)
        .toolbar {
            if model.phase == .ready && !model.showWelcome {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: Bindable(model).tab) {
                        ForEach(AppModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }
            // Settings live in their own window (⌘,); this makes them findable from here.
            if model.phase == .ready && !model.showWelcome {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.beginQuickLog() }
                    } label: {
                        Label("Add log", systemImage: "plus")
                    }
                    .help("Add a quick log (⇧⌘L)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Personalize", systemImage: "slider.horizontal.3")
                }
                .help("Personalization and settings (⌘,)")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// Before the first mood the composer sits in the middle of the window; once there are
/// results (or a request is running) it moves to the top and results flow underneath.
private struct MainScreen: View {
    @Environment(AppModel.self) private var model

    private var isEmpty: Bool { model.recommendation == nil && !model.isWorking && !isFailed }
    private var isFailed: Bool {
        if case .failed = model.status { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 28) {
                    MoodInputView()
                        .frame(maxWidth: 720)
                    StatusBanner()
                        .frame(maxWidth: 720)
                    if let recommendation = model.recommendation {
                        ResultsView(recommendation: recommendation)
                            .frame(maxWidth: 1040)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, isEmpty ? max(24, geo.size.height * 0.16) : 12)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.smooth(duration: 0.45), value: isEmpty)
        .animation(.smooth(duration: 0.35), value: model.recommendation?.id)
    }
}

struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .working(let message):
            WorkingBanner(message: message)
                .id(message)          // a new step restarts the clock
                .transition(.opacity)
        case .failed(let message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.clay)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Theme.clay.opacity(0.18)), in: .rect(cornerRadius: 16))
        }
    }
}

/// "Thinking with Claude…" that never just spins: after a few seconds it shows how long it's
/// been, and if Claude is taking unusually long it says what to check and offers Cancel.
private struct WorkingBanner: View {
    @Environment(AppModel.self) private var model
    let message: String
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(started))
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message).foregroundStyle(.secondary)
                    if elapsed >= 10 {
                        Text("\(elapsed / 60):\(String(format: "%02d", elapsed % 60))")
                            .font(Theme.smallPrint)
                            .foregroundStyle(.tertiary)
                    }
                    if elapsed >= 30 {
                        Button("Cancel") { model.cancel() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                if elapsed >= 30 {
                    Text("Taking longer than usual. If it doesn't finish, check Claude Code: run claude -p \"hi\" in Terminal to make sure it's installed and signed in.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.4), value: elapsed >= 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

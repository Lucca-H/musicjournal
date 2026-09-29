import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // `MusicJournal --brain-test "<mood>" [claude|apple]` exercises a brain without the UI.
        if CommandLine.arguments.contains("--brain-test") {
            BrainTest.runBlocking(arguments: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--resolve-test") {
            BrainTest.runResolveBlocking(arguments: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--youtube-test") {
            BrainTest.runYouTubeBlocking(arguments: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--style-render") {
            MainActor.assumeIsolated { StyleRender.run(arguments: CommandLine.arguments) }
            return
        }
        if CommandLine.arguments.contains("--sky-render") {
            MainActor.assumeIsolated { SkyRender.run(arguments: CommandLine.arguments) }
            return
        }
        if CommandLine.arguments.contains("--zen-render") {
            ZenRender.run(arguments: CommandLine.arguments)
            return
        }
        if CommandLine.arguments.contains("--queue-test") {
            MainActor.assumeIsolated { QueueTest.run() }
            return
        }
        LegacyMigration.run()
        Fraunces.register()
        MusicJournalApp.main()
    }
}

struct MusicJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MusicJournal") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 620)
                .task {
                    if let state = UIReview.requested {
                        await UIReview.configure(model, state: state)
                    } else {
                        await model.start()
                    }
                }
        }
        .defaultSize(width: 980, height: 820)
        .commands {
            // Single-window app: ⌘N means a new journal entry, not a second window.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Welcome Tour") { model.replayWelcome() }
            }
            CommandMenu("Journal") {
                Button("New Entry") {
                    model.tab = .journal
                    Task {
                        if model.journal.isLocked { await model.journal.unlock() }
                        if !model.journal.isLocked { model.journal.newEntry() }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Add Log…") { Task { await model.beginQuickLog() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Lock Journal") { model.journal.lock() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.journal.isLocked)
            }
            // Developer tools: only in debug builds, never in a release.
            #if DEBUG
            CommandMenu("Debug") {

                Button("Refresh Taste Profile") {
                    Task { await model.loadProfile(forceRefresh: true) }
                }
                .disabled(model.phase != .ready || model.accessMode != .spotifyAccount)
                Button("Force Spotify Token Expiry") {
                    Task { await model.forceTokenExpiry() }
                }
                .disabled(model.accessMode != .spotifyAccount)
            }
            #endif
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApp.setActivationPolicy(.regular)
        // Set the Dock icon directly so it shows even when macOS's icon cache is stale.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

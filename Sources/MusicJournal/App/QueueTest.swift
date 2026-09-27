import AppKit
import Foundation

/// `MusicJournal --queue-test`: plays a short real queue in Spotify (skipping to the end of each
/// song) to check that it moves on to the next song and skips ones Spotify can't play.
@MainActor
enum QueueTest {
    static func run() {
        let queue = SpotifyQueue()
        let items = [
            SpotifyQueue.Item(id: "35KiiILklye1JRRctaLUb4", title: "Holocene", artist: "Bon Iver", imageURL: nil),
            SpotifyQueue.Item(id: "0000000000000000000000", title: "Not a real song", artist: "—", imageURL: nil),
            SpotifyQueue.Item(id: "19YKaevk2bce4odJkP5L22", title: "Nikes", artist: "Frank Ocean", imageURL: nil),
        ]
        let start = Date()
        func log(_ text: String) { print(String(format: "[%5.1fs] ", Date().timeIntervalSince(start)) + text) }

        queue.start(items, from: "queue test")
        log("started: \(queue.current?.title ?? "-")")

        Task { @MainActor in
            var lastIndex = -1
            var seekedIndex = -1
            while queue.isActive, Date().timeIntervalSince(start) < 90 {
                try? await Task.sleep(for: .milliseconds(500))
                if queue.index != lastIndex {
                    lastIndex = queue.index
                    log("now on #\(queue.index + 1): \(queue.current?.title ?? "-")")
                }
                // Once our song is really playing, jump to its last few seconds.
                if case .success(let o) = SpotifyScript.observe(),
                   let current = queue.current, o.trackURI == "spotify:track:\(current.id)",
                   o.durationMs > 0, seekedIndex != queue.index, o.position > 1 {
                    seekedIndex = queue.index
                    let target = o.durationMs / 1000 - 4
                    _ = SpotifyScript.run("tell application \"Spotify\" to set player position to \(Int(target))")
                    log("  playing \(current.title); skipped to \(Int(target))s of \(Int(o.durationMs / 1000))s")
                }
            }
            log("finished: \(queue.message ?? "stopped")")
            _ = SpotifyScript.run("tell application \"Spotify\" to pause")
            log("paused Spotify")
            exit(0)
        }
        RunLoop.main.run()
    }
}

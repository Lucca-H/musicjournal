import AVFoundation
import Foundation
import Observation

/// Plays one 30-second song preview at a time.
@MainActor
@Observable
final class PreviewPlayer {
    private(set) var playingID: String?
    private let player = AVPlayer()
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func toggle(id: String, url: URL) {
        if playingID == id {
            stop()
            return
        }
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playingID = nil }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        playingID = id
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        playingID = nil
    }
}

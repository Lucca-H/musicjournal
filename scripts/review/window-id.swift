// Prints the window number of MusicJournal's main window (the largest), or of its Settings
// window with `settings` (the narrower one). Window titles are hidden without Screen
// Recording permission, so this matches on size. ui-review.sh uses it to capture only
// MusicJournal, never the whole screen.
import CoreGraphics

let wantSettings = CommandLine.arguments.dropFirst().first == "settings"
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { $0[kCGWindowOwnerName as String] as? String == "MusicJournal" && $0[kCGWindowLayer as String] as? Int == 0 }
    .compactMap { window -> (id: Int, width: Double)? in
        guard let id = window[kCGWindowNumber as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double else { return nil }
        return (id, width)
    }
    .sorted { $0.width > $1.width }

if let pick = wantSettings ? windows.last(where: { $0.width < 720 }) : windows.first {
    print(pick.id)
}

import AppKit

/// Subtle trackpad haptics for moments worth feeling: a choice made, a log saved.
/// Silent on Macs without a Force Touch trackpad.
@MainActor
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

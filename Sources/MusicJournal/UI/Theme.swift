import SwiftUI

/// The Dusk Record palette (from the app icon): muted mood tones over charcoal or paper.
/// Everything in the UI draws from here so the app stays calm and consistent.
enum Theme {
    // Mood tones, cool → warm.
    static let dustyBlue = Color(red: 0.56, green: 0.64, blue: 0.75)
    static let mauve = Color(red: 0.70, green: 0.60, blue: 0.69)
    static let clay = Color(red: 0.82, green: 0.64, blue: 0.56)
    static let sand = Color(red: 0.85, green: 0.77, blue: 0.63)
    static let moodTones = [dustyBlue, mauve, clay, sand]

    /// The one accent: a dusty rose between mauve and clay. Used instead of the system
    /// accent so selected states and primary buttons match the icon.
    static let accent = Color(red: 0.76, green: 0.56, blue: 0.58)

    static let charcoal = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let paper = Color(red: 0.95, green: 0.94, blue: 0.92)

    /// Quiet content surface (lists, cards). Glass is reserved for controls.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.05) : .black.opacity(0.035)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.08) : .black.opacity(0.07)
    }

    /// Picks a tone along the cool → warm ramp for a 0–1 valence.
    static func tone(forValence valence: Double) -> Color {
        let clamped = min(max(valence, 0), 1)
        let index = min(Int(clamped * Double(moodTones.count)), moodTones.count - 1)
        return moodTones[index]
    }

    /// Smooth blend along dusty blue → mauve → clay → sand, for the month chart.
    static func blend(valence: Double) -> Color {
        let t = min(max(valence, 0), 1) * Double(moodTones.count - 1)
        let lower = min(Int(t), moodTones.count - 2)
        return moodTones[lower].mix(with: moodTones[lower + 1], by: t - Double(lower))
    }

    static let titleFont = Font.system(size: 38, weight: .regular, design: .serif)
    static let sectionFont = Font.system(.subheadline, design: .default).weight(.semibold)
}

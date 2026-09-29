import AppKit
import CoreText
import SwiftUI

/// "Last Light" (see DESIGN.md): night ink or paper, a sky-coloured scale from blue hour to
/// afterglow, one dusty-rose accent. Everything in the UI draws from here.
enum Theme {
    /// The sky ramp, Awful → Great. Lightness rises every step, so the day scale and the
    /// month chart read by brightness alone.
    static let blueHour = Color(red: 0.369, green: 0.420, blue: 0.522)   // #5E6B85
    static let violet = Color(red: 0.498, green: 0.486, blue: 0.612)     // #7F7C9C
    static let mauve = Color(red: 0.659, green: 0.541, blue: 0.620)      // #A88A9E
    static let clayTone = Color(red: 0.769, green: 0.592, blue: 0.541)   // #C4978A
    static let afterglow = Color(red: 0.851, green: 0.737, blue: 0.584)  // #D9BC95
    static let moodTones = [blueHour, violet, mauve, clayTone, afterglow]

    /// Errors and failed checks: a muted clay red, never a bright one.
    static let clay = Color(red: 0.769, green: 0.478, blue: 0.431)       // #C47A6E

    /// Text: warm and never pure white or black.
    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.875, green: 0.843, blue: 0.800)   // #DFD7CC
            : Color(red: 0.161, green: 0.149, blue: 0.184)               // #29262F
    }

    /// The one accent: a dusty rose between mauve and clay. Used instead of the system
    /// accent so selected states and primary buttons match the icon.
    static let accent = Color(red: 0.76, green: 0.56, blue: 0.58)

    /// Night ink (#18171F): charcoal leaning toward indigo, the way dusk actually looks.
    static let charcoal = Color(red: 0.094, green: 0.090, blue: 0.122)
    /// Paper (#ECE7DF), a touch dim, for light mode.
    static let paper = Color(red: 0.925, green: 0.906, blue: 0.875)

    /// The background dims through the evening (see `Sky.dim`): afternoon ink → deep night.
    static let dayInk = Color(red: 0.137, green: 0.133, blue: 0.173)       // #23222C
    static let deepInk = Color(red: 0.059, green: 0.055, blue: 0.078)      // #0F0E14
    static let duskPaper = Color(red: 0.867, green: 0.839, blue: 0.796)    // #DDD6CB

    // The evening glow: sunset clay and mauve deepening to night violet and blue.
    static let duskClay = Color(red: 0.788, green: 0.561, blue: 0.467)     // #C98F77
    static let duskMauve = Color(red: 0.592, green: 0.478, blue: 0.565)    // #977A90
    static let nightViolet = Color(red: 0.365, green: 0.349, blue: 0.522)  // #5D5985
    static let nightBlue = Color(red: 0.263, green: 0.290, blue: 0.420)    // #434A6B
    static let moonlight = Color(red: 0.722, green: 0.769, blue: 0.863)    // #B8C4DC

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

    /// Smooth blend along the sky ramp. The day ratings' own values (0.1, 0.3 … 0.9) land
    /// exactly on its five colours.
    static func blend(valence: Double) -> Color {
        let t = min(max((valence - 0.1) / 0.8, 0), 1) * Double(moodTones.count - 1)
        let lower = min(Int(t), moodTones.count - 2)
        let fraction = t - Double(lower)
        if fraction < 0.001 { return moodTones[lower] }
        if fraction > 0.999 { return moodTones[lower + 1] }
        return moodTones[lower].mix(with: moodTones[lower + 1], by: fraction)
    }

    // MARK: Type (DESIGN.md › Typography)

    /// Fraunces Light for titles and anything written; SF for everything you operate.
    enum Serif {
        static let display = Theme.serif(40)      // the welcome tour's hero only
        static let page = Theme.serif(34)         // screen titles
        static let sheet = Theme.serif(26)        // sheet and panel titles
        static let prompt = Theme.serif(22)       // the mood prompt, a mix's name
        static let quote = Theme.serif(20, italic: true)
        static let cover = Theme.serif(20)        // words set on a playlist's cover
        static let small = Theme.serif(17)        // small titles (a month, the up-next list)
        static let note = Theme.serif(16)         // a quick log's line
        static let writing = Theme.serif(17)      // journal writing
        static let feeling = Theme.serif(15, italic: true)
    }

    /// Dates, times and counts: small, light and tabular, like a record sleeve's small print.
    static let smallPrint = Font.system(size: 11, weight: .light, design: .monospaced).monospacedDigit()

    static let titleFont = Serif.page
    static let sectionFont = Font.system(.subheadline, design: .default).weight(.medium)

    /// Fraunces Light, soft and not wonky, optical size matched to the size. Falls back to
    /// New York Light if the bundled font isn't there.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        if let font = Fraunces.font(size: size, italic: italic) { return Font(font) }
        let fallback = Font.system(size: size, weight: .light, design: .serif)
        return italic ? fallback.italic() : fallback
    }
}

extension View {
    /// DESIGN.md: at most one accent action per screen. The primary one is prominent glass
    /// (dusty rose); anything else is plain glass.
    @ViewBuilder
    func primaryAction(_ isPrimary: Bool = true) -> some View {
        if isPrimary { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    }
}

/// The bundled Fraunces variable font (SIL Open Font License, see Resources/Fonts/OFL.txt).
enum Fraunces {
    /// Makes the fonts in the app's Resources/Fonts available to this process. Call once at launch.
    static func register(bundle: Bundle = .main) {
        guard let dir = bundle.resourceURL?.appendingPathComponent("Fonts") else { return }
        register(directory: dir)
    }

    static func register(directory dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func tag(_ s: String) -> NSNumber {
        NSNumber(value: s.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    static func font(size: CGFloat, italic: Bool, weight: Double = 300) -> CTFont? {
        let variations: [NSNumber: NSNumber] = [
            tag("wght"): NSNumber(value: weight), tag("SOFT"): 100, tag("WONK"): 0,
            tag("opsz"): NSNumber(value: Double(min(max(size, 9), 144))),
        ]
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: "Fraunces",
            kCTFontVariationAttribute: variations as NSDictionary,
        ]
        if italic {
            attributes[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitItalic.rawValue] as NSDictionary
        }
        let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
        guard (CTFontCopyFamilyName(font) as String) == "Fraunces" else { return nil }
        if italic, !CTFontGetSymbolicTraits(font).contains(.traitItalic) { return nil }
        return font
    }
}

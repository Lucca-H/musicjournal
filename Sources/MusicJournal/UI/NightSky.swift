import AppKit
import SwiftUI

/// What the sky is doing by the local clock. At sunset a warm clay glow and a low horizon
/// glow; through the evening they fade toward violet, and by midnight the warm light is
/// gone entirely, leaving only faint moonlight from the upper right and the stars. Dawn
/// brings the warmth back. Daytime keeps a soft, starless glow.
struct Sky: Equatable {
    var warm: Double      // strength of the sunset glow, 0…1
    var violet: Double    // how far that glow has shifted from clay to violet
    var horizon: Double   // the low glow along the bottom
    var moon: Double      // cool moonlight from the upper right
    var stars: Double
    /// How far the room itself has dimmed: 0 in the afternoon, deepening steadily through
    /// the evening to its darkest around 3 am, lifting again at dawn.
    var dim: Double = 0

    static func at(_ date: Date, calendar: Calendar = .current) -> Sky {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
        let e = clock < 7 ? clock + 24 : clock          // one evening: 7:00 … 30:59 (6:59 am)
        let dawn = smooth((e - 28.5) / 1.5)             // 4:30 → 6:00 am, the night lifts
        let dim = smooth((e - 14.5) / 12.5) * (1 - dawn)
        if e < 17 {
            return Sky(warm: 0.8, violet: 0, horizon: 0.45, moon: 0, stars: 0, dim: dim)
        }
        // Sunset warms the glow's colour more than its strength, so the room never gets
        // brighter as the evening goes on: it only ever darkens.
        let dusk = e < 19 ? 0.8 + 0.1 * smooth((e - 17) / 2) : 0.9 * (1 - smooth((e - 19) / 5))
        return Sky(
            warm: max(dusk, 0.6 * dawn),
            violet: smooth((e - 18) / 4) * (1 - dawn),
            horizon: max(0.45 * (1 - smooth((e - 17.5) / 4)), 0.3 * dawn),
            moon: smooth((e - 22.5) / 2) * (1 - dawn),
            stars: smooth((e - 19.5) / 3) * (1 - dawn),
            dim: dim)
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The window's sky: night ink (or paper, in light mode) with slow-drifting glows that follow
/// the real evening and take on the colour of your mood, a low horizon glow, a faint
/// vignette, and in dark mode, stars. Everything moves on minute-long loops, too slow to
/// watch directly; with Reduce Motion it all holds still.
struct DuskBackground: View {
    var energy: Double
    var valence: Double
    /// For rendering a still of a given moment (see `--sky-render`); nil follows the clock.
    var fixedDate: Date? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Mood: Equatable { var energy: Double; var valence: Double }
    @State private var from = Mood(energy: 0.4, valence: 0.5)
    @State private var to = Mood(energy: 0.4, valence: 0.5)
    @State private var changedAt = Date.distantPast
    /// The sky moves slowly, so it only needs a few frames a second, and far fewer (or none)
    /// when you're not looking: every frame also re-renders the glass drawn over it.
    @State private var appActive = NSApp?.isActive ?? true
    @State private var onScreen = true

    private var frameInterval: Double { appActive ? 0.25 : 2 }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: reduceMotion || !onScreen)) { context in
            let now = fixedDate ?? context.date
            let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
            let sky = Sky.at(now)
            let mood = blendedMood(at: now)
            ZStack {
                Self.base(sky, dark: scheme == .dark)
                glows(t: t, sky: sky, mood: mood)
                if scheme == .dark {
                    StarField(time: t, visibility: sky.stars, still: reduceMotion)
                    if !reduceMotion {
                        ShootingStar(enabled: sky.stars > 0.6 && appActive && onScreen)
                    }
                }
                vignette
            }
        }
        .background(scheme == .dark ? Theme.charcoal : Theme.paper)   // behind the first frame only
        .onAppear {
            to = Mood(energy: energy, valence: valence)
            from = to
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            onScreen = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        }
        .onChange(of: Mood(energy: energy, valence: valence)) { _, new in
            from = blendedMood(at: Date())
            to = new
            changedAt = Date()
        }
    }

    /// A new mood fades in over a couple of seconds rather than snapping.
    private func blendedMood(at date: Date) -> Mood {
        let p = reduceMotion ? 1 : Sky.smooth(date.timeIntervalSince(changedAt) / 2.4)
        return Mood(energy: from.energy + (to.energy - from.energy) * p,
                    valence: from.valence + (to.valence - from.valence) * p)
    }

    private func glows(t: Double, sky: Sky, mood: Mood) -> some View {
        let dark = scheme == .dark
        let base = Self.base(sky, dark: dark)
        // Slow, offset loops (about a minute each), so nothing ever visibly repeats.
        func wave(_ period: Double, _ phase: Double) -> Double { sin(t / period * 2 * .pi + phase) }
        func float(_ x: Double) -> Float { Float(x) }

        // Sunset clay shifting to violet as it fades, tinted by the mood; gone by midnight.
        let warm = Theme.duskClay.mix(with: Theme.nightViolet, by: sky.violet)
            .mix(with: Theme.tone(forValence: mood.valence), by: 0.35)
        let cool = Theme.duskMauve.mix(with: Theme.nightBlue, by: sky.violet)
            .mix(with: Theme.tone(forValence: 1 - mood.valence * 0.6), by: 0.25)
        let breathe = 0.88 + 0.12 * wave(53, 0.7)
        let strength = ((dark ? 0.62 : 0.45) + mood.energy * 0.12) * sky.warm * breathe
        let horizon = (dark ? 0.5 : 0.3) * sky.horizon
        // Moonlight: a cool silver wash from the upper right, only late at night.
        // The top-right corner hands over smoothly from the evening's violet to the moon.
        let moonStrength = (dark ? 0.26 : 0.12) * sky.moon * (0.9 + 0.1 * wave(89, 2.1))
        let violetStrength = strength * 0.45 * (0.7 + 0.3 * wave(47, 1.3))
        let topRight = cool.mix(with: Theme.moonlight, by: sky.moon).opacity(max(moonStrength, violetStrength))

        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [float(0.5 + 0.08 * wave(67, 0)), 0], [1, 0],
                [0, float(0.5 + 0.08 * wave(59, 1))],
                [float(0.55 + 0.07 * wave(71, 2)), float(0.5 + 0.07 * wave(83, 3))],
                [1, float(0.5 + 0.08 * wave(61, 4))],
                [0, 1], [float(0.5 + 0.08 * wave(73, 5)), 1], [1, 1],
            ],
            colors: [
                warm.opacity(strength), base, topRight,
                base, base, base,
                cool.opacity(strength * 0.35), warm.opacity(horizon), cool.opacity(strength * 0.9),
            ]
        )
    }

    /// The room's own colour, dimming with the evening: a lighter charcoal in the afternoon,
    /// night ink by about 10 pm, deepest around 3 am. Light mode's paper dims a little too.
    static func base(_ sky: Sky, dark: Bool) -> Color {
        dark ? Theme.dayInk.mix(with: Theme.deepInk, by: sky.dim)
             : Theme.paper.mix(with: Theme.duskPaper, by: sky.dim)
    }

    /// The edges of the room go dark first.
    private var vignette: some View {
        EllipticalGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.55),
                .init(color: Color(red: 0.03, green: 0.02, blue: 0.05).opacity(scheme == .dark ? 0.35 : 0.06), location: 1),
            ],
            center: UnitPoint(x: 0.5, y: 0.4),
            startRadiusFraction: 0, endRadiusFraction: 0.85)
        .allowsHitTesting(false)
    }
}

/// Faint stars, mostly high in the sky: a fixed scatter, a few twinkling slowly, the whole
/// field turning very slowly (one width every 15 minutes), and now and then, once it's
/// properly dark, a faint shooting star.
private struct StarField: View {
    let time: Double
    let visibility: Double
    let still: Bool

    private struct Star {
        let x: Double, y: Double, radius: Double, alpha: Double
        let twinkles: Bool, speed: Double, phase: Double
    }

    private static let stars: [Star] = {
        var rng = SplitMix64(seed: 11)
        return (0..<170).map { _ in
            let height = pow(rng.nextUnit(), 1.8)          // most sit high up
            return Star(x: rng.nextUnit(), y: height * 0.75,
                        radius: 0.35 + pow(rng.nextUnit(), 3) * 1.1,
                        alpha: (0.25 + rng.nextUnit() * 0.6) * (1 - height * 0.6),
                        twinkles: rng.nextUnit() < 0.25, speed: 0.3 + rng.nextUnit() * 0.7, phase: rng.nextUnit() * 6.28)
        }
    }()

    private static let starlight = Color(red: 0.94, green: 0.90, blue: 0.85)

    var body: some View {
        Canvas { context, size in
            guard visibility > 0.01 else { return }
            let turn = still ? 0 : (time / 900).truncatingRemainder(dividingBy: 1)
            for star in Self.stars {
                let twinkle = star.twinkles && !still ? 0.65 + 0.35 * sin(time * star.speed + star.phase) : 1
                let x = (star.x + turn).truncatingRemainder(dividingBy: 1) * size.width
                let y = star.y * size.height
                let alpha = star.alpha * twinkle * visibility
                let r = star.radius
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(Self.starlight.opacity(alpha)))
                if r > 1.1 {                                    // the brightest get a tiny halo
                    let h = r * 3.2
                    context.fill(Path(ellipseIn: CGRect(x: x - h, y: y - h, width: h * 2, height: h * 2)),
                                 with: .color(Self.starlight.opacity(alpha * 0.18)))
                }
            }
        }
        .allowsHitTesting(false)
    }

}

/// Now and then, once it's properly dark, a faint streak crosses the upper sky in about a
/// second. It's its own short animation, so the rest of the sky can stay at a few frames
/// a second.
private struct ShootingStar: View {
    let enabled: Bool
    @State private var fire = 0
    @State private var origin = CGPoint(x: 0.4, y: 0.15)

    private static let starlight = Color(red: 0.94, green: 0.90, blue: 0.85)

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, trigger: fire) { progress in
            Canvas { context, size in
                guard progress > 0, progress < 1 else { return }
                let start = CGPoint(x: origin.x * size.width, y: origin.y * size.height)
                let head = CGPoint(x: start.x + 140 * progress, y: start.y + 63 * progress)
                let tail = CGPoint(x: head.x - 90, y: head.y - 40)
                var path = Path()
                path.move(to: tail)
                path.addLine(to: head)
                let fade = sin(progress * .pi)
                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [Self.starlight.opacity(0), Self.starlight.opacity(0.55 * fade)]),
                    startPoint: tail, endPoint: head),
                               style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: 1.1)
        }
        .allowsHitTesting(false)
        .task(id: enabled) {
            guard enabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 45...80)))
                guard !Task.isCancelled else { return }
                origin = CGPoint(x: Double.random(in: 0.15...0.75), y: Double.random(in: 0.05...0.3))
                fire += 1
            }
        }
    }
}

/// `MusicJournal --sky-render <out-prefix>` saves the background at a few times of night, so
/// the sky can be checked without opening the app.
@MainActor
enum SkyRender {
    static func run(arguments: [String]) {
        let prefix = arguments.drop { $0 != "--sky-render" }.dropFirst().first ?? "sky"
        for (hour, minute) in [(12, 0), (16, 0), (17, 30), (19, 0), (20, 30), (22, 0), (23, 30), (1, 0), (3, 0)] {
            var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            parts.hour = hour; parts.minute = minute
            let date = Calendar.current.date(from: parts)!
            let view = DuskBackground(energy: 0.3, valence: 0.45, fixedDate: date)
                .frame(width: 960, height: 600)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let path = "\(prefix)-\(String(format: "%02d%02d", hour, minute)).png"
            try? png.write(to: URL(fileURLWithPath: path))
            // Average brightness (0–255) of the whole window, to check the evening darkens.
            if let rep = NSBitmapImageRep(data: tiff) {
                var total = 0.0, n = 0.0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        total += (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) * 255
                        n += 1
                    }
                }
                print(String(format: "%02d:%02d  brightness %.1f", hour, minute, total / max(n, 1)))
            }
        }
    }
}

/// `MusicJournal --style-render <out.png>`: the type scale, day scale and a glass control on
/// the real sky, rendered with the app's own views, to check fonts and colours.
@MainActor
enum StyleRender {
    static func run(arguments: [String]) {
        Fraunces.register()
        let out = arguments.drop { $0 != "--style-render" }.dropFirst().first ?? "style.png"
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        parts.hour = 21; parts.minute = 30
        let evening = Calendar.current.date(from: parts)!
        let view = ZStack {
            DuskBackground(energy: 0.3, valence: 0.45, fixedDate: evening)
            VStack(alignment: .leading, spacing: 18) {
                Text("saturday evening · 9:30 pm").font(Theme.smallPrint).foregroundStyle(.secondary)
                Text("How are you feeling?").font(Theme.Serif.page)
                Text("Running on Empty, Gently").font(Theme.Serif.sheet)
                Text("You're worn out in the nice way.").font(Theme.Serif.prompt).foregroundStyle(.secondary)
                Text("Long week. The rain helped.").font(Theme.Serif.writing)
                HStack(spacing: 8) {
                    ForEach(["tired", "calm", "grateful"], id: \.self) {
                        Text($0).font(Theme.Serif.feeling)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Theme.hairline(.dark)))
                    }
                }
                DayRatingPicker(title: "How was the day?", current: .good) { _ in }
                HStack(spacing: 4) {
                    ForEach(DayRating.allCases) { r in
                        RoundedRectangle(cornerRadius: 6).fill(r.color).frame(width: 36, height: 36)
                    }
                }
                Text("Play in Spotify").font(.body).padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(Color(red: 0.13, green: 0.12, blue: 0.14))
            }
            .padding(40)
            .foregroundStyle(Theme.text(.dark))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 640)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: out))
        print("Wrote \(out)")
    }
}

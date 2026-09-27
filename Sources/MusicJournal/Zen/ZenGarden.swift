import CoreGraphics
import Foundation
import Observation
import simd

/// State for the Zen corner: the sand, the rendered image, and the rake.
@MainActor
@Observable
final class ZenGarden {
    let field = SandField()
    private(set) var image: CGImage?
    var tines = 5
    private(set) var isSmoothing = false
    /// Direction the rake is being pulled, for drawing the rake cursor (radians).
    private(set) var angle: Double = -.pi / 2
    var dark = false {
        didSet { if dark != oldValue { render() } }
    }

    @ObservationIgnored private var last: SIMD2<Float>?

    /// Tine spacing in sand cells, scaled to the field so it looks the same at any resolution.
    var spacing: Float { Float(field.width) / 66 }

    var aspectRatio: CGFloat { CGFloat(field.width) / CGFloat(field.height) }

    func render() {
        image = field.render(dark: dark)
    }

    /// Continues a stroke to `point` (in a view of `size`).
    func rake(to point: CGPoint, in size: CGSize) {
        guard !isSmoothing, size.width > 0, size.height > 0 else { return }
        let cell = SIMD2<Float>(
            Float(point.x / size.width) * Float(field.width),
            Float(point.y / size.height) * Float(field.height))
        guard let last else {
            self.last = cell
            return
        }
        let delta = cell - last
        guard simd_length(delta) >= 0.6 else { return }
        field.rake(from: last, to: cell, tines: tines, spacing: spacing)
        // Ease the rake's heading toward the stroke direction so it turns smoothly.
        let target = atan2(Double(delta.y), Double(delta.x))
        var diff = target - angle
        while diff > .pi { diff -= 2 * .pi }
        while diff < -.pi { diff += 2 * .pi }
        angle += diff * 0.35
        self.last = cell
        render()
    }

    func endStroke() {
        last = nil
        field.endStroke()
    }

    /// Sweeps the garden flat from left to right, like drawing a board across it.
    func smoothSand() async {
        guard !isSmoothing else { return }
        isSmoothing = true
        let steps = 40
        var done = 0
        for step in 1...steps {
            let upTo = field.width * step / steps
            field.smooth(columns: done..<upTo)
            done = upTo
            render()
            try? await Task.sleep(for: .milliseconds(18))
        }
        isSmoothing = false
    }

    func moveStones() async {
        await smoothSand()
        field.shuffleStones()
        render()
    }
}

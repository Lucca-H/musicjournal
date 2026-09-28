import AppKit
import Foundation

/// `MusicJournal --zen-render <out.png>`: rakes a sample pattern and saves the garden image,
/// so the sand's look can be checked without opening the app.
enum ZenRender {
    static func run(arguments: [String]) {
        let out = arguments.drop { $0 != "--zen-render" }.dropFirst().first ?? "zen.png"
        let field = SandField()
        let k = Float(field.width) / 400       // sample pattern was drawn for a 400-wide field
        let spacing = Float(field.width) / 66
        // Straight passes across the top, like a freshly raked garden.
        for row in stride(from: Float(20), through: 70, by: 26) {
            stroke(field, spacing: spacing, points: (0...40).map { SIMD2(Float($0) * 10 * k, row * k) })
        }
        // A ring around the big stone, and a wave across the bottom.
        let big = field.stones[0]
        stroke(field, spacing: spacing, points: (0...72).map { i in
            let a = Float(i) / 72 * 2 * .pi
            return SIMD2(big.x + cos(a) * (big.rx + 14 * k), big.y + sin(a) * (big.ry + 14 * k))
        })
        stroke(field, spacing: spacing, points: (0...80).map { i in
            let x = Float(i) * 5 * k
            return SIMD2(x, (205 + sin(x / k / 30) * 14) * k)
        })
        // A stroke across the top rows and down through the wave, to show how ridges meet.
        stroke(field, spacing: spacing, points: (0...60).map { i in
            let t = Float(i) / 60
            return SIMD2((250 + t * 60) * k, (10 + t * 235) * k)
        })
        // Speed check: one rake segment plus a full redraw, as happens on every drag event.
        let clock = ContinuousClock()
        let start = clock.now
        for i in 0..<60 {
            field.rake(from: SIMD2(100 + Float(i) * 2, 150), to: SIMD2(102 + Float(i) * 2, 150), tines: 5, spacing: spacing)
            _ = field.render(dark: false)
        }
        print("rake + redraw: \((clock.now - start) / 60) per drag event")

        for (dark, suffix) in [(false, "light"), (true, "dark")] {
            guard let image = field.render(dark: dark) else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            let path = out.replacingOccurrences(of: ".png", with: "-\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        }
    }

    private static func stroke(_ field: SandField, spacing: Float, points: [SIMD2<Float>]) {
        for (a, b) in zip(points, points.dropFirst()) {
            field.rake(from: a, to: b, tines: 5, spacing: spacing)
        }
        field.endStroke()
    }
}

import CoreGraphics
import simd
import Foundation

/// A small sand garden simulated as a height field. Raking presses grooves where the tines
/// pass and lifts ridges between them. Rendering lights the sand like late afternoon (or
/// moonlight in dark mode): warm light from the top left, cool sky in the shade, soft stone
/// shadows, and the sand darkening a little where it meets the stones. Only the part of the
/// garden that changed is shaded again, so raking stays smooth at full resolution.
final class SandField {
    struct Stone: Equatable {
        var x: Float, y: Float      // centre, in cells
        var rx: Float, ry: Float    // radii, in cells
        var tone: Float             // 0.85…1.15 brightness variation
        /// Width of the moss ring around the stone, as a share of its radius (0 = bare).
        var moss: Float = 0
    }

    private enum Kind: UInt8 { case sand = 0, stone, moss }

    let width: Int
    let height: Int
    private(set) var heights: [Float]
    private var grain: [Float]           // slow tonal drift across the garden
    /// The gravel: every cell belongs to one small pebble. These hold that pebble's colour,
    /// the tilt of its surface at this cell, and how deep in the gap between pebbles it is.
    private var pebbleTone: [Float]
    private var pebbleTint: [Float]      // -1 cool grey … +1 warm grey
    private var pebbleSlope: [SIMD2<Float>]
    private var pebbleGap: [Float]       // 1 on a pebble, lower in the crevices between them
    private var pebbleShine: [Float]     // quartz-like pebbles that catch the light
    private var kind: [Kind]
    private var islandHeight: [Float]    // stone and moss height above the sand, in cells
    private var islandTone: [Float]      // stone/moss surface colour variation
    private var sunlight: [Float]        // 1 = in full sun, lower in a stone's shadow
    private var ambient: [Float]         // 1 = open sky, lower where sand meets a stone
    private(set) var stones: [Stone] = []
    private var rng: SplitMix64

    private var pixels: [UInt8]
    private var shadedDark: Bool?        // nil: everything needs shading
    private var dirty: (x: ClosedRange<Int>, y: ClosedRange<Int>)?

    /// Light comes from the top left and a little above.
    private let light = simd_normalize(SIMD3<Float>(-0.55, -0.65, 0.55))

    init(width: Int = 1120, height: Int = 700, seed: UInt64 = 7) {
        self.width = width
        self.height = height
        rng = SplitMix64(seed: seed)
        let count = width * height
        heights = Array(repeating: 0, count: count)
        grain = Array(repeating: 1, count: count)
        kind = Array(repeating: .sand, count: count)
        islandHeight = Array(repeating: 0, count: count)
        islandTone = Array(repeating: 1, count: count)
        sunlight = Array(repeating: 1, count: count)
        ambient = Array(repeating: 1, count: count)
        pixels = Array(repeating: 255, count: count * 4)
        strokeBase = Array(repeating: .nan, count: count)
        pebbleTone = Array(repeating: 1, count: count)
        pebbleTint = Array(repeating: 0, count: count)
        pebbleSlope = Array(repeating: .zero, count: count)
        pebbleGap = Array(repeating: 1, count: count)
        pebbleShine = Array(repeating: 0, count: count)
        let drift = 90 / Float(max(width, 1)) * 6     // slow tonal drift, same look at any size
        for y in 0..<height {
            for x in 0..<width {
                let slow = Noise.fbm(Float(x) * drift / 90, Float(y) * drift / 90, seed: 11)
                grain[y * width + x] = 1 + (slow - 0.5) * 0.06
            }
        }
        layGravel()
        smoothAll()
        placeStones(Self.defaultStones(width: width, height: height))
    }

    // MARK: Gravel

    /// Scatters pebbles over the garden: a jittered grid, each cell of it one pebble with its
    /// own size, colour and roundness (like the crushed granite of a karesansui garden).
    private func layGravel() {
        let size = max(2.2, Float(width) / 350)             // pebble spacing, in cells
        let cols = Int(Float(width) / size) + 2, rows = Int(Float(height) / size) + 2
        struct Pebble { var centre: SIMD2<Float>; var radius: Float; var tone: Float; var tint: Float; var shine: Float }
        var pebbles: [Pebble] = []
        pebbles.reserveCapacity(cols * rows)
        for gy in 0..<rows {
            for gx in 0..<cols {
                let jx = Float(rng.nextUnit()) - 0.5, jy = Float(rng.nextUnit()) - 0.5
                let pick = Float(rng.nextUnit())
                // Mostly pale granite; some mid grey, a few dark flecks, a few bright white.
                let tone: Float = pick < 0.03 ? 0.5 + Float(rng.nextUnit()) * 0.12
                    : pick < 0.12 ? 0.74 + Float(rng.nextUnit()) * 0.1
                    : pick < 0.2 ? 1.05 + Float(rng.nextUnit()) * 0.04
                    : 0.92 + Float(rng.nextUnit()) * 0.1
                pebbles.append(Pebble(
                    centre: SIMD2((Float(gx) + 0.5 + jx * 0.8) * size, (Float(gy) + 0.5 + jy * 0.8) * size),
                    radius: size * (0.5 + Float(rng.nextUnit()) * 0.16),
                    tone: tone,
                    tint: Float(rng.nextUnit()) * 2 - 1,
                    shine: rng.nextUnit() < 0.12 ? 1 : 0))
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let gx = Int(p.x / size), gy = Int(p.y / size)
                var best = Float.greatestFiniteMagnitude, second = Float.greatestFiniteMagnitude
                var nearest = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let cx = gx + dx, cy = gy + dy
                        guard cx >= 0, cy >= 0, cx < cols, cy < rows else { continue }
                        let index = cy * cols + cx
                        let d = simd_distance(p, pebbles[index].centre) / pebbles[index].radius
                        if d < best { second = best; best = d; nearest = index }
                        else if d < second { second = d }
                    }
                }
                let pebble = pebbles[nearest]
                let i = y * width + x
                let v = (p - pebble.centre) / pebble.radius
                pebbleSlope[i] = v * 0.38                     // a rounded top, facing outward
                pebbleGap[i] = 0.72 + 0.28 * smoothstep(0, 0.3, second - best)
                pebbleTone[i] = pebble.tone
                pebbleTint[i] = pebble.tint
                pebbleShine[i] = pebble.shine
            }
        }
    }

    // MARK: Raking

    /// Height of each cell when the current stroke first reached it (NaN: not yet). Every
    /// segment of a stroke works from this, so overlapping segments never rake twice.
    private var strokeBase: [Float]
    private var strokeCells: [Int] = []
    private var lastDirection: SIMD2<Float>?
    private var strokeBox: (x: ClosedRange<Int>, y: ClosedRange<Int>)?
    private var strokeTalus: Float = 0.35

    /// Ends the current stroke: the gravel it moved settles, and the next rake starts a new
    /// stroke. Settling once per stroke (not per drag event) keeps it even along the stroke.
    func endStroke() {
        if let box = strokeBox {
            let xs = max(0, box.x.lowerBound - 2)...min(width - 1, box.x.upperBound + 2)
            let ys = max(0, box.y.lowerBound - 2)...min(height - 1, box.y.upperBound + 2)
            settle(x: xs, y: ys, talus: strokeTalus)
            markDirty(x: xs, y: ys)
        }
        strokeBox = nil
        for i in strokeCells { strokeBase[i] = .nan }
        strokeCells.removeAll(keepingCapacity: true)
        lastDirection = nil
    }

    /// Drags a rake with `tines` teeth `spacing` cells apart from `a` to `b` (cell coords).
    ///
    /// Each tine scoops a round-bottomed groove and the gravel it moves builds the ridge beside
    /// it, so grooves and ridges hold the same amount of material. The ground under the rake
    /// isn't simply replaced: between the tines some of the old pattern survives, so crossing
    /// an earlier pattern leaves it faintly showing through. Gravel pushed past the outermost
    /// tines piles into a low shoulder, and anything left steeper than gravel can hold slumps
    /// (see `settle`), so crossings and stroke ends crumble naturally instead of cutting off.
    func rake(from a: SIMD2<Float>, to b: SIMD2<Float>, tines: Int, spacing: Float, depth: Float = 1, strength: Float = 0.85) {
        let delta = b - a
        let length = simd_length(delta)
        guard length > 0.01 else { return }
        let dir = delta / length
        let normal = SIMD2<Float>(-dir.y, dir.x)
        let half = Float(tines - 1) / 2 * spacing
        let shoulder = spacing * 0.45                     // where pushed-out gravel slopes back down
        let reach = half + spacing * 0.5 + shoulder
        // At a bend the outside of the turn falls between two segments; fan the tines around
        // the joint there, like a rake pivoting, so the grooves stay continuous.
        // The gap is the wedge past the end of the previous segment and before this one.
        let previous = lastDirection
        lastDirection = dir

        // Groove half-width as a share of the tine gap, and the ridge height that holds exactly
        // the gravel the groove removed.
        let g: Float = 0.45
        let ridge = depth * g * .pi * .pi / (8 * (1 - g))

        let minX = max(0, Int((min(a.x, b.x) - reach - 1).rounded(.down)))
        let maxX = min(width - 1, Int((max(a.x, b.x) + reach + 1).rounded(.up)))
        let minY = max(0, Int((min(a.y, b.y) - reach - 1).rounded(.down)))
        let maxY = min(height - 1, Int((max(a.y, b.y) + reach + 1).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let i = y * width + x
                if kind[i] != .sand { continue }
                let cell = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                let p = cell - a
                let along = simd_dot(p, dir)
                var offset = simd_dot(p, normal)
                if along < 0 {
                    guard let previous, simd_dot(p, previous) >= 0 else { continue }
                    offset = offset >= 0 ? simd_length(p) : -simd_length(p)
                } else if along > length {
                    continue
                }
                guard abs(offset) <= reach else { continue }

                // Hand-pulled tines never cut perfectly evenly.
                let wobble = 0.9 + Noise.value(cell.x * 0.07, cell.y * 0.07, seed: 21) * 0.2
                let outside = abs(offset) - half              // beyond the outermost tine
                let u = (offset + half) / spacing
                let r = outside > spacing * 0.5 ? 1 : abs(u - u.rounded()) * 2   // 0 at a tine, 1 between two
                var target: Float
                if r < g {
                    let t = r / g
                    target = -depth * wobble * (1 - t * t).squareRoot()          // round-bottomed groove
                } else {
                    target = ridge * wobble * sin(.pi / 2 * (r - g) / (1 - g))   // rounded crest
                }

                if strokeBase[i].isNaN {
                    strokeBase[i] = heights[i]
                    strokeCells.append(i)
                }
                let base = strokeBase[i]
                // The tine clears its groove; between tines a little of what was there remains.
                let memory = r < g ? 0 : 0.18 * (r - g) / (1 - g)
                var value = target + base * memory
                var weight = strength
                if outside > spacing * 0.5 {
                    // The shoulder: a slightly raised lip of pushed-out gravel, easing back
                    // down to the undisturbed ground.
                    let t = min(1, (outside - spacing * 0.5) / shoulder)
                    value = (ridge * 1.15 + base * 0.18) * (1 - t * t)
                    weight *= 1 - t * t * t
                }
                heights[i] = base + (value - base) * weight
            }
        }
        strokeTalus = depth * 6 / spacing
        if let box = strokeBox {
            strokeBox = (min(box.x.lowerBound, minX)...max(box.x.upperBound, maxX),
                         min(box.y.lowerBound, minY)...max(box.y.upperBound, maxY))
        } else {
            strokeBox = (minX...maxX, minY...maxY)
        }
        markDirty(x: minX...maxX, y: minY...maxY)
    }

    /// Gravel can't hold a slope steeper than `talus` (height per cell): where it is, some
    /// slides to the lower neighbour. Moves are symmetric, so no gravel is made or lost.
    private func settle(x xs: ClosedRange<Int>, y ys: ClosedRange<Int>, talus: Float) {
        for _ in 0..<3 {
            var moved = false
            for y in ys {
                for x in xs {
                    let i = y * width + x
                    guard kind[i] == .sand else { continue }
                    for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < width && ny < height {
                        let j = ny * width + nx
                        guard kind[j] == .sand else { continue }
                        let diff = heights[i] - heights[j]
                        let excess = abs(diff) - talus
                        guard excess > 0 else { continue }
                        let shift = (diff > 0 ? excess : -excess) * 0.25
                        heights[i] -= shift
                        heights[j] += shift
                        moved = true
                    }
                }
            }
            if !moved { break }
        }
    }

    /// Flattens columns `from..<to`, as if smoothed by a board, leaving only a faint,
    /// wind-soft undulation (never per-grain noise, which reads as an old emboss filter).
    func smooth(columns range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(width, range.upperBound)
        guard lo < hi else { return }
        let scale = 14 / Float(max(width, 1))
        for y in 0..<height {
            for x in lo..<hi {
                let i = y * width + x
                guard kind[i] == .sand else { continue }
                heights[i] = (Noise.fbm(Float(x) * scale, Float(y) * scale * 1.6, seed: 3) - 0.5) * 0.08
            }
        }
        markDirty(x: lo...(hi - 1), y: 0...(height - 1))
    }

    func smoothAll() {
        smooth(columns: 0..<width)
    }

    // MARK: Stones

    static func defaultStones(width: Int, height: Int) -> [Stone] {
        let w = Float(width), h = Float(height)
        return [
            Stone(x: w * 0.27, y: h * 0.38, rx: w * 0.055, ry: w * 0.042, tone: 1.0, moss: 0.34),
            Stone(x: w * 0.335, y: h * 0.52, rx: w * 0.024, ry: w * 0.019, tone: 0.9),
            Stone(x: w * 0.72, y: h * 0.62, rx: w * 0.045, ry: w * 0.034, tone: 1.08, moss: 0.26),
        ]
    }

    /// A new, calm arrangement: two or three stones, not too close to each other or the edge.
    func shuffleStones() {
        let w = Float(width), h = Float(height)
        var placed: [Stone] = []
        let count = 2 + Int(rng.next() % 2)
        var attempts = 0
        while placed.count < count, attempts < 200 {
            attempts += 1
            let rx = w * (0.028 + Float(rng.nextUnit()) * 0.03)
            let stone = Stone(
                x: w * (0.15 + Float(rng.nextUnit()) * 0.7),
                y: h * (0.2 + Float(rng.nextUnit()) * 0.6),
                rx: rx, ry: rx * (0.72 + Float(rng.nextUnit()) * 0.2),
                tone: 0.88 + Float(rng.nextUnit()) * 0.24,
                moss: rng.nextUnit() < 0.55 ? 0.22 + Float(rng.nextUnit()) * 0.16 : 0)
            let clear = placed.allSatisfy { simd_distance(SIMD2($0.x, $0.y), SIMD2(stone.x, stone.y)) > ($0.rx + stone.rx) * 2.4 }
            if clear { placed.append(stone) }
        }
        placeStones(placed)
    }

    func placeStones(_ newStones: [Stone]) {
        endStroke()
        stones = newStones
        let count = width * height
        for i in 0..<count where kind[i] != .sand {
            kind[i] = .sand
            heights[i] = 0
        }
        islandHeight = Array(repeating: 0, count: count)
        islandTone = Array(repeating: 1, count: count)

        for (n, stone) in stones.enumerated() {
            let seed = UInt32(n * 97 + 13)
            let outer = 1 + stone.moss * 1.3
            let minX = max(0, Int(stone.x - stone.rx * outer) - 2), maxX = min(width - 1, Int(stone.x + stone.rx * outer) + 2)
            let minY = max(0, Int(stone.y - stone.ry * outer) - 2), maxY = min(height - 1, Int(stone.y + stone.ry * outer) + 2)
            guard minX <= maxX, minY <= maxY else { continue }
            let size = min(stone.rx, stone.ry)
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = (Float(x) + 0.5 - stone.x) / stone.rx
                    let dy = (Float(y) + 0.5 - stone.y) / stone.ry
                    let d = (dx * dx + dy * dy).squareRoot()
                    // A slightly irregular outline, like a real river stone.
                    let angle = atan2(dy, dx)
                    let wobble = 1 + (Noise.value(cos(angle) * 1.7 + Float(n) * 5, sin(angle) * 1.7, seed: seed) - 0.5) * 0.16
                    let r = d / wobble
                    let i = y * width + x
                    let fx = Float(x), fy = Float(y)
                    if r < 1 {
                        // A flattened dome with gentle lumps; matte, speckled surface.
                        let dome = pow(1 - r * r, 0.45) * size * 0.62
                        let lumps = (Noise.fbm(fx / size * 2.2, fy / size * 2.2, seed: seed) - 0.5) * size * 0.08
                        kind[i] = .stone
                        islandHeight[i] = max(0.5, dome + lumps * (1 - r))
                        islandTone[i] = stone.tone * (0.86 + Noise.fbm(fx * 0.09, fy * 0.09, seed: seed &+ 7) * 0.22)
                            + (Float(rng.nextUnit()) - 0.5) * 0.05
                        heights[i] = 0
                    } else if stone.moss > 0 {
                        // A soft cushion of moss hugging the stone, with a ragged edge.
                        let edge = 1 + stone.moss * (0.65 + Noise.fbm(fx * 0.05, fy * 0.05, seed: seed &+ 3) * 0.7)
                        guard r < edge else { continue }
                        let t = (r - 1) / (edge - 1)                // 0 at the stone, 1 at the edge
                        let tuft = Noise.fbm(fx * 0.45, fy * 0.45, seed: seed &+ 5)
                        kind[i] = .moss
                        islandHeight[i] = (1 - t * t) * 2.6 + tuft * 3
                        // Patchy colour, a little lighter toward the sunny outer edge.
                        islandTone[i] = 0.62 + Noise.fbm(fx * 0.12, fy * 0.12, seed: seed &+ 9) * 0.5 + t * 0.18
                        heights[i] = 0
                    }
                }
            }
        }
        computeLighting()
        shadedDark = nil
    }

    /// Soft shadows from the stones, and the gentle darkening where sand meets them.
    private func computeLighting() {
        let count = width * height
        sunlight = Array(repeating: 1, count: count)

        // Shadows: march from each cell toward the light; the penumbra widens with distance.
        let step = simd_normalize(SIMD2<Float>(light.x, light.y))   // toward the light
        let rise = light.z / simd_length(SIMD2(light.x, light.y))
        for stone in stones {
            let tall = min(stone.rx, stone.ry) * 0.7
            let reach = tall / rise + 4
            let pad = max(stone.rx, stone.ry) * 1.5
            let minX = max(0, Int(stone.x - pad)), maxX = min(width - 1, Int(stone.x + pad + reach))
            let minY = max(0, Int(stone.y - pad)), maxY = min(height - 1, Int(stone.y + pad + reach))
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let i = y * width + x
                    guard kind[i] != .stone else { continue }
                    let base = islandHeight[i]
                    var p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    var t: Float = 0
                    var dark: Float = 0
                    while t < reach {
                        p += step
                        t += 1
                        let sx = Int(p.x), sy = Int(p.y)
                        guard sx >= 0, sx < width, sy >= 0, sy < height else { break }
                        let blocker = islandHeight[sy * width + sx]
                        guard blocker > base else { continue }      // only stones and moss cast shadows
                        let over = blocker - base - t * rise
                        guard over > -3 else { continue }
                        let soft = 1.5 + t * 0.18
                        let fade = 1 - t / reach * 0.45
                        dark = max(dark, smoothstep(-soft, soft, over) * fade)
                    }
                    sunlight[i] = min(sunlight[i], 1 - dark * 0.7)
                }
            }
        }

        // Contact shade: a blurred copy of the stones darkens the sand right around them.
        var mask = [Float](repeating: 0, count: count)
        for i in 0..<count {
            mask[i] = kind[i] == .stone ? 1 : kind[i] == .moss ? 0.45 : 0
        }
        let radius = max(2, width / 160)
        boxBlur(&mask, radius: radius)
        boxBlur(&mask, radius: radius)
        ambient = mask.map { 1 - min(1, $0) * 0.5 }
    }

    private func boxBlur(_ values: inout [Float], radius r: Int) {
        var temp = values
        let window = Float(2 * r + 1)
        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for x in -r...r { sum += values[row + min(max(x, 0), width - 1)] }
            for x in 0..<width {
                temp[row + x] = sum / window
                sum += values[row + min(x + r + 1, width - 1)] - values[row + max(x - r, 0)]
            }
        }
        for x in 0..<width {
            var sum: Float = 0
            for y in -r...r { sum += temp[min(max(y, 0), height - 1) * width + x] }
            for y in 0..<height {
                values[y * width + x] = sum / window
                sum += temp[min(y + r + 1, height - 1) * width + x] - temp[max(y - r, 0) * width + x]
            }
        }
    }

    // MARK: Rendering

    private struct Palette {
        var sand: SIMD3<Float>, stone: SIMD3<Float>, moss: SIMD3<Float>, mossDeep: SIMD3<Float>
        var sun: SIMD3<Float>, sky: SIMD3<Float>
        var sunAmount: Float, skyAmount: Float

        static let day = Palette(
            sand: SIMD3(0.98, 0.97, 0.94), stone: SIMD3(0.50, 0.49, 0.47),
            moss: SIMD3(0.56, 0.62, 0.36), mossDeep: SIMD3(0.33, 0.43, 0.25),
            sun: SIMD3(1.0, 0.95, 0.87), sky: SIMD3(0.80, 0.86, 1.0),
            sunAmount: 0.78, skyAmount: 0.36)
        static let night = Palette(
            sand: SIMD3(0.70, 0.70, 0.71), stone: SIMD3(0.30, 0.30, 0.31),
            moss: SIMD3(0.50, 0.60, 0.40), mossDeep: SIMD3(0.28, 0.38, 0.27),
            sun: SIMD3(0.80, 0.83, 0.92), sky: SIMD3(0.28, 0.30, 0.36),
            sunAmount: 0.72, skyAmount: 0.45)
    }

    /// Renders the garden to an RGB image, one pixel per cell. After the first call only
    /// what changed since (raking, smoothing) is shaded again.
    func render(dark: Bool) -> CGImage? {
        if shadedDark != dark {
            shade(x: 0...(width - 1), y: 0...(height - 1), dark: dark)
            shadedDark = dark
            dirty = nil
        } else if let region = dirty {
            shade(x: region.x, y: region.y, dark: dark)
            dirty = nil
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func markDirty(x: ClosedRange<Int>, y: ClosedRange<Int>) {
        // Normals look at neighbours, so shade one extra cell around the change.
        let nx = max(0, x.lowerBound - 1)...min(width - 1, x.upperBound + 1)
        let ny = max(0, y.lowerBound - 1)...min(height - 1, y.upperBound + 1)
        if let d = dirty {
            dirty = (min(d.x.lowerBound, nx.lowerBound)...max(d.x.upperBound, nx.upperBound),
                     min(d.y.lowerBound, ny.lowerBound)...max(d.y.upperBound, ny.upperBound))
        } else {
            dirty = (nx, ny)
        }
    }

    private func shade(x xs: ClosedRange<Int>, y ys: ClosedRange<Int>, dark: Bool) {
        let p = dark ? Palette.night : Palette.day
        // Grooves are a fixed share of the tine spacing, so slope scales with resolution.
        let slope = 1.8 * Float(width) / 1120
        let cx = Float(width) / 2, cy = Float(height) / 2

        for y in ys {
            let up = max(0, y - 1), down = min(height - 1, y + 1)
            for x in xs {
                let i = y * width + x
                let left = max(0, x - 1), right = min(width - 1, x + 1)
                var color: SIMD3<Float>
                switch kind[i] {
                case .stone:
                    let dx = islandHeight[y * width + right] - islandHeight[y * width + left]
                    let dy = islandHeight[down * width + x] - islandHeight[up * width + x]
                    let n = simd_normalize(SIMD3(-dx * 0.5, -dy * 0.5, 1))
                    let diffuse = max(0, (simd_dot(n, light) + 0.15) / 1.15)
                    let spec = pow(max(0, simd_reflect(-light, n).z), 10) * 0.07
                    let occlusion = 0.55 + 0.45 * n.z
                    let albedo = p.stone * islandTone[i]
                    color = albedo * (p.sun * diffuse * p.sunAmount * 1.1 + p.sky * occlusion * p.skyAmount)
                        + p.sun * spec
                case .moss:
                    let dx = islandHeight[y * width + right] - islandHeight[y * width + left]
                    let dy = islandHeight[down * width + x] - islandHeight[up * width + x]
                    let n = simd_normalize(SIMD3(-dx, -dy, 1))
                    let diffuse = max(0, (simd_dot(n, light) + 0.3) / 1.3)
                    let albedo = simd_mix(p.mossDeep, p.moss, SIMD3(repeating: min(1, max(0, islandTone[i] - 0.5))))
                    color = albedo * (p.sun * diffuse * sunlight[i] * p.sunAmount + p.sky * p.skyAmount * 0.9)
                case .sand:
                    let h = heights[i]
                    let hl = heights[y * width + left], hr = heights[y * width + right]
                    let hu = heights[up * width + x], hd = heights[down * width + x]
                    // The raked shape, plus each pebble's own rounded top.
                    let pebble = pebbleSlope[i]
                    let n = simd_normalize(SIMD3(-(hr - hl) * slope + pebble.x, -(hd - hu) * slope + pebble.y, 1))
                    // Wrapped diffuse keeps the shaded side of each ridge soft, not black.
                    let diffuse = max(0, (simd_dot(n, light) + 0.15) / 1.15)
                    // Gravel collects light on crests and a touch of shade in the grooves.
                    let curvature = (hl + hr + hu + hd - 4 * h) * slope
                    let cavity = 1 - min(0.12, max(-0.06, curvature * 0.35))
                    let tint = pebbleTint[i] * 0.025
                    let albedo = p.sand * SIMD3(1 + tint, 1, 1 - tint) * pebbleTone[i] * grain[i]
                    let gap = pebbleGap[i]
                    let glint = pebbleShine[i] * pow(max(0, simd_reflect(-light, n).z), 24) * 0.25 * sunlight[i]
                    color = albedo * cavity * gap * (p.sun * diffuse * sunlight[i] * p.sunAmount
                        + p.sky * ambient[i] * p.skyAmount) + p.sun * glint
                }
                // A faint vignette settles the eye toward the middle.
                let vx = (Float(x) - cx) / cx, vy = (Float(y) - cy) / cy
                color *= 1 - 0.10 * smoothstep(0.45, 1.35, (vx * vx + vy * vy).squareRoot())

                let o = i * 4
                pixels[o] = UInt8(max(0, min(255, color.x * 255)))
                pixels[o + 1] = UInt8(max(0, min(255, color.y * 255)))
                pixels[o + 2] = UInt8(max(0, min(255, color.z * 255)))
            }
        }
    }

    func height(atX x: Int, y: Int) -> Float { heights[y * width + x] }
    func isStone(atX x: Int, y: Int) -> Bool { kind[y * width + x] == .stone }
    func isMoss(atX x: Int, y: Int) -> Bool { kind[y * width + x] == .moss }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// Smooth value noise, for natural-looking variation that isn't per-pixel static.
enum Noise {
    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263 &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFF_FFFF) / Float(0xFF_FFFF)
    }

    static func value(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        let fx = x - x0, fy = y - y0
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let ix = Int32(clamping: Int(x0)), iy = Int32(clamping: Int(y0))
        let a = hash(ix, iy, seed), b = hash(ix &+ 1, iy, seed)
        let c = hash(ix, iy &+ 1, seed), d = hash(ix &+ 1, iy &+ 1, seed)
        return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
    }

    /// Three octaves of value noise, 0…1.
    static func fbm(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        (value(x, y, seed: seed) * 0.57 + value(x * 2.03, y * 2.03, seed: seed &+ 1) * 0.29
            + value(x * 4.1, y * 4.1, seed: seed &+ 2) * 0.14)
    }
}

/// Small deterministic random generator, so grain looks the same each launch.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

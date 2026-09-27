// Renders the MusicJournal app icon ("Dusk Record") into an .iconset.
// Run via scripts/make-icon.sh, which then builds Resources/AppIcon.icns with iconutil.
import AppKit
import SwiftUI

/// Muted "mood" tones: dusty blue → mauve → clay → sand.
let dusty: [Color] = [
    Color(red: 0.56, green: 0.64, blue: 0.75),
    Color(red: 0.70, green: 0.60, blue: 0.69),
    Color(red: 0.82, green: 0.64, blue: 0.56),
    Color(red: 0.85, green: 0.77, blue: 0.63),
]
let charcoal = Color(red: 0.20, green: 0.21, blue: 0.25)
let label = Color(red: 0.93, green: 0.90, blue: 0.86)

/// Muted vinyl on charcoal, drawn on Apple's 1024pt icon grid (824pt body, continuous corners).
struct DuskRecord: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(LinearGradient(colors: [charcoal, Color(red: 0.13, green: 0.13, blue: 0.16)], startPoint: .top, endPoint: .bottom))
            .overlay(record)
            .overlay(
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 2)
            )
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.22), radius: 20, y: 12)
            .frame(width: 1024, height: 1024)
    }

    private var record: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: dusty + [dusty[0]], center: .center, angle: .degrees(-90)))
                .frame(width: 580, height: 580)
                .opacity(0.9)
            ForEach(0..<10) { i in
                Circle()
                    .stroke(Color.black.opacity(0.10), lineWidth: 2)
                    .frame(width: CGFloat(560 - i * 34), height: CGFloat(560 - i * 34))
            }
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.18), .clear], center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 320))
                .frame(width: 580, height: 580)
            Circle().fill(label).frame(width: 170, height: 170)
            Circle().fill(charcoal).frame(width: 22, height: 22)
        }
    }
}

@MainActor
func write(size: Int, to url: URL) throws {
    let renderer = ImageRenderer(content: DuskRecord().scaleEffect(CGFloat(size) / 1024).frame(width: CGFloat(size), height: CGFloat(size)))
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

@main
struct RenderIcon {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            try write(size: points, to: out.appendingPathComponent("icon_\(points)x\(points).png"))
            try write(size: points * 2, to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
        }
        print("Wrote \(out.path)")
    }
}

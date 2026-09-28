import AppKit
import SwiftUI

/// The Zen corner: rake the sand. Nothing here is saved or sent anywhere.
struct ZenView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var garden = ZenGarden()
    @State private var cursor: CGPoint?
    @State private var cursorHidden = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Zen corner")
                    .font(Theme.Serif.page)
                Text("Drag across the gravel to rake it. Slow, steady strokes make the cleanest lines.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let image = garden.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                    }
                    if let cursor {
                        RakeCursor(tines: garden.tines, spacing: CGFloat(garden.spacing) * geo.size.width / CGFloat(garden.field.width),
                                   angle: garden.angle)
                            .position(cursor)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            cursor = value.location
                            garden.rake(to: value.location, in: geo.size)
                        }
                        .onEnded { _ in garden.endStroke() }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        cursor = location
                        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
                    case .ended:
                        cursor = nil
                        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
                    }
                }
            }
            .aspectRatio(garden.aspectRatio, contentMode: .fit)
            .frame(maxWidth: 940)

            controls
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            garden.dark = scheme == .dark
            garden.render()
        }
        .onChange(of: scheme) { _, new in garden.dark = new == .dark }
        .onDisappear {
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Text("Rake").foregroundStyle(.secondary)
            Picker("Rake", selection: $garden.tines) {
                Text("3").tag(3)
                Text("5").tag(5)
                Text("7").tag(7)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)

            Divider().frame(height: 18)

            Button {
                Task {
                    await garden.smoothSand()
                    Haptics.tap()
                }
            } label: {
                Label("Smooth the gravel", systemImage: "wind")
            }
            .buttonStyle(.glass)
            Button {
                Task {
                    await garden.moveStones()
                    Haptics.tap()
                }
            } label: {
                Label("Move stones", systemImage: "circle.grid.cross")
            }
            .buttonStyle(.glass)
        }
        .disabled(garden.isSmoothing)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A small wooden rake that follows the pointer: handle leading, tines trailing, head across
/// the stroke. Its tines line up with the grooves it leaves.
private struct RakeCursor: View {
    let tines: Int
    let spacing: CGFloat
    let angle: Double

    private let wood = Color(red: 0.55, green: 0.40, blue: 0.27)

    var body: some View {
        let headWidth = spacing * CGFloat(tines - 1) + 10
        ZStack {
            // Handle, pointing the way the rake is pulled.
            Capsule()
                .fill(LinearGradient(colors: [wood.opacity(0.95), wood.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 5, height: 64)
                .offset(y: -34)
            // Head.
            RoundedRectangle(cornerRadius: 2.5)
                .fill(wood)
                .frame(width: headWidth, height: 6)
            // Tines.
            HStack(spacing: spacing - 3) {
                ForEach(0..<tines, id: \.self) { _ in
                    Capsule().fill(wood.opacity(0.9)).frame(width: 3, height: 7)
                }
            }
            .offset(y: 5)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, x: 2, y: 3)
        .rotationEffect(.radians(angle + .pi / 2))
        .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.9), value: angle)
    }
}

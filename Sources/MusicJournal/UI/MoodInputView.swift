import SwiftUI

/// The composer: one centred Liquid Glass panel holding the question, the text box, the
/// match-or-lift switch and the Find music button, with recent moods underneath.
/// Everything is centred on one axis so the screen reads balanced.
struct MoodInputView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @Namespace private var glass

    private var canSubmit: Bool {
        !model.moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 20) {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text(greeting)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("How are you feeling?")
                        .font(Theme.titleFont)
                }
                .multilineTextAlignment(.center)

                TextField("rainy sunday, a bit melancholy but cozy", text: $model.moodText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(2...5)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(16)
                    .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.hairline(scheme))
                    )

                VStack(spacing: 8) {
                    approachPicker
                    Text(model.moodApproach.caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }

                primaryButton
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))

            if !model.recentMoods.isEmpty {
                recentMoods
            }
        }
        .onAppear { focused = true }
    }

    private var greeting: String {
        let time = TimeOfDay.describe()
        if let name = model.taste?.displayName { return "\(time), \(name)" }
        return time
    }

    private func submit() {
        guard canSubmit, !model.isWorking else { return }
        Haptics.tap()
        model.recommend()
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.isWorking {
            Button("Cancel", role: .cancel) { model.cancel() }
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            Button(action: submit) {
                Label("Find music", systemImage: "sparkles")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSubmit)
            .help("Find music (⌘↩)")
        }
    }

    /// The three mood options as equal-width glass pills that melt into one another.
    private var approachPicker: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(MoodApproach.allCases) { approach in
                    let selected = model.moodApproach == approach
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { model.moodApproach = approach }
                    } label: {
                        Text(approach.label)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .frame(width: 128)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selected ? .regular.tint(Theme.accent.opacity(0.45)).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                    .glassEffectID(approach, in: glass)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    /// Centred chips that wrap, each with when you asked. Refreshes every minute so
    /// "2 min ago" stays true while the window is open.
    private var recentMoods: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 10) {
                Text("RECENT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
                CenteredFlowLayout(spacing: 8) {
                    ForEach(model.recentMoods) { mood in
                        Button {
                            model.recommend(mood.text)
                        } label: {
                            HStack(spacing: 6) {
                                Text(mood.text.truncated(to: 36))
                                if let time = mood.relativeTime(now: context.date) {
                                    Text(time).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help(mood.date.map { "\(mood.text)\n\($0.formatted(date: .abbreviated, time: .shortened))" } ?? mood.text)
                    }
                }
            }
            .disabled(model.isWorking)
        }
    }
}

/// Lays children out in rows that wrap, with each row centred.
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8
    /// Left-align rows instead of centring them.
    var alignLeading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = alignLeading ? bounds.minX : bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

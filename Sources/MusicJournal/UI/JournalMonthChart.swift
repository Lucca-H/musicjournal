import SwiftUI

/// A month of days: each day is coloured by how it went, on one scale from awful to great.
/// Click a day to open it.
struct JournalMonthChart: View {
    @Environment(AppModel.self) private var model
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    var body: some View {
        VStack(spacing: 10) {
            header
            weekdayLabels
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                ForEach(days, id: \.self) { day in
                    DayCell(day: day)
                }
            }
            legend
        }
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous month")
            Spacer()
            Text(month, format: .dateTime.month(.wide).year())
                .font(Theme.Serif.small)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(isCurrentMonth)
                .help("Next month")
        }
        .foregroundStyle(.secondary)
    }

    private var weekdayLabels: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 5) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text("rough")
            Capsule()
                .fill(LinearGradient(colors: DayRating.allCases.map(\.color), startPoint: .leading, endPoint: .trailing))
                .frame(height: 5)
            Text("great")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var days: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    /// Empty cells before the 1st so days line up under their weekday.
    private var leadingBlanks: Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) { month = next }
    }
}

private struct DayCell: View {
    @Environment(AppModel.self) private var model
    let day: Date
    private let calendar = Calendar.current

    var body: some View {
        let journal = model.journal
        let entries = journal.entries(on: day)
        let valence = journal.valence(on: day)
        let isToday = calendar.isDateInToday(day)
        let isSelected = journal.selectedEntry.map { calendar.isDate($0.createdAt, inSameDayAs: day) } ?? false
        let isFuture = day > Date()

        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(valence.map(Theme.blend(valence:)) ?? Color.primary.opacity(entries.isEmpty ? 0.05 : 0.14))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Text("\(calendar.component(.day, from: day))")
                    .font(Theme.smallPrint)
                    .foregroundStyle(valence.map { v in
                        // Light numbers on the dark blue-hour and violet days, dark on the rest.
                        AnyShapeStyle(v < 0.4 ? Color.white.opacity(0.78) : Color.black.opacity(0.55))
                    } ?? AnyShapeStyle(.tertiary))
            }
            .overlay {
                if isSelected || isToday {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.primary.opacity(0.7) : Theme.accent, lineWidth: isSelected ? 2 : 1.5)
                }
            }
            .overlay {
                if let logged = model.lastLoggedDay, calendar.isDate(logged, inSameDayAs: day) {
                    LogRipple(trigger: model.logPulse, color: valence.map(Theme.blend(valence:)) ?? Theme.accent)
                }
            }
            .animation(.easeOut(duration: 0.6), value: valence)
            .opacity(isFuture ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if let latest = entries.first { journal.selectedID = latest.id }
            }
            .help(tooltip(entries: entries, valence: valence))
    }

    private func tooltip(entries: [JournalEntry], valence: Double?) -> String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard !entries.isEmpty else { return date }
        let count = "\(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
        let rating = valence.map { " · \(DayRating(valence: $0).label.lowercased()) day" } ?? ""
        return "\(date) · \(count)\(rating)"
    }
}

/// Every feeling and its colour.
struct FeelingKey: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(0..<(Feeling.all.count + 1) / 2, id: \.self) { row in
                GridRow {
                    ForEach(Feeling.all.dropFirst(row * 2).prefix(2)) { feeling in
                        HStack(spacing: 7) {
                            Circle().fill(feeling.color).frame(width: 10, height: 10)
                            Text(feeling.label).font(Theme.serif(12, italic: true))
                        }
                    }
                }
            }
        }
    }
}

/// A soft ring that swells out of a day's square and fades, when you log that day.
private struct LogRipple: View {
    let trigger: Int
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(color, lineWidth: 2)
            .keyframeAnimator(initialValue: RippleFrame(), trigger: trigger) { content, frame in
                content
                    .scaleEffect(frame.scale)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.0, duration: 0.01)
                    CubicKeyframe(1.7, duration: 0.7)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.9, duration: 0.01)
                    CubicKeyframe(0.0, duration: 0.7)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct RippleFrame {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

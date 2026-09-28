import SwiftUI

/// "Add log": a quick entry (how the day's going, plus a line) from anywhere in the app.
struct QuickLogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var rating: DayRating?
    @State private var text = ""
    @State private var changingDay = false
    @FocusState private var focused: Bool

    private var todayRating: DayRating? { model.journal.dayRating(on: Date()) }
    private var todayConfirmed: Bool { model.journal.isDayConfirmed(on: Date()) }
    /// Only asked once the day has mostly happened (see `DayPrompt`), or if you ask to.
    private var asking: Bool {
        changingDay || model.dayToRate().map { Calendar.current.isDateInToday($0) } == true
    }

    private var canSave: Bool {
        rating != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text("Add a log")
                    .font(Theme.Serif.sheet)
                Text(TimeOfDay.describe())
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Asked from the evening on; before that (or once answered) it's a quiet line.
            Group {
                if asking {
                    VStack(spacing: 8) {
                        DayRatingPicker(title: "How was the day?", current: rating ?? todayRating) { choice in
                            // Tapping a guessed rating confirms it rather than clearing it.
                            rating = choice == nil && !todayConfirmed ? todayRating : choice
                        }
                        if rating == nil, todayRating != nil, !todayConfirmed {
                            Text("Guessed from your mood. Tap to confirm or change.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    DayRatingSummary(current: todayRating, guessed: !todayConfirmed, invitation: "Rate today") {
                        changingDay = true
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: changingDay)

            TextField("What happened? A line is enough.", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Serif.note)
                .lineLimit(3...6)
                .focused($focused)
                .onSubmit(save)
                .padding(14)
                .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.hairline(scheme))
                )

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: save) {
                    Label("Log it", systemImage: "checkmark")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(width: 440)
        .tint(Theme.accent)
        .onAppear { focused = true }
    }

    private func save() {
        guard canSave else { return }
        model.saveQuickLog(rating: rating, text: text)
        dismiss()
    }
}

/// The quiet confirmation that rises from the bottom after logging or saving.
struct LoggedToast: View {
    let text: String
    @State private var drawn = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, options: .nonRepeating, value: drawn)
            Text(text)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .onAppear { drawn = true }
    }
}

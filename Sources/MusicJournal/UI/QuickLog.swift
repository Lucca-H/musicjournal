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

    private var canSave: Bool {
        rating != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text("Add a log")
                    .font(.system(size: 26, weight: .regular, design: .serif))
                Text(TimeOfDay.describe())
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Asked once a day: if today already has an answer, it's just a quiet line.
            Group {
                if let answered = todayRating, !changingDay {
                    DayRatingSummary(current: answered) { changingDay = true }
                } else {
                    DayRatingPicker(title: "How's the day?", current: rating ?? (changingDay ? todayRating : nil)) { choice in
                        rating = choice
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: changingDay)

            TextField("What happened? A line is enough.", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .serif))
                .lineLimit(3...6)
                .focused($focused)
                .onSubmit(save)
                .padding(14)
                .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                .symbolEffect(.bounce, value: drawn)
            Text(text)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .onAppear { drawn = true }
    }
}

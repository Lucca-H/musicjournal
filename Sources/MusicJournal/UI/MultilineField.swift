import SwiftUI

/// A labelled, multi-line text box (Settings, onboarding). Unlike a TextField in a Form, Return adds a
/// new line here, so "one per line" lists can actually be typed.
struct MultilineField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 110)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(Theme.surface(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.hairline(scheme))
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

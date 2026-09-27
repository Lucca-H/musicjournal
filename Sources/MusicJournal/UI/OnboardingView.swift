import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MusicJournal")
                    .font(Theme.titleFont)
                Text("Tell it how you feel. Get the music for it.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Free mode needs no setup, so onboarding only appears for Spotify account mode.
            AccountSetup()

            StatusBanner()
        }
        .padding(32)
        .frame(width: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }
}

private struct AccountSetup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 18) {
            if model.phase == .needsSetup || model.clientID.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Create a Spotify developer app") {
                        Text("Open the dashboard, click **Create app**, and tick **Web API**. The account needs Spotify Premium.")
                        Link("developer.spotify.com/dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    }
                    step(2, "Add this Redirect URI") {
                        RedirectURIField()
                    }
                    step(3, "Paste the app's Client ID") {
                        TextField("Client ID", text: $model.clientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                }
            }

            Button {
                Task { await model.signIn() }
            } label: {
                Label("Connect Spotify", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(model.clientID.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("No Premium? Use free mode instead.") {
                Task { await model.setAccessMode(.free) }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.accent.opacity(0.22)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RedirectURIField: View {
    @State private var copied = false

    var body: some View {
        HStack {
            Text(SpotifyConfig.redirectURI)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SpotifyConfig.redirectURI, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
    }
}

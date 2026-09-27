import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PersonalizationSettings()
                .tabItem { Label("Personalization", systemImage: "person.crop.circle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
    }
}

/// Optional personalization. Recommendations go by mood; this shapes them.
private struct PersonalizationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                Picker("Mood", selection: $model.moodApproach) {
                    ForEach(MoodApproach.allCases) { Text($0.label).tag($0) }
                }
                Picker("Discovery", selection: $model.discovery) {
                    ForEach(Discovery.allCases) { Text($0.label).tag($0) }
                }
                Picker("Vocals", selection: $model.vocals) {
                    ForEach(VocalPreference.allCases) { Text($0.label).tag($0) }
                }
                Picker("Songs per mix", selection: $model.mixLength) {
                    ForEach(AppModel.mixLengths, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Clean lyrics only", isOn: $model.cleanOnly)
            } header: {
                Text("How to pick")
            } footer: {
                Text("Your mood always comes first. These apply to every mix.")
            }

            Section {
                Picker("Use my taste", selection: $model.tasteInfluence) {
                    ForEach(TasteInfluence.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.tasteInfluence.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Group {
                    field("Artists", text: $model.profileArtistsText, prompt: "Separated by commas or new lines")
                    field("Favourite songs", text: $model.profileSongsText, prompt: "One per line (Return), or separated by ;\ne.g. Holocene — Bon Iver")
                    field("Genres & vibes", text: $model.profileGenresText, prompt: "e.g. pop rock, bedroom pop, rainy acoustic")
                    field("Eras", text: $model.profileErasText, prompt: "e.g. 90s, 2000s")
                    field("Languages", text: $model.profileLanguagesText, prompt: "e.g. English, Spanish, Korean")
                    field("Songs you liked", text: $model.likedSongsText, prompt: "Fills in when you thumbs-up a song")
                }
                .disabled(model.tasteInfluence == .off)
            } header: {
                Text("What you like")
            } footer: {
                Text("All optional. Subtle never replays the favourite songs you list here.")
            }

            Section {
                field("Artists & genres", text: $model.profileAvoidText, prompt: "Never suggest these")
                field("Songs you skipped", text: $model.skippedSongsText, prompt: "Fills in when you thumbs-down a song")
            } header: {
                Text("Not for me")
            } footer: {
                Text("Always respected, even when “Use my taste” is off.")
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        MultilineField(title: title, text: text, placeholder: prompt)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let mode = Binding(
            get: { model.accessMode },
            set: { newMode in Task { await model.setAccessMode(newMode) } }
        )

        Form {
            Section("Spotify") {
                Picker("Mode", selection: mode) {
                    ForEach(AccessMode.allCases) { Text($0.label).tag($0) }
                }

                switch model.accessMode {
                case .free:
                    Text("Songs are checked with Apple's free iTunes search and open in the Spotify app. No login needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .spotifyAccount:
                    TextField("Client ID", text: $model.clientID)
                        .font(.body.monospaced())
                    LabeledContent("Redirect URI") { RedirectURIField() }
                    if model.phase == .ready {
                        LabeledContent("Signed in as") {
                            Text(model.taste?.displayName ?? model.taste?.userID ?? "—")
                        }
                        HStack {
                            Button("Refresh listening history") {
                                Task { await model.loadProfile(forceRefresh: true) }
                            }
                            Button("Sign out", role: .destructive) {
                                Task { await model.signOut() }
                            }
                        }
                    } else {
                        Button("Connect Spotify") { Task { await model.signIn() } }
                            .disabled(model.clientID.isEmpty)
                    }
                }
            }

            Section("Mood brain") {
                Picker("Use", selection: $model.brainPreference) {
                    ForEach(BrainPreference.allCases) { Text($0.label).tag($0) }
                }
                TextField("Claude model", text: $model.claudeModel, prompt: Text("Default (your Claude Code model)"))
                TextField("Claude CLI path", text: $model.claudePath, prompt: Text("Auto-detect"))
                    .onSubmit { Task { await model.refreshDiagnostics() } }
                LabeledContent("Claude Code") {
                    Text(model.detectedClaudePath ?? "Not found")
                        .foregroundStyle(model.detectedClaudePath == nil ? .orange : .secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("On-device model") {
                    Text(model.onDeviceStatus)
                        .foregroundStyle(model.onDeviceStatus == "Ready" ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshDiagnostics() }
    }
}

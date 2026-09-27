import Foundation
import FoundationModels

/// Apple's on-device Foundation Model. Built with `DynamicGenerationSchema` rather than
/// `@Generable` so it compiles without Xcode's macro plugins.
struct AppleBrain: MoodBrain {
    let kind = BrainKind.onDevice

    /// nil when the model is ready, otherwise a human-readable reason.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off (System Settings → Apple Intelligence & Siri)."
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple's on-device model."
        case .unavailable(.modelNotReady):
            return "Apple's on-device model is still downloading."
        case .unavailable(let other):
            return "Apple's on-device model is unavailable (\(other))."
        }
    }

    func interpret(_ request: MoodRequest) async throws -> MoodPlan {
        if let reason = Self.unavailableReason {
            throw BrainError.unavailable(reason)
        }
        let session = LanguageModelSession(instructions: MoodPrompt.system)
        do {
            let response = try await session.respond(
                to: MoodPrompt.user(request, compact: true),
                schema: try Self.makeSchema()
            )
            return try JSONDecoder().decode(MoodPlan.self, from: Data(response.content.jsonString.utf8))
        } catch let error as LanguageModelSession.GenerationError {
            throw BrainError.failed("On-device model: \(error.localizedDescription)")
        } catch let error as DecodingError {
            throw BrainError.badOutput(String(describing: error).truncated(to: 200))
        }
    }

    static func makeSchema() throws -> GenerationSchema {
        func string() -> DynamicGenerationSchema {
            DynamicGenerationSchema(type: String.self)
        }
        func array(_ of: DynamicGenerationSchema, max: Int) -> DynamicGenerationSchema {
            DynamicGenerationSchema(arrayOf: of, minimumElements: 0, maximumElements: max)
        }
        let unit = DynamicGenerationSchema(type: Double.self, guides: [.range(0...1)])

        let pick = DynamicGenerationSchema(name: "Pick", properties: [
            .init(name: "id", description: "Playlist id copied exactly from the list", schema: string()),
            .init(name: "reason", description: "Why it fits, a few words", schema: string()),
        ])
        let track = DynamicGenerationSchema(name: "TrackIdea", properties: [
            .init(name: "title", description: "Exact song title", schema: string()),
            .init(name: "artist", description: "Primary artist", schema: string()),
        ])
        let plan = DynamicGenerationSchema(name: "MoodPlan", properties: [
            .init(name: "interpretation", description: "One sentence reading of the mood", schema: string()),
            .init(name: "energy", description: "0 still to 1 intense", schema: unit),
            .init(name: "valence", description: "0 dark/sad to 1 bright/happy", schema: unit),
            .init(name: "keywords", description: "3-6 mood keywords", schema: array(string(), max: 6)),
            .init(name: "ownedPlaylistPicks", description: "Fitting playlists from the listener's list", schema: array(pick, max: 5)),
            .init(name: "playlistSearchQueries", description: "Short Spotify playlist search phrases", schema: array(string(), max: 5)),
            .init(name: "trackSuggestions", description: "Real songs that fit the mood", schema: array(track, max: 15)),
            .init(name: "mixName", description: "Evocative playlist name under 40 characters", schema: string()),
            .init(name: "mixDescription", description: "One sentence description", schema: string()),
        ])
        return try GenerationSchema(root: plan, dependencies: [])
    }
}

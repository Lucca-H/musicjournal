import Foundation

struct PickedPlaylist: Sendable, Identifiable, Hashable {
    let playlist: PlaylistSummary
    let reason: String
    var id: String { playlist.id }
}

struct MixEntry: Sendable, Identifiable, Hashable {
    let id: Int
    let idea: MoodPlan.TrackIdea
    let lookup: TrackLookup

    var track: TrackSummary? { lookup.track }

    /// Where a click goes: the verified track, or a Spotify search for the suggestion.
    var openTarget: (uri: String, webURL: URL?) {
        if let track { return (track.uri, track.webURL) }
        return SpotifyLinks.search("\(idea.title) \(idea.artist)")
    }
}

struct Recommendation: Sendable, Identifiable {
    let id = UUID()
    let createdAt = Date()
    let mood: String
    let plan: MoodPlan
    let brain: BrainKind
    let fallbackReason: String?
    let fromLibrary: [PickedPlaylist]
    let discovered: [PickedPlaylist]
    /// Shown as "search on Spotify" cards when the catalog can't list playlists (free mode).
    let searchPhrases: [String]
    let mix: [MixEntry]
    let canSaveMix: Bool
    let catalogName: String
}

enum RecommendationStage: Sendable {
    case thinking
    case searching
}

struct RecommendationEngine: Sendable {
    let catalog: any MusicCatalog
    let brain: FallbackBrain

    func recommend(
        mood: String,
        taste: TasteProfile,
        personalization: Personalization = Personalization(),
        onStage: @escaping @Sendable (RecommendationStage) async -> Void
    ) async throws -> Recommendation {
        await onStage(.thinking)
        let result = try await brain.interpret(MoodRequest(mood: mood, taste: taste, personalization: personalization))
        // Subtle promises mostly new music, so enforce its cap on your artists here rather
        // than trusting the model to count.
        let yourArtists = personalization.artists
            + taste.recentArtists.map(\.name) + taste.longTermArtists.map(\.name)
        let plan = result.plan.sanitized(
            validPlaylistIDs: Set(taste.playlists.map(\.id)),
            excluded: personalization.excludedSongs,
            favouriteArtists: personalization.influence == .subtle ? yourArtists : [],
            maxFromFavourites: 3,
            maxTracks: min(max(personalization.mixLength, 5), 40)
        )

        await onStage(.searching)
        let byID = Dictionary(taste.playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fromLibrary = plan.ownedPlaylistPicks.compactMap { pick in
            byID[pick.id].map { PickedPlaylist(playlist: $0, reason: pick.reason) }
        }

        async let discovered = catalog.listsPlaylists
            ? catalog.discoverPlaylists(queries: plan.playlistSearchQueries, excluding: Set(byID.keys))
            : []
        async let mix = resolveTracks(plan.trackSuggestions, cleanOnly: personalization.cleanOnly)

        return Recommendation(
            mood: mood,
            plan: plan,
            brain: result.brain,
            fallbackReason: result.fallbackReason,
            fromLibrary: fromLibrary,
            discovered: try await discovered,
            searchPhrases: catalog.listsPlaylists ? [] : plan.playlistSearchQueries,
            mix: await mix,
            canSaveMix: catalog.listsPlaylists,
            catalogName: catalog.name
        )
    }

    private func resolveTracks(_ ideas: [MoodPlan.TrackIdea], cleanOnly: Bool) async -> [MixEntry] {
        let catalog = catalog
        let lookups = (try? await concurrentMap(ideas, limit: catalog.lookupConcurrency) { idea in
            await catalog.lookup(idea)
        }) ?? Array(repeating: .unverified, count: ideas.count)

        var seen = Set<String>()
        return ideas.enumerated().compactMap { index, idea in
            if let track = lookups[index].track {
                // Two ideas can resolve to the same song; keep the first.
                guard seen.insert(track.id).inserted else { return nil }
                // The prompt asks for clean songs; drop any the catalog knows are explicit.
                if cleanOnly && track.isExplicit == true { return nil }
            }
            return MixEntry(id: index, idea: idea, lookup: lookups[index])
        }
    }
}

/// Order-preserving async map with at most `limit` tasks in flight.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        func launch() {
            let index = next
            let item = items[index]
            group.addTask { (index, try await transform(item)) }
            next += 1
        }
        while next < min(max(limit, 1), items.count) { launch() }
        while let (index, value) = try await group.next() {
            results[index] = value
            if next < items.count { launch() }
        }
        return results.map { $0! }
    }
}

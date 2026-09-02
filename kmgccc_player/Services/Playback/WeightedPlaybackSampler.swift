//
//  WeightedPlaybackSampler.swift
//  myPlayer2
//
//  Preference-aware track selection for playback commands.
//

import Foundation

/// Encapsulates preference scoring and runtime penalties used when choosing a
/// track for a one-shot random playback request.
///
/// Stateful shuffle sessions remain owned by `ShuffleSession`. This type only
/// handles the small, stateless selection strategy that used to live inside
/// `PlaybackCoordinator`.
@MainActor
struct WeightedPlaybackSampler {
    static func playableUniqueTracks(from tracks: [Track]) -> [Track] {
        var seenIDs = Set<UUID>()
        return tracks.filter { track in
            guard !seenIDs.contains(track.id) else { return false }
            seenIDs.insert(track.id)
            return track.availability != .missing
        }
    }

    static func pick(
        from tracks: [Track],
        recentHistory: [UUID] = [],
        preferenceStatsService: PreferenceStatsService
    ) -> Track? {
        let uniqueTracks = playableUniqueTracks(from: tracks)
        guard !uniqueTracks.isEmpty else { return nil }

        let trackByID = Dictionary(uniqueKeysWithValues: uniqueTracks.map { ($0.id, $0) })
        let weights = Dictionary(uniqueKeysWithValues: uniqueTracks.map { track in
            let stats = preferenceStatsService.getStats(for: track.id)
            let score = PreferenceScorerV2.calculateScore(
                stats: stats,
                duration: track.duration,
                manualLikeState: stats.manualLikeState
            )
            return (track.id, score.baseWeight)
        })

        let adjustedWeights = Dictionary(uniqueKeysWithValues: uniqueTracks.map { track in
            let baseWeight = weights[track.id] ?? 1
            let runtimeWeight = PreferenceScorerV2.applyRuntimePenalties(
                baseWeight: baseWeight,
                track: track,
                recentHistory: recentHistory,
                tracks: trackByID
            )
            return (track.id, runtimeWeight)
        })

        guard let selectedID = WeightedRandomSampler.sample(
            from: uniqueTracks.map(\.id),
            weights: adjustedWeights
        ) else {
            return nil
        }

        return trackByID[selectedID]
    }
}

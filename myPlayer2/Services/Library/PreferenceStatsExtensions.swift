//
//  PreferenceStatsExtensions.swift
//  myPlayer2
//
//  Smart Shuffle - Preference Stats Extensions
//  Convenience extensions for accessing and modifying preference stats.
//

import SwiftUI

// MARK: - Track Preference Extensions

@MainActor
extension Track {
    /// Get the preference stats for this track.
    var preferenceStats: TrackPreferenceStats {
        PreferenceStatsService.shared.getStats(for: id)
    }

    /// Get the effective weight for weighted random selection.
    var effectiveWeight: Double {
        preferenceStats.effectiveWeightCache
    }

    /// Get the preference score (V2: finalPreference, human-readable range).
    var preferenceScore: Double {
        preferenceStats.preferenceScoreCache
    }

    /// Get the bounded preference (-1.0 ~ 1.0, V2 algorithm).
    var boundedPreference: Double {
        let result = PreferenceScorerV2.calculateScore(
            stats: preferenceStats,
            duration: duration,
            manualLikeState: preferenceStats.manualLikeState
        )
        return result.boundedPreference
    }

    /// Whether this track has been manually liked.
    var isManuallyLiked: Bool {
        preferenceStats.manualLikeState == .liked
    }

    /// Whether this track has been manually disliked.
    var isManuallyDisliked: Bool {
        preferenceStats.manualLikeState == .disliked
    }

    /// Toggle the manual like state (none -> liked -> disliked -> none).
    func toggleManualLikeState() {
        let current = preferenceStats.manualLikeState
        let next = current.nextState
        guard current != next else { return }
        PreferenceStatsService.shared.setManualLikeState(trackID: id, state: next)
        LocalLibraryService.shared.writeMetaOnly(for: self, reason: "manualLike")
    }

    /// Set manual like state explicitly.
    func setManualLikeState(_ state: ManualLikeState) {
        guard preferenceStats.manualLikeState != state else { return }
        PreferenceStatsService.shared.setManualLikeState(trackID: id, state: state)
        LocalLibraryService.shared.writeMetaOnly(for: self, reason: "manualLike")
    }
}

// MARK: - Preference Score Description

extension TrackPreferenceStats {
    /// Human-readable description of preference.
    var preferenceDescription: String {
        switch manualLikeState {
        case .liked:
            return "👍 Liked"
        case .disliked:
            return "👎 Disliked"
        case .none:
            break
        }

        if playCount == 0 {
            return "🆕 New"
        }

        if quickSkipRatio > 0.5 {
            return "⏭️ Often Skipped"
        }

        if averageCompletionRatio >= 0.8 {
            return "❤️ Favorite"
        }

        if averageCompletionRatio >= 0.5 {
            return "👍 Liked"
        }

        if skipRatio > 0.5 {
            return "👎 Rarely Finished"
        }

        return "😐 Neutral"
    }

    /// Short symbol representing preference.
    var preferenceSymbol: String {
        switch manualLikeState {
        case .liked: return "heart.fill"
        case .disliked: return "hand.thumbsdown.fill"
        case .none: break
        }

        if playCount == 0 { return "circle" }
        if quickSkipRatio > 0.5 { return "forward" }
        if averageCompletionRatio >= 0.8 { return "heart.fill" }
        if averageCompletionRatio >= 0.5 { return "hand.thumbsup.fill" }
        if skipRatio > 0.5 { return "hand.thumbsdown" }
        return "minus"
    }

    /// Color representing preference state.
    var preferenceColor: Color {
        switch manualLikeState {
        case .liked: return .pink
        case .disliked: return .gray
        case .none: break
        }

        if playCount == 0 { return .blue }
        if quickSkipRatio > 0.5 { return .orange }
        if averageCompletionRatio >= 0.8 { return .pink }
        if averageCompletionRatio >= 0.5 { return .green }
        if skipRatio > 0.5 { return .gray }
        return .secondary
    }
}

// MARK: - Manual Like State Icons

extension ManualLikeState {
    var iconName: String {
        switch self {
        case .none: return "heart"
        case .liked: return "heart.fill"
        case .disliked: return "heart.slash.fill"
        }
    }

    var label: String {
        switch self {
        case .none: return "Not Rated"
        case .liked: return "Liked"
        case .disliked: return "Disliked"
        }
    }

    var nextState: ManualLikeState {
        switch self {
        case .none: return .liked
        case .liked: return .disliked
        case .disliked: return .none
        }
    }
}

// MARK: - App Lifecycle Integration

/// Handles saving preference stats on app lifecycle events.
final class PreferenceStatsLifecycleHandler {
    static let shared = PreferenceStatsLifecycleHandler()

    private init() {
        setupNotifications()
    }

    private func setupNotifications() {
        // Save on app resign active (user switches away).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savePendingStats),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // Save on app termination.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(savePendingStats),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // Periodic save every 5 minutes.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                await PreferenceStatsService.shared.saveAllPending()
            }
        }
    }

    @objc private func savePendingStats() {
        Task { @MainActor in
            await PreferenceStatsService.shared.saveAllPending()
        }
    }
}

// MARK: - Debug Information

extension PreferenceStatsService {
    /// Get detailed debug info for a track.
    func debugInfo(for trackID: UUID) -> String {
        let stats = getStats(for: trackID)

        return """
        Preference Stats:
        - Play Count: \(stats.playCount)
        - Complete Plays: \(stats.completePlayCount)
        - Skips: \(stats.skipCount) (Quick: \(stats.quickSkipCount))
        - Total Listened: \(Int(stats.totalPlayedSeconds))s
        - Avg Completion: \(Int(stats.averageCompletionRatio * 100))%
        - Preference Score: \(Int(stats.preferenceScoreCache))
        - Effective Weight: \(String(format: "%.2f", stats.effectiveWeightCache))
        - Manual State: \(stats.manualLikeState.rawValue)
        """
    }
}

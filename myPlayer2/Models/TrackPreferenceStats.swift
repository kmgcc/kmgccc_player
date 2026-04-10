//
//  TrackPreferenceStats.swift
//  myPlayer2
//
//  Smart Shuffle - Track Preference Statistics
//  Extended playback statistics for preference-based weighted random playback.
//

import Foundation

/// Manually set like/dislike state for a track.
/// This directly influences the preference score.
enum ManualLikeState: String, Codable, CaseIterable {
    case none = "none"
    case liked = "liked"
    case disliked = "disliked"
}

/// Comprehensive playback statistics for a track.
/// Stored in meta.json sidecar and used for preference scoring.
struct TrackPreferenceStats: Codable, Equatable {
    // MARK: - Basic Counts

    /// Total number of times playback started (playCount >= 2 seconds).
    var playCount: Int = 0

    /// Number of times track was played to completion (>= 85% or <= 12s remaining).
    var completePlayCount: Int = 0

    /// Number of times user actively skipped before completion.
    var skipCount: Int = 0

    /// Number of quick skips (< 12s or < 8% played).
    var quickSkipCount: Int = 0

    // MARK: - Time Tracking

    /// Total seconds actually listened across all sessions.
    var totalPlayedSeconds: Double = 0

    /// Timestamp of last playback start.
    var lastPlayedAt: Date?

    /// Timestamp of last completed playback.
    var lastCompletedAt: Date?

    /// Timestamp of last skip (user actively skipped).
    var lastSkippedAt: Date?

    // MARK: - Manual Override

    /// User's explicit like/dislike state.
    var manualLikeState: ManualLikeState = .none

    // MARK: - Cached Scores

    /// Cached preference score (computed from stats).
    /// Range: typically -100 to +100, but unbounded.
    var preferenceScoreCache: Double = 0

    /// Cached effective weight for random selection.
    /// Range: 0.25 to 2.5 (enforced limits to prevent extreme values).
    var effectiveWeightCache: Double = 1.0

    // MARK: - Versioning

    /// Schema version for migration support.
    static let currentSchemaVersion: Int = 3

    enum CodingKeys: String, CodingKey {
        case playCount
        case completePlayCount
        case skipCount
        case quickSkipCount
        case totalPlayedSeconds
        case lastPlayedAt
        case lastCompletedAt
        case lastSkippedAt
        case manualLikeState
        case preferenceScoreCache
        case effectiveWeightCache
    }

    // MARK: - Initialization

    init(
        playCount: Int = 0,
        completePlayCount: Int = 0,
        skipCount: Int = 0,
        quickSkipCount: Int = 0,
        totalPlayedSeconds: Double = 0,
        lastPlayedAt: Date? = nil,
        lastCompletedAt: Date? = nil,
        lastSkippedAt: Date? = nil,
        manualLikeState: ManualLikeState = .none,
        preferenceScoreCache: Double = 0,
        effectiveWeightCache: Double = 1.0
    ) {
        self.playCount = playCount
        self.completePlayCount = completePlayCount
        self.skipCount = skipCount
        self.quickSkipCount = quickSkipCount
        self.totalPlayedSeconds = totalPlayedSeconds
        self.lastPlayedAt = lastPlayedAt
        self.lastCompletedAt = lastCompletedAt
        self.lastSkippedAt = lastSkippedAt
        self.manualLikeState = manualLikeState
        self.preferenceScoreCache = preferenceScoreCache
        self.effectiveWeightCache = effectiveWeightCache
    }

    // MARK: - Computed Properties

    /// Average completion ratio across all plays.
    var averageCompletionRatio: Double {
        guard playCount > 0 else { return 0 }
        return Double(completePlayCount) / Double(playCount)
    }

    /// Skip ratio (lower is better).
    var skipRatio: Double {
        guard playCount > 0 else { return 0 }
        return Double(skipCount) / Double(playCount)
    }

    /// Quick skip ratio (lower is better, high indicates strong dislike).
    var quickSkipRatio: Double {
        guard playCount > 0 else { return 0 }
        return Double(quickSkipCount) / Double(playCount)
    }

    /// Whether this track has enough data for reliable scoring.
    var hasReliableData: Bool {
        playCount >= 3
    }
}

// MARK: - Merge with Legacy Stats

extension TrackPreferenceStats {
    /// Create from legacy playCount value (migration).
    static func fromLegacy(playCount: Int) -> TrackPreferenceStats {
        var stats = TrackPreferenceStats()
        stats.playCount = playCount
        // Assume legacy plays were complete plays (conservative estimate).
        stats.completePlayCount = playCount
        return stats
    }
}

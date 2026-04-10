//
//  PlaybackSessionTracker.swift
//  myPlayer2
//
//  Smart Shuffle - Playback Session Tracker
//  Tracks playback behavior to detect completes, skips, and quick skips.
//

import Foundation
import SwiftData

/// Represents the outcome of a playback session.
enum PlaybackSessionOutcome: Equatable {
    /// Playback completed naturally (reached end).
    case completed

    /// User actively skipped before completion.
    case skipped(progress: Double, playedSeconds: Double)

    /// Playback was interrupted (device change, app quit, etc).
    case interrupted(progress: Double, playedSeconds: Double)

    /// Playback was very short (< 2 seconds), doesn't count as a play.
    case tooShort
}

/// Tracks a single playback session with detailed metrics.
/// Determines whether the session counts as a play, complete play, skip, or quick skip.
@MainActor
final class PlaybackSessionTracker {

    // MARK: - Configuration

    /// Minimum play duration to count as a play (seconds).
    static let minPlayDuration: Double = 2.0

    /// Threshold for complete play: >= 85% played.
    static let completePlayPercentage: Double = 0.85

    /// Threshold for complete play: <= 12 seconds remaining.
    static let completePlayRemainingSeconds: Double = 12.0

    /// Threshold for quick skip: < 12 seconds played.
    static let quickSkipDuration: Double = 12.0

    /// Threshold for quick skip: < 8% played.
    static let quickSkipPercentage: Double = 0.08

    // MARK: - Session State

    private let track: Track
    private let trackDuration: Double
    private let startTime: Date

    private var lastProgressTime: Double = 0
    private var maxProgressReached: Double = 0
    private var hasReachedMinPlayThreshold: Bool = false

    /// Total accumulated played seconds.
    internal private(set) var totalPlayedSeconds: Double = 0

    /// Whether this session has crossed the minimum play threshold.
    var isValidPlay: Bool { hasReachedMinPlayThreshold }

    /// Whether the track was played to completion.
    internal private(set) var isCompleted: Bool = false

    /// Whether the session ended due to user action (vs auto/system).
    private(set) var endedByUserAction: Bool = false

    /// Whether the track is currently playing.
    private(set) var isActive: Bool = true

    // MARK: - Initialization

    init(track: Track) {
        self.track = track
        self.trackDuration = track.duration
        self.startTime = Date()
        self.lastProgressTime = 0
    }

    // MARK: - Progress Updates

    /// Update progress during playback.
    func updateProgress(currentTime: Double) {
        guard isActive else { return }
        guard trackDuration > 0 else { return }

        let progressDelta = max(0, currentTime - lastProgressTime)
        if progressDelta > 0 {
            totalPlayedSeconds += progressDelta
        }
        lastProgressTime = currentTime
        maxProgressReached = max(maxProgressReached, currentTime)

        // Check if we've reached minimum play threshold.
        if !hasReachedMinPlayThreshold && totalPlayedSeconds >= Self.minPlayDuration {
            hasReachedMinPlayThreshold = true
        }
    }

    /// Mark the track as completed naturally (reached end).
    func markCompleted() {
        guard isActive else { return }
        isActive = false
        isCompleted = true
        endedByUserAction = false
        maxProgressReached = trackDuration
    }

    /// Mark the session as ended by user action (pressed next/previous button).
    func markEndedByUserAction() {
        guard isActive else { return }
        endedByUserAction = true
    }

    /// Mark the session as ended by system/app (not user action).
    func markEndedBySystem() {
        guard isActive else { return }
        endedByUserAction = false
    }

    /// End the session and compute the outcome.
    func finalize() -> PlaybackSessionOutcome {
        guard isActive else {
            // Already finalized, return based on recorded state.
            return computeOutcome()
        }
        isActive = false
        return computeOutcome()
    }

    // MARK: - Outcome Computation

    private func computeOutcome() -> PlaybackSessionOutcome {
        let progress = trackDuration > 0 ? maxProgressReached / trackDuration : 0

        // If too short, don't count as a play at all.
        if totalPlayedSeconds < Self.minPlayDuration {
            return .tooShort
        }

        // If completed naturally, it's a complete play.
        if isCompleted {
            return .completed
        }

        // Check for complete play criteria (even if user skipped).
        let remainingSeconds = trackDuration - maxProgressReached
        let metCompletePercentage = progress >= Self.completePlayPercentage
        let metCompleteRemaining = remainingSeconds <= Self.completePlayRemainingSeconds

        if metCompletePercentage || metCompleteRemaining {
            // User was very close to the end, treat as completed.
            return .completed
        }

        // Determine if this was a user-initiated skip or system interrupt.
        if endedByUserAction {
            return .skipped(progress: progress, playedSeconds: totalPlayedSeconds)
        } else {
            return .interrupted(progress: progress, playedSeconds: totalPlayedSeconds)
        }
    }

    // MARK: - Quick Skip Detection

    /// Check if the current state qualifies as a quick skip.
    func isQuickSkip() -> Bool {
        guard trackDuration > 0 else { return false }

        let progress = maxProgressReached / trackDuration

        // Quick skip: very short play time OR very small percentage.
        let isShortDuration = totalPlayedSeconds < Self.quickSkipDuration
        let isSmallProgress = progress < Self.quickSkipPercentage

        return isShortDuration || isSmallProgress
    }

    // MARK: - Statistics Update

    /// Apply this session's outcome to track statistics.
    /// Returns the updated stats for persistence.
    func applyToStats(_ stats: inout TrackPreferenceStats) -> TrackPreferenceStats {
        let outcome = finalize()

        switch outcome {
        case .tooShort:
            // Don't update any stats for very short plays.
            break

        case .completed:
            stats.playCount += 1
            stats.completePlayCount += 1
            stats.totalPlayedSeconds += totalPlayedSeconds
            stats.lastPlayedAt = startTime
            stats.lastCompletedAt = Date()

        case .skipped(let progress, _):
            stats.playCount += 1
            stats.skipCount += 1
            stats.totalPlayedSeconds += totalPlayedSeconds
            stats.lastPlayedAt = startTime
            stats.lastSkippedAt = Date()

            // Check for quick skip.
            let isQuick = isQuickSkip()
            if isQuick {
                stats.quickSkipCount += 1
            }

        case .interrupted(let progress, _):
            // Interrupted plays count as plays but not skips.
            stats.playCount += 1
            stats.totalPlayedSeconds += totalPlayedSeconds
            stats.lastPlayedAt = startTime

            // If they got close to completion, count as complete.
            let remainingSeconds = trackDuration - maxProgressReached
            let metCompletePercentage = progress >= Self.completePlayPercentage
            let metCompleteRemaining = remainingSeconds <= Self.completePlayRemainingSeconds

            if metCompletePercentage || metCompleteRemaining {
                stats.completePlayCount += 1
                stats.lastCompletedAt = Date()
            }
        }

        return stats
    }
}

// MARK: - Non-interactive Skip Detection

extension PlaybackSessionTracker {
    /// Determine if a transition was caused by seeking/dragging.
    /// When user drags progress bar, we get a seek followed by a position update.
    /// This should NOT be counted as a skip.
    static func isSeekingTransition(
        from previousTime: Double,
        to newTime: Double,
        duration: Double
    ) -> Bool {
        // Large backward jumps are typically seeks.
        // Small forward jumps could be seeks or normal playback.
        let timeDiff = newTime - previousTime

        // If time went backwards significantly, it's a seek.
        if timeDiff < -1.0 {
            return true
        }

        // If time jumped forward by more than 5 seconds (more than typical tick interval).
        if timeDiff > 5.0 {
            return true
        }

        return false
    }
}

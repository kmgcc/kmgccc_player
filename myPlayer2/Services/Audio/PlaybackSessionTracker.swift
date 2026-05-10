//
//  PlaybackSessionTracker.swift
//  myPlayer2
//
//  Smart Shuffle - Playback Session Tracker
//  Tracks playback behavior to detect completes, skips, and quick skips.
//

import Foundation
import SwiftData

/// Why a playback session ended.
/// This is intentionally more specific than "user initiated" because stats semantics differ.
enum PlaybackSessionEndReason: Equatable {
    case naturalCompletion
    case userNext
    case userPrevious
    case userJumpToTrack
    case userJumpWithinQueue
    case systemInterrupt
    case appTermination
    case repeatOneReplay
    case stopAfterTrack

    var isUserInitiatedTrackChange: Bool {
        switch self {
        case .userNext, .userPrevious, .userJumpToTrack, .userJumpWithinQueue:
            return true
        case .naturalCompletion, .systemInterrupt, .appTermination, .repeatOneReplay, .stopAfterTrack:
            return false
        }
    }

    var allowsQuickSkip: Bool {
        switch self {
        case .userNext, .userJumpToTrack, .userJumpWithinQueue:
            return true
        case .userPrevious, .naturalCompletion, .systemInterrupt, .appTermination, .repeatOneReplay, .stopAfterTrack:
            return false
        }
    }
}

/// Represents the outcome of a playback session.
enum PlaybackSessionOutcome: Equatable {
    /// Playback completed naturally (reached end).
    case completed(reason: PlaybackSessionEndReason, progress: Double, playedSeconds: Double)

    /// User actively skipped before completion.
    case skipped(reason: PlaybackSessionEndReason, progress: Double, playedSeconds: Double, allowsQuickSkip: Bool)

    /// Playback was interrupted (device change, app quit, etc).
    case interrupted(reason: PlaybackSessionEndReason, progress: Double, playedSeconds: Double)

    /// Playback was very short (< 2 seconds), doesn't count as a play.
    case tooShort(reason: PlaybackSessionEndReason, playedSeconds: Double)
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

    /// Progress jumps above this are treated as seeks/position changes, not listening time.
    private static let maxContinuousProgressDelta: Double = 2.0

    /// Small negative jitter can happen around timing boundaries; larger backward movement is seek.
    private static let backwardJumpTolerance: Double = 0.5

    // MARK: - Session State

    private let track: Track
    private let trackDuration: Double

    private var lastProgressTime: Double = 0
    private var maxProgressReached: Double = 0
    private var hasReachedMinPlayThreshold: Bool = false
    private var endReason: PlaybackSessionEndReason = .systemInterrupt
    private var isExplicitlySeeking: Bool = false
    private var suppressNextProgressDelta: Bool = false

    /// Total accumulated played seconds.
    internal private(set) var totalPlayedSeconds: Double = 0

    /// Whether this session has crossed the minimum play threshold.
    var isValidPlay: Bool { hasReachedMinPlayThreshold }

    /// Whether the track was played to completion.
    internal private(set) var isCompleted: Bool = false

    /// Whether seek or position-jump activity occurred during this session.
    private(set) var hadSeekActivity: Bool = false

    /// Whether the track is currently playing.
    private(set) var isActive: Bool = true

    /// Whether this session's eventual finalize writeback should be discarded once.
    private var shouldDiscardStatsOnFinalize: Bool = false

    // MARK: - Initialization

    init(track: Track) {
        self.track = track
        self.trackDuration = track.duration
        self.lastProgressTime = 0
    }

    // MARK: - Progress Updates

    /// Update progress during playback.
    func updateProgress(currentTime: Double) {
        guard isActive else { return }
        guard trackDuration > 0 else { return }

        let boundedTime = max(0, min(currentTime, trackDuration))
        defer {
            lastProgressTime = boundedTime
            maxProgressReached = max(maxProgressReached, boundedTime)

            if !hasReachedMinPlayThreshold && totalPlayedSeconds >= Self.minPlayDuration {
                hasReachedMinPlayThreshold = true
            }
        }

        if isExplicitlySeeking || suppressNextProgressDelta {
            hadSeekActivity = true
            suppressNextProgressDelta = false
            return
        }

        let progressDelta = boundedTime - lastProgressTime
        let isBackwardJump = progressDelta < -Self.backwardJumpTolerance
        let isLargeForwardJump = progressDelta > Self.maxContinuousProgressDelta

        if isBackwardJump || isLargeForwardJump {
            hadSeekActivity = true
            return
        }

        if progressDelta > 0 {
            totalPlayedSeconds += progressDelta
        }
    }

    /// Mark the track as completed (natural end, repeat-one replay, stop-after-track).
    func markCompleted(reason: PlaybackSessionEndReason) {
        guard isActive else { return }
        isActive = false
        isCompleted = true
        endReason = reason
        maxProgressReached = trackDuration
    }

    /// Mark the session as ended by a specific non-completion reason.
    func markEnded(reason: PlaybackSessionEndReason) {
        guard isActive else { return }
        endReason = reason
    }

    func beginSeek() {
        guard isActive else { return }
        hadSeekActivity = true
        isExplicitlySeeking = true
    }

    func recordSeek(to currentTime: Double) {
        guard isActive else { return }
        let boundedTime = max(0, min(currentTime, trackDuration))
        hadSeekActivity = true
        isExplicitlySeeking = false
        suppressNextProgressDelta = true
        lastProgressTime = boundedTime
        maxProgressReached = max(maxProgressReached, boundedTime)
    }

    func endSeek() {
        guard isActive else { return }
        hadSeekActivity = true
        isExplicitlySeeking = false
        suppressNextProgressDelta = true
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

    func discardStatsOnFinalizeOnce() {
        shouldDiscardStatsOnFinalize = true
    }

    func consumePendingStatsDiscardFlag() -> Bool {
        let shouldDiscard = shouldDiscardStatsOnFinalize
        shouldDiscardStatsOnFinalize = false
        return shouldDiscard
    }

    // MARK: - Outcome Computation

    private func computeOutcome() -> PlaybackSessionOutcome {
        let progress = trackDuration > 0 ? maxProgressReached / trackDuration : 0

        // If too short, don't count as a play at all.
        if totalPlayedSeconds < Self.minPlayDuration {
            return .tooShort(reason: endReason, playedSeconds: totalPlayedSeconds)
        }

        // If completed naturally, it's a complete play.
        if isCompleted {
            return .completed(reason: endReason, progress: progress, playedSeconds: totalPlayedSeconds)
        }

        // Check for complete play criteria (even if user skipped).
        let remainingSeconds = trackDuration - maxProgressReached
        let metCompletePercentage = progress >= Self.completePlayPercentage
        let metCompleteRemaining = remainingSeconds <= Self.completePlayRemainingSeconds

        if metCompletePercentage || metCompleteRemaining {
            // User was very close to the end, treat as completed.
            return .completed(reason: endReason, progress: progress, playedSeconds: totalPlayedSeconds)
        }

        if endReason.isUserInitiatedTrackChange {
            return .skipped(
                reason: endReason,
                progress: progress,
                playedSeconds: totalPlayedSeconds,
                allowsQuickSkip: endReason.allowsQuickSkip && !hadSeekActivity
            )
        } else {
            return .interrupted(reason: endReason, progress: progress, playedSeconds: totalPlayedSeconds)
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
}

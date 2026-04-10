//
//  PlayCountService.swift
//  myPlayer2
//
//  DEPRECATED: This service is deprecated. Use PlaybackSessionTracker + PreferenceStatsService instead.
//

import Foundation

/// DEPRECATED: Use PlaybackSessionTracker + PreferenceStatsService for comprehensive playback statistics.
@MainActor
protocol PlayCountServiceProtocol: AnyObject {
    func startPlaybackSession(for track: Track)
    func endPlaybackSession()
    func updatePlaybackProgress(currentTime: Double, duration: Double)
}

/// DEPRECATED: Use PlaybackSessionTracker + PreferenceStatsService for comprehensive playback statistics.
/// This service now delegates to PreferenceStatsService for backward compatibility.
@MainActor
final class PlayCountService: PlayCountServiceProtocol {

    static let shared = PlayCountService()

    // MARK: - Configuration (kept for API compatibility)

    private let minPlayDuration: Double = 30.0 // seconds
    private let minPlayPercentage: Double = 0.5 // 50%

    // MARK: - Session State

    private var currentSession: PlaybackSession?
    private var hasCountedPlay: Bool = false

    private struct PlaybackSession {
        let trackID: UUID
        let track: Track
        let startTime: Date
        var totalPlayedDuration: Double = 0
        var lastProgressTime: Double = 0
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Session Management (deprecated)

    /// DEPRECATED: Use PlaybackSessionTracker instead.
    func startPlaybackSession(for track: Track) {
        // End any existing session first
        endPlaybackSession()

        // Start new session
        currentSession = PlaybackSession(
            trackID: track.id,
            track: track,
            startTime: Date(),
            totalPlayedDuration: 0,
            lastProgressTime: 0
        )
        hasCountedPlay = false

        print("🎵 Play count session started for: \(track.title)")
    }

    /// DEPRECATED: Use PlaybackSessionTracker instead.
    func endPlaybackSession() {
        guard let session = currentSession else { return }

        // If we haven't counted yet and conditions are met, count it
        if !hasCountedPlay {
            maybeCountPlay(for: session)
        }

        print("🎵 Play count session ended for: \(session.track.title)")
        currentSession = nil
        hasCountedPlay = false
    }

    /// DEPRECATED: Use PlaybackSessionTracker instead.
    func updatePlaybackProgress(currentTime: Double, duration: Double) {
        guard let session = currentSession else { return }
        guard duration > 0 else { return }

        // Calculate progress delta
        let progressDelta = currentTime - session.lastProgressTime
        if progressDelta > 0 {
            currentSession?.totalPlayedDuration += progressDelta
        }
        currentSession?.lastProgressTime = currentTime

        // Check if we should count the play
        if !hasCountedPlay {
            maybeCountPlay(for: session)
        }
    }

    // MARK: - Play Count Logic (delegates to PreferenceStatsService)

    private func maybeCountPlay(for session: PlaybackSession) {
        guard !hasCountedPlay else { return }

        let duration = session.track.duration
        guard duration > 0 else { return }

        let playedDuration = session.totalPlayedDuration
        let playedPercentage = playedDuration / duration

        // Check if conditions are met
        let metDurationThreshold = playedDuration >= minPlayDuration
        let metPercentageThreshold = playedPercentage >= minPlayPercentage

        if metDurationThreshold || metPercentageThreshold {
            countPlay(for: session.track)
            hasCountedPlay = true
            currentSession = nil // Clear session after counting
        }
    }

    private func countPlay(for track: Track) {
        // Delegate to PreferenceStatsService
        // This maintains backward compatibility while using the new stats system
        PreferenceStatsService.shared.updateStats(for: track.id) { stats in
            stats.playCount += 1
            // Also increment completePlayCount since this is a "counted" play
            stats.completePlayCount += 1
            stats.totalPlayedSeconds += track.duration * 0.5 // Estimate 50% played
            stats.lastPlayedAt = Date()
        }

        // Persist to disk
        LocalLibraryService.shared.writeSidecar(for: track)

        print("✅ Play counted for '\(track.title)' via legacy PlayCountService (delegated to PreferenceStatsService)")
    }
}

// MARK: - Stub for Previews

@MainActor
final class StubPlayCountService: PlayCountServiceProtocol {
    func startPlaybackSession(for track: Track) {}
    func endPlaybackSession() {}
    func updatePlaybackProgress(currentTime: Double, duration: Double) {}
}

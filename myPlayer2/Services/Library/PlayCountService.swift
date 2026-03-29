//
//  PlayCountService.swift
//  myPlayer2
//
//  kmgccc_player - Play Count Service
//  Manages play counting logic with session tracking.
//

import Foundation

/// Protocol for play count service
@MainActor
protocol PlayCountServiceProtocol: AnyObject {
    func startPlaybackSession(for track: Track)
    func endPlaybackSession()
    func updatePlaybackProgress(currentTime: Double, duration: Double)
}

/// Service responsible for tracking play counts with session-based logic.
/// A play is counted when:
/// - User listens to >= 50% of the track duration, OR
/// - User listens for >= 30 seconds (whichever comes first)
/// Each playback session counts only once.
@MainActor
final class PlayCountService: PlayCountServiceProtocol {

    static let shared = PlayCountService()

    // MARK: - Configuration

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

    // MARK: - Session Management

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

    // MARK: - Play Count Logic

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
        // Increment play count
        track.playCount += 1

        // Persist to disk
        LocalLibraryService.shared.writeSidecar(for: track)

        print("✅ Play counted for '\(track.title)' (total: \(track.playCount))")
    }
}

// MARK: - Stub for Previews

@MainActor
final class StubPlayCountService: PlayCountServiceProtocol {
    func startPlaybackSession(for track: Track) {}
    func endPlaybackSession() {}
    func updatePlaybackProgress(currentTime: Double, duration: Double) {}
}

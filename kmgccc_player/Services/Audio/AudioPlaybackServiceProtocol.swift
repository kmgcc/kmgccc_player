//
//  AudioPlaybackServiceProtocol.swift
//  myPlayer2
//
//  kmgccc_player - Audio Playback Service Protocol
//  Defines playback control interface for AVAudioEngine implementation.
//

import Foundation

/// Protocol for audio playback control.
/// Implemented by AVAudioPlaybackService (real) and StubAudioPlaybackService (preview).
@MainActor
protocol AudioPlaybackServiceProtocol: AnyObject {

    /// Whether audio is currently playing.
    var isPlaying: Bool { get }

    /// Playback volume (0.0 to 1.0).
    var volume: Double { get set }

    /// Current playback position in seconds.
    var currentTime: Double { get }

    /// Realized audio output delay in seconds. This is non-zero only when the
    /// playback graph delays audible output; internal analysis remains pre-delay.
    var audioOutputDelay: Double { get }

    /// Total duration of current track in seconds.
    var duration: Double { get }

    /// Currently playing track (nil if nothing playing).
    var currentTrack: Track? { get }

    /// Effective playback order mode for the active local playback session.
    var currentPlaybackOrderMode: PlaybackOrderMode { get }

    // MARK: - Playback Control

    /// Play a specific track.
    func play(track: Track)

    /// Play multiple tracks starting at an index.
    func playTracks(_ tracks: [Track], startingAt index: Int, startPolicy: PlaybackStartPolicy)

    /// Restore a saved session into a paused state: rebuilds the queue and loads
    /// the current track at `positionSeconds` without auto-playing. Used to
    /// restore playback memory at launch. Ends paused; never starts audio.
    func restorePausedPlayback(_ tracks: [Track], startingAt index: Int, positionSeconds: Double)

    /// Update current playable track set (playlist/filter/import/delete changes).
    func updateQueueTracks(_ tracks: [Track])

    /// Insert tracks into the current queue after the active play-next block.
    /// Returns the number of tracks accepted into the queue.
    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int

    /// Replace queue/current-track metadata for already-known track IDs without rebuilding playback state.
    func refreshTracks(_ tracks: [Track])

    /// Return the current queue in the active playback order.
    func currentQueueTracks() -> [Track]

    /// Return the current track index in the displayed queue order.
    func currentQueueDisplayIndex() -> Int?

    /// Jump to a specific track within the current queue without rebuilding it.
    func playTrackFromQueue(_ track: Track)

    /// Immediately sync shuffle behavior for the active playback session.
    func setShuffleEnabled(_ enabled: Bool)

    /// Discard the currently active playback session's pending stats writeback once.
    /// Only affects the session that is already in progress when this is called.
    func discardCurrentPlaybackSessionStatsOnce()

    /// Pause playback.
    func pause()

    /// Resume playback.
    func resume()

    /// Stop playback completely.
    func stop()

    /// Skip to the next track.
    func next()

    /// Go back to the previous track.
    func previous()

    /// Seek to a specific time position.
    func seek(to seconds: Double)
}

// MARK: - Convenience Extension

extension AudioPlaybackServiceProtocol {

    /// Toggle between play and pause.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }
}

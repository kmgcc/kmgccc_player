//
//  AudioPlaybackServiceProtocol.swift
//  myPlayer2
//
//  TrueMusic - Audio Playback Service Protocol
//  Defines playback control interface for AVAudioEngine implementation.
//

import Foundation

/// Protocol for audio playback control.
/// Implemented by AVAudioPlaybackService (real) and StubAudioPlaybackService (preview).
@MainActor
protocol AudioPlaybackServiceProtocol: AnyObject {

    // MARK: - State

    /// Whether audio is currently playing.
    var isPlaying: Bool { get }

    /// Playback volume (0.0 to 1.0).
    var volume: Double { get set }

    /// Current playback position in seconds.
    var currentTime: Double { get }

    /// Total duration of current track in seconds.
    var duration: Double { get }

    /// Currently playing track (nil if nothing playing).
    var currentTrack: Track? { get }

    // MARK: - Playback Control

    /// Play a specific track.
    func play(track: Track)

    /// Play multiple tracks starting at an index.
    func playTracks(_ tracks: [Track], startingAt index: Int)

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

//
//  PlayerViewModel.swift
//  myPlayer2
//
//  TrueMusic - Player ViewModel
//  Manages playback state and controls.
//

import Foundation

/// Observable ViewModel for playback control.
/// Bridges UI with audio playback and level meter services.
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - Dependencies

    private let playbackService: AudioPlaybackServiceProtocol
    private let levelMeter: AudioLevelMeterProtocol
    private let settings: AppSettings

    // MARK: - Computed Properties (from playbackService)

    var isPlaying: Bool {
        playbackService.isPlaying
    }

    var currentTime: Double {
        playbackService.currentTime
    }

    var duration: Double {
        playbackService.duration
    }

    var currentTrack: Track? {
        playbackService.currentTrack
    }

    var volume: Double {
        get { playbackService.volume }
        set {
            playbackService.volume = newValue
            // Volume is persisted by playbackService
        }
    }

    /// Normalized audio level for LED visualization (0.0 to 1.0)
    var level: Float {
        levelMeter.normalizedLevel
    }

    // MARK: - Initialization

    init(
        playbackService: AudioPlaybackServiceProtocol,
        levelMeter: AudioLevelMeterProtocol,
        settings: AppSettings = .shared
    ) {
        self.playbackService = playbackService
        self.levelMeter = levelMeter
        self.settings = settings
    }

    // MARK: - Queue Management

    /// Play tracks starting at a specific index.
    func playTracks(_ tracks: [Track], startingAt index: Int = 0) {
        playbackService.playTracks(tracks, startingAt: index)
        levelMeter.start()
    }

    // MARK: - Playback Control

    func play(track: Track) {
        playbackService.play(track: track)
        levelMeter.start()
    }

    func pause() {
        playbackService.pause()
        // Keep level meter running but it will show low levels
    }

    func resume() {
        playbackService.resume()
        levelMeter.start()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        playbackService.stop()
        levelMeter.stop()
    }

    func next() {
        playbackService.next()
    }

    func previous() {
        playbackService.previous()
    }

    func seek(to seconds: Double) {
        playbackService.seek(to: seconds)
    }

    func setVolume(_ newVolume: Double) {
        volume = newVolume
    }

    // MARK: - Cleanup

    func stopLevelMeter() {
        levelMeter.stop()
    }
}

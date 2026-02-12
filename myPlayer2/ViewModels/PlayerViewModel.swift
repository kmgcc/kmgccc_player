//
//  PlayerViewModel.swift
//  myPlayer2
//
//  TrueMusic - Player ViewModel
//  Manages playback state and controls.
//

import Foundation
import MediaPlayer

/// Observable ViewModel for playback control.
/// Bridges UI with audio playback and level meter services.
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - Dependencies

    private let playbackService: AudioPlaybackServiceProtocol
    private let levelMeter: AudioLevelMeterProtocol
    private let settings: AppSettings
    private let nowPlayingService: NowPlayingService

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
        settings: AppSettings? = nil,
        nowPlayingService: NowPlayingService? = nil
    ) {
        self.playbackService = playbackService
        self.levelMeter = levelMeter
        self.settings = settings ?? AppSettings.shared
        self.nowPlayingService = nowPlayingService ?? .shared
        self.nowPlayingService.register(player: self)
        self.nowPlayingService.updateNowPlaying(force: true)
    }

    // MARK: - Queue Management

    /// Play tracks starting at a specific index.
    func playTracks(_ tracks: [Track], startingAt index: Int = 0) {
        playbackService.playTracks(tracks, startingAt: index)
        levelMeter.start()
        nowPlayingService.updateNowPlaying(force: true)
    }

    func updateQueueTracks(_ tracks: [Track]) {
        playbackService.updateQueueTracks(tracks)
        nowPlayingService.updateNowPlaying(force: true)
    }

    // MARK: - Playback Control

    func play(track: Track) {
        playbackService.play(track: track)
        levelMeter.start()
        nowPlayingService.updateNowPlaying(force: true)
    }

    func pause() {
        playbackService.pause()
        // Keep level meter running but it will show low levels
        nowPlayingService.updateNowPlaying(force: true)
    }

    func resume() {
        playbackService.resume()
        levelMeter.start()
        nowPlayingService.updateNowPlaying(force: true)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
        nowPlayingService.updateNowPlaying(force: true)
    }

    func stop() {
        playbackService.stop()
        levelMeter.stop()
        nowPlayingService.updateNowPlaying(force: true)
    }

    func next() {
        playbackService.next()
        nowPlayingService.updateNowPlaying(force: true)
    }

    func previous() {
        playbackService.previous()
        nowPlayingService.updateNowPlaying(force: true)
    }

    func seek(to seconds: Double) {
        playbackService.seek(to: seconds)
        nowPlayingService.updateNowPlaying(force: true)
    }

    func setVolume(_ newVolume: Double) {
        volume = newVolume
    }

    // MARK: - Cleanup

    func stopLevelMeter() {
        levelMeter.stop()
    }
}

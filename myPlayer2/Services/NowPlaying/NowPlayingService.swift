//
//  NowPlayingService.swift
//  myPlayer2
//
//  TrueMusic - Media keys + Control Center Now Playing
//

import AppKit
import MediaPlayer

@MainActor
final class NowPlayingService {

    static let shared = NowPlayingService()

    private weak var player: PlayerViewModel?
    private var progressTimer: Timer?
    private var isRegistered = false
    private var lastUpdateTime: TimeInterval = 0
    private let progressInterval: TimeInterval = 0.5

    private init() {}

    func register(player: PlayerViewModel) {
        self.player = player
        registerRemoteCommandsIfNeeded()
        updateNowPlaying(force: true)
        startProgressTimer()
    }

    func updateNowPlaying(force: Bool = false) {
        guard let player else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastUpdateTime < progressInterval {
            return
        }
        lastUpdateTime = now

        guard let track = player.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(macOS 12.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
            return
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        if !track.album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = track.album
        }
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0

        if let data = track.artworkData, let image = NSImage(data: data) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        }
    }

    // MARK: - Remote Commands

    private func registerRemoteCommandsIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { @MainActor in
                player.resume()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { @MainActor in
                player.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { @MainActor in
                player.togglePlayPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { @MainActor in
                player.next()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            Task { @MainActor in
                player.previous()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let player = self?.player else { return .commandFailed }
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                player.seek(to: positionEvent.positionTime)
            }
            return .success
        }
    }

    // MARK: - Progress Updates

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(
            timeInterval: progressInterval,
            target: self,
            selector: #selector(handleProgressTimer),
            userInfo: nil,
            repeats: true
        )
        if let timer = progressTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    @objc private func handleProgressTimer() {
        updateNowPlaying(force: false)
    }
}

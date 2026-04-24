//
//  NowPlayingService.swift
//  myPlayer2
//
//  kmgccc_player - Media keys + Control Center Now Playing
//

import AppKit
import MediaPlayer

@MainActor
final class NowPlayingService {

    static let shared = NowPlayingService()

    private weak var player: PlayerViewModel?
    private weak var coordinator: PlaybackCoordinator?
    private var progressTimer: Timer?
    private var isRegistered = false
    private var lastUpdateTime: TimeInterval = 0
    private let progressInterval: TimeInterval = 0.5
    private var cachedArtworkKey: String?
    private var cachedArtwork: MPMediaItemArtwork?
    private static let artworkSignatureSampleBytes = 12

    private init() {}

    func register(player: PlayerViewModel) {
        self.player = player
        registerRemoteCommandsIfNeeded()
        updateNowPlaying(force: true)
        startProgressTimer()
    }

    func register(coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
        registerRemoteCommandsIfNeeded()
        updateNowPlaying(force: true)
        startProgressTimer()
    }

    func updateNowPlaying(force: Bool = false) {
        guard coordinator != nil || player != nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastUpdateTime < progressInterval {
            return
        }
        lastUpdateTime = now

        if let coordinator {
            updateNowPlaying(from: coordinator.presentation)
            return
        }

        guard let player, let track = player.currentTrack else {
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

        if let artwork = mediaArtwork(for: track) {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
        }
    }

    private func updateNowPlaying(from presentation: NowPlayingPresentation) {
        guard presentation.hasTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(macOS 12.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
            return
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = presentation.title
        info[MPMediaItemPropertyArtist] = presentation.artist
        if let album = presentation.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        } else {
            info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        info[MPMediaItemPropertyPlaybackDuration] = presentation.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = presentation.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = presentation.isPlaying ? 1.0 : 0.0

        if let artwork = mediaArtwork(for: presentation) {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(macOS 12.0, *) {
            MPNowPlayingInfoCenter.default().playbackState =
                presentation.isPlaying ? .playing : .paused
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
            guard let self, self.coordinator != nil || self.player != nil else {
                return .commandFailed
            }
            Task { @MainActor in
                if let coordinator = self.coordinator {
                    coordinator.resume()
                } else {
                    self.player?.resume()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.coordinator != nil || self.player != nil else {
                return .commandFailed
            }
            Task { @MainActor in
                if let coordinator = self.coordinator {
                    coordinator.pause()
                } else {
                    self.player?.pause()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.coordinator != nil || self.player != nil else {
                return .commandFailed
            }
            Task { @MainActor in
                if let coordinator = self.coordinator {
                    coordinator.playPause()
                } else {
                    self.player?.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.coordinator != nil || self.player != nil else {
                return .commandFailed
            }
            Task { @MainActor in
                if let coordinator = self.coordinator {
                    coordinator.next()
                } else {
                    self.player?.next()
                }
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.coordinator != nil || self.player != nil else {
                return .commandFailed
            }
            Task { @MainActor in
                if let coordinator = self.coordinator {
                    coordinator.previous()
                } else {
                    self.player?.previous()
                }
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.coordinator != nil || self.player != nil else {
                return .commandFailed
            }
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                if let coordinator = self.coordinator {
                    coordinator.seek(to: positionEvent.positionTime)
                } else {
                    self.player?.seek(to: positionEvent.positionTime)
                }
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
    
    private func mediaArtwork(for track: Track) -> MPMediaItemArtwork? {
        let cacheKey = "track-\(track.id.uuidString)-\(artworkSignature(for: track.artworkData))"
        
        if cachedArtworkKey == cacheKey {
            return cachedArtwork
        }
        
        cachedArtworkKey = cacheKey
        cachedArtwork = nil
        
        guard let data = track.artworkData, !data.isEmpty, let image = NSImage(data: data) else {
            return nil
        }
        
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = artwork
        return artwork
    }

    private func mediaArtwork(for presentation: NowPlayingPresentation) -> MPMediaItemArtwork? {
        let identity = presentation.artworkIdentity
            ?? presentation.lyricsIdentity
            ?? presentation.localTrack?.id.uuidString
            ?? presentation.title
        let cacheKey =
            "\(presentation.source.rawValue)-\(identity)-\(artworkSignature(for: presentation.artworkData))"

        if cachedArtworkKey == cacheKey {
            return cachedArtwork
        }

        cachedArtworkKey = cacheKey
        cachedArtwork = nil

        guard
            let data = presentation.artworkData,
            !data.isEmpty,
            let image = NSImage(data: data)
        else {
            return nil
        }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = artwork
        return artwork
    }

    private func artworkSignature(for data: Data?) -> String {
        guard let data, !data.isEmpty else { return "none" }

        let sampleSize = min(Self.artworkSignatureSampleBytes, data.count)
        let prefix = sampleHex(data.prefix(sampleSize))
        let suffix = sampleHex(data.suffix(sampleSize))
        return "\(data.count)-\(prefix)-\(suffix)"
    }

    private func sampleHex(_ bytes: Data.SubSequence) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

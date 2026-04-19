//
//  PlaybackCoordinator.swift
//  myPlayer2
//
//  Source-aware playback command and presentation coordinator.
//

import Foundation
import Observation

@Observable
@MainActor
final class PlaybackCoordinator {
    private let playerVM: PlayerViewModel
    private let settings: AppSettings
    private var presentationTimer: Timer?

    private(set) var activeSource: PlaybackSource = .local
    private(set) var presentation: NowPlayingPresentation = .emptyLocal

    init(playerVM: PlayerViewModel, settings: AppSettings? = nil) {
        self.playerVM = playerVM
        self.settings = settings ?? AppSettings.shared
        refreshPresentation()
        startPresentationTimer()
    }

    func playPause() {
        switch activeSource {
        case .local:
            playerVM.togglePlayPause()
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func pause() {
        switch activeSource {
        case .local:
            playerVM.pause()
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func resume() {
        switch activeSource {
        case .local:
            playerVM.resume()
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func stop() {
        switch activeSource {
        case .local:
            playerVM.stop()
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func next() {
        switch activeSource {
        case .local:
            playerVM.next()
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func previous() {
        switch activeSource {
        case .local:
            playerVM.previous()
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func seek(to seconds: Double) {
        switch activeSource {
        case .local:
            playerVM.seek(to: seconds)
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func setVolume(_ volume: Double) {
        switch activeSource {
        case .local:
            playerVM.setVolume(volume)
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func setPlaybackOrderMode(_ mode: PlaybackOrderMode, announceChange: Bool = true) {
        switch activeSource {
        case .local:
            playerVM.setPlaybackOrderMode(mode, announceChange: announceChange)
        case .appleMusic:
            break
        }
        refreshPresentation()
    }

    func refreshPresentation() {
        switch activeSource {
        case .local:
            presentation = makeLocalPresentation()
        case .appleMusic:
            presentation = .emptyLocal
        }
    }

    private func startPresentationTimer() {
        presentationTimer?.invalidate()
        presentationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPresentation()
            }
        }
        if let presentationTimer {
            RunLoop.main.add(presentationTimer, forMode: .common)
        }
    }

    private func makeLocalPresentation() -> NowPlayingPresentation {
        guard let track = playerVM.currentTrack else {
            var empty = NowPlayingPresentation.emptyLocal
            empty.volume = playerVM.volume
            return empty
        }

        let lyricsText = preferredLyricsText(for: track)
        return NowPlayingPresentation(
            source: .local,
            localTrack: track,
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            artworkData: track.artworkData,
            duration: playerVM.duration,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            volume: playerVM.volume,
            lyricsText: lyricsText,
            lyricsIdentity: track.id.uuidString,
            isControlEnabled: true,
            isSeekEnabled: playerVM.duration > 0,
            emptyTitleKey: "mini.not_playing"
        )
    }

    private func preferredLyricsText(for track: Track) -> String? {
        let candidates = [track.lyricsText, track.ttmlLyricText]
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return candidate
            }
        }
        return nil
    }
}

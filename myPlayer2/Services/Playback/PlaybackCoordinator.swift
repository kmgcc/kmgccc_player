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
    private enum Keys {
        static let activeSource = "playback.activeSource"
    }

    private let playerVM: PlayerViewModel
    private let appleMusicAdapter: AppleMusicPlaybackAdapter
    private let systemNowPlayingProvider: SystemNowPlayingProvider
    private let settings: AppSettings
    private let meterProvider: AudioLevelMeterProtocol?
    private var presentationTimer: Timer?
    private var cachedLyricsTrackID: UUID?
    private var cachedLyricsText: String?
    private var lastSyncedPlayingState: Bool?

    private(set) var activeSource: PlaybackSource
    private(set) var presentation: NowPlayingPresentation = .emptyLocal

    var onActiveSourceChanged: ((PlaybackSource) -> Void)?

    init(
        playerVM: PlayerViewModel,
        appleMusicAdapter: AppleMusicPlaybackAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider,
        settings: AppSettings? = nil,
        meterProvider: AudioLevelMeterProtocol? = nil
    ) {
        self.playerVM = playerVM
        self.appleMusicAdapter = appleMusicAdapter
        self.systemNowPlayingProvider = systemNowPlayingProvider
        self.settings = settings ?? AppSettings.shared
        self.meterProvider = meterProvider
        self.activeSource = PlaybackSource(
            rawValue: UserDefaults.standard.string(forKey: Keys.activeSource) ?? ""
        ) ?? .local
        if activeSource.isExternal {
            externalProvider(for: activeSource)?.start()
            ExternalPlaybackSpectrumSimulator.shared.start()
        }
        refreshPresentation()
        startPresentationTimer()
        NowPlayingService.shared.register(coordinator: self)
    }

    func setActiveSource(_ source: PlaybackSource) {
        guard activeSource != source else {
            if source.isExternal {
                externalProvider(for: source)?.start()
            }
            refreshPresentation()
            NowPlayingService.shared.updateNowPlaying(force: true)
            return
        }

        Log.info(
            "[PlaybackCoordinator] source switch \(activeSource.rawValue) -> \(source.rawValue)",
            category: .playback
        )

        let previousSource = activeSource
        if previousSource.isExternal, previousSource != source {
            externalProvider(for: previousSource)?.pause()
            externalProvider(for: previousSource)?.stop()
        }

        switch source {
        case .local:
            stopExternalProviders()
            ExternalPlaybackSpectrumSimulator.shared.stop()
        case .appleMusic, .systemNowPlaying:
            if playerVM.isPlaying {
                playerVM.pause()
            }
            externalProvider(for: source)?.start()
            ExternalPlaybackSpectrumSimulator.shared.start()
        }

        activeSource = source
        lastSyncedPlayingState = nil
        UserDefaults.standard.set(source.rawValue, forKey: Keys.activeSource)
        onActiveSourceChanged?(source)
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func playPause() {
        switch activeSource {
        case .local:
            playerVM.togglePlayPause()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.playPause()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func pause() {
        switch activeSource {
        case .local:
            playerVM.pause()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.pause()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func resume() {
        switch activeSource {
        case .local:
            playerVM.resume()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.play()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func stop() {
        switch activeSource {
        case .local:
            playerVM.stop()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.pause()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func next() {
        switch activeSource {
        case .local:
            playerVM.next()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.next()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func previous() {
        switch activeSource {
        case .local:
            playerVM.previous()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.previous()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func seek(to seconds: Double) {
        switch activeSource {
        case .local:
            playerVM.seek(to: seconds)
        case .appleMusic:
            appleMusicAdapter.seek(to: seconds)
        case .systemNowPlaying:
            guard systemNowPlayingProvider.capabilities.canSeek,
                  systemNowPlayingProvider.presentation.isSeekEnabled else {
                Log.debug("[PlaybackCoordinator] system now playing seek ignored; capability disabled", category: .playback)
                return
            }
            systemNowPlayingProvider.seek(to: seconds)
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func setVolume(_ volume: Double) {
        switch activeSource {
        case .local:
            playerVM.setVolume(volume)
        case .appleMusic:
            appleMusicAdapter.setVolume(volume)
        case .systemNowPlaying:
            guard systemNowPlayingProvider.capabilities.canSetVolume else { return }
            systemNowPlayingProvider.setVolume(volume)
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func setPlaybackOrderMode(_ mode: PlaybackOrderMode, announceChange: Bool = true) {
        switch activeSource {
        case .local:
            playerVM.setPlaybackOrderMode(mode, announceChange: announceChange)
        case .appleMusic:
            appleMusicAdapter.setPlaybackOrderMode(mode)
        case .systemNowPlaying:
            guard systemNowPlayingProvider.capabilities.canSetPlaybackMode else { return }
            systemNowPlayingProvider.setPlaybackOrderMode(mode)
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func setAppleMusicPlaybackMode(_ mode: AppleMusicPlaybackMode) {
        guard activeSource.isExternal else { return }
        switch activeSource {
        case .local:
            return
        case .appleMusic:
            appleMusicAdapter.setAppleMusicPlaybackMode(mode)
        case .systemNowPlaying:
            guard systemNowPlayingProvider.capabilities.canSetPlaybackMode else { return }
            systemNowPlayingProvider.setAppleMusicPlaybackMode(mode)
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func invalidateExternalPlaybackResolution() {
        guard activeSource.isExternal else { return }
        Log.info(
            "[ExternalPlayback] override saved; invalidating current resolution source=\(activeSource.rawValue) identity=\(presentation.externalStableKey ?? "nil")",
            category: .playback
        )
        activeExternalProvider?.invalidateCurrentResolution()
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func clearExternalPlaybackRuntimeCaches() {
        guard activeSource.isExternal else { return }
        activeExternalProvider?.clearRuntimeResolutionCaches()
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    // MARK: - Local Track Playback (auto-switches source)

    func playTracks(_ tracks: [Track], startingAt index: Int = 0, libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil) {
        if activeSource != .local {
            setActiveSource(.local)
        }
        playerVM.playTracks(tracks, startingAt: index, libraryQueueSource: libraryQueueSource)
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func play(track: Track) {
        if activeSource != .local {
            setActiveSource(.local)
        }
        playerVM.play(track: track)
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func playTrackFromQueue(_ track: Track) {
        if activeSource != .local {
            setActiveSource(.local)
        }
        playerVM.playTrackFromQueue(track)
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func refreshPresentation() {
        let newPresentation: NowPlayingPresentation
        switch activeSource {
        case .local:
            newPresentation = makeLocalPresentation()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.tickPresentation()
            newPresentation = activeExternalProvider?.presentation
                ?? NowPlayingPresentation.emptySystemNowPlaying
        }

        if activeSource.isExternal {
            let isPlaying = newPresentation.isPlaying
            ExternalPlaybackSpectrumSimulator.shared.setPlaying(isPlaying)
            if lastSyncedPlayingState != isPlaying {
                lastSyncedPlayingState = isPlaying
                meterProvider?.updatePlaybackState(isPlaying: isPlaying)
            }
        }

        guard !newPresentation.isEffectivelyEqual(to: presentation) else { return }
        presentation = newPresentation
    }

    private var activeExternalProvider: (any ExternalPlaybackProvider)? {
        externalProvider(for: activeSource)
    }

    private func externalProvider(for source: PlaybackSource) -> (any ExternalPlaybackProvider)? {
        switch source {
        case .local:
            return nil
        case .appleMusic:
            return appleMusicAdapter
        case .systemNowPlaying:
            return systemNowPlayingProvider
        }
    }

    private func stopExternalProviders(except retainedSource: PlaybackSource? = nil) {
        for source in PlaybackSource.allCases where source.isExternal && source != retainedSource {
            externalProvider(for: source)?.stop()
        }
    }

    private func startPresentationTimer() {
        presentationTimer?.invalidate()
        presentationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
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
        let artworkData = track.loadArtworkDataIfNeeded()
        return NowPlayingPresentation(
            source: .local,
            localTrack: track,
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            artworkData: artworkData,
            artworkIdentity: "\(track.id.uuidString):\(ArtworkAssetStore.checksum(for: artworkData))",
            artworkDisplayTrackID: track.id,
            isArtworkLoading: false,
            duration: playerVM.duration,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            volume: playerVM.volume,
            lyricsText: lyricsText,
            lyricsIdentity: track.id.uuidString,
            appleMusicPlaybackMode: nil,
            externalStableKey: nil,
            externalRawTitle: nil,
            externalRawArtist: nil,
            externalRawAlbum: nil,
            externalEffectiveTitle: nil,
            externalEffectiveArtist: nil,
            externalEffectiveAlbum: nil,
            externalUsesOverride: false,
            externalMatchConfidence: nil,
            externalLyricsStatusMessage: nil,
            externalConnectionState: nil,
            isControlEnabled: true,
            isSeekEnabled: playerVM.duration > 0,
            isVolumeControlEnabled: true,
            isPlaybackModeControlEnabled: true,
            emptyTitleKey: "mini.not_playing"
        )
    }

    private func preferredLyricsText(for track: Track) -> String? {
        if cachedLyricsTrackID == track.id {
            return cachedLyricsText
        }
        let plain = track.loadLyricsIfNeeded()
        let ttml = track.loadTTMLLyricsIfNeeded()
        let candidates = [plain, ttml]
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                cachedLyricsTrackID = track.id
                cachedLyricsText = candidate
                return candidate
            }
        }
        cachedLyricsTrackID = track.id
        cachedLyricsText = nil
        return nil
    }
}

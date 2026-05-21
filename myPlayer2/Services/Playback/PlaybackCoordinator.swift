//
//  PlaybackCoordinator.swift
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
    private var lastTelemetrySource: PlaybackSource?
    private var lastTelemetryIsPlaying: Bool?
    private var sidecarHydrationTask: Task<Void, Never>?
    private var sidecarHydratingTrackID: UUID?

    private(set) var activeSource: PlaybackSource
    private(set) var presentation: NowPlayingPresentation = .emptyLocal

    var onActiveSourceChanged: ((PlaybackSource) -> Void)?
    var onTelemetryPlaybackStateChanged: ((PlaybackSource, Bool) -> Void)?

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
        notifyTelemetryIfNeeded(source: source, isPlaying: isPlayingForTelemetry(source))
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

    func playTracks(
        _ tracks: [Track],
        startingAt index: Int = 0,
        libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil,
        playbackOrderMode: PlaybackOrderMode? = nil
    ) {
        if activeSource != .local {
            setActiveSource(.local)
        }
        if let playbackOrderMode {
            playerVM.setPlaybackOrderMode(playbackOrderMode, announceChange: true)
        }
        playerVM.playTracks(tracks, startingAt: index, libraryQueueSource: libraryQueueSource)
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func playRandomTracks(_ tracks: [Track], libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil) {
        let queue = Self.availableUniqueTracks(from: tracks)
        guard !queue.isEmpty else { return }
        let startTrack = Self.smartRandomPick(from: queue) ?? queue[0]
        let startIndex = queue.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        playTracks(
            queue,
            startingAt: startIndex,
            libraryQueueSource: libraryQueueSource,
            playbackOrderMode: .shuffle
        )
    }

    func playTrack(
        _ track: Track,
        inRandomQueueFrom tracks: [Track],
        libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil
    ) {
        let queue = Self.availableUniqueTracks(from: tracks)
        guard !queue.isEmpty else { return }
        let startIndex = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        playTracks(
            queue,
            startingAt: startIndex,
            libraryQueueSource: libraryQueueSource,
            playbackOrderMode: .shuffle
        )
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

        notifyTelemetryIfNeeded(source: activeSource, isPlaying: newPresentation.isPlaying)

        guard !newPresentation.isEffectivelyEqual(to: presentation) else { return }
        presentation = newPresentation
    }

    private var activeExternalProvider: (any ExternalPlaybackProvider)? {
        externalProvider(for: activeSource)
    }

    @available(*, deprecated, message: "Use smartRandomPick for single picks or playRandomTracks for ShuffleSession-backed playback.")
    static func smartRandomQueue(from tracks: [Track], startingWith startTrack: Track? = nil) -> [Track] {
        if let startTrack,
           let matched = availableUniqueTracks(from: tracks).first(where: { $0.id == startTrack.id }) {
            return [matched]
        }
        return smartRandomPick(from: tracks).map { [$0] } ?? []
    }

    static func smartRandomPick(from tracks: [Track]) -> Track? {
        let uniqueTracks = availableUniqueTracks(from: tracks)
        guard !uniqueTracks.isEmpty else { return nil }

        let trackByID = Dictionary(uniqueKeysWithValues: uniqueTracks.map { ($0.id, $0) })
        let weights = Dictionary(uniqueKeysWithValues: uniqueTracks.map { track in
            let stats = PreferenceStatsService.shared.getStats(for: track.id)
            let score = PreferenceScorerV2.calculateScore(
                stats: stats,
                duration: track.duration,
                manualLikeState: stats.manualLikeState
            )
            return (track.id, score.baseWeight)
        })

        return weightedSample(
            from: uniqueTracks,
            weights: weights,
            recentHistory: [],
            trackByID: trackByID
        )
    }

    private static func availableUniqueTracks(from tracks: [Track]) -> [Track] {
        var seenIDs = Set<UUID>()
        return tracks.filter { track in
            guard !seenIDs.contains(track.id) else { return false }
            seenIDs.insert(track.id)
            return track.availability != .missing
        }
    }

    private static func weightedSample(
        from tracks: [Track],
        weights: [UUID: Double],
        recentHistory: [UUID],
        trackByID: [UUID: Track]
    ) -> Track? {
        let adjustedWeights = Dictionary(uniqueKeysWithValues: tracks.map { track in
            let baseWeight = weights[track.id] ?? 1
            let runtimeWeight = PreferenceScorerV2.applyRuntimePenalties(
                baseWeight: baseWeight,
                track: track,
                recentHistory: recentHistory,
                tracks: trackByID
            )
            return (track.id, runtimeWeight)
        })

        guard let selectedID = WeightedRandomSampler.sample(
            from: tracks.map(\.id),
            weights: adjustedWeights
        ) else { return nil }

        return trackByID[selectedID]
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

    private func notifyTelemetryIfNeeded(source: PlaybackSource, isPlaying: Bool) {
        guard lastTelemetrySource != source || lastTelemetryIsPlaying != isPlaying else { return }
        lastTelemetrySource = source
        lastTelemetryIsPlaying = isPlaying
        onTelemetryPlaybackStateChanged?(source, isPlaying)
    }

    private func isPlayingForTelemetry(_ source: PlaybackSource) -> Bool {
        switch source {
        case .local:
            return playerVM.isPlaying
        case .appleMusic, .systemNowPlaying:
            return externalProvider(for: source)?.presentation.isPlaying ?? false
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

        let lyricsText = preferredLyricsTextSnapshot(for: track)
        let artworkData = track.artworkData
        scheduleSidecarHydrationIfNeeded(for: track)
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

    private func preferredLyricsTextSnapshot(for track: Track) -> String? {
        if cachedLyricsTrackID == track.id {
            return cachedLyricsText
        }
        let plain = track.lyricsText
        let ttml = track.ttmlLyricText
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

    private func scheduleSidecarHydrationIfNeeded(for track: Track) {
        let needsArtwork = track.artworkData?.isEmpty != false && track.resolvedArtworkURL() != nil
        let needsPlainLyrics = track.lyricsText?.isEmpty != false && track.resolvedLyricsURL() != nil
        let needsTTMLLyrics = track.ttmlLyricText?.isEmpty != false
            && (track.resolvedTTMLURL() != nil || track.resolvedLyricsURL() != nil)
        guard needsArtwork || needsPlainLyrics || needsTTMLLyrics else { return }
        guard sidecarHydratingTrackID != track.id else { return }

        let trackID = track.id
        let artworkURL = needsArtwork ? track.resolvedArtworkURL() : nil
        let lyricsURL = needsPlainLyrics ? track.resolvedLyricsURL() : nil
        let ttmlURL = needsTTMLLyrics ? track.resolvedTTMLURL() : nil
        let ttmlFallbackURL = needsTTMLLyrics ? track.resolvedLyricsURL() : nil

        sidecarHydrationTask?.cancel()
        sidecarHydratingTrackID = trackID
        sidecarHydrationTask = Task(priority: .utility) { @MainActor [weak self, weak track] in
            let token = FirstUseHitchDiagnostics.begin(
                "PlaybackCoordinator.sidecarHydration",
                detail: "track=\(trackID.uuidString.prefix(8)) artwork=\(artworkURL != nil) lyrics=\(lyricsURL != nil) ttml=\(ttmlURL != nil || ttmlFallbackURL != nil)"
            )

            async let artworkTask: Data? = Task.detached(priority: .utility) { @Sendable in
                guard let artworkURL else { return nil }
                return try? Data(contentsOf: artworkURL)
            }.value

            async let lyricsTask: String? = Task.detached(priority: .utility) { @Sendable in
                guard let lyricsURL else { return nil }
                return try? String(contentsOf: lyricsURL, encoding: .utf8)
            }.value

            async let ttmlTask: String? = Task.detached(priority: .utility) { @Sendable in
                if let ttmlURL,
                   let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
                   !text.isEmpty {
                    return text
                }
                if let ttmlFallbackURL,
                   ttmlFallbackURL.lastPathComponent.lowercased().hasSuffix(".ttml"),
                   let text = try? String(contentsOf: ttmlFallbackURL, encoding: .utf8),
                   !text.isEmpty {
                    return text
                }
                return nil
            }.value

            let artwork = await artworkTask
            let lyrics = await lyricsTask
            let ttml = await ttmlTask

            defer {
                FirstUseHitchDiagnostics.end(
                    token,
                    detail: "artworkBytes=\(artwork?.count ?? 0) lyricsChars=\(lyrics?.count ?? 0) ttmlChars=\(ttml?.count ?? 0)"
                )
                if self?.sidecarHydratingTrackID == trackID {
                    self?.sidecarHydratingTrackID = nil
                }
            }

            guard !Task.isCancelled, let self, let track, track.id == trackID else { return }
            if let artwork, track.artworkData?.isEmpty != false {
                track.artworkData = artwork
            }
            if let lyrics, track.lyricsText?.isEmpty != false {
                track.lyricsText = lyrics
            }
            if let ttml, track.ttmlLyricText?.isEmpty != false {
                track.ttmlLyricText = ttml
            }
            if self.playerVM.currentTrack?.id == trackID {
                self.cachedLyricsTrackID = nil
                self.refreshPresentation()
            }
        }
    }
}

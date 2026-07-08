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
    private var currentPresentationInterval: TimeInterval = 0
    private var cachedLyricsTrackID: UUID?
    private var cachedLyricsSignature: String?
    private var cachedLyricsText: String?
    private var lastSyncedPlayingState: Bool?
    private var lastTelemetrySource: PlaybackSource?
    private var lastTelemetryIsPlaying: Bool?
    private var sidecarHydrationTask: Task<Void, Never>?
    private var sidecarHydratingTrackID: UUID?
    private var trackArtworkWarmupTask: Task<Void, Never>?
    private var trackArtworkWarmupSignature: String?
    private let lyricSnippetSeekLeadInSeconds: Double = 0.8

    private(set) var activeSource: PlaybackSource
    private(set) var presentation: NowPlayingPresentation = .emptyLocal

    var onActiveSourceChanged: ((PlaybackSource) -> Void)?
    var onTelemetryPlaybackStateChanged: ((PlaybackSource, Bool) -> Void)?
    var onPresentationChanged: (@MainActor (NowPlayingPresentation, NowPlayingPresentation) -> Void)?

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

    func invalidateCachedLyrics(for trackID: UUID) {
        if cachedLyricsTrackID == trackID {
            cachedLyricsTrackID = nil
            cachedLyricsSignature = nil
            cachedLyricsText = nil
        }
    }

    func forceRefetchLyrics(libraryVM: LibraryViewModel?) {
        switch activeSource {
        case .local:
            guard let track = presentation.localTrack else { return }
            let trackID = track.id
            let title = track.title
            let artist = track.artist.isEmpty ? nil : track.artist
            let album = track.album.isEmpty ? nil : track.album
            let duration = track.duration > 0 ? track.duration : nil
            
            guard !title.isEmpty else { return }
            
            Task { @MainActor [weak self, weak track] in
                let result = await LyricsSearchHelper.searchAndFetchAutomaticallyMatchedLyrics(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                
                guard let self else { return }
                guard let track, track.id == trackID else { return }
                
                guard let ttml = result.ttml, !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Log.warning("[PlaybackCoordinator] forceRefetchLyrics: failed to fetch automatically matched lyrics or low confidence", category: .playback)
                    return
                }
                
                track.ttmlLyricText = ttml
                track.lyricsText = nil
                track.lyricsFileName = nil
                
                if self.playerVM.currentTrack?.id == trackID {
                    self.cachedLyricsTrackID = nil
                    self.cachedLyricsSignature = nil
                    self.refreshPresentation()
                }
                
                if let libraryVM {
                    await libraryVM.saveTrackEdits(track, mode: .metaAndLyrics, reason: "forceRefetchLyrics")
                } else {
                    Log.warning("[PlaybackCoordinator] forceRefetchLyrics: libraryVM was nil, saving track edits locally only (in-memory)", category: .playback)
                }
                Log.info("[PlaybackCoordinator] forceRefetchLyrics: successfully re-fetched and applied lyrics for track=\(trackID.uuidString.prefix(8))", category: .playback)
            }
            
        case .appleMusic, .systemNowPlaying:
            guard let identity = presentation.externalStableKey else { return }
            ExternalPlaybackMetadataStore.shared.clearAutoLyricsCache(for: identity)
            invalidateExternalPlaybackResolution()
            Log.info("[PlaybackCoordinator] forceRefetchLyrics: cleared external lyrics cache and invalidated resolution for identity=\(identity.prefix(8))", category: .playback)
        }
    }

    func checkSystemNowPlayingAvailability() async -> ExternalPlaybackPermissionState {
        await systemNowPlayingProvider.checkAdapterAvailability()
    }

    // MARK: - Local Track Playback (auto-switches source)

    var canInsertTracksAfterCurrent: Bool {
        activeSource == .local && playerVM.currentTrack != nil
    }

    func playTracks(
        _ tracks: [Track],
        startingAt index: Int = 0,
        libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil,
        startPolicy: PlaybackStartPolicy = .useSavedMode
    ) {
        if activeSource != .local {
            setActiveSource(.local)
        }
        playerVM.playTracks(
            tracks,
            startingAt: index,
            libraryQueueSource: libraryQueueSource,
            startPolicy: startPolicy
        )
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func playTracks(
        _ tracks: [Track],
        startingAt index: Int = 0,
        seekTo seconds: Double,
        libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil,
        startPolicy: PlaybackStartPolicy = .useSavedMode
    ) {
        guard index >= 0, index < tracks.count else { return }
        playTracks(
            tracks,
            startingAt: index,
            libraryQueueSource: libraryQueueSource,
            startPolicy: startPolicy
        )
        scheduleSeekAfterLocalTrackLoad(trackID: tracks[index].id, seconds: seconds)
    }

    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int {
        guard canInsertTracksAfterCurrent else { return 0 }
        let insertedCount = playerVM.insertTracksAfterCurrent(tracks)
        guard insertedCount > 0 else { return 0 }

        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
        return insertedCount
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
            startPolicy: .forceShuffleTemporary
        )
    }

    func playTrack(
        _ track: Track,
        inQueueFrom tracks: [Track],
        libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil
    ) {
        let queue = Self.availableUniqueTracks(from: tracks)
        guard !queue.isEmpty else { return }
        let startIndex = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        playTracks(
            queue,
            startingAt: startIndex,
            libraryQueueSource: libraryQueueSource
        )
    }

    func playTrack(
        _ track: Track,
        inQueueFrom tracks: [Track],
        seekTo seconds: Double,
        libraryQueueSource: PlayerViewModel.LibraryQueueSource? = nil
    ) {
        let queue = Self.availableUniqueTracks(from: tracks)
        guard !queue.isEmpty else { return }
        let startIndex = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        playTracks(
            queue,
            startingAt: startIndex,
            seekTo: seconds,
            libraryQueueSource: libraryQueueSource
        )
    }

    private func scheduleSeekAfterLocalTrackLoad(trackID: UUID, seconds: Double) {
        let targetTime = max(0, seconds - lyricSnippetSeekLeadInSeconds)
        Task { @MainActor [weak self] in
            for _ in 0..<80 {
                guard let self else { return }
                guard self.activeSource == .local else { return }
                guard self.playerVM.currentTrack?.id == trackID else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                guard self.playerVM.isPlaying else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }

                self.seek(to: targetTime)
                return
            }
        }
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

        let isPlaying = newPresentation.isPlaying
        if activeSource.isExternal {
            ExternalPlaybackSpectrumSimulator.shared.setPlaying(isPlaying)
        }
        // Propagate play/pause to the meter + FFT chain for ALL sources (local
        // included, which previously never notified the meter) so the shared
        // analysis hub can suspend the FFT while paused, and re-cadence the
        // presentation timer (4Hz playing / 1Hz paused).
        if lastSyncedPlayingState != isPlaying {
            lastSyncedPlayingState = isPlaying
            meterProvider?.updatePlaybackState(isPlaying: isPlaying)
            adjustPresentationTimerCadence(isPlaying: isPlaying)
        }

        notifyTelemetryIfNeeded(source: activeSource, isPlaying: isPlaying)
        scheduleTrackArtworkWarmupIfNeeded(for: newPresentation)

        let previousPresentation = presentation
        guard !newPresentation.isEffectivelyEqual(to: previousPresentation) else { return }
        presentation = newPresentation
        onPresentationChanged?(previousPresentation, newPresentation)
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

    private static let presentationIntervalPlaying: TimeInterval = 0.25
    private static let presentationIntervalPaused: TimeInterval = 1.0

    private func startPresentationTimer() {
        startPresentationTimer(interval: Self.presentationIntervalPaused)
    }

    private func startPresentationTimer(interval: TimeInterval) {
        presentationTimer?.invalidate()
        currentPresentationInterval = interval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presentationTimer = timer
    }

    /// Idle-CPU: refresh at 4Hz while playing (so elapsed time advances), and
    /// drop to 1Hz when paused. Commands already call `refreshPresentation()`
    /// directly for immediate updates (seek/track/source/play/pause); the 1Hz
    /// paused tick only exists to catch async metadata such as late artwork.
    private func adjustPresentationTimerCadence(isPlaying: Bool) {
        let target = isPlaying ? Self.presentationIntervalPlaying : Self.presentationIntervalPaused
        guard target != currentPresentationInterval else { return }
        startPresentationTimer(interval: target)
    }

    private func makeLocalPresentation() -> NowPlayingPresentation {
        guard let track = playerVM.currentTrack else {
            var empty = NowPlayingPresentation.emptyLocal
            empty.volume = playerVM.volume
            return empty
        }

        let artworkData = track.artworkData
        let artworkSource = track.trackArtworkSource(fallbackData: artworkData)
        let hasDiskArtworkCache = artworkSource.map {
            TrackArtworkCache.shared.hasAnyDiskCache(for: $0)
        } ?? false
        let lyricsText = preferredLyricsTextSnapshot(for: track)
        let isArtworkLoading = track.artworkData?.isEmpty != false
            && track.resolvedArtworkURL() != nil
            && !hasDiskArtworkCache
        scheduleSidecarHydrationIfNeeded(for: track)
        return NowPlayingPresentation(
            source: .local,
            localTrack: track,
            localPlaybackOrderMode: playerVM.currentPlaybackOrderMode,
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            artworkData: artworkData,
            artworkIdentity: artworkIdentity(for: track, artworkData: artworkData),
            artworkDisplayTrackID: track.id,
            isArtworkLoading: isArtworkLoading,
            duration: playerVM.duration,
            currentTime: playerVM.currentTime,
            audioOutputDelay: playerVM.audioOutputDelay,
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
        let signature = lyricsCacheSignature(for: track)
        if cachedLyricsTrackID == track.id, cachedLyricsSignature == signature {
            return cachedLyricsText
        }
        if let ttml = LyricsFormatSupport.normalizedTTMLText(track.ttmlLyricText) {
            cachedLyricsTrackID = track.id
            cachedLyricsSignature = signature
            cachedLyricsText = ttml
            return ttml
        }
        cachedLyricsTrackID = track.id
        cachedLyricsSignature = signature
        cachedLyricsText = nil
        return nil
    }

    private func lyricsCacheSignature(for track: Track) -> String {
        [
            textSignature(track.lyricsText),
            textSignature(track.ttmlLyricText),
            track.lyricsFileName ?? "",
            track.ttmlLyricsFileName ?? "",
        ].joined(separator: "|lyrics-cache|")
    }

    private func artworkIdentity(for track: Track, artworkData: Data?) -> String {
        [
            track.id.uuidString,
            track.artworkFileName ?? "no-file",
            ArtworkDataFingerprint.sampledString(for: artworkData),
        ].joined(separator: ":")
    }

    private func scheduleTrackArtworkWarmupIfNeeded(for presentation: NowPlayingPresentation) {
        guard activeSource == .local, let currentTrack = presentation.localTrack else {
            trackArtworkWarmupTask?.cancel()
            trackArtworkWarmupTask = nil
            trackArtworkWarmupSignature = nil
            return
        }

        let queue = playerVM.currentQueueTracks
        let currentIndex = queue.firstIndex(where: { $0.id == currentTrack.id })
        var targets: [Track] = [currentTrack]
        if let currentIndex {
            for offset in 1...2 {
                let index = currentIndex + offset
                if queue.indices.contains(index) {
                    targets.append(queue[index])
                }
            }
            let previousIndex = currentIndex - 1
            if queue.indices.contains(previousIndex) {
                targets.append(queue[previousIndex])
            }
        }

        var seen = Set<UUID>()
        let sources = targets.compactMap { track -> TrackArtworkSource? in
            guard seen.insert(track.id).inserted else { return nil }
            let fallbackData = track.id == currentTrack.id ? presentation.artworkData : track.artworkData
            return track.trackArtworkSource(fallbackData: fallbackData)
        }
        guard !sources.isEmpty else {
            trackArtworkWarmupTask?.cancel()
            trackArtworkWarmupTask = nil
            trackArtworkWarmupSignature = nil
            return
        }

        let signature = sources.map(\.sourceKey).joined(separator: "||")
        guard signature != trackArtworkWarmupSignature else { return }
        trackArtworkWarmupSignature = signature
        trackArtworkWarmupTask?.cancel()
        trackArtworkWarmupTask = TrackArtworkCache.shared.preloadPlaybackArtwork(
            for: sources,
            reason: "playback-current-window"
        )
    }

    private func textSignature(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "empty" }
        let head = String(text.prefix(16))
        let tail = String(text.suffix(16))
        return "\(text.count):\(head):\(tail)"
    }

    private func scheduleSidecarHydrationIfNeeded(for track: Track) {
        let needsArtwork = track.artworkData?.isEmpty != false && track.resolvedArtworkURL() != nil
        let needsTTMLLyrics = track.ttmlLyricText?.isEmpty != false
            && (track.resolvedTTMLURL() != nil || track.resolvedLyricsURL() != nil)
        guard needsArtwork || needsTTMLLyrics else { return }
        guard sidecarHydratingTrackID != track.id else { return }

        let trackID = track.id
        let artworkSource = needsArtwork ? track.trackArtworkSource(fallbackData: track.artworkData) : nil
        let artworkURL = artworkSource?.artworkFileURL
        let ttmlURL = needsTTMLLyrics ? track.resolvedTTMLURL() : nil
        let ttmlFallbackURL = needsTTMLLyrics ? track.resolvedLyricsURL() : nil

        sidecarHydrationTask?.cancel()
        sidecarHydratingTrackID = trackID
        sidecarHydrationTask = Task(priority: .utility) { @MainActor [weak self, weak track] in
                let token = FirstUseHitchDiagnostics.begin(
                    "PlaybackCoordinator.sidecarHydration",
                    detail: "track=\(trackID.uuidString.prefix(8)) artwork=\(artworkURL != nil) ttml=\(ttmlURL != nil || ttmlFallbackURL != nil)"
                )

            async let artworkTask: Data? = {
                guard let artworkSource else { return nil }
                return await TrackArtworkCache.shared.sourceData(for: artworkSource, purpose: "hydration")
            }()

            async let ttmlTask: String? = Task.detached(priority: .utility) { @Sendable in
                if let ttmlURL,
                   let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
                   let ttml = LyricsFormatSupport.normalizedTTMLText(text) {
                    return ttml
                }
                if let ttmlFallbackURL,
                   ttmlFallbackURL.lastPathComponent.lowercased().hasSuffix(".ttml"),
                   let text = try? String(contentsOf: ttmlFallbackURL, encoding: .utf8),
                   let ttml = LyricsFormatSupport.normalizedTTMLText(text) {
                    return ttml
                }
                return nil
            }.value

            let artwork = await artworkTask
            let ttml = await ttmlTask

            defer {
                FirstUseHitchDiagnostics.end(
                    token,
                    detail: "artworkBytes=\(artwork?.count ?? 0) ttmlChars=\(ttml?.count ?? 0)"
                )
                if self?.sidecarHydratingTrackID == trackID {
                    self?.sidecarHydratingTrackID = nil
                }
            }

            guard !Task.isCancelled, let self, let track, track.id == trackID else { return }
            if let artwork, track.artworkData?.isEmpty != false {
                track.artworkData = artwork
            }
            if let ttml, track.ttmlLyricText?.isEmpty != false {
                track.ttmlLyricText = ttml
            }
            if self.playerVM.currentTrack?.id == trackID {
                self.cachedLyricsTrackID = nil
                self.cachedLyricsSignature = nil
                self.refreshPresentation()
            }
        }
    }
}

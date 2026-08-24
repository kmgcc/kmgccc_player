//
//  PlaybackCoordinator.swift
//
//  Source-aware playback command and presentation coordinator.
//

import Foundation
import CryptoKit
import Observation

/// Narrow local-playback seam (§16): the coordinator issues transport
/// commands and reads state through this abstraction instead of holding a
/// view model strongly. `PlayerViewModel` conforms; the session factory
/// installs it as a weak link so neither side keeps the other alive.
@MainActor
protocol LocalPlaybackControlling: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var audioOutputDelay: Double { get }
    var duration: Double { get }
    var currentTrack: Track? { get }
    var currentPlaybackOrderMode: PlaybackOrderMode { get }
    var volume: Double { get }
    var currentQueueTracks: [Track] { get }

    func togglePlayPause()
    func pause()
    func resume()
    func stop()
    func next()
    func previous()
    func seek(to seconds: Double)
    func setVolume(_ volume: Double)
    func setPlaybackOrderMode(_ mode: PlaybackOrderMode, announceChange: Bool)
    func playTracks(
        _ tracks: [Track],
        startingAt index: Int,
        libraryQueueSource: LibraryQueueSource?,
        startPolicy: PlaybackStartPolicy
    )
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int
    func play(track: Track)
    func playTrackFromQueue(_ track: Track)
}

extension PlayerViewModel: LocalPlaybackControlling {}

@Observable
@MainActor
final class PlaybackCoordinator {
    private enum Keys {
        static let activeSource = "playback.activeSource"
    }

    private weak var localPlayback: (any LocalPlaybackControlling)?
    private let appleMusicAdapter: AppleMusicPlaybackAdapter
    private let systemNowPlayingProvider: SystemNowPlayingProvider
    private let settings: AppSettings
    private let preferenceStatsService: PreferenceStatsService
    private let artworkCache: TrackArtworkCache
    private let lyricsSearchCoordinator: LyricsSearchCoordinator
    private let amllDBService: AMLLDBService
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
    private let artworkWarmer: PlaybackArtworkWarmer
    private let lyricSnippetSeekLeadInSeconds: Double = 0.8

    private struct LyricsRefetchContext: Equatable {
        let requestID: UUID
        let trackIdentity: String
    }

    private var activeLyricsRefetchContext: LyricsRefetchContext?
    private var activeLyricsRefetchTask: Task<Void, Never>?

    private(set) var activeSource: PlaybackSource
    private(set) var presentation: NowPlayingPresentation = .emptyLocal

    var onActiveSourceChanged: ((PlaybackSource) -> Void)?
    var onTelemetryPlaybackStateChanged: ((PlaybackSource, Bool) -> Void)?
    var onPresentationChanged: (@MainActor (NowPlayingPresentation, NowPlayingPresentation) -> Void)?

    init(
        localPlayback: any LocalPlaybackControlling,
        appleMusicAdapter: AppleMusicPlaybackAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider,
        settings: AppSettings? = nil,
        preferenceStatsService: PreferenceStatsService = .shared,
        artworkCache: TrackArtworkCache,
        lyricsSearchCoordinator: LyricsSearchCoordinator,
        amllDBService: AMLLDBService,
        meterProvider: AudioLevelMeterProtocol? = nil,
        artworkWarmer: PlaybackArtworkWarmer? = nil
    ) {
        self.localPlayback = localPlayback
        self.appleMusicAdapter = appleMusicAdapter
        self.systemNowPlayingProvider = systemNowPlayingProvider
        self.settings = settings ?? AppSettings.shared
        self.preferenceStatsService = preferenceStatsService
        self.artworkCache = artworkCache
        self.lyricsSearchCoordinator = lyricsSearchCoordinator
        self.amllDBService = amllDBService
        self.meterProvider = meterProvider
        self.artworkWarmer = artworkWarmer ?? PlaybackArtworkWarmer(
            artworkCache: artworkCache
        )
        self.activeSource = PlaybackSource(
            rawValue: UserDefaults.standard.string(forKey: Keys.activeSource) ?? ""
        ) ?? .local
        if activeSource.isExternal {
            externalProvider(for: activeSource)?.start()
        }
        AudioVisualizationVisibilityRegistry.shared.setExternalMode(activeSource.isExternal)
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

        CrashBreadcrumbRecorder.shared.record(
            .playbackSourceChanged,
            metadata: [.source: .string(TelemetryPlaybackMode(source: source).rawValue)]
        )

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
        case .appleMusic, .systemNowPlaying:
            if localPlayback?.isPlaying == true {
                localPlayback?.pause()
            }
            externalProvider(for: source)?.start()
        }

        activeSource = source
        AudioVisualizationVisibilityRegistry.shared.setExternalMode(source.isExternal)
        lastSyncedPlayingState = nil
        UserDefaults.standard.set(source.rawValue, forKey: Keys.activeSource)
        onActiveSourceChanged?(source)
        notifyTelemetryIfNeeded(source: source, isPlaying: isPlayingForTelemetry(source))
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func playPause() {
        recordCrashPlaybackCommand(.playPause)
        switch activeSource {
        case .local:
            localPlayback?.togglePlayPause()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.playPause()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func pause() {
        recordCrashPlaybackCommand(.pause)
        switch activeSource {
        case .local:
            localPlayback?.pause()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.pause()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func resume() {
        recordCrashPlaybackCommand(.resume)
        switch activeSource {
        case .local:
            localPlayback?.resume()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.play()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func close() {
        presentationTimer?.invalidate()
        presentationTimer = nil
        sidecarHydrationTask?.cancel()
        sidecarHydrationTask = nil
        activeLyricsRefetchTask?.cancel()
        activeLyricsRefetchTask = nil
        stopExternalProviders()
        artworkWarmer.reset()
        onActiveSourceChanged = nil
        onTelemetryPlaybackStateChanged = nil
        onPresentationChanged = nil
    }

    func stop() {
        recordCrashPlaybackCommand(.stop)
        switch activeSource {
        case .local:
            localPlayback?.stop()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.pause()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func next() {
        recordCrashPlaybackCommand(.next)
        switch activeSource {
        case .local:
            localPlayback?.next()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.next()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func previous() {
        recordCrashPlaybackCommand(.previous)
        switch activeSource {
        case .local:
            localPlayback?.previous()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.previous()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func seek(to seconds: Double) {
        recordCrashPlaybackCommand(.seek)
        switch activeSource {
        case .local:
            localPlayback?.seek(to: seconds)
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
            localPlayback?.setVolume(volume)
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
            localPlayback?.setPlaybackOrderMode(mode, announceChange: announceChange)
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

    func invalidateExternalPlaybackResolution(onlyOffsetChanged: Bool = false) {
        guard activeSource.isExternal else { return }
        Log.info(
            "[ExternalPlayback] override saved; invalidating current resolution onlyOffsetChanged=\(onlyOffsetChanged) source=\(activeSource.rawValue) identity=\(presentation.externalStableKey ?? "nil")",
            category: .playback
        )
        if onlyOffsetChanged {
            activeExternalProvider?.updateLyricsOffsetOnly()
        } else {
            activeExternalProvider?.invalidateCurrentResolution()
        }
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
        let context: LyricsRefetchContext
        switch activeSource {
        case .local:
            guard let track = presentation.localTrack else { return }
            context = LyricsRefetchContext(
                requestID: UUID(),
                trackIdentity: track.id.uuidString
            )
        case .appleMusic, .systemNowPlaying:
            guard let identity = presentation.externalStableKey else { return }
            context = LyricsRefetchContext(
                requestID: UUID(),
                trackIdentity: identity
            )
        }

        activeLyricsRefetchTask?.cancel()
        activeLyricsRefetchContext = context
        refreshPresentation()

        activeLyricsRefetchTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.activeLyricsRefetchContext == context {
                    self.activeLyricsRefetchContext = nil
                    self.refreshPresentation()
                }
            }
            guard let self else { return }
            switch self.activeSource {
            case .local:
                await self.performLocalLyricsRefetch(libraryVM: libraryVM, context: context)
            case .appleMusic, .systemNowPlaying:
                await self.activeExternalProvider?.forceRefetchLyrics()
            }
        }
    }

    private func performLocalLyricsRefetch(
        libraryVM: LibraryViewModel?,
        context: LyricsRefetchContext
    ) async {
        guard let track = presentation.localTrack else { return }
        guard track.id.uuidString == context.trackIdentity else { return }

        let trackID = track.id
        let title = track.title
        let artist = track.artist.isEmpty ? nil : track.artist
        let album = track.album.isEmpty ? nil : track.album
        let duration = track.duration > 0 ? track.duration : nil

        guard !title.isEmpty else { return }

        let result = await LyricsSearchHelper.searchAndFetchAutomaticallyMatchedLyrics(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            searchCoordinator: lyricsSearchCoordinator,
            amllDBService: amllDBService
        )

        guard !Task.isCancelled else { return }
        guard track.id == trackID else { return }

        guard
            let ttml = result.ttml,
            !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            Log.warning(
                "[PlaybackCoordinator] forceRefetchLyrics: failed to fetch automatically matched lyrics or low confidence",
                category: .playback
            )
            return
        }

        track.ttmlLyricText = ttml
        track.lyricsText = nil
        track.lyricsFileName = nil

        if localPlayback?.currentTrack?.id == trackID {
            self.cachedLyricsTrackID = nil
            self.cachedLyricsSignature = nil
            self.refreshPresentation()
        }

        if let libraryVM {
            await libraryVM.saveTrackEdits(track, mode: .metaAndLyrics, reason: "forceRefetchLyrics")
        } else {
            Log.warning(
                "[PlaybackCoordinator] forceRefetchLyrics: libraryVM was nil, saving track edits locally only (in-memory)",
                category: .playback
            )
        }

        Log.info(
            "[PlaybackCoordinator] forceRefetchLyrics: successfully re-fetched and applied lyrics for track=\(trackID.uuidString.prefix(8))",
            category: .playback
        )
    }

    func checkSystemNowPlayingAvailability() async -> ExternalPlaybackPermissionState {
        await systemNowPlayingProvider.checkAdapterAvailability()
    }

    // MARK: - Local Track Playback (auto-switches source)

    var canInsertTracksAfterCurrent: Bool {
        activeSource == .local && localPlayback?.currentTrack != nil
    }

    func playTracks(
        _ tracks: [Track],
        startingAt index: Int = 0,
        libraryQueueSource: LibraryQueueSource? = nil,
        startPolicy: PlaybackStartPolicy = .useSavedMode
    ) {
        recordCrashPlaybackCommand(.playQueue)
        if activeSource != .local {
            setActiveSource(.local)
        }
        localPlayback?.playTracks(
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
        libraryQueueSource: LibraryQueueSource? = nil,
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
        let insertedCount = localPlayback?.insertTracksAfterCurrent(tracks) ?? 0
        guard insertedCount > 0 else { return 0 }

        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
        return insertedCount
    }

    func playRandomTracks(_ tracks: [Track], libraryQueueSource: LibraryQueueSource? = nil) {
        let queue = WeightedPlaybackSampler.playableUniqueTracks(from: tracks)
        guard !queue.isEmpty else { return }
        let startTrack = WeightedPlaybackSampler.pick(
            from: queue,
            preferenceStatsService: preferenceStatsService
        ) ?? queue[0]
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
        libraryQueueSource: LibraryQueueSource? = nil
    ) {
        let queue = WeightedPlaybackSampler.playableUniqueTracks(from: tracks)
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
        libraryQueueSource: LibraryQueueSource? = nil
    ) {
        let queue = WeightedPlaybackSampler.playableUniqueTracks(from: tracks)
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
                guard self.localPlayback?.currentTrack?.id == trackID else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                guard self.localPlayback?.isPlaying == true else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }

                self.seek(to: targetTime)
                return
            }
        }
    }

    func play(track: Track) {
        recordCrashPlaybackCommand(.playTrack)
        if activeSource != .local {
            setActiveSource(.local)
        }
        localPlayback?.play(track: track)
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    func playTrackFromQueue(_ track: Track) {
        recordCrashPlaybackCommand(.playTrackFromQueue)
        if activeSource != .local {
            setActiveSource(.local)
        }
        localPlayback?.playTrackFromQueue(track)
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
            var externalPresentation = activeExternalProvider?.presentation
                ?? NowPlayingPresentation.emptySystemNowPlaying
            externalPresentation.isRefetchingLyrics = activeLyricsRefetchContext != nil
            newPresentation = externalPresentation
        }

        let isPlaying = newPresentation.isPlaying
        AudioVisualizationVisibilityRegistry.shared.setPlaying(isPlaying)
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
        artworkWarmer.update(
            activeSource: activeSource,
            presentation: newPresentation,
            queue: localPlayback?.currentQueueTracks ?? []
        )

        let previousPresentation = presentation
        guard !newPresentation.isEffectivelyEqual(to: previousPresentation) else { return }
        presentation = newPresentation
        onPresentationChanged?(previousPresentation, newPresentation)
    }

    private var activeExternalProvider: (any ExternalPlaybackProvider)? {
        externalProvider(for: activeSource)
    }

    @available(*, deprecated, message: "Use smartRandomPick for single picks or playRandomTracks for ShuffleSession-backed playback.")
    static func smartRandomQueue(
        from tracks: [Track],
        startingWith startTrack: Track? = nil,
        preferenceStatsService: PreferenceStatsService
    ) -> [Track] {
        if let startTrack,
           let matched = WeightedPlaybackSampler.playableUniqueTracks(from: tracks).first(where: { $0.id == startTrack.id }) {
            return [matched]
        }
        return WeightedPlaybackSampler.pick(
            from: tracks,
            preferenceStatsService: preferenceStatsService
        ).map { [$0] } ?? []
    }

    static func smartRandomPick(
        from tracks: [Track],
        preferenceStatsService: PreferenceStatsService
    ) -> Track? {
        WeightedPlaybackSampler.pick(
            from: tracks,
            preferenceStatsService: preferenceStatsService
        )
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

    private func recordCrashPlaybackCommand(_ command: CrashPlaybackCommand) {
        CrashBreadcrumbRecorder.shared.record(
            .playbackCommand(command),
            metadata: [.source: .string(TelemetryPlaybackMode(source: activeSource).rawValue)]
        )
    }

    private func isPlayingForTelemetry(_ source: PlaybackSource) -> Bool {
        switch source {
        case .local:
            return localPlayback?.isPlaying ?? false
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
        guard let playback = localPlayback else {
            return .emptyLocal
        }
        guard let track = playback.currentTrack else {
            var empty = NowPlayingPresentation.emptyLocal
            empty.volume = playback.volume
            return empty
        }

        let artworkData = track.artworkData
        let artworkSource = track.trackArtworkSource(fallbackData: artworkData)
        let hasDiskArtworkCache = artworkSource.map {
            artworkCache.hasAnyDiskCache(for: $0)
        } ?? false
        let lyricsText = preferredLyricsTextSnapshot(for: track)
        let isArtworkLoading = track.artworkData?.isEmpty != false
            && track.resolvedArtworkURL() != nil
            && !hasDiskArtworkCache
        let isRefetchingLyrics = activeLyricsRefetchContext?.trackIdentity == track.id.uuidString
        scheduleSidecarHydrationIfNeeded(for: track)
        return NowPlayingPresentation(
            source: .local,
            localTrack: track,
            localPlaybackOrderMode: playback.currentPlaybackOrderMode,
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            artworkData: artworkData,
            artworkIdentity: artworkIdentity(for: track, artworkData: artworkData),
            artworkDisplayTrackID: track.id,
            isArtworkLoading: isArtworkLoading,
            isRefetchingLyrics: isRefetchingLyrics,
            duration: playback.duration,
            currentTime: playback.currentTime,
            audioOutputDelay: playback.audioOutputDelay,
            isPlaying: playback.isPlaying,
            volume: playback.volume,
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
            isSeekEnabled: playback.duration > 0,
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

    private func textSignature(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "empty" }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        let artworkCache = artworkCache

        sidecarHydrationTask?.cancel()
        sidecarHydratingTrackID = trackID
        sidecarHydrationTask = Task(priority: .utility) { @MainActor [weak self, weak track] in
                let token = FirstUseHitchDiagnostics.begin(
                    "PlaybackCoordinator.sidecarHydration",
                    detail: "track=\(trackID.uuidString.prefix(8)) artwork=\(artworkURL != nil) ttml=\(ttmlURL != nil || ttmlFallbackURL != nil)"
                )

            async let artworkTask: Data? = {
                guard let artworkSource else { return nil }
                return await artworkCache.sourceData(
                    for: artworkSource,
                    purpose: "hydration"
                )
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
            if self.localPlayback?.currentTrack?.id == trackID {
                self.cachedLyricsTrackID = nil
                self.cachedLyricsSignature = nil
                self.refreshPresentation()
            }
        }
    }
}

//
//  PlaybackCoordinator.swift
//
//  Source-aware playback command and presentation coordinator.
//

import Foundation
import Observation

// Keep exact inputs so the presentation timer can compare without rebuilding digests.
nonisolated struct PlaybackLyricsCacheKey: Equatable, Sendable {
    let trackID: UUID
    let lyricsText: String?
    let ttmlLyricText: String?
    let lyricsFileName: String?
    let ttmlLyricsFileName: String?
}

nonisolated struct PlaybackSidecarHydrationKey: Equatable, Sendable {
    let trackID: UUID
    let libraryRoot: String
    let ttmlURL: URL?
    let fallbackURL: URL?
}

nonisolated struct PlaybackSidecarRetryState {
    private var lastKey: PlaybackSidecarHydrationKey?
    private var nextAttemptUptime: TimeInterval = 0

    mutating func begin(_ key: PlaybackSidecarHydrationKey, uptime: TimeInterval) -> Bool {
        guard key != lastKey || uptime >= nextAttemptUptime else { return false }
        lastKey = key
        nextAttemptUptime = uptime + 5
        return true
    }
}

/// Narrow local-playback seam (§16): the coordinator issues transport
/// commands and reads state through this abstraction instead of holding a
/// view model strongly. `PlayerViewModel` conforms; the session factory
/// installs it as a weak link so neither side keeps the other alive.
@MainActor
protocol LocalPlaybackControlling: AnyObject {
    var isPlaying: Bool { get }
    var isLyricsClockPlaying: Bool { get }
    var currentTime: Double { get }
    var audioOutputDelay: Double { get }
    var duration: Double { get }
    var currentTrack: Track? { get }
    var isReadyForSeek: Bool { get }
    var nowPlayingAssetURL: URL? { get }
    var currentPlaybackOrderMode: PlaybackOrderMode { get }
    var volume: Double { get }
    var currentQueueTracks: [Track] { get }
    var queueRevision: Int { get }
    var currentQueueDisplayIndex: Int? { get }

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

extension LocalPlaybackControlling {
    var nowPlayingAssetURL: URL? { nil }
    var isLyricsClockPlaying: Bool { isPlaying }
}

/// Elapsed-time snapshot for progress UIs and system Now Playing.
///
/// Kept out of `NowPlayingPresentation` so a progress tick does not invalidate
/// the much larger body of content observers.
struct PlaybackProgress: Equatable {
    var currentTime: Double
    var duration: Double
}

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
    private let libraryTracksProvider: @MainActor () -> [Track]
    private let musicEnrichmentService: MusicEnrichmentService?
    private let externalMetadataStore: ExternalPlaybackMetadataStore?
    private let meterProvider: AudioLevelMeterProtocol?
    private var presentationTimer: Timer?
    private var currentPresentationInterval: TimeInterval = 0
    private var cachedLyricsKey: PlaybackLyricsCacheKey?
    private var cachedLyricsText: String?
    // Inline source keys checksum the full payload; reuse while its inputs stay unchanged.
    private var cachedLocalArtworkSource: TrackArtworkSource?
    private let localArtworkFileProbe = TrackArtworkFileProbe()
    private var isClosed = false
    private var lastSyncedPlayingState: Bool?
    private var lastMetadataSourceSignature: String?
    private var lastTelemetrySource: PlaybackSource?
    private var lastTelemetryIsPlaying: Bool?
    private var sidecarHydrationTask: Task<Void, Never>?
    private var sidecarHydratingTrackID: UUID?
    private var sidecarHydrationTaskID: UUID?
    private var sidecarHydrationKey: PlaybackSidecarHydrationKey?
    private var sidecarRetryState = PlaybackSidecarRetryState()
    private var deferredNowPlayingUpdateTask: Task<Void, Never>?
    private var trackMemoryTrimTask: Task<Void, Never>?
    private var routineTrackMemoryTrimTask: Task<Void, Never>?
    private var retiredTrackReleaseTask: Task<Void, Never>?
    private var retiredTracks: [UUID: Track] = [:]
    private var switchPreparationTask: Task<Void, Never>?
    private var switchCommitWatchdogTask: Task<Void, Never>?
    private var pendingSwitch: PendingTrackSwitch?
    private var appearanceRefreshTask: Task<Void, Never>?
    private(set) var switchGeneration: UInt64 = 0
    private let artworkWarmer: PlaybackArtworkWarmer
    private let nextSongLyricsPreloader: NextSongLyricsPreloader
    private let lyricSnippetSeekLeadInSeconds: Double = 0.8
    private var lastRoutineTrimUptime: TimeInterval = 0

    private(set) var activeSource: PlaybackSource
    private(set) var presentation: NowPlayingPresentation = .emptyLocal
    private(set) var stablePresentation: NowPlayingPresentation = .emptyLocal

    /// Playback progress, published apart from `presentation`.
    ///
    /// Elapsed time advances several times a second. Publishing it inside
    /// `presentation` invalidated every observer of the now-playing content,
    /// so a plain 4 Hz progress tick re-evaluated the whole now-playing tree
    /// (and the library window behind it) while nothing about the track had
    /// changed. Progress-only changes now touch this value alone; the content
    /// presentation is written when content changes.
    private(set) var playbackProgress = PlaybackProgress(currentTime: 0, duration: 0)

    /// Content consumers still receive progress nudges through this narrow
    /// callback when `presentation` itself did not change.
    /// `LyricsPlaybackPipeline` uses it to keep the lyric clock anchored.
    var onPlaybackProgressChanged: (@MainActor (NowPlayingPresentation) -> Void)?

    /// The audible song position right now, for media that follows the song.
    var audiblePlaybackTime: Double {
        if activeSource == .local, let localPlayback {
            return max(0, localPlayback.currentTime - localPlayback.audioOutputDelay)
        }
        return playbackProgress.currentTime
    }

    /// Live lyric clock position. `presentation.lyricsCurrentTime` now only
    /// advances when content changes, so any caller that needs the position at
    /// this instant (lyric reveal, panel mount, author scripts) reads this.
    var liveLyricsTime: Double {
        if let override = presentation.lyricsCurrentTimeOverride {
            return override
        }
        if activeSource == .local, let localPlayback {
            return max(0, localPlayback.currentTime - localPlayback.audioOutputDelay)
        }
        return max(0, playbackProgress.currentTime - max(0, presentation.audioOutputDelay))
    }
    /// Monotonic marker for explicit transport seeks. Lyrics use it to
    /// distinguish a deliberate small backward seek from a stale 4 Hz
    /// presentation sample, which the native display clock intentionally
    /// ignores while playing.
    private(set) var lyricsSeekRevision = 0

    var localNowPlayingAssetURL: URL? {
        localPlayback?.nowPlayingAssetURL
    }

    var onActiveSourceChanged: ((PlaybackSource) -> Void)?
    var onTelemetryPlaybackStateChanged: ((PlaybackSource, Bool) -> Void)?
    var onPresentationChanged: (@MainActor (NowPlayingPresentation, NowPlayingPresentation) -> Void)?

    /// Resolves the artwork-derived appearance (theme palette) for a staged
    /// local track switch. The composition root wires this to `ThemeStore`;
    /// the switch commits immediately after it returns, so the new palette,
    /// metadata, artwork and lyric document become visible together.
    var prepareSwitchAppearance: (@MainActor (NowPlayingPresentation) async -> Void)?

    /// A local track change whose display state is staged until the lyric
    /// document is ready. Committing once keeps SwiftUI from laying out the
    /// now-playing surfaces first with an empty document and again when the
    /// sidecar finishes loading.
    private struct PendingTrackSwitch {
        let identity: TrackSwitchIdentity
        var presentation: NowPlayingPresentation
        let startedAt: TimeInterval
    }

    private struct TrackSwitchIdentity: Equatable {
        let trackID: UUID
    }

    init(
        localPlayback: any LocalPlaybackControlling,
        appleMusicAdapter: AppleMusicPlaybackAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider,
        settings: AppSettings? = nil,
        preferenceStatsService: PreferenceStatsService = .shared,
        artworkCache: TrackArtworkCache,
        meterProvider: AudioLevelMeterProtocol? = nil,
        artworkWarmer: PlaybackArtworkWarmer? = nil,
        musicEnrichmentService: MusicEnrichmentService? = nil,
        externalMetadataStore: ExternalPlaybackMetadataStore? = nil,
        libraryTracksProvider: @escaping @MainActor () -> [Track] = { [] }
    ) {
        self.localPlayback = localPlayback
        self.appleMusicAdapter = appleMusicAdapter
        self.systemNowPlayingProvider = systemNowPlayingProvider
        self.settings = settings ?? AppSettings.shared
        self.preferenceStatsService = preferenceStatsService
        self.libraryTracksProvider = libraryTracksProvider
        self.musicEnrichmentService = musicEnrichmentService
        self.externalMetadataStore = externalMetadataStore
        self.meterProvider = meterProvider
        self.artworkWarmer = artworkWarmer ?? PlaybackArtworkWarmer(
            artworkCache: artworkCache
        )
        self.nextSongLyricsPreloader = NextSongLyricsPreloader(
            trackLookup: { [weak localPlayback] id in
                localPlayback?.currentQueueTracks.first { $0.id == id }
            }
        )
        self.activeSource = PlaybackSource(
            rawValue: UserDefaults.standard.string(forKey: Keys.activeSource) ?? ""
        ) ?? .local
        musicEnrichmentService?.onChange = { [weak self] in
            self?.refreshPresentation()
        }
        if activeSource.isExternal {
            externalProvider(for: activeSource)?.start()
        }
        AudioVisualizationVisibilityRegistry.shared.setExternalMode(activeSource.isExternal)
        SystemVolumeService.shared.onVolumeChanged = { [weak self] _ in
            guard let self, self.settings.volumeControlTarget == .system else { return }
            self.refreshPresentation()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeControlTargetDidChange),
            name: .volumeControlTargetDidChange,
            object: nil
        )
        refreshPresentation()
        startPresentationTimer()
        NowPlayingService.shared.register(coordinator: self)
    }

    func setActiveSource(_ source: PlaybackSource) {
        if source != .local {
            cachedLocalArtworkSource = nil
            localArtworkFileProbe.reset()
            sidecarHydrationTask?.cancel()
            sidecarHydrationTask = nil
            sidecarHydratingTrackID = nil
            sidecarHydrationTaskID = nil
            sidecarHydrationKey = nil
        }
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
        trackMemoryTrimTask?.cancel()
        trackMemoryTrimTask = nil
        routineTrackMemoryTrimTask?.cancel()
        routineTrackMemoryTrimTask = nil
        retiredTrackReleaseTask?.cancel()
        retiredTrackReleaseTask = nil
        retiredTracks.removeAll()
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
            if localPlayback?.currentTrack == nil {
                playRandomTracks(libraryTracksProvider(), libraryQueueSource: .librarySelection("allSongs"))
            } else {
                localPlayback?.togglePlayPause()
            }
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
            if localPlayback?.currentTrack == nil {
                playRandomTracks(libraryTracksProvider(), libraryQueueSource: .librarySelection("allSongs"))
            } else {
                localPlayback?.resume()
            }
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.play()
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
    }

    /// Lets the playing song's artwork warm-up run as upcoming work of the App
    /// background scheduler.
    func bindBackgroundWork(scheduler: BackgroundWorkScheduler, owner: BackgroundWorkOwner) {
        artworkWarmer.bind(scheduler: scheduler, owner: owner)
        nextSongLyricsPreloader.bind(scheduler: scheduler, owner: owner)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        musicEnrichmentService?.onChange = nil
        cachedLocalArtworkSource = nil
        localArtworkFileProbe.reset()
        presentationTimer?.invalidate()
        presentationTimer = nil
        trackMemoryTrimTask?.cancel()
        trackMemoryTrimTask = nil
        routineTrackMemoryTrimTask?.cancel()
        routineTrackMemoryTrimTask = nil
        retiredTrackReleaseTask?.cancel()
        retiredTrackReleaseTask = nil
        retiredTracks.removeAll()
        sidecarHydrationTask?.cancel()
        sidecarHydrationTask = nil
        sidecarHydratingTrackID = nil
        sidecarHydrationTaskID = nil
        sidecarHydrationKey = nil
        deferredNowPlayingUpdateTask?.cancel()
        deferredNowPlayingUpdateTask = nil
        cancelPendingSwitch(reason: "coordinator closed")
        switchPreparationTask?.cancel()
        switchPreparationTask = nil
        switchCommitWatchdogTask?.cancel()
        switchCommitWatchdogTask = nil
        appearanceRefreshTask?.cancel()
        appearanceRefreshTask = nil
        switchGeneration &+= 1
        prepareSwitchAppearance = nil
        stopExternalProviders()
        artworkWarmer.reset()
        nextSongLyricsPreloader.reset()
        onActiveSourceChanged = nil
        onTelemetryPlaybackStateChanged = nil
        onPresentationChanged = nil
        NotificationCenter.default.removeObserver(self, name: .volumeControlTargetDidChange, object: nil)
        SystemVolumeService.shared.onVolumeChanged = nil
    }

    @objc private func handleVolumeControlTargetDidChange() {
        if settings.volumeControlTarget == .system {
            localPlayback?.setVolume(AppSettings.defaultVolume)
        }
        refreshPresentation()
        NowPlayingService.shared.updateNowPlaying(force: true)
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
        scheduleDeferredNowPlayingUpdate()
    }

    func previous() {
        recordCrashPlaybackCommand(.previous)
        switch activeSource {
        case .local:
            // Local previous restarts the current track after three seconds.
            // Mark that internal seek just like the progress-bar seek so the
            // lyric clock can rebase while the renderer is still preparing.
            if (localPlayback?.currentTime ?? 0) > 3 {
                lyricsSeekRevision &+= 1
            }
            localPlayback?.previous()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.previous()
        }
        refreshPresentation()
        scheduleDeferredNowPlayingUpdate()
    }

    /// Publish track metadata after the release transaction has had a chance
    /// to reach the render server. Updating MediaPlayer is cheap in isolation,
    /// but its artwork/remote-command bookkeeping is unnecessary work in the
    /// same main-actor turn as a user-initiated track transition.
    private func scheduleDeferredNowPlayingUpdate() {
        deferredNowPlayingUpdateTask?.cancel()
        deferredNowPlayingUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            NowPlayingService.shared.updateNowPlaying(force: true)
            self.deferredNowPlayingUpdateTask = nil
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        recordCrashPlaybackCommand(.seek)
        lyricsSeekRevision &+= 1
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

    /// A lyric-row tap is an explicit navigation command. If the player was
    /// paused, the tap should both move the playhead and resume playback; the
    /// progress bar and keyboard seek paths continue using `seek(to:)` so they
    /// retain their existing pause-preserving behavior.
    func seekAndResumeIfNeeded(to seconds: Double) {
        guard seconds.isFinite else { return }
        let shouldResume = presentation.hasTrack
            && presentation.isSeekEnabled
            && !presentation.isPlaying
        seek(to: seconds)
        if shouldResume {
            resume()
        }
    }

    func seek(by offset: Double) {
        guard offset.isFinite,
              presentation.hasTrack,
              presentation.isSeekEnabled else {
            Log.debug("[PlaybackCoordinator] relative seek ignored; no seekable presentation", category: .playback)
            return
        }

        let liveTime = playbackProgress.currentTime
        let current = liveTime.isFinite ? max(0, liveTime) : 0
        let unclampedTarget = current + offset
        let upperBound = presentation.duration > 0 ? presentation.duration : .greatestFiniteMagnitude
        seek(to: min(max(unclampedTarget, 0), upperBound))
    }

    func setVolume(_ volume: Double) {
        if settings.volumeControlTarget == .system {
            SystemVolumeService.shared.setSystemVolume(volume)
            if let local = localPlayback, abs(local.volume - AppSettings.defaultVolume) > 0.001 {
                local.setVolume(AppSettings.defaultVolume)
            }
            refreshPresentation()
            NowPlayingService.shared.updateNowPlaying(force: true)
            return
        }

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
        if cachedLyricsKey?.trackID == trackID {
            cachedLyricsKey = nil
            cachedLyricsText = nil
        }
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
    func playDroppedTracks(_ tracks: [Track]) -> Int {
        guard localPlayback != nil else { return 0 }
        let plan = LibraryTrackPlaybackDropPlan(
            tracks: tracks,
            currentTrackID: activeSource == .local ? localPlayback?.currentTrack?.id : nil,
            existingQueue: activeSource == .local ? localPlayback?.currentQueueTracks ?? [] : []
        )
        guard !plan.initialQueue.isEmpty else { return 0 }
        playTracks(plan.initialQueue, startPolicy: .forceSequentialTemporary)
        if !plan.playNext.isEmpty { insertTracksAfterCurrent(plan.playNext) }
        return 1 + plan.playNext.count
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
                guard self.localPlayback?.isReadyForSeek == true else {
                    // The playback command publishes the track and playing
                    // state before AVAudioFile preparation completes. Calling
                    // seek in that window is a silent no-op because the audio
                    // service has no file to schedule yet.
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
        guard !isClosed else { return }
        let basePresentation: NowPlayingPresentation
        switch activeSource {
        case .local:
            basePresentation = makeLocalPresentation()
        case .appleMusic, .systemNowPlaying:
            activeExternalProvider?.tickPresentation()
            let externalPresentation = activeExternalProvider?.presentation
                ?? NowPlayingPresentation.emptySystemNowPlaying
            basePresentation = externalPresentation
        }

        var newPresentation = basePresentation
        enrichPresentation(&newPresentation)
        if settings.volumeControlTarget == .system {
            newPresentation.volume = SystemVolumeService.shared.systemVolume
            newPresentation.isVolumeControlEnabled = true
        }

        if newPresentation.source != .local, let key = newPresentation.externalStableKey {
            let fields = newPresentation.metadataSources.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let signature = "\(key)|\(fields)|\(newPresentation.title)|\(newPresentation.artist)|\(newPresentation.album ?? "")|\(newPresentation.artworkIdentity ?? "")|\(newPresentation.lyricsIdentity ?? "")"
            if lastMetadataSourceSignature != signature {
                lastMetadataSourceSignature = signature
                Log.info("[ExternalMetadata] key=\(key) event=adopted \(fields) titleValue=\(newPresentation.title) artistValue=\(newPresentation.artist) albumValue=\(newPresentation.album ?? "") artworkBytes=\(newPresentation.artworkData?.count ?? 0) lyricsCharacters=\(newPresentation.lyricsText?.count ?? 0)", category: .playback)
            }
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
        let warmStart = ProcessInfo.processInfo.systemUptime
        artworkWarmer.update(
            activeSource: activeSource,
            presentation: newPresentation,
            queueRevision: localPlayback?.queueRevision ?? 0,
            currentQueueIndex: localPlayback?.currentQueueDisplayIndex,
            queue: localPlayback?.currentQueueTracks ?? []
        )
        nextSongLyricsPreloader.update(
            activeSource: activeSource,
            currentTrack: newPresentation.localTrack,
            queue: localPlayback?.currentQueueTracks ?? []
        )
        let warmEnd = ProcessInfo.processInfo.systemUptime

        let nowUptime = ProcessInfo.processInfo.systemUptime
        if isPlaying && nowUptime - lastRoutineTrimUptime > 60 {
            lastRoutineTrimUptime = nowUptime
            scheduleRoutineTrackMemoryTrim()
            DebugUIHooks.record(String(
                format: "switch-timing routine-trim-schedule=%.1fms warmers=%.1fms",
                (ProcessInfo.processInfo.systemUptime - nowUptime) * 1000,
                (warmEnd - warmStart) * 1000
            ))
        } else if (warmEnd - warmStart) * 1000 > 1 {
            DebugUIHooks.record(String(
                format: "switch-timing warmers=%.1fms",
                (warmEnd - warmStart) * 1000
            ))
        }

        if stageTrackSwitchIfNeeded(newPresentation) {
            return
        }

        let previousPresentation = presentation
        if !newPresentation.isEffectivelyEqualIgnoringCurrentTime(to: stablePresentation) {
            stablePresentation = newPresentation
        }
        // Measurement switch: publishing a time-only change invalidates every
        // observer of the whole presentation. KMGCCC_DEBUG_FREEZE_PRESENTATION_TIME=1
        // suppresses those writes so an A/B run can measure how much of the
        // frame cost comes from progress ticks rather than content changes.
        let contentChanged = !newPresentation.isEffectivelyEqualIgnoringCurrentTime(to: previousPresentation)
        let nextProgress = PlaybackProgress(
            currentTime: newPresentation.currentTime,
            duration: newPresentation.duration
        )
        guard contentChanged || nextProgress != playbackProgress else { return }
        playbackProgress = nextProgress
        guard contentChanged else {
            // Progress-only tick: keep the lyric clock anchored without
            // republishing the now-playing content to every observer.
            onPlaybackProgressChanged?(newPresentation)
            return
        }
        presentation = newPresentation
        onPresentationChanged?(previousPresentation, newPresentation)
        if previousPresentation.localTrack?.id != newPresentation.localTrack?.id {
            releaseTrackResources(for: previousPresentation.localTrack)
            if let newTrackID = newPresentation.localTrack?.id {
                scheduleTrackMemoryTrim(for: newTrackID)
            }
        }
    }

    // MARK: - Atomic local track switches

    /// Intercepts a visible local track change. Returns `true` when the new
    /// presentation was staged instead of published.
    @discardableResult
    private func stageTrackSwitchIfNeeded(_ newPresentation: NowPlayingPresentation) -> Bool {
        guard activeSource == .local else {
            cancelPendingSwitch(reason: "source changed")
            return false
        }
        guard let newTrackID = newPresentation.localTrack?.id else {
            cancelPendingSwitch(reason: "track cleared")
            return false
        }

        if let pending = pendingSwitch {
            if pending.identity.trackID == newTrackID {
                pendingSwitch?.presentation = newPresentation
                return true
            }
            if newTrackID == presentation.localTrack?.id {
                // Back to the track that is still on screen: keeping the
                // current frame is both the fastest and the most coherent
                // response, so drop the preparation and publish normally.
                cancelPendingSwitch(reason: "reverted to visible track")
                requestAppearanceRefresh()
                return false
            }
            cancelPendingSwitch(reason: "superseded")
        }

        guard let visibleTrackID = presentation.localTrack?.id,
              visibleTrackID != newTrackID
        else {
            return false
        }
        beginTrackSwitch(to: newPresentation)
        return true
    }

    private func beginTrackSwitch(to newPresentation: NowPlayingPresentation) {
        guard let target = newPresentation.localTrack else { return }
        switchGeneration &+= 1
        appearanceRefreshTask?.cancel()
        appearanceRefreshTask = nil
        let generation = switchGeneration
        pendingSwitch = PendingTrackSwitch(
            identity: TrackSwitchIdentity(trackID: target.id),
            presentation: newPresentation,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        DebugUIHooks.record(
            "track-switch begin gen=\(generation) track=\(FirstUseHitchDiagnostics.trackIDPrefix(target.id))"
        )
        switchPreparationTask?.cancel()
        switchPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndCommitTrackSwitch(generation: generation, trackID: target.id)
        }
        switchCommitWatchdogTask?.cancel()
        switchCommitWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self,
                  generation == self.switchGeneration,
                  self.pendingSwitch != nil
            else { return }
            // A cold artwork read must not hold the transport hostage. The
            // palette still lands through ThemeStore once it resolves.
            Log.debug(
                "[TrackSwitch] appearance deadline reached; committing without it",
                category: .playback
            )
            if let committed = self.commitTrackSwitch(generation: generation) {
                DebugUIHooks.record(
                    "track-switch commit gen=\(generation) track=\(FirstUseHitchDiagnostics.trackIDPrefix(committed.localTrack?.id)) prepare=watchdog lyrics=\(committed.lyricsText?.count ?? 0)"
                )
            }
        }
    }

    private func prepareAndCommitTrackSwitch(generation: UInt64, trackID: UUID) async {
        let startedAt = pendingSwitch?.startedAt ?? ProcessInfo.processInfo.systemUptime
        let token = FirstUseHitchDiagnostics.begin(
            "PlaybackCoordinator.trackSwitch",
            detail: "generation=\(generation) track=\(FirstUseHitchDiagnostics.trackIDPrefix(trackID))"
        )
        defer { FirstUseHitchDiagnostics.end(token) }

        guard let target = localPlayback?.currentTrack, target.id == trackID else {
            if generation == switchGeneration {
                cancelPendingSwitch(reason: "target unavailable")
            }
            return
        }

        let lyricsStart = ProcessInfo.processInfo.systemUptime
        let lyricsPrepared = await prepareSwitchLyrics(for: target)
        let lyricsEnd = ProcessInfo.processInfo.systemUptime
        guard lyricsPrepared, !Task.isCancelled, generation == switchGeneration else {
            releaseTrackLyricsIfAbandoned(target)
            return
        }
        _ = await localArtworkFileProbe.resolve(for: target)
        guard !Task.isCancelled, generation == switchGeneration,
              localPlayback?.currentTrack?.id == trackID else { return }
        if pendingSwitch == nil {
            // The appearance watchdog committed the core switch while the
            // sidecar read was still in flight. Publish the completed
            // document as soon as it lands instead of waiting for the timer.
            refreshPresentation()
            return
        }
        // File metadata arrived without blocking input. Use it for the same
        // staged cover and palette commit, including local-over-online priority.
        var latestPresentation = makeLocalPresentation()
        enrichPresentation(&latestPresentation)
        pendingSwitch?.presentation = latestPresentation

        // The palette resolves before the commit so the new colours and the new
        // cover appear together. Deferring it until after the switch was
        // measured: it does not remove the invalidation, it moves the hitch into
        // the lyric entrance window, so the wait is the cheaper trade.
        let appearanceStart = ProcessInfo.processInfo.systemUptime
        if let staged = pendingSwitch?.presentation {
            await prepareSwitchAppearanceIfNeeded(for: staged)
        }
        let appearanceEnd = ProcessInfo.processInfo.systemUptime
        guard !Task.isCancelled, generation == switchGeneration else {
            releaseTrackLyricsIfAbandoned(target)
            return
        }

        let elapsed = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let commitStart = ProcessInfo.processInfo.systemUptime
        guard let committed = commitTrackSwitch(generation: generation) else {
            releaseTrackLyricsIfAbandoned(target)
            return
        }
        DebugUIHooks.record(
            "track-switch commit gen=\(generation) track=\(FirstUseHitchDiagnostics.trackIDPrefix(committed.localTrack?.id)) prepare=\(String(format: "%.1f", elapsed))ms lyrics=\(committed.lyricsText?.count ?? 0)"
        )
        DebugUIHooks.record(String(
            format: "switch-timing staging lyrics=%.1fms appearance=%.1fms commit=%.1fms",
            (lyricsEnd - lyricsStart) * 1000,
            (appearanceEnd - appearanceStart) * 1000,
            (ProcessInfo.processInfo.systemUptime - commitStart) * 1000
        ))
    }

    /// Loads a local track's sidecar lyrics before its presentation becomes
    /// visible. The document then installs once, with final content, instead
    /// of being cleared and replaced when hydration completes later.
    private func prepareSwitchLyrics(for track: Track) async -> Bool {
        if track.ttmlLyricText?.isEmpty == false || track.lyricsText?.isEmpty == false {
            return true
        }
        guard track.resolvedTTMLURL() != nil || track.resolvedLyricsURL() != nil else {
            return true
        }

        _ = await track.loadTTMLLyricsOffMainIfNeeded()
        guard !Task.isCancelled else { return false }
        if track.ttmlLyricText?.isEmpty != false {
            _ = await track.loadLyricsOffMainIfNeeded()
        }
        return !Task.isCancelled
    }

    /// Resolves the artwork palette inside the switch task so it can be
    /// published immediately before the presentation. Cancelling the switch
    /// (a newer track, or a return to the visible track) cancels this work at
    /// its next checkpoint; the theme watcher remains the fallback for
    /// palettes that need another pass.
    private func prepareSwitchAppearanceIfNeeded(for presentation: NowPlayingPresentation) async {
        guard let prepare = prepareSwitchAppearance else { return }
        await prepare(presentation)
    }

    /// Publishes the staged track exactly once. Returns the committed
    /// presentation, or `nil` when playback already moved to another track.
    @discardableResult
    private func commitTrackSwitch(generation: UInt64) -> NowPlayingPresentation? {
        let switchCommitStart = ProcessInfo.processInfo.systemUptime
        guard generation == switchGeneration,
              let pending = pendingSwitch,
              activeSource == .local,
              let playback = localPlayback,
              let target = playback.currentTrack,
              target.id == pending.identity.trackID
        else {
            if generation == switchGeneration {
                cancelPendingSwitch(reason: "target changed before commit")
            }
            return nil
        }

        switchCommitWatchdogTask?.cancel()
        switchCommitWatchdogTask = nil

        var newPresentation = pending.presentation
        newPresentation.currentTime = playback.currentTime
        newPresentation.duration = playback.duration
        newPresentation.audioOutputDelay = playback.audioOutputDelay
        newPresentation.isPlaying = playback.isPlaying
        newPresentation.lyricsIsPlaying = playback.isLyricsClockPlaying
        newPresentation.volume = settings.volumeControlTarget == .system
            ? SystemVolumeService.shared.systemVolume
            : playback.volume
        newPresentation.localPlaybackOrderMode = playback.currentPlaybackOrderMode
        newPresentation.isSeekEnabled = playback.duration > 0
        newPresentation.lyricsText = preferredLyricsTextSnapshot(for: target)

        let previousPresentation = presentation
        pendingSwitch = nil
        switchPreparationTask = nil
        if sidecarHydratingTrackID == target.id {
            sidecarHydratingTrackID = nil
        }
        if !newPresentation.isEffectivelyEqualIgnoringCurrentTime(to: stablePresentation) {
            stablePresentation = newPresentation
        }
        let assembleEnd = ProcessInfo.processInfo.systemUptime
        scheduleSidecarHydrationIfNeeded(for: target)
        guard !newPresentation.isEffectivelyEqual(to: previousPresentation) else {
            return newPresentation
        }
        presentation = newPresentation
        onPresentationChanged?(previousPresentation, newPresentation)
        let publishEnd = ProcessInfo.processInfo.systemUptime
        NowPlayingService.shared.updateNowPlaying(force: true)
        let nowPlayingEnd = ProcessInfo.processInfo.systemUptime
        if previousPresentation.localTrack?.id != target.id {
            // Release only after the new presentation and its consumers have
            // committed, so the outgoing track's document state stays intact
            // while the pipeline diffs it.
            releaseTrackResources(for: previousPresentation.localTrack)
            scheduleTrackMemoryTrim(for: target.id)
        }
        DebugUIHooks.record(String(
            format: "switch-timing commit assemble=%.1fms publish=%.1fms nowplaying=%.1fms release=%.1fms",
            (assembleEnd - switchCommitStart) * 1000,
            (publishEnd - assembleEnd) * 1000,
            (nowPlayingEnd - publishEnd) * 1000,
            (ProcessInfo.processInfo.systemUptime - nowPlayingEnd) * 1000
        ))
        return newPresentation
    }

    private func cancelPendingSwitch(reason: String) {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        // Invalidate any appearance work that was already in flight. A late
        // palette from the abandoned track must not outlive the switch.
        switchGeneration &+= 1
        appearanceRefreshTask?.cancel()
        appearanceRefreshTask = nil
        switchCommitWatchdogTask?.cancel()
        switchCommitWatchdogTask = nil
        switchPreparationTask?.cancel()
        switchPreparationTask = nil
        if sidecarHydratingTrackID == pending.identity.trackID {
            sidecarHydratingTrackID = nil
        }
        releaseTrackLyricsIfAbandoned(pending.presentation.localTrack)
        Log.debug(
            "[TrackSwitch] cancelled reason=\(reason) track=\(FirstUseHitchDiagnostics.trackIDPrefix(pending.identity.trackID))",
            category: .playback
        )
    }

    /// Serializes background appearance work (the delayed artwork watcher)
    /// with track switches. Requests that arrive while a switch is being
    /// prepared are dropped; that switch publishes its palette itself.
    func requestAppearanceRefresh() {
        guard pendingSwitch == nil, prepareSwitchAppearance != nil else { return }
        appearanceRefreshTask?.cancel()
        let generation = switchGeneration
        appearanceRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applySwitchAppearance(self.stablePresentation)
            guard generation == self.switchGeneration else { return }
            self.appearanceRefreshTask = nil
        }
    }

    private func applySwitchAppearance(_ presentation: NowPlayingPresentation) async {
        guard let prepare = prepareSwitchAppearance else { return }
        await prepare(presentation)
    }

    private func releaseTrackResources(for track: Track?) {
        guard !isClosed, let track else { return }
        retiredTracks[track.id] = track
        guard retiredTrackReleaseTask == nil else { return }
        retiredTrackReleaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let trackID = self.retiredTracks.keys.first {
                guard !Task.isCancelled else { return }
                guard let retired = self.retiredTracks.removeValue(forKey: trackID) else { continue }
                await retired.releaseFileBackedResourcesAfterCheckingDisk {
                    self.localPlayback?.currentTrack?.id != trackID
                        && self.presentation.localTrack?.id != trackID
                }
            }
            guard !Task.isCancelled else { return }
            self.retiredTrackReleaseTask = nil
        }
    }

    private func releaseTrackLyricsIfAbandoned(_ track: Track?) {
        guard let track,
              track.id != presentation.localTrack?.id,
              track.id != localPlayback?.currentTrack?.id
        else { return }
        releaseTrackResources(for: track)
    }

    private func enrichPresentation(_ value: inout NowPlayingPresentation) {
        guard let musicEnrichmentService, value.hasTrack else {
            musicEnrichmentService?.update(query: nil)
            return
        }
        let key: String
        if value.source == .local, let track = value.localTrack {
            key = "track:\(track.id.uuidString)"
        } else if let stableKey = value.externalStableKey {
            key = stableKey
        } else {
            return
        }
        var seed = value.externalMusicAttributes ?? [:]
        if let track = value.localTrack, value.source == .local {
            if let artist = track.albumArtist, !artist.isEmpty { seed["albumArtistName"] = .string(artist) }
            if !track.genreTags.isEmpty { seed["genreNames"] = .array(track.genreTags.map(MusicMetadataValue.string)) }
            if !track.language.isEmpty { seed["audioLocale"] = .string(track.language) }
            if !track.labelOrCompany.isEmpty { seed["recordLabel"] = .string(track.labelOrCompany) }
            if !track.userDescription.isEmpty { seed["description"] = .string(track.userDescription) }
        }
        let query = MusicEnrichmentQuery(
            key: key,
            title: value.externalRawTitle ?? value.title,
            artist: value.externalRawArtist ?? value.artist,
            album: value.externalRawAlbum ?? value.album ?? "",
            duration: value.duration,
            appleSongID: seed["appleSongID"]?.text,
            appleAlbumID: seed["appleAlbumID"]?.text,
            storefront: seed["storefront"]?.text,
            isrc: seed["isrc"]?.text,
            seedAttributes: seed.isEmpty ? nil : seed,
            storedMotionArtwork: value.source == .local ? value.localTrack?.motionArtwork : nil,
            albumArtist: value.localTrack?.albumArtist
        )
        musicEnrichmentService.update(query: query)
        guard let snapshot = musicEnrichmentService.snapshot(for: key) else { return }
        value.musicEnrichment = snapshot
        if value.canUseEnrichmentArtwork,
           !(value.source == .local && value.isArtworkLoading),
           let artwork = snapshot.artworkData {
            value.artworkData = artwork
            let artworkIdentity = "enrichment:\(key):artwork"
            value.artworkIdentity = artworkIdentity
            value.isArtworkLoading = false
            value.metadataSources["artwork"] = snapshot.record.attributeSources["artwork"] ?? "enrichment"
            if value.source == .local, let track = value.localTrack {
                let previous = presentation
                if previous.source == .local,
                   previous.localTrack?.id == track.id,
                   previous.artworkIdentity == artworkIdentity,
                   previous.musicEnrichment?.record.updatedAt == snapshot.record.updatedAt,
                   let previousSourceKey = previous.localArtworkSourceKey {
                    value.localArtworkSourceKey = previousSourceKey
                    value.artworkDataChecksum = previous.artworkDataChecksum
                } else {
                    let artworkSource = TrackArtworkSource(
                        trackID: track.id,
                        artworkFileName: track.artworkFileName,
                        artworkFileURL: nil,
                        inlineArtworkData: artwork
                    )
                    value.localArtworkSourceKey = artworkSource?.sourceKey
                    value.artworkDataChecksum = artworkSource?.inlineArtworkChecksum
                }
            }
        }
        let hasManualLyrics = value.externalStableKey.map {
            externalMetadataStore?.hasManualLyricsDecision(for: $0) ?? false
        } ?? false
        let hasLocalLyrics = value.localTrack != nil && value.lyricsText?.isEmpty == false
        if !hasManualLyrics, !hasLocalLyrics, let lyrics = snapshot.lyricsTTML {
            value.lyricsText = lyrics
            value.lyricsIdentity = "enrichment:\(key):\(snapshot.lyricsIdentity ?? "lyrics")"
            value.externalLyricsStatusMessage = nil
            value.metadataSources["lyrics"] = snapshot.record.lyricsSource ?? "enrichment"
        }
        value.metadataSources["metadata"] = snapshot.record.attributeSources.values.sorted().joined(separator: ",")
    }

    private var activeExternalProvider: (any ExternalPlaybackProvider)? {
        externalProvider(for: activeSource)
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
            MainActor.assumeIsolated {
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
            releaseEmptyLocalPresentationResources()
            return .emptyLocal
        }
        guard let track = playback.currentTrack else {
            releaseEmptyLocalPresentationResources()
            var empty = NowPlayingPresentation.emptyLocal
            empty.isControlEnabled = libraryTracksProvider().contains { $0.availability != .missing }
            empty.volume = settings.volumeControlTarget == .system
                ? SystemVolumeService.shared.systemVolume
                : playback.volume
            return empty
        }

        let artworkData = track.artworkData
        let artworkFileSnapshot = localArtworkFileProbe.snapshot(for: track)
        let artworkSource: TrackArtworkSource?
        if let cachedSource = cachedLocalArtworkSource,
           cachedSource.matches(
               trackID: track.id,
               artworkFileName: track.artworkFileName,
               artworkFileSnapshot: artworkFileSnapshot,
               inlineArtworkData: artworkData
           ) {
            artworkSource = cachedSource
        } else {
            artworkSource = track.trackArtworkSource(
                fallbackData: artworkData,
                fileSnapshot: artworkFileSnapshot
            )
            cachedLocalArtworkSource = artworkSource
        }
        let lyricsText = preferredLyricsTextSnapshot(for: track)
        let isArtworkLoading = track.artworkData?.isEmpty != false
            && artworkSource?.artworkFileURL == nil
            && localArtworkFileProbe.isResolving
        let hasVisibleTrackChange = presentation.localTrack != nil
            && presentation.localTrack?.id != track.id
        if !hasVisibleTrackChange {
            // A visible track change is staged first; the switch preparation
            // owns the sidecar read so the document is complete on its first
            // install. Other refreshes keep the ordinary hydration safety net.
            scheduleSidecarHydrationIfNeeded(for: track)
        }
        return NowPlayingPresentation(
            source: .local,
            localTrack: track,
            localPlaybackOrderMode: playback.currentPlaybackOrderMode,
            title: track.title,
            artist: track.artist,
            album: track.album.isEmpty ? nil : track.album,
            artworkData: artworkData,
            artworkDataChecksum: artworkSource?.inlineArtworkChecksum,
            artworkIdentity: artworkIdentity(for: track, artworkData: artworkData),
            localArtworkSourceKey: artworkSource?.sourceKey,
            localArtworkFileURL: artworkSource?.artworkFileURL,
            artworkDisplayTrackID: track.id,
            isArtworkLoading: isArtworkLoading,
            duration: playback.duration,
            currentTime: playback.currentTime,
            audioOutputDelay: playback.audioOutputDelay,
            isPlaying: playback.isPlaying,
            volume: settings.volumeControlTarget == .system
                ? SystemVolumeService.shared.systemVolume
                : playback.volume,
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
            lyricsIsPlaying: playback.isLyricsClockPlaying,
            isControlEnabled: true,
            isSeekEnabled: playback.duration > 0,
            isVolumeControlEnabled: true,
            isPlaybackModeControlEnabled: true,
            emptyTitleKey: "mini.not_playing"
        )
    }

    private func releaseEmptyLocalPresentationResources() {
        localArtworkFileProbe.reset()
        trackMemoryTrimTask?.cancel()
        trackMemoryTrimTask = nil
        cachedLocalArtworkSource = nil
        cachedLyricsKey = nil
        cachedLyricsText = nil
        // The paused presentation timer also polls an empty queue. Reclaim
        // once when the previous track leaves, rather than on every poll.
        guard let previousTrack = presentation.localTrack else { return }
        releaseTrackResources(for: previousTrack)
        CacheManager.trimRoutinePlaybackMemory()
    }

    private func scheduleTrackMemoryTrim(for trackID: UUID) {
        trackMemoryTrimTask?.cancel()
        // The lyric entrance, cover movement and fullscreen Bokeh of the new
        // track run for about two seconds; the old 500 ms trim landed in the
        // middle of them. This trim also stands in for the periodic one.
        lastRoutineTrimUptime = ProcessInfo.processInfo.systemUptime
        trackMemoryTrimTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.activeSource == .local,
                  self.localPlayback?.currentTrack?.id == trackID else { return }
            self.trackMemoryTrimTask = nil
            CacheManager.trimRoutinePlaybackMemory()
        }
    }

    private func scheduleRoutineTrackMemoryTrim() {
        guard routineTrackMemoryTrimTask == nil else { return }
        routineTrackMemoryTrimTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let queue = self.activeSource == .local ? self.localPlayback?.currentQueueTracks ?? [] : []
            for (index, track) in queue.enumerated() {
                guard !Task.isCancelled else { return }
                await track.releaseFileBackedResourcesAfterCheckingDisk {
                    self.activeSource == .local && self.localPlayback?.currentTrack?.id != track.id
                }
                // Tracks without hydrated media return immediately. A large
                // queue must still give input and navigation a turn.
                if index.isMultiple(of: 32) { await Task.yield() }
            }
            guard !Task.isCancelled else { return }
            self.routineTrackMemoryTrimTask = nil
            CacheManager.trimRoutinePlaybackMemory()
        }
    }

    private func preferredLyricsTextSnapshot(for track: Track) -> String? {
        let cacheKey = PlaybackLyricsCacheKey(
            trackID: track.id,
            lyricsText: track.lyricsText,
            ttmlLyricText: track.ttmlLyricText,
            lyricsFileName: track.lyricsFileName,
            ttmlLyricsFileName: track.ttmlLyricsFileName
        )
        if cachedLyricsKey == cacheKey {
            return cachedLyricsText
        }
        if let ttml = LyricsFormatSupport.normalizedTTMLText(track.ttmlLyricText) {
            cachedLyricsKey = cacheKey
            cachedLyricsText = ttml
            return ttml
        }
        cachedLyricsKey = cacheKey
        cachedLyricsText = nil
        return nil
    }

    private func artworkIdentity(for track: Track, artworkData: Data?) -> String {
        [
            track.id.uuidString,
            track.artworkFileName ?? "no-file",
            ArtworkDataFingerprint.sampledString(for: artworkData),
        ].joined(separator: ":")
    }

    private func scheduleSidecarHydrationIfNeeded(for track: Track) {
        guard track.ttmlLyricText?.isEmpty != false else { return }
        let trackID = track.id
        let ttmlURL = track.resolvedTTMLURL()
        let ttmlFallbackURL = track.resolvedLyricsURL().flatMap {
            $0.lastPathComponent.lowercased().hasSuffix(".ttml") ? $0 : nil
        }
        guard ttmlURL != nil || ttmlFallbackURL != nil else { return }
        let key = PlaybackSidecarHydrationKey(
            trackID: trackID, libraryRoot: track.libraryRootSnapshot,
            ttmlURL: ttmlURL, fallbackURL: ttmlFallbackURL
        )
        guard sidecarHydrationTask == nil || sidecarHydrationKey != key else { return }
        guard sidecarRetryState.begin(key, uptime: ProcessInfo.processInfo.systemUptime) else { return }

        sidecarHydrationTask?.cancel()
        sidecarHydratingTrackID = trackID
        let taskID = UUID()
        sidecarHydrationTaskID = taskID
        sidecarHydrationKey = key
        sidecarHydrationTask = Task(priority: .utility) { @MainActor [weak self, weak track] in
            let token = FirstUseHitchDiagnostics.begin(
                "PlaybackCoordinator.lyricsSidecarHydration",
                detail: "track=\(trackID.uuidString.prefix(8)) ttml=\(ttmlURL != nil || ttmlFallbackURL != nil)"
            )

            async let ttmlTask: String? = Task.detached(priority: .utility) { @Sendable in
                LyricsSidecarReader.loadTTML(ttmlURL: ttmlURL, fallbackURL: ttmlFallbackURL)
            }.value

            let ttml = await ttmlTask

            defer {
                FirstUseHitchDiagnostics.end(
                    token,
                    detail: "ttmlChars=\(ttml?.count ?? 0)"
                )
                if self?.sidecarHydrationTaskID == taskID {
                    self?.sidecarHydratingTrackID = nil
                    self?.sidecarHydrationTaskID = nil
                    self?.sidecarHydrationKey = nil
                    self?.sidecarHydrationTask = nil
                }
            }

            guard !Task.isCancelled, let self, let track, track.id == trackID,
                  self.sidecarHydrationTaskID == taskID,
                  track.libraryRootSnapshot == key.libraryRoot,
                  track.resolvedTTMLURL() == ttmlURL,
                  track.resolvedLyricsURL().flatMap({ $0.lastPathComponent.lowercased().hasSuffix(".ttml") ? $0 : nil }) == ttmlFallbackURL,
                  let ttml, track.ttmlLyricText?.isEmpty != false else { return }
            track.ttmlLyricText = ttml
            if self.localPlayback?.currentTrack?.id == trackID {
                self.cachedLyricsKey = nil
                self.refreshPresentation()
            }
        }
    }
}

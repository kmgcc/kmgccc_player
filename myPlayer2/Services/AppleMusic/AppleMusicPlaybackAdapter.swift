//
//  AppleMusicPlaybackAdapter.swift
//  myPlayer2
//
//  Presents Music.app playback through the source-neutral now-playing model.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppleMusicPlaybackAdapter {
    private enum PollFailureReason: Equatable {
        case processNotRunning
        case scriptExecutionFailed(String)
        case emptyResponse
        case busy(String)
        case timeout(String)
        case noNowPlayingData

        var logDescription: String {
            switch self {
            case .processNotRunning:
                return "process_not_running"
            case .scriptExecutionFailed(let detail):
                return "script_execution_failed(\(detail))"
            case .emptyResponse:
                return "empty_response"
            case .busy(let detail):
                return "apple_music_busy(\(detail))"
            case .timeout(let detail):
                return "script_timeout(\(detail))"
            case .noNowPlayingData:
                return "no_now_playing_data"
            }
        }

        var temporaryTitleKey: String {
            switch self {
            case .noNowPlayingData:
                return "apple_music.not_playing"
            case .processNotRunning, .scriptExecutionFailed, .emptyResponse, .busy, .timeout:
                return "apple_music.temporarily_unavailable"
            }
        }

        var disconnectedTitleKey: String {
            switch self {
            case .processNotRunning:
                return "apple_music.not_running"
            case .scriptExecutionFailed, .emptyResponse, .busy, .timeout, .noNowPlayingData:
                return "apple_music.disconnected"
            }
        }
    }

    private enum ControlAction: Sendable {
        case playPause
        case play
        case pause
        case next
        case previous
        case seek(Double)
        case volume(Double)
        case playbackMode(AppleMusicPlaybackMode)
    }

    private struct ResolvedArtwork {
        enum Source: Int, Sendable {
            case none = 0
            case network = 1
            case localLibrary = 2
            case appleMusic = 3
            case manualOverride = 4

            var logSource: String {
                switch self {
                case .none:
                    return "failed/noArtwork"
                case .network:
                    return "onlineFallback"
                case .localLibrary:
                    return "localMatchedArtwork"
                case .appleMusic:
                    return "appleMusicArtwork"
                case .manualOverride:
                    return "metadataOverride"
                }
            }
        }

        var identity: String?
        var source: Source
        var data: Data?
        var displayTrackID: UUID?

        static let none = ResolvedArtwork(
            identity: nil,
            source: .none,
            data: nil,
            displayTrackID: nil
        )

        var checksum: UInt64 {
            ArtworkAssetStore.checksum(for: data)
        }

        var presentationIdentity: String? {
            guard let identity, let data, !data.isEmpty else { return nil }
            return "\(identity):\(source):\(checksum)"
        }

        var logSource: String { source.logSource }
    }

    private enum AutoLyricsLookupState: Equatable {
        case idle
        case noResults
        case thresholdRejected(bestScore: Double, threshold: Double)
        case allCandidatesFailed
    }

    private let bridge: AppleMusicBridge
    private let libraryVM: LibraryViewModel
    private let artworkResolver: AppleMusicArtworkResolver
    private let metadataStore: ExternalPlaybackMetadataStore
    private let pollQueue = DispatchQueue(label: "myPlayer2.applemusic.poll", qos: .utility)
    private let temporaryUnavailableThreshold = 2
    private let disconnectedFailureThreshold = 8
    private let processMissingDisconnectThreshold = 3

    private var pollTimer: Timer?
    private var isPollInFlight = false
    private var controlTask: Task<Void, Never>?
    private var volumeWriteTask: Task<Void, Never>?
    private var modeWriteTask: Task<Void, Never>?
    private var isTransportControlInFlight = false
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var lyricsSearchTimestamps: [String: Date] = [:]
    private var latestIdentity: String?
    private var latestInfo: AppleMusicBridge.NowPlayingInfo?
    private var latestRawMetadata: ExternalPlaybackRawMetadata?
    private var resolvedRawMetadata: ExternalPlaybackRawMetadata?
    private var latestEffectiveMetadata: ExternalPlaybackEffectiveMetadata?
    private var latestMatchResult: ExternalPlaybackMatchResult?
    private var latestMatchedTrack: Track?
    private var resolvedLyricsText: String?
    private var autoLyricsLookupState: AutoLyricsLookupState = .idle
    private var displayedArtwork: ResolvedArtwork = .none
    private var pendingArtworkIdentity: String?
    private var pendingPlaybackMode: AppleMusicPlaybackMode?
    private var pendingPlaybackModeStartedAt: Date?
    private var pendingVolume: Double?
    private var pendingVolumeStartedAt: Date?
    private var lastControlFailureLogAt: Date = .distantPast
    private var connectionState: ExternalPlaybackConnectionState = .disconnected
    private var consecutiveFailureCount = 0
    private var consecutiveProcessMissingCount = 0
    private var lastPollFailureReason: PollFailureReason?

    private(set) var presentation: NowPlayingPresentation = .emptyAppleMusic

    init(
        bridge: AppleMusicBridge? = nil,
        libraryVM: LibraryViewModel,
        artworkResolver: AppleMusicArtworkResolver = AppleMusicArtworkResolver(),
        metadataStore: ExternalPlaybackMetadataStore? = nil
    ) {
        self.bridge = bridge ?? AppleMusicBridge()
        self.libraryVM = libraryVM
        self.artworkResolver = artworkResolver
        self.metadataStore = metadataStore ?? .shared
    }

    func start() {
        schedulePoll()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePoll()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isPollInFlight = false
        lyricsTask?.cancel()
        lyricsTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        controlTask?.cancel()
        controlTask = nil
        volumeWriteTask?.cancel()
        volumeWriteTask = nil
        modeWriteTask?.cancel()
        modeWriteTask = nil
        isTransportControlInFlight = false
    }

    func refresh() {
        schedulePoll()
    }

    func invalidateCurrentResolution() {
        let invalidatedIdentity = latestIdentity
        cancelPerTrackTasks()
        resolutionTask?.cancel()
        resolutionTask = nil
        if let invalidatedIdentity {
            lyricsSearchTimestamps.removeValue(forKey: invalidatedIdentity)
            Task {
                await artworkResolver.removeCachedArtwork(for: invalidatedIdentity)
            }
        }
        latestIdentity = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = nil
        schedulePoll()
    }

    func reResolveCurrentTrack() {
        guard let info = latestInfo, let raw = latestRawMetadata, let identity = latestIdentity else {
            schedulePoll()
            return
        }
        cancelPerTrackTasks()
        resolutionTask?.cancel()
        resolutionTask = nil
        resolvedRawMetadata = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        autoLyricsLookupState = .idle
        pendingArtworkIdentity = identity
        startResolutionIfNeeded(for: info, raw: raw, identity: identity)
        updatePresentationFromLatestInfo()
    }

    func clearRuntimeResolutionCaches() {
        lyricsSearchTimestamps.removeAll()
        Task {
            await artworkResolver.clearCache()
        }
        invalidateCurrentResolution()
    }

    func playPause() {
        runControl(.playPause)
    }

    func play() {
        runControl(.play)
    }

    func pause() {
        runControl(.pause)
    }

    func next() {
        runControl(.next)
    }

    func previous() {
        runControl(.previous)
    }

    func seek(to seconds: Double) {
        runControl(.seek(seconds))
    }

    func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        pendingVolume = clamped
        pendingVolumeStartedAt = Date()
        updatePresentationFromLatestInfo()

        volumeWriteTask?.cancel()
        let bridge = self.bridge
        volumeWriteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let success = await Self.performControl(.volume(clamped), bridge: bridge)
            await MainActor.run {
                guard let self else { return }
                if !success {
                    self.pendingVolume = nil
                    self.pendingVolumeStartedAt = nil
                    self.logControlFailureIfNeeded(.volume(clamped))
                }
                self.schedulePoll()
            }
        }
    }

    func setPlaybackOrderMode(_ mode: PlaybackOrderMode) {
        setAppleMusicPlaybackMode(AppleMusicPlaybackMode(localMode: mode))
    }

    func setAppleMusicPlaybackMode(_ mode: AppleMusicPlaybackMode) {
        guard pendingPlaybackMode != mode else { return }
        let actualMode = latestInfo.map {
            AppleMusicPlaybackMode(shuffleEnabled: $0.shuffleEnabled, repeatMode: $0.songRepeat)
        }
        guard actualMode != mode || pendingPlaybackMode != nil else { return }

        pendingPlaybackMode = mode
        pendingPlaybackModeStartedAt = Date()
        updatePresentationFromLatestInfo()

        modeWriteTask?.cancel()
        let bridge = self.bridge
        modeWriteTask = Task { [weak self] in
            let success = await Self.performControl(.playbackMode(mode), bridge: bridge)
            await MainActor.run {
                guard let self else { return }
                if !success {
                    self.pendingPlaybackMode = nil
                    self.pendingPlaybackModeStartedAt = nil
                    self.logControlFailureIfNeeded(.playbackMode(mode))
                }
                self.schedulePoll()
            }
        }
    }

    // MARK: - Polling (background AppleScript + main-thread state update)

    private func schedulePoll() {
        guard !isPollInFlight else { return }
        isPollInFlight = true

        let bridge = self.bridge
        pollQueue.async { [weak self] in
            guard let self else { return }
            let result = bridge.fetchFullInfoResult()
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handlePollResult(result)
                    self.isPollInFlight = false
                }
            }
        }
    }

    private func handlePollResult(_ result: AppleMusicBridge.FetchResult) {
        switch result {
        case .success(let info):
            if let title = info.title, !title.isEmpty {
                consecutiveFailureCount = 0
                consecutiveProcessMissingCount = 0
                lastPollFailureReason = nil
                transitionConnectionState(to: .runningHasData, reason: "valid now playing data")
                handlePolledInfo(info)
            } else {
                handleTransientPollFailure(.noNowPlayingData, snapshot: info)
            }
        case .failure(let issue):
            switch issue {
            case .appNotRunning:
                handleTransientPollFailure(.processNotRunning, snapshot: nil)
            case .emptyResponse, .invalidResponse:
                handleTransientPollFailure(.emptyResponse, snapshot: nil)
            case .noNowPlayingData(let snapshot):
                handleTransientPollFailure(.noNowPlayingData, snapshot: snapshot)
            case .busy(let message):
                handleTransientPollFailure(.busy(message), snapshot: nil)
            case .timeout(let message):
                handleTransientPollFailure(.timeout(message), snapshot: nil)
            case .scriptError(let message):
                handleTransientPollFailure(.scriptExecutionFailed(message), snapshot: nil)
            }
        }
    }

    private func handleTransientPollFailure(
        _ reason: PollFailureReason,
        snapshot: AppleMusicBridge.NowPlayingInfo?
    ) {
        consecutiveFailureCount += 1
        if reason == .processNotRunning {
            consecutiveProcessMissingCount += 1
        } else {
            consecutiveProcessMissingCount = 0
        }
        lastPollFailureReason = reason

        Log.warning(
            "[AMAdapter] poll failure reason=\(reason.logDescription) consecutiveFailures=\(consecutiveFailureCount) consecutiveProcessMissing=\(consecutiveProcessMissingCount)",
            category: .playback
        )

        if shouldTransitionToDisconnected(for: reason) {
            handleDisconnectedPoll(reason: reason)
            return
        }

        if shouldTransitionToTemporaryUnavailable() {
            transitionConnectionState(to: .runningTemporarilyUnavailable, reason: reason.logDescription)
        }
        preserveLastKnownPresentationDuringFailure(reason: reason, snapshot: snapshot)
    }

    private func shouldTransitionToTemporaryUnavailable() -> Bool {
        latestInfo == nil || consecutiveFailureCount >= temporaryUnavailableThreshold
    }

    private func shouldTransitionToDisconnected(for reason: PollFailureReason) -> Bool {
        if reason == .processNotRunning {
            return consecutiveProcessMissingCount >= processMissingDisconnectThreshold
        }
        return consecutiveFailureCount >= disconnectedFailureThreshold
    }

    private func preserveLastKnownPresentationDuringFailure(
        reason: PollFailureReason,
        snapshot: AppleMusicBridge.NowPlayingInfo?
    ) {
        if latestInfo != nil, presentation.source == .appleMusic, presentation.hasTrack {
            var stalePresentation = presentation
            stalePresentation.externalConnectionState = .runningTemporarilyUnavailable
            updatePresentationIfNeeded(stalePresentation)
            return
        }

        let fallbackInfo = snapshot ?? AppleMusicBridge.NowPlayingInfo(state: .unknown)
        updateUnavailablePresentation(
            from: fallbackInfo,
            titleKey: reason.temporaryTitleKey,
            connectionState: .runningTemporarilyUnavailable
        )
    }

    private func handleDisconnectedPoll(reason: PollFailureReason) {
        latestInfo = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        latestIdentity = nil
        displayedArtwork = .none
        pendingArtworkIdentity = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        lyricsTask?.cancel()
        lyricsTask = nil
        artworkTask?.cancel()
        artworkTask = nil

        var empty = NowPlayingPresentation.emptyAppleMusic
        empty.externalConnectionState = .disconnected
        empty.emptyTitleKey = reason.disconnectedTitleKey
        empty.isControlEnabled = true
        transitionConnectionState(to: .disconnected, reason: reason.logDescription)
        updatePresentationIfNeeded(empty)
    }

    private func handlePolledInfo(_ info: AppleMusicBridge.NowPlayingInfo) {
        latestInfo = info

        guard let title = info.title, !title.isEmpty else { return }

        let raw = ExternalPlaybackRawMetadata(
            source: .appleMusic,
            persistentID: info.persistentID,
            title: title,
            artist: info.artist ?? "",
            album: info.album,
            duration: info.duration
        )
        let identity = raw.stableKey
        let didChangeTrack = latestIdentity != identity
        if didChangeTrack {
            cancelPerTrackTasks()
            resolutionTask?.cancel()
            resolutionTask = nil
            latestIdentity = identity
            resolvedRawMetadata = nil
            latestEffectiveMetadata = nil
            latestMatchResult = nil
            latestMatchedTrack = nil
            resolvedLyricsText = nil
            autoLyricsLookupState = .idle
            pendingArtworkIdentity = identity
        }

        latestRawMetadata = raw
        reconcilePendingExternalState(with: info)
        updatePresentationFromLatestInfo()
        startResolutionIfNeeded(for: info, raw: raw, identity: identity)
    }

    private func startResolutionIfNeeded(
        for info: AppleMusicBridge.NowPlayingInfo,
        raw: ExternalPlaybackRawMetadata,
        identity: String
    ) {
        guard resolvedRawMetadata != raw else { return }
        guard resolutionTask == nil else { return }

        let metadataStore = self.metadataStore
        let libraryTracks = libraryVM.allTracks
        resolutionTask = Task { [weak self] in
            let resolution = await metadataStore.resolve(raw: raw, libraryTracks: libraryTracks)
            await MainActor.run {
                guard let self else { return }
                self.resolutionTask = nil
                guard self.latestIdentity == identity, self.latestRawMetadata == raw else { return }
                self.applyResolution(resolution, info: info, identity: identity)
            }
        }
    }

    private func applyResolution(
        _ resolution: ExternalPlaybackResolution,
        info: AppleMusicBridge.NowPlayingInfo,
        identity: String
    ) {
        let didResolveDifferentRaw = resolvedRawMetadata != resolution.raw
        resolvedRawMetadata = resolution.raw
        latestEffectiveMetadata = resolution.effective
        latestMatchResult = resolution.matchResult
        latestMatchedTrack = resolution.matchedTrack

        // Lyrics priority:
        // 1. Manually locked lyrics (highest)
        // 2. Matched local track lyrics
        // 3. Auto-cached network lyrics
        let manualLyrics = metadataStore.manualLyrics(for: identity)
        let localLyrics = preferredLocalLyrics(for: resolution.matchedTrack)
        let autoLyrics = manualLyrics == nil && localLyrics.text == nil
            ? metadataStore.cachedAutoLyrics(for: identity)
            : nil
        resolvedLyricsText = manualLyrics ?? localLyrics.text ?? autoLyrics
        if manualLyrics != nil || localLyrics.text != nil || autoLyrics != nil {
            autoLyricsLookupState = .idle
        }

        logLocalMatchResolution(
            resolution,
            identity: identity,
            localLyricsSource: localLyrics.source,
            manualLyricsAvailable: manualLyrics != nil,
            cachedAutoLyricsAvailable: autoLyrics != nil
        )

        updatePresentationFromLatestInfo()

        if didResolveDifferentRaw {
            startArtworkResolution(
                for: info,
                identity: identity,
                effective: resolution.effective,
                matchedTrack: resolution.matchedTrack,
                manualOverrideArtwork: metadataStore.cachedArtwork(for: identity, source: "manualOverride"),
                cachedNetworkArtwork: metadataStore.cachedNetworkArtwork(for: identity)
            )
        }

        resolveLyricsIfNeeded(
            for: info,
            identity: identity,
            effective: resolution.effective,
            localLyrics: localLyrics.text,
            localLyricsSource: localLyrics.source,
            matchedTrack: resolution.matchedTrack
        )
    }

    private func cancelPerTrackTasks() {
        lyricsTask?.cancel()
        lyricsTask = nil
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func updateEmptyPlayingPresentation(from info: AppleMusicBridge.NowPlayingInfo) {
        updateUnavailablePresentation(
            from: info,
            titleKey: "apple_music.not_playing",
            connectionState: .runningTemporarilyUnavailable
        )
    }

    private func updateUnavailablePresentation(
        from info: AppleMusicBridge.NowPlayingInfo,
        titleKey: String,
        connectionState: ExternalPlaybackConnectionState
    ) {
        lyricsTask?.cancel()
        lyricsTask = nil
        var empty = NowPlayingPresentation.emptyAppleMusic
        empty.externalConnectionState = connectionState
        empty.emptyTitleKey = titleKey
        empty.volume = visibleVolume(actual: Double(info.volume) / 100)
        empty.isPlaying = info.state == .playing
        empty.currentTime = info.position
        empty.isControlEnabled = true
        empty.appleMusicPlaybackMode = visiblePlaybackMode(actual: AppleMusicPlaybackMode(
            shuffleEnabled: info.shuffleEnabled,
            repeatMode: info.songRepeat
        ))
        updatePresentationIfNeeded(empty)
    }

    private func updatePresentationFromLatestInfo() {
        guard let info = latestInfo,
              let title = info.title,
              !title.isEmpty,
              let identity = latestIdentity else {
            return
        }

        let lyricsText = resolvedLyricsText
        let actualMode = AppleMusicPlaybackMode(
            shuffleEnabled: info.shuffleEnabled,
            repeatMode: info.songRepeat
        )
        let mode = visiblePlaybackMode(actual: actualMode)
        let volume = visibleVolume(actual: Double(info.volume) / 100)
        let raw = latestRawMetadata
        let effective = latestEffectiveMetadata
        let override = metadataStore.override(for: identity)
        let matchedTrack = latestMatchedTrack

        let displayTitle = nonEmpty(override?.title)
            ?? matchedTrack?.title
            ?? effective?.title
            ?? raw?.title
            ?? title
        let displayArtist = nonEmpty(override?.artist)
            ?? matchedTrack?.artist
            ?? effective?.artist
            ?? raw?.artist
            ?? (info.artist ?? "")
        let displayAlbum = nonEmpty(override?.album)
            ?? nonEmpty(matchedTrack?.album)
            ?? effective?.album
            ?? raw?.album
            ?? info.album
        let displayedArtworkForPresentation = displayedArtwork
        let isArtworkLoading = pendingArtworkIdentity == identity

        let newPresentation = NowPlayingPresentation(
            source: .appleMusic,
            localTrack: matchedTrack,
            title: displayTitle,
            artist: displayArtist,
            album: displayAlbum,
            artworkData: displayedArtworkForPresentation.data,
            artworkIdentity: displayedArtworkForPresentation.presentationIdentity,
            artworkDisplayTrackID: displayedArtworkForPresentation.displayTrackID,
            isArtworkLoading: isArtworkLoading,
            duration: info.duration,
            currentTime: info.position,
            isPlaying: info.state == .playing,
            volume: volume,
            lyricsText: lyricsText,
            lyricsIdentity: identity,
            appleMusicPlaybackMode: mode,
            externalStableKey: identity,
            externalRawTitle: raw?.title ?? title,
            externalRawArtist: raw?.artist ?? info.artist,
            externalRawAlbum: raw?.album ?? info.album,
            externalEffectiveTitle: effective?.title,
            externalEffectiveArtist: effective?.artist,
            externalEffectiveAlbum: effective?.album,
            externalUsesOverride: effective?.usesOverride ?? false,
            externalMatchConfidence: latestMatchResult?.confidence,
            externalLyricsStatusMessage: externalLyricsStatusMessage(for: lyricsText),
            externalConnectionState: connectionState,
            isControlEnabled: true,
            isSeekEnabled: info.duration > 0,
            isVolumeControlEnabled: true,
            isPlaybackModeControlEnabled: true,
            emptyTitleKey: "apple_music.not_playing"
        )

        updatePresentationIfNeeded(newPresentation)
    }

    private func reconcilePendingExternalState(with info: AppleMusicBridge.NowPlayingInfo) {
        let actualMode = AppleMusicPlaybackMode(
            shuffleEnabled: info.shuffleEnabled,
            repeatMode: info.songRepeat
        )
        if let pendingPlaybackMode {
            if pendingPlaybackMode == actualMode || isExpired(pendingPlaybackModeStartedAt, seconds: 5) {
                self.pendingPlaybackMode = nil
                pendingPlaybackModeStartedAt = nil
            }
        }

        if let pendingVolume {
            let actualVolume = Double(info.volume) / 100
            if abs(pendingVolume - actualVolume) < 0.015 || isExpired(pendingVolumeStartedAt, seconds: 5) {
                self.pendingVolume = nil
                pendingVolumeStartedAt = nil
            }
        }
    }

    private func visiblePlaybackMode(actual: AppleMusicPlaybackMode) -> AppleMusicPlaybackMode {
        pendingPlaybackMode ?? actual
    }

    private func visibleVolume(actual: Double) -> Double {
        pendingVolume ?? actual
    }

    private func isExpired(_ date: Date?, seconds: TimeInterval) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > seconds
    }

    private func updatePresentationIfNeeded(_ newPresentation: NowPlayingPresentation) {
        guard !newPresentation.isEffectivelyEqual(to: presentation) else { return }
        presentation = newPresentation
    }

    // MARK: - Artwork

    private func startArtworkResolution(
        for info: AppleMusicBridge.NowPlayingInfo,
        identity: String,
        effective: ExternalPlaybackEffectiveMetadata,
        matchedTrack: Track?,
        manualOverrideArtwork: Data?,
        cachedNetworkArtwork: Data?
    ) {
        let bridge = self.bridge
        let resolver = self.artworkResolver
        let metadataStore = self.metadataStore
        let matchedTrackID = matchedTrack?.id
        let localArtwork = matchedTrack?.loadArtworkDataIfNeeded()
        if let matchedTrack, let localArtwork, !localArtwork.isEmpty {
            let localMatchedTrackID = matchedTrack.id
            if displayedArtwork.identity == identity,
               displayedArtwork.source == .localLibrary,
               displayedArtwork.data?.isEmpty == false {
                pendingArtworkIdentity = nil
                Log.info(
                    "[AMAdapter] artwork finalSource=localMatchedArtwork identity=\(identity.prefix(16)) trackID=\(localMatchedTrackID) action=keep-existing skipAutoSearch=true",
                    category: .playback
                )
                updatePresentationFromLatestInfo()
                return
            }

            pendingArtworkIdentity = identity
            updatePresentationFromLatestInfo()
            artworkTask = Task { [weak self] in
                guard let self else { return }
                let displayTrackID = matchedTrackID ?? NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                let didCommit = await self.prepareAndCommitArtwork(
                    localArtwork,
                    source: .localLibrary,
                    identity: identity,
                    displayTrackID: displayTrackID
                )
                if didCommit {
                    await MainActor.run {
                        metadataStore.updateArtworkSource("localMatchedArtwork", for: identity)
                        Log.info(
                            "[AMAdapter] artwork local match trackID=\(localMatchedTrackID) identity=\(identity.prefix(16)) used=artwork skipOnlineFallback=true",
                            category: .playback
                        )
                    }
                }
            }
            return
        } else if let matchedTrack {
            Log.info(
                "[AMAdapter] artwork local match trackID=\(matchedTrack.id) identity=\(identity.prefix(16)) missing=artwork fallback=enabled",
                category: .playback
            )
        }

        if displayedArtwork.identity == identity,
           displayedArtwork.source == .appleMusic,
           displayedArtwork.data?.isEmpty == false {
            pendingArtworkIdentity = nil
            Log.info(
                "[AMAdapter] artwork finalSource=appleMusicArtwork identity=\(identity.prefix(16)) action=keep-existing",
                category: .playback
            )
            updatePresentationFromLatestInfo()
            return
        }

        pendingArtworkIdentity = identity
        updatePresentationFromLatestInfo()

        artworkTask = Task { [weak self] in
            guard let self else { return }

            let directArtwork = bridge.fetchCurrentArtworkData()
            guard !Task.isCancelled else { return }
            if let directArtwork, !directArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                let didCommit = await self.prepareAndCommitArtwork(
                    directArtwork,
                    source: .appleMusic,
                    identity: identity,
                    displayTrackID: displayTrackID
                )
                if didCommit {
                    await MainActor.run {
                        metadataStore.updateArtworkSource("appleMusicArtwork", for: identity)
                    }
                }
                return
            }
            Log.info(
                "[AMAdapter] artwork source=appleMusicArtwork identity=\(identity.prefix(16)) result=unavailable fallback=enabled",
                category: .playback
            )

            if let manualOverrideArtwork, !manualOverrideArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                let didCommit = await self.prepareAndCommitArtwork(
                    manualOverrideArtwork,
                    source: .manualOverride,
                    identity: identity,
                    displayTrackID: displayTrackID
                )
                if didCommit {
                    await MainActor.run {
                        metadataStore.updateArtworkSource("manualOverride", for: identity)
                    }
                }
                return
            }

            if let cachedNetworkArtwork, !cachedNetworkArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                let didCommit = await self.prepareAndCommitArtwork(
                    cachedNetworkArtwork,
                    source: .network,
                    identity: identity,
                    displayTrackID: displayTrackID
                )
                if didCommit {
                    await MainActor.run {
                        metadataStore.updateArtworkSource("onlineFallback", for: identity)
                    }
                }
                return
            }

            let networkArtwork = await resolver.resolveNetworkArtwork(
                identity: identity,
                title: effective.title,
                artist: effective.artist,
                album: effective.album
            )
            guard !Task.isCancelled else { return }
            if let networkArtwork, !networkArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                let didCommit = await self.prepareAndCommitArtwork(
                    networkArtwork,
                    source: .network,
                    identity: identity,
                    displayTrackID: displayTrackID
                )
                if didCommit {
                    await MainActor.run {
                        metadataStore.storeNetworkArtwork(networkArtwork, for: identity, source: "onlineFallback")
                    }
                }
                return
            }

            await MainActor.run {
                self.commitArtworkResolutionFinishedWithoutArtwork(identity: identity)
            }
        }
    }

    private func prepareAndCommitArtwork(
        _ data: Data,
        source: ResolvedArtwork.Source,
        identity: String,
        displayTrackID: UUID
    ) async -> Bool {
        guard !data.isEmpty else {
            await MainActor.run {
                self.commitArtworkResolutionFinishedWithoutArtwork(identity: identity)
            }
            return false
        }

        _ = await ArtworkAssetStore.shared.snapshot(
            trackID: displayTrackID,
            artworkData: data,
            fullImageMaxPixelSize: 1_400
        )
        guard !Task.isCancelled else { return false }
        return await MainActor.run {
            self.commitArtwork(
                data,
                source: source,
                identity: identity,
                displayTrackID: displayTrackID
            )
        }
    }

    private func commitArtwork(
        _ data: Data,
        source: ResolvedArtwork.Source,
        identity: String,
        displayTrackID: UUID
    ) -> Bool {
        guard latestIdentity == identity else {
            let skippedLatest = latestIdentity.map { String($0.prefix(16)) } ?? "nil"
            Log.info(
                "[AMAdapter] artwork source=\(source.logSource) identity=\(identity.prefix(16)) result=stale skippedLatest=\(skippedLatest)",
                category: .playback
            )
            return false
        }
        pendingArtworkIdentity = nil
        displayedArtwork = ResolvedArtwork(
            identity: identity,
            source: source,
            data: data,
            displayTrackID: displayTrackID
        )
        Log.info(
            "[AMAdapter] artwork finalSource=\(source.logSource) identity=\(identity.prefix(16)) bytes=\(data.count) checksum=\(displayedArtwork.checksum)",
            category: .playback
        )
        updatePresentationFromLatestInfo()
        return true
    }

    private func commitArtworkResolutionFinishedWithoutArtwork(identity: String) {
        guard latestIdentity == identity else { return }
        pendingArtworkIdentity = nil
        displayedArtwork = .none
        Log.info(
            "[AMAdapter] artwork finalSource=failed/noArtwork identity=\(identity.prefix(16))",
            category: .playback
        )
        updatePresentationFromLatestInfo()
    }

    // MARK: - Lyrics

    private func resolveLyricsIfNeeded(
        for info: AppleMusicBridge.NowPlayingInfo,
        identity: String,
        effective: ExternalPlaybackEffectiveMetadata,
        localLyrics: String?,
        localLyricsSource: String?,
        matchedTrack: Track?
    ) {
        // Priority 1: Manually locked lyrics — never overwritten by auto search
        if let manualLyrics = metadataStore.manualLyrics(for: identity) {
            let didClearStatus = autoLyricsLookupState != .idle
            autoLyricsLookupState = .idle
            if resolvedLyricsText != manualLyrics {
                resolvedLyricsText = manualLyrics
                Log.debug("[AMAdapter] resolveLyrics: using manualLocked for \(identity.prefix(16))", category: .lyrics)
                updatePresentationFromLatestInfo()
            } else if didClearStatus {
                updatePresentationFromLatestInfo()
            }
            return
        }

        // Priority 2: Matched local track lyrics
        if let localLyrics {
            let didClearStatus = autoLyricsLookupState != .idle
            resolvedLyricsText = localLyrics
            autoLyricsLookupState = .idle
            metadataStore.updateLyricsSource("localLibrary", for: identity)
            Log.info(
                "[AMAdapter] resolveLyrics: local match used=\(localLyricsSource ?? "localTrack") identity=\(identity.prefix(16)) skipAutoSearch=true",
                category: .lyrics
            )
            if didClearStatus {
                updatePresentationFromLatestInfo()
            }
            return
        }

        if let matchedTrack {
            Log.info(
                "[AMAdapter] resolveLyrics: local match trackID=\(matchedTrack.id) identity=\(identity.prefix(16)) missing=lyrics fallback=enabled",
                category: .lyrics
            )
        }

        // Priority 3: Previously auto-cached lyrics (non-empty only)
        if let autoLyrics = metadataStore.cachedAutoLyrics(for: identity) {
            let didClearStatus = autoLyricsLookupState != .idle
            autoLyricsLookupState = .idle
            if resolvedLyricsText != autoLyrics {
                resolvedLyricsText = autoLyrics
                Log.debug("[AMAdapter] resolveLyrics: using cachedAuto for \(identity.prefix(16))", category: .lyrics)
                updatePresentationFromLatestInfo()
            } else if didClearStatus {
                updatePresentationFromLatestInfo()
            }
            return
        }

        guard !effective.title.isEmpty else { return }
        guard lyricsTask == nil else { return }

        // Throttle re-search to avoid hammering the server on every poll
        if let lastSearch = lyricsSearchTimestamps[identity],
           Date().timeIntervalSince(lastSearch) < 30 {
            return
        }
        lyricsSearchTimestamps[identity] = Date()

        Log.info("[AMAdapter] resolveLyrics: starting auto search for '\(effective.title)' identity=\(identity.prefix(16))", category: .lyrics)

        let metadataStore = self.metadataStore
        lyricsTask = Task { [weak self] in
            let result = await LyricsSearchHelper.searchAndFetchAutomaticallyMatchedLyrics(
                title: effective.title,
                artist: effective.artist,
                album: effective.album,
                duration: info.duration > 0 ? info.duration : nil
            )
            guard !Task.isCancelled else {
                Log.debug("[AMAdapter] resolveLyrics: task cancelled", category: .lyrics)
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.lyricsTask = nil

                // Re-check manual lock after await (user may have selected lyrics while searching)
                if let manualLyrics = metadataStore.manualLyrics(for: identity) {
                    let didClearStatus = self.autoLyricsLookupState != .idle
                    self.autoLyricsLookupState = .idle
                    Log.debug("[AMAdapter] resolveLyrics: manual lock appeared during search, discarding auto result", category: .lyrics)
                    if self.resolvedLyricsText != manualLyrics {
                        self.resolvedLyricsText = manualLyrics
                        if self.latestIdentity == identity {
                            self.updatePresentationFromLatestInfo()
                        }
                    } else if didClearStatus, self.latestIdentity == identity {
                        self.updatePresentationFromLatestInfo()
                    }
                    return
                }

                if let ttml = result.ttml, !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metadataStore.storeNetworkLyrics(ttml, for: identity, source: "network")
                    self.resolvedLyricsText = ttml
                    self.autoLyricsLookupState = .idle
                    Log.info(
                        "[AMAdapter] resolveLyrics: auto search succeeded, length=\(ttml.count), candidate='\(result.fetchedCandidate?.title ?? "unknown")', source=\(result.fetchedCandidate?.source ?? "unknown")",
                        category: .lyrics
                    )
                } else {
                    switch result.status {
                    case .noCandidates:
                        self.autoLyricsLookupState = .noResults
                        Log.warning(
                            "[AMAdapter] resolveLyrics: auto search found no candidates for '\(effective.title)'",
                            category: .lyrics
                        )
                    case .thresholdRejected:
                        let bestScore = result.topCandidate?.normalizedScore ?? 0
                        let threshold = result.threshold ?? LyricsSearchHelper.automaticMatchMinimumScore
                        self.autoLyricsLookupState = .thresholdRejected(bestScore: bestScore, threshold: threshold)
                        Log.warning(
                            "[AMAdapter] resolveLyrics: auto search blocked by threshold for '\(effective.title)' bestScore=\(String(format: "%.2f", bestScore)) threshold=\(String(format: "%.2f", threshold))",
                            category: .lyrics
                        )
                    case .allCandidatesFailed:
                        self.autoLyricsLookupState = .allCandidatesFailed
                        Log.warning(
                            "[AMAdapter] resolveLyrics: auto search found candidates but none produced usable lyrics for '\(effective.title)'",
                            category: .lyrics
                        )
                    case .matched:
                        self.autoLyricsLookupState = .idle
                    }
                    // Do NOT cache empty string or threshold-rejected candidates.
                    // Keep the current state empty so future retries or manual selection remain valid.
                    self.resolvedLyricsText = nil
                }

                if self.latestIdentity == identity {
                    self.updatePresentationFromLatestInfo()
                }
            }
        }
    }

    private func externalLyricsStatusMessage(for lyricsText: String?) -> String? {
        guard lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
        switch autoLyricsLookupState {
        case .idle:
            return nil
        case .noResults:
            return "未搜到任何歌词候选"
        case .thresholdRejected(let bestScore, let threshold):
            return "已搜到候选，但最高匹配分 \(Int(bestScore.rounded())) 不超过 \(Int(threshold.rounded()))，已阻止自动应用"
        case .allCandidatesFailed:
            return "已搜到候选，但未取回可用歌词"
        }
    }

    // MARK: - Controls

    private func runControl(_ action: ControlAction, requiresTransportGate: Bool = true) {
        if requiresTransportGate {
            guard !isTransportControlInFlight else { return }
            isTransportControlInFlight = true
        }

        let bridge = self.bridge
        controlTask = Task { [weak self] in
            let success = await Self.performControl(action, bridge: bridge)
            await MainActor.run {
                guard let self else { return }
                if requiresTransportGate {
                    self.isTransportControlInFlight = false
                }
                if !success {
                    self.logControlFailureIfNeeded(action)
                }
                self.schedulePoll()
            }
        }
    }

    private static func performControl(_ action: ControlAction, bridge: AppleMusicBridge) async -> Bool {
        await withControlTimeout(seconds: 4.0) {
            switch action {
            case .playPause:
                return await performPlayPauseStateMachine(bridge: bridge)
            case .play:
                return await performDefaultPlayStateMachine(bridge: bridge)
            case .pause:
                return bridge.pause()
            case .next:
                return bridge.nextTrack()
            case .previous:
                return bridge.previousTrack()
            case .seek(let seconds):
                return bridge.seek(to: seconds)
            case .volume(let volume):
                return bridge.setVolume(volume)
            case .playbackMode(let mode):
                let shuffleOK = bridge.setShuffleEnabled(mode.shuffleEnabled)
                let repeatOK = bridge.setRepeatMode(mode.repeatMode)
                return shuffleOK || repeatOK
            }
        }
    }

    private static func performPlayPauseStateMachine(bridge: AppleMusicBridge) async -> Bool {
        guard bridge.isMusicAppRunning() else {
            return await performDefaultPlayStateMachine(bridge: bridge)
        }

        let info = bridge.fetchFullInfo()
        switch info.state {
        case .playing:
            return bridge.pause()
        case .paused:
            return bridge.play()
        case .stopped, .unknown:
            return await performDefaultPlayStateMachine(bridge: bridge)
        }
    }

    private static func performDefaultPlayStateMachine(bridge: AppleMusicBridge) async -> Bool {
        if !bridge.isMusicAppRunning() {
            let launched = await MainActor.run {
                bridge.launchMusicApp()
            }
            guard launched else { return false }
            guard await waitForMusicAppRunning(bridge: bridge, timeout: 6.0) else {
                return false
            }
        }

        let info = bridge.fetchFullInfo()
        switch info.state {
        case .playing:
            return true
        case .paused, .stopped, .unknown:
            return bridge.play()
        }
    }

    private static func waitForMusicAppRunning(
        bridge: AppleMusicBridge,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bridge.isMusicAppRunning() {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return bridge.isMusicAppRunning()
    }

    private static func withControlTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func logControlFailureIfNeeded(_ action: ControlAction) {
        let now = Date()
        guard now.timeIntervalSince(lastControlFailureLogAt) > 5 else { return }
        lastControlFailureLogAt = now
        Log.warning("[AppleMusic] control failed: \(String(describing: action))", category: .playback)
    }

    private func transitionConnectionState(
        to newState: ExternalPlaybackConnectionState,
        reason: String
    ) {
        guard connectionState != newState else { return }
        let oldState = connectionState
        connectionState = newState
        Log.info(
            "[AMAdapter] connection state \(oldState.rawValue) -> \(newState.rawValue) reason=\(reason)",
            category: .playback
        )
    }

    // MARK: - Track Metadata

    private func preferredLyricsText(for track: Track?) -> String? {
        preferredLocalLyrics(for: track).text
    }

    private func preferredLocalLyrics(for track: Track?) -> (text: String?, source: String?) {
        guard let track else { return (nil, nil) }
        let candidates: [(String, String?)] = [
            ("lyricsFile", track.loadLyricsIfNeeded()),
            ("ttmlLyricsFile", track.loadTTMLLyricsIfNeeded())
        ]
        for (source, candidate) in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (candidate, source)
            }
        }
        return (nil, nil)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func logLocalMatchResolution(
        _ resolution: ExternalPlaybackResolution,
        identity: String,
        localLyricsSource: String?,
        manualLyricsAvailable: Bool,
        cachedAutoLyricsAvailable: Bool
    ) {
        guard let track = resolution.matchedTrack else {
            Log.info(
                "[AMAdapter] local match identity=\(identity.prefix(16)) hit=false fallback=enabled reason=\(resolution.matchResult.reason)",
                category: .playback
            )
            return
        }

        let hasArtwork = track.loadArtworkDataIfNeeded()?.isEmpty == false
        let resourceSummary = [
            "metadata",
            hasArtwork ? "artwork" : nil,
            localLyricsSource
        ].compactMap { $0 }.joined(separator: ",")
        let missing = [
            hasArtwork ? nil : "artwork",
            localLyricsSource == nil ? "lyrics" : nil
        ].compactMap { $0 }.joined(separator: ",")
        Log.info(
            "[AMAdapter] local match identity=\(identity.prefix(16)) hit=true trackID=\(track.id) confidence=\(String(format: "%.2f", resolution.matchResult.confidence)) resources=\(resourceSummary) missing=\(missing.isEmpty ? "none" : missing) manualLyrics=\(manualLyricsAvailable) cachedAutoLyrics=\(cachedAutoLyricsAvailable)",
            category: .playback
        )
    }
}

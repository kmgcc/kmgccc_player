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
        }

        var identity: String?
        var source: Source
        var data: Data?
        var isLoading: Bool

        static let none = ResolvedArtwork(identity: nil, source: .none, data: nil, isLoading: false)

        var checksum: UInt64 {
            ArtworkAssetStore.checksum(for: data)
        }

        var presentationIdentity: String? {
            guard let identity, let data, !data.isEmpty else { return nil }
            return "\(identity):\(source):\(checksum)"
        }
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
    private var resolvedArtwork: ResolvedArtwork = .none
    private var pendingPlaybackMode: AppleMusicPlaybackMode?
    private var pendingPlaybackModeStartedAt: Date?
    private var pendingVolume: Double?
    private var pendingVolumeStartedAt: Date?
    private var lastControlFailureLogAt: Date = .distantPast

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
        resolvedArtwork = .none
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
            let info: AppleMusicBridge.NowPlayingInfo?
            if bridge.isMusicAppRunning() {
                info = bridge.fetchFullInfo()
            } else {
                info = nil
            }
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let info {
                        self.handlePolledInfo(info)
                    } else {
                        self.handleNotRunningPoll()
                    }
                    self.isPollInFlight = false
                }
            }
        }
    }

    private func handleNotRunningPoll() {
        latestInfo = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        latestIdentity = nil
        resolvedArtwork = .none
        resolutionTask?.cancel()
        resolutionTask = nil
        lyricsTask?.cancel()
        lyricsTask = nil
        artworkTask?.cancel()
        artworkTask = nil

        var empty = NowPlayingPresentation.emptyAppleMusic
        empty.isControlEnabled = true
        updatePresentationIfNeeded(empty)
    }

    private func handlePolledInfo(_ info: AppleMusicBridge.NowPlayingInfo) {
        latestInfo = info

        guard let title = info.title, !title.isEmpty else {
            latestRawMetadata = nil
            resolvedRawMetadata = nil
            latestEffectiveMetadata = nil
            latestMatchResult = nil
            latestMatchedTrack = nil
            resolvedLyricsText = nil
            autoLyricsLookupState = .idle
            latestIdentity = nil
            resolvedArtwork = .none
            resolutionTask?.cancel()
            resolutionTask = nil
            artworkTask?.cancel()
            artworkTask = nil
            updateEmptyPlayingPresentation(from: info)
            return
        }

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
            resolvedArtwork = .none
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
        let localLyrics = preferredLyricsText(for: resolution.matchedTrack)
        let autoLyrics = metadataStore.cachedAutoLyrics(for: identity)
        resolvedLyricsText = manualLyrics ?? localLyrics ?? autoLyrics
        if manualLyrics != nil || localLyrics != nil || autoLyrics != nil {
            autoLyricsLookupState = .idle
        }

        Log.debug("[AMAdapter] applyResolution lyrics source for \(identity.prefix(16)): " +
            "\(manualLyrics != nil ? "manualLocked" : localLyrics != nil ? "localTrack" : autoLyrics != nil ? "cachedAuto" : "none")",
            category: .lyrics)

        if didResolveDifferentRaw,
           let cachedArtwork = metadataStore.cachedNetworkArtwork(for: identity),
           !cachedArtwork.isEmpty {
            publishArtwork(cachedArtwork, source: .network, identity: identity, loading: false)
        }
        publishLocalArtworkIfBetter(resolution.matchedTrack?.artworkData, identity: identity)

        updatePresentationFromLatestInfo()

        if didResolveDifferentRaw {
            startArtworkResolution(
                for: info,
                identity: identity,
                effective: resolution.effective,
                matchedTrack: resolution.matchedTrack
            )
        }

        resolveLyricsIfNeeded(
            for: info,
            identity: identity,
            effective: resolution.effective,
            localLyrics: preferredLyricsText(for: resolution.matchedTrack)
        )
    }

    private func cancelPerTrackTasks() {
        lyricsTask?.cancel()
        lyricsTask = nil
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func updateEmptyPlayingPresentation(from info: AppleMusicBridge.NowPlayingInfo) {
        lyricsTask?.cancel()
        lyricsTask = nil
        var empty = NowPlayingPresentation.emptyAppleMusic
        empty.emptyTitleKey = "apple_music.not_playing"
        empty.volume = visibleVolume(actual: Double(info.volume) / 100)
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

        let displayTitle = effective?.title ?? raw?.title ?? title
        let displayArtist = effective?.artist ?? raw?.artist ?? (info.artist ?? "")
        let displayAlbum = effective?.album ?? raw?.album ?? info.album

        let newPresentation = NowPlayingPresentation(
            source: .appleMusic,
            localTrack: latestMatchedTrack,
            title: displayTitle,
            artist: displayArtist,
            album: displayAlbum,
            artworkData: resolvedArtwork.data,
            artworkIdentity: resolvedArtwork.presentationIdentity,
            isArtworkLoading: resolvedArtwork.isLoading,
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
            isControlEnabled: true,
            isSeekEnabled: info.duration > 0,
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
        matchedTrack: Track?
    ) {
        if resolvedArtwork.data == nil {
            resolvedArtwork = ResolvedArtwork(
                identity: identity,
                source: .none,
                data: nil,
                isLoading: true
            )
            updatePresentationFromLatestInfo()
        }

        let bridge = self.bridge
        let resolver = self.artworkResolver
        let metadataStore = self.metadataStore
        let localArtwork = matchedTrack?.artworkData
        artworkTask = Task { [weak self] in
            let directArtwork = await Self.fetchWithTimeout(seconds: 3.0) {
                bridge.fetchCurrentArtworkData()
            }
            guard !Task.isCancelled else { return }
            if let directArtwork, !directArtwork.isEmpty {
                await MainActor.run {
                    self?.publishArtwork(
                        directArtwork,
                        source: .appleMusic,
                        identity: identity,
                        loading: false
                    )
                    metadataStore.updateArtworkSource("appleMusic", for: identity)
                }
                return
            }

            guard localArtwork == nil || localArtwork?.isEmpty == true else {
                await MainActor.run {
                    self?.markArtworkResolutionFinished(identity: identity)
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
            await MainActor.run {
                if let networkArtwork, !networkArtwork.isEmpty {
                    self?.publishArtwork(
                        networkArtwork,
                        source: .network,
                        identity: identity,
                        loading: false
                    )
                    metadataStore.storeNetworkArtwork(networkArtwork, for: identity, source: "network")
                } else {
                    self?.markArtworkResolutionFinished(identity: identity)
                }
            }
        }
    }

    private func publishLocalArtworkIfBetter(_ data: Data?, identity: String) {
        guard let data, !data.isEmpty else { return }
        publishArtwork(data, source: .localLibrary, identity: identity, loading: false)
        metadataStore.updateArtworkSource("localLibrary", for: identity)
    }

    private func publishArtwork(
        _ data: Data,
        source: ResolvedArtwork.Source,
        identity: String,
        loading: Bool
    ) {
        guard latestIdentity == identity else { return }
        let incomingChecksum = ArtworkAssetStore.checksum(for: data)
        let shouldReplace = source.rawValue > resolvedArtwork.source.rawValue
            || resolvedArtwork.data == nil
            || (source == resolvedArtwork.source && incomingChecksum != resolvedArtwork.checksum)
        guard shouldReplace else {
            if resolvedArtwork.isLoading != loading {
                resolvedArtwork.isLoading = loading
                updatePresentationFromLatestInfo()
            }
            return
        }

        resolvedArtwork = ResolvedArtwork(
            identity: identity,
            source: source,
            data: data,
            isLoading: loading
        )
        updatePresentationFromLatestInfo()
    }

    private func markArtworkResolutionFinished(identity: String) {
        guard latestIdentity == identity, resolvedArtwork.isLoading else { return }
        resolvedArtwork.isLoading = false
        updatePresentationFromLatestInfo()
    }

    // MARK: - Lyrics

    private func resolveLyricsIfNeeded(
        for info: AppleMusicBridge.NowPlayingInfo,
        identity: String,
        effective: ExternalPlaybackEffectiveMetadata,
        localLyrics: String?
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
            if didClearStatus {
                updatePresentationFromLatestInfo()
            }
            return
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

    private static func fetchWithTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () -> Data?
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let result = await group.next() ?? nil
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

    // MARK: - Track Metadata

    private func preferredLyricsText(for track: Track?) -> String? {
        guard let track else { return nil }
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

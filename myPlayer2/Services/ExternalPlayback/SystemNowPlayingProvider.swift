//
//  SystemNowPlayingProvider.swift
//  myPlayer2
//
//  Bridges MediaRemote Adapter stream output into the external playback pipeline.
//

import Foundation

@Observable
@MainActor
final class SystemNowPlayingProvider: ExternalPlaybackProvider {
    private struct StreamEnvelope: Decodable {
        var type: String
        var diff: Bool
        var payload: Payload
    }

    private struct Payload: Decodable, Equatable {
        var bundleIdentifier: String?
        var parentApplicationBundleIdentifier: String?
        var playing: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsedTime: Double?
        var timestamp: String?
        var artworkMimeType: String?
        var artworkData: String?
        var playbackRate: Double?
        var repeatMode: Int?
        var shuffleMode: Int?
        var uniqueIdentifier: String?
        var contentItemIdentifier: String?

        var hasAnyValue: Bool {
            bundleIdentifier != nil ||
            parentApplicationBundleIdentifier != nil ||
            playing != nil ||
            title != nil ||
            artist != nil ||
            album != nil ||
            duration != nil ||
            elapsedTime != nil ||
            timestamp != nil ||
            artworkMimeType != nil ||
            artworkData != nil ||
            playbackRate != nil ||
            repeatMode != nil ||
            shuffleMode != nil ||
            uniqueIdentifier != nil ||
            contentItemIdentifier != nil
        }
    }

    private struct AdapterPaths: Sendable {
        var script: String
        var framework: String
        var testClient: String?
    }

    private enum ControlAction: Sendable {
        case playPause
        case play
        case pause
        case next
        case previous
        case seek(Double)
        case playbackMode(AppleMusicPlaybackMode)

        var throttleKey: String {
            switch self {
            case .playPause: return "playPause"
            case .play: return "play"
            case .pause: return "pause"
            case .next: return "next"
            case .previous: return "previous"
            case .seek: return "seek"
            case .playbackMode: return "playbackMode"
            }
        }

        var throttleInterval: TimeInterval {
            switch self {
            case .seek:
                return 0.35
            case .playbackMode:
                return 0.45
            default:
                return 0.20
            }
        }
    }

    private enum HealthState: Equatable {
        case unknown
        case warning(status: Int32)
        case healthy
    }

    private struct ResolvedArtwork {
        enum Source: Int, Sendable {
            case none = 0
            case network = 1
            case localLibrary = 2
            case provider = 3
            case manualOverride = 4
        }

        var identity: String?
        var source: Source
        var data: Data?
        var displayTrackID: UUID?

        static let none = ResolvedArtwork(identity: nil, source: .none, data: nil, displayTrackID: nil)

        var checksum: UInt64 {
            ArtworkAssetStore.checksum(for: data)
        }

        var presentationIdentity: String? {
            guard let identity, let data, !data.isEmpty else { return nil }
            return "\(identity):\(source.rawValue):\(checksum)"
        }
    }

    private enum AutoLyricsLookupState: Equatable {
        case idle
        case noResults
        case thresholdRejected(bestScore: Double, threshold: Double)
        case allCandidatesFailed
    }

    let source: PlaybackSource = .systemNowPlaying

    private let libraryVM: LibraryViewModel
    private let artworkResolver: AppleMusicArtworkResolver
    private let metadataStore: ExternalPlaybackMetadataStore
    private let decoder = JSONDecoder()
    private let streamQueue = DispatchQueue(label: "myPlayer2.systemNowPlaying.stream", qos: .utility)
    private let controlQueue = DispatchQueue(label: "myPlayer2.systemNowPlaying.control", qos: .utility)

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var streamGeneration: UInt64 = 0
    private var isStarting = false
    private var healthState: HealthState = .unknown
    private var healthTask: Task<Void, Never>?
    private var lastPayload: Payload?
    private var latestIdentity: String?
    private var latestRawMetadata: ExternalPlaybackRawMetadata?
    private var resolvedRawMetadata: ExternalPlaybackRawMetadata?
    private var latestEffectiveMetadata: ExternalPlaybackEffectiveMetadata?
    private var latestMatchResult: ExternalPlaybackMatchResult?
    private var latestMatchedTrack: Track?
    private var resolvedLyricsText: String?
    private var autoLyricsLookupState: AutoLyricsLookupState = .idle
    private var displayedArtwork: ResolvedArtwork = .none
    private var pendingArtworkIdentity: String?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var pendingEmptyPayloadTask: Task<Void, Never>?
    private var streamObservationTask: Task<Void, Never>?
    private var lyricsSearchTimestamps: [String: Date] = [:]
    private var connectionState: ExternalPlaybackConnectionState = .disconnected
    private var lastControlFailureLogAt: Date = .distantPast
    private var emptyPayloadCount = 0
    private var lastControlSentAt: [String: Date] = [:]
    private var currentCapabilities: ExternalPlaybackCapabilities = .unavailable
    private var hasReceivedValidPayload = false

    private(set) var presentation: NowPlayingPresentation = .emptySystemNowPlaying
    var capabilities: ExternalPlaybackCapabilities { currentCapabilities }

    init(
        libraryVM: LibraryViewModel,
        artworkResolver: AppleMusicArtworkResolver = AppleMusicArtworkResolver(),
        metadataStore: ExternalPlaybackMetadataStore? = nil
    ) {
        self.libraryVM = libraryVM
        self.artworkResolver = artworkResolver
        self.metadataStore = metadataStore ?? .shared
    }

    func start() {
        guard process == nil, !isStarting else { return }
        guard let paths = resolveAdapterPaths() else {
            Log.warning("[SystemNowPlaying] adapter paths missing; stream not started", category: .playback)
            updateUnavailablePresentation(titleKey: "system_now_playing.adapter_unavailable", connectionState: .unavailable)
            return
        }

        isStarting = true
        streamGeneration &+= 1
        let generation = streamGeneration
        hasReceivedValidPayload = false
        updateUnavailablePresentation(
            titleKey: "system_now_playing.waiting",
            connectionState: .waitingForData
        )

        Log.info("[SystemNowPlaying] running adapter health check via \(paths.script)", category: .playback)
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let status = await Self.runHealthTest(paths: paths)
            await MainActor.run {
                guard let self, self.streamGeneration == generation else { return }
                self.healthTask = nil
                if status == 0 {
                    self.healthState = .healthy
                    Log.info("[SystemNowPlaying] adapter health check passed status=0", category: .playback)
                } else {
                    self.healthState = .warning(status: status)
                    Log.warning("[SystemNowPlaying] adapter health check returned status=\(status); continuing with soft-gated stream", category: .playback)
                }
            }
        }

        startStream(paths: paths, generation: generation)
    }

    private func startStream(paths: AdapterPaths, generation: UInt64) {
        let arguments = [paths.script, paths.framework] + streamArguments(paths: paths)
        Log.info("[SystemNowPlaying] starting stream command=/usr/bin/perl \(arguments.joined(separator: " "))", category: .playback)
        let stdout = Pipe()
        let stderr = Pipe()
        let launched = launchStreamProcess(arguments: arguments, stdout: stdout, stderr: stderr, generation: generation)
        guard launched else {
            isStarting = false
            updateUnavailablePresentation(titleKey: "system_now_playing.adapter_unavailable", connectionState: .unavailable)
            return
        }

        stdoutPipe = stdout
        stderrPipe = stderr
        isStarting = false
        transitionConnectionState(to: .waitingForData, reason: "stream started")
        scheduleStreamObservation(generation: generation)
        readPipe(stdout.fileHandleForReading, generation: generation, isStdout: true)
        readPipe(stderr.fileHandleForReading, generation: generation, isStdout: false)
    }

    func stop() {
        Log.info("[SystemNowPlaying] stopping stream", category: .playback)
        streamGeneration &+= 1
        isStarting = false
        healthTask?.cancel()
        healthTask = nil
        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        closePipes()
        cancelRuntimeWork(clearPresentation: true)
    }

    func tickPresentation() {
        guard lastPayload != nil, presentation.source == source, presentation.hasTrack else { return }
        updatePresentationFromLatestPayload()
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

    func setPlaybackOrderMode(_ mode: PlaybackOrderMode) {
        setAppleMusicPlaybackMode(AppleMusicPlaybackMode(localMode: mode))
    }

    func setAppleMusicPlaybackMode(_ mode: AppleMusicPlaybackMode) {
        runControl(.playbackMode(mode))
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
        resolvedRawMetadata = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = latestIdentity
        handlePayload(lastPayload)
    }

    func clearRuntimeResolutionCaches() {
        lyricsSearchTimestamps.removeAll()
        Task {
            await artworkResolver.clearCache()
        }
        invalidateCurrentResolution()
    }

    private func launchStreamProcess(
        arguments: [String],
        stdout: Pipe,
        stderr: Pipe,
        generation: UInt64
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.streamGeneration == generation else { return }
                let status = process.terminationStatus
                Log.warning("[SystemNowPlaying] stream exited pid=\(process.processIdentifier) status=\(status) validPayload=\(self.hasReceivedValidPayload)", category: .playback)
                self.process = nil
                self.closePipes()
                let key = self.hasReceivedValidPayload ? self.source.disconnectedTitleKey : "system_now_playing.adapter_unavailable"
                let state: ExternalPlaybackConnectionState = self.hasReceivedValidPayload ? .disconnected : .unavailable
                self.updateUnavailablePresentation(titleKey: key, connectionState: state)
            }
        }

        do {
            try process.run()
            self.process = process
            Log.info("[SystemNowPlaying] stream launched pid=\(process.processIdentifier)", category: .playback)
            return true
        } catch {
            Log.warning("[SystemNowPlaying] failed to launch adapter stream: \(error.localizedDescription)", category: .playback)
            return false
        }
    }

    private func streamArguments(paths: AdapterPaths) -> [String] {
        var arguments = ["stream", "--no-diff", "--debounce=300"]
        if Self.adapterScriptSupportsNoArtwork(paths.script) {
            arguments.insert("--no-artwork", at: 2)
        } else {
            Log.warning("[SystemNowPlaying] adapter does not advertise --no-artwork; using metadata-only debounce args without that flag", category: .playback)
        }
        return arguments
    }

    private static func adapterScriptSupportsNoArtwork(_ script: String) -> Bool {
        guard let contents = try? String(contentsOfFile: script, encoding: .utf8) else { return true }
        return contents.contains("no-artwork")
    }

    private func readPipe(_ handle: FileHandle, generation: UInt64, isStdout: Bool) {
        streamQueue.async { [weak self, handle] in
            var buffer = Data()
            while true {
                guard let data = try? handle.read(upToCount: 4096),
                      !data.isEmpty else {
                    break
                }
                if isStdout {
                    buffer.append(data)
                    while let lineRange = buffer.firstRange(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<lineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<lineRange.upperBound)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        Task { @MainActor [weak self] in
                            guard let self, self.streamGeneration == generation else { return }
                            self.handleStreamLine(line)
                        }
                    }
                } else if let text = String(data: data, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        Task { @MainActor [weak self] in
                            guard let self, self.streamGeneration == generation else { return }
                            Log.warning("[SystemNowPlaying] stream stderr: \(trimmed)", category: .playback)
                        }
                    }
                }
            }
            if isStdout, !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    guard let self, self.streamGeneration == generation else { return }
                    self.handleStreamLine(line)
                }
            }
        }
    }

    private func handleStreamLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        Log.debug("[SystemNowPlaying] stream stdout line: \(trimmed)", category: .playback)
        do {
            let envelope = try decoder.decode(StreamEnvelope.self, from: data)
            guard envelope.type == "data", envelope.diff == false else { return }
            handlePayload(envelope.payload)
        } catch {
            Log.warning("[SystemNowPlaying] ignored malformed stream line: \(error.localizedDescription)", category: .playback)
        }
    }

    private func scheduleStreamObservation(generation: UInt64) {
        streamObservationTask?.cancel()
        streamObservationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                guard let self, self.streamGeneration == generation else { return }
                self.streamObservationTask = nil
                guard !self.hasReceivedValidPayload else { return }
                if self.process?.isRunning == true {
                    Log.warning("[SystemNowPlaying] stream observation window elapsed with no valid payload; keeping provider connected-empty", category: .playback)
                    self.updateUnavailablePresentation(
                        titleKey: "system_now_playing.connected_empty",
                        connectionState: .connectedNoMetadata
                    )
                } else {
                    Log.warning("[SystemNowPlaying] stream observation window elapsed after process exit; marking adapter unavailable", category: .playback)
                    self.updateUnavailablePresentation(
                        titleKey: "system_now_playing.adapter_unavailable",
                        connectionState: .unavailable
                    )
                }
            }
        }
    }

    private func handlePayload(_ payload: Payload?) {
        guard let payload, payload.hasAnyValue else {
            Log.info("[SystemNowPlaying] payload empty; entering empty grace", category: .playback)
            handleEmptyPayload()
            return
        }

        let mergedPayload = mergePayload(payload)
        guard let title = mergedPayload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            Log.info("[SystemNowPlaying] payload has no title; entering empty grace", category: .playback)
            handleEmptyPayload()
            return
        }

        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        emptyPayloadCount = 0
        hasReceivedValidPayload = true
        lastPayload = mergedPayload
        Log.info("[SystemNowPlaying] entering active with title=\(title) artist=\(mergedPayload.artist ?? "")", category: .playback)
        transitionConnectionState(to: .runningHasData, reason: "valid now playing data")
        let raw = ExternalPlaybackRawMetadata(
            source: source,
            persistentID: mergedPayload.uniqueIdentifier ?? mergedPayload.contentItemIdentifier,
            title: title,
            artist: mergedPayload.artist ?? "",
            album: mergedPayload.album,
            duration: mergedPayload.duration ?? 0
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
            displayedArtwork = .none
            pendingArtworkIdentity = identity
        }

        latestRawMetadata = raw
        updatePresentationFromLatestPayload()
        startResolutionIfNeeded(raw: raw, identity: identity)
    }

    private func handleEmptyPayload() {
        emptyPayloadCount += 1
        let generation = streamGeneration
        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                guard let self,
                      self.streamGeneration == generation,
                      self.emptyPayloadCount > 0 else { return }
                Log.info("[SystemNowPlaying] clearing presentation after empty payload grace", category: .playback)
                self.clearTemporarilyUnavailable()
            }
        }
    }

    private func clearTemporarilyUnavailable() {
        lastPayload = nil
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
        resolutionTask?.cancel()
        resolutionTask = nil
        updateUnavailablePresentation(titleKey: "system_now_playing.connected_empty", connectionState: .connectedNoMetadata)
    }

    private func mergePayload(_ payload: Payload) -> Payload {
        guard let previous = lastPayload, shouldMergePayload(previous: previous, incoming: payload) else {
            return payload
        }
        var merged = payload
        merged.bundleIdentifier = nonEmpty(merged.bundleIdentifier) ?? previous.bundleIdentifier
        merged.parentApplicationBundleIdentifier = nonEmpty(merged.parentApplicationBundleIdentifier) ?? previous.parentApplicationBundleIdentifier
        merged.title = nonEmpty(merged.title) ?? previous.title
        merged.artist = nonEmpty(merged.artist) ?? previous.artist
        merged.album = nonEmpty(merged.album) ?? previous.album
        merged.duration = merged.duration ?? previous.duration
        merged.elapsedTime = merged.elapsedTime ?? previous.elapsedTime
        merged.timestamp = merged.timestamp ?? previous.timestamp
        merged.artworkMimeType = nonEmpty(merged.artworkMimeType) ?? previous.artworkMimeType
        merged.artworkData = nonEmpty(merged.artworkData) ?? previous.artworkData
        merged.playbackRate = merged.playbackRate ?? previous.playbackRate
        merged.repeatMode = merged.repeatMode ?? previous.repeatMode
        merged.shuffleMode = merged.shuffleMode ?? previous.shuffleMode
        merged.uniqueIdentifier = nonEmpty(merged.uniqueIdentifier) ?? previous.uniqueIdentifier
        merged.contentItemIdentifier = nonEmpty(merged.contentItemIdentifier) ?? previous.contentItemIdentifier
        return merged
    }

    private func shouldMergePayload(previous: Payload, incoming: Payload) -> Bool {
        let previousIdentifier = providerIdentity(for: previous)
        let incomingIdentifier = providerIdentity(for: incoming)
        if let previousIdentifier, let incomingIdentifier {
            return previousIdentifier == incomingIdentifier
        }
        let previousTitle = nonEmpty(previous.title)
        let incomingTitle = nonEmpty(incoming.title)
        if let previousTitle, let incomingTitle {
            return previousTitle == incomingTitle
        }
        return incomingTitle == nil && previousTitle != nil
    }

    private func providerIdentity(for payload: Payload) -> String? {
        nonEmpty(payload.uniqueIdentifier) ?? nonEmpty(payload.contentItemIdentifier)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func startResolutionIfNeeded(raw: ExternalPlaybackRawMetadata, identity: String) {
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
                self.applyResolution(resolution, identity: identity)
            }
        }
    }

    private func applyResolution(_ resolution: ExternalPlaybackResolution, identity: String) {
        let didResolveDifferentRaw = resolvedRawMetadata != resolution.raw
        resolvedRawMetadata = resolution.raw
        latestEffectiveMetadata = resolution.effective
        latestMatchResult = resolution.matchResult
        latestMatchedTrack = resolution.matchedTrack

        let manualLyrics = metadataStore.manualLyrics(for: identity)
        let localLyrics = preferredLyricsText(for: resolution.matchedTrack)
        let autoLyrics = metadataStore.cachedAutoLyrics(for: identity)
        resolvedLyricsText = manualLyrics ?? localLyrics ?? autoLyrics
        if manualLyrics != nil || localLyrics != nil || autoLyrics != nil {
            autoLyricsLookupState = .idle
        }

        updatePresentationFromLatestPayload()

        if didResolveDifferentRaw {
            startArtworkResolution(
                identity: identity,
                effective: resolution.effective,
                matchedTrack: resolution.matchedTrack,
                manualOverrideArtwork: metadataStore.cachedArtwork(for: identity, source: "manualOverride"),
                cachedNetworkArtwork: metadataStore.cachedNetworkArtwork(for: identity),
                providerArtwork: currentProviderArtworkData()
            )
        }

        resolveLyricsIfNeeded(
            identity: identity,
            effective: resolution.effective,
            localLyrics: preferredLyricsText(for: resolution.matchedTrack)
        )
    }

    private func updatePresentationFromLatestPayload() {
        guard let payload = lastPayload,
              let rawTitle = payload.title,
              let identity = latestIdentity else { return }

        let raw = latestRawMetadata
        let effective = latestEffectiveMetadata
        let displayTitle = effective?.title ?? raw?.title ?? rawTitle
        let displayArtist = effective?.artist ?? raw?.artist ?? (payload.artist ?? "")
        let displayAlbum = effective?.album ?? raw?.album ?? payload.album
        let artwork = displayedArtwork
        let capabilities = capabilities(for: payload)
        currentCapabilities = capabilities

        let newPresentation = NowPlayingPresentation(
            source: source,
            localTrack: latestMatchedTrack,
            title: displayTitle,
            artist: displayArtist,
            album: displayAlbum,
            artworkData: artwork.data,
            artworkIdentity: artwork.presentationIdentity,
            artworkDisplayTrackID: artwork.displayTrackID,
            isArtworkLoading: pendingArtworkIdentity == identity,
            duration: payload.duration ?? 0,
            currentTime: estimatedCurrentTime(from: payload),
            isPlaying: isPayloadPlaying(payload),
            volume: presentation.volume,
            lyricsText: resolvedLyricsText,
            lyricsIdentity: identity,
            appleMusicPlaybackMode: playbackMode(from: payload),
            externalStableKey: identity,
            externalRawTitle: raw?.title ?? rawTitle,
            externalRawArtist: raw?.artist ?? payload.artist,
            externalRawAlbum: raw?.album ?? payload.album,
            externalEffectiveTitle: effective?.title,
            externalEffectiveArtist: effective?.artist,
            externalEffectiveAlbum: effective?.album,
            externalUsesOverride: effective?.usesOverride ?? false,
            externalMatchConfidence: latestMatchResult?.confidence,
            externalLyricsStatusMessage: externalLyricsStatusMessage(for: resolvedLyricsText),
            externalConnectionState: connectionState,
            isControlEnabled: capabilities.canControlPlayback,
            isSeekEnabled: capabilities.canSeek && (payload.duration ?? 0) > 0,
            isVolumeControlEnabled: capabilities.canSetVolume,
            isPlaybackModeControlEnabled: capabilities.canSetPlaybackMode,
            emptyTitleKey: source.notPlayingTitleKey
        )
        updatePresentationIfNeeded(newPresentation)
    }

    private func capabilities(for payload: Payload) -> ExternalPlaybackCapabilities {
        guard connectionState == .runningHasData else { return .unavailable }
        let hasTrack = nonEmpty(payload.title) != nil
        return ExternalPlaybackCapabilities(
            canControlPlayback: hasTrack,
            canSkip: hasTrack,
            canSeek: false,
            canSetVolume: false,
            canSetPlaybackMode: hasTrack && (payload.repeatMode != nil || payload.shuffleMode != nil)
        )
    }

    private func updateUnavailablePresentation(titleKey: String, connectionState: ExternalPlaybackConnectionState) {
        cancelPerTrackTasks()
        var empty = NowPlayingPresentation.emptySystemNowPlaying
        empty.externalConnectionState = connectionState
        empty.emptyTitleKey = titleKey
        currentCapabilities = .unavailable
        empty.isControlEnabled = false
        empty.isSeekEnabled = false
        empty.isVolumeControlEnabled = false
        empty.isPlaybackModeControlEnabled = false
        transitionConnectionState(to: connectionState, reason: titleKey)
        updatePresentationIfNeeded(empty)
    }

    private func updateDisconnected(reason: String) {
        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        emptyPayloadCount = 0
        hasReceivedValidPayload = false
        lastPayload = nil
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
        resolutionTask?.cancel()
        resolutionTask = nil
        cancelPerTrackTasks()

        var empty = NowPlayingPresentation.emptySystemNowPlaying
        empty.externalConnectionState = .disconnected
        empty.emptyTitleKey = source.disconnectedTitleKey
        currentCapabilities = .unavailable
        empty.isControlEnabled = false
        empty.isSeekEnabled = false
        empty.isVolumeControlEnabled = false
        empty.isPlaybackModeControlEnabled = false
        transitionConnectionState(to: .disconnected, reason: reason)
        updatePresentationIfNeeded(empty)
    }

    private func startArtworkResolution(
        identity: String,
        effective: ExternalPlaybackEffectiveMetadata,
        matchedTrack: Track?,
        manualOverrideArtwork: Data?,
        cachedNetworkArtwork: Data?,
        providerArtwork: Data?
    ) {
        pendingArtworkIdentity = identity
        updatePresentationFromLatestPayload()

        let resolver = artworkResolver
        let metadataStore = metadataStore
        let matchedTrackID = matchedTrack?.id
        let localArtwork = matchedTrack?.artworkData
        artworkTask = Task { [weak self] in
            guard let self else { return }

            if let manualOverrideArtwork, !manualOverrideArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                await self.prepareAndCommitArtwork(manualOverrideArtwork, source: .manualOverride, identity: identity, displayTrackID: displayTrackID)
                await MainActor.run { metadataStore.updateArtworkSource("manualOverride", for: identity) }
                return
            }

            if let cachedNetworkArtwork, !cachedNetworkArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                await self.prepareAndCommitArtwork(cachedNetworkArtwork, source: .network, identity: identity, displayTrackID: displayTrackID)
                await MainActor.run { metadataStore.updateArtworkSource("network-cache", for: identity) }
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
                await self.prepareAndCommitArtwork(networkArtwork, source: .network, identity: identity, displayTrackID: displayTrackID)
                await MainActor.run {
                    metadataStore.storeNetworkArtwork(networkArtwork, for: identity, source: "network")
                }
                return
            }

            if let localArtwork, !localArtwork.isEmpty {
                let displayTrackID = matchedTrackID ?? NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                await self.prepareAndCommitArtwork(localArtwork, source: .localLibrary, identity: identity, displayTrackID: displayTrackID)
                await MainActor.run { metadataStore.updateArtworkSource("localLibrary", for: identity) }
                return
            }

            if let providerArtwork, !providerArtwork.isEmpty {
                let displayTrackID = NowPlayingPresentation.externalArtworkDisplayUUID(for: identity)
                await self.prepareAndCommitArtwork(providerArtwork, source: .provider, identity: identity, displayTrackID: displayTrackID)
                await MainActor.run { metadataStore.updateArtworkSource("provider-fallback", for: identity) }
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
    ) async {
        guard !data.isEmpty else {
            await MainActor.run { self.commitArtworkResolutionFinishedWithoutArtwork(identity: identity) }
            return
        }

        _ = await ArtworkAssetStore.shared.snapshot(
            trackID: displayTrackID,
            artworkData: data,
            fullImageMaxPixelSize: 1_400
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.commitArtwork(data, source: source, identity: identity, displayTrackID: displayTrackID)
        }
    }

    private func commitArtwork(_ data: Data, source: ResolvedArtwork.Source, identity: String, displayTrackID: UUID) {
        guard latestIdentity == identity else { return }
        pendingArtworkIdentity = nil
        displayedArtwork = ResolvedArtwork(identity: identity, source: source, data: data, displayTrackID: displayTrackID)
        updatePresentationFromLatestPayload()
    }

    private func commitArtworkResolutionFinishedWithoutArtwork(identity: String) {
        guard latestIdentity == identity else { return }
        pendingArtworkIdentity = nil
        displayedArtwork = .none
        updatePresentationFromLatestPayload()
    }

    private func resolveLyricsIfNeeded(
        identity: String,
        effective: ExternalPlaybackEffectiveMetadata,
        localLyrics: String?
    ) {
        if let manualLyrics = metadataStore.manualLyrics(for: identity) {
            autoLyricsLookupState = .idle
            if resolvedLyricsText != manualLyrics {
                resolvedLyricsText = manualLyrics
                updatePresentationFromLatestPayload()
            }
            return
        }

        if let localLyrics {
            resolvedLyricsText = localLyrics
            autoLyricsLookupState = .idle
            metadataStore.updateLyricsSource("localLibrary", for: identity)
            updatePresentationFromLatestPayload()
            return
        }

        if let autoLyrics = metadataStore.cachedAutoLyrics(for: identity) {
            resolvedLyricsText = autoLyrics
            autoLyricsLookupState = .idle
            updatePresentationFromLatestPayload()
            return
        }

        guard !effective.title.isEmpty, lyricsTask == nil else { return }
        if let lastSearch = lyricsSearchTimestamps[identity], Date().timeIntervalSince(lastSearch) < 30 {
            return
        }
        lyricsSearchTimestamps[identity] = Date()

        let metadataStore = metadataStore
        let duration = lastPayload?.duration
        lyricsTask = Task { [weak self] in
            let result = await LyricsSearchHelper.searchAndFetchAutomaticallyMatchedLyrics(
                title: effective.title,
                artist: effective.artist,
                album: effective.album,
                duration: (duration ?? 0) > 0 ? duration : nil
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.lyricsTask = nil
                guard self.latestIdentity == identity else { return }

                if let manualLyrics = metadataStore.manualLyrics(for: identity) {
                    self.autoLyricsLookupState = .idle
                    self.resolvedLyricsText = manualLyrics
                    self.updatePresentationFromLatestPayload()
                    return
                }

                if let ttml = result.ttml, !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metadataStore.storeNetworkLyrics(ttml, for: identity, source: "network")
                    self.resolvedLyricsText = ttml
                    self.autoLyricsLookupState = .idle
                } else {
                    switch result.status {
                    case .noCandidates:
                        self.autoLyricsLookupState = .noResults
                    case .thresholdRejected:
                        let bestScore = result.topCandidate?.normalizedScore ?? 0
                        let threshold = result.threshold ?? LyricsSearchHelper.automaticMatchMinimumScore
                        self.autoLyricsLookupState = .thresholdRejected(bestScore: bestScore, threshold: threshold)
                    case .allCandidatesFailed:
                        self.autoLyricsLookupState = .allCandidatesFailed
                    case .matched:
                        self.autoLyricsLookupState = .idle
                    }
                    self.resolvedLyricsText = nil
                }

                self.updatePresentationFromLatestPayload()
            }
        }
    }

    private func runControl(_ action: ControlAction) {
        guard isControlActionEnabled(action) else {
            Log.debug("[SystemNowPlaying] control ignored by capability gate: \(String(describing: action))", category: .playback)
            return
        }
        let now = Date()
        let throttleKey = action.throttleKey
        if let lastSent = lastControlSentAt[throttleKey],
           now.timeIntervalSince(lastSent) < action.throttleInterval {
            Log.debug("[SystemNowPlaying] control throttled: \(String(describing: action))", category: .playback)
            return
        }
        lastControlSentAt[throttleKey] = now
        guard let paths = resolveAdapterPaths() else {
            Log.warning("[SystemNowPlaying] control skipped because adapter paths are missing: \(String(describing: action))", category: .playback)
            return
        }
        applyOptimisticState(for: action)
        controlTask = Task { [weak self] in
            let success = await Self.performControl(action, paths: paths)
            await MainActor.run {
                guard let self else { return }
                if !success {
                    self.logControlFailureIfNeeded(action)
                }
            }
        }
    }

    private func isControlActionEnabled(_ action: ControlAction) -> Bool {
        switch action {
        case .playPause, .play, .pause:
            return currentCapabilities.canControlPlayback
        case .next, .previous:
            return currentCapabilities.canSkip
        case .seek:
            return currentCapabilities.canSeek
        case .playbackMode:
            return currentCapabilities.canSetPlaybackMode
        }
    }

    private func applyOptimisticState(for action: ControlAction) {
        guard presentation.hasTrack else { return }
        switch action {
        case .playPause:
            presentation.isPlaying.toggle()
        case .play:
            presentation.isPlaying = true
        case .pause:
            presentation.isPlaying = false
        case .next, .previous, .seek, .playbackMode:
            break
        }
    }

    private static func performControl(_ action: ControlAction, paths: AdapterPaths) async -> Bool {
        switch action {
        case .playPause:
            return await runAdapterCommand(paths: paths, arguments: ["send", "2"])
        case .play:
            return await runAdapterCommand(paths: paths, arguments: ["send", "0"])
        case .pause:
            return await runAdapterCommand(paths: paths, arguments: ["send", "1"])
        case .next:
            return await runAdapterCommand(paths: paths, arguments: ["send", "4"])
        case .previous:
            return await runAdapterCommand(paths: paths, arguments: ["send", "5"])
        case .seek(let seconds):
            let micros = max(0, Int64((seconds * 1_000_000).rounded()))
            return await runAdapterCommand(paths: paths, arguments: ["seek", "\(micros)"])
        case .playbackMode(let mode):
            let shuffleOK = await runAdapterCommand(paths: paths, arguments: ["shuffle", "\(shuffleModeID(for: mode))"])
            let repeatOK = await runAdapterCommand(paths: paths, arguments: ["repeat", "\(repeatModeID(for: mode))"])
            return shuffleOK || repeatOK
        }
    }

    private static func runHealthTest(paths: AdapterPaths) async -> Int32 {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            var arguments = [paths.script, paths.framework]
            if let testClient = paths.testClient {
                arguments.append(testClient)
            }
            arguments.append("test")
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }.value
    }

    private static func runAdapterCommand(paths: AdapterPaths, arguments: [String]) async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [paths.script, paths.framework] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    private func resolveAdapterPaths() -> AdapterPaths? {
        let bundle = Bundle.main
        let script = bundle.path(forResource: "mediaremote-adapter", ofType: "pl")
            ?? "/tmp/mediaremote-adapter/bin/mediaremote-adapter.pl"
        let framework = bundle.path(forResource: "MediaRemoteAdapter", ofType: "framework")
            ?? "/tmp/mediaremote-adapter/build/MediaRemoteAdapter.framework"
        let testClientCandidate = bundle.path(forResource: "MediaRemoteAdapterTestClient", ofType: nil)
            ?? "/tmp/mediaremote-adapter/build/MediaRemoteAdapterTestClient"
        let testClient = FileManager.default.fileExists(atPath: testClientCandidate) ? testClientCandidate : nil

        guard FileManager.default.fileExists(atPath: script),
              FileManager.default.fileExists(atPath: framework) else {
            return nil
        }
        return AdapterPaths(script: script, framework: framework, testClient: testClient)
    }

    private func currentProviderArtworkData() -> Data? {
        guard let encoded = lastPayload?.artworkData, !encoded.isEmpty else { return nil }
        return Data(base64Encoded: encoded)
    }

    private func estimatedCurrentTime(from payload: Payload) -> Double {
        let duration = payload.duration ?? 0
        var elapsed = payload.elapsedTime ?? 0
        if isPayloadPlaying(payload),
           let timestamp = payload.timestamp.flatMap(Self.parseTimestamp) {
            elapsed += Date().timeIntervalSince(timestamp) * max(payload.playbackRate ?? 1, 0)
        }
        if duration > 0 {
            return min(max(elapsed, 0), duration)
        }
        return max(elapsed, 0)
    }

    private func isPayloadPlaying(_ payload: Payload) -> Bool {
        if let playing = payload.playing {
            return playing
        }
        return (payload.playbackRate ?? 0) > 0
    }

    private func playbackMode(from payload: Payload) -> AppleMusicPlaybackMode {
        switch payload.repeatMode {
        case 2:
            return .repeatOne
        case 3:
            return .repeatAll
        default:
            if (payload.shuffleMode ?? 1) > 1 {
                return .shuffle
            }
            return .sequence
        }
    }

    private static func shuffleModeID(for mode: AppleMusicPlaybackMode) -> Int {
        mode == .shuffle ? 3 : 1
    }

    private static func repeatModeID(for mode: AppleMusicPlaybackMode) -> Int {
        switch mode {
        case .sequence, .shuffle:
            return 1
        case .repeatOne:
            return 2
        case .repeatAll:
            return 3
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        SystemNowPlayingDateParsers.iso8601.date(from: value)
            ?? SystemNowPlayingDateParsers.fallback.date(from: value)
    }

    private func closePipes() {
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func cancelRuntimeWork(clearPresentation: Bool) {
        resolutionTask?.cancel()
        resolutionTask = nil
        cancelPerTrackTasks()
        controlTask?.cancel()
        controlTask = nil
        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        emptyPayloadCount = 0
        currentCapabilities = .unavailable
        hasReceivedValidPayload = false
        lastPayload = nil
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
        if clearPresentation {
            transitionConnectionState(to: .disconnected, reason: "stopped")
            presentation = .emptySystemNowPlaying
        }
    }

    private func cancelPerTrackTasks() {
        lyricsTask?.cancel()
        lyricsTask = nil
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func updatePresentationIfNeeded(_ newPresentation: NowPlayingPresentation) {
        guard !newPresentation.isEffectivelyEqual(to: presentation) else { return }
        presentation = newPresentation
    }

    private func transitionConnectionState(to newState: ExternalPlaybackConnectionState, reason: String) {
        guard connectionState != newState else { return }
        let oldState = connectionState
        connectionState = newState
        Log.info(
            "[SystemNowPlaying] connection state \(oldState.rawValue) -> \(newState.rawValue) reason=\(reason)",
            category: .playback
        )
    }

    private func logControlFailureIfNeeded(_ action: ControlAction) {
        let now = Date()
        guard now.timeIntervalSince(lastControlFailureLogAt) > 5 else { return }
        lastControlFailureLogAt = now
        Log.warning("[SystemNowPlaying] control failed: \(String(describing: action))", category: .playback)
    }

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
}

private enum SystemNowPlayingDateParsers {
    static let iso8601 = ISO8601DateFormatter()

    static let fallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}

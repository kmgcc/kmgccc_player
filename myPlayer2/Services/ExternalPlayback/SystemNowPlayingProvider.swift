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

    nonisolated private struct Payload: Decodable, Equatable, Sendable {
        var bundleIdentifier: String?
        var parentApplicationBundleIdentifier: String?
        var clientBundleIdentifier: String?
        var ownerBundleIdentifier: String?
        var applicationBundleIdentifier: String?
        var processIdentifier: Int?
        var pid: Int?
        var playing: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsedTime: Double?
        var elapsedTimeNow: Double?
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
            clientBundleIdentifier != nil ||
            ownerBundleIdentifier != nil ||
            applicationBundleIdentifier != nil ||
            processIdentifier != nil ||
            pid != nil ||
            playing != nil ||
            title != nil ||
            artist != nil ||
            album != nil ||
            duration != nil ||
            elapsedTime != nil ||
            elapsedTimeNow != nil ||
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

    private struct StableMetadataKey: Equatable, Sendable {
        var identifier: String?
        var title: String
        var artist: String
        var album: String?
        var duration: Double
        var playing: Bool
        var playbackRate: Double

        var trackIdentity: String {
            if let identifier {
                return "id:\(identifier)"
            }
            return [
                "title:\(title)",
                "artist:\(artist)",
                "album:\(album ?? "")",
                "duration:\(duration)"
            ].joined(separator: "|")
        }
    }

    private struct ProgressBaseline: Equatable, Sendable {
        var baseElapsedTime: Double
        var baseTimestamp: Date
        var playbackRate: Double
        var isPlaying: Bool
        var duration: Double

        func estimatedTime(at now: Date = Date()) -> Double {
            let runningDelta = isPlaying ? now.timeIntervalSince(baseTimestamp) * max(playbackRate, 0) : 0
            let value = max(baseElapsedTime + runningDelta, 0)
            if duration > 0 {
                return min(value, duration)
            }
            return value
        }
    }

    private struct ControlRollbackState {
        var payload: Payload?
        var stableKey: StableMetadataKey?
        var baseline: ProgressBaseline?
        var presentation: NowPlayingPresentation
    }

    private enum ReliabilityState: String, Sendable {
        case reliable
        case stale
        case inconsistent
        case unavailable
    }

    private enum PayloadSource: String, Sendable, Hashable {
        case stream
        case get
    }

    private struct PayloadObservation: Sendable {
        var source: PayloadSource
        var payload: Payload
        var stableKey: StableMetadataKey
        var core: String?
        var receivedAt: Date
    }

    private struct PendingStableCandidate {
        var core: String
        var payload: Payload
        var stableKey: StableMetadataKey
        var firstSeenAt: Date
        var lastSeenAt: Date
        var confirmations: Int
        var sources: Set<PayloadSource>
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
    private let systemProgressDisplayDelay: TimeInterval = 0.5
    private let blockedExternalOwnerPrefixes = [
        "com.apple.safari",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.browser",
        "com.operasoftware.opera"
    ]

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var streamGeneration: UInt64 = 0
    private var isStarting = false
    private var healthState: HealthState = .unknown
    private var healthTask: Task<Void, Never>?
    private var lastPayload: Payload?
    private var latestStableMetadataKey: StableMetadataKey?
    private var progressBaseline: ProgressBaseline?
    private var latestIdentity: String?
    private var latestRawMetadata: ExternalPlaybackRawMetadata?
    private var resolvedRawMetadata: ExternalPlaybackRawMetadata?
    private var resolvedTrackIdentity: String?
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
    private var progressPollTask: Task<Void, Never>?
    private var pendingEmptyPayloadTask: Task<Void, Never>?
    private var streamObservationTask: Task<Void, Never>?
    private var pendingHeavyPresentationTask: Task<Void, Never>?
    private var controlCooldownTask: Task<Void, Never>?
    private var unidentifiedTrackCandidateTask: Task<Void, Never>?
    private var lyricsSearchTimestamps: [String: Date] = [:]
    private var connectionState: ExternalPlaybackConnectionState = .disconnected
    private var lastControlFailureLogAt: Date = .distantPast
    private var emptyPayloadCount = 0
    private var lastControlSentAt: [String: Date] = [:]
    private var currentCapabilities: ExternalPlaybackCapabilities = .unavailable
    private var hasReceivedValidPayload = false
    private var hasLoggedFirstValidPayload = false
    private var isInEmptyPayloadWindow = false
    private var lastHeavyPresentationUpdateAt: Date = .distantPast
    private var controlCooldownUntil: Date = .distantPast
    private var optimisticPlayingState: Bool?
    private var controlGeneration: UInt64 = 0
    private var pendingUnidentifiedPayload: Payload?
    private var pendingUnidentifiedKey: StableMetadataKey?
    private var isCommittingUnidentifiedCandidate = false
    private var cachedAdapterPaths: AdapterPaths?
    private var hasLoggedAdapterResolution = false
    private var reliability: ReliabilityState = .unavailable
    private var lastValidPayloadAt: Date?
    private var lastReliablePayloadAt: Date?
    private var lastStreamObservation: PayloadObservation?
    private var lastGetObservation: PayloadObservation?
    private var lastSnapshotLogAt: [PayloadSource: Date] = [:]
    private var consecutiveEmptyGetCount = 0
    private var pendingStableCandidate: PendingStableCandidate?
    private var pendingStableCommitTask: Task<Void, Never>?
    private var controlFailureCounts: [String: Int] = [:]
    private var controlDisabledUntil: [String: Date] = [:]
    private var ignoredSelfOwnedPayloadCount = 0
    private var consecutiveSelfOwnedPayloadCount = 0
    private var lastSelfOwnedPayloadLogAt: [PayloadSource: Date] = [:]
    private var acceptedExternalPayloadCount = 0
    private var activeExternalOwnerBundle: String?
    private var hasLoggedSelfBundleID = false
    private var lockedExternalOwner: String?
    private var lockedExternalOwnerSince: Date?
    private var lastNonLockedOwnerLogAt: [String: Date] = [:]
    private var lastBlockedOwnerLogAt: [String: Date] = [:]
    private var hasLoggedProgressDisplayOffset = false
    private var lastControlAction: ControlAction?
    private var controlIssuedAt: Date?
    private var suppressStateRollbackUntil: Date?
    private var expectedPostControlPlaying: Bool?
    private var expectedPostControlCore: String?
    private var expectedPostControlSeek: Double?
    private var preControlCore: String?
    private var lastCommittedCore: String?
    private var recentRetiredCores: [String: Date] = [:]
    private var suppressedPreControlCores: [String: Date] = [:]
    private var preControlRestoreTask: Task<Void, Never>?
    private var lastRetiredCoreLogAt: [String: Date] = [:]
    private var lastSuppressedRollbackLogAt: [String: Date] = [:]
    private var lastPausedStableRetainedLogAt: Date = .distantPast
    private var lastPausedEmptyIgnoredLogAt: Date = .distantPast
    private var isInvalidatingCurrentResolution = false

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
        invalidateAdapterPathCache()
        guard let paths = resolveAdapterPaths() else {
            Log.warning("[SystemNowPlaying] adapter paths missing; stream not started", category: .playback)
            updateUnavailablePresentation(titleKey: "system_now_playing.adapter_unavailable", connectionState: .unavailable)
            return
        }

        isStarting = true
        streamGeneration &+= 1
        let generation = streamGeneration
        hasReceivedValidPayload = false
        hasLoggedFirstValidPayload = false
        isInEmptyPayloadWindow = false
        latestStableMetadataKey = nil
        progressBaseline = nil
        lastCommittedCore = nil
        recentRetiredCores.removeAll()
        suppressedPreControlCores.removeAll()
        preControlRestoreTask?.cancel()
        preControlRestoreTask = nil
        optimisticPlayingState = nil
        controlCooldownUntil = .distantPast
        clearControlExpectation()
        unlockExternalOwner(reason: "provider_start")
        clearReliabilityTracking(to: .unavailable)
        logSelfBundleIDIfNeeded()
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
        startProgressPolling(generation: generation)
    }

    func stop() {
        Log.info("[SystemNowPlaying] stopping stream", category: .playback)
        streamGeneration &+= 1
        unlockExternalOwner(reason: "provider_stop")
        isStarting = false
        healthTask?.cancel()
        healthTask = nil
        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        pendingHeavyPresentationTask?.cancel()
        pendingHeavyPresentationTask = nil
        controlCooldownTask?.cancel()
        controlCooldownTask = nil
        preControlRestoreTask?.cancel()
        preControlRestoreTask = nil
        unidentifiedTrackCandidateTask?.cancel()
        unidentifiedTrackCandidateTask = nil
        progressPollTask?.cancel()
        progressPollTask = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        closePipes()
        cancelRuntimeWork(clearPresentation: true)
        invalidateAdapterPathCache()
    }

    func tickPresentation() {
        updateProgressPresentationFromBaseline()
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
        resolvedTrackIdentity = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = latestIdentity
        guard let raw = latestRawMetadata,
              let identity = latestIdentity else {
            handlePayload(lastPayload, source: .stream)
            return
        }
        isInvalidatingCurrentResolution = true
        updatePresentationFromLatestPayload(force: true)
        startResolutionIfNeeded(raw: raw, identity: identity)
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
        do {
            let envelope = try decoder.decode(StreamEnvelope.self, from: data)
            guard envelope.type == "data", envelope.diff == false else { return }
            handlePayload(envelope.payload, source: .stream)
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

    private func startProgressPolling(generation: UInt64) {
        progressPollTask?.cancel()
        progressPollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.currentPollInterval() ?? 1_000_000_000 }
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                guard let self else { break }
                let (genMatch, paths) = await MainActor.run { () -> (Bool, AdapterPaths?) in
                    (self.streamGeneration == generation, self.resolveAdapterPaths())
                }
                guard genMatch else { break }
                guard let paths else { continue }
                guard let payload = await Self.fetchGetPayload(paths: paths) else {
                    await MainActor.run {
                        guard self.streamGeneration == generation else { return }
                        self.handleEmptyPayload(source: .get)
                    }
                    continue
                }
                await MainActor.run {
                    guard self.streamGeneration == generation else { return }
                    self.handlePayload(payload, source: .get)
                }
            }
        }
    }

    private func currentPollInterval() -> UInt64 {
        if isControlCoolingDown {
            return 500_000_000
        }
        if reliability == .reliable {
            return 700_000_000
        }
        return 1_000_000_000
    }

    private func handlePayload(_ payload: Payload?, source: PayloadSource) {
        guard let payload, payload.hasAnyValue else {
            handleEmptyPayload(source: source)
            return
        }

        if isSelfOwnedPayload(payload) {
            handleSelfOwnedPayload(payload, source: source)
            return
        }
        if shouldIgnoreExternalOwner(payload, source: source) {
            return
        }

        let mergedPayload = mergePayload(payload)
        if isSelfOwnedPayload(mergedPayload) {
            handleSelfOwnedPayload(mergedPayload, source: source)
            return
        }
        if shouldIgnoreExternalOwner(mergedPayload, source: source) {
            return
        }

        guard let title = mergedPayload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            handleEmptyPayload(source: source)
            return
        }

        if shouldIgnorePayloadDuringControlCooldown(mergedPayload) {
            return
        }

        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = nil
        streamObservationTask?.cancel()
        streamObservationTask = nil
        emptyPayloadCount = 0
        if isInEmptyPayloadWindow {
            isInEmptyPayloadWindow = false
            Log.info("[SystemNowPlaying] empty payload window exited", category: .playback)
        }
        if source == .get {
            consecutiveEmptyGetCount = 0
        }
        consecutiveSelfOwnedPayloadCount = 0

        let stableKey = stableMetadataKey(for: mergedPayload, title: title)
        if shouldIgnoreSuppressedCore(stableKey.identifier, source: source) {
            return
        }
        let observation = recordValidObservation(
            source: source,
            payload: mergedPayload,
            stableKey: stableKey
        )
        let previousStableKey = latestStableMetadataKey
        let didChangeTrack = previousStableKey?.trackIdentity != stableKey.trackIdentity
        if shouldDeferUnidentifiedTrackChange(stableKey: stableKey, didChangeTrack: didChangeTrack) {
            deferUnidentifiedTrackCandidate(payload: mergedPayload, stableKey: stableKey)
            return
        }
        if stableKey.identifier != nil || pendingUnidentifiedKey == stableKey {
            clearUnidentifiedTrackCandidate()
        }
        hasReceivedValidPayload = true
        if !hasLoggedFirstValidPayload {
            hasLoggedFirstValidPayload = true
            Log.info("[SystemNowPlaying] first valid payload title=\(title) artist=\(mergedPayload.artist ?? "")", category: .playback)
        }
        transitionConnectionState(to: .runningHasData, reason: "valid now playing data")

        if let stableCore = previousStableKey?.identifier,
           stableKey.identifier == stableCore {
            applyCommittedPayloadUpdate(
                mergedPayload,
                stableKey: stableKey,
                source: source,
                forceProgress: progressBaseline == nil
            )
            resolveCooldownIfOptimisticMatches(incomingPlaying: isPayloadPlaying(mergedPayload))
            return
        }

        if previousStableKey == nil {
            handlePendingStableCandidate(observation)
            return
        }

        handlePendingStableCandidate(observation)
    }

    private func commitStablePayload(
        _ payload: Payload,
        stableKey: StableMetadataKey,
        source: PayloadSource,
        reason: String
    ) {
        guard let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }

        pendingStableCandidate = nil
        pendingStableCommitTask?.cancel()
        pendingStableCommitTask = nil
        setReliability(.reliable, reason: reason)
        lockExternalOwnerIfNeeded(from: payload, reason: reason)

        let previousStableKey = latestStableMetadataKey
        let didChangeTrack = previousStableKey?.trackIdentity != stableKey.trackIdentity
        let didChangeStableMetadata = previousStableKey != stableKey
        if didChangeTrack {
            retireCommittedCore(previousStableKey?.identifier, replacing: stableKey.identifier)
            clearCoreSuppression(for: stableKey.identifier)
            lastCommittedCore = stableKey.identifier
        }
        lastPayload = payload
        latestStableMetadataKey = stableKey
        updateProgressBaselineIfNeeded(
            from: payload,
            stableKey: stableKey,
            force: didChangeTrack || progressBaseline == nil,
            source: source
        )
        if stableKey.playing == false {
            logPausedStableTrackRetainedIfNeeded()
        }

        // Deliberately avoid using the upstream uniqueIdentifier / contentItemIdentifier as the
        // persistentID. For the system-now-playing source those fields are frequently rotated
        // by the upstream app (a fresh UUID per stream event), which would make the track
        // identity unstable and trigger repeated lyrics/artwork/presentation rebuilds. We use
        // the semantic key derived above so identity is stable across events for the same song.
        let raw = ExternalPlaybackRawMetadata(
            source: self.source,
            persistentID: stableKey.identifier,
            title: title,
            artist: payload.artist ?? "",
            album: payload.album,
            duration: payload.duration ?? 0
        )
        let identity = raw.stableKey
        if didChangeTrack {
            Log.info("[SystemNowPlaying] identity changed \(latestIdentity ?? "nil") -> \(identity)", category: .playback)
            cancelPerTrackTasks()
            resolutionTask?.cancel()
            resolutionTask = nil
            latestIdentity = identity
            resolvedRawMetadata = nil
            resolvedTrackIdentity = nil
            latestEffectiveMetadata = nil
            latestMatchResult = nil
            latestMatchedTrack = nil
            resolvedLyricsText = nil
            autoLyricsLookupState = .idle
            displayedArtwork = .none
            pendingArtworkIdentity = identity
        }

        latestRawMetadata = raw
        if didChangeTrack {
            resolveControlConvergenceAfterTrackChange(newCore: stableKey.identifier)
            // Track identity path: presentation refresh + (gated) resolve.
            updatePresentationFromLatestPayload(force: true)
            if reliability == .reliable {
                startResolutionIfNeeded(raw: raw, identity: identity)
            }
        } else if didChangeStableMetadata {
            // Playback state / metadata fill-in path: presentation only, no resolve.
            Log.debug("[SystemNowPlaying] playback state update isPlaying=\(stableKey.playing) rate=\(stableKey.playbackRate) duration=\(stableKey.duration)", category: .playback)
            updatePresentationFromLatestPayload(force: false)
        } else {
            updateProgressPresentationFromBaseline()
        }
    }

    private func applyCommittedPayloadUpdate(
        _ payload: Payload,
        stableKey: StableMetadataKey,
        source: PayloadSource,
        forceProgress: Bool
    ) {
        let didChangeStableMetadata = latestStableMetadataKey != stableKey
        lastPayload = payload
        latestStableMetadataKey = stableKey
        if reliability == .reliable || stableKey.playing == false {
            updateProgressBaselineIfNeeded(
                from: payload,
                stableKey: stableKey,
                force: forceProgress || stableKey.playing == false,
                source: source
            )
            if stableKey.playing == false {
                logPausedStableTrackRetainedIfNeeded()
            }
        } else {
            freezeProgressBaseline(reason: "unreliable same-track update")
        }

        if let raw = latestRawMetadata {
            latestRawMetadata = ExternalPlaybackRawMetadata(
                source: self.source,
                persistentID: stableKey.identifier,
                title: nonEmpty(payload.title) ?? raw.title,
                artist: payload.artist ?? raw.artist,
                album: payload.album ?? raw.album,
                duration: payload.duration ?? raw.duration
            )
        }

        if didChangeStableMetadata {
            Log.debug("[SystemNowPlaying] playback state update isPlaying=\(stableKey.playing) rate=\(stableKey.playbackRate) duration=\(stableKey.duration)", category: .playback)
            updatePresentationFromLatestPayload(force: false)
        } else {
            updateProgressPresentationFromBaseline()
        }

        resolveCooldownIfOptimisticMatches(incomingPlaying: stableKey.playing)
    }

    private func recordValidObservation(
        source: PayloadSource,
        payload: Payload,
        stableKey: StableMetadataKey
    ) -> PayloadObservation {
        let now = Date()
        lastValidPayloadAt = now
        let observation = PayloadObservation(
            source: source,
            payload: payload,
            stableKey: stableKey,
            core: stableKey.identifier,
            receivedAt: now
        )
        switch source {
        case .stream:
            lastStreamObservation = observation
        case .get:
            lastGetObservation = observation
        }
        logAcceptedExternalPayload(payload, source: source)
        updateReliability(with: observation)
        logSnapshotIfNeeded(observation)
        return observation
    }

    private func handleSelfOwnedPayload(_ payload: Payload, source: PayloadSource) {
        ignoredSelfOwnedPayloadCount += 1
        consecutiveSelfOwnedPayloadCount += 1
        logIgnoredSelfOwnedPayloadIfNeeded(payload, source: source)
        if latestIdentity == nil {
            updateUnavailablePresentation(
                titleKey: "system_now_playing.connected_empty",
                connectionState: .connectedNoMetadata
            )
        } else {
            setReliability(.stale, reason: "self_owned_payload_only count=\(consecutiveSelfOwnedPayloadCount)")
            freezeProgressBaseline(reason: "ignored self-owned payload")
            updateProgressPresentationFromBaseline()
        }
    }

    private func isSelfOwnedPayload(_ payload: Payload) -> Bool {
        let selfBundleID = Self.selfBundleID
        for owner in ownerBundleCandidates(for: payload) {
            guard owner == selfBundleID else { continue }
            return true
        }
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)
        if payload.processIdentifier == selfPID || payload.pid == selfPID {
            return true
        }
        return false
    }

    private func ownerBundleCandidates(for payload: Payload) -> [String] {
        [
            nonEmpty(payload.bundleIdentifier),
            nonEmpty(payload.parentApplicationBundleIdentifier),
            nonEmpty(payload.clientBundleIdentifier),
            nonEmpty(payload.ownerBundleIdentifier),
            nonEmpty(payload.applicationBundleIdentifier)
        ]
        .compactMap { $0?.lowercased() }
    }

    private func rawOwnerBundle(for payload: Payload) -> String? {
        ownerBundleCandidates(for: payload).first
    }

    private func shouldIgnoreExternalOwner(_ payload: Payload, source: PayloadSource) -> Bool {
        guard let owner = effectiveExternalBundleId(for: payload) else {
            if let lockedExternalOwner {
                if isSameCoreAsStablePayload(payload) {
                    return false
                }
                logIgnoredNonLockedOwnerIfNeeded(incoming: "unknown", locked: lockedExternalOwner, source: source)
                return true
            }
            return false
        }

        if isBlockedExternalOwner(owner) {
            logIgnoredBlockedOwnerIfNeeded(owner: owner, source: source)
            return true
        }

        if let lockedExternalOwner, owner != lockedExternalOwner {
            logIgnoredNonLockedOwnerIfNeeded(incoming: owner, locked: lockedExternalOwner, source: source)
            return true
        }

        return false
    }

    private func isBlockedExternalOwner(_ owner: String) -> Bool {
        let lowercased = owner.lowercased()
        return blockedExternalOwnerPrefixes.contains { lowercased.hasPrefix($0) }
    }

    private func lockExternalOwnerIfNeeded(from payload: Payload, reason: String) {
        guard lockedExternalOwner == nil,
              let owner = effectiveExternalBundleId(for: payload),
              !isBlockedExternalOwner(owner) else { return }
        lockedExternalOwner = owner
        lockedExternalOwnerSince = Date()
        Log.info("[SystemNowPlaying] owner locked=\(owner) reason=\(reason)", category: .playback)
    }

    private func unlockExternalOwner(reason: String) {
        guard let owner = lockedExternalOwner else { return }
        lockedExternalOwner = nil
        lockedExternalOwnerSince = nil
        lastNonLockedOwnerLogAt.removeAll()
        Log.info("[SystemNowPlaying] owner unlocked reason=\(reason) owner=\(owner)", category: .playback)
    }

    private func logIgnoredSelfOwnedPayloadIfNeeded(_ payload: Payload, source: PayloadSource) {
        let now = Date()
        if let last = lastSelfOwnedPayloadLogAt[source],
           now.timeIntervalSince(last) < 1 {
            return
        }
        lastSelfOwnedPayloadLogAt[source] = now
        Log.warning(
            "[SystemNowPlaying] ignored self-owned payload source=\(source.rawValue) bundle=\(nonEmpty(payload.bundleIdentifier) ?? "nil") parent=\(nonEmpty(payload.parentApplicationBundleIdentifier) ?? "nil") title=\(nonEmpty(payload.title) ?? "") count=\(ignoredSelfOwnedPayloadCount)",
            category: .playback
        )
    }

    private func logIgnoredNonLockedOwnerIfNeeded(incoming: String, locked: String, source: PayloadSource) {
        let key = "\(source.rawValue)|\(incoming)|\(locked)"
        let now = Date()
        if let last = lastNonLockedOwnerLogAt[key],
           now.timeIntervalSince(last) < 1 {
            return
        }
        lastNonLockedOwnerLogAt[key] = now
        Log.warning(
            "[SystemNowPlaying] ignored non-locked owner incoming=\(incoming) locked=\(locked) source=\(source.rawValue)",
            category: .playback
        )
    }

    private func logIgnoredBlockedOwnerIfNeeded(owner: String, source: PayloadSource) {
        let key = "\(source.rawValue)|\(owner)"
        let now = Date()
        if let last = lastBlockedOwnerLogAt[key],
           now.timeIntervalSince(last) < 1 {
            return
        }
        lastBlockedOwnerLogAt[key] = now
        Log.warning("[SystemNowPlaying] ignored blocked owner=\(owner) source=\(source.rawValue)", category: .playback)
    }

    private func logAcceptedExternalPayload(_ payload: Payload, source: PayloadSource) {
        acceptedExternalPayloadCount += 1
        let owner = effectiveExternalBundleId(for: payload) ?? lockedExternalOwner ?? rawOwnerBundle(for: payload) ?? "unknown"
        if activeExternalOwnerBundle != owner {
            activeExternalOwnerBundle = owner
            Log.info(
                "[SystemNowPlaying] accepted external payload owner=\(owner) source=\(source.rawValue) active external owner sticky=\(owner)",
                category: .playback
            )
        }
    }

    private func updateReliability(with observation: PayloadObservation) {
        if let reason = recentCrossSourceConflictReason(for: observation) {
            setReliability(.inconsistent, reason: reason)
            return
        }

        if let stableCore = latestStableMetadataKey?.identifier,
           observation.core == stableCore {
            setReliability(.reliable, reason: "confirmed stable core source=\(observation.source.rawValue)")
            return
        }

        if latestStableMetadataKey == nil, reliability == .unavailable {
            setReliability(.stale, reason: "waiting for stable confirmation")
        }
    }

    private func recentCrossSourceConflictReason(for observation: PayloadObservation) -> String? {
        let other: PayloadObservation?
        switch observation.source {
        case .stream:
            other = lastGetObservation
        case .get:
            other = lastStreamObservation
        }
        guard let other,
              observation.receivedAt.timeIntervalSince(other.receivedAt) <= 2 else {
            return nil
        }

        if let currentCore = observation.core,
           let otherCore = other.core,
           currentCore != otherCore {
            return "stream_get_core_conflict stream=\(lastStreamObservation?.core ?? "nil") get=\(lastGetObservation?.core ?? "nil")"
        }

        if let currentPlaying = playingSignal(for: observation.payload),
           let otherPlaying = playingSignal(for: other.payload),
           currentPlaying != otherPlaying {
            return "stream_get_playing_conflict stream=\(String(describing: playingSignal(for: lastStreamObservation?.payload))) get=\(String(describing: playingSignal(for: lastGetObservation?.payload)))"
        }

        if let currentElapsed = observation.payload.elapsedTime,
           let otherElapsed = other.payload.elapsedTime,
           playingSignal(for: observation.payload) == false,
           playingSignal(for: other.payload) == false {
            let delta = abs(currentElapsed - otherElapsed)
            if delta > 8.0 {
                return "stream_get_elapsed_conflict delta=\(formatTime(delta))"
            }
        }

        if observation.core != nil, observation.core == other.core {
            setReliability(.reliable, reason: "stream_get_consistent core=\(observation.core ?? "nil")")
        }
        return nil
    }

    private func handlePendingStableCandidate(_ observation: PayloadObservation) {
        guard let core = observation.core else { return }
        let now = observation.receivedAt

        if var pending = pendingStableCandidate {
            if pending.core == core {
                pending.payload = observation.payload
                pending.stableKey = observation.stableKey
                pending.lastSeenAt = now
                pending.confirmations += 1
                pending.sources.insert(observation.source)
                pendingStableCandidate = pending
                if pending.confirmations >= 2 {
                    guard !hasRecentCrossSourceCoreConflict(for: core) else {
                        setReliability(.inconsistent, reason: "pending confirmation saw cross-source conflict core=\(core)")
                        return
                    }
                    commitStablePayload(
                        pending.payload,
                        stableKey: pending.stableKey,
                        source: observation.source,
                        reason: "pending confirmed core=\(core) confirmations=\(pending.confirmations)"
                    )
                }
                return
            }

            setReliability(.inconsistent, reason: "pending_core_changed old=\(pending.core) new=\(core)")
            pendingStableCandidate = PendingStableCandidate(
                core: core,
                payload: observation.payload,
                stableKey: observation.stableKey,
                firstSeenAt: now,
                lastSeenAt: now,
                confirmations: 1,
                sources: [observation.source]
            )
            schedulePendingStableCommit(core: core)
            return
        }

        pendingStableCandidate = PendingStableCandidate(
            core: core,
            payload: observation.payload,
            stableKey: observation.stableKey,
            firstSeenAt: now,
            lastSeenAt: now,
            confirmations: 1,
            sources: [observation.source]
        )
        schedulePendingStableCommit(core: core)
    }

    private func shouldIgnoreSuppressedCore(_ core: String?, source: PayloadSource) -> Bool {
        guard let core else { return false }
        pruneExpiredCoreSuppressions()

        if let expiry = suppressedPreControlCores[core],
           Date() < expiry {
            logRetiredCoreIgnoredIfNeeded(core: core, source: source)
            return true
        }

        if let expiry = recentRetiredCores[core],
           Date() < expiry,
           core != latestStableMetadataKey?.identifier {
            logRetiredCoreIgnoredIfNeeded(core: core, source: source)
            return true
        }

        return false
    }

    private func retireCommittedCore(_ core: String?, replacing newCore: String?) {
        guard let core,
              core != newCore else { return }
        recentRetiredCores[core] = Date().addingTimeInterval(3)
    }

    private func suppressPreControlCore(_ core: String, action: ControlAction) {
        suppressedPreControlCores[core] = Date().addingTimeInterval(2)
        Log.info("[SystemNowPlaying] suppressed pre-control core=\(core) action=\(action.throttleKey)", category: .playback)
        preControlRestoreTask?.cancel()
        let generation = controlGeneration
        preControlRestoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                guard let self,
                      self.controlGeneration == generation else { return }
                self.suppressedPreControlCores.removeValue(forKey: core)
                guard self.latestStableMetadataKey?.identifier == core,
                      self.expectedPostControlCore == nil else { return }
                Log.info("[SystemNowPlaying] restored pre-control core after no new state core=\(core)", category: .playback)
            }
        }
    }

    private func clearCoreSuppression(for core: String?) {
        guard let core else { return }
        recentRetiredCores.removeValue(forKey: core)
        suppressedPreControlCores.removeValue(forKey: core)
    }

    private func pruneExpiredCoreSuppressions() {
        let now = Date()
        recentRetiredCores = recentRetiredCores.filter { $0.value > now }
        suppressedPreControlCores = suppressedPreControlCores.filter { $0.value > now }
    }

    private func logRetiredCoreIgnoredIfNeeded(core: String, source: PayloadSource) {
        let key = "\(source.rawValue)|\(core)"
        let now = Date()
        if let last = lastRetiredCoreLogAt[key],
           now.timeIntervalSince(last) < 0.8 {
            return
        }
        lastRetiredCoreLogAt[key] = now
        Log.info(
            "[SystemNowPlaying] ignored retired core=\(core) current=\(latestStableMetadataKey?.identifier ?? "nil") source=\(source.rawValue)",
            category: .playback
        )
    }

    private func schedulePendingStableCommit(core: String) {
        pendingStableCommitTask?.cancel()
        let generation = streamGeneration
        pendingStableCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                guard let self,
                      self.streamGeneration == generation,
                      let pending = self.pendingStableCandidate,
                      pending.core == core else { return }
                guard !self.hasRecentCrossSourceCoreConflict(for: core) else {
                    self.setReliability(.inconsistent, reason: "pending timeout saw cross-source conflict core=\(core)")
                    return
                }
                let source: PayloadSource = pending.sources.contains(.get) ? .get : .stream
                guard !self.shouldIgnoreSuppressedCore(core, source: source) else { return }
                self.commitStablePayload(
                    pending.payload,
                    stableKey: pending.stableKey,
                    source: source,
                    reason: "pending unique timeout core=\(core)"
                )
            }
        }
    }

    private func hasRecentCrossSourceCoreConflict(for core: String) -> Bool {
        guard let stream = lastStreamObservation,
              let get = lastGetObservation,
              abs(stream.receivedAt.timeIntervalSince(get.receivedAt)) <= 2,
              let streamCore = stream.core,
              let getCore = get.core else {
            return false
        }
        return streamCore != getCore && (streamCore == core || getCore == core)
    }

    private func refreshReliabilityForAge() {
        guard let lastValidPayloadAt else { return }
        let age = Date().timeIntervalSince(lastValidPayloadAt)
        if lockedExternalOwner != nil, age > 30 {
            unlockExternalOwner(reason: "locked_owner_timeout age=\(formatTime(age))s")
        }
        guard reliability != .unavailable else { return }
        if age > 3 {
            setReliability(.stale, reason: "no_valid_state_for=\(formatTime(age))s")
        }
    }

    private func setReliability(_ newState: ReliabilityState, reason: String) {
        guard reliability != newState else { return }
        let oldState = reliability
        reliability = newState
        if newState == .reliable {
            lastReliablePayloadAt = Date()
        } else {
            freezeProgressBaseline(reason: reason)
            resolutionTask?.cancel()
            resolutionTask = nil
            cancelPerTrackTasks()
            pendingArtworkIdentity = nil
        }
        Log.info(
            "[SystemNowPlaying] reliability changed old=\(oldState.rawValue) new=\(newState.rawValue) reason=\(reason)",
            category: .playback
        )
        refreshCapabilitiesFromLatestPayload()
    }

    private func freezeProgressBaseline(reason: String) {
        guard var baseline = progressBaseline else { return }
        let frozenElapsed = baseline.estimatedTime()
        guard baseline.isPlaying || baseline.playbackRate != 0 || abs(baseline.baseElapsedTime - frozenElapsed) > 0.05 else {
            return
        }
        baseline.baseElapsedTime = frozenElapsed
        baseline.baseTimestamp = Date()
        baseline.playbackRate = 0
        baseline.isPlaying = false
        progressBaseline = baseline
        Log.debug("[SystemNowPlaying] progress frozen reason=\(reason) elapsed=\(formatTime(frozenElapsed)) reliability=\(reliability.rawValue)", category: .playback)
    }

    private func logSnapshotIfNeeded(_ observation: PayloadObservation) {
        let now = Date()
        if let last = lastSnapshotLogAt[observation.source],
           now.timeIntervalSince(last) < 1 {
            return
        }
        lastSnapshotLogAt[observation.source] = now
        let payload = observation.payload
        let timestampAge = payload.timestamp.flatMap(Self.parseTimestamp).map { max(now.timeIntervalSince($0), 0) } ?? now.timeIntervalSince(observation.receivedAt)
        let ownerPID = payload.processIdentifier ?? payload.pid ?? Int(process?.processIdentifier ?? 0)
        Log.info(
            "[SystemNowPlaying] snapshot source=\(observation.source.rawValue) core=\(observation.core ?? "nil") title=\(nonEmpty(payload.title) ?? "") artist=\(nonEmpty(payload.artist) ?? "") playing=\(String(describing: playingSignal(for: payload))) rate=\(formatTime(payload.playbackRate ?? 0)) elapsed=\(formatTime(payload.elapsedTime ?? -1)) duration=\(formatTime(payload.duration ?? -1)) bundle=\(nonEmpty(payload.bundleIdentifier) ?? "nil") parent=\(nonEmpty(payload.parentApplicationBundleIdentifier) ?? "nil") pid=\(ownerPID) age=\(formatTime(timestampAge)) reliability=\(reliability.rawValue)",
            category: .playback
        )
    }

    private func handleEmptyPayload(source: PayloadSource = .stream) {
        emptyPayloadCount += 1
        refreshReliabilityForAge()
        if isPausedStableTrackActive {
            if source == .get {
                consecutiveEmptyGetCount = 0
            }
            logPausedEmptyIgnoredIfNeeded()
            setReliability(.stale, reason: "empty_payload_while_paused_stable source=\(source.rawValue)")
            freezeProgressBaseline(reason: "empty payload while paused stable track active")
            updateProgressPresentationFromBaseline()
            return
        }
        if source == .get {
            consecutiveEmptyGetCount += 1
            if consecutiveEmptyGetCount >= 3 {
                setReliability(.unavailable, reason: "consecutive_empty_get=\(consecutiveEmptyGetCount)")
                freezeProgressBaseline(reason: "empty get unavailable")
            }
        }
        if isControlCoolingDown {
            return
        }
        if !isInEmptyPayloadWindow {
            isInEmptyPayloadWindow = true
            Log.info("[SystemNowPlaying] empty payload window entered", category: .playback)
        }

        guard latestIdentity != nil else {
            return
        }

        let generation = streamGeneration
        let clearDelay: TimeInterval = lockedExternalOwner != nil ? 30 : 15
        pendingEmptyPayloadTask?.cancel()
        pendingEmptyPayloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(clearDelay * 1_000_000_000))
            await MainActor.run {
                guard let self,
                      self.streamGeneration == generation,
                      self.emptyPayloadCount > 0 else { return }
                Log.info("[SystemNowPlaying] long-empty clear triggered", category: .playback)
                self.clearTemporarilyUnavailable()
            }
        }
    }

    private var isPausedStableTrackActive: Bool {
        guard latestStableMetadataKey != nil,
              latestIdentity != nil,
              presentation.source == source,
              presentation.hasTrack else { return false }
        if progressBaseline?.isPlaying == false {
            return true
        }
        if latestStableMetadataKey?.playing == false {
            return true
        }
        return false
    }

    private func logPausedEmptyIgnoredIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPausedEmptyIgnoredLogAt) >= 1 else { return }
        lastPausedEmptyIgnoredLogAt = now
        Log.info("[SystemNowPlaying] empty payload ignored while paused stable track active", category: .playback)
    }

    private func logPausedStableTrackRetainedIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPausedStableRetainedLogAt) >= 1 else { return }
        lastPausedStableRetainedLogAt = now
        Log.info("[SystemNowPlaying] paused stable track retained", category: .playback)
    }

    private func clearTemporarilyUnavailable() {
        lastPayload = nil
        latestStableMetadataKey = nil
        lastCommittedCore = nil
        recentRetiredCores.removeAll()
        suppressedPreControlCores.removeAll()
        preControlRestoreTask?.cancel()
        preControlRestoreTask = nil
        progressBaseline = nil
        isInEmptyPayloadWindow = false
        clearReliabilityTracking(to: .stale)
        latestIdentity = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        resolvedTrackIdentity = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = nil
        isInvalidatingCurrentResolution = false
        resolutionTask?.cancel()
        resolutionTask = nil
        updateUnavailablePresentation(titleKey: "system_now_playing.connected_empty", connectionState: .connectedNoMetadata)
    }

    private func clearReliabilityTracking(to state: ReliabilityState = .unavailable) {
        reliability = state
        lastValidPayloadAt = nil
        lastReliablePayloadAt = nil
        lastStreamObservation = nil
        lastGetObservation = nil
        lastSnapshotLogAt.removeAll()
        consecutiveEmptyGetCount = 0
        consecutiveSelfOwnedPayloadCount = 0
        activeExternalOwnerBundle = nil
        pendingStableCandidate = nil
        pendingStableCommitTask?.cancel()
        pendingStableCommitTask = nil
    }

    private func mergePayload(_ payload: Payload) -> Payload {
        guard let previous = lastPayload, shouldMergePayload(previous: previous, incoming: payload) else {
            return payload
        }
        var merged = payload
        merged.bundleIdentifier = nonEmpty(merged.bundleIdentifier) ?? previous.bundleIdentifier
        merged.parentApplicationBundleIdentifier = nonEmpty(merged.parentApplicationBundleIdentifier) ?? previous.parentApplicationBundleIdentifier
        merged.clientBundleIdentifier = nonEmpty(merged.clientBundleIdentifier) ?? previous.clientBundleIdentifier
        merged.ownerBundleIdentifier = nonEmpty(merged.ownerBundleIdentifier) ?? previous.ownerBundleIdentifier
        merged.applicationBundleIdentifier = nonEmpty(merged.applicationBundleIdentifier) ?? previous.applicationBundleIdentifier
        merged.processIdentifier = merged.processIdentifier ?? previous.processIdentifier
        merged.pid = merged.pid ?? previous.pid
        merged.title = nonEmpty(merged.title) ?? previous.title
        merged.artist = nonEmpty(merged.artist) ?? previous.artist
        merged.album = nonEmpty(merged.album) ?? previous.album
        merged.duration = merged.duration ?? previous.duration
        merged.elapsedTime = merged.elapsedTime ?? previous.elapsedTime
        merged.elapsedTimeNow = merged.elapsedTimeNow ?? previous.elapsedTimeNow
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

    // NOTE: Identity is split into two layers:
    //   1) `trackCoreIdentity(for:)` — a minimal, high-confidence key derived only from
    //      normalized(title) + normalized(artist). THIS is what drives "did the track
    //      change?" / lyrics / artwork / resolve. Album, duration and bundle are intentionally
    //      NOT part of the core key, because any of them can briefly drop out or jitter
    //      between events. A real track change is only declared when title or artist
    //      actually flip to another non-empty value.
    //   2) `effectiveExternalBundleId(for:)` — the *external* app's bundle, with our own
    //      app bundle filtered out (MediaRemote sometimes attributes the now-playing session
    //      to the caller, which would otherwise make the same song look like it's coming
    //      from a different app).
    // The old full "semantic" key (bundle|title|artist|album|duration) is still emitted as
    // an identity string for cache/lyrics/artwork lookup, but it is frozen at the moment we
    // confirm a track change and does not flip mid-track just because album/duration/bundle
    // drifted.
    private static let selfBundleID: String = (Bundle.main.bundleIdentifier ?? "kmgccc.player").lowercased()

    private func logSelfBundleIDIfNeeded() {
        guard !hasLoggedSelfBundleID else { return }
        hasLoggedSelfBundleID = true
        Log.info("[SystemNowPlaying] selfBundleId=\(Self.selfBundleID)", category: .playback)
    }

    private func providerIdentity(for payload: Payload) -> String? {
        trackCoreIdentity(for: payload)
    }

    private func trackCoreIdentity(for payload: Payload) -> String? {
        let title = ExternalPlaybackTextNormalizer.normalizedKey(nonEmpty(payload.title))
        let artist = ExternalPlaybackTextNormalizer.normalizedKey(nonEmpty(payload.artist))
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        return "core|t=\(title)|a=\(artist)"
    }

    private func effectiveExternalBundleId(for payload: Payload) -> String? {
        let candidates: [String?] = [
            nonEmpty(payload.bundleIdentifier),
            nonEmpty(payload.parentApplicationBundleIdentifier),
            nonEmpty(payload.clientBundleIdentifier),
            nonEmpty(payload.ownerBundleIdentifier),
            nonEmpty(payload.applicationBundleIdentifier)
        ]
        for candidate in candidates {
            guard let raw = candidate?.lowercased(), !raw.isEmpty, raw != Self.selfBundleID else { continue }
            return raw
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private func stableMetadataKey(for payload: Payload, title: String? = nil) -> StableMetadataKey {
        StableMetadataKey(
            identifier: providerIdentity(for: payload),
            title: title ?? nonEmpty(payload.title) ?? "",
            artist: nonEmpty(payload.artist) ?? "",
            album: nonEmpty(payload.album),
            duration: normalizedTime(payload.duration ?? 0),
            playing: isPayloadPlaying(payload),
            playbackRate: normalizedTime(payload.playbackRate ?? (isPayloadPlaying(payload) ? 1 : 0))
        )
    }

    private func normalizedTime(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private func shouldDeferUnidentifiedTrackChange(
        stableKey: StableMetadataKey,
        didChangeTrack: Bool
    ) -> Bool {
        guard !isCommittingUnidentifiedCandidate else { return false }
        guard didChangeTrack, latestStableMetadataKey != nil else { return false }
        // Defer ONLY when the new payload has no usable core identity at all
        // (both title and artist missing/empty). Any payload with a clear title+artist
        // must be treated as an immediate track change — even if album/duration/bundle
        // haven't filled in yet.
        return stableKey.identifier == nil
    }

    private func deferUnidentifiedTrackCandidate(payload: Payload, stableKey: StableMetadataKey) {
        if pendingUnidentifiedKey == stableKey {
            pendingUnidentifiedPayload = payload
            return
        }
        pendingUnidentifiedPayload = payload
        pendingUnidentifiedKey = stableKey
        unidentifiedTrackCandidateTask?.cancel()
        let generation = streamGeneration
        unidentifiedTrackCandidateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                guard let self,
                      self.streamGeneration == generation,
                      self.pendingUnidentifiedKey == stableKey,
                      let payload = self.pendingUnidentifiedPayload else { return }
                self.pendingUnidentifiedPayload = nil
                self.pendingUnidentifiedKey = nil
                self.unidentifiedTrackCandidateTask = nil
                self.isCommittingUnidentifiedCandidate = true
                self.handlePayload(payload, source: .stream)
                self.isCommittingUnidentifiedCandidate = false
            }
        }
    }

    private func clearUnidentifiedTrackCandidate() {
        pendingUnidentifiedPayload = nil
        pendingUnidentifiedKey = nil
        unidentifiedTrackCandidateTask?.cancel()
        unidentifiedTrackCandidateTask = nil
    }

    private func startResolutionIfNeeded(raw: ExternalPlaybackRawMetadata, identity: String) {
        // Guard on core track identity, NOT raw equality. Album/duration/playing/rate
        // fill-ins for the same track must NOT re-resolve metadata, artwork, or lyrics.
        guard resolvedTrackIdentity != identity else { return }
        guard resolutionTask == nil else { return }

        let metadataStore = self.metadataStore
        let libraryTracks = libraryVM.allTracks
        resolutionTask = Task { [weak self] in
            let resolution = await metadataStore.resolve(raw: raw, libraryTracks: libraryTracks)
            await MainActor.run {
                guard let self else { return }
                self.resolutionTask = nil
                guard self.latestIdentity == identity else { return }
                self.applyResolution(resolution, identity: identity)
            }
        }
    }

    private func applyResolution(_ resolution: ExternalPlaybackResolution, identity: String) {
        guard canApplyCurrentResolution(identity: identity) else {
            isInvalidatingCurrentResolution = false
            return
        }
        let didChangeResolvedIdentity = resolvedTrackIdentity != identity
        resolvedRawMetadata = resolution.raw
        resolvedTrackIdentity = identity
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

        // Only re-run artwork / lyrics resolvers when the resolved core identity
        // actually changed. Album/duration fill-ins on the same track don't qualify.
        guard didChangeResolvedIdentity else { return }

        startArtworkResolution(
            identity: identity,
            effective: resolution.effective,
            matchedTrack: resolution.matchedTrack,
            manualOverrideArtwork: metadataStore.cachedArtwork(for: identity, source: "manualOverride"),
            cachedNetworkArtwork: metadataStore.cachedNetworkArtwork(for: identity),
            providerArtwork: currentProviderArtworkData()
        )

        resolveLyricsIfNeeded(
            identity: identity,
            effective: resolution.effective,
            localLyrics: preferredLyricsText(for: resolution.matchedTrack)
        )
    }

    private func canApplyCurrentResolution(identity: String) -> Bool {
        latestIdentity == identity && (reliability == .reliable || isInvalidatingCurrentResolution)
    }

    private func updatePresentationFromLatestPayload(force: Bool = false) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastHeavyPresentationUpdateAt)
        guard force || elapsed >= 0.5 else {
            scheduleHeavyPresentationUpdate(after: 0.5 - elapsed)
            return
        }
        pendingHeavyPresentationTask?.cancel()
        pendingHeavyPresentationTask = nil
        lastHeavyPresentationUpdateAt = now
        publishPresentationFromLatestPayload()
    }

    private func scheduleHeavyPresentationUpdate(after delay: TimeInterval) {
        guard pendingHeavyPresentationTask == nil else { return }
        let generation = streamGeneration
        pendingHeavyPresentationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            await MainActor.run {
                guard let self, self.streamGeneration == generation else { return }
                self.pendingHeavyPresentationTask = nil
                self.lastHeavyPresentationUpdateAt = Date()
                self.publishPresentationFromLatestPayload()
            }
        }
    }

    private func publishPresentationFromLatestPayload() {
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
            duration: progressBaseline?.duration ?? payload.duration ?? 0,
            currentTime: displayCurrentTimeFromBaseline(),
            isPlaying: progressBaseline?.isPlaying ?? isPayloadPlaying(payload),
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
            externalConnectionState: presentationConnectionState,
            isControlEnabled: capabilities.canControlPlayback,
            isSeekEnabled: false,
            isVolumeControlEnabled: capabilities.canSetVolume,
            isPlaybackModeControlEnabled: capabilities.canSetPlaybackMode,
            emptyTitleKey: source.notPlayingTitleKey
        )
        updatePresentationIfNeeded(newPresentation)
    }

    private func updateProgressPresentationFromBaseline() {
        refreshReliabilityForAge()
        guard presentation.source == source,
              presentation.hasTrack,
              progressBaseline != nil else { return }
        var updated = presentation
        updated.currentTime = displayCurrentTimeFromBaseline()
        updated.isPlaying = progressBaseline?.isPlaying ?? updated.isPlaying
        updated.duration = progressBaseline?.duration ?? updated.duration
        updated.externalConnectionState = presentationConnectionState
        updated.isControlEnabled = currentCapabilities.canControlPlayback
        updated.isSeekEnabled = false
        updated.isVolumeControlEnabled = currentCapabilities.canSetVolume
        updated.isPlaybackModeControlEnabled = currentCapabilities.canSetPlaybackMode
        updatePresentationIfNeeded(updated)
    }

    private func updateProgressBaselineIfNeeded(
        from payload: Payload,
        stableKey: StableMetadataKey,
        force: Bool = false,
        source: PayloadSource? = nil
    ) {
        let isPlaying = stableKey.playing
        let playbackRate = stableKey.playbackRate
        let duration = payload.duration ?? progressBaseline?.duration ?? 0
        let incomingElapsed = currentElapsedTime(from: payload) ?? progressBaseline?.estimatedTime() ?? 0
        let incomingTimestamp: Date
        if payload.elapsedTimeNow != nil {
            incomingTimestamp = Date()
        } else {
            incomingTimestamp = payload.timestamp.flatMap(Self.parseTimestamp) ?? Date()
        }
        let localEstimate = progressBaseline?.estimatedTime(at: incomingTimestamp) ?? incomingElapsed
        let correctionDelta = abs(incomingElapsed - localEstimate)
        let shouldCorrectTime = correctionDelta > 0.75
        let shouldUpdateTransport =
            progressBaseline?.isPlaying != isPlaying ||
            normalizedTime(progressBaseline?.playbackRate ?? -1) != playbackRate ||
            normalizedTime(progressBaseline?.duration ?? -1) != normalizedTime(duration)

        guard force || shouldCorrectTime || shouldUpdateTransport else {
            return
        }

        progressBaseline = ProgressBaseline(
            baseElapsedTime: incomingElapsed,
            baseTimestamp: incomingTimestamp,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            duration: duration
        )
        if source == .get, shouldCorrectTime {
            Log.info(
                "[SystemNowPlaying] progress correction source=get local=\(formatTime(localEstimate)) incoming=\(formatTime(incomingElapsed)) delta=\(formatTime(correctionDelta))",
                category: .playback
            )
        }
    }

    private func estimatedCurrentTimeFromBaseline() -> Double {
        progressBaseline?.estimatedTime() ?? 0
    }

    private func displayCurrentTimeFromBaseline() -> Double {
        let estimated = estimatedCurrentTimeFromBaseline()
        guard estimated > 0 else { return 0 }
        if !hasLoggedProgressDisplayOffset {
            hasLoggedProgressDisplayOffset = true
            Log.info("[SystemNowPlaying] progress display delay applied delay=0.5", category: .playback)
        }
        return max(0, estimated - systemProgressDisplayDelay)
    }

    private func capabilities(for payload: Payload) -> ExternalPlaybackCapabilities {
        guard connectionState == .runningHasData,
              reliability != .unavailable else { return .unavailable }
        let hasTrack = nonEmpty(payload.title) != nil
        let playbackControlDisabled =
            isControlKeyTemporarilyDisabled("playPause") ||
            isControlKeyTemporarilyDisabled("play") ||
            isControlKeyTemporarilyDisabled("pause")
        let skipDisabled =
            isControlKeyTemporarilyDisabled("next") &&
            isControlKeyTemporarilyDisabled("previous")
        return ExternalPlaybackCapabilities(
            canControlPlayback: hasTrack && !playbackControlDisabled,
            canSkip: hasTrack && !skipDisabled,
            // mediaremote-adapter seek currently uses global MRMediaRemoteSetElapsedTime
            // and fails to target the visible Control Center session for some players;
            // keep disabled until adapter-level seek is fixed.
            canSeek: false,
            canSetVolume: false,
            canSetPlaybackMode: false
        )
    }

    private var presentationConnectionState: ExternalPlaybackConnectionState {
        if connectionState == .runningHasData, reliability != .reliable {
            return .runningTemporarilyUnavailable
        }
        return connectionState
    }

    private func refreshCapabilitiesFromLatestPayload() {
        guard let lastPayload else {
            currentCapabilities = .unavailable
            return
        }
        currentCapabilities = capabilities(for: lastPayload)
        updateProgressPresentationFromBaseline()
    }

    private func updateUnavailablePresentation(titleKey: String, connectionState: ExternalPlaybackConnectionState) {
        cancelPerTrackTasks()
        pendingHeavyPresentationTask?.cancel()
        pendingHeavyPresentationTask = nil
        if connectionState == .unavailable || connectionState == .disconnected || connectionState == .connectedNoMetadata {
            unlockExternalOwner(reason: "unavailable_presentation state=\(connectionState.rawValue)")
        }
        lastPayload = nil
        latestStableMetadataKey = nil
        lastCommittedCore = nil
        recentRetiredCores.removeAll()
        suppressedPreControlCores.removeAll()
        preControlRestoreTask?.cancel()
        preControlRestoreTask = nil
        progressBaseline = nil
        clearReliabilityTracking(to: connectionState == .unavailable ? .unavailable : .stale)
        latestIdentity = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        resolvedTrackIdentity = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = nil
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
        pendingHeavyPresentationTask?.cancel()
        pendingHeavyPresentationTask = nil
        controlCooldownTask?.cancel()
        controlCooldownTask = nil
        unidentifiedTrackCandidateTask?.cancel()
        unidentifiedTrackCandidateTask = nil
        progressPollTask?.cancel()
        progressPollTask = nil
        emptyPayloadCount = 0
        hasReceivedValidPayload = false
        hasLoggedFirstValidPayload = false
        isInEmptyPayloadWindow = false
        optimisticPlayingState = nil
        controlCooldownUntil = .distantPast
        clearControlExpectation()
        unlockExternalOwner(reason: "disconnected")
        pendingUnidentifiedPayload = nil
        pendingUnidentifiedKey = nil
        isCommittingUnidentifiedCandidate = false
        lastPayload = nil
        latestStableMetadataKey = nil
        progressBaseline = nil
        clearReliabilityTracking(to: .unavailable)
        latestIdentity = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        resolvedTrackIdentity = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = nil
        isInvalidatingCurrentResolution = false
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
        guard canApplyCurrentResolution(identity: identity) else { return }
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
        guard canApplyCurrentResolution(identity: identity) else { return }
        pendingArtworkIdentity = nil
        displayedArtwork = ResolvedArtwork(identity: identity, source: source, data: data, displayTrackID: displayTrackID)
        isInvalidatingCurrentResolution = false
        updatePresentationFromLatestPayload()
    }

    private func commitArtworkResolutionFinishedWithoutArtwork(identity: String) {
        guard canApplyCurrentResolution(identity: identity) else { return }
        pendingArtworkIdentity = nil
        displayedArtwork = .none
        isInvalidatingCurrentResolution = false
        updatePresentationFromLatestPayload()
    }

    private func resolveLyricsIfNeeded(
        identity: String,
        effective: ExternalPlaybackEffectiveMetadata,
        localLyrics: String?
    ) {
        guard canApplyCurrentResolution(identity: identity) else { return }
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
                guard self.canApplyCurrentResolution(identity: identity) else { return }

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
        let rollbackState = ControlRollbackState(
            payload: lastPayload,
            stableKey: latestStableMetadataKey,
            baseline: progressBaseline,
            presentation: presentation
        )
        // Capture pre-command snapshot for later verification.
        let preCore = latestStableMetadataKey?.identifier
        let prePlaying: Bool? = rollbackState.payload.map { isPayloadPlaying($0) }
        controlGeneration &+= 1
        let generation = controlGeneration
        configureControlExpectation(for: action, preCore: preCore, prePlaying: prePlaying)
        enterControlCooldown(for: action)
        applyOptimisticState(for: action)
        logControlSend(action)
        controlTask = Task { [weak self] in
            let success = await Self.performControl(action, paths: paths)
            await MainActor.run {
                guard let self else { return }
                Log.info("[SystemNowPlaying] command process success=\(success) action=\(action)", category: .playback)
                if !success {
                    if self.controlGeneration == generation {
                        self.rollbackOptimisticState(rollbackState)
                    }
                    self.logSeekVerificationUnavailableIfNeeded(action)
                    self.logCommandVerification(
                        action: action,
                        processSuccess: false,
                        stateChanged: false,
                        pre: preCore,
                        actual: nil
                    )
                    self.recordControlVerificationFailure(action, reason: "process_failed")
                    self.logControlFailureIfNeeded(action)
                    return
                }
                self.scheduleCommandVerification(
                    action: action,
                    generation: generation,
                    preCore: preCore,
                    prePlaying: prePlaying,
                    rollbackState: rollbackState
                )
            }
        }
    }

    private func logControlSend(_ action: ControlAction) {
        switch action {
        case .seek(let seconds):
            let target = max(0, seconds)
            let micros = Self.seekMicros(for: target)
            Log.info("[SystemNowPlaying] command send action=seek target=\(formatTime(target))s micros=\(micros)", category: .playback)
        default:
            Log.info("[SystemNowPlaying] command send action=\(action)", category: .playback)
        }
    }

    private func scheduleCommandVerification(
        action: ControlAction,
        generation: UInt64,
        preCore: String?,
        prePlaying: Bool?,
        rollbackState: ControlRollbackState
    ) {
        switch action {
        case .playbackMode:
            return
        case .playPause, .play, .pause, .next, .previous, .seek:
            break
        }
        Task { [weak self] in
            let checkpoints: [UInt64]
            switch action {
            case .next, .previous:
                checkpoints = [800_000_000, 2_000_000_000]
            case .seek:
                checkpoints = [900_000_000]
            default:
                checkpoints = [700_000_000, 1_500_000_000]
            }
            var elapsed: UInt64 = 0
            for (index, checkpoint) in checkpoints.enumerated() {
                let delay = checkpoint > elapsed ? checkpoint - elapsed : 0
                elapsed = checkpoint
                try? await Task.sleep(nanoseconds: delay)
                guard let self else { return }
                let shouldRun = await MainActor.run { self.controlGeneration == generation }
                guard shouldRun else { return }
                let paths = await MainActor.run { self.resolveAdapterPaths() }
                guard let paths else { return }
                let actual = await Self.fetchGetPayload(paths: paths)
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard self.controlGeneration == generation else { return false }
                    return !self.verifyControl(
                        action: action,
                        preCore: preCore,
                        prePlaying: prePlaying,
                        actual: actual,
                        rollbackState: rollbackState,
                        isFinalAttempt: index == checkpoints.count - 1
                    )
                }
                guard shouldContinue else { return }
            }
        }
    }

    private func verifyControl(
        action: ControlAction,
        preCore: String?,
        prePlaying: Bool?,
        actual: Payload?,
        rollbackState: ControlRollbackState,
        isFinalAttempt: Bool
    ) -> Bool {
        guard let actual, actual.hasAnyValue else {
            guard isFinalAttempt else {
                Log.info("[SystemNowPlaying] command verify delayed action=\(action)", category: .playback)
                return false
            }
            logSeekVerificationUnavailableIfNeeded(action)
            logCommandVerification(
                action: action,
                processSuccess: true,
                stateChanged: false,
                pre: preCore,
                actual: nil
            )
            rollbackOptimisticState(rollbackState)
            recordControlVerificationFailure(action, reason: "no_verification_payload")
            return true
        }
        if isSelfOwnedPayload(actual) {
            Log.warning("[SystemNowPlaying] command verify ignored self-owned payload action=\(action)", category: .playback)
            guard isFinalAttempt else {
                Log.info("[SystemNowPlaying] command verify delayed action=\(action)", category: .playback)
                return false
            }
            logSeekVerificationUnavailableIfNeeded(action)
            logCommandVerification(
                action: action,
                processSuccess: true,
                stateChanged: false,
                pre: preCore,
                actual: nil
            )
            rollbackOptimisticState(rollbackState)
            recordControlVerificationFailure(action, reason: "sentButNoExternalState")
            return true
        }
        if shouldIgnoreExternalOwner(actual, source: .get) {
            guard isFinalAttempt else {
                Log.info("[SystemNowPlaying] command verify delayed action=\(action)", category: .playback)
                return false
            }
            logSeekVerificationUnavailableIfNeeded(action)
            logCommandVerification(
                action: action,
                processSuccess: true,
                stateChanged: false,
                pre: preCore,
                actual: nil
            )
            rollbackOptimisticState(rollbackState)
            recordControlVerificationFailure(action, reason: "sentButNoExternalState")
            return true
        }
        let actualPlaying = isPayloadPlaying(actual)
        let actualCore = trackCoreIdentity(for: actual)
        let matched: Bool
        let stateChanged: Bool

        switch action {
        case .play:
            matched = actualPlaying == true
            stateChanged = prePlaying.map { $0 != actualPlaying } ?? matched
        case .pause:
            matched = actualPlaying == false
            stateChanged = prePlaying.map { $0 != actualPlaying } ?? matched
        case .playPause:
            if let prev = prePlaying {
                let expected = !prev
                matched = actualPlaying == expected
                stateChanged = matched
            } else {
                matched = true
                stateChanged = false
            }
        case .next, .previous:
            stateChanged = preCore != nil && actualCore != nil && preCore != actualCore
            matched = stateChanged
        case .seek(let expected):
            let actualElapsed = currentElapsedTime(from: actual) ?? progressBaseline?.estimatedTime() ?? 0
            matched = abs(actualElapsed - max(0, expected)) <= 1.5
            stateChanged = matched
            logSeekCommandVerification(expected: max(0, expected), actual: actualElapsed, matched: matched)
        case .playbackMode:
            matched = true
            stateChanged = false
        }

        if case .seek = action {
            // Seek has a target/elapsed verification log above; avoid the generic core log.
        } else {
            logCommandVerification(
                action: action,
                processSuccess: true,
                stateChanged: stateChanged,
                pre: preCore,
                actual: actualCore
            )
        }

        if matched {
            Log.info("[SystemNowPlaying] control converged action=\(action)", category: .playback)
            recordControlVerificationSuccess(action)
            if isSkipControlAction(action) {
                lastStreamObservation = nil
            } else if case .seek = action {
                clearControlCooldown(reason: "verified action=\(action)")
            } else {
                clearControlCooldown(reason: "verified action=\(action)")
            }
            handlePayload(actual, source: .get)
            return true
        } else {
            guard isFinalAttempt else {
                Log.info("[SystemNowPlaying] command verify delayed action=\(action)", category: .playback)
                return false
            }
            if case .seek = action {
                if actualCore == latestStableMetadataKey?.identifier {
                    handlePayload(actual, source: .get)
                } else {
                    rollbackOptimisticState(rollbackState)
                }
                clearControlCooldown(reason: "seek_verification_failed")
            } else {
                rollbackOptimisticState(rollbackState)
            }
            recordControlVerificationFailure(action, reason: "sentButNoStateChange")
            return true
        }
    }

    private func logSeekCommandVerification(expected: Double, actual: Double, matched: Bool) {
        Log.info(
            "[SystemNowPlaying] command verify action=seek expected=\(formatTime(expected)) actual=\(formatTime(actual)) matched=\(matched)",
            category: .playback
        )
    }

    private func logSeekVerificationUnavailableIfNeeded(_ action: ControlAction) {
        guard case .seek(let expected) = action else { return }
        Log.info(
            "[SystemNowPlaying] command verify action=seek expected=\(formatTime(max(0, expected))) actual=nil matched=false",
            category: .playback
        )
    }

    private func logSeekUnsupportedIfNeeded(reason: String) {
        guard let owner = lockedExternalOwner ?? activeExternalOwnerBundle else { return }
        Log.warning(
            "[SystemNowPlaying] seek unsupported by owner=\(owner) reason=\(reason)",
            category: .playback
        )
    }

    private func logCommandVerification(
        action: ControlAction,
        processSuccess: Bool,
        stateChanged: Bool,
        pre: String?,
        actual: String?
    ) {
        Log.info(
            "[SystemNowPlaying] command verify action=\(action) processSuccess=\(processSuccess) stateChanged=\(stateChanged) pre=\(pre ?? "nil") actual=\(actual ?? "nil") reliability=\(reliability.rawValue)",
            category: .playback
        )
    }

    private func recordControlVerificationFailure(_ action: ControlAction, reason: String) {
        let key = action.throttleKey
        let failures = (controlFailureCounts[key] ?? 0) + 1
        controlFailureCounts[key] = failures
        if case .seek = action {
            Log.warning("[SystemNowPlaying] seek failed count=\(failures)", category: .playback)
            if failures >= 3 {
                controlDisabledUntil[key] = Date().addingTimeInterval(3)
                Log.warning("[SystemNowPlaying] seek temporarily disabled reason=consecutive_failures", category: .playback)
                logSeekUnsupportedIfNeeded(reason: reason)
            } else {
                controlDisabledUntil.removeValue(forKey: key)
            }
            Log.warning("[SystemNowPlaying] command \(reason) action=\(action) failures=\(failures)", category: .playback)
            refreshCapabilitiesFromLatestPayload()
            return
        } else if failures >= 5 {
            controlDisabledUntil[key] = Date().addingTimeInterval(9)
        } else {
            controlDisabledUntil.removeValue(forKey: key)
        }
        setReliability(.stale, reason: "command_\(reason) action=\(action)")
        Log.warning("[SystemNowPlaying] command \(reason) action=\(action) failures=\(failures)", category: .playback)
        if failures >= 5 {
            Log.warning("[SystemNowPlaying] capability degraded action=\(action) reason=consecutive_failures", category: .playback)
        }
        refreshCapabilitiesFromLatestPayload()
    }

    private func recordControlVerificationSuccess(_ action: ControlAction) {
        let wasDisabled = isControlKeyTemporarilyDisabled(action.throttleKey)
        let previousFailures = controlFailureCounts[action.throttleKey] ?? 0
        controlFailureCounts[action.throttleKey] = 0
        controlDisabledUntil.removeValue(forKey: action.throttleKey)
        if case .seek = action, wasDisabled || previousFailures > 0 {
            Log.info("[SystemNowPlaying] seek re-enabled reason=success", category: .playback)
        }
        refreshCapabilitiesFromLatestPayload()
    }

    private func isControlActionEnabled(_ action: ControlAction) -> Bool {
        guard !isActionTemporarilyDisabled(action) else {
            Log.debug("[SystemNowPlaying] control disabled by temporary degradation: \(String(describing: action))", category: .playback)
            return false
        }
        switch action {
        case .playPause, .play, .pause:
            return currentCapabilities.canControlPlayback
        case .next, .previous:
            return currentCapabilities.canSkip
        case .seek:
            return false
        case .playbackMode:
            return false
        }
    }

    private func isActionTemporarilyDisabled(_ action: ControlAction) -> Bool {
        isControlKeyTemporarilyDisabled(action.throttleKey)
    }

    private func isControlKeyTemporarilyDisabled(_ key: String) -> Bool {
        guard let until = controlDisabledUntil[key] else { return false }
        if Date() < until {
            return true
        }
        controlDisabledUntil.removeValue(forKey: key)
        return false
    }

    private func applyOptimisticState(for action: ControlAction) {
        guard presentation.hasTrack else { return }
        switch action {
        case .playPause:
            presentation.isPlaying.toggle()
            applyOptimisticPlayingState(presentation.isPlaying)
        case .play:
            presentation.isPlaying = true
            applyOptimisticPlayingState(true)
        case .pause:
            presentation.isPlaying = false
            applyOptimisticPlayingState(false)
        case .seek(let seconds):
            applyOptimisticSeek(to: seconds)
        case .next, .previous, .playbackMode:
            break
        }
    }

    private func configureControlExpectation(for action: ControlAction, preCore: String?, prePlaying: Bool?) {
        let now = Date()
        lastControlAction = action
        controlIssuedAt = now
        preControlCore = preCore
        expectedPostControlCore = nil
        switch action {
        case .play:
            expectedPostControlPlaying = true
            suppressStateRollbackUntil = now.addingTimeInterval(1.2)
        case .pause:
            expectedPostControlPlaying = false
            suppressStateRollbackUntil = now.addingTimeInterval(1.2)
        case .playPause:
            expectedPostControlPlaying = prePlaying.map { !$0 }
            suppressStateRollbackUntil = now.addingTimeInterval(1.2)
        case .next, .previous:
            expectedPostControlPlaying = nil
            suppressStateRollbackUntil = now.addingTimeInterval(1.5)
            if let preCore {
                suppressPreControlCore(preCore, action: action)
            }
        case .seek(let seconds):
            expectedPostControlPlaying = nil
            expectedPostControlSeek = max(0, seconds)
            suppressStateRollbackUntil = now.addingTimeInterval(0.8)
        case .playbackMode:
            expectedPostControlPlaying = nil
            expectedPostControlSeek = nil
            suppressStateRollbackUntil = nil
        }
    }

    private func clearControlExpectation() {
        lastControlAction = nil
        controlIssuedAt = nil
        suppressStateRollbackUntil = nil
        expectedPostControlPlaying = nil
        expectedPostControlCore = nil
        expectedPostControlSeek = nil
        preControlCore = nil
        lastSuppressedRollbackLogAt.removeAll()
    }

    private func isPlaybackControlAction(_ action: ControlAction?) -> Bool {
        guard let action else { return false }
        switch action {
        case .playPause, .play, .pause:
            return true
        case .next, .previous, .seek, .playbackMode:
            return false
        }
    }

    private func isSkipControlAction(_ action: ControlAction?) -> Bool {
        guard let action else { return false }
        switch action {
        case .next, .previous:
            return true
        case .playPause, .play, .pause, .seek, .playbackMode:
            return false
        }
    }

    private var isControlCoolingDown: Bool {
        Date() < controlCooldownUntil
    }

    private func cooldownDuration(for action: ControlAction) -> TimeInterval {
        switch action {
        case .playPause, .play, .pause:
            return 1.5
        case .next, .previous:
            return 2.0
        case .seek:
            return 0.8
        case .playbackMode:
            return 0.5
        }
    }

    private func enterControlCooldown(for action: ControlAction) {
        let duration = cooldownDuration(for: action)
        controlCooldownUntil = Date().addingTimeInterval(duration)
        controlCooldownTask?.cancel()
        let generation = controlGeneration
        Log.info("[SystemNowPlaying] control cooldown start action=\(action) duration=\(duration)s", category: .playback)
        controlCooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1_000_000_000))
            await MainActor.run {
                guard let self, self.controlGeneration == generation else { return }
                self.controlCooldownTask = nil
                self.optimisticPlayingState = nil
                self.controlCooldownUntil = .distantPast
                self.clearControlExpectation()
                Log.info("[SystemNowPlaying] control cooldown end action=\(action) reason=timeout", category: .playback)
            }
        }
    }

    private func resolveCooldownIfOptimisticMatches(incomingPlaying: Bool) {
        guard isControlCoolingDown,
              let desired = optimisticPlayingState,
              desired == incomingPlaying else { return }
        if let action = lastControlAction {
            Log.info("[SystemNowPlaying] control converged action=\(action)", category: .playback)
            recordControlVerificationSuccess(action)
        }
        clearControlCooldown(reason: "converged desired=\(desired)")
    }

    private func resolveControlConvergenceAfterTrackChange(newCore: String?) {
        guard isControlCoolingDown,
              isSkipControlAction(lastControlAction),
              let action = lastControlAction,
              let newCore,
              newCore != preControlCore else { return }
        expectedPostControlCore = newCore
        Log.info("[SystemNowPlaying] control converged action=\(action)", category: .playback)
        recordControlVerificationSuccess(action)
        clearControlCooldown(reason: "converged core=\(newCore)")
    }

    private func clearControlCooldown(reason: String) {
        controlCooldownTask?.cancel()
        controlCooldownTask = nil
        optimisticPlayingState = nil
        controlCooldownUntil = .distantPast
        clearControlExpectation()
        Log.info("[SystemNowPlaying] control cooldown end reason=\(reason)", category: .playback)
    }

    private func applyOptimisticPlayingState(_ isPlaying: Bool) {
        optimisticPlayingState = isPlaying
        if var payload = lastPayload {
            payload.playing = isPlaying
            payload.playbackRate = isPlaying ? max(payload.playbackRate ?? 1, 1) : 0
            payload.elapsedTime = estimatedCurrentTimeFromBaseline()
            payload.timestamp = nil
            lastPayload = payload
            latestStableMetadataKey = stableMetadataKey(for: payload)
        }
        progressBaseline = ProgressBaseline(
            baseElapsedTime: estimatedCurrentTimeFromBaseline(),
            baseTimestamp: Date(),
            playbackRate: isPlaying ? max(progressBaseline?.playbackRate ?? 1, 1) : 0,
            isPlaying: isPlaying,
            duration: progressBaseline?.duration ?? presentation.duration
        )
        updateProgressPresentationFromBaseline()
    }

    private func applyOptimisticSeek(to seconds: Double) {
        let target = max(0, seconds)
        Log.info("[SystemNowPlaying] optimistic seek target=\(formatTime(target))", category: .playback)
        if var payload = lastPayload {
            payload.elapsedTime = target
            payload.timestamp = nil
            lastPayload = payload
        }
        progressBaseline = ProgressBaseline(
            baseElapsedTime: target,
            baseTimestamp: Date(),
            playbackRate: progressBaseline?.playbackRate ?? (presentation.isPlaying ? 1 : 0),
            isPlaying: progressBaseline?.isPlaying ?? presentation.isPlaying,
            duration: progressBaseline?.duration ?? presentation.duration
        )
        updateProgressPresentationFromBaseline()
    }

    private func rollbackOptimisticState(_ rollbackState: ControlRollbackState) {
        lastPayload = rollbackState.payload
        latestStableMetadataKey = rollbackState.stableKey
        progressBaseline = rollbackState.baseline
        presentation = rollbackState.presentation
        optimisticPlayingState = nil
        controlCooldownTask?.cancel()
        controlCooldownTask = nil
        controlCooldownUntil = .distantPast
        clearControlExpectation()
        refreshCapabilitiesFromLatestPayload()
    }

    private func shouldIgnorePayloadDuringControlCooldown(_ payload: Payload) -> Bool {
        guard isControlCoolingDown,
              let action = lastControlAction,
              let suppressUntil = suppressStateRollbackUntil,
              Date() < suppressUntil else { return false }

        if isPlaybackControlAction(action),
           let expectedPostControlPlaying,
           isSameTrackAsStablePayload(payload),
           let incomingPlaying = payload.playing ?? ((payload.playbackRate ?? 0) > 0 ? true : nil),
           incomingPlaying != expectedPostControlPlaying {
            logSuppressingRollback(action: action, incoming: "\(incomingPlaying)", expected: "\(expectedPostControlPlaying)")
            return true
        }

        if isSkipControlAction(action),
           let incomingCore = trackCoreIdentity(for: payload),
           let oldCore = preControlCore,
           incomingCore == oldCore {
            logSuppressingRollback(action: action, incoming: incomingCore, expected: "new_core")
            return true
        }

        if case .seek = action,
           let expectedPostControlSeek,
           isSameTrackAsStablePayload(payload),
           let incomingElapsed = currentElapsedTime(from: payload),
           abs(incomingElapsed - expectedPostControlSeek) > 1.5 {
            logSuppressingRollback(
                action: action,
                incoming: formatTime(incomingElapsed),
                expected: formatTime(expectedPostControlSeek)
            )
            return true
        }

        return false
    }

    private func logSuppressingRollback(action: ControlAction, incoming: String, expected: String) {
        let key = "\(action.throttleKey)|\(incoming)|\(expected)"
        let now = Date()
        if let last = lastSuppressedRollbackLogAt[key],
           now.timeIntervalSince(last) < 0.8 {
            return
        }
        lastSuppressedRollbackLogAt[key] = now
        Log.info(
            "[SystemNowPlaying] suppressing rollback action=\(action) incoming=\(incoming) expected=\(expected)",
            category: .playback
        )
    }

    private func isSameTrackAsStablePayload(_ payload: Payload) -> Bool {
        guard let latestStableMetadataKey else { return false }
        let incoming = stableMetadataKey(for: payload)
        return incoming.trackIdentity == latestStableMetadataKey.trackIdentity
    }

    private func isSameCoreAsStablePayload(_ payload: Payload) -> Bool {
        guard let stableCore = latestStableMetadataKey?.identifier,
              let incomingCore = trackCoreIdentity(for: payload) else { return false }
        return incomingCore == stableCore
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
        case .seek:
            return false
        case .playbackMode(let mode):
            let shuffleOK = await runAdapterCommand(paths: paths, arguments: ["shuffle", "\(shuffleModeID(for: mode))"])
            let repeatOK = await runAdapterCommand(paths: paths, arguments: ["repeat", "\(repeatModeID(for: mode))"])
            return shuffleOK || repeatOK
        }
    }

    private static func seekMicros(for seconds: Double) -> Int64 {
        Int64((max(0, seconds) * 1_000_000).rounded())
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
            let processArguments = [paths.script, paths.framework] + arguments
            process.arguments = processArguments
            if arguments.first == "seek" {
                Log.info("[SystemNowPlaying] seek command args=\(processArguments)", category: .playback)
            }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
                process.waitUntilExit()
                let success = process.terminationStatus == 0
                if !success, arguments.first == "seek" {
                    let stderr = String(
                        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Log.warning(
                        "[SystemNowPlaying] seek command failed exit=\(process.terminationStatus) stderr=\(stderr)",
                        category: .playback
                    )
                }
                return success
            } catch {
                if arguments.first == "seek" {
                    Log.warning("[SystemNowPlaying] seek command launch failed error=\(error.localizedDescription)", category: .playback)
                }
                return false
            }
        }.value
    }

    private static func fetchGetPayload(paths: AdapterPaths) async -> Payload? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [paths.script, paths.framework, "get", "--no-artwork", "--now"]
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                guard !data.isEmpty else { return nil }
                // `get` outputs raw JSON (no {type,diff,payload} envelope).
                return try? JSONDecoder().decode(Payload.self, from: data)
            } catch {
                return nil
            }
        }.value
    }

    private func resolveAdapterPaths() -> AdapterPaths? {
        if let cached = cachedAdapterPaths {
            return cached
        }
        let resolved = discoverAdapterPaths()
        cachedAdapterPaths = resolved
        return resolved
    }

    private func invalidateAdapterPathCache() {
        cachedAdapterPaths = nil
        hasLoggedAdapterResolution = false
    }

    private func discoverAdapterPaths() -> AdapterPaths? {
        let fileManager = FileManager.default
        let bundle = Bundle.main

        var scriptCandidates: [String] = []
        var frameworkCandidates: [String] = []
        var testClientCandidates: [String] = []

        // 1) Bundle resourceURL with the adapter dropped under Resources/mediaremote-adapter/.
        if let resourceURL = bundle.resourceURL {
            let base = resourceURL.appendingPathComponent("mediaremote-adapter", isDirectory: true)
            scriptCandidates.append(base.appendingPathComponent("bin/mediaremote-adapter.pl").path)
            frameworkCandidates.append(base.appendingPathComponent("build/MediaRemoteAdapter.framework").path)
            testClientCandidates.append(base.appendingPathComponent("build/MediaRemoteAdapterTestClient").path)
        }

        // 2) Direct lookup at the bundle root (in case the file copy phase flattens names).
        if let path = bundle.path(forResource: "mediaremote-adapter", ofType: "pl") {
            scriptCandidates.append(path)
        }
        if let path = bundle.path(forResource: "MediaRemoteAdapter", ofType: "framework") {
            frameworkCandidates.append(path)
        }
        if let path = bundle.path(forResource: "MediaRemoteAdapterTestClient", ofType: nil) {
            testClientCandidates.append(path)
        }

        // 3) Lookup with the adapter directory hint, in case Xcode preserves a one-level subdir.
        if let path = bundle.path(forResource: "mediaremote-adapter", ofType: "pl", inDirectory: "mediaremote-adapter/bin") {
            scriptCandidates.append(path)
        }
        if let path = bundle.path(forResource: "MediaRemoteAdapter", ofType: "framework", inDirectory: "mediaremote-adapter/build") {
            frameworkCandidates.append(path)
        }
        if let path = bundle.path(forResource: "MediaRemoteAdapterTestClient", ofType: nil, inDirectory: "mediaremote-adapter/build") {
            testClientCandidates.append(path)
        }

        // 4) Developer fallbacks – /tmp clone and the project tree, only used when the bundle
        //    is missing the resources (e.g. running from an old build).
        var devBases: [String] = ["/tmp/mediaremote-adapter"]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            devBases.append("\(home)/Documents/vscode/player/myPlayer2/myPlayer2/Resources/mediaremote-adapter")
        }
        for base in devBases {
            scriptCandidates.append("\(base)/bin/mediaremote-adapter.pl")
            frameworkCandidates.append("\(base)/build/MediaRemoteAdapter.framework")
            testClientCandidates.append("\(base)/build/MediaRemoteAdapterTestClient")
        }

        // De-duplicate while preserving order so logs stay readable.
        scriptCandidates = Self.uniqued(scriptCandidates)
        frameworkCandidates = Self.uniqued(frameworkCandidates)
        testClientCandidates = Self.uniqued(testClientCandidates)

        let firstExisting: ([String]) -> String? = { candidates in
            candidates.first { fileManager.fileExists(atPath: $0) }
        }
        let scriptHit = firstExisting(scriptCandidates)
        let frameworkHit = firstExisting(frameworkCandidates)
        let testClientHit = firstExisting(testClientCandidates)

        if let script = scriptHit, let framework = frameworkHit {
            if !hasLoggedAdapterResolution {
                Log.info("[SystemNowPlaying] adapter script found: \(script)", category: .playback)
                Log.info("[SystemNowPlaying] adapter framework found: \(framework)", category: .playback)
                if let testClient = testClientHit {
                    Log.info("[SystemNowPlaying] adapter test client found: \(testClient)", category: .playback)
                } else {
                    Log.info("[SystemNowPlaying] adapter test client missing (optional); health check will be skipped", category: .playback)
                }
                hasLoggedAdapterResolution = true
            }
            return AdapterPaths(script: script, framework: framework, testClient: testClientHit)
        }

        if !hasLoggedAdapterResolution {
            Log.warning("[SystemNowPlaying] adapter resources missing; tried candidates:", category: .playback)
            for path in scriptCandidates {
                Log.warning("[SystemNowPlaying]   script candidate exists=\(fileManager.fileExists(atPath: path)): \(path)", category: .playback)
            }
            for path in frameworkCandidates {
                Log.warning("[SystemNowPlaying]   framework candidate exists=\(fileManager.fileExists(atPath: path)): \(path)", category: .playback)
            }
            for path in testClientCandidates {
                Log.warning("[SystemNowPlaying]   test client candidate exists=\(fileManager.fileExists(atPath: path)): \(path)", category: .playback)
            }
            Log.warning("[SystemNowPlaying] place mediaremote-adapter.pl + MediaRemoteAdapter.framework under myPlayer2/Resources/mediaremote-adapter/{bin,build}/ and rebuild", category: .playback)
            hasLoggedAdapterResolution = true
        }
        return nil
    }

    private static func uniqued(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(items.count)
        for item in items where seen.insert(item).inserted {
            output.append(item)
        }
        return output
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

    private func currentElapsedTime(from payload: Payload) -> Double? {
        if let elapsedTimeNow = payload.elapsedTimeNow {
            return max(0, elapsedTimeNow)
        }
        guard payload.elapsedTime != nil else { return nil }
        return estimatedCurrentTime(from: payload)
    }

    private func isPayloadPlaying(_ payload: Payload) -> Bool {
        if let playing = payload.playing {
            return playing
        }
        return (payload.playbackRate ?? 0) > 0
    }

    private func playingSignal(for payload: Payload?) -> Bool? {
        guard let payload else { return nil }
        return playingSignal(for: payload)
    }

    private func playingSignal(for payload: Payload) -> Bool? {
        if let playing = payload.playing {
            return playing
        }
        if let rate = payload.playbackRate {
            return rate > 0
        }
        return nil
    }

    private func formatTime(_ value: Double) -> String {
        String(format: "%.2f", value)
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
        pendingHeavyPresentationTask?.cancel()
        pendingHeavyPresentationTask = nil
        controlCooldownTask?.cancel()
        controlCooldownTask = nil
        unidentifiedTrackCandidateTask?.cancel()
        unidentifiedTrackCandidateTask = nil
        progressPollTask?.cancel()
        progressPollTask = nil
        emptyPayloadCount = 0
        currentCapabilities = .unavailable
        hasReceivedValidPayload = false
        hasLoggedFirstValidPayload = false
        isInEmptyPayloadWindow = false
        optimisticPlayingState = nil
        controlCooldownUntil = .distantPast
        clearControlExpectation()
        unlockExternalOwner(reason: "runtime_cancel")
        pendingUnidentifiedPayload = nil
        pendingUnidentifiedKey = nil
        isCommittingUnidentifiedCandidate = false
        lastPayload = nil
        latestStableMetadataKey = nil
        progressBaseline = nil
        clearReliabilityTracking(to: .unavailable)
        latestIdentity = nil
        latestRawMetadata = nil
        resolvedRawMetadata = nil
        resolvedTrackIdentity = nil
        latestEffectiveMetadata = nil
        latestMatchResult = nil
        latestMatchedTrack = nil
        resolvedLyricsText = nil
        autoLyricsLookupState = .idle
        displayedArtwork = .none
        pendingArtworkIdentity = nil
        isInvalidatingCurrentResolution = false
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

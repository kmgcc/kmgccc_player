//
//  AVAudioPlaybackService.swift
//  myPlayer2
//
//  kmgccc_player - AVAudioEngine Playback Service
//  Real audio playback using AVAudioEngine + AVAudioPlayerNode.
//  Integrated with Smart Shuffle for preference-based random playback.
//

import AVFoundation
import Foundation
import SwiftData
import SwiftUI

/// Real audio playback service using AVAudioEngine.
@Observable
@MainActor
final class AVAudioPlaybackService: AudioPlaybackServiceProtocol {

    // MARK: - Published State

    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentTrack: Track? {
        didSet {
            guard oldValue?.id != currentTrack?.id else { return }
            NotificationCenter.default.post(name: .playbackTrackDidChange, object: nil)
        }
    }

    var volume: Double {
        didSet {
            playerNode.volume = Float(volume)
            rendererPipeline.setVolume(Float(volume))
            AppSettings.shared.volume = volume
            // Forward to the spectrum service so it can volume-compensate its
            // time-domain loudness measurement; otherwise the quiet/normal/loud
            // classification would shift with the volume slider.
            AudioVisualizationService.shared.updateVolume(Float(volume))
        }
    }

    // MARK: - Audio Engine Components

    /// Lazy initialization: engine is only created on first access.
    /// This defers ~15-30ms of AVAudioEngine construction from app launch to first use.
    @ObservationIgnored
    private lazy var engine: AVAudioEngine = {
        engineAccessed = true
        let e = AVAudioEngine()
        setupEngine(e)
        return e
    }()

    /// Set once engine has been accessed (for guard checks without triggering lazy init)
    @ObservationIgnored
    private var isEngineInitialized: Bool { engineAccessed }
    @ObservationIgnored
    private var engineAccessed = false

    private let playerNode = AVAudioPlayerNode()
    /// Dedicated pre-output mixer. Analysis taps attach here so LED/spectrum
    /// sampling sees raw player audio before any audible output delay.
    private let playbackMixer = AVAudioMixerNode()
    /// Optional output-chain delay used for visualization sync. It is inserted
    /// only between `playbackMixer` and `engine.mainMixerNode`, never before the
    /// analysis tap and never as a substitute for delaying `playerNode.play()`.
    private let delayNode = AVAudioUnitDelay()
    private var audioFile: AVAudioFile?

    /// The renderer path is the primary output so macOS can expose system
    /// spatial-audio modes (Off / Fixed / Head Tracked). AVAudioEngine remains
    /// intact as a session-level fallback for unsupported formats or a hard
    /// renderer/CoreAudio failure.
    private enum AudioOutputBackend {
        case spatialRenderer
        case legacyEngine
    }
    private var outputBackend: AudioOutputBackend = .spatialRenderer
    private let rendererPipeline = RendererPlaybackPipeline()
    private var spatialCurrentProvider: AVFilePCMProvider?
    private var spatialCurrentSegmentID: UUID?
    private var spatialCurrentLogicalStart: Double = 0
    private var spatialClockTime: Double = 0
    private var isHandlingRendererFailure = false

    private struct SpatialPendingBoundary {
        let trackID: UUID
        let descriptor: RendererSegmentDescriptor
        let provider: AVFilePCMProvider
        let token: UUID
        let duration: Double
        let startFrameInFile: AVAudioFramePosition
    }
    private var spatialPendingBoundary: SpatialPendingBoundary?

    /// A renderer load is asynchronous because decoding is serialized on its
    /// private queue. Keep the latest explicit seek alive until that queue has
    /// committed the new synchronizer anchor; progress callbacks from the old
    /// renderer must not overwrite the target in the meantime.
    private struct SpatialPendingSeek {
        let segmentID: UUID
        let position: Double
        let wasPlaying: Bool
    }
    private var spatialPendingSeek: SpatialPendingSeek?

    // MARK: - Playback State

    private var sampleRate: Double = 44100
    private var startingFramePosition: AVAudioFramePosition = 0
    private var activeScheduleToken = UUID()
    private var completionWorkItem: DispatchWorkItem?
    /// The lookahead-delay state actually realized in the audio graph. Distinct
    /// from `AppSettings.shared.audioLookaheadEnabled` (the desired state): the
    /// toggle is applied to the live graph only at the start of a track, so an
    /// in-flight track keeps a stable pipeline. All delay handling (progress
    /// compensation, drain, buffer resets) keys off this realized flag.
    private var activeLookaheadEnabled = false
    private enum AudioGraphState: String {
        case unconfigured
        case configuring
        case ready
        case failed
    }
    private var graphState: AudioGraphState = .unconfigured
    private var graphGeneration: UInt64 = 0
    private var scheduledGraphGeneration: UInt64?
    private var currentGraphOperation = "idle"
    /// Drain bookkeeping: when lookahead is active, ~lookahead seconds of audio
    /// still sit in the delay buffer after the player finishes scheduling, so
    /// completion is deferred and progress is advanced from these anchors.
    private var drainStartUptime: TimeInterval?
    private var drainStartTime: Double = 0
    private var lastProgressUpdateUptime: TimeInterval?
    private var lastProgressAudibleTime: Double = 0
    /// The scheduled-item token observed on the previous progress tick. Used to
    /// detect a per-track clock re-base (gapless boundary, seek, reload, device
    /// change) so the `[AudioClockGap]` diagnostic does not compare track times
    /// across that discontinuity (the node sample clock is continuous, but the
    /// mapped `currentTime` legitimately resets).
    private var lastProgressScheduledToken: UUID?
    private var lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
    private var activePlaybackOrderModeOverride: PlaybackOrderMode?
    private static let fixedAudioOutputDelaySeconds: Double = 0.18
    private static let outputLatencyRefreshInterval: TimeInterval = 0.25
    private var outputLatencySnapshot = AudioOutputLatencySnapshot.zero
    private var lastOutputLatencyRefreshUptime: TimeInterval = 0

    var audioOutputDelay: Double {
        // This value is intentionally limited to the application's own
        // visualization lookahead. Bluetooth/device latency is represented by
        // the AVSampleBufferAudioRenderer's output-device clock and must not be
        // added here, otherwise lyrics and analysis are delayed twice.
        lookaheadSeconds
    }

    /// URL exposed to the system media session. Keeping this tied to the
    /// resolved current resource gives macOS the same asset context that IINA
    /// publishes alongside its AVSampleBufferAudioRenderer output.
    var nowPlayingAssetURL: URL? {
        currentFileURL
    }

    var currentPlaybackOrderMode: PlaybackOrderMode {
        effectivePlaybackOrderMode
    }

    // MARK: - Off-Main Preparation

    /// Off-main file preparation (bookmark resolve + AVAudioFile open). See
    /// `AudioFilePreparationActor`.
    private let prepActor = AudioFilePreparationActor()
    private let authorizedSourceRootsProvider: AuthorizedSourceRootsProvider
    private let libraryPaths: LibraryPaths
    /// Monotonic id for the current play request. Bumped ONLY by
    /// `invalidatePreparation()` (called from `stopPlayback`). A prepared
    /// resource is consumed only if its captured generation still matches —
    /// this discards stale results from a track the user already switched away
    /// from. See `invalidatePreparation()` for why there is a single bump site.
    private var playGeneration: UInt64 = 0
    /// The in-flight preparation task, cancelled when a newer request starts.
    private var prepTask: Task<Void, Never>?

    // MARK: - Paused Restore (Playback Memory)

    /// The `playGeneration` of an armed paused-restore load. The load owning this
    /// exact generation must finish in a *paused* state and must never call
    /// `playerNode.play()`. Scoping to a generation (instead of a bare flag)
    /// ensures a superseding normal play request — which bumps the generation —
    /// is never mistaken for the restore. Used to restore the last session at
    /// launch without auto-playing. Consumed in `finishStart`.
    private var restorePausedGeneration: UInt64?
    /// Position (seconds) to schedule the restored track at while staying paused.
    /// The seek is applied in `finishStart` once the engine is started/ready, so
    /// it is deferred (not discarded) until the off-main prepare completes.
    private var pendingRestorePositionSeconds: Double?

    // MARK: - Gapless Scheduling

    /// Queue of segments scheduled onto `playerNode`. Index 0 is the committed
    /// current item; index 1 (when present) is the prefetched next item already
    /// scheduled for a seamless join. See `PlaybackScheduling.swift`.
    private var scheduleQueue = GaplessScheduleQueue()
    /// Bumped whenever the scheduled queue is invalidated (stop, seek, manual
    /// switch, lookahead/device rebuild, failure). Async prefetch results whose
    /// captured value no longer matches are discarded. Distinct from
    /// `playGeneration`, which guards the *current* track's prepare.
    private var scheduleGeneration: UInt64 = 0
    /// The in-flight gapless prefetch of the upcoming track.
    private var prefetchTask: Task<Void, Never>?
    /// Whether a prefetch has already been attempted for the current committed
    /// item (regardless of outcome). Prevents re-spamming prefetch every progress
    /// tick after a fallback. Reset whenever the committed current item changes.
    private var prefetchAttemptedForCurrentItem = false
    /// Security-scope owner for the prefetched-but-not-yet-current item. This is
    /// the ONLY scope owner besides `currentFileLease` (which owns the committed
    /// current item). Released on discard, or TRANSFERRED into the current-file
    /// bookkeeping at a gapless boundary commit — never double-released.
    private var prefetchedResource: PreparedAudioResource?
    /// Seconds of remaining current-track audio at/under which the next track is
    /// prefetched and gapless-scheduled.
    private static let gaplessPrefetchLeadSeconds: Double = 20

    /// Reasons a natural boundary could not (or chose not to) go gapless. Logged
    /// for field diagnosis.
    private enum GaplessFallbackReason: String {
        case disabled
        case noNext
        case formatMismatch
        case prefetchFailed
        case generationMismatch
        case stopAfterTrack
        case repeatOne
        case predictionMismatch
        case stateChanged
        case notScheduledInTime

        /// Reasons that indicate an unexpected internal state (vs. a normal,
        /// expected fallback like end-of-queue or a superseded prefetch). Only
        /// these are logged unconditionally; the rest are gated behind
        /// `LogConfig.gaplessVerbose`.
        var isUnexpected: Bool {
            switch self {
            case .notScheduledInTime: return true
            default: return false
            }
        }
    }

    /// Gapless is allowed when the user hasn't disabled it. Lookahead (the
    /// 180ms output delay node) is compatible with gapless: AVAudioPlayerNode
    /// renders back-to-back scheduled items seamlessly regardless of downstream
    /// delay nodes, so both features coexist.
    private var gaplessEnabled: Bool {
        AppSettings.shared.audioGaplessSchedulingEnabled
    }

    // MARK: - Smart Shuffle Integration

    private let smartController: SmartPlaybackController

    // MARK: - Timer

    private var progressTimer: Timer?

    // MARK: - Current File Access

    private var currentFileURL: URL?
    private var currentFileLease: SecurityScopedResourceLease?

    /// Persists refreshed locators and availability through the active repository.
    var onAudioLocatorResolved: ((UUID, TrackMediaLocator, TrackAvailability) -> Void)?

    // MARK: - Level Meter Integration

    /// Pre-delay mixer exposed for level meter / spectrum taps.
    /// Accessing this property triggers lazy engine initialization.
    var analysisMixerNode: AVAudioMixerNode {
        engineAccessed = true
        _ = engine
        return playbackMixer
    }

    /// Kept for older call sites; use `analysisMixerNode` for visualization taps.
    var mainMixerNode: AVAudioMixerNode {
        analysisMixerNode
    }

    init(
        smartController: SmartPlaybackController,
        libraryPaths: LibraryPaths,
        authorizedSourceRootsProvider: AuthorizedSourceRootsProvider = AuthorizedSourceRootsProvider()
    ) {
        self.smartController = smartController
        self.libraryPaths = libraryPaths
        self.authorizedSourceRootsProvider = authorizedSourceRootsProvider
        self.volume = AppSettings.shared.volume
        // Engine is now lazily initialized on first access (see `engine` property)
        setupSmartController()
        setupRendererPipeline()
        refreshOutputLatency(force: true)
        Log.info(
            "[PlaybackPipeline] AVAudioPlaybackService init id=\(ObjectIdentifier(self)) engine=deferred",
            category: .audio
        )
    }

    deinit {
        Log.info(
            "[PlaybackPipeline] AVAudioPlaybackService deinit id=\(ObjectIdentifier(self))",
            category: .audio
        )
    }

    // MARK: - Setup

    /// Sets up the audio engine with nodes and connections.
    /// Called once when engine is first accessed via lazy initialization.
    private func setupEngine(_ engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(playbackMixer)
        engine.attach(delayNode)

        // Build the full graph atomically. Pass the local `engine` — we are
        // INSIDE the lazy `self.engine` initializer
        // here, so touching `self.engine` would re-enter init and spawn a second
        // AVAudioEngine (nodes then mismatch their owningEngine → crash). The
        // analysis tap (FFT/LED) is installed separately on playbackMixer and
        // is intentionally before delayNode.
        rebuildPlaybackGraph(
            engine,
            format: nil,
            lookahead: desiredLookaheadEnabled,
            operation: "setupEngine"
        )
        AudioAnalysisHub.shared.attachToMixer(playbackMixer)

        playerNode.volume = Float(volume)
        // Seed the spectrum service with the initial volume (didSet does not fire
        // during init, so the first classification would otherwise use the 1.0
        // default and mis-classify until the first manual volume change).
        AudioVisualizationService.shared.updateVolume(Float(volume))
        engine.prepare()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    private func setupSmartController() {
        smartController.onPlayTrack = { [weak self] track in
            self?.playInternal(track: track)
        }
        smartController.onTrackChanged = { [weak self] track in
            self?.currentTrack = track
        }
    }

    private func setupRendererPipeline() {
        rendererPipeline.setVolume(Float(volume))
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        rendererPipeline.onProgress = { [weak self] clock in
            guard let self, self.spatialPendingSeek == nil else { return }
            self.spatialClockTime = clock
        }
        rendererPipeline.onTimelineMutationCommitted = { [weak self] segmentID, clock, autoplay in
            guard let self,
                  self.outputBackend == .spatialRenderer,
                  let pending = self.spatialPendingSeek,
                  pending.segmentID == segmentID else { return }
            self.spatialPendingSeek = nil
            self.spatialClockTime = clock
            self.currentTime = pending.position
            self.isPlaying = autoplay
            self.smartController.endSeek()
            AudioAnalysisHub.shared.setPlaying(autoplay)
            if autoplay {
                self.startProgressTimer()
            } else {
                self.stopProgressTimer()
                if self.duration > 0 {
                    self.smartController.updateProgress(
                        currentTime: self.currentTime,
                        duration: self.duration
                    )
                }
            }
            // The coordinator already publishes the target immediately from
            // seek(to:). Republish at the commit boundary so the system media
            // session follows the same one-shot timeline transaction.
            NowPlayingService.shared.syncLocalPlaybackState()
        }
        rendererPipeline.onAnalysisPCM = { pcm in
            // Feed only when the renderer clock reaches the application-owned
            // lookahead delivery point, avoiding the renderer's larger decode
            // pre-roll. The output device's Core Audio clock is selected on the
            // renderer; no route-specific delay estimate belongs in this path.
            AudioAnalysisHub.shared.enqueueExternalPCM(pcm)
        }
        rendererPipeline.onSegmentExhausted = { [weak self] descriptor in
            // This is the renderer equivalent of RendererEngine.onTrackEnded:
            // the source is fully queued, so give the existing prefetch owner
            // one more opportunity to prepare the next item. Progress-based
            // prefetch remains the normal early path.
            guard let self,
                  self.outputBackend == .spatialRenderer,
                  descriptor.id == self.spatialCurrentSegmentID else { return }
            self.maybeTriggerGaplessPrefetch()
        }
        rendererPipeline.onSystemReconfigEvent = {
            Log.info(
                "[SpatialAudio] renderer output configuration changed; timeline recovery requested",
                category: .audio
            )
        }
        rendererPipeline.onFailure = { [weak self] error in
            guard let self else { return }
            if self.spatialPendingSeek != nil {
                self.spatialPendingSeek = nil
                self.smartController.endSeek()
            }
            self.fallbackToLegacyEngine(after: error)
        }
    }

    /// Refresh the active Core Audio output route at the same cadence as the
    /// playback presentation timer. The renderer itself is bound to the
    /// reported device UID so its synchronizer follows the device clock. The
    /// latency fields are retained for diagnostics only; they never become a
    /// presentation offset.
    private func refreshOutputLatency(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastOutputLatencyRefreshUptime >= Self.outputLatencyRefreshInterval else {
            return
        }
        lastOutputLatencyRefreshUptime = now

        let snapshot = AudioOutputLatencyMonitor.currentSnapshot()
        let snapshotChanged = snapshot != outputLatencySnapshot
        let outputDeviceChanged = snapshot.deviceID != outputLatencySnapshot.deviceID
            || snapshot.deviceUID != outputLatencySnapshot.deviceUID
        outputLatencySnapshot = snapshot
        if snapshotChanged {
            Log.info(
                "[AudioClock] output=\(snapshot.deviceName) uid=\(snapshot.deviceUID ?? "default") transport=\(snapshot.transportType) deviceFrames=\(snapshot.deviceLatencyFrames) streamFrames=\(snapshot.streamLatencyFrames) reportedSeconds=\(String(format: "%.4f", snapshot.seconds)) presentationOffset=0",
                category: .audio
            )
        }
        if outputDeviceChanged {
            rendererPipeline.setAudioOutputDeviceUniqueID(snapshot.deviceUID)
        }
    }

    // MARK: - Engine Management

    @objc nonisolated private func handleEngineConfigurationChange(_ notification: Notification) {
        // AVAudioEngine may post this notification from its internal engine queue.
        // Keep the ObjC entrypoint nonisolated so Swift 6 does not assert that
        // the CoreAudio callback is already running on MainActor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconnectEngineAndResume()
        }
    }

    private func reconnectEngineAndResume() async {
        // The legacy engine can be initialized solely to host the visualization
        // mixer. Its device-change notifications must not disturb live renderer
        // playback; the renderer owns its own route/auto-flush recovery.
        guard outputBackend == .legacyEngine else { return }
        let wasPlaying = isPlaying
        let savedTime = currentTime
        let savedTrack = currentTrack
        let savedVolume = volume

        Log.debug("Audio device changed. Was playing: \(wasPlaying), position: \(String(format: "%.1f", savedTime))s", category: .audio)

        AudioAnalysisHub.shared.prepareForEngineConfigurationChange()
        defer {
            AudioAnalysisHub.shared.restoreAfterEngineConfigurationChange()
        }

        playerNode.stop()
        // A device change clears all scheduled buffers on the node, so drop any
        // prefetched gapless item (releasing its scope) before rescheduling.
        resetGaplessSchedulingState(reason: "deviceChange")
        stopProgressTimer()
        reconnectAudioGraph()

        do {
            if !engine.isRunning {
                try engine.start()
                Log.info("Engine restarted after device change", category: .audio)
            }
        } catch {
            Log.error("Failed to restart engine after device change: \(error)", category: .audio)
            isPlaying = false
            return
        }

        if wasPlaying, let _ = savedTrack, let file = audioFile {
            let targetFrame = AVAudioFramePosition(savedTime * sampleRate)
            let totalFrames = file.length

            guard targetFrame >= 0, targetFrame < totalFrames else {
                Log.warning("Cannot resume: invalid position", category: .audio)
                isPlaying = false
                return
            }

            let frameCount = AVAudioFrameCount(totalFrames - targetFrame)
            startingFramePosition = targetFrame

            rebuildPlaybackGraph(
                engine,
                format: file.processingFormat,
                lookahead: activeLookaheadEnabled,
                operation: "deviceChangeResume"
            )
            do {
                if !engine.isRunning {
                    try engine.start()
                }
            } catch {
                graphState = .failed
                Log.error("Failed to restart engine for device-change resume: \(error)", category: .audio)
                isPlaying = false
                return
            }
            scheduleSegment(file, startingFrame: targetFrame, frameCount: frameCount)
            guard graphReadyForPlay(scheduledGeneration: scheduledGraphGeneration, operation: "deviceChangeResume.play") else {
                failPlaybackRequest(reason: "graph not ready after device-change resume")
                return
            }
            playerNode.play()
            isPlaying = true
            startProgressTimer()
            playerNode.volume = Float(savedVolume)

            Log.info("Resumed playback at \(String(format: "%.1f", savedTime))s after device change", category: .playback)
        } else {
            isPlaying = false
        }
    }

    private func reconnectAudioGraph() {
        // Preserve whatever chain the current track is using; a device change
        // mid-track must not silently switch the lookahead state.
        rebuildPlaybackGraph(
            engine,
            format: audioFile?.processingFormat,
            lookahead: activeLookaheadEnabled,
            operation: "reconnectAudioGraph"
        )
    }

    /// Session-level safety net. A renderer failure must never turn a playable
    /// local file into silence: stop the spatial path, preserve the current
    /// media position, and resume through the existing AVAudioEngine graph.
    private func fallbackToLegacyEngine(after rendererError: RendererPipelineError) {
        guard outputBackend == .spatialRenderer,
              !isHandlingRendererFailure,
              let file = audioFile,
              currentTrack != nil else { return }

        isHandlingRendererFailure = true
        defer { isHandlingRendererFailure = false }
        let wasPlaying = isPlaying
        let resumeTime = max(0, min(currentTime, duration))
        Log.error(
            "[SpatialAudio] renderer failed; falling back to AVAudioEngine at \(String(format: "%.3f", resumeTime))s error=\(rendererError)",
            category: .audio
        )

        outputBackend = .legacyEngine
        rendererPipeline.stop()
        AudioAnalysisHub.shared.disableExternalFeed()
        resetGaplessSchedulingState(reason: "rendererFailureFallback")
        spatialCurrentProvider = nil
        spatialCurrentSegmentID = nil
        spatialPendingSeek = nil
        spatialPendingBoundary = nil
        spatialCurrentLogicalStart = 0
        spatialClockTime = 0

        rebuildPlaybackGraph(
            engine,
            format: file.processingFormat,
            lookahead: desiredLookaheadEnabled,
            operation: "rendererFailureFallback"
        )
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            graphState = .failed
            isPlaying = false
            AudioAnalysisHub.shared.setPlaying(false)
            Log.error(
                "[SpatialAudio] legacy fallback engine failed to start: \(error)",
                category: .audio
            )
            return
        }

        configureDelay()
        resetDelayBufferIfActive()
        let upperFrame = max(0, file.length - 1)
        let targetFrame = max(
            0,
            min(AVAudioFramePosition(resumeTime * sampleRate), upperFrame)
        )
        startingFramePosition = targetFrame
        currentTime = resumeTime
        let frameCount = AVAudioFrameCount(file.length - targetFrame)
        scheduleSegment(file, startingFrame: targetFrame, frameCount: frameCount)

        guard wasPlaying else {
            isPlaying = false
            AudioAnalysisHub.shared.setPlaying(false)
            return
        }
        guard graphReadyForPlay(
            scheduledGeneration: scheduledGraphGeneration,
            operation: "rendererFailureFallback.play"
        ) else {
            failPlaybackRequest(reason: "legacy graph not ready after renderer failure")
            return
        }
        playerNode.play()
        isPlaying = true
        AudioAnalysisHub.shared.setPlaying(true)
        startProgressTimer()
    }

    // MARK: - Lookahead (Audio Delay)

    /// Rebuilds the owned playback graph with one of two stable topologies:
    /// off: `playerNode -> playbackMixer -> engine.mainMixerNode`
    /// on:  `playerNode -> playbackMixer -> delayNode -> engine.mainMixerNode`
    ///
    /// The analysis tap attaches to `playbackMixer`, so it always samples
    /// pre-delay audio. We never disconnect `engine.mainMixerNode` from the
    /// hardware output; AVAudioEngine owns that final connection.
    private func rebuildPlaybackGraph(
        _ engine: AVAudioEngine,
        format: AVAudioFormat?,
        lookahead: Bool,
        operation: String
    ) {
        graphState = .configuring
        currentGraphOperation = operation
        if engine.isRunning {
            engine.stop()
            if LogConfig.perfDebugEnabled {
                Log.info("[PlaybackPipeline] engine.stop() operation=\(operation) operationStack=\(FirstUseHitchDiagnostics.currentOperationStack())", category: .audio)
            }
        }
        let mainMixer = engine.mainMixerNode
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(playbackMixer)
        engine.disconnectNodeOutput(delayNode)

        engine.connect(playerNode, to: playbackMixer, format: format)
        if lookahead {
            engine.connect(playbackMixer, to: delayNode, format: nil)
            engine.connect(delayNode, to: mainMixer, format: nil)
            activeLookaheadEnabled = true
            configureDelay()
        } else {
            engine.connect(playbackMixer, to: mainMixer, format: nil)
            activeLookaheadEnabled = false
            delayNode.reset()
        }
        graphGeneration &+= 1
        scheduledGraphGeneration = nil
        graphState = .ready
        currentGraphOperation = "idle"
        let operationStackSuffix = LogConfig.perfDebugEnabled
            ? " operationStack=\(FirstUseHitchDiagnostics.currentOperationStack())"
            : ""
        Log.info(
            "[PlaybackPipeline] graph ready generation=\(graphGeneration) operation=\(operation) topology=\(activeLookaheadEnabled ? "player->playbackMixer->delay->mainMixer" : "player->playbackMixer->mainMixer") delaySeconds=\(String(format: "%.3f", lookaheadSeconds)) engineRunning=\(engine.isRunning)\(operationStackSuffix)",
            category: .audio
        )
    }

    /// The lookahead state the user *wants* realized, gated by the debug
    /// bypass. When `audioDebugBypassDelayNode` is true this is always false,
    /// forcing the no-delay direct chain. Default behavior (bypass off) is
    /// unchanged.
    private var desiredLookaheadEnabled: Bool {
        AppSettings.shared.audioLookaheadEnabled && !AppSettings.shared.audioDebugBypassDelayNode
    }

    /// Realized lookahead in seconds (0 when the feature is off in the live
    /// graph). The current product target is a fixed 180ms output delay.
    private var lookaheadSeconds: Double {
        guard activeLookaheadEnabled else { return 0 }
        return Self.fixedAudioOutputDelaySeconds
    }

    private func graphReadyForPlay(scheduledGeneration: UInt64?, operation: String) -> Bool {
        let scheduledText = scheduledGeneration.map(String.init) ?? "nil"
        let ready = graphState == .ready
            && scheduledGeneration == graphGeneration
            && engine.isRunning

        if !ready {
            Log.error(
                "[PlaybackPipeline] graph not ready operation=\(operation) graphState=\(graphState.rawValue) graphGeneration=\(graphGeneration) scheduledGeneration=\(scheduledText) engineRunning=\(engine.isRunning) currentGraphOperation=\(currentGraphOperation)",
                category: .audio
            )
        }
        return ready
    }

    private func failPlaybackRequest(reason: String) {
        Log.error(
            "[PlaybackPipeline] playback request failed reason=\(reason) graphState=\(graphState.rawValue) graphGeneration=\(graphGeneration) scheduledGeneration=\(scheduledGraphGeneration.map(String.init) ?? "nil") engineRunning=\(isEngineInitialized ? engine.isRunning : false) currentGraphOperation=\(currentGraphOperation)",
            category: .audio
        )
        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        stopProgressTimer()
        resetDelayBufferIfActive()
        isPlaying = false
    }

    /// Applies `lookaheadMs` to the delay node. No-op unless lookahead is the
    /// realized state, so a disabled feature never touches the delay node.
    private func configureDelay() {
        guard activeLookaheadEnabled else { return }
        let seconds = lookaheadSeconds
        delayNode.delayTime = seconds
        delayNode.feedback = 0
        delayNode.wetDryMix = seconds > 0 ? 100 : 0
        delayNode.lowPassCutoff = 20_000
        delayNode.reset()
        if LogConfig.perfDebugEnabled {
            Log.info("[PlaybackPipeline] delayNode configured delaySeconds=\(String(format: "%.3f", seconds)) reset operationStack=\(FirstUseHitchDiagnostics.currentOperationStack())", category: .audio)
        }
    }

    /// Clears buffered delay-line audio. No-op when lookahead is off.
    private func resetDelayBufferIfActive() {
        guard activeLookaheadEnabled else { return }
        delayNode.reset()
    }

    private func applyLookaheadPreferenceChangeIfNeeded(reason: String) {
        let desired = desiredLookaheadEnabled
        guard desired != activeLookaheadEnabled else { return }

        Log.info(
            "[PlaybackPipeline] audio lookahead preference change reason=\(reason) desired=\(desired) wasPlaying=\(isPlaying) currentTime=\(String(format: "%.3f", currentTime))",
            category: .audio
        )

        if outputBackend == .spatialRenderer {
            let wasPlaying = isPlaying
            let resumeTime = currentTime
            cancelPendingCompletion()
            invalidateScheduleToken()
            activeLookaheadEnabled = desired
            guard let file = audioFile else { return }

            let targetFrame = AVAudioFramePosition(resumeTime * sampleRate)
            guard targetFrame >= 0, targetFrame < file.length else {
                Log.warning(
                    "[SpatialAudio] cannot apply output delay at invalid frame=\(targetFrame)",
                    category: .audio
                )
                return
            }
            let provider = AVFilePCMProvider(file: file)
            let segmentID = UUID()
            spatialCurrentProvider = provider
            spatialCurrentSegmentID = segmentID
            spatialCurrentLogicalStart = 0
            spatialClockTime = resumeTime
            spatialPendingBoundary = nil
            rendererPipeline.setAnalysisLeadSeconds(lookaheadSeconds)
            refreshOutputLatency(force: true)
            rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
            rendererPipeline.load(
                source: provider,
                sourcePosition: targetFrame,
                // The descriptor anchor represents source time zero; the
                // pipeline adds `sourcePosition` to the first buffer PTS.
                presentationStartSeconds: lookaheadSeconds,
                clockTimeSeconds: resumeTime,
                segmentID: segmentID,
                autoplay: wasPlaying
            )
            AudioAnalysisHub.shared.setPlaying(wasPlaying)
            return
        }

        let wasPlaying = isPlaying
        let resumeTime = currentTime
        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBufferIfActive()
        stopProgressTimer()
        isPlaying = false

        rebuildPlaybackGraph(
            engine,
            format: audioFile?.processingFormat,
            lookahead: desired,
            operation: "lookaheadPreferenceChange.\(reason)"
        )

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            graphState = .failed
            Log.error("[PlaybackPipeline] engine start failed after lookahead preference change: \(error)", category: .audio)
            return
        }

        guard let file = audioFile else {
            return
        }

        let targetFrame = AVAudioFramePosition(resumeTime * sampleRate)
        let totalFrames = file.length
        guard targetFrame >= 0, targetFrame < totalFrames else {
            Log.warning("[PlaybackPipeline] cannot reschedule after lookahead change: invalid frame=\(targetFrame) total=\(totalFrames)", category: .audio)
            return
        }

        startingFramePosition = targetFrame
        currentTime = max(0, min(resumeTime, duration))
        let frameCount = AVAudioFrameCount(totalFrames - targetFrame)
        scheduleSegment(file, startingFrame: targetFrame, frameCount: frameCount)

        guard wasPlaying else {
            return
        }
        guard graphReadyForPlay(
            scheduledGeneration: scheduledGraphGeneration,
            operation: "lookaheadPreferenceChange.play"
        ) else {
            failPlaybackRequest(reason: "graph not ready after lookahead preference change")
            return
        }
        playerNode.play()
        isPlaying = true
        startProgressTimer()
    }

    private func cancelPendingCompletion() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        drainStartUptime = nil
    }

    // MARK: - Scheduling Helpers

    private func invalidateScheduleToken() {
        activeScheduleToken = UUID()
        scheduledGraphGeneration = nil
        resetGaplessSchedulingState(reason: "invalidateScheduleToken")
    }

    /// Invalidate the gapless scheduled queue: bump the generation so in-flight
    /// prefetch results are discarded, cancel the prefetch task, release the
    /// prefetched item's security scope (single release site), and clear the
    /// queue. Safe to call repeatedly. Does NOT touch the committed current
    /// file's scope (owned by `currentFileURL` / `stopAccessingCurrentFile`).
    private func resetGaplessSchedulingState(reason: String) {
        scheduleGeneration &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAttemptedForCurrentItem = false
        releasePrefetchedResource(reason: reason)
        spatialPendingBoundary = nil
        scheduleQueue.reset()
    }

    /// Release the prefetched item's security scope, if any. The single release
    /// path for `prefetchedResource` when it is discarded (not promoted).
    private func releasePrefetchedResource(reason: String) {
        guard let resource = prefetchedResource else { return }
        prefetchedResource = nil
        releaseSecurityScope(for: resource)
        gaplessLog("[Gapless] released prefetched resource track=\(resource.trackID.uuidString.prefix(8)) lease=owned reason=\(reason)")
    }

    /// Record the freshly-scheduled current segment into the queue with a node
    /// clock base of 0. Every existing schedule path (finishStart, seek,
    /// device-change, lookahead rebuild, restore-paused) re-starts the node from
    /// a stopped state, so the node clock restarts at 0 for the new current item.
    private func recordCurrentScheduledItem(
        file: AVAudioFile,
        token: UUID,
        startFrameInFile: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) {
        let item = ScheduledItem(
            trackID: currentTrack?.id ?? UUID(),
            token: token,
            startNodeSample: 0,
            startFrameInFile: startFrameInFile,
            frameCount: frameCount,
            sampleRate: file.processingFormat.sampleRate,
            duration: duration
        )
        scheduleQueue.setCurrent(item)
        prefetchAttemptedForCurrentItem = false
    }

    private func formatsGaplessCompatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        // AVAudioFile.processingFormat is always float32 / deinterleaved, so
        // sample rate + channel count fully determine node compatibility. This is
        // also exactly the format the player node is connected with.
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    private func logGaplessFallback(_ reason: GaplessFallbackReason, context: String) {
        // Unexpected internal state is always surfaced (warning). Normal,
        // expected fallbacks (end-of-queue, superseded prefetch, format
        // mismatch, etc.) are routine diagnostics gated behind gaplessVerbose.
        if reason.isUnexpected {
            Log.warning("[Gapless] fallback reason=\(reason.rawValue) \(context)", category: .audio)
        } else {
            gaplessLog("[Gapless] fallback reason=\(reason.rawValue) \(context)")
        }
    }

    /// Routine gapless diagnostics. No-op unless `LogConfig.gaplessVerbose` is on,
    /// so normal Debug runs stay quiet; the `@autoclosure` keeps the string from
    /// being built when disabled. Use for expected prefetch/schedule/boundary/AAC
    /// trace; use `Log.warning`/`Log.error` directly for genuine problems.
    private func gaplessLog(_ message: @autoclosure () -> String) {
        if LogConfig.gaplessVerbose {
            Log.info(message(), category: .audio)
        }
    }

    /// Invalidate any in-flight file preparation: bump the generation so a
    /// returning `PreparedAudioResource` fails the guard in
    /// `finishStartIfCurrent`, and cancel the background task. This is the
    /// SINGLE generation-bump site. `stopPlayback` calls it, and every
    /// `playInternal` runs `stopPlayback` first — so a new play request
    /// naturally observes a freshly-bumped generation to adopt as its own. Do
    /// NOT add a second bump in `playInternal`; the single site is intentional.
    private func invalidatePreparation() {
        playGeneration &+= 1
        prepTask?.cancel()
        prepTask = nil
    }

    private func scheduleFile(_ file: AVAudioFile) {
        let token = UUID()
        activeScheduleToken = token
        scheduledGraphGeneration = graphGeneration
        recordCurrentScheduledItem(
            file: file,
            token: token,
            startFrameInFile: 0,
            frameCount: AVAudioFrameCount(file.length)
        )
        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] scheduleFile frames=\(file.length) graphGeneration=\(graphGeneration) graphState=\(graphState.rawValue) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }
        let completion = playbackBoundaryHandler(token: token)
        playerNode.scheduleFile(file, at: nil, completionHandler: completion)
    }

    private func scheduleSegment(
        _ file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) {
        let token = UUID()
        activeScheduleToken = token
        scheduledGraphGeneration = graphGeneration
        recordCurrentScheduledItem(
            file: file,
            token: token,
            startFrameInFile: startingFrame,
            frameCount: frameCount
        )
        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] scheduleSegment startFrame=\(startingFrame) frameCount=\(frameCount) graphGeneration=\(graphGeneration) graphState=\(graphState.rawValue) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }
        let completion = playbackBoundaryHandler(token: token)
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: completion
        )
    }

    // MARK: - Playback Control

    func play(track: Track) {
        Log.debug("play(track:) called for: \(track.title)", category: .audio)
        let mode = applyPlaybackStartPolicy(.useSavedMode)
        smartController.startPlayback(tracks: [track], startingAt: 0, shuffle: mode == .shuffle)
    }

    func playTracks(_ tracks: [Track], startingAt index: Int, startPolicy: PlaybackStartPolicy) {
        guard index >= 0, index < tracks.count else { return }
        let mode = applyPlaybackStartPolicy(startPolicy)

        // Pass to smart controller
        smartController.startPlayback(tracks: tracks, startingAt: index, shuffle: mode == .shuffle)
    }

    /// Restore a saved session into a **paused** state: rebuilds the queue, loads
    /// the current track and schedules audio at `positionSeconds`, but never
    /// starts the player node. The user must press play to begin from the
    /// restored position. This is the playback-memory restore path; it deliberately
    /// does not auto-play (the launch auto-play chain stays disabled).
    func restorePausedPlayback(_ tracks: [Track], startingAt index: Int, positionSeconds: Double) {
        guard index >= 0, index < tracks.count else { return }
        let mode = applyPlaybackStartPolicy(.useSavedMode)

        Log.info(
            "[PlaybackPipeline] restorePausedPlayback queueCount=\(tracks.count) startIndex=\(index) position=\(String(format: "%.1f", positionSeconds)) mode=\(mode.rawValue)",
            category: .audio
        )

        // startPlayback runs synchronously through playInternal (which calls
        // stopPlayback → clears the restore arm, bumps playGeneration, creates
        // the prep task), so once it returns, playGeneration identifies exactly
        // this load. Arm the restore intent AFTER it returns — arming before
        // would be wiped by stopPlayback. finishStart consumes these.
        smartController.startPlayback(tracks: tracks, startingAt: index, shuffle: mode == .shuffle)
        restorePausedGeneration = playGeneration
        pendingRestorePositionSeconds = max(0, positionSeconds)
    }

    private func applyPlaybackStartPolicy(_ policy: PlaybackStartPolicy) -> PlaybackOrderMode {
        let mode = policy.resolvedMode()
        activePlaybackOrderModeOverride = policy.isTemporaryOverride ? mode : nil
        lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
        return mode
    }

    private var effectivePlaybackOrderMode: PlaybackOrderMode {
        activePlaybackOrderModeOverride ?? AppSettings.shared.playbackOrderMode
    }

    func makePrepRequest(for track: Track) -> AudioPrepRequest {
        let root = track.libraryRootSnapshot.isEmpty
            ? libraryPaths.rootURL
            : URL(fileURLWithPath: track.libraryRootSnapshot, isDirectory: true)
        return AudioPrepRequest(
            trackID: track.id,
            locator: track.mediaLocator,
            libraryPaths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: authorizedSourceRootsProvider.snapshot(),
            titleForLog: track.title
        )
    }

    private func playInternal(track: Track) {
        Log.info(
            "[PlaybackPipeline] load item requested track=\(track.id.uuidString) title=\(track.title)",
            category: .audio
        )

        // Stop current audio immediately (matches "switch track = stop now").
        // stopPlayback runs invalidatePreparation() — bumping playGeneration and
        // cancelling any in-flight prepare — and clears currentTrack/audioFile +
        // releases the old file's security scope.
        stopPlayback(clearQueue: false)

        // Adopt the generation stopPlayback just bumped. There is NO second bump
        // here on purpose (see invalidatePreparation()): this request owns the
        // current generation, so its own prepared resource passes the guard,
        // while any earlier in-flight prepare holds an older (cancelled) one.
        let generation = playGeneration

        // Presentation updates immediately; audio follows after the off-main
        // prepare. duration is a placeholder reconciled in finishStart.
        currentTrack = track
        duration = track.duration
        currentTime = 0
        startingFramePosition = 0

        // Cheap MainActor snapshot of the @Model fields the actor needs. Only
        // this Sendable value crosses into the actor — never the Track itself.
        let request = makePrepRequest(for: track)

        // Task {} (not detached) inherits this @MainActor context: the await
        // suspends and the actor runs the heavy work off-main, then resumes on
        // main. The closure captures only Sendable values (request, generation)
        // and self — never `track`, so there is no Swift 6 non-Sendable capture.
        // The Track is re-acquired from currentTrack on resume.
        prepTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.prepActor.prepare(request)
                self.finishStartIfCurrent(resource, generation: generation)
            } catch {
                self.handlePrepareFailureIfCurrent(
                    error,
                    trackID: request.trackID,
                    generation: generation
                )
            }
        }
    }

    /// MainActor: consume a prepared resource only if it is still the current
    /// generation AND the current track still matches; otherwise discard it and
    /// release its security scope.
    private func finishStartIfCurrent(_ resource: PreparedAudioResource, generation: UInt64) {
        guard generation == playGeneration else {
            // Superseded by a newer play request — release and drop.
            releaseSecurityScope(for: resource)
            Log.info(
                "[PlaybackPipeline] prepared resource discarded gen=\(generation) current=\(playGeneration) track=\(resource.trackID.uuidString)",
                category: .audio
            )
            return
        }
        guard let track = currentTrack, track.id == resource.trackID else {
            // currentTrack moved without a generation bump (e.g. cleared): drop.
            releaseSecurityScope(for: resource)
            Log.info(
                "[PlaybackPipeline] prepared resource dropped; currentTrack mismatch track=\(resource.trackID.uuidString)",
                category: .audio
            )
            return
        }
        let restorePaused = (restorePausedGeneration == generation)
        finishStart(resource, track: track, restorePaused: restorePaused)
    }

    /// Release a prepared resource's security scope, but only if it actually
    /// started one (library-relative paths never do).
    private func releaseSecurityScope(for resource: PreparedAudioResource) {
        resource.lease.release()
    }

    /// MainActor: lightweight engine scheduling for an already-prepared file.
    /// No file open / bookmark resolve happens here — only engine ops, which
    /// must run on main (AVAudioEngine is not Sendable).
    private func finishStart(_ resource: PreparedAudioResource, track: Track, restorePaused: Bool) {
        let scheduleToken = FirstUseHitchDiagnostics.begin(
            "AudioEngine.schedule",
            detail: "track=\(resource.trackID.uuidString.prefix(8))"
        )
        defer { FirstUseHitchDiagnostics.end(scheduleToken) }

        currentFileURL = resource.resolvedURL
        currentFileLease = resource.lease
        audioFile = resource.file
        sampleRate = resource.sampleRate
        duration = resource.duration
        currentTime = 0
        startingFramePosition = 0

        track.availability = resource.newAvailability
        if let refreshed = resource.refreshedLocator {
            track.mediaLocator = refreshed
            onAudioLocatorResolved?(track.id, refreshed, resource.newAvailability)
        }

        if outputBackend == .spatialRenderer {
            startSpatialRenderer(
                resource: resource,
                track: track,
                restorePaused: restorePaused
            )
            return
        }

        let desiredLookahead = desiredLookaheadEnabled
        if desiredLookahead != activeLookaheadEnabled {
            Log.info(
                "[PlaybackPipeline] audio lookahead chain rebuild desired=\(desiredLookahead)",
                category: .audio
            )
        }
        rebuildPlaybackGraph(
            engine,
            format: resource.file.processingFormat,
            lookahead: desiredLookahead,
            operation: "finishStart"
        )

        do {
            if !engine.isRunning {
                try engine.start()
                if LogConfig.perfDebugEnabled {
                    Log.info("[PlaybackPipeline] engine.start() operation=finishStart operationStack=\(FirstUseHitchDiagnostics.currentOperationStack())", category: .audio)
                }
            }
        } catch {
            Log.error("[PlaybackPipeline] engine start failed: \(error)", category: .audio)
            graphState = .failed
            stopAccessingCurrentFile()
            audioFile = nil
            isPlaying = false
            return
        }

        configureDelay()
        resetDelayBufferIfActive()

        // Paused-restore path: schedule at the saved position and stop here.
        // The engine is started and the graph is ready at this point, so the
        // deferred seek is applied now (not discarded). Hard constraint: never
        // call playerNode.play() — the restored session must end paused.
        if restorePaused {
            finishRestorePaused(resource: resource, track: track)
            return
        }

        scheduleFile(resource.file)
        guard graphReadyForPlay(scheduledGeneration: scheduledGraphGeneration, operation: "finishStart.play") else {
            failPlaybackRequest(reason: "graph not ready before finishStart play")
            return
        }
        playerNode.play()
        isPlaying = true
        startProgressTimer()

        Log.info(
            "[PlaybackPipeline] item loaded track=\(resource.trackID.uuidString) duration=\(String(format: "%.1f", resource.duration))s engineRunning=\(engine.isRunning)",
            category: .audio
        )
    }

    private func startSpatialRenderer(
        resource: PreparedAudioResource,
        track: Track,
        restorePaused: Bool
    ) {
        let requestedPosition = restorePaused ? (pendingRestorePositionSeconds ?? 0) : 0
        restorePausedGeneration = nil
        pendingRestorePositionSeconds = nil

        let upperBound = duration > 0.5 ? duration - 0.5 : 0
        let position = max(0, min(requestedPosition, upperBound))
        let frame = AVAudioFramePosition(position * sampleRate)
        let provider = AVFilePCMProvider(file: resource.file)
        let segmentID = UUID()

        activeLookaheadEnabled = desiredLookaheadEnabled
        spatialCurrentProvider = provider
        spatialCurrentSegmentID = segmentID
        spatialCurrentLogicalStart = 0
        spatialClockTime = position
        spatialPendingSeek = nil
        spatialPendingBoundary = nil
        startingFramePosition = frame
        currentTime = position
        activeScheduleToken = UUID()

        refreshOutputLatency(force: true)
        AudioAnalysisHub.shared.enableExternalFeed()
        AudioAnalysisHub.shared.setPlaying(!restorePaused)
        rendererPipeline.setVolume(Float(volume))
        rendererPipeline.setAnalysisLeadSeconds(lookaheadSeconds)
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        rendererPipeline.load(
            source: provider,
            sourcePosition: frame,
            // The descriptor anchor represents source time zero; the
            // pipeline adds `sourcePosition` to the first buffer PTS.
            presentationStartSeconds: lookaheadSeconds,
            clockTimeSeconds: position,
            segmentID: segmentID,
            autoplay: !restorePaused
        )

        isPlaying = !restorePaused
        if isPlaying {
            startProgressTimer()
        } else if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }

        // The preparation path can update Now Playing while the player is
        // still paused. Re-publish after the renderer actually starts so
        // macOS sees an active local media session before deciding which
        // AirPods spatial modes to offer.
        NowPlayingService.shared.syncLocalPlaybackState()

        Log.info(
            "[SpatialAudio] renderer loaded track=\(track.id.uuidString) position=\(String(format: "%.3f", position))s duration=\(String(format: "%.1f", duration))s outputDelay=\(String(format: "%.3f", audioOutputDelay))s autoplay=\(!restorePaused)",
            category: .audio
        )
    }

    /// MainActor: complete a paused restore. Schedules the track segment at the
    /// saved position so a later `resume()` plays from there, but leaves the
    /// player node stopped and `isPlaying == false`.
    private func finishRestorePaused(resource: PreparedAudioResource, track: Track) {
        let requested = pendingRestorePositionSeconds ?? 0
        restorePausedGeneration = nil
        pendingRestorePositionSeconds = nil

        let totalFrames = resource.file.length
        // Keep at least ~0.5s of headroom from the end so the segment is valid.
        let upperBound = duration > 0.5 ? duration - 0.5 : 0
        let clampedPosition = max(0, min(requested, upperBound))
        let targetFrame = AVAudioFramePosition(clampedPosition * sampleRate)

        if targetFrame > 0, targetFrame < totalFrames {
            startingFramePosition = targetFrame
            currentTime = clampedPosition
            let frameCount = AVAudioFrameCount(totalFrames - targetFrame)
            scheduleSegment(resource.file, startingFrame: targetFrame, frameCount: frameCount)
        } else {
            startingFramePosition = 0
            currentTime = 0
            scheduleFile(resource.file)
        }

        // HARD CONSTRAINT: no playerNode.play(), no progress timer. Paused only.
        isPlaying = false
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }

        Log.info(
            "[PlaybackPipeline] restored paused track=\(track.id.uuidString) position=\(String(format: "%.1f", currentTime))s duration=\(String(format: "%.1f", duration))s engineRunning=\(engine.isRunning)",
            category: .audio
        )
    }

    /// MainActor: failure handling for a prepare that belongs to the current
    /// generation. Preserves the original behavior — mark availability, log,
    /// stop on this track (no auto-skip). Cancelled / superseded prepares are
    /// dropped silently.
    private func handlePrepareFailureIfCurrent(
        _ error: Error,
        trackID: UUID,
        generation: UInt64
    ) {
        guard generation == playGeneration else { return }
        if error is CancellationError { return }
        if case AudioFilePreparationActor.PrepError.cancelled = error { return }

        // Re-acquire the current track (never captured in the Task).
        guard let track = currentTrack, track.id == trackID else { return }

        switch error {
        case AudioFilePreparationActor.PrepError.missingFile,
             AudioFilePreparationActor.PrepError.bookmarkUnresolved:
            // Resolution failed: mark missing (matches old resolveFileURL path).
            track.availability = .missing
        case AudioFilePreparationActor.PrepError.openFailed:
            // Resolved but failed to open: keep availability (matches old catch).
            break
        default:
            break
        }

        Log.error(
            "[PlaybackPipeline] prepare failed track=\(track.id.uuidString) title=\(track.title) error=\(error)",
            category: .audio
        )
        stopAccessingCurrentFile()
        isPlaying = false
    }

    func pause() {
        guard isPlaying else { return }

        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] pause currentTime=\(String(format: "%.3f", currentTime)) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }
        cancelPendingCompletion()
        if outputBackend == .spatialRenderer {
            if spatialPendingSeek != nil {
                spatialPendingSeek = nil
                smartController.endSeek()
            }
            rendererPipeline.pause()
            AudioAnalysisHub.shared.setPlaying(false)
            isPlaying = false
            stopProgressTimer()
            return
        }
        playerNode.pause()
        resetDelayBufferIfActive()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() {
        guard !isPlaying, audioFile != nil else { return }

        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] resume currentTime=\(String(format: "%.3f", currentTime)) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }
        applyLookaheadPreferenceChangeIfNeeded(reason: "resume")
        if outputBackend == .spatialRenderer {
            // A route can change while the player is paused, when the progress
            // timer is not running. Refresh immediately so the renderer resumes
            // on the current device clock instead of an old explicit UID.
            refreshOutputLatency(force: true)
            rendererPipeline.play()
            AudioAnalysisHub.shared.setPlaying(true)
            isPlaying = true
            startProgressTimer()
            return
        }
        configureDelay()
        resetDelayBufferIfActive()
        guard graphReadyForPlay(scheduledGeneration: scheduledGraphGeneration, operation: "resume.play") else {
            failPlaybackRequest(reason: "graph not ready before resume")
            return
        }
        playerNode.play()
        isPlaying = true
        startProgressTimer()
    }

    func stop() {
        stopPlayback(clearQueue: true)
    }

    private func stopPlayback(clearQueue: Bool) {
        Log.info(
            "[PlaybackPipeline] stopPlayback clearQueue=\(clearQueue) currentTrack=\(currentTrack?.id.uuidString ?? "nil") operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
            category: .audio
        )
        // Drop any armed paused-restore intent: a new load is taking over.
        // restorePausedPlayback re-arms this *after* startPlayback returns, so
        // clearing here only discards stale intent from a superseded load.
        restorePausedGeneration = nil
        pendingRestorePositionSeconds = nil

        invalidatePreparation()
        cancelPendingCompletion()
        invalidateScheduleToken()
        rendererPipeline.stop()
        AudioAnalysisHub.shared.disableExternalFeed()
        spatialCurrentProvider = nil
        spatialCurrentSegmentID = nil
        spatialCurrentLogicalStart = 0
        spatialClockTime = 0
        spatialPendingSeek = nil
        smartController.endSeek()
        AudioAnalysisHub.shared.setPlaying(false)
        playerNode.stop()
        resetDelayBufferIfActive()
        stopProgressTimer()
        stopAccessingCurrentFile()

        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrack = nil
        audioFile = nil
        startingFramePosition = 0

        if clearQueue {
            smartController.stop()
        }
    }

    func seek(to seconds: Double) {
        guard let audioFile = audioFile else {
            return
        }

        let wasPlaying = isPlaying
        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] seek target=\(String(format: "%.3f", seconds)) wasPlaying=\(wasPlaying) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }

        smartController.beginSeek()

        if outputBackend == .spatialRenderer {
            seekSpatialRenderer(to: seconds, file: audioFile, wasPlaying: wasPlaying)
            return
        }

        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBufferIfActive()
        isPlaying = false

        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let totalFrames = audioFile.length

        guard targetFrame >= 0, targetFrame < totalFrames else {
            Log.warning("[AudioDiagnostics] Seek position out of range", category: .audio)
            smartController.endSeek()
            return
        }

        let frameCount = AVAudioFrameCount(totalFrames - targetFrame)

        startingFramePosition = targetFrame
        currentTime = max(0, min(seconds, duration))
        smartController.recordSeek(to: currentTime)

        scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: frameCount)

        if wasPlaying {
            guard graphReadyForPlay(scheduledGeneration: scheduledGraphGeneration, operation: "seek.play") else {
                smartController.endSeek()
                failPlaybackRequest(reason: "graph not ready before seek resume")
                return
            }
            playerNode.play()
            isPlaying = true
            startProgressTimer()
        }
    }

    private func seekSpatialRenderer(
        to seconds: Double,
        file: AVAudioFile,
        wasPlaying: Bool
    ) {
        cancelPendingCompletion()
        invalidateScheduleToken()
        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        guard targetFrame >= 0, targetFrame < file.length else {
            Log.warning("[SpatialAudio] seek target out of range frame=\(targetFrame)", category: .audio)
            smartController.endSeek()
            return
        }

        let position = max(0, min(seconds, duration))
        let provider = AVFilePCMProvider(file: file)
        let segmentID = UUID()
        spatialCurrentProvider = provider
        spatialCurrentSegmentID = segmentID
        spatialCurrentLogicalStart = 0
        spatialClockTime = position
        spatialPendingSeek = SpatialPendingSeek(
            segmentID: segmentID,
            position: position,
            wasPlaying: wasPlaying
        )
        spatialPendingBoundary = nil
        startingFramePosition = targetFrame
        currentTime = position
        smartController.recordSeek(to: currentTime)

        refreshOutputLatency(force: true)
        rendererPipeline.setAnalysisLeadSeconds(lookaheadSeconds)
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        // Drop the old analysis window and stop its processing timer before the
        // asynchronous renderer load can begin. The commit callback above
        // restarts it only after the new timeline wins.
        AudioAnalysisHub.shared.enableExternalFeed()
        AudioAnalysisHub.shared.setPlaying(false)
        stopProgressTimer()
        rendererPipeline.load(
            source: provider,
            sourcePosition: targetFrame,
            // The descriptor anchor represents source time zero; the
            // pipeline adds `sourcePosition` to the first buffer PTS.
            presentationStartSeconds: lookaheadSeconds,
            clockTimeSeconds: position,
            segmentID: segmentID,
            autoplay: wasPlaying
        )
        isPlaying = wasPlaying
    }

    // MARK: - Queue Management

    func updateQueueTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        smartController.updateQueue(tracks: tracks, preservePosition: true)
    }

    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int {
        smartController.insertTracksAfterCurrent(tracks)
    }

    func refreshTracks(_ tracks: [Track]) {
        let refreshedByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard !refreshedByID.isEmpty else { return }

        // Update current track if it was refreshed
        if let currentID = currentTrack?.id, let refreshedTrack = refreshedByID[currentID] {
            currentTrack = refreshedTrack
            duration = refreshedTrack.duration
            NotificationCenter.default.post(name: .playbackTrackDidChange, object: nil)
        }
    }

    func next() {
        syncShuffleStateIfNeeded()
        smartController.nextTrack()
    }

    func previous() {
        syncShuffleStateIfNeeded()

        // Standard behavior: if you're a few seconds in, restart.
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        smartController.previousTrack()
    }

    private func syncShuffleStateIfNeeded() {
        guard activePlaybackOrderModeOverride == nil else { return }
        let enabled = AppSettings.shared.shuffleEnabled
        guard enabled != lastKnownShuffleEnabled else { return }

        lastKnownShuffleEnabled = enabled
        smartController.setShuffle(enabled)
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        lastProgressUpdateUptime = ProcessInfo.processInfo.systemUptime
        lastProgressAudibleTime = currentTime
        lastProgressScheduledToken = scheduleQueue.current?.token

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProgress()
            }
        }

        if let timer = progressTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        applyLookaheadPreferenceChangeIfNeeded(reason: "progressTick")
        refreshOutputLatency()

        let nowUptime = ProcessInfo.processInfo.systemUptime
        let previousUptime = lastProgressUpdateUptime
        let previousAudibleTime = lastProgressAudibleTime
        lastProgressUpdateUptime = nowUptime

        // Drain phase (lookahead only): the player has finished, but the delay
        // buffer is still emptying. Advance the clock from the drain anchors so
        // the UI keeps moving through the tail instead of freezing.
        if let drainStartUptime {
            let elapsed = max(0, nowUptime - drainStartUptime)
            currentTime = min(duration, drainStartTime + elapsed)
            lastProgressAudibleTime = currentTime
            if duration > 0 {
                smartController.updateProgress(currentTime: currentTime, duration: duration)
            }
            return
        }

        if outputBackend == .spatialRenderer {
            updateSpatialRendererProgress()
            return
        }

        guard isPlaying else { return }
        guard playerNode.isPlaying else { return }

        guard let nodeTime = playerNode.lastRenderTime,
            nodeTime.isSampleTimeValid,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return
        }

        // Map the node render clock through the scheduled queue so the time is
        // correct even after a gapless boundary (the node clock keeps counting
        // across items). For the first/only item this equals the legacy formula
        // `startingFramePosition + sampleTime`, so seek/device/lookahead paths are
        // unchanged. The fallback covers the (transient) empty-queue case only.
        let nodeSample = playerTime.sampleTime
        let newTime = scheduleQueue.currentTime(nodeSample: nodeSample)
            ?? (Double(startingFramePosition + nodeSample) / sampleRate)

        currentTime = max(0, min(newTime, duration))
        lastProgressAudibleTime = currentTime

        // A gapless boundary (or seek / reload / device change) re-bases the
        // per-track clock: `currentTime` resets to the new item's position while
        // the node sample clock keeps counting, so a track-time delta across that
        // tick is meaningless (it was producing `clockDeltaMs=-229090.5`-style
        // false positives). Every such discontinuity changes the committed
        // scheduled-item token, so skip the clock-gap check for that one tick and
        // re-baseline on the next.
        let scheduledToken = scheduleQueue.current?.token
        let crossedScheduleBoundary = scheduledToken != lastProgressScheduledToken
        lastProgressScheduledToken = scheduledToken

        if !crossedScheduleBoundary, let previousUptime {
            let timerGap = nowUptime - previousUptime
            let clockDelta = currentTime - previousAudibleTime
            // `audioBehind` is how far the audio render clock fell short of wall
            // time over this interval. A genuine output underrun (HAL overload /
            // dropout) advances the audio clock materially LESS than wall while the
            // node is still playing → audioBehind large. A progress tick merely
            // delayed by a main-thread stall is the opposite: the player keeps
            // rendering on its real-time thread, so when the tick finally fires both
            // wall and audio clocks have advanced together → audioBehind ~0 even
            // though timerGap is large. The previous `timerGap >= 0.24` trigger
            // conflated the two and fired on every first-use UI stall, mislabeling a
            // frozen UI as an audio gap. Only flag a true audio discontinuity here.
            let audioBehind = timerGap - clockDelta
            if playerNode.isPlaying, audioBehind >= 0.12 {
                let contextMenu = ContextMenuDiagnostics.currentStateDescription()
                Log.warning(
                    "[AudioUnderrun] audioBehindMs=\(String(format: "%.1f", audioBehind * 1000)) timerGapMs=\(String(format: "%.1f", timerGap * 1000)) clockDeltaMs=\(String(format: "%.1f", clockDelta * 1000)) playerNodePlaying=\(playerNode.isPlaying) engineRunning=\(isEngineInitialized ? engine.isRunning : false) operation=\(FirstUseHitchDiagnostics.currentOperationStack()) recentEvents=[\(FirstUseHitchDiagnostics.recentEvents())] isPlaying=\(isPlaying) trackID=\(FirstUseHitchDiagnostics.trackIDPrefix(currentTrack?.id)) surface=audio contextMenu=[\(contextMenu)]",
                    category: .audio
                )
            } else if timerGap >= 0.5, LogConfig.mainThreadStallLoggingEnabled {
                // Audio intact; the progress timer was just delayed by a main-thread
                // stall (first-use UI cold start, menu tracking, etc.). Opt-in
                // diagnostic only — explicitly NOT an audio gap.
                Log.info(
                    "[ProgressTimerStall] timerGapMs=\(String(format: "%.1f", timerGap * 1000)) clockDeltaMs=\(String(format: "%.1f", clockDelta * 1000)) audioIntact=true operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                    category: .perf
                )
            }
        }

        // Update smart controller with progress
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }

        // As the current track nears its end, prefetch + gapless-schedule the
        // next one so the join is seamless.
        maybeTriggerGaplessPrefetch()
    }

    private func updateSpatialRendererProgress() {
        guard isPlaying, spatialPendingSeek == nil else { return }

        let mediaTime = spatialClockTime - spatialCurrentLogicalStart
        currentTime = max(0, min(mediaTime, duration))
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }

        maybeTriggerGaplessPrefetch()

        guard duration > 0, mediaTime >= duration - 0.02 else { return }
        if let pending = spatialPendingBoundary {
            if let reason = spatialGaplessBoundaryBlockReason(pending: pending) {
                logGaplessFallback(
                    reason,
                    context: "renderer boundary track=\(pending.descriptor.id.uuidString.prefix(8))"
                )
                abandonSpatialGaplessAndFinalize()
            } else {
                commitSpatialGaplessBoundary(pending)
            }
            return
        }

        let token = activeScheduleToken
        // The progress observer intentionally accepts a 20 ms boundary
        // tolerance. Include any not-yet-reached media tail in the drain so a
        // tick just before `duration` can never pause the renderer early.
        let drainDelay = lookaheadSeconds + max(0, duration - mediaTime)
        if drainDelay > 0 {
            beginDrain(delaySeconds: drainDelay, token: token)
        } else {
            finalizePlaybackCompletion(token: token)
        }
    }

    // MARK: - Gapless Prefetch

    /// Decide whether to prefetch the upcoming track for a seamless join. Called
    /// every progress tick; the guards make it fire at most once per current item.
    private func maybeTriggerGaplessPrefetch() {
        guard gaplessEnabled else { return }
        guard isPlaying else { return }
        guard !prefetchAttemptedForCurrentItem, prefetchTask == nil else { return }
        // Only prefetch when exactly the current item is scheduled (a pending
        // next already covers the boundary).
        if outputBackend == .spatialRenderer {
            guard spatialPendingBoundary == nil else { return }
        } else {
            guard scheduleQueue.count == 1 else { return }
        }
        guard duration > 0 else { return }

        // Next track must be deterministic. Repeat-one and stop-after-track do not
        // advance to a different track, so never prefetch in those modes.
        let playbackOrderMode = effectivePlaybackOrderMode
        if playbackOrderMode == .stopAfterTrack { return }
        if playbackOrderMode == .repeatOne { return }

        let remaining = duration - currentTime
        guard remaining <= Self.gaplessPrefetchLeadSeconds else { return }

        triggerGaplessPrefetch()
    }

    private func triggerGaplessPrefetch() {
        prefetchAttemptedForCurrentItem = true

        guard let nextTrack = smartController.peekNextForGapless() else {
            logGaplessFallback(.noNext, context: "prefetch")
            return
        }

        let generation = scheduleGeneration
        let request = makePrepRequest(for: nextTrack)

        gaplessLog("[Gapless] prefetch started track=\(nextTrack.id.uuidString.prefix(8)) title=\(nextTrack.title) generation=\(generation)")

        // Task {} (not detached) inherits this @MainActor context: the heavy work
        // runs off-main inside the actor, then resumes on main. Captures only
        // Sendable values + self (never the Track).
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.prepActor.prepare(request)
                self.finishPrefetchIfCurrent(resource, generation: generation)
            } catch {
                self.handlePrefetchFailure(error, trackID: request.trackID, generation: generation)
            }
        }
    }

    /// MainActor: a prefetch finished preparing. Validate it is still wanted and
    /// format-compatible, then schedule it onto the node. Any failure releases the
    /// resource's scope and leaves the boundary to the legacy completion path.
    private func finishPrefetchIfCurrent(_ resource: PreparedAudioResource, generation: UInt64) {
        prefetchTask = nil

        guard generation == scheduleGeneration else {
            logGaplessFallback(.generationMismatch, context: "prepared track=\(resource.trackID.uuidString.prefix(8))")
            releaseSecurityScope(for: resource)
            return
        }
        let canAcceptPreparedNext = outputBackend == .spatialRenderer
            ? spatialPendingBoundary == nil
            : scheduleQueue.count == 1
        guard gaplessEnabled, isPlaying, canAcceptPreparedNext else {
            logGaplessFallback(.stateChanged, context: "prepared track=\(resource.trackID.uuidString.prefix(8))")
            releaseSecurityScope(for: resource)
            return
        }
        if outputBackend == .spatialRenderer {
            scheduleNextSpatial(resource)
            return
        }
        guard let currentFormat = audioFile?.processingFormat,
              formatsGaplessCompatible(currentFormat, resource.file.processingFormat) else {
            logGaplessFallback(.formatMismatch, context: "prepared track=\(resource.trackID.uuidString.prefix(8))")
            releaseSecurityScope(for: resource)
            return
        }

        gaplessLog("[Gapless] prefetch prepared track=\(resource.trackID.uuidString.prefix(8)) duration=\(String(format: "%.1f", resource.duration)) generation=\(generation)")
        scheduleNextGapless(resource)
    }

    // MARK: - AAC Gapless Trim (Phase 1.2)

    /// One resolved AAC trim: frames to skip at the head (encoder priming) and
    /// drop at the tail (encoder padding), plus the resulting scheduled segment.
    private struct AACTrimDecision {
        let headTrimFrames: AVAudioFramePosition
        let tailTrimFrames: AVAudioFramePosition
        let scheduledFrameCount: AVAudioFrameCount
        let scheduledDuration: Double
    }

    /// Decide whether to skip the prefetched AAC item's encoder priming/padding at
    /// a gapless join. Returns `nil` (and logs a precise `[AACGapless] skipped
    /// reason=…`) whenever trimming is disabled, the file is not AAC, metadata is
    /// missing, the decoder already trimmed it, or the values fail safety checks —
    /// in which case the caller schedules the full file exactly as Phase 1 did.
    /// Only AAC files with reliable packet-table metadata are ever trimmed; WAV /
    /// FLAC / MP3 and single-track playback are untouched.
    private func resolveAACTrim(_ resource: PreparedAudioResource) -> AACTrimDecision? {
        let idTag = resource.trackID.uuidString.prefix(8)

        guard AppSettings.shared.audioAACGaplessTrimEnabled else {
            gaplessLog("[AACGapless] skipped reason=disabled track=\(idTag)")
            return nil
        }

        guard let info = resource.aacGaplessInfo else {
            gaplessLog("[AACGapless] skipped reason=noMetadata track=\(idTag)")
            return nil
        }

        guard info.isAAC else {
            // MP3 / WAV / FLAC / ALAC: diagnostics only, never trimmed (Phase 1.2
            // scope is AAC). Surface any priming the container reported.
            gaplessLog("[AACGapless] skipped reason=unsupportedContainer track=\(idTag) format=\(info.formatTag) primingFrames=\(info.primingFrames) paddingFrames=\(info.paddingFrames) source=\(info.source)")
            return nil
        }

        guard info.hasGaplessPadding else {
            gaplessLog("[AACGapless] skipped reason=noMetadata track=\(idTag) format=\(info.formatTag) source=\(info.source)")
            return nil
        }

        let priming = info.primingFrames
        let padding = info.paddingFrames
        let valid = info.validFrames

        gaplessLog("[AACGapless] track=\(idTag) primingFrames=\(priming) paddingFrames=\(padding) source=\(info.source)")

        // Determine how `AVAudioFile` presents the decoded stream so we never
        // double-trim: compare the decoded length against the three plausible
        // accountings and pick the closest. If none matches within tolerance the
        // metadata is inconsistent with the decode → fall back (no trim).
        let pcm = Int64(resource.frameLength)
        let candIncludesBoth = valid + priming + padding   // priming + padding still in PCM
        let candPaddingOnly = valid + padding              // priming consumed by edit list
        let candFullyTrimmed = valid                       // decoder already removed both
        let dBoth = abs(pcm - candIncludesBoth)
        let dPadding = abs(pcm - candPaddingOnly)
        let dTrimmed = abs(pcm - candFullyTrimmed)
        let minDiff = min(dBoth, dPadding, dTrimmed)

        let tolerance: Int64 = 256  // ~6ms @44.1k; far smaller than priming (~2112)
        guard minDiff <= tolerance else {
            // Metadata can't be reconciled with the decoded length — kept
            // unconditional (this is the "unsafe AAC trim metadata" signal).
            Log.warning(
                "[AACGapless] skipped reason=unsafeValues track=\(idTag) pcm=\(pcm) valid=\(valid) priming=\(priming) padding=\(padding)",
                category: .audio
            )
            return nil
        }

        let head: Int64
        let tail: Int64
        if minDiff == dBoth {
            head = priming
            tail = padding
        } else if minDiff == dPadding {
            head = 0
            tail = padding
        } else {
            // Decoder already removed priming+padding (pcm ≈ validFrames): nothing
            // to trim. Not an error — fall back to a full-file schedule.
            gaplessLog("[AACGapless] skipped reason=noMetadata track=\(idTag) detail=decoderAlreadyTrimmed pcm=\(pcm) valid=\(valid)")
            return nil
        }

        // Safety: trims non-negative, and head+tail must leave a positive segment
        // that fits within the file's total frames.
        let total = Int64(resource.frameLength)
        guard head >= 0, tail >= 0, head + tail < total else {
            Log.warning(
                "[AACGapless] skipped reason=unsafeValues track=\(idTag) head=\(head) tail=\(tail) total=\(total)",
                category: .audio
            )
            return nil
        }
        let scheduled = total - head - tail
        guard scheduled > 0, scheduled <= Int64(AVAudioFrameCount.max) else {
            Log.warning(
                "[AACGapless] skipped reason=unsafeValues track=\(idTag) scheduledFrames=\(scheduled) total=\(total)",
                category: .audio
            )
            return nil
        }

        let durationSec = resource.sampleRate > 0 ? Double(scheduled) / resource.sampleRate : resource.duration
        let headMs = resource.sampleRate > 0 ? Double(head) / resource.sampleRate * 1000 : 0
        let tailMs = resource.sampleRate > 0 ? Double(tail) / resource.sampleRate * 1000 : 0
        gaplessLog("[AACGapless] applying headTrimFrames=\(head) tailTrimFrames=\(tail) track=\(idTag) headMs=\(String(format: "%.1f", headMs)) tailMs=\(String(format: "%.1f", tailMs)) scheduledFrames=\(scheduled)")

        return AACTrimDecision(
            headTrimFrames: AVAudioFramePosition(head),
            tailTrimFrames: AVAudioFramePosition(tail),
            scheduledFrameCount: AVAudioFrameCount(scheduled),
            scheduledDuration: durationSec
        )
    }

    /// MainActor: append the prepared next item after the current one on the
    /// player node, without stopping/rebuilding. The node renders current→next
    /// with no gap. Uses `.dataPlayedBack` so this item's completion fires at the
    /// audible end (the current item keeps its existing completion callback).
    private func scheduleNextSpatial(_ resource: PreparedAudioResource) {
        let trim = resolveAACTrim(resource)
        let startFrame = trim?.headTrimFrames ?? 0
        let frameCount = trim?.scheduledFrameCount
            ?? AVAudioFrameCount(resource.file.length)
        let itemDuration = trim?.scheduledDuration
            ?? (resource.sampleRate > 0 ? Double(frameCount) / resource.sampleRate : resource.duration)
        let provider = AVFilePCMProvider(
            file: resource.file,
            startingFrame: startFrame,
            frameCount: frameCount
        )

        guard let descriptor = rendererPipeline.append(source: provider) else {
            logGaplessFallback(
                .notScheduledInTime,
                context: "renderer append failed track=\(resource.trackID.uuidString.prefix(8))"
            )
            releaseSecurityScope(for: resource)
            return
        }

        let token = UUID()
        prefetchedResource = resource
        spatialPendingBoundary = SpatialPendingBoundary(
            trackID: resource.trackID,
            descriptor: descriptor,
            provider: provider,
            token: token,
            duration: itemDuration,
            startFrameInFile: startFrame
        )
        gaplessLog(
            "[SpatialGapless] queued next track=\(resource.trackID.uuidString.prefix(8)) ptsStart=\(String(format: "%.6f", descriptor.presentationStartSeconds)) duration=\(String(format: "%.3f", itemDuration)) headTrim=\(startFrame)"
        )
    }

    private func scheduleNextGapless(_ resource: PreparedAudioResource) {
        guard let startNodeSample = scheduleQueue.nextStartNodeSample else {
            logGaplessFallback(.notScheduledInTime, context: "no current item to append after")
            releaseSecurityScope(for: resource)
            return
        }

        let token = UUID()

        // AAC gapless trim (Phase 1.2): when the next item is AAC with reliable
        // packet-table metadata, skip its encoder priming at the head and drop its
        // padding at the tail by scheduling only the musical segment. `nil` means
        // schedule the full file exactly as Phase 1 did (WAV/FLAC/MP3 and any AAC
        // without usable metadata). Display origin stays 0 even when we skip the
        // head priming — the trimmed start IS this track's time 0 — so the shared
        // progress formula and the WAV/FLAC/seek paths are untouched.
        let trim = resolveAACTrim(resource)
        let frameCount = trim?.scheduledFrameCount ?? AVAudioFrameCount(resource.file.length)
        let itemDuration = trim?.scheduledDuration ?? resource.duration

        let item = ScheduledItem(
            trackID: resource.trackID,
            token: token,
            startNodeSample: startNodeSample,
            startFrameInFile: 0,
            frameCount: frameCount,
            sampleRate: resource.sampleRate,
            duration: itemDuration
        )

        // Adopt the prefetched scope owner BEFORE scheduling so there is a single
        // owner to release if anything later discards it.
        prefetchedResource = resource
        gaplessLog("[Gapless] adopt prefetched resource track=\(resource.trackID.uuidString.prefix(8)) lease=owned")

        scheduleQueue.append(item)

        let completion = playbackBoundaryCallback(token: token)
        if let trim {
            playerNode.scheduleSegment(
                resource.file,
                startingFrame: trim.headTrimFrames,
                frameCount: frameCount,
                at: nil,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        } else {
            playerNode.scheduleFile(
                resource.file,
                at: nil,
                completionCallbackType: .dataPlayedBack,
                completionHandler: completion
            )
        }

        let headTrim = trim?.headTrimFrames ?? 0
        gaplessLog("[Gapless] scheduled next track=\(resource.trackID.uuidString.prefix(8)) startNodeSample=\(startNodeSample) frames=\(frameCount) headTrim=\(headTrim)")

        // Boundary invariant: the next item is scheduled exactly at the current
        // item's end on the node clock, so the difference must be 0. A non-zero
        // value would mean the queue's node-sample math is wrong, so surface it
        // unconditionally; the expected diffFrames=0 case is gated behind verbose.
        let currentEndNodeSample = scheduleQueue.current?.endNodeSample ?? startNodeSample
        let boundaryDiffFrames = startNodeSample - currentEndNodeSample
        let boundaryDiffMs = resource.sampleRate > 0
            ? Double(boundaryDiffFrames) / resource.sampleRate * 1000
            : 0
        if boundaryDiffFrames != 0 {
            Log.warning(
                "[GaplessBoundary] non-zero gap currentEndNodeSample=\(currentEndNodeSample) nextStartNodeSample=\(startNodeSample) diffFrames=\(boundaryDiffFrames) diffMs=\(String(format: "%.3f", boundaryDiffMs))",
                category: .audio
            )
        } else {
            gaplessLog("[GaplessBoundary] currentEndNodeSample=\(currentEndNodeSample) nextStartNodeSample=\(startNodeSample) diffFrames=0 diffMs=\(String(format: "%.3f", boundaryDiffMs))")
        }

        // DEBUG-only: measure the real audio content at the seam (current tail vs
        // next head) off-main, so an audible gap can be attributed to file content
        // (encoder delay / padding / leading silence) rather than the schedule.
        // Gated behind gaplessVerbose so the probe doesn't even read files in a
        // normal Debug run.
        #if DEBUG
        if LogConfig.gaplessVerbose, let currentURL = currentFileURL, let currentItem = scheduleQueue.current {
            let currentTailEndFrame = currentItem.startFrameInFile + AVAudioFramePosition(currentItem.frameCount)
            let currentTrackID = currentItem.trackID
            let currentProbeURL = currentURL
            let nextProbeURL = resource.resolvedURL
            let nextTrackID = resource.trackID
            Task.detached(priority: .utility) {
                GaplessProbe.run(
                    currentURL: currentProbeURL,
                    currentTailEndFrame: currentTailEndFrame,
                    currentTrackID: currentTrackID,
                    nextURL: nextProbeURL,
                    nextTrackID: nextTrackID
                )
            }
        }
        #endif
    }

    private func handlePrefetchFailure(_ error: Error, trackID: UUID, generation: UInt64) {
        prefetchTask = nil
        if error is CancellationError { return }
        if case AudioFilePreparationActor.PrepError.cancelled = error { return }
        logGaplessFallback(.prefetchFailed, context: "track=\(trackID.uuidString.prefix(8)) error=\(error)")
        // A failed prepare never returns a resource, so there is no scope to free.
    }

    // MARK: - Playback Completion

    private func playbackBoundaryHandler(token: UUID) -> @Sendable () -> Void {
        { [weak self] in
            self?.submitPlaybackBoundaryEvent(token: token)
        }
    }

    private func playbackBoundaryCallback(token: UUID) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak self] _ in
            self?.submitPlaybackBoundaryEvent(token: token)
        }
    }

    nonisolated private func submitPlaybackBoundaryEvent(token: UUID) {
        Task { @MainActor [weak self] in
            self?.handlePlaybackCompletion(token: token)
        }
    }

    private func handlePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        guard isPlaying else { return }

        // Gapless boundary (checked first, even with lookahead): the next item
        // is already scheduled and rendering on the same player node. The node
        // renders back-to-back items seamlessly regardless of any downstream
        // delay node, so we commit the logical/UI boundary here. With lookahead
        // the UI update precedes the audible transition by ~lookaheadSeconds,
        // which is acceptable.
        if scheduleQueue.current?.token == token, let pending = scheduleQueue.pendingNext {
            if let reason = gaplessBoundaryBlockReason(pending: pending) {
                logGaplessFallback(reason, context: "boundary track=\(pending.trackID.uuidString.prefix(8))")
                // The scheduled-but-unwanted next is already on the node; stop and
                // run the normal decision (reload the correct track, or stop).
                abandonGaplessAndFinalize(token: token)
                return
            }
            commitGaplessBoundary(pending: pending)
            return
        }

        // No gapless pending. With lookahead active, the player finishes
        // ~lookahead seconds before the audio is actually heard. Defer finalize
        // so the buffered tail plays out (no truncated ending / premature track
        // switch).
        let delaySeconds = lookaheadSeconds
        if delaySeconds > 0 {
            beginDrain(delaySeconds: delaySeconds, token: token)
            return
        }

        // No prefetched next (or token is a stale/cleared item): legacy
        // completion — repeat-one, stop-after-track, auto-advance, or queue end.
        finalizePlaybackCompletion(token: token)
    }

    private func beginDrain(delaySeconds: Double, token: UUID) {
        cancelPendingCompletion()
        drainStartUptime = ProcessInfo.processInfo.systemUptime
        drainStartTime = duration
        currentTime = drainStartTime

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            self.finalizePlaybackCompletion(token: token)
        }
    }

    private func finalizePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        cancelPendingCompletion()
        stopProgressTimer()

        Log.info("[PlaybackPipeline] Playback completed: \(currentTrack?.title ?? "unknown")", category: .audio)

        if outputBackend == .spatialRenderer {
            rendererPipeline.pause()
            AudioAnalysisHub.shared.setPlaying(false)
        }

        let playbackOrderMode = effectivePlaybackOrderMode

        if playbackOrderMode == .stopAfterTrack {
            smartController.finishCurrentTrackForStopAfterTrack()
            isPlaying = false
            currentTime = duration
            return
        }

        if playbackOrderMode == .repeatOne, currentTrack != nil {
            smartController.replayCurrentTrackAfterCompletion()
            return
        }

        // Auto-advance via smart controller, or stop at queue end.
        if smartController.autoAdvance() == nil {
            isPlaying = false
            currentTime = duration
        }
    }

    // MARK: - Gapless Boundary

    private func spatialGaplessBoundaryBlockReason(
        pending: SpatialPendingBoundary
    ) -> GaplessFallbackReason? {
        if !AppSettings.shared.audioGaplessSchedulingEnabled { return .disabled }
        let playbackOrderMode = effectivePlaybackOrderMode
        if playbackOrderMode == .stopAfterTrack { return .stopAfterTrack }
        if playbackOrderMode == .repeatOne { return .repeatOne }
        guard let predicted = smartController.peekNextForGapless() else { return .noNext }
        guard predicted.id == pending.trackID else { return .predictionMismatch }
        return nil
    }

    private func commitSpatialGaplessBoundary(_ pending: SpatialPendingBoundary) {
        guard let resource = prefetchedResource,
              resource.trackID == pending.trackID else {
            logGaplessFallback(
                .notScheduledInTime,
                context: "renderer boundary missing prefetched resource"
            )
            abandonSpatialGaplessAndFinalize()
            return
        }

        // The logical/UI boundary intentionally leads the audible renderer PTS
        // by the configured delay, matching the legacy playerNode -> delayNode
        // behavior. Keep the outgoing lease alive through that short audible
        // tail so an automatic renderer flush can still re-read it.
        let outgoingLease = currentFileLease
        prefetchedResource = nil
        currentFileURL = resource.resolvedURL
        currentFileLease = resource.lease
        audioFile = resource.file
        sampleRate = resource.sampleRate
        duration = pending.duration
        startingFramePosition = pending.startFrameInFile
        spatialCurrentProvider = pending.provider
        spatialCurrentSegmentID = pending.descriptor.id
        spatialCurrentLogicalStart = pending.descriptor.presentationStartSeconds - lookaheadSeconds
        spatialPendingBoundary = nil
        activeScheduleToken = pending.token
        prefetchAttemptedForCurrentItem = false
        currentTime = max(0, min(spatialClockTime - spatialCurrentLogicalStart, duration))

        guard let advancedTrack = smartController.commitGaplessAdvance() else {
            Log.error(
                "[SpatialGapless] commit found no predicted next track; stopping renderer",
                category: .audio
            )
            rendererPipeline.stop()
            stopProgressTimer()
            isPlaying = false
            outgoingLease?.release()
            currentFileLease?.release()
            currentFileLease = nil
            currentFileURL = nil
            return
        }

        advancedTrack.availability = resource.newAvailability
        if let refreshed = resource.refreshedLocator {
            advancedTrack.mediaLocator = refreshed
            onAudioLocatorResolved?(advancedTrack.id, refreshed, resource.newAvailability)
        }
        releaseOutgoingSpatialScopeAfterAudibleBoundary(
            lease: outgoingLease,
            delay: lookaheadSeconds
        )

        gaplessLog(
            "[SpatialGapless] boundary committed track=\(advancedTrack.id.uuidString) title=\(advancedTrack.title) logicalStart=\(String(format: "%.6f", spatialCurrentLogicalStart)) duration=\(String(format: "%.3f", duration))"
        )
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }
    }

    private func releaseOutgoingSpatialScopeAfterAudibleBoundary(
        lease: SecurityScopedResourceLease?,
        delay: Double
    ) {
        guard let lease else { return }
        if delay <= 0 {
            lease.release()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            lease.release()
        }
    }

    private func abandonSpatialGaplessAndFinalize() {
        if let currentSegmentID = spatialCurrentSegmentID {
            rendererPipeline.discardSegments(after: currentSegmentID)
        }
        releasePrefetchedResource(reason: "rendererBoundaryFallback")
        spatialPendingBoundary = nil
        let token = activeScheduleToken
        let mediaTime = spatialClockTime - spatialCurrentLogicalStart
        let drainDelay = lookaheadSeconds + max(0, duration - mediaTime)
        if drainDelay > 0 {
            beginDrain(delaySeconds: drainDelay, token: token)
        } else {
            finalizePlaybackCompletion(token: token)
        }
    }

    /// Returns a reason the pre-scheduled `pending` item must NOT play through
    /// gaplessly (nil = good to commit). Re-derives the natural-advance decision
    /// at the boundary so a mid-track settings/queue change is honored.
    private func gaplessBoundaryBlockReason(pending: ScheduledItem) -> GaplessFallbackReason? {
        if !AppSettings.shared.audioGaplessSchedulingEnabled { return .disabled }
        let playbackOrderMode = effectivePlaybackOrderMode
        if playbackOrderMode == .stopAfterTrack { return .stopAfterTrack }
        if playbackOrderMode == .repeatOne { return .repeatOne }
        guard let predicted = smartController.peekNextForGapless() else { return .noNext }
        guard predicted.id == pending.trackID else { return .predictionMismatch }
        return nil
    }

    /// Commit a natural gapless boundary: the audio for `pending` is already
    /// rendering on the node. Transfer scope + audio state to it, advance the
    /// queue, and advance the smart controller's logical/session state — all
    /// WITHOUT stopping or rebuilding the node. `currentTrack` (and therefore
    /// theme/lyrics/Now Playing) updates exactly as on the legacy advance path.
    private func commitGaplessBoundary(pending: ScheduledItem) {
        guard let resource = prefetchedResource else {
            logGaplessFallback(.notScheduledInTime, context: "missing prefetched resource at commit")
            abandonGaplessAndFinalize(token: activeScheduleToken)
            return
        }

        // 1. Transfer security-scope + audio state to the new current item.
        //    Release the outgoing current's scope (single site), then adopt the
        //    prefetched scope into the current-file bookkeeping (no double-release).
        stopAccessingCurrentFile()
        prefetchedResource = nil
        currentFileURL = resource.resolvedURL
        currentFileLease = resource.lease
        audioFile = resource.file
        sampleRate = resource.sampleRate
        // Use the scheduled item's duration, which reflects any AAC head/tail trim
        // (== resource.duration when the item was scheduled untrimmed). This keeps
        // the scrubber's total aligned with the actually-scheduled audio so it
        // reaches 100% exactly at the audible boundary.
        duration = pending.duration
        startingFramePosition = pending.startFrameInFile
        currentTime = 0

        // 2. Promote the queue: drop the finished item; `pending` becomes current.
        scheduleQueue.advance()
        activeScheduleToken = pending.token
        prefetchAttemptedForCurrentItem = false

        // 3. Advance logical/session state WITHOUT restarting audio. Sets
        //    currentTrack = next via onTrackChanged (posts .playbackTrackDidChange);
        //    never calls onPlayTrack.
        guard let advancedTrack = smartController.commitGaplessAdvance() else {
            // Pre-validated to have a next; reaching here is an unexpected race.
            Log.error(
                "[Gapless] commit found no next despite a scheduled pending item; stopping",
                category: .audio
            )
            playerNode.stop()
            resetGaplessSchedulingState(reason: "commitNoNext")
            stopProgressTimer()
            isPlaying = false
            return
        }

        // 4. Apply availability / refreshed bookmark to the new track (matches
        //    finishStart). advancedTrack.id == resource.trackID by construction.
        advancedTrack.availability = resource.newAvailability
        if let refreshed = resource.refreshedLocator {
            advancedTrack.mediaLocator = refreshed
            onAudioLocatorResolved?(advancedTrack.id, refreshed, resource.newAvailability)
        }

        gaplessLog("[Gapless] adopt current-file from prefetch track=\(advancedTrack.id.uuidString.prefix(8)) lease=\(currentFileLease != nil)")
        gaplessLog("[Gapless] boundary committed track=\(advancedTrack.id.uuidString) title=\(advancedTrack.title) duration=\(String(format: "%.1f", duration))")

        // 5. Keep playing; the node continues rendering the new item with no stop
        //    or rebuild. The progress timer prefetches the following track as this
        //    one nears its end.
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }
    }

    /// The pre-scheduled next item must not play (a mid-track change made it the
    /// wrong choice). Stop the node — which clears the scheduled item — drop the
    /// gapless schedule, then run the normal completion decision (reload the
    /// correct track, or stop). Only reached on an actual settings/queue change.
    private func abandonGaplessAndFinalize(token: UUID) {
        playerNode.stop()
        resetGaplessSchedulingState(reason: "boundaryFallback")
        finalizePlaybackCompletion(token: token)
    }

    // MARK: - File Access

    private func stopAccessingCurrentFile() {
        currentFileLease?.release()
        currentFileLease = nil
        currentFileURL = nil
    }

    // MARK: - Queue Access for Fullscreen Queue View

    func currentQueueTracks() -> [Track] {
        return smartController.getCurrentQueue()
    }

    func currentQueueDisplayIndex() -> Int? {
        return smartController.getCurrentQueueIndex()
    }

    func playTrackFromQueue(_ track: Track) {
        smartController.jumpToTrackInQueue(track)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        activePlaybackOrderModeOverride = nil
        AppSettings.shared.shuffleEnabled = enabled
        lastKnownShuffleEnabled = enabled
        smartController.setShuffle(enabled)
    }

    func discardCurrentPlaybackSessionStatsOnce() {
        smartController.discardCurrentSessionStatsOnFinalizeOnce()
    }

    func prepareForTermination() {
        smartController.prepareForTermination()
        rendererPipeline.stop()
        AudioAnalysisHub.shared.setPlaying(false)
        AudioAnalysisHub.shared.disableExternalFeed()
    }

}

//
//  RendererPlaybackPipeline.swift
//  myPlayer2
//
//  Queue-confined AVSampleBufferAudioRenderer pipeline used by the real player.
//  The verified demo established the renderer configuration; this production
//  version adds a recoverable multi-track timeline, bounded feed, analysis
//  timing, route-change recovery, and stalled-renderer rebuilding.
//

import AVFoundation
import Foundation
import os

protocol RendererPCMProvider: AnyObject, Sendable {
    nonisolated var sourceChannelCount: Int { get }
    nonisolated var sourceSampleRate: Double { get }
    nonisolated var sourceDSPFormat: DSPAudioFormat { get }
    nonisolated var totalFrames: AVAudioFramePosition { get }

    nonisolated func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM?
    nonisolated func seek(to position: AVAudioFramePosition) throws
    nonisolated func setDSPReadAheadEnabled(_ enabled: Bool)
    /// Reads future PCM without consuming the live decode cursor. Providers
    /// may cache this prefix so FIR compensation does not repeatedly seek.
    nonisolated func peekChunk(
        at position: AVAudioFramePosition,
        maxFrames: AVAudioFrameCount,
        restoringTo restorePosition: AVAudioFramePosition
    ) throws -> CanonicalPCM?
}

nonisolated extension RendererPCMProvider {
    func setDSPReadAheadEnabled(_ enabled: Bool) {}

    func peekChunk(
        at position: AVAudioFramePosition,
        maxFrames: AVAudioFrameCount,
        restoringTo restorePosition: AVAudioFramePosition
    ) throws -> CanonicalPCM? {
        do {
            try seek(to: position)
            let pcm = try nextChunk(maxFrames: maxFrames)
            try seek(to: restorePosition)
            return pcm
        } catch {
            try seek(to: restorePosition)
            throw error
        }
    }

    /// Providers without a native layout source remain explicitly unknown.
    /// In particular, channel count alone never implies 5.1/7.1 speaker order.
    var sourceDSPFormat: DSPAudioFormat {
        DSPAudioFormat(
            sampleRate: sourceSampleRate,
            channelCount: sourceChannelCount,
            rawLayoutData: nil,
            channelLabels: nil,
            layoutIsKnown: false
        )
    }
}

enum RendererPipelineError: Error {
    case rendererFailed(underlying: Error?)
    case sourceError(underlying: Error)
    case unsupportedFormat(channels: Int, sampleRate: Double)
    case noSource
}

/// One renderer rebuild is allowed for a continuous fault. Only observed clock
/// advancement proves that the rebuilt output recovered and opens the budget
/// for a later, independent fault.
nonisolated struct RendererFailureRecoveryBudget: Sendable {
    private(set) var hasAttemptedRecovery = false

    mutating func beginRecoveryAttempt() -> Bool {
        guard !hasAttemptedRecovery else { return false }
        hasAttemptedRecovery = true
        return true
    }

    mutating func observeClock(
        previous: Double,
        current: Double,
        rendererIsRendering: Bool
    ) -> Bool {
        guard rendererIsRendering,
              previous.isFinite,
              current.isFinite,
              current > previous + 0.05 else {
            return false
        }
        hasAttemptedRecovery = false
        return true
    }

    mutating func beginNewRequest() {
        hasAttemptedRecovery = false
    }
}

/// Thread-safe identity checked by callbacks delivered outside pipelineQueue.
nonisolated final class RendererTimelineGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()

    func advance() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        value = UUID()
        return value
    }

    func current() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == candidate
    }
}

nonisolated struct RendererSegmentDescriptor: Sendable, Equatable {
    let id: UUID
    let presentationStartSeconds: Double
    let presentationEndSeconds: Double

    var duration: Double {
        max(0, presentationEndSeconds - presentationStartSeconds)
    }
}

nonisolated enum RendererRecoveryTimeline {
    static func segmentIndex(
        in descriptors: [RendererSegmentDescriptor],
        clockSeconds: Double,
        leadSeconds: Double
    ) -> Int? {
        descriptors.firstIndex {
            $0.presentationEndSeconds - leadSeconds > clockSeconds + 0.000_001
        }
    }

    static func sourceFrame(
        clockSeconds: Double,
        segmentStartSeconds: Double,
        leadSeconds: Double,
        sampleRate: Double,
        totalFrames: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let logicalStart = segmentStartSeconds - leadSeconds
        let relativeSeconds = max(0, clockSeconds - logicalStart)
        // Subtracting PTS origins can put an exact frame infinitesimally below
        // its integer value. Preserve that frame while still flooring real offsets.
        let requested = AVAudioFramePosition((relativeSeconds * sampleRate + 0.000_001).rounded(.down))
        return max(0, min(requested, totalFrames))
    }

    static func nextPresentationTime(
        clockSeconds: Double,
        segmentStartSeconds: Double,
        leadSeconds: Double
    ) -> Double {
        max(segmentStartSeconds, clockSeconds + leadSeconds)
    }
}

nonisolated final class RendererPlaybackPipeline: @unchecked Sendable {
    private static let pipelineLog = Logger(
        subsystem: "kmg.myplayer2",
        category: "renderer-pipeline"
    )

    static let targetAheadSeconds: Double = 1.5
    /// Queued output depth while the DSP chain is on. A parameter edit can only
    /// take effect where the queued output ends, so this depth is also how long
    /// the change waits before it is audible. It exists to absorb producer
    /// hiccups, and the 30 Hz top-up below refills it, so it stays short.
    private static let dspTargetAheadSeconds: Double = 0.25
    /// Feed top-up cadence. Independent of the ahead target so a deep queue does
    /// not also mean a slow refill after a flush, a seek or a dry renderer.
    private static let feedTopUpInterval: TimeInterval = 1.0 / 30.0
    static let chunkFrames: AVAudioFrameCount = 8192
    static let enqueueBlockFrames: Int = 2048
    private static let dspLedgerByteLimit = 32 * 1_024 * 1_024
    private static let dspFutureByteBudget = 24 * 1_024 * 1_024
    private static let dspWarmupByteLimit = 16 * 1_024 * 1_024
    private static let dspReplacementByteLimit = 64 * 1_024 * 1_024
    /// Bounded chase of blocks produced while a replacement was preparing.
    private static let dspPreparationMaximumExtensions = 3
    /// Headroom the swap point must keep ahead of the play clock before the
    /// queued output is flushed and replaced. The whole flush round trip has to
    /// fit inside this window; a shorter one lets the renderer run dry, which is
    /// audible. When it cannot be met the swap waits for the queue horizon
    /// instead of interrupting playback.
    private static let dspFlushSafetySeconds: Double = 0.15
    // Visualizer analysis delivers fine-grained slices (≈23ms @ 44.1kHz)
    // so downstream FFT/LED calculations advance continuously without burstiness.
    static let analysisChunkFrames: Int = 1024

    var dspOutputBoundaryCountForTesting: Int {
        if DispatchQueue.getSpecific(key: pipelineQueueKey) != nil {
            return dspOutputBoundaries.count
        }
        return pipelineQueue.sync { dspOutputBoundaries.count }
    }

    var synchronizerAnchorMutationCountForTesting: Int {
        if DispatchQueue.getSpecific(key: pipelineQueueKey) != nil {
            return synchronizerAnchorMutationCount
        }
        return pipelineQueue.sync { synchronizerAnchorMutationCount }
    }

    var dspOutputHistoryIsNonoverlappingForTesting: Bool {
        pipelineQueue.sync {
            zip(dspOutputBoundaries, dspOutputBoundaries.dropFirst()).allSatisfy { previous, next in
                previous.endPresentationTime <= next.presentationTime
                    + max(1 / next.format.sampleRate, 0.000_1)
            }
        }
    }

    @discardableResult
    func recoverSourcesForTesting(atTimelineSeconds clock: Double) -> Bool {
        pipelineQueue.sync {
            renderer.flush()
            analysisQueue.removeAll(keepingCapacity: true)
            synchronizer.setRate(0, time: CMTime(seconds: clock, preferredTimescale: 1_000_000))
            return recoverSources(atTimelineSeconds: clock)
        }
    }

    nonisolated(unsafe) private(set) var renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    private let pipelineQueue: DispatchQueue
    private let pipelineQueueKey = DispatchSpecificKey<Void>()

    private struct Segment {
        let descriptor: RendererSegmentDescriptor
        let source: RendererPCMProvider
        let sourceFormat: DSPAudioFormat
        let formatDescription: CMAudioFormatDescription
        var nextSourceFrame: AVAudioFramePosition
        var normalizationGain: Double = 1
        var didReportExhaustion = false
    }

    private struct DSPPCMBlock {
        let segmentID: UUID
        let sourceFrameStart: AVAudioFramePosition
        let presentationTime: Double
        let format: DSPAudioFormat
        let pcm: CanonicalPCM

        var endPresentationTime: Double {
            presentationTime + pcm.seconds
        }
    }

    private struct DSPQueuedBlock {
        let raw: DSPPCMBlock
        let output: CanonicalPCM
        let revision: String
    }

    private struct DSPBlockKey: Hashable {
        let segmentID: UUID
        let sourceFrameStart: AVAudioFramePosition
        let frameCount: Int
        // A source range can be enqueued again after renderer recovery. Its
        // output identity includes the sample-precise position on the timeline.
        let presentationFrame: Int64

        init(_ block: DSPPCMBlock) {
            segmentID = block.segmentID
            sourceFrameStart = block.sourceFrameStart
            frameCount = block.pcm.frames
            presentationFrame = Int64((block.presentationTime * block.format.sampleRate).rounded())
        }

        init(_ boundary: DSPOutputBoundary) {
            segmentID = boundary.segmentID
            sourceFrameStart = boundary.sourceFrameStart
            frameCount = boundary.frameCount
            presentationFrame = Int64((boundary.presentationTime * boundary.format.sampleRate).rounded())
        }
    }

    private struct DSPOutputBoundary {
        let enqueueID: UUID
        var outputIsIdentity: Bool
        let segmentID: UUID
        let sourceFrameStart: AVAudioFramePosition
        let presentationTime: Double
        let frameCount: Int
        let format: DSPAudioFormat
        let normalizationGain: Double
        var request: DSPApplyRequest?
        var headroomDB: Double
        var processingLatencyFrames: Int
        var peakGuarantee: String
        var warnings: [DSPDiagnostic]
        var state: AudioDSPProcessor.StateSnapshot?

        var endPresentationTime: Double {
            presentationTime + Double(frameCount) / format.sampleRate
        }
    }

    private struct PendingDecodedPCM {
        let segmentID: UUID
        let sourceFrameStart: AVAudioFramePosition
        let presentationTime: Double
        let format: DSPAudioFormat
        let pcm: CanonicalPCM
        var frameOffset: Int = 0
    }

    private struct DSPApplyRequest {
        let configuration: AudioDSPConfiguration
        let revision: String
        let requestID: UUID
        let token: UUID
        let context: DSPEqualLoudnessContext
    }

    private enum DSPApplyPreparationError: Error {
        case unavailablePCM
        case timelineChanged
        case incompleteQueue
        case superseded
    }

    /// Prepared on the DSP preparation queue and handed to `pipelineQueue`.
    /// `CMSampleBuffer` and the processor carry no Sendable conformance, but the
    /// handoff is strictly one-directional and never aliased by both queues.
    private struct DSPReplacementBlock: @unchecked Sendable {
        let raw: DSPPCMBlock
        let oldOutput: CanonicalPCM
        let output: CanonicalPCM
        let sampleBuffer: CMSampleBuffer
        let headroomDB: Double
        let processingLatencyFrames: Int
        let peakGuarantee: String
        let warnings: [DSPDiagnostic]
        let state: AudioDSPProcessor.StateSnapshot?
    }

    private struct DSPReplacementTransaction: @unchecked Sendable {
        let request: DSPApplyRequest
        let transactionID: UUID
        let timelineGeneration: UUID
        let rendererGeneration: UUID
        let rendererID: ObjectIdentifier
        let startPTS: Double
        let oldHorizonPTS: Double
        let format: DSPAudioFormat
        let blocks: [DSPReplacementBlock]
        let finalProcessor: AudioDSPProcessor
        let warnings: [DSPDiagnostic]
        let headroomDB: Double
        let processingLatencyFrames: Int
        let peakGuarantee: String
        let retryCount: Int
    }

    private struct DSPPreparationBlock: @unchecked Sendable {
        let raw: DSPPCMBlock
        let oldOutput: CanonicalPCM
        let lookahead: CanonicalPCM?
        let formatDescription: CMAudioFormatDescription
    }

    private struct DSPPreparationPlan: @unchecked Sendable {
        let request: DSPApplyRequest
        let timelineGeneration: UUID
        let rendererGeneration: UUID
        let rendererID: ObjectIdentifier
        let startPTS: Double
        let horizon: Double
        let format: DSPAudioFormat
        let warmup: [DSPPCMBlock]
        let state: AudioDSPProcessor.StateSnapshot?
        let blocks: [DSPPreparationBlock]
        let retryCount: Int
        let prefix: DSPReplacementTransaction?
    }

    private struct DSPHorizonTransition {
        let previous: AudioDSPProcessor
        let weights: [Double]
        var offsetSeconds: Double = 0
    }

    private struct AnalysisChunk {
        let presentationTime: Double
        let pcm: CanonicalPCM
        let segmentID: UUID
        let dspRevision: String
    }

    private var segments: [Segment] = []
    private var decodeIndex: Int?
    private var nextPresentationTime: Double = 0
    private var enqueueToken = UUID()
    private var isLoaded = false
    private var isPlaybackActive = false
    private var synchronizerAnchorMutationCount = 0
    private var activeLoadSegmentID: UUID?
    private var timelineGeneration = UUID()
    private let timelineGenerationGate = RendererTimelineGeneration()
    /// Advances at command ingress, before a busy decode queue can finish an
    /// old fade or deliver its state back to MainActor.
    private var transportCommandGeneration = UUID()
    private let transportCommandGate = RendererTimelineGeneration()
    private var rendererFailureRecoveryBudget = RendererFailureRecoveryBudget()
    private var pendingAutoFlushResync = false
    /// Renderer PTS lead used for source re-seeks after a route/mode flush.
    /// This is intentionally separate from analysis delivery lead so the
    /// application-owned visualization lookahead remains explicit and stable.
    private var analysisLeadSeconds: Double = 0
    private var analysisDeliveryLeadSeconds: Double = 0
    private var analysisQueue: [AnalysisChunk] = []
    private var dspConfiguration = AudioDSPConfiguration.defaultFlat
    private var dspRevision = "initial"
    private var dspProcessor: AudioDSPProcessor?
    private var latestAcceptedDSPRequest: DSPApplyRequest?
    private var effectiveDSPRequest: DSPApplyRequest?
    private var pendingDecodedPCM: PendingDecodedPCM?
    private var dspLedger: [DSPQueuedBlock] = []
    private var dspOutputBoundaries: [DSPOutputBoundary] = []
    private var lastAudibleDSPFormat: DSPAudioFormat?
    private var lastAudibleDSPDiagnosticIDs: Set<String> = []
    private var pendingAudibleDSPEvent: DSPApplyEvent?
    private var activeDSPTransaction: DSPReplacementTransaction?
    private var queuedDSPApply: DSPApplyRequest?
    private let dspPreparationQueue = DispatchQueue(label: "kmg.myplayer2.dsp-preparation", qos: .userInitiated)
    private let dspRequestGate = RendererTimelineGeneration()
    private var dspPreparationID: UUID?
    private var preparingDSPRequest: DSPApplyRequest?
    private var dspPreparationSeconds: Double = 0
    private var dspHorizonTransition: DSPHorizonTransition?
    private var currentVolume: Float = 1
    private var fadeConfiguration = AudioFadeConfiguration()
    private var desiredDSPContext = DSPEqualLoudnessContext.appOnly
    private var dspContext = DSPEqualLoudnessContext.appOnly
    private let outputGainController: PlaybackOutputGainController
    /// Core Audio UID currently selected for this renderer. On macOS the
    /// synchronizer uses the attached audio renderer's device clock, so keeping
    /// this value explicit avoids falling back to a host-time clock during a
    /// route transition.
    private var audioOutputDeviceUniqueID: String?

    /// Explicit loads/seeks and system auto-flushes share the same renderer
    /// queue. These fields prevent a notification queued during an explicit
    /// flush from re-seeking the newly requested provider to the old clock.
    private var timelineMutationInProgress = false
    private var lastExplicitTimelineMutationWallTime: TimeInterval = 0
    private var explicitTimelineClock: Double = 0

    private var lastRecoveryWallTime: TimeInterval = 0
    private var lastSystemChangeWallTime: TimeInterval = 0
    private var lastAdvancingClock: Double = 0
    private var lastClockAdvanceWallTime: TimeInterval = 0
    private var stallRecoveryToken = UUID()
    private var stallRecoveryScheduled = false
    private var rendererGeneration = UUID()
    private var rendererObserverTokens: [NSObjectProtocol] = []

    var onProgress: ((Double) -> Void)?
    /// Called on the main queue after a load/seek has flushed the old timeline,
    /// primed the new samples, and committed the synchronizer's rate/anchor.
    /// The segment ID lets the owner discard a callback from an older seek.
    var onTimelineMutationCommitted: ((UUID, Double, Bool) -> Void)?
    var onSystemReconfigEvent: (() -> Void)?
    /// Main-queue confirmation after the renderer commits an output route.
    var onOutputDeviceChange: ((String?) -> Void)?
    var onEnqueue: (@Sendable (CanonicalPCM, Double) -> Void)?
    var onAnalysisPCM: (@Sendable (CanonicalPCM) -> Void)?
    var onSegmentExhausted: ((RendererSegmentDescriptor) -> Void)?
    var onFailure: ((_ segmentID: UUID?, _ error: RendererPipelineError) -> Void)?
    var onDSPApplyEvent: (@Sendable (DSPApplyEvent) -> Void)?
    var onTransportStateChange: (@Sendable (AudioTransportTransitionState, UUID, UUID) -> Void)?

    private static let feedInterval: TimeInterval = 0.1
    private static let analysisInterval: TimeInterval = 1.0 / 60.0
    private static let statusPollInterval: TimeInterval = 0.5
    private static let recoveryCooldown: TimeInterval = 0.5
    private static let rebuildSuppressionInterval: TimeInterval = 3.0
    private static let timelineMutationSuppressionInterval: TimeInterval = 0.35

    nonisolated(unsafe) private var feedTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var analysisTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var statusTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var progressObserver: Any?

    init() {
        let queue = DispatchQueue(label: "kmg.myplayer2.renderer-pipeline", qos: .userInitiated)
        pipelineQueue = queue
        outputGainController = PlaybackOutputGainController(queue: queue)
        outputGainController.writeGain = { [weak self] gain in self?.renderer.volume = gain }
        outputGainController.publish = { [weak self] state in
            guard let self,
                  self.transportCommandGate.isCurrent(self.transportCommandGeneration) else { return }
            self.onTransportStateChange?(state, self.timelineGeneration, self.transportCommandGeneration)
        }
        pipelineQueue.setSpecific(key: pipelineQueueKey, value: ())
        timelineGeneration = timelineGenerationGate.current()
        transportCommandGeneration = transportCommandGate.current()
        configureRenderer(renderer)
        synchronizer.addRenderer(renderer)
        // Keep this ordering identical to the verified AVSampleBuffer demo:
        // spatialization eligibility is declared after the renderer is attached
        // to its synchronizer, but before the first sample is enqueued.
        configureSpatialization(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        installRendererObservers(for: renderer, timelineGeneration: timelineGeneration)
        installProgressObserver(for: timelineGeneration)
        startAnalysisTimer()
        startStatusPolling()
    }

    deinit {
        removeRendererObservers()
        feedTimer?.cancel()
        analysisTimer?.cancel()
        statusTimer?.cancel()
        if let progressObserver {
            synchronizer.removeTimeObserver(progressObserver)
        }
    }

    private func configureRenderer(_ renderer: AVSampleBufferAudioRenderer) {
        outputGainController.restore { renderer.volume = $0 }
        // The SDK documents this property as nullable, but the current macOS
        // renderer asserts if nil is explicitly assigned. Leaving it untouched
        // is exactly the documented default-device behavior.
        if let audioOutputDeviceUniqueID {
            renderer.audioOutputDeviceUniqueID = audioOutputDeviceUniqueID
        }
    }

    private func configureSpatialization(_ renderer: AVSampleBufferAudioRenderer) {
        renderer.allowedAudioSpatializationFormats = [.monoStereoAndMultichannel]
    }

    private func installRendererObservers(
        for renderer: AVSampleBufferAudioRenderer,
        timelineGeneration: UUID
    ) {
        removeRendererObservers()
        let rendererGeneration = self.rendererGeneration
        let observedRendererID = ObjectIdentifier(renderer)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .AVSampleBufferAudioRendererWasFlushedAutomatically,
            .AVSampleBufferAudioRendererOutputConfigurationDidChange
        ]
        rendererObserverTokens = names.map { name in
            center.addObserver(forName: name, object: renderer, queue: nil) { [weak self] notification in
                guard let self,
                      let observedRenderer = notification.object as? AVSampleBufferAudioRenderer,
                      ObjectIdentifier(observedRenderer) == observedRendererID else {
                    return
                }
                let flushTime = (
                    notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue
                )?.timeValue ?? .invalid
                self.handleAutomaticFlush(
                    flushTime: flushTime,
                    observedRendererID: observedRendererID,
                    rendererGeneration: rendererGeneration,
                    timelineGeneration: timelineGeneration
                )
            }
        }
    }

    private func removeRendererObservers() {
        for token in rendererObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        rendererObserverTokens.removeAll(keepingCapacity: true)
    }

    // MARK: - Configuration

    func setVolume(_ volume: Float) {
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.currentVolume = volume
            self.outputGainController.setMaster(Double(volume))
        }
    }

    func isTimelineCurrent(_ generation: UUID) -> Bool { timelineGenerationGate.isCurrent(generation) }

    func isTransportCommandCurrent(_ generation: UUID) -> Bool { transportCommandGate.isCurrent(generation) }

    func setFadeConfiguration(_ configuration: AudioFadeConfiguration) {
        pipelineQueue.async { [weak self] in self?.fadeConfiguration = configuration }
    }

    func setEqualLoudnessContext(_ context: DSPEqualLoudnessContext) {
        pipelineQueue.async { [weak self] in
            guard let self, self.desiredDSPContext != context else { return }
            self.desiredDSPContext = context
            guard let request = self.latestAcceptedDSPRequest,
                  request.configuration.enabled,
                  request.configuration.nodes.contains(where: { $0.enabled && $0.typeID == "equalLoudness" }) else {
                self.dspContext = context
                return
            }
            self.applyDSP(request.configuration, revision: request.revision, requestID: request.requestID)
        }
    }

    /// Controls the logical PTS lead used by the renderer timeline.
    func setAnalysisLeadSeconds(_ seconds: Double) {
        pipelineQueue.async { [weak self] in
            self?.analysisLeadSeconds = max(0, seconds)
        }
    }

    /// Controls how far decoded PCM is released to the analysis hub ahead of
    /// the synchronizer clock. This is independent of the renderer PTS lead so
    /// the application-owned visualization lookahead can be preserved without
    /// moving the renderer's seek/recovery anchor. Output-route latency is
    /// represented by the renderer's device clock, never by this value.
    func setAnalysisDeliveryLeadSeconds(_ seconds: Double) {
        pipelineQueue.async { [weak self] in
            self?.analysisDeliveryLeadSeconds = max(0, seconds)
        }
    }

    /// Applies a renderer configuration at a future queued output boundary.
    /// All decoding, cursor replay and renderer mutations remain serialized on
    /// pipelineQueue; the renderer completion only returns transaction IDs.
    func applyDSP(
        _ configuration: AudioDSPConfiguration,
        revision: String,
        requestID: UUID
    ) {
        // Invalidate stale preparation before this request reaches the busy
        // producer queue. Only the newest ingress request starts work.
        let token = dspRequestGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            let request = DSPApplyRequest(
                configuration: configuration, revision: revision, requestID: requestID,
                token: token, context: self.desiredDSPContext
            )
            guard self.dspRequestGate.isCurrent(token) else {
                self.emitDSPEvent(request, state: .superseded, format: self.currentDSPFormat,
                    scheduledPTS: nil, audiblePTS: nil, headroomDB: nil, warnings: [], diagnostics: [])
                return
            }
            if let superseded = self.queuedDSPApply, superseded.requestID != request.requestID {
                self.emitDSPEvent(
                    superseded,
                    state: .superseded,
                    format: self.currentDSPFormat,
                    scheduledPTS: nil,
                    audiblePTS: nil,
                    headroomDB: nil,
                    warnings: [],
                    diagnostics: []
                )
            }
            self.queuedDSPApply = request
            self.latestAcceptedDSPRequest = request
            if !self.isLoaded {
                self.dspConfiguration = configuration
                self.dspRevision = revision
                self.dspContext = request.context
                self.dspProcessor = nil
                self.effectiveDSPRequest = request
                self.emitDSPEvent(
                    request,
                    state: .ready,
                    format: nil,
                    scheduledPTS: nil,
                    audiblePTS: nil,
                    headroomDB: nil,
                    warnings: [],
                    diagnostics: []
                )
                self.queuedDSPApply = nil
                return
            }

            self.emitDSPEvent(
                request,
                state: .preparing,
                format: self.currentDSPFormat,
                scheduledPTS: nil,
                audiblePTS: nil,
                headroomDB: nil,
                warnings: [],
                diagnostics: []
            )
            guard self.activeDSPTransaction == nil else { return }
            self.startNextDSPApply(retryCount: 0, afterPTS: nil)
        }
    }

    private var currentDSPFormat: DSPAudioFormat? {
        guard let index = decodeIndex, segments.indices.contains(index) else {
            return segments.last?.sourceFormat
        }
        return segments[index].sourceFormat
    }

    private func emitDSPEvent(
        _ request: DSPApplyRequest,
        state: DSPApplyState,
        format: DSPAudioFormat?,
        scheduledPTS: Double?,
        audiblePTS: Double?,
        headroomDB: Double?,
        processingLatencyFrames: Int? = nil,
        peakGuarantee: String? = nil,
        warnings: [DSPDiagnostic],
        diagnostics: [DSPDiagnostic],
        rebuffered: Bool = false
    ) {
        let runtime = dspProcessor.flatMap { processor -> AudioDSPProcessor? in
            guard let format, processor.format == format,
                  dspRevision == request.revision, dspContext == request.context else { return nil }
            return processor
        }
        let latency = processingLatencyFrames ?? runtime?.processingLatencyFrames
        let event = DSPApplyEvent(
            requestID: request.requestID,
            revisionString: request.revision,
            state: state,
            format: format,
            scheduledPTS: scheduledPTS,
            audiblePTS: audiblePTS,
            headroomDB: headroomDB,
            processingLatencyFrames: latency,
            mediaMappingLatencyFrames: latency == nil ? nil : 0,
            peakGuarantee: peakGuarantee ?? runtime?.peakGuarantee,
            warnings: warnings,
            diagnostics: diagnostics,
            rebuffered: rebuffered
        )
        DispatchQueue.main.async { [weak self] in
            self?.onDSPApplyEvent?(event)
        }
    }

    private func emitDSPEvent(_ event: DSPApplyEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onDSPApplyEvent?(event)
        }
    }

    private func scheduleDSPRequestAtFirstQueuedPTS(
        _ request: DSPApplyRequest?,
        rebuffered: Bool,
        excludingPreviouslyQueued: Set<UUID> = [],
        additionalWarnings: [DSPDiagnostic] = []
    ) {
        guard let request else {
            pendingAudibleDSPEvent = nil
            return
        }
        guard let firstBoundary = dspOutputBoundaries.first(where: {
            !excludingPreviouslyQueued.contains($0.enqueueID)
        }) else {
            let currentProcessor = dspProcessor
            let warnings = Self.deduplicatedDSPDiagnostics(
                (currentProcessor?.diagnostics ?? []) + additionalWarnings
            )
            emitDSPEvent(
                request,
                state: .ready,
                format: currentDSPFormat,
                scheduledPTS: nil,
                audiblePTS: nil,
                headroomDB: currentProcessor?.headroomDB,
                warnings: warnings,
                diagnostics: warnings,
                rebuffered: rebuffered
            )
            return
        }

        // A recovery prime can cross a gapless format boundary. Report the
        // runtime that will actually process the first newly queued sample,
        // even when decoding has already advanced dspProcessor to a later
        // format in the queue.
        var warningsByID = [String: DSPDiagnostic]()
        for warning in firstBoundary.warnings + additionalWarnings {
            warningsByID[warning.id] = warning
        }
        let warnings = warningsByID.values.sorted { $0.id < $1.id }
        let event = DSPApplyEvent(
            requestID: request.requestID,
            revisionString: request.revision,
            state: .scheduled,
            format: firstBoundary.format,
            scheduledPTS: firstBoundary.presentationTime,
            audiblePTS: nil,
            headroomDB: firstBoundary.headroomDB,
            processingLatencyFrames: firstBoundary.processingLatencyFrames,
            mediaMappingLatencyFrames: 0,
            peakGuarantee: firstBoundary.peakGuarantee,
            warnings: warnings,
            diagnostics: warnings,
            rebuffered: rebuffered
        )
        pendingAudibleDSPEvent = event
        emitDSPEvent(event)
    }

    private static func deduplicatedDSPDiagnostics(
        _ diagnostics: [DSPDiagnostic]
    ) -> [DSPDiagnostic] {
        var diagnosticsByID = [String: DSPDiagnostic]()
        for diagnostic in diagnostics {
            diagnosticsByID[diagnostic.id] = diagnostic
        }
        return diagnosticsByID.values.sorted { $0.id < $1.id }
    }

    private func startNextDSPApply(retryCount: Int, afterPTS: Double?) {
        guard activeDSPTransaction == nil, dspPreparationID == nil,
              let request = queuedDSPApply, isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return }
        queuedDSPApply = nil
        let format = replacementBoundary(afterPTS: afterPTS)?.format ?? currentDSPFormat
        guard let format else { return }
        let id = UUID()
        let timeline = timelineGeneration
        dspPreparationID = id
        preparingDSPRequest = request
        dspPreparationQueue.async { [weak self] in
            guard let self else { return }
            guard self.dspRequestGate.isCurrent(request.token) else {
                self.pipelineQueue.async { self.finishSupersededPreparation(id: id, request: request) }
                return
            }
            let processor = AudioDSPProcessor(configuration: request.configuration, format: format, context: request.context)
            self.pipelineQueue.async {
                guard self.dspPreparationID == id else { return }
                self.dspPreparationID = nil
                self.preparingDSPRequest = nil
                guard self.timelineGeneration == timeline, self.isLoaded,
                      self.timelineGenerationGate.isCurrent(timeline) else { return }
                guard self.dspRequestGate.isCurrent(request.token) else {
                    self.finishSupersededPreparation(id: nil, request: request)
                    return
                }
                guard let boundary = self.replacementBoundary(afterPTS: afterPTS), boundary.format == processor.format else {
                    self.installDSPAtQueueHorizon(request, processor: processor)
                    return
                }
                do {
                    let plan = try self.prepareDSPReplacement(request, boundary: boundary,
                        horizon: self.nextPresentationTime, retryCount: retryCount, processor: processor)
                    self.runDSPPreparation(plan, processor: processor)
                } catch {
                    self.installDSPAtQueueHorizon(request, processor: processor)
                }
            }
        }
    }

    private func replacementBoundary(afterPTS: Double?) -> DSPOutputBoundary? {
        let clock = currentSynchronizerClockSeconds()
        let analysisThrough = clock + analysisLeadSeconds - analysisDeliveryLeadSeconds + 0.005
        let lead = max(Self.dspFlushSafetySeconds, dspPreparationSeconds * 1.5 + 0.04)
        let target = max(max(clock, analysisThrough) + lead, (afterPTS ?? 0) + 0.03)
        return dspOutputBoundaries.first {
            $0.presentationTime >= target && $0.presentationTime < nextPresentationTime - 0.000_001
        }
    }

    /// Snapshot only immutable PCM and state. The source cursor and renderer
    /// remain confined to pipelineQueue; expensive processing runs elsewhere.
    private func prepareDSPReplacement(
        _ request: DSPApplyRequest,
        boundary start: DSPOutputBoundary,
        horizon: Double,
        retryCount: Int,
        processor: AudioDSPProcessor,
        prefix: DSPReplacementTransaction? = nil
    ) throws -> DSPPreparationPlan {
        guard timelineGenerationGate.isCurrent(timelineGeneration),
              let startIndex = dspOutputBoundaries.firstIndex(where: { $0.enqueueID == start.enqueueID }) else {
            throw DSPApplyPreparationError.timelineChanged
        }
        let boundaries = Array(dspOutputBoundaries[startIndex...].filter { $0.presentationTime < horizon - 0.000_001 })
        guard let last = boundaries.last, abs(last.endPresentationTime - horizon) <= max(1 / last.format.sampleRate, 0.000_1) else {
            throw DSPApplyPreparationError.incompleteQueue
        }
        for (previous, next) in zip(boundaries, boundaries.dropFirst()) {
            guard abs(previous.endPresentationTime - next.presentationTime) <= max(1 / next.format.sampleRate, 0.000_1) else {
                throw DSPApplyPreparationError.incompleteQueue
            }
        }
        let state = prefix == nil ? start.state : nil
        var warmupBoundaries: [DSPOutputBoundary] = []
        if prefix == nil, processor.needsWarmup, state?.matches(request.configuration) != true {
            warmupBoundaries = dspOutputBoundaries[..<startIndex].filter {
                $0.endPresentationTime >= start.presentationTime - 2 && $0.format == start.format
            }
            // A format change or recovery can leave unrelated earlier ranges.
            while let first = warmupBoundaries.first, let second = warmupBoundaries.dropFirst().first,
                  abs(first.endPresentationTime - second.presentationTime) > 1 / start.format.sampleRate {
                warmupBoundaries.removeFirst()
            }
        }
        let warmup = try rawBlocks(for: warmupBoundaries)
        let future = try rawBlocks(for: boundaries)
        let warmupBytes = warmup.reduce(0) { $0 + $1.pcm.data.count * MemoryLayout<Float>.size }
        let futureBytes = future.reduce(0) { $0 + $1.pcm.data.count * MemoryLayout<Float>.size }
        let prefixBytes = prefix?.blocks.reduce(0) { $0 + $1.raw.pcm.data.count * MemoryLayout<Float>.size } ?? 0
        guard warmupBytes <= Self.dspWarmupByteLimit,
              warmupBytes + (futureBytes + prefixBytes) * 4 <= Self.dspReplacementByteLimit else {
            throw DSPApplyPreparationError.incompleteQueue
        }
        var oldByKey = [DSPBlockKey: CanonicalPCM]()
        for item in dspLedger { oldByKey[DSPBlockKey(item.raw)] = item.output }
        var blocks = [DSPPreparationBlock]()
        for (index, raw) in future.enumerated() {
            guard let segment = segments.first(where: { $0.descriptor.id == raw.segmentID }),
                  let old = oldByKey[DSPBlockKey(raw)] ?? (boundaries[index].outputIsIdentity ? raw.pcm : nil) else {
                throw DSPApplyPreparationError.unavailablePCM
            }
            let lookahead = try dspLookahead(after: raw, frameCount: processor.processingLatencyFrames,
                following: future[(index + 1)...])
            blocks.append(DSPPreparationBlock(raw: raw, oldOutput: old, lookahead: lookahead,
                formatDescription: segment.formatDescription))
        }
        return DSPPreparationPlan(request: request, timelineGeneration: timelineGeneration,
            rendererGeneration: rendererGeneration, rendererID: ObjectIdentifier(renderer),
            startPTS: prefix?.startPTS ?? start.presentationTime, horizon: horizon,
            format: prefix?.format ?? start.format, warmup: warmup, state: state, blocks: blocks,
            retryCount: retryCount, prefix: prefix)
    }

    private func runDSPPreparation(
        _ plan: DSPPreparationPlan,
        processor: AudioDSPProcessor,
        extensions: Int = 0
    ) {
        let id = UUID()
        dspPreparationID = id
        preparingDSPRequest = plan.request
        dspPreparationQueue.async { [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let result = Result { try self.processDSPReplacement(plan, processor: processor) }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            self.pipelineQueue.async {
                guard self.dspPreparationID == id else { return }
                self.dspPreparationID = nil
                self.preparingDSPRequest = nil
                guard self.isLoaded, self.timelineGeneration == plan.timelineGeneration,
                      self.timelineGenerationGate.isCurrent(plan.timelineGeneration),
                      self.rendererGeneration == plan.rendererGeneration,
                      ObjectIdentifier(self.renderer) == plan.rendererID else { return }
                guard self.dspRequestGate.isCurrent(plan.request.token) else {
                    self.finishSupersededPreparation(id: nil, request: plan.request)
                    return
                }
                self.dspPreparationSeconds = elapsed
                switch result {
                case .failure:
                    Self.pipelineLog.warning(
                        "dsp apply: preparation failed after \(elapsed, format: .fixed(precision: 3))s; waiting for the queue horizon"
                    )
                    self.installDSPAtQueueHorizon(plan.request, processor: processor)
                case .success(let transaction):
                    let clock = self.currentSynchronizerClockSeconds()
                    let safe = max(clock, clock + self.analysisLeadSeconds - self.analysisDeliveryLeadSeconds + 0.005) + 0.02
                    guard transaction.startPTS > safe else {
                        // A slow preparation never stops or rewinds playback.
                        // Adopt its plan at the next produced block instead.
                        Self.pipelineLog.info(
                            "dsp apply: prepared in \(elapsed, format: .fixed(precision: 3))s but its swap point \(transaction.startPTS, format: .fixed(precision: 3))s is already behind; waiting for the queue horizon"
                        )
                        self.installDSPAtQueueHorizon(plan.request, processor: processor)
                        return
                    }
                    // The feed keeps running during preparation. Cover the blocks
                    // it produced since the snapshot, but never chase the feed
                    // indefinitely: a preparation slower than real time adopts
                    // its processor at the horizon instead of never landing.
                    if self.nextPresentationTime > transaction.oldHorizonPTS + 0.000_001,
                       extensions < Self.dspPreparationMaximumExtensions,
                       let tail = self.dspOutputBoundaries.first(where: {
                           abs($0.presentationTime - transaction.oldHorizonPTS) < 0.000_001
                       }) {
                        Self.pipelineLog.debug(
                            "dsp apply: extending preparation #\(extensions + 1, privacy: .public) to the feed horizon"
                        )
                        do {
                            let extensionPlan = try self.prepareDSPReplacement(plan.request, boundary: tail,
                                horizon: self.nextPresentationTime, retryCount: plan.retryCount,
                                processor: transaction.finalProcessor, prefix: transaction)
                            self.runDSPPreparation(extensionPlan, processor: transaction.finalProcessor,
                                extensions: extensions + 1)
                        } catch {
                            Self.pipelineLog.warning(
                                "dsp apply: extension failed; waiting for the queue horizon"
                            )
                            self.installDSPAtQueueHorizon(plan.request, processor: transaction.finalProcessor)
                        }
                        return
                    }
                    Self.pipelineLog.info(
                        "dsp apply: prepared in \(elapsed, format: .fixed(precision: 3))s with \(extensions, privacy: .public) extension(s), queued ahead \(self.nextPresentationTime - clock, format: .fixed(precision: 3))s"
                    )
                    self.beginPartialDSPFlush(transaction)
                }
            }
        }
    }

    /// Called only on dspPreparationQueue. No live provider/renderer access.
    private func processDSPReplacement(_ plan: DSPPreparationPlan, processor: AudioDSPProcessor) throws -> DSPReplacementTransaction {
        var runtime = processor
        if plan.prefix == nil {
            if let state = plan.state, runtime.restoreState(state) {
                // Recursive histories now start at exactly the selected PTS.
            } else if runtime.needsWarmup {
                for block in plan.warmup {
                    guard dspRequestGate.isCurrent(plan.request.token), timelineGenerationGate.isCurrent(plan.timelineGeneration) else {
                        throw DSPApplyPreparationError.superseded
                    }
                    runtime.warm(with: [block.pcm])
                }
            }
        }
        let startHeadroom = plan.prefix?.headroomDB ?? runtime.headroomDB
        let startLatency = plan.prefix?.processingLatencyFrames ?? runtime.processingLatencyFrames
        let startPeak = plan.prefix?.peakGuarantee ?? runtime.peakGuarantee
        let weights = AudioDSPProcessor.transitionWeights(sampleRate: plan.format.sampleRate, durationMilliseconds: 30)
        var blocks = plan.prefix?.blocks ?? []
        var warnings = plan.prefix?.warnings ?? runtime.diagnostics
        for item in plan.blocks {
            guard dspRequestGate.isCurrent(plan.request.token), timelineGenerationGate.isCurrent(plan.timelineGeneration) else {
                throw DSPApplyPreparationError.superseded
            }
            if runtime.format != item.raw.format {
                runtime = AudioDSPProcessor(configuration: plan.request.configuration, format: item.raw.format, context: plan.request.context)
            }
            let state = runtime.stateSnapshot()
            let processed = runtime.process(item.raw.pcm, lookahead: item.lookahead)
            let output = AudioDSPProcessor.crossfade(old: item.oldOutput, new: processed, weights: weights,
                transitionOffsetSeconds: item.raw.presentationTime - plan.startPTS, weightSampleRate: plan.format.sampleRate)
            guard let buffer = CMSampleBufferFactory.makeSampleBuffer(from: output,
                formatDescription: item.formatDescription, presentationTime: CMSampleBufferFactory.time(
                    frames: Int64((item.raw.presentationTime * item.raw.format.sampleRate).rounded()), sampleRate: item.raw.format.sampleRate)) else {
                throw DSPApplyPreparationError.unavailablePCM
            }
            warnings += runtime.diagnostics
            blocks.append(DSPReplacementBlock(raw: item.raw, oldOutput: item.oldOutput, output: output,
                sampleBuffer: buffer, headroomDB: runtime.headroomDB, processingLatencyFrames: runtime.processingLatencyFrames,
                peakGuarantee: runtime.peakGuarantee, warnings: runtime.diagnostics, state: state))
        }
        return DSPReplacementTransaction(request: plan.request, transactionID: plan.prefix?.transactionID ?? UUID(),
            timelineGeneration: plan.timelineGeneration, rendererGeneration: plan.rendererGeneration,
            rendererID: plan.rendererID, startPTS: plan.startPTS, oldHorizonPTS: plan.horizon, format: plan.format,
            blocks: blocks, finalProcessor: runtime, warnings: Self.deduplicatedDSPDiagnostics(warnings),
            headroomDB: startHeadroom, processingLatencyFrames: startLatency, peakGuarantee: startPeak, retryCount: plan.retryCount)
    }

    private func finishSupersededPreparation(id: UUID?, request: DSPApplyRequest) {
        if let id {
            guard dspPreparationID == id else { return }
            dspPreparationID = nil
            preparingDSPRequest = nil
        }
        emitDSPEvent(request, state: .superseded, format: currentDSPFormat,
            scheduledPTS: nil, audiblePTS: nil, headroomDB: nil, warnings: [], diagnostics: [])
        startNextDSPApply(retryCount: 0, afterPTS: nil)
    }

    private func installDSPAtQueueHorizon(_ request: DSPApplyRequest, processor: AudioDSPProcessor) {
        guard dspRequestGate.isCurrent(request.token), let format = currentDSPFormat else { return }
        if processor.format != format {
            let id = UUID()
            let timeline = timelineGeneration
            dspPreparationID = id
            preparingDSPRequest = request
            dspPreparationQueue.async { [weak self] in
                guard let self else { return }
                let updated = AudioDSPProcessor(configuration: request.configuration, format: format, context: request.context)
                self.pipelineQueue.async {
                    guard self.dspPreparationID == id else { return }
                    self.dspPreparationID = nil
                    self.preparingDSPRequest = nil
                    guard self.isLoaded, self.timelineGeneration == timeline else { return }
                    guard self.dspRequestGate.isCurrent(request.token) else {
                        self.finishSupersededPreparation(id: nil, request: request)
                        return
                    }
                    self.installDSPAtQueueHorizon(request, processor: updated)
                }
            }
            return
        }
        if let previous = dspProcessor {
            processor.reset()
            processor.inheritState(from: previous)
            dspHorizonTransition = DSPHorizonTransition(previous: previous,
                weights: AudioDSPProcessor.transitionWeights(sampleRate: format.sampleRate, durationMilliseconds: 30))
        }
        dspProcessor = processor
        dspConfiguration = request.configuration
        dspRevision = request.revision
        dspContext = request.context
        effectiveDSPRequest = request
        Self.pipelineLog.info(
            "dsp apply: adopted at horizon \(self.nextPresentationTime, format: .fixed(precision: 3))s revision=\(request.revision, privacy: .public)"
        )
        let event = DSPApplyEvent(requestID: request.requestID, revisionString: request.revision, state: .scheduled,
            format: format, scheduledPTS: nextPresentationTime, audiblePTS: nil, headroomDB: processor.headroomDB,
            processingLatencyFrames: processor.processingLatencyFrames, mediaMappingLatencyFrames: 0,
            peakGuarantee: processor.peakGuarantee, warnings: processor.diagnostics, diagnostics: processor.diagnostics, rebuffered: false)
        pendingAudibleDSPEvent = event
        emitDSPEvent(event)
        startFeedTimerIfNeeded()
        // An edit that arrived while this one was preparing still has to land.
        startQueuedDSPApply(afterPTS: nextPresentationTime)
    }

    private func rawBlocks(for boundaries: [DSPOutputBoundary]) throws -> [DSPPCMBlock] {
        guard !boundaries.isEmpty else { return [] }
        var rawByKey = [DSPBlockKey: DSPPCMBlock]()
        for item in dspLedger {
            rawByKey[DSPBlockKey(item.raw)] = item.raw
        }

        let missing = boundaries.filter { rawByKey[DSPBlockKey($0)] == nil }
        if !missing.isEmpty {
            let replayed = try replayRawBlocks(missing)
            for (key, block) in replayed { rawByKey[key] = block }
        }

        let blocks = boundaries.compactMap { boundary in
            rawByKey[DSPBlockKey(boundary)]
        }
        guard blocks.count == boundaries.count else {
            throw DSPApplyPreparationError.unavailablePCM
        }
        return blocks
    }

    /// Replays only missing cached ranges and restores every provider cursor
    /// before returning to the live feed. Boundaries, not decoded read sizes,
    /// define the authoritative frame offsets and partial tail lengths.
    private func replayRawBlocks(
        _ boundaries: [DSPOutputBoundary]
    ) throws -> [DSPBlockKey: DSPPCMBlock] {
        var cursorBySegment = [UUID: AVAudioFramePosition]()
        for boundary in boundaries {
            guard let segment = segments.first(where: { $0.descriptor.id == boundary.segmentID }) else {
                throw DSPApplyPreparationError.unavailablePCM
            }
            cursorBySegment[boundary.segmentID] = segment.nextSourceFrame
        }

        var result = [DSPBlockKey: DSPPCMBlock]()
        do {
            let ordered = boundaries.sorted {
                if $0.segmentID == $1.segmentID {
                    return $0.sourceFrameStart < $1.sourceFrameStart
                }
                return $0.presentationTime < $1.presentationTime
            }
            var offset = 0
            while offset < ordered.count {
                let segmentID = ordered[offset].segmentID
                var end = offset + 1
                while end < ordered.count, ordered[end].segmentID == segmentID {
                    end += 1
                }
                guard let segment = segments.first(where: { $0.descriptor.id == segmentID }) else {
                    throw DSPApplyPreparationError.unavailablePCM
                }
                let segmentBlocks = Array(ordered[offset..<end])
                var runStart = 0
                while runStart < segmentBlocks.count {
                    var runEnd = runStart + 1
                    while runEnd < segmentBlocks.count {
                        let prior = segmentBlocks[runEnd - 1]
                        let next = segmentBlocks[runEnd]
                        guard prior.sourceFrameStart + AVAudioFramePosition(prior.frameCount)
                            == next.sourceFrameStart else { break }
                        runEnd += 1
                    }
                    let firstBoundary = segmentBlocks[runStart]
                    try segment.source.seek(to: firstBoundary.sourceFrameStart)
                    for boundary in segmentBlocks[runStart..<runEnd] {
                        let pcm = try readExactly(
                            boundary.frameCount,
                            from: segment.source,
                            expectedFormat: boundary.format
                        )
                        let block = DSPPCMBlock(
                            segmentID: boundary.segmentID,
                            sourceFrameStart: boundary.sourceFrameStart,
                            presentationTime: boundary.presentationTime,
                            format: boundary.format,
                            pcm: Self.applyingFixedGain(pcm, gain: boundary.normalizationGain)
                        )
                        result[DSPBlockKey(boundary)] = block
                    }
                    runStart = runEnd
                }
                offset = end
            }
        } catch {
            try restoreProviderCursors(cursorBySegment)
            throw error
        }
        try restoreProviderCursors(cursorBySegment)
        return result
    }

    private func readExactly(
        _ frameCount: Int,
        from source: RendererPCMProvider,
        expectedFormat: DSPAudioFormat
    ) throws -> CanonicalPCM {
        var data = [Float]()
        data.reserveCapacity(frameCount * expectedFormat.channelCount)
        var receivedFrames = 0
        while receivedFrames < frameCount {
            let request = AVAudioFrameCount(frameCount - receivedFrames)
            guard let pcm = try source.nextChunk(maxFrames: request),
                  pcm.frames > 0,
                  pcm.channelCount == expectedFormat.channelCount,
                  abs(pcm.sampleRate - expectedFormat.sampleRate) < 0.5 else {
                throw DSPApplyPreparationError.unavailablePCM
            }
            let acceptedFrames = min(pcm.frames, frameCount - receivedFrames)
            data.append(contentsOf: pcm.data.prefix(acceptedFrames * pcm.channelCount))
            receivedFrames += acceptedFrames
        }
        return CanonicalPCM(
            frames: frameCount,
            channelCount: expectedFormat.channelCount,
            sampleRate: expectedFormat.sampleRate,
            data: data
        )
    }

    private func restoreProviderCursors(_ cursors: [UUID: AVAudioFramePosition]) throws {
        for (segmentID, position) in cursors {
            guard let segment = segments.first(where: { $0.descriptor.id == segmentID }) else { continue }
            try segment.source.seek(to: position)
        }
    }

    private func beginPartialDSPFlush(_ transaction: DSPReplacementTransaction) {
        guard activeDSPTransaction == nil,
              transaction.timelineGeneration == timelineGeneration,
              timelineGenerationGate.isCurrent(transaction.timelineGeneration),
              transaction.rendererGeneration == rendererGeneration,
              transaction.rendererID == ObjectIdentifier(renderer) else { return }
        guard dspRequestGate.isCurrent(transaction.request.token) else {
            finishSupersededPreparation(id: nil, request: transaction.request)
            return
        }
        let clock = currentSynchronizerClockSeconds()
        let analysisPublishedThrough = clock + analysisLeadSeconds
            - analysisDeliveryLeadSeconds + 0.005
        let swapPoint = max(clock, analysisPublishedThrough)
        // The flush removes every queued buffer from the swap point on, so the
        // renderer only has `swapPoint - clock` left to cover the round trip
        // that re-enqueues the replaced output.
        let margin = transaction.startPTS - swapPoint
        guard margin >= Self.dspFlushSafetySeconds else {
            Self.pipelineLog.info(
                "dsp apply: swap point \(transaction.startPTS, format: .fixed(precision: 3))s is only \(margin, format: .fixed(precision: 3))s ahead; waiting for the queue horizon"
            )
            installDSPAtQueueHorizon(transaction.request, processor: transaction.finalProcessor)
            return
        }
        activeDSPTransaction = transaction
        stopFeedTimer()
        let transactionID = transaction.transactionID
        let timelineID = transaction.timelineGeneration
        let rendererGenerationID = transaction.rendererGeneration
        let rendererID = transaction.rendererID
        let time = transaction.blocks.first.map {
            CMSampleBufferGetPresentationTimeStamp($0.sampleBuffer)
        } ?? CMTime(seconds: transaction.startPTS, preferredTimescale: 600)
        Self.pipelineLog.info(
            "dsp apply: flushing from \(transaction.startPTS, format: .fixed(precision: 3))s with \(margin, format: .fixed(precision: 3))s of margin, blocks=\(transaction.blocks.count, privacy: .public)"
        )
        renderer.flush(fromSourceTime: time) { [weak self] succeeded in
            guard let self else { return }
            self.pipelineQueue.async { [weak self] in
                self?.completePartialDSPFlush(
                    transactionID: transactionID,
                    timelineGeneration: timelineID,
                    rendererGeneration: rendererGenerationID,
                    rendererID: rendererID,
                    succeeded: succeeded
                )
            }
        }
    }

    private func completePartialDSPFlush(
        transactionID: UUID,
        timelineGeneration expectedTimeline: UUID,
        rendererGeneration expectedRendererGeneration: UUID,
        rendererID expectedRendererID: ObjectIdentifier,
        succeeded: Bool
    ) {
        guard let transaction = activeDSPTransaction,
              transaction.transactionID == transactionID,
              transaction.timelineGeneration == expectedTimeline,
              transaction.rendererGeneration == expectedRendererGeneration,
              transaction.rendererID == expectedRendererID,
              timelineGenerationGate.isCurrent(expectedTimeline),
              timelineGeneration == expectedTimeline,
              rendererGeneration == expectedRendererGeneration,
              ObjectIdentifier(renderer) == expectedRendererID else { return }

        activeDSPTransaction = nil
        guard succeeded else {
            // Nothing was flushed, so the queued output is untouched: adopt the
            // prepared processor at the queue horizon instead of stopping. A
            // renderer whose current configuration does not support a partial
            // flush answers this way, and that answer is normal here.
            Self.pipelineLog.info("dsp apply: renderer rejected the flush; waiting for the queue horizon")
            installDSPAtQueueHorizon(transaction.request, processor: transaction.finalProcessor)
            return
        }
        guard renderer.status != .failed else {
            recoverFailedRenderer(atTimelineClock: currentSynchronizerClockSeconds())
            emitDSPEvent(
                transaction.request,
                state: .failed,
                format: currentDSPFormat,
                scheduledPTS: nil,
                audiblePTS: nil,
                headroomDB: nil,
                warnings: transaction.warnings,
                diagnostics: [DSPDiagnostic(
                    code: "rendererFailedDuringApply",
                    message: "The renderer failed while applying the DSP update.",
                    retryable: true
                )]
            )
            startQueuedDSPApply(afterPTS: transaction.startPTS)
            return
        }

        if currentSynchronizerClockSeconds() >= transaction.startPTS {
            // The flush landed after its own swap point, so the renderer has
            // been without data since then. Enqueueing the prepared output now
            // resumes with the new settings; rebuilding the timeline here would
            // turn a short gap into a long one.
            Self.pipelineLog.warning(
                "dsp apply: flush completed behind \(transaction.startPTS, format: .fixed(precision: 3))s; committing late"
            )
            commitDSPReplacement(transaction)
            startQueuedDSPApply(afterPTS: transaction.startPTS)
            return
        }

        // Enqueue the already-prepared output immediately after a successful
        // flush. A newer edit starts a separate preparation while feeding runs.
        commitDSPReplacement(transaction)
        startQueuedDSPApply(afterPTS: transaction.startPTS)
    }

    private func commitDSPReplacement(_ transaction: DSPReplacementTransaction) {
        guard transaction.timelineGeneration == timelineGeneration,
              timelineGenerationGate.isCurrent(transaction.timelineGeneration),
              transaction.rendererGeneration == rendererGeneration,
              transaction.rendererID == ObjectIdentifier(renderer) else { return }
        for block in transaction.blocks {
            renderer.enqueue(block.sampleBuffer)
        }
        analysisQueue.removeAll { $0.presentationTime >= transaction.startPTS - 0.000_001 }
        for block in transaction.blocks {
            appendAnalysisChunks(
                block.output,
                presentationTime: block.raw.presentationTime,
                segmentID: block.raw.segmentID,
                revision: transaction.request.revision
            )
        }
        // Crossfaded buffers retain their actual old/new mixture even when the
        // new processor is bypassed. A following edit may select an earlier T.
        var replacementByKey = [DSPBlockKey: DSPReplacementBlock]()
        for block in transaction.blocks { replacementByKey[DSPBlockKey(block.raw)] = block }
        for index in dspOutputBoundaries.indices
            where dspOutputBoundaries[index].presentationTime >= transaction.startPTS - 0.000_001 {
            dspOutputBoundaries[index].outputIsIdentity = false
            if let block = replacementByKey[DSPBlockKey(dspOutputBoundaries[index])] {
                dspOutputBoundaries[index].request = transaction.request
                dspOutputBoundaries[index].headroomDB = block.headroomDB
                dspOutputBoundaries[index].processingLatencyFrames = block.processingLatencyFrames
                dspOutputBoundaries[index].peakGuarantee = block.peakGuarantee
                dspOutputBoundaries[index].warnings = block.warnings
                dspOutputBoundaries[index].state = block.state
            }
        }
        dspLedger.removeAll { $0.raw.presentationTime >= transaction.startPTS - 0.000_001 }
        dspLedger.append(contentsOf: transaction.blocks.map {
            DSPQueuedBlock(raw: $0.raw, output: $0.output, revision: transaction.request.revision)
        })
        dspConfiguration = transaction.request.configuration
        dspRevision = transaction.request.revision
        dspContext = transaction.request.context
        effectiveDSPRequest = transaction.request
        dspProcessor = transaction.finalProcessor
        dspHorizonTransition = nil
        nextPresentationTime = transaction.oldHorizonPTS
        pendingAudibleDSPEvent = DSPApplyEvent(
            requestID: transaction.request.requestID,
            revisionString: transaction.request.revision,
            state: .scheduled,
            format: transaction.format,
            scheduledPTS: transaction.startPTS,
            audiblePTS: nil,
            headroomDB: transaction.headroomDB,
            processingLatencyFrames: transaction.processingLatencyFrames,
            mediaMappingLatencyFrames: 0,
            peakGuarantee: transaction.peakGuarantee,
            warnings: transaction.warnings,
            diagnostics: transaction.warnings,
            rebuffered: false
        )
        emitDSPEvent(
            transaction.request,
            state: .scheduled,
            format: transaction.format,
            scheduledPTS: transaction.startPTS,
            audiblePTS: nil,
            headroomDB: transaction.headroomDB,
            processingLatencyFrames: transaction.processingLatencyFrames,
            peakGuarantee: transaction.peakGuarantee,
            warnings: transaction.warnings,
            diagnostics: transaction.warnings
        )
        pruneDSPHistory()
        startFeedTimerIfNeeded()
    }

    private func appendAnalysisChunks(
        _ pcm: CanonicalPCM,
        presentationTime: Double,
        segmentID: UUID,
        revision: String
    ) {
        var offset = 0
        while offset < pcm.frames {
            let count = min(Self.analysisChunkFrames, pcm.frames - offset)
            analysisQueue.append(AnalysisChunk(
                presentationTime: presentationTime + Double(offset) / pcm.sampleRate,
                pcm: pcm.slice(frameOffset: offset, frameCount: count),
                segmentID: segmentID,
                dspRevision: revision
            ))
            offset += count
        }
    }

    private func startQueuedDSPApply(afterPTS: Double) {
        guard queuedDSPApply != nil else { return }
        startNextDSPApply(retryCount: 0, afterPTS: afterPTS)
    }

    /// Binds the renderer and its synchronizer to a Core Audio output device.
    ///
    /// AVSampleBufferAudioRenderer can change the synchronizer's source clock
    /// when this property changes. Serialize the change with enqueueing and
    /// perform it as one stop/flush/reprime transaction so a running AirPods
    /// route cannot leave the timebase paused or release an old queue after the
    /// new device has become active.
    func setAudioOutputDeviceUniqueID(_ uniqueID: String?) {
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.audioOutputDeviceUniqueID != uniqueID else {
                self.publishOutputDevice(uniqueID)
                return
            }

            let oldUID = self.audioOutputDeviceUniqueID
            self.audioOutputDeviceUniqueID = uniqueID
            let clock = self.currentSynchronizerClockSeconds()
            let wasPlaying = self.outputGainController.desiredPlaying
            self.isPlaybackActive = wasPlaying
            self.outputGainController.reset(playing: wasPlaying)
            let rendererWasFailed = self.renderer.status == .failed
            self.lastSystemChangeWallTime = ProcessInfo.processInfo.systemUptime

            guard self.isLoaded else {
                if uniqueID == nil, oldUID != nil {
                    self.replaceRendererForDefaultOutput()
                } else if let uniqueID {
                    self.renderer.audioOutputDeviceUniqueID = uniqueID
                }
                Self.pipelineLog.info(
                    "output device clock selected old=\(oldUID ?? "default", privacy: .public) new=\(uniqueID ?? "default", privacy: .public) loaded=false"
                )
                self.publishOutputDevice(uniqueID)
                return
            }

            let anchor = CMTime(seconds: clock, preferredTimescale: 600)
            self.timelineMutationInProgress = true
            self.explicitTimelineClock = clock
            self.lastExplicitTimelineMutationWallTime = ProcessInfo.processInfo.systemUptime
            self.stopFeedTimer()

            // Apple documents that changing audioOutputDeviceUniqueID while a
            // timebase is running may briefly set its rate to zero. Establish a
            // known state before changing the source clock, then explicitly
            // restore the previous playback state after the new queue is ready.
            self.setSynchronizerRateSynchronously(0, time: anchor)
            if rendererWasFailed {
                self.recoverFailedRenderer(atTimelineClock: clock)
                self.timelineMutationInProgress = false
                self.resetStallBaseline(clock: clock)
                self.publishOutputDevice(uniqueID)
                return
            }
            if uniqueID == nil, oldUID != nil {
                self.replaceRendererForDefaultOutput()
            } else if let uniqueID {
                self.renderer.audioOutputDeviceUniqueID = uniqueID
            }
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: true)
            guard self.recoverSources(atTimelineSeconds: clock) else {
                self.timelineMutationInProgress = false
                return
            }
            if self.renderer.status == .failed {
                self.recoverFailedRenderer(atTimelineClock: clock)
                guard self.isLoaded else {
                    self.timelineMutationInProgress = false
                    return
                }
            } else {
                self.setSynchronizerRateSynchronously(wasPlaying ? 1 : 0, time: anchor)
                self.startFeedTimerIfNeeded()
            }
            self.timelineMutationInProgress = false
            self.resetStallBaseline(clock: clock)

            self.publishOutputDevice(uniqueID)

            Self.pipelineLog.info(
                "output device clock changed old=\(oldUID ?? "default", privacy: .public) new=\(uniqueID ?? "default", privacy: .public) anchor=\(clock, format: .fixed(precision: 3)) rate=\(wasPlaying ? 1 : 0)"
            )
        }
    }

    private func publishOutputDevice(_ uid: String?) {
        guard renderer.status != .failed else { return }
        DispatchQueue.main.async { [weak self] in self?.onOutputDeviceChange?(uid) }
    }

    /// Recreate the renderer when returning to the default output device. The
    /// current macOS implementation rejects an explicit `nil` assignment to
    /// audioOutputDeviceUniqueID, while a fresh renderer naturally starts with
    /// the default device selected.
    private func replaceRendererForDefaultOutput() {
        removeRendererObservers()
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: .positiveInfinity)

        let replacement = AVSampleBufferAudioRenderer()
        renderer = replacement
        rendererGeneration = UUID()
        configureRenderer(replacement)
        synchronizer.addRenderer(replacement)
        configureSpatialization(replacement)
        installRendererObservers(for: replacement, timelineGeneration: timelineGeneration)
    }

    // MARK: - Source timeline

    func load(
        source: RendererPCMProvider,
        sourcePosition: AVAudioFramePosition = 0,
        presentationStartSeconds: Double = 0,
        clockTimeSeconds: Double = 0,
        segmentID: UUID = UUID(),
        autoplay: Bool = true,
        normalizationGain: Double = 1,
        fadeOnStart: Bool = false
    ) {
        let requestedGeneration = timelineGenerationGate.advance()
        let transportGeneration = transportCommandGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.timelineGenerationGate.isCurrent(requestedGeneration) else { return }
            self.timelineGeneration = requestedGeneration
            self.transportCommandGeneration = transportGeneration
            self.stopFeedTimer()
            self.outputGainController.reset(playing: false, publish: false)
            self.activeLoadSegmentID = segmentID
            self.rendererFailureRecoveryBudget.beginNewRequest()
            self.invalidateStallRecovery()
            self.timelineMutationInProgress = true
            self.isLoaded = false
            self.isPlaybackActive = false
            self.explicitTimelineClock = max(0, clockTimeSeconds)
            self.lastExplicitTimelineMutationWallTime = ProcessInfo.processInfo.systemUptime

            // Stop the old timebase before flushing. All clock mutations stay
            // on pipelineQueue so a stale main-queue write cannot resume a
            // superseded source.
            self.setSynchronizerRateSynchronously(
                0,
                time: CMTime(seconds: max(0, clockTimeSeconds), preferredTimescale: 600)
            )
            self.removeRendererObservers()
            self.removeProgressObserver()
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: true)
            self.segments.removeAll(keepingCapacity: true)
            self.pendingDecodedPCM = nil
            self.dspLedger.removeAll(keepingCapacity: false)
            self.dspOutputBoundaries.removeAll(keepingCapacity: false)
            self.lastAudibleDSPFormat = nil
            self.activeDSPTransaction = nil
            self.dspPreparationID = nil
            self.preparingDSPRequest = nil
            self.dspHorizonTransition = nil
            self.pendingAudibleDSPEvent = nil
            if let request = self.latestAcceptedDSPRequest {
                self.dspConfiguration = request.configuration
                self.dspRevision = request.revision
                self.dspContext = request.context
                self.effectiveDSPRequest = request
            }
            self.queuedDSPApply = nil
            self.decodeIndex = nil
            self.pendingAutoFlushResync = false

            guard let segment = self.makeSegment(
                source: source,
                presentationStartSeconds: presentationStartSeconds,
                id: segmentID
            ) else {
                self.timelineMutationInProgress = false
                self.finishWithFailure(
                    .unsupportedFormat(
                        channels: source.sourceChannelCount,
                        sampleRate: source.sourceSampleRate
                    ),
                    segmentID: segmentID
                )
                return
            }

            do {
                let clamped = max(0, min(sourcePosition, source.totalFrames))
                try source.seek(to: clamped)
                var loadedSegment = segment
                loadedSegment.nextSourceFrame = clamped
                loadedSegment.normalizationGain = normalizationGain.isFinite ? max(0, normalizationGain) : 1
                self.segments = [loadedSegment]
                self.decodeIndex = clamped < source.totalFrames ? 0 : nil
                self.nextPresentationTime = presentationStartSeconds
                    + Double(clamped) / source.sourceSampleRate
                self.dspProcessor = AudioDSPProcessor(
                    configuration: self.dspConfiguration,
                    format: loadedSegment.sourceFormat, context: self.dspContext
                )
                self.dspProcessor?.reset()
                self.pendingAudibleDSPEvent = nil
            } catch {
                self.timelineMutationInProgress = false
                self.finishWithFailure(.sourceError(underlying: error), segmentID: segmentID)
                return
            }

            self.enqueueToken = UUID()
            self.isLoaded = true
            self.isPlaybackActive = autoplay
            self.resetStallBaseline(clock: clockTimeSeconds)
            // A seek should become audible as soon as the new anchor is
            // committed. Priming a full 1.5 s window here makes AirPods wait
            // for an unnecessarily large queue during their route handoff;
            // steady-state feed/recovery still use the larger bounded window.
            self.primeOneBatch(maxChunks: 2)

            if let request = self.effectiveDSPRequest {
                self.scheduleDSPRequestAtFirstQueuedPTS(request, rebuffered: false)
            }

            guard self.isLoaded,
                  self.timelineGenerationGate.isCurrent(requestedGeneration) else {
                self.timelineMutationInProgress = false
                return
            }

            if self.renderer.status == .failed {
                self.recoverFailedRenderer()
                guard self.isLoaded,
                      self.timelineGenerationGate.isCurrent(requestedGeneration) else {
                    self.timelineMutationInProgress = false
                    return
                }
            }

            let rate: Float = autoplay ? 1 : 0
            let clock = CMTime(seconds: max(0, clockTimeSeconds), preferredTimescale: 600)
            self.setSynchronizerRateSynchronously(rate, time: clock)
            self.outputGainController.reset(playing: autoplay, envelope: autoplay && !fadeOnStart ? 1 : 0)
            if autoplay && fadeOnStart {
                self.beginPlaybackFadeIn()
            }
            self.lastExplicitTimelineMutationWallTime = ProcessInfo.processInfo.systemUptime
            self.timelineMutationInProgress = false
            self.installRendererObservers(
                for: self.renderer,
                timelineGeneration: requestedGeneration
            )
            self.installProgressObserver(for: requestedGeneration)
            self.startFeedTimerIfNeeded()
            let committedClock = max(0, clockTimeSeconds)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.timelineGenerationGate.isCurrent(requestedGeneration) else { return }
                self.onTimelineMutationCommitted?(segmentID, committedClock, autoplay)
            }
        }
    }

    /// Queue a prepared next track on the same continuous renderer timeline.
    /// This call only mutates lightweight queue metadata and returns immediately;
    /// decoding remains on pipelineQueue.
    func append(
        source: RendererPCMProvider,
        expectedLoadSegmentID: UUID? = nil,
        normalizationGain: Double = 1
    ) -> RendererSegmentDescriptor? {
        let expectedTimelineGeneration = timelineGenerationGate.current()
        return pipelineQueue.sync {
            guard isLoaded,
                  timelineGeneration == expectedTimelineGeneration,
                  timelineGenerationGate.isCurrent(expectedTimelineGeneration),
                  expectedLoadSegmentID == nil || expectedLoadSegmentID == activeLoadSegmentID else {
                return nil
            }
            let start = segments.last?.descriptor.presentationEndSeconds
                ?? max(0, synchronizer.currentTime().seconds)
            let segmentID = UUID()
            guard var segment = makeSegment(
                source: source,
                presentationStartSeconds: start,
                id: segmentID
            ) else {
                let activeID = activeSegmentID(atTimelineClock: currentSynchronizerClockSeconds())
                finishWithFailure(
                    .unsupportedFormat(
                        channels: source.sourceChannelCount,
                        sampleRate: source.sourceSampleRate
                    ),
                    segmentID: activeID ?? activeLoadSegmentID
                )
                return nil
            }
            do {
                try source.seek(to: 0)
            } catch {
                let activeID = activeSegmentID(atTimelineClock: currentSynchronizerClockSeconds())
                finishWithFailure(
                    .sourceError(underlying: error),
                    segmentID: activeID ?? activeLoadSegmentID
                )
                return nil
            }
            segment.normalizationGain = normalizationGain.isFinite ? max(0, normalizationGain) : 1
            let previousSegment = segments.last
            segments.append(segment)
            if let previousSegment, previousSegment.sourceFormat == segment.sourceFormat {
                let generation = timelineGeneration
                let appendedID = segment.descriptor.id
                let previousID = previousSegment.descriptor.id
                pipelineQueue.async { [weak self] in
                    guard let self, self.isLoaded,
                          self.timelineGenerationGate.isCurrent(generation),
                          self.segments.contains(where: { $0.descriptor.id == appendedID }),
                          let previous = self.segments.first(where: { $0.descriptor.id == previousID }) else { return }
                    self.refreshDSPAfterLateAppend(previous)
                }
            }
            if decodeIndex == nil {
                decodeIndex = segments.count - 1
                nextPresentationTime = segment.descriptor.presentationStartSeconds
            }
            enqueueToken = UUID()
            startFeedTimerIfNeeded()
            return segment.descriptor
        }
    }

    /// A next source may arrive after the prior source's terminal FIR window
    /// was queued with EOF padding. Replace that still-future audio through
    /// the existing transaction before the new source becomes audible.
    private func refreshDSPAfterLateAppend(_ previous: Segment) {
        guard let processor = dspProcessor, processor.processingLatencyFrames > 0,
              let base = latestAcceptedDSPRequest ?? effectiveDSPRequest,
              dspOutputBoundaries.contains(where: {
                  $0.segmentID == previous.descriptor.id && !$0.outputIsIdentity
                      && $0.sourceFrameStart + AVAudioFramePosition($0.frameCount)
                          + AVAudioFramePosition(processor.processingLatencyFrames) > previous.source.totalFrames
              }) else { return }
        let affectedStartPTS = previous.descriptor.presentationEndSeconds
            - Double(processor.processingLatencyFrames) / previous.sourceFormat.sampleRate
        let clock = currentSynchronizerClockSeconds()
        let earliestSafePTS = max(clock, clock + analysisLeadSeconds - analysisDeliveryLeadSeconds + 0.005) + 0.05
        if isPlaybackActive, !dspOutputBoundaries.contains(where: {
            $0.presentationTime >= earliestSafePTS && $0.presentationTime + 0.03 <= affectedStartPTS
        }) {
            let warning = DSPDiagnostic(
                code: "dsp.lateGaplessLookahead",
                message: "The next source arrived after the prior FIR tail could be replaced safely; that queued tail retains its EOF boundary.",
                fieldPath: "processingLatencyFrames", retryable: false
            )
            let reportedRequest = effectiveDSPRequest ?? base
            let pending = pendingAudibleDSPEvent.flatMap { event -> DSPApplyEvent? in
                event.requestID == reportedRequest.requestID && event.revisionString == reportedRequest.revision ? event : nil
            }
            emitDSPEvent(reportedRequest, state: pending?.state ?? .audible, format: processor.format,
                scheduledPTS: pending?.scheduledPTS, audiblePTS: pending == nil ? clock : nil,
                headroomDB: processor.headroomDB,
                warnings: processor.diagnostics + [warning], diagnostics: processor.diagnostics + [warning])
            return
        }
        let request = DSPApplyRequest(configuration: base.configuration, revision: base.revision,
            requestID: base.requestID, token: base.token, context: desiredDSPContext)
        queuedDSPApply = request
        latestAcceptedDSPRequest = request
        if activeDSPTransaction == nil { startNextDSPApply(retryCount: 0, afterPTS: nil) }
    }

    /// Remove an already-queued prediction after the named segment. The
    /// renderer is flushed and reconstructed from the live clock so no samples
    /// from the rejected next track can leak through.
    func discardSegments(
        after segmentID: UUID,
        completion: (@Sendable () -> Void)? = nil
    ) {
        pipelineQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            guard let index = self.segments.firstIndex(where: { $0.descriptor.id == segmentID }),
                  index + 1 < self.segments.count else {
                completion?()
                return
            }
            self.segments.removeSubrange((index + 1)..<self.segments.count)
            self.stopFeedTimer()
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: true)
            let clock = self.currentSynchronizerClockSeconds()
            _ = self.recoverSources(atTimelineSeconds: clock)
            completion?()
        }
    }

    /// Drop sources through an audible gapless boundary after their final PCM
    /// has already been queued. The renderer's queued sample buffers and clock
    /// stay untouched; removing providers prevents a later recovery from
    /// seeking into a file whose security-scope lease is being released.
    func retireSegments(
        through segmentID: UUID,
        completion: (@Sendable () -> Void)? = nil
    ) {
        pipelineQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            guard let index = self.segments.firstIndex(where: { $0.descriptor.id == segmentID }) else {
                completion?()
                return
            }

            let removedCount = index + 1
            self.segments.removeSubrange(0..<removedCount)
            if let decodeIndex = self.decodeIndex {
                if decodeIndex < removedCount {
                    self.decodeIndex = self.segments.isEmpty ? nil : 0
                    if let next = self.segments.first {
                        self.nextPresentationTime = max(
                            self.nextPresentationTime,
                            next.descriptor.presentationStartSeconds
                        )
                    }
                } else {
                    self.decodeIndex = decodeIndex - removedCount
                }
            }
            self.enqueueToken = UUID()
            completion?()
        }
    }

    private func makeSegment(
        source: RendererPCMProvider,
        presentationStartSeconds: Double,
        id: UUID
    ) -> Segment? {
        let sourceFormat = source.sourceDSPFormat
        guard source.sourceSampleRate > 0,
              source.sourceChannelCount > 0,
              sourceFormat.sampleRate == source.sourceSampleRate,
              sourceFormat.channelCount == source.sourceChannelCount,
              let format = CMSampleBufferFactory.formatDescription(
                  sourceFormat: sourceFormat
              ) else {
            return nil
        }
        let duration = Double(source.totalFrames) / source.sourceSampleRate
        let descriptor = RendererSegmentDescriptor(
            id: id,
            presentationStartSeconds: max(0, presentationStartSeconds),
            presentationEndSeconds: max(0, presentationStartSeconds) + duration
        )
        return Segment(
            descriptor: descriptor,
            source: source,
            sourceFormat: sourceFormat,
            formatDescription: format,
            nextSourceFrame: 0
        )
    }

    // MARK: - Transport

    private func beginPlaybackFadeIn() {
        let clock = currentSynchronizerClockSeconds()
        // A fresh timeline has visualization lead before the first PCM PTS.
        // Starting the envelope at rate=1 would finish a short fade in silence.
        let firstUnplayedPTS = dspOutputBoundaries.first(where: {
            $0.endPresentationTime > clock + 0.000_001
        })?.presentationTime ?? clock
        let startPTS = max(clock, firstUnplayedPTS)
        let generation = timelineGeneration
        let commandGeneration = transportCommandGeneration
        let waitForAudio = outputGainController.envelope == 0
        outputGainController.transition(
            playing: true,
            configuration: fadeConfiguration,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.timelineGenerationGate.isCurrent(generation)
                    && self.transportCommandGate.isCurrent(commandGeneration)
            },
            startWhen: { [weak self] in
                guard let self, self.timelineGenerationGate.isCurrent(generation) else { return false }
                return !waitForAudio || self.currentSynchronizerClockSeconds() >= startPTS
            }
        ) {}
    }

    func play() {
        let expectedGeneration = timelineGenerationGate.current()
        let commandGeneration = transportCommandGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self,
                  self.isLoaded,
                  self.timelineGeneration == expectedGeneration,
                  self.timelineGenerationGate.isCurrent(expectedGeneration),
                  self.transportCommandGate.isCurrent(commandGeneration) else { return }
            self.transportCommandGeneration = commandGeneration
            // A pause envelope leaves the timebase running until it reaches
            // silence. Reversing that envelope must preserve the live clock
            // and queued PCM; setRate(time:) would re-anchor audible output.
            if self.isPlaybackActive && !self.pendingAutoFlushResync {
                self.beginPlaybackFadeIn()
                return
            }
            self.isPlaybackActive = true
            if self.pendingAutoFlushResync {
                self.pendingAutoFlushResync = false
                let clock = self.currentSynchronizerClockSeconds()
                self.renderer.flush()
                self.analysisQueue.removeAll(keepingCapacity: true)
                guard self.recoverSources(atTimelineSeconds: clock) else { return }
            }
            let clock = self.currentSynchronizerClockSeconds()
            self.resetStallBaseline(clock: clock)
            self.setSynchronizerRateSynchronously(
                1,
                time: CMTime(seconds: clock, preferredTimescale: 600)
            )
            self.startFeedTimerIfNeeded()
            self.beginPlaybackFadeIn()
        }
    }

    func pause() {
        let expectedGeneration = timelineGenerationGate.current()
        let commandGeneration = transportCommandGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self,
                  self.timelineGeneration == expectedGeneration,
                  self.timelineGenerationGate.isCurrent(expectedGeneration),
                  self.transportCommandGate.isCurrent(commandGeneration) else { return }
            self.transportCommandGeneration = commandGeneration
            self.outputGainController.transition(
                playing: false,
                configuration: self.fadeConfiguration,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.timelineGenerationGate.isCurrent(expectedGeneration)
                        && self.transportCommandGate.isCurrent(commandGeneration)
                }
            ) { [weak self] in
                guard let self,
                      self.timelineGenerationGate.isCurrent(expectedGeneration),
                      self.transportCommandGate.isCurrent(commandGeneration) else { return }
                self.isPlaybackActive = false
                self.invalidateStallRecovery()
                self.setSynchronizerRateSynchronously(0, time: self.synchronizer.currentTime())
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        // This is called from the main-actor playback command path. Preserve
        // ordering with the following load() through the serial queue, but do
        // not make the UI wait for an in-flight decode or renderer flush.
        let stopGeneration = timelineGenerationGate.advance()
        let transportGeneration = transportCommandGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            if self.timelineGenerationGate.isCurrent(stopGeneration) {
                self.timelineGeneration = stopGeneration
            }
            self.transportCommandGeneration = transportGeneration
            self.isLoaded = false
            self.isPlaybackActive = false
            self.outputGainController.reset(playing: false)
            self.activeLoadSegmentID = nil
            self.pendingAutoFlushResync = false
            self.invalidateStallRecovery()
            self.stopFeedTimer()
            self.removeRendererObservers()
            self.removeProgressObserver()
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: false)
            self.pendingDecodedPCM = nil
            self.dspLedger.removeAll(keepingCapacity: false)
            self.dspOutputBoundaries.removeAll(keepingCapacity: false)
            self.lastAudibleDSPFormat = nil
            self.pendingAudibleDSPEvent = nil
            self.activeDSPTransaction = nil
            self.dspPreparationID = nil
            self.preparingDSPRequest = nil
            self.dspHorizonTransition = nil
            if let request = self.latestAcceptedDSPRequest ?? self.effectiveDSPRequest {
                self.dspConfiguration = request.configuration
                self.dspRevision = request.revision
                self.dspContext = request.context
                self.effectiveDSPRequest = request
                self.emitDSPEvent(
                    request,
                    state: .ready,
                    format: self.currentDSPFormat,
                    scheduledPTS: nil,
                    audiblePTS: nil,
                    headroomDB: self.dspProcessor?.headroomDB,
                    warnings: self.dspProcessor?.diagnostics ?? [],
                    diagnostics: []
                )
            }
            self.queuedDSPApply = nil
            self.segments.removeAll(keepingCapacity: false)
            self.decodeIndex = nil
            self.nextPresentationTime = 0
            // Keep the reset on the same serial queue as flush/load. Posting
            // this back to main can let a stale stop overwrite the next
            // track's freshly committed synchronizer anchor.
            self.synchronizer.setRate(0, time: .zero)
            completion?()
        }
    }

    // MARK: - Producer

    private func startFeedTimerIfNeeded() {
        guard isLoaded, decodeIndex != nil, feedTimer == nil,
              activeDSPTransaction == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pipelineQueue)
        // Top up on a fixed short cadence. Deriving it from the ahead target made
        // a deeper queue refill more slowly, which is the opposite of what a
        // flush, a seek or a drained renderer needs.
        let cadence = min(Self.feedInterval, Self.feedTopUpInterval)
        timer.schedule(deadline: .now(), repeating: cadence)
        timer.setEventHandler { [weak self] in
            self?.provideMediaData()
        }
        timer.resume()
        feedTimer = timer
    }

    private func stopFeedTimer() {
        feedTimer?.cancel()
        feedTimer = nil
    }

    private func primeOneBatch(maxChunks: Int = 16) {
        var count = 0
        // AirPods can take longer to accept the first queue after a route or
        // spatial-mode transition. Prime a bounded batch, but never call
        // enqueue while the renderer reports backpressure.
        let clock = currentSynchronizerClockSeconds()
        let aheadLimit = dspQueueAheadLimitSeconds()
        while count < max(0, maxChunks),
              activeDSPTransaction == nil,
              nextPresentationTime - clock < aheadLimit,
              renderer.isReadyForMoreMediaData,
              enqueueOneChunk() {
            count += 1
        }
    }

    private func provideMediaData() {
        guard isLoaded,
              activeDSPTransaction == nil,
              timelineGenerationGate.isCurrent(timelineGeneration) else {
            stopFeedTimer()
            return
        }
        let clock = max(0, synchronizer.currentTime().seconds)
        let aheadLimit = dspQueueAheadLimitSeconds()
        guard nextPresentationTime - clock < aheadLimit else { return }
        guard renderer.isReadyForMoreMediaData else { return }

        var count = 0
        while count < 16,
              nextPresentationTime - clock < aheadLimit,
              renderer.isReadyForMoreMediaData,
              enqueueOneChunk() {
            count += 1
        }
    }

    @discardableResult
    private func enqueueOneChunk() -> Bool {
        guard activeDSPTransaction == nil,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
        while pendingDecodedPCM == nil {
            guard let index = decodeIndex, segments.indices.contains(index) else {
                stopFeedTimer()
                return false
            }
            let token = enqueueToken
            let source = segments[index].source
            let sourceFrameStart = segments[index].nextSourceFrame
            ensureDSPProcessor(for: segments[index].sourceFormat)
            source.setDSPReadAheadEnabled((dspProcessor?.processingLatencyFrames ?? 0) > 0)
            do {
                guard let pcm = try source.nextChunk(maxFrames: Self.chunkFrames) else {
                    reportExhaustionIfNeeded(at: index)
                    if index + 1 < segments.count {
                        decodeIndex = index + 1
                        nextPresentationTime = max(
                            nextPresentationTime,
                            segments[index + 1].descriptor.presentationStartSeconds
                        )
                        continue
                    }
                    decodeIndex = nil
                    stopFeedTimer()
                    return false
                }
                guard token == enqueueToken,
                      timelineGenerationGate.isCurrent(timelineGeneration),
                      segments.indices.contains(index) else { return false }

                segments[index].nextSourceFrame += AVAudioFramePosition(pcm.frames)
                pendingDecodedPCM = PendingDecodedPCM(
                    segmentID: segments[index].descriptor.id,
                    sourceFrameStart: sourceFrameStart,
                    presentationTime: segments[index].descriptor.presentationStartSeconds
                        + Double(sourceFrameStart) / source.sourceSampleRate,
                    format: segments[index].sourceFormat,
                    pcm: pcm
                )
            } catch {
                let failedSegmentID = segments.indices.contains(index)
                    ? segments[index].descriptor.id
                    : activeLoadSegmentID
                finishWithFailure(
                    .sourceError(underlying: error),
                    segmentID: failedSegmentID
                )
                return false
            }
        }

        guard var pending = pendingDecodedPCM else { return false }
        let frameCount = min(Self.enqueueBlockFrames, pending.pcm.frames - pending.frameOffset)
        guard frameCount > 0,
              let segmentIndex = segments.firstIndex(where: {
                  $0.descriptor.id == pending.segmentID
              }) else {
            pendingDecodedPCM = nil
            return false
        }

        let normalizationGain = segments[segmentIndex].normalizationGain
        let rawPCM = Self.applyingFixedGain(pending.pcm.slice(
            frameOffset: pending.frameOffset, frameCount: frameCount
        ), gain: normalizationGain)
        let sourceFrameStart = pending.sourceFrameStart + AVAudioFramePosition(pending.frameOffset)
        let ptsSeconds = pending.presentationTime + Double(pending.frameOffset) / rawPCM.sampleRate
        let pts = CMSampleBufferFactory.time(
            frames: Int64((ptsSeconds * rawPCM.sampleRate).rounded()),
            sampleRate: rawPCM.sampleRate
        )
        guard timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
        ensureDSPProcessor(for: pending.format)
        let state = dspProcessor?.stateSnapshot()
        let wasCrossfaded = dspHorizonTransition != nil
        var outputPCM: CanonicalPCM
        do {
            let future = try dspLookahead(
                after: sourceFrameStart + AVAudioFramePosition(rawPCM.frames),
                segmentID: pending.segmentID, format: pending.format,
                frameCount: max(dspProcessor?.processingLatencyFrames ?? 0, dspHorizonTransition?.previous.processingLatencyFrames ?? 0)
            )
            outputPCM = dspProcessor?.process(rawPCM, lookahead: future) ?? rawPCM
            if var transition = dspHorizonTransition, transition.previous.format == pending.format {
                let old = transition.previous.process(rawPCM, lookahead: future)
                outputPCM = AudioDSPProcessor.crossfade(old: old, new: outputPCM, weights: transition.weights,
                    transitionOffsetSeconds: transition.offsetSeconds, weightSampleRate: pending.format.sampleRate)
                transition.offsetSeconds += rawPCM.seconds
                dspHorizonTransition = transition.offsetSeconds < 0.03 ? transition : nil
            }
        } catch {
            finishWithFailure(.sourceError(underlying: error), segmentID: pending.segmentID)
            return false
        }
        guard let sampleBuffer = CMSampleBufferFactory.makeSampleBuffer(
            from: outputPCM,
            formatDescription: segments[segmentIndex].formatDescription,
            presentationTime: pts
        ) else {
            finishWithFailure(
                .unsupportedFormat(
                    channels: outputPCM.channelCount,
                    sampleRate: outputPCM.sampleRate
                ),
                segmentID: pending.segmentID
            )
            return false
        }

        let rawBlock = DSPPCMBlock(
            segmentID: pending.segmentID,
            sourceFrameStart: sourceFrameStart,
            presentationTime: ptsSeconds,
            format: pending.format,
            pcm: rawPCM
        )
        dspOutputBoundaries.append(DSPOutputBoundary(
            enqueueID: UUID(),
            outputIsIdentity: (dspProcessor?.isBypassed ?? true) && !wasCrossfaded,
            segmentID: rawBlock.segmentID,
            sourceFrameStart: rawBlock.sourceFrameStart,
            presentationTime: rawBlock.presentationTime,
            frameCount: rawBlock.pcm.frames,
            format: rawBlock.format,
            normalizationGain: normalizationGain,
            request: effectiveDSPRequest,
            headroomDB: dspProcessor?.headroomDB ?? 0,
            processingLatencyFrames: dspProcessor?.processingLatencyFrames ?? 0,
            peakGuarantee: dspProcessor?.peakGuarantee ?? "bypassed",
            warnings: dspProcessor?.diagnostics ?? [],
            state: state
        ))
        // Bypass raw/output share the same immutable PCM array. Retaining a
        // bounded history avoids provider seeks when DSP is first enabled.
        dspLedger.append(DSPQueuedBlock(raw: rawBlock, output: outputPCM, revision: dspRevision))
        pruneDSPHistory()

        onEnqueue?(outputPCM, ptsSeconds)
        var sliceOffset = 0
        while sliceOffset < outputPCM.frames {
            let sliceCount = min(Self.analysisChunkFrames, outputPCM.frames - sliceOffset)
            let slicePTS = ptsSeconds + (Double(sliceOffset) / outputPCM.sampleRate)
            let slicePCM = outputPCM.slice(frameOffset: sliceOffset, frameCount: sliceCount)
            analysisQueue.append(AnalysisChunk(
                presentationTime: slicePTS,
                pcm: slicePCM,
                segmentID: pending.segmentID,
                dspRevision: dspRevision
            ))
            sliceOffset += sliceCount
        }
        renderer.enqueue(sampleBuffer)
        nextPresentationTime = ptsSeconds + outputPCM.seconds

        pending.frameOffset += frameCount
        pendingDecodedPCM = pending.frameOffset < pending.pcm.frames ? pending : nil
        return true
    }

    /// Prepared replacements already own normalized, source-time raw PCM.
    /// Reuse those blocks before consulting a provider, so a parameter edit
    /// does not seek/decode the same future window for every output block.
    private func dspLookahead(
        after raw: DSPPCMBlock,
        frameCount: Int,
        following blocks: ArraySlice<DSPPCMBlock>
    ) throws -> CanonicalPCM? {
        guard frameCount > 0 else { return nil }
        var data = [Float]()
        data.reserveCapacity(frameCount * raw.format.channelCount)
        var expectedPTS = raw.endPresentationTime
        var lastSegmentID = raw.segmentID
        var lastSourceFrame = raw.sourceFrameStart + AVAudioFramePosition(raw.pcm.frames)
        for block in blocks {
            guard block.format == raw.format,
                  abs(block.presentationTime - expectedPTS) <= 0.5 / raw.format.sampleRate else {
                let remaining = frameCount * raw.format.channelCount - data.count
                data.append(contentsOf: repeatElement(Float(0), count: remaining))
                return CanonicalPCM(frames: frameCount, channelCount: raw.format.channelCount,
                                    sampleRate: raw.format.sampleRate, data: data)
            }
            let count = min(frameCount - data.count / raw.format.channelCount, block.pcm.frames)
            data.append(contentsOf: block.pcm.data.prefix(count * raw.format.channelCount))
            expectedPTS = block.presentationTime + Double(count) / raw.format.sampleRate
            lastSegmentID = block.segmentID
            lastSourceFrame = block.sourceFrameStart + AVAudioFramePosition(count)
            if data.count == frameCount * raw.format.channelCount {
                return CanonicalPCM(frames: frameCount, channelCount: raw.format.channelCount,
                                    sampleRate: raw.format.sampleRate, data: data)
            }
        }
        let remainingFrames = frameCount - data.count / raw.format.channelCount
        if let tail = try dspLookahead(after: lastSourceFrame, segmentID: lastSegmentID,
                                      format: raw.format, frameCount: remainingFrames) {
            data.append(contentsOf: tail.data)
        }
        return CanonicalPCM(frames: frameCount, channelCount: raw.format.channelCount,
                            sampleRate: raw.format.sampleRate, data: data)
    }

    private func dspLookahead(
        after sourceFrame: AVAudioFramePosition,
        segmentID: UUID,
        format: DSPAudioFormat,
        frameCount: Int
    ) throws -> CanonicalPCM? {
        guard frameCount > 0 else { return nil }
        guard let index = segments.firstIndex(where: { $0.descriptor.id == segmentID }) else {
            throw DSPApplyPreparationError.unavailablePCM
        }
        return try RendererDSPLookahead.read(
            frameCount: frameCount, format: format, segmentIndex: index,
            sourceFrame: sourceFrame, segmentCount: segments.count
        ) { index in
            let segment = self.segments[index]
            let decoded = self.pendingDecodedPCM.flatMap { pending -> PendingDecodedPCM? in
                pending.segmentID == segment.descriptor.id && pending.format == format ? pending : nil
            }
            return RendererDSPSourceRange(
                source: segment.source, format: segment.sourceFormat,
                presentationStartSeconds: segment.descriptor.presentationStartSeconds,
                normalizationGain: segment.normalizationGain,
                decodePosition: segment.nextSourceFrame,
                decodedPCM: decoded?.pcm, decodedStartFrame: decoded?.sourceFrameStart ?? 0
            )
        }
    }

    private static func applyingFixedGain(_ pcm: CanonicalPCM, gain: Double) -> CanonicalPCM {
        guard gain != 1 else { return pcm }
        return CanonicalPCM(frames: pcm.frames, channelCount: pcm.channelCount,
                            sampleRate: pcm.sampleRate, data: pcm.data.map { Float(Double($0) * gain) })
    }

    private func ensureDSPProcessor(for format: DSPAudioFormat) {
        if let dspProcessor, dspProcessor.format == format { return }
        let processor = AudioDSPProcessor(configuration: dspConfiguration, format: format, context: dspContext)
        processor.reset()
        dspProcessor = processor
    }

    private func pruneDSPHistory() {
        let currentPTS = currentSynchronizerClockSeconds()
        let earliestPTS = currentPTS - 2.5
        dspOutputBoundaries.removeAll { $0.endPresentationTime < earliestPTS }
        dspLedger.removeAll { $0.raw.endPresentationTime < earliestPTS }
        var cachedBytes = dspLedger.reduce(0) {
            $0 + 4 * ($1.raw.pcm.data.count + $1.output.data.count)
        }
        while cachedBytes > Self.dspLedgerByteLimit,
              let oldestPastIndex = dspLedger.firstIndex(where: {
                  $0.raw.endPresentationTime < currentPTS - 0.01
              }) {
            let removed = dspLedger.remove(at: oldestPastIndex)
            cachedBytes -= 4 * (removed.raw.pcm.data.count + removed.output.data.count)
        }
    }

    private func dspQueueAheadLimitSeconds() -> Double {
        guard let processor = dspProcessor, !processor.isBypassed else {
            // An enabled chain that currently does nothing is one edit away from
            // working again, so it keeps the short queue. A disabled chain has no
            // edit to answer and keeps the deeper buffer.
            return dspConfiguration.enabled ? Self.dspTargetAheadSeconds : Self.targetAheadSeconds
        }
        let candidateSegments = segments.dropFirst(max(0, decodeIndex ?? segments.count))
        let formats = candidateSegments.map(\.sourceFormat) + [processor.format]
        let maximumBytesPerSecond = formats.reduce(0.0) { maximum, format in
            max(maximum, format.sampleRate * Double(format.channelCount) * 4 * 2)
        }
        guard maximumBytesPerSecond.isFinite, maximumBytesPerSecond > 0 else {
            return Self.targetAheadSeconds
        }
        let maximumBytesPerFrame = formats.reduce(0) {
            max($0, $1.channelCount * 4 * 2)
        }
        let maximumBlockFrames = min(
            Int(Self.enqueueBlockFrames),
            max(1, Self.dspFutureByteBudget / max(1, maximumBytesPerFrame))
        )
        let maximumBlockBytes = maximumBlockFrames * maximumBytesPerFrame
        let maximumSampleRate = formats.reduce(0.0) { max($0, $1.sampleRate) }
        let remainingBudgetSeconds = Double(max(0, Self.dspFutureByteBudget - maximumBlockBytes))
            / maximumBytesPerSecond
        // Leave room for one complete block beyond the threshold used by the
        // feed loop. The single-frame quantum lets an empty queue start even
        // when that one-block reserve consumes the entire future budget.
        let minimumQueueingQuantum = maximumSampleRate > 0 ? 1 / maximumSampleRate : 0
        return min(
            Self.dspTargetAheadSeconds,
            max(remainingBudgetSeconds, minimumQueueingQuantum)
        )
    }

    private func reportExhaustionIfNeeded(at index: Int) {
        guard segments.indices.contains(index), !segments[index].didReportExhaustion else { return }
        segments[index].didReportExhaustion = true
        let descriptor = segments[index].descriptor
        let generation = timelineGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.timelineGenerationGate.isCurrent(generation) else { return }
            self.onSegmentExhausted?(descriptor)
        }
    }

    // MARK: - Analysis timing and stall detection

    private func startAnalysisTimer() {
        let timer = DispatchSource.makeTimerSource(queue: pipelineQueue)
        timer.schedule(deadline: .now(), repeating: Self.analysisInterval)
        timer.setEventHandler { [weak self] in
            self?.analysisTick()
        }
        timer.resume()
        analysisTimer = timer
    }

    private func analysisTick() {
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return }
        let clock = max(0, synchronizer.currentTime().seconds)
        if isPlaybackActive {
            // `analysisLeadSeconds` is already encoded in every sample's PTS
            // (the renderer deliberately starts the first buffer after the
            // logical clock by that amount). The delivery lead is the same
            // application-owned lookahead, not a route-latency estimate. The
            // active output device clock is selected on the renderer itself.
            let threshold = clock
                + analysisLeadSeconds
                - analysisDeliveryLeadSeconds
                + 0.005
            while let first = analysisQueue.first, first.presentationTime <= threshold {
                analysisQueue.removeFirst()
                onAnalysisPCM?(first.pcm)
            }
            if var event = pendingAudibleDSPEvent,
               let scheduledPTS = event.scheduledPTS,
               clock >= scheduledPTS {
                event.state = .audible
                event.audiblePTS = clock
                pendingAudibleDSPEvent = nil
                lastAudibleDSPFormat = event.format
                lastAudibleDSPDiagnosticIDs = Set(event.warnings.map(\.id))
                emitDSPEvent(event)
            }
            publishAudibleDSPFormatIfNeeded(at: clock)
            detectStall(clock: clock)
        }
        prunePlayedSegments(clock: clock)
        pruneDSPHistory()
    }

    /// Decoding can lead playback by seconds. Publish format-dependent routing
    /// and latency from the block reaching the output clock, not the decoder.
    private func publishAudibleDSPFormatIfNeeded(at clock: Double) {
        guard let boundary = dspOutputBoundaries.first(where: {
            $0.presentationTime <= clock && clock < $0.endPresentationTime
        }), let request = boundary.request,
              boundary.format != lastAudibleDSPFormat
                || Set(boundary.warnings.map(\.id)) != lastAudibleDSPDiagnosticIDs else { return }
        lastAudibleDSPFormat = boundary.format
        lastAudibleDSPDiagnosticIDs = Set(boundary.warnings.map(\.id))
        emitDSPEvent(request, state: .audible, format: boundary.format,
                     scheduledPTS: boundary.presentationTime, audiblePTS: clock,
                     headroomDB: boundary.headroomDB,
                     processingLatencyFrames: boundary.processingLatencyFrames,
                     peakGuarantee: boundary.peakGuarantee,
                     warnings: boundary.warnings, diagnostics: boundary.warnings)
    }

    private func prunePlayedSegments(clock: Double) {
        while segments.count > 1,
              clock > segments[0].descriptor.presentationEndSeconds + 0.25 {
            segments.removeFirst()
            if let decodeIndex {
                self.decodeIndex = max(0, decodeIndex - 1)
            }
        }
    }

    private func resetStallBaseline(clock: Double) {
        lastAdvancingClock = max(0, clock)
        lastClockAdvanceWallTime = ProcessInfo.processInfo.systemUptime
        invalidateStallRecovery()
    }

    private func invalidateStallRecovery() {
        stallRecoveryToken = UUID()
        stallRecoveryScheduled = false
    }

    private func detectStall(clock: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if clock > lastAdvancingClock + 0.05 {
            _ = rendererFailureRecoveryBudget.observeClock(
                previous: lastAdvancingClock,
                current: clock,
                rendererIsRendering: renderer.status == .rendering
            )
            lastAdvancingClock = clock
            lastClockAdvanceWallTime = now
            return
        }
        guard lastClockAdvanceWallTime > 0,
              now - lastClockAdvanceWallTime > 0.8,
              now - lastSystemChangeWallTime > Self.rebuildSuppressionInterval,
              !stallRecoveryScheduled else { return }

        stallRecoveryScheduled = true
        let token = UUID()
        stallRecoveryToken = token
        let baselineClock = clock
        let generation = timelineGeneration
        let currentRendererGeneration = rendererGeneration
        Self.pipelineLog.warning(
            "renderer clock stalled at \(clock, format: .fixed(precision: 3))s; scheduling recovery"
        )
        pipelineQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            defer { self.stallRecoveryScheduled = false }
            guard self.stallRecoveryToken == token,
                  self.timelineGenerationGate.isCurrent(generation),
                  self.timelineGeneration == generation,
                  self.rendererGeneration == currentRendererGeneration,
                  self.isPlaybackActive,
                  self.currentSynchronizerClockSeconds() <= baselineClock + 0.2,
                  ProcessInfo.processInfo.systemUptime - self.lastSystemChangeWallTime
                    > Self.rebuildSuppressionInterval else { return }
            self.rebuildRendererAndResume(at: max(0, baselineClock))
        }
    }

    // MARK: - System flush and recovery

    private func handleAutomaticFlush(
        flushTime: CMTime,
        observedRendererID: ObjectIdentifier,
        rendererGeneration: UUID,
        timelineGeneration: UUID
    ) {
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.timelineGenerationGate.isCurrent(timelineGeneration),
                  self.timelineGeneration == timelineGeneration,
                  self.rendererGeneration == rendererGeneration,
                  ObjectIdentifier(self.renderer) == observedRendererID else {
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastSystemChangeWallTime = now

            // A seek/load explicitly flushes the old renderer. On AirPods the
            // corresponding output-configuration notification may be delivered
            // just after the load closure, while this queue still contains the
            // old notification. Do not let that stale event rewind the freshly
            // sought provider. A real route event whose flush time matches the
            // new anchor is still allowed through.
            if self.timelineMutationInProgress {
                return
            }
            if now - self.lastExplicitTimelineMutationWallTime
                < Self.timelineMutationSuppressionInterval {
                let flushMatchesNewAnchor = flushTime.isNumeric
                    && abs(flushTime.seconds - self.explicitTimelineClock) < 0.35
                if !flushMatchesNewAnchor {
                    Self.pipelineLog.debug(
                        "ignored stale auto-flush during explicit timeline mutation"
                    )
                    return
                }
            }

            guard self.isLoaded else { return }
            let callbackGeneration = self.timelineGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.timelineGenerationGate.isCurrent(callbackGeneration) else { return }
                self.onSystemReconfigEvent?()
            }
            let clock = self.currentSynchronizerClockSeconds()
            self.resetStallBaseline(clock: clock)
            if !self.isPlaybackActive {
                self.pendingAutoFlushResync = true
                return
            }
            guard now - self.lastRecoveryWallTime > Self.recoveryCooldown else { return }
            self.lastRecoveryWallTime = now

            let device = Self.currentDefaultOutputDescription()
            Self.pipelineLog.info(
                "auto-flush at \(flushTime.isNumeric ? flushTime.seconds : -1, format: .fixed(precision: 3))s, output=\(device, privacy: .public); rebuilding queued timeline"
            )
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: true)
            guard self.recoverSources(atTimelineSeconds: clock) else { return }
            if self.renderer.status == .failed {
                self.recoverFailedRenderer()
                return
            }
            self.setSynchronizerRateSynchronously(
                1,
                time: CMTime(seconds: clock, preferredTimescale: 600)
            )
            self.startFeedTimerIfNeeded()
        }
    }

    private func takeDSPApplyForRendererRebuild() -> DSPApplyRequest? {
        let activeRequest = activeDSPTransaction?.request ?? preparingDSPRequest
        guard let request = queuedDSPApply ?? activeRequest else { return nil }
        if queuedDSPApply != nil, let activeRequest {
            emitDSPEvent(
                activeRequest,
                state: .superseded,
                format: currentDSPFormat,
                scheduledPTS: nil,
                audiblePTS: nil,
                headroomDB: nil,
                warnings: [],
                diagnostics: []
            )
        }
        activeDSPTransaction = nil
        dspPreparationID = nil
        preparingDSPRequest = nil
        dspHorizonTransition = nil
        queuedDSPApply = nil
        return request
    }

    private func recoverSources(
        atTimelineSeconds clock: Double,
        dspRebuffered: Bool = false
    ) -> Bool {
        stopFeedTimer()
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
        let interruptedDSPRequest = takeDSPApplyForRendererRebuild()
        if let interruptedDSPRequest {
            dspConfiguration = interruptedDSPRequest.configuration
            dspRevision = interruptedDSPRequest.revision
            dspContext = interruptedDSPRequest.context
            effectiveDSPRequest = interruptedDSPRequest
        }
        let reportDSPRebuffer = dspRebuffered || interruptedDSPRequest != nil
        let descriptors = segments.map(\.descriptor)
        guard let index = RendererRecoveryTimeline.segmentIndex(
            in: descriptors,
            clockSeconds: clock,
            leadSeconds: analysisLeadSeconds
        ) else {
            decodeIndex = nil
            pendingDecodedPCM = nil
            dspOutputBoundaries.removeAll(keepingCapacity: false)
            lastAudibleDSPFormat = nil
            dspLedger.removeAll(keepingCapacity: false)
            scheduleDSPRequestAtFirstQueuedPTS(effectiveDSPRequest, rebuffered: reportDSPRebuffer)
            return true
        }

        let selected = segments[index]
        let targetPTS = RendererRecoveryTimeline.nextPresentationTime(
            clockSeconds: clock,
            segmentStartSeconds: selected.descriptor.presentationStartSeconds,
            leadSeconds: analysisLeadSeconds
        )
        var recoveryWarnings = [DSPDiagnostic]()
        let nextProcessor = AudioDSPProcessor(
            configuration: dspConfiguration,
            format: selected.sourceFormat, context: dspContext
        )
        if !nextProcessor.isBypassed {
            let lowerBound = targetPTS - 2.0
            var warmupBoundaries = dspOutputBoundaries.filter { boundary in
                boundary.endPresentationTime >= lowerBound
                    && boundary.endPresentationTime <= targetPTS + 0.000_001
                    && boundary.format == selected.sourceFormat
                    && (segments.contains(where: { $0.descriptor.id == boundary.segmentID })
                        || dspLedger.contains(where: { DSPBlockKey($0.raw) == DSPBlockKey(boundary) }))
            }
            if let formatChange = warmupBoundaries.lastIndex(where: {
                $0.format != selected.sourceFormat
            }) {
                warmupBoundaries = Array(warmupBoundaries.suffix(from: warmupBoundaries.index(after: formatChange)))
            }
            if !warmupBoundaries.isEmpty {
                var contiguousStart = warmupBoundaries.count - 1
                while contiguousStart > 0 {
                    let previous = warmupBoundaries[contiguousStart - 1]
                    let next = warmupBoundaries[contiguousStart]
                    let tolerance = max(1 / next.format.sampleRate, 0.000_1)
                    guard previous.format == next.format,
                          abs(previous.endPresentationTime - next.presentationTime) <= tolerance else { break }
                    contiguousStart -= 1
                }
                warmupBoundaries = Array(warmupBoundaries[contiguousStart...])
            }
            var warmupBytes = warmupBoundaries.reduce(0) {
                $0 + $1.frameCount * $1.format.channelCount * MemoryLayout<Float>.size
            }
            while warmupBytes > Self.dspWarmupByteLimit,
                  let oldest = warmupBoundaries.first {
                warmupBytes -= oldest.frameCount * oldest.format.channelCount * MemoryLayout<Float>.size
                warmupBoundaries.removeFirst()
                recoveryWarnings.append(DSPDiagnostic(
                    code: "warmupHistoryLimited",
                    message: "The filter warmup history was shortened to fit the renderer memory budget.",
                    fieldPath: "dsp.warmup",
                    retryable: false
                ))
            }
            do {
                nextProcessor.warm(with: try rawBlocks(for: warmupBoundaries).map(\.pcm))
            } catch {
                finishWithFailure(
                    .sourceError(underlying: error),
                    segmentID: selected.descriptor.id
                )
                return false
            }
        }

        do {
            for candidate in index..<segments.count {
                let segment = segments[candidate]
                let frame = candidate == index
                    ? RendererRecoveryTimeline.sourceFrame(
                        clockSeconds: clock,
                        segmentStartSeconds: segment.descriptor.presentationStartSeconds,
                        leadSeconds: analysisLeadSeconds,
                        sampleRate: segment.source.sourceSampleRate,
                        totalFrames: segment.source.totalFrames
                    )
                    : 0
                try segment.source.seek(to: frame)
                segments[candidate].nextSourceFrame = frame
            }
        } catch {
            finishWithFailure(
                .sourceError(underlying: error),
                segmentID: segments.indices.contains(index) ? segments[index].descriptor.id : activeLoadSegmentID
            )
            return false
        }

        // Segment descriptors are expressed on the renderer PTS timeline,
        // while the synchronizer clock is the logical media timeline. Keep the
        // configured output delay when rebuilding after an automatic flush or
        // a stall; anchoring the next PTS directly at `clock` would silently
        // remove the delay after the first route/mode recovery.
        decodeIndex = index
        pendingDecodedPCM = nil
        nextPresentationTime = RendererRecoveryTimeline.nextPresentationTime(
            clockSeconds: clock,
            segmentStartSeconds: selected.descriptor.presentationStartSeconds,
            leadSeconds: analysisLeadSeconds
        )
        dspProcessor = nextProcessor
        // Discard a buffer that straddles the recovery anchor as well. Keeping
        // its prefix metadata alongside freshly decoded output creates overlap.
        dspOutputBoundaries.removeAll { $0.endPresentationTime > nextPresentationTime + 0.000_001 }
        dspLedger.removeAll {
            $0.raw.presentationTime + $0.raw.pcm.seconds > nextPresentationTime + 0.000_001
        }
        let previouslyQueuedBlocks = Set(dspOutputBoundaries.map(\.enqueueID))
        enqueueToken = UUID()
        primeOneBatch()
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
        scheduleDSPRequestAtFirstQueuedPTS(
            effectiveDSPRequest,
            rebuffered: reportDSPRebuffer,
            excludingPreviouslyQueued: previouslyQueuedBlocks,
            additionalWarnings: recoveryWarnings
        )
        startFeedTimerIfNeeded()
        return true
    }

    private func rebuildRendererAndResume(at clock: Double) {
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return }
        Self.pipelineLog.warning(
            "stall recovery: replacing renderer at \(clock, format: .fixed(precision: 3))s"
        )
        recoverFailedRenderer(atTimelineClock: clock)
    }

    // MARK: - Progress and diagnostics

    private func installProgressObserver(for generation: UUID) {
        removeProgressObserver()
        progressObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            guard let self,
                  self.timelineGenerationGate.isCurrent(generation),
                  time.isNumeric,
                  time.seconds.isFinite else { return }
            // Time observers are asynchronous. A callback queued just before
            // a seek can run after the new setRate(time:) and otherwise publish
            // the old clock back to AVAudioPlaybackService. Compare it with the
            // synchronizer's live clock and discard only that stale event.
            let live = self.synchronizer.currentTime().seconds
            guard live.isFinite,
                  abs(live - time.seconds) <= 0.35 else { return }
            self.onProgress?(max(0, time.seconds))
        }
    }

    private func removeProgressObserver() {
        guard let progressObserver else { return }
        synchronizer.removeTimeObserver(progressObserver)
        self.progressObserver = nil
    }

    private func currentSynchronizerClockSeconds() -> Double {
        let seconds = synchronizer.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else {
            // During a Core Audio route handoff the synchronizer can briefly
            // report an invalid time. Keep the last committed/advancing anchor
            // so rebinding the output clock cannot turn a live route change
            // into an unintended seek to the beginning of the track.
            return max(0, max(explicitTimelineClock, lastAdvancingClock))
        }
        return seconds
    }

    /// Apply the synchronizer rate/anchor on the same serial queue that flushes
    /// and enqueues samples. AVSampleBufferRenderSynchronizer is thread-safe;
    /// keeping the operation on this queue makes a seek one ordered transaction
    /// instead of posting an anchor to main.async behind a stale route callback.
    private func setSynchronizerRateSynchronously(_ rate: Float, time: CMTime) {
        synchronizerAnchorMutationCount += 1
        synchronizer.setRate(rate, time: time)
    }

    private func startStatusPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pipelineQueue)
        timer.schedule(
            deadline: .now() + Self.statusPollInterval,
            repeating: Self.statusPollInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.isLoaded,
                  self.timelineGenerationGate.isCurrent(self.timelineGeneration) else { return }
            if self.renderer.status == .failed {
                self.recoverFailedRenderer()
            }
        }
        timer.resume()
        statusTimer = timer
    }

    private func finishWithFailure(
        _ error: RendererPipelineError,
        segmentID: UUID?
    ) {
        guard activeLoadSegmentID != nil,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return }
        let scopedSegmentID = segmentID ?? activeSegmentID(
            atTimelineClock: currentSynchronizerClockSeconds()
        ) ?? activeLoadSegmentID
        let failedDSPFormat = currentDSPFormat ?? dspProcessor?.format
        let failedDSPRequest = latestAcceptedDSPRequest ?? effectiveDSPRequest
        let failureGeneration = timelineGenerationGate.advance()
        timelineGeneration = failureGeneration
        isLoaded = false
        isPlaybackActive = false
        outputGainController.reset(playing: false)
        activeLoadSegmentID = nil
        pendingAutoFlushResync = false
        timelineMutationInProgress = false
        invalidateStallRecovery()
        stopFeedTimer()
        removeRendererObservers()
        removeProgressObserver()
        analysisQueue.removeAll(keepingCapacity: false)
        pendingDecodedPCM = nil
        dspLedger.removeAll(keepingCapacity: false)
        dspOutputBoundaries.removeAll(keepingCapacity: false)
        lastAudibleDSPFormat = nil
        pendingAudibleDSPEvent = nil
        activeDSPTransaction = nil
        dspPreparationID = nil
        preparingDSPRequest = nil
        dspHorizonTransition = nil
        queuedDSPApply = nil
        segments.removeAll(keepingCapacity: false)
        decodeIndex = nil
        enqueueToken = UUID()
        let clock = currentSynchronizerClockSeconds()
        setSynchronizerRateSynchronously(0, time: CMTime(seconds: clock, preferredTimescale: 600))
        renderer.flush()

        if let request = failedDSPRequest {
            emitDSPEvent(
                request,
                state: .failed,
                format: failedDSPFormat,
                scheduledPTS: nil,
                audiblePTS: nil,
                headroomDB: dspProcessor?.headroomDB,
                warnings: dspProcessor?.diagnostics ?? [],
                diagnostics: [DSPDiagnostic(
                    code: "rendererTimelineFailed",
                    message: "Playback failed before the DSP output became audible.",
                    retryable: true
                )]
            )
        }

        let generationGate = timelineGenerationGate
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  generationGate.isCurrent(failureGeneration) else { return }
            self.onFailure?(scopedSegmentID, error)
        }
    }

    private func activeSegmentID(atTimelineClock clock: Double) -> UUID? {
        let rendererTime = clock + analysisLeadSeconds
        if let segment = segments.first(where: {
            $0.descriptor.presentationStartSeconds <= rendererTime
                && $0.descriptor.presentationEndSeconds > rendererTime
        }) {
            return segment.descriptor.id
        }
        return segments.first(where: {
            $0.descriptor.presentationEndSeconds > rendererTime
        })?.descriptor.id ?? segments.last?.descriptor.id
    }

    private func recoverFailedRenderer(atTimelineClock requestedClock: Double? = nil) {
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return }
        let failedSegmentID = activeSegmentID(
            atTimelineClock: requestedClock ?? currentSynchronizerClockSeconds()
        ) ?? activeLoadSegmentID
        guard rendererFailureRecoveryBudget.beginRecoveryAttempt() else {
            finishWithFailure(
                .rendererFailed(underlying: renderer.error),
                segmentID: failedSegmentID
            )
            return
        }

        let clock = max(0, requestedClock ?? currentSynchronizerClockSeconds())
        let shouldResume = isPlaybackActive
        invalidateStallRecovery()
        stopFeedTimer()
        setSynchronizerRateSynchronously(0, time: CMTime(seconds: clock, preferredTimescale: 600))
        removeRendererObservers()
        synchronizer.removeRenderer(renderer, at: .positiveInfinity)
        renderer.flush()

        let replacement = AVSampleBufferAudioRenderer()
        renderer = replacement
        rendererGeneration = UUID()
        configureRenderer(replacement)
        synchronizer.addRenderer(replacement)
        configureSpatialization(replacement)
        installRendererObservers(for: replacement, timelineGeneration: timelineGeneration)
        analysisQueue.removeAll(keepingCapacity: true)

        guard recoverSources(atTimelineSeconds: clock) else { return }
        guard renderer.status != .failed else {
            finishWithFailure(
                .rendererFailed(underlying: renderer.error),
                segmentID: activeSegmentID(atTimelineClock: clock) ?? failedSegmentID
            )
            return
        }
        setSynchronizerRateSynchronously(
            shouldResume ? 1 : 0,
            time: CMTime(seconds: clock, preferredTimescale: 600)
        )
        isPlaybackActive = shouldResume
        resetStallBaseline(clock: clock)
        lastRecoveryWallTime = ProcessInfo.processInfo.systemUptime
        startFeedTimerIfNeeded()
        publishOutputDevice(audioOutputDeviceUniqueID)
    }

    var diagnosticStatus: AVQueuedSampleBufferRenderingStatus { renderer.status }
    var diagnosticError: Error? { renderer.error }

    static func currentDefaultOutputDescription() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return "unknown" }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &name
        ) == noErr else { return "device#\(deviceID)" }
        return name?.takeUnretainedValue() as String? ?? "device#\(deviceID)"
    }
}

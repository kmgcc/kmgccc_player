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
    nonisolated var totalFrames: AVAudioFramePosition { get }

    nonisolated func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM?
    nonisolated func seek(to position: AVAudioFramePosition) throws
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
    static let chunkFrames: AVAudioFrameCount = 8192
    // Visualizer analysis delivers fine-grained slices (≈23ms @ 44.1kHz)
    // so downstream FFT/LED calculations advance continuously without burstiness.
    static let analysisChunkFrames: Int = 1024

    nonisolated(unsafe) private(set) var renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    private let pipelineQueue = DispatchQueue(
        label: "kmg.myplayer2.renderer-pipeline",
        qos: .userInitiated
    )
    private let pipelineQueueKey = DispatchSpecificKey<Void>()

    private struct Segment {
        let descriptor: RendererSegmentDescriptor
        let source: RendererPCMProvider
        let formatDescription: CMAudioFormatDescription
        var didReportExhaustion = false
    }

    private struct AnalysisChunk {
        let presentationTime: Double
        let pcm: CanonicalPCM
    }

    private var segments: [Segment] = []
    private var decodeIndex: Int?
    private var nextPresentationTime: Double = 0
    private var enqueueToken = UUID()
    private var isLoaded = false
    private var isPlaybackActive = false
    private var activeLoadSegmentID: UUID?
    private var timelineGeneration = UUID()
    private let timelineGenerationGate = RendererTimelineGeneration()
    private var rendererFailureRecoveryBudget = RendererFailureRecoveryBudget()
    private var pendingAutoFlushResync = false
    /// Renderer PTS lead used for source re-seeks after a route/mode flush.
    /// This is intentionally separate from analysis delivery lead so the
    /// application-owned visualization lookahead remains explicit and stable.
    private var analysisLeadSeconds: Double = 0
    private var analysisDeliveryLeadSeconds: Double = 0
    private var analysisQueue: [AnalysisChunk] = []
    private var currentVolume: Float = 1
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
    var onEnqueue: (@Sendable (CanonicalPCM, Double) -> Void)?
    var onAnalysisPCM: (@Sendable (CanonicalPCM) -> Void)?
    var onSegmentExhausted: ((RendererSegmentDescriptor) -> Void)?
    var onFailure: ((_ segmentID: UUID?, _ error: RendererPipelineError) -> Void)?

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
        pipelineQueue.setSpecific(key: pipelineQueueKey, value: ())
        timelineGeneration = timelineGenerationGate.current()
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
        renderer.volume = currentVolume
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
            self.renderer.volume = volume
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

    /// Binds the renderer and its synchronizer to a Core Audio output device.
    ///
    /// AVSampleBufferAudioRenderer can change the synchronizer's source clock
    /// when this property changes. Serialize the change with enqueueing and
    /// perform it as one stop/flush/reprime transaction so a running AirPods
    /// route cannot leave the timebase paused or release an old queue after the
    /// new device has become active.
    func setAudioOutputDeviceUniqueID(_ uniqueID: String?) {
        pipelineQueue.async { [weak self] in
            guard let self, self.audioOutputDeviceUniqueID != uniqueID else { return }

            let oldUID = self.audioOutputDeviceUniqueID
            self.audioOutputDeviceUniqueID = uniqueID
            let clock = self.currentSynchronizerClockSeconds()
            let wasPlaying = self.isPlaybackActive
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

            Self.pipelineLog.info(
                "output device clock changed old=\(oldUID ?? "default", privacy: .public) new=\(uniqueID ?? "default", privacy: .public) anchor=\(clock, format: .fixed(precision: 3)) rate=\(wasPlaying ? 1 : 0)"
            )
        }
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
        autoplay: Bool = true
    ) {
        let requestedGeneration = timelineGenerationGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            guard self.timelineGenerationGate.isCurrent(requestedGeneration) else { return }
            self.timelineGeneration = requestedGeneration
            self.stopFeedTimer()
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
                self.segments = [segment]
                self.decodeIndex = clamped < source.totalFrames ? 0 : nil
                self.nextPresentationTime = presentationStartSeconds
                    + Double(clamped) / source.sourceSampleRate
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
        expectedLoadSegmentID: UUID? = nil
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
            guard let segment = makeSegment(
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
            segments.append(segment)
            if decodeIndex == nil {
                decodeIndex = segments.count - 1
                nextPresentationTime = segment.descriptor.presentationStartSeconds
            }
            enqueueToken = UUID()
            startFeedTimerIfNeeded()
            return segment.descriptor
        }
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
        guard source.sourceSampleRate > 0,
              source.sourceChannelCount > 0,
              let format = CMSampleBufferFactory.formatDescription(
                  channelCount: source.sourceChannelCount,
                  sampleRate: source.sourceSampleRate
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
            formatDescription: format
        )
    }

    // MARK: - Transport

    func play() {
        let expectedGeneration = timelineGenerationGate.current()
        pipelineQueue.async { [weak self] in
            guard let self,
                  self.isLoaded,
                  self.timelineGeneration == expectedGeneration,
                  self.timelineGenerationGate.isCurrent(expectedGeneration) else { return }
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
        }
    }

    func pause() {
        let expectedGeneration = timelineGenerationGate.current()
        pipelineQueue.async { [weak self] in
            guard let self,
                  self.timelineGeneration == expectedGeneration,
                  self.timelineGenerationGate.isCurrent(expectedGeneration) else { return }
            self.isPlaybackActive = false
            self.invalidateStallRecovery()
            let clock = self.currentSynchronizerClockSeconds()
            self.setSynchronizerRateSynchronously(
                0,
                time: CMTime(seconds: clock, preferredTimescale: 600)
            )
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        // This is called from the main-actor playback command path. Preserve
        // ordering with the following load() through the serial queue, but do
        // not make the UI wait for an in-flight decode or renderer flush.
        let stopGeneration = timelineGenerationGate.advance()
        pipelineQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            if self.timelineGenerationGate.isCurrent(stopGeneration) {
                self.timelineGeneration = stopGeneration
            }
            self.isLoaded = false
            self.isPlaybackActive = false
            self.activeLoadSegmentID = nil
            self.pendingAutoFlushResync = false
            self.invalidateStallRecovery()
            self.stopFeedTimer()
            self.removeRendererObservers()
            self.removeProgressObserver()
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: false)
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
        guard isLoaded, decodeIndex != nil, feedTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pipelineQueue)
        timer.schedule(deadline: .now(), repeating: Self.feedInterval)
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
        while count < max(0, maxChunks),
              renderer.isReadyForMoreMediaData,
              enqueueOneChunk() {
            count += 1
        }
    }

    private func provideMediaData() {
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else {
            stopFeedTimer()
            return
        }
        let clock = max(0, synchronizer.currentTime().seconds)
        guard nextPresentationTime - clock < Self.targetAheadSeconds else { return }
        guard renderer.isReadyForMoreMediaData else { return }

        var count = 0
        while count < 16,
              nextPresentationTime - clock < Self.targetAheadSeconds,
              renderer.isReadyForMoreMediaData,
              enqueueOneChunk() {
            count += 1
        }
    }

    @discardableResult
    private func enqueueOneChunk() -> Bool {
        guard timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
        while let index = decodeIndex, segments.indices.contains(index) {
            let token = enqueueToken
            let source = segments[index].source
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
                let ptsSeconds = nextPresentationTime
                let pts = CMSampleBufferFactory.time(
                    frames: Int64((ptsSeconds * source.sourceSampleRate).rounded()),
                    sampleRate: source.sourceSampleRate
                )
                guard let sampleBuffer = CMSampleBufferFactory.makeSampleBuffer(
                    from: pcm,
                    formatDescription: segments[index].formatDescription,
                    presentationTime: pts
                ) else {
                    finishWithFailure(
                        .unsupportedFormat(
                            channels: source.sourceChannelCount,
                            sampleRate: source.sourceSampleRate
                        ),
                        segmentID: segments[index].descriptor.id
                    )
                    return false
                }
                onEnqueue?(pcm, ptsSeconds)
                var sliceOffset = 0
                while sliceOffset < pcm.frames {
                    let sliceCount = min(Self.analysisChunkFrames, pcm.frames - sliceOffset)
                    let slicePTS = ptsSeconds + (Double(sliceOffset) / source.sourceSampleRate)
                    let slicePCM = pcm.slice(frameOffset: sliceOffset, frameCount: sliceCount)
                    analysisQueue.append(
                        AnalysisChunk(presentationTime: slicePTS, pcm: slicePCM)
                    )
                    sliceOffset += sliceCount
                }
                renderer.enqueue(sampleBuffer)
                nextPresentationTime += pcm.seconds
                return true
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
        stopFeedTimer()
        return false
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
            detectStall(clock: clock)
        }
        prunePlayedSegments(clock: clock)
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

    private func recoverSources(atTimelineSeconds clock: Double) -> Bool {
        stopFeedTimer()
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
        let descriptors = segments.map(\.descriptor)
        guard let index = RendererRecoveryTimeline.segmentIndex(
            in: descriptors,
            clockSeconds: clock,
            leadSeconds: analysisLeadSeconds
        ) else {
            decodeIndex = nil
            return true
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
                segments[candidate].didReportExhaustion = false
            }
        } catch {
            finishWithFailure(
                .sourceError(underlying: error),
                segmentID: segments.indices.contains(index) ? segments[index].descriptor.id : activeLoadSegmentID
            )
            return false
        }

        let selected = segments[index]
        // Segment descriptors are expressed on the renderer PTS timeline,
        // while the synchronizer clock is the logical media timeline. Keep the
        // configured output delay when rebuilding after an automatic flush or
        // a stall; anchoring the next PTS directly at `clock` would silently
        // remove the delay after the first route/mode recovery.
        decodeIndex = index
        nextPresentationTime = RendererRecoveryTimeline.nextPresentationTime(
            clockSeconds: clock,
            segmentStartSeconds: selected.descriptor.presentationStartSeconds,
            leadSeconds: analysisLeadSeconds
        )
        enqueueToken = UUID()
        primeOneBatch()
        guard isLoaded,
              timelineGenerationGate.isCurrent(timelineGeneration) else { return false }
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
        let failureGeneration = timelineGenerationGate.advance()
        timelineGeneration = failureGeneration
        isLoaded = false
        isPlaybackActive = false
        activeLoadSegmentID = nil
        pendingAutoFlushResync = false
        timelineMutationInProgress = false
        invalidateStallRecovery()
        stopFeedTimer()
        removeRendererObservers()
        removeProgressObserver()
        analysisQueue.removeAll(keepingCapacity: false)
        segments.removeAll(keepingCapacity: false)
        decodeIndex = nil
        enqueueToken = UUID()
        let clock = currentSynchronizerClockSeconds()
        setSynchronizerRateSynchronously(0, time: CMTime(seconds: clock, preferredTimescale: 600))
        renderer.flush()

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

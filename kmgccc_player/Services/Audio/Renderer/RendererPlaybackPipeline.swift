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

nonisolated struct RendererSegmentDescriptor: Sendable, Equatable {
    let id: UUID
    let presentationStartSeconds: Double
    let presentationEndSeconds: Double

    var duration: Double {
        max(0, presentationEndSeconds - presentationStartSeconds)
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

    var onProgress: ((Double) -> Void)?
    /// Called on the main queue after a load/seek has flushed the old timeline,
    /// primed the new samples, and committed the synchronizer's rate/anchor.
    /// The segment ID lets the owner discard a callback from an older seek.
    var onTimelineMutationCommitted: ((UUID, Double, Bool) -> Void)?
    var onSystemReconfigEvent: (() -> Void)?
    var onEnqueue: ((CanonicalPCM, Double) -> Void)?
    var onAnalysisPCM: ((CanonicalPCM) -> Void)?
    var onSegmentExhausted: ((RendererSegmentDescriptor) -> Void)?
    var onFailure: ((RendererPipelineError) -> Void)?

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
        configureRenderer(renderer)
        synchronizer.addRenderer(renderer)
        // Keep this ordering identical to the verified AVSampleBuffer demo:
        // spatialization eligibility is declared after the renderer is attached
        // to its synchronizer, but before the first sample is enqueued.
        configureSpatialization(renderer)
        if #available(macOS 11.3, *) {
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        }
        installRendererObservers(for: renderer)
        installProgressObserver()
        startAnalysisTimer()
        startStatusPolling()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    private func installRendererObservers(for renderer: AVSampleBufferAudioRenderer) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAutomaticFlush),
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAutomaticFlush),
            name: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer
        )
    }

    private func removeRendererObservers(for renderer: AVSampleBufferAudioRenderer) {
        NotificationCenter.default.removeObserver(
            self,
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer
        )
        NotificationCenter.default.removeObserver(
            self,
            name: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer
        )
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
            if uniqueID == nil, oldUID != nil {
                self.replaceRendererForDefaultOutput()
            } else if let uniqueID {
                self.renderer.audioOutputDeviceUniqueID = uniqueID
            }
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: true)
            self.recoverSources(atTimelineSeconds: clock, reanchorClock: false)
            self.setSynchronizerRateSynchronously(wasPlaying ? 1 : 0, time: anchor)
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
        removeRendererObservers(for: renderer)
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: .positiveInfinity)

        let replacement = AVSampleBufferAudioRenderer()
        renderer = replacement
        configureRenderer(replacement)
        synchronizer.addRenderer(replacement)
        configureSpatialization(replacement)
        installRendererObservers(for: replacement)
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
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.stopFeedTimer()
            let previousClock = self.currentSynchronizerClockSeconds()
            self.timelineMutationInProgress = true
            self.isLoaded = false
            self.isPlaybackActive = false
            self.explicitTimelineClock = max(0, clockTimeSeconds)
            self.lastExplicitTimelineMutationWallTime = ProcessInfo.processInfo.systemUptime

            // Stop the old timebase before flushing. The old implementation
            // left rate == 1 while replacing the source and only applied the
            // new anchor via main.async; on AirPods an output-configuration
            // notification could then recover the new provider from the old
            // clock. The synchronous main-queue transition makes this load an
            // atomic timeline replacement from the renderer's perspective.
            self.setSynchronizerRateSynchronously(
                0,
                time: CMTime(seconds: previousClock, preferredTimescale: 600)
            )
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
                self.isLoaded = false
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
                self.isLoaded = false
                self.reportFailure(.sourceError(underlying: error))
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

            let rate: Float = autoplay ? 1 : 0
            let clock = CMTime(seconds: max(0, clockTimeSeconds), preferredTimescale: 600)
            self.setSynchronizerRateSynchronously(rate, time: clock)
            self.lastExplicitTimelineMutationWallTime = ProcessInfo.processInfo.systemUptime
            self.timelineMutationInProgress = false
            self.startFeedTimerIfNeeded()
            let committedClock = max(0, clockTimeSeconds)
            DispatchQueue.main.async { [weak self] in
                self?.onTimelineMutationCommitted?(segmentID, committedClock, autoplay)
            }
        }
    }

    /// Queue a prepared next track on the same continuous renderer timeline.
    /// This call only mutates lightweight queue metadata and returns immediately;
    /// decoding remains on pipelineQueue.
    func append(source: RendererPCMProvider) -> RendererSegmentDescriptor? {
        pipelineQueue.sync {
            guard isLoaded else { return nil }
            let start = segments.last?.descriptor.presentationEndSeconds
                ?? max(0, synchronizer.currentTime().seconds)
            guard let segment = makeSegment(
                source: source,
                presentationStartSeconds: start,
                id: UUID()
            ) else { return nil }
            do {
                try source.seek(to: 0)
            } catch {
                reportFailure(.sourceError(underlying: error))
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
    func discardSegments(after segmentID: UUID) {
        pipelineQueue.async { [weak self] in
            guard let self,
                  let index = self.segments.firstIndex(where: { $0.descriptor.id == segmentID }),
                  index + 1 < self.segments.count else { return }
            self.segments.removeSubrange((index + 1)..<self.segments.count)
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: true)
            let clock = max(0, self.synchronizer.currentTime().seconds)
            self.recoverSources(atTimelineSeconds: clock, reanchorClock: false)
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
            reportFailure(
                .unsupportedFormat(
                    channels: source.sourceChannelCount,
                    sampleRate: source.sourceSampleRate
                )
            )
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
        pipelineQueue.async { [weak self] in
            guard let self, self.isLoaded else { return }
            self.isPlaybackActive = true
            if self.pendingAutoFlushResync {
                self.pendingAutoFlushResync = false
                let clock = max(0, self.synchronizer.currentTime().seconds)
                self.renderer.flush()
                self.analysisQueue.removeAll(keepingCapacity: true)
                self.recoverSources(atTimelineSeconds: clock, reanchorClock: false)
            }
            self.resetStallBaseline(clock: self.synchronizer.currentTime().seconds)
            DispatchQueue.main.async { [weak self] in
                self?.synchronizer.rate = 1
            }
            self.startFeedTimerIfNeeded()
        }
    }

    func pause() {
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.isPlaybackActive = false
            self.invalidateStallRecovery()
            DispatchQueue.main.async { [weak self] in
                self?.synchronizer.rate = 0
            }
        }
    }

    func stop() {
        // This is called from the main-actor playback command path. Preserve
        // ordering with the following load() through the serial queue, but do
        // not make the UI wait for an in-flight decode or renderer flush.
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.isLoaded = false
            self.isPlaybackActive = false
            self.pendingAutoFlushResync = false
            self.invalidateStallRecovery()
            self.stopFeedTimer()
            self.renderer.flush()
            self.analysisQueue.removeAll(keepingCapacity: false)
            self.segments.removeAll(keepingCapacity: false)
            self.decodeIndex = nil
            self.nextPresentationTime = 0
            // Keep the reset on the same serial queue as flush/load. Posting
            // this back to main can let a stale stop overwrite the next
            // track's freshly committed synchronizer anchor.
            self.synchronizer.setRate(0, time: .zero)
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
        guard isLoaded else {
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
                guard token == enqueueToken else { return false }
                let ptsSeconds = nextPresentationTime
                onEnqueue?(pcm, ptsSeconds)
                let pts = CMSampleBufferFactory.time(
                    frames: Int64((ptsSeconds * source.sourceSampleRate).rounded()),
                    sampleRate: source.sourceSampleRate
                )
                guard let sampleBuffer = CMSampleBufferFactory.makeSampleBuffer(
                    from: pcm,
                    formatDescription: segments[index].formatDescription,
                    presentationTime: pts
                ) else {
                    reportFailure(
                        .unsupportedFormat(
                            channels: source.sourceChannelCount,
                            sampleRate: source.sourceSampleRate
                        )
                    )
                    return false
                }
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
                reportFailure(.sourceError(underlying: error))
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
        DispatchQueue.main.async { [weak self] in
            self?.onSegmentExhausted?(descriptor)
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
        guard isLoaded else { return }
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
        Self.pipelineLog.warning(
            "renderer clock stalled at \(clock, format: .fixed(precision: 3))s; scheduling recovery"
        )
        pipelineQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            defer { self.stallRecoveryScheduled = false }
            guard self.stallRecoveryToken == token,
                  self.isPlaybackActive,
                  self.synchronizer.currentTime().seconds <= baselineClock + 0.2,
                  ProcessInfo.processInfo.systemUptime - self.lastSystemChangeWallTime
                    > Self.rebuildSuppressionInterval else { return }
            self.rebuildRendererAndResume(at: max(0, baselineClock))
        }
    }

    // MARK: - System flush and recovery

    @objc private func handleAutomaticFlush(_ notification: Notification) {
        let flushTime = (
            notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue
        )?.timeValue ?? .invalid
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lastSystemChangeWallTime = now
            self.resetStallBaseline(clock: self.synchronizer.currentTime().seconds)
            DispatchQueue.main.async { [weak self] in
                self?.onSystemReconfigEvent?()
            }

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
            let clock = max(0, self.synchronizer.currentTime().seconds)
            self.recoverSources(atTimelineSeconds: clock, reanchorClock: false)
        }
    }

    private func recoverSources(atTimelineSeconds clock: Double, reanchorClock: Bool) {
        stopFeedTimer()
        guard let index = segments.firstIndex(where: {
            $0.descriptor.presentationEndSeconds > clock + 0.000_001
        }) else {
            decodeIndex = nil
            return
        }

        do {
            for candidate in index..<segments.count {
                let segment = segments[candidate]
                let logicalStart = segment.descriptor.presentationStartSeconds - analysisLeadSeconds
                let relativeSeconds = candidate == index
                    ? max(0, clock - logicalStart)
                    : 0
                let frame = AVAudioFramePosition(
                    (relativeSeconds * segment.source.sourceSampleRate).rounded(.down)
                )
                try segment.source.seek(to: frame)
                segments[candidate].didReportExhaustion = false
            }
        } catch {
            reportFailure(.sourceError(underlying: error))
            return
        }

        let selected = segments[index]
        // Segment descriptors are expressed on the renderer PTS timeline,
        // while the synchronizer clock is the logical media timeline. Keep the
        // configured output delay when rebuilding after an automatic flush or
        // a stall; anchoring the next PTS directly at `clock` would silently
        // remove the delay after the first route/mode recovery.
        decodeIndex = index
        nextPresentationTime = max(
            selected.descriptor.presentationStartSeconds,
            clock + analysisLeadSeconds
        )
        enqueueToken = UUID()
        primeOneBatch()
        startFeedTimerIfNeeded()

        if reanchorClock {
            let time = CMTime(seconds: clock, preferredTimescale: 600)
            let rate: Float = isPlaybackActive ? 1 : 0
            DispatchQueue.main.async { [weak self] in
                self?.synchronizer.setRate(rate, time: time)
            }
        }
    }

    private func rebuildRendererAndResume(at clock: Double) {
        guard isLoaded else { return }
        Self.pipelineLog.warning(
            "stall recovery: replacing renderer at \(clock, format: .fixed(precision: 3))s"
        )
        stopFeedTimer()
        removeRendererObservers(for: renderer)
        synchronizer.removeRenderer(renderer, at: .positiveInfinity)

        let replacement = AVSampleBufferAudioRenderer()
        configureRenderer(replacement)
        renderer = replacement
        synchronizer.addRenderer(replacement)
        configureSpatialization(replacement)
        installRendererObservers(for: replacement)
        analysisQueue.removeAll(keepingCapacity: true)
        recoverSources(atTimelineSeconds: clock, reanchorClock: true)
        resetStallBaseline(clock: clock)
    }

    // MARK: - Progress and diagnostics

    private func installProgressObserver() {
        progressObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            guard let self,
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
            guard let self, self.isLoaded else { return }
            if self.renderer.status == .failed {
                self.isPlaybackActive = false
                self.stopFeedTimer()
                self.reportFailure(.rendererFailed(underlying: self.renderer.error))
            }
        }
        timer.resume()
        statusTimer = timer
    }

    private func reportFailure(_ error: RendererPipelineError) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(error)
        }
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

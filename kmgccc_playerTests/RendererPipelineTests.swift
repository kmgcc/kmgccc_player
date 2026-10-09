import AVFoundation
import CoreMedia
import XCTest
@testable import kmgccc_player

final class RendererSampleBufferTests: XCTestCase {
    func testStereoFormatCarriesExplicitSourceLayoutTag() throws {
        let sourceLayout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)
        )
        let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: sourceLayout
        )
        let dspFormat = CMSampleBufferFactory.dspAudioFormat(from: source)
        XCTAssertTrue(dspFormat.layoutIsKnown)
        XCTAssertEqual(dspFormat.channelLabels, [
            UInt32(kAudioChannelLabel_Left),
            UInt32(kAudioChannelLabel_Right),
        ])
        let description = try XCTUnwrap(
            CMSampleBufferFactory.formatDescription(sourceFormat: dspFormat)
        )
        var layoutSize = 0
        let layout = try XCTUnwrap(
            CMAudioFormatDescriptionGetChannelLayout(
                description,
                sizeOut: &layoutSize
            )
        )
        let layoutHeaderSize = MemoryLayout<AudioChannelLayout>.size
            - MemoryLayout<AudioChannelDescription>.size
        XCTAssertGreaterThanOrEqual(layoutSize, layoutHeaderSize)
        XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_Stereo)
        XCTAssertEqual(layout.pointee.mNumberChannelDescriptions, 0)
    }

    func testChannelCountAloneDoesNotInferMultichannelLayout() throws {
        let description = try XCTUnwrap(
            CMSampleBufferFactory.formatDescription(channelCount: 6, sampleRate: 48_000)
        )
        var layoutSize = 0
        XCTAssertNil(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize))
        XCTAssertEqual(layoutSize, 0)
    }

    func testSampleBufferUsesSamplePrecisePTSAndPerFrameSize() throws {
        let sampleRate = 44_100.0
        let description = try XCTUnwrap(
            CMSampleBufferFactory.formatDescription(
                channelCount: 2,
                sampleRate: sampleRate
            )
        )
        let pcm = CanonicalPCM(
            frames: 4_410,
            channelCount: 2,
            sampleRate: sampleRate,
            data: [Float](repeating: 0.25, count: 8_820)
        )
        let presentationTime = CMSampleBufferFactory.time(
            frames: 4_410,
            sampleRate: sampleRate
        )
        let buffer = try XCTUnwrap(
            CMSampleBufferFactory.makeSampleBuffer(
                from: pcm,
                formatDescription: description,
                presentationTime: presentationTime
            )
        )

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer).seconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetDuration(buffer).seconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 4_410)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(buffer), 4_410 * 2 * 4)
    }

    func testCanonicalPCMSlice() {
        let pcm = CanonicalPCM(
            frames: 2048,
            channelCount: 2,
            sampleRate: 44_100,
            data: (0..<4096).map { Float($0) }
        )
        let slice = pcm.slice(frameOffset: 512, frameCount: 1024)
        XCTAssertEqual(slice.frames, 1024)
        XCTAssertEqual(slice.channelCount, 2)
        XCTAssertEqual(slice.sampleRate, 44_100)
        XCTAssertEqual(slice.data.count, 2048)
        XCTAssertEqual(slice.data.first, 1024)
        XCTAssertEqual(slice.data.last, 3071)

        // Clamped at tail
        let tailSlice = pcm.slice(frameOffset: 1536, frameCount: 1024)
        XCTAssertEqual(tailSlice.frames, 512)
        XCTAssertEqual(tailSlice.data.count, 1024)

        // Out of bounds
        let emptySlice = pcm.slice(frameOffset: 3000, frameCount: 512)
        XCTAssertEqual(emptySlice.frames, 0)
        XCTAssertTrue(emptySlice.data.isEmpty)
    }
}

final class RendererTimelineTests: XCTestCase {
    func testLoadSeekFailureIsScopedAndDoesNotCommitOrEnqueue() {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let failureReported = expectation(description: "source seek failure is reported")
        let timelineCommitted = expectation(description: "failed load does not commit")
        timelineCommitted.isInverted = true
        let pcmEnqueued = expectation(description: "failed load does not enqueue")
        pcmEnqueued.isInverted = true
        let stopCompleted = expectation(description: "stop completes after terminal cleanup")
        let requestedSegmentID = UUID()

        pipeline.onFailure = { segmentID, error in
            XCTAssertEqual(segmentID, requestedSegmentID)
            guard case .sourceError = error else {
                XCTFail("expected a terminal source error")
                return
            }
            failureReported.fulfill()
        }
        pipeline.onTimelineMutationCommitted = { _, _, _ in
            timelineCommitted.fulfill()
        }
        pipeline.onEnqueue = { _, _ in
            pcmEnqueued.fulfill()
        }

        pipeline.load(
            source: ThrowingSeekRendererPCMProvider(),
            segmentID: requestedSegmentID,
            autoplay: true
        )
        wait(for: [failureReported], timeout: 2)
        pipeline.stop {
            stopCompleted.fulfill()
        }
        wait(for: [stopCompleted], timeout: 2)
        wait(for: [timelineCommitted, pcmEnqueued], timeout: 0.1)
    }

    func testStopCompletionRunsAfterPipelineReleasesLoadedProvider() {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let timelineCommitted = expectation(description: "empty source load commits without renderer output")
        let stopCompleted = expectation(description: "stop completion is a source-release barrier")
        var provider: MemoryRendererPCMProvider? = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 0,
            marker: 0
        )
        let weakProvider = WeakMemoryRendererProvider(provider!)

        pipeline.onTimelineMutationCommitted = { _, _, _ in
            timelineCommitted.fulfill()
        }
        pipeline.load(source: provider!, autoplay: false)
        provider = nil

        wait(for: [timelineCommitted], timeout: 2)
        XCTAssertNotNil(weakProvider.value)
        pipeline.stop {
            XCTAssertNil(weakProvider.value)
            stopCompleted.fulfill()
        }
        wait(for: [stopCompleted], timeout: 2)
    }

    func testAppendCreatesContinuousTimelineAcrossSampleRatesWithOutputDelay() throws {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let first = MemoryRendererPCMProvider(
            sampleRate: 44_100,
            channels: 2,
            frames: 44_100,
            marker: 0.1
        )
        let second = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 24_000,
            marker: 0.2
        )
        pipeline.load(
            source: first,
            presentationStartSeconds: 0.18,
            clockTimeSeconds: 0,
            autoplay: false
        )
        let secondDescriptor = try XCTUnwrap(pipeline.append(source: second))
        XCTAssertEqual(secondDescriptor.presentationStartSeconds, 1.18, accuracy: 0.000_001)
        XCTAssertEqual(secondDescriptor.presentationEndSeconds, 1.68, accuracy: 0.000_001)
        pipeline.stop()
    }

    func testNonZeroClockLoadAnchorsPTSAfterOutputDelay() throws {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let first = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 31 * 48_000,
            marker: 0.3
        )
        let second = MemoryRendererPCMProvider(
            sampleRate: 44_100,
            channels: 2,
            frames: 44_100,
            marker: 0.4
        )

        let enqueueState = EnqueueState()
        pipeline.onEnqueue = { _, pts in
            enqueueState.append(pts)
        }
        pipeline.load(
            source: first,
            sourcePosition: 30 * 48_000,
            presentationStartSeconds: 0.18,
            clockTimeSeconds: 30,
            autoplay: false
        )
        let secondDescriptor = try XCTUnwrap(pipeline.append(source: second))

        XCTAssertEqual(enqueueState.values.first ?? .nan, 30.18, accuracy: 0.000_001)
        XCTAssertEqual(secondDescriptor.presentationStartSeconds, 31.18, accuracy: 0.000_001)
        XCTAssertEqual(secondDescriptor.presentationEndSeconds, 32.18, accuracy: 0.000_001)
        pipeline.stop()
    }

    func testAnalysisChunkGranularity() throws {
        XCTAssertEqual(RendererPlaybackPipeline.analysisChunkFrames, 1024)
        XCTAssertEqual(RendererPlaybackPipeline.chunkFrames, 8192)
        XCTAssertEqual(RendererPlaybackPipeline.enqueueBlockFrames, 2048)
    }

    func testDecodedChunkIsSplitAndShortTailIsEnqueued() {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let provider = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 2 * AVAudioFramePosition(RendererPlaybackPipeline.enqueueBlockFrames) + 17,
            marker: 0.25
        )
        let state = EnqueuedFrameState()
        let allFramesEnqueued = expectation(description: "both full blocks and the short tail are queued")
        allFramesEnqueued.expectedFulfillmentCount = 3
        pipeline.onEnqueue = { pcm, _ in
            state.append(pcm.frames)
            allFramesEnqueued.fulfill()
        }
        pipeline.load(source: provider, autoplay: false)

        wait(for: [allFramesEnqueued], timeout: 2)
        XCTAssertEqual(state.values, [2048, 2048, 17])
        pipeline.stop()
    }

    func testDisabledDSPHistoryStaysBoundedDuringLongPlayback() {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let provider = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 15 * 48_000,
            marker: 0.125
        )
        let passedEightSeconds = expectation(description: "renderer has continued feeding past eight seconds")
        let gate = OneShotGate()
        pipeline.onEnqueue = { _, pts in
            if pts >= 8, gate.claim() { passedEightSeconds.fulfill() }
        }
        pipeline.load(source: provider, autoplay: true)

        wait(for: [passedEightSeconds], timeout: 12)
        XCTAssertLessThan(pipeline.dspOutputBoundaryCountForTesting, 160)
        pipeline.stop()
    }

    func testDSPApplyAfterRepeatedRecoveryInsideAnOutputBlock() {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        defer { pipeline.stop() }
        let provider = MemoryRendererPCMProvider(
            sampleRate: 44_100, channels: 2, frames: 3 * 44_100, marker: 0.125
        )
        let primed = expectation(description: "original output is queued")
        let gate = OneShotGate()
        pipeline.onEnqueue = { _, pts in
            if pts > 0.5, gate.claim() { primed.fulfill() }
        }
        pipeline.load(source: provider, autoplay: false)
        wait(for: [primed], timeout: 2)

        // An anchor inside a 2048-frame buffer must discard the old overlap,
        // including when the same source frames are replayed more than once.
        let clock = 0.081
        XCTAssertTrue(pipeline.recoverSourcesForTesting(atTimelineSeconds: clock))
        XCTAssertTrue(pipeline.recoverSourcesForTesting(atTimelineSeconds: clock))
        XCTAssertTrue(pipeline.dspOutputHistoryIsNonoverlappingForTesting)

        let scheduled = expectation(description: "DSP replacement after recovery is scheduled")
        let requestID = UUID()
        let scheduleGate = OneShotGate()
        pipeline.onDSPApplyEvent = { event in
            if event.requestID == requestID, event.state == .scheduled, scheduleGate.claim() {
                scheduled.fulfill()
            }
            if event.requestID == requestID, event.state == .failed {
                XCTFail("DSP replacement failed: \(event.diagnostics)")
            }
        }
        pipeline.applyDSP(
            AudioDSPConfiguration(
                enabled: true, inputTrimDB: -3,
                headroom: DSPHeadroomConfiguration(mode: .off)
            ),
            revision: "recovered-output-test", requestID: requestID
        )
        wait(for: [scheduled], timeout: 3)
        XCTAssertTrue(pipeline.dspOutputHistoryIsNonoverlappingForTesting)
    }

    func testDSPApplyReplaysQueuedBlocksAcrossGaplessSegmentBoundary() throws {
        let pipeline = RendererPlaybackPipeline()
        pipeline.setVolume(0)
        let first = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 33_600,
            marker: 0.1
        )
        let second = MemoryRendererPCMProvider(
            sampleRate: 48_000,
            channels: 2,
            frames: 96_000,
            marker: 0.2
        )
        let hasQueuedPastBoundary = expectation(description: "output is queued from the second segment")
        let didScheduleDSP = expectation(description: "cross-segment DSP replacement is scheduled")
        let requestID = UUID()
        let queueExpectationGate = OneShotGate()
        pipeline.onEnqueue = { _, pts in
            if pts >= 0.8, queueExpectationGate.claim() { hasQueuedPastBoundary.fulfill() }
        }
        pipeline.onDSPApplyEvent = { event in
            if event.requestID == requestID, event.state == .scheduled {
                didScheduleDSP.fulfill()
            }
        }
        pipeline.load(source: first, autoplay: false)
        _ = try XCTUnwrap(pipeline.append(source: second))
        wait(for: [hasQueuedPastBoundary], timeout: 2)

        var bands = DSPParametricEQBand.defaultBands
        bands[4] = DSPParametricEQBand(
            enabled: true,
            type: .bell,
            frequencyHz: 1_000,
            gainDB: 3
        )
        var node = DSPNodeConfiguration.parametricEQ(bands: bands)
        node.channelPolicy = "allChannels"
        pipeline.applyDSP(
            AudioDSPConfiguration(
                enabled: true,
                headroom: DSPHeadroomConfiguration(mode: .off),
                nodes: [node]
            ),
            revision: "gapless-replay-test",
            requestID: requestID
        )
        wait(for: [didScheduleDSP], timeout: 3)
        pipeline.stop()
    }

    func testRendererRecoveryUsesLogicalSegmentBoundaryWithOutputLead() {
        let outgoing = RendererSegmentDescriptor(
            id: UUID(),
            presentationStartSeconds: 0.18,
            presentationEndSeconds: 10.18
        )
        let incoming = RendererSegmentDescriptor(
            id: UUID(),
            presentationStartSeconds: 10.18,
            presentationEndSeconds: 20.18
        )

        XCTAssertEqual(
            RendererRecoveryTimeline.segmentIndex(
                in: [outgoing, incoming],
                clockSeconds: 9.99,
                leadSeconds: 0.18
            ),
            0
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.segmentIndex(
                in: [outgoing, incoming],
                clockSeconds: 10.10,
                leadSeconds: 0.18
            ),
            1
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.sourceFrame(
                clockSeconds: 10.10,
                segmentStartSeconds: incoming.presentationStartSeconds,
                leadSeconds: 0.18,
                sampleRate: 48_000,
                totalFrames: 480_000
            ),
            4_800
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.nextPresentationTime(
                clockSeconds: 10.10,
                segmentStartSeconds: incoming.presentationStartSeconds,
                leadSeconds: 0.18
            ),
            10.28,
            accuracy: 0.000_001
        )
    }

    func testRendererFailureRecoveryBudgetResetsOnlyAfterRenderingClockAdvances() {
        var budget = RendererFailureRecoveryBudget()

        XCTAssertTrue(budget.beginRecoveryAttempt())
        XCTAssertFalse(budget.beginRecoveryAttempt())
        XCTAssertFalse(
            budget.observeClock(previous: 1, current: 1.10, rendererIsRendering: false)
        )
        XCTAssertFalse(budget.beginRecoveryAttempt())
        XCTAssertFalse(
            budget.observeClock(previous: 1, current: 1.04, rendererIsRendering: true)
        )
        XCTAssertTrue(
            budget.observeClock(previous: 1, current: 1.06, rendererIsRendering: true)
        )
        XCTAssertTrue(budget.beginRecoveryAttempt())
    }

    func testTimelineGenerationInvalidatesQueuedCallbacksAfterStopOrNewLoad() {
        let gate = RendererTimelineGeneration()
        let oldLoad = gate.current()

        let stopped = gate.advance()
        XCTAssertFalse(gate.isCurrent(oldLoad))
        XCTAssertTrue(gate.isCurrent(stopped))

        let nextLoad = gate.advance()
        XCTAssertFalse(gate.isCurrent(stopped))
        XCTAssertTrue(gate.isCurrent(nextLoad))
    }
}

private final class EnqueueState: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return points
    }

    func append(_ value: Double) {
        lock.lock()
        points.append(value)
        lock.unlock()
    }
}

private final class EnqueuedFrameState: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCounts: [Int] = []

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return frameCounts
    }

    func append(_ count: Int) {
        lock.lock()
        frameCounts.append(count)
        lock.unlock()
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var wasClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !wasClaimed else { return false }
        wasClaimed = true
        return true
    }
}

private enum RendererProviderTestError: Error {
    case seek
}

private nonisolated final class ThrowingSeekRendererPCMProvider: RendererPCMProvider, @unchecked Sendable {
    let sourceSampleRate = 48_000.0
    let sourceChannelCount = 2
    let totalFrames: AVAudioFramePosition = 48_000

    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        XCTFail("a provider that fails positioning must not be decoded")
        return nil
    }

    func seek(to position: AVAudioFramePosition) throws {
        throw RendererProviderTestError.seek
    }
}

private nonisolated final class WeakMemoryRendererProvider: @unchecked Sendable {
    weak var value: MemoryRendererPCMProvider?

    init(_ value: MemoryRendererPCMProvider) {
        self.value = value
    }
}

private nonisolated final class MemoryRendererPCMProvider: RendererPCMProvider, @unchecked Sendable {
    let sourceSampleRate: Double
    let sourceChannelCount: Int
    let totalFrames: AVAudioFramePosition
    private let marker: Float
    private var position: AVAudioFramePosition = 0

    init(
        sampleRate: Double,
        channels: Int,
        frames: AVAudioFramePosition,
        marker: Float
    ) {
        sourceSampleRate = sampleRate
        sourceChannelCount = channels
        totalFrames = frames
        self.marker = marker
    }

    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        guard position < totalFrames else { return nil }
        let count = AVAudioFrameCount(
            min(AVAudioFramePosition(maxFrames), totalFrames - position)
        )
        position += AVAudioFramePosition(count)
        return CanonicalPCM(
            frames: Int(count),
            channelCount: sourceChannelCount,
            sampleRate: sourceSampleRate,
            data: [Float](
                repeating: marker,
                count: Int(count) * sourceChannelCount
            )
        )
    }

    func seek(to position: AVAudioFramePosition) throws {
        self.position = max(0, min(position, totalFrames))
    }
}

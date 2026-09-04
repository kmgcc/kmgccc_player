import AVFoundation
import CoreMedia
import XCTest

final class RendererSampleBufferTests: XCTestCase {
    func testStereoFormatCarriesVerifiedStandardLayoutTag() throws {
        let description = try XCTUnwrap(
            CMSampleBufferFactory.formatDescription(
                channelCount: 2,
                sampleRate: 48_000
            )
        )
        var layoutSize = 0
        let layout = try XCTUnwrap(
            CMAudioFormatDescriptionGetChannelLayout(
                description,
                sizeOut: &layoutSize
            )
        )
        XCTAssertGreaterThanOrEqual(layoutSize, MemoryLayout<AudioChannelLayout>.size)
        XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_Stereo)
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
    func testAppendCreatesContinuousTimelineAcrossSampleRatesWithOutputDelay() throws {
        let pipeline = RendererPlaybackPipeline()
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

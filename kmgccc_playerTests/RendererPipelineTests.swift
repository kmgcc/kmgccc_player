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

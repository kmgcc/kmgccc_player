import AVFoundation
import Foundation
import XCTest
@testable import kmgccc_player

final class RendererDSPLookaheadTests: XCTestCase {
    private let mono = DSPAudioFormat(sampleRate: 48_000, channelCount: 1,
        rawLayoutData: nil, channelLabels: [UInt32(kAudioChannelLabel_Mono)], layoutIsKnown: true)

    func testContinuousSegmentsKeepTheirFixedGainAndDecodeCursor() throws {
        let first = LookaheadPCMProvider(samples: [1, 2, 3, 4, 5])
        let second = LookaheadPCMProvider(samples: [6, 7, 8])
        try first.seek(to: 4)
        let ranges = [
            RendererDSPSourceRange(source: first, format: mono, presentationStartSeconds: 0,
                normalizationGain: 0.5, decodePosition: 4),
            RendererDSPSourceRange(source: second, format: mono, presentationStartSeconds: 5 / 48_000.0,
                normalizationGain: 2, decodePosition: 0)
        ]
        let future = try XCTUnwrap(RendererDSPLookahead.read(frameCount: 4, format: mono,
            segmentIndex: 0, sourceFrame: 3, segmentCount: ranges.count, segmentAt: { ranges[$0] }))
        XCTAssertEqual(future.data, [2, 2.5, 12, 14])
        XCTAssertEqual(first.position, 4)
        XCTAssertEqual(second.position, 0)
    }

    func testEOFAndFormatBoundaryDrainWithoutAddingSourceFrames() throws {
        let first = LookaheadPCMProvider(samples: [1, 2])
        let otherFormat = DSPAudioFormat(sampleRate: 96_000, channelCount: 1,
            rawLayoutData: nil, channelLabels: [UInt32(kAudioChannelLabel_Mono)], layoutIsKnown: true)
        let ranges = [
            RendererDSPSourceRange(source: first, format: mono, presentationStartSeconds: 0,
                normalizationGain: 1, decodePosition: 0),
            RendererDSPSourceRange(source: LookaheadPCMProvider(samples: [8]), format: otherFormat,
                presentationStartSeconds: 2 / 48_000.0, normalizationGain: 1, decodePosition: 0)
        ]
        let future = try XCTUnwrap(RendererDSPLookahead.read(frameCount: 4, format: mono,
            segmentIndex: 0, sourceFrame: 1, segmentCount: ranges.count, segmentAt: { ranges[$0] }))
        XCTAssertEqual(future.data, [2, 0, 0, 0])
        XCTAssertEqual(first.totalFrames, 2)
        XCTAssertEqual(first.position, 0)
    }

    func testTimeGapDoesNotPretendToBeGapless() throws {
        let ranges = [
            RendererDSPSourceRange(source: LookaheadPCMProvider(samples: [1]), format: mono,
                presentationStartSeconds: 0, normalizationGain: 1, decodePosition: 0),
            RendererDSPSourceRange(source: LookaheadPCMProvider(samples: [8]), format: mono,
                presentationStartSeconds: 1, normalizationGain: 1, decodePosition: 0)
        ]
        let future = try XCTUnwrap(RendererDSPLookahead.read(frameCount: 2, format: mono,
            segmentIndex: 0, sourceFrame: 1, segmentCount: ranges.count, segmentAt: { ranges[$0] }))
        XCTAssertEqual(future.data, [0, 0])
    }

    func testDecoderFailureIsNotReplacedBySilence() {
        let source = LookaheadPCMProvider(samples: [1], declaredFrames: 4)
        let range = RendererDSPSourceRange(source: source, format: mono,
            presentationStartSeconds: 0, normalizationGain: 1, decodePosition: 0)
        XCTAssertThrowsError(try RendererDSPLookahead.read(frameCount: 2, format: mono,
            segmentIndex: 0, sourceFrame: 1, segmentCount: 1, segmentAt: { _ in range }))
        XCTAssertEqual(source.position, 0)
    }

    func testAVFilePeekReusesPrefixAndRestoresRandomReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("frames.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 1, interleaved: false))
        let samples = (0..<512).map { Float($0) / 1024 }
        do {
            let output = try AVAudioFile(forWriting: url, settings: format.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            buffer.frameLength = 512
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in samples.indices { channel[index] = samples[index] }
            try output.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = AVFilePCMProvider(file: file)
        try source.seek(to: 0)
        source.setDSPReadAheadEnabled(true)
        XCTAssertEqual(try source.nextChunk(maxFrames: 128)?.data, Array(samples[0..<128]))
        let physicalCursor = file.framePosition
        XCTAssertEqual(try source.peekChunk(at: 64, maxFrames: 32, restoringTo: 128)?.data, Array(samples[64..<96]))
        XCTAssertEqual(file.framePosition, physicalCursor)
        XCTAssertEqual(try source.peekChunk(at: 128, maxFrames: 64, restoringTo: 128)?.data, Array(samples[128..<192]))
        XCTAssertEqual(try source.nextChunk(maxFrames: 128)?.data, Array(samples[128..<256]))
        let replayCursor = file.framePosition
        XCTAssertEqual(try source.peekChunk(at: 10, maxFrames: 16, restoringTo: 256)?.data, Array(samples[10..<26]))
        XCTAssertEqual(file.framePosition, replayCursor)
        XCTAssertEqual(try source.nextChunk(maxFrames: 64)?.data, Array(samples[256..<320]))
        try source.seek(to: 44)
        XCTAssertEqual(try source.nextChunk(maxFrames: 8)?.data, Array(samples[44..<52]))
    }
}

private nonisolated final class LookaheadPCMProvider: RendererPCMProvider, @unchecked Sendable {
    let samples: [Float]
    let totalFrames: AVAudioFramePosition
    private(set) var position: AVAudioFramePosition = 0
    var sourceChannelCount: Int { 1 }
    var sourceSampleRate: Double { 48_000 }

    init(samples: [Float], declaredFrames: Int? = nil) {
        self.samples = samples
        totalFrames = AVAudioFramePosition(declaredFrames ?? samples.count)
    }

    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        let offset = Int(position)
        guard offset < samples.count else { return nil }
        let count = min(Int(maxFrames), samples.count - offset)
        position += AVAudioFramePosition(count)
        return CanonicalPCM(frames: count, channelCount: 1, sampleRate: 48_000,
                            data: Array(samples[offset..<(offset + count)]))
    }

    func seek(to position: AVAudioFramePosition) throws { self.position = max(0, min(position, totalFrames)) }
}

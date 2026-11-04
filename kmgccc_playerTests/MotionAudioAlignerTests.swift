import XCTest
@testable import kmgccc_player

final class MotionAudioAlignerTests: XCTestCase {
    func testMusicVideoEligibilityMatchesPlaybackRule() {
        XCTAssertTrue(MotionAudioAligner.isMusicVideo(songDuration: 248, videoDuration: 265))
        XCTAssertFalse(MotionAudioAligner.isMusicVideo(songDuration: 248, videoDuration: 30))
        XCTAssertFalse(MotionAudioAligner.isMusicVideo(songDuration: 248, videoDuration: 320))
        XCTAssertFalse(MotionAudioAligner.isMusicVideo(songDuration: .nan, videoDuration: 200))
    }

    func testFindsKnownOffsetWithDifferentGain() throws {
        var state: UInt32 = 42
        let song: [Float] = (0..<16_000).map { _ in
            state = 1_664_525 &* state &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
        let delay = 3_000
        let video = [Float](repeating: 0, count: delay) + song.map { $0 * 0.5 } + [Float](repeating: 0, count: 2_000)
        let a = MotionAudioAligner.Samples(data: song, start: 10)
        let b = MotionAudioAligner.Samples(data: video, start: 10)
        let match = try XCTUnwrap(MotionAudioAligner.match(a, b))
        XCTAssertEqual(match.offset, Double(delay) / MotionAudioAligner.sampleRate, accuracy: 0.000_125)
        XCTAssertGreaterThan(match.score, 0.99)
    }

    func testSilenceDoesNotProduceMatch() {
        let silence = MotionAudioAligner.Samples(data: [Float](repeating: 0, count: 16_000), start: 0)
        XCTAssertNil(MotionAudioAligner.match(silence, silence))
    }
}

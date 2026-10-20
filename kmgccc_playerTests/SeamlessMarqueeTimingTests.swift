import QuartzCore
import XCTest
@testable import kmgccc_player

@MainActor
final class SeamlessMarqueeTimingTests: XCTestCase {
    func testBothTextInitializersUseTheSlowerRateAndReadablePause() {
        let styled = SeamlessMarqueeText(text: "Title", style: .body, fontWeight: .regular, color: .primary)
        let scaled = SeamlessMarqueeText(text: "Title", fontSize: 18)
        XCTAssertEqual(styled.speed, 24)
        XCTAssertEqual(scaled.speed, 24)
        XCTAssertEqual(styled.pauseDuration, 5)
        XCTAssertEqual(scaled.pauseDuration, 5)
    }

    func testTravelRateStaysConstantAcrossTitleLengthsAndRepeatsAtTheSeam() throws {
        for distance in [CGFloat(120), 240, 720] {
            let timing = SeamlessMarqueeTiming(distance: distance, speed: 24, pauseDuration: 5, fadeWidth: 12)
            let animation = timing.scrollAnimation()
            let offsets = try XCTUnwrap(animation.values as? [NSNumber]).map(\.doubleValue)
            let times = try XCTUnwrap(animation.keyTimes).map { $0.doubleValue * animation.duration }

            XCTAssertEqual(animation.keyPath, "transform.translation.x")
            XCTAssertEqual(offsets.count, 3)
            XCTAssertEqual(times.count, 3)
            guard offsets.count == 3, times.count == 3 else { return }
            XCTAssertEqual(offsets[0], 0)
            XCTAssertEqual(offsets[1], 0)
            XCTAssertEqual(times[1], 5, accuracy: 0.000001)
            XCTAssertEqual((offsets[2] - offsets[1]) / (times[2] - times[1]), -24, accuracy: 0.000001)
            // At the seam, copy 2's origin becomes copy 1's readable origin.
            XCTAssertEqual(offsets[2] + Double(distance), 0)
            XCTAssertTrue(animation.repeatCount.isInfinite)
            XCTAssertEqual(animation.calculationMode, .linear)
            let globalCurve = try XCTUnwrap(animation.timingFunction)
            let segmentCurves = try XCTUnwrap(animation.timingFunctions)
            XCTAssertEqual(segmentCurves.count, 2)
            for curve in [globalCurve] + segmentCurves {
                for (index, expected) in [(1, Float(0)), (2, Float(1))] {
                    var point = [Float](repeating: 0, count: 2)
                    point.withUnsafeMutableBufferPointer { buffer in
                        curve.getControlPoint(at: index, values: buffer.baseAddress!)
                    }
                    XCTAssertEqual(point, [expected, expected])
                }
            }
        }
    }

    func testLeadingEdgeIsClearThroughoutThePauseAndReturnsClearAtTheSeam() throws {
        let opaque = CGColor(gray: 1, alpha: 1)
        let clear = CGColor(gray: 1, alpha: 0)
        let rest = [opaque, opaque, opaque, clear]
        let moving = [clear, opaque, opaque, clear]
        let timing = SeamlessMarqueeTiming(distance: 240, speed: 24, pauseDuration: 5, fadeWidth: 12)
        let fade = timing.fadeAnimation(restingColors: rest, movingColors: moving)
        let colors = try XCTUnwrap(fade.values as? [[CGColor]])
        let times = try XCTUnwrap(fade.keyTimes).map { $0.doubleValue * fade.duration }

        XCTAssertEqual(colors.count, 5)
        XCTAssertEqual(times.count, 5)
        guard colors.count == 5, times.count == 5 else { return }
        XCTAssertEqual(times[1], 5, accuracy: 0.000001)
        XCTAssertEqual(times[2], 5.5, accuracy: 0.000001)
        XCTAssertEqual(times[3], 14.5, accuracy: 0.000001)
        XCTAssertEqual(times[4], 15, accuracy: 0.000001)
        XCTAssertEqual(colors.map { $0[0].alpha }, [1, 1, 0, 0, 1])
        XCTAssertEqual(colors.map { $0[3].alpha }, [0, 0, 0, 0, 0])
        XCTAssertEqual(fade.duration, timing.scrollAnimation().duration)
        XCTAssertTrue(fade.repeatCount.isInfinite)
    }

    func testZeroPauseStartsTravelImmediatelyWithOrderedKeyframes() throws {
        let timing = SeamlessMarqueeTiming(distance: 240, speed: 24, pauseDuration: 0, fadeWidth: 12)
        let scroll = timing.scrollAnimation()
        let times = try XCTUnwrap(scroll.keyTimes).map(\.doubleValue)
        XCTAssertEqual(times, [0, 1])
        XCTAssertEqual(scroll.duration, 10)
        let opaque = CGColor(gray: 1, alpha: 1)
        let clear = CGColor(gray: 1, alpha: 0)
        let fade = timing.fadeAnimation(
            restingColors: [opaque, opaque, opaque, clear],
            movingColors: [clear, opaque, opaque, clear]
        )
        let fadeTimes = try XCTUnwrap(fade.keyTimes).map(\.doubleValue)
        XCTAssertEqual(fadeTimes.count, 4)
        XCTAssertTrue(zip(fadeTimes, fadeTimes.dropFirst()).allSatisfy { $0.0 < $0.1 })
    }
}

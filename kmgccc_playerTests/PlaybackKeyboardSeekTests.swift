import XCTest
@testable import kmgccc_player

@MainActor
final class PlaybackKeyboardSeekTests: XCTestCase {
    func testRapidSameDirectionTapsAccelerateToThirtySeconds() {
        var acceleration = PlaybackSeekAcceleration()
        let times = stride(from: 0.0, through: 1.0, by: 0.2)
        let steps = times.map {
            acceleration.nextStep(direction: .forward, at: $0)
        }

        XCTAssertEqual(steps.map(\.seconds), [3, 6, 10, 15, 20, 30])
        XCTAssertFalse(steps[0].continuesFromPreviousTarget)
        XCTAssertTrue(steps.dropFirst().allSatisfy(\.continuesFromPreviousTarget))
    }

    func testDirectionChangeOrSlowTapRestartsAtThreeSeconds() {
        var acceleration = PlaybackSeekAcceleration()

        _ = acceleration.nextStep(direction: .forward, at: 10)
        let changedDirection = acceleration.nextStep(direction: .backward, at: 10.2)
        let slowTap = acceleration.nextStep(direction: .backward, at: 11)

        XCTAssertEqual(changedDirection.seconds, 3)
        XCTAssertFalse(changedDirection.continuesFromPreviousTarget)
        XCTAssertEqual(slowTap.seconds, 3)
        XCTAssertFalse(slowTap.continuesFromPreviousTarget)
    }
}

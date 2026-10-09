import Foundation
import XCTest
@testable import kmgccc_player

final class PlaybackOutputGainControllerTests: XCTestCase {
    func testPerceptualEnvelopeHasExactEndpointsAndMonotonicGain() {
        let rising = (0...100).map {
            PlaybackOutputGainController.envelopeGain(start: 0, target: 1, progress: Double($0) / 100, floorDB: -80)
        }
        XCTAssertEqual(rising.first, 0)
        XCTAssertEqual(rising.last, 1)
        XCTAssertTrue(zip(rising, rising.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
        XCTAssertEqual(rising[50], 0.01, accuracy: 1e-12)
        let falling = (0...100).map {
            PlaybackOutputGainController.envelopeGain(start: 1, target: 0, progress: Double($0) / 100, floorDB: -80)
        }
        XCTAssertTrue(zip(falling, falling.dropFirst()).allSatisfy { pair in pair.0 >= pair.1 })
        XCTAssertEqual(falling.last, 0)
    }

    func testReversalBeginsAtCurrentEnvelope() {
        let current = PlaybackOutputGainController.envelopeGain(start: 1, target: 0, progress: 0.4, floorDB: -80)
        XCTAssertEqual(PlaybackOutputGainController.envelopeGain(start: current, target: 1, progress: 0, floorDB: -80), current)
        XCTAssertEqual(PlaybackOutputGainController.envelopeGain(start: current, target: 1, progress: 1, floorDB: -80), 1)
    }

    func testFadeInWaitsForFirstAudioPTS() {
        let queue = DispatchQueue(label: "test.transport-envelope")
        let owner = PlaybackOutputGainController(queue: queue)
        let readiness = FadeTestReadiness()
        let waiting = expectation(description: "waiting for audio")
        let finished = expectation(description: "fade completed")
        queue.async {
            owner.reset(playing: false)
            owner.publish = { state in
                if state.phase == "waitingForAudio" { waiting.fulfill() }
            }
            owner.transition(playing: true,
                configuration: AudioFadeConfiguration(enabled: true, playFadeMs: 10),
                startWhen: { readiness.isReady }) { finished.fulfill() }
        }
        wait(for: [waiting], timeout: 1)
        XCTAssertEqual(queue.sync { owner.envelope }, 0)
        readiness.setReady()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(queue.sync { owner.envelope }, 1)
    }
}

private final class FadeTestReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
    func setReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }
}

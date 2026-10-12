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

    func testResumeInterruptsFadeOutWithoutCommittingOldPause() {
        assertReversal(fromPlaying: true)
    }

    func testPauseInterruptsFadeInWithoutCommittingOldPlay() {
        assertReversal(fromPlaying: false)
    }

    private func assertReversal(fromPlaying: Bool) {
        let queue = DispatchQueue(label: "test.transport-reversal")
        let owner = PlaybackOutputGainController(queue: queue)
        let superseded = expectation(description: "superseded transition cannot complete")
        superseded.isInverted = true
        let finished = expectation(description: "latest transition completes")
        queue.async {
            owner.reset(playing: fromPlaying)
            owner.writeGain = { gain in
                let reachedMidFade = fromPlaying ? gain < 0.5 : gain > 0.001
                guard reachedMidFade else { return }
                owner.writeGain = nil
                queue.async {
                    let current = owner.envelope
                    XCTAssertGreaterThan(current, 0)
                    XCTAssertLessThan(current, 1)
                    owner.transition(
                        playing: fromPlaying,
                        configuration: AudioFadeConfiguration(enabled: true)
                    ) { finished.fulfill() }
                    XCTAssertEqual(owner.envelope, current)
                    XCTAssertEqual(owner.desiredPlaying, fromPlaying)
                }
            }
            owner.transition(
                playing: !fromPlaying,
                configuration: AudioFadeConfiguration(enabled: true)
            ) { superseded.fulfill() }
            XCTAssertEqual(owner.desiredPlaying, !fromPlaying)
        }
        wait(for: [finished], timeout: 2)
        wait(for: [superseded], timeout: 0.15)
        XCTAssertEqual(queue.sync { owner.envelope }, fromPlaying ? 1 : 0)
    }

    func testSupersededCommandCannotStartWaitingFade() {
        let queue = DispatchQueue(label: "test.transport-command-generation")
        let owner = PlaybackOutputGainController(queue: queue)
        let commandGate = RendererTimelineGeneration()
        let command = commandGate.current()
        let readiness = FadeTestReadiness()
        let waiting = expectation(description: "waiting for audio")
        let superseded = expectation(description: "superseded command cannot complete")
        superseded.isInverted = true
        queue.async {
            owner.reset(playing: false)
            owner.publish = { state in
                if state.phase == "waitingForAudio" { waiting.fulfill() }
            }
            owner.transition(
                playing: true,
                configuration: AudioFadeConfiguration(enabled: true),
                isCurrent: { commandGate.isCurrent(command) },
                startWhen: { readiness.isReady }
            ) { superseded.fulfill() }
        }
        wait(for: [waiting], timeout: 1)
        _ = commandGate.advance()
        readiness.setReady()
        wait(for: [superseded], timeout: 0.1)
        XCTAssertEqual(queue.sync { owner.envelope }, 0)
    }

    func testRapidReversalsOnlyCompleteFinalPause() {
        let queue = DispatchQueue(label: "test.transport-rapid-reversal")
        let owner = PlaybackOutputGainController(queue: queue)
        let superseded = expectation(description: "intermediate commands cannot complete")
        superseded.isInverted = true
        let finished = expectation(description: "final pause completes")
        queue.async {
            owner.reset(playing: true, envelope: 0.25)
            let configuration = AudioFadeConfiguration(enabled: true)
            owner.transition(playing: false, configuration: configuration) { superseded.fulfill() }
            owner.transition(playing: true, configuration: configuration) { superseded.fulfill() }
            XCTAssertEqual(owner.envelope, 0.25)
            owner.transition(
                playing: false,
                configuration: AudioFadeConfiguration(enabled: true)
            ) { finished.fulfill() }
            XCTAssertFalse(owner.desiredPlaying)
        }
        wait(for: [finished], timeout: 2)
        wait(for: [superseded], timeout: 0.15)
        XCTAssertEqual(queue.sync { owner.envelope }, 0)
    }

    func testDisabledFadeCommitsLatestTransportImmediately() {
        let queue = DispatchQueue(label: "test.transport-no-fade")
        let owner = PlaybackOutputGainController(queue: queue)
        queue.sync {
            owner.reset(playing: true)
            owner.publish = { state in
                XCTAssertEqual(state.desiredTransport, state.actualPlaying ? "playing" : "paused")
                XCTAssertEqual(state.phase, "idle")
            }
            owner.transition(playing: false, configuration: AudioFadeConfiguration()) {}
            XCTAssertEqual(owner.envelope, 0)
            owner.transition(playing: true, configuration: AudioFadeConfiguration()) {}
            XCTAssertEqual(owner.envelope, 1)
            owner.transition(playing: false, configuration: AudioFadeConfiguration()) {}
            XCTAssertEqual(owner.envelope, 0)
        }
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
                configuration: AudioFadeConfiguration(enabled: true),
                startWhen: { readiness.isReady }) { finished.fulfill() }
        }
        wait(for: [waiting], timeout: 1)
        XCTAssertEqual(queue.sync { owner.envelope }, 0)
        readiness.setReady()
        wait(for: [finished], timeout: 2)
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

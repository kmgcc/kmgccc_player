#if DEBUG
import XCTest
@testable import kmgccc_player

final class SkinLifecycleCompletionTests: XCTestCase {
    @MainActor
    func testLocalFeedPauseKeepsLastFrameAndReleasesItsLeasesIdempotently() {
        let (feed, provider) = makeFeed()
        defer {
            feed.stop()
            provider.releaseNowPlayingResources()
        }

        let hubBaseline = AudioAnalysisHub.shared.skinDebugConsumerCount
        let providerBaseline = provider.skinDebugSessionCount
        let frame = makeAudioFrame(hostTime: 42)

        feed.update(provider: provider, source: .local, active: true, isPlaying: true)
        XCTAssertEqual(feed.availability, .localAudio)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline + 2)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline + 1)

        // Repeated active updates must not acquire duplicate Hub consumers or sessions.
        feed.update(provider: provider, source: .local, active: true, isPlaying: true)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline + 2)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline + 1)

        feed.receive(frame)
        XCTAssertEqual(feed.frame?.hostTime, frame.hostTime)

        feed.update(provider: provider, source: .local, active: true, isPlaying: false)
        XCTAssertEqual(feed.availability, .inactive)
        XCTAssertEqual(feed.frame?.hostTime, frame.hostTime)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline)

        // A repeated pause retains the frozen frame without reacquiring resources.
        feed.update(provider: provider, source: .local, active: true, isPlaying: false)
        XCTAssertEqual(feed.frame?.hostTime, frame.hostTime)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline)
    }

    @MainActor
    func testExternalSourceAndHiddenLocalFeedReleaseLeasesAndClearFrames() {
        let (feed, provider) = makeFeed()
        defer {
            feed.stop()
            provider.releaseNowPlayingResources()
        }

        let hubBaseline = AudioAnalysisHub.shared.skinDebugConsumerCount
        let providerBaseline = provider.skinDebugSessionCount
        let frame = makeAudioFrame(hostTime: 84)

        feed.update(provider: provider, source: .local, active: true, isPlaying: true)
        feed.receive(frame)
        feed.update(provider: provider, source: .appleMusic, active: true, isPlaying: true)
        XCTAssertEqual(feed.availability, .externalAudioUnavailable)
        XCTAssertNil(feed.frame)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline)

        // External playback remains unavailable while paused and never leases local analysis.
        feed.update(provider: provider, source: .appleMusic, active: true, isPlaying: false)
        XCTAssertEqual(feed.availability, .externalAudioUnavailable)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline)

        feed.update(provider: provider, source: .local, active: true, isPlaying: true)
        feed.receive(frame)
        feed.update(provider: provider, source: .local, active: false, isPlaying: true)
        XCTAssertEqual(feed.availability, .inactive)
        XCTAssertNil(feed.frame)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline)

        feed.update(provider: provider, source: .local, active: false, isPlaying: true)
        XCTAssertEqual(AudioAnalysisHub.shared.skinDebugConsumerCount, hubBaseline)
        XCTAssertEqual(provider.skinDebugSessionCount, providerBaseline)
    }

    @MainActor
    func testSkinSessionSameRevisionIsStableAndRetirementRunsCleanupOnce() {
        let session = SkinSession()
        session.activate("skin.lifecycle.test", revision: 7)
        let generation = session.generation
        var cleanupCount = 0
        let cleanupID = session.registerCleanup { cleanupCount += 1 }

        session.activate("skin.lifecycle.test", revision: 7)
        XCTAssertEqual(session.generation, generation)
        XCTAssertEqual(session.identity(for: "skin.lifecycle.test"), "skin.lifecycle.test_\(generation)")
        XCTAssertEqual(cleanupCount, 0)

        session.activate("skin.lifecycle.test", revision: 8)
        XCTAssertEqual(session.generation, generation + 1)
        XCTAssertEqual(cleanupCount, 1)
        session.removeCleanup(cleanupID)
        XCTAssertEqual(cleanupCount, 1)

        session.registerCleanup { cleanupCount += 1 }
        session.deactivate()
        XCTAssertEqual(cleanupCount, 2)
        session.deactivate()
        XCTAssertEqual(cleanupCount, 2)
    }

    func testRendererPCMFeedPublishesAnalysisFromItsOwnHub() {
        let hub = AudioAnalysisHub()
        hub.targetHz = 60
        let receivedRendererPCM = expectation(description: "renderer PCM reaches analysis consumer")
        let delivery = OneShotExpectation(receivedRendererPCM)
        let consumerID = hub.addConsumer { data in
            guard data.sampleRate == 48_000,
                  data.pcmSamples.contains(where: { abs($0) > 0.1 }) else { return }
            delivery.fulfillIfNeeded()
        }
        defer {
            hub.setPlaying(false)
            hub.disableRendererFeed()
            hub.removeConsumer(consumerID)
            hub.stop()
        }

        hub.start()
        hub.enableRendererFeed()
        let frameCount = 4_096
        hub.enqueueRendererPCM(
            CanonicalPCM(
                frames: frameCount,
                channelCount: 2,
                sampleRate: 48_000,
                data: [Float](repeating: 0.2, count: frameCount * 2)
            )
        )
        hub.setPlaying(true)

        wait(for: [receivedRendererPCM], timeout: 2)
    }

    func testRendererSourceSpectrumIsIndependentOfMasterVolume() {
        func render(volume: Float) -> [[Float]] {
            let processor = SpectrumProcessor()
            return (0..<60).map { frame in
                let rms: Float = frame < 30 ? 0.01 : 0.1
                return processor.process(
                    magnitudes: [Float](repeating: rms * rms, count: 512),
                    fftSize: 1024,
                    sampleRate: 48_000,
                    rms: rms,
                    peak: rms * 2,
                    playerVolume: volume,
                    scheduling: (produced: 0, displayed: 0, coalesced: 0, pending: 0, frameAgeMs: 0),
                    dt: 1.0 / 30.0
                )
            }
        }

        let reference = render(volume: 1)
        XCTAssertEqual(render(volume: 0.1), reference)
        XCTAssertEqual(render(volume: 0), reference)
    }

    @MainActor
    private func makeFeed() -> (SkinAudioFeed, LEDMeterServiceProvider) {
        let provider = LEDMeterServiceProvider(
            config: LEDMeterConfig()
        )
        return (SkinAudioFeed(), provider)
    }

    private func makeAudioFrame(hostTime: Double) -> AudioAnalysisData {
        AudioAnalysisData(
            pcmSamples: [0.25, -0.25],
            hostTime: hostTime,
            magnitudes: [0.5],
            sampleRate: 44_100,
            fftSize: 2,
            rms: 0.25,
            peak: 0.25,
            fastRMS: 0.25,
            fastPeak: 0.25,
            fastWindow: 2
        )
    }
}

nonisolated private final class OneShotExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var isFulfilled = false

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfillIfNeeded() {
        lock.lock()
        let shouldFulfill = !isFulfilled
        isFulfilled = true
        lock.unlock()
        if shouldFulfill {
            expectation.fulfill()
        }
    }
}
#endif

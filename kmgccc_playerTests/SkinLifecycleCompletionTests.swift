#if DEBUG
import AVFoundation
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

    @MainActor
    private func makeFeed() -> (SkinAudioFeed, LEDMeterServiceProvider) {
        let engine = AVAudioEngine()
        let provider = LEDMeterServiceProvider(
            config: LEDMeterConfig(),
            mixerProvider: { engine.mainMixerNode }
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
#endif

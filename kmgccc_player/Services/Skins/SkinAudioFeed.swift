import Foundation
import Observation

@Observable
@MainActor
final class SkinAudioFeed {
    enum Availability {
        /// No live lease. Local pause keeps its last frame; hidden scenes clear it.
        case inactive
        /// Local PCM is being sampled for this visible, playing scene.
        case localAudio
        /// The visible scene uses an external source that does not expose PCM to skins.
        case externalAudioUnavailable
    }
    private(set) var frame: AudioAnalysisData?
    private(set) var availability = Availability.inactive
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var consumerID: UUID?
    @ObservationIgnored private var provider: LEDMeterServiceProvider?

    func update(provider: LEDMeterServiceProvider, source: PlaybackSource, active: Bool, isPlaying: Bool) {
        let next: Availability
        if !active {
            next = .inactive
        } else if source != .local {
            next = .externalAudioUnavailable
        } else {
            next = isPlaying ? .localAudio : .inactive
        }

        let keepsPausedLocalFrame = active && source == .local && !isPlaying
        guard next != availability else {
            if next == .inactive && !keepsPausedLocalFrame { frame = nil }
            return
        }
        releaseConsumer(clearFrame: !keepsPausedLocalFrame)
        availability = next
        guard next == .localAudio else { return }
        self.provider = provider
        provider.acquireSession()
        let expectedGeneration = generation
        consumerID = AudioAnalysisHub.shared.addConsumer { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self,
                      self.availability == .localAudio,
                      self.generation == expectedGeneration else { return }
                self.receive(frame)
            }
        }
    }

    /// Apply a frame from the active Hub subscription.
    func receive(_ frame: AudioAnalysisData) {
        guard availability == .localAudio else { return }
        self.frame = frame
    }

    func stop() {
        releaseConsumer(clearFrame: true)
        availability = .inactive
    }

    private func releaseConsumer(clearFrame: Bool) {
        generation &+= 1
        if let consumerID { AudioAnalysisHub.shared.removeConsumer(consumerID) }
        consumerID = nil
        provider?.releaseSession()
        provider = nil
        if clearFrame { frame = nil }
    }
}

struct SkinAudioData {
    let frame: AudioAnalysisData?
    let availability: SkinAudioFeed.Availability
}

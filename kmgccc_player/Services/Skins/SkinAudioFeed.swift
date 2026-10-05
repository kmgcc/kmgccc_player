import Foundation
import Observation

@Observable
@MainActor
final class SkinAudioFeed {
    enum Availability { case inactive, localAudio, externalAudioUnavailable }
    private(set) var frame: AudioAnalysisData?
    private(set) var availability = Availability.inactive
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var consumerID: UUID?
    @ObservationIgnored private var provider: LEDMeterServiceProvider?

    func update(provider: LEDMeterServiceProvider, source: PlaybackSource, active: Bool) {
        let next: Availability = !active ? .inactive : source == .local ? .localAudio : .externalAudioUnavailable
        guard next != availability else { return }
        stop()
        availability = next
        guard next == .localAudio else { return }
        self.provider = provider
        provider.acquireSession()
        let expectedGeneration = generation
        consumerID = AudioAnalysisHub.shared.addConsumer { [weak self] frame in
            Task { @MainActor [weak self] in
                guard self?.availability == .localAudio, self?.generation == expectedGeneration else { return }
                self?.frame = frame
            }
        }
    }

    func stop() {
        generation &+= 1
        if let consumerID { AudioAnalysisHub.shared.removeConsumer(consumerID) }
        consumerID = nil
        provider?.releaseSession()
        provider = nil
        frame = nil
        availability = .inactive
    }
}


struct SkinAudioData {
    let frame: AudioAnalysisData?
    let availability: SkinAudioFeed.Availability
}

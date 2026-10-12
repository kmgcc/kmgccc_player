import Foundation
import Observation

/// Owner of the equal-loudness control input: the routed device, its system
/// volume and a live calibration preview. Calibrations themselves live in
/// each equal-loudness node, so every preset compensates independently. It
/// publishes one context; the renderer turns context changes into shelf-gain
/// glides through its parameter channel.
@Observable
@MainActor
final class EqualLoudnessController {
    let volumeObserver: OutputDeviceVolumeObserver
    private(set) var previewGains: DSPEqualLoudnessGains?
    private(set) var routedDeviceUID: String?

    @ObservationIgnored var onContextChange: (@MainActor (DSPEqualLoudnessContext) -> Void)?
    @ObservationIgnored private var lastPublished: DSPEqualLoudnessContext?

    init(volumeObserver: OutputDeviceVolumeObserver = OutputDeviceVolumeObserver()) {
        self.volumeObserver = volumeObserver
        volumeObserver.onChange = { [weak self] _ in self?.publish() }
    }

    var volumeState: OutputDeviceVolumeState { volumeObserver.state }

    var context: DSPEqualLoudnessContext {
        DSPEqualLoudnessContext(volume: volumeObserver.state, override: previewGains)
    }

    /// The player's confirmed route; the default device when it follows the
    /// system output, the chosen device when the App selects one.
    func setRoutedDevice(_ uid: String?) {
        routedDeviceUID = uid
        volumeObserver.observe(deviceUID: uid)
        publish()
    }

    func refreshVolume() {
        volumeObserver.observe(deviceUID: routedDeviceUID)
    }

    /// While a calibration step is adjusted, the node plays these gains
    /// directly instead of following a curve.
    func setPreview(_ gains: DSPEqualLoudnessGains?) {
        guard previewGains != gains else { return }
        previewGains = gains
        publish()
    }

    func republish() {
        lastPublished = nil
        publish()
    }

    private func publish() {
        let next = context
        guard next != lastPublished else { return }
        lastPublished = next
        onContextChange?(next)
    }
}

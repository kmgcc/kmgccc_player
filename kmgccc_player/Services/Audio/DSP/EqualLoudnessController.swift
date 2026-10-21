import Foundation
import Observation

/// Owner of the equal-loudness control input: the routed device, its system
/// volume and a live calibration preview. The calibration itself lives in the
/// preset's equal-loudness stage. It publishes one context; the renderer
/// turns context changes into shelf-gain glides through its parameter channel.
@Observable
@MainActor
final class EqualLoudnessController {
    let volumeObserver: OutputDeviceVolumeObserver
    private(set) var previewGains: DSPEqualLoudnessGains?
    private(set) var routedDeviceUID: String?
    /// The routed output with its data source; calibrations match on it.
    private(set) var routedDeviceKey: String?
    private(set) var routedOutputKind: DSPOutputKind?

    @ObservationIgnored var onContextChange: (@MainActor (DSPEqualLoudnessContext) -> Void)?
    @ObservationIgnored private var lastPublished: DSPEqualLoudnessContext?
    @ObservationIgnored private var calibrationSwitches: (chain: Bool, stage: Bool)?

    init(volumeObserver: OutputDeviceVolumeObserver = OutputDeviceVolumeObserver()) {
        self.volumeObserver = volumeObserver
        volumeObserver.onChange = { [weak self] _ in self?.publish() }
    }

    var volumeState: OutputDeviceVolumeState { volumeObserver.state }

    var context: DSPEqualLoudnessContext {
        DSPEqualLoudnessContext(volume: volumeObserver.state, deviceKey: routedDeviceKey,
                                override: previewGains, outputKind: routedOutputKind)
    }

    /// The player's confirmed route; the default device when it follows the
    /// system output, the chosen device when the App selects one.
    func setRoutedDevice(_ device: DSPOutputDevice?) {
        if routedDeviceKey != device?.id { volumeObserver.cancelVolumeRamp() }
        routedDeviceUID = device?.uid
        routedDeviceKey = device?.id
        routedOutputKind = device?.outputKind
        volumeObserver.observe(deviceUID: device?.uid)
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

    /// Calibration must be audible even when either processing switch was off.
    /// Only the switches are borrowed; cancelling preserves the preset's data.
    func beginCalibration(using dsp: AudioDSPController) {
        guard calibrationSwitches == nil else { return }
        calibrationSwitches = (dsp.configuration.enabled, dsp.configuration.equalLoudness.enabled)
        setPreview(.zero)
        dsp.updateConfiguration(commit: true, recordsUndo: false) {
            $0.enabled = true
            $0.equalLoudness.enabled = true
        }
    }

    func endCalibration(using dsp: AudioDSPController, keepingEnabled: Bool = false) {
        volumeObserver.cancelVolumeRamp()
        if let switches = calibrationSwitches {
            calibrationSwitches = nil
            if !keepingEnabled {
                dsp.updateConfiguration(commit: true, recordsUndo: false) {
                    $0.enabled = switches.chain
                    $0.equalLoudness.enabled = switches.stage
                }
            }
        }
        setPreview(nil)
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

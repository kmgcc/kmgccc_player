import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Reads, observes and (for calibration) writes the system volume of the one
/// output device this App actually plays through. It takes the route the
/// player has already resolved and never chooses a device itself.
///
/// The control value prefers the device's own dB reading or its
/// scalar-to-dB conversion; a device with only a percentage control is
/// reported on a percent axis. Per-channel devices are read from their
/// loudest channel and written on every channel alike, so balance is kept.
/// A device without any readable volume control is reported unavailable;
/// the App's own volume is never used in its place.
@Observable
@MainActor
final class OutputDeviceVolumeObserver {
    private(set) var state: OutputDeviceVolumeState = .unknown

    @ObservationIgnored var onChange: (@MainActor (OutputDeviceVolumeState) -> Void)?
    @ObservationIgnored private var deviceUID: String?
    @ObservationIgnored private var deviceID: AudioDeviceID?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var listenedAddresses: [AudioObjectPropertyAddress] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Volume-key presses arrive as bursts; one refresh covers a burst.
    private static let coalescingInterval: Duration = .milliseconds(40)

    init() {}

    /// Follows the routed device. Nil means the device is not known yet.
    func observe(deviceUID uid: String?) {
        let device = uid.flatMap { uid in
            AudioOutputLatencyMonitor.availableOutputDevices().first { $0.uniqueID == uid }
        }
        guard uid != deviceUID || device?.deviceID != deviceID else {
            refreshNow()
            return
        }
        removeListeners()
        deviceUID = uid
        deviceID = device?.deviceID
        if let device { installListeners(on: device.deviceID) }
        refreshNow()
    }

    /// Writes the routed device's system volume (0...1). A muted device is
    /// unmuted, as the system volume keys do.
    @discardableResult
    func setScalar(_ value: Double) -> Bool {
        guard let deviceID else { return false }
        let clamped = Float32(min(1, max(0, value)))
        var wrote = false
        for address in Self.writableScalarAddresses(deviceID) {
            var scalar = clamped
            var mutable = address
            if AudioObjectSetPropertyData(deviceID, &mutable, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr {
                wrote = true
            }
        }
        if wrote, clamped > 0 {
            var muteAddress = Self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(deviceID, &muteAddress),
               AudioObjectIsPropertySettable(deviceID, &muteAddress, &settable) == noErr, settable.boolValue {
                var unmuted: UInt32 = 0
                AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
            }
        }
        refreshNow()
        return wrote
    }

    // MARK: - Reading

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalescingInterval)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        let next: OutputDeviceVolumeState
        if let deviceID, let uid = deviceUID {
            let name = AudioOutputLatencyMonitor.availableOutputDevices().first { $0.deviceID == deviceID }?.name ?? uid
            next = Self.read(deviceID: deviceID, uid: uid, name: name)
        } else {
            next = .unavailable(deviceUID: deviceUID, deviceName: nil)
        }
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private static func read(deviceID: AudioDeviceID, uid: String, name: String) -> OutputDeviceVolumeState {
        let elements = volumeElements(deviceID)
        var scalar: Double?
        var decibels: Double?
        var maximumDecibels: Double?
        for element in elements {
            if let value = float(deviceID, kAudioDevicePropertyVolumeScalar, element) {
                scalar = max(scalar ?? 0, Double(value))
            }
            if let value = float(deviceID, kAudioDevicePropertyVolumeDecibels, element) {
                decibels = max(decibels ?? -.infinity, Double(value))
                if let range = decibelRange(deviceID, element) {
                    maximumDecibels = max(maximumDecibels ?? -.infinity, range.mMaximum)
                }
            }
        }
        if scalar == nil, let virtual = float(deviceID,
            AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            kAudioObjectPropertyElementMain) {
            scalar = Double(virtual)
        }
        if decibels == nil, let scalar, let element = elements.first,
           let converted = scalarToDecibels(deviceID, element, Float32(scalar)),
           let range = decibelRange(deviceID, element) {
            decibels = Double(converted)
            maximumDecibels = range.mMaximum
        }
        guard let scalar, scalar.isFinite else {
            return .unavailable(deviceUID: uid, deviceName: name)
        }
        var belowMaximum: Double?
        if let decibels, let maximumDecibels, decibels.isFinite, maximumDecibels.isFinite {
            belowMaximum = min(0, decibels - maximumDecibels)
        }
        var muteAddress = address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let isMuted = AudioObjectHasProperty(deviceID, &muteAddress)
            && AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &muted) == noErr
            && muted != 0
        return .available(OutputDeviceVolumeReading(
            deviceUID: uid,
            deviceName: name,
            scalar: min(1, max(0, scalar)),
            decibelsBelowMaximum: belowMaximum,
            isMuted: isMuted,
            isWritable: !writableScalarAddresses(deviceID).isEmpty
        ))
    }

    /// The main element when it carries a volume control, otherwise the
    /// first two channels.
    private static func volumeElements(_ deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = address(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(deviceID, &main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { element in
            var channel = address(kAudioDevicePropertyVolumeScalar, element: element)
            return AudioObjectHasProperty(deviceID, &channel)
        }
    }

    private static func writableScalarAddresses(_ deviceID: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        var virtual = address(AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                              element: kAudioObjectPropertyElementMain)
        if isSettable(deviceID, &virtual) { return [virtual] }
        return volumeElements(deviceID).compactMap { element in
            var scalar = address(kAudioDevicePropertyVolumeScalar, element: element)
            return isSettable(deviceID, &scalar) ? scalar : nil
        }
    }

    private static func isSettable(_ deviceID: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    private static func float(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement
    ) -> Float32? {
        var propertyAddress = address(selector, element: element)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return value
    }

    private static func decibelRange(_ deviceID: AudioDeviceID, _ element: AudioObjectPropertyElement) -> AudioValueRange? {
        var propertyAddress = address(kAudioDevicePropertyVolumeRangeDecibels, element: element)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &range) == noErr,
              range.mMaximum.isFinite, range.mMinimum.isFinite, range.mMaximum > range.mMinimum else { return nil }
        return range
    }

    private static func scalarToDecibels(
        _ deviceID: AudioDeviceID,
        _ element: AudioObjectPropertyElement,
        _ scalar: Float32
    ) -> Float32? {
        var propertyAddress = address(kAudioDevicePropertyVolumeScalarToDecibels, element: element)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        var value = scalar
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return value
    }

    // MARK: - Listeners

    private func installListeners(on deviceID: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        listener = block
        var addresses = [
            Self.address(AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                         element: kAudioObjectPropertyElementMain),
            Self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain),
        ]
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            addresses.append(Self.address(kAudioDevicePropertyVolumeScalar, element: element))
            addresses.append(Self.address(kAudioDevicePropertyVolumeDecibels, element: element))
        }
        listenedAddresses = addresses.filter { address in
            var mutable = address
            guard AudioObjectHasProperty(deviceID, &mutable) else { return false }
            return AudioObjectAddPropertyListenerBlock(deviceID, &mutable, .main, block) == noErr
        }
    }

    private func removeListeners() {
        guard let deviceID, let listener else { return }
        for address in listenedAddresses {
            var mutable = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &mutable, .main, listener)
        }
        listenedAddresses.removeAll()
        self.listener = nil
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }
}

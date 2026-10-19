import CoreAudio
import Foundation

/// The active data source of an output device. One Core Audio device can
/// switch between its built-in speakers and a headphone jack while keeping
/// the same UID; only the data source tells the two apart.
nonisolated enum AudioOutputDataSource {
    nonisolated struct Info: Equatable, Sendable {
        let id: UInt32
        let name: String?
        /// The device offers more than one source, so the source is part of
        /// the route's identity.
        let isSwitchable: Bool
    }

    static func current(deviceID: AudioDeviceID) -> Info? {
        var address = outputAddress(kAudioDevicePropertyDataSource)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr else { return nil }
        return Info(id: source, name: name(of: source, deviceID: deviceID), isSwitchable: sourceCount(deviceID) > 1)
    }

    /// Four printable characters ('ispk', 'hdpn') or hexadecimal.
    static func code(_ source: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((source >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(format: "%08x", source) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func sourceCount(_ deviceID: AudioDeviceID) -> Int {
        var address = outputAddress(kAudioDevicePropertyDataSources)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<UInt32>.size
    }

    private static func name(of source: UInt32, deviceID: AudioDeviceID) -> String? {
        var address = outputAddress(kAudioDevicePropertyDataSourceNameForIDCFString)
        var sourceID = source
        var name: Unmanaged<CFString>?
        return withUnsafeMutablePointer(to: &sourceID) { input in
            withUnsafeMutablePointer(to: &name) { output in
                var translation = AudioValueTranslation(
                    mInputData: input,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: output,
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &translation) == noErr else {
                    return nil
                }
                return output.pointee?.takeRetainedValue() as String?
            }
        }
    }
}

/// Follows the data source of one output device, such as headphones being
/// plugged into a Mac whose speakers and jack share one device.
nonisolated final class AudioOutputDataSourceObservation {
    private let deviceID: AudioDeviceID
    private let listener: AudioObjectPropertyListenerBlock

    @MainActor
    init(deviceID: AudioDeviceID, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.deviceID = deviceID
        listener = { _, _ in
            Task { @MainActor in onChange() }
        }
        var address = AudioOutputDataSource.outputAddress(kAudioDevicePropertyDataSource)
        AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener)
    }

    deinit {
        var address = AudioOutputDataSource.outputAddress(kAudioDevicePropertyDataSource)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, listener)
    }
}

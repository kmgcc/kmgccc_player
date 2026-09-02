//
//  AudioOutputLatencyMonitor.swift
//  myPlayer2
//
//  Diagnostic information for the current Core Audio default output. The
//  renderer's presentation timeline is driven by the output-device clock; the
//  reported latency fields are intentionally not converted into a UI offset.
//

import CoreAudio
import Foundation

nonisolated struct AudioOutputLatencySnapshot: Equatable, Sendable {
    let deviceID: AudioDeviceID
    /// Core Audio's stable identifier for the output device. This is the value
    /// AVSampleBufferAudioRenderer uses to bind the synchronizer to the active
    /// device clock. It is optional because Core Audio may temporarily report
    /// no default device while a route is being reconfigured.
    let deviceUID: String?
    let deviceName: String
    let transportType: UInt32
    let sampleRate: Double
    let deviceLatencyFrames: UInt32
    let streamLatencyFrames: UInt32
    /// HAL-reported presentation latency, retained for diagnostics only.
    let seconds: Double

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    static let zero = AudioOutputLatencySnapshot(
        deviceID: kAudioObjectUnknown,
        deviceUID: nil,
        deviceName: "unknown",
        transportType: kAudioDeviceTransportTypeUnknown,
        sampleRate: 0,
        deviceLatencyFrames: 0,
        streamLatencyFrames: 0,
        seconds: 0
    )
}

enum AudioOutputLatencyMonitor {

    static func currentSnapshot() -> AudioOutputLatencySnapshot {
        guard let deviceID = defaultOutputDeviceID(),
              let sampleRate: Double = read(
                  deviceID,
                  selector: kAudioDevicePropertyNominalSampleRate
              ),
              sampleRate > 0 else {
            return .zero
        }

        let transport: UInt32 = read(
            deviceID,
            selector: kAudioDevicePropertyTransportType
        ) ?? kAudioDeviceTransportTypeUnknown
        let deviceUID = stringValue(
            deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        let deviceLatency: UInt32 = read(
            deviceID,
            selector: kAudioDevicePropertyLatency,
            scope: kAudioObjectPropertyScopeOutput
        ) ?? 0

        var streamLatency: UInt32 = 0
        for streamID in outputStreamIDs(for: deviceID) {
            let latency: UInt32 = read(
                streamID,
                selector: kAudioStreamPropertyLatency
            ) ?? 0
            streamLatency = max(streamLatency, latency)
        }

        // Core Audio's device and stream latency properties are not guaranteed
        // to be additive. Keep the larger component as a bounded diagnostic
        // value while a route is being reconfigured; this value is never fed
        // into the playback, lyrics, or visualization clocks.
        let observedFrames = max(deviceLatency, streamLatency)
        let seconds = min(0.25, max(0, Double(observedFrames) / sampleRate))

        return AudioOutputLatencySnapshot(
            deviceID: deviceID,
            deviceUID: deviceUID,
            deviceName: deviceName(for: deviceID),
            transportType: transport,
            sampleRate: sampleRate,
            deviceLatencyFrames: deviceLatency,
            streamLatencyFrames: streamLatency,
            seconds: seconds
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func outputStreamIDs(for deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { return [] }
        var streams = [AudioStreamID](repeating: 0, count: count)
        let status = streams.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareBadObjectError }
            var dataSize = size
            return AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        return status == noErr ? streams : []
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String {
        stringValue(deviceID, selector: kAudioObjectPropertyName)
            ?? "device#\(deviceID)"
    }

    private static func stringValue(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &name
        ) == noErr else {
            return nil
        }
        return name?.takeUnretainedValue() as String?
    }

    private static func read<T>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            storage
        )
        return status == noErr ? storage.load(as: T.self) : nil
    }
}

//
//  AudioOutputLatencyMonitor.swift
//  myPlayer2
//
//  Best-effort output latency information for the current Core Audio default
//  output.  AVSampleBufferAudioRenderer does not expose an output-latency
//  property on macOS, so the public Core Audio device and stream properties are
//  the narrowest system-provided estimate available to the player.
//

import CoreAudio
import Foundation

nonisolated struct AudioOutputLatencySnapshot: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let deviceName: String
    let transportType: UInt32
    let sampleRate: Double
    let deviceLatencyFrames: UInt32
    let streamLatencyFrames: UInt32
    let seconds: Double

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Only Bluetooth output is folded into the UI/analysis compensation. The
    /// built-in path is intentionally left at zero so a few reported hardware
    /// frames do not change the established local-speaker behavior.
    var compensationSeconds: Double {
        isBluetooth ? seconds : 0
    }

    static let zero = AudioOutputLatencySnapshot(
        deviceID: kAudioObjectUnknown,
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
        // to be additive. On Bluetooth routes they commonly describe
        // overlapping portions of the same output path; summing them made the
        // UI compensate twice and put lyrics/visualization visibly behind the
        // sound. Use the larger reported component and keep a conservative cap
        // for transient values while a route is being reconfigured.
        let observedFrames = max(deviceLatency, streamLatency)
        let seconds = min(0.25, max(0, Double(observedFrames) / sampleRate))

        return AudioOutputLatencySnapshot(
            deviceID: deviceID,
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
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        ) == noErr else {
            return "device#\(deviceID)"
        }
        return name?.takeUnretainedValue() as String? ?? "device#\(deviceID)"
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

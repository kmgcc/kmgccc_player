//
//  SystemVolumeService.swift
//  myPlayer2
//
//  System output volume reader, writer, and listener via Core Audio.
//

import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class SystemVolumeService {
    static let shared = SystemVolumeService()

    private(set) var systemVolume: Double = 0.5
    var onVolumeChanged: (@MainActor (Double) -> Void)?

    private var monitoredDeviceID: AudioDeviceID?
    private let listenerQueue = DispatchQueue(label: "com.kmgccc.player.systemVolumeListener", qos: .userInitiated)

    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        self.systemVolume = Self.getSystemVolume()
        setupListeners()
    }

    // MARK: - Public API

    func refreshVolume() {
        let current = Self.getSystemVolume()
        if abs(current - systemVolume) > 0.001 {
            systemVolume = current
            onVolumeChanged?(current)
        }
    }

    func setSystemVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        systemVolume = clamped
        Self.setSystemVolume(clamped)
        onVolumeChanged?(clamped)
    }

    // MARK: - Private Listeners

    private func setupListeners() {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultDeviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultDeviceChanged()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            listenerQueue,
            defaultDeviceBlock
        )
        if status != noErr {
            Log.error("[SystemVolumeService] failed to add default device listener: \(status)", category: .audio)
        }

        updateDeviceVolumeListener()
    }

    private func handleDefaultDeviceChanged() {
        updateDeviceVolumeListener()
        refreshVolume()
    }

    private func updateDeviceVolumeListener() {
        removeDeviceVolumeListener()

        guard let deviceID = Self.defaultOutputDeviceID() else { return }
        monitoredDeviceID = deviceID

        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleVolumeChangedFromSystem()
            }
        }
        self.volumeListenerBlock = volBlock

        var virtualAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &virtualAddress,
            listenerQueue,
            volBlock
        )

        var mainScalarAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &mainScalarAddress,
            listenerQueue,
            volBlock
        )

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &muteAddress,
            listenerQueue,
            volBlock
        )
    }

    private func removeDeviceVolumeListener() {
        guard let deviceID = monitoredDeviceID, let volBlock = volumeListenerBlock else { return }

        var virtualAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &virtualAddress, listenerQueue, volBlock)

        var mainScalarAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &mainScalarAddress, listenerQueue, volBlock)

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, listenerQueue, volBlock)

        self.monitoredDeviceID = nil
        self.volumeListenerBlock = nil
    }

    private func handleVolumeChangedFromSystem() {
        let newVolume = Self.getSystemVolume()
        guard abs(newVolume - systemVolume) > 0.001 else { return }
        systemVolume = newVolume
        onVolumeChanged?(newVolume)
    }

    // MARK: - CoreAudio Primitives

    nonisolated static func defaultOutputDeviceID() -> AudioDeviceID? {
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

    nonisolated static func getSystemVolume() -> Double {
        guard let deviceID = defaultOutputDeviceID() else { return 0.5 }

        // Check mute state first
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var isMuted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &isMuted) == noErr, isMuted != 0 {
                return 0.0
            }
        }

        // 1. AudioHardwareService VirtualMainVolume
        var virtualAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddress) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &virtualAddress,
                0,
                nil,
                &size,
                &volume
            )
            if status == noErr {
                return Double(max(0, min(1, volume)))
            }
        }

        // 2. AudioDevicePropertyVolumeScalar on Main Element
        var mainScalarAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &mainScalarAddress) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &mainScalarAddress,
                0,
                nil,
                &size,
                &volume
            )
            if status == noErr {
                return Double(max(0, min(1, volume)))
            }
        }

        // 3. Fallback: channel 1
        var ch1Address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: 1
        )
        if AudioObjectHasProperty(deviceID, &ch1Address) {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &ch1Address,
                0,
                nil,
                &size,
                &volume
            )
            if status == noErr {
                return Double(max(0, min(1, volume)))
            }
        }

        return 0.5
    }

    nonisolated static func setSystemVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        guard let deviceID = defaultOutputDeviceID() else { return }

        var didApply = false

        // 1. AudioHardwareService VirtualMainVolume
        var virtualAddress = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddress) {
            var val = Float32(clamped)
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectSetPropertyData(
                deviceID,
                &virtualAddress,
                0,
                nil,
                size,
                &val
            )
            if status == noErr {
                didApply = true
            }
        }

        // 2. Fallback: AudioDevicePropertyVolumeScalar on Main Element
        if !didApply {
            var mainScalarAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(deviceID, &mainScalarAddress) {
                var val = Float32(clamped)
                let size = UInt32(MemoryLayout<Float32>.size)
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &mainScalarAddress,
                    0,
                    nil,
                    size,
                    &val
                )
                if status == noErr {
                    didApply = true
                }
            }
        }

        // 3. Fallback: channels 1 & 2
        if !didApply {
            for element in [UInt32(1), UInt32(2)] {
                var chAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
                if AudioObjectHasProperty(deviceID, &chAddress) {
                    var val = Float32(clamped)
                    let size = UInt32(MemoryLayout<Float32>.size)
                    _ = AudioObjectSetPropertyData(
                        deviceID,
                        &chAddress,
                        0,
                        nil,
                        size,
                        &val
                    )
                }
            }
        }

        // 4. Mute / Unmute handling
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            if clamped > 0 {
                var isMuted: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &isMuted) == noErr, isMuted != 0 {
                    var unmute: UInt32 = 0
                    _ = AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, size, &unmute)
                }
            } else {
                var mute: UInt32 = 1
                let size = UInt32(MemoryLayout<UInt32>.size)
                _ = AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, size, &mute)
            }
        }
    }
}

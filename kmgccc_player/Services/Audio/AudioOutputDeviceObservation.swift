import AppKit
import CoreAudio
import Foundation

/// One app-owned subscription covers output changes even while playback is paused.
nonisolated final class AudioOutputDeviceObservation {
    private let listener: AudioObjectPropertyListenerBlock
    private let workspaceCenter: NotificationCenter
    private var preferenceObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    @MainActor
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        workspaceCenter = NSWorkspace.shared.notificationCenter
        listener = { _, _ in
            Task { @MainActor in onChange() }
        }
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .audioOutputDevicePreferenceDidChange, object: nil, queue: .main
        ) { _ in Task { @MainActor in onChange() } }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in onChange() } }
    }

    deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let wakeObserver { workspaceCenter.removeObserver(wakeObserver) }
        for selector in selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

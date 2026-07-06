//
//  ExternalPlaybackPermissions.swift
//  myPlayer2
//
//  Small helpers for the permissions and availability states shown in Settings.
//

import AppKit
import ApplicationServices
import Foundation

enum ExternalPlaybackPermissionState: Equatable, Sendable {
    case allowed
    case notAllowed
    case manual
    case checking
    case unknown

    var title: String {
        switch self {
        case .allowed: return "已允许"
        case .notAllowed: return "未允许"
        case .manual: return "需要手动开启"
        case .checking: return "检查中"
        case .unknown: return "未知"
        }
    }
}

enum ExternalPlaybackPermissions {
    static func appleMusicAutomationStatus(prompt: Bool = false) -> ExternalPlaybackPermissionState {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
        guard let aeDesc = descriptor.aeDesc else { return .unknown }
        let status = aeDesc.withMemoryRebound(to: AEAddressDesc.self, capacity: 1) { target in
            AEDeterminePermissionToAutomateTarget(
                target,
                typeWildCard,
                typeWildCard,
                prompt
            )
        }
        switch status {
        case OSStatus(noErr):
            return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notAllowed
        case OSStatus(errAEEventNotPermitted):
            return .manual
        default:
            return .unknown
        }
    }

    @MainActor
    static func openAutomationSettings() {
        openSystemSettings(path: "Privacy_Automation")
    }

    @MainActor
    static func openPrivacySettings() {
        openSystemSettings(path: nil)
    }

    @MainActor
    private static func openSystemSettings(path: String?) {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        let urlString = path.map { "\(base)?\($0)" } ?? base
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

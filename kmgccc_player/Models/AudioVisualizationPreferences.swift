//
//  AudioVisualizationPreferences.swift
//  myPlayer2
//

import Foundation
import Observation

public enum AudioVisualizationKind: String, CaseIterable, Identifiable, Codable {
    case off
    case spectrum
    case led

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .spectrum: return "频谱"
        case .led: return "LED"
        }
    }
}

enum AudioVisualizationPlacement: String, Codable {
    case off
    case skinSpectrum
    case skinLED
    case miniPlayerSpectrum
    case miniPlayerLED

    var skinKind: AudioVisualizationKind {
        switch self {
        case .skinSpectrum: return .spectrum
        case .skinLED: return .led
        case .off, .miniPlayerSpectrum, .miniPlayerLED: return .off
        }
    }

    var miniPlayerKind: AudioVisualizationKind {
        switch self {
        case .miniPlayerSpectrum: return .spectrum
        case .miniPlayerLED: return .led
        case .off, .skinSpectrum, .skinLED: return .off
        }
    }

    static func skin(_ kind: AudioVisualizationKind) -> Self {
        switch kind {
        case .off: return .off
        case .spectrum: return .skinSpectrum
        case .led: return .skinLED
        }
    }

    static func miniPlayer(_ kind: AudioVisualizationKind) -> Self {
        switch kind {
        case .off: return .off
        case .spectrum: return .miniPlayerSpectrum
        case .led: return .miniPlayerLED
        }
    }
}

enum AudioVisualizationScope: String {
    case fullscreen
    case window
}

@Observable
@MainActor
final class AudioVisualizationPreferences {
    static let shared = AudioVisualizationPreferences()

    private(set) var revision = 0
    private let defaults = UserDefaults.standard

    private init() {}

    func selection(for skinID: String, scope: AudioVisualizationScope) -> AudioVisualizationPlacement {
        _ = revision
        let key = preferenceKey(for: skinID, scope: scope)
        if let raw = defaults.string(forKey: key),
           let selection = AudioVisualizationPlacement(rawValue: raw) {
            return selection
        }

        let selection = migratedSelection(for: skinID, scope: scope)
        persist(selection, for: skinID, scope: scope, notify: false)
        return selection
    }

    func setSkinKind(_ kind: AudioVisualizationKind, for skinID: String, scope: AudioVisualizationScope) {
        persist(.skin(kind), for: skinID, scope: scope, notify: true)
    }

    func setMiniPlayerKind(_ kind: AudioVisualizationKind, for skinID: String, scope: AudioVisualizationScope) {
        persist(.miniPlayer(kind), for: skinID, scope: scope, notify: true)
    }

    func synchronizeLegacyState(for skinID: String, scope: AudioVisualizationScope) {
        persist(selection(for: skinID, scope: scope), for: skinID, scope: scope, notify: false)
    }

    func migrateSelectionIfNeeded(
        _ selection: AudioVisualizationPlacement,
        for skinID: String,
        scope: AudioVisualizationScope
    ) {
        guard defaults.string(forKey: preferenceKey(for: skinID, scope: scope)) == nil else { return }
        persist(selection, for: skinID, scope: scope, notify: false)
    }

    private func persist(
        _ selection: AudioVisualizationPlacement,
        for skinID: String,
        scope: AudioVisualizationScope,
        notify: Bool
    ) {
        defaults.set(selection.rawValue, forKey: preferenceKey(for: skinID, scope: scope))
        defaults.set(selection.skinKind.rawValue, forKey: legacySkinKey(for: skinID, scope: scope))
        if scope == .fullscreen {
            defaults.set(selection.miniPlayerKind == .spectrum, forKey: "miniPlayerSpectrumEnabled")
        }
        if notify {
            revision &+= 1
            TelemetryService.shared.updateSkinState()
        }
    }

    private func migratedSelection(
        for skinID: String,
        scope: AudioVisualizationScope
    ) -> AudioVisualizationPlacement {
        if scope == .fullscreen,
           defaults.object(forKey: "miniPlayerSpectrumEnabled") != nil,
           defaults.bool(forKey: "miniPlayerSpectrumEnabled") {
            return .miniPlayerSpectrum
        }

        let legacyKey = legacySkinKey(for: skinID, scope: scope)
        if defaults.object(forKey: legacyKey) != nil,
           let kind = AudioVisualizationKind(rawValue: defaults.string(forKey: legacyKey) ?? "off") {
            return .skin(kind)
        }

        if scope == .window {
            return .miniPlayerSpectrum
        }
        if skinID == FullscreenSkinID.coverGradientBlur.rawValue {
            return .miniPlayerSpectrum
        }
        if skinID == FullscreenSkinID.kmgcccCassette.rawValue {
            return .miniPlayerLED
        }
        return .skinLED
    }

    private func preferenceKey(for skinID: String, scope: AudioVisualizationScope) -> String {
        "audioVisualization.\(scope.rawValue).\(skinID).selection.v1"
    }

    private func legacySkinKey(for skinID: String, scope: AudioVisualizationScope) -> String {
        let suffix = scope == .fullscreen ? ".fullscreen.visualizerMode" : ".visualizerMode"
        switch skinID {
        case FullscreenSkinID.coverLed.rawValue:
            return "skin.classicLED\(suffix)"
        case FullscreenSkinID.appleStyle.rawValue:
            return "skin.appleStyle\(suffix)"
        case FullscreenSkinID.rotatingCover.rawValue:
            return "skin.rotatingCover\(suffix)"
        case FullscreenSkinID.kmgcccCassette.rawValue:
            return "skin.kmgcccCassette\(suffix)"
        default:
            return "skin.\(skinID)\(suffix)"
        }
    }
}

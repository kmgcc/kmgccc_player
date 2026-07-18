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

    private enum Keys {
        static let defaultsMigration = "audioVisualizationDefaultsMigrated_v2"
    }

    private(set) var revision = 0
    private let defaults = UserDefaults.standard

    private init() {
        migrateDefaultSelectionsIfNeeded()
    }

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

    private func defaultSelection(
        for skinID: String,
        scope: AudioVisualizationScope
    ) -> AudioVisualizationPlacement {
        switch scope {
        case .fullscreen:
            switch skinID {
            case FullscreenSkinID.coverLed.rawValue:
                return .miniPlayerLED
            case FullscreenSkinID.appleStyle.rawValue:
                return .skinLED
            case FullscreenSkinID.rotatingCover.rawValue,
                 FullscreenSkinID.coverGradientBlur.rawValue:
                return .miniPlayerSpectrum
            case FullscreenSkinID.kmgcccCassette.rawValue:
                return .off
            default:
                return .off
            }

        case .window:
            switch skinID {
            case FullscreenSkinID.appleStyle.rawValue,
                 FullscreenSkinID.kmgcccCassette.rawValue:
                return .miniPlayerLED
            case FullscreenSkinID.coverLed.rawValue,
                 FullscreenSkinID.rotatingCover.rawValue:
                return .miniPlayerSpectrum
            default:
                return .miniPlayerSpectrum
            }
        }
    }

    private func previousDefaultSelection(
        for skinID: String,
        scope: AudioVisualizationScope
    ) -> AudioVisualizationPlacement {
        switch scope {
        case .fullscreen:
            switch skinID {
            case FullscreenSkinID.coverGradientBlur.rawValue:
                return .miniPlayerSpectrum
            case FullscreenSkinID.kmgcccCassette.rawValue:
                return .miniPlayerLED
            default:
                return .skinLED
            }

        case .window:
            return .miniPlayerSpectrum
        }
    }

    private func migrateDefaultSelectionsIfNeeded() {
        guard !defaults.bool(forKey: Keys.defaultsMigration) else { return }

        let skinIDs = [
            FullscreenSkinID.coverLed.rawValue,
            FullscreenSkinID.appleStyle.rawValue,
            FullscreenSkinID.rotatingCover.rawValue,
            FullscreenSkinID.kmgcccCassette.rawValue,
            FullscreenSkinID.coverGradientBlur.rawValue,
        ]

        for scope in [AudioVisualizationScope.fullscreen, .window] {
            for skinID in skinIDs {
                let target = defaultSelection(for: skinID, scope: scope)
                let previous = previousDefaultSelection(for: skinID, scope: scope)
                let selectionKey = preferenceKey(for: skinID, scope: scope)

                if let raw = defaults.string(forKey: selectionKey),
                   let existing = AudioVisualizationPlacement(rawValue: raw),
                   existing == previous {
                    persist(target, for: skinID, scope: scope, notify: false)
                    continue
                }

                // Older installations may have only the legacy skin key. If
                // it still matches the old generated default, upgrade it;
                // otherwise leave the user's explicit legacy choice alone.
                guard defaults.string(forKey: selectionKey) == nil,
                      let raw = defaults.string(forKey: legacySkinKey(for: skinID, scope: scope)),
                      let legacyKind = AudioVisualizationKind(rawValue: raw),
                      legacyKind == previous.skinKind else {
                    continue
                }
                persist(target, for: skinID, scope: scope, notify: false)
            }
        }

        defaults.set(true, forKey: Keys.defaultsMigration)
    }

    private func migratedSelection(
        for skinID: String,
        scope: AudioVisualizationScope
    ) -> AudioVisualizationPlacement {
        let legacyKey = legacySkinKey(for: skinID, scope: scope)
        if defaults.object(forKey: legacyKey) != nil,
           let kind = AudioVisualizationKind(rawValue: defaults.string(forKey: legacyKey) ?? "off") {
            return .skin(kind)
        }

        return defaultSelection(for: skinID, scope: scope)
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

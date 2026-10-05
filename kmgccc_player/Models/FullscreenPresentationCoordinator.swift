//
//  FullscreenPresentationCoordinator.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Presentation Configuration Coordinator
//  Single source of truth for fullscreen visualizer/skin presentation state.
//  Enforces mutual exclusivity rules at the state layer, not view layer.
//

import Foundation
import SwiftUI

// MARK: - Fullscreen Presentation State Model

/// Represents the mutually exclusive visualizer configuration for fullscreen mode.
public enum FullscreenVisualizerMode: String, CaseIterable, Identifiable, Codable {
    case off = "off"
    case miniPlayerSpectrum = "miniPlayerSpectrum"
    case miniPlayerLED = "miniPlayerLED"
    case skinVisualizer = "skinVisualizer"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .miniPlayerSpectrum: return "MiniPlayer 频谱"
        case .miniPlayerLED: return "MiniPlayer LED"
        case .skinVisualizer: return "全屏皮肤频谱"
        }
    }
}

/// Historic built-in identifiers retained for source compatibility. Routing uses SkinRegistry.
public enum FullscreenSkinID: String, CaseIterable, Identifiable {
    case coverLed = "coverLed"
    case appleStyle = "appleStyle"
    case kmgcccCassette = "kmgccc.cassette"
    case rotatingCover = "rotatingCover"
    case coverGradientBlur = "fullscreen.coverGradientBlur"

    public var id: String { rawValue }

    public var supportsEmbeddedVisualizer: Bool {
        SkinRegistry.registeredDescriptor(for: rawValue)?.audio.supportsEmbeddedVisualizer ?? false
    }

    public var supportsMiniPlayerVisualization: Bool {
        SkinRegistry.registeredDescriptor(for: rawValue)?.audio.supportsMiniPlayerVisualization ?? false
    }

    public var defaultsMiniPlayerSpectrumOn: Bool {
        SkinRegistry.registeredDescriptor(for: rawValue)?.legacy?.defaultsMiniPlayerSpectrumOn ?? false
    }

    public var hasLedMeter: Bool {
        SkinRegistry.registeredDescriptor(for: rawValue)?.audio.hasLedMeter ?? false
    }
}

/// Resolved configuration - guaranteed to be valid per mutual exclusivity rules
public struct FullscreenPresentationConfiguration: Equatable, Codable {
    public let skinID: String
    public let visualizerMode: FullscreenVisualizerMode

    public var isMiniPlayerSpectrumEnabled: Bool {
        visualizerMode == .miniPlayerSpectrum
    }

    public var isMiniPlayerLEDEnabled: Bool {
        visualizerMode == .miniPlayerLED
    }

    public var miniPlayerVisualization: AudioVisualizationKind {
        switch visualizerMode {
        case .miniPlayerSpectrum: return .spectrum
        case .miniPlayerLED: return .led
        case .off, .skinVisualizer: return .off
        }
    }

    public var isSkinVisualizerEnabled: Bool {
        visualizerMode == .skinVisualizer
    }

    public var isAnyVisualizerEnabled: Bool {
        visualizerMode != .off
    }

    public init(skinID: String, visualizerMode: FullscreenVisualizerMode) {
        let descriptor = SkinRegistry.fullscreenSkin(for: skinID).descriptor
        self.skinID = descriptor.id
        let unsupported = ((visualizerMode == .miniPlayerSpectrum || visualizerMode == .miniPlayerLED)
            && !descriptor.audio.supportsMiniPlayerVisualization)
            || (visualizerMode == .skinVisualizer && !descriptor.audio.supportsEmbeddedVisualizer)
        self.visualizerMode = unsupported ? .off : visualizerMode
    }

    public init(fromLegacy skinID: String, miniPlayerSpectrum: Bool, skinVisualizerEnabled: Bool) {
        let effectiveVisualizerMode: FullscreenVisualizerMode

        if miniPlayerSpectrum {
            effectiveVisualizerMode = .miniPlayerSpectrum
        } else if skinVisualizerEnabled {
            effectiveVisualizerMode = .skinVisualizer
        } else {
            effectiveVisualizerMode = .off
        }

        self.init(skinID: skinID, visualizerMode: effectiveVisualizerMode)
    }
}

// MARK: - Coordinator

/// Central coordinator for fullscreen presentation settings.
@Observable
@MainActor
public final class FullscreenPresentationCoordinator {

    public static let shared = FullscreenPresentationCoordinator()

    private enum Keys {
        static let configuration = "fullscreenPresentationConfiguration_v2"
        static let skinID = "fullscreenSkin"
        static let miniPlayerSpectrumEnabled = "miniPlayerSpectrumEnabled"
        static let userExplicitlyDisabledMiniPlayerSpectrum = "userExplicitlyDisabledMiniPlayerSpectrum_v1"
    }

    @ObservationIgnored
    private var _configuration: FullscreenPresentationConfiguration?

    public var configuration: FullscreenPresentationConfiguration {
        get {
            access(keyPath: \.configuration)
            if let cached = _configuration {
                return cached
            }
            let resolved = loadConfiguration()
            _configuration = resolved
            return resolved
        }
    }

    private func updateConfiguration(_ newValue: FullscreenPresentationConfiguration) {
        withMutation(keyPath: \.configuration) {
            _configuration = newValue
            saveConfiguration(newValue)
            syncLegacySettings(newValue)
            persistSelection(newValue)
        }
        TelemetryService.shared.updateSkinState()
    }

    public var skinID: String { configuration.skinID }
    public var visualizerMode: FullscreenVisualizerMode { configuration.visualizerMode }
    public var isMiniPlayerSpectrumEnabled: Bool { configuration.isMiniPlayerSpectrumEnabled }
    public var isMiniPlayerLEDEnabled: Bool { configuration.isMiniPlayerLEDEnabled }
    public var miniPlayerVisualization: AudioVisualizationKind { configuration.miniPlayerVisualization }
    public var isSkinVisualizerEnabled: Bool { configuration.isSkinVisualizerEnabled }

    private init() {
        migrateAndNormalize()
    }

    public func setSkinID(_ skinID: String) {
        let currentConfig = configuration
        let previousID = currentConfig.skinID
        guard previousID != skinID else { return }

        let selection = AudioVisualizationPreferences.shared.selection(for: skinID, scope: .fullscreen)
        let targetVisualizerMode = Self.mode(for: selection)
        AudioVisualizationPreferences.shared.synchronizeLegacyState(for: skinID, scope: .fullscreen)

        let proposed = FullscreenPresentationConfiguration(
            skinID: skinID,
            visualizerMode: targetVisualizerMode
        )
        updateConfiguration(applyingMiniPlayerSpectrumDefaultIfNeeded(to: proposed))
    }

    public func setVisualizerMode(_ mode: FullscreenVisualizerMode) {
        let currentConfig = configuration

        updateConfiguration(FullscreenPresentationConfiguration(
            skinID: currentConfig.skinID,
            visualizerMode: mode
        ))
    }

    public func setMiniPlayerVisualization(_ kind: AudioVisualizationKind) {
        AudioVisualizationPreferences.shared.setMiniPlayerKind(
            kind,
            for: configuration.skinID,
            scope: .fullscreen
        )
        setVisualizerMode(Self.mode(for: .miniPlayer(kind)))
    }

    public func setSkinVisualizer(_ kind: AudioVisualizationKind) {
        AudioVisualizationPreferences.shared.setSkinKind(
            kind,
            for: configuration.skinID,
            scope: .fullscreen
        )
        setVisualizerMode(kind == .off ? .off : .skinVisualizer)
    }

    public var skinVisualizerKind: AudioVisualizationKind {
        AudioVisualizationPreferences.shared.selection(
            for: configuration.skinID,
            scope: .fullscreen
        ).skinKind
    }

    public func toggleMiniPlayerSpectrum() {
        let currentConfig = configuration

        if currentConfig.isMiniPlayerSpectrumEnabled {
            if SkinRegistry.registeredDescriptor(for: currentConfig.skinID)?.audio.supportsMiniPlayerVisualization == true {
                UserDefaults.standard.set(true, forKey: Keys.userExplicitlyDisabledMiniPlayerSpectrum)
            }
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: currentConfig.skinID,
                visualizerMode: .off
            ))
        } else {
            UserDefaults.standard.set(false, forKey: Keys.userExplicitlyDisabledMiniPlayerSpectrum)
            // Mutual exclusion: enabling MiniPlayer spectrum must clear the
            // current skin's embedded visualizer so both don't display.
            clearSkinVisualizer(for: currentConfig.skinID)
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: currentConfig.skinID,
                visualizerMode: .miniPlayerSpectrum
            ))
        }
    }

    public func disableMiniPlayerSpectrumForExplicitUserChoice() {
        UserDefaults.standard.set(true, forKey: Keys.userExplicitlyDisabledMiniPlayerSpectrum)
        updateConfiguration(FullscreenPresentationConfiguration(
            skinID: configuration.skinID,
            visualizerMode: .off
        ))
    }

    public func toggleSkinVisualizer() {
        let currentConfig = configuration

        if currentConfig.isSkinVisualizerEnabled {
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: currentConfig.skinID,
                visualizerMode: .off
            ))
        } else {
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: currentConfig.skinID,
                visualizerMode: .skinVisualizer
            ))
        }
    }

    @discardableResult
    public func normalizeConfiguration() -> FullscreenPresentationConfiguration {
        let current = configuration
        let normalized = applyingMiniPlayerSpectrumDefaultIfNeeded(
            to: FullscreenPresentationConfiguration(
                skinID: current.skinID,
                visualizerMode: current.visualizerMode
            )
        )
        if normalized != current {
            updateConfiguration(normalized)
        } else {
            saveConfiguration(normalized)
            syncLegacySettings(normalized)
        }
        return normalized
    }

    private func loadConfiguration() -> FullscreenPresentationConfiguration {
        if let data = UserDefaults.standard.data(forKey: Keys.configuration),
           let config = try? JSONDecoder().decode(FullscreenPresentationConfiguration.self, from: data) {
            let legacySelection: AudioVisualizationPlacement
            switch config.visualizerMode {
            case .off:
                legacySelection = .off
            case .miniPlayerSpectrum:
                legacySelection = .miniPlayerSpectrum
            case .miniPlayerLED:
                legacySelection = .miniPlayerLED
            case .skinVisualizer:
                let kind = legacySkinVisualizerKind(for: config.skinID)
                legacySelection = .skin(kind == .off ? .led : kind)
            }
            AudioVisualizationPreferences.shared.migrateSelectionIfNeeded(
                legacySelection,
                for: config.skinID,
                scope: .fullscreen
            )
            let selection = AudioVisualizationPreferences.shared.selection(
                for: config.skinID,
                scope: .fullscreen
            )
            return FullscreenPresentationConfiguration(
                skinID: config.skinID,
                visualizerMode: Self.mode(for: selection)
            )
        }
        return loadLegacyConfiguration()
    }

    private func loadLegacyConfiguration() -> FullscreenPresentationConfiguration {
        let skinID = UserDefaults.standard.string(forKey: Keys.skinID) ?? "coverLed"
        let selection = AudioVisualizationPreferences.shared.selection(
            for: skinID,
            scope: .fullscreen
        )
        return FullscreenPresentationConfiguration(
            skinID: skinID,
            visualizerMode: Self.mode(for: selection)
        )
    }

    private func applyingMiniPlayerSpectrumDefaultIfNeeded(
        to config: FullscreenPresentationConfiguration
    ) -> FullscreenPresentationConfiguration {
        config
    }

    private func clearSkinVisualizer(for skinID: String) {
        guard let descriptor = SkinRegistry.registeredDescriptor(for: skinID),
              descriptor.audio.hasLedMeter || descriptor.audio.supportsEmbeddedVisualizer else { return }
        UserDefaults.standard.set("off", forKey: visualizerKey(for: descriptor))
    }

    private func legacySkinVisualizerKind(for skinID: String) -> AudioVisualizationKind {
        guard let descriptor = SkinRegistry.registeredDescriptor(for: skinID),
              descriptor.audio.hasLedMeter || descriptor.audio.supportsEmbeddedVisualizer else { return .off }
        return AudioVisualizationKind(rawValue: UserDefaults.standard.string(forKey: visualizerKey(for: descriptor)) ?? "off") ?? .off
    }

    private func visualizerKey(for descriptor: SkinDescriptor) -> String {
        descriptor.legacy?.visualizerKey(scope: .fullscreen)
            ?? "skin.\(descriptor.id).fullscreen.visualizerMode"
    }

    private func saveConfiguration(_ config: FullscreenPresentationConfiguration) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Keys.configuration)
        }
    }

    private func syncLegacySettings(_ config: FullscreenPresentationConfiguration) {
        UserDefaults.standard.set(config.skinID, forKey: Keys.skinID)
        UserDefaults.standard.set(config.isMiniPlayerSpectrumEnabled, forKey: Keys.miniPlayerSpectrumEnabled)

        if config.isMiniPlayerSpectrumEnabled {
            clearSkinVisualizer(for: config.skinID)
        }

        if config.isSkinVisualizerEnabled,
           let descriptor = SkinRegistry.registeredDescriptor(for: config.skinID),
           let activationKind = descriptor.legacy?.visualizerActivationKind {
            let key = visualizerKey(for: descriptor)
            if (UserDefaults.standard.string(forKey: key) ?? "off") == "off" {
                UserDefaults.standard.set(activationKind.rawValue, forKey: key)
            }
        }
    }

    private func persistSelection(_ config: FullscreenPresentationConfiguration) {
        switch config.visualizerMode {
        case .off:
            AudioVisualizationPreferences.shared.setMiniPlayerKind(
                .off,
                for: config.skinID,
                scope: .fullscreen
            )
        case .miniPlayerSpectrum:
            AudioVisualizationPreferences.shared.setMiniPlayerKind(
                .spectrum,
                for: config.skinID,
                scope: .fullscreen
            )
        case .miniPlayerLED:
            AudioVisualizationPreferences.shared.setMiniPlayerKind(
                .led,
                for: config.skinID,
                scope: .fullscreen
            )
        case .skinVisualizer:
            let kind = AudioVisualizationPreferences.shared.selection(
                for: config.skinID,
                scope: .fullscreen
            ).skinKind
            AudioVisualizationPreferences.shared.setSkinKind(
                kind == .off ? .led : kind,
                for: config.skinID,
                scope: .fullscreen
            )
        }
    }

    private static func mode(for selection: AudioVisualizationPlacement) -> FullscreenVisualizerMode {
        switch selection {
        case .off: return .off
        case .skinSpectrum, .skinLED: return .skinVisualizer
        case .miniPlayerSpectrum: return .miniPlayerSpectrum
        case .miniPlayerLED: return .miniPlayerLED
        }
    }

    private func migrateAndNormalize() {
        _ = normalizeConfiguration()
    }

    public func validateOnStartup() {
        _ = normalizeConfiguration()
    }

    public func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Keys.userExplicitlyDisabledMiniPlayerSpectrum)
        updateConfiguration(FullscreenPresentationConfiguration(
            skinID: "coverLed",
            visualizerMode: .skinVisualizer
        ))
    }
}

// MARK: - Convenience Extensions

public extension AppSettings {
    var fullscreenPresentation: FullscreenPresentationCoordinator {
        FullscreenPresentationCoordinator.shared
    }
}

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
    case skinVisualizer = "skinVisualizer"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .miniPlayerSpectrum: return "MiniPlayer 频谱"
        case .skinVisualizer: return "全屏皮肤频谱"
        }
    }
}

/// Fullscreen skin identifier
public enum FullscreenSkinID: String, CaseIterable, Identifiable {
    case coverLed = "coverLed"
    case appleStyle = "appleStyle"
    case kmgcccCassette = "kmgccc.cassette"
    case rotatingCover = "rotatingCover"
    case coverGradientBlur = "fullscreen.coverGradientBlur"

    public var id: String { rawValue }

    public var supportsEmbeddedVisualizer: Bool {
        switch self {
        case .coverLed, .appleStyle, .rotatingCover: return true
        case .kmgcccCassette: return false
        case .coverGradientBlur: return false
        }
    }

    public var supportsMiniPlayerSpectrum: Bool {
        switch self {
        case .coverLed, .appleStyle, .rotatingCover, .coverGradientBlur, .kmgcccCassette: return true
        }
    }

    public var defaultsMiniPlayerSpectrumOn: Bool {
        switch self {
        case .coverGradientBlur, .kmgcccCassette: return true
        case .coverLed, .appleStyle, .rotatingCover: return false
        }
    }

    /// Whether this skin renders an audio LED meter as part of its decoration.
    /// LED is a peer of spectrum: it should be driven by the skin identity,
    /// not by the visualizerMode toggle.
    public var hasLedMeter: Bool {
        switch self {
        case .coverLed: return true
        case .appleStyle: return true
        case .kmgcccCassette: return true
        case .rotatingCover: return true
        case .coverGradientBlur: return false
        }
    }
}

/// Resolved configuration - guaranteed to be valid per mutual exclusivity rules
public struct FullscreenPresentationConfiguration: Equatable, Codable {
    public let skinID: String
    public let visualizerMode: FullscreenVisualizerMode

    public var isMiniPlayerSpectrumEnabled: Bool {
        visualizerMode == .miniPlayerSpectrum
    }

    public var isSkinVisualizerEnabled: Bool {
        visualizerMode == .skinVisualizer
    }

    public var isAnyVisualizerEnabled: Bool {
        visualizerMode != .off
    }

    public init(skinID: String, visualizerMode: FullscreenVisualizerMode) {
        let normalizedSkinID = FullscreenSkinID(rawValue: skinID)?.rawValue ?? "coverLed"

        if let skin = FullscreenSkinID(rawValue: normalizedSkinID) {
            switch visualizerMode {
            case .miniPlayerSpectrum:
                if !skin.supportsMiniPlayerSpectrum {
                    self.skinID = "coverLed"
                    self.visualizerMode = .miniPlayerSpectrum
                } else {
                    self.skinID = normalizedSkinID
                    self.visualizerMode = .miniPlayerSpectrum
                }

            case .skinVisualizer:
                if !skin.supportsEmbeddedVisualizer {
                    self.skinID = normalizedSkinID
                    self.visualizerMode = .off
                } else {
                    self.skinID = normalizedSkinID
                    self.visualizerMode = .skinVisualizer
                }

            case .off:
                self.skinID = normalizedSkinID
                self.visualizerMode = .off
            }
        } else {
            self.skinID = "coverLed"
            self.visualizerMode = .off
        }
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
        static let classicLEDVisualizer = "skin.classicLED.fullscreen.visualizerMode"
        static let appleStyleVisualizer = "skin.appleStyle.fullscreen.visualizerMode"
        static let kmgcccCassetteVisualizer = "skin.kmgcccCassette.fullscreen.visualizerMode"
        static let rotatingCoverVisualizer = "skin.rotatingCover.fullscreen.visualizerMode"
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
        }
        TelemetryService.shared.updateSkinState()
    }

    public var skinID: String { configuration.skinID }
    public var visualizerMode: FullscreenVisualizerMode { configuration.visualizerMode }
    public var isMiniPlayerSpectrumEnabled: Bool { configuration.isMiniPlayerSpectrumEnabled }
    public var isSkinVisualizerEnabled: Bool { configuration.isSkinVisualizerEnabled }

    private init() {
        migrateAndNormalize()
    }

    public func setSkinID(_ skinID: String) {
        let currentConfig = configuration
        let previousID = currentConfig.skinID
        let proposed = FullscreenPresentationConfiguration(
            skinID: skinID,
            visualizerMode: currentConfig.visualizerMode
        )
        updateConfiguration(applyingMiniPlayerSpectrumDefaultIfNeeded(to: proposed))
        applyFullscreenSkinEntryDefaults(previous: previousID, new: skinID)
    }

    /// Apply one-shot fullscreen LED defaults on a real skin transition. Mirrors
    /// `AppSettings.applySkinEntryDefaults` for the fullscreen-side settings keys.
    /// - Only fires when previous != new (so init / cold start never trigger).
    /// - Cassette is intentionally left untouched.
    /// - User toggles inside the same skin persist (no transition fires while
    ///   the skin stays the same).
    /// - Switching out and back DOES re-apply the default — matches the user
    ///   spec "切出再切回 Classic / RotatingCover 默认再次开 LED".
    private func applyFullscreenSkinEntryDefaults(previous: String, new: String) {
        guard previous != new else { return }
        let defaults = UserDefaults.standard
        switch new {
        case FullscreenSkinID.coverLed.rawValue:
            defaults.set("led", forKey: Keys.classicLEDVisualizer)
            setVisualizerMode(.skinVisualizer)
        case FullscreenSkinID.appleStyle.rawValue:
            defaults.set("led", forKey: Keys.appleStyleVisualizer)
            setVisualizerMode(.skinVisualizer)
        case FullscreenSkinID.rotatingCover.rawValue:
            defaults.set("led", forKey: Keys.rotatingCoverVisualizer)
            defaults.set(true, forKey: "skin.rotatingCover.cdMode")
            setVisualizerMode(.skinVisualizer)
        default:
            break
        }
    }

    public func setVisualizerMode(_ mode: FullscreenVisualizerMode) {
        let currentConfig = configuration

        updateConfiguration(FullscreenPresentationConfiguration(
            skinID: currentConfig.skinID,
            visualizerMode: mode
        ))
    }

    public func toggleMiniPlayerSpectrum() {
        let currentConfig = configuration

        if currentConfig.isMiniPlayerSpectrumEnabled {
            if let skin = FullscreenSkinID(rawValue: currentConfig.skinID),
               skin.supportsMiniPlayerSpectrum {
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
            let normalized = FullscreenPresentationConfiguration(
                skinID: config.skinID,
                visualizerMode: config.visualizerMode
            )
            return applyingMiniPlayerSpectrumDefaultIfNeeded(to: normalized)
        }
        return loadLegacyConfiguration()
    }

    private func loadLegacyConfiguration() -> FullscreenPresentationConfiguration {
        let skinID = UserDefaults.standard.string(forKey: Keys.skinID) ?? "fullscreen.coverGradientBlur"
        let hasExplicitMiniPlayerSpectrum = UserDefaults.standard.object(forKey: Keys.miniPlayerSpectrumEnabled) != nil
        let miniPlayerSpectrum = hasExplicitMiniPlayerSpectrum
            ? shouldUseLegacyMiniPlayerSpectrumValue(for: skinID)
            : shouldDefaultMiniPlayerSpectrumOn(for: skinID)
        let classicMode = UserDefaults.standard.string(forKey: Keys.classicLEDVisualizer) ?? "off"
        let appleStyleMode = UserDefaults.standard.string(forKey: Keys.appleStyleVisualizer) ?? "off"
        let cassetteMode = UserDefaults.standard.string(forKey: Keys.kmgcccCassetteVisualizer) ?? "off"
        let rotatingMode = UserDefaults.standard.string(forKey: Keys.rotatingCoverVisualizer) ?? "off"
        let skinVisualizerEnabled = classicMode != "off"
            || appleStyleMode != "off"
            || cassetteMode != "off"
            || rotatingMode != "off"

        return FullscreenPresentationConfiguration(
            fromLegacy: skinID,
            miniPlayerSpectrum: miniPlayerSpectrum,
            skinVisualizerEnabled: skinVisualizerEnabled
        )
    }

    private func applyingMiniPlayerSpectrumDefaultIfNeeded(
        to config: FullscreenPresentationConfiguration
    ) -> FullscreenPresentationConfiguration {
        guard config.visualizerMode == .off,
              shouldDefaultMiniPlayerSpectrumOn(for: config.skinID) else {
            return config
        }
        return FullscreenPresentationConfiguration(
            skinID: config.skinID,
            visualizerMode: .miniPlayerSpectrum
        )
    }

    private func shouldDefaultMiniPlayerSpectrumOn(for skinID: String) -> Bool {
        guard let skin = FullscreenSkinID(rawValue: skinID),
              skin.supportsMiniPlayerSpectrum,
              skin.defaultsMiniPlayerSpectrumOn else {
            return false
        }
        return !UserDefaults.standard.bool(forKey: Keys.userExplicitlyDisabledMiniPlayerSpectrum)
    }

    private func shouldUseLegacyMiniPlayerSpectrumValue(for skinID: String) -> Bool {
        if shouldDefaultMiniPlayerSpectrumOn(for: skinID) {
            return true
        }
        return UserDefaults.standard.bool(forKey: Keys.miniPlayerSpectrumEnabled)
    }

    private func clearSkinVisualizer(for skinID: String) {
        guard let skin = FullscreenSkinID(rawValue: skinID) else { return }
        switch skin {
        case .coverLed:
            UserDefaults.standard.set("off", forKey: Keys.classicLEDVisualizer)
        case .appleStyle:
            UserDefaults.standard.set("off", forKey: Keys.appleStyleVisualizer)
        case .rotatingCover:
            UserDefaults.standard.set("off", forKey: Keys.rotatingCoverVisualizer)
        case .kmgcccCassette:
            UserDefaults.standard.set("off", forKey: Keys.kmgcccCassetteVisualizer)
        case .coverGradientBlur:
            break
        }
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

        if let skin = FullscreenSkinID(rawValue: config.skinID) {
            switch skin {
            case .rotatingCover:
                // The "spectrum" sub-mode is only meaningful when the skin is
                // currently active; keep this single legacy bridge so the
                // existing skin-visualizer toggle still produces a value the
                // skin can read. LED keys are NOT touched here — they belong
                // to user settings + transition defaults.
                if config.isSkinVisualizerEnabled {
                    let existingMode = UserDefaults.standard.string(forKey: Keys.rotatingCoverVisualizer) ?? "off"
                    if existingMode == "off" {
                        UserDefaults.standard.set("spectrum", forKey: Keys.rotatingCoverVisualizer)
                    }
                }

            case .coverLed, .appleStyle, .kmgcccCassette, .coverGradientBlur:
                break
            }
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
            skinID: "fullscreen.coverGradientBlur",
            visualizerMode: .miniPlayerSpectrum
        ))
    }
}

// MARK: - Convenience Extensions

public extension AppSettings {
    var fullscreenPresentation: FullscreenPresentationCoordinator {
        FullscreenPresentationCoordinator.shared
    }
}

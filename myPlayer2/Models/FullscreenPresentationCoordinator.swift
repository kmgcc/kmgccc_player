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
    case kmgcccCassette = "kmgccc.cassette"
    case rotatingCover = "rotatingCover"
    case coverGradientBlur = "fullscreen.coverGradientBlur"

    public var id: String { rawValue }

    public var supportsEmbeddedVisualizer: Bool {
        switch self {
        case .coverLed, .rotatingCover: return true
        case .kmgcccCassette: return false
        case .coverGradientBlur: return false
        }
    }

    public var supportsMiniPlayerSpectrum: Bool {
        switch self {
        case .coverLed, .rotatingCover, .coverGradientBlur: return true
        case .kmgcccCassette: return false
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
        static let kmgcccCassetteVisualizer = "skin.kmgcccCassette.fullscreen.visualizerMode"
        static let rotatingCoverVisualizer = "skin.rotatingCover.fullscreen.visualizerMode"
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

        if skinID == "kmgccc.cassette" && currentConfig.isMiniPlayerSpectrumEnabled {
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: skinID,
                visualizerMode: .off
            ))
            return
        }

        updateConfiguration(FullscreenPresentationConfiguration(
            skinID: skinID,
            visualizerMode: currentConfig.visualizerMode
        ))
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
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: currentConfig.skinID,
                visualizerMode: .off
            ))
        } else {
            updateConfiguration(FullscreenPresentationConfiguration(
                skinID: currentConfig.skinID,
                visualizerMode: .miniPlayerSpectrum
            ))
        }
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
        let normalized = FullscreenPresentationConfiguration(
            skinID: current.skinID,
            visualizerMode: current.visualizerMode
        )
        if normalized != current {
            updateConfiguration(normalized)
        }
        return normalized
    }

    private func loadConfiguration() -> FullscreenPresentationConfiguration {
        if let data = UserDefaults.standard.data(forKey: Keys.configuration),
           let config = try? JSONDecoder().decode(FullscreenPresentationConfiguration.self, from: data) {
            return config
        }
        return loadLegacyConfiguration()
    }

    private func loadLegacyConfiguration() -> FullscreenPresentationConfiguration {
        let skinID = UserDefaults.standard.string(forKey: Keys.skinID) ?? "fullscreen.coverGradientBlur"
        let hasExplicitMiniPlayerSpectrum = UserDefaults.standard.object(forKey: Keys.miniPlayerSpectrumEnabled) != nil
        let miniPlayerSpectrum = hasExplicitMiniPlayerSpectrum
            ? UserDefaults.standard.bool(forKey: Keys.miniPlayerSpectrumEnabled)
            : true
        let classicMode = UserDefaults.standard.string(forKey: Keys.classicLEDVisualizer) ?? "off"
        let cassetteMode = UserDefaults.standard.string(forKey: Keys.kmgcccCassetteVisualizer) ?? "off"
        let rotatingMode = UserDefaults.standard.string(forKey: Keys.rotatingCoverVisualizer) ?? "off"
        let skinVisualizerEnabled = classicMode != "off" || cassetteMode != "off" || rotatingMode != "off"

        return FullscreenPresentationConfiguration(
            fromLegacy: skinID,
            miniPlayerSpectrum: miniPlayerSpectrum,
            skinVisualizerEnabled: skinVisualizerEnabled
        )
    }

    private func saveConfiguration(_ config: FullscreenPresentationConfiguration) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Keys.configuration)
        }
    }

    private func syncLegacySettings(_ config: FullscreenPresentationConfiguration) {
        UserDefaults.standard.set(config.skinID, forKey: Keys.skinID)
        UserDefaults.standard.set(config.isMiniPlayerSpectrumEnabled, forKey: Keys.miniPlayerSpectrumEnabled)

        if let skin = FullscreenSkinID(rawValue: config.skinID) {
            switch skin {
            case .coverLed:
                if config.isSkinVisualizerEnabled {
                    // Preserve existing mode if already set (led or spectrum)
                    let existingMode = UserDefaults.standard.string(forKey: Keys.classicLEDVisualizer) ?? "off"
                    if existingMode == "off" {
                        UserDefaults.standard.set("led", forKey: Keys.classicLEDVisualizer)
                    }
                } else {
                    UserDefaults.standard.set("off", forKey: Keys.classicLEDVisualizer)
                }
                UserDefaults.standard.set("off", forKey: Keys.kmgcccCassetteVisualizer)
                UserDefaults.standard.set("off", forKey: Keys.rotatingCoverVisualizer)

            case .kmgcccCassette:
                UserDefaults.standard.set("off", forKey: Keys.classicLEDVisualizer)
                UserDefaults.standard.set("off", forKey: Keys.kmgcccCassetteVisualizer)
                UserDefaults.standard.set("off", forKey: Keys.rotatingCoverVisualizer)

            case .rotatingCover:
                if config.isSkinVisualizerEnabled {
                    let existingMode = UserDefaults.standard.string(forKey: Keys.rotatingCoverVisualizer) ?? "off"
                    if existingMode == "off" {
                        UserDefaults.standard.set("spectrum", forKey: Keys.rotatingCoverVisualizer)
                    }
                } else {
                    UserDefaults.standard.set("off", forKey: Keys.rotatingCoverVisualizer)
                }
                UserDefaults.standard.set("off", forKey: Keys.classicLEDVisualizer)
                UserDefaults.standard.set("off", forKey: Keys.kmgcccCassetteVisualizer)

            case .coverGradientBlur:
                UserDefaults.standard.set("off", forKey: Keys.classicLEDVisualizer)
                UserDefaults.standard.set("off", forKey: Keys.kmgcccCassetteVisualizer)
                UserDefaults.standard.set("off", forKey: Keys.rotatingCoverVisualizer)
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
        updateConfiguration(FullscreenPresentationConfiguration(
            skinID: "fullscreen.coverGradientBlur",
            visualizerMode: .off
        ))
    }
}

// MARK: - Convenience Extensions

public extension AppSettings {
    var fullscreenPresentation: FullscreenPresentationCoordinator {
        FullscreenPresentationCoordinator.shared
    }
}
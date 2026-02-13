//
//  AppSettings.swift
//  myPlayer2
//
//  kmgccc_player - App Settings Model
//  Uses AppStorage for persistent user preferences.
//

import Foundation
import SwiftUI

/// Observable app settings using AppStorage for persistence.
/// Observable app settings using AppStorage for persistence.
@Observable
public final class AppSettings {

    // MARK: - Singleton

    public static let shared = AppSettings()

    // MARK: - Localization Settings

    enum Language: String, CaseIterable {
        case auto
        case en
        case zhHans = "zh-Hans"

        var title: String {
            switch self {
            case .auto: return NSLocalizedString("settings.language.auto", comment: "")
            case .en: return NSLocalizedString("settings.language.en", comment: "")
            case .zhHans: return NSLocalizedString("settings.language.zh", comment: "")
            }
        }

        var locale: Locale {
            switch self {
            case .en: return Locale(identifier: "en")
            case .zhHans: return Locale(identifier: "zh-Hans")
            case .auto:
                // Use the first preferred localization if possible, or current system locale
                if let preferred = Bundle.main.preferredLocalizations.first {
                    return Locale(identifier: preferred)
                }
                return .current
            }
        }
    }

    @ObservationIgnored
    private let _languageStore = UserDefaults.standard

    var language: Language {
        get {
            access(keyPath: \.language)
            return Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "")
                ?? .auto
        }
        set {
            withMutation(keyPath: \.language) {
                UserDefaults.standard.set(newValue.rawValue, forKey: "language")
            }
        }
    }

    // MARK: - Audio Settings

    /// Master volume (0.0 to 1.0)
    @ObservationIgnored
    @AppStorage("volume") var volume: Double = 0.8

    // MARK: - LED Meter Settings

    /// Number of LEDs (default 11)
    @ObservationIgnored
    @AppStorage("ledCount") var ledCount: Int = 13

    /// Brightness levels per LED (default 5)
    @ObservationIgnored
    @AppStorage("ledBrightnessLevels") var ledBrightnessLevels: Int = 3

    /// LED sensitivity (0.5 to 2.0, default 1.0)
    @ObservationIgnored
    @AppStorage("ledSensitivity") private var _ledSensitivity: Double = 2.3

    var ledSensitivity: Float {
        get { Float(_ledSensitivity) }
        set { _ledSensitivity = Double(newValue) }
    }

    /// LED cutoff frequency (Hz)
    @ObservationIgnored
    @AppStorage("ledCutoffHz") var ledCutoffHz: Double = 900

    /// LED pre-gain (0.25 to 8.0)
    @ObservationIgnored
    @AppStorage("ledPreGain") var ledPreGain: Double = 0.35

    /// LED response speed (0.5 to 2.0)
    @ObservationIgnored
    @AppStorage("ledSpeed") var ledSpeed: Double = 1.4

    /// LED publish rate (Hz): 30 or 60
    @ObservationIgnored
    @AppStorage("ledTargetHz") var ledTargetHz: Int = 30

    /// Threshold to trigger transient boost (dB above average)
    @ObservationIgnored
    @AppStorage("ledTransientThreshold") var ledTransientThreshold: Double = 12.0

    /// Intensity of the transient boost effect (0.0 to 4.0)
    @ObservationIgnored
    @AppStorage("ledTransientIntensity") var ledTransientIntensity: Double = 4.0

    /// Transient cutoff frequency for LED meter (Hz)
    @ObservationIgnored
    @AppStorage("ledTransientCutoffHz") var ledTransientCutoffHz: Double = 60.0

    /// Master switch for LED meter sampling/analysis.
    @ObservationIgnored
    @AppStorage("ledMeterEnabled") var ledMeterEnabled: Bool = true

    // MARK: - Appearance Settings

    enum AppearanceMode: String, CaseIterable {
        case system
        case light
        case dark
    }

    enum ManualAppearance: String, CaseIterable {
        case light
        case dark
    }

    private enum AppearanceKeys {
        static let globalArtworkTintEnabled = "globalArtworkTintEnabled"
        static let followSystemAppearance = "followSystemAppearance"
        static let manualAppearance = "manualAppearance"
    }

    /// Whether global accent/tint follows current artwork dominant color.
    var globalArtworkTintEnabled: Bool {
        get {
            access(keyPath: \.globalArtworkTintEnabled)
            if UserDefaults.standard.object(forKey: AppearanceKeys.globalArtworkTintEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AppearanceKeys.globalArtworkTintEnabled)
        }
        set {
            withMutation(keyPath: \.globalArtworkTintEnabled) {
                UserDefaults.standard.set(
                    newValue,
                    forKey: AppearanceKeys.globalArtworkTintEnabled
                )
            }
        }
    }

    /// Whether app appearance follows system (true => preferredColorScheme(nil)).
    var followSystemAppearance: Bool {
        get {
            access(keyPath: \.followSystemAppearance)
            if UserDefaults.standard.object(forKey: AppearanceKeys.followSystemAppearance) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AppearanceKeys.followSystemAppearance)
        }
        set {
            withMutation(keyPath: \.followSystemAppearance) {
                UserDefaults.standard.set(
                    newValue,
                    forKey: AppearanceKeys.followSystemAppearance
                )
            }
        }
    }

    /// Manual appearance mode used only when followSystemAppearance == false.
    var manualAppearance: ManualAppearance {
        get {
            access(keyPath: \.manualAppearance)
            let raw = UserDefaults.standard.string(forKey: AppearanceKeys.manualAppearance)
                ?? ManualAppearance.dark.rawValue
            return ManualAppearance(rawValue: raw) ?? .dark
        }
        set {
            withMutation(keyPath: \.manualAppearance) {
                UserDefaults.standard.set(newValue.rawValue, forKey: AppearanceKeys.manualAppearance)
            }
        }
    }

    /// Backward-compatible appearance mode facade.
    var appearanceMode: AppearanceMode {
        get {
            if followSystemAppearance { return .system }
            return manualAppearance == .dark ? .dark : .light
        }
        set {
            switch newValue {
            case .system:
                followSystemAppearance = true
            case .light:
                followSystemAppearance = false
                manualAppearance = .light
            case .dark:
                followSystemAppearance = false
                manualAppearance = .dark
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
        }
    }

    /// Accent color hex string
    @ObservationIgnored
    @AppStorage("accentColorHex") var accentColorHex: String = "#007AFF"

    /// Liquid Glass intensity (0.0 to 1.0)
    @ObservationIgnored
    @AppStorage("liquidGlassIntensity") var liquidGlassIntensity: Double = 1.0

    // MARK: - AMLL Settings

    /// AMLL configuration as JSON string
    @ObservationIgnored
    @AppStorage("amllConfigJSON") var amllConfigJSON: String = "{}"

    /// Lyrics font name
    @ObservationIgnored
    @AppStorage("lyricsFontName") var lyricsFontName: String = "SF Pro"

    /// Lyrics font name (Chinese/CJK)
    @ObservationIgnored
    @AppStorage("lyricsFontNameZh") var lyricsFontNameZh: String = "PingFang SC"

    /// Lyrics font name (Latin/English)
    @ObservationIgnored
    @AppStorage("lyricsFontNameEn") var lyricsFontNameEn: String = "SF Pro Text"

    /// Translation font name
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontName") var lyricsTranslationFontName: String = "SF Pro Text"

    /// Translation font size
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontSize") var lyricsTranslationFontSize: Double = 12.0

    /// Translation font weight in light mode (100~900)
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontWeightLight") var lyricsTranslationFontWeightLight: Int = 400

    /// Translation font weight in dark mode (100~900)
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontWeightDark") var lyricsTranslationFontWeightDark: Int = 100

    /// Lyrics font weight in light mode (100~900)
    @ObservationIgnored
    @AppStorage("lyricsFontWeightLight") var lyricsFontWeightLight: Int = 600

    /// Lyrics font weight in dark mode (100~900)
    @ObservationIgnored
    @AppStorage("lyricsFontWeightDark") var lyricsFontWeightDark: Int = 100

    /// Lyrics font size
    @ObservationIgnored
    @AppStorage("lyricsFontSize") var lyricsFontSize: Double = 24.0

    /// Lead-in milliseconds for next line start/word timing
    @ObservationIgnored
    @AppStorage("lyricsLeadInMs") var lyricsLeadInMs: Double = 240

    /// Now Playing skin identifier
    @ObservationIgnored
    @AppStorage("nowPlayingSkin") var nowPlayingSkin: String = "coverLed"

    /// Single source of truth for Now Playing skin.
    var selectedNowPlayingSkinID: String {
        get {
            access(keyPath: \.selectedNowPlayingSkinID)
            return nowPlayingSkin
        }
        set {
            withMutation(keyPath: \.selectedNowPlayingSkinID) {
                nowPlayingSkin = newValue
            }
        }
    }

    // MARK: - Playback Settings

    /// Lookahead delay in milliseconds (0-200). Delays audio output for LED lead.
    @ObservationIgnored
    @AppStorage("lookaheadMs") var lookaheadMs: Double = 200

    // MARK: - Now Playing Background Settings

    /// Enable BKArt animated background layer in Now Playing.
    @ObservationIgnored
    @AppStorage("nowPlayingArtBackgroundEnabled") var nowPlayingArtBackgroundEnabled: Bool = true

    /// Legacy background blur multiplier (kept for compatibility)
    @ObservationIgnored
    @AppStorage("nowPlayingBackgroundBlur") var nowPlayingBackgroundBlur: Double = 1.0

    /// Legacy background brightness offset (kept for compatibility)
    @ObservationIgnored
    @AppStorage("nowPlayingBackgroundBrightness") var nowPlayingBackgroundBrightness: Double = 0.0

    /// Legacy background saturation multiplier (kept for compatibility)
    @ObservationIgnored
    @AppStorage("nowPlayingBackgroundSaturation") var nowPlayingBackgroundSaturation: Double = 1.0

    /// Mesh motion amplitude
    @ObservationIgnored
    @AppStorage("nowPlayingMeshAmplitude") var nowPlayingMeshAmplitude: Double = 2.0

    /// Mesh flow speed
    @ObservationIgnored
    @AppStorage("nowPlayingMeshFlowSpeed") var nowPlayingMeshFlowSpeed: Double = 0.6

    /// Edge definition for mesh boundaries (soft -> sharp)
    @ObservationIgnored
    @AppStorage("nowPlayingMeshSharpness") var nowPlayingMeshSharpness: Double = 0.4

    /// Soft blur amount for mesh color transitions
    @ObservationIgnored
    @AppStorage("nowPlayingMeshSoftness") var nowPlayingMeshSoftness: Double = 1.0

    /// Saturation boost for artwork-derived mesh colors
    @ObservationIgnored
    @AppStorage("nowPlayingMeshColorBoost") var nowPlayingMeshColorBoost: Double = 1.8

    /// Contrast tuning for mesh regions
    @ObservationIgnored
    @AppStorage("nowPlayingMeshContrast") var nowPlayingMeshContrast: Double = 1.38

    /// Low-frequency impact multiplier for background pulse
    @ObservationIgnored
    @AppStorage("nowPlayingMeshBassImpact") var nowPlayingMeshBassImpact: Double = 0.7

    // MARK: - Now Playing Background Meter

    @ObservationIgnored
    @AppStorage("bgMeterCutoffHz") var bgMeterCutoffHz: Double = 1200

    @ObservationIgnored
    @AppStorage("bgMeterPreGain") var bgMeterPreGain: Double = 1.0

    @ObservationIgnored
    @AppStorage("bgMeterSensitivity") private var _bgMeterSensitivity: Double = 1.0

    var bgMeterSensitivity: Float {
        get { Float(_bgMeterSensitivity) }
        set { _bgMeterSensitivity = Double(newValue) }
    }

    @ObservationIgnored
    @AppStorage("bgMeterSpeed") var bgMeterSpeed: Double = 1.0

    @ObservationIgnored
    @AppStorage("bgMeterTargetHz") var bgMeterTargetHz: Int = 30

    @ObservationIgnored
    @AppStorage("bgMeterTransientThreshold") var bgMeterTransientThreshold: Double = 1.5

    @ObservationIgnored
    @AppStorage("bgMeterTransientIntensity") var bgMeterTransientIntensity: Double = 2.5

    @ObservationIgnored
    @AppStorage("bgMeterTransientCutoffHz") var bgMeterTransientCutoffHz: Double = 40.0

    // MARK: - Now Playing Background Dynamics (New)

    /// One-time migration flag from legacy bgMeter* keys.
    @ObservationIgnored
    @AppStorage("bgDynamicsMigrated") var bgDynamicsMigrated: Bool = false

    /// Low-band loudness cutoff (Hz).
    @ObservationIgnored
    @AppStorage("bgLowCutoffHz") var bgLowCutoffHz: Double = 650

    /// Low-band sensitivity (persisted as Double, exposed as Float for processors).
    @ObservationIgnored
    @AppStorage("bgLowSensitivity") private var _bgLowSensitivity: Double = 1.4

    var bgLowSensitivity: Float {
        get { Float(_bgLowSensitivity) }
        set { _bgLowSensitivity = Double(newValue) }
    }

    /// Low-band pre-boost (dB). Positive makes background respond earlier; negative makes it calmer.
    @ObservationIgnored
    @AppStorage("bgLowPreBoostDb") var bgLowPreBoostDb: Double = -0.5

    /// Low-band envelope timing (seconds).
    @ObservationIgnored
    @AppStorage("bgLowAttack") var bgLowAttack: Double = 0.18

    @ObservationIgnored
    @AppStorage("bgLowRelease") var bgLowRelease: Double = 0.50

    /// Kick (transient) cutoff (Hz).
    @ObservationIgnored
    @AppStorage("bgKickCutoffHz") var bgKickCutoffHz: Double = 39

    /// Kick trigger threshold (dB above baseline).
    @ObservationIgnored
    @AppStorage("bgKickThresholdDb") var bgKickThresholdDb: Double = 18.7

    /// Kick intensity multiplier.
    @ObservationIgnored
    @AppStorage("bgKickIntensity") var bgKickIntensity: Double = 4.0

    /// Kick envelope timing (seconds).
    @ObservationIgnored
    @AppStorage("bgKickAttack") var bgKickAttack: Double = 0.04

    @ObservationIgnored
    @AppStorage("bgKickRelease") var bgKickRelease: Double = 0.45

    /// Optional transient brightness overlay mix (0...0.80).
    @ObservationIgnored
    @AppStorage("bgKickToBrightnessMix") var bgKickToBrightnessMix: Double = 0.79

    /// Kick-driven mesh displacement amount (0...1).
    @ObservationIgnored
    @AppStorage("bgKickDisplaceAmount") var bgKickDisplaceAmount: Double = 0.84

    /// Kick-driven mesh scale amount (0...0.03).
    @ObservationIgnored
    @AppStorage("bgKickScaleAmount") var bgKickScaleAmount: Double = 0.03

    /// Quiet-track suppression mode: "off" | "mild" | "strong".
    @ObservationIgnored
    @AppStorage("bgQuietSuppressionMode") var bgQuietSuppressionMode: String = "mild"

    /// Shuffle enabled
    @ObservationIgnored
    @AppStorage("shuffleEnabled") var shuffleEnabled: Bool = false

    /// Repeat mode: "off", "all", "one"
    @ObservationIgnored
    @AppStorage("repeatMode") var repeatMode: String = "off"

    /// Pause playback after current song finishes (single-cycle stop mode).
    @ObservationIgnored
    @AppStorage("stopAfterTrack") var stopAfterTrack: Bool = false

    // MARK: - Private Init

    private init() {
        // Legacy migration from old `appearance` key.
        if UserDefaults.standard.object(forKey: "followSystemAppearance") == nil,
            let saved = UserDefaults.standard.string(forKey: "appearance"),
            let mode = AppearanceMode(rawValue: saved)
        {
            switch mode {
            case .system:
                followSystemAppearance = true
            case .light:
                followSystemAppearance = false
                manualAppearance = .light
            case .dark:
                followSystemAppearance = false
                manualAppearance = .dark
            }
        }
    }

    // MARK: - Computed Properties

    var colorScheme: ColorScheme? {
        followSystemAppearance ? nil : (manualAppearance == .dark ? .dark : .light)
    }

    var accentColor: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }

    // MARK: - Migrations

    /// Migrates legacy bgMeter* settings to the new bg* dynamics keys once.
    func migrateBackgroundDynamicsIfNeeded() {
        guard bgDynamicsMigrated == false else { return }

        // Map existing legacy values as a starting point.
        bgLowCutoffHz = bgMeterCutoffHz
        bgLowSensitivity = bgMeterSensitivity
        bgKickCutoffHz = bgMeterTransientCutoffHz
        bgKickThresholdDb = bgMeterTransientThreshold
        bgKickIntensity = bgMeterTransientIntensity

        // Derive default timing from legacy speed (faster speed -> shorter times).
        let speed = max(0.1, bgMeterSpeed)
        bgLowAttack = clamp(0.09 / speed, min: 0.05, max: 0.20)
        bgLowRelease = clamp(0.28 / speed, min: 0.15, max: 0.50)
        bgKickAttack = clamp(0.05 / speed, min: 0.02, max: 0.12)
        bgKickRelease = clamp(0.22 / speed, min: 0.12, max: 0.45)

        // New knobs default values.
        bgKickToBrightnessMix = 0.0
        bgKickDisplaceAmount = 1.0
        bgKickScaleAmount = 0.02
        bgQuietSuppressionMode = "strong"

        bgDynamicsMigrated = true
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(max, Swift.max(min, value))
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}

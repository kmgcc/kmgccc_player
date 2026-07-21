//
//  AppSettings.swift
//  myPlayer2
//
//  kmgccc_player - App Settings Model
//  Uses AppStorage for persistent user preferences.
//

import Foundation
import SwiftUI

enum PlaybackOrderMode: String, CaseIterable, Identifiable {
    case sequence
    case shuffle
    case repeatOne
    case stopAfterTrack

    var id: String { rawValue }
}

enum PlaybackStartPolicy: Equatable {
    case useSavedMode
    case forceSequentialTemporary
    case forceShuffleTemporary

    var isTemporaryOverride: Bool {
        switch self {
        case .useSavedMode:
            return false
        case .forceSequentialTemporary, .forceShuffleTemporary:
            return true
        }
    }

    func resolvedMode(settings: AppSettings = .shared) -> PlaybackOrderMode {
        switch self {
        case .useSavedMode:
            return settings.playbackOrderMode
        case .forceSequentialTemporary:
            return .sequence
        case .forceShuffleTemporary:
            return .shuffle
        }
    }
}

struct LyricSpringUserSettings: Equatable {
    var enabled: Bool
    var duration: Double
    var bounce: Double
}

/// Typography used by fullscreen lyrics.
///
/// The global fullscreen typography remains separate from the optional
/// per-skin profiles so switching that mode never destroys either set of
/// user-edited values.
struct FullscreenLyricsTypography: Codable, Equatable {
    var mainFontNameZh: String
    var mainFontNameEn: String
    var translationFontName: String
    var mainFontWeight: Int
    var translationFontWeight: Int
    var mainFontSize: Double
    var translationFontSize: Double

    static let defaultValue = FullscreenLyricsTypography(
        mainFontNameZh: LyricsFontDefaults.chinese,
        mainFontNameEn: LyricsFontDefaults.english,
        translationFontName: LyricsFontDefaults.translation,
        mainFontWeight: 700,
        translationFontWeight: 600,
        mainFontSize: 53,
        translationFontSize: 25
    )

    /// Readability-oriented defaults for the fullscreen skins with dedicated
    /// typography. The three cover/disc/cassette skins share one preset;
    /// Panorama follows the Apple-style font and size preset but uses an
    /// ultra-light weight.
    static func defaultValue(forFullscreenSkinID skinID: String) -> Self {
        switch skinID {
        case "coverLed", "rotatingCover", "kmgccc.cassette":
            return Self(
                mainFontNameZh: LyricsFontDefaults.skinChinese,
                mainFontNameEn: LyricsFontDefaults.skinEnglish,
                translationFontName: LyricsFontDefaults.skinTranslation,
                mainFontWeight: 600,
                translationFontWeight: 600,
                mainFontSize: 64,
                translationFontSize: 24
            )
        case "fullscreen.coverGradientBlur":
            return Self(
                mainFontNameZh: Self.defaultValue.mainFontNameZh,
                mainFontNameEn: Self.defaultValue.mainFontNameEn,
                translationFontName: Self.defaultValue.translationFontName,
                mainFontWeight: 100,
                translationFontWeight: 300,
                mainFontSize: Self.defaultValue.mainFontSize,
                translationFontSize: Self.defaultValue.translationFontSize
            )
        default:
            return Self.defaultValue
        }
    }

    /// Defaults written by previous per-skin typography implementations.
    /// They are recognized only during the one-time upgrade so a genuinely
    /// customized profile is not overwritten.
    static func previousDefaultValues(forFullscreenSkinID skinID: String) -> [Self] {
        switch skinID {
        case "coverLed":
            return [
                Self(
                    mainFontNameZh: LyricsFontDefaults.skinChinese,
                    mainFontNameEn: LyricsFontDefaults.english,
                    translationFontName: LyricsFontDefaults.skinTranslation,
                    mainFontWeight: 700,
                    translationFontWeight: 600,
                    mainFontSize: 56,
                    translationFontSize: 27
                )
            ]
        case "rotatingCover":
            return [
                Self(
                    mainFontNameZh: LyricsFontDefaults.skinChinese,
                    mainFontNameEn: LyricsFontDefaults.english,
                    translationFontName: LyricsFontDefaults.skinTranslation,
                    mainFontWeight: 600,
                    translationFontWeight: 500,
                    mainFontSize: 54,
                    translationFontSize: 25
                )
            ]
        case "kmgccc.cassette":
            return [
                Self(
                    mainFontNameZh: LyricsFontDefaults.skinChinese,
                    mainFontNameEn: LyricsFontDefaults.english,
                    translationFontName: LyricsFontDefaults.skinTranslation,
                    mainFontWeight: 700,
                    translationFontWeight: 600,
                    mainFontSize: 52,
                    translationFontSize: 24
                )
            ]
        case "fullscreen.coverGradientBlur":
            return [
                Self(
                    mainFontNameZh: Self.defaultValue.mainFontNameZh,
                    mainFontNameEn: Self.defaultValue.mainFontNameEn,
                    translationFontName: Self.defaultValue.translationFontName,
                    mainFontWeight: 100,
                    translationFontWeight: 100,
                    mainFontSize: Self.defaultValue.mainFontSize,
                    translationFontSize: Self.defaultValue.translationFontSize
                ),
                Self(
                    mainFontNameZh: LyricsFontDefaults.skinChinese,
                    mainFontNameEn: LyricsFontDefaults.skinEnglish,
                    translationFontName: LyricsFontDefaults.skinTranslation,
                    mainFontWeight: 100,
                    translationFontWeight: 100,
                    mainFontSize: 64,
                    translationFontSize: 24
                )
            ]
        default:
            return []
        }
    }
}

extension Notification.Name {
    static let lyricSpringSettingsDidSettle = Notification.Name("kmgccc_player.lyricSpringSettingsDidSettle")
}

/// Observable app settings using AppStorage for persistence.
@Observable
public final class AppSettings {

    // MARK: - Singleton

    public static let shared = AppSettings()
    public static let defaultVolume: Double = 0.8

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
    @AppStorage("volume") var volume: Double = AppSettings.defaultVolume

    // MARK: - LED Meter Settings

    private enum LEDKeys {
        static let ledCount = "ledCount"
        static let ledBrightnessLevels = "ledBrightnessLevels"
    }

    /// Number of LEDs (default 11)
    var ledCount: Int {
        get {
            access(keyPath: \.ledCount)
            let val = UserDefaults.standard.integer(forKey: LEDKeys.ledCount)
            return val == 0 ? LEDDefaults.ledCount : val
        }
        set {
            withMutation(keyPath: \.ledCount) {
                UserDefaults.standard.set(newValue, forKey: LEDKeys.ledCount)
            }
        }
    }

    /// Brightness levels per LED (default 5)
    var ledBrightnessLevels: Int {
        get {
            access(keyPath: \.ledBrightnessLevels)
            let val = UserDefaults.standard.integer(forKey: LEDKeys.ledBrightnessLevels)
            return val == 0 ? LEDDefaults.levels : val
        }
        set {
            withMutation(keyPath: \.ledBrightnessLevels) {
                UserDefaults.standard.set(newValue, forKey: LEDKeys.ledBrightnessLevels)
            }
        }
    }

    /// LED sensitivity is now fixed; UI control was removed and the value is sourced from LEDDefaults.
    var ledSensitivity: Float { LEDDefaults.sensitivity }

    /// LED cutoff frequency is now fixed; UI control was removed and the value is sourced from LEDDefaults.
    var ledCutoffHz: Double { LEDDefaults.cutoffHz }

    /// LED response speed is now fixed; UI control was removed and the value is sourced from LEDDefaults.
    var ledSpeed: Double { LEDDefaults.speed }

    /// LED publish rate is now fixed; UI control was removed and the value is sourced from LEDDefaults.
    var ledTargetHz: Int { LEDDefaults.targetHz }

    // MARK: - Deprecated LED parameters (kept for storage compatibility, no longer used by algorithm)

    /// Deprecated: pre-gain was replaced by internal perceptual curve.
    @ObservationIgnored
    @AppStorage("ledPreGain") var ledPreGain: Double = 1.0

    /// Deprecated: transient boost removed from LED algorithm.
    @ObservationIgnored
    @AppStorage("ledTransientThreshold") var ledTransientThreshold: Double = 12.0

    /// Deprecated: transient boost removed from LED algorithm.
    @ObservationIgnored
    @AppStorage("ledTransientIntensity") var ledTransientIntensity: Double = 4.0

    /// Deprecated: transient boost removed from LED algorithm.
    @ObservationIgnored
    @AppStorage("ledTransientCutoffHz") var ledTransientCutoffHz: Double = 60.0

    

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

    enum LyricsBackgroundMode: String, CaseIterable, Identifiable {
        case clear
        case sidebar

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clear: return "磨砂玻璃"
            case .sidebar: return "液态玻璃"
            }
        }
    }

    enum HomeCardMaterialMode: String, CaseIterable, Identifiable {
        case solid
        case frostedGlass
        case liquidGlass

        var id: String { rawValue }

        var title: String {
            switch self {
            case .solid: return "普通"
            case .frostedGlass: return "磨砂玻璃"
            case .liquidGlass: return "液态玻璃"
            }
        }
    }

    private enum AppearanceKeys {
        static let globalArtworkTintEnabled = "globalArtworkTintEnabled"
        static let dockProgressVisible = "dockProgressVisible"
        static let followSystemAppearance = "followSystemAppearance"
        static let manualAppearance = "manualAppearance"
        static let lyricsBackgroundMode = "lyricsBackgroundMode"
        static let homeCardMaterialMode = "homeCardMaterialMode"
        static let homeSectionOrder = "homeSectionOrder"
    }

    private enum ImportKeys {
        static let deferImportEnrichment = "deferImportEnrichment"
    }

    private enum PlaybackOrderKeys {
        static let mode = "playbackOrderMode"
        static let shuffleEnabled = "shuffleEnabled"
        static let repeatMode = "repeatMode"
        static let stopAfterTrack = "stopAfterTrack"
    }

    /// Whether global accent/tint follows current artwork dominant color.
    var globalArtworkTintEnabled: Bool {
        get {
            access(keyPath: \.globalArtworkTintEnabled)
            if UserDefaults.standard.object(forKey: AppearanceKeys.globalArtworkTintEnabled) == nil
            {
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

    /// Whether the Dock icon shows the current playback progress bar.
    var dockProgressVisible: Bool {
        get {
            access(keyPath: \.dockProgressVisible)
            if UserDefaults.standard.object(forKey: AppearanceKeys.dockProgressVisible) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: AppearanceKeys.dockProgressVisible)
        }
        set {
            withMutation(keyPath: \.dockProgressVisible) {
                UserDefaults.standard.set(newValue, forKey: AppearanceKeys.dockProgressVisible)
                NotificationCenter.default.post(
                    name: .dockProgressVisibilityChanged,
                    object: self
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
            let raw =
                UserDefaults.standard.string(forKey: AppearanceKeys.manualAppearance)
                ?? ManualAppearance.dark.rawValue
            return ManualAppearance(rawValue: raw) ?? .dark
        }
        set {
            withMutation(keyPath: \.manualAppearance) {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: AppearanceKeys.manualAppearance)
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

    /// Lyrics Background Mode
    var lyricsBackgroundMode: LyricsBackgroundMode {
        get {
            access(keyPath: \.lyricsBackgroundMode)
            let raw =
                UserDefaults.standard.string(forKey: AppearanceKeys.lyricsBackgroundMode)
                ?? LyricsBackgroundMode.sidebar.rawValue
            return LyricsBackgroundMode(rawValue: raw) ?? .sidebar
        }
        set {
            withMutation(keyPath: \.lyricsBackgroundMode) {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: AppearanceKeys.lyricsBackgroundMode)
            }
        }
    }

    /// Home card material mode.
    var homeCardMaterialMode: HomeCardMaterialMode {
        get {
            access(keyPath: \.homeCardMaterialMode)
            let raw =
                UserDefaults.standard.string(forKey: AppearanceKeys.homeCardMaterialMode)
                ?? HomeCardMaterialMode.frostedGlass.rawValue
            return HomeCardMaterialMode(rawValue: raw) ?? .frostedGlass
        }
        set {
            withMutation(keyPath: \.homeCardMaterialMode) {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: AppearanceKeys.homeCardMaterialMode)
            }
        }
    }

    /// Custom order for Home page content sections, stored as stable section ids.
    var homeSectionOrder: [HomeSection] {
        get {
            access(keyPath: \.homeSectionOrder)
            let rawIDs = UserDefaults.standard.stringArray(forKey: AppearanceKeys.homeSectionOrder)
                ?? HomeSection.defaultOrder.map(\.rawValue)
            return HomeSection.normalizedOrder(from: rawIDs)
        }
        set {
            withMutation(keyPath: \.homeSectionOrder) {
                let normalizedIDs = HomeSection.normalizedOrder(from: newValue.map(\.rawValue))
                    .map(\.rawValue)
                UserDefaults.standard.set(normalizedIDs, forKey: AppearanceKeys.homeSectionOrder)
            }
        }
    }

    func resetHomeSectionOrder() {
        homeSectionOrder = HomeSection.defaultOrder
    }

    /// Whether imported tracks should appear immediately and fetch lyrics/artwork afterward.
    var deferImportEnrichment: Bool {
        get {
            access(keyPath: \.deferImportEnrichment)
            if UserDefaults.standard.object(forKey: ImportKeys.deferImportEnrichment) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: ImportKeys.deferImportEnrichment)
        }
        set {
            withMutation(keyPath: \.deferImportEnrichment) {
                UserDefaults.standard.set(newValue, forKey: ImportKeys.deferImportEnrichment)
            }
        }
    }

    /// Accent color hex string (default: soft warm amber, desaturated for light-mode readability)
    @ObservationIgnored
    @AppStorage("accentColorHex") var accentColorHex: String = "#E6C799"

    /// Liquid Glass intensity (0.0 to 1.0)
    @ObservationIgnored
    @AppStorage("liquidGlassIntensity") var liquidGlassIntensity: Double = 1.0

    // MARK: - AMLL Settings

    /// AMLL configuration as JSON string
    @ObservationIgnored
    @AppStorage("amllConfigJSON") var amllConfigJSON: String = "{}"

    /// Lyrics font name
    @ObservationIgnored
    @AppStorage("lyricsFontName") var lyricsFontName: String = LyricsFontDefaults.english

    /// Lyrics font name (Chinese/CJK)
    @ObservationIgnored
    @AppStorage("lyricsFontNameZh") var lyricsFontNameZh: String = LyricsFontDefaults.chinese

    /// Lyrics font name (Latin/English)
    @ObservationIgnored
    @AppStorage("lyricsFontNameEn") var lyricsFontNameEn: String = LyricsFontDefaults.english

    /// Translation font name
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontName") var lyricsTranslationFontName: String = LyricsFontDefaults.translation

    /// Translation font size
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontSize") var lyricsTranslationFontSize: Double = 18.0

    /// Translation font weight in light mode (100~900)
    @ObservationIgnored
    @AppStorage("lyricsTranslationFontWeightLight") var lyricsTranslationFontWeightLight: Int = 500

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
    @AppStorage("lyricsFontSize") var lyricsFontSize: Double = 32.0

    /// Lead-in milliseconds for near-switch lyric line advance
    @ObservationIgnored
    @AppStorage("lyricsLeadInMs") var lyricsLeadInMs: Double = 600

    /// If the next main line begins within this gap (ms) after current main line ends,
    /// the lyrics renderer will early-switch to the next line using `lyricsLeadInMs`.
    @ObservationIgnored
    @AppStorage("lyricsNearSwitchGapMs") var lyricsNearSwitchGapMs: Double = 160

    /// Global lyrics advance amount in milliseconds (positive value means lyrics appear earlier).
    @ObservationIgnored
    @AppStorage("lyricsGlobalAdvanceMs") var lyricsGlobalAdvanceMs: Double = 0

    enum AMLLLyricsRenderQuality: String, CaseIterable, Identifiable {
        case low
        case medium
        case high

        var id: String { rawValue }

        var title: String {
            switch self {
            case .low: return "低"
            case .medium: return "中"
            case .high: return "高"
            }
        }

        var resolutionDescription: String {
            switch self {
            case .low: return "0.5x 分辨率"
            case .medium: return "0.75x 分辨率"
            case .high: return "原生分辨率"
            }
        }

        var webViewScale: Double {
            switch self {
            case .low: return 0.5
            case .medium: return 0.75
            case .high: return 1.0
            }
        }

        var sliderValue: Double {
            switch self {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            }
        }

        init(sliderValue: Double) {
            let index = Int(sliderValue.rounded())
            switch index {
            case 0: self = .low
            case 2: self = .high
            default: self = .medium
            }
        }
    }

    private enum AMLLKeys {
        static let lyricsRenderQuality = "amllLyricsRenderQuality"
        static let highResolutionLyricsEnabled = "amllHighResolutionLyricsEnabled"
        static let discreteWordHighlightEnabled = "amllDiscreteWordHighlightEnabled"
        static let springEnabled = "amllLyricsSpringEnabled"
        static let springDuration = "amllLyricsSpringDuration"
        static let springBounce = "amllLyricsSpringBounce"
    }

    static let lyricSpringDurationRange: ClosedRange<Double> = 0.30...1.20
    static let lyricSpringBounceRange: ClosedRange<Double> = -0.25...3.25
    static let defaultLyricSpringDuration: Double = 0.4
    static let defaultLyricSpringBounce: Double = 0.75

    private static func clampLyricSpringDuration(_ value: Double) -> Double {
        guard value.isFinite else { return defaultLyricSpringDuration }
        return min(max(value, lyricSpringDurationRange.lowerBound), lyricSpringDurationRange.upperBound)
    }

    private static func clampLyricSpringBounce(_ value: Double) -> Double {
        guard value.isFinite else { return defaultLyricSpringBounce }
        return min(max(value, lyricSpringBounceRange.lowerBound), lyricSpringBounceRange.upperBound)
    }

    /// Shared render quality for AMLL lyric WebViews.
    var amllLyricsRenderQuality: AMLLLyricsRenderQuality {
        get {
            access(keyPath: \.amllLyricsRenderQuality)
            let defaults = UserDefaults.standard
            if let stored = defaults.string(forKey: AMLLKeys.lyricsRenderQuality),
               let quality = AMLLLyricsRenderQuality(rawValue: stored)
            {
                return quality
            }

            if defaults.object(forKey: AMLLKeys.highResolutionLyricsEnabled) != nil {
                let migratedQuality: AMLLLyricsRenderQuality =
                    defaults.bool(forKey: AMLLKeys.highResolutionLyricsEnabled) ? .high : .medium
                defaults.set(migratedQuality.rawValue, forKey: AMLLKeys.lyricsRenderQuality)
                return migratedQuality
            }

            return .medium
        }
        set {
            withMutation(keyPath: \.amllLyricsRenderQuality) {
                UserDefaults.standard.set(newValue.rawValue, forKey: AMLLKeys.lyricsRenderQuality)
            }
        }
    }

    /// Shared WebView backing scale for user-facing AMLL lyric surfaces.
    var amllLyricsRenderQualityScale: Double {
        amllLyricsRenderQuality.webViewScale
    }

    /// Whether word-by-word AMLL highlighting should jump by whole words instead of sweeping left-to-right.
    var amllDiscreteWordHighlightEnabled: Bool {
        get {
            access(keyPath: \.amllDiscreteWordHighlightEnabled)
            return UserDefaults.standard.bool(forKey: AMLLKeys.discreteWordHighlightEnabled)
        }
        set {
            withMutation(keyPath: \.amllDiscreteWordHighlightEnabled) {
                UserDefaults.standard.set(newValue, forKey: AMLLKeys.discreteWordHighlightEnabled)
            }
        }
    }

    var amllLyricsSpringEnabled: Bool {
        get {
            access(keyPath: \.amllLyricsSpringEnabled)
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: AMLLKeys.springEnabled) != nil else { return true }
            return defaults.bool(forKey: AMLLKeys.springEnabled)
        }
        set {
            withMutation(keyPath: \.amllLyricsSpringEnabled) {
                UserDefaults.standard.set(newValue, forKey: AMLLKeys.springEnabled)
            }
        }
    }

    var amllLyricsSpringDuration: Double {
        get {
            access(keyPath: \.amllLyricsSpringDuration)
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: AMLLKeys.springDuration) != nil else {
                return Self.defaultLyricSpringDuration
            }
            return Self.clampLyricSpringDuration(defaults.double(forKey: AMLLKeys.springDuration))
        }
        set {
            withMutation(keyPath: \.amllLyricsSpringDuration) {
                UserDefaults.standard.set(Self.clampLyricSpringDuration(newValue), forKey: AMLLKeys.springDuration)
            }
        }
    }

    var amllLyricsSpringBounce: Double {
        get {
            access(keyPath: \.amllLyricsSpringBounce)
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: AMLLKeys.springBounce) != nil else {
                return Self.defaultLyricSpringBounce
            }
            return Self.clampLyricSpringBounce(defaults.double(forKey: AMLLKeys.springBounce))
        }
        set {
            withMutation(keyPath: \.amllLyricsSpringBounce) {
                UserDefaults.standard.set(Self.clampLyricSpringBounce(newValue), forKey: AMLLKeys.springBounce)
            }
        }
    }

    var lyricSpringUserSettings: LyricSpringUserSettings {
        LyricSpringUserSettings(
            enabled: amllLyricsSpringEnabled,
            duration: amllLyricsSpringDuration,
            bounce: amllLyricsSpringBounce
        )
    }

    /// Now Playing skin identifier
    @ObservationIgnored
    @AppStorage("nowPlayingSkin") var nowPlayingSkin: String = "kmgccc.cassette"

    /// Single source of truth for Now Playing skin.
    var selectedNowPlayingSkinID: String {
        get {
            access(keyPath: \.selectedNowPlayingSkinID)
            return nowPlayingSkin
        }
        set {
            let previous = nowPlayingSkin
            withMutation(keyPath: \.selectedNowPlayingSkinID) {
                nowPlayingSkin = newValue
                applySkinEntryDefaults(previous: previous, new: newValue)
            }
            Task { @MainActor in
                TelemetryService.shared.updateSkinState()
            }
        }
    }

    /// Visualizer choices are retained per skin by AudioVisualizationPreferences;
    /// only the rotating-cover presentation mode still has an entry default.
    private func applySkinEntryDefaults(previous: String, new: String) {
        guard previous != new else { return }
        if new == "rotatingCover" {
            UserDefaults.standard.set(true, forKey: "skin.rotatingCover.cdMode")
        }
    }

    /// Fullscreen skin selection - now managed by FullscreenPresentationCoordinator.
    /// This property is kept for backward compatibility but delegates to the coordinator.
    var selectedFullscreenSkinID: String {
        get { fullscreen.skinID }
        set { fullscreen.setSkinID(newValue) }
    }

    // MARK: - Playback Settings

    /// When enabled, real audio output is delayed by the fixed 180ms playback
    /// graph delay so the
    /// inherent latency of the LED / spectrum / lyrics visual pipeline lines up
    /// with what the user hears. Default ON — improve visual sync out-of-the-box.
    /// When OFF the output chain is physically delay-free.
    @ObservationIgnored
    @AppStorage("audioLookaheadEnabled") var audioLookaheadEnabled: Bool = true

    /// Legacy lookahead delay preference. The current playback graph uses a
    /// fixed 180ms target; this stored value is preserved for compatibility and
    /// future UI work.
    @ObservationIgnored
    @AppStorage("lookaheadMs") var lookaheadMs: Double = 180

    /// Debug-only: when true, forces the no-delay direct output chain
    /// regardless of `audioLookaheadEnabled`. Not surfaced in any formal UI;
    /// used to isolate whether the delay node contributes to a playback hitch.
    /// Default false — normal behavior is unchanged.
    @ObservationIgnored
    @AppStorage("audioDebugBypassDelayNode") var audioDebugBypassDelayNode: Bool = false

    /// Kill-switch for gapless scheduling (pre-scheduling the next track onto the
    /// same player node for a 0-second join). Default ON. Turn OFF to revert to
    /// the legacy "load the next track only after completion" path without a
    /// rebuild — useful to isolate any gapless-related issue in the field.
    @ObservationIgnored
    @AppStorage("audioGaplessSchedulingEnabled") var audioGaplessSchedulingEnabled: Bool = true

    /// Kill-switch for AAC gapless trimming (skipping encoder priming/padding at a
    /// gapless join so AAC→AAC boundaries don't insert the encoder's leading/
    /// trailing silence). Default ON. Turn OFF to keep Phase-1 gapless scheduling
    /// but schedule each next AAC item at full length — useful to isolate any
    /// trim-related issue without disabling gapless entirely. Only ever affects
    /// the gapless-append path for AAC files with reliable packet-table metadata;
    /// WAV / FLAC / MP3 and single-track playback are never trimmed.
    @ObservationIgnored
    @AppStorage("audioAACGaplessTrimEnabled") var audioAACGaplessTrimEnabled: Bool = true

    // MARK: - Now Playing Background Settings

    /// Enable BKArt animated background layer in Now Playing.
    @ObservationIgnored
    @AppStorage("nowPlayingArtBackgroundEnabled") var nowPlayingArtBackgroundEnabled: Bool = true

    /// Enable BKArt animated background layer in the fullscreen player.
    @ObservationIgnored
    @AppStorage("fullscreenArtBackgroundEnabled") var fullscreenArtBackgroundEnabled: Bool = true

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

    // MARK: - Now Playing Background Dynamics

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
    var shuffleEnabled: Bool {
        get {
            access(keyPath: \.shuffleEnabled)
            return readLegacyPlaybackFields().shuffleEnabled
        }
        set {
            withMutation(keyPath: \.shuffleEnabled) {
                var fields = readLegacyPlaybackFields()
                fields.shuffleEnabled = newValue
                writePlaybackOrder(derivePlaybackOrderMode(from: fields))
            }
        }
    }

    /// Repeat mode: "off", "all", "one"
    var repeatMode: String {
        get {
            access(keyPath: \.repeatMode)
            return readLegacyPlaybackFields().repeatMode
        }
        set {
            withMutation(keyPath: \.repeatMode) {
                var fields = readLegacyPlaybackFields()
                fields.repeatMode = newValue
                writePlaybackOrder(derivePlaybackOrderMode(from: fields))
            }
        }
    }

    /// Pause playback after current song finishes (single-cycle stop mode).
    var stopAfterTrack: Bool {
        get {
            access(keyPath: \.stopAfterTrack)
            return readLegacyPlaybackFields().stopAfterTrack
        }
        set {
            withMutation(keyPath: \.stopAfterTrack) {
                var fields = readLegacyPlaybackFields()
                fields.stopAfterTrack = newValue
                writePlaybackOrder(derivePlaybackOrderMode(from: fields))
            }
        }
    }

    var playbackOrderMode: PlaybackOrderMode {
        get {
            access(keyPath: \.playbackOrderMode)

            if let rawValue = UserDefaults.standard.string(forKey: PlaybackOrderKeys.mode),
                let mode = PlaybackOrderMode(rawValue: rawValue)
            {
                return mode
            }

            let fields = readLegacyPlaybackFields()
            guard fields.hasStoredValue else { return .sequence }
            return derivePlaybackOrderMode(from: fields)
        }
        set {
            setPlaybackOrderMode(newValue)
        }
    }

    func setPlaybackOrderMode(_ mode: PlaybackOrderMode, announceChange: Bool = false) {
        let oldMode = playbackOrderMode

        withMutation(keyPath: \.playbackOrderMode) {
            writePlaybackOrder(mode)
        }

        guard announceChange, oldMode != mode else { return }
        NotificationCenter.default.post(name: .playbackModeChanged, object: nil)
    }

    private struct LegacyPlaybackOrderFields {
        var shuffleEnabled: Bool
        var repeatMode: String
        var stopAfterTrack: Bool
        var hasStoredValue: Bool
    }

    private func readLegacyPlaybackFields() -> LegacyPlaybackOrderFields {
        let defaults = UserDefaults.standard
        let hasShuffle = defaults.object(forKey: PlaybackOrderKeys.shuffleEnabled) != nil
        let hasRepeat = defaults.object(forKey: PlaybackOrderKeys.repeatMode) != nil
        let hasStopAfterTrack = defaults.object(forKey: PlaybackOrderKeys.stopAfterTrack) != nil

        return LegacyPlaybackOrderFields(
            shuffleEnabled: hasShuffle ? defaults.bool(forKey: PlaybackOrderKeys.shuffleEnabled) : false,
            repeatMode: defaults.string(forKey: PlaybackOrderKeys.repeatMode) ?? "off",
            stopAfterTrack: hasStopAfterTrack ? defaults.bool(forKey: PlaybackOrderKeys.stopAfterTrack) : false,
            hasStoredValue: hasShuffle || hasRepeat || hasStopAfterTrack
        )
    }

    private func derivePlaybackOrderMode(from fields: LegacyPlaybackOrderFields) -> PlaybackOrderMode {
        if fields.stopAfterTrack { return .stopAfterTrack }
        if fields.repeatMode == "one" { return .repeatOne }
        if fields.shuffleEnabled { return .shuffle }
        return .sequence
    }

    private func writePlaybackOrder(_ mode: PlaybackOrderMode) {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: PlaybackOrderKeys.mode)

        switch mode {
        case .sequence:
            defaults.set(false, forKey: PlaybackOrderKeys.shuffleEnabled)
            defaults.set("off", forKey: PlaybackOrderKeys.repeatMode)
            defaults.set(false, forKey: PlaybackOrderKeys.stopAfterTrack)
        case .shuffle:
            defaults.set(true, forKey: PlaybackOrderKeys.shuffleEnabled)
            defaults.set("off", forKey: PlaybackOrderKeys.repeatMode)
            defaults.set(false, forKey: PlaybackOrderKeys.stopAfterTrack)
        case .repeatOne:
            defaults.set(false, forKey: PlaybackOrderKeys.shuffleEnabled)
            defaults.set("one", forKey: PlaybackOrderKeys.repeatMode)
            defaults.set(false, forKey: PlaybackOrderKeys.stopAfterTrack)
        case .stopAfterTrack:
            defaults.set(false, forKey: PlaybackOrderKeys.shuffleEnabled)
            defaults.set("off", forKey: PlaybackOrderKeys.repeatMode)
            defaults.set(true, forKey: PlaybackOrderKeys.stopAfterTrack)
        }
    }

    // MARK: - External Playback Settings

    private enum ExternalPlaybackKeys {
        static let sourcePreferences = "externalPlaybackSourcePreferences"
    }

    /// Whether to show the playback source switcher (local / Apple Music) in the sidebar.
    /// When false, shows the legacy app header (icon + app name) instead.
    @ObservationIgnored
    @AppStorage("showPlaybackSourceSwitcher") var showPlaybackSourceSwitcher: Bool = true

    /// Whether the "System Now Playing" (其他) playback mode is available.
    /// When enabled, the sidebar shows three modes: Local / Apple Music / Other.
    /// When disabled, only Local and Apple Music are shown.
    /// This is an opt-in because System Now Playing relies on macOS MediaRemote,
    /// which may be unstable (spotty metadata, no reliable progress control,
    /// and limited pause/resume support). Users who only need local library
    /// or Apple Music can safely disable it to declutter the UI.
    @ObservationIgnored
    @AppStorage("enableSystemNowPlayingMode") var enableSystemNowPlayingMode: Bool = false

    var externalPlaybackSourcePreferences: [ExternalPlaybackSourcePreference] {
        get {
            access(keyPath: \.externalPlaybackSourcePreferences)
            guard let data = UserDefaults.standard.data(forKey: ExternalPlaybackKeys.sourcePreferences),
                  let decoded = try? JSONDecoder().decode([ExternalPlaybackSourcePreference].self, from: data)
            else {
                return []
            }
            return Self.normalizedExternalPlaybackSourcePreferences(decoded)
        }
        set {
            withMutation(keyPath: \.externalPlaybackSourcePreferences) {
                let normalized = Self.normalizedExternalPlaybackSourcePreferences(newValue)
                if let data = try? JSONEncoder().encode(normalized) {
                    UserDefaults.standard.set(data, forKey: ExternalPlaybackKeys.sourcePreferences)
                }
                NotificationCenter.default.post(
                    name: .externalPlaybackSourcePreferencesDidChange,
                    object: self
                )
            }
        }
    }

    private static func normalizedExternalPlaybackSourcePreferences(
        _ preferences: [ExternalPlaybackSourcePreference]
    ) -> [ExternalPlaybackSourcePreference] {
        var seen = Set<String>()
        var normalized: [ExternalPlaybackSourcePreference] = []
        normalized.reserveCapacity(preferences.count)
        for preference in preferences {
            let id = preference.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let bundleIdentifier = preference.bundleIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let displayName = preference.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.append(
                ExternalPlaybackSourcePreference(
                    id: id,
                    bundleIdentifier: bundleIdentifier.isEmpty ? id : bundleIdentifier,
                    displayName: displayName.isEmpty ? id : displayName,
                    isDisabled: preference.isDisabled
                )
            )
        }
        return normalized
    }

    // MARK: - Fullscreen Presentation Coordinator

    /// Access the fullscreen presentation coordinator for managing visualizer/skin state.
    /// This is the single entry point for all fullscreen presentation configuration.
    public var fullscreen: FullscreenPresentationCoordinator { FullscreenPresentationCoordinator.shared }

    // MARK: - Fullscreen Player Settings

    private enum FullscreenLyricsKeys {
        static let fontDefaultsMigration = "lyricsTypographyDefaultsMigrated_v2"
        static let perSkinTypographyDefaultsMigration = "fullscreenLyricsPerSkinTypographyDefaults_v6"
        static let perSkinTypographyEnabled = "fullscreenLyricsPerSkinTypographyEnabled"
        static let perSkinTypographyProfiles = "fullscreenLyricsPerSkinTypographyProfiles_v1"
        static let fontNameZh = "fullscreenLyricsFontNameZh"
        static let fontNameEn = "fullscreenLyricsFontNameEn"
        static let translationFontName = "fullscreenLyricsTranslationFontName"
        static let fontWeight = "fullscreenLyricsFontWeight"
        static let translationFontWeight = "fullscreenLyricsTranslationFontWeight"
        static let fontSize = "fullscreenLyricsFontSize"
        static let translationFontSize = "fullscreenLyricsTranslationFontSize"
    }

    enum FullscreenDefaults {
        static let artworkScale: Double = 1.1
        static let lyricsFontScale: Double = 2.0
        static let dimmingIntensity: Double = 0.15
        static let miniplayerHeight: Double = 60

        static let lyricsFontNameZh = FullscreenLyricsTypography.defaultValue.mainFontNameZh
        static let lyricsFontNameEn = FullscreenLyricsTypography.defaultValue.mainFontNameEn
        static let lyricsTranslationFontName = FullscreenLyricsTypography.defaultValue.translationFontName
        static let lyricsFontWeight = FullscreenLyricsTypography.defaultValue.mainFontWeight
        static let lyricsTranslationFontWeight = FullscreenLyricsTypography.defaultValue.translationFontWeight
        static let lyricsFontSize: Double = FullscreenLyricsTypography.defaultValue.mainFontSize
        static let lyricsTranslationFontSize: Double = FullscreenLyricsTypography.defaultValue.translationFontSize
    }

    /// The initial fullscreen background dimming varies by skin. The stored
    /// preference remains shared for backward compatibility; this only changes
    /// the value used before the user has made an explicit choice.
    public static func defaultFullscreenDimmingIntensity(for skinID: String) -> Double {
        skinID == "fullscreen.coverGradientBlur"
            ? 0.0
            : FullscreenDefaults.dimmingIntensity
    }

    /// Observation-only revision used by fullscreen surfaces to reapply AMLL
    /// when a per-skin profile changes without changing the global keys.
    var fullscreenLyricsTypographyRevision: UInt64 = 0

    /// Whether fullscreen lyrics typography is stored independently per skin.
    /// The global fullscreen typography is retained while this is enabled, so
    /// turning the switch off and on never loses either configuration set.
    var fullscreenLyricsUsesPerSkinTypography: Bool {
        get {
            access(keyPath: \.fullscreenLyricsUsesPerSkinTypography)
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: FullscreenLyricsKeys.perSkinTypographyEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: FullscreenLyricsKeys.perSkinTypographyEnabled)
        }
        set {
            guard newValue != fullscreenLyricsUsesPerSkinTypography else { return }
            if newValue {
                snapshotMissingFullscreenLyricsTypographyProfiles()
            }
            withMutation(keyPath: \.fullscreenLyricsUsesPerSkinTypography) {
                UserDefaults.standard.set(
                    newValue,
                    forKey: FullscreenLyricsKeys.perSkinTypographyEnabled
                )
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    enum FullscreenMiniPlayerGlassMaterial: String, CaseIterable, Identifiable {
        case clear
        case normal

        var id: String { rawValue }
    }

    /// Fullscreen player artwork scale (default varies by skin, stored per skin ID)
    var fullscreenArtworkScale: Double {
        get {
            access(keyPath: \.fullscreenArtworkScale)
            _ = fullscreen.skinID
            return artworkScale(for: fullscreen.skinID)
        }
        set {
            withMutation(keyPath: \.fullscreenArtworkScale) {
                setArtworkScale(newValue, for: fullscreen.skinID)
            }
        }
    }

    public static func defaultArtworkScale(for skinID: String) -> Double {
        switch skinID {
        case "kmgccc.cassette":
            return 1.25
        case "rotatingCover":
            return 1.1
        case AppleStyleSkin.skinID:
            return 1.1
        case "coverLed":
            return 1.1
        case "fullscreen.coverGradientBlur":
            return 1.0
        default:
            return 1.1
        }
    }

    public static func maxArtworkScale(for skinID: String) -> Double {
        switch skinID {
        case "coverLed":
            return 1.35
        case AppleStyleSkin.skinID:
            return 1.45
        case "rotatingCover":
            return 1.35
        case "fullscreen.coverGradientBlur":
            return 1.0
        default:
            return 1.6
        }
    }

    public func artworkScale(for skinID: String) -> Double {
        let key = "fullscreenArtworkScale_" + skinID.replacingOccurrences(of: ".", with: "_")
        let defaultVal = Self.defaultArtworkScale(for: skinID)
        let scale = UserDefaults.standard.object(forKey: key) as? Double ?? defaultVal
        let maxVal = Self.maxArtworkScale(for: skinID)
        return min(max(scale, 0.9), maxVal)
    }

    public func setArtworkScale(_ scale: Double, for skinID: String) {
        let key = "fullscreenArtworkScale_" + skinID.replacingOccurrences(of: ".", with: "_")
        let maxVal = Self.maxArtworkScale(for: skinID)
        let clamped = min(max(scale, 0.9), maxVal)
        UserDefaults.standard.set(clamped, forKey: key)
    }

    /// Fullscreen player lyrics font size multiplier (1.0 to 3.0, default 2.0)
    @ObservationIgnored
    @AppStorage("fullscreenLyricsFontScale") var fullscreenLyricsFontScale: Double =
        FullscreenDefaults.lyricsFontScale

    /// Fullscreen player background dimming intensity (0.0 to 0.5, default 0.15)
    @ObservationIgnored
    @AppStorage("fullscreenDimmingIntensity") var fullscreenDimmingIntensity: Double =
        FullscreenDefaults.dimmingIntensity

    /// Fullscreen player miniplayer bar height (40 to 80, default 60)
    @ObservationIgnored
    @AppStorage("fullscreenMiniplayerHeight") var fullscreenMiniplayerHeight: Double =
        FullscreenDefaults.miniplayerHeight

    /// Fullscreen mini player auto-hide delay in seconds. `0` disables auto-hide.
    @ObservationIgnored
    @AppStorage("fullscreenMiniPlayerAutoHideSeconds") var fullscreenMiniPlayerAutoHideSeconds: Double = 4

    @ObservationIgnored
    @AppStorage("fullscreenMiniPlayerGlassMaterial") private var fullscreenMiniPlayerGlassMaterialRaw: String =
        FullscreenMiniPlayerGlassMaterial.clear.rawValue

    var fullscreenMiniPlayerGlassMaterial: FullscreenMiniPlayerGlassMaterial {
        get {
            access(keyPath: \.fullscreenMiniPlayerGlassMaterial)
            if fullscreenMiniPlayerGlassMaterialRaw == "darkGlass" {
                return .normal
            }
            return FullscreenMiniPlayerGlassMaterial(rawValue: fullscreenMiniPlayerGlassMaterialRaw) ?? .clear
        }
        set {
            withMutation(keyPath: \.fullscreenMiniPlayerGlassMaterial) {
                fullscreenMiniPlayerGlassMaterialRaw = newValue.rawValue
            }
        }
    }

    /// The shared fullscreen typography edited when per-skin mode is off.
    var globalFullscreenLyricsTypography: FullscreenLyricsTypography {
        access(keyPath: \.globalFullscreenLyricsTypography)
        return FullscreenLyricsTypography(
            mainFontNameZh: fullscreenLyricsFontNameZh,
            mainFontNameEn: fullscreenLyricsFontNameEn,
            translationFontName: fullscreenLyricsTranslationFontName,
            mainFontWeight: fullscreenLyricsFontWeight,
            translationFontWeight: fullscreenLyricsTranslationFontWeight,
            mainFontSize: fullscreenLyricsFontSize,
            translationFontSize: fullscreenLyricsTranslationFontSize
        )
    }

    /// Typography saved for one fullscreen skin. Every known fullscreen skin
    /// gets its own profile; an unknown skin can still inherit the global
    /// typography until it is first edited.
    func fullscreenLyricsTypography(for skinID: String) -> FullscreenLyricsTypography {
        let normalizedSkinID = skinID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSkinID.isEmpty,
              let stored = loadFullscreenLyricsTypographyProfiles()[normalizedSkinID]
        else {
            return globalFullscreenLyricsTypography
        }
        return stored
    }

    /// Typography currently consumed by the fullscreen AMLL surface.
    var effectiveFullscreenLyricsTypography: FullscreenLyricsTypography {
        access(keyPath: \.effectiveFullscreenLyricsTypography)
        if fullscreenLyricsUsesPerSkinTypography {
            return fullscreenLyricsTypography(for: fullscreen.skinID)
        }
        return globalFullscreenLyricsTypography
    }

    /// Persist one fullscreen skin's typography without touching the global
    /// values or any other skin profile.
    func setFullscreenLyricsTypography(
        _ typography: FullscreenLyricsTypography,
        for skinID: String
    ) {
        let normalizedSkinID = skinID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSkinID.isEmpty else { return }

        var profiles = loadFullscreenLyricsTypographyProfiles()
        guard profiles[normalizedSkinID] != typography else { return }
        profiles[normalizedSkinID] = typography
        saveFullscreenLyricsTypographyProfiles(profiles)
        markFullscreenLyricsTypographyDidChange()
    }

    private func loadFullscreenLyricsTypographyProfiles()
        -> [String: FullscreenLyricsTypography]
    {
        guard let data = UserDefaults.standard.data(
            forKey: FullscreenLyricsKeys.perSkinTypographyProfiles
        ) else {
            return [:]
        }
        var decoded = (try? JSONDecoder().decode(
            [String: FullscreenLyricsTypography].self,
            from: data
        )) ?? [:]

        var migrated = false
        for (skinID, var profile) in decoded {
            var profileChanged = false
            if profile.mainFontNameZh == LyricsFontDefaults.legacySystemDefault {
                profile.mainFontNameZh = LyricsFontDefaults.chinese
                profileChanged = true
            }
            if profile.mainFontNameEn == LyricsFontDefaults.legacySystemDefault {
                profile.mainFontNameEn = LyricsFontDefaults.english
                profileChanged = true
            }
            if profile.translationFontName == LyricsFontDefaults.legacySystemDefault {
                profile.translationFontName = LyricsFontDefaults.translation
                profileChanged = true
            }
            if profile.mainFontSize == 50.0 {
                profile.mainFontSize = 53.0
                profileChanged = true
            }
            if profileChanged {
                decoded[skinID] = profile
                migrated = true
            }
        }

        if migrated {
            if let encoded = try? JSONEncoder().encode(decoded) {
                UserDefaults.standard.set(encoded, forKey: FullscreenLyricsKeys.perSkinTypographyProfiles)
            }
        }
        
        return decoded
    }

    private func saveFullscreenLyricsTypographyProfiles(
        _ profiles: [String: FullscreenLyricsTypography]
    ) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: FullscreenLyricsKeys.perSkinTypographyProfiles)
    }

    private func seedDefaultFullscreenLyricsTypographyProfilesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: FullscreenLyricsKeys.perSkinTypographyDefaultsMigration) else {
            return
        }

        var profiles = loadFullscreenLyricsTypographyProfiles()
        let globalTypography = FullscreenLyricsTypography(
            mainFontNameZh: defaults.string(forKey: FullscreenLyricsKeys.fontNameZh)
                ?? FullscreenDefaults.lyricsFontNameZh,
            mainFontNameEn: defaults.string(forKey: FullscreenLyricsKeys.fontNameEn)
                ?? FullscreenDefaults.lyricsFontNameEn,
            translationFontName: defaults.string(forKey: FullscreenLyricsKeys.translationFontName)
                ?? FullscreenDefaults.lyricsTranslationFontName,
            mainFontWeight: (defaults.object(forKey: FullscreenLyricsKeys.fontWeight) as? NSNumber)?
                .intValue ?? FullscreenDefaults.lyricsFontWeight,
            translationFontWeight: (defaults.object(
                forKey: FullscreenLyricsKeys.translationFontWeight
            ) as? NSNumber)?.intValue ?? FullscreenDefaults.lyricsTranslationFontWeight,
            mainFontSize: (defaults.object(forKey: FullscreenLyricsKeys.fontSize) as? NSNumber)?
                .doubleValue ?? FullscreenDefaults.lyricsFontSize,
            translationFontSize: (defaults.object(
                forKey: FullscreenLyricsKeys.translationFontSize
            ) as? NSNumber)?.doubleValue ?? FullscreenDefaults.lyricsTranslationFontSize
        )
        let shouldUseSkinDefaults = globalTypography == FullscreenLyricsTypography.defaultValue

        var didChange = false
        for skinID in [
            "coverLed",
            "appleStyle",
            "rotatingCover",
            "kmgccc.cassette",
            "fullscreen.coverGradientBlur"
        ] {
            let skinDefault = FullscreenLyricsTypography.defaultValue(
                forFullscreenSkinID: skinID
            )
            if let existing = profiles[skinID] {
                let isPreviousGeneratedDefault = FullscreenLyricsTypography
                    .previousDefaultValues(forFullscreenSkinID: skinID)
                    .contains(existing)
                let isGeneratedDefault = existing == globalTypography
                    || existing == FullscreenLyricsTypography.defaultValue
                    || isPreviousGeneratedDefault
                guard isGeneratedDefault else { continue }

                let target = isPreviousGeneratedDefault || shouldUseSkinDefaults
                    ? skinDefault
                    : globalTypography
                if existing != target {
                    profiles[skinID] = target
                    didChange = true
                }
            } else {
                profiles[skinID] = shouldUseSkinDefaults ? skinDefault : globalTypography
                didChange = true
            }
        }

        if didChange {
            saveFullscreenLyricsTypographyProfiles(profiles)
        }
        defaults.set(true, forKey: FullscreenLyricsKeys.perSkinTypographyDefaultsMigration)
    }

    private func snapshotMissingFullscreenLyricsTypographyProfiles() {
        var profiles = loadFullscreenLyricsTypographyProfiles()
        let globalTypography = globalFullscreenLyricsTypography
        let shouldUseSkinDefaults = globalTypography == FullscreenLyricsTypography.defaultValue
        var didChange = false

        for skinID in FullscreenSkinID.allCases.map(\.rawValue) {
            guard profiles[skinID] == nil else { continue }
            profiles[skinID] = shouldUseSkinDefaults
                ? FullscreenLyricsTypography.defaultValue(forFullscreenSkinID: skinID)
                : globalTypography
            didChange = true
        }

        if didChange {
            saveFullscreenLyricsTypographyProfiles(profiles)
        }
    }

    private func markFullscreenLyricsTypographyDidChange() {
        withMutation(keyPath: \.fullscreenLyricsTypographyRevision) {
            fullscreenLyricsTypographyRevision &+= 1
        }
    }

    /// Fullscreen lyrics font name (Chinese/CJK).
    var fullscreenLyricsFontNameZh: String {
        get {
            access(keyPath: \.fullscreenLyricsFontNameZh)
            return UserDefaults.standard.string(forKey: FullscreenLyricsKeys.fontNameZh)
                ?? FullscreenDefaults.lyricsFontNameZh
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsFontNameZh) {
                UserDefaults.standard.set(newValue, forKey: FullscreenLyricsKeys.fontNameZh)
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Fullscreen lyrics font name (Latin/English).
    var fullscreenLyricsFontNameEn: String {
        get {
            access(keyPath: \.fullscreenLyricsFontNameEn)
            return UserDefaults.standard.string(forKey: FullscreenLyricsKeys.fontNameEn)
                ?? FullscreenDefaults.lyricsFontNameEn
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsFontNameEn) {
                UserDefaults.standard.set(newValue, forKey: FullscreenLyricsKeys.fontNameEn)
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Fullscreen translation font name.
    var fullscreenLyricsTranslationFontName: String {
        get {
            access(keyPath: \.fullscreenLyricsTranslationFontName)
            return UserDefaults.standard.string(forKey: FullscreenLyricsKeys.translationFontName)
                ?? FullscreenDefaults.lyricsTranslationFontName
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsTranslationFontName) {
                UserDefaults.standard.set(
                    newValue,
                    forKey: FullscreenLyricsKeys.translationFontName
                )
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Fullscreen main lyrics font weight.
    var fullscreenLyricsFontWeight: Int {
        get {
            access(keyPath: \.fullscreenLyricsFontWeight)
            return (UserDefaults.standard.object(forKey: FullscreenLyricsKeys.fontWeight) as? NSNumber)?
                .intValue ?? FullscreenDefaults.lyricsFontWeight
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsFontWeight) {
                UserDefaults.standard.set(newValue, forKey: FullscreenLyricsKeys.fontWeight)
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Fullscreen translation font weight.
    var fullscreenLyricsTranslationFontWeight: Int {
        get {
            access(keyPath: \.fullscreenLyricsTranslationFontWeight)
            return (UserDefaults.standard.object(
                forKey: FullscreenLyricsKeys.translationFontWeight) as? NSNumber)?
                .intValue ?? FullscreenDefaults.lyricsTranslationFontWeight
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsTranslationFontWeight) {
                UserDefaults.standard.set(
                    newValue,
                    forKey: FullscreenLyricsKeys.translationFontWeight
                )
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Fullscreen main lyrics font size.
    var fullscreenLyricsFontSize: Double {
        get {
            access(keyPath: \.fullscreenLyricsFontSize)
            return (UserDefaults.standard.object(forKey: FullscreenLyricsKeys.fontSize) as? NSNumber)?
                .doubleValue ?? FullscreenDefaults.lyricsFontSize
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsFontSize) {
                UserDefaults.standard.set(newValue, forKey: FullscreenLyricsKeys.fontSize)
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Fullscreen translation lyrics font size.
    var fullscreenLyricsTranslationFontSize: Double {
        get {
            access(keyPath: \.fullscreenLyricsTranslationFontSize)
            return (UserDefaults.standard.object(
                forKey: FullscreenLyricsKeys.translationFontSize) as? NSNumber)?
                .doubleValue ?? FullscreenDefaults.lyricsTranslationFontSize
        }
        set {
            withMutation(keyPath: \.fullscreenLyricsTranslationFontSize) {
                UserDefaults.standard.set(
                    newValue,
                    forKey: FullscreenLyricsKeys.translationFontSize
                )
            }
            markFullscreenLyricsTypographyDidChange()
        }
    }

    /// Removes fullscreen-only lyrics typography overrides and falls back to the inherited defaults.
    func resetFullscreenLyricsTypographyOverrides() {
        withMutation(keyPath: \.fullscreenLyricsFontNameZh) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.fontNameZh)
        }
        withMutation(keyPath: \.fullscreenLyricsFontNameEn) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.fontNameEn)
        }
        withMutation(keyPath: \.fullscreenLyricsTranslationFontName) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.translationFontName)
        }
        withMutation(keyPath: \.fullscreenLyricsFontWeight) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.fontWeight)
        }
        withMutation(keyPath: \.fullscreenLyricsTranslationFontWeight) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.translationFontWeight)
        }
        withMutation(keyPath: \.fullscreenLyricsFontSize) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.fontSize)
        }
        withMutation(keyPath: \.fullscreenLyricsTranslationFontSize) {
            UserDefaults.standard.removeObject(forKey: FullscreenLyricsKeys.translationFontSize)
        }
        markFullscreenLyricsTypographyDidChange()
    }

    private func migrateLegacyLyricsTypographyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: FullscreenLyricsKeys.fontDefaultsMigration) else {
            return
        }

        func migrate(_ key: String, to newValue: String) {
            guard defaults.string(forKey: key) == LyricsFontDefaults.legacySystemDefault else {
                return
            }
            defaults.set(newValue, forKey: key)
        }

        migrate("lyricsFontName", to: LyricsFontDefaults.english)
        migrate("lyricsFontNameZh", to: LyricsFontDefaults.chinese)
        migrate("lyricsFontNameEn", to: LyricsFontDefaults.english)
        migrate("lyricsTranslationFontName", to: LyricsFontDefaults.translation)
        migrate(FullscreenLyricsKeys.fontNameZh, to: LyricsFontDefaults.chinese)
        migrate(FullscreenLyricsKeys.fontNameEn, to: LyricsFontDefaults.english)
        migrate(FullscreenLyricsKeys.translationFontName, to: LyricsFontDefaults.translation)

        defaults.set(true, forKey: FullscreenLyricsKeys.fontDefaultsMigration)
    }

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

        // Migrate old default accent (#FFC878) to new desaturated default (#E6C799).
        // Only fires when the stored value exactly matches the previous default,
        // so users who somehow set a custom value are left alone.
        if UserDefaults.standard.string(forKey: "accentColorHex") == "#FFC878" {
            UserDefaults.standard.set("#E6C799", forKey: "accentColorHex")
        }

        // Migrate old default fullscreen lyric font size (50.0) to new default (53.0).
        if let storedFontSize = UserDefaults.standard.object(forKey: FullscreenLyricsKeys.fontSize) as? NSNumber,
           storedFontSize.doubleValue == 50.0 {
            UserDefaults.standard.set(53.0, forKey: FullscreenLyricsKeys.fontSize)
        }

        migrateLegacyLyricsTypographyDefaults()
        seedDefaultFullscreenLyricsTypographyProfilesIfNeeded()

        // A missing value means this is a new install (or an older install
        // that predates the switch). Keep an explicit user-off choice intact.
        if UserDefaults.standard.object(forKey: FullscreenLyricsKeys.perSkinTypographyEnabled) == nil {
            UserDefaults.standard.set(true, forKey: FullscreenLyricsKeys.perSkinTypographyEnabled)
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

    // NOTE: Legacy bgMeter* / bgLow* / bgKick* migration removed.
    // The remaining actively-used background parameters are:
    // bgKickToBrightnessMix, bgKickDisplaceAmount, bgKickScaleAmount, bgQuietSuppressionMode.
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

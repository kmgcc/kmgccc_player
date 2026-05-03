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
    @AppStorage("ledBrightnessLevels") var ledBrightnessLevels: Int = 5

    /// LED sensitivity (0.5 to 1.5, default 1.0)
    @ObservationIgnored
    @AppStorage("ledSensitivity") private var _ledSensitivity: Double = 1.0

    var ledSensitivity: Float {
        get { Float(_ledSensitivity) }
        set { _ledSensitivity = Double(newValue) }
    }

    /// LED cutoff frequency (Hz)
    @ObservationIgnored
    @AppStorage("ledCutoffHz") var ledCutoffHz: Double = 900

    /// LED response speed (0.5 to 2.0)
    @ObservationIgnored
    @AppStorage("ledSpeed") var ledSpeed: Double = 1.4

    /// LED publish rate (Hz): 30 or 60
    @ObservationIgnored
    @AppStorage("ledTargetHz") var ledTargetHz: Int = 30

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
        case liquidGlass
        case frostedGlass
        case solid

        var id: String { rawValue }

        var title: String {
            switch self {
            case .liquidGlass: return "液态玻璃"
            case .frostedGlass: return "磨砂玻璃"
            case .solid: return "普通"
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
                ?? HomeCardMaterialMode.liquidGlass.rawValue
            return HomeCardMaterialMode(rawValue: raw) ?? .liquidGlass
        }
        set {
            withMutation(keyPath: \.homeCardMaterialMode) {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: AppearanceKeys.homeCardMaterialMode)
            }
        }
    }

    /// Whether imported tracks should appear immediately and fetch lyrics/artwork afterward.
    var deferImportEnrichment: Bool {
        get {
            access(keyPath: \.deferImportEnrichment)
            return UserDefaults.standard.bool(forKey: ImportKeys.deferImportEnrichment)
        }
        set {
            withMutation(keyPath: \.deferImportEnrichment) {
                UserDefaults.standard.set(newValue, forKey: ImportKeys.deferImportEnrichment)
            }
        }
    }

    /// Accent color hex string (default: soft warm yellow)
    @ObservationIgnored
    @AppStorage("accentColorHex") var accentColorHex: String = "#FFC878"

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
    @AppStorage("lyricsTranslationFontSize") var lyricsTranslationFontSize: Double = 14.0

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
            withMutation(keyPath: \.selectedNowPlayingSkinID) {
                nowPlayingSkin = newValue
            }
        }
    }

    /// Fullscreen skin selection - now managed by FullscreenPresentationCoordinator.
    /// This property is kept for backward compatibility but delegates to the coordinator.
    var selectedFullscreenSkinID: String {
        get { fullscreen.skinID }
        set { fullscreen.setSkinID(newValue) }
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
    @AppStorage("enableSystemNowPlayingMode") var enableSystemNowPlayingMode: Bool = true

    // MARK: - Fullscreen Presentation Coordinator

    /// Access the fullscreen presentation coordinator for managing visualizer/skin state.
    /// This is the single entry point for all fullscreen presentation configuration.
    public var fullscreen: FullscreenPresentationCoordinator { FullscreenPresentationCoordinator.shared }

    // MARK: - Fullscreen Player Settings

    private enum FullscreenLyricsKeys {
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

        static let lyricsFontNameZh = "PingFang SC"
        static let lyricsFontNameEn = "SF Pro Text"
        static let lyricsTranslationFontName = "SF Pro Text"
        static let lyricsFontWeight = 600
        static let lyricsTranslationFontWeight = 400
        static let lyricsFontSize: Double = 36
        static let lyricsTranslationFontSize: Double = 18
    }

    enum FullscreenMiniPlayerGlassMaterial: String, CaseIterable, Identifiable {
        case clear
        case darkGlass

        var id: String { rawValue }
    }

    /// Fullscreen player artwork scale (0.8 to 1.5, default 1.20)
    @ObservationIgnored
    @AppStorage("fullscreenArtworkScale") var fullscreenArtworkScale: Double =
        FullscreenDefaults.artworkScale

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
            return FullscreenMiniPlayerGlassMaterial(rawValue: fullscreenMiniPlayerGlassMaterialRaw) ?? .clear
        }
        set {
            withMutation(keyPath: \.fullscreenMiniPlayerGlassMaterial) {
                fullscreenMiniPlayerGlassMaterialRaw = newValue.rawValue
            }
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

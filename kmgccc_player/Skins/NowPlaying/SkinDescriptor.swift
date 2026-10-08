import SwiftUI

enum SkinSurface: String, Codable, Hashable {
    case window
    case fullscreen
}

/// The host consumes behavior, never the identity of a particular built-in skin.
nonisolated struct SkinPresentationPolicy: Codable, Sendable {
    enum WindowBackgroundPlacement: String, Codable, Sendable { case content, parent }
    enum BackgroundOwner: String, Codable, Sendable { case host, skin }
    enum BackgroundDimming: String, Codable, Sendable { case host, renderer }
    enum ArtworkLayout: String, Codable, Sendable { case foreground, backdrop }
    enum LyricsBackdrop: String, Codable, Sendable { case standard, coverBlur, mesh }
    enum ControlForeground: String, Codable, Sendable { case chrome, artworkAdaptive, fixedLight, artistic }
    enum ArtBackgroundResourceProfile: String, Codable, Sendable { case standard, foreground }

    var windowBackgroundPlacement: WindowBackgroundPlacement = .content
    var backgroundOwner: BackgroundOwner = .host
    var backgroundDimming: BackgroundDimming = .host
    var artworkLayout: ArtworkLayout = .foreground
    var lyricsBackdrop: LyricsBackdrop = .standard
    var controlForeground: ControlForeground = .chrome
    var movesArtworkWithControls: Bool = true
    var artBackgroundResourceProfile: ArtBackgroundResourceProfile = .standard
}

struct SkinAudioDefaults: Codable {
    var window: AudioVisualizationPlacement = .miniPlayerSpectrum
    var fullscreen: AudioVisualizationPlacement = .off
    var supportsEmbeddedVisualizer: Bool = true
    var supportsMiniPlayerVisualization: Bool = true
    var hasLedMeter: Bool = true
}

struct SkinArtworkDefaults: Codable {
    var scale: Double = 1.1
    var maximumScale: Double = 1.6
}

/// Historic keys and generated values remain separate from current capabilities.
struct SkinLegacySettings: Codable {
    let visualizerNamespace: String
    var previousFullscreenVisualization: AudioVisualizationPlacement = .skinLED
    var defaultsMiniPlayerSpectrumOn: Bool = true
    var visualizerActivationKind: AudioVisualizationKind?
    var entryBooleanKey: String?

    func visualizerKey(scope: AudioVisualizationScope) -> String {
        let suffix = scope == .fullscreen ? ".fullscreen.visualizerMode" : ".visualizerMode"
        return visualizerNamespace + suffix
    }
}

struct SkinDescriptor: Codable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let systemImage: String
    var surfaces: Set<SkinSurface> = [.window, .fullscreen]
    var presentation = SkinPresentationPolicy()
    var audio = SkinAudioDefaults()
    var artwork = SkinArtworkDefaults()
    var fullscreenTypography: FullscreenLyricsTypography = .defaultValue
    var fullscreenDimming: Double = AppSettings.FullscreenDefaults.dimmingIntensity
    var fullscreenOrder: Int = 500
    var legacy: SkinLegacySettings?

    func withIdentity(id: String, name: String) -> Self {
        Self(id: id, name: name, detail: detail, systemImage: systemImage,
             surfaces: surfaces, presentation: presentation, audio: audio,
             artwork: artwork, fullscreenTypography: fullscreenTypography,
             fullscreenDimming: fullscreenDimming, fullscreenOrder: fullscreenOrder, legacy: legacy)
    }

    static var coverTypography: FullscreenLyricsTypography {
        FullscreenLyricsTypography(
            mainFontNameZh: LyricsFontDefaults.skinChinese,
            mainFontNameEn: LyricsFontDefaults.skinEnglish,
            translationFontName: LyricsFontDefaults.skinTranslation,
            mainFontWeight: 600,
            translationFontWeight: 600,
            mainFontSize: 64,
            translationFontSize: 24
        )
    }

    static var backdropTypography: FullscreenLyricsTypography {
        var typography = FullscreenLyricsTypography.defaultValue
        typography.mainFontWeight = 100
        typography.translationFontWeight = 300
        return typography
    }
}

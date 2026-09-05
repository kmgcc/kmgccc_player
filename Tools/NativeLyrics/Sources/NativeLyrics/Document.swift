import Foundation

/// All public times are seconds in the media domain. Source timing is never rewritten.
public struct LyricRange: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    public var duration: Double { max(0, end - start) }
    public func contains(_ time: Double) -> Bool { start <= time && time < end }
}

public struct RubySyllable: Equatable, Codable, Sendable {
    public var text: String
    public var range: LyricRange
}

public struct LyricWord: Equatable, Codable, Sendable {
    public var id: String
    public var text: String
    public var range: LyricRange
    public var ruby: [RubySyllable] = []
    public var romanization = ""
    public var obscene = false
    public var emptyBeat: Int?
}

public struct LyricTextLayer: Equatable, Codable, Sendable {
    public var language: String
    public var text: String
    public var words: [LyricWord] = []
}

public struct LyricLine: Equatable, Codable, Sendable {
    public var id: String
    public var range: LyricRange
    public var words: [LyricWord]
    public var translations: [LyricTextLayer] = []
    public var romanizations: [LyricTextLayer] = []
    public var isWordTimed = false
    public var isBackground = false
    public var isDuet = false
    public var agent = ""
    public var language = ""
    public var text: String { words.map(\.text).joined() }
}

public struct LyricGroup: Equatable, Codable, Sendable {
    public var main: LyricLine
    public var background: LyricLine?
    public var id: String { main.id }
}

public struct LyricsDocument: Equatable, Codable, Sendable {
    public var groups: [LyricGroup]
    public var title: String
    public var duration: Double
    public var diagnostics: [String]
    public var isWordTimed: Bool { groups.contains { $0.main.isWordTimed } }
    public var hasDuet: Bool { groups.contains { $0.main.isDuet } }
}

public enum LyricsProfile: String, CaseIterable, Codable, Sendable {
    case currentPlayer, upstream
}

public enum HighlightMode: String, CaseIterable, Codable, Sendable { case smooth, discrete }
public enum LyricAlignment: String, CaseIterable, Codable, Sendable { case top, center, bottom }
public enum ObscenityMode: String, CaseIterable, Sendable { case disabled, full, partial }

/// The two semantic cover-blur profiles used by the APP adapter.
public enum LyricsCoverBlurProfile: String, CaseIterable, Sendable {
    case lighter, darker
}

/// Selects which of the native lyric channels is emitted for a cover-blur
/// compositor. `full` is the normal single-surface path; `base` and
/// `highlight` are intended for hosts that composite two lyric surfaces over
/// a blurred cover image.
public enum LyricsRenderLayer: String, CaseIterable, Sendable {
    case full, base, highlight
}

/// Blend modes exposed by the APP adapter. `automatic` lets a cover-blur
/// surface select its lighter/darker compositor while keeping the normal
/// window surface unmodified.
public enum LyricsBlendMode: String, CaseIterable, Codable, Sendable {
    case automatic, normal, plusLighter, plusDarker
}

public enum LyricsSurfaceStyle: String, CaseIterable, Sendable {
    case window, artisticFullscreen, coverBlurLight, coverBlurDark, appleStyle, coreReference
    var opaque: Bool { self != .window && self != .coreReference }
}

/// Semantic colors are supplied by the host ThemeStore adapter, including Display P3 values.
public struct LyricsColor: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public var displayP3: Bool
    public init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1, displayP3: Bool = false) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.displayP3 = displayP3
    }
    public static let white = Self(1,1,1)
    public static let black = Self(0,0,0)
}

public struct LyricsPalette: Equatable, Sendable {
    public var mainActive = LyricsColor.white
    public var mainInactive = LyricsColor(0.42,0.44,0.49)
    public var translation = LyricsColor(0.48,0.50,0.55)
    public var backgroundActive = LyricsColor(0.84,0.84,0.84)
    public var backgroundInactive = LyricsColor(0.38,0.40,0.44)
    public var backgroundKaraoke = LyricsColor(0.90,0.91,0.93)
    public var emphasisGlow = LyricsColor.white
    public var backgroundBaseOpacity = 0.38
    public var backgroundKaraokeOpacity = 0.84
    public init() {}
}

public struct LyricsConfiguration: Equatable, Sendable {
    public var profile: LyricsProfile = .currentPlayer
    public var fontName = "Helvetica Neue"
    public var fontSize: Double = 38
    public var fontWeight: Double = 0.4
    public var translationFontName = "Helvetica Neue"
    public var translationFontWeight: Double = 0
    public var translationFontSize: Double? = nil
    public var surface: LyricsSurfaceStyle = .window
    public var palette = LyricsPalette()
    /// Additional host opacity applied after the lyric channels are composed.
    /// This mirrors the adapter's `blendOpacity` without changing mask alpha.
    public var blendOpacity: Double = 1
    public var blendMode: LyricsBlendMode = .automatic
    public var coverBlurProfile: LyricsCoverBlurProfile = .lighter
    public var coverBlurRenderLayer: LyricsRenderLayer = .full
    public var coverBlurHideActiveMainLine = false
    public var coverBlurSuppressEmphasisGlow = false
    public var coverBlurGenericMode = false
    public var coverBlurThemeColor: LyricsColor?
    public var fullscreenAppleStyleMode = false
    public var fullscreenLyricDodgeMode = false
    public var preserveCompletedHighlight = true
    public var lineTimingOnly = false
    public var hoverBackground = false
    public var alignPosition: Double = 0.35
    /// A settled host supplied offset for the focus position. It is applied
    /// in points after focus/scroll geometry and never gets a second spring.
    public var alignOffset: Double = 0
    public var alignAnchor: LyricAlignment = .center
    public var highlightMode: HighlightMode = .smooth
    public var wordFadeWidth: Double = 0.5
    public var emphasis = true
    public var glow = true
    public var glowRadiusScale: Double = 1
    public var blur = true
    public var scale = true
    public var spring = true
    public var hidePassedLines = false
    public var alwaysPostpositionBackground = false
    public var translationLanguage = "zh-Hans"
    public var romanizationLanguage = ""
    public var showTranslation = true
    public var showRomanization = true
    public var showRuby = true
    public var obscenity: ObscenityMode = .disabled
    public var maskCharacter = "*"
    public var timing = LyricsTimingConfiguration()
    public var positionSpring: SpringParameters?
    public var bottomText = ""
    public var cacheBudgetBytes = 64 * 1024 * 1024
    public var overscan: Double = 300
    /// Raster quality relative to the backing scale. Values below one are
    /// useful for an always-on fullscreen surface and match APP renderScale.
    public var renderScale: Double = 1
    /// Zero follows the display's native cadence; otherwise the display link
    /// is capped to this rate, matching APP fpsCap semantics.
    public var fpsCap: Int = 0
    public init() {}

    var usesCoverBlurCompositing: Bool {
        surface == .coverBlurLight || surface == .coverBlurDark
            || (coverBlurGenericMode && surface != .window && surface != .coreReference)
    }

    var usesOpaqueCompositing: Bool {
        surface.opaque || fullscreenLyricDodgeMode || usesCoverBlurCompositing
    }

    var effectiveCoverBlurProfile: LyricsCoverBlurProfile {
        coverBlurProfile
    }

    public var effectiveRenderLayer: LyricsRenderLayer {
        usesCoverBlurCompositing ? coverBlurRenderLayer : .full
    }
}

public struct LyricsTimingConfiguration: Equatable, Sendable {
    public var enabled = true
    /// Track correction used for the presentation timeline. The host may set
    /// this to the APP combined `trackOffset - globalAdvance` value.
    public var trackOffset: Double = 0
    /// Source correction applied only to the time sent back after a lyric
    /// click. This is the APP `seekTimeOffsetMs` value; it must not inherit a
    /// global visual advance.
    public var seekOffset: Double = 0
    public var globalAdvance: Double = 0
    public var leadIn: Double = 0.6
    public var nearSwitchGap: Double = 0.16
    public init() {}
}

public enum LyricsError: Error, LocalizedError {
    case invalidTTML(String)
    public var errorDescription: String? {
        switch self { case .invalidTTML(let message): return message }
    }
}

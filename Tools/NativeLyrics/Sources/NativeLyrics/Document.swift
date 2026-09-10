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
    /// The optional AMLL `itunes:song-part` value inherited from the
    /// containing `<div>`.
    public var songPart: String?
    /// The source-order block index used to distinguish repeated song parts.
    public var blockIndex: Int?
    public var text: String { words.map(\.text).joined() }

    public init(
        id: String,
        range: LyricRange,
        words: [LyricWord],
        translations: [LyricTextLayer] = [],
        romanizations: [LyricTextLayer] = [],
        isWordTimed: Bool = false,
        isBackground: Bool = false,
        isDuet: Bool = false,
        agent: String = "",
        language: String = "",
        songPart: String? = nil,
        blockIndex: Int? = nil
    ) {
        self.id = id
        self.range = range
        self.words = words
        self.translations = translations
        self.romanizations = romanizations
        self.isWordTimed = isWordTimed
        self.isBackground = isBackground
        self.isDuet = isDuet
        self.agent = agent
        self.language = language
        self.songPart = songPart
        self.blockIndex = blockIndex
    }

    /// Whether this line contains enough distinct word timing to support a
    /// karaoke sweep. A number of LDDC-to-TTML converters wrap an entire LRC
    /// line in one timed span. That span is still line-timed (the renderer can
    /// use one continuous line-level mask), but it is not independent word
    /// timing and must not opt into the per-word karaoke layout path.
    public var hasEffectiveWordTiming: Bool {
        var first: LyricRange?
        var count = 0
        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.range.start.isFinite, word.range.end.isFinite else { continue }
            count += 1
            if let first {
                if abs(word.range.start - first.start) > 0.001
                    || abs(word.range.end - first.end) > 0.001 {
                    return count >= 2
                }
            } else {
                first = word.range
            }
        }
        return false
    }
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
    public var timingMode: TTMLTimingMode
    /// AMLL metadata is retained by key so host integrations can consume
    /// platform IDs, author information, and custom `amll:meta` values
    /// without reparsing the source XML.
    public var metadata: [String: [String]]

    public init(
        groups: [LyricGroup],
        title: String,
        duration: Double,
        diagnostics: [String],
        timingMode: TTMLTimingMode = .word,
        metadata: [String: [String]] = [:]
    ) {
        self.groups = groups
        self.title = title
        self.duration = duration
        self.diagnostics = diagnostics
        self.timingMode = timingMode
        self.metadata = metadata
    }
    public var isWordTimed: Bool {
        groups.contains {
            $0.main.hasEffectiveWordTiming || $0.background?.hasEffectiveWordTiming == true
        }
    }
    public var hasDuet: Bool { groups.contains { $0.main.isDuet } }
}

public enum TTMLTimingMode: String, CaseIterable, Codable, Sendable {
    case word = "Word"
    case line = "Line"
}

/// The time semantics of the input document. AMLL TTML is media-absolute by
/// default; generic W3C parent-relative timing is available only explicitly.
public enum TTMLTimingProfile: String, CaseIterable, Codable, Sendable {
    case amllAbsolute
    case w3cRelative
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
    /// In fullscreen AMLL skins a line-timed document has its own inactive
    /// tone.  Window palettes leave these equal to `mainInactive`; keeping
    /// the channel explicit prevents the native renderer from silently
    /// dropping the skin's line-timing colors.
    public var lineTimingInactive = LyricsColor(0.42,0.44,0.49)
    public var translation = LyricsColor(0.48,0.50,0.55)
    public var lineTimingSubInactive = LyricsColor(0.48,0.50,0.55)
    public var backgroundActive = LyricsColor(0.84,0.84,0.84)
    public var backgroundInactive = LyricsColor(0.38,0.40,0.44)
    public var backgroundKaraoke = LyricsColor(0.90,0.91,0.93)
    public var emphasisGlow = LyricsColor.white
    public var backgroundBaseOpacity = 0.38
    public var backgroundKaraokeOpacity = 0.84
    public init() {}
}

public struct LyricsConfiguration: Equatable, Sendable {
    /// Native behavior and channel controls; hosts need no layer-tree patches.
    public var motion = LyricsMotionConfiguration()
    public var channelBlend = LyricsChannelBlendConfiguration()
    public var profile: LyricsProfile = .currentPlayer
    /// Main Latin/English family. CJK glyphs use `fontNameCJK` when supplied;
    /// keeping the two families separate is required for fullscreen typography
    /// settings, whose CSS fallback list cannot express per-script weight.
    public var fontName = "Helvetica Neue"
    public var fontNameCJK: String? = nil
    public var fontSize: Double = 38
    public var fontWeight: Double = 0.4
    public var translationFontName = "Helvetica Neue"
    public var translationFontWeight: Double = 0
    public var translationFontSize: Double? = nil
    public var surface: LyricsSurfaceStyle = .window
    public var palette = LyricsPalette()
    /// Optional host backdrop, composed behind both ink channels.
    public var backdropColor: LyricsColor? = nil
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
    /// Relative diameter of the three-dot interlude indicator. The indicator
    /// keeps a centered transform anchor while this value changes its size.
    /// Slightly larger than the original native size so the marker remains
    /// legible in the compact window and fullscreen density settings.
    public var interludeDotScale: Double = 1.15
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

public struct LyricsMotionConfiguration: Equatable, Sendable {
    /// Keep inactive rows legible over artwork. The old native defaults were
    /// noticeably heavier than AMLL's 5px CSS cap once Core Image and the
    /// distance falloff were combined.
    public var blurRadius: Double = 2.25
    public var maximumBlurRadius: Double = 4.5
    public var blurTransition: Double = 0.45
    /// Delay before blur returns after pointer exit. The Demo and native
    /// default are zero: blur starts immediately; hosts may opt into a delay.
    public var pointerExitDelay: Double = 0
    public var clickStagger: Double = 0.055
    public var backgroundTransition: Double = 0.35
    /// Resize/configuration reflow uses a critically damped track by default.
    /// This keeps newly wrapped half-lines continuous without the large bounce
    /// that is useful for a focus change but distracting during window resize.
    public var resizeSpring = SpringParameters(mass: 1, damping: 22, stiffness: 120, soft: true)
    public var exitFade: Double = 0.28
    public var catchUpMinimum: Double = 0.12
    public var catchUpMaximum: Double = 0.28
    /// Bounded anticipation through authored word gaps, never a trailing filter.
    public var highlightAnticipation: Double = 0.12
    public init() {}
}

public struct LyricsChannelBlendConfiguration: Equatable, Sendable {
    /// All nil inherits the surface preset. When any mode is set, remaining
    /// nil channels use normal blending. Modes compose individual ink channels.
    public var inactive: LyricsBlendMode?
    public var current: LyricsBlendMode?
    public var highlight: LyricsBlendMode?
    public init(inactive: LyricsBlendMode? = nil, current: LyricsBlendMode? = nil, highlight: LyricsBlendMode? = nil) {
        self.inactive = inactive; self.current = current; self.highlight = highlight
    }
    var isExplicit: Bool { inactive != nil || current != nil || highlight != nil }
}

public enum LyricsSeekMotion: Sendable { case immediate, cascade, preview }

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

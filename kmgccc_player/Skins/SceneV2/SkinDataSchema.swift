import AppKit
import MotionKit
import SwiftUI

/// How often a value can change. The renderer evaluates frame-tier expressions in a display
/// timeline only on the nodes that use them; everything else re-evaluates on change.
enum SkinDataTier: Int, Comparable {
    case constant = 0
    case change = 1
    case frame = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The owners a scene reads from. A scene subscribes only to the domains it references.
enum SkinDataDomain: String, CaseIterable, Hashable {
    case track, artwork, playback, clock, lyrics, lyricsTimeline, theme, audio
    case viewport, host, prefs, params, state, like, queue, library, output, time, local
}

struct SkinDataField {
    let type: SkinValueType
    let tier: SkinDataTier
    let domain: SkinDataDomain
    let capability: String
}

/// The data half of the capability contract. Every path an expression can name is listed here;
/// the theme roles are generated from the same table the runtime reads, so the two cannot drift.
enum SkinDataSchema {
    static let fields: [String: SkinDataField] = {
        var fields: [String: SkinDataField] = [:]
        func add(_ capability: String, _ domain: SkinDataDomain, _ tier: SkinDataTier, _ entries: [(String, SkinValueType)]) {
            for (path, type) in entries {
                fields[path] = SkinDataField(type: type, tier: tier, domain: domain, capability: capability)
            }
        }

        add("track@1", .track, .change, [
            ("track.hasTrack", .boolean), ("track.id", .text), ("track.title", .text), ("track.artist", .text),
            ("track.album", .text), ("track.duration", .number), ("track.source", .text), ("track.emptyTitleKey", .text),
            ("track.external.rawTitle", .text), ("track.external.rawArtist", .text), ("track.external.rawAlbum", .text),
            ("track.external.effectiveTitle", .text), ("track.external.effectiveArtist", .text),
            ("track.external.effectiveAlbum", .text), ("track.external.usesOverride", .boolean),
            ("track.external.matchConfidence", .number), ("track.external.connectionState", .text),
            ("track.external.lyricsStatusMessage", .text), ("track.external.lyricsTimeOffset", .number),
            ("track.metadataSources", .record),
        ])
        add("track.enrichment@1", .track, .change, [("track.enrichment", .record), ("track.hasMusicInfo", .boolean)])
        // Format, codec, bitrate, sampleRate, bitDepth, channels, isLossless and isHiRes of a local file.
        add("track.audio@1", .track, .change, [("track.audio", .record)])

        add("artwork@1", .artwork, .change, [
            ("artwork.available", .boolean), ("artwork.identity", .text), ("artwork.checksum", .number),
            ("artwork.isLoading", .boolean), ("artwork.width", .number), ("artwork.height", .number),
            ("artwork.aspectRatio", .number), ("artwork.averageColor", .color), ("artwork.palette", .list),
        ])
        add("artwork.motion@1", .artwork, .change, [
            ("artwork.hasMotion", .boolean), ("artwork.hasTallMotion", .boolean),
        ])

        add("playback@1", .playback, .change, [
            ("playback.isPlaying", .boolean), ("playback.volume", .number), ("playback.duration", .number),
            ("playback.orderMode", .text), ("playback.appleMusicMode", .text), ("playback.isLocal", .boolean),
            ("playback.canControl", .boolean), ("playback.canSeek", .boolean), ("playback.canSetVolume", .boolean),
            ("playback.canSetOrderMode", .boolean), ("playback.hasTrack", .boolean), ("playback.audioOutputDelay", .number),
        ])
        add("clock.playback@1", .clock, .frame, [
            ("clock.position", .number), ("clock.progress", .number), ("clock.remaining", .number), ("clock.rate", .number),
        ])
        add("clock.lyrics@1", .clock, .frame, [("clock.lyrics", .number)])
        add("time@1", .time, .frame, [("time", .number)])

        add("lyrics.document@1", .lyrics, .change, [
            ("lyrics.available", .boolean), ("lyrics.availability", .text), ("lyrics.revision", .number),
            ("lyrics.lineCount", .number), ("lyrics.lines", .list), ("lyrics.title", .text),
            ("lyrics.duration", .number), ("lyrics.timingMode", .text), ("lyrics.isWordTimed", .boolean),
            ("lyrics.hasDuet", .boolean), ("lyrics.metadata", .record),
        ])
        add("lyrics.source@1", .lyrics, .change, [("lyrics.sourceTTML", .text)])
        add("lyrics.prefs@1", .lyrics, .change, [
            ("lyrics.prefs.showTranslation", .boolean), ("lyrics.prefs.showRomanization", .boolean),
            ("lyrics.prefs.showRuby", .boolean), ("lyrics.prefs.translationLanguage", .text),
            ("lyrics.prefs.romanizationLanguage", .text), ("lyrics.prefs.fontSize", .number),
            ("lyrics.prefs.fontFamily", .text), ("lyrics.prefs.translationFontSize", .number),
            ("lyrics.prefs.obscenity", .text),
        ])
        add("lyrics.derived@1", .lyricsTimeline, .frame, [
            ("lyrics.currentIndex", .number), ("lyrics.current", .record), ("lyrics.previous", .record),
            ("lyrics.next", .record), ("lyrics.upcoming", .list), ("lyrics.recent", .list),
            ("lyrics.lineProgress", .number), ("lyrics.wordIndex", .number), ("lyrics.wordProgress", .number),
            ("lyrics.isInterlude", .boolean), ("lyrics.interludeProgress", .number), ("lyrics.songPart", .text),
        ])

        add("theme@1", .theme, .change, SkinThemeRoles.colorRoles.map { ($0.path, SkinValueType.color) } + [
            ("theme.scheme", .text), ("theme.isDark", .boolean), ("theme.accent", .color),
            ("theme.hasArtworkColor", .boolean), ("theme.palette", .list), ("theme.averageColor", .color),
            ("theme.spectrumColors", .list), ("theme.spectrumUsesDarkForeground", .boolean),
            ("theme.artBackgroundIsUltraDark", .boolean), ("theme.readability.usesDarkForeground", .boolean),
            ("theme.roles", .record),
            ("theme.readability.isNearMonochrome", .boolean),
        ])
        add("theme.foreground@1", .theme, .change, SkinThemeRoles.foregroundStrategies.flatMap { strategy in
            ["primary", "secondary", "disabled", "pillTint"].map { ("theme.controlForeground.\(strategy.rawValue).\($0)", SkinValueType.color) }
        })
        add("theme.analysis@1", .theme, .change, SkinThemeRoles.analysisFields.map { ($0.path, $0.type) })

        add("audio.raw@1", .audio, .frame, [
            ("audio.available", .boolean), ("audio.availability", .text), ("audio.rms", .number), ("audio.peak", .number),
            ("audio.fastRMS", .number), ("audio.fastPeak", .number), ("audio.level", .number),
            ("audio.sampleRate", .number), ("audio.fftSize", .number),
            ("audio.pcm", .list), ("audio.fft", .list), ("audio.windowLength", .number), ("audio.timestamp", .number),
        ])
        add("audio.bands@1", .audio, .frame, [
            ("audio.bass", .number), ("audio.lowMid", .number), ("audio.mid", .number), ("audio.vocal", .number),
            ("audio.treble", .number), ("audio.beat", .number),
        ])
        add("audio.led@1", .audio, .frame, [("audio.ledLevel", .number), ("audio.leds", .list)])

        add("viewport@1", .viewport, .change, [
            ("viewport.width", .number), ("viewport.height", .number), ("viewport.w", .number), ("viewport.h", .number),
            ("viewport.min", .number), ("viewport.max", .number), ("viewport.aspect", .number),
            ("viewport.displayScale", .number), ("viewport.maximumRefreshRate", .number), ("viewport.surface", .text),
            ("viewport.fullscreenHost", .text), ("viewport.isFullscreen", .boolean), ("viewport.colorScheme", .text),
            ("viewport.isDark", .boolean), ("viewport.reduceMotion", .boolean), ("viewport.reduceTransparency", .boolean),
            ("viewport.increaseContrast", .boolean), ("viewport.safeArea", .record),
        ])
        // MotionKit token durations in seconds after the user's motion speed, for timing written in expressions.
        add("motion@1", .viewport, .change, MotionToken.allCases.map { ("motion.\($0.rawValue)", SkinValueType.number) } + [("motion.speed", .number)])
        add("host@1", .host, .change, [
            ("host.isActive", .boolean), ("host.lyricsVisible", .boolean), ("host.queueVisible", .boolean),
            ("host.isKeyWindow", .boolean), ("host.pointerInside", .boolean), ("host.reservedControls", .record),
            ("host.layout", .record),
        ])
        add("host.pointer@1", .host, .frame, [("host.pointerIdleTime", .number)])
        add("host.pointer@1", .host, .change, [("host.pointerIdle", .boolean)])
        add("prefs@1", .prefs, .change, [
            ("prefs.fullscreenDimming", .number), ("prefs.artBackgroundEnabled", .boolean),
            ("prefs.artworkScale", .number), ("prefs.miniPlayerAutoHide", .number),
            ("prefs.miniPlayerGlass", .text), ("prefs.lyricsRenderQuality", .text), ("prefs.visualizerMode", .text),
            ("prefs.cassetteKmgLook", .boolean),
        ])
        add("like@1", .like, .change, [("like.isLiked", .boolean), ("like.available", .boolean)])
        add("like.state@1", .like, .change, [("like.state", .text), ("like.isDisliked", .boolean)])
        add("queue@1", .queue, .change, [
            ("queue.count", .number), ("queue.position", .number), ("queue.upNext", .list),
        ])
        add("queue.items@1", .queue, .change, [
            ("queue.items", .list), ("queue.currentIndex", .number), ("queue.title", .text), ("queue.available", .boolean),
        ])
        add("library.playlists@1", .library, .change, [("library.playlists", .list), ("library.canEditTrack", .boolean)])
        add("output@1", .output, .change, [
            ("output.name", .text), ("output.symbol", .text), ("output.isBluetooth", .boolean),
            ("output.followsSystem", .boolean), ("output.devices", .list),
        ])
        return fields
    }()

    /// Namespaces whose members are declared by the package or the node, not by the host.
    static let declaredNamespaces: Set<String> = ["params", "state", "props", "item", "index", "self", "parent", "gesture", "count"]

    /// Longest registered prefix, so `lyrics.current.text` resolves to the `lyrics.current` record.
    static func field(for path: [String]) -> (field: SkinDataField, remainder: [String])? {
        guard !path.isEmpty else { return nil }
        for length in stride(from: path.count, through: 1, by: -1) {
            if let field = fields[path.prefix(length).joined(separator: ".")] {
                return (field, Array(path.dropFirst(length)))
            }
        }
        return nil
    }

    static var capabilities: Set<String> { Set(fields.values.map(\.capability)) }

    /// Suggest a nearby registered name for an unknown path.
    static func suggestion(for path: String) -> String? {
        let candidates = fields.keys.filter { $0.hasPrefix(path.split(separator: ".").first.map(String.init) ?? "") }
        return candidates.min { distance($0, path) < distance($1, path) }
    }

    private static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Every SemanticPalette colour role, by stable author-facing name.
enum SkinThemeRoles {
    struct ColorRole {
        let path: String
        let read: (SemanticPalette) -> NSColor
    }

    static let colorRoles: [ColorRole] = [
        .init(path: "theme.globalAccent") { $0.globalAccent },
        .init(path: "theme.uiAccentOnDark") { $0.uiAccentOnDark },
        .init(path: "theme.uiAccentOnLight") { $0.uiAccentOnLight },
        .init(path: "theme.ambientSurface") { $0.ambientSurface },
        .init(path: "theme.artBackgroundPrimary") { $0.artBackgroundPrimary },
        .init(path: "theme.artBackgroundSecondary") { $0.artBackgroundSecondary },
        .init(path: "theme.readableTextOnArtwork") { $0.readableTextOnArtwork },
        .init(path: "theme.secondaryTextOnArtwork") { $0.secondaryTextOnArtwork },
        .init(path: "theme.windowLyricActive") { $0.windowLyricActive },
        .init(path: "theme.windowLyricInactive") { $0.windowLyricInactive },
        .init(path: "theme.fullscreenLyricBase") { $0.fullscreenLyricBase },
        .init(path: "theme.fullscreenLyricInactiveBase") { $0.fullscreenLyricInactiveBase },
        .init(path: "theme.coverGradientDominant") { $0.coverGradientDominant },
        .init(path: "theme.coverGradientText") { $0.coverGradientText },
        .init(path: "theme.coverGradientTextCandidates.darkOnLightBackground") { $0.coverGradientTextCandidates.darkOnLightBackground },
        .init(path: "theme.coverGradientTextCandidates.lightOnDarkBackground") { $0.coverGradientTextCandidates.lightOnDarkBackground },
        .init(path: "theme.readability.foregroundPrimary") { $0.readabilityProfile.foregroundPrimary },
        .init(path: "theme.readability.foregroundSecondary") { $0.readabilityProfile.foregroundSecondary },
        .init(path: "theme.readability.foregroundTertiary") { $0.readabilityProfile.foregroundTertiary },
        .init(path: "theme.readability.foregroundQuaternary") { $0.readabilityProfile.foregroundQuaternary },
        .init(path: "theme.readability.iconForeground") { $0.readabilityProfile.iconForeground },
        .init(path: "theme.readabilityCandidates.darkOnLightBackground.foregroundPrimary") { $0.readabilityCandidates.darkOnLightBackground.foregroundPrimary },
        .init(path: "theme.readabilityCandidates.darkOnLightBackground.foregroundSecondary") { $0.readabilityCandidates.darkOnLightBackground.foregroundSecondary },
        .init(path: "theme.readabilityCandidates.lightOnDarkBackground.foregroundPrimary") { $0.readabilityCandidates.lightOnDarkBackground.foregroundPrimary },
        .init(path: "theme.readabilityCandidates.lightOnDarkBackground.foregroundSecondary") { $0.readabilityCandidates.lightOnDarkBackground.foregroundSecondary },
        .init(path: "theme.miniPlayerControl.primary") { $0.miniPlayerControl.primary },
        .init(path: "theme.miniPlayerControl.secondary") { $0.miniPlayerControl.secondary },
        .init(path: "theme.miniPlayerControl.progressFill") { $0.miniPlayerControl.progressFill },
        .init(path: "theme.miniPlayerControl.progressTrack") { $0.miniPlayerControl.progressTrack },
        .init(path: "theme.cassetteTint.shadow") { $0.cassetteTint.shadow },
        .init(path: "theme.cassetteTint.midtone") { $0.cassetteTint.midtone },
        .init(path: "theme.cassetteTint.highlight") { $0.cassetteTint.highlight },
        .init(path: "theme.plusBlendText.lightOnDarkBackground.primary") { $0.plusBlendText.lightOnDarkBackground.primary },
        .init(path: "theme.plusBlendText.lightOnDarkBackground.secondary") { $0.plusBlendText.lightOnDarkBackground.secondary },
        .init(path: "theme.plusBlendText.lightOnDarkBackground.tertiary") { $0.plusBlendText.lightOnDarkBackground.tertiary },
        .init(path: "theme.plusBlendText.lightOnDarkBackground.quaternary") { $0.plusBlendText.lightOnDarkBackground.quaternary },
        .init(path: "theme.plusBlendText.darkOnLightBackground.primary") { $0.plusBlendText.darkOnLightBackground.primary },
        .init(path: "theme.plusBlendText.darkOnLightBackground.secondary") { $0.plusBlendText.darkOnLightBackground.secondary },
        .init(path: "theme.plusBlendText.darkOnLightBackground.tertiary") { $0.plusBlendText.darkOnLightBackground.tertiary },
        .init(path: "theme.plusBlendText.darkOnLightBackground.quaternary") { $0.plusBlendText.darkOnLightBackground.quaternary },
        .init(path: "theme.appForeground.primary") { $0.appForeground.primary },
        .init(path: "theme.appForeground.secondary") { $0.appForeground.secondary },
        .init(path: "theme.appForeground.tertiary") { $0.appForeground.tertiary },
        .init(path: "theme.appForeground.quaternary") { $0.appForeground.quaternary },
        .init(path: "theme.appForeground.disabled") { $0.appForeground.disabled },
        .init(path: "theme.lyrics.windowActive") { $0.lyrics.windowActive },
        .init(path: "theme.lyrics.windowInactive") { $0.lyrics.windowInactive },
        .init(path: "theme.lyrics.fullscreenBase") { $0.lyrics.fullscreenBase },
        .init(path: "theme.lyrics.fullscreenInactiveBase") { $0.lyrics.fullscreenInactiveBase },
        .init(path: "theme.lyrics.mainActive") { $0.lyrics.fullscreen.mainActive },
        .init(path: "theme.lyrics.mainInactive") { $0.lyrics.fullscreen.mainInactive },
        .init(path: "theme.lyrics.lineTimingMainInactive") { $0.lyrics.fullscreen.lineTimingMainInactive },
        .init(path: "theme.lyrics.subActive") { $0.lyrics.fullscreen.subActive },
        .init(path: "theme.lyrics.subInactive") { $0.lyrics.fullscreen.subInactive },
        .init(path: "theme.lyrics.lineTimingSubInactive") { $0.lyrics.fullscreen.lineTimingSubInactive },
    ]

    /// SemanticPalette members that are not colour roles but are exposed through other fields.
    static let nonColorMembers: Set<String> = ["scheme", "analysis"]

    /// Top-level SemanticPalette members covered by `colorRoles`, used by the contract audit.
    static var coveredMembers: Set<String> {
        Set(colorRoles.compactMap { role in
            role.path.split(separator: ".").dropFirst().first.map(String.init)
        }).union(["readabilityProfile"]).union(nonColorMembers)
    }

    static let foregroundStrategies: [SkinPresentationPolicy.ControlForeground] = [.chrome, .artworkAdaptive, .fixedLight, .artistic]

    struct AnalysisField {
        let path: String
        let type: SkinValueType
        let read: (ArtworkColorAnalysis) -> SkinValue
    }

    static let analysisFields: [AnalysisField] = [
        .init(path: "theme.analysis.averageHue", type: .number) { .number(Double($0.avgHue) * 360) },
        .init(path: "theme.analysis.dominantHue", type: .number) { .number(Double($0.dominantHue) * 360) },
        .init(path: "theme.analysis.dominantHueConfidence", type: .number) { .number(Double($0.dominantHueConfidence)) },
        .init(path: "theme.analysis.averageSaturation", type: .number) { .number(Double($0.avgSaturation)) },
        .init(path: "theme.analysis.averageBrightness", type: .number) { .number(Double($0.avgBrightness)) },
        .init(path: "theme.analysis.averageLightness", type: .number) { .number(Double($0.avgHslLightness)) },
        .init(path: "theme.analysis.weightedLuma", type: .number) { .number(Double($0.weightedLuma)) },
        .init(path: "theme.analysis.colorfulness", type: .number) { .number(Double($0.colorfulness)) },
        .init(path: "theme.analysis.brightAreaRatio", type: .number) { .number(Double($0.brightAreaRatio)) },
        .init(path: "theme.analysis.darkAreaRatio", type: .number) { .number(Double($0.darkAreaRatio)) },
        .init(path: "theme.analysis.isMonochrome", type: .boolean) { .boolean($0.isMonochrome) },
        .init(path: "theme.analysis.isNearMonochrome", type: .boolean) { .boolean($0.isNearMonochrome) },
        .init(path: "theme.analysis.isUltraDark", type: .boolean) { .boolean($0.isUltraDark) },
    ]
}

/// Contract audit: a new SemanticPalette member without an author-facing name fails here.
enum SkinContractAudit {
    static func uncoveredPaletteMembers(_ palette: SemanticPalette) -> [String] {
        Mirror(reflecting: palette).children.compactMap(\.label)
            .filter { !SkinThemeRoles.coveredMembers.contains($0) }
            .sorted()
    }
}

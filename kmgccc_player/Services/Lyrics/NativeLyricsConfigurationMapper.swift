//
//  NativeLyricsConfigurationMapper.swift
//  myPlayer2
//
//  Translates the existing public lyrics settings payload into the reusable
//  NativeLyrics configuration. The JSON shape is kept as an input bridge for
//  fullscreen skin adapters, but the renderer never depends on that payload.
//

import Foundation
import NativeLyrics
import SwiftUI

enum NativeLyricsConfigurationMapper {
    static func makeWindowConfiguration(
        settings: AppSettings,
        palette: ThemePalette?,
        playbackSource: PlaybackSource,
        currentTrack: Track?,
        lyricsTimeOffsetMs: Double? = nil,
        role: LyricsSurfaceRole = .main
    ) -> LyricsConfiguration {
        let isDark = ThemeStore.shared.colorScheme == .dark
        let weight = isDark ? settings.lyricsFontWeightDark : settings.lyricsFontWeightLight
        let translationWeight = isDark
            ? settings.lyricsTranslationFontWeightDark
            : settings.lyricsTranslationFontWeightLight
        let rawTrackOffset = max(-15000, min(15000, lyricsTimeOffsetMs
            ?? (playbackSource.isExternal ? 0 : (currentTrack?.lyricsTimeOffsetMs ?? 0))))
        let globalAdvance = settings.lyricsGlobalAdvanceMs
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: .mainPanel,
            playbackSource: playbackSource
        )

        var config = base(role: role)
        config.fontName = firstFontName(settings.lyricsFontNameEn, fallback: LyricsFontDefaults.english)
        config.fontNameCJK = firstFontName(settings.lyricsFontNameZh, fallback: LyricsFontDefaults.chinese)
        config.fontSize = settings.lyricsFontSize
        config.fontWeight = cssWeight(Double(weight))
        config.translationFontName = firstFontName(
            settings.lyricsTranslationFontName,
            fallback: LyricsFontDefaults.translation
        )
        config.translationFontSize = settings.lyricsTranslationFontSize
        config.translationFontWeight = cssWeight(Double(translationWeight))
        config.highlightMode = settings.amllDiscreteWordHighlightEnabled ? .discrete : .smooth
        // `trackOffset - globalAdvance` is the established player contract;
        // the runtime overlay is already part of the effective global value.
        config.timing.trackOffset = (rawTrackOffset - globalAdvance - overlay.globalAdvanceDeltaMs) / 1000
        config.timing.seekOffset = rawTrackOffset / 1000
        config.timing.leadIn = max(0, settings.lyricsLeadInMs) / 1000
        config.timing.nearSwitchGap = max(0, min(500, settings.lyricsNearSwitchGapMs)) / 1000
        config.wordFadeWidth = role.wordFadeWidth
        config.palette = palette.map(paletteForWindow) ?? config.palette
        config.positionSpring = NativeLyricsSurfaceManager.springParameters(
            from: settings.lyricSpringUserSettings
        )
        config.spring = role.enableSpring && settings.amllLyricsSpringEnabled
        config.blur = role.enableBlur
        // NativeLyrics owns its layer-backed rasterization and is fast enough
        // to stay at the display's full backing resolution. The old AMLL
        // quality preference remains a compatibility value for the rollback
        // WebView path, but must not downsample the native surface.
        config.renderScale = role == .batchPreview ? role.renderScale : 1
        config.fpsCap = role.fpsCap
        config.overscan = Double(role.overscanPx)
        return config
    }

    static func base(role: LyricsSurfaceRole) -> LyricsConfiguration {
        var configuration = LyricsConfiguration()
        configuration.profile = .currentPlayer
        configuration.surface = .window
        configuration.blur = role.enableBlur
        configuration.spring = role.enableSpring
        configuration.renderScale = role == .batchPreview ? role.renderScale : 1
        configuration.fpsCap = role.fpsCap
        configuration.overscan = Double(role.overscanPx)
        configuration.wordFadeWidth = role.wordFadeWidth
        // The package default is intentionally conservative for the standalone
        // demo. Keep the player marker legible without letting the breathing
        // transform dominate the compact lyric column.
        configuration.interludeDotScale = {
            switch role {
            case .main: return 1.6
            case .fullscreen, .fullscreenCoverBlurHighlight, .standalone: return 1.45
            case .batchPreview: return 1.3
            }
        }()
        // The main inspector used the package default (0.35), which leaves
        // the focused row noticeably low once the panel's top padding is
        // applied. Keep fullscreen's skin-owned top anchor untouched while
        // giving the window surface the same slightly-upward reading position
        // as the old AMLL panel.
        if role == .main { configuration.alignPosition = 0.27 }
        configuration.glow = true
        configuration.emphasis = true
        configuration.showTranslation = true
        configuration.showRomanization = true
        configuration.showRuby = true
        return configuration
    }

    /// Apply one of the existing fullscreen theme payloads. This lets the
    /// fullscreen skin code keep its semantic color decisions while routing
    /// the actual rendering through the package's public API.
    static func fromJSON(
        _ json: String,
        role: LyricsSurfaceRole,
        fallback: LyricsConfiguration? = nil
    ) -> LyricsConfiguration? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var configuration = fallback ?? base(role: role)
        apply(object, to: &configuration, role: role)
        return configuration
    }

    static func apply(_ values: [String: Any], to configuration: inout LyricsConfiguration, role: LyricsSurfaceRole) {
        if let value = double(values["fontSize"]) { configuration.fontSize = max(10, value) }
        if let value = double(values["fontWeight"]) { configuration.fontWeight = cssWeight(value) }
        var mainFamilies: [String] = []
        if let value = string(values["fontFamilyMain"]) {
            mainFamilies = fontNames(value)
            configuration.fontName = mainFamilies.first ?? configuration.fontName
        }
        if let value = string(values["fontFamilyLatin"]) {
            configuration.fontName = firstFontName(value, fallback: configuration.fontName)
        }
        if let value = string(values["fontFamilyCJK"]) {
            configuration.fontNameCJK = firstFontName(value, fallback: configuration.fontNameCJK ?? LyricsFontDefaults.chinese)
        } else if configuration.fontNameCJK == nil, let fallbackCJK = mainFamilies.last {
            // Backward-compatible parsing for older JSON that only carried a
            // CSS family list: the last non-system candidate is the intended
            // CJK family in LyricsFontResolver's ordering.
            configuration.fontNameCJK = fallbackCJK
        }
        if let value = double(values["translationFontSize"]) { configuration.translationFontSize = value }
        if let value = double(values["translationFontWeight"]) { configuration.translationFontWeight = cssWeight(value) }
        if let value = string(values["fontFamilyTranslation"]) { configuration.translationFontName = firstFontName(value, fallback: configuration.translationFontName) }
        if let value = double(values["renderScale"]) { configuration.renderScale = max(0.35, min(1, value)) }
        if let value = int(values["fpsCap"]) { configuration.fpsCap = max(0, value) }
        if let value = double(values["overscanPx"]) { configuration.overscan = max(0, value) }
        if let value = double(values["wordFadeWidth"]) { configuration.wordFadeWidth = max(0.05, value) }
        if let value = string(values["wordHighlightMode"]) { configuration.highlightMode = value == "discrete" ? .discrete : .smooth }
        if let value = double(values["leadInMs"]) { configuration.timing.leadIn = max(0, value) / 1000 }
        if let value = double(values["nearSwitchGapMs"]) { configuration.timing.nearSwitchGap = max(0, value) / 1000 }
        if let value = double(values["timeOffsetMs"]) { configuration.timing.trackOffset = value / 1000 }
        if let value = double(values["seekTimeOffsetMs"]) { configuration.timing.seekOffset = value / 1000 }
        if let value = double(values["alignPosition"]) { configuration.alignPosition = value }
        if let value = double(values["alignOffset"]) { configuration.alignOffset = value }
        if let value = string(values["alignAnchor"]) {
            configuration.alignAnchor = value == "bottom" ? .bottom : value == "top" ? .top : .center
        }
        if let value = double(values["blendOpacity"]) { configuration.blendOpacity = value }
        if let value = bool(values["enableBlur"]) { configuration.blur = value }
        if let value = bool(values["enableSpring"]) { configuration.spring = value }
        if double(values["springDuration"]) != nil || double(values["springBounce"]) != nil {
            let springDuration = double(values["springDuration"])
                ?? AppSettings.defaultLyricSpringDuration
            let springBounce = double(values["springBounce"])
                ?? AppSettings.defaultLyricSpringBounce
            let springEnabled = bool(values["enableSpring"]) ?? configuration.spring
            configuration.positionSpring = NativeLyricsSurfaceManager.springParameters(
                from: LyricSpringUserSettings(
                    enabled: springEnabled,
                    duration: springDuration,
                    bounce: springBounce
                )
            )
        }
        if let value = bool(values["fullscreenLyricDodgeMode"]) { configuration.fullscreenLyricDodgeMode = value }
        if let value = bool(values["fullscreenAppleStyleMode"]) { configuration.fullscreenAppleStyleMode = value }
        if let value = bool(values["coverBlurHideActiveMainLine"]) {
            configuration.coverBlurHideActiveMainLine = value
        }
        if let value = bool(values["coverBlurSuppressEmphasisGlow"]) {
            configuration.coverBlurSuppressEmphasisGlow = value
        }
        if let value = bool(values["coverBlurFullscreenGenericMode"]) {
            configuration.coverBlurGenericMode = value
            if value {
                configuration.surface = .coverBlurLight
                // Generic fullscreen cover/Apple skins use one native surface;
                // its highlight channel must remain in that surface.  A base
                // channel is only selected for the dedicated second overlay.
                configuration.coverBlurRenderLayer = .full
                configuration.coverBlurSuppressEmphasisGlow =
                    bool(values["coverBlurSuppressEmphasisGlow"]) ?? false
            } else if role != .fullscreenCoverBlurHighlight {
                configuration.surface = .window
                configuration.coverBlurRenderLayer = .full
                configuration.coverBlurThemeColor = nil
                configuration.coverBlurSuppressEmphasisGlow = false
            }
        }
        if let value = string(values["coverBlurFullscreenGenericProfile"]) {
            configuration.coverBlurProfile = value == LyricsCoverBlurProfile.darker.rawValue ? .darker : .lighter
            configuration.surface = value == LyricsCoverBlurProfile.darker.rawValue ? .coverBlurDark : .coverBlurLight
        }
        if values["coverBlurFullscreenThemeColor"] != nil {
            configuration.coverBlurThemeColor = color(
                values["coverBlurFullscreenThemeColor"],
                fallback: configuration.coverBlurThemeColor ?? .white
            )
        }
        if let value = string(values["mixBlendMode"]) { configuration.blendMode = blendMode(value) }
        applyChannelBlend(values, to: &configuration)
        if values["textColor"] != nil {
            configuration.palette.mainActive = color(values["textColor"], fallback: .white)
        }

        configuration.palette.mainActive = color(
            values["fullscreenActiveColor"] ?? values["coverBlurMainActiveColor"],
            fallback: configuration.palette.mainActive
        )
        configuration.palette.mainInactive = color(
            values["fullscreenInactiveColor"] ?? values["coverBlurMainInactiveColor"],
            fallback: configuration.palette.mainInactive
        )
        configuration.palette.lineTimingInactive = color(
            values["fullscreenLineTimingInactiveColor"]
                ?? values["coverBlurLineTimingInactiveColor"],
            fallback: configuration.palette.mainInactive
        )
        configuration.palette.translation = color(
            values["fullscreenSubColor"] ?? values["coverBlurSubColor"],
            fallback: configuration.palette.translation
        )
        configuration.palette.lineTimingSubInactive = color(
            values["fullscreenLineTimingSubInactiveColor"]
                ?? values["coverBlurLineTimingSubInactiveColor"],
            fallback: configuration.palette.translation
        )
        configuration.palette.backgroundActive = color(
            values["fullscreenBackgroundColor"] ?? values["coverBlurBackgroundColor"],
            fallback: configuration.palette.backgroundActive
        )
        configuration.palette.backgroundInactive = color(
            values["fullscreenBackgroundInactiveColor"] ?? values["coverBlurBackgroundInactiveColor"],
            fallback: configuration.palette.backgroundInactive
        )
        configuration.palette.backgroundKaraoke = color(
            values["fullscreenBackgroundKaraokeActiveColor"]
                ?? values["coverBlurBackgroundKaraokeActiveColor"],
            fallback: configuration.palette.backgroundKaraoke
        )
        configuration.palette.emphasisGlow = color(
            values["fullscreenEmphasisGlowColor"]
                ?? values["coverBlurMainGlowColor"],
            fallback: configuration.palette.emphasisGlow
        )
        if let value = double(values["fullscreenBackgroundBaseOpacity"]) { configuration.palette.backgroundBaseOpacity = value }
        if let value = double(values["fullscreenBackgroundKaraokeOpacity"]) { configuration.palette.backgroundKaraokeOpacity = value }

        if role == .fullscreenCoverBlurHighlight {
            configuration.coverBlurRenderLayer = .highlight
            configuration.coverBlurSuppressEmphasisGlow = false
        } else if !configuration.coverBlurGenericMode
                    && (configuration.surface == .coverBlurLight || configuration.surface == .coverBlurDark) {
            configuration.coverBlurRenderLayer = .base
        }
    }

    static func paletteForWindow(_ palette: ThemePalette) -> LyricsPalette {
        var result = LyricsPalette()
        result.mainActive = color(palette.activeLine, fallback: .white)
        result.mainInactive = color(palette.inactiveLine, fallback: LyricsColor(0.42, 0.44, 0.49))
        result.lineTimingInactive = result.mainInactive
        result.translation = result.mainInactive
        result.lineTimingSubInactive = result.translation
        result.emphasisGlow = result.mainActive
        return result
    }

    private static func cssWeight(_ value: Double) -> Double {
        let weight = max(100, min(900, value))
        return max(-1, min(1, (weight - 400) / 500))
    }

    private static func firstFontName(_ value: String, fallback: String) -> String {
        let candidate = fontNames(value).first
        return candidate ?? fallback
    }

    private static func fontNames(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter {
                guard !$0.isEmpty, !$0.hasPrefix("-") else { return false }
                let lower = $0.lowercased()
                return lower != "sans-serif"
                    && lower != "serif"
                    && lower != "system-ui"
                    && lower != "ui-sans-serif"
            }
    }

    private static func color(_ value: Any?, fallback: LyricsColor) -> LyricsColor {
        NativeLyricsSurfaceManager.color(value, fallback: fallback)
    }

    private static func blendMode(_ value: String) -> LyricsBlendMode {
        switch value.lowercased() {
        case "plus-lighter", "pluslighter", "screen": return .plusLighter
        case "plus-darker", "plusdarker": return .plusDarker
        case "normal": return .normal
        default: return .automatic
        }
    }

    /// Channel blend is composed inside the glyph mask. It is intentionally
    /// separate from `mixBlendMode`, which controls the complete lyric surface
    /// when a cover-blur host explicitly requests that behavior.
    private static func applyChannelBlend(
        _ values: [String: Any],
        to configuration: inout LyricsConfiguration
    ) {
        var channel = configuration.channelBlend
        if let object = values["channelBlend"] as? [String: Any] {
            if let value = string(object["inactive"]) { channel.inactive = blendMode(value) }
            if let value = string(object["current"]) { channel.current = blendMode(value) }
            if let value = string(object["highlight"]) { channel.highlight = blendMode(value) }
        }
        if let value = string(values["inactiveBlendMode"]) { channel.inactive = blendMode(value) }
        if let value = string(values["currentBlendMode"]) { channel.current = blendMode(value) }
        if let value = string(values["highlightBlendMode"]) { channel.highlight = blendMode(value) }
        configuration.channelBlend = channel
    }

    private static func string(_ value: Any?) -> String? { value as? String }
    private static func bool(_ value: Any?) -> Bool? { value as? Bool }
    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

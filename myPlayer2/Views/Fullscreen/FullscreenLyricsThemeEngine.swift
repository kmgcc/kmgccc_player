//
//  FullscreenLyricsThemeEngine.swift
//  myPlayer2
//
//  Pure fullscreen lyrics color/theme calculations and config assembly.
//

import AppKit
import Foundation
import SwiftUI

struct FullscreenLyricsColorSet {
    let mainActive: NSColor
    let mainInactive: NSColor
    let lineTimingMainInactive: NSColor
    let subActive: NSColor
    let subInactive: NSColor
    let lineTimingSubInactive: NSColor
}

enum FullscreenCoverBlurBlendProfile: String {
    case lighter
    case darker

    var paletteScheme: ColorScheme {
        switch self {
        case .lighter:
            return .dark
        case .darker:
            return .light
        }
    }
}

struct FullscreenCoverBlurLyricsTheme {
    let trackID: UUID
    let themeColor: NSColor
    let themeLightness: CGFloat
    let profile: FullscreenCoverBlurBlendProfile
    let colors: FullscreenLyricsColorSet
}

enum FullscreenCoverBlurRenderLayer: String {
    case base
    case highlight
}

@MainActor
final class FullscreenLyricsThemeEngine {
    private enum Tuning {
        static let minimumBaseLightness: CGFloat = 0.52
        static let maximumBaseLightness: CGFloat = 0.66
        static let minimumSubActiveLightness: CGFloat = 0.88
        static let maximumSubActiveLightness: CGFloat = 0.94
        static let minimumMainActiveLightness: CGFloat = 0.95
        static let maximumMainActiveLightness: CGFloat = 0.98
        static let saturationFloor: CGFloat = 0.10
        static let saturationCeiling: CGFloat = 0.58
    }

    func makeLyricsPalette(
        from colors: FullscreenLyricsColorSet,
        scheme: ColorScheme
    ) -> ThemePalette {
        let active = ArtworkColorExtractor.cssRGBA(colors.mainActive, alpha: 1.0)
        let inactive = ArtworkColorExtractor.cssRGBA(colors.mainInactive, alpha: 1.0)

        return ThemePalette(
            scheme: scheme,
            background: "rgba(0,0,0,0)",
            text: active,
            activeLine: active,
            inactiveLine: inactive,
            accent: active,
            shadow: "rgba(0,0,0,0)"
        )
    }

    func makeFullscreenLyricsPalette(from colors: FullscreenLyricsColorSet) -> ThemePalette {
        makeLyricsPalette(from: colors, scheme: .dark)
    }

    func makeCoverBlurLyricsPalette(from theme: FullscreenCoverBlurLyricsTheme) -> ThemePalette {
        let active = ArtworkColorExtractor.cssRGBA(theme.colors.mainActive, alpha: 1.0)
        let inactive = ArtworkColorExtractor.cssRGBA(theme.colors.mainInactive, alpha: 1.0)

        return ThemePalette(
            scheme: theme.profile.paletteScheme,
            background: "rgba(0,0,0,0)",
            text: active,
            activeLine: active,
            inactiveLine: inactive,
            accent: active,
            shadow: "rgba(0,0,0,0)"
        )
    }

    func cssFontFamily(_ names: [String]) -> String {
        let sanitized = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        let fallbacks = ["-apple-system", "\"Helvetica Neue\"", "sans-serif"]
        return (sanitized + fallbacks).joined(separator: ", ")
    }

    func buildFullscreenLyricsConfig(
        surfaceRole: LyricsSurfaceRole,
        settings: AppSettings,
        currentTrack: Track?,
        colorSet: FullscreenLyricsColorSet,
        activeCoverBlurTheme: FullscreenCoverBlurLyricsTheme?,
        isCoverBlurFullscreenSkin: Bool,
        currentFullscreenScale: CGFloat,
        isFullscreenBottomControlsVisible: Bool
    ) -> [String: Any] {
        let mainFontFamily = cssFontFamily([
            settings.fullscreenLyricsFontNameEn,
            settings.fullscreenLyricsFontNameZh,
        ])
        let translationFontFamily = cssFontFamily([
            settings.fullscreenLyricsTranslationFontName
        ])
        let mainActiveColor = ArtworkColorExtractor.cssRGBA(colorSet.mainActive, alpha: 1.0)
        let mainInactiveColor = ArtworkColorExtractor.cssRGBA(colorSet.mainInactive, alpha: 1.0)
        let subActiveColor = ArtworkColorExtractor.cssRGBA(colorSet.subActive, alpha: 1.0)
        let subInactiveColor = ArtworkColorExtractor.cssRGBA(colorSet.subInactive, alpha: 1.0)
        let lineTimingMainInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.lineTimingMainInactive,
            alpha: 1.0
        )
        let lineTimingSubInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.lineTimingSubInactive,
            alpha: 1.0
        )
        let backgroundColor = ArtworkColorExtractor.cssRGBA(colorSet.subActive, alpha: 1.0)
        let coverBlurThemeColor = activeCoverBlurTheme.map {
            ArtworkColorExtractor.cssRGBA($0.themeColor, alpha: 1.0)
        }
        let trackOffsetMs = max(-15000, min(15000, currentTrack?.lyricsTimeOffsetMs ?? 0))
        let globalAdvanceMs = max(-5000, min(5000, settings.lyricsGlobalAdvanceMs))
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - globalAdvanceMs))
        let scaledFontSize = settings.fullscreenLyricsFontSize * currentFullscreenScale
        let scaledTranslationFontSize = settings.fullscreenLyricsTranslationFontSize * currentFullscreenScale

        var config: [String: Any] = [
            "fontSize": scaledFontSize,
            "fontWeight": max(100, min(900, settings.fullscreenLyricsFontWeight)),
            "fontFamilyMain": mainFontFamily,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": scaledTranslationFontSize,
            "translationFontWeight": max(100, min(900, settings.fullscreenLyricsTranslationFontWeight)),
            "renderScale": surfaceRole.renderScale,
            "enableBlur": surfaceRole.enableBlur,
            "enableSpring": surfaceRole.enableSpring,
            "fpsCap": surfaceRole.fpsCap,
            "overscanPx": surfaceRole.overscanPx,
            "wordFadeWidth": surfaceRole.wordFadeWidth,
            "mixBlendMode": "normal",
            "blendOpacity": 1.0,
            "fullscreenActiveColor": mainActiveColor,
            "fullscreenInactiveColor": mainInactiveColor,
            "fullscreenSubActiveColor": subActiveColor,
            "fullscreenSubInactiveColor": subInactiveColor,
            "fullscreenBackgroundColor": backgroundColor,
            "fullscreenLineTimingInactiveColor": lineTimingMainInactiveColor,
            "fullscreenLineTimingSubInactiveColor": lineTimingSubInactiveColor,
            "alignAnchor": "top",
            "alignPosition": isFullscreenBottomControlsVisible ? 0.18 : 0.20,
            "alignOffset": 0,
            "lineHeight": 1.8,
            "activeScale": 1.2,
            "leadInMs": max(0, settings.lyricsLeadInMs),
            "nearSwitchGapMs": max(0, min(500, settings.lyricsNearSwitchGapMs)),
            "timeOffsetMs": combinedOffsetMs,
        ]

        config["fullscreenLyricDodgeMode"] = true
        config["fullscreenCoverBlurMode"] = false
        config["coverBlurFullscreenGenericMode"] = isCoverBlurFullscreenSkin && activeCoverBlurTheme != nil
        config["coverBlurFullscreenGenericProfile"] = activeCoverBlurTheme?.profile.rawValue ?? NSNull()
        config["coverBlurFullscreenThemeColor"] = coverBlurThemeColor ?? NSNull()

        return config
    }

    func pushFullscreenLyricsConfig(
        _ config: [String: Any],
        to store: LyricsWebViewStore,
        force: Bool,
        reason: String,
        probeLabel: String,
        probeDelay: TimeInterval
    ) {
        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            if let role = LyricsSurfaceRole(rawValue: store.role) {
                LyricsSurfaceManager.shared.updateSurfaceConfigSnapshot(json, for: role)
            }
            if force {
                store.forceSetConfigJSON(json, reason: reason)
            } else {
                store.setConfigJSON(json)
            }
            store.scheduleDebugVisibleLayerProbe(label: probeLabel, delay: probeDelay)
        }
    }

    func makeFullscreenLyricsColorSet(
        for track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?,
        colorScheme: ColorScheme,
        lockedBackgroundColor: NSColor?,
        lockedUltraDark: Bool,
        pendingBackgroundCapture: Bool,
        bkPrimaryBackgroundColor: NSColor?,
        bkSurfaceBackgroundColor: NSColor?,
        bkLyricsColorTrackID: UUID?,
        artBackgroundEnabled: Bool
    ) -> FullscreenLyricsColorSet {
        let highlightBaseColor = resolveFullscreenLyricsBaseColor(
            for: track,
            artworkSnapshot: artworkSnapshot
        )
        let highlightHSL = HSLColorUtilities.hslComponents(from: highlightBaseColor)
        let inactiveBaseColor = resolveFullscreenLyricsInactiveBaseColor(
            for: track,
            artworkSnapshot: artworkSnapshot,
            lockedBgColor: lockedBackgroundColor,
            pendingCapture: pendingBackgroundCapture,
            bkPrimaryBgColor: bkPrimaryBackgroundColor,
            bkSurfaceBgColor: bkSurfaceBackgroundColor,
            bkLyricsColorTrackID: bkLyricsColorTrackID,
            artBgEnabled: artBackgroundEnabled
        )
        let inactiveHSL = HSLColorUtilities.hslComponents(from: inactiveBaseColor)
        let inactiveDarkModeShift: CGFloat = colorScheme == .dark ? 0.08 : 0
        let inactiveUltraDarkShift: CGFloat = lockedUltraDark
            ? (colorScheme == .dark ? 0.22 : 0.17)
            : 0
        let totalInactiveShift = inactiveDarkModeShift + inactiveUltraDarkShift
        let activeLightnessShift: CGFloat = lockedUltraDark
            ? (colorScheme == .dark ? 0.10 : 0.06)
            : (colorScheme == .dark ? 0.02 : 0)
        let inactiveSaturationScale: CGFloat = lockedUltraDark
            ? (colorScheme == .dark ? 0.34 : 0.40)
            : (colorScheme == .dark ? 0.42 : 0.48)
        let inactiveSaturationBias: CGFloat = colorScheme == .dark ? 0.015 : 0.02
        let tunedSaturation = HSLColorUtilities.clamp(
            highlightHSL.saturation * 0.70 + 0.06,
            min: Tuning.saturationFloor,
            max: Tuning.saturationCeiling
        )
        let baseLightness = HSLColorUtilities.clamp(
            max(
                inactiveHSL.lightness - 0.02 - totalInactiveShift,
                Tuning.minimumBaseLightness - totalInactiveShift * 0.55
            ),
            min: max(0.24, Tuning.minimumBaseLightness - totalInactiveShift),
            max: max(0.40, Tuning.maximumBaseLightness - totalInactiveShift * 0.95)
        )
        let subActiveLightness = HSLColorUtilities.clamp(
            max(highlightHSL.lightness + 0.04 - activeLightnessShift * 0.75, baseLightness + 0.04),
            min: max(0.64, Tuning.minimumSubActiveLightness - 0.08 - activeLightnessShift * 0.9),
            max: max(0.74, Tuning.maximumSubActiveLightness - 0.08 - activeLightnessShift * 0.75)
        )
        let activeLightness = HSLColorUtilities.clamp(
            max(highlightHSL.lightness + 0.18 - activeLightnessShift * 0.6, subActiveLightness + 0.08),
            min: max(0.84, Tuning.minimumMainActiveLightness - activeLightnessShift * 0.55),
            max: max(0.90, Tuning.maximumMainActiveLightness - activeLightnessShift * 0.45)
        )
        let mainInactiveColor = HSLColorUtilities.colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: HSLColorUtilities.clamp(
                inactiveHSL.saturation * inactiveSaturationScale + inactiveSaturationBias,
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )
        let lineTimingMainInactiveColor = HSLColorUtilities.colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: HSLColorUtilities.clamp(
                inactiveHSL.saturation * max(0.28, inactiveSaturationScale - 0.03)
                    + max(0.01, inactiveSaturationBias - 0.005),
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )
        let subActiveColor = HSLColorUtilities.colorFromHSL(
            hue: highlightHSL.hue,
            saturation: HSLColorUtilities.clamp(tunedSaturation * 0.78, min: 0, max: 1),
            lightness: subActiveLightness
        )
        let subInactiveColor = HSLColorUtilities.colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: HSLColorUtilities.clamp(
                inactiveHSL.saturation * max(0.26, inactiveSaturationScale - 0.05)
                    + max(0.01, inactiveSaturationBias - 0.005),
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )
        let lineTimingSubInactiveColor = HSLColorUtilities.colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: HSLColorUtilities.clamp(
                inactiveHSL.saturation * max(0.24, inactiveSaturationScale - 0.08)
                    + max(0.008, inactiveSaturationBias - 0.008),
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )

        return FullscreenLyricsColorSet(
            mainActive: HSLColorUtilities.colorFromHSL(
                hue: highlightHSL.hue,
                saturation: HSLColorUtilities.clamp(tunedSaturation * 1.12 + 0.02, min: 0, max: 1),
                lightness: activeLightness
            ),
            mainInactive: mainInactiveColor,
            lineTimingMainInactive: lineTimingMainInactiveColor,
            subActive: subActiveColor,
            subInactive: subInactiveColor,
            lineTimingSubInactive: lineTimingSubInactiveColor
        )
    }

    func resolveFullscreenLyricsBaseColor(
        for track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?
    ) -> NSColor {
        if let accent = currentArtworkSnapshot(for: track, artworkSnapshot: artworkSnapshot)?.accentColor {
            return accent
        }
        if let base = currentArtworkSnapshot(for: track, artworkSnapshot: artworkSnapshot)?.averageColor {
            return base
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    func resolveFullscreenLyricsInactiveBaseColor(
        for track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?,
        lockedBgColor: NSColor?,
        pendingCapture: Bool,
        bkPrimaryBgColor: NSColor?,
        bkSurfaceBgColor: NSColor?,
        bkLyricsColorTrackID: UUID?,
        artBgEnabled: Bool
    ) -> NSColor {
        if let lockedBgColor {
            return lockedBgColor
        }

        if artBgEnabled, bkLyricsColorTrackID == track?.id {
            if pendingCapture, let bkPrimaryBgColor {
                return bkPrimaryBgColor
            }

            if let bkSurfaceBgColor {
                return bkSurfaceBgColor
            }

            if let bkPrimaryBgColor {
                return bkPrimaryBgColor
            }
        }

        return resolveFullscreenLyricsBaseColor(for: track, artworkSnapshot: artworkSnapshot)
    }

    func makeCoverBlurLyricsColorSet(
        from themeColor: NSColor,
        profile: FullscreenCoverBlurBlendProfile
    ) -> FullscreenLyricsColorSet {
        let themeHSL = HSLColorUtilities.hslComponents(from: themeColor)

        switch profile {
        case .lighter:
            let inputLightness = themeHSL.lightness
            let nonHighlightMaxLightness: CGFloat = 0.20
            let isVeryDarkTheme = inputLightness < 0.05
            let isVeryBrightButStillLighter = inputLightness > 0.70
            let activeSaturation: CGFloat
            let activeLightness: CGFloat

            if inputLightness >= 0.64 {
                activeLightness = HSLColorUtilities.clamp(
                    max(inputLightness + 0.01, 0.90),
                    min: 0.90,
                    max: 0.935
                )
                activeSaturation = HSLColorUtilities.clamp(
                    themeHSL.saturation * 0.70 + 0.04,
                    min: 0.06,
                    max: 0.48
                )
            } else if inputLightness >= 0.46 {
                activeLightness = HSLColorUtilities.clamp(
                    max(inputLightness + 0.08, 0.85),
                    min: 0.85,
                    max: 0.89
                )
                activeSaturation = HSLColorUtilities.clamp(
                    themeHSL.saturation * 0.54 + 0.04,
                    min: 0.06,
                    max: 0.38
                )
            } else if inputLightness >= 0.18 {
                activeLightness = HSLColorUtilities.clamp(
                    max(inputLightness + 0.06, 0.80),
                    min: 0.80,
                    max: 0.84
                )
                activeSaturation = HSLColorUtilities.clamp(
                    themeHSL.saturation * 0.48 + 0.04,
                    min: 0.05,
                    max: 0.34
                )
            } else {
                activeLightness = HSLColorUtilities.clamp(
                    max(inputLightness + 0.38, 0.67),
                    min: 0.67,
                    max: 0.78
                )
                activeSaturation = HSLColorUtilities.clamp(
                    themeHSL.saturation * 0.14 + 0.06,
                    min: 0.05,
                    max: 0.18
                )
            }

            let veryDarkInactiveBoost: CGFloat = isVeryDarkTheme ? 0.090 : 0
            let brightInactiveTrim: CGFloat = isVeryBrightButStillLighter ? 0.015 : 0
            let inactiveSaturation = HSLColorUtilities.clamp(
                themeHSL.saturation * 0.34 + 0.03,
                min: 0.03,
                max: 0.18
            )
            let subInactiveSaturation = HSLColorUtilities.clamp(
                themeHSL.saturation * 0.28 + 0.03,
                min: 0.02,
                max: 0.14
            )
            let baseLightness = HSLColorUtilities.clamp(
                inputLightness * 0.08 + 0.09 + veryDarkInactiveBoost - brightInactiveTrim,
                min: isVeryDarkTheme ? 0.13 : 0.08,
                max: nonHighlightMaxLightness
            )
            let lineTimingBaseLightness = HSLColorUtilities.clamp(
                baseLightness - (isVeryDarkTheme ? 0.025 : 0.04),
                min: isVeryDarkTheme ? 0.10 : 0.05,
                max: nonHighlightMaxLightness
            )
            let subActiveLightness = HSLColorUtilities.clamp(
                baseLightness + (isVeryDarkTheme ? 0.035 : 0.045),
                min: isVeryDarkTheme ? 0.15 : 0.13,
                max: 0.24
            )

            return FullscreenLyricsColorSet(
                mainActive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: activeSaturation,
                    lightness: activeLightness
                ),
                mainInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: inactiveSaturation,
                    lightness: baseLightness
                ),
                lineTimingMainInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: HSLColorUtilities.clamp(inactiveSaturation * 0.92, min: 0.02, max: 0.24),
                    lightness: lineTimingBaseLightness
                ),
                subActive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: HSLColorUtilities.clamp(activeSaturation * 0.82, min: 0.08, max: 0.52),
                    lightness: subActiveLightness
                ),
                subInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: subInactiveSaturation,
                    lightness: HSLColorUtilities.clamp(
                        baseLightness - 0.02,
                        min: isVeryDarkTheme ? 0.09 : 0.07,
                        max: 0.18
                    )
                ),
                lineTimingSubInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: HSLColorUtilities.clamp(subInactiveSaturation * 0.92, min: 0.02, max: 0.12),
                    lightness: HSLColorUtilities.clamp(
                        lineTimingBaseLightness - 0.01,
                        min: isVeryDarkTheme ? 0.07 : 0.04,
                        max: 0.14
                    )
                )
            )
        case .darker:
            let highlightSaturation = HSLColorUtilities.clamp(
                themeHSL.saturation * 0.34 + 0.08,
                min: 0.05,
                max: 0.24
            )
            let inactiveSaturation = HSLColorUtilities.clamp(
                themeHSL.saturation * 0.18 + 0.02,
                min: 0.01,
                max: 0.10
            )
            let subInactiveSaturation = HSLColorUtilities.clamp(
                inactiveSaturation * 0.90,
                min: 0.01,
                max: 0.09
            )
            let baseLightness = HSLColorUtilities.clamp(
                0.82 - (1 - themeHSL.lightness) * 0.18,
                min: 0.76,
                max: 0.88
            )
            let lineTimingBaseLightness = HSLColorUtilities.clamp(baseLightness - 0.05, min: 0.70, max: 0.82)
            let subActiveLightness = HSLColorUtilities.clamp(baseLightness - 0.10, min: 0.62, max: 0.76)
            let highlightLightness = HSLColorUtilities.clamp(
                themeHSL.lightness * 0.14 + 0.32,
                min: 0.34,
                max: 0.50
            )

            return FullscreenLyricsColorSet(
                mainActive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: highlightSaturation,
                    lightness: highlightLightness
                ),
                mainInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: inactiveSaturation,
                    lightness: baseLightness
                ),
                lineTimingMainInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: HSLColorUtilities.clamp(inactiveSaturation * 0.9, min: 0.06, max: 0.30),
                    lightness: lineTimingBaseLightness
                ),
                subActive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: HSLColorUtilities.clamp(highlightSaturation * 0.78, min: 0.04, max: 0.18),
                    lightness: subActiveLightness
                ),
                subInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: subInactiveSaturation,
                    lightness: HSLColorUtilities.clamp(baseLightness - 0.02, min: 0.74, max: 0.88)
                ),
                lineTimingSubInactive: HSLColorUtilities.colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: HSLColorUtilities.clamp(subInactiveSaturation * 0.95, min: 0.01, max: 0.08),
                    lightness: HSLColorUtilities.clamp(lineTimingBaseLightness - 0.01, min: 0.68, max: 0.82)
                )
            )
        }
    }

    func resolveCoverBlurThemeColor(
        for track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?
    ) -> NSColor? {
        guard let snapshot = currentArtworkSnapshot(for: track, artworkSnapshot: artworkSnapshot) else {
            return nil
        }

        return snapshot.averageColor ?? snapshot.dominantColor ?? snapshot.accentColor
    }

    func makeCoverBlurLyricsTheme(
        for track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?
    ) -> FullscreenCoverBlurLyricsTheme? {
        guard let track, let themeColor = resolveCoverBlurThemeColor(for: track, artworkSnapshot: artworkSnapshot) else {
            return nil
        }

        let themeHSL = HSLColorUtilities.hslComponents(from: themeColor)
        let profile: FullscreenCoverBlurBlendProfile = themeHSL.lightness > 0.72 ? .darker : .lighter

        return FullscreenCoverBlurLyricsTheme(
            trackID: track.id,
            themeColor: themeColor,
            themeLightness: themeHSL.lightness,
            profile: profile,
            colors: makeCoverBlurLyricsColorSet(from: themeColor, profile: profile)
        )
    }

    func updateCoverBlurLyricsThemeIfReady(
        for track: Track?,
        currentTheme: FullscreenCoverBlurLyricsTheme?,
        artworkSnapshot: ArtworkAssetSnapshot?
    ) -> FullscreenCoverBlurLyricsTheme? {
        guard let resolvedTheme = makeCoverBlurLyricsTheme(for: track, artworkSnapshot: artworkSnapshot) else {
            return nil
        }

        let previousTrackID = currentTheme?.trackID
        let previousProfile = currentTheme?.profile
        let previousLightness = currentTheme?.themeLightness ?? -1
        let themeChanged = previousTrackID != resolvedTheme.trackID
            || previousProfile != resolvedTheme.profile
            || abs(previousLightness - resolvedTheme.themeLightness) > 0.000_1

        return themeChanged ? resolvedTheme : currentTheme
    }

    private func currentArtworkSnapshot(
        for track: Track?,
        artworkSnapshot: ArtworkAssetSnapshot?
    ) -> ArtworkAssetSnapshot? {
        guard let track, let artworkSnapshot, artworkSnapshot.trackID == track.id else {
            return nil
        }
        return artworkSnapshot
    }
}

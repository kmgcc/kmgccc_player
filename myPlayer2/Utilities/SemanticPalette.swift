//
//  SemanticPalette.swift
//  myPlayer2
//
//  Per-role colours derived from a single ArtworkColorAnalysis. UI surfaces
//  read these instead of running their own extraction. Phase 2 wires up the
//  factory with placeholder behaviour that exactly mirrors today's output;
//  later phases harden each role.
//

import AppKit
import SwiftUI

struct SemanticPalette: Equatable, Sendable {
    let scheme: ColorScheme
    let analysis: ArtworkColorAnalysis

    let globalAccent: NSColor
    let uiAccentOnDark: NSColor
    let uiAccentOnLight: NSColor

    let ambientSurface: NSColor
    let artBackgroundPrimary: NSColor
    let artBackgroundSecondary: NSColor

    let readableTextOnArtwork: NSColor
    let secondaryTextOnArtwork: NSColor

    let windowLyricActive: NSColor
    let windowLyricInactive: NSColor

    let fullscreenLyricBase: NSColor
    let fullscreenLyricInactiveBase: NSColor

    let coverGradientDominant: NSColor
    let coverGradientText: NSColor
}

enum SemanticPaletteFactory {
    static func make(
        from analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        userFallbackAccent: NSColor,
        useArtworkTint: Bool
    ) -> SemanticPalette {
        let isDark = scheme == .dark
        let globalAccent: NSColor
        if useArtworkTint {
            globalAccent = optimizedAccent(for: scheme, analysis: analysis)
        } else {
            globalAccent = isDark
                ? ColorMath.clampLightness(
                    userFallbackAccent,
                    lo: ColorSystemTokens.FallbackAccent.darkMinL,
                    hi: ColorSystemTokens.FallbackAccent.darkMaxL
                )
                : ColorMath.clampLightness(
                    userFallbackAccent,
                    lo: ColorSystemTokens.FallbackAccent.lightMinL,
                    hi: ColorSystemTokens.FallbackAccent.lightMaxL
                )
            // Debug: log resolved accent RGB so we can confirm the runtime colour.
            let inC = ColorMath.hsl(of: userFallbackAccent)
            let outC = ColorMath.hsl(of: globalAccent)
            let outNS = globalAccent.usingColorSpace(.deviceRGB) ?? globalAccent
            let r8 = Int((outNS.redComponent * 255).rounded())
            let g8 = Int((outNS.greenComponent * 255).rounded())
            let b8 = Int((outNS.blueComponent * 255).rounded())
            Log.debug(
                "Palette fallback accent: \(isDark ? "dark" : "light") "
                + "in hsl(\(f3(inC.h)),\(f3(inC.s)),\(f3(inC.l))) "
                + "→ rgb(\(r8),\(g8),\(b8)) hsl(\(f3(outC.h)),\(f3(outC.s)),\(f3(outC.l)))",
                category: .theme
            )
        }

        return SemanticPalette(
            scheme: scheme,
            analysis: analysis,
            globalAccent: globalAccent,
            uiAccentOnDark: optimizedAccent(for: .dark, analysis: analysis),
            uiAccentOnLight: optimizedAccent(for: .light, analysis: analysis),
            ambientSurface: ambientSurface(analysis: analysis, isDark: isDark),
            artBackgroundPrimary: artBackgroundPrimary(analysis: analysis, isDark: isDark),
            artBackgroundSecondary: artBackgroundSecondary(analysis: analysis, isDark: isDark),
            readableTextOnArtwork: readableTextOnArtwork(analysis: analysis),
            secondaryTextOnArtwork: secondaryTextOnArtwork(analysis: analysis),
            windowLyricActive: windowLyricActive(analysis: analysis, isDark: isDark),
            windowLyricInactive: windowLyricInactive(analysis: analysis, isDark: isDark),
            fullscreenLyricBase: fullscreenLyricBase(analysis: analysis),
            fullscreenLyricInactiveBase: fullscreenLyricInactiveBase(analysis: analysis),
            coverGradientDominant: coverGradientDominant(analysis: analysis, isDark: isDark),
            coverGradientText: coverGradientText(analysis: analysis)
        )
    }

    // MARK: - Role derivations (Phase 2 placeholders)

    fileprivate static func optimizedAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        if analysis.isEffectivelyMonochrome {
            return nearMonochromeAccent(for: scheme, analysis: analysis)
        }

        let raw = analysis.dominantColor
        let comp = ColorMath.hsl(of: raw)
        var h = comp.h, s = comp.s, l = comp.l

        // Hue guard: covers whose average hue sits in the warm-yellow / beige /
        // ochre band must not produce a red or pink accent — small brown spots
        // can drift the dominant bucket past the band, so snap back to avgHue.
        let avg = analysis.avgHue
        let isWarmAvg = avg >= ColorSystemTokens.Accent.warmGuardHueLo
            && avg <= ColorSystemTokens.Accent.warmGuardHueHi
        let isWarmConfident = analysis.dominantHueConfidence
            >= ColorSystemTokens.Accent.warmGuardHueConfidenceMin
        if isWarmAvg && isWarmConfident {
            let inWarmBand = (h >= ColorSystemTokens.Accent.warmBandHueLo
                              && h <= ColorSystemTokens.Accent.warmBandHueHi)
            let drifted = ColorMath.circularHueDistance(h, avg)
                > ColorSystemTokens.Accent.warmGuardDriftThreshold
            if !inWarmBand || drifted {
                h = avg
            }
        }

        // Hue-aware minimum lightness on dark surfaces. Yellow/orange already glow
        // at lower L; blue/violet/red need higher L to remain readable.
        let darkMinL: CGFloat = {
            switch h {
            case 0.10..<0.18: return ColorSystemTokens.Accent.darkMinLByHueYellowOrange
            case 0.18..<0.42: return ColorSystemTokens.Accent.darkMinLByHueGreen
            case 0.42..<0.72: return ColorSystemTokens.Accent.darkMinLByHueCyanBlue
            case 0.72..<0.85: return ColorSystemTokens.Accent.darkMinLByHueViolet
            default:           return ColorSystemTokens.Accent.darkMinLByHueDefault
            }
        }()
        let darkMaxL: CGFloat = ColorSystemTokens.Accent.darkLightnessCeiling

        if scheme == .dark {
            s = ColorMath.clamp(
                max(s * ColorSystemTokens.Accent.darkSaturationLift,
                    ColorSystemTokens.Accent.darkSaturationFloor),
                ColorSystemTokens.Accent.darkSaturationFloor,
                ColorSystemTokens.Accent.darkSaturationCeiling
            )
            l = ColorMath.clamp(max(l, darkMinL), darkMinL, darkMaxL)
        } else {
            // Light mode: hue-aware saturation ceiling. Cheap/garish hues
            // (medical green, magenta, industrial blue) cap lower; warm yellow
            // / orange can stay richer. Use a soft shoulder so colours just
            // above the ceiling compress smoothly instead of clipping.
            let lightSatCeiling: CGFloat = {
                switch h {
                case 0.83..<1.00, 0.00..<0.03:
                    return ColorSystemTokens.Accent.lightSatCeilingPinkMagenta
                case 0.72..<0.83:
                    return ColorSystemTokens.Accent.lightSatCeilingPurpleViolet
                case 0.30..<0.50:
                    return ColorSystemTokens.Accent.lightSatCeilingMedicalGreen
                case 0.50..<0.65:
                    return ColorSystemTokens.Accent.lightSatCeilingIndustrialBlue
                case 0.65..<0.72:
                    return ColorSystemTokens.Accent.lightSatCeilingDeepBlue
                case 0.03..<0.10:
                    return ColorSystemTokens.Accent.lightSatCeilingWarmRedOrange
                case 0.10..<0.20:
                    return ColorSystemTokens.Accent.lightSatCeilingYellowAmber
                case 0.20..<0.30:
                    return ColorSystemTokens.Accent.lightSatCeilingChartreuse
                default:
                    return ColorSystemTokens.Accent.lightSatCeilingDefault
                }
            }()
            let raised = max(
                s * ColorSystemTokens.Accent.lightSaturationLift,
                ColorSystemTokens.Accent.lightSaturationFloor
            )
            let softened = ColorMath.softShoulder(
                raised,
                ceiling: lightSatCeiling,
                softness: ColorSystemTokens.Accent.lightSatShoulderSoftness
            )
            s = ColorMath.clamp(
                softened,
                ColorSystemTokens.Accent.lightSaturationFloor,
                ColorSystemTokens.Accent.lightSaturationOuterCeiling
            )
            l = ColorMath.clamp(
                min(l * ColorSystemTokens.Accent.lightLightnessScale,
                    ColorSystemTokens.Accent.lightLightnessCeiling),
                ColorSystemTokens.Accent.lightLightnessFloor,
                ColorSystemTokens.Accent.lightLightnessCeiling
            )
        }

        // Saturation safety net for low-colour covers — the dominant bucket on a
        // grey/black/white cover with a few pink/red noise pixels will *look*
        // saturated; cap it so the noise can't paint the accent neon.
        if analysis.isMonochrome {
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.strictMonoSatCapDark
                : ColorSystemTokens.Accent.strictMonoSatCapLight)
        } else if analysis.colorfulness < ColorSystemTokens.Accent.nearMonoColorfulnessThreshold
                  || analysis.avgSaturation < ColorSystemTokens.Accent.nearMonoAvgSaturationThreshold {
            // Near-monochrome but not strict mono: low-sat photo, off-white
            // sleeve with a small logo, dim duo-tone, etc.
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.nearMonoSatCapDark
                : ColorSystemTokens.Accent.nearMonoSatCapLight)
        } else if analysis.dominantHueConfidence
                    < ColorSystemTokens.Accent.lowConfidenceHueConfidenceThreshold {
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.lowConfidenceSatCapDark
                : ColorSystemTokens.Accent.lowConfidenceSatCapLight)
        }

        return ColorMath.color(h: h, s: s, l: l)
    }

    fileprivate static func nearMonochromeAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        let average = ColorMath.hsl(of: analysis.averageColor)
        let hasUsableAverageHue =
            average.s >= ColorSystemTokens.NearMonochrome.avgHueUsableSaturation
            && analysis.avgSaturation >= ColorSystemTokens.NearMonochrome.avgHueUsableAvgSaturation
        let neutralHue: CGFloat
        if hasUsableAverageHue {
            neutralHue = average.h
        } else if analysis.avgHslLightness
                    < ColorSystemTokens.NearMonochrome.neutralHueChoiceLightnessThreshold {
            neutralHue = ColorSystemTokens.NearMonochrome.neutralCoolHue
        } else {
            neutralHue = ColorSystemTokens.NearMonochrome.neutralWarmHue
        }

        let strictMono =
            analysis.isMonochrome
            || analysis.colorfulness < ColorSystemTokens.NearMonochrome.strictMonoColorfulness
            || analysis.avgSaturation < ColorSystemTokens.NearMonochrome.strictMonoAvgSaturation
            || analysis.largestHighSaturationAreaShare
                < ColorSystemTokens.NearMonochrome.strictMonoHighSatAreaShare
        let saturationCeiling: CGFloat = strictMono
            ? (scheme == .dark
                ? ColorSystemTokens.NearMonochrome.strictMonoSatCapDark
                : ColorSystemTokens.NearMonochrome.strictMonoSatCapLight)
            : (scheme == .dark
                ? ColorSystemTokens.NearMonochrome.nearMonoSatCapDark
                : ColorSystemTokens.NearMonochrome.nearMonoSatCapLight)
        let saturationFloor: CGFloat = scheme == .dark
            ? ColorSystemTokens.NearMonochrome.saturationFloorDark
            : ColorSystemTokens.NearMonochrome.saturationFloorLight
        let saturation = ColorMath.clamp(
            min(average.s * ColorSystemTokens.NearMonochrome.saturationScale, saturationCeiling),
            saturationFloor,
            saturationCeiling
        )

        let lightness: CGFloat
        if scheme == .dark {
            let toneLift = ColorMath.clamp(
                (ColorSystemTokens.NearMonochrome.darkLiftPivot - analysis.avgHslLightness)
                    / ColorSystemTokens.NearMonochrome.darkLiftRange,
                0, 1
            )
            lightness = ColorMath.clamp(
                ColorSystemTokens.NearMonochrome.darkBaseLightness
                    + toneLift * ColorSystemTokens.NearMonochrome.darkLiftMax,
                ColorSystemTokens.NearMonochrome.darkBaseLightness,
                ColorSystemTokens.NearMonochrome.darkCeilingLightness
            )
        } else {
            let toneDrop = ColorMath.clamp(
                (analysis.avgHslLightness - ColorSystemTokens.NearMonochrome.lightDropPivot)
                    / ColorSystemTokens.NearMonochrome.lightDropRange,
                0, 1
            )
            lightness = ColorMath.clamp(
                ColorSystemTokens.NearMonochrome.lightBaseLightness
                    - toneDrop * ColorSystemTokens.NearMonochrome.lightDropMax,
                ColorSystemTokens.NearMonochrome.lightFloorLightness,
                ColorSystemTokens.NearMonochrome.lightCeilingLightness
            )
        }

        return ColorMath.color(h: neutralHue, s: saturation, l: lightness)
    }

    fileprivate static func ambientSurface(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.averageColor
    }

    fileprivate static func artBackgroundPrimary(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.topPalette.first ?? analysis.dominantColor
    }

    fileprivate static func artBackgroundSecondary(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.topPalette.dropFirst().first ?? analysis.dominantColor
    }

    fileprivate static func readableTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
        if analysis.usesDarkForeground {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s + ColorSystemTokens.ReadableText.darkForegroundSaturationLift,
                    ColorSystemTokens.ReadableText.darkForegroundSatLo,
                    ColorSystemTokens.ReadableText.darkForegroundSatHi
                ),
                l: ColorSystemTokens.ReadableText.darkForegroundLightness
            )
        } else {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s,
                    ColorSystemTokens.ReadableText.lightForegroundSatLo,
                    ColorSystemTokens.ReadableText.lightForegroundSatHi
                ),
                l: ColorSystemTokens.ReadableText.lightForegroundLightness
            )
        }
    }

    fileprivate static func secondaryTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor.withAlphaComponent(
            ColorSystemTokens.ReadableText.secondaryAlpha
        )
    }

    fileprivate static func windowLyricActive(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        ArtworkColorExtractor.adjustedAccent(from: analysis.averageColor, isDarkMode: isDark)
    }

    fileprivate static func windowLyricInactive(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        windowLyricActive(analysis: analysis, isDark: isDark)
            .withAlphaComponent(ColorSystemTokens.WindowLyric.inactiveAlpha)
    }

    fileprivate static func fullscreenLyricBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // High colorfulness + clear hue dominance → use the dominant cover hue.
        // Otherwise fall back to the best text source colour (already mid-tone, hue-rich).
        if analysis.colorfulness >= ColorSystemTokens.FullscreenLyric.usesDominantColorfulnessMin
           && analysis.dominantHueConfidence
                >= ColorSystemTokens.FullscreenLyric.usesDominantHueConfidenceMin {
            return analysis.dominantColor
        }
        return analysis.bestTextSourceColor
    }

    fileprivate static func fullscreenLyricInactiveBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // Inactive uses the average colour — more stable than dominantColor on
        // covers with strong but small high-saturation regions.
        analysis.averageColor
    }

    fileprivate static func coverGradientDominant(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        // Drive cover-overlay tint from dominant hue. Keep moderate saturation
        // and never push past the cover's own brightness band.
        let hsl = ColorMath.hsl(of: analysis.dominantColor)
        let s = ColorMath.clamp(
            hsl.s * ColorSystemTokens.CoverGradient.dominantSaturationScale,
            ColorSystemTokens.CoverGradient.dominantSaturationLo,
            ColorSystemTokens.CoverGradient.dominantSaturationHi
        )
        let l = ColorMath.clamp(
            hsl.l,
            ColorSystemTokens.CoverGradient.dominantLightnessLo,
            ColorSystemTokens.CoverGradient.dominantLightnessHi
        )
        return ColorMath.color(h: hsl.h, s: s, l: l)
    }

    fileprivate static func coverGradientText(analysis: ArtworkColorAnalysis) -> NSColor {
        // Stronger contrast bias than readableTextOnArtwork — used over a blurred
        // cover, not a solid surface.
        let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
        if analysis.usesDarkForeground {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s,
                    ColorSystemTokens.CoverGradient.darkTextSatLo,
                    ColorSystemTokens.CoverGradient.darkTextSatHi
                ),
                l: ColorSystemTokens.CoverGradient.darkTextLightness
            )
        } else {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(
                    hsl.s,
                    ColorSystemTokens.CoverGradient.lightTextSatLo,
                    ColorSystemTokens.CoverGradient.lightTextSatHi
                ),
                l: ColorSystemTokens.CoverGradient.lightTextLightness
            )
        }
    }
}

/// Format a CGFloat to 3 decimal places for debug logging.
private func f3(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}

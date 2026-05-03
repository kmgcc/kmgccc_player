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
                ? ColorMath.clampLightness(userFallbackAccent, lo: 0.66, hi: 0.82)
                : ColorMath.clampLightness(userFallbackAccent, lo: 0.30, hi: 0.50)
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
        let raw = analysis.dominantColor
        let comp = ColorMath.hsl(of: raw)
        var h = comp.h, s = comp.s, l = comp.l

        // Hue guard: covers whose average hue sits in the warm-yellow / beige /
        // ochre band must not produce a red or pink accent — small brown spots
        // can drift the dominant bucket past the band, so snap back to avgHue.
        let avg = analysis.avgHue
        let isWarmAvg = avg >= 0.07 && avg <= 0.20
        let isWarmConfident = analysis.dominantHueConfidence >= 0.16
        if isWarmAvg && isWarmConfident {
            let inWarmBand = (h >= 0.06 && h <= 0.20)
            let drifted = ColorMath.circularHueDistance(h, avg) > 0.06
            if !inWarmBand || drifted {
                h = avg
            }
        }

        // Hue-aware minimum lightness on dark surfaces. Yellow/orange already glow
        // at lower L; blue/violet/red need higher L to remain readable.
        let darkMinL: CGFloat = {
            switch h {
            case 0.10..<0.18: return 0.66   // yellow / orange
            case 0.18..<0.42: return 0.70   // green
            case 0.42..<0.72: return 0.74   // cyan / blue
            case 0.72..<0.85: return 0.76   // violet
            default:           return 0.72  // red / magenta / pink
            }
        }()
        let darkMaxL: CGFloat = 0.82

        if scheme == .dark {
            s = ColorMath.clamp(max(s * 1.06, 0.32), 0.32, 0.86)
            l = ColorMath.clamp(max(l, darkMinL), darkMinL, darkMaxL)
        } else {
            // Light mode: hue-aware saturation ceiling. Cheap/garish hues
            // (medical green, magenta, industrial blue) cap lower; warm yellow
            // / orange can stay richer. Use a soft shoulder so colours just
            // above the ceiling compress smoothly instead of clipping.
            let lightSatCeiling: CGFloat = {
                switch h {
                case 0.83..<1.00, 0.00..<0.03:
                    return 0.46                                 // pink / magenta / red-pink
                case 0.72..<0.83:
                    return 0.50                                 // purple / violet
                case 0.30..<0.50:
                    return 0.48                                 // medical green / cyan-green
                case 0.50..<0.65:
                    return 0.54                                 // industrial blue / cyan-blue
                case 0.65..<0.72:
                    return 0.58                                 // deep blue
                case 0.03..<0.10:
                    return 0.66                                 // warm red-orange
                case 0.10..<0.20:
                    return 0.68                                 // yellow / amber
                case 0.20..<0.30:
                    return 0.56                                 // yellow-green / chartreuse
                default:
                    return 0.54
                }
            }()
            let raised = max(s * 1.02, 0.30)
            let softened = ColorMath.softShoulder(
                raised,
                ceiling: lightSatCeiling,
                softness: 0.10
            )
            s = ColorMath.clamp(softened, 0.30, 0.72)
            l = ColorMath.clamp(min(l * 0.78, 0.50), 0.30, 0.50)
        }

        // Saturation safety net for low-colour covers — the dominant bucket on a
        // grey/black/white cover with a few pink/red noise pixels will *look*
        // saturated; cap it so the noise can't paint the accent neon.
        if analysis.isMonochrome {
            s = min(s, scheme == .dark ? 0.18 : 0.14)
        } else if analysis.colorfulness < 0.10 || analysis.avgSaturation < 0.12 {
            // Near-monochrome but not strict mono: low-sat photo, off-white
            // sleeve with a small logo, dim duo-tone, etc.
            s = min(s, scheme == .dark ? 0.26 : 0.20)
        } else if analysis.dominantHueConfidence < 0.18 {
            s = min(s, scheme == .dark ? 0.40 : 0.32)
        }

        return ColorMath.color(h: h, s: s, l: l)
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
                s: ColorMath.clamp(hsl.s + 0.04, 0.10, 0.34),
                l: 0.12
            )
        } else {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(hsl.s, 0.04, 0.24),
                l: 0.92
            )
        }
    }

    fileprivate static func secondaryTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor.withAlphaComponent(0.86)
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
        windowLyricActive(analysis: analysis, isDark: isDark).withAlphaComponent(0.35)
    }

    fileprivate static func fullscreenLyricBase(analysis: ArtworkColorAnalysis) -> NSColor {
        // High colorfulness + clear hue dominance → use the dominant cover hue.
        // Otherwise fall back to the best text source colour (already mid-tone, hue-rich).
        if analysis.colorfulness >= 0.20 && analysis.dominantHueConfidence >= 0.20 {
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
        let s = ColorMath.clamp(hsl.s * 0.92, 0.10, 0.62)
        let l = ColorMath.clamp(hsl.l, 0.22, 0.78)
        return ColorMath.color(h: hsl.h, s: s, l: l)
    }

    fileprivate static func coverGradientText(analysis: ArtworkColorAnalysis) -> NSColor {
        // Stronger contrast bias than readableTextOnArtwork — used over a blurred
        // cover, not a solid surface.
        let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
        if analysis.usesDarkForeground {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(hsl.s, 0.18, 0.36),
                l: 0.16
            )
        } else {
            return ColorMath.color(
                h: hsl.h,
                s: ColorMath.clamp(hsl.s, 0.06, 0.20),
                l: 0.94
            )
        }
    }
}

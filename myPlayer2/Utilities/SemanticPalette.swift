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
        // Behaviour-equivalent to ThemeStore.optimizeAccentColor pre-refactor.
        let raw = analysis.dominantColor
        guard let rgb = raw.usingColorSpace(.deviceRGB) else { return raw }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        s = max(s, 0.24)
        b = max(b, 0.22)
        if scheme == .dark {
            s = min(max(s * 1.06, 0.30), 0.90)
            b = min(max(b * 1.10, 0.62), 0.88)
            let pre = NSColor(deviceHue: h, saturation: s, brightness: b, alpha: 1)
            return ColorMath.clampLightness(pre, lo: 0.56, hi: 1.0)
        } else {
            s = min(max(s * 1.02, 0.28), 0.78)
            b = min(max(b * 0.88, 0.28), 0.68)
            return NSColor(deviceHue: h, saturation: s, brightness: b, alpha: 1)
        }
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
        analysis.bestTextSourceColor
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
        analysis.bestTextSourceColor
    }

    fileprivate static func fullscreenLyricInactiveBase(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor
    }

    fileprivate static func coverGradientDominant(
        analysis: ArtworkColorAnalysis,
        isDark: Bool
    ) -> NSColor {
        analysis.dominantColor
    }

    fileprivate static func coverGradientText(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor
    }
}

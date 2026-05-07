//
//  LEDColorResolver.swift
//  myPlayer2
//
//  LED-dedicated color resolver with dual-tone gradient, level-driven hue shift,
//  adaptive light/dark, opaque Normal compositing.
//  Internal color math uses OKLCH via OKColor utility.
//

import AppKit
import SwiftUI

struct LEDColorResolver {
    let palette: SemanticPalette?
    let accentColor: Color
    let colorScheme: ColorScheme
    let brightnessLevels: Int
    let isEffectivelyMonochrome: Bool

    private var accentNS: NSColor {
        NSColor(accentColor)
    }

    init(
        accentColor: Color,
        colorScheme: ColorScheme,
        brightnessLevels: Int,
        palette: SemanticPalette? = nil
    ) {
        self.accentColor = accentColor
        self.colorScheme = colorScheme
        self.brightnessLevels = max(2, brightnessLevels)
        self.palette = palette
        self.isEffectivelyMonochrome = palette?.analysis.isEffectivelyMonochrome ?? false
    }

    // MARK: - Neutral Base (for monochrome artwork)

    private var stableWarmHue: CGFloat { 0.105 }
    private var stableNeutralHue: CGFloat { 0.60 }

    private var neutralLEDOKLCH: OKColor.OKLCH {
        OKColor.OKLCH(
            l: colorScheme == .dark ? 0.82 : 0.46,
            c: colorScheme == .dark ? 0.010 : 0.008,
            h: stableNeutralHue
        )
    }

    // MARK: - Base Colors

    private var rawBase: NSColor {
        if let palette {
            return colorScheme == .dark ? palette.uiAccentOnDark : palette.uiAccentOnLight
        }
        return accentNS
    }

    var centerColor: NSColor {
        if let palette, shouldUseNeutralVolumeLED(for: palette) {
            if hasClearMainColor(in: palette),
               let lch = OKColor.nsColorToOKLCH(colorScheme == .dark ? palette.uiAccentOnDark : palette.uiAccentOnLight) {
                return OKColor.okLCHToNSColor(optimizedLEDLCH(from: lch, preservesLowChromaHue: true), alpha: 1.0)
            }
            let source = nearNeutralVolumeSourceColor(for: palette.analysis)
            guard let lch = OKColor.nsColorToOKLCH(source) else {
                return OKColor.okLCHToNSColor(neutralLEDOKLCH, alpha: 1.0)
            }
            return OKColor.okLCHToNSColor(optimizedNearNeutralLEDLCH(from: lch), alpha: 1.0)
        }

        guard let lch = OKColor.nsColorToOKLCH(volumeLEDSourceColor) else {
            return rawBase
        }

        return OKColor.okLCHToNSColor(optimizedLEDLCH(from: lch, preservesLowChromaHue: true), alpha: 1.0)
    }

    private var volumeLEDSourceColor: NSColor {
        if let palette, shouldUseNeutralVolumeLED(for: palette) {
            if hasClearMainColor(in: palette) {
                return colorScheme == .dark ? palette.uiAccentOnDark : palette.uiAccentOnLight
            }
            return nearNeutralVolumeSourceColor(for: palette.analysis)
        }
        return rawBase
    }

    private func optimizedNearNeutralLEDLCH(from source: OKColor.OKLCH) -> OKColor.OKLCH {
        let l = colorScheme == .dark ? CGFloat(0.82) : CGFloat(0.46)
        let sourceC = min(source.c, 0.040)
        let chromaCap: CGFloat = colorScheme == .dark ? 0.024 : 0.020
        let c = ColorMath.clamp(sourceC * 0.42, 0.006, chromaCap)
        return OKColor.OKLCH(l: l, c: c, h: source.h)
    }

    private func nearNeutralVolumeSourceColor(for analysis: ArtworkColorAnalysis) -> NSColor {
        guard !analysis.isMonochrome else {
            return OKColor.okLCHToNSColor(neutralLEDOKLCH, alpha: 1.0)
        }
        let average = ColorMath.hsl(of: analysis.averageColor)
        let averageHueIsStable = average.s >= 0.045
            && analysis.avgSaturation >= 0.045
            && analysis.lightnessVariance < 0.090
        if averageHueIsStable {
            return analysis.averageColor
        }
        return OKColor.okLCHToNSColor(neutralLEDOKLCH, alpha: 1.0)
    }

    private func optimizedLEDLCH(from source: OKColor.OKLCH, preservesLowChromaHue: Bool) -> OKColor.OKLCH {
        let lowChromaThreshold: CGFloat = 0.045
        let sourceHue = source.c < lowChromaThreshold && !preservesLowChromaHue ? fallbackHue() : source.h
        let baseL: CGFloat
        let capC: CGFloat
        let minC: CGFloat
        let scaleC: CGFloat

        if colorScheme == .dark {
            switch sourceHue {
            case 0.55..<0.92:  // blue/purple needs a little more L to stay clear on dark UI
                baseL = 0.855
            case 0.08..<0.20:  // amber/yellow glows sooner
                baseL = 0.805
            default:
                baseL = 0.835
            }
            minC = 0.066
            capC = hueAwareChromaCap(for: sourceHue, darkMode: true) * 1.08
            scaleC = 0.82
        } else {
            switch sourceHue {
            case 0.55..<0.92:
                baseL = 0.49
            case 0.08..<0.20:
                baseL = 0.44
            default:
                baseL = 0.47
            }
            minC = 0.057
            capC = hueAwareChromaCap(for: sourceHue, darkMode: false) * 1.08
            scaleC = 0.74
        }

        let requestedC = source.c < lowChromaThreshold
            ? (colorScheme == .dark ? 0.075 : 0.065)
            : source.c * scaleC
        let baseC = ColorMath.clamp(requestedC, minC, capC)
        return OKColor.OKLCH(l: baseL, c: baseC, h: sourceHue)
    }

    private func hueAwareChromaCap(for h: CGFloat, darkMode: Bool) -> CGFloat {
        switch h {
        case 0.18..<0.30: return darkMode ? 0.105 : 0.092 // yellow is the first to look neon/dirty
        case 0.25..<0.45: return darkMode ? 0.125 : 0.108 // keep greens controlled
        case 0.55..<0.75: return darkMode ? 0.150 : 0.128 // blue needs less C to read saturated
        case 0.75..<0.92: return darkMode ? 0.135 : 0.116
        default:          return darkMode ? 0.155 : 0.132
        }
    }

    private func fallbackHue() -> CGFloat {
        if let palette {
            let analysis = palette.analysis
            if analysis.colorfulness >= 0.14,
               analysis.dominantHueConfidence >= 0.18,
               let dominantLCH = OKColor.nsColorToOKLCH(analysis.dominantColor),
               dominantLCH.c >= 0.060 {
                return dominantLCH.h
            }
            if let textSourceLCH = OKColor.nsColorToOKLCH(analysis.bestTextSourceColor),
               textSourceLCH.c >= 0.070 {
                return textSourceLCH.h
            }
        }

        if palette == nil,
           let accentLCH = OKColor.nsColorToOKLCH(accentNS),
           accentLCH.c >= 0.050 {
            return accentLCH.h
        }

        return stableWarmHue
    }

    private func hasClearMainColor(in palette: SemanticPalette) -> Bool {
        let analysis = palette.analysis
        guard !analysis.isMonochrome else { return false }

        let average = ColorMath.hsl(of: analysis.averageColor)
        let dominant = ColorMath.hsl(of: analysis.dominantColor)
        let averageHueUsable = average.s >= 0.105
            && analysis.avgSaturation >= 0.095
            && analysis.colorfulness >= 0.105
            && isCoolMainHue(average.h)
        let dominantHueUsable = dominant.s >= 0.150
            && analysis.dominantHueConfidence >= 0.24
            && analysis.largestHighSaturationAreaShare >= 0.14
            && isCoolMainHue(dominant.h)
        let analysisDominantHueUsable = analysis.dominantSaturation >= 0.150
            && analysis.dominantHueConfidence >= 0.24
            && analysis.largestHighSaturationAreaShare >= 0.14
            && isCoolMainHue(analysis.dominantHue)

        return averageHueUsable || dominantHueUsable || analysisDominantHueUsable
    }

    private func shouldUseNeutralVolumeLED(for palette: SemanticPalette) -> Bool {
        let analysis = palette.analysis
        let nearNeutralArtwork = analysis.colorfulness < 0.18
            && analysis.avgSaturation < 0.18
            && analysis.dominantSaturation < 0.22
            && analysis.largestHighSaturationAreaShare < 0.18
        return analysis.isEffectivelyMonochrome || nearNeutralArtwork
    }

    private func isCoolMainHue(_ h: CGFloat) -> Bool {
        (h >= 0.34 && h <= 0.72)
    }

    var edgeColor: NSColor {
        guard let centerLCH = OKColor.nsColorToOKLCH(centerColor) else {
            return centerColor
        }

        var edgeH = centerLCH.h
        if centerLCH.h < 0.08 || centerLCH.h >= 0.92 {
            edgeH += 0.012  // red
        } else if centerLCH.h >= 0.55 && centerLCH.h < 0.75 {
            edgeH -= 0.014  // blue
        } else if centerLCH.h >= 0.25 && centerLCH.h < 0.45 {
            edgeH += 0.012  // green
        } else {
            edgeH += 0.010  // default
        }
        edgeH = edgeH.truncatingRemainder(dividingBy: 1)
        if edgeH < 0 { edgeH += 1 }

        let edgeC = centerLCH.c * 0.90
        let edgeL = centerLCH.l - (colorScheme == .dark ? 0.030 : 0.020)

        return OKColor.okLCHToNSColor(
            OKColor.OKLCH(l: edgeL, c: edgeC, h: edgeH),
            alpha: 1.0
        )
    }

    // MARK: - Status Light Base Color

    private var statusLightBaseColor: NSColor {
        if isEffectivelyMonochrome {
            return OKColor.okLCHToNSColor(neutralLEDOKLCH, alpha: 1.0)
        }
        if let palette {
            let candidate = palette.coverGradientDominant
            guard let centerLCH = OKColor.nsColorToOKLCH(centerColor) else {
                return centerColor
            }
            guard let candidateLCH = OKColor.nsColorToOKLCH(candidate) else {
                return centerColor
            }
            if ColorMath.circularHueDistance(centerLCH.h, candidateLCH.h) > 0.03 {
                return OKColor.okLCHToNSColor(optimizedLEDLCH(from: candidateLCH, preservesLowChromaHue: false), alpha: 1.0)
            }
            if let secondaryLCH = OKColor.nsColorToOKLCH(palette.artBackgroundSecondary) {
                return OKColor.okLCHToNSColor(optimizedLEDLCH(from: secondaryLCH, preservesLowChromaHue: false), alpha: 1.0)
            }
            return centerColor
        }
        // Fallback: shift hue from rawBase
        guard let rawLCH = OKColor.nsColorToOKLCH(rawBase) else {
            return rawBase
        }
        return OKColor.okLCHToNSColor(optimizedLEDLCH(from: rawLCH, preservesLowChromaHue: false), alpha: 1.0)
    }

    // MARK: - Gradient Interpolation (OKLab)

    private func baseColorForIndex(index: Int, count: Int) -> NSColor {
        guard count > 1 else { return centerColor }
        guard let centerLCH = OKColor.nsColorToOKLCH(centerColor),
              let edgeLCH = OKColor.nsColorToOKLCH(edgeColor) else {
            return centerColor
        }
        let centerLab = OKColor.okLCHToOKLab(centerLCH)
        let edgeLab = OKColor.okLCHToOKLab(edgeLCH)
        let center = Double(count - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        let t = CGFloat(distance)
        let oneMinusT = CGFloat(1.0) - t
        let lerpedLab = OKColor.OKLab(
            l: centerLab.l * oneMinusT + edgeLab.l * t,
            a: centerLab.a * oneMinusT + edgeLab.a * t,
            b: centerLab.b * oneMinusT + edgeLab.b * t
        )
        let lerpedLCH = OKColor.okLabToOKLCH(lerpedLab)
        return OKColor.okLCHToNSColor(lerpedLCH, alpha: 1.0)
    }

    // MARK: - Level-Driven Color (OKLCH)

    private func oklchColorForLevel(
        base baseNS: NSColor,
        level: Int,
        isStroke: Bool = false
    ) -> NSColor {
        guard let baseLCH = OKColor.nsColorToOKLCH(baseNS) else { return baseNS }
        let maxLevel = max(1, brightnessLevels - 1)
        let t = CGFloat(min(level, maxLevel)) / CGFloat(maxLevel)
        let oneMinusT = 1.0 - t

        let l: CGFloat
        if colorScheme == .dark {
            l = baseLCH.l - 0.020 * oneMinusT + 0.010 * t
        } else {
            l = baseLCH.l - 0.012 * oneMinusT + 0.008 * t
        }

        let c = baseLCH.c * (0.94 + 0.06 * t)

        let h = ColorMath.normalizedHue(baseLCH.h + hueShift(baseLCH.h) * oneMinusT)

        if isStroke {
            let strokeL = l - (colorScheme == .dark ? 0.070 : 0.045)
            let strokeC = c * 0.96
            return OKColor.okLCHToNSColor(OKColor.OKLCH(l: strokeL, c: strokeC, h: h), alpha: 1.0)
        }
        return OKColor.okLCHToNSColor(OKColor.OKLCH(l: l, c: c, h: h), alpha: 1.0)
    }

    // Helper: returns max hue shift for a given hue (in normalized units, 0...1)
    private func hueShift(_ h: CGFloat) -> CGFloat {
        switch h {
        case 0.0..<0.08, 0.92..<1.0: return +0.010
        case 0.08..<0.20:             return -0.014
        case 0.20..<0.25:             return -0.012
        case 0.25..<0.42:             return +0.014
        case 0.42..<0.52:             return +0.010
        case 0.52..<0.65:             return +0.012
        case 0.65..<0.75:             return +0.012
        case 0.75..<0.85:             return -0.010
        case 0.85..<0.92:             return -0.010
        default:                      return 0
        }
    }

    // MARK: - Opacity (primary brightness control)

    private func opacityForLevel(level: Int) -> Double {
        guard level > 0, brightnessLevels > 1 else { return 0 }
        let maxLevel = brightnessLevels - 1
        let t = Double(level) / Double(maxLevel)
        if colorScheme == .dark {
            return 0.08 + pow(t, 1.55) * 0.92
        } else {
            return 0.06 + pow(t, 1.65) * 0.94
        }
    }

    // MARK: - Status Light

    func statusLightColor(level: Int) -> Color {
        Color(nsColor: oklchColorForLevel(base: statusLightBaseColor, level: level))
            .opacity(opacityForLevel(level: level))
    }

    func statusLightStrokeColor(level: Int) -> Color {
        Color(nsColor: oklchColorForLevel(base: statusLightBaseColor, level: level, isStroke: true))
            .opacity(min(0.50, opacityForLevel(level: level) * 0.55))
    }

    // MARK: - Volume LED

    func volumeLEDColor(index: Int, count: Int, level: Int) -> Color {
        let base = baseColorForIndex(index: index, count: count)
        return Color(nsColor: oklchColorForLevel(base: base, level: level))
            .opacity(opacityForLevel(level: level))
    }

    func volumeLEDStrokeColor(index: Int, count: Int, level: Int) -> Color {
        let base = baseColorForIndex(index: index, count: count)
        return Color(nsColor: oklchColorForLevel(base: base, level: level, isStroke: true))
            .opacity(min(0.50, opacityForLevel(level: level) * 0.55))
    }
}

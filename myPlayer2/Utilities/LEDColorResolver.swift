//
//  LEDColorResolver.swift
//  myPlayer2
//
//  LED-dedicated color resolver with dual-tone gradient, level-driven hue shift,
//  adaptive light/dark, opaque Normal compositing.
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

    private var neutralLEDBase: NSColor {
        let h: CGFloat = 0.58 // cool silver/blue-grey
        let s: CGFloat = colorScheme == .dark ? 0.06 : 0.05
        let l: CGFloat = colorScheme == .dark
            ? ColorMath.clamp(0.62, 0.55, 0.72)
            : ColorMath.clamp(0.38, 0.30, 0.45)
        return ColorMath.color(h: h, s: s, l: l)
    }

    // MARK: - Base Colors

    private var rawBase: NSColor {
        if let palette {
            return colorScheme == .dark ? palette.uiAccentOnDark : palette.uiAccentOnLight
        }
        return accentNS
    }

    var centerColor: NSColor {
        if isEffectivelyMonochrome {
            return neutralLEDBase
        }
        let hsl = ColorMath.hsl(of: rawBase)
        if colorScheme == .dark {
            // Bright vivid base — stays colorful even at low opacity
            let s = ColorMath.clamp(hsl.s * 1.10, 0.60, 1.0)
            let l = ColorMath.clamp(hsl.l, 0.52, 0.72)
            return ColorMath.color(h: hsl.h, s: s, l: l)
        } else {
            // Dark vivid base — never pure black, keeps hue at low opacity
            let s = ColorMath.clamp(hsl.s * 1.05, 0.55, 0.95)
            let l = ColorMath.clamp(hsl.l * 0.50, 0.25, 0.42)
            return ColorMath.color(h: hsl.h, s: s, l: l)
        }
    }

    var edgeColor: NSColor {
        if isEffectivelyMonochrome {
            let hsl = ColorMath.hsl(of: neutralLEDBase)
            let l = colorScheme == .dark
                ? ColorMath.clamp(hsl.l * 0.90, 0.46, 0.64)
                : ColorMath.clamp(hsl.l * 0.90, 0.22, 0.38)
            return ColorMath.color(h: hsl.h, s: hsl.s, l: l)
        }
        let hsl = ColorMath.hsl(of: centerColor)
        var h = hsl.h
        // Gentle hue shift based on region
        if h >= 0.08 && h < 0.17 {
            h = ColorMath.normalizedHue(h - 0.05) // orange → yellow
        } else if h >= 0.55 && h < 0.75 {
            h = ColorMath.normalizedHue(h + 0.04) // blue → violet
        } else if h >= 0.25 && h < 0.45 {
            h = ColorMath.normalizedHue(h + 0.05) // green → cyan
        } else if h < 0.08 || h >= 0.92 {
            h = ColorMath.normalizedHue(h + 0.03) // red → orange
        } else if h >= 0.75 && h < 0.92 {
            h = ColorMath.normalizedHue(h - 0.03) // purple → blue
        }
        let s = ColorMath.clamp(hsl.s * 0.92, 0.50, 0.95)
        let l = colorScheme == .dark
            ? ColorMath.clamp(hsl.l * 0.90, 0.46, 0.64)
            : ColorMath.clamp(hsl.l * 0.90, 0.22, 0.38)
        return ColorMath.color(h: h, s: s, l: l)
    }

    // MARK: - Status Light Base Color

    private var statusLightBaseColor: NSColor {
        if isEffectivelyMonochrome {
            return neutralLEDBase
        }
        if let palette {
            let candidate = palette.coverGradientDominant
            let centerHSL = ColorMath.hsl(of: centerColor)
            let candidateHSL = ColorMath.hsl(of: candidate)
            if ColorMath.circularHueDistance(centerHSL.h, candidateHSL.h) > 0.03 {
                return candidate
            }
            return palette.artBackgroundSecondary
        }
        let hsl = ColorMath.hsl(of: rawBase)
        let h = ColorMath.normalizedHue(hsl.h + 0.05)
        let s = min(1.0, hsl.s * 1.10)
        let l = colorScheme == .dark
            ? ColorMath.clamp(hsl.l * 0.95, 0.40, 0.60)
            : ColorMath.clamp(hsl.l * 0.50, 0.25, 0.42)
        return ColorMath.color(h: h, s: s, l: l)
    }

    // MARK: - Mix

    private func mix(_ a: NSColor, _ b: NSColor, t: CGFloat) -> NSColor {
        let ar = a.redComponent, ag = a.greenComponent, ab = a.blueComponent, aa = a.alphaComponent
        let br = b.redComponent, bg = b.greenComponent, bb = b.blueComponent, ba = b.alphaComponent
        let u = 1 - t
        return NSColor(
            deviceRed: ColorMath.clamp(ar * u + br * t, 0, 1),
            green: ColorMath.clamp(ag * u + bg * t, 0, 1),
            blue: ColorMath.clamp(ab * u + bb * t, 0, 1),
            alpha: ColorMath.clamp(aa * u + ba * t, 0, 1)
        )
    }

    private func baseColorForIndex(index: Int, count: Int) -> NSColor {
        guard count > 1 else { return centerColor }
        let center = Double(count - 1) / 2.0
        let distance = abs(Double(index) - center) / center // 0..1
        return mix(centerColor, edgeColor, t: CGFloat(distance))
    }

    // MARK: - Level-Driven Color

    private func darkEmissiveColor(
        base: NSColor,
        level: Int,
        isStroke: Bool = false
    ) -> NSColor {
        let maxLevel = max(1, brightnessLevels - 1)
        let t = CGFloat(min(level, maxLevel)) / CGFloat(maxLevel)
        let eased = t * t * (3 - 2 * t) // smoothstep
        let hsl = ColorMath.hsl(of: base)

        if isEffectivelyMonochrome {
            let minL: CGFloat = 0.82
            let targetL: CGFloat = 0.95
            let l = minL + (targetL - minL) * eased
            let s = isStroke ? hsl.s * 0.95 : hsl.s
            let finalL = isStroke ? l * 0.96 : l
            return ColorMath.color(h: hsl.h, s: s, l: finalL)
        }

        let h = hsl.h
        let (targetL, targetS): (CGFloat, CGFloat)
        switch h {
        case 0.92..<1.0, 0.0..<0.08:
            targetL = 0.93; targetS = 0.96   // red: vivid LED red
        case 0.08..<0.15:
            targetL = 0.94; targetS = 0.94   // orange: rich warm glow
        case 0.15..<0.20:
            targetL = 0.94; targetS = 0.86   // amber: warm amber LED
        case 0.20..<0.25:
            targetL = 0.94; targetS = 0.76   // yellow: amber-adjacent warm white, not dirty grey
        case 0.25..<0.42:
            targetL = 0.92; targetS = 0.84   // green: bright LED green
        case 0.42..<0.52:
            targetL = 0.93; targetS = 0.82   // cyan: luminous teal
        case 0.52..<0.65:
            targetL = 0.95; targetS = 0.82   // sky blue: bright, soft, not grey
        case 0.65..<0.75:
            targetL = 0.95; targetS = 0.78   // blue: vivid with chroma
        case 0.75..<0.85:
            targetL = 0.96; targetS = 0.72   // purple/violet: rich, not grey-lavender
        case 0.85..<0.92:
            targetL = 0.95; targetS = 0.76   // magenta/pink: colorful, not fuchsia-blind
        default:
            targetL = 0.94; targetS = 0.78
        }

        // Saturation floor: level 1 keeps ≥84% of targetS, not base→target lerp
        let satFloor = targetS * 0.84
        let s = satFloor + (targetS - satFloor) * eased

        // Lightness floor: level 1 ≥ 0.80, target at max
        let minL: CGFloat = 0.80
        let l = minL + (targetL - minL) * eased

        if isStroke {
            return ColorMath.color(h: h, s: s * 0.98, l: l * 0.96)
        }
        return ColorMath.color(h: h, s: s, l: l)
    }

    private func colorForLevel(
        base: NSColor,
        level: Int,
        isStroke: Bool = false
    ) -> NSColor {
        if colorScheme == .dark {
            return darkEmissiveColor(base: base, level: level, isStroke: isStroke)
        }

        let maxLevel = max(1, brightnessLevels - 1)
        let t = CGFloat(min(level, maxLevel)) / CGFloat(maxLevel)
        let hsl = ColorMath.hsl(of: base)
        var h = hsl.h
        var s = hsl.s
        var l = hsl.l

        if isEffectivelyMonochrome {
            l = l * (0.92 + 0.08 * t)
            if isStroke {
                l = l * 0.92
            }
            return ColorMath.color(h: hsl.h, s: hsl.s, l: l)
        }

        // Hue warmth shift for low levels
        let oneMinus = 1 - t
        if h >= 0.08 && h < 0.17 {
            h = ColorMath.normalizedHue(h - 0.05 * oneMinus)
        } else if h >= 0.55 && h < 0.75 {
            h = ColorMath.normalizedHue(h + 0.05 * oneMinus)
        } else if h >= 0.25 && h < 0.45 {
            h = ColorMath.normalizedHue(h + 0.06 * oneMinus)
        } else if h < 0.08 || h >= 0.92 {
            h = ColorMath.normalizedHue(h + 0.04 * oneMinus)
        } else if h >= 0.75 && h < 0.92 {
            h = ColorMath.normalizedHue(h - 0.04 * oneMinus)
        }

        s = min(1.0, s * (1.0 + 0.22 * oneMinus))
        l = l * (0.92 + 0.08 * t)

        if isStroke {
            s = min(1.0, s * 1.06)
            l = l * 0.92
        }

        return ColorMath.color(h: h, s: s, l: l)
    }

    // MARK: - Opacity (primary brightness control)

    private func opacityForLevel(level: Int) -> Double {
        guard level > 0, brightnessLevels > 1 else { return 0 }
        let maxLevel = brightnessLevels - 1
        let fraction = Double(level) / Double(maxLevel)
        if colorScheme == .dark {
            let eased = fraction * fraction * (3 - 2 * fraction)
            let minOpacity = 0.58
            return minOpacity + eased * (1.0 - minOpacity)
        } else {
            return 0.40 + fraction * 0.60
        }
    }

    // MARK: - Status Light

    func statusLightColor(level: Int) -> Color {
        Color(nsColor: colorForLevel(base: statusLightBaseColor, level: level))
            .opacity(opacityForLevel(level: level))
    }

    func statusLightStrokeColor(level: Int) -> Color {
        Color(nsColor: colorForLevel(base: statusLightBaseColor, level: level, isStroke: true))
            .opacity(min(0.55, opacityForLevel(level: level) * 0.70))
    }

    // MARK: - Volume LED

    func volumeLEDColor(index: Int, count: Int, level: Int) -> Color {
        let base = baseColorForIndex(index: index, count: count)
        return Color(nsColor: colorForLevel(base: base, level: level))
            .opacity(opacityForLevel(level: level))
    }

    func volumeLEDStrokeColor(index: Int, count: Int, level: Int) -> Color {
        let base = baseColorForIndex(index: index, count: count)
        return Color(nsColor: colorForLevel(base: base, level: level, isStroke: true))
            .opacity(min(0.55, opacityForLevel(level: level) * 0.70))
    }

}

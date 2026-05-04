//
//  LEDColorResolver.swift
//  myPlayer2
//
//  LED-dedicated color resolver with dual-tone gradient, level-driven hue shift,
//  adaptive light/dark, and plusLighter glow.
//

import AppKit
import SwiftUI

struct LEDColorResolver {
    let palette: SemanticPalette?
    let accentColor: Color
    let colorScheme: ColorScheme
    let brightnessLevels: Int

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
    }

    // MARK: - Base Colors

    private var rawBase: NSColor {
        if let palette {
            return colorScheme == .dark ? palette.uiAccentOnDark : palette.uiAccentOnLight
        }
        return accentNS
    }

    var centerColor: NSColor {
        let hsl = ColorMath.hsl(of: rawBase)
        if colorScheme == .dark {
            let l = ColorMath.clamp(hsl.l, 0.32, 0.52)
            return ColorMath.color(h: hsl.h, s: hsl.s, l: l)
        }
        let l = ColorMath.clamp(hsl.l * 1.30, 0.78, 0.90)
        return ColorMath.color(h: hsl.h, s: hsl.s, l: l)
    }

    var edgeColor: NSColor {
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
        let s = ColorMath.clamp(hsl.s * 0.92, 0.30, 0.90)
        let l = colorScheme == .dark
            ? ColorMath.clamp(hsl.l * 0.92, 0.28, 0.48)
            : ColorMath.clamp(hsl.l * 1.08, 0.72, 0.82)
        return ColorMath.color(h: h, s: s, l: l)
    }

    // MARK: - Status Light Base Color

    private var statusLightBaseColor: NSColor {
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
            ? ColorMath.clamp(hsl.l * 0.95, 0.30, 0.50)
            : ColorMath.clamp(hsl.l * 1.05, 0.70, 0.88)
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

    private func colorForLevel(
        base: NSColor,
        level: Int,
        isStroke: Bool = false
    ) -> NSColor {
        let maxLevel = max(1, brightnessLevels - 1)
        let levelRatio = CGFloat(min(level, maxLevel)) / CGFloat(maxLevel)
        let hsl = ColorMath.hsl(of: base)
        var h = hsl.h
        var s = hsl.s
        var l = hsl.l

        // Enhanced hue shift for low levels
        let oneMinus = 1 - levelRatio
        if h >= 0.08 && h < 0.17 {
            h = ColorMath.normalizedHue(h - 0.05 * oneMinus)  // orange → yellow, ~18°
        } else if h >= 0.55 && h < 0.75 {
            h = ColorMath.normalizedHue(h + 0.05 * oneMinus)  // blue → violet, ~18°
        } else if h >= 0.25 && h < 0.45 {
            h = ColorMath.normalizedHue(h + 0.06 * oneMinus)  // green → cyan, ~22°
        } else if h < 0.08 || h >= 0.92 {
            h = ColorMath.normalizedHue(h + 0.04 * oneMinus)  // red → orange, ~14°
        } else if h >= 0.75 && h < 0.92 {
            h = ColorMath.normalizedHue(h - 0.04 * oneMinus)  // purple → blue, ~14°
        }

        s = min(1.0, s * (1.0 + 0.18 * oneMinus))

        if colorScheme == .dark {
            l = l * (0.40 + 0.40 * levelRatio)
            l = min(l, 0.55)
        } else {
            l = l * (0.88 + 0.12 * levelRatio)
            l = min(l, 0.92)
        }

        if isStroke {
            s = min(1.0, s + 0.08)
            l = l * 0.80
        }

        return ColorMath.color(h: h, s: s, l: l)
    }

    private func opacityForLevel(level: Int) -> Double {
        guard level > 0, brightnessLevels > 1 else { return 0 }
        let maxLevel = brightnessLevels - 1
        let fraction = Double(level) / Double(maxLevel)
        let minOpacity = colorScheme == .dark ? 0.20 : 0.60
        let maxOpacity = 1.0
        return minOpacity + fraction * (maxOpacity - minOpacity)
    }

    // MARK: - Status Light

    func statusLightColor(level: Int) -> Color {
        let ns = colorForLevel(base: statusLightBaseColor, level: level)
        return Color(nsColor: ns).opacity(opacityForLevel(level: level))
    }

    func statusLightStrokeColor(level: Int) -> Color {
        let ns = colorForLevel(base: statusLightBaseColor, level: level, isStroke: true)
        return Color(nsColor: ns).opacity(min(0.60, opacityForLevel(level: level) * 0.70))
    }

    // MARK: - Volume LED

    func volumeLEDColor(index: Int, count: Int, level: Int) -> Color {
        let base = baseColorForIndex(index: index, count: count)
        let ns = colorForLevel(base: base, level: level)
        return Color(nsColor: ns).opacity(opacityForLevel(level: level))
    }

    func volumeLEDStrokeColor(index: Int, count: Int, level: Int) -> Color {
        let base = baseColorForIndex(index: index, count: count)
        let ns = colorForLevel(base: base, level: level, isStroke: true)
        return Color(nsColor: ns).opacity(min(0.60, opacityForLevel(level: level) * 0.70))
    }

    var ledBlendMode: BlendMode {
        colorScheme == .dark ? .plusLighter : .plusDarker
    }
}

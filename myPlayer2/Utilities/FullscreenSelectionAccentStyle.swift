//
//  FullscreenSelectionAccentStyle.swift
//  myPlayer2
//
//  kmgccc_player - Shared fullscreen selection accent adjustment.
//

import AppKit
import SwiftUI

enum FullscreenSelectionAccentStyle {
    private static let brightTargetLightness: CGFloat = 0.92
    private static let darkTargetLightness: CGFloat = 0.18

    static func adjustedAccent(from color: NSColor) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetLightness = hsl.l >= 0.5
            ? max(hsl.l, brightTargetLightness)
            : min(hsl.l, darkTargetLightness)
        let tunedSaturation = clamp(hsl.s, min: 0.22, max: 0.92)
        return rgbColorFromHsl(h: hsl.h, s: tunedSaturation, l: targetLightness)
    }

    static func adjustedAccentColor(from color: NSColor) -> Color {
        Color(nsColor: adjustedAccent(from: color))
    }

    private static func hslComponents(from color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }

        let r = clamp(rgb.redComponent, min: 0, max: 1)
        let g = clamp(rgb.greenComponent, min: 0, max: 1)
        let b = clamp(rgb.blueComponent, min: 0, max: 1)

        let maxValue = max(r, max(g, b))
        let minValue = min(r, min(g, b))
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        var hue: CGFloat = 0
        if delta > 0.000_001 {
            if maxValue == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == g {
                hue = ((b - r) / delta) + 2
            } else {
                hue = ((r - g) / delta) + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }

        var saturation: CGFloat = 0
        if delta > 0.000_001 {
            saturation = delta / (1 - abs(2 * lightness - 1))
        }

        return (hue, saturation, lightness)
    }

    private static func rgbColorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let saturation = clamp(s, min: 0, max: 1)
        let lightness = clamp(l, min: 0, max: 1)
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let scaledHue = (h - floor(h)) * 6
        let x = chroma * (1 - abs(scaledHue.truncatingRemainder(dividingBy: 2) - 1))

        let components: (CGFloat, CGFloat, CGFloat)
        switch scaledHue {
        case 0..<1:
            components = (chroma, x, 0)
        case 1..<2:
            components = (x, chroma, 0)
        case 2..<3:
            components = (0, chroma, x)
        case 3..<4:
            components = (0, x, chroma)
        case 4..<5:
            components = (x, 0, chroma)
        default:
            components = (chroma, 0, x)
        }

        let match = lightness - chroma * 0.5
        return NSColor(
            calibratedRed: clamp(components.0 + match, min: 0, max: 1),
            green: clamp(components.1 + match, min: 0, max: 1),
            blue: clamp(components.2 + match, min: 0, max: 1),
            alpha: 1
        )
    }

    private static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minValue), maxValue)
    }
}

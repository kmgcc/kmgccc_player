//
//  HSLColorUtilities.swift
//  myPlayer2
//
//  Shared HSL conversion helpers used by fullscreen lyrics theming.
//

import AppKit

struct HSLComponents {
    let hue: CGFloat
    let saturation: CGFloat
    let lightness: CGFloat
}

enum HSLColorUtilities {
    static func hslComponents(from color: NSColor) -> HSLComponents {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        var hue: CGFloat = 0
        var saturation: CGFloat = 0

        if delta > 0.000_1 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = ((blue - red) / delta) + 2
            } else {
                hue = ((red - green) / delta) + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }

        return HSLComponents(
            hue: clamp(hue, min: 0, max: 1),
            saturation: clamp(saturation, min: 0, max: 1),
            lightness: clamp(lightness, min: 0, max: 1)
        )
    }

    static func colorFromHSL(hue: CGFloat, saturation: CGFloat, lightness: CGFloat) -> NSColor {
        let h = clamp(hue, min: 0, max: 1)
        let s = clamp(saturation, min: 0, max: 1)
        let l = clamp(lightness, min: 0, max: 1)

        if s < 0.000_1 {
            return NSColor(calibratedRed: l, green: l, blue: l, alpha: 1)
        }

        let chroma = (1 - abs(2 * l - 1)) * s
        let scaledHue = h * 6
        let secondary = chroma * (1 - abs(scaledHue.truncatingRemainder(dividingBy: 2) - 1))
        let match = l - chroma * 0.5

        let redPrime: CGFloat
        let greenPrime: CGFloat
        let bluePrime: CGFloat

        switch scaledHue {
        case 0..<1:
            redPrime = chroma
            greenPrime = secondary
            bluePrime = 0
        case 1..<2:
            redPrime = secondary
            greenPrime = chroma
            bluePrime = 0
        case 2..<3:
            redPrime = 0
            greenPrime = chroma
            bluePrime = secondary
        case 3..<4:
            redPrime = 0
            greenPrime = secondary
            bluePrime = chroma
        case 4..<5:
            redPrime = secondary
            greenPrime = 0
            bluePrime = chroma
        default:
            redPrime = chroma
            greenPrime = 0
            bluePrime = secondary
        }

        return NSColor(
            calibratedRed: clamp(redPrime + match, min: 0, max: 1),
            green: clamp(greenPrime + match, min: 0, max: 1),
            blue: clamp(bluePrime + match, min: 0, max: 1),
            alpha: 1
        )
    }

    static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(upper, Swift.max(lower, value))
    }
}

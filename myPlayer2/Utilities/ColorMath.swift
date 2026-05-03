//
//  ColorMath.swift
//  myPlayer2
//
//  Shared HSL/HSB/contrast helpers used by ArtworkColorExtractor,
//  ThemeStore, SemanticPaletteFactory, and BKColorEngine.
//

import AppKit

enum ColorMath {
    static func fnv1a(_ data: Data) -> UInt64 {
        // FNV-1a 64-bit. http://www.isthe.com/chongo/tech/comp/fnv/
        var hash: UInt64 = 14_695_981_039_346_656_037
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(hi, Swift.max(lo, v))
    }

    static func normalizedHue(_ value: CGFloat) -> CGFloat {
        var h = value.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return h
    }

    static func circularHueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(normalizedHue(a) - normalizedHue(b))
        return Swift.min(d, 1 - d)
    }

    /// Convert NSColor (deviceRGB) to HSL components (h in [0,1)).
    static func hsl(of color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let l = (maxV + minV) * 0.5
        let delta = maxV - minV
        if delta < 0.000_001 { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxV - minV) : delta / (maxV + minV)
        var h: CGFloat
        if maxV == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = ((b - r) / delta) + 2
        } else {
            h = ((r - g) / delta) + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    /// HSL → NSColor (deviceRGB).
    static func color(h: CGFloat, s: CGFloat, l: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        switch hPrime {
        case 0..<1: r = c; g = x
        case 1..<2: r = x; g = c
        case 2..<3: g = c; b = x
        case 3..<4: g = x; b = c
        case 4..<5: r = x; b = c
        default:    r = c; b = x
        }
        let m = l - c * 0.5
        return NSColor(
            deviceRed: clamp(r + m, 0, 1),
            green: clamp(g + m, 0, 1),
            blue: clamp(b + m, 0, 1),
            alpha: alpha
        )
    }

    /// Returns the NSColor with its HSL lightness clamped to [lo, hi]; hue and saturation preserved.
    static func clampLightness(_ color: NSColor, lo: CGFloat, hi: CGFloat) -> NSColor {
        let comp = hsl(of: color)
        let target = clamp(comp.l, lo, hi)
        if abs(target - comp.l) < 0.001 { return color }
        return self.color(h: comp.h, s: comp.s, l: target)
    }

    /// Returns the NSColor with HSL saturation clamped; hue and lightness preserved.
    static func clampSaturation(_ color: NSColor, lo: CGFloat, hi: CGFloat) -> NSColor {
        let comp = hsl(of: color)
        let target = clamp(comp.s, lo, hi)
        if abs(target - comp.s) < 0.001 { return color }
        return self.color(h: comp.h, s: target, l: comp.l)
    }

    /// Reinhard-style soft shoulder above `ceiling`. Returns identity below
    /// the ceiling; above, compresses asymptotically toward `ceiling + softness`
    /// so input values can never overshoot by more than `softness`.
    /// Use when a hard clamp would create visible jumps at the boundary.
    static func softShoulder(
        _ value: CGFloat,
        ceiling: CGFloat,
        softness: CGFloat
    ) -> CGFloat {
        if value <= ceiling || softness <= 0 { return value }
        let excess = value - ceiling
        return ceiling + softness * (excess / (excess + softness))
    }

    static func relativeLuminance(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.redComponent)
             + 0.7152 * lin(rgb.greenComponent)
             + 0.0722 * lin(rgb.blueComponent)
    }
}

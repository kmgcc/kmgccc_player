//
//  OKColor.swift
//  myPlayer2
//
//  Public OKLab/OKLCH colour math layer. Conversions, clamping, hue
//  normalisation, chroma soft-shoulder, OKLab interpolation, and gamut-safe
//  sRGB output. Used by `LEDColorResolver` today and by the wider colour
//  system (Phase 2 onwards) as the OKLCH math primitives.
//
//  No callers should reach into perceptual colour math via ad-hoc HSL/RGB
//  computations; route through this layer instead.
//

import AppKit
import SwiftUI

nonisolated enum OKColor {

    struct OKLab: Equatable, Sendable {
        var l: CGFloat
        var a: CGFloat
        var b: CGFloat
    }

    struct OKLCH: Equatable, Sendable {
        var l: CGFloat
        var c: CGFloat
        var h: CGFloat // 0...1 normalized, NOT degrees
    }

    // MARK: - sRGB <-> linear sRGB

    static func linearToSRGB(_ x: CGFloat) -> CGFloat {
        if x <= 0.0031308 {
            return x * 12.92
        }
        return 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }

    static func sRGBToLinear(_ x: CGFloat) -> CGFloat {
        if x <= 0.04045 {
            return x / 12.92
        }
        return pow((x + 0.055) / 1.055, 2.4)
    }

    // MARK: - linear sRGB <-> OKLab (Björn Ottosson)

    static func linearSRGBToOKLab(r: CGFloat, g: CGFloat, b: CGFloat) -> OKLab {
        let l_ = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m_ = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s_ = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let l = cbrt(l_)
        let m = cbrt(m_)
        let s = cbrt(s_)

        return OKLab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    static func okLabToLinearSRGB(_ lab: OKLab) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let l = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b

        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s

        return (
            r: +4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            g: -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            b: -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }

    // MARK: - OKLab <-> OKLCH

    static func okLabToOKLCH(_ lab: OKLab) -> OKLCH {
        let c = sqrt(lab.a * lab.a + lab.b * lab.b)
        var h = atan2(lab.b, lab.a) / (2 * .pi)
        if h < 0 { h += 1 }
        return OKLCH(l: lab.l, c: c, h: h)
    }

    static func okLCHToOKLab(_ lch: OKLCH) -> OKLab {
        let a = lch.c * cos(lch.h * 2 * .pi)
        let b = lch.c * sin(lch.h * 2 * .pi)
        return OKLab(l: lch.l, a: a, b: b)
    }

    // MARK: - High-level: NSColor <-> OKLCH

    static func nsColorToOKLCH(_ color: NSColor) -> OKLCH? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        let r = sRGBToLinear(rgb.redComponent)
        let g = sRGBToLinear(rgb.greenComponent)
        let b = sRGBToLinear(rgb.blueComponent)
        let lab = linearSRGBToOKLab(r: r, g: g, b: b)
        return okLabToOKLCH(lab)
    }

    static func okLCHToNSColor(_ lch: OKLCH, alpha: CGFloat) -> NSColor {
        let l = clamp(lch.l, 0, 1)
        let h = normalizedHue(lch.h)
        let requestedC = max(0, lch.c)
        let c: CGFloat

        if isInSRGBGamut(l: l, c: requestedC, h: h) {
            c = requestedC
        } else {
            var lo: CGFloat = 0
            var hi = requestedC
            for _ in 0..<18 {
                let mid = (lo + hi) * 0.5
                if isInSRGBGamut(l: l, c: mid, h: h) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            c = lo
        }

        let (r, g, b) = sRGBComponents(l: l, c: c, h: h)
        func clamp01(_ x: CGFloat) -> CGFloat { max(0, min(1, x)) }
        return NSColor(deviceRed: clamp01(r), green: clamp01(g), blue: clamp01(b), alpha: alpha)
    }

    private static func isInSRGBGamut(l: CGFloat, c: CGFloat, h: CGFloat) -> Bool {
        let lab = OKLab(l: l, a: c * cos(h * 2 * .pi), b: c * sin(h * 2 * .pi))
        let rgb = okLabToLinearSRGB(lab)
        return rgb.r >= 0 && rgb.r <= 1
            && rgb.g >= 0 && rgb.g <= 1
            && rgb.b >= 0 && rgb.b <= 1
    }

    private static func sRGBComponents(l: CGFloat, c: CGFloat, h: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let lab = OKLab(l: l, a: c * cos(h * 2 * .pi), b: c * sin(h * 2 * .pi))
        let rgb = okLabToLinearSRGB(lab)
        return (
            r: linearToSRGB(rgb.r),
            g: linearToSRGB(rgb.g),
            b: linearToSRGB(rgb.b)
        )
    }

    // MARK: - Public primitives (Phase 1 math layer)

    /// Wraps a hue into the `[0, 1)` range.
    static func normalizedHue(_ value: CGFloat) -> CGFloat {
        var h = value.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return h
    }

    /// Returns the OKLCH triple with lightness clamped to `[lo, hi]`.
    /// Hue and chroma are preserved.
    static func clampLightness(_ lch: OKLCH, lo: CGFloat, hi: CGFloat) -> OKLCH {
        OKLCH(l: clamp(lch.l, lo, hi), c: lch.c, h: lch.h)
    }

    /// Returns the OKLCH triple with chroma clamped to `[lo, hi]`.
    /// Hue and lightness are preserved.
    static func clampChroma(_ lch: OKLCH, lo: CGFloat, hi: CGFloat) -> OKLCH {
        OKLCH(l: lch.l, c: clamp(lch.c, lo, hi), h: lch.h)
    }

    /// Reinhard-style soft shoulder on chroma above `ceiling`. Mirrors
    /// `ColorMath.softShoulder` but in OKLCH space so the perceptual
    /// asymptote is consistent regardless of hue.
    static func chromaSoftShoulder(
        _ lch: OKLCH,
        ceiling: CGFloat,
        softness: CGFloat
    ) -> OKLCH {
        if lch.c <= ceiling || softness <= 0 { return lch }
        let excess = lch.c - ceiling
        let shouldered = ceiling + softness * (excess / (excess + softness))
        return OKLCH(l: lch.l, c: shouldered, h: lch.h)
    }

    /// Rotates the hue by `delta` (in normalised 0...1 units) and re-wraps
    /// the result into `[0, 1)`.
    static func rotateHue(_ lch: OKLCH, by delta: CGFloat) -> OKLCH {
        OKLCH(l: lch.l, c: lch.c, h: normalizedHue(lch.h + delta))
    }

    /// Linear interpolation between two OKLCH triples performed in OKLab
    /// (preserves perceptual straightness across the hue circle, unlike a
    /// naive L/C/H lerp which can ring around the colour wheel).
    static func oklabLerp(_ a: OKLCH, _ b: OKLCH, t: CGFloat) -> OKLCH {
        let la = okLCHToOKLab(a)
        let lb = okLCHToOKLab(b)
        let oneMinusT = 1 - t
        let lerped = OKLab(
            l: la.l * oneMinusT + lb.l * t,
            a: la.a * oneMinusT + lb.a * t,
            b: la.b * oneMinusT + lb.b * t
        )
        return okLabToOKLCH(lerped)
    }

    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(hi, Swift.max(lo, value))
    }
}

// MARK: - Phase 6 perceptual tone ladder

/// Shared OKLCH tone ladder for colour roles that need perceptual distance
/// and painterly hue/chroma coupling. It intentionally does not know about
/// views, skins, or AMLL. Callers provide a semantic seed colour and a role;
/// the ladder returns an opaque OKLCH tone.
nonisolated enum PerceptualToneLadder {
    enum LyricsRole: CaseIterable {
        case mainActive
        case subActive
        case mainInactive
        case lineTimingMainInactive
        case subInactive
        case lineTimingSubInactive
    }

    static func ledTone(
        base: OKColor.OKLCH,
        level: Int,
        maxLevel: Int,
        scheme: ColorScheme,
        isNearMonochrome: Bool,
        isStroke: Bool = false
    ) -> OKColor.OKLCH {
        let T = ColorSystemTokens.ToneLadder.self
        let safeMax = max(1, maxLevel)
        let rawT = ColorMath.clamp(CGFloat(min(max(level, 0), safeMax)) / CGFloat(safeMax), 0, 1)
        let t = pow(rawT, 0.88)
        let isDark = scheme == .dark
        let lowL = isDark ? T.ledDarkMinL : T.ledLightMinL
        let peakL = isDark ? T.ledDarkPeakL : T.ledLightPeakL

        var l = lowL + (peakL - lowL) * t
        let mid = sin(.pi * t)
        let chromaScale = T.ledLowChromaScale * (1 - t)
            + T.ledPeakChromaScale * t
            + T.ledMidChromaBoost * mid * 0.18
        var c = base.c * chromaScale
        if isNearMonochrome {
            c = min(c, T.ledNearMonoChromaCap)
        } else {
            c = max(c, min(T.ledColorfulMinimumChroma, hueChromaCap(base.h, role: .led, scheme: scheme)))
            c = min(c, hueChromaCap(base.h, role: .led, scheme: scheme))
        }

        let shadowAmount = 1 - t
        let highlightAmount = max(0, t - 0.70) / 0.30
        var h = shiftedHue(
            base.h,
            shadowAmount: shadowAmount,
            highlightAmount: highlightAmount,
            intensity: .led
        )

        if isStroke {
            l -= isDark ? T.ledStrokeLightnessTrimDark : T.ledStrokeLightnessTrimLight
            c *= T.ledStrokeChromaScale
            h = shiftedHue(h, shadowAmount: 0.25, highlightAmount: 0, intensity: .subtle)
        }
        return OKColor.OKLCH(l: l, c: c, h: OKColor.normalizedHue(h))
    }

    static func artisticLyricsTone(
        base: OKColor.OKLCH,
        role: LyricsRole,
        isUltraDark: Bool,
        isNearMonochrome: Bool
    ) -> OKColor.OKLCH {
        let T = ColorSystemTokens.ToneLadder.self
        let targetL: CGFloat
        let chromaScale: CGFloat
        let shadowAmount: CGFloat
        let highlightAmount: CGFloat

        switch role {
        case .mainActive:
            targetL = T.lyricsMainActiveL - (isUltraDark ? T.lyricsUltraDarkActiveTrim : 0)
            chromaScale = T.lyricsMainActiveChromaScale
            shadowAmount = 0
            highlightAmount = 0.75
        case .subActive:
            targetL = T.lyricsSubActiveL - (isUltraDark ? T.lyricsUltraDarkSubActiveTrim : 0)
            chromaScale = T.lyricsSubActiveChromaScale
            shadowAmount = 0.10
            highlightAmount = 0.35
        case .mainInactive:
            targetL = T.lyricsMainInactiveL - (isUltraDark ? T.lyricsUltraDarkInactiveTrim : 0)
            chromaScale = T.lyricsMainInactiveChromaScale
            shadowAmount = 0.62
            highlightAmount = 0
        case .lineTimingMainInactive:
            targetL = T.lyricsLineTimingMainInactiveL - (isUltraDark ? T.lyricsUltraDarkInactiveTrim : 0)
            chromaScale = T.lyricsLineTimingMainInactiveChromaScale
            shadowAmount = 0.75
            highlightAmount = 0
        case .subInactive:
            targetL = T.lyricsSubInactiveL - (isUltraDark ? T.lyricsUltraDarkInactiveTrim : 0)
            chromaScale = T.lyricsSubInactiveChromaScale
            shadowAmount = 0.82
            highlightAmount = 0
        case .lineTimingSubInactive:
            targetL = T.lyricsLineTimingSubInactiveL - (isUltraDark ? T.lyricsUltraDarkInactiveTrim : 0)
            chromaScale = T.lyricsLineTimingSubInactiveChromaScale
            shadowAmount = 0.92
            highlightAmount = 0
        }

        var c: CGFloat
        if isNearMonochrome {
            c = min(base.c * chromaScale, T.nearMonoChromaCeiling)
        } else {
            let cap = hueChromaCap(base.h, role: .lyrics(role), scheme: .dark)
            let floor = min(T.lyricsColorfulMinimumChroma, cap * 0.55)
            c = ColorMath.clamp(base.c * chromaScale, floor, cap)
            if targetL > 0.82 {
                c = OKColor.chromaSoftShoulder(
                    OKColor.OKLCH(l: targetL, c: c, h: base.h),
                    ceiling: cap * 0.74,
                    softness: T.brightToneChromaShoulder
                ).c
            } else if targetL < 0.46 {
                c = OKColor.chromaSoftShoulder(
                    OKColor.OKLCH(l: targetL, c: c, h: base.h),
                    ceiling: cap * 0.62,
                    softness: T.shadowToneChromaShoulder
                ).c
            }
        }

        let h = shiftedHue(
            base.h,
            shadowAmount: shadowAmount,
            highlightAmount: highlightAmount,
            intensity: .lyrics
        )
        return OKColor.OKLCH(l: targetL, c: c, h: OKColor.normalizedHue(h))
    }

    private enum HueIntensity {
        case subtle
        case led
        case lyrics
    }

    private enum ToneRole {
        case led
        case lyrics(LyricsRole)
    }

    private static func shiftedHue(
        _ h: CGFloat,
        shadowAmount: CGFloat,
        highlightAmount: CGFloat,
        intensity: HueIntensity
    ) -> CGFloat {
        let scale: CGFloat
        switch intensity {
        case .subtle: scale = 0.55
        case .led: scale = 0.85
        case .lyrics: scale = 1.00
        }
        let shadow = familyShadowDrift(h) * shadowAmount * scale
        let highlight = familyHighlightDrift(h) * highlightAmount * scale
        return OKColor.normalizedHue(h + shadow + highlight)
    }

    private static func familyShadowDrift(_ h: CGFloat) -> CGFloat {
        switch h {
        case 0.00..<0.06, 0.94..<1.00: return 0.008   // red deepens toward ruby
        case 0.06..<0.20:              return -0.014  // yellow/orange shadows warm to amber
        case 0.20..<0.34:              return -0.010  // chartreuse avoids fluorescent green
        case 0.34..<0.48:              return -0.006  // green shadows olive down
        case 0.48..<0.62:              return 0.008   // cyan shadows toward blue
        case 0.62..<0.76:              return 0.014   // blue shadows toward indigo
        case 0.76..<0.92:              return -0.010  // violet shadows stay wine, not electric
        default:                       return 0.006
        }
    }

    private static func familyHighlightDrift(_ h: CGFloat) -> CGFloat {
        switch h {
        case 0.00..<0.06, 0.94..<1.00: return -0.004
        case 0.06..<0.20:              return 0.004
        case 0.20..<0.34:              return -0.004
        case 0.34..<0.48:              return -0.003
        case 0.48..<0.62:              return -0.004
        case 0.62..<0.76:              return -0.006  // blue highlights avoid over-cold ice
        case 0.76..<0.92:              return 0.004
        default:                       return 0
        }
    }

    private static func hueChromaCap(
        _ h: CGFloat,
        role: ToneRole,
        scheme: ColorScheme
    ) -> CGFloat {
        let baseCap: CGFloat
        switch h {
        case 0.06..<0.20: baseCap = 0.090  // yellow/orange gets dirty quickly
        case 0.20..<0.34: baseCap = 0.082  // chartreuse/green fluorescent risk
        case 0.34..<0.48: baseCap = 0.095
        case 0.48..<0.62: baseCap = 0.105
        case 0.62..<0.76: baseCap = 0.118  // blue needs more C to feel alive
        case 0.76..<0.92: baseCap = 0.104
        default:          baseCap = 0.108
        }

        switch role {
        case .led:
            return scheme == .dark ? baseCap * 1.12 : baseCap * 0.95
        case .lyrics(let lyricsRole):
            switch lyricsRole {
            case .mainActive:
                return baseCap * 0.82
            case .subActive:
                return baseCap * 0.68
            case .mainInactive:
                return baseCap * 0.58
            case .lineTimingMainInactive:
                return baseCap * 0.50
            case .subInactive:
                return baseCap * 0.44
            case .lineTimingSubInactive:
                return baseCap * 0.38
            }
        }
    }
}

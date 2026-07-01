//
//  AccentColorPolicy.swift
//  myPlayer2
//
//  kmgccc_player - Accent color decision policy.
//

import AppKit
import SwiftUI

nonisolated enum AccentColorPolicy {
    enum Implementation: String, Sendable {
        case legacy
        case candidate
    }

    static let productionImplementation: Implementation = .legacy

    static func productionOptimizedAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        optimizedAccent(
            implementation: productionImplementation,
            for: scheme,
            analysis: analysis
        )
    }

    static func legacyOptimizedAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        optimizedAccent(implementation: .legacy, for: scheme, analysis: analysis)
    }

    static func candidateOptimizedAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        optimizedAccent(implementation: .candidate, for: scheme, analysis: analysis)
    }

    static func optimizedAccent(
        implementation: Implementation,
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        switch implementation {
        case .legacy:
            legacyOptimizedAccentImpl(for: scheme, analysis: analysis)
        case .candidate:
            candidateOptimizedAccentImpl(for: scheme, analysis: analysis)
        }
    }

    static func productionMiniPlayerControlColor(
        base: NSColor,
        scheme: ColorScheme
    ) -> NSColor {
        miniPlayerControlColor(
            implementation: productionImplementation,
            base: base,
            scheme: scheme
        )
    }

    static func legacyMiniPlayerControlColor(
        base: NSColor,
        scheme: ColorScheme
    ) -> NSColor {
        miniPlayerControlColor(implementation: .legacy, base: base, scheme: scheme)
    }

    static func candidateMiniPlayerControlColor(
        base: NSColor,
        scheme: ColorScheme
    ) -> NSColor {
        miniPlayerControlColor(implementation: .candidate, base: base, scheme: scheme)
    }

    static func miniPlayerControlColor(
        implementation: Implementation,
        base: NSColor,
        scheme: ColorScheme
    ) -> NSColor {
        switch implementation {
        case .legacy:
            scheme == .dark
                ? legacyEnforceMinimumHslLightness(base, minimumLightness: 0.70)
                : legacyEnforceMaximumHslLightness(base, maximumLightness: 0.45)
        case .candidate:
            candidateMiniPlayerControlColorImpl(base: base, scheme: scheme)
        }
    }

    // MARK: - OKLCH candidate

    private static func candidateOptimizedAccentImpl(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            return candidateNearMonochromeAccent(for: scheme, analysis: analysis)
        }

        let raw = analysis.primaryHueSourceColor ?? analysis.dominantColor
        guard var source = OKColor.nsColorToOKLCH(raw) else {
            return candidateNearMonochromeAccent(for: scheme, analysis: analysis)
        }

        if source.c < 0.010 && !analysis.hasTrustedHueCandidate {
            return candidateNearMonochromeAccent(for: scheme, analysis: analysis)
        }

        source = applyWarmHueGuard(source, analysis: analysis)
        let h = source.h
        let lowColor = usesLowColorAccentRestraint(analysis: analysis, source: source)
        let target: OKColor.OKLCH
        if scheme == .dark {
            let minL = lowColor
                ? lowColorDarkLightnessFloor(for: h)
                : darkAccentLightnessFloor(for: h, sourceChroma: source.c)
            let maxL = lowColor ? 0.805 : darkAccentLightnessCeiling(for: h)
            let floorC = lowColor ? 0.020 : darkAccentChromaFloor(for: h, sourceChroma: source.c)
            let capC = lowColor ? 0.064 : darkAccentChromaCap(
                for: h,
                source: source,
                analysis: analysis
            )
            let baseC = max(source.c * 1.08, floorC)
            let c = min(baseC, capC)
            target = OKColor.OKLCH(
                l: ColorMath.clamp(max(source.l, minL), minL, maxL),
                c: lowColorChromaCapped(c, scheme: scheme, analysis: analysis, source: source),
                h: h
            )
        } else {
            let targetL = lightAccentTargetLightness(source: source, lowColor: lowColor, analysis: analysis)
            let cap = lowColor ? 0.058 : lightAccentChromaCap(for: h)
            let chromaLift: CGFloat = source.c >= 0.080 ? 1.10 : 0.98
            let raised = max(source.c * chromaLift, lowColor ? 0.018 : lightAccentChromaFloor(for: h))
            let shouldered = chromaSoftShoulder(
                raised,
                ceiling: cap,
                softness: 0.030
            )
            target = OKColor.OKLCH(
                l: targetL,
                c: lowColorChromaCapped(shouldered, scheme: scheme, analysis: analysis, source: source),
                h: h
            )
        }

        return OKColor.okLCHToNSColor(target, alpha: 1.0)
    }

    private static func candidateNearMonochromeAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        let averageL = OKColor.nsColorToOKLCH(analysis.averageColor)?.l
            ?? CGFloat(analysis.avgHslLightness)
        let l: CGFloat
        if scheme == .dark {
            let toneLift = ColorMath.clamp((0.36 - averageL) / 0.28, 0, 1)
            l = ColorMath.clamp(0.760 + toneLift * 0.035, 0.760, 0.795)
        } else {
            let toneDrop = ColorMath.clamp((averageL - 0.68) / 0.24, 0, 1)
            l = ColorMath.clamp(0.510 - toneDrop * 0.105, 0.405, 0.510)
        }
        return OKColor.okLCHToNSColor(OKColor.OKLCH(l: l, c: 0, h: 0), alpha: 1.0)
    }

    private static func applyWarmHueGuard(
        _ source: OKColor.OKLCH,
        analysis: ArtworkColorAnalysis
    ) -> OKColor.OKLCH {
        guard let average = OKColor.nsColorToOKLCH(analysis.averageColor),
              average.c >= 0.012,
              analysis.dominantHueConfidence >= ColorSystemTokens.Accent.warmGuardHueConfidenceMin else {
            return source
        }

        let isWarmAverage = average.h >= 0.13 && average.h <= 0.31
        let sourceIsWarmEdge = source.h >= 0.03 && source.h <= 0.13
        let sourceIsWeakWarmDrift = source.c <= 0.070
            && sourceIsWarmEdge
            && ColorMath.circularHueDistance(source.h, average.h) > 0.090
        guard isWarmAverage, sourceIsWeakWarmDrift else { return source }
        return OKColor.OKLCH(l: source.l, c: source.c, h: average.h)
    }

    private static func lowColorDarkLightnessFloor(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.30..<0.44: return 0.780
        case 0.44..<0.72: return 0.800
        default:          return 0.740
        }
    }

    private static func darkAccentLightnessFloor(for h: CGFloat, sourceChroma: CGFloat) -> CGFloat {
        if sourceChroma >= 0.110 {
            switch h {
            case 0.10..<0.18: return 0.760
            case 0.34..<0.44: return 0.825
            case 0.18..<0.44: return 0.860
            case 0.44..<0.67: return 0.810
            case 0.67..<0.72: return 0.780
            case 0.72..<0.88: return 0.720
            default:          return 0.720
            }
        }
        switch h {
        case 0.10..<0.20: return 0.810
        case 0.20..<0.44: return 0.845
        case 0.44..<0.72: return 0.780
        case 0.72..<0.86: return 0.735
        default:          return 0.790
        }
    }

    private static func darkAccentLightnessCeiling(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.10..<0.44: return 0.930
        case 0.44..<0.72: return 0.875
        case 0.72..<0.86: return 0.860
        default:          return 0.875
        }
    }

    private static func darkAccentChromaFloor(for h: CGFloat, sourceChroma: CGFloat) -> CGFloat {
        if sourceChroma < 0.070 {
            switch h {
            case 0.10..<0.44: return 0.036
            case 0.44..<0.72: return 0.042
            case 0.72..<0.86: return 0.044
            default:          return 0.040
            }
        }
        switch h {
        case 0.10..<0.20: return 0.088
        case 0.20..<0.44: return 0.092
        case 0.44..<0.72: return 0.086
        case 0.72..<0.86: return 0.086
        default:          return 0.084
        }
    }

    private static func darkAccentChromaCap(
        for h: CGFloat,
        source: OKColor.OKLCH,
        analysis: ArtworkColorAnalysis
    ) -> CGFloat {
        if analysis.isUltraDark {
            switch h {
            case 0.00..<0.13, 0.88..<1.00: return 0.112
            case 0.13..<0.32:              return 0.126
            default: break
            }
        }
        if source.c >= 0.090 {
            switch h {
            case 0.00..<0.03, 0.88..<1.00: return 0.098
            case 0.03..<0.10:              return 0.112
            case 0.10..<0.18:              return 0.128
            default: break
            }
        }
        if source.c >= 0.160 {
            switch h {
            case 0.34..<0.44: return 0.098
            case 0.30..<0.50: return 0.112
            default: break
            }
        }
        if source.l >= 0.650 {
            switch h {
            case 0.50..<0.72: return 0.096
            case 0.30..<0.50: return 0.120
            case 0.00..<0.10, 0.86..<1.00: return 0.110
            default: break
            }
        }
        switch h {
        case 0.10..<0.20: return 0.180
        case 0.18..<0.32: return 0.190
        case 0.32..<0.50: return 0.170
        case 0.50..<0.72: return 0.165
        case 0.72..<0.88: return 0.155
        default:          return 0.165
        }
    }

    private static func lightAccentTargetLightness(
        source: OKColor.OKLCH,
        lowColor: Bool,
        analysis: ArtworkColorAnalysis
    ) -> CGFloat {
        let h = source.h
        if lowColor {
            if analysis.isMonochrome || source.c < 0.045 {
                return ColorMath.clamp(source.l * 0.82, 0.430, 0.560)
            }
            let floor: CGFloat = {
                switch h {
                case 0.18..<0.50: return 0.500
                case 0.50..<0.72: return 0.460
                default: return 0.430
                }
            }()
            let ceiling: CGFloat = {
                switch h {
                case 0.18..<0.50: return 0.660
                case 0.50..<0.72: return 0.620
                default: return 0.560
                }
            }()
            return ColorMath.clamp(source.l * 0.88, floor, ceiling)
        }
        let scale: CGFloat = {
            switch h {
            case 0.03..<0.10: return 0.78
            case 0.10..<0.18: return 0.74
            case 0.18..<0.29: return 0.80
            case 0.29..<0.34: return source.c >= 0.100 ? 1.00 : 0.84
            case 0.34..<0.50: return 0.82
            case 0.50..<0.72: return 0.78
            case 0.72..<0.88: return 0.70
            default:          return 0.74
            }
        }()
        return ColorMath.clamp(
            source.l * scale,
            lightAccentLightnessFloor(for: h, sourceChroma: source.c),
            lightAccentLightnessCeiling(for: h)
        )
    }

    private static func lightAccentLightnessFloor(for h: CGFloat, sourceChroma: CGFloat) -> CGFloat {
        switch h {
        case 0.10..<0.18: return 0.390
        case 0.18..<0.29: return 0.500
        case 0.29..<0.34: return sourceChroma >= 0.100 ? 0.760 : 0.470
        case 0.34..<0.50: return 0.500
        case 0.50..<0.72: return 0.440
        case 0.72..<0.88: return 0.380
        default:          return 0.390
        }
    }

    private static func lightAccentLightnessCeiling(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.10..<0.18: return 0.610
        case 0.18..<0.29: return 0.700
        case 0.29..<0.34: return 0.870
        case 0.30..<0.50: return 0.650
        case 0.50..<0.72: return 0.600
        case 0.72..<0.88: return 0.600
        default:          return 0.590
        }
    }

    private static func lightAccentChromaFloor(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.10..<0.20: return 0.052
        case 0.20..<0.44: return 0.048
        case 0.44..<0.72: return 0.052
        case 0.72..<0.86: return 0.120
        case 0.86..<1.00, 0.00..<0.03: return 0.120
        case 0.03..<0.10: return 0.096
        default:          return 0.056
        }
    }

    private static func lightAccentChromaCap(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.83..<1.00, 0.00..<0.03: return 0.190
        case 0.72..<0.83:              return 0.175
        case 0.30..<0.50:              return 0.145
        case 0.50..<0.65:              return 0.135
        case 0.65..<0.72:              return 0.115
        case 0.03..<0.10:              return 0.105
        case 0.10..<0.20:              return 0.135
        case 0.20..<0.30:              return 0.145
        default:                       return 0.140
        }
    }

    private static func lowColorChromaCapped(
        _ c: CGFloat,
        scheme: ColorScheme,
        analysis: ArtworkColorAnalysis,
        source: OKColor.OKLCH
    ) -> CGFloat {
        let cap: CGFloat?
        if analysis.isMonochrome || source.c < 0.010 {
            if scheme == .dark,
               analysis.hasTrustedHueCandidate,
               analysis.colorfulness < 0.055,
               source.h >= 0.03,
               source.h < 0.16 {
                cap = 0.014
            } else {
                cap = scheme == .dark ? 0.022 : 0.016
            }
        } else if scheme == .dark,
                  analysis.colorfulness < 0.055,
                  source.h >= 0.03,
                  source.h < 0.16 {
            cap = 0.018
        } else if analysis.colorfulness < ColorSystemTokens.Accent.nearMonoColorfulnessThreshold
                    || source.c < 0.040 {
            cap = scheme == .dark ? 0.065 : 0.052
        } else if source.c < 0.080,
                  analysis.dominantHueConfidence
                    < ColorSystemTokens.Accent.lowConfidenceHueConfidenceThreshold {
            cap = scheme == .dark ? 0.105 : 0.086
        } else {
            cap = nil
        }
        guard let cap else { return c }
        return min(c, cap)
    }

    private static func usesLowColorAccentRestraint(
        analysis: ArtworkColorAnalysis,
        source: OKColor.OKLCH
    ) -> Bool {
        analysis.isMonochrome
            || source.c < 0.045
            || analysis.colorfulness < ColorSystemTokens.Accent.nearMonoColorfulnessThreshold
    }

    private static func candidateMiniPlayerControlColorImpl(
        base: NSColor,
        scheme: ColorScheme
    ) -> NSColor {
        guard let lch = OKColor.nsColorToOKLCH(base) else { return base }
        if lch.c < 0.006 {
            let l = scheme == .dark ? max(lch.l, 0.805) : min(lch.l, 0.545)
            return OKColor.okLCHToNSColor(OKColor.OKLCH(l: l, c: 0, h: 0), alpha: 1.0)
        }

        let target: OKColor.OKLCH
        if scheme == .dark {
            let floorL: CGFloat = {
                if lch.c >= 0.100 {
                    switch lch.h {
                    case 0.18..<0.44: return 0.865
                    case 0.44..<0.88: return 0.710
                    default:          return 0.710
                    }
                }
                return lch.c >= 0.050 ? 0.745 : 0.765
            }()
            target = OKColor.OKLCH(
                l: ColorMath.clamp(max(lch.l, floorL), floorL, 0.910),
                c: min(lch.c, miniPlayerDarkChromaCap(for: lch.h)),
                h: lch.h
            )
        } else {
            let ceilingL = miniPlayerLightLightnessCeiling(for: lch.h, chroma: lch.c)
            target = OKColor.OKLCH(
                l: ColorMath.clamp(min(lch.l, ceilingL), 0.340, ceilingL),
                c: min(lch.c, miniPlayerLightChromaCap(for: lch.h)),
                h: lch.h
            )
        }
        return OKColor.okLCHToNSColor(target, alpha: 1.0)
    }

    private static func miniPlayerDarkChromaCap(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.18..<0.44: return 0.155
        case 0.44..<0.72: return 0.140
        case 0.72..<0.88: return 0.140
        default:          return 0.150
        }
    }

    private static func miniPlayerLightLightnessCeiling(
        for h: CGFloat,
        chroma: CGFloat
    ) -> CGFloat {
        switch h {
        case 0.18..<0.34 where chroma >= 0.095: return 0.790
        case 0.34..<0.50 where chroma >= 0.120: return 0.660
        case 0.10..<0.18 where chroma >= 0.120: return 0.620
        default: return 0.545
        }
    }

    private static func miniPlayerLightChromaCap(for h: CGFloat) -> CGFloat {
        switch h {
        case 0.18..<0.34: return 0.170
        case 0.34..<0.50: return 0.140
        case 0.50..<0.72: return 0.150
        case 0.72..<0.88: return 0.165
        case 0.88..<1.00, 0.00..<0.10: return 0.175
        default:          return 0.130
        }
    }

    private static func chromaSoftShoulder(
        _ value: CGFloat,
        ceiling: CGFloat,
        softness: CGFloat
    ) -> CGFloat {
        if value <= ceiling || softness <= 0 { return value }
        let excess = value - ceiling
        return ceiling + softness * (excess / (excess + softness))
    }

    // MARK: - Legacy compare

    private static func legacyOptimizedAccentImpl(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        if analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            return legacyNearMonochromeAccent(for: scheme, analysis: analysis)
        }

        let raw = analysis.primaryHueSourceColor ?? analysis.dominantColor
        let comp = ColorMath.hsl(of: raw)
        var h = comp.h, s = comp.s, l = comp.l

        let avg = analysis.avgHue
        let isWarmAvg = avg >= ColorSystemTokens.Accent.warmGuardHueLo
            && avg <= ColorSystemTokens.Accent.warmGuardHueHi
        let isWarmConfident = analysis.dominantHueConfidence
            >= ColorSystemTokens.Accent.warmGuardHueConfidenceMin
        if isWarmAvg && isWarmConfident {
            let inWarmBand = h >= ColorSystemTokens.Accent.warmBandHueLo
                && h <= ColorSystemTokens.Accent.warmBandHueHi
            let drifted = ColorMath.circularHueDistance(h, avg)
                > ColorSystemTokens.Accent.warmGuardDriftThreshold
            if !inWarmBand || drifted {
                h = avg
            }
        }

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

        if analysis.isMonochrome {
            s = min(s, scheme == .dark
                ? ColorSystemTokens.Accent.strictMonoSatCapDark
                : ColorSystemTokens.Accent.strictMonoSatCapLight)
        } else if analysis.colorfulness < ColorSystemTokens.Accent.nearMonoColorfulnessThreshold
                    || analysis.avgSaturation < ColorSystemTokens.Accent.nearMonoAvgSaturationThreshold {
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

    private static func legacyNearMonochromeAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
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

        return ColorMath.color(h: 0, s: 0, l: lightness)
    }

    // Byte-faithful port of the former MiniPlayerView inline HSL clamp. It must
    // reproduce the exact prior production output, including the deviceRGB read,
    // the `s = delta / (1 - |2L-1|)` form, and the `calibratedRed` write — the
    // result is consumed by `ColorRenderingAdapter` via `usingColorSpace(.deviceRGB)`,
    // so the calibrated→device transform is part of the legacy pixel value.
    private static func legacyEnforceMinimumHslLightness(
        _ color: NSColor,
        minimumLightness: CGFloat
    ) -> NSColor {
        guard let hsl = legacyMiniHslComponents(from: color) else { return color }
        let targetL = max(hsl.l, minimumLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        return legacyMiniRGBColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func legacyEnforceMaximumHslLightness(
        _ color: NSColor,
        maximumLightness: CGFloat
    ) -> NSColor {
        guard let hsl = legacyMiniHslComponents(from: color) else { return color }
        let targetL = min(hsl.l, maximumLightness)
        if targetL >= hsl.l - 0.000_001 { return color }
        return legacyMiniRGBColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func legacyMiniHslComponents(
        from color: NSColor
    ) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        let r = legacyMiniClamp01(rgb.redComponent)
        let g = legacyMiniClamp01(rgb.greenComponent)
        let b = legacyMiniClamp01(rgb.blueComponent)
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        let l = (maxV + minV) * 0.5
        var h: CGFloat = 0
        if delta > 0.000_001 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        var s: CGFloat = 0
        if delta > 0.000_001 {
            s = delta / (1 - abs(2 * l - 1))
        }
        return (h: h, s: s, l: l)
    }

    private static func legacyMiniRGBColorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        var rp: CGFloat = 0
        var gp: CGFloat = 0
        var bp: CGFloat = 0
        switch hPrime {
        case 0..<1:
            rp = c; gp = x; bp = 0
        case 1..<2:
            rp = x; gp = c; bp = 0
        case 2..<3:
            rp = 0; gp = c; bp = x
        case 3..<4:
            rp = 0; gp = x; bp = c
        case 4..<5:
            rp = x; gp = 0; bp = c
        default:
            rp = c; gp = 0; bp = x
        }
        let m = l - c * 0.5
        return NSColor(
            calibratedRed: legacyMiniClamp01(rp + m),
            green: legacyMiniClamp01(gp + m),
            blue: legacyMiniClamp01(bp + m),
            alpha: 1.0
        )
    }

    private static func legacyMiniClamp01(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, 0), 1)
    }
}

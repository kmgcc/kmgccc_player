//
//  LEDColorResolver.swift
//  myPlayer2
//
//  LED-dedicated semantic colour resolver. Production colour decisions are made
//  in OKLCH / OKLab and rendered through ColorRenderingAdapter.
//

import AppKit
import SwiftUI

nonisolated enum LEDColorResolverImplementation: String, Sendable {
    case oklch
#if DEBUG
    case legacy
#endif
}

nonisolated enum LEDHueRisk: String, Sendable {
    case achromatic
    case red
    case amber
    case yellowGreen = "yellow-green"
    case green
    case cyan
    case blue
    case violet
    case magenta

    static func classify(_ lch: OKColor.OKLCH, trustsHue: Bool) -> LEDHueRisk {
        guard trustsHue, lch.c >= LEDPerceptualPolicy.visibleHueChromaFloor else {
            return .achromatic
        }
        switch OKColor.normalizedHue(lch.h) {
        case 0.00..<0.06, 0.94..<1.00:
            return .red
        case 0.06..<0.18:
            return .amber
        case 0.18..<0.30:
            return .yellowGreen
        case 0.30..<0.45:
            return .green
        case 0.45..<0.58:
            return .cyan
        case 0.58..<0.76:
            return .blue
        case 0.76..<0.92:
            return .violet
        default:
            return .magenta
        }
    }

    var isGreenRisk: Bool {
        self == .yellowGreen || self == .green || self == .cyan
    }

    func centerLightness(scheme: ColorScheme, isUltraDark: Bool) -> CGFloat {
        let dark: CGFloat
        let light: CGFloat
        switch self {
        case .achromatic:
            dark = 0.820
            light = 0.460
        case .amber:
            dark = 0.805
            light = 0.440
        case .yellowGreen:
            dark = 0.815
            light = 0.452
        case .green:
            dark = 0.825
            light = 0.462
        case .cyan:
            dark = 0.842
            light = 0.478
        case .blue, .violet:
            dark = 0.825
            light = 0.490
        case .red, .magenta:
            dark = 0.835
            light = 0.470
        }
        let base = scheme == .dark ? dark : light
        guard scheme == .dark, isUltraDark else { return base }
        return min(base, self == .achromatic ? 0.815 : 0.835)
    }

    func centerChromaCap(scheme: ColorScheme, isUltraDark: Bool) -> CGFloat {
        let dark: CGFloat
        let light: CGFloat
        switch self {
        case .achromatic:
            dark = 0.006
            light = 0.005
        case .amber:
            dark = 0.100
            light = 0.090
        case .yellowGreen:
            dark = 0.096
            light = 0.086
        case .green:
            dark = 0.100
            light = 0.094
        case .cyan:
            dark = 0.112
            light = 0.112
        case .blue:
            dark = 0.112
            light = 0.121
        case .violet:
            dark = 0.108
            light = 0.106
        case .red:
            dark = 0.108
            light = 0.112
        case .magenta:
            dark = 0.108
            light = 0.108
        }
        let cap = scheme == .dark ? dark : light
        return isUltraDark && self != .achromatic ? cap * 0.92 : cap
    }

    func edgeChromaScale(isNearMonochrome: Bool) -> CGFloat {
        if isNearMonochrome || self == .achromatic { return 0.72 }
        switch self {
        case .yellowGreen:
            return 0.78
        case .green, .cyan:
            return 0.82
        case .blue, .violet:
            return 0.76
        case .amber:
            return 0.84
        default:
            return 0.86
        }
    }

    var edgeHueShift: CGFloat {
        switch self {
        case .red:
            return 0.006
        case .amber:
            return -0.004
        case .yellowGreen:
            return -0.004
        case .green:
            return 0.006
        case .cyan:
            return 0.004
        case .blue:
            return -0.006
        case .violet:
            return -0.004
        case .magenta:
            return 0.004
        case .achromatic:
            return 0
        }
    }
}

nonisolated struct LEDSeed: Sendable {
    let lch: OKColor.OKLCH
    let trustsHue: Bool
    let reason: String
}

nonisolated struct LEDSemanticPalette: Sendable {
    let seed: LEDSeed
    let center: OKColor.OKLCH
    let edge: OKColor.OKLCH
    let statusBase: OKColor.OKLCH
    let hueRisk: LEDHueRisk
    let isNearMonochrome: Bool
    let isUltraDark: Bool
}

nonisolated enum LEDPerceptualPolicy {
    static let visibleHueChromaFloor: CGFloat = 0.018
    static let trustedHueChromaFloor: CGFloat = 0.045
    private static let stableWarmHue: CGFloat = 0.105
    private static let stableNeutralHue: CGFloat = 0.60

    static func makePalette(
        palette: SemanticPalette?,
        accentColor: NSColor,
        scheme: ColorScheme
    ) -> LEDSemanticPalette {
        let seed = makeSeed(palette: palette, accentColor: accentColor, scheme: scheme)
        let analysis = palette?.analysis
        let nearMono = isNearMonochrome(seed: seed, analysis: analysis)
        let ultraDark = analysis?.isUltraDark ?? false
        let center = centerTone(seed: seed, scheme: scheme, isNearMonochrome: nearMono, isUltraDark: ultraDark)
        let risk = LEDHueRisk.classify(center, trustsHue: seed.trustsHue && !nearMono)
        let edge = edgeTone(center: center, risk: risk, scheme: scheme, isNearMonochrome: nearMono)
        let status = statusBaseTone(
            center: center,
            palette: palette,
            scheme: scheme,
            isNearMonochrome: nearMono,
            isUltraDark: ultraDark
        )
        return LEDSemanticPalette(
            seed: seed,
            center: center,
            edge: edge,
            statusBase: status,
            hueRisk: risk,
            isNearMonochrome: nearMono,
            isUltraDark: ultraDark
        )
    }

    static func neutralLEDOKLCH(scheme: ColorScheme) -> OKColor.OKLCH {
        OKColor.OKLCH(
            l: scheme == .dark ? 0.820 : 0.460,
            c: scheme == .dark ? 0.006 : 0.005,
            h: stableNeutralHue
        )
    }

    private static func makeSeed(
        palette: SemanticPalette?,
        accentColor: NSColor,
        scheme: ColorScheme
    ) -> LEDSeed {
        guard let palette else {
            if let accent = OKColor.nsColorToOKLCH(accentColor), accent.c >= visibleHueChromaFloor {
                return LEDSeed(lch: accent, trustsHue: accent.c >= trustedHueChromaFloor, reason: "fallback-accent-oklch")
            }
            return LEDSeed(lch: neutralLEDOKLCH(scheme: scheme), trustsHue: false, reason: "fallback-neutral")
        }

        let analysis = palette.analysis
        if analysis.lacksTrustedHue {
            return LEDSeed(lch: neutralLEDOKLCH(scheme: scheme), trustsHue: false, reason: "analysis-lacks-trusted-hue")
        }

        if let source = analysis.primaryHueSourceColor,
           let sourceLCH = OKColor.nsColorToOKLCH(source),
           sourceLCH.c >= visibleHueChromaFloor {
            return LEDSeed(lch: sourceLCH, trustsHue: true, reason: "primary-hue-source-oklch")
        }

        if analysis.isEffectivelyMonochrome {
            return LEDSeed(lch: neutralLEDOKLCH(scheme: scheme), trustsHue: false, reason: "effectively-monochrome-neutral")
        }

        if let candidate = strongestOKLCHCandidate(in: [
            analysis.averageColor,
            analysis.dominantColor,
            analysis.bestTextSourceColor,
            palette.globalAccent,
            palette.coverGradientDominant,
            palette.artBackgroundSecondary,
        ] + analysis.topPalette.prefix(3) + analysis.salientHighlightPalette.prefix(2)) {
            let trustsHue = candidate.c >= trustedHueChromaFloor || analysis.hasTrustedHueCandidate
            if trustsHue || candidate.c >= visibleHueChromaFloor {
                return LEDSeed(
                    lch: candidate,
                    trustsHue: trustsHue,
                    reason: trustsHue ? "oklch-candidate-trusted" : "oklch-candidate-muted"
                )
            }
        }

        return LEDSeed(lch: neutralLEDOKLCH(scheme: scheme), trustsHue: false, reason: "no-visible-oklch-seed")
    }

    private static func strongestOKLCHCandidate(in colors: [NSColor]) -> OKColor.OKLCH? {
        colors
            .compactMap { OKColor.nsColorToOKLCH($0) }
            .max { lhs, rhs in
                if abs(lhs.c - rhs.c) > 0.0005 { return lhs.c < rhs.c }
                return lhs.l < rhs.l
            }
    }

    private static func isNearMonochrome(seed: LEDSeed, analysis: ArtworkColorAnalysis?) -> Bool {
        if !seed.trustsHue { return true }
        if let analysis, analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate {
            return seed.lch.c < trustedHueChromaFloor
        }
        return seed.lch.c < visibleHueChromaFloor
    }

    private static func centerTone(
        seed: LEDSeed,
        scheme: ColorScheme,
        isNearMonochrome: Bool,
        isUltraDark: Bool
    ) -> OKColor.OKLCH {
        if isNearMonochrome || !seed.trustsHue {
            let neutral = neutralLEDOKLCH(scheme: scheme)
            let c = min(neutral.c, max(0, seed.lch.c * 0.18))
            return OKColor.OKLCH(l: neutral.l, c: c, h: stableNeutralHue)
        }

        let risk = LEDHueRisk.classify(seed.lch, trustsHue: true)
        let lightness = risk.centerLightness(scheme: scheme, isUltraDark: isUltraDark)
        let cap = risk.centerChromaCap(scheme: scheme, isUltraDark: isUltraDark)
        let minC = min(scheme == .dark ? CGFloat(0.062) : CGFloat(0.054), cap)
        let scale = scheme == .dark ? CGFloat(0.82) : CGFloat(0.74)
        let requested = seed.lch.c < trustedHueChromaFloor
            ? minC
            : seed.lch.c * scale
        let chroma = ColorMath.clamp(requested, minC, cap)
        return OKColor.OKLCH(l: lightness, c: chroma, h: OKColor.normalizedHue(seed.lch.h))
    }

    private static func edgeTone(
        center: OKColor.OKLCH,
        risk: LEDHueRisk,
        scheme: ColorScheme,
        isNearMonochrome: Bool
    ) -> OKColor.OKLCH {
        let lightnessTrim: CGFloat = scheme == .dark ? 0.038 : 0.024
        let minLightness: CGFloat = scheme == .dark ? 0.540 : 0.280
        let c = isNearMonochrome
            ? min(center.c * risk.edgeChromaScale(isNearMonochrome: true), scheme == .dark ? 0.004 : 0.0035)
            : center.c * risk.edgeChromaScale(isNearMonochrome: false)
        return OKColor.OKLCH(
            l: max(minLightness, center.l - lightnessTrim),
            c: c,
            h: OKColor.normalizedHue(center.h + risk.edgeHueShift)
        )
    }

    private static func statusBaseTone(
        center: OKColor.OKLCH,
        palette: SemanticPalette?,
        scheme: ColorScheme,
        isNearMonochrome: Bool,
        isUltraDark: Bool
    ) -> OKColor.OKLCH {
        guard let palette, !isNearMonochrome else { return center }
        let candidates = [
            palette.coverGradientDominant,
            palette.artBackgroundSecondary,
            palette.globalAccent,
        ].compactMap { OKColor.nsColorToOKLCH($0) }

        for candidate in candidates where candidate.c >= visibleHueChromaFloor {
            if ColorMath.circularHueDistance(center.h, candidate.h) >= 0.030 {
                let seed = LEDSeed(lch: candidate, trustsHue: candidate.c >= visibleHueChromaFloor, reason: "status-companion-oklch")
                let companion = centerTone(
                    seed: seed,
                    scheme: scheme,
                    isNearMonochrome: false,
                    isUltraDark: isUltraDark
                )
                return OKColor.OKLCH(
                    l: companion.l,
                    c: min(companion.c, center.c * 0.90),
                    h: companion.h
                )
            }
        }
        return center
    }
}

struct LEDColorResolver {
    let palette: SemanticPalette?
    let accentColor: Color
    let colorScheme: ColorScheme
    let brightnessLevels: Int
    let implementation: LEDColorResolverImplementation
    let levelToneVariant: PerceptualToneLadder.LEDToneVariant
    let isEffectivelyMonochrome: Bool

    private var accentNS: NSColor {
        NSColor(accentColor)
    }

    private var semanticPalette: LEDSemanticPalette {
        LEDPerceptualPolicy.makePalette(
            palette: palette,
            accentColor: accentNS,
            scheme: colorScheme
        )
    }

    private var isNearMonochrome: Bool {
        semanticPalette.isNearMonochrome
    }

    init(
        accentColor: Color,
        colorScheme: ColorScheme,
        brightnessLevels: Int,
        palette: SemanticPalette? = nil,
        implementation: LEDColorResolverImplementation = .oklch,
        levelToneVariant: PerceptualToneLadder.LEDToneVariant = .retuned
    ) {
        self.accentColor = accentColor
        self.colorScheme = colorScheme
        self.brightnessLevels = max(2, brightnessLevels)
        self.palette = palette
        self.implementation = implementation
        self.levelToneVariant = levelToneVariant
        self.isEffectivelyMonochrome = palette?.analysis.isEffectivelyMonochrome ?? false
    }

    var oklchSemanticPalette: LEDSemanticPalette {
        semanticPalette
    }

    var centerColor: NSColor {
        switch implementation {
        case .oklch:
            return render(semanticPalette.center)
#if DEBUG
        case .legacy:
            return legacyCenterColor
#endif
        }
    }

    var edgeColor: NSColor {
        switch implementation {
        case .oklch:
            return render(semanticPalette.edge)
#if DEBUG
        case .legacy:
            return legacyEdgeColor
#endif
        }
    }

    // MARK: - Status Light

    func statusLightNSColor(level: Int) -> NSColor {
        switch implementation {
        case .oklch:
            return render(oklchColorForLevel(base: semanticPalette.statusBase, level: level))
#if DEBUG
        case .legacy:
            return legacyStatusLightNSColor(level: level)
#endif
        }
    }

    func statusLightStrokeNSColor(level: Int) -> NSColor {
        switch implementation {
        case .oklch:
            return render(oklchColorForLevel(base: semanticPalette.statusBase, level: level, isStroke: true))
#if DEBUG
        case .legacy:
            return legacyStatusLightStrokeNSColor(level: level)
#endif
        }
    }

    func statusLightColor(level: Int) -> Color {
        switch implementation {
        case .oklch:
            return renderSwiftUIColor(oklchColorForLevel(base: semanticPalette.statusBase, level: level))
                .opacity(opacityForLevel(level: level))
#if DEBUG
        case .legacy:
            return ColorRenderingAdapter.makeSwiftUIColor(legacyStatusLightNSColor(level: level))
                .opacity(opacityForLevel(level: level))
#endif
        }
    }

    func statusLightStrokeColor(level: Int) -> Color {
        switch implementation {
        case .oklch:
            return renderSwiftUIColor(oklchColorForLevel(base: semanticPalette.statusBase, level: level, isStroke: true))
                .opacity(min(0.50, opacityForLevel(level: level) * 0.55))
#if DEBUG
        case .legacy:
            return ColorRenderingAdapter.makeSwiftUIColor(legacyStatusLightStrokeNSColor(level: level))
                .opacity(min(0.50, opacityForLevel(level: level) * 0.55))
#endif
        }
    }

    // MARK: - Volume LED

    func volumeLEDNSColor(index: Int, count: Int, level: Int) -> NSColor {
        switch implementation {
        case .oklch:
            return render(oklchColorForLevel(base: baseLCHForIndex(index: index, count: count), level: level))
#if DEBUG
        case .legacy:
            return legacyVolumeLEDNSColor(index: index, count: count, level: level)
#endif
        }
    }

    func volumeLEDStrokeNSColor(index: Int, count: Int, level: Int) -> NSColor {
        switch implementation {
        case .oklch:
            return render(oklchColorForLevel(base: baseLCHForIndex(index: index, count: count), level: level, isStroke: true))
#if DEBUG
        case .legacy:
            return legacyVolumeLEDStrokeNSColor(index: index, count: count, level: level)
#endif
        }
    }

    func volumeLEDColor(index: Int, count: Int, level: Int) -> Color {
        switch implementation {
        case .oklch:
            return renderSwiftUIColor(oklchColorForLevel(base: baseLCHForIndex(index: index, count: count), level: level))
                .opacity(opacityForLevel(level: level))
#if DEBUG
        case .legacy:
            return ColorRenderingAdapter.makeSwiftUIColor(legacyVolumeLEDNSColor(index: index, count: count, level: level))
                .opacity(opacityForLevel(level: level))
#endif
        }
    }

    func volumeLEDStrokeColor(index: Int, count: Int, level: Int) -> Color {
        switch implementation {
        case .oklch:
            return renderSwiftUIColor(oklchColorForLevel(base: baseLCHForIndex(index: index, count: count), level: level, isStroke: true))
                .opacity(min(0.50, opacityForLevel(level: level) * 0.55))
#if DEBUG
        case .legacy:
            return ColorRenderingAdapter.makeSwiftUIColor(legacyVolumeLEDStrokeNSColor(index: index, count: count, level: level))
                .opacity(min(0.50, opacityForLevel(level: level) * 0.55))
#endif
        }
    }

    // MARK: - OKLCH production helpers

    private func baseLCHForIndex(index: Int, count: Int) -> OKColor.OKLCH {
        let led = semanticPalette
        guard count > 1 else { return led.center }
        let center = Double(count - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        return OKColor.oklabLerp(led.center, led.edge, t: CGFloat(distance))
    }

    private func oklchColorForLevel(
        base: OKColor.OKLCH,
        level: Int,
        isStroke: Bool = false
    ) -> OKColor.OKLCH {
        let maxLevel = max(1, brightnessLevels - 1)
        return PerceptualToneLadder.ledTone(
            base: base,
            level: level,
            maxLevel: maxLevel,
            scheme: colorScheme,
            isNearMonochrome: isNearMonochrome,
            isUltraDark: semanticPalette.isUltraDark,
            isStroke: isStroke,
            variant: levelToneVariant
        )
    }

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

    private func render(_ lch: OKColor.OKLCH) -> NSColor {
        ColorRenderingAdapter.makeNSColor(OKLCHColor(lch, alpha: 1), target: .displayP3)
    }

    private func renderSwiftUIColor(_ lch: OKColor.OKLCH) -> Color {
        ColorRenderingAdapter.makeSwiftUIColor(OKLCHColor(lch, alpha: 1), target: .displayP3)
    }
}

#if DEBUG
extension LEDColorResolver {
    // MARK: - Legacy parity reference

    private var legacyStableWarmHue: CGFloat { 0.105 }
    private var legacyStableNeutralHue: CGFloat { 0.60 }

    private var legacyNeutralLEDOKLCH: OKColor.OKLCH {
        OKColor.OKLCH(
            l: colorScheme == .dark ? 0.82 : 0.46,
            c: colorScheme == .dark ? 0.010 : 0.008,
            h: legacyStableNeutralHue
        )
    }

    private var legacyRawBase: NSColor {
        if let palette {
            return colorScheme == .dark ? palette.uiAccentOnDark : palette.uiAccentOnLight
        }
        return accentNS
    }

    private var legacyCenterColor: NSColor {
        guard let lch = OKColor.nsColorToOKLCH(legacyVolumeLEDSourceColor) else {
            return legacyRawBase
        }
        if let palette,
           palette.analysis.primaryHueSourceColor == nil,
           legacyShouldUseNeutralVolumeLED(for: palette) {
            return OKColor.okLCHToNSColor(legacyOptimizedNearNeutralLEDLCH(from: lch), alpha: 1.0)
        }
        return OKColor.okLCHToNSColor(legacyOptimizedLEDLCH(from: lch, preservesLowChromaHue: true), alpha: 1.0)
    }

    private var legacyVolumeLEDSourceColor: NSColor {
        if let palette {
            if palette.analysis.lacksTrustedHue {
                return OKColor.okLCHToNSColor(legacyNeutralLEDOKLCH, alpha: 1.0)
            }
            if let source = palette.analysis.primaryHueSourceColor {
                return source
            }
            if legacyShouldUseNeutralVolumeLED(for: palette) {
                return legacyNearNeutralVolumeSourceColor(for: palette.analysis)
            }
        }
        return legacyRawBase
    }

    private func legacyOptimizedNearNeutralLEDLCH(from source: OKColor.OKLCH) -> OKColor.OKLCH {
        let l = colorScheme == .dark ? CGFloat(0.82) : CGFloat(0.46)
        let sourceC = min(source.c, 0.040)
        let chromaCap: CGFloat = colorScheme == .dark ? 0.024 : 0.020
        let c = ColorMath.clamp(sourceC * 0.42, 0.006, chromaCap)
        return OKColor.OKLCH(l: l, c: c, h: source.h)
    }

    private func legacyNearNeutralVolumeSourceColor(for analysis: ArtworkColorAnalysis) -> NSColor {
        if let source = analysis.primaryHueSourceColor {
            return source
        }
        guard !analysis.isMonochrome else {
            return OKColor.okLCHToNSColor(legacyNeutralLEDOKLCH, alpha: 1.0)
        }
        let average = ColorMath.hsl(of: analysis.averageColor)
        let averageHueIsStable = average.s >= 0.045
            && analysis.avgSaturation >= 0.045
            && analysis.lightnessVariance < 0.090
        if averageHueIsStable {
            return analysis.averageColor
        }
        return OKColor.okLCHToNSColor(legacyNeutralLEDOKLCH, alpha: 1.0)
    }

    private func legacyOptimizedLEDLCH(from source: OKColor.OKLCH, preservesLowChromaHue: Bool) -> OKColor.OKLCH {
        let lowChromaThreshold: CGFloat = 0.045
        let sourceHue = source.c < lowChromaThreshold && !preservesLowChromaHue ? legacyFallbackHue() : source.h
        let baseL: CGFloat
        let capC: CGFloat
        let minC: CGFloat
        let scaleC: CGFloat

        if colorScheme == .dark {
            switch sourceHue {
            case 0.55..<0.92:
                baseL = 0.855
            case 0.08..<0.20:
                baseL = 0.805
            default:
                baseL = 0.835
            }
            minC = 0.066
            capC = legacyHueAwareChromaCap(for: sourceHue, darkMode: true) * 1.08
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
            capC = legacyHueAwareChromaCap(for: sourceHue, darkMode: false) * 1.08
            scaleC = 0.74
        }

        let requestedC = source.c < lowChromaThreshold
            ? (colorScheme == .dark ? 0.075 : 0.065)
            : source.c * scaleC
        let baseC = ColorMath.clamp(requestedC, minC, capC)
        return OKColor.OKLCH(l: baseL, c: baseC, h: sourceHue)
    }

    private func legacyHueAwareChromaCap(for h: CGFloat, darkMode: Bool) -> CGFloat {
        switch h {
        case 0.18..<0.30: return darkMode ? 0.105 : 0.092
        case 0.25..<0.45: return darkMode ? 0.125 : 0.108
        case 0.55..<0.75: return darkMode ? 0.150 : 0.128
        case 0.75..<0.92: return darkMode ? 0.135 : 0.116
        default:          return darkMode ? 0.155 : 0.132
        }
    }

    private func legacyFallbackHue() -> CGFloat {
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

        return legacyStableWarmHue
    }

    private func legacyShouldUseNeutralVolumeLED(for palette: SemanticPalette) -> Bool {
        let analysis = palette.analysis
        let nearNeutralArtwork = analysis.colorfulness < 0.18
            && analysis.avgSaturation < 0.18
            && analysis.dominantSaturation < 0.22
            && analysis.largestHighSaturationAreaShare < 0.18
        return analysis.isEffectivelyMonochrome || nearNeutralArtwork
    }

    private var legacyEdgeColor: NSColor {
        guard let centerLCH = OKColor.nsColorToOKLCH(legacyCenterColor) else {
            return legacyCenterColor
        }

        var edgeH = centerLCH.h
        if centerLCH.h < 0.08 || centerLCH.h >= 0.92 {
            edgeH += 0.012
        } else if centerLCH.h >= 0.55 && centerLCH.h < 0.75 {
            edgeH -= 0.014
        } else if centerLCH.h >= 0.25 && centerLCH.h < 0.45 {
            edgeH += 0.012
        } else {
            edgeH += 0.010
        }
        edgeH = OKColor.normalizedHue(edgeH)

        let edgeC = centerLCH.c * 0.90
        let edgeL = centerLCH.l - (colorScheme == .dark ? 0.030 : 0.020)
        return OKColor.okLCHToNSColor(OKColor.OKLCH(l: edgeL, c: edgeC, h: edgeH), alpha: 1.0)
    }

    private var legacyStatusLightBaseColor: NSColor {
        if isEffectivelyMonochrome {
            return OKColor.okLCHToNSColor(legacyNeutralLEDOKLCH, alpha: 1.0)
        }
        if let palette {
            let candidate = palette.coverGradientDominant
            guard let centerLCH = OKColor.nsColorToOKLCH(legacyCenterColor) else {
                return legacyCenterColor
            }
            guard let candidateLCH = OKColor.nsColorToOKLCH(candidate) else {
                return legacyCenterColor
            }
            if ColorMath.circularHueDistance(centerLCH.h, candidateLCH.h) > 0.03 {
                return OKColor.okLCHToNSColor(legacyOptimizedLEDLCH(from: candidateLCH, preservesLowChromaHue: false), alpha: 1.0)
            }
            if let secondaryLCH = OKColor.nsColorToOKLCH(palette.artBackgroundSecondary) {
                return OKColor.okLCHToNSColor(legacyOptimizedLEDLCH(from: secondaryLCH, preservesLowChromaHue: false), alpha: 1.0)
            }
            return legacyCenterColor
        }
        guard let rawLCH = OKColor.nsColorToOKLCH(legacyRawBase) else {
            return legacyRawBase
        }
        return OKColor.okLCHToNSColor(legacyOptimizedLEDLCH(from: rawLCH, preservesLowChromaHue: false), alpha: 1.0)
    }

    private func legacyBaseColorForIndex(index: Int, count: Int) -> NSColor {
        guard count > 1 else { return legacyCenterColor }
        guard let centerLCH = OKColor.nsColorToOKLCH(legacyCenterColor),
              let edgeLCH = OKColor.nsColorToOKLCH(legacyEdgeColor) else {
            return legacyCenterColor
        }
        let center = Double(count - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        let lerpedLCH = OKColor.oklabLerp(centerLCH, edgeLCH, t: CGFloat(distance))
        return OKColor.okLCHToNSColor(lerpedLCH, alpha: 1.0)
    }

    private func legacyOKLCHColorForLevel(
        base baseNS: NSColor,
        level: Int,
        isStroke: Bool = false
    ) -> NSColor {
        guard let baseLCH = OKColor.nsColorToOKLCH(baseNS) else { return baseNS }
        let maxLevel = max(1, brightnessLevels - 1)
        let tone = PerceptualToneLadder.ledTone(
            base: baseLCH,
            level: level,
            maxLevel: maxLevel,
            scheme: colorScheme,
            isNearMonochrome: palette?.analysis.isNearMonochrome ?? isEffectivelyMonochrome,
            isStroke: isStroke
        )
        return OKColor.okLCHToNSColor(tone, alpha: 1.0)
    }

    private func legacyStatusLightNSColor(level: Int) -> NSColor {
        legacyOKLCHColorForLevel(base: legacyStatusLightBaseColor, level: level)
    }

    private func legacyStatusLightStrokeNSColor(level: Int) -> NSColor {
        legacyOKLCHColorForLevel(base: legacyStatusLightBaseColor, level: level, isStroke: true)
    }

    private func legacyVolumeLEDNSColor(index: Int, count: Int, level: Int) -> NSColor {
        let base = legacyBaseColorForIndex(index: index, count: count)
        return legacyOKLCHColorForLevel(base: base, level: level)
    }

    private func legacyVolumeLEDStrokeNSColor(index: Int, count: Int, level: Int) -> NSColor {
        let base = legacyBaseColorForIndex(index: index, count: count)
        return legacyOKLCHColorForLevel(base: base, level: level, isStroke: true)
    }
}
#endif

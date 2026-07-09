//
//  BKPerceptualColorPolicy.swift
//  myPlayer2
//
//  OKLCH-first policy for BK art background roles. Production enters through
//  BKColorEngine.make / makeShapeSwatches / stabilize; legacy HSB entry points
//  remain available for parity and DEBUG diagnostics.
//

import AppKit
import CoreGraphics
import Foundation

nonisolated enum BKPerceptualPolicy: String, Sendable {
    case legacyHSB = "legacy-hsb"
    case candidateOKLCH = "candidate-oklch"
}

nonisolated enum BKSemanticColorRole: String, CaseIterable, Sendable {
    case backgroundBase = "background-base"
    case backgroundAtmosphere = "background-atmosphere"
    case floatingShapePrimary = "floating-shape-primary"
    case floatingShapeSecondary = "floating-shape-secondary"
    case highlightGlow = "highlight-glow"
    case stabilizedShape = "stabilized-shape"
}

nonisolated struct BKLayerContractMetrics: Sendable {
    let scheme: String
    let backgroundBaseL: CGFloat
    let backgroundMaxC: CGFloat
    let shapeMaxL: CGFloat
    let shapeMaxC: CGFloat
    let shapeMinL: CGFloat
    let highlightL: CGFloat
    let highlightC: CGFloat
    let sRGBBackgroundBaseL: CGFloat
    let sRGBShapeMaxL: CGFloat
    let lightModeSeparation: CGFloat
    let darkModeShapeUpperBound: CGFloat
    let nearMonoMaxChroma: CGFloat
    let blockerReasons: [String]
    let reviewReasons: [String]

    var classification: BKLayerContractClassification {
        if !blockerReasons.isEmpty { return .blocker }
        if !reviewReasons.isEmpty { return .reviewRequired }
        return .pass
    }
}

nonisolated enum BKLayerContractClassification: String, Sendable {
    case pass
    case reviewRequired = "review-required"
    case blocker
}

nonisolated enum BKInputPalettePolicy {
    static func selectedPalette(
        analysis: ArtworkColorAnalysis?,
        basePalette: [NSColor],
        richPalette: [NSColor],
        fallbackPalette: [NSColor] = BKExtractedPalettePolicy.fallbackPalette
    ) -> [NSColor] {
        BKExtractedPalettePolicy.select(
            analysis: analysis,
            basePalette: basePalette,
            richPalette: richPalette,
            fallbackPalette: fallbackPalette
        )
    }
}

nonisolated enum BKLegacyHSBPolicy {
    static func palette(
        extracted: [NSColor],
        fallback: [NSColor],
        isDark: Bool,
        analysis: ArtworkColorAnalysis?
    ) -> HarmonizedPalette {
        BKColorEngine.makeLegacyHSB(
            extracted: extracted,
            fallback: fallback,
            isDark: isDark,
            analysis: analysis
        )
    }

    static func shapeSwatches(
        seed: UInt64,
        extracted: [NSColor],
        fallback: [NSColor],
        isDark: Bool,
        analysis: ArtworkColorAnalysis?
    ) -> BKColorEngine.ShapeSwatchResult {
        BKColorEngine.makeLegacyHSBShapeSwatches(
            seed: seed,
            extracted: extracted,
            fallback: fallback,
            isDark: isDark,
            analysis: analysis
        )
    }

    static func stabilize(
        color: CGColor,
        kind: ElementKind,
        palette: HarmonizedPalette,
        hueJitter: CGFloat = 0,
        saturationJitter: CGFloat = 0,
        brightnessJitter: CGFloat = 0
    ) -> CGColor {
        BKColorEngine.stabilizeLegacyHSB(
            color: color,
            kind: kind,
            palette: palette,
            hueJitter: hueJitter,
            saturationJitter: saturationJitter,
            brightnessJitter: brightnessJitter
        )
    }
}

nonisolated enum BKPerceptualRolePolicy {
    static func candidateOKLCHPalette(
        legacy: HarmonizedPalette,
        analysis: ArtworkColorAnalysis?
    ) -> HarmonizedPalette {
        let neutral = shouldRenderNeutral(legacy: legacy, analysis: analysis)
        let seed = seedLCH(legacy: legacy, analysis: analysis)
        let brightAreaRatio = analysis?.brightAreaRatio ?? 0
        let bgStops = BKBackgroundTonePolicy.backgroundStops(
            legacy: legacy.bgStops,
            seed: seed,
            isDark: legacy.isDark,
            isUltraDark: analysis?.isUltraDark ?? false,
            neutral: neutral,
            coverColorfulness: analysis?.colorfulness ?? legacy.coverAvgS,
            brightAreaRatio: brightAreaRatio
        )
        let bgVariants = BKBackgroundTonePolicy.backgroundVariants(
            legacy: legacy.bgVariants,
            fallbackStops: bgStops,
            seed: seed,
            isDark: legacy.isDark,
            isUltraDark: analysis?.isUltraDark ?? false,
            neutral: neutral,
            coverColorfulness: analysis?.colorfulness ?? legacy.coverAvgS,
            brightAreaRatio: brightAreaRatio
        )
        let bgMetrics = BKPerceptualColorMath.lchValues(from: bgVariants.flatMap { $0 }.ifEmpty(bgStops))
        let bgMinL = bgMetrics.map(\.l).min() ?? seed.l
        let bgMaxC = bgMetrics.map(\.c).max() ?? seed.c

        let shapePool = BKFloatingShapePolicy.shapePool(
            legacy: legacy.shapePool,
            seed: seed,
            backgroundMinL: bgMinL,
            backgroundMaxC: bgMaxC,
            isDark: legacy.isDark,
            isUltraDark: analysis?.isUltraDark ?? false,
            neutral: neutral,
            coverColorfulness: analysis?.colorfulness ?? legacy.coverAvgS
        )
        let dotBase = BKFloatingShapePolicy.highlightGlow(
            legacy: legacy.dotBase,
            seed: seed,
            backgroundMinL: bgMinL,
            backgroundMaxC: bgMaxC,
            isDark: legacy.isDark,
            isUltraDark: analysis?.isUltraDark ?? false,
            neutral: neutral
        )

        return HarmonizedPalette(
            primaryHue: legacy.primaryHue,
            imageHue: legacy.imageHue,
            isDark: legacy.isDark,
            complexity: legacy.complexity,
            grayScore: legacy.grayScore,
            isGrayscaleCover: legacy.isGrayscaleCover,
            isNearGray: legacy.isNearGray,
            coverLuma: legacy.coverLuma,
            imageCoverLuma: legacy.imageCoverLuma,
            coverAvgS: legacy.coverAvgS,
            areaDominantS: legacy.areaDominantS,
            areaDominantB: legacy.areaDominantB,
            accentHue: legacy.accentHue,
            accentStrength: legacy.accentStrength,
            accentEnabled: legacy.accentEnabled,
            usesStrictNeutralRendering: neutral,
            chromaticClusterCount: neutral ? 0 : legacy.chromaticClusterCount,
            bgStops: bgStops,
            bgVariants: bgVariants,
            shapePool: shapePool,
            dotBase: dotBase,
            bgBRange: legacy.bgBRange,
            fgBRange: legacy.fgBRange,
            dotBRange: legacy.dotBRange,
            bgSRange: legacy.bgSRange,
            fgSRange: legacy.fgSRange,
            dotSRange: legacy.dotSRange
        )
    }

    static func candidateShapeSwatches(
        legacy: BKColorEngine.ShapeSwatchResult,
        palette: HarmonizedPalette,
        analysis: ArtworkColorAnalysis?
    ) -> BKColorEngine.ShapeSwatchResult {
        let bgL = BKPerceptualColorMath.lchValues(from: palette.bgStops).map(\.l).min()
            ?? (palette.isDark ? 0.18 : 0.92)
        let bgC = BKPerceptualColorMath.lchValues(from: palette.bgStops).map(\.c).max()
            ?? (palette.isDark ? 0.05 : 0.07)
        let neutral = shouldRenderNeutral(legacy: palette, analysis: analysis)
        let converted = BKFloatingShapePolicy.shapePool(
            legacy: legacy.colors,
            seed: seedLCH(legacy: palette, analysis: analysis),
            backgroundMinL: bgL,
            backgroundMaxC: bgC,
            isDark: palette.isDark,
            isUltraDark: analysis?.isUltraDark ?? false,
            neutral: neutral,
            coverColorfulness: analysis?.colorfulness ?? palette.coverAvgS
        )
        return BKColorEngine.ShapeSwatchResult(
            colors: converted,
            diagnostics: BKColorEngine.ShapeSwatchDiagnostics(
                avgS: BKPerceptualColorMath.averageHSBSaturation(converted),
                hueSpread: BKPerceptualColorMath.hueSpreadDegrees(converted),
                swatchCount: converted.count,
                chromaticClusterCount: neutral ? 0 : legacy.diagnostics.chromaticClusterCount,
                swatchHSB: converted.map(BKPerceptualColorMath.hsbDebugString(for:)),
                nearestCandidateHueDiff: legacy.diagnostics.nearestCandidateHueDiff
            )
        )
    }

    static func contractMetrics(
        palette: HarmonizedPalette,
        shapeSwatches: [CGColor],
        stabilizedShapes: [CGColor],
        analysis: ArtworkColorAnalysis?
    ) -> BKLayerContractMetrics {
        let bgColors = palette.bgStops.ifEmpty(palette.bgVariants.flatMap { $0 })
        let bgLCH = BKPerceptualColorMath.lchValues(from: bgColors)
        let atmosphereLCH = BKPerceptualColorMath.lchValues(from: palette.bgVariants.flatMap { $0 })
            .ifEmpty(bgLCH)
        let shapeLCH = BKPerceptualColorMath.lchValues(from: shapeSwatches.ifEmpty(palette.shapePool))
        let stabilizedLCH = BKPerceptualColorMath.lchValues(from: stabilizedShapes)
        let allShapeLCH = shapeLCH + stabilizedLCH
        let dotLCH = BKPerceptualColorMath.lch(from: palette.dotBase)

        let backgroundBaseL = bgLCH.first?.l ?? (palette.isDark ? 0.16 : 0.92)
        let backgroundMaxC = atmosphereLCH.map(\.c).max() ?? bgLCH.map(\.c).max() ?? 0
        let shapeMaxL = allShapeLCH.map(\.l).max() ?? 0
        let shapeMinL = allShapeLCH.map(\.l).min() ?? 0
        let shapeMaxC = allShapeLCH.map(\.c).max() ?? 0
        let highlightL = dotLCH?.l ?? 0
        let highlightC = dotLCH?.c ?? 0

        let bgSRGB = BKPerceptualColorMath.sRGBFallbackLCH(from: bgColors.first)
        let shapeSRGBMaxL = shapeSwatches.ifEmpty(palette.shapePool)
            .compactMap(BKPerceptualColorMath.sRGBFallbackLCH(from:))
            .map(\.l)
            .max() ?? 0

        var blockers: [String] = []
        var review: [String] = []
        let isNearMono = analysis?.lacksTrustedHue ?? palette.usesStrictNeutralRendering
        let isUltraDark = analysis?.isUltraDark ?? false
        let nearMonoMaxC = max(
            bgLCH.map(\.c).max() ?? 0,
            allShapeLCH.map(\.c).max() ?? 0,
            highlightC
        )

        if isNearMono && nearMonoMaxC > 0.012 {
            blockers.append("nearMono chroma exceeded neutral ceiling")
        }

        if palette.isDark {
            let upper = isUltraDark ? CGFloat(0.48) : CGFloat(0.56)
            if shapeMaxL > upper {
                blockers.append("dark floating shape L exceeds upper bound")
            }
            if highlightL > (isUltraDark ? 0.50 : 0.58) {
                review.append("dark highlight/glow is near foreground brightness")
            }
            if shapeMaxC > 0.125 {
                review.append("dark floating shape chroma may read fluorescent")
            }
        } else {
            let separation = backgroundBaseL - shapeMaxL
            if separation < 0.055 {
                blockers.append("light background base is not perceptually above shapes")
            }
            if (bgSRGB?.l ?? backgroundBaseL) - shapeSRGBMaxL < 0.045 {
                blockers.append("sRGB fallback reverses or collapses light hierarchy")
            }
            if shapeMaxL > backgroundBaseL && shapeMaxC >= backgroundMaxC {
                blockers.append("light shape is both brighter and more chromatic than background")
            }
            if shapeMaxC > max(0.030, backgroundMaxC - 0.004) {
                review.append("light floating shape chroma no longer sits under atmosphere")
            }
        }

        return BKLayerContractMetrics(
            scheme: palette.isDark ? "dark" : "light",
            backgroundBaseL: backgroundBaseL,
            backgroundMaxC: backgroundMaxC,
            shapeMaxL: shapeMaxL,
            shapeMaxC: shapeMaxC,
            shapeMinL: shapeMinL,
            highlightL: highlightL,
            highlightC: highlightC,
            sRGBBackgroundBaseL: bgSRGB?.l ?? backgroundBaseL,
            sRGBShapeMaxL: shapeSRGBMaxL,
            lightModeSeparation: backgroundBaseL - shapeMaxL,
            darkModeShapeUpperBound: isUltraDark ? 0.48 : 0.56,
            nearMonoMaxChroma: nearMonoMaxC,
            blockerReasons: blockers,
            reviewReasons: review
        )
    }

    private static func shouldRenderNeutral(
        legacy: HarmonizedPalette,
        analysis: ArtworkColorAnalysis?
    ) -> Bool {
        if let analysis {
            if analysis.lacksTrustedHue {
                return true
            }
            if analysis.hasTrustedHueCandidate {
                return false
            }
        }
        return legacy.usesStrictNeutralRendering || legacy.isGrayscaleCover
    }

    private static func seedLCH(
        legacy: HarmonizedPalette,
        analysis: ArtworkColorAnalysis?
    ) -> OKColor.OKLCH {
        let candidates: [NSColor?] = [
            analysis?.primaryHueSourceColor,
            analysis?.displayPalette.first,
            analysis?.surfacePalette.first,
            analysis?.topPalette.first,
        ]
        for candidate in candidates {
            if let color = candidate,
               let lch = OKColor.nsColorToOKLCH(color),
               lch.c >= 0.006 {
                return lch
            }
        }
        return OKColor.OKLCH(
            l: legacy.isDark ? 0.26 : 0.88,
            c: legacy.usesStrictNeutralRendering ? 0 : 0.055,
            h: OKColor.normalizedHue(legacy.primaryHue / 360)
        )
    }
}

nonisolated enum BKBackgroundTonePolicy {
    static func backgroundStops(
        legacy: [CGColor],
        seed: OKColor.OKLCH,
        isDark: Bool,
        isUltraDark: Bool,
        neutral: Bool,
        coverColorfulness: CGFloat,
        brightAreaRatio: CGFloat = 0
    ) -> [CGColor] {
        let sources = BKPerceptualColorMath.lchValues(from: legacy)
            .ifEmpty([seed, seed, seed])
        let count = max(3, min(5, sources.count))
        return (0..<count).map { index in
            let source = sources[index % sources.count]
            let t = CGFloat(index) / CGFloat(max(1, count - 1))
            let lch = tone(
                source: source,
                seed: seed,
                indexT: t,
                isDark: isDark,
                isUltraDark: isUltraDark,
                neutral: neutral,
                coverColorfulness: coverColorfulness,
                brightAreaRatio: brightAreaRatio
            )
            return BKRenderingColorAdapter.cgColor(lch)
        }
    }

    static func backgroundVariants(
        legacy: [[CGColor]],
        fallbackStops: [CGColor],
        seed: OKColor.OKLCH,
        isDark: Bool,
        isUltraDark: Bool,
        neutral: Bool,
        coverColorfulness: CGFloat,
        brightAreaRatio: CGFloat = 0
    ) -> [[CGColor]] {
        guard !legacy.isEmpty else { return [fallbackStops] }
        return legacy.enumerated().map { variantIndex, variant in
            let sources = BKPerceptualColorMath.lchValues(from: variant).ifEmpty([seed])
            return sources.enumerated().map { colorIndex, source in
                let t = CGFloat(colorIndex + variantIndex) / CGFloat(max(1, sources.count + legacy.count - 2))
                let lch = tone(
                    source: source,
                    seed: seed,
                    indexT: t,
                    isDark: isDark,
                    isUltraDark: isUltraDark,
                    neutral: neutral,
                    coverColorfulness: coverColorfulness,
                    brightAreaRatio: brightAreaRatio
                )
                return BKRenderingColorAdapter.cgColor(lch)
            }
        }
    }

    private static func tone(
        source: OKColor.OKLCH,
        seed: OKColor.OKLCH,
        indexT: CGFloat,
        isDark: Bool,
        isUltraDark: Bool,
        neutral: Bool,
        coverColorfulness: CGFloat,
        brightAreaRatio: CGFloat = 0
    ) -> OKColor.OKLCH {
        let hue = source.c >= 0.004 ? source.h : seed.h
        if neutral {
            let lightL = CGFloat(0.940 + (indexT - 0.5) * 0.055)
            let darkL = CGFloat(isUltraDark ? 0.112 + indexT * 0.060 : 0.170 + indexT * 0.090)
            return OKColor.OKLCH(l: ColorMath.clamp(isDark ? darkL : lightL, 0, 1), c: 0, h: 0)
        }

        if isDark {
            // Narrowed L spread so the gradient-mapped image no longer crushes
            // shadows to dead black. Hierarchy preserved, just less extreme.
            let baseL = isUltraDark ? CGFloat(0.122 + indexT * 0.060) : CGFloat(0.185 + indexT * 0.075)
            let colorFloor = ColorMath.clamp(0.020 + coverColorfulness * 0.10, 0.024, 0.070)
            let cap = BKColorRiskPolicy.chromaCap(
                hue: hue,
                role: .backgroundAtmosphere,
                isDark: true
            )
            let c = min(cap, max(colorFloor, source.c * 0.80 + seed.c * 0.18))
            return OKColor.OKLCH(l: baseL, c: c, h: BKColorRiskPolicy.adjustedHue(hue, role: .backgroundAtmosphere))
        }

        // Light mode: lift L and fade chroma for predominantly-bright / near-white
        // covers so the background never reads darker than a light cover.
        let brightBoost = ColorMath.clamp((brightAreaRatio - 0.35) / 0.40, 0, 1)
        let nearWhiteFade = brightBoost * ColorMath.clamp(1 - seed.c * 5.0, 0, 1)
        let baseL = CGFloat(0.928 + indexT * 0.040 + brightBoost * 0.022)
        let colorFloor = ColorMath.clamp(
            (0.030 + coverColorfulness * 0.14) * (1 - nearWhiteFade * 0.45),
            0.018,
            0.110
        )
        let cap = BKColorRiskPolicy.chromaCap(
            hue: hue,
            role: .backgroundAtmosphere,
            isDark: false
        )
        let c = min(cap, max(colorFloor, source.c * 0.80 + seed.c * 0.32))
        return OKColor.OKLCH(l: baseL, c: c, h: BKColorRiskPolicy.adjustedHue(hue, role: .backgroundAtmosphere))
    }
}

nonisolated enum BKFloatingShapePolicy {
    static func shapePool(
        legacy: [CGColor],
        seed: OKColor.OKLCH,
        backgroundMinL: CGFloat,
        backgroundMaxC: CGFloat,
        isDark: Bool,
        isUltraDark: Bool,
        neutral: Bool,
        coverColorfulness: CGFloat
    ) -> [CGColor] {
        let sources = BKPerceptualColorMath.lchValues(from: legacy).ifEmpty([seed])
        return sources.enumerated().map { index, source in
            let t = CGFloat(index % max(1, sources.count)) / CGFloat(max(1, sources.count - 1))
            let lch = shapeTone(
                source: source,
                seed: seed,
                position: t,
                backgroundMinL: backgroundMinL,
                backgroundMaxC: backgroundMaxC,
                isDark: isDark,
                isUltraDark: isUltraDark,
                neutral: neutral,
                coverColorfulness: coverColorfulness
            )
            return BKRenderingColorAdapter.cgColor(lch)
        }
    }

    static func highlightGlow(
        legacy: CGColor,
        seed: OKColor.OKLCH,
        backgroundMinL: CGFloat,
        backgroundMaxC: CGFloat,
        isDark: Bool,
        isUltraDark: Bool,
        neutral: Bool
    ) -> CGColor {
        let source = BKPerceptualColorMath.lch(from: legacy) ?? seed
        let hue = source.c >= 0.004 ? source.h : seed.h
        let l: CGFloat
        let c: CGFloat
        if neutral {
            l = isDark ? (isUltraDark ? 0.38 : 0.46) : 0.690
            c = 0
        } else if isDark {
            l = isUltraDark ? 0.395 : 0.470
            c = min(
                BKColorRiskPolicy.chromaCap(hue: hue, role: .highlightGlow, isDark: true),
                max(0.040, source.c * 0.84)
            )
        } else {
            l = min(0.760, max(0.680, backgroundMinL - 0.155))
            // Let the dot/highlight carry more of the cover's own chroma so the
            // moving circles can follow cover saturation. The background-linked
            // ceiling is raised and source retention increased.
            c = min(
                BKColorRiskPolicy.chromaCap(hue: hue, role: .highlightGlow, isDark: false),
                max(min(0.108, backgroundMaxC + 0.018), source.c * 0.86)
            )
        }
        return BKRenderingColorAdapter.cgColor(
            OKColor.OKLCH(l: l, c: c, h: BKColorRiskPolicy.adjustedHue(hue, role: .highlightGlow))
        )
    }

    private static func shapeTone(
        source: OKColor.OKLCH,
        seed: OKColor.OKLCH,
        position: CGFloat,
        backgroundMinL: CGFloat,
        backgroundMaxC: CGFloat,
        isDark: Bool,
        isUltraDark: Bool,
        neutral: Bool,
        coverColorfulness: CGFloat
    ) -> OKColor.OKLCH {
        let hue = source.c >= 0.004 ? source.h : seed.h
        if neutral {
            // Light: keep neutral shapes bright (raised floor). Dark: press darker
            // to match the "light brightens, dark darkens" direction.
            let l = isDark
                ? CGFloat(0.250 + position * (isUltraDark ? 0.075 : 0.135))
                : CGFloat(0.750 + position * 0.108)
            return OKColor.OKLCH(l: l, c: 0, h: 0)
        }

        if isDark {
            // Dark mode: press shapes darker so they sit more subtly on the dark field.
            let upper = isUltraDark ? CGFloat(0.345) : CGFloat(0.410)
            let baseL = isUltraDark ? CGFloat(0.225 + position * 0.105) : CGFloat(0.250 + position * 0.135)
            let c = min(
                BKColorRiskPolicy.chromaCap(hue: hue, role: .floatingShapePrimary, isDark: true),
                max(0.030, source.c * 0.78 + coverColorfulness * 0.016)
            )
            return OKColor.OKLCH(
                l: min(upper, baseL),
                c: c,
                h: BKColorRiskPolicy.adjustedHue(hue, role: .floatingShapePrimary)
            )
        }

        // Light mode: raise the whole L band so shapes are always bright against the
        // light background, and decouple chroma from the (possibly muted) background
        // so vivid covers produce recognizable shapes instead of gray.
        let lightUpper = max(0.730, min(0.862, backgroundMinL - 0.028))
        let baseL = CGFloat(0.750 + position * 0.108)
        let sourceDrivenC = source.c * 0.58 + seed.c * 0.20 + coverColorfulness * 0.034
        let chromaCeiling = max(0.038, min(0.100, max(backgroundMaxC * 0.82, sourceDrivenC)))
        let c = min(
            chromaCeiling,
            BKColorRiskPolicy.chromaCap(hue: hue, role: .floatingShapePrimary, isDark: false),
            max(0.034, sourceDrivenC)
        )
        return OKColor.OKLCH(
            l: min(lightUpper, baseL),
            c: c,
            h: BKColorRiskPolicy.adjustedHue(hue, role: .floatingShapePrimary)
        )
    }
}

nonisolated enum BKColorRiskPolicy {
    static func chromaCap(
        hue: CGFloat,
        role: BKSemanticColorRole,
        isDark: Bool
    ) -> CGFloat {
        let h = OKColor.normalizedHue(hue)
        let roleBase: CGFloat
        switch role {
        case .backgroundBase, .backgroundAtmosphere:
            roleBase = isDark ? 0.092 : 0.114
        case .floatingShapePrimary, .floatingShapeSecondary, .stabilizedShape:
            roleBase = isDark ? 0.108 : 0.096
        case .highlightGlow:
            roleBase = isDark ? 0.105 : 0.128
        }

        let familyScale: CGFloat
        switch h {
        case 0.12..<0.22:
            familyScale = 0.84      // muddy yellow / warm paper
        case 0.22..<0.30:
            familyScale = 0.86      // yellow - less fluorescent risk than chartreuse
        case 0.30..<0.42:
            familyScale = 0.72      // green / chartreuse fluorescent risk
        case 0.78..<0.94:
            familyScale = 0.82      // pink / violet glow risk
        default:
            familyScale = 1.0
        }
        return roleBase * familyScale
    }

    static func adjustedHue(
        _ hue: CGFloat,
        role: BKSemanticColorRole
    ) -> CGFloat {
        let h = OKColor.normalizedHue(hue)
        switch h {
        case 0.22..<0.34:
            return OKColor.normalizedHue(h - 0.010)
        case 0.34..<0.42:
            return OKColor.normalizedHue(h - 0.006)
        case 0.12..<0.22:
            return OKColor.normalizedHue(h - 0.004)
        default:
            return h
        }
    }
}

nonisolated enum BKStabilizationPolicy {
    static func candidateOKLCHStabilize(
        color: CGColor,
        kind: ElementKind,
        palette: HarmonizedPalette,
        hueJitter: CGFloat = 0,
        saturationJitter: CGFloat = 0,
        brightnessJitter: CGFloat = 0
    ) -> CGColor {
        guard var lch = BKPerceptualColorMath.lch(from: color) else { return color }
        let role: BKSemanticColorRole
        switch kind {
        case .background:
            role = .backgroundAtmosphere
        case .shape:
            role = .stabilizedShape
        case .dot:
            role = .highlightGlow
        }
        lch.h = OKColor.normalizedHue(lch.h + hueJitter / 360)
        lch.c = max(0, lch.c + saturationJitter * 0.22)
        lch.l = ColorMath.clamp(lch.l + brightnessJitter * 0.72, 0, 1)
        if palette.usesStrictNeutralRendering {
            lch.c = 0
            lch.h = 0
        } else {
            lch.c = min(lch.c, BKColorRiskPolicy.chromaCap(hue: lch.h, role: role, isDark: palette.isDark))
        }

        if palette.isDark {
            switch kind {
            case .background:
                lch.l = min(lch.l, 0.30)
            case .shape:
                lch.l = min(lch.l, 0.410)
            case .dot:
                lch.l = min(lch.l, 0.58)
            }
        } else {
            let bgL = BKPerceptualColorMath.lchValues(from: palette.bgStops).map(\.l).min() ?? 0.92
            switch kind {
            case .background:
                lch.l = max(lch.l, 0.900)
            case .shape:
                lch.l = min(lch.l, bgL - 0.060)
                // Safety cap only - do not re-couple shape chroma to the muted
                // background. shapeTone already set a faithful, capped chroma.
                lch.c = min(lch.c, 0.096)
            case .dot:
                lch.l = min(lch.l, 0.765)
            }
        }
        return BKRenderingColorAdapter.cgColor(lch)
    }
}

nonisolated enum BKRenderingColorAdapter {
    static func cgColor(
        _ lch: OKColor.OKLCH,
        alpha: CGFloat = 1,
        target: ColorRenderTarget = .displayP3
    ) -> CGColor {
        ColorRenderingAdapter.makeCGColor(
            OKLCHColor(
                lightness: Double(ColorMath.clamp(lch.l, 0, 1)),
                chroma: Double(max(0, lch.c)),
                hue: lch.c > 0.0005 ? Double(OKColor.normalizedHue(lch.h)) : nil,
                alpha: Double(alpha)
            ),
            target: target
        )
    }
}

nonisolated enum BKPerceptualColorMath {
    static func lch(from color: CGColor?) -> OKColor.OKLCH? {
        guard let color,
              let ns = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB)
        else { return nil }
        return OKColor.nsColorToOKLCH(ns)
    }

    static func lchValues(from colors: [CGColor]) -> [OKColor.OKLCH] {
        colors.compactMap { lch(from: $0) }
    }

    static func sRGBFallbackLCH(from color: CGColor?) -> OKColor.OKLCH? {
        guard let color,
              let ns = NSColor(cgColor: color)
        else { return nil }
        let resolved = ColorRenderingAdapter.makeNSColor(ns, target: .sRGB)
        return OKColor.nsColorToOKLCH(resolved)
    }

    static func averageHSBSaturation(_ colors: [CGColor]) -> CGFloat {
        let values = colors.compactMap { color -> CGFloat? in
            guard let ns = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return nil }
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return s
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / CGFloat(values.count)
    }

    static func hueSpreadDegrees(_ colors: [CGColor]) -> CGFloat {
        let hues = colors.compactMap { color -> CGFloat? in
            guard let ns = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return nil }
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            guard s >= 0.010 else { return nil }
            return h
        }
        guard hues.count >= 2 else { return 0 }
        var maxDelta: CGFloat = 0
        for i in 0..<(hues.count - 1) {
            for j in (i + 1)..<hues.count {
                maxDelta = max(maxDelta, ColorMath.circularHueDistance(hues[i], hues[j]) * 360)
            }
        }
        return maxDelta
    }

    static func hsbDebugString(for color: CGColor) -> String {
        guard let ns = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else {
            return "h=0.0 s=0.000 b=0.000"
        }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return String(
            format: "h=%.1f s=%.3f b=%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            h * 360,
            s,
            b
        )
    }
}

extension BKColorEngine {
    nonisolated static func makeCandidateOKLCH(
        extracted: [NSColor],
        fallback: [NSColor],
        isDark: Bool,
        analysis: ArtworkColorAnalysis? = nil
    ) -> HarmonizedPalette {
        let legacy = makeLegacyHSB(
            extracted: extracted,
            fallback: fallback,
            isDark: isDark,
            analysis: analysis
        )
        return makeCandidateOKLCH(fromLegacy: legacy, analysis: analysis)
    }

    nonisolated static func makeCandidateOKLCH(
        fromLegacy legacy: HarmonizedPalette,
        analysis: ArtworkColorAnalysis? = nil
    ) -> HarmonizedPalette {
        BKPerceptualRolePolicy.candidateOKLCHPalette(
            legacy: legacy,
            analysis: analysis
        )
    }

    nonisolated static func makeCandidateOKLCHShapeSwatches(
        seed: UInt64,
        extracted: [NSColor],
        fallback: [NSColor],
        isDark: Bool,
        analysis: ArtworkColorAnalysis? = nil,
        candidatePalette: HarmonizedPalette? = nil
    ) -> ShapeSwatchResult {
        let legacy = makeLegacyHSBShapeSwatches(
            seed: seed,
            extracted: extracted,
            fallback: fallback,
            isDark: isDark,
            analysis: analysis
        )
        let palette = candidatePalette ?? makeCandidateOKLCH(
            extracted: extracted,
            fallback: fallback,
            isDark: isDark,
            analysis: analysis
        )
        return BKPerceptualRolePolicy.candidateShapeSwatches(
            legacy: legacy,
            palette: palette,
            analysis: analysis
        )
    }

    nonisolated static func stabilizeCandidateOKLCH(
        color: CGColor,
        kind: ElementKind,
        palette: HarmonizedPalette,
        hueJitter: CGFloat = 0,
        saturationJitter: CGFloat = 0,
        brightnessJitter: CGFloat = 0
    ) -> CGColor {
        BKStabilizationPolicy.candidateOKLCHStabilize(
            color: color,
            kind: kind,
            palette: palette,
            hueJitter: hueJitter,
            saturationJitter: saturationJitter,
            brightnessJitter: brightnessJitter
        )
    }
}

private extension Array {
    nonisolated func ifEmpty(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}

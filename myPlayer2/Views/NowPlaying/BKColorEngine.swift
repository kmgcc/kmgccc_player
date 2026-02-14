//
//  BKColorEngine.swift
//  myPlayer2
//
//  Harmonized artwork palette engine with hue risk avoidance,
//  brightness-saturation coupling, and explicit light/dark tiering.
//

import AppKit
import Foundation

enum ColorComplexityLevel: String {
    case monochrome
    case low
    case medium
    case high
}

enum CoverKind: String {
    case grayscaleTrue
    case mostlyBWWithColor
    case lowSatColor
    case richDistributed
    case normal
}

enum PrimarySelectionSource: String {
    case saliencyCandidate
    case cluster
    case scorer
    case grayscaleFallback
}

struct HarmonizedPalette {
    let primaryHue: CGFloat
    let imageHue: CGFloat
    let isDark: Bool
    let complexity: ColorComplexityLevel
    let grayScore: CGFloat
    let isGrayscaleCover: Bool
    let isNearGray: Bool
    let coverLuma: CGFloat
    let imageCoverLuma: CGFloat
    let coverAvgS: CGFloat
    let areaDominantS: CGFloat
    let areaDominantB: CGFloat
    let accentHue: CGFloat?
    let accentStrength: CGFloat
    let accentEnabled: Bool

    // Background (low sat)
    let bgStops: [CGColor]
    let bgVariants: [[CGColor]]

    // Foreground pools (higher sat)
    let shapePool: [CGColor]
    let dotBase: CGColor

    // Tier control (explicit)
    let bgBRange: ClosedRange<CGFloat>
    let fgBRange: ClosedRange<CGFloat>
    let dotBRange: ClosedRange<CGFloat>
    let bgSRange: ClosedRange<CGFloat>
    let fgSRange: ClosedRange<CGFloat>
    let dotSRange: ClosedRange<CGFloat>
}

enum ElementKind: Sendable, Equatable {
    case background
    case shape
    case dot

    nonisolated static func == (lhs: ElementKind, rhs: ElementKind) -> Bool {
        switch (lhs, rhs) {
        case (.background, .background),
            (.shape, .shape),
            (.dot, .dot):
            return true
        default:
            return false
        }
    }
}

struct BKColorEngine {
    struct ShapeSwatchDiagnostics {
        let avgS: CGFloat
        let hueSpread: CGFloat
        let swatchCount: Int
        let swatchHSB: [String]
        let nearestCandidateHueDiff: [CGFloat]
    }

    struct ShapeSwatchResult {
        let colors: [CGColor]
        let diagnostics: ShapeSwatchDiagnostics
    }

    nonisolated static func make(extracted: [NSColor], fallback: [NSColor], isDark: Bool)
        -> HarmonizedPalette
    {
        let paletteInput = (extracted.isEmpty ? fallback : extracted)
            .compactMap(hsb(from:))
            .map(normalizeCandidateColor(_:))
        let stats = analyzePalette(paletteInput)
        let tier = tierRanges(
            isDark: isDark,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            lowSatColorCover: stats.lowSatColorCover,
            coverKind: stats.coverKind,
            avgS: stats.matchedAvgS,
            coverLuma: stats.imageCoverLuma,
            veryDarkCover: stats.veryDarkCover,
            areaDominantS: stats.areaDominantS,
            areaDominantB: stats.areaDominantB
        )
        let lumaTargetBg = lumaTarget(coverLuma: stats.imageCoverLuma, isDark: isDark)
        let lumaTargetFg = lumaTarget(coverLuma: stats.coverLuma, isDark: isDark)
        let lumaKBg: CGFloat = isDark ? 0.82 : lumaBlendK(coverKind: stats.coverKind)
        let lumaKShape: CGFloat = isDark ? 0.55 : lumaBlendK(coverKind: stats.coverKind)
        let lumaKDot: CGFloat = isDark ? 0.45 : lumaBlendK(coverKind: stats.coverKind)

        if stats.coverKind == .grayscaleTrue {
            var triggered = Set<RiskFlag>()
            let grayscalePalette = makeGrayscalePalette(
                stats: stats, isDark: isDark, triggered: &triggered)
            logPalette(
                primaryBefore: grayscalePalette.primaryHue,
                primaryAfter: grayscalePalette.primaryHue,
                primarySource: .grayscaleFallback,
                stats: stats,
                tier: grayscaleTierRanges(isDark: isDark),
                triggered: triggered,
                bgStops: grayscalePalette.bgStops.compactMap(hsb(from:)),
                shapePool: grayscalePalette.shapePool.compactMap(hsb(from:)),
                dotBase: hsb(from: grayscalePalette.dotBase)
                    ?? HSBColor(
                        h: grayscalePalette.primaryHue, s: 0.24, b: isDark ? 0.72 : 0.56, a: 1),
                injectedAccentCount: 0
            )
            return grayscalePalette
        }

        var globalTriggers = Set<RiskFlag>()
        let primarySource: PrimarySelectionSource
        let primaryBefore: CGFloat
        if let hue = stats.bestSalientHue, stats.maxColorCandidateScore >= 0.22 {
            primaryBefore = normalizeHue(hue)
            primarySource = .saliencyCandidate
        } else if let clusterHue = stats.primaryClusterHue {
            primaryBefore = normalizeHue(clusterHue)
            primarySource = .cluster
        } else {
            let filteredCandidates = paletteInput.filter(isValidPrimaryCandidate(_:))
            let candidates = filteredCandidates.isEmpty ? paletteInput : filteredCandidates
            primaryBefore = selectPrimaryHue(
                from: candidates,
                isDark: isDark,
                complexity: stats.complexity,
                isNearGray: stats.isNearGray,
                dominantHue: stats.dominantHue,
                coverKind: stats.coverKind,
                salientHues: stats.topSalientHues
            )
            primarySource = .scorer
        }
        let primaryAfter = adjustPrimaryHue(
            primaryBefore,
            source: primarySource,
            coverKind: stats.coverKind,
            triggered: &globalTriggers
        )

        let hueFamily = makeHueFamily(
            primaryHue: primaryAfter,
            complexity: stats.complexity,
            clusterCenters: stats.clusterCenters,
            isNearGray: stats.isNearGray,
            triggered: &globalTriggers
        )

        var bgStopsHSB = makeBackgroundStops(
            primaryHue: stats.areaDominantHue,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            lowSatColorCover: stats.lowSatColorCover,
            satBoost: stats.lowSatSatBoost,
            briBoost: stats.lowSatBriBoost,
            lumaTarget: lumaTargetBg,
            lumaK: lumaKBg,
            isDark: isDark,
            triggered: &globalTriggers
        )
        var injectedAccentCount = 0
        var shapePoolHSB = makeShapePool(
            primaryHue: primaryAfter,
            dominantHue: stats.primaryClusterHue ?? stats.dominantHue,
            dominantS: stats.dominantS,
            clusterCount: stats.clusterCount,
            hueFamily: hueFamily,
            accentHue: stats.accentHue,
            accentShare: stats.accentShare,
            secondAccentHue: stats.accentClusterHue,
            accentEnabled: stats.accentEnabled,
            accentStrength: stats.accentStrength,
            salientHues: stats.topSalientHues,
            topClusters: stats.topClusters,
            injectAccentHues: stats.injectAccentHues,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            lowSatColorCover: stats.lowSatColorCover,
            satBoost: stats.lowSatSatBoost,
            briBoost: stats.lowSatBriBoost,
            lumaTarget: lumaTargetFg,
            lumaK: lumaKShape,
            isDark: isDark,
            injectedAccentCount: &injectedAccentCount,
            triggered: &globalTriggers
        )
        var dotBaseHSB = makeDotBase(
            primaryHue: primaryAfter,
            dominantHue: stats.primaryClusterHue ?? stats.dominantHue,
            dominantS: stats.dominantS,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            lowSatColorCover: stats.lowSatColorCover,
            satBoost: stats.lowSatSatBoost,
            briBoost: stats.lowSatBriBoost,
            lumaTarget: lumaTargetFg,
            lumaK: lumaKDot,
            isDark: isDark,
            triggered: &globalTriggers
        )

        let candidateHues = paletteInput.map { normalizeHue($0.h) }
        enforceCandidateHueSource(
            candidateHues: candidateHues,
            bgStops: &bgStopsHSB,
            shapePool: &shapePoolHSB,
            dotBase: &dotBaseHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            isDark: isDark,
            triggered: &globalTriggers
        )

        enforceDominantHueAffinity(
            dominantHue: stats.dominantHue,
            bgReferenceHue: stats.areaDominantHue,
            bgStops: &bgStopsHSB,
            shapePool: &shapePoolHSB,
            dotBase: &dotBaseHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            isDark: isDark,
            triggered: &globalTriggers
        )

        enforceSaturationGap(
            bgStops: &bgStopsHSB,
            shapePool: &shapePoolHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            isDark: isDark,
            triggered: &globalTriggers
        )
        enforceBrightnessHierarchy(
            bgStops: &bgStopsHSB,
            shapePool: &shapePoolHSB,
            dotBase: &dotBaseHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            isDark: isDark,
            triggered: &globalTriggers
        )
        enforceCoverSaturationMatch(
            avgS: stats.matchedAvgS,
            bgStops: &bgStopsHSB,
            shapePool: &shapePoolHSB,
            dotBase: &dotBaseHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            isDark: isDark,
            triggered: &globalTriggers
        )
        enforceSaturationGap(
            bgStops: &bgStopsHSB,
            shapePool: &shapePoolHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            isDark: isDark,
            triggered: &globalTriggers
        )

        let bgVariantsHSB = makeBackgroundVariants(
            candidates: paletteInput,
            shapePool: shapePoolHSB,
            baseStops: bgStopsHSB,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            avgS: stats.matchedAvgS,
            hueSpread: stats.hueSpread,
            isDark: isDark,
            triggered: &globalTriggers
        )

        let harmonized = HarmonizedPalette(
            primaryHue: normalizeHue(primaryAfter),
            imageHue: normalizeHue(stats.areaDominantHue),
            isDark: isDark,
            complexity: stats.complexity,
            grayScore: stats.grayScore,
            isGrayscaleCover: stats.isGrayscaleCover,
            isNearGray: stats.isNearGray,
            coverLuma: stats.coverLuma,
            imageCoverLuma: stats.imageCoverLuma,
            coverAvgS: stats.matchedAvgS,
            areaDominantS: stats.areaDominantS,
            areaDominantB: stats.areaDominantB,
            accentHue: stats.accentHue,
            accentStrength: stats.accentStrength,
            accentEnabled: stats.accentEnabled,
            bgStops: bgStopsHSB.map(toCGColor(_:)),
            bgVariants: bgVariantsHSB.map { $0.map(toCGColor(_:)) },
            shapePool: shapePoolHSB.map(toCGColor(_:)),
            dotBase: toCGColor(dotBaseHSB),
            bgBRange: tier.bgB,
            fgBRange: tier.fgB,
            dotBRange: tier.dotB,
            bgSRange: tier.bgS,
            fgSRange: tier.fgS,
            dotSRange: tier.dotS
        )

        logPalette(
            primaryBefore: primaryBefore,
            primaryAfter: harmonized.primaryHue,
            primarySource: primarySource,
            stats: stats,
            tier: tier,
            triggered: globalTriggers,
            bgStops: bgStopsHSB,
            shapePool: shapePoolHSB,
            dotBase: dotBaseHSB,
            injectedAccentCount: injectedAccentCount
        )

        return harmonized
    }

    nonisolated static func makeShapeSwatches(
        seed: UInt64,
        extracted: [NSColor],
        fallback: [NSColor],
        isDark: Bool
    ) -> ShapeSwatchResult {
        let input = (extracted.isEmpty ? fallback : extracted)
            .compactMap(hsb(from:))
            .map(normalizeCandidateColor(_:))
        guard !input.isEmpty else {
            let fallbackHSB = HSBColor(h: 220, s: 0.36, b: isDark ? 0.58 : 0.70, a: 1)
            return ShapeSwatchResult(
                colors: [toCGColor(fallbackHSB)],
                diagnostics: ShapeSwatchDiagnostics(
                    avgS: 0,
                    hueSpread: 0,
                    swatchCount: 1,
                    swatchHSB: [hsbString(fallbackHSB)],
                    nearestCandidateHueDiff: [0]
                )
            )
        }

        struct Candidate {
            let index: Int
            let color: HSBColor
            let score: CGFloat
        }

        let shares = inferredShares(count: input.count)
        let avgS = input.map(\.s).reduce(0, +) / CGFloat(input.count)
        let hues = input.map(\.h)
        let hueSpread = maxHueSpread(hues)
        let coverRichness = clamp((avgS / 0.55) * 0.6 + (hueSpread / 120) * 0.4, min: 0, max: 1)

        let swatchCount: Int
        if avgS < 0.16 {
            swatchCount = 1 + (coverRichness > 0.35 ? 1 : 0)
        } else if avgS < 0.42 {
            swatchCount = 3
        } else {
            swatchCount = max(4, min(6, 4 + Int(round(2 * coverRichness))))
        }

        var candidates: [Candidate] = input.enumerated().map { idx, color in
            let midBBoost = clamp(1 - abs(color.b - 0.55) / 0.55, min: 0, max: 1)
            let saliency = pow(color.s, 1.25) * (0.55 + 0.45 * midBBoost)
            let rankWeight = shares[idx]
            let score = rankWeight * (1 + 1.6 * saliency)
            return Candidate(index: idx, color: color, score: score)
        }
        candidates.sort { $0.score > $1.score }

        let targetCount = max(1, min(swatchCount, 6))
        var selected: [Candidate] = []
        if let primary = candidates.first {
            selected.append(primary)
        }

        if avgS >= 0.16, targetCount >= 3, let primary = selected.first {
            if let accent = candidates.first(where: {
                $0.index != primary.index && hueDistance($0.color.h, primary.color.h) >= 45
            }) {
                selected.append(accent)
            } else if let accent = candidates.first(where: {
                $0.index != primary.index && hueDistance($0.color.h, primary.color.h) >= 30
            }) {
                selected.append(accent)
            }
        }

        let maxScore = max(0.0001, candidates.first?.score ?? 0.0001)
        while selected.count < min(targetCount, candidates.count) {
            var picked: Candidate?
            var pickedComposite: CGFloat = -CGFloat.greatestFiniteMagnitude

            for candidate in candidates
            where !selected.contains(where: { $0.index == candidate.index }) {
                let minDistance =
                    selected.map { hueDistance(candidate.color.h, $0.color.h) }.min() ?? 180
                guard minDistance >= 18 else { continue }
                let scoreNorm = candidate.score / maxScore
                let composite = (minDistance / 180) * 0.65 + scoreNorm * 0.35
                if composite > pickedComposite {
                    pickedComposite = composite
                    picked = candidate
                }
            }

            if let picked {
                selected.append(picked)
            } else if let fallbackPick = candidates.first(where: { candidate in
                !selected.contains(where: { $0.index == candidate.index })
            }) {
                selected.append(fallbackPick)
            } else {
                break
            }
        }

        if selected.isEmpty, let first = candidates.first {
            selected = [first]
        }

        while selected.count < targetCount {
            guard let first = selected.first else { break }
            selected.append(first)
        }

        var state: UInt64 = seed == 0 ? 0xD1B5_4A32_9C7E_44F1 : seed
        func nextUnit(_ state: inout UInt64) -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            let x = value ^ (value >> 31)
            return CGFloat(Double(x >> 11) / Double((1 << 53) - 1))
        }
        func jittered(_ magnitude: CGFloat, _ state: inout UInt64) -> CGFloat {
            (nextUnit(&state) * 2 - 1) * magnitude
        }

        let briJitterMax: CGFloat = isDark ? 0.035 : 0.03
        let satJitterMax: CGFloat = 0.03

        var swatches: [HSBColor] = []
        swatches.reserveCapacity(targetCount)
        var nearestDiffs: [CGFloat] = []
        nearestDiffs.reserveCapacity(targetCount)
        let candidateHues = candidates.map { normalizeHue($0.color.h) }

        for index in 0..<targetCount {
            let candidate = selected[index % selected.count]
            let base = candidate.color
            let hueJitterMax: CGFloat
            if base.b < 0.18 {
                hueJitterMax = 2
            } else if base.s < 0.25 {
                hueJitterMax = 4
            } else if base.s < 0.45 {
                hueJitterMax = 8
            } else {
                hueJitterMax = 12
            }

            let hue = clampHueDistance(
                normalizeHue(base.h + jittered(hueJitterMax, &state)),
                around: base.h,
                maxDistance: 18
            )
            let sat = clamp(base.s + jittered(satJitterMax, &state), min: 0.01, max: 0.95)
            let bri = clamp(base.b + jittered(briJitterMax, &state), min: 0.10, max: 0.96)
            let swatch = HSBColor(h: hue, s: sat, b: bri, a: 1)
            swatches.append(swatch)

            let nearest = candidateHues.map { hueDistance($0, hue) }.min() ?? 0
            nearestDiffs.append(nearest)
        }

        return ShapeSwatchResult(
            colors: swatches.map(toCGColor(_:)),
            diagnostics: ShapeSwatchDiagnostics(
                avgS: avgS,
                hueSpread: hueSpread,
                swatchCount: targetCount,
                swatchHSB: swatches.map(hsbString(_:)),
                nearestCandidateHueDiff: nearestDiffs
            )
        )
    }

    nonisolated static func stabilize(
        color: CGColor,
        kind: ElementKind,
        palette: HarmonizedPalette,
        hueJitter: CGFloat = 0,
        saturationJitter: CGFloat = 0,
        brightnessJitter: CGFloat = 0
    ) -> CGColor {
        guard var hsb = hsb(from: color) else { return color }
        let effectiveHueJitter: CGFloat
        if hsb.b < 0.18 {
            effectiveHueJitter = clamp(hueJitter, min: -2, max: 2)
        } else {
            effectiveHueJitter = hueJitter
        }
        hsb.h = normalizeHue(hsb.h + effectiveHueJitter)
        hsb.s = clamp01(hsb.s + saturationJitter)
        hsb.b = clamp01(hsb.b + brightnessJitter)

        var triggered = Set<RiskFlag>()
        let ranges = ranges(for: kind, palette: palette)
        let safe = sanitize(
            hsb,
            kind: kind,
            bRange: ranges.b,
            sRange: ranges.s,
            complexity: palette.complexity,
            isNearGray: palette.isNearGray,
            isDark: palette.isDark,
            triggered: &triggered
        )
        return toCGColor(safe)
    }

    static func hsbDebugString(for color: CGColor) -> String {
        guard let hsb = hsb(from: color) else { return "h=0.0 s=0.000 b=0.000" }
        return hsbString(hsb)
    }
}

extension BKColorEngine {
    fileprivate enum RiskFlag: String, CaseIterable {
        case greenDanger = "green_danger"
        case hospitalGreen = "hospital_green"
        case muddyYellow = "muddy_yellow"
        case plasticRed = "plastic_red"
        case dirtyPurple = "dirty_purple"
        case fluorescentPink = "fluorescent_pink"
        case muddyCombo = "muddy_combo"
        case reverseHue = "reverse_hue"
    }

    fileprivate struct HSBColor {
        var h: CGFloat  // degrees: 0...360
        var s: CGFloat
        var b: CGFloat
        var a: CGFloat
    }

    fileprivate struct TierRanges {
        let bgB: ClosedRange<CGFloat>
        let fgB: ClosedRange<CGFloat>
        let dotB: ClosedRange<CGFloat>
        let bgS: ClosedRange<CGFloat>
        let fgS: ClosedRange<CGFloat>
        let dotS: ClosedRange<CGFloat>
    }

    fileprivate struct HueCluster {
        var sumX: CGFloat
        var sumY: CGFloat
        var count: Int
        var totalWeight: CGFloat

        nonisolated init(hue: CGFloat, weight: CGFloat = 1) {
            let radians = deg2rad(hue)
            sumX = cos(radians) * weight
            sumY = sin(radians) * weight
            count = 1
            totalWeight = weight
        }

        nonisolated mutating func add(hue: CGFloat, weight: CGFloat = 1) {
            let radians = deg2rad(hue)
            sumX += cos(radians) * weight
            sumY += sin(radians) * weight
            count += 1
            totalWeight += weight
        }

        nonisolated var centerHue: CGFloat {
            normalizeHue(rad2deg(atan2(sumY, sumX)))
        }
    }

    fileprivate struct PaletteStats {
        struct SalientHue {
            let hue: CGFloat
            let weight: CGFloat
        }

        struct HueWeight {
            let hue: CGFloat
            let weight: CGFloat
        }

        let avgS: CGFloat
        let matchedAvgS: CGFloat
        let hueSpread: CGFloat
        let circularVariance: CGFloat
        let circularStdDegrees: CGFloat
        let clusterCenters: [CGFloat]
        let clusterCount: Int
        let dominantHue: CGFloat
        let areaDominantHue: CGFloat
        let dominantS: CGFloat
        let areaDominantS: CGFloat
        let areaDominantB: CGFloat
        let dominantShare: CGFloat
        let accentHue: CGFloat?
        let accentShare: CGFloat
        let secondAccentHue: CGFloat?
        let grayScore: CGFloat
        let isGrayscaleCover: Bool
        let isNearGray: Bool
        let lowSatColorCover: Bool
        let lowSatSatBoost: CGFloat
        let lowSatBriBoost: CGFloat
        let coverKind: CoverKind
        let veryDarkCover: Bool
        let wBlack: CGFloat
        let wWhite: CGFloat
        let wColor: CGFloat
        let coverLuma: CGFloat
        let imageCoverLuma: CGFloat
        let accentEnabled: Bool
        let accentStrength: CGFloat
        let topSalientHues: [SalientHue]
        let topClusters: [HueWeight]
        let primaryClusterHue: CGFloat?
        let accentClusterHue: CGFloat?
        let maxColorCandidateScore: CGFloat
        let bestSalientHue: CGFloat?
        let injectAccentHues: [CGFloat]
        let evenness: CGFloat
        let complexity: ColorComplexityLevel
    }

    fileprivate nonisolated static func analyzePalette(_ colors: [HSBColor]) -> PaletteStats {
        guard !colors.isEmpty else {
            return PaletteStats(
                avgS: 0.25,
                matchedAvgS: 0.22,
                hueSpread: 30,
                circularVariance: 0.12,
                circularStdDegrees: 18,
                clusterCenters: [220],
                clusterCount: 1,
                dominantHue: 220,
                areaDominantHue: 220,
                dominantS: 0.30,
                areaDominantS: 0.30,
                areaDominantB: 0.45,
                dominantShare: 0.60,
                accentHue: nil,
                accentShare: 0,
                secondAccentHue: nil,
                grayScore: 0.25,
                isGrayscaleCover: false,
                isNearGray: false,
                lowSatColorCover: false,
                lowSatSatBoost: 1.0,
                lowSatBriBoost: 1.0,
                coverKind: .normal,
                veryDarkCover: false,
                wBlack: 0.15,
                wWhite: 0.10,
                wColor: 0.70,
                coverLuma: 0.52,
                imageCoverLuma: 0.45,
                accentEnabled: false,
                accentStrength: 0,
                topSalientHues: [.init(hue: 220, weight: 1)],
                topClusters: [.init(hue: 220, weight: 1)],
                primaryClusterHue: 220,
                accentClusterHue: nil,
                maxColorCandidateScore: 0.30,
                bestSalientHue: 220,
                injectAccentHues: [],
                evenness: 0.50,
                complexity: .low
            )
        }

        struct ScoredColor {
            let index: Int
            let color: HSBColor
            let score: CGFloat
            let saliency: CGFloat
        }

        let shares = inferredShares(count: colors.count)
        let avgS = colors.map(\.s).reduce(0, +) / CGFloat(colors.count)
        var matchedSatNumerator: CGFloat = 0
        var matchedSatDenominator: CGFloat = 0
        for index in colors.indices {
            let c = colors[index]
            let w = shares[index]
            let chroma = c.s * min(c.b, 1 - c.b)
            // Suppress fake vivid noise from near-black/near-white buckets.
            let matched = clamp(chroma * 2.2, min: 0, max: 1)
            matchedSatNumerator += matched * w
            matchedSatDenominator += w
        }
        let matchedAvgS = clamp(
            matchedSatNumerator / max(0.0001, matchedSatDenominator),
            min: 0,
            max: 1
        )
        let hueSpread = maxHueSpread(colors.map(\.h))
        let areaDominantIndex = shares.indices.max(by: { shares[$0] < shares[$1] }) ?? 0
        let areaDominant = colors[areaDominantIndex]
        let areaDominantHue = normalizeHue(areaDominant.h)
        let areaDominantS = areaDominant.s
        let areaDominantB = areaDominant.b

        var colorCandidates: [ScoredColor] = []
        var neutralCandidateIndices = Set<Int>()
        var wBlack: CGFloat = 0
        var wWhite: CGFloat = 0
        var wColor: CGFloat = 0

        for index in colors.indices {
            let c = colors[index]
            let rankWeight = shares[index]

            if c.b < 0.12 { wBlack += rankWeight }
            if c.b > 0.90 { wWhite += rankWeight }
            if c.s > 0.22 && c.b >= 0.12 && c.b <= 0.90 { wColor += rankWeight }

            let isNeutral = c.s < 0.14 || c.b < 0.12 || c.b > 0.90
            if isNeutral { neutralCandidateIndices.insert(index) }

            let chroma = c.s * min(c.b, 1 - c.b)
            if c.s >= 0.18 && c.b > 0.10 && c.b < 0.92 && chroma >= 0.08 {
                let midBBoost = clamp(1 - abs(c.b - 0.55) / 0.55, min: 0, max: 1)
                let saliency = pow(c.s, 1.35) * (0.65 + 0.35 * midBBoost)
                let score = rankWeight * (1 + 2.2 * saliency)
                colorCandidates.append(
                    ScoredColor(index: index, color: c, score: score, saliency: saliency)
                )
            }
        }

        if !colorCandidates.isEmpty {
            for candidate in colorCandidates {
                neutralCandidateIndices.insert(candidate.index)
            }
        }

        var coverLumaNum: CGFloat = 0
        var coverLumaDen: CGFloat = 0
        for index in colors.indices {
            guard neutralCandidateIndices.contains(index) || neutralCandidateIndices.isEmpty else {
                continue
            }
            let w = shares[index]
            coverLumaNum += clamp(colors[index].b, min: 0.06, max: 0.96) * w
            coverLumaDen += w
        }
        if coverLumaDen <= 0 {
            for index in colors.indices {
                let w = shares[index]
                coverLumaNum += clamp(colors[index].b, min: 0.06, max: 0.96) * w
                coverLumaDen += w
            }
        }
        let coverLuma = clamp(coverLumaNum / max(0.0001, coverLumaDen), min: 0.06, max: 0.96)

        var rankLumaNum: CGFloat = 0
        var rankLumaDen: CGFloat = 0
        for index in colors.indices {
            let w = shares[index]
            rankLumaNum += clamp(colors[index].b, min: 0.03, max: 0.96) * w
            rankLumaDen += w
        }
        let rankLuma = rankLumaNum / max(0.0001, rankLumaDen)
        let imageCoverLuma = clamp(
            0.75 * clamp(areaDominantB, min: 0.03, max: 0.96) + 0.25 * rankLuma,
            min: 0.03,
            max: 0.96
        )
        let veryDarkCover = imageCoverLuma < 0.22

        var grayWeightSum: CGFloat = 0
        var totalWeight: CGFloat = 0
        for index in colors.indices {
            let c = colors[index]
            let chroma = c.s * min(c.b, 1 - c.b)
            let grayLike = c.s < 0.14 || chroma < 0.06
            let extreme = c.b < 0.12 || c.b > 0.92
            let weight: CGFloat = (extreme ? 1.8 : 1.0) * shares[index]
            totalWeight += weight
            if grayLike { grayWeightSum += weight }
        }
        let grayScore = totalWeight > 0 ? grayWeightSum / totalWeight : 0

        var clusterCentersRaw: [HueCluster] = []
        var clusterScores: [CGFloat] = []
        var clusterMaxMember: [ScoredColor] = []
        for candidate in colorCandidates {
            if let nearest = nearestClusterIndex(for: candidate.color.h, in: clusterCentersRaw),
                hueDistance(clusterCentersRaw[nearest].centerHue, candidate.color.h) <= 25
            {
                clusterCentersRaw[nearest].add(hue: candidate.color.h, weight: candidate.score)
                clusterScores[nearest] += candidate.score
                if candidate.score > clusterMaxMember[nearest].score {
                    clusterMaxMember[nearest] = candidate
                }
            } else {
                clusterCentersRaw.append(
                    HueCluster(hue: candidate.color.h, weight: candidate.score))
                clusterScores.append(candidate.score)
                clusterMaxMember.append(candidate)
            }
        }

        let sortedClusterIndices = clusterScores.indices.sorted {
            clusterScores[$0] > clusterScores[$1]
        }
        let topClusterRawTotal = max(
            0.0001, sortedClusterIndices.map { clusterScores[$0] }.reduce(0, +))
        let topClusters = sortedClusterIndices.prefix(3).map { idx in
            PaletteStats.HueWeight(
                hue: normalizeHue(clusterCentersRaw[idx].centerHue),
                weight: clusterScores[idx] / topClusterRawTotal
            )
        }
        let clusterCenters = clusterCentersRaw.map(\.centerHue)
        let clusterCount = clusterCentersRaw.count
        let clusterEvenness = entropyNormalized(
            sortedClusterIndices.map { clusterScores[$0] / topClusterRawTotal }
        )

        let primaryClusterHue = sortedClusterIndices.first.map {
            normalizeHue(clusterCentersRaw[$0].centerHue)
        }
        let accentClusterHue: CGFloat?
        let secondClusterHasVivid: Bool
        if sortedClusterIndices.count >= 2 {
            let w0 = clusterScores[sortedClusterIndices[0]]
            let w1 = clusterScores[sortedClusterIndices[1]]
            secondClusterHasVivid = clusterMaxMember[sortedClusterIndices[1]].color.s >= 0.45
            accentClusterHue =
                (w1 >= 0.35 * w0)
                ? normalizeHue(clusterCentersRaw[sortedClusterIndices[1]].centerHue) : nil
        } else {
            secondClusterHasVivid = false
            accentClusterHue = nil
        }

        let maxColorCandidateScore = colorCandidates.map(\.score).max() ?? 0
        let bestSalientHue = colorCandidates.max(by: { $0.score < $1.score })?.color.h

        var salientRaw = colorCandidates.sorted(by: { $0.score > $1.score })
        if salientRaw.isEmpty {
            salientRaw = colors.enumerated().map { index, color in
                let s = saliencyScore(color)
                return ScoredColor(
                    index: index, color: color, score: shares[index] * (1 + 1.8 * s), saliency: s)
            }.sorted(by: { $0.score > $1.score })
        }
        let salientTotal = max(0.0001, salientRaw.map(\.score).reduce(0, +))
        var salientOut: [PaletteStats.SalientHue] = []
        for candidate in salientRaw {
            let h = normalizeHue(candidate.color.h)
            if salientOut.contains(where: { hueDistance($0.hue, h) < 14 }) { continue }
            salientOut.append(.init(hue: h, weight: candidate.score / salientTotal))
            if salientOut.count >= 3 { break }
        }

        var injectAccentHues: [CGFloat] = []
        for clusterIndex in sortedClusterIndices.prefix(3) {
            let representative = clusterMaxMember[clusterIndex]
            if representative.color.s >= 0.55 {
                injectAccentHues.append(normalizeHue(representative.color.h))
            }
            if injectAccentHues.count >= 2 { break }
        }
        if matchedAvgS < 0.16 {
            injectAccentHues.removeAll()
        }

        let coverKind: CoverKind
        if colorCandidates.isEmpty && wColor < 0.10 && matchedAvgS < 0.12 {
            coverKind = .grayscaleTrue
        } else if (wBlack + wWhite) > 0.65 && wColor >= 0.10 {
            coverKind = .mostlyBWWithColor
        } else if clusterCount >= 3 && clusterEvenness >= 0.62 && matchedAvgS >= 0.24 {
            coverKind = .richDistributed
        } else if matchedAvgS < 0.20 {
            coverKind = .lowSatColor
        } else {
            coverKind = .normal
        }

        let isGrayscaleCover = coverKind == .grayscaleTrue
        let isNearGray = coverKind == .lowSatColor && grayScore >= 0.55 && colorCandidates.isEmpty
        let lowSatColorCover = coverKind == .lowSatColor

        let satBoost: CGFloat
        let briBoost: CGFloat
        if lowSatColorCover {
            // Only mildly boost low-sat covers; ultra-low sat should not be pushed vivid.
            let t = clamp((matchedAvgS - 0.05) / 0.18, min: 0, max: 1)
            satBoost = lerp(0.88, 1.24, t: t)
            briBoost = lerp(1.02, 1.10, t: t)
        } else if coverKind == .mostlyBWWithColor {
            satBoost = 1.35
            briBoost = 1.12
        } else {
            satBoost = 1.0
            briBoost = 1.0
        }

        let complexity: ColorComplexityLevel
        if coverKind == .grayscaleTrue {
            complexity = .monochrome
        } else if coverKind == .lowSatColor {
            complexity = .low
        } else if coverKind == .richDistributed {
            complexity = .high
        } else if matchedAvgS < 0.26 || clusterCount <= 2 {
            complexity = .medium
        } else {
            complexity = .high
        }

        let dominantIndex = shares.indices.max(by: { shares[$0] < shares[$1] }) ?? 0
        let dominantColor = colors[dominantIndex]
        let dominantHue = primaryClusterHue ?? dominantColor.h
        let dominantS =
            colorCandidates.first(where: { hueDistance($0.color.h, dominantHue) < 12 })?.color.s
            ?? dominantColor.s
        let dominantShare = shares[dominantIndex]
        let accentShare = (topClusters.count >= 2) ? topClusters[1].weight : 0
        let accentStrength = clamp(
            accentShare / max(0.0001, topClusters.first?.weight ?? 1),
            min: 0,
            max: 1
        )
        let forcedAccentInMostlyBW =
            coverKind == .mostlyBWWithColor
            && colorCandidates.contains {
                $0.color.s >= 0.40 && hueDistance($0.color.h, dominantHue) > 12
            }
        let accentEnabled =
            (topClusters.count >= 2
                && topClusters[1].weight >= 0.28 * max(0.0001, topClusters[0].weight)
                && secondClusterHasVivid)
            || forcedAccentInMostlyBW

        var meanX: CGFloat = 0
        var meanY: CGFloat = 0
        if !colorCandidates.isEmpty {
            let total = max(0.0001, colorCandidates.map(\.score).reduce(0, +))
            for candidate in colorCandidates {
                let w = candidate.score / total
                let radians = deg2rad(candidate.color.h)
                meanX += cos(radians) * w
                meanY += sin(radians) * w
            }
        } else {
            for index in colors.indices {
                let w = shares[index]
                let radians = deg2rad(colors[index].h)
                meanX += cos(radians) * w
                meanY += sin(radians) * w
            }
        }
        let resultant = max(0, min(1, sqrt(meanX * meanX + meanY * meanY)))
        let variance = 1 - resultant
        let stdRadians = resultant > 0 ? sqrt(max(0, -2 * log(resultant))) : CGFloat.pi
        let stdDegrees = rad2deg(stdRadians)

        return PaletteStats(
            avgS: avgS,
            matchedAvgS: matchedAvgS,
            hueSpread: hueSpread,
            circularVariance: variance,
            circularStdDegrees: stdDegrees,
            clusterCenters: clusterCenters,
            clusterCount: max(1, clusterCount),
            dominantHue: normalizeHue(dominantHue),
            areaDominantHue: areaDominantHue,
            dominantS: dominantS,
            areaDominantS: areaDominantS,
            areaDominantB: areaDominantB,
            dominantShare: dominantShare,
            accentHue: accentEnabled ? accentClusterHue : nil,
            accentShare: accentShare,
            secondAccentHue: accentEnabled ? accentClusterHue : nil,
            grayScore: grayScore,
            isGrayscaleCover: isGrayscaleCover,
            isNearGray: isNearGray,
            lowSatColorCover: lowSatColorCover,
            lowSatSatBoost: satBoost,
            lowSatBriBoost: briBoost,
            coverKind: coverKind,
            veryDarkCover: veryDarkCover,
            wBlack: wBlack,
            wWhite: wWhite,
            wColor: wColor,
            coverLuma: coverLuma,
            imageCoverLuma: imageCoverLuma,
            accentEnabled: accentEnabled,
            accentStrength: accentStrength,
            topSalientHues: salientOut,
            topClusters: topClusters,
            primaryClusterHue: primaryClusterHue,
            accentClusterHue: accentClusterHue,
            maxColorCandidateScore: maxColorCandidateScore,
            bestSalientHue: bestSalientHue,
            injectAccentHues: injectAccentHues,
            evenness: clusterEvenness,
            complexity: complexity
        )
    }

    fileprivate nonisolated static func nearestClusterIndex(
        for hue: CGFloat, in clusters: [HueCluster]
    ) -> Int? {
        guard !clusters.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = hueDistance(hue, clusters[0].centerHue)
        for index in clusters.indices.dropFirst() {
            let distance = hueDistance(hue, clusters[index].centerHue)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    fileprivate nonisolated static func inferredShares(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let raw: [CGFloat]
        if count <= 4 {
            let base: [CGFloat] = [0.48, 0.26, 0.16, 0.10]
            raw = Array(base.prefix(count))
        } else {
            var values: [CGFloat] = [0.40, 0.25, 0.18, 0.12]
            var tail: CGFloat = 0.05
            while values.count < count {
                values.append(tail)
                tail *= 0.70
            }
            raw = values
        }
        let total = raw.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1 / CGFloat(count), count: count)
        }
        return raw.map { $0 / total }
    }

    fileprivate nonisolated static func saliencyScore(_ color: HSBColor) -> CGFloat {
        let midBBoost = clamp(1 - abs(color.b - 0.55) / 0.55, min: 0, max: 1)
        return pow(color.s, 1.2) * (0.6 + 0.4 * midBBoost)
    }

    fileprivate nonisolated static func entropyNormalized(_ probabilities: [CGFloat]) -> CGFloat {
        let positive = probabilities.filter { $0 > 0.0001 }
        guard positive.count > 1 else { return 0 }
        let entropy = positive.reduce(CGFloat(0)) { partial, p in
            partial - p * log(p)
        }
        return entropy / log(CGFloat(positive.count))
    }

    fileprivate nonisolated static func lumaTarget(coverLuma: CGFloat, isDark: Bool) -> CGFloat {
        if isDark {
            return clamp(0.18 + 0.70 * coverLuma, min: 0.10, max: 0.62)
        }
        return clamp(0.55 + 0.55 * coverLuma, min: 0.65, max: 0.90)
    }

    fileprivate nonisolated static func lumaBlendK(coverKind: CoverKind) -> CGFloat {
        switch coverKind {
        case .mostlyBWWithColor:
            return 0.70
        case .grayscaleTrue:
            return 0.45
        default:
            return 0.55
        }
    }

    fileprivate nonisolated static func tierRanges(
        isDark: Bool,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        lowSatColorCover: Bool,
        coverKind: CoverKind,
        avgS: CGFloat,
        coverLuma: CGFloat,
        veryDarkCover: Bool,
        areaDominantS: CGFloat,
        areaDominantB: CGFloat
    ) -> TierRanges {
        var bgB: ClosedRange<CGFloat>
        var fgB: ClosedRange<CGFloat>
        var dotB: ClosedRange<CGFloat>
        var bgS: ClosedRange<CGFloat>
        var fgS: ClosedRange<CGFloat>
        var dotS: ClosedRange<CGFloat>

        if isDark {
            bgB = 0.24...0.40
            fgB = 0.44...0.64
            dotB = 0.56...0.82
            bgS = 0.24...0.50
            fgS = 0.34...0.72
            dotS = 0.30...0.62

            if veryDarkCover || coverLuma < 0.22 {
                bgB = 0.08...0.22
                fgB = 0.30...0.52
                dotB = 0.46...0.70
                bgS = 0.08...0.26
            }
            if coverLuma < 0.34 && areaDominantB < 0.30 {
                bgB = 0.08...0.18
                fgB = 0.28...0.50
                dotB = 0.42...0.66
                bgS = makeRange(lower: 0.06, upper: min(bgS.upperBound, 0.20))
            }
            if areaDominantS < 0.14 {
                bgS = makeRange(lower: 0.08, upper: min(bgS.upperBound, 0.24))
            }
        } else {
            bgB = 0.78...0.85
            fgB = 0.66...0.78
            dotB = 0.50...0.62
            bgS = 0.12...0.36
            fgS = 0.26...0.60
            dotS = 0.20...0.56
        }

        if complexity == .monochrome {
            bgS = makeRange(lower: bgS.lowerBound * 0.60, upper: bgS.upperBound * 0.50)
            fgS = makeRange(lower: fgS.lowerBound * 0.60, upper: fgS.upperBound * 0.60)
            dotS = makeRange(lower: dotS.lowerBound * 0.60, upper: dotS.upperBound * 0.60)
        } else if complexity == .low || isNearGray || coverKind == .lowSatColor {
            fgS = makeRange(lower: fgS.lowerBound * 0.88, upper: fgS.upperBound * 0.92)
            dotS = makeRange(lower: dotS.lowerBound * 0.90, upper: dotS.upperBound * 0.94)
            bgS = makeRange(lower: bgS.lowerBound, upper: bgS.upperBound * 0.92)
        }

        if isNearGray {
            bgS = makeRange(lower: bgS.lowerBound, upper: min(bgS.upperBound, 0.20))
            fgS = makeRange(lower: fgS.lowerBound, upper: min(fgS.upperBound, 0.35))
            dotS = makeRange(lower: dotS.lowerBound, upper: min(dotS.upperBound, 0.35))
        }

        if lowSatColorCover {
            fgS = makeRange(lower: fgS.lowerBound, upper: min(0.66, fgS.upperBound * 1.20))
            dotS = makeRange(lower: dotS.lowerBound, upper: min(0.70, dotS.upperBound * 1.22))
            bgS = makeRange(
                lower: bgS.lowerBound, upper: min(isDark ? 0.42 : 0.36, bgS.upperBound * 1.10))

            fgB = makeRange(
                lower: min(1, fgB.lowerBound * 1.05),
                upper: min(1, fgB.upperBound * 1.10)
            )
            dotB = makeRange(
                lower: min(1, dotB.lowerBound * 1.05),
                upper: min(1, dotB.upperBound * 1.12)
            )
        }

        let ultraLowSatCover =
            lowSatColorCover
            && avgS < 0.10
            && areaDominantS < 0.12
            && coverKind != .mostlyBWWithColor
        if ultraLowSatCover {
            bgS = makeRange(
                lower: max(bgS.lowerBound, isDark ? 0.04 : 0.03),
                upper: min(bgS.upperBound, isDark ? 0.16 : 0.12)
            )
            fgS = makeRange(
                lower: max(fgS.lowerBound, isDark ? 0.10 : 0.08),
                upper: min(fgS.upperBound, isDark ? 0.30 : 0.24)
            )
            dotS = makeRange(
                lower: max(dotS.lowerBound, isDark ? 0.12 : 0.09),
                upper: min(dotS.upperBound, isDark ? 0.32 : 0.26)
            )
        }

        // Keep hard separation: background saturation stays below foreground.
        let bgUpper = bgS.upperBound
        let fgLower = min(fgS.upperBound, max(fgS.lowerBound, bgUpper + 0.06))
        bgS = makeRange(lower: bgS.lowerBound, upper: bgUpper)
        fgS = makeRange(lower: fgLower, upper: fgS.upperBound)

        return TierRanges(bgB: bgB, fgB: fgB, dotB: dotB, bgS: bgS, fgS: fgS, dotS: dotS)
    }

    fileprivate nonisolated static func makeRange(lower: CGFloat, upper: CGFloat) -> ClosedRange<
        CGFloat
    > {
        if lower <= upper {
            return lower...upper
        }
        return upper...upper
    }

    fileprivate nonisolated static func ranges(for kind: ElementKind, palette: HarmonizedPalette)
        -> (b: ClosedRange<CGFloat>, s: ClosedRange<CGFloat>)
    {
        switch kind {
        case .background:
            return (palette.bgBRange, palette.bgSRange)
        case .shape:
            return (palette.fgBRange, palette.fgSRange)
        case .dot:
            return (palette.dotBRange, palette.dotSRange)
        }
    }

    fileprivate nonisolated static func makeGrayscalePalette(
        stats: PaletteStats,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> HarmonizedPalette {
        let tier = grayscaleTierRanges(isDark: isDark)
        let safeHueBase: CGFloat = 215
        let bgOffsets: [CGFloat] = [-6, 0, 6]
        let shapeOffsets: [CGFloat] = [0, -4, 4, 6]
        let shapeCount = stats.grayScore > 0.86 ? 3 : 4
        let bgSValues: [CGFloat] = [0.01, 0.02, 0.04]
        let bgBOffsetsDark: [CGFloat] = [-0.03, -0.01, 0.03]
        let bgBOffsetsLight: [CGFloat] = [-0.02, 0.0, 0.02]
        let shapeBOffsets: [CGFloat] = [-0.03, -0.01, 0.01, 0.03]

        var bgStops = bgOffsets.enumerated().map { index, offset -> HSBColor in
            sanitize(
                HSBColor(
                    h: normalizeHue(safeHueBase + offset),
                    s: bgSValues[index],
                    b: clamp(
                        midpoint(tier.bgB)
                            + (isDark ? bgBOffsetsDark[index] : bgBOffsetsLight[index]),
                        min: tier.bgB.lowerBound,
                        max: tier.bgB.upperBound
                    ),
                    a: 1
                ),
                kind: .background,
                bRange: tier.bgB,
                sRange: tier.bgS,
                complexity: .monochrome,
                isNearGray: false,
                isDark: isDark,
                triggered: &triggered
            )
        }

        var shapePool: [HSBColor] = []
        for index in 0..<shapeCount {
            let safe = sanitize(
                HSBColor(
                    h: normalizeHue(safeHueBase + shapeOffsets[index]),
                    s: clamp(
                        CGFloat(0.06) + CGFloat(index) * 0.015, min: tier.fgS.lowerBound,
                        max: tier.fgS.upperBound),
                    b: clamp(
                        midpoint(tier.fgB) + shapeBOffsets[index],
                        min: tier.fgB.lowerBound,
                        max: tier.fgB.upperBound
                    ),
                    a: 1
                ),
                kind: .shape,
                bRange: tier.fgB,
                sRange: tier.fgS,
                complexity: .monochrome,
                isNearGray: false,
                isDark: isDark,
                triggered: &triggered
            )
            shapePool.append(safe)
        }

        var dotBase = sanitize(
            HSBColor(
                h: normalizeHue(safeHueBase + 2),
                s: min(0.10, tier.dotS.upperBound),
                b: midpoint(tier.dotB),
                a: 1
            ),
            kind: .dot,
            bRange: tier.dotB,
            sRange: tier.dotS,
            complexity: .monochrome,
            isNearGray: false,
            isDark: isDark,
            triggered: &triggered
        )

        enforceSaturationGap(
            bgStops: &bgStops,
            shapePool: &shapePool,
            tier: tier,
            complexity: .monochrome,
            isNearGray: false,
            isDark: isDark,
            triggered: &triggered
        )
        enforceBrightnessHierarchy(
            bgStops: &bgStops,
            shapePool: &shapePool,
            dotBase: &dotBase,
            tier: tier,
            complexity: .monochrome,
            isNearGray: false,
            isDark: isDark,
            triggered: &triggered
        )

        return HarmonizedPalette(
            primaryHue: normalizeHue(safeHueBase),
            imageHue: normalizeHue(stats.areaDominantHue),
            isDark: isDark,
            complexity: .monochrome,
            grayScore: stats.grayScore,
            isGrayscaleCover: true,
            isNearGray: false,
            coverLuma: stats.coverLuma,
            imageCoverLuma: stats.imageCoverLuma,
            coverAvgS: stats.matchedAvgS,
            areaDominantS: stats.areaDominantS,
            areaDominantB: stats.areaDominantB,
            accentHue: nil,
            accentStrength: 0,
            accentEnabled: false,
            bgStops: bgStops.map(toCGColor(_:)),
            bgVariants: [bgStops.map(toCGColor(_:))],
            shapePool: shapePool.map(toCGColor(_:)),
            dotBase: toCGColor(dotBase),
            bgBRange: tier.bgB,
            fgBRange: tier.fgB,
            dotBRange: tier.dotB,
            bgSRange: tier.bgS,
            fgSRange: tier.fgS,
            dotSRange: tier.dotS
        )
    }

    fileprivate nonisolated static func grayscaleTierRanges(isDark: Bool) -> TierRanges {
        if isDark {
            return TierRanges(
                bgB: 0.24...0.36,
                fgB: 0.48...0.62,
                dotB: 0.64...0.82,
                bgS: 0.01...0.04,
                fgS: 0.04...0.12,
                dotS: 0.05...0.14
            )
        }
        return TierRanges(
            bgB: 0.80...0.85,
            fgB: 0.68...0.78,
            dotB: 0.52...0.62,
            bgS: 0.01...0.04,
            fgS: 0.04...0.12,
            dotS: 0.05...0.14
        )
    }

    fileprivate nonisolated static func makeHueFamily(
        primaryHue: CGFloat,
        complexity: ColorComplexityLevel,
        clusterCenters: [CGFloat],
        isNearGray: Bool,
        triggered: inout Set<RiskFlag>
    ) -> [CGFloat] {
        var family: [CGFloat] = [primaryHue]

        if isNearGray {
            family += [
                primaryHue - 6, primaryHue + 6,
                primaryHue - 12, primaryHue + 12,
                primaryHue - 24, primaryHue + 24,
                primaryHue - 35, primaryHue + 35,
            ]
            let nearGrayFamily = dedupeHues(family).filter { hueDistance($0, primaryHue) <= 45 }
            return nearGrayFamily.isEmpty ? [normalizeHue(primaryHue)] : nearGrayFamily
        }

        switch complexity {
        case .monochrome:
            family += [primaryHue - 6, primaryHue + 6]

        case .low:
            family += [primaryHue - 12, primaryHue + 12, primaryHue - 18, primaryHue + 18]

        case .medium:
            family += [primaryHue - 12, primaryHue + 12, primaryHue - 22, primaryHue + 22]
            let farCandidates =
                clusterCenters
                .map(normalizeHue)
                .filter {
                    let d = hueDistance($0, primaryHue)
                    return d > 28 && d <= 70
                }
            if let far = farCandidates.max(by: {
                hueDistance($0, primaryHue) < hueDistance($1, primaryHue)
            }) {
                family.append(far)
            }

        case .high:
            family += [primaryHue - 12, primaryHue + 12, primaryHue - 22, primaryHue + 22]
            let splitCandidates = [primaryHue + 150, primaryHue + 210].map(normalizeHue)
                .filter { !inRange($0, 92, 140) && !inRange($0, 45, 78) }
            if let split = splitCandidates.min(by: {
                riskPenalty(h: $0, s: 0.45, b: 0.52) < riskPenalty(h: $1, s: 0.45, b: 0.52)
            }) {
                family.append(split)
            }
        }

        var unique = dedupeHues(family)

        if complexity != .high {
            unique = unique.filter { hueDistance($0, primaryHue) <= 70 }
        }

        // High complexity still avoids explicit ugly zones.
        unique = unique.filter {
            !(inRange($0, 92, 140) && hueDistance($0, primaryHue) > 50)
                && !(inRange($0, 45, 78) && hueDistance($0, primaryHue) > 50)
        }

        if unique.isEmpty {
            triggered.insert(.greenDanger)
            return [normalizeHue(primaryHue)]
        }
        return unique
    }

    fileprivate nonisolated static func makeBackgroundStops(
        primaryHue: CGFloat,
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        coverKind: CoverKind,
        lowSatColorCover: Bool,
        satBoost: CGFloat,
        briBoost: CGFloat,
        lumaTarget: CGFloat,
        lumaK: CGFloat,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> [HSBColor] {
        let hueOffsets: [CGFloat]
        if isNearGray {
            hueOffsets = [-2, 0, 2]
        } else {
            switch complexity {
            case .monochrome:
                hueOffsets = [-2, 0, 2]
            case .low:
                hueOffsets = [-3, 0, 3]
            case .medium:
                hueOffsets = [-4, 0, 4]
            case .high:
                hueOffsets = [-5, 0, 5]
            }
        }

        let tierMid = midpoint(tier.bgB)
        let remapped = lerp(tierMid, lumaTarget, t: lumaK)
        var bMid = clamp(remapped, min: tier.bgB.lowerBound, max: tier.bgB.upperBound)
        if !isDark {
            bMid = min(0.85, bMid)
        }
        let sMid = midpoint(tier.bgS)
        let bOffsets: [CGFloat] = isDark ? [-0.04, -0.01, 0.03] : [-0.02, 0.00, 0.03]
        let sOffsets: [CGFloat] = [-0.03, -0.01, 0.01]

        return hueOffsets.indices.map { index in
            let hue = normalizeHue(primaryHue + hueOffsets[index])
            var targetB = clamp(
                bMid + bOffsets[index], min: tier.bgB.lowerBound, max: tier.bgB.upperBound)
            var targetS = clamp(
                sMid + sOffsets[index], min: tier.bgS.lowerBound, max: tier.bgS.upperBound)
            if lowSatColorCover {
                targetS = clamp(
                    targetS * min(1.24, satBoost), min: tier.bgS.lowerBound,
                    max: tier.bgS.upperBound)
                targetB = clamp(
                    targetB * min(1.08, briBoost), min: tier.bgB.lowerBound,
                    max: tier.bgB.upperBound)
            } else if coverKind == .mostlyBWWithColor {
                targetS = clamp(targetS * 1.10, min: tier.bgS.lowerBound, max: tier.bgS.upperBound)
            }
            return sanitize(
                HSBColor(h: hue, s: targetS, b: targetB, a: 1),
                kind: .background,
                bRange: tier.bgB,
                sRange: tier.bgS,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
        }
    }

    fileprivate nonisolated static func makeBackgroundVariants(
        candidates: [HSBColor],
        shapePool: [HSBColor],
        baseStops: [HSBColor],
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        avgS: CGFloat,
        hueSpread: CGFloat,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> [[HSBColor]] {
        let variantCount: Int
        let stopCounts: [Int]
        if avgS < 0.16 || hueSpread < 22 {
            variantCount = 1
            stopCounts = [(avgS < 0.10 || hueSpread < 12) ? 1 : 2]
        } else if avgS < 0.42 {
            variantCount = 2
            stopCounts = [2, 3]
        } else {
            variantCount = 3
            stopCounts = [3, 4, 5]
        }

        let sourcePool = (candidates.isEmpty ? shapePool : candidates).ifEmpty(baseStops)
        let shares = inferredShares(count: sourcePool.count)
        struct BgCandidate {
            let color: HSBColor
            let weight: CGFloat
        }
        var weighted: [BgCandidate] = sourcePool.enumerated().map { index, color in
            let saliency = saliencyScore(color)
            return BgCandidate(
                color: normalizeCandidateColor(color),
                weight: shares[index] * (0.85 + 0.30 * saliency)
            )
        }
        weighted.sort { $0.weight > $1.weight }
        if weighted.isEmpty {
            return [baseStops]
        }

        let shapeMeanS =
            shapePool.isEmpty
            ? midpoint(tier.fgS)
            : shapePool.map(\.s).reduce(0, +) / CGFloat(shapePool.count)
        let desiredGapMin: CGFloat = isNearGray ? 0.12 : 0.10
        let desiredGapMax: CGFloat = isNearGray ? 0.08 : 0.06
        let desiredBgLower = clamp(
            shapeMeanS - desiredGapMin, min: tier.bgS.lowerBound, max: tier.bgS.upperBound)
        let desiredBgUpper = clamp(
            shapeMeanS - desiredGapMax, min: desiredBgLower, max: tier.bgS.upperBound)

        let bgUpperCap = min(
            tier.bgS.upperBound,
            max(tier.bgS.lowerBound, tier.fgS.lowerBound - 0.08)
        )
        var variantSRange = makeRange(
            lower: max(tier.bgS.lowerBound, desiredBgLower),
            upper: min(bgUpperCap, desiredBgUpper)
        )
        if avgS >= 0.10 && avgS < 0.22 {
            let colorFloor = clamp(
                (isDark ? 0.10 : 0.08) + avgS * (isDark ? 0.75 : 0.65),
                min: tier.bgS.lowerBound,
                max: min(bgUpperCap, tier.bgS.upperBound)
            )
            let raisedLower = max(variantSRange.lowerBound, colorFloor)
            let raisedUpper = min(bgUpperCap, max(variantSRange.upperBound, raisedLower + 0.06))
            variantSRange = makeRange(lower: raisedLower, upper: raisedUpper)
        }

        func pickStops(count: Int, variantIndex: Int) -> [HSBColor] {
            guard count > 0 else { return [] }
            var selectedIndices: [Int] = []
            let start = min(weighted.count - 1, variantIndex % weighted.count)
            selectedIndices.append(start)

            while selectedIndices.count < min(count, weighted.count) {
                var best: Int?
                var bestScore = -CGFloat.greatestFiniteMagnitude
                for idx in weighted.indices where !selectedIndices.contains(idx) {
                    let hue = weighted[idx].color.h
                    let minDist =
                        selectedIndices.map { hueDistance(hue, weighted[$0].color.h) }.min() ?? 180
                    guard minDist >= 18 else { continue }
                    let score = minDist * 0.72 + weighted[idx].weight * 120 * 0.28
                    if score > bestScore {
                        bestScore = score
                        best = idx
                    }
                }
                if let best {
                    selectedIndices.append(best)
                } else if let fallback = weighted.indices.first(where: {
                    !selectedIndices.contains($0)
                }) {
                    selectedIndices.append(fallback)
                } else {
                    break
                }
            }

            while selectedIndices.count < count {
                selectedIndices.append(
                    selectedIndices[selectedIndices.count % max(1, selectedIndices.count)])
            }

            return selectedIndices.map { weighted[$0].color }
        }

        var variants: [[HSBColor]] = []
        variants.reserveCapacity(variantCount)
        let baseBMids = baseStops.ifEmpty([
            HSBColor(
                h: weighted[0].color.h,
                s: midpoint(variantSRange),
                b: midpoint(tier.bgB),
                a: 1
            )
        ])

        for variantIndex in 0..<variantCount {
            let stopCount = stopCounts[min(stopCounts.count - 1, variantIndex)]
            let selected = pickStops(count: stopCount, variantIndex: variantIndex)
            var variantStops: [HSBColor] = []
            for (idx, selectedColor) in selected.enumerated() {
                let baseRef = baseBMids[min(idx, baseBMids.count - 1)]
                let satScale: CGFloat
                if avgS < 0.06 || (avgS < 0.09 && isNearGray) {
                    satScale = 0.40
                } else if avgS < 0.12 {
                    satScale = 0.70
                } else if avgS < 0.22 {
                    satScale = 0.94
                } else if avgS < 0.42 || isNearGray {
                    satScale = 0.86
                } else {
                    satScale = 0.90
                }
                let targetS = clamp(
                    selectedColor.s * satScale, min: variantSRange.lowerBound,
                    max: variantSRange.upperBound)
                let targetB = clamp(
                    lerp(baseRef.b, selectedColor.b, t: 0.30),
                    min: tier.bgB.lowerBound,
                    max: tier.bgB.upperBound
                )
                let stop = sanitize(
                    HSBColor(h: selectedColor.h, s: targetS, b: targetB, a: 1),
                    kind: .background,
                    bRange: tier.bgB,
                    sRange: variantSRange,
                    complexity: complexity,
                    isNearGray: isNearGray,
                    isDark: isDark,
                    triggered: &triggered
                )
                variantStops.append(stop)
            }
            variants.append(variantStops)
        }

        if variants.isEmpty {
            return [baseStops]
        }
        let stopCountsLog = variants.map { String($0.count) }.joined(separator: ",")
        print(
            "[BKColorEngine] bgVariants count=\(variants.count) stops=[\(stopCountsLog)] avgS=\(f3(avgS)) hueSpread=\(f1(hueSpread)) bgSRange=\(f3(variantSRange.lowerBound))...\(f3(variantSRange.upperBound)) shapeMeanS=\(f3(shapeMeanS))"
        )
        return variants
    }

    fileprivate nonisolated static func makeShapePool(
        primaryHue: CGFloat,
        dominantHue: CGFloat,
        dominantS: CGFloat,
        clusterCount: Int,
        hueFamily: [CGFloat],
        accentHue: CGFloat?,
        accentShare: CGFloat,
        secondAccentHue: CGFloat?,
        accentEnabled: Bool,
        accentStrength: CGFloat,
        salientHues: [PaletteStats.SalientHue],
        topClusters: [PaletteStats.HueWeight],
        injectAccentHues: [CGFloat],
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        coverKind: CoverKind,
        lowSatColorCover: Bool,
        satBoost: CGFloat,
        briBoost: CGFloat,
        lumaTarget: CGFloat,
        lumaK: CGFloat,
        isDark: Bool,
        injectedAccentCount: inout Int,
        triggered: inout Set<RiskFlag>
    ) -> [HSBColor] {
        let targetCount: Int
        if coverKind == .richDistributed {
            targetCount = 10
        } else if isNearGray {
            targetCount = clusterCount > 1 ? 6 : 4
        } else {
            switch complexity {
            case .monochrome:
                targetCount = dominantS > 0.10 ? 4 : 3
            case .low:
                targetCount = lowSatColorCover ? 9 : 6
            case .medium:
                targetCount = 8
            case .high:
                targetCount = 10
            }
        }

        var hueQueue: [CGFloat] = []
        let offsetsPrimary: [CGFloat] = [0, 6, -6, 10, -10, 14, -14, 4, -4, 8]
        let offsetsAccent: [CGFloat] = [0, 5, -5, 9, -9, 3, -3]
        let offsetsExpand: [CGFloat] = [0, 12, -12, 18, -18, 26, -26, 32, -32]

        let primaryBase = topClusters.first?.hue ?? dominantHue
        let clusterAccentBase = secondAccentHue ?? accentHue ?? topClusters.dropFirst().first?.hue

        let primaryCount = max(1, Int(round(Double(targetCount) * 0.65)))
        var accentCount = 0
        if accentEnabled {
            let ratio = clamp(0.22 + 0.18 * accentStrength, min: 0.22, max: 0.40)
            accentCount = max(2, Int(round(CGFloat(targetCount) * ratio)))
        }
        if primaryCount + accentCount > targetCount {
            accentCount = max(0, targetCount - primaryCount)
        }
        let expandedCount = max(0, targetCount - primaryCount - accentCount)

        for i in 0..<primaryCount {
            let raw = normalizeHue(primaryBase + offsetsPrimary[i % offsetsPrimary.count])
            hueQueue.append(clampHueDistance(raw, around: primaryBase, maxDistance: 18))
        }

        if let accentBase = clusterAccentBase, accentCount > 0 {
            let boundedAccent = clampHueDistance(accentBase, around: primaryBase, maxDistance: 75)
            for i in 0..<accentCount {
                let raw = normalizeHue(boundedAccent + offsetsAccent[i % offsetsAccent.count])
                hueQueue.append(clampHueDistance(raw, around: boundedAccent, maxDistance: 18))
            }
        }

        for i in 0..<expandedCount {
            let raw = normalizeHue(primaryBase + offsetsExpand[i % offsetsExpand.count])
            hueQueue.append(clampHueDistance(raw, around: primaryBase, maxDistance: 35))
        }

        while hueQueue.count < targetCount {
            hueQueue.append(normalizeHue(primaryBase))
        }

        let injectCount = min(2, injectAccentHues.count, targetCount)
        injectedAccentCount = injectCount
        for i in 0..<injectCount {
            let injectHue = injectAccentHues[i]
            let jitter: CGFloat = i == 0 ? -4 : 4
            hueQueue[i] = normalizeHue(injectHue + jitter)
        }

        let remapped = lerp(midpoint(tier.fgB), lumaTarget, t: lumaK)
        let bMid = clamp(remapped, min: tier.fgB.lowerBound, max: tier.fgB.upperBound)
        let sMid = midpoint(tier.fgS)
        let bOffsets: [CGFloat] = [-0.05, -0.03, -0.01, 0.00, 0.02, 0.03, 0.04, -0.02, 0.01, -0.04]
        let sOffsets: [CGFloat] = [0.04, 0.02, 0.01, -0.01, 0.03, 0.00, -0.02, 0.02, -0.01, 0.01]

        var output: [HSBColor] = []
        for index in 0..<targetCount {
            let rawHue = hueQueue[index % hueQueue.count]
            let isAccentSlot =
                index < injectCount
                || (index >= primaryCount && index < (primaryCount + accentCount))
            let maxDistanceFromBg: CGFloat
            if isAccentSlot {
                maxDistanceFromBg = 75
            } else if complexity == .monochrome {
                maxDistanceFromBg = 6
            } else if complexity == .low || isNearGray || coverKind == .mostlyBWWithColor {
                maxDistanceFromBg = 8
            } else {
                maxDistanceFromBg = 10
            }
            var hue = clampHueDistance(rawHue, around: primaryHue, maxDistance: maxDistanceFromBg)
            if coverKind == .lowSatColor || coverKind == .mostlyBWWithColor {
                hue = lerpHue(hue, to: primaryHue, t: 0.18)
            }
            var targetB = clamp(
                bMid + bOffsets[index], min: tier.fgB.lowerBound, max: tier.fgB.upperBound)

            var targetS = clamp(
                sMid + sOffsets[index], min: tier.fgS.lowerBound, max: tier.fgS.upperBound)
            if lowSatColorCover {
                targetS = clamp(
                    targetS * satBoost, min: tier.fgS.lowerBound, max: tier.fgS.upperBound)
                targetB = clamp(
                    targetB * briBoost, min: tier.fgB.lowerBound, max: tier.fgB.upperBound)
            } else if dominantS < 0.22 {
                targetS = min(targetS, tier.fgS.upperBound * 0.78)
            }
            if isAccentSlot {
                targetS = min(tier.fgS.upperBound, max(targetS, sMid + 0.10))
                targetB = clamp(targetB * 1.03, min: tier.fgB.lowerBound, max: tier.fgB.upperBound)
            }

            let safe = sanitize(
                HSBColor(h: hue, s: targetS, b: targetB, a: 1),
                kind: .shape,
                bRange: tier.fgB,
                sRange: tier.fgS,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
            output.append(safe)
        }

        return output
    }

    fileprivate nonisolated static func makeDotBase(
        primaryHue: CGFloat,
        dominantHue: CGFloat,
        dominantS: CGFloat,
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        coverKind: CoverKind,
        lowSatColorCover: Bool,
        satBoost: CGFloat,
        briBoost: CGFloat,
        lumaTarget: CGFloat,
        lumaK: CGFloat,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> HSBColor {
        var hue = dominantHue
        if isNearGray {
            hue = lerpHue(dominantHue, to: primaryHue, t: 0.45)
        }
        let maxDotDistance: CGFloat = (complexity == .monochrome || isNearGray) ? 10 : 14
        hue = clampHueDistance(hue, around: primaryHue, maxDistance: maxDotDistance)

        let remapped = lerp(midpoint(tier.dotB), lumaTarget, t: lumaK)
        var b = clamp(remapped, min: tier.dotB.lowerBound, max: tier.dotB.upperBound)
        var s = clamp(midpoint(tier.dotS), min: tier.dotS.lowerBound, max: tier.dotS.upperBound)

        if lowSatColorCover {
            s = clamp(
                s * max(1.20, satBoost * 0.92), min: tier.dotS.lowerBound, max: tier.dotS.upperBound
            )
            b = clamp(
                b * max(1.05, briBoost * 0.95), min: tier.dotB.lowerBound, max: tier.dotB.upperBound
            )
        } else if coverKind == .mostlyBWWithColor {
            s = clamp(s * 1.12, min: tier.dotS.lowerBound, max: tier.dotS.upperBound)
        } else if dominantS < 0.22 {
            s = min(s, min(0.40, tier.dotS.upperBound * 0.70))
        }

        return sanitize(
            HSBColor(h: hue, s: s, b: b, a: 1),
            kind: .dot,
            bRange: tier.dotB,
            sRange: tier.dotS,
            complexity: complexity,
            isNearGray: isNearGray,
            isDark: isDark,
            triggered: &triggered
        )
    }

    fileprivate nonisolated static func enforceCandidateHueSource(
        candidateHues: [CGFloat],
        bgStops: inout [HSBColor],
        shapePool: inout [HSBColor],
        dotBase: inout HSBColor,
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) {
        guard !candidateHues.isEmpty else { return }

        func nearestHue(to hue: CGFloat) -> CGFloat {
            candidateHues.min(by: { hueDistance($0, hue) < hueDistance($1, hue) }) ?? hue
        }

        func clampToCandidate(
            _ color: HSBColor,
            kind: ElementKind,
            bRange: ClosedRange<CGFloat>,
            sRange: ClosedRange<CGFloat>
        ) -> HSBColor {
            var adjusted = color
            let nearest = nearestHue(to: adjusted.h)
            let delta = hueDistance(adjusted.h, nearest)
            if delta > 18 {
                adjusted.h = clampHueDistance(adjusted.h, around: nearest, maxDistance: 18)
                triggered.insert(.reverseHue)
            }
            return sanitize(
                adjusted,
                kind: kind,
                bRange: bRange,
                sRange: sRange,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
        }

        for i in bgStops.indices {
            bgStops[i] = clampToCandidate(
                bgStops[i], kind: .background, bRange: tier.bgB, sRange: tier.bgS)
        }
        for i in shapePool.indices {
            shapePool[i] = clampToCandidate(
                shapePool[i], kind: .shape, bRange: tier.fgB, sRange: tier.fgS)
        }
        dotBase = clampToCandidate(dotBase, kind: .dot, bRange: tier.dotB, sRange: tier.dotS)
    }

    fileprivate nonisolated static func enforceDominantHueAffinity(
        dominantHue: CGFloat,
        bgReferenceHue: CGFloat,
        bgStops: inout [HSBColor],
        shapePool: inout [HSBColor],
        dotBase: inout HSBColor,
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        coverKind: CoverKind,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) {
        func clampReverse(
            _ color: HSBColor,
            kind: ElementKind,
            bRange: ClosedRange<CGFloat>,
            sRange: ClosedRange<CGFloat>
        ) -> HSBColor {
            var c = color
            let reverseCenter = (kind == .background) ? bgReferenceHue : dominantHue
            if hueDistance(c.h, reverseCenter) > 90 {
                c.h = clampHueDistance(c.h, around: reverseCenter, maxDistance: 15)
                triggered.insert(.reverseHue)
            }
            switch kind {
            case .background:
                c.h = clampHueDistance(c.h, around: bgReferenceHue, maxDistance: 6)
            case .shape:
                let shapeMax: CGFloat =
                    (coverKind == .richDistributed)
                    ? 75
                    : ((coverKind == .lowSatColor || coverKind == .mostlyBWWithColor) ? 8 : 10)
                c.h = clampHueDistance(c.h, around: dominantHue, maxDistance: shapeMax)
            case .dot:
                c.h = clampHueDistance(c.h, around: dominantHue, maxDistance: 14)
            }
            return sanitize(
                c,
                kind: kind,
                bRange: bRange,
                sRange: sRange,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
        }

        for index in bgStops.indices {
            bgStops[index] = clampReverse(
                bgStops[index],
                kind: .background,
                bRange: tier.bgB,
                sRange: tier.bgS
            )
        }
        for index in shapePool.indices {
            shapePool[index] = clampReverse(
                shapePool[index],
                kind: .shape,
                bRange: tier.fgB,
                sRange: tier.fgS
            )
        }
        dotBase = clampReverse(dotBase, kind: .dot, bRange: tier.dotB, sRange: tier.dotS)
    }

    fileprivate nonisolated static func enforceSaturationGap(
        bgStops: inout [HSBColor],
        shapePool: inout [HSBColor],
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) {
        guard let maxBg = bgStops.map(\.s).max(), let minFg = shapePool.map(\.s).min() else {
            return
        }
        let requiredGap: CGFloat = 0.06
        guard maxBg >= (minFg - requiredGap) else { return }

        let desiredBgMax = max(tier.bgS.lowerBound, minFg - requiredGap)
        for index in bgStops.indices {
            var color = bgStops[index]
            color.s = min(color.s, desiredBgMax)
            bgStops[index] = sanitize(
                color,
                kind: .background,
                bRange: tier.bgB,
                sRange: tier.bgS,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
        }
    }

    fileprivate nonisolated static func enforceCoverSaturationMatch(
        avgS: CGFloat,
        bgStops: inout [HSBColor],
        shapePool: inout [HSBColor],
        dotBase: inout HSBColor,
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) {
        let ultraLow = avgS < 0.085
        let low = avgS < 0.18

        guard ultraLow || low else { return }

        let bgCap: CGFloat
        let shapeCap: CGFloat
        let dotCap: CGFloat
        let bgFloor: CGFloat

        if ultraLow {
            bgCap = min(tier.bgS.upperBound, isDark ? 0.10 : 0.08)
            shapeCap = min(tier.fgS.upperBound, isDark ? 0.16 : 0.14)
            dotCap = min(tier.dotS.upperBound, isDark ? 0.18 : 0.16)
            bgFloor = max(tier.bgS.lowerBound, isDark ? 0.01 : 0.00)
        } else {
            bgCap = min(tier.bgS.upperBound, isDark ? 0.32 : 0.27)
            shapeCap = min(tier.fgS.upperBound, isDark ? 0.30 : 0.28)
            dotCap = min(tier.dotS.upperBound, isDark ? 0.32 : 0.30)
            bgFloor = max(
                tier.bgS.lowerBound,
                clamp(avgS * (isDark ? 1.00 : 0.92) + 0.05, min: 0.12, max: 0.22)
            )
        }

        for index in bgStops.indices {
            var c = bgStops[index]
            c.s = clamp(c.s, min: bgFloor, max: bgCap)
            bgStops[index] = sanitize(
                c,
                kind: .background,
                bRange: tier.bgB,
                sRange: tier.bgS,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
        }

        for index in shapePool.indices {
            var c = shapePool[index]
            c.s = min(c.s, shapeCap)
            shapePool[index] = sanitize(
                c,
                kind: .shape,
                bRange: tier.fgB,
                sRange: tier.fgS,
                complexity: complexity,
                isNearGray: isNearGray,
                isDark: isDark,
                triggered: &triggered
            )
        }

        dotBase.s = min(dotBase.s, dotCap)
        dotBase = sanitize(
            dotBase,
            kind: .dot,
            bRange: tier.dotB,
            sRange: tier.dotS,
            complexity: complexity,
            isNearGray: isNearGray,
            isDark: isDark,
            triggered: &triggered
        )
    }

    fileprivate nonisolated static func enforceBrightnessHierarchy(
        bgStops: inout [HSBColor],
        shapePool: inout [HSBColor],
        dotBase: inout HSBColor,
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) {
        let minBgFgGap: CGFloat = isDark ? 0.10 : 0.08
        let minFgDotGap: CGFloat = isDark ? 0.08 : 0.08

        guard
            let bgMax = bgStops.map(\.b).max(),
            let bgMin = bgStops.map(\.b).min(),
            let fgMax = shapePool.map(\.b).max(),
            let fgMin = shapePool.map(\.b).min()
        else { return }

        if isDark {
            if (fgMin - bgMax) < minBgFgGap {
                let targetBgMax = max(tier.bgB.lowerBound, fgMin - minBgFgGap)
                for index in bgStops.indices {
                    var adjusted = bgStops[index]
                    adjusted.b = min(adjusted.b, targetBgMax)
                    bgStops[index] = sanitize(
                        adjusted,
                        kind: .background,
                        bRange: tier.bgB,
                        sRange: tier.bgS,
                        complexity: complexity,
                        isNearGray: isNearGray,
                        isDark: true,
                        triggered: &triggered
                    )
                }
            }

            let currentFgMax = shapePool.map(\.b).max() ?? fgMax
            if (dotBase.b - currentFgMax) < minFgDotGap {
                dotBase.b = min(tier.dotB.upperBound, currentFgMax + minFgDotGap)
                dotBase = sanitize(
                    dotBase,
                    kind: .dot,
                    bRange: tier.dotB,
                    sRange: tier.dotS,
                    complexity: complexity,
                    isNearGray: isNearGray,
                    isDark: true,
                    triggered: &triggered
                )
            }
        } else {
            if (bgMin - fgMax) < minBgFgGap {
                let targetBgMin = min(tier.bgB.upperBound, fgMax + minBgFgGap)
                for index in bgStops.indices {
                    var adjusted = bgStops[index]
                    adjusted.b = max(adjusted.b, targetBgMin)
                    bgStops[index] = sanitize(
                        adjusted,
                        kind: .background,
                        bRange: tier.bgB,
                        sRange: tier.bgS,
                        complexity: complexity,
                        isNearGray: isNearGray,
                        isDark: false,
                        triggered: &triggered
                    )
                }
            }

            let currentFgMin = shapePool.map(\.b).min() ?? fgMin
            if (currentFgMin - dotBase.b) < minFgDotGap {
                dotBase.b = max(tier.dotB.lowerBound, currentFgMin - minFgDotGap)
                dotBase = sanitize(
                    dotBase,
                    kind: .dot,
                    bRange: tier.dotB,
                    sRange: tier.dotS,
                    complexity: complexity,
                    isNearGray: isNearGray,
                    isDark: false,
                    triggered: &triggered
                )
            }
        }
    }

    fileprivate nonisolated static func selectPrimaryHue(
        from candidates: [HSBColor],
        isDark: Bool,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        dominantHue: CGFloat,
        coverKind: CoverKind,
        salientHues: [PaletteStats.SalientHue]
    ) -> CGFloat {
        guard !candidates.isEmpty else { return isDark ? 220 : 28 }

        if coverKind == .mostlyBWWithColor {
            let colorCandidates = candidates.filter { $0.s > 0.22 && $0.b >= 0.12 && $0.b <= 0.90 }
            if let bestColor = colorCandidates.max(by: { saliencyScore($0) < saliencyScore($1) }) {
                return normalizeHue(bestColor.h)
            }
        }

        let targetS: CGFloat = 0.45
        let targetB: CGFloat = isDark ? 0.52 : 0.48

        let dominantWeight: CGFloat
        switch complexity {
        case .monochrome: dominantWeight = 1.20
        case .low: dominantWeight = 0.85
        case .medium: dominantWeight = 0.45
        case .high: dominantWeight = 0.22
        }
        let nearGrayExtra: CGFloat = isNearGray ? 0.30 : 0

        var bestScore = -CGFloat.greatestFiniteMagnitude
        var bestHue = candidates[0].h

        for color in candidates {
            var c = color
            let sLower = sMin(forBrightness: c.b)
            let sUpper = min(sMax(forBrightness: c.b), 0.75)
            c.s = clamp(c.s, min: sLower, max: sUpper)

            let hueDeltaPenalty = (hueDistance(c.h, dominantHue) / 180) * dominantWeight
            let salientBonus = salientHues.reduce(CGFloat(0)) { partial, salient in
                let d = hueDistance(c.h, salient.hue)
                let proximity = max(0, 1 - d / 60)
                return partial + salient.weight * proximity
                    * (coverKind == .richDistributed ? 0.85 : 0.55)
            }
            let score =
                -abs(c.s - targetS) * 1.4
                - abs(c.b - targetB) * 1.1
                - riskPenalty(h: c.h, s: c.s, b: c.b)
                - hueDeltaPenalty
                - (hueDistance(c.h, dominantHue) / 180) * nearGrayExtra
                + salientBonus

            if score > bestScore {
                bestScore = score
                bestHue = c.h
            }
        }

        return normalizeHue(bestHue)
    }

    fileprivate nonisolated static func isValidPrimaryCandidate(_ c: HSBColor) -> Bool {
        if c.b < 0.10 { return false }
        if c.b > 0.96 && c.s < 0.22 { return false }
        if c.b > 0.20 && c.b < 0.85 && c.s < 0.10 { return false }
        return true
    }

    fileprivate nonisolated static func adjustPrimaryHue(
        _ hue: CGFloat,
        source: PrimarySelectionSource,
        coverKind: CoverKind,
        triggered: inout Set<RiskFlag>
    ) -> CGFloat {
        var h = normalizeHue(hue)

        if inRange(h, 92, 140) {
            triggered.insert(.greenDanger)
            h = abs(h - 90) <= abs(h - 148) ? 90 : 148
        }

        if inRange(h, 45, 78), source == .scorer {
            triggered.insert(.muddyYellow)
            h = lerpHue(h, to: 42, t: 0.40)
        } else if inRange(h, 45, 78) {
            triggered.insert(.muddyYellow)
            h = lerpHue(h, to: 42, t: 0.28)
        }

        if inRedZone(h) {
            triggered.insert(.plasticRed)
        }

        let blandRanges: [(CGFloat, CGFloat)] = [(120, 170), (140, 160)]
        if source == .scorer, blandRanges.contains(where: { inRange(h, $0.0, $0.1) }) {
            let preferred: [CGFloat] = [220, 190, 265, 28, 350]
            let nearest = preferred.min { hueDistance(h, $0) < hueDistance(h, $1) } ?? 220
            let t: CGFloat = (coverKind == .mostlyBWWithColor) ? 0.12 : 0.22
            h = lerpHue(h, to: nearest, t: t)
        }

        return normalizeHue(h)
    }

    fileprivate nonisolated static func sanitize(
        _ color: HSBColor,
        kind: ElementKind,
        bRange: ClosedRange<CGFloat>,
        sRange: ClosedRange<CGFloat>,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> HSBColor {
        var c = color
        c.h = normalizeHue(c.h)
        c.b = clamp(c.b, min: bRange.lowerBound, max: bRange.upperBound)
        c.s = min(c.s, darkShadowSaturationCap(forBrightness: c.b) ?? c.s)

        let hardCap = saturationHardCap(
            kind: kind,
            isDark: isDark,
            complexity: complexity,
            isNearGray: isNearGray
        )
        let sLower = max(sRange.lowerBound, sMin(forBrightness: c.b))
        let sUpper = min(
            sRange.upperBound,
            sMax(forBrightness: c.b),
            hardCap,
            darkShadowSaturationCap(forBrightness: c.b) ?? 1
        )
        c.s = clamp(c.s, min: sLower, max: sUpper)

        c = applyRiskRules(
            c,
            kind: kind,
            bRange: bRange,
            sRange: sRange,
            complexity: complexity,
            isNearGray: isNearGray,
            isDark: isDark,
            triggered: &triggered
        )

        c = avoidHospitalGreen(
            c,
            kind: kind,
            bRange: bRange,
            sRange: sRange,
            isDark: isDark,
            triggered: &triggered
        )

        c.b = clamp(c.b, min: bRange.lowerBound, max: bRange.upperBound)
        c.s = min(c.s, darkShadowSaturationCap(forBrightness: c.b) ?? c.s)
        let finalLower = max(sRange.lowerBound, sMin(forBrightness: c.b))
        let finalUpper = min(
            sRange.upperBound,
            sMax(forBrightness: c.b),
            hardCap,
            darkShadowSaturationCap(forBrightness: c.b) ?? 1
        )
        c.s = clamp(c.s, min: finalLower, max: finalUpper)
        return c
    }

    fileprivate nonisolated static func applyRiskRules(
        _ color: HSBColor,
        kind: ElementKind,
        bRange: ClosedRange<CGFloat>,
        sRange: ClosedRange<CGFloat>,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> HSBColor {
        var c = color

        if inRange(c.h, 92, 140) {
            triggered.insert(.greenDanger)
            let cap: CGFloat = (kind == .background) ? 0.34 : 0.60
            c.s = min(c.s, cap)
        }

        if inRange(c.h, 45, 78) {
            triggered.insert(.muddyYellow)
            let cap: CGFloat = (kind == .background) ? 0.28 : 0.55
            c.s = min(c.s, cap)
            if c.s > 0.4 {
                c.s *= 0.6
            }
            c.h = lerpHue(c.h, to: 42, t: kind == .background ? 0.38 : 0.24)
            let floor = max(
                bRange.lowerBound,
                kind == .background
                    ? 0.30
                    : 0.38
            )
            c.b = max(c.b, floor)
        }

        if inRedZone(c.h) {
            triggered.insert(.plasticRed)
            if c.s > 0.70 {
                c.s *= 0.75
            }
            if c.b > 0.78 {
                c.b *= 0.92
            }
            if kind == .background {
                let bgCap: CGFloat = isDark ? 0.40 : 0.30
                c.s = min(c.s, bgCap)
            }
        }

        if inRange(c.h, 255, 290), c.b < 0.30 {
            triggered.insert(.dirtyPurple)
            c.b = max(c.b, min(bRange.upperBound, 0.30))
            c.s *= 0.72
        }
        if kind == .background, inRange(c.h, 255, 290), c.b < 0.22 {
            c.b = 0.22
        }

        if inRange(c.h, 300, 335) {
            if c.s > 0.62 || c.b > 0.75 {
                triggered.insert(.fluorescentPink)
            }
            c.s = min(c.s, kind == .background ? 0.45 : 0.62)
            if c.b > 0.75 {
                c.s *= 0.7
            }
        }

        if c.b < 0.28, c.s > 0.45 {
            triggered.insert(.muddyCombo)
            if kind == .background {
                c.s = clamp(c.s, min: 0.35, max: 0.45)
            } else {
                c.b = max(c.b, bRange.lowerBound)
                c.s = min(c.s, 0.55)
            }
        }

        if complexity == .monochrome || isNearGray {
            c.s = min(c.s, kind == .background ? sRange.upperBound * 0.5 : sRange.upperBound * 0.6)
        }

        c.s = clamp(c.s, min: sRange.lowerBound, max: sRange.upperBound)
        c.b = clamp(c.b, min: bRange.lowerBound, max: bRange.upperBound)
        return c
    }

    fileprivate nonisolated static func avoidHospitalGreen(
        _ color: HSBColor,
        kind: ElementKind,
        bRange: ClosedRange<CGFloat>,
        sRange: ClosedRange<CGFloat>,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) -> HSBColor {
        var c = color
        let before = c
        var action = "none"

        if isHospitalGreenPrimary(c) {
            let t = clamp((c.h - 118) / 24, min: 0, max: 1)
            switch kind {
            case .background:
                c.s *= 0.62
                c.b = min(max(c.b, 0.58), isDark ? 0.62 : 0.85)
                c.h = normalizeHue(c.h + lerp(10, 18, t: t))
                action = "desat+lift+shiftC"
            case .shape:
                c.s *= 0.65
                c.b = min(max(c.b, isDark ? 0.52 : 0.62), isDark ? 0.70 : 0.85)
                c.h = normalizeHue(c.h - lerp(10, 18, t: t))
                action = "desat+lift+shiftY"
            case .dot:
                c.s *= 0.72
                c.b = min(max(c.b, isDark ? 0.50 : 0.60), isDark ? 0.74 : 0.88)
                c.h = normalizeHue(c.h + lerp(8, 14, t: t))
                action = "desat+lift+shiftCdot"
            }
        }

        if isHospitalGreenSecondaryA(c) {
            switch kind {
            case .background:
                c.b = max(c.b, 0.26)
                c.s = min(c.s, (0.22 + 0.8 * c.b) * 0.90)
                c.h = normalizeHue(c.h - 8)
            case .shape:
                c.b = max(c.b, 0.26)
                c.s = min(c.s, 0.22 + 0.8 * c.b)
                c.h = normalizeHue(c.h - 10)
            case .dot:
                c.b = max(c.b, 0.30)
                c.s = min(c.s, 0.24 + 0.8 * c.b)
                c.h = normalizeHue(c.h - 6)
            }
            action = action == "none" ? "lift+capS+shiftY" : "\(action)+A"
        }

        if isHospitalGreenSecondaryB(c) {
            switch kind {
            case .background:
                c.s *= 0.75
                c.b = min(c.b + 0.10, isDark ? 0.60 : 0.85)
                action = action == "none" ? "desat+liftBg" : "\(action)+BgB"
            case .shape:
                c.b = max(c.b, isDark ? 0.42 : 0.58)
                action = action == "none" ? "liftFg" : "\(action)+FgB"
            case .dot:
                c.b = max(c.b, isDark ? 0.48 : 0.62)
                c.s = min(c.s, 0.58)
                action = action == "none" ? "liftDot" : "\(action)+DotB"
            }
        }

        if kind == .background {
            let bgExtraCap = min(sRange.upperBound, isDark ? 0.34 : 0.30)
            c.s = min(c.s, bgExtraCap)
        } else if kind == .dot {
            if c.b < 0.24 { c.b = 0.24 }
            if c.b < 0.38, c.s > 0.62 {
                c.s = 0.62
            }
        }

        if isHospitalGreenPrimary(c) {
            switch kind {
            case .background:
                c.s = min(c.s, 0.28)
                c.b = max(c.b, 0.58)
                c.h = normalizeHue(c.h + 16)
            case .shape:
                c.s = min(c.s, 0.30)
                c.b = max(c.b, isDark ? 0.52 : 0.62)
                c.h = normalizeHue(c.h - 12)
            case .dot:
                c.s = min(c.s, 0.34)
                c.b = max(c.b, isDark ? 0.50 : 0.62)
                c.h = normalizeHue(c.h + 12)
            }
            action = action == "none" ? "force_exit" : "\(action)+force_exit"
        }

        c.s = clamp(c.s, min: sRange.lowerBound, max: sRange.upperBound)
        c.b = clamp(c.b, min: bRange.lowerBound, max: bRange.upperBound)

        if action != "none" {
            triggered.insert(.hospitalGreen)
            print(
                "[BKColorEngine] avoid_hospital_green kind=\(elementKindName(kind)) hsb before={\(hsbString(before))} after={\(hsbString(c))} action=\(action)"
            )
        }
        return c
    }

    fileprivate nonisolated static func riskPenalty(h: CGFloat, s: CGFloat, b: CGFloat) -> CGFloat {
        var penalty: CGFloat = 0

        if inRange(h, 118, 142), s >= 0.32, s <= 0.75, b >= 0.18, b <= 0.55 {
            penalty += 0.95 + max(0, s - 0.35) * 0.7 + max(0, 0.55 - b) * 0.5
        }
        if inRange(h, 110, 150), b < 0.22, s > 0.22 {
            penalty += 0.60 + (0.22 - b) * 1.4 + (s - 0.22) * 0.4
        }
        if inRange(h, 115, 145), s >= 0.18, s <= 0.35, b >= 0.35, b <= 0.55 {
            penalty += 0.45
        }

        if inRange(h, 92, 140) {
            penalty += 0.42 + max(0, s - 0.34) * 0.9
        }
        if inRange(h, 45, 78) {
            penalty += 0.55 + max(0, 0.40 - b) * 1.2 + max(0, s - 0.42) * 0.7
        }
        if inRedZone(h) {
            penalty += 0.18 + max(0, s - 0.70) * 0.9 + max(0, b - 0.80) * 0.5
        }
        if inRange(h, 255, 290), b < 0.32 {
            penalty += 0.60 + (0.32 - b) * 1.8
        }
        if inRange(h, 300, 335), s > 0.66, b > 0.70 {
            penalty += 0.75 + (s - 0.66) * 1.2 + (b - 0.70) * 0.6
        }
        if b < 0.28, s > 0.45 {
            penalty += 0.65 + (0.28 - b) * 1.1 + (s - 0.45) * 0.8
        }

        return penalty
    }

    fileprivate nonisolated static func saturationHardCap(
        kind: ElementKind,
        isDark: Bool,
        complexity: ColorComplexityLevel,
        isNearGray: Bool
    ) -> CGFloat {
        let base: CGFloat
        switch kind {
        case .background:
            base = isDark ? 0.50 : 0.36
        case .shape:
            base = isDark ? 0.70 : 0.60
        case .dot:
            base = isDark ? 0.62 : 0.56
        }

        if isNearGray {
            return base * 0.78
        }

        switch complexity {
        case .monochrome:
            return base * (kind == .background ? 0.50 : 0.60)
        case .low:
            return base * 0.88
        case .medium, .high:
            return base
        }
    }

    fileprivate nonisolated static func normalizeCandidateColor(_ color: HSBColor) -> HSBColor {
        var c = color
        c.h = biasedBlueVioletHue(c.h, s: c.s, b: c.b)
        if let cap = darkShadowSaturationCap(forBrightness: c.b) {
            c.s = min(c.s, cap)
        }
        c = avoidHospitalGreenCandidate(c)
        c.h = normalizeHue(c.h)
        c.s = clamp01(c.s)
        c.b = clamp01(c.b)
        return c
    }

    fileprivate nonisolated static func biasedBlueVioletHue(_ hue: CGFloat, s: CGFloat, b: CGFloat)
        -> CGFloat
    {
        let h = normalizeHue(hue)
        guard s >= 0.20, b >= 0.22, b <= 0.78, h >= 55, h <= 90 else { return h }
        let t = clamp((h - 55) / 35, min: 0, max: 1)
        let satFactor = clamp((s - 0.20) / 0.50, min: 0, max: 1)
        let delta = min(14, max(0, lerp(6, 14, t: t) * satFactor))
        return normalizeHue(h + delta)
    }

    fileprivate nonisolated static func darkShadowSaturationCap(forBrightness b: CGFloat)
        -> CGFloat?
    {
        if b < 0.18 {
            return lerp(0.10, 0.22, t: clamp(b / 0.18, min: 0, max: 1))
        }
        if b <= 0.30 {
            return lerp(0.22, 0.38, t: clamp((b - 0.18) / 0.12, min: 0, max: 1))
        }
        return nil
    }

    fileprivate nonisolated static func isHospitalGreenPrimary(_ c: HSBColor) -> Bool {
        inRange(c.h, 118, 142)
            && c.s >= 0.32 && c.s <= 0.75
            && c.b >= 0.18 && c.b <= 0.55
    }

    fileprivate nonisolated static func isHospitalGreenSecondaryA(_ c: HSBColor) -> Bool {
        inRange(c.h, 110, 150) && c.b < 0.22 && c.s > 0.22
    }

    fileprivate nonisolated static func isHospitalGreenSecondaryB(_ c: HSBColor) -> Bool {
        inRange(c.h, 115, 145)
            && c.s >= 0.18 && c.s <= 0.35
            && c.b >= 0.35 && c.b <= 0.55
    }

    fileprivate nonisolated static func avoidHospitalGreenCandidate(_ color: HSBColor) -> HSBColor {
        var c = color
        let before = c
        var action = "none"

        if isHospitalGreenPrimary(c) {
            let t = clamp((c.h - 118) / 24, min: 0, max: 1)
            c.s *= 0.65
            c.b = min(max(c.b, 0.58), 0.80)
            c.h = normalizeHue(c.h + lerp(10, 18, t: t))
            action = "desat+lift+shiftC"
        }
        if isHospitalGreenSecondaryA(c) {
            c.b = max(c.b, 0.26)
            c.s = min(c.s, 0.22 + 0.8 * c.b)
            c.h = normalizeHue(c.h - 8)
            action = action == "none" ? "lift+capS+shiftY" : "\(action)+A"
        }
        if isHospitalGreenSecondaryB(c) {
            c.s *= 0.78
            c.b = min(c.b + 0.08, 0.80)
            action = action == "none" ? "desat+liftB" : "\(action)+B"
        }
        if isHospitalGreenPrimary(c) {
            c.s = min(c.s, 0.30)
            c.b = max(c.b, 0.58)
            c.h = normalizeHue(c.h + 14)
            action = action == "none" ? "force_exit" : "\(action)+force_exit"
        }

        if action != "none" {
            print(
                "[BKColorEngine] avoid_hospital_green kind=candidate hsb before={\(hsbString(before))} after={\(hsbString(c))} action=\(action)"
            )
        }
        return c
    }

    fileprivate nonisolated static func sMax(forBrightness b: CGFloat) -> CGFloat {
        if b < 0.22 { return 0.38 }
        if b < 0.40 { return lerp(0.38, 0.68, t: (b - 0.22) / (0.40 - 0.22)) }
        if b < 0.75 { return 0.68 }
        if b < 0.88 { return lerp(0.68, 0.52, t: (b - 0.75) / (0.88 - 0.75)) }
        return 0.52
    }

    fileprivate nonisolated static func sMin(forBrightness b: CGFloat) -> CGFloat {
        if b < 0.22 { return 0.08 }
        if b < 0.40 { return lerp(0.08, 0.12, t: (b - 0.22) / (0.40 - 0.22)) }
        if b < 0.75 { return 0.12 }
        if b < 0.88 { return lerp(0.12, 0.10, t: (b - 0.75) / (0.88 - 0.75)) }
        return 0.10
    }

    fileprivate nonisolated static func logPalette(
        primaryBefore: CGFloat,
        primaryAfter: CGFloat,
        primarySource: PrimarySelectionSource,
        stats: PaletteStats,
        tier: TierRanges,
        triggered: Set<RiskFlag>,
        bgStops: [HSBColor],
        shapePool: [HSBColor],
        dotBase: HSBColor,
        injectedAccentCount: Int
    ) {
        let triggerText =
            triggered.isEmpty
            ? "none"
            : triggered.map(\.rawValue).sorted().joined(separator: ", ")

        let shapeHues = shapePool.map { normalizeHue($0.h) }
        let hueSpan = hueSpanAround(reference: primaryAfter, hues: shapeHues)
        let hueDist = shapeHues.map { Int(round($0)) }.sorted().map(String.init).joined(
            separator: ",")
        let salientText = stats.topSalientHues.prefix(3).map {
            "\(f1($0.hue))@\(f3($0.weight))"
        }.joined(separator: " | ")
        let clusterText = stats.topClusters.prefix(3).map {
            "\(f1($0.hue))@\(f3($0.weight))"
        }.joined(separator: " | ")

        print(
            "[BKColorEngine] coverKind=\(stats.coverKind.rawValue) complexity=\(stats.complexity.rawValue) avgS=\(f3(stats.avgS)) matchedAvgS=\(f3(stats.matchedAvgS)) grayScore=\(f3(stats.grayScore)) wBlack=\(f3(stats.wBlack)) wWhite=\(f3(stats.wWhite)) wColor=\(f3(stats.wColor)) coverLuma=\(f3(stats.coverLuma)) imageLuma=\(f3(stats.imageCoverLuma)) areaB=\(f3(stats.areaDominantB)) areaS=\(f3(stats.areaDominantS)) veryDark=\(stats.veryDarkCover ? 1 : 0) accentEnabled=\(stats.accentEnabled ? 1 : 0) accentStrength=\(f3(stats.accentStrength)) maxColorScore=\(f3(stats.maxColorCandidateScore)) evenness=\(f3(stats.evenness)) gray=\(stats.isGrayscaleCover ? 1 : 0) nearGray=\(stats.isNearGray ? 1 : 0) lowSatColor=\(stats.lowSatColorCover ? 1 : 0)"
        )
        print(
            "[BKColorEngine] primary selected from=\(primarySource.rawValue) primaryHue before=\(f1(primaryBefore)) after=\(f1(primaryAfter)) imageHue=\(f1(stats.areaDominantHue)) dominantHue=\(f1(stats.dominantHue)) dominantShare=\(f3(stats.dominantShare)) accentHue=\(stats.accentHue.map(f1) ?? "none") secondAccent=\(stats.secondAccentHue.map(f1) ?? "none") triggers=\(triggerText)"
        )
        print(
            "[BKColorEngine] ranges bgB=\(f3(tier.bgB.lowerBound))...\(f3(tier.bgB.upperBound)) bgS=\(f3(tier.bgS.lowerBound))...\(f3(tier.bgS.upperBound)) fgB=\(f3(tier.fgB.lowerBound))...\(f3(tier.fgB.upperBound)) fgS=\(f3(tier.fgS.lowerBound))...\(f3(tier.fgS.upperBound)) dotB=\(f3(tier.dotB.lowerBound))...\(f3(tier.dotB.upperBound)) dotS=\(f3(tier.dotS.lowerBound))...\(f3(tier.dotS.upperBound))"
        )
        print("[BKColorEngine] topSalientHues \(salientText)")
        print("[BKColorEngine] topClusters \(clusterText)")

        if let bg0 = bgStops.first, let shape0 = shapePool.first {
            print(
                "[BKColorEngine] sample bgStop0{b=\(f3(bg0.b)) s=\(f3(bg0.s))} shape0{b=\(f3(shape0.b)) s=\(f3(shape0.s))} dotBase{b=\(f3(dotBase.b)) s=\(f3(dotBase.s))}"
            )
        }

        print(
            "[BKColorEngine] shapePoolHueDist [\(hueDist)] maxHueDelta=\(f1(hueSpan)) secondAccentEnabled=\(stats.secondAccentHue != nil ? 1 : 0) injectedAccentColors=\(injectedAccentCount)"
        )
        if hueSpan > 90, stats.complexity != .high {
            print("[BKColorEngine][WARN] hue span exceeds 90 in non-high complexity")
        }

        let bgText = bgStops.enumerated().map { "\($0):{\(hsbString($1))}" }.joined(separator: " ")
        let shapeText = shapePool.enumerated().map { "\($0):{\(hsbString($1))}" }.joined(
            separator: " ")
        print("[BKColorEngine] bgStopsHSB \(bgText)")
        print("[BKColorEngine] shapePoolHSB \(shapeText)")
        print("[BKColorEngine] dotBaseHSB \(hsbString(dotBase))")
    }

    fileprivate nonisolated static func hueSpanAround(reference: CGFloat, hues: [CGFloat])
        -> CGFloat
    {
        guard !hues.isEmpty else { return 0 }
        let offsets = hues.map { signedHueOffset(from: reference, to: $0) }
        let minOffset = offsets.min() ?? 0
        let maxOffset = offsets.max() ?? 0
        return maxOffset - minOffset
    }

    fileprivate nonisolated static func maxHueSpread(_ hues: [CGFloat]) -> CGFloat {
        guard hues.count >= 2 else { return 0 }
        var maxDelta: CGFloat = 0
        for i in 0..<(hues.count - 1) {
            for j in (i + 1)..<hues.count {
                maxDelta = max(maxDelta, hueDistance(hues[i], hues[j]))
            }
        }
        return maxDelta
    }

    fileprivate nonisolated static func hsbString(_ c: HSBColor) -> String {
        "h=\(f1(c.h)) s=\(f3(c.s)) b=\(f3(c.b))"
    }

    fileprivate nonisolated static func elementKindName(_ kind: ElementKind) -> String {
        switch kind {
        case .background: return "bg"
        case .shape: return "shape"
        case .dot: return "dot"
        }
    }

    fileprivate nonisolated static func hsb(from color: NSColor) -> HSBColor? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return HSBColor(
            h: normalizeHue(h * 360),
            s: clamp01(s),
            b: clamp01(b),
            a: clamp01(a)
        )
    }

    fileprivate nonisolated static func hsb(from color: CGColor) -> HSBColor? {
        guard let ns = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return nil }
        return hsb(from: ns)
    }

    fileprivate nonisolated static func toCGColor(_ c: HSBColor) -> CGColor {
        let deviceColor = NSColor(
            deviceHue: normalizeHue(c.h) / 360,
            saturation: clamp01(c.s),
            brightness: clamp01(c.b),
            alpha: clamp01(c.a)
        )
        return (deviceColor.usingColorSpace(.deviceRGB) ?? deviceColor).cgColor
    }

    fileprivate nonisolated static func midpoint(_ range: ClosedRange<CGFloat>) -> CGFloat {
        (range.lowerBound + range.upperBound) * 0.5
    }

    fileprivate nonisolated static func inRange(
        _ hue: CGFloat, _ minDeg: CGFloat, _ maxDeg: CGFloat
    ) -> Bool {
        let h = normalizeHue(hue)
        let lo = normalizeHue(minDeg)
        let hi = normalizeHue(maxDeg)
        if lo <= hi {
            return h >= lo && h <= hi
        }
        return h >= lo || h <= hi
    }

    fileprivate nonisolated static func inRedZone(_ hue: CGFloat) -> Bool {
        inRange(hue, 350, 360) || inRange(hue, 0, 15)
    }

    fileprivate nonisolated static func hueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        abs(signedHueOffset(from: lhs, to: rhs))
    }

    fileprivate nonisolated static func signedHueOffset(from: CGFloat, to: CGFloat) -> CGFloat {
        let a = normalizeHue(from)
        let b = normalizeHue(to)
        var delta = b - a
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    fileprivate nonisolated static func clampHueDistance(
        _ hue: CGFloat, around center: CGFloat, maxDistance: CGFloat
    )
        -> CGFloat
    {
        let delta = signedHueOffset(from: center, to: hue)
        let clamped = clamp(delta, min: -maxDistance, max: maxDistance)
        return normalizeHue(center + clamped)
    }

    fileprivate nonisolated static func lerpHue(_ from: CGFloat, to: CGFloat, t: CGFloat) -> CGFloat
    {
        let delta = signedHueOffset(from: from, to: to)
        return normalizeHue(from + delta * clamp(t, min: 0, max: 1))
    }

    fileprivate nonisolated static func normalizeHue(_ hue: CGFloat) -> CGFloat {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }

    fileprivate nonisolated static func dedupeHues(_ hues: [CGFloat]) -> [CGFloat] {
        var seen = Set<Int>()
        var output: [CGFloat] = []
        for raw in hues {
            let hue = normalizeHue(raw)
            let key = Int(round(hue * 10))
            if !seen.contains(key) {
                seen.insert(key)
                output.append(hue)
            }
        }
        return output
    }

    fileprivate nonisolated static func deg2rad(_ value: CGFloat) -> CGFloat {
        value * .pi / 180
    }

    fileprivate nonisolated static func rad2deg(_ value: CGFloat) -> CGFloat {
        value * 180 / .pi
    }

    fileprivate nonisolated static func clamp01(_ value: CGFloat) -> CGFloat {
        clamp(value, min: 0, max: 1)
    }

    fileprivate nonisolated static func clamp(
        _ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat
    )
        -> CGFloat
    {
        Swift.min(maxValue, Swift.max(minValue, value))
    }

    fileprivate nonisolated static func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * clamp(t, min: 0, max: 1)
    }

    fileprivate nonisolated static func f1(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    fileprivate nonisolated static func f3(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}

extension Array {
    fileprivate nonisolated func ifEmpty(_ fallback: @autoclosure () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
    }
}

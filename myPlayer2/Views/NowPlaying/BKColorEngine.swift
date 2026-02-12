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

struct HarmonizedPalette {
    let primaryHue: CGFloat
    let isDark: Bool
    let complexity: ColorComplexityLevel
    let grayScore: CGFloat
    let isGrayscaleCover: Bool
    let isNearGray: Bool

    // Background (low sat)
    let bgStops: [CGColor]

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

enum ElementKind {
    case background
    case shape
    case dot
}

struct BKColorEngine {
    static func make(extracted: [NSColor], fallback: [NSColor], isDark: Bool) -> HarmonizedPalette {
        let paletteInput = (extracted.isEmpty ? fallback : extracted).compactMap(hsb(from:))
        let stats = analyzePalette(paletteInput)
        let tier = tierRanges(
            isDark: isDark,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            lowSatColorCover: stats.lowSatColorCover,
            coverKind: stats.coverKind
        )
        let lumaTargetValue = lumaTarget(coverLuma: stats.coverLuma, isDark: isDark)
        let lumaK = lumaBlendK(coverKind: stats.coverKind)

        if stats.coverKind == .grayscaleTrue {
            var triggered = Set<RiskFlag>()
            let grayscalePalette = makeGrayscalePalette(stats: stats, isDark: isDark, triggered: &triggered)
            logPalette(
                primaryBefore: grayscalePalette.primaryHue,
                primaryAfter: grayscalePalette.primaryHue,
                stats: stats,
                tier: grayscaleTierRanges(isDark: isDark),
                triggered: triggered,
                bgStops: grayscalePalette.bgStops.compactMap(hsb(from:)),
                shapePool: grayscalePalette.shapePool.compactMap(hsb(from:)),
                dotBase: hsb(from: grayscalePalette.dotBase)
                    ?? HSBColor(h: grayscalePalette.primaryHue, s: 0.24, b: isDark ? 0.72 : 0.56, a: 1)
            )
            return grayscalePalette
        }

        let filteredCandidates = paletteInput.filter(isValidPrimaryCandidate(_:))
        let candidates = filteredCandidates.isEmpty ? paletteInput : filteredCandidates
        let colorCandidates = candidates.filter { $0.s > 0.22 && $0.b >= 0.12 && $0.b <= 0.90 }
        let primaryCandidates =
            (stats.coverKind == .mostlyBWWithColor && !colorCandidates.isEmpty) ? colorCandidates : candidates

        var globalTriggers = Set<RiskFlag>()
        let primaryBefore = selectPrimaryHue(
            from: primaryCandidates,
            isDark: isDark,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            dominantHue: stats.dominantHue,
            coverKind: stats.coverKind,
            salientHues: stats.topSalientHues
        )
        let primaryAfter = adjustPrimaryHue(primaryBefore, triggered: &globalTriggers)

        let hueFamily = makeHueFamily(
            primaryHue: primaryAfter,
            complexity: stats.complexity,
            clusterCenters: stats.clusterCenters,
            isNearGray: stats.isNearGray,
            triggered: &globalTriggers
        )

        var bgStopsHSB = makeBackgroundStops(
            primaryHue: primaryAfter,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            lowSatColorCover: stats.lowSatColorCover,
            satBoost: stats.lowSatSatBoost,
            briBoost: stats.lowSatBriBoost,
            lumaTarget: lumaTargetValue,
            lumaK: lumaK,
            isDark: isDark,
            triggered: &globalTriggers
        )
        var shapePoolHSB = makeShapePool(
            primaryHue: primaryAfter,
            dominantHue: stats.dominantHue,
            dominantS: stats.dominantS,
            clusterCount: stats.clusterCount,
            hueFamily: hueFamily,
            accentHue: stats.accentHue,
            accentShare: stats.accentShare,
            secondAccentHue: stats.secondAccentHue,
            salientHues: stats.topSalientHues,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            lowSatColorCover: stats.lowSatColorCover,
            satBoost: stats.lowSatSatBoost,
            briBoost: stats.lowSatBriBoost,
            lumaTarget: lumaTargetValue,
            lumaK: lumaK,
            isDark: isDark,
            triggered: &globalTriggers
        )
        var dotBaseHSB = makeDotBase(
            primaryHue: primaryAfter,
            dominantHue: stats.dominantHue,
            dominantS: stats.dominantS,
            tier: tier,
            complexity: stats.complexity,
            isNearGray: stats.isNearGray,
            coverKind: stats.coverKind,
            lowSatColorCover: stats.lowSatColorCover,
            satBoost: stats.lowSatSatBoost,
            briBoost: stats.lowSatBriBoost,
            lumaTarget: lumaTargetValue,
            lumaK: lumaK,
            isDark: isDark,
            triggered: &globalTriggers
        )

        enforceDominantHueAffinity(
            dominantHue: stats.dominantHue,
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

        let harmonized = HarmonizedPalette(
            primaryHue: normalizeHue(primaryAfter),
            isDark: isDark,
            complexity: stats.complexity,
            grayScore: stats.grayScore,
            isGrayscaleCover: stats.isGrayscaleCover,
            isNearGray: stats.isNearGray,
            bgStops: bgStopsHSB.map(toCGColor(_:)),
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
            stats: stats,
            tier: tier,
            triggered: globalTriggers,
            bgStops: bgStopsHSB,
            shapePool: shapePoolHSB,
            dotBase: dotBaseHSB
        )

        return harmonized
    }

    static func stabilize(
        color: CGColor,
        kind: ElementKind,
        palette: HarmonizedPalette,
        hueJitter: CGFloat = 0,
        saturationJitter: CGFloat = 0,
        brightnessJitter: CGFloat = 0
    ) -> CGColor {
        guard var hsb = hsb(from: color) else { return color }
        hsb.h = normalizeHue(hsb.h + hueJitter)
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

private extension BKColorEngine {
    enum RiskFlag: String, CaseIterable {
        case greenDanger = "green_danger"
        case muddyYellow = "muddy_yellow"
        case plasticRed = "plastic_red"
        case dirtyPurple = "dirty_purple"
        case fluorescentPink = "fluorescent_pink"
        case muddyCombo = "muddy_combo"
        case reverseHue = "reverse_hue"
    }

    struct HSBColor {
        var h: CGFloat  // degrees: 0...360
        var s: CGFloat
        var b: CGFloat
        var a: CGFloat
    }

    struct TierRanges {
        let bgB: ClosedRange<CGFloat>
        let fgB: ClosedRange<CGFloat>
        let dotB: ClosedRange<CGFloat>
        let bgS: ClosedRange<CGFloat>
        let fgS: ClosedRange<CGFloat>
        let dotS: ClosedRange<CGFloat>
    }

    struct HueCluster {
        var sumX: CGFloat
        var sumY: CGFloat
        var count: Int
        var totalWeight: CGFloat

        init(hue: CGFloat, weight: CGFloat = 1) {
            let radians = deg2rad(hue)
            sumX = cos(radians) * weight
            sumY = sin(radians) * weight
            count = 1
            totalWeight = weight
        }

        mutating func add(hue: CGFloat, weight: CGFloat = 1) {
            let radians = deg2rad(hue)
            sumX += cos(radians) * weight
            sumY += sin(radians) * weight
            count += 1
            totalWeight += weight
        }

        var centerHue: CGFloat {
            normalizeHue(rad2deg(atan2(sumY, sumX)))
        }
    }

    struct PaletteStats {
        struct SalientHue {
            let hue: CGFloat
            let weight: CGFloat
        }

        let avgS: CGFloat
        let circularVariance: CGFloat
        let circularStdDegrees: CGFloat
        let clusterCenters: [CGFloat]
        let clusterCount: Int
        let dominantHue: CGFloat
        let dominantS: CGFloat
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
        let wBlack: CGFloat
        let wWhite: CGFloat
        let wColor: CGFloat
        let coverLuma: CGFloat
        let topSalientHues: [SalientHue]
        let evenness: CGFloat
        let complexity: ColorComplexityLevel
    }

    static func analyzePalette(_ colors: [HSBColor]) -> PaletteStats {
        guard !colors.isEmpty else {
            return PaletteStats(
                avgS: 0.25,
                circularVariance: 0.12,
                circularStdDegrees: 18,
                clusterCenters: [220],
                clusterCount: 1,
                dominantHue: 220,
                dominantS: 0.30,
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
                wBlack: 0.15,
                wWhite: 0.10,
                wColor: 0.70,
                coverLuma: 0.52,
                topSalientHues: [.init(hue: 220, weight: 1)],
                evenness: 0.50,
                complexity: .low
            )
        }

        let avgS = colors.map(\.s).reduce(0, +) / CGFloat(colors.count)
        let shares = inferredShares(count: colors.count)
        let saliencyWeights = colors.indices.map { index in
            let s = saliencyScore(colors[index])
            return shares[index] * (1 + 1.8 * s)
        }
        let saliencyTotal = max(0.0001, saliencyWeights.reduce(0, +))
        let normalizedSaliency = saliencyWeights.map { $0 / saliencyTotal }

        var meanX: CGFloat = 0
        var meanY: CGFloat = 0
        for index in colors.indices {
            let c = colors[index]
            let w = normalizedSaliency[index]
            let radians = deg2rad(c.h)
            meanX += cos(radians) * w
            meanY += sin(radians) * w
        }

        let resultant = max(0, min(1, sqrt(meanX * meanX + meanY * meanY)))
        let variance = 1 - resultant
        let stdRadians = resultant > 0 ? sqrt(max(0, -2 * log(resultant))) : CGFloat.pi
        let stdDegrees = rad2deg(stdRadians)

        var clusters: [HueCluster] = []
        for index in colors.indices {
            let color = colors[index]
            let weight = normalizedSaliency[index]
            if let nearest = nearestClusterIndex(for: color.h, in: clusters),
                hueDistance(clusters[nearest].centerHue, color.h) <= 25
            {
                clusters[nearest].add(hue: color.h, weight: weight)
            } else {
                clusters.append(HueCluster(hue: color.h, weight: weight))
            }
        }

        let centers = clusters.map(\.centerHue)
        let clusterCount = max(1, clusters.filter { $0.totalWeight > 0.10 }.count)

        let dominantIndex = normalizedSaliency.indices.max(by: {
            normalizedSaliency[$0] < normalizedSaliency[$1]
        }) ?? 0
        let dominant = colors[dominantIndex]
        let dominantShare = shares[dominantIndex]

        var grayWeightSum: CGFloat = 0
        var totalWeight: CGFloat = 0
        var wBlack: CGFloat = 0
        var wWhite: CGFloat = 0
        var wColor: CGFloat = 0
        var coverLumaWeighted: CGFloat = 0
        for index in colors.indices {
            let c = colors[index]
            let chroma = c.s * min(c.b, 1 - c.b)
            let grayLike = c.s < 0.14 || chroma < 0.06
            let extreme = c.b < 0.12 || c.b > 0.92
            let share = shares[index]
            let weight: CGFloat = (extreme ? 1.8 : 1.0) * share
            totalWeight += weight
            if grayLike {
                grayWeightSum += weight
            }
            if c.b < 0.12 {
                wBlack += share
            }
            if c.b > 0.90 {
                wWhite += share
            }
            if c.s > 0.22 && c.b >= 0.12 && c.b <= 0.90 {
                wColor += share
            }
            coverLumaWeighted += clamp(c.b, min: 0.06, max: 0.96) * normalizedSaliency[index]
        }
        let grayScore = totalWeight > 0 ? grayWeightSum / totalWeight : 0
        let coverLuma = clamp(coverLumaWeighted, min: 0.06, max: 0.96)

        var salientSorted: [PaletteStats.SalientHue] = []
        for index in colors.indices.sorted(by: { normalizedSaliency[$0] > normalizedSaliency[$1] }) {
            let hue = normalizeHue(colors[index].h)
            let weight = normalizedSaliency[index]
            if salientSorted.contains(where: { hueDistance($0.hue, hue) < 16 }) {
                continue
            }
            salientSorted.append(.init(hue: hue, weight: weight))
            if salientSorted.count >= 5 { break }
        }
        let topSalient = Array(salientSorted.prefix(3))
        let evenness = entropyNormalized(normalizedSaliency)

        let coverKind: CoverKind
        if wColor < 0.10 && avgS < 0.16 {
            coverKind = .grayscaleTrue
        } else if (wBlack + wWhite) > 0.65 && wColor >= 0.10 {
            coverKind = .mostlyBWWithColor
        } else if clusterCount >= 3 && evenness >= 0.72 && avgS >= 0.30 {
            coverKind = .richDistributed
        } else if avgS < 0.22 {
            coverKind = .lowSatColor
        } else {
            coverKind = .normal
        }

        let isGrayscaleCover = coverKind == .grayscaleTrue
        let isNearGray = coverKind == .lowSatColor && grayScore >= 0.52
        let lowSatColorCover = coverKind == .lowSatColor
        let satBoost: CGFloat
        let briBoost: CGFloat
        if lowSatColorCover {
            let t = clamp((avgS - 0.06) / 0.16, min: 0, max: 1)
            satBoost = lerp(1.50, 1.20, t: t)
            briBoost = lerp(1.15, 1.05, t: t)
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
        } else if avgS < 0.30 || clusterCount <= 2 {
            complexity = .medium
        } else {
            complexity = .high
        }

        var accentHue: CGFloat?
        var accentShare: CGFloat = 0
        var bestAccentScore = -CGFloat.greatestFiniteMagnitude
        for index in colors.indices {
            let c = colors[index]
            let share = shares[index]
            guard share < 0.12 else { continue }
            let hueDelta = hueDistance(c.h, dominant.h)
            guard hueDelta >= 28 else { continue }
            let satFloor = max(0.36, avgS + 0.16)
            guard c.s >= satFloor else { continue }

            let score =
                c.s * 1.4
                + (hueDelta / 180) * 1.0
                + (0.12 - share) * 1.2
                - riskPenalty(h: c.h, s: c.s, b: c.b) * 0.35
            if score > bestAccentScore {
                bestAccentScore = score
                accentHue = c.h
                accentShare = share
            }
        }

        let secondAccentHue: CGFloat?
        if coverKind == .richDistributed, topSalient.count >= 2 {
            let raw = topSalient[1].hue
            secondAccentHue = clampHueDistance(raw, around: topSalient[0].hue, maxDistance: 75)
        } else {
            secondAccentHue = nil
        }

        return PaletteStats(
            avgS: avgS,
            circularVariance: variance,
            circularStdDegrees: stdDegrees,
            clusterCenters: centers,
            clusterCount: clusterCount,
            dominantHue: dominant.h,
            dominantS: dominant.s,
            dominantShare: dominantShare,
            accentHue: accentHue,
            accentShare: accentShare,
            secondAccentHue: secondAccentHue,
            grayScore: grayScore,
            isGrayscaleCover: isGrayscaleCover,
            isNearGray: isNearGray,
            lowSatColorCover: lowSatColorCover,
            lowSatSatBoost: satBoost,
            lowSatBriBoost: briBoost,
            coverKind: coverKind,
            wBlack: wBlack,
            wWhite: wWhite,
            wColor: wColor,
            coverLuma: coverLuma,
            topSalientHues: topSalient,
            evenness: evenness,
            complexity: complexity
        )
    }

    static func nearestClusterIndex(for hue: CGFloat, in clusters: [HueCluster]) -> Int? {
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

    static func inferredShares(count: Int) -> [CGFloat] {
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

    static func saliencyScore(_ color: HSBColor) -> CGFloat {
        let midBBoost = clamp(1 - abs(color.b - 0.55) / 0.55, min: 0, max: 1)
        return pow(color.s, 1.2) * (0.6 + 0.4 * midBBoost)
    }

    static func entropyNormalized(_ probabilities: [CGFloat]) -> CGFloat {
        let positive = probabilities.filter { $0 > 0.0001 }
        guard positive.count > 1 else { return 0 }
        let entropy = positive.reduce(CGFloat(0)) { partial, p in
            partial - p * log(p)
        }
        return entropy / log(CGFloat(positive.count))
    }

    static func lumaTarget(coverLuma: CGFloat, isDark: Bool) -> CGFloat {
        if isDark {
            return clamp(0.18 + 0.70 * coverLuma, min: 0.10, max: 0.62)
        }
        return clamp(0.55 + 0.55 * coverLuma, min: 0.65, max: 0.90)
    }

    static func lumaBlendK(coverKind: CoverKind) -> CGFloat {
        switch coverKind {
        case .mostlyBWWithColor:
            return 0.70
        case .grayscaleTrue:
            return 0.45
        default:
            return 0.55
        }
    }

    static func tierRanges(
        isDark: Bool,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        lowSatColorCover: Bool,
        coverKind: CoverKind
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
            bgS = 0.18...0.42
            fgS = 0.34...0.70
            dotS = 0.28...0.62
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
            bgS = makeRange(lower: bgS.lowerBound, upper: min(isDark ? 0.42 : 0.36, bgS.upperBound * 1.10))

            fgB = makeRange(
                lower: min(1, fgB.lowerBound * 1.05),
                upper: min(1, fgB.upperBound * 1.10)
            )
            dotB = makeRange(
                lower: min(1, dotB.lowerBound * 1.05),
                upper: min(1, dotB.upperBound * 1.12)
            )
        }

        // Keep hard separation: background saturation stays below foreground.
        let bgUpper = bgS.upperBound
        let fgLower = min(fgS.upperBound, max(fgS.lowerBound, bgUpper + 0.06))
        bgS = makeRange(lower: bgS.lowerBound, upper: bgUpper)
        fgS = makeRange(lower: fgLower, upper: fgS.upperBound)

        return TierRanges(bgB: bgB, fgB: fgB, dotB: dotB, bgS: bgS, fgS: fgS, dotS: dotS)
    }

    static func makeRange(lower: CGFloat, upper: CGFloat) -> ClosedRange<CGFloat> {
        if lower <= upper {
            return lower...upper
        }
        return upper...upper
    }

    static func ranges(for kind: ElementKind, palette: HarmonizedPalette)
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

    static func makeGrayscalePalette(
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
                        midpoint(tier.bgB) + (isDark ? bgBOffsetsDark[index] : bgBOffsetsLight[index]),
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
                    s: clamp(CGFloat(0.06) + CGFloat(index) * 0.015, min: tier.fgS.lowerBound, max: tier.fgS.upperBound),
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
            isDark: isDark,
            complexity: .monochrome,
            grayScore: stats.grayScore,
            isGrayscaleCover: true,
            isNearGray: false,
            bgStops: bgStops.map(toCGColor(_:)),
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

    static func grayscaleTierRanges(isDark: Bool) -> TierRanges {
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

    static func makeHueFamily(
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
            let farCandidates = clusterCenters
                .map(normalizeHue)
                .filter {
                    let d = hueDistance($0, primaryHue)
                    return d > 28 && d <= 70
                }
            if let far = farCandidates.max(by: { hueDistance($0, primaryHue) < hueDistance($1, primaryHue) }) {
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

    static func makeBackgroundStops(
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
            var targetB = clamp(bMid + bOffsets[index], min: tier.bgB.lowerBound, max: tier.bgB.upperBound)
            var targetS = clamp(sMid + sOffsets[index], min: tier.bgS.lowerBound, max: tier.bgS.upperBound)
            if lowSatColorCover {
                targetS = clamp(targetS * min(1.24, satBoost), min: tier.bgS.lowerBound, max: tier.bgS.upperBound)
                targetB = clamp(targetB * min(1.08, briBoost), min: tier.bgB.lowerBound, max: tier.bgB.upperBound)
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

    static func makeShapePool(
        primaryHue: CGFloat,
        dominantHue: CGFloat,
        dominantS: CGFloat,
        clusterCount: Int,
        hueFamily: [CGFloat],
        accentHue: CGFloat?,
        accentShare: CGFloat,
        secondAccentHue: CGFloat?,
        salientHues: [PaletteStats.SalientHue],
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
        let localOffsets: [CGFloat] = [0, 6, -6, 10, -10, 4, -4, 8, -8, 2]

        var accentQuota = 0
        if coverKind == .richDistributed, !salientHues.isEmpty {
            let top = Array(salientHues.prefix(3))
            let totalWeight = max(0.0001, top.map(\.weight).reduce(0, +))
            var assigned = 0
            for (index, salient) in top.enumerated() {
                let ratio = salient.weight / totalWeight
                var count = Int(round(CGFloat(targetCount) * ratio))
                if index < min(2, top.count) { count = max(2, count) }
                if index == top.count - 1 {
                    count = max(1, targetCount - assigned)
                }
                count = min(count, targetCount - assigned)
                assigned += count
                for n in 0..<count {
                    hueQueue.append(normalizeHue(salient.hue + localOffsets[(index + n) % localOffsets.count]))
                }
                if assigned >= targetCount { break }
            }
            while hueQueue.count < targetCount {
                hueQueue.append(normalizeHue(primaryHue + localOffsets[hueQueue.count % localOffsets.count]))
            }

            if let secondAccentHue {
                accentQuota = max(1, Int(round(Double(targetCount) * 0.20)))
                accentQuota = min(accentQuota, targetCount)
                for idx in (targetCount - accentQuota)..<targetCount {
                    let offset = localOffsets[idx % localOffsets.count]
                    hueQueue[idx] = normalizeHue(secondAccentHue + offset * 0.9)
                }
            }
        } else {
            let allowAccent = accentHue != nil && accentShare > 0 && !isNearGray && targetCount >= 8
            let accentCount = allowAccent ? 1 : 0
            let dominantRatio = isNearGray ? 0.70 : (lowSatColorCover ? 0.70 : 0.62)
            var dominantCount = max(1, Int(round(Double(targetCount) * dominantRatio)))
            dominantCount = min(dominantCount, targetCount - accentCount - 1)
            let neighborCount = max(1, targetCount - dominantCount - accentCount)

            let dominantOffsets: [CGFloat] = [0, 4, -4, 8, -8, 10, -10, 6]
            for index in 0..<dominantCount {
                let raw = normalizeHue(dominantHue + dominantOffsets[index % dominantOffsets.count])
                hueQueue.append(clampHueDistance(raw, around: dominantHue, maxDistance: isNearGray ? 12 : 18))
            }

            let neighborCandidates = hueFamily
                .filter {
                    let distance = hueDistance($0, dominantHue)
                    return distance >= 8 && distance <= (isNearGray ? 35 : 42)
                }
                .ifEmpty([normalizeHue(primaryHue + 10), normalizeHue(primaryHue - 10)])
            let neighborOffsets: [CGFloat] = [0, 2, -2, 4, -4, 6, -6]
            for index in 0..<neighborCount {
                let base = neighborCandidates[index % neighborCandidates.count]
                var candidate = normalizeHue(base + neighborOffsets[index % neighborOffsets.count])
                candidate = clampHueDistance(candidate, around: dominantHue, maxDistance: isNearGray ? 24 : 35)
                hueQueue.append(candidate)
            }

            if let accentHue, allowAccent {
                let cappedAccent = clampHueDistance(accentHue, around: dominantHue, maxDistance: 45)
                hueQueue.append(cappedAccent)
            }
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
                coverKind == .richDistributed && secondAccentHue != nil && accentQuota > 0
                && index >= (targetCount - accentQuota)
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
            let hue = clampHueDistance(rawHue, around: primaryHue, maxDistance: maxDistanceFromBg)
            var targetB = clamp(bMid + bOffsets[index], min: tier.fgB.lowerBound, max: tier.fgB.upperBound)

            var targetS = clamp(sMid + sOffsets[index], min: tier.fgS.lowerBound, max: tier.fgS.upperBound)
            if lowSatColorCover {
                targetS = clamp(targetS * satBoost, min: tier.fgS.lowerBound, max: tier.fgS.upperBound)
                targetB = clamp(targetB * briBoost, min: tier.fgB.lowerBound, max: tier.fgB.upperBound)
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

    static func makeDotBase(
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
            s = clamp(s * max(1.20, satBoost * 0.92), min: tier.dotS.lowerBound, max: tier.dotS.upperBound)
            b = clamp(b * max(1.05, briBoost * 0.95), min: tier.dotB.lowerBound, max: tier.dotB.upperBound)
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

    static func enforceDominantHueAffinity(
        dominantHue: CGFloat,
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
            if hueDistance(c.h, dominantHue) > 90 {
                c.h = clampHueDistance(c.h, around: dominantHue, maxDistance: 15)
                triggered.insert(.reverseHue)
            }
            switch kind {
            case .background:
                c.h = clampHueDistance(c.h, around: dominantHue, maxDistance: 6)
            case .shape:
                let shapeMax: CGFloat =
                    (coverKind == .richDistributed) ? 75
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

    static func enforceSaturationGap(
        bgStops: inout [HSBColor],
        shapePool: inout [HSBColor],
        tier: TierRanges,
        complexity: ColorComplexityLevel,
        isNearGray: Bool,
        isDark: Bool,
        triggered: inout Set<RiskFlag>
    ) {
        guard let maxBg = bgStops.map(\.s).max(), let minFg = shapePool.map(\.s).min() else { return }
        let requiredGap: CGFloat = 0.08
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

    static func enforceBrightnessHierarchy(
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

    static func selectPrimaryHue(
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
                return partial + salient.weight * proximity * (coverKind == .richDistributed ? 0.85 : 0.55)
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

    static func isValidPrimaryCandidate(_ c: HSBColor) -> Bool {
        if c.b < 0.10 { return false }
        if c.b > 0.96 && c.s < 0.22 { return false }
        if c.b > 0.20 && c.b < 0.85 && c.s < 0.10 { return false }
        return true
    }

    static func adjustPrimaryHue(_ hue: CGFloat, triggered: inout Set<RiskFlag>) -> CGFloat {
        var h = normalizeHue(hue)

        if inRange(h, 92, 140) {
            triggered.insert(.greenDanger)
            h = abs(h - 90) <= abs(h - 148) ? 90 : 148
        }

        if inRange(h, 45, 78) {
            triggered.insert(.muddyYellow)
            h = (h > 66) ? 85 : 38
        }

        if inRedZone(h) {
            triggered.insert(.plasticRed)
            h = lerpHue(h, to: 22, t: 0.18)
        }

        let blandRanges: [(CGFloat, CGFloat)] = [(120, 170), (35, 55), (75, 92), (140, 160)]
        if blandRanges.contains(where: { inRange(h, $0.0, $0.1) }) {
            let preferred: [CGFloat] = [220, 190, 265, 28, 350]
            let nearest = preferred.min { hueDistance(h, $0) < hueDistance(h, $1) } ?? 220
            h = lerpHue(h, to: nearest, t: 0.22)
        }

        return normalizeHue(h)
    }

    static func sanitize(
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

        let hardCap = saturationHardCap(
            kind: kind,
            isDark: isDark,
            complexity: complexity,
            isNearGray: isNearGray
        )
        let sLower = max(sRange.lowerBound, sMin(forBrightness: c.b))
        let sUpper = min(sRange.upperBound, sMax(forBrightness: c.b), hardCap)
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

        c.b = clamp(c.b, min: bRange.lowerBound, max: bRange.upperBound)
        let finalLower = max(sRange.lowerBound, sMin(forBrightness: c.b))
        let finalUpper = min(sRange.upperBound, sMax(forBrightness: c.b), hardCap)
        c.s = clamp(c.s, min: finalLower, max: finalUpper)
        return c
    }

    static func applyRiskRules(
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
            let floor = max(bRange.lowerBound, kind == .background ? 0.30 : 0.38)
            c.b = max(c.b, floor)
        }

        if inRedZone(c.h) {
            triggered.insert(.plasticRed)
            c.h = lerpHue(c.h, to: 22, t: 0.18)
            let cap: CGFloat = (kind == .background) ? 0.45 : 0.62
            c.s = min(c.s, cap)
            let bLow = max(bRange.lowerBound, kind == .background ? 0.24 : 0.30)
            let bHigh = min(bRange.upperBound, kind == .background ? 0.60 : 0.78)
            c.b = clamp(c.b, min: bLow, max: bHigh)
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

    static func riskPenalty(h: CGFloat, s: CGFloat, b: CGFloat) -> CGFloat {
        var penalty: CGFloat = 0

        if inRange(h, 92, 140) {
            penalty += 0.42 + max(0, s - 0.34) * 0.9
        }
        if inRange(h, 45, 78) {
            penalty += 0.55 + max(0, 0.40 - b) * 1.2 + max(0, s - 0.42) * 0.7
        }
        if inRedZone(h) {
            penalty += 0.35 + max(0, s - 0.60) * 1.3 + max(0, b - 0.78) * 0.8
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

    static func saturationHardCap(
        kind: ElementKind,
        isDark: Bool,
        complexity: ColorComplexityLevel,
        isNearGray: Bool
    ) -> CGFloat {
        let base: CGFloat
        switch kind {
        case .background:
            base = isDark ? 0.42 : 0.36
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

    static func sMax(forBrightness b: CGFloat) -> CGFloat {
        if b < 0.22 { return 0.38 }
        if b < 0.40 { return lerp(0.38, 0.68, t: (b - 0.22) / (0.40 - 0.22)) }
        if b < 0.75 { return 0.68 }
        if b < 0.88 { return lerp(0.68, 0.52, t: (b - 0.75) / (0.88 - 0.75)) }
        return 0.52
    }

    static func sMin(forBrightness b: CGFloat) -> CGFloat {
        if b < 0.22 { return 0.08 }
        if b < 0.40 { return lerp(0.08, 0.12, t: (b - 0.22) / (0.40 - 0.22)) }
        if b < 0.75 { return 0.12 }
        if b < 0.88 { return lerp(0.12, 0.10, t: (b - 0.75) / (0.88 - 0.75)) }
        return 0.10
    }

    static func logPalette(
        primaryBefore: CGFloat,
        primaryAfter: CGFloat,
        stats: PaletteStats,
        tier: TierRanges,
        triggered: Set<RiskFlag>,
        bgStops: [HSBColor],
        shapePool: [HSBColor],
        dotBase: HSBColor
    ) {
        let triggerText = triggered.isEmpty
            ? "none"
            : triggered.map(\.rawValue).sorted().joined(separator: ", ")

        let shapeHues = shapePool.map { normalizeHue($0.h) }
        let hueSpan = hueSpanAround(reference: primaryAfter, hues: shapeHues)
        let hueDist = shapeHues.map { Int(round($0)) }.sorted().map(String.init).joined(separator: ",")
        let salientText = stats.topSalientHues.prefix(3).map {
            "\(f1($0.hue))@\(f3($0.weight))"
        }.joined(separator: " | ")

        print(
            "[BKColorEngine] coverKind=\(stats.coverKind.rawValue) complexity=\(stats.complexity.rawValue) avgS=\(f3(stats.avgS)) grayScore=\(f3(stats.grayScore)) wBlack=\(f3(stats.wBlack)) wWhite=\(f3(stats.wWhite)) wColor=\(f3(stats.wColor)) coverLuma=\(f3(stats.coverLuma)) evenness=\(f3(stats.evenness)) gray=\(stats.isGrayscaleCover ? 1 : 0) nearGray=\(stats.isNearGray ? 1 : 0) lowSatColor=\(stats.lowSatColorCover ? 1 : 0)"
        )
        print(
            "[BKColorEngine] primaryHue before=\(f1(primaryBefore)) after=\(f1(primaryAfter)) dominantHue=\(f1(stats.dominantHue)) dominantShare=\(f3(stats.dominantShare)) accentHue=\(stats.accentHue.map(f1) ?? "none") secondAccent=\(stats.secondAccentHue.map(f1) ?? "none") triggers=\(triggerText)"
        )
        print(
            "[BKColorEngine] ranges bgB=\(f3(tier.bgB.lowerBound))...\(f3(tier.bgB.upperBound)) bgS=\(f3(tier.bgS.lowerBound))...\(f3(tier.bgS.upperBound)) fgB=\(f3(tier.fgB.lowerBound))...\(f3(tier.fgB.upperBound)) fgS=\(f3(tier.fgS.lowerBound))...\(f3(tier.fgS.upperBound)) dotB=\(f3(tier.dotB.lowerBound))...\(f3(tier.dotB.upperBound)) dotS=\(f3(tier.dotS.lowerBound))...\(f3(tier.dotS.upperBound))"
        )
        print("[BKColorEngine] topSalientHues \(salientText)")

        if let bg0 = bgStops.first, let shape0 = shapePool.first {
            print(
                "[BKColorEngine] sample bgStop0{b=\(f3(bg0.b)) s=\(f3(bg0.s))} shape0{b=\(f3(shape0.b)) s=\(f3(shape0.s))} dotBase{b=\(f3(dotBase.b)) s=\(f3(dotBase.s))}"
            )
        }

        print("[BKColorEngine] shapePoolHueDist [\(hueDist)] maxHueDelta=\(f1(hueSpan)) secondAccentEnabled=\(stats.secondAccentHue != nil ? 1 : 0)")
        if hueSpan > 90, stats.complexity != .high {
            print("[BKColorEngine][WARN] hue span exceeds 90 in non-high complexity")
        }

        let bgText = bgStops.enumerated().map { "\($0):{\(hsbString($1))}" }.joined(separator: " ")
        let shapeText = shapePool.enumerated().map { "\($0):{\(hsbString($1))}" }.joined(separator: " ")
        print("[BKColorEngine] bgStopsHSB \(bgText)")
        print("[BKColorEngine] shapePoolHSB \(shapeText)")
        print("[BKColorEngine] dotBaseHSB \(hsbString(dotBase))")
    }

    static func hueSpanAround(reference: CGFloat, hues: [CGFloat]) -> CGFloat {
        guard !hues.isEmpty else { return 0 }
        let offsets = hues.map { signedHueOffset(from: reference, to: $0) }
        let minOffset = offsets.min() ?? 0
        let maxOffset = offsets.max() ?? 0
        return maxOffset - minOffset
    }

    static func hsbString(_ c: HSBColor) -> String {
        "h=\(f1(c.h)) s=\(f3(c.s)) b=\(f3(c.b))"
    }

    static func hsb(from color: NSColor) -> HSBColor? {
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

    static func hsb(from color: CGColor) -> HSBColor? {
        guard let ns = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return nil }
        return hsb(from: ns)
    }

    static func toCGColor(_ c: HSBColor) -> CGColor {
        let deviceColor = NSColor(
            deviceHue: normalizeHue(c.h) / 360,
            saturation: clamp01(c.s),
            brightness: clamp01(c.b),
            alpha: clamp01(c.a)
        )
        return (deviceColor.usingColorSpace(.deviceRGB) ?? deviceColor).cgColor
    }

    static func midpoint(_ range: ClosedRange<CGFloat>) -> CGFloat {
        (range.lowerBound + range.upperBound) * 0.5
    }

    static func inRange(_ hue: CGFloat, _ minDeg: CGFloat, _ maxDeg: CGFloat) -> Bool {
        let h = normalizeHue(hue)
        let lo = normalizeHue(minDeg)
        let hi = normalizeHue(maxDeg)
        if lo <= hi {
            return h >= lo && h <= hi
        }
        return h >= lo || h <= hi
    }

    static func inRedZone(_ hue: CGFloat) -> Bool {
        inRange(hue, 350, 360) || inRange(hue, 0, 15)
    }

    static func hueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        abs(signedHueOffset(from: lhs, to: rhs))
    }

    static func signedHueOffset(from: CGFloat, to: CGFloat) -> CGFloat {
        let a = normalizeHue(from)
        let b = normalizeHue(to)
        var delta = b - a
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    static func clampHueDistance(_ hue: CGFloat, around center: CGFloat, maxDistance: CGFloat)
        -> CGFloat
    {
        let delta = signedHueOffset(from: center, to: hue)
        let clamped = clamp(delta, min: -maxDistance, max: maxDistance)
        return normalizeHue(center + clamped)
    }

    static func lerpHue(_ from: CGFloat, to: CGFloat, t: CGFloat) -> CGFloat {
        let delta = signedHueOffset(from: from, to: to)
        return normalizeHue(from + delta * clamp(t, min: 0, max: 1))
    }

    static func normalizeHue(_ hue: CGFloat) -> CGFloat {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }

    static func dedupeHues(_ hues: [CGFloat]) -> [CGFloat] {
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

    static func deg2rad(_ value: CGFloat) -> CGFloat {
        value * .pi / 180
    }

    static func rad2deg(_ value: CGFloat) -> CGFloat {
        value * 180 / .pi
    }

    static func clamp01(_ value: CGFloat) -> CGFloat {
        clamp(value, min: 0, max: 1)
    }

    static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.min(maxValue, Swift.max(minValue, value))
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * clamp(t, min: 0, max: 1)
    }

    static func f1(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    static func f3(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}

private extension Array {
    func ifEmpty(_ fallback: @autoclosure () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
    }
}

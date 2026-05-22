//
//  ArtworkColorAnalysis.swift
//  myPlayer2
//
//  Single statistical analysis pass over an artwork. All semantic role
//  colors (ThemeStore accent, BKArt background, lyrics colors, Home Hero
//  text) derive from this structure rather than re-running pixel sampling.
//
//  Phase 2 introduces two orthogonal axes on top of the original signal:
//    - `isUltraDark` — pure lightness / luminance regime, "is this a
//      night-feel cover regardless of whether it carries hue?"
//    - `isNearMonochrome` — pure chromatic confidence regime, "is the
//      cover's hue trustworthy or is it grey/black/white at heart?"
//
//  These two flags are independent (any of four combinations is possible).
//  The legacy `isEffectivelyMonochrome` is kept as an alias of
//  `isNearMonochrome` so existing consumers (LED resolver, Home shapes,
//  BKArt, theme log) compile unchanged. Their behaviour changes only for
//  the narrow class of covers that the old definition mis-classified —
//  i.e. dark covers with usable hue ("極暗有色"), which the new flag
//  correctly leaves in the non-mono regime per K.2.
//
//  Phase 2 also exposes two new structured palettes:
//    - `salientHighlightPalette` — small-area but visually striking
//      colours (designer-grade "accent" picks);
//    - `displayPalette` — quality-controlled merge intended for the
//      Phase 3 multi-colour consumers (Home Shapes, BKArt, Spectrum).
//

import AppKit

nonisolated struct ArtworkColorAnalysis: Equatable, Sendable {
    let avgHue: CGFloat                 // circular [0,1)
    let dominantHue: CGFloat
    let dominantHueConfidence: CGFloat  // top bucket weight / total
    let avgSaturation: CGFloat
    let avgBrightness: CGFloat          // HSB
    let avgHslLightness: CGFloat
    let weightedLuma: CGFloat           // WCAG relative luminance, weighted
    let saturationVariance: CGFloat
    let lightnessVariance: CGFloat
    let colorfulness: CGFloat           // 0..1
    let dominantSaturation: CGFloat
    let dominantBrightness: CGFloat     // HSB B of dominant bucket
    let largestHighSaturationAreaShare: CGFloat
    let highSaturationAreaShare: CGFloat
    let isMonochrome: Bool
    /// Pure chromatic-confidence regime. True when the cover lacks a
    /// trustworthy hue. Independent of lightness.
    let isNearMonochrome: Bool
    /// Pure lightness regime. True when the cover is a night-feel cover
    /// (very dark on both HSL average and WCAG luma). Independent of hue.
    let isUltraDark: Bool
    /// Backwards-compatible alias of `isNearMonochrome`. Pre-Phase-2
    /// callers (LED, Home shapes, BKArt) read this; Phase 2 deliberately
    /// leaves the name in place but corrects its definition (the old
    /// branch 4, which folded extreme lightness into chromatic
    /// classification, is gone — see K.2 / J.2.d).
    let isEffectivelyMonochrome: Bool
    let hasStrongAccentRegion: Bool
    let usesDarkForeground: Bool

    let dominantColor: NSColor          // top bucket centroid (raw, NOT yet UI-tuned)
    let averageColor: NSColor
    let topPalette: [NSColor]           // up to 4 distinct colours
    let richPalette: [NSColor]          // up to 8 (artistic)
    /// Small-area, high-visual-impact colours suitable as accents /
    /// decorative highlights. Empty on near-monochrome covers (no
    /// fabrication).
    let salientHighlightPalette: [NSColor]
    /// Quality-controlled multi-colour palette for downstream visual
    /// consumers (Phase 3: Home Shapes, BKArt, Spectrum). Narrowed on
    /// near-monochrome covers; never synthesised via hue rotation.
    let displayPalette: [NSColor]
    let bestTextSourceColor: NSColor    // most colourful mid-tone bucket

    static let neutralFallback = ArtworkColorAnalysis(
        avgHue: 0.10,
        dominantHue: 0.10,
        dominantHueConfidence: 0,
        avgSaturation: 0.18,
        avgBrightness: 0.62,
        avgHslLightness: 0.62,
        weightedLuma: 0.55,
        saturationVariance: 0,
        lightnessVariance: 0,
        colorfulness: 0,
        dominantSaturation: 0.10,
        dominantBrightness: 0.62,
        largestHighSaturationAreaShare: 0,
        highSaturationAreaShare: 0,
        isMonochrome: true,
        isNearMonochrome: true,
        isUltraDark: false,
        isEffectivelyMonochrome: true,
        hasStrongAccentRegion: false,
        usesDarkForeground: true,
        dominantColor: NSColor(deviceRed: 1.0, green: 200/255, blue: 120/255, alpha: 1),
        averageColor: NSColor(deviceRed: 1.0, green: 200/255, blue: 120/255, alpha: 1),
        topPalette: [],
        richPalette: [],
        salientHighlightPalette: [],
        displayPalette: [],
        bestTextSourceColor: NSColor(deviceRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
    )
}

extension ArtworkColorExtractor {
    /// Single full-pass analysis of an artwork. The returned analysis is the
    /// canonical input for SemanticPaletteFactory and any downstream colour
    /// surface (BKColorEngine, HomeHero, CoverGradientBlur, lyrics).
    nonisolated static func analyze(from data: Data) -> ArtworkColorAnalysis? {
        guard let sample = sampledBitmap(from: data, side: 64) else { return nil }
        return analyzeInternal(sample: sample)
    }

    /// Test / self-check entry point. Accepts a synthetic RGBA pixel buffer
    /// without going through `CGImageSource`, so the colour decision engine
    /// can be exercised with deterministic inputs (see
    /// `ColorSystemSelfCheck`).
    nonisolated static func analyzeSyntheticSample(
        pixels: [UInt8],
        side: Int
    ) -> ArtworkColorAnalysis? {
        let sample = ArtworkBitmapSample(pixels: pixels, side: side)
        return analyzeInternal(sample: sample)
    }

    fileprivate nonisolated static func analyzeInternal(
        sample: ArtworkBitmapSample
    ) -> ArtworkColorAnalysis? {
        let pixels = sample.pixels
        guard !pixels.isEmpty else { return nil }

        let bucketCount = 48
        var buckets = [HueBucket](repeating: .zero, count: bucketCount)

        var totalWeight: CGFloat = 0
        var weightedR: CGFloat = 0
        var weightedG: CGFloat = 0
        var weightedB: CGFloat = 0
        var satSum: CGFloat = 0
        var briSum: CGFloat = 0
        var hslLSum: CGFloat = 0
        var lumaSum: CGFloat = 0
        var hueSinSum: CGFloat = 0
        var hueCosSum: CGFloat = 0
        var vividWeight: CGFloat = 0
        // For Welford-style variance accumulators (saturation, HSL lightness)
        var satMean: CGFloat = 0
        var satM2: CGFloat = 0
        var lMean: CGFloat = 0
        var lM2: CGFloat = 0
        var weightProcessed: CGFloat = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255.0
            let g = CGFloat(pixels[i + 1]) / 255.0
            let b = CGFloat(pixels[i + 2]) / 255.0
            let a = CGFloat(pixels[i + 3]) / 255.0
            if a < 0.08 { continue }

            let rgb = NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
                .usingColorSpace(.deviceRGB) ?? NSColor.gray
            var hue: CGFloat = 0
            var sat: CGFloat = 0
            var bri: CGFloat = 0
            var alpha: CGFloat = 0
            rgb.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            let hslL = (maxRGB + minRGB) * 0.5
            let luma = ColorMath.relativeLuminance(of: rgb)

            // Mirror the existing uiThemePalette weighting so that downstream
            // dominantHue / topPalette are consistent with the rest of the system.
            let areaWeight = a
            let toneWeight = 0.90 + max(0, 1 - abs(bri - 0.5) * 1.8) * 0.20
            let satWeight  = 0.90 + sat * 0.20
            var weight = areaWeight * toneWeight * satWeight
            if sat < 0.04 { weight *= 0.82 }
            if weight < 0.000_1 { continue }

            totalWeight += weight
            weightedR += r * weight
            weightedG += g * weight
            weightedB += b * weight
            satSum += sat * weight
            briSum += bri * weight
            hslLSum += hslL * weight
            lumaSum += luma * weight

            // Circular hue mean via vector sum.
            let theta = hue * 2 * .pi
            hueSinSum += sin(theta) * weight
            hueCosSum += cos(theta) * weight

            if sat > 0.28 { vividWeight += weight * min(1.2, sat * 1.1) }

            // Welford running variance (weighted) for saturation + HSL L.
            weightProcessed += weight
            let satDelta = sat - satMean
            satMean += satDelta * (weight / weightProcessed)
            satM2 += weight * satDelta * (sat - satMean)
            let lDelta = hslL - lMean
            lMean += lDelta * (weight / weightProcessed)
            lM2 += weight * lDelta * (hslL - lMean)

            let idx = min(bucketCount - 1, max(0, Int(floor(hue * CGFloat(bucketCount)))))
            buckets[idx].weight += weight
            buckets[idx].r += r * weight
            buckets[idx].g += g * weight
            buckets[idx].b += b * weight
        }

        guard totalWeight > 0 else { return nil }

        let avgSat = satSum / totalWeight
        let avgBri = briSum / totalWeight
        let avgHslL = hslLSum / totalWeight
        let avgLuma = lumaSum / totalWeight
        let satVar = weightProcessed > 0 ? satM2 / weightProcessed : 0
        let lVar   = weightProcessed > 0 ? lM2 / weightProcessed   : 0
        let colorfulness = ColorMath.clamp(vividWeight / totalWeight, 0, 1)

        // Average hue (circular).
        let avgHueAngle = atan2(hueSinSum, hueCosSum) / (2 * .pi)
        let avgHue = ColorMath.normalizedHue(avgHueAngle)

        // Top bucket → dominant hue + dominantHueConfidence.
        var topIdx = 0
        var topW: CGFloat = 0
        for (i, bucket) in buckets.enumerated() where bucket.weight > topW {
            topW = bucket.weight
            topIdx = i
        }
        let topBucket = buckets[topIdx]
        let dominantHueConfidence = topW / totalWeight
        let dominantColor: NSColor = {
            guard topBucket.weight > 0 else {
                return NSColor(
                    deviceRed: weightedR / totalWeight,
                    green: weightedG / totalWeight,
                    blue: weightedB / totalWeight,
                    alpha: 1
                )
            }
            let inv = 1 / topBucket.weight
            return NSColor(
                deviceRed: ColorMath.clamp(topBucket.r * inv, 0, 1),
                green: ColorMath.clamp(topBucket.g * inv, 0, 1),
                blue: ColorMath.clamp(topBucket.b * inv, 0, 1),
                alpha: 1
            )
        }()
        let dominantHue: CGFloat = {
            let rgb = dominantColor.usingColorSpace(.deviceRGB) ?? dominantColor
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return h
        }()
        let dominantBrightness: CGFloat = {
            let rgb = dominantColor.usingColorSpace(.deviceRGB) ?? dominantColor
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return b
        }()

        var dominantSaturation: CGFloat = 0
        var highSaturationAreaShare: CGFloat = 0
        var largestHighSaturationAreaShare: CGFloat = 0

        var hasStrong = false
        // hasStrongAccentRegion: any bucket with >= 18% area AND >= 0.50 saturation.
        for bucket in buckets {
            guard bucket.weight > 0 else { continue }
            let inv = 1 / bucket.weight
            let bColor = NSColor(
                deviceRed: ColorMath.clamp(bucket.r * inv, 0, 1),
                green: ColorMath.clamp(bucket.g * inv, 0, 1),
                blue: ColorMath.clamp(bucket.b * inv, 0, 1),
                alpha: 1
            )
            let s = saturationValue(of: bColor)
            let areaShare = bucket.weight / totalWeight
            if s >= 0.35 {
                highSaturationAreaShare += areaShare
                largestHighSaturationAreaShare = max(largestHighSaturationAreaShare, areaShare)
            }
            if bucket.weight == topW {
                dominantSaturation = s
            }
            if areaShare >= 0.18 && s >= 0.50 {
                hasStrong = true
            }
        }

        // -------- Chromatic axis (Phase 2: isNearMonochrome) --------
        //
        // Branch 4 of the legacy gate folded lightness into this signal —
        // Phase 2 drops it and gives that responsibility to UltraDark.
        // The remaining four branches are pure colour-confidence tests.

        // Phase 6.2 — chromatic trust override. If the dominant centroid OR
        // any topPalette / salient candidate carries OKLCH chroma at or
        // above `trustedHueChromaFloor`, the cover has a hue identity even
        // when the average saturation looks low (compressed JPEGs, vintage
        // prints, warm-tinted photos). Without this override the historical
        // 4-branch OR would grey-wash these covers — exactly the "明明有颜色
        // 但歌词变成灰白" report.
        let phase62TopPalette = uiThemePalette(from: sample, targetCount: 4)
        let phase62SalientCandidates = computeSalientHighlights(
            buckets: buckets,
            totalWeight: totalWeight,
            dominantHue: dominantHue
        )
        let dominantLCH = OKColor.nsColorToOKLCH(dominantColor)
        let topLCHs: [OKColor.OKLCH] = phase62TopPalette.compactMap { OKColor.nsColorToOKLCH($0) }
        let salientLCHs: [OKColor.OKLCH] = phase62SalientCandidates
            .compactMap { OKColor.nsColorToOKLCH($0) }
        let hasTrustedHue =
            (dominantLCH?.c ?? 0) >= ColorSystemTokens.NearMonochromeProfile.trustedHueChromaFloor
            || topLCHs.contains(where: { $0.c >= ColorSystemTokens.NearMonochromeProfile.trustedHueChromaFloor })
            || salientLCHs.contains(where: { $0.c >= ColorSystemTokens.NearMonochromeProfile.trustedHueChromaFloor })

        let isMono = colorfulness < ColorSystemTokens.NearMonochromeProfile.strictColorfulness
            && avgSat < ColorSystemTokens.NearMonochromeProfile.strictAvgSaturation
        // Phase 6.2: strict mono (branch 1) is unconditional; the other 3
        // OR branches are skipped when `hasTrustedHue == true`.
        let isNearMonochrome =
            isMono
            || (!hasTrustedHue && (
                (colorfulness < ColorSystemTokens.NearMonochromeProfile.lowColorfulness
                    && avgSat < ColorSystemTokens.NearMonochromeProfile.lowAvgSaturation
                    && largestHighSaturationAreaShare
                        < ColorSystemTokens.NearMonochromeProfile.lowMaxHighSatAreaShare)
                || (avgSat < ColorSystemTokens.NearMonochromeProfile.subtleAvgSaturation
                    && colorfulness < ColorSystemTokens.NearMonochromeProfile.subtleColorfulness
                    && largestHighSaturationAreaShare
                        < ColorSystemTokens.NearMonochromeProfile.subtleMaxHighSatAreaShare)
                || (dominantSaturation
                        < ColorSystemTokens.NearMonochromeProfile.dominantBucketSaturation
                    && colorfulness
                        < ColorSystemTokens.NearMonochromeProfile.dominantBucketColorfulness
                    && avgSat
                        < ColorSystemTokens.NearMonochromeProfile.dominantBucketAvgSaturation)
            ))

        // -------- Lightness axis (Phase 2: isUltraDark) --------
        //
        // Three gates, all pure lightness. A cover only counts as UltraDark
        // when it is dim on the HSL average AND on perceptual luma AND its
        // dominant bucket itself is not bright (a single neon highlight on
        // a black background is not UltraDark — `dominantBrightnessCeiling`
        // is what rules that out).

        let isUltraDark =
            avgHslL <= ColorSystemTokens.UltraDark.cutoffAvgHslL
            && avgLuma <= ColorSystemTokens.UltraDark.cutoffWcagLuma
            && dominantBrightness <= ColorSystemTokens.UltraDark.dominantBrightnessCeiling

        let usesDark = avgHslL >= ColorSystemTokens.ReadabilityForeground.usesDarkAvgHslL

        let averageColor = NSColor(
            deviceRed: ColorMath.clamp(weightedR / totalWeight, 0, 1),
            green: ColorMath.clamp(weightedG / totalWeight, 0, 1),
            blue: ColorMath.clamp(weightedB / totalWeight, 0, 1),
            alpha: 1
        )

        // Reuse existing palette helpers so dominantHue / topPalette stay in sync
        // with the rest of the system.
        let topPalette = uiThemePalette(from: sample, targetCount: 4)
        let richPalette = uiThemePaletteRich(from: sample, targetCount: 8)
        let bestText = textSourceColor(from: buckets, fallback: averageColor)

        // Phase 2 structured outputs.
        //
        // `salientHighlightPalette` is computed *regardless* of
        // isNearMonochrome — the whole point of the structure is to
        // recover small-area but high-impact accents on covers whose
        // chromatic average looks bland. The 95% gray + 5% bright yellow
        // case lives here: the cover IS near-monochrome on average, but
        // the yellow is a real highlight and must survive.
        //
        // `displayPalette` is the place where we resist fabricating
        // multi-colour: on near-monochrome covers it caps to a small
        // count (top + salient, no rich expansion) so downstream UI
        // doesn't gain a colour the cover doesn't really have.
        let salient = computeSalientHighlights(
            buckets: buckets,
            totalWeight: totalWeight,
            dominantHue: dominantHue
        )

        let displayPalette = computeDisplayPalette(
            top: topPalette,
            salient: salient,
            rich: richPalette,
            isNearMonochrome: isNearMonochrome
        )

        return ArtworkColorAnalysis(
            avgHue: avgHue,
            dominantHue: dominantHue,
            dominantHueConfidence: dominantHueConfidence,
            avgSaturation: avgSat,
            avgBrightness: avgBri,
            avgHslLightness: avgHslL,
            weightedLuma: avgLuma,
            saturationVariance: satVar,
            lightnessVariance: lVar,
            colorfulness: colorfulness,
            dominantSaturation: dominantSaturation,
            dominantBrightness: dominantBrightness,
            largestHighSaturationAreaShare: largestHighSaturationAreaShare,
            highSaturationAreaShare: highSaturationAreaShare,
            isMonochrome: isMono,
            isNearMonochrome: isNearMonochrome,
            isUltraDark: isUltraDark,
            isEffectivelyMonochrome: isNearMonochrome,
            hasStrongAccentRegion: hasStrong,
            usesDarkForeground: usesDark,
            dominantColor: dominantColor,
            averageColor: averageColor,
            topPalette: topPalette,
            richPalette: richPalette,
            salientHighlightPalette: salient,
            displayPalette: displayPalette,
            bestTextSourceColor: bestText
        )
    }
}

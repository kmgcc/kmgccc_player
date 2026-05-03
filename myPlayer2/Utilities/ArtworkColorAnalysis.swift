//
//  ArtworkColorAnalysis.swift
//  myPlayer2
//
//  Single statistical analysis pass over an artwork. All semantic role
//  colors (ThemeStore accent, BKArt background, lyrics colors, Home Hero
//  text) derive from this structure rather than re-running pixel sampling.
//

import AppKit

struct ArtworkColorAnalysis: Equatable, Sendable {
    let avgHue: CGFloat                 // circular [0,1)
    let dominantHue: CGFloat
    let dominantHueConfidence: CGFloat  // top bucket weight / total
    let avgSaturation: CGFloat
    let avgBrightness: CGFloat          // HSB
    let avgHslLightness: CGFloat
    let saturationVariance: CGFloat
    let lightnessVariance: CGFloat
    let colorfulness: CGFloat           // 0..1
    let isMonochrome: Bool
    let hasStrongAccentRegion: Bool
    let usesDarkForeground: Bool

    let dominantColor: NSColor          // top bucket centroid (raw, NOT yet UI-tuned)
    let averageColor: NSColor
    let topPalette: [NSColor]           // up to 4 distinct colours
    let richPalette: [NSColor]          // up to 8 (artistic)
    let bestTextSourceColor: NSColor    // most colourful mid-tone bucket

    static let neutralFallback = ArtworkColorAnalysis(
        avgHue: 0.10,
        dominantHue: 0.10,
        dominantHueConfidence: 0,
        avgSaturation: 0.18,
        avgBrightness: 0.62,
        avgHslLightness: 0.62,
        saturationVariance: 0,
        lightnessVariance: 0,
        colorfulness: 0,
        isMonochrome: true,
        hasStrongAccentRegion: false,
        usesDarkForeground: true,
        dominantColor: NSColor(deviceRed: 1.0, green: 200/255, blue: 120/255, alpha: 1),
        averageColor: NSColor(deviceRed: 1.0, green: 200/255, blue: 120/255, alpha: 1),
        topPalette: [],
        richPalette: [],
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

        // hasStrongAccentRegion: any bucket with >= 18% area AND >= 0.50 saturation.
        let hasStrong = buckets.contains { bucket in
            guard bucket.weight > 0 else { return false }
            let inv = 1 / bucket.weight
            let bColor = NSColor(
                deviceRed: ColorMath.clamp(bucket.r * inv, 0, 1),
                green: ColorMath.clamp(bucket.g * inv, 0, 1),
                blue: ColorMath.clamp(bucket.b * inv, 0, 1),
                alpha: 1
            )
            let s = saturationValue(of: bColor)
            return (bucket.weight / totalWeight) >= 0.18 && s >= 0.50
        }

        let isMono = colorfulness < 0.04 && avgSat < 0.10
        let usesDark = avgHslL >= 0.58

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

        return ArtworkColorAnalysis(
            avgHue: avgHue,
            dominantHue: dominantHue,
            dominantHueConfidence: dominantHueConfidence,
            avgSaturation: avgSat,
            avgBrightness: avgBri,
            avgHslLightness: avgHslL,
            saturationVariance: satVar,
            lightnessVariance: lVar,
            colorfulness: colorfulness,
            isMonochrome: isMono,
            hasStrongAccentRegion: hasStrong,
            usesDarkForeground: usesDark,
            dominantColor: dominantColor,
            averageColor: averageColor,
            topPalette: topPalette,
            richPalette: richPalette,
            bestTextSourceColor: bestText
        )
    }
}

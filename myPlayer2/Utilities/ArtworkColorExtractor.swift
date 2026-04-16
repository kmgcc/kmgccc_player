//
//  ArtworkColorExtractor.swift
//  myPlayer2
//
//  kmgccc_player - Artwork Color Extraction
//  Computes artwork colors for lyrics and UI themes.
//

import AppKit
import ImageIO

public enum ArtworkColorExtractor {

    // Pixel data cache to avoid repeated decode + CGContext creation.
    private final class PixelCacheBox: @unchecked Sendable {
        nonisolated(unsafe) let cache: NSCache<NSString, PixelDataCacheEntry> = {
            let cache = NSCache<NSString, PixelDataCacheEntry>()
            cache.countLimit = 256
            cache.totalCostLimit = 8 * 1024 * 1024
            return cache
        }()
    }

    struct ArtworkBitmapSample: Sendable {
        let pixels: [UInt8]
        let side: Int
    }

    private nonisolated static let pixelCache = PixelCacheBox()
    
    private final class PixelDataCacheEntry: NSObject {
        let pixels: [UInt8]
        let side: Int
        let checksum: UInt64
        
        nonisolated init(pixels: [UInt8], side: Int, checksum: UInt64) {
            self.pixels = pixels
            self.side = side
            self.checksum = checksum
            super.init()
        }
    }
    
    private nonisolated static func computeChecksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }
    
    private nonisolated static func cacheKey(for checksum: UInt64, side: Int) -> NSString {
        "\(checksum)-\(side)" as NSString
    }

    public nonisolated static func averageColor(from data: Data) -> NSColor? {
        guard let sample = sampledBitmap(from: data, side: 48) else { return nil }
        return averageColor(from: sample)
    }

    public nonisolated static func adjustedAccent(from color: NSColor, isDarkMode: Bool) -> NSColor
    {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Keep color soft and readable (avoid heavy saturation).
        saturation = min(max(saturation, 0.08), 0.22)

        if isDarkMode {
            // Near-white in dark mode.
            brightness = min(max(brightness, 0.98), 1.0)
        } else {
            // Near-black in light mode.
            brightness = min(max(brightness, 0.08), 0.15)
        }

        return NSColor(
            calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
    }

    /// Theme palette for UI backgrounds. Returns 2-3 distinct artwork colors by default.
    public nonisolated static func uiThemePalette(from data: Data, maxColors: Int = 3) -> [NSColor]
    {
        let targetCount = min(max(2, maxColors), 4)
        guard let sample = sampledBitmap(from: data, side: 56) else { return [] }
        return uiThemePalette(from: sample, targetCount: targetCount)
    }

    /// Accent for UI tinting (skins/components), decoupled from lyrics text color.
    /// Keeps color close to artwork dominant hue and slightly richer, while avoiding
    /// dead-black / near-white extremes.
    public nonisolated static func uiAccentColor(from data: Data) -> NSColor? {
        uiThemePalette(from: data, maxColors: 3).first
    }

    /// Rich palette for artistic backgrounds.
    /// Unlike uiThemePalette, this does not synthesize variants; it returns
    /// distinct colors that already exist in the artwork.
    public nonisolated static func uiThemePaletteRich(from data: Data, desiredCount: Int = 6)
        -> [NSColor]
    {
        let targetCount = min(max(3, desiredCount), 8)
        guard let sample = sampledBitmap(from: data, side: 72) else { return [] }
        return uiThemePaletteRich(from: sample, targetCount: targetCount)
    }

    public static func cssRGBA(_ color: NSColor, alpha: CGFloat) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return "rgba(255,255,255,\(alpha))"
        }

        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return "rgba(\(r),\(g),\(b),\(alpha))"
    }

    /// Very fast accent estimate used to avoid "one-track-behind" tinting while
    /// the full dominant-color extraction runs.
    public static func quickAccentSample(from data: Data, side: Int = 18) -> NSColor? {
        let s = max(8, min(32, side))
        guard let pixels = resizedPixels(from: data, side: s) else { return nil }

        var rSum: CGFloat = 0
        var gSum: CGFloat = 0
        var bSum: CGFloat = 0
        var weightSum: CGFloat = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = CGFloat(pixels[i + 3]) / 255.0
            if a < 0.10 { continue }

            let w = a
            rSum += (CGFloat(pixels[i]) / 255.0) * w
            gSum += (CGFloat(pixels[i + 1]) / 255.0) * w
            bSum += (CGFloat(pixels[i + 2]) / 255.0) * w
            weightSum += w
        }

        guard weightSum > 0 else { return nil }
        return NSColor(
            calibratedRed: rSum / weightSum,
            green: gSum / weightSum,
            blue: bSum / weightSum,
            alpha: 1.0
        )
    }
}

extension ArtworkColorExtractor {
    nonisolated static func sampledBitmap(from data: Data, side: Int) -> ArtworkBitmapSample? {
        guard let pixels = resizedPixels(from: data, side: side) else { return nil }
        return ArtworkBitmapSample(pixels: pixels, side: side)
    }

    nonisolated static func averageColor(from sample: ArtworkBitmapSample) -> NSColor? {
        guard !sample.pixels.isEmpty else { return nil }

        var weightedR: CGFloat = 0
        var weightedG: CGFloat = 0
        var weightedB: CGFloat = 0
        var totalWeight: CGFloat = 0

        for i in stride(from: 0, to: sample.pixels.count, by: 4) {
            let alpha = CGFloat(sample.pixels[i + 3]) / 255.0
            if alpha <= 0.001 { continue }

            weightedR += (CGFloat(sample.pixels[i]) / 255.0) * alpha
            weightedG += (CGFloat(sample.pixels[i + 1]) / 255.0) * alpha
            weightedB += (CGFloat(sample.pixels[i + 2]) / 255.0) * alpha
            totalWeight += alpha
        }

        guard totalWeight > 0 else { return nil }
        return NSColor(
            calibratedRed: weightedR / totalWeight,
            green: weightedG / totalWeight,
            blue: weightedB / totalWeight,
            alpha: 1.0
        )
    }

    nonisolated static func uiThemePalette(from sample: ArtworkBitmapSample, targetCount: Int)
        -> [NSColor]
    {
        let pixels = sample.pixels

        let bucketCount = 48
        var buckets = [HueBucket](repeating: .zero, count: bucketCount)
        var fallbackWeight: CGFloat = 0
        var fallbackR: CGFloat = 0
        var fallbackG: CGFloat = 0
        var fallbackB: CGFloat = 0
        var saturationWeightedSum: CGFloat = 0
        var brightnessWeightedSum: CGFloat = 0
        var vividWeight: CGFloat = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255.0
            let g = CGFloat(pixels[i + 1]) / 255.0
            let b = CGFloat(pixels[i + 2]) / 255.0
            let a = CGFloat(pixels[i + 3]) / 255.0
            if a < 0.08 { continue }

            let rgbColor = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
            guard let hsb = rgbColor.usingColorSpace(.deviceRGB) else { continue }
            var hue: CGFloat = 0
            var sat: CGFloat = 0
            var bri: CGFloat = 0
            var alpha: CGFloat = 0
            hsb.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

            // Area first: dominant regions should win. Only mild color/brightness factors.
            let areaWeight = a
            let toneWeight = 0.90 + max(0, 1 - abs(bri - 0.5) * 1.8) * 0.20
            let satWeight = 0.90 + sat * 0.20
            var weight = areaWeight * toneWeight * satWeight
            if sat < 0.04 { weight *= 0.82 }
            if weight < 0.000_1 { continue }

            fallbackWeight += weight
            fallbackR += r * weight
            fallbackG += g * weight
            fallbackB += b * weight
            saturationWeightedSum += sat * weight
            brightnessWeightedSum += bri * weight
            if sat > 0.28 { vividWeight += weight * min(1.2, sat * 1.1) }

            let idx = min(bucketCount - 1, max(0, Int(floor(hue * CGFloat(bucketCount)))))
            buckets[idx].weight += weight
            buckets[idx].r += r * weight
            buckets[idx].g += g * weight
            buckets[idx].b += b * weight
        }

        guard fallbackWeight > 0 else { return [] }
        let profile = ArtworkProfile(
            avgSaturation: saturationWeightedSum / fallbackWeight,
            avgBrightness: brightnessWeightedSum / fallbackWeight,
            vividness: clamp(vividWeight / fallbackWeight, min: 0, max: 1)
        )

        var candidates: [PaletteCandidate] = []
        candidates.reserveCapacity(bucketCount)

        let totalBucketWeight = buckets.reduce(CGFloat(0)) { $0 + $1.weight }
        let minimumBucketWeight = totalBucketWeight * 0.012

        for bucket in buckets where bucket.weight > minimumBucketWeight {
            let inv = 1 / bucket.weight
            let color = NSColor(
                calibratedRed: bucket.r * inv,
                green: bucket.g * inv,
                blue: bucket.b * inv,
                alpha: 1
            )
            let tuned = tuneUI(color, profile: profile)
            let hue = hueValue(of: tuned)
            let score = bucket.weight * (0.85 + saturationValue(of: tuned) * 0.25)
            candidates.append(PaletteCandidate(color: tuned, hue: hue, score: score))
        }

        if candidates.isEmpty {
            let fallback = NSColor(
                calibratedRed: fallbackR / fallbackWeight,
                green: fallbackG / fallbackWeight,
                blue: fallbackB / fallbackWeight,
                alpha: 1
            )
            return [tuneUI(fallback, profile: profile)]
        }

        candidates.sort { $0.score > $1.score }

        var selected: [NSColor] = []
        for candidate in candidates {
            if selected.isEmpty {
                selected.append(candidate.color)
            } else {
                let isDistinct = selected.allSatisfy { existing in
                    let hueGap = circularHueDistance(candidate.hue, hueValue(of: existing))
                    let rgbGap = rgbDistance(candidate.color, existing)
                    return hueGap > 0.08 || rgbGap > 0.17
                }
                if isDistinct {
                    selected.append(candidate.color)
                }
            }
            if selected.count >= targetCount {
                break
            }
        }

        // Ensure we always expose multi-color themes for mesh gradients.
        while selected.count < targetCount, let base = selected.first {
            let variant = paletteVariant(from: base, index: selected.count, profile: profile)
            selected.append(variant)
        }

        return Array(selected.prefix(targetCount))
    }

    nonisolated static func uiThemePaletteRich(from sample: ArtworkBitmapSample, targetCount: Int)
        -> [NSColor]
    {
        let pixels = sample.pixels
        let bucketCount = 72
        var buckets = [HueBucket](repeating: .zero, count: bucketCount)

        var totalWeight: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255.0
            let g = CGFloat(pixels[i + 1]) / 255.0
            let b = CGFloat(pixels[i + 2]) / 255.0
            let a = CGFloat(pixels[i + 3]) / 255.0
            if a < 0.08 { continue }

            let rgbColor = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
            guard let hsb = rgbColor.usingColorSpace(.deviceRGB) else { continue }
            var hue: CGFloat = 0
            var sat: CGFloat = 0
            var bri: CGFloat = 0
            var alpha: CGFloat = 0
            hsb.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

            let midBBoost = max(0, 1 - abs(bri - 0.55) / 0.55)
            var weight = a * (0.70 + 0.30 * sat) * (0.70 + 0.30 * midBBoost)
            if sat > 0.42 {
                weight *= 1.08
            }
            if weight < 0.000_1 { continue }

            totalWeight += weight
            let idx = min(bucketCount - 1, max(0, Int(floor(hue * CGFloat(bucketCount)))))
            buckets[idx].weight += weight
            buckets[idx].r += r * weight
            buckets[idx].g += g * weight
            buckets[idx].b += b * weight
        }

        guard totalWeight > 0 else { return [] }
        let threshold = totalWeight * 0.006

        var candidates: [PaletteCandidate] = []
        for bucket in buckets where bucket.weight > threshold {
            let inv = 1 / bucket.weight
            let raw = NSColor(
                calibratedRed: bucket.r * inv,
                green: bucket.g * inv,
                blue: bucket.b * inv,
                alpha: 1
            )
            let rgb = raw.usingColorSpace(.deviceRGB) ?? raw
            var h: CGFloat = 0
            var s: CGFloat = 0
            var v: CGFloat = 0
            var a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let normalized = NSColor(
                calibratedHue: normalizedHue(h),
                saturation: clamp(s, min: 0.01, max: 0.95),
                brightness: clamp(v, min: 0.03, max: 0.96),
                alpha: 1
            )
            let score = bucket.weight * (0.90 + s * 0.35)
            candidates.append(PaletteCandidate(color: normalized, hue: h, score: score))
        }

        guard !candidates.isEmpty else { return [] }
        candidates.sort { $0.score > $1.score }

        var selected: [NSColor] = []
        for candidate in candidates {
            let distinct = selected.allSatisfy { existing in
                let hueGap = circularHueDistance(
                    hueValue(of: candidate.color), hueValue(of: existing))
                let rgbGap = rgbDistance(candidate.color, existing)
                return hueGap >= 0.05 || rgbGap >= 0.14
            }
            if distinct || selected.count < 2 {
                selected.append(candidate.color)
            }
            if selected.count >= targetCount { break }
        }

        // Ensure vivid accents that exist in the artwork can be present.
        if selected.count < targetCount {
            for candidate in candidates where saturationValue(of: candidate.color) >= 0.45 {
                let distinct = selected.allSatisfy {
                    circularHueDistance(hueValue(of: candidate.color), hueValue(of: $0)) >= 0.05
                }
                if distinct {
                    selected.append(candidate.color)
                }
                if selected.count >= targetCount { break }
            }
        }

        return Array(selected.prefix(targetCount))
    }
}

extension ArtworkColorExtractor {
    fileprivate struct HueBucket {
        var weight: CGFloat
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat

        nonisolated static let zero = HueBucket(weight: 0, r: 0, g: 0, b: 0)
    }

    fileprivate struct PaletteCandidate {
        let color: NSColor
        let hue: CGFloat
        let score: CGFloat
    }

    fileprivate struct ArtworkProfile {
        let avgSaturation: CGFloat
        let avgBrightness: CGFloat
        let vividness: CGFloat
    }

    fileprivate nonisolated static func resizedPixels(from data: Data, side: Int) -> [UInt8]? {
        let checksum = computeChecksum(data)
        let key = cacheKey(for: checksum, side: side)

        if let cached = pixelCache.cache.object(forKey: key) {
            return cached.pixels
        }

        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, side),
        ]

        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            )
        else { return nil }

        let width = side
        let height = side
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let entry = PixelDataCacheEntry(pixels: pixels, side: side, checksum: checksum)
        pixelCache.cache.setObject(entry, forKey: key, cost: pixels.count)

        return pixels
    }

    fileprivate nonisolated static func tuneUI(_ color: NSColor, profile: ArtworkProfile) -> NSColor
    {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let avgSat = clamp(profile.avgSaturation, min: 0, max: 1)
        let satMin = clamp(avgSat * 0.55, min: 0.02, max: 0.18)
        let satMax = clamp(0.16 + avgSat * 0.88 + profile.vividness * 0.08, min: 0.24, max: 0.80)
        let satScale = 0.92 + profile.vividness * 0.08 + avgSat * 0.03
        s = clamp(s * satScale, min: satMin, max: satMax)

        let pull =
            profile.avgBrightness < 0.42 ? 0.76 : (profile.avgBrightness > 0.66 ? 0.90 : 0.83)
        b = clamp(0.5 + (b - 0.5) * pull, min: 0.18, max: 0.84)

        return NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1)
    }

    fileprivate nonisolated static func paletteVariant(
        from color: NSColor, index: Int, profile: ArtworkProfile
    )
        -> NSColor
    {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let shiftBase = 0.014 + profile.avgSaturation * 0.026
        let hueShift: CGFloat = index == 1 ? shiftBase : -shiftBase * 0.82
        let brightnessShift: CGFloat = index == 1 ? -0.035 : 0.028
        let newHue = normalizedHue(h + hueShift)
        let satMin = clamp(profile.avgSaturation * 0.55, min: 0.02, max: 0.18)
        let satMax = clamp(
            0.16 + profile.avgSaturation * 0.88 + profile.vividness * 0.08, min: 0.24, max: 0.80)
        let satBoost = 0.95 + profile.vividness * 0.04
        let newSat = clamp(s * satBoost, min: satMin, max: satMax)
        let newBri = clamp(b + brightnessShift, min: 0.18, max: 0.84)

        return NSColor(calibratedHue: newHue, saturation: newSat, brightness: newBri, alpha: 1)
    }

    fileprivate nonisolated static func hueValue(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }

    fileprivate nonisolated static func saturationValue(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s
    }

    fileprivate nonisolated static func circularHueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    fileprivate nonisolated static func rgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let l = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let r = rhs.usingColorSpace(.deviceRGB) ?? rhs
        let dr = l.redComponent - r.redComponent
        let dg = l.greenComponent - r.greenComponent
        let db = l.blueComponent - r.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }

    fileprivate nonisolated static func normalizedHue(_ value: CGFloat) -> CGFloat {
        var h = value.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return h
    }

    fileprivate nonisolated static func clamp(
        _ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat
    )
        -> CGFloat
    {
        Swift.min(maxValue, Swift.max(minValue, value))
    }
}

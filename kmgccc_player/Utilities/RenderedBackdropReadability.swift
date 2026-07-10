//
//  RenderedBackdropReadability.swift
//  myPlayer2
//
//  Local, per-surface foreground-polarity engine.
//
//  The global `ArtworkForegroundPolarityPolicy` decides polarity from
//  whole-image statistics. That is conservative by design: it does not know
//  where text/controls actually land on the *final rendered* backdrop. This
//  file samples the rendered backdrop (Hero card image, Cover Gradient Blur
//  background) at the exact pixel regions occupied by foreground elements and
//  compares the two candidate foregrounds' WCAG contrast directly. The result
//  may override the global polarity for that one surface only.
//
//  Layering rules (see docs/readability-foreground-region-implementation-plan.md):
//    - `RenderedBackdropReadabilityMap` owns final-backdrop pixels + region
//      stats only. It never touches hue/chroma semantics.
//    - The contrast engine receives the exact dark/light primary colours the
//      surface will render, so "what is scored" == "what is drawn".
//    - The engine is a pure value-type utility: no SwiftUI / ThemeStore. It
//      runs inside SelfCheck and the Golden Master CLI as well as on render
//      threads.
//
//  Coordinate convention: map origin is the TOP-LEFT corner, matching SwiftUI
//  layout rects. Region row 0 is the top scanline of the source image. The
//  `checkRenderedBackdropReadabilityMap` self-check asserts this with a
//  top-white / bottom-black synthetic image.
//

import AppKit
import CoreGraphics
import Foundation

/// A rectangle in normalized [0,1] backdrop coordinates, top-left origin.
nonisolated struct NormalizedReadabilityRegion: Sendable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Build a normalized region from a view-space `CGRect` given the canvas
    /// size it was expressed in. The caller is responsible for any aspect-fill
    /// mapping beforehand (see `AspectFillReadabilityMapping`).
    static func from(rect: CGRect, canvasSize: CGSize) -> Self {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            return Self(x: 0, y: 0, width: 0, height: 0)
        }
        return Self(
            x: rect.minX / canvasSize.width,
            y: rect.minY / canvasSize.height,
            width: rect.width / canvasSize.width,
            height: rect.height / canvasSize.height
        )
    }
}

/// Low-resolution WCAG luminance map of a rendered backdrop. Built once per
/// final `CGImage` (Hero backdrop, Cover Blur background) on a render thread;
/// queried by region from the view layer.
nonisolated struct RenderedBackdropReadabilityMap: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    /// WCAG relative luminance per pixel, row-major, row 0 = top scanline.
    let luma: [Float]

    /// Downscale `image` so its longest edge is at most `maximumDimension`,
    /// render to an sRGB 8-bit buffer, and compute WCAG relative luminance.
    /// Returns nil if the image cannot be rendered.
    static func make(
        from image: CGImage,
        maximumDimension: Int = ColorSystemTokens.ReadabilityForeground.mapMaximumDimension
    ) -> Self? {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0, maximumDimension > 0 else { return nil }

        let longest = max(srcW, srcH)
        let scale = longest > maximumDimension
            ? CGFloat(maximumDimension) / CGFloat(longest)
            : 1
        let w = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let h = max(1, Int((CGFloat(srcH) * scale).rounded()))
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // sRGB -> linear -> WCAG relative luminance. Same transfer function as
        // `ColorMath.relativeLuminance`, inlined for the Float buffer.
        func linearize(_ c: Float) -> Float {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var luma = [Float](repeating: 0, count: w * h)
        // CGContext bitmap memory: row 0 of the buffer is the TOP scanline of
        // the rendered image (row 0 = top), matching the SwiftUI convention.
        for row in 0..<h {
            let base = row * bytesPerRow
            let outBase = row * w
            for col in 0..<w {
                let p = base + col * 4
                // Premultiplied last: undo premultiply for luma (alpha affects
                // compositing, not the surface's intrinsic luminance).
                let a = Float(pixels[p + 3]) / 255.0
                let r: Float
                let g: Float
                let b: Float
                if a > 0 {
                    r = (Float(pixels[p]) / 255.0) / a
                    g = (Float(pixels[p + 1]) / 255.0) / a
                    b = (Float(pixels[p + 2]) / 255.0) / a
                } else {
                    r = 0; g = 0; b = 0
                }
                let rl = linearize(min(1, max(0, r)))
                let gl = linearize(min(1, max(0, g)))
                let bl = linearize(min(1, max(0, b)))
                luma[outBase + col] = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
            }
        }
        return Self(pixelWidth: w, pixelHeight: h, luma: luma)
    }

    /// Luma at an integer pixel (top-left origin). Out-of-bounds returns nil.
    func lumaAt(col: Int, row: Int) -> Float? {
        guard col >= 0, col < pixelWidth, row >= 0, row < pixelHeight else {
            return nil
        }
        return luma[row * pixelWidth + col]
    }

    /// Collect per-pixel luma for a normalized region (top-left origin,
    /// clamped to the map). Returns nil if the region covers fewer than
    /// `minimumRegionSampleCount` map pixels.
    func sample(
        region: NormalizedReadabilityRegion,
        minimumSampleCount: Int = ColorSystemTokens.ReadabilityForeground.minimumRegionSampleCount
    ) -> RegionReadabilitySample? {
        let x0 = max(0, min(pixelWidth, Int(region.x * CGFloat(pixelWidth))))
        let y0 = max(0, min(pixelHeight, Int(region.y * CGFloat(pixelHeight))))
        let x1 = max(0, min(pixelWidth, Int((region.x + region.width) * CGFloat(pixelWidth))))
        let y1 = max(0, min(pixelHeight, Int((region.y + region.height) * CGFloat(pixelHeight))))
        guard x1 > x0, y1 > y0 else { return nil }

        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        var sum: Double = 0
        for row in y0..<y1 {
            let base = row * pixelWidth
            for col in x0..<x1 {
                let v = luma[base + col]
                values.append(v)
                sum += Double(v)
            }
        }
        let count = values.count
        guard count >= minimumSampleCount else { return nil }

        let sorted = values.sorted()
        let mean = CGFloat(sum / Double(count))
        let p10 = Self.percentile(sorted, p: 0.10)
        let p25 = Self.percentile(sorted, p: 0.25)
        let median = Self.percentile(sorted, p: 0.50)
        var varianceSum: Double = 0
        for v in values {
            let d = Double(v) - Double(mean)
            varianceSum += d * d
        }
        let stdev = CGFloat(sqrt(varianceSum / Double(count)))
        let darkRatio = CGFloat(values.filter { $0 < 0.28 }.count) / CGFloat(count)
        let brightRatio = CGFloat(values.filter { $0 > 0.62 }.count) / CGFloat(count)
        return RegionReadabilitySample(
            sampleCount: count,
            meanLuma: mean,
            p10Luma: p10,
            p25Luma: p25,
            medianLuma: median,
            standardDeviation: stdev,
            darkPixelRatio: darkRatio,
            brightPixelRatio: brightRatio,
            lumaValues: values
        )
    }

    /// Nearest-rank percentile of a pre-sorted ascending array.
    private static func percentile(_ sorted: [Float], p: CGFloat) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        let idx = max(0, min(n - 1, Int((p * CGFloat(n)).rounded()) - 1))
        return CGFloat(sorted[idx])
    }
}

/// Statistics for one sampled region. `lumaValues` is unsorted (pixel order);
/// the engine sorts per-pixel contrast arrays internally.
nonisolated struct RegionReadabilitySample: Sendable {
    let sampleCount: Int
    let meanLuma: CGFloat
    let p10Luma: CGFloat
    let p25Luma: CGFloat
    let medianLuma: CGFloat
    let standardDeviation: CGFloat
    let darkPixelRatio: CGFloat
    let brightPixelRatio: CGFloat
    let lumaValues: [Float]
}

/// Pure aspect-fill mapping from a SwiftUI view-space rect to a normalized
/// backdrop-image region. Covers the Hero's leading-aligned, center-vertical
/// aspect-fill. The same math applies to any surface that aspect-fills a
/// backing image.
nonisolated enum AspectFillReadabilityMapping {
    enum HorizontalAlignment: Sendable {
        case leading
        case center
        case trailing
    }
    enum VerticalAlignment: Sendable {
        case top
        case center
        case bottom
    }

    /// Returns the normalized image region (top-left origin) visible behind
    /// `viewRect`, or nil if the inputs are degenerate. The result is clamped
    /// to [0,1]; callers should still tolerate an undersized sample.
    static func map(
        viewRect: CGRect,
        viewSize: CGSize,
        imageSize: CGSize,
        horizontalAlignment: HorizontalAlignment,
        verticalAlignment: VerticalAlignment
    ) -> NormalizedReadabilityRegion? {
        guard viewSize.width > 0, viewSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        guard scale > 0 else { return nil }
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let offsetX: CGFloat
        switch horizontalAlignment {
        case .leading: offsetX = 0
        case .center: offsetX = (viewSize.width - scaledW) / 2
        case .trailing: offsetX = viewSize.width - scaledW
        }
        let offsetY: CGFloat
        switch verticalAlignment {
        case .top: offsetY = 0
        case .center: offsetY = (viewSize.height - scaledH) / 2
        case .bottom: offsetY = viewSize.height - scaledH
        }

        let nx0 = (viewRect.minX - offsetX) / scaledW
        let ny0 = (viewRect.minY - offsetY) / scaledH
        let nx1 = (viewRect.maxX - offsetX) / scaledW
        let ny1 = (viewRect.maxY - offsetY) / scaledH

        let x = max(0, min(1, nx0))
        let y = max(0, min(1, ny0))
        let xMax = max(0, min(1, nx1))
        let yMax = max(0, min(1, ny1))
        return NormalizedReadabilityRegion(
            x: x,
            y: y,
            width: max(0, xMax - x),
            height: max(0, yMax - y)
        )
    }
}

/// Local polarity decision produced by the contrast engine.
nonisolated struct LocalForegroundDecision: Sendable, Equatable {
    let polarity: ArtworkForegroundPolarity
    let darkForegroundRobustContrast: CGFloat
    let lightForegroundRobustContrast: CGFloat
    let requiresContrastAssist: Bool
    let reason: Reason

    enum Reason: String, Sendable {
        /// No valid region samples; caller must fall back to global polarity.
        case noValidSamples
        /// Dark clearly beats light by the required margin at AA contrast.
        case darkClearlyBetter
        /// Light reaches AA contrast.
        case lightClear
        /// Dark reaches AA but light does not (and dark did not clear the
        /// advantage margin, so this branch is only hit when light is poor).
        case darkOnly
        /// Best of two weak scores (>= floor but < AA); assist flagged.
        case bestEffort
        /// Both below the floor; light chosen unless dark leads by margin.
        case fallback
    }
}

/// Stateless local contrast engine.
nonisolated enum RenderedBackdropReadability {
    /// WCAG contrast ratio between a foreground luminance and a background
    /// luminance.
    static func contrastRatio(foregroundLuma: CGFloat, backgroundLuma: CGFloat) -> CGFloat {
        let hi = max(foregroundLuma, backgroundLuma)
        let lo = min(foregroundLuma, backgroundLuma)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// p10 (robust) contrast of a candidate foreground against a region: the
    /// value such that at least 90% of sampled pixels reach it. Nil if the
    /// sample has no pixels.
    static func robustContrast(
        foregroundLuma: CGFloat,
        sample: RegionReadabilitySample
    ) -> CGFloat? {
        guard sample.sampleCount > 0 else { return nil }
        var ratios = [CGFloat](repeating: 0, count: sample.sampleCount)
        for (i, bg) in sample.lumaValues.enumerated() {
            ratios[i] = contrastRatio(foregroundLuma: foregroundLuma, backgroundLuma: CGFloat(bg))
        }
        ratios.sort()
        let n = ratios.count
        // Nearest-rank p10: 90% of samples reach this value.
        let idx = max(0, min(n - 1, Int((0.10 * CGFloat(n)).rounded()) - 1))
        return ratios[idx]
    }

    /// Decide local polarity from the worst-case robust contrast of each
    /// candidate across every (map, regions) pair. `darkForeground` and
    /// `lightForeground` are the exact NSColors the surface will render.
    static func decide(
        darkForeground: NSColor,
        lightForeground: NSColor,
        samples: [(map: RenderedBackdropReadabilityMap, regions: [NormalizedReadabilityRegion])]
    ) -> LocalForegroundDecision {
        let darkLuma = ColorMath.relativeLuminance(of: darkForeground)
        let lightLuma = ColorMath.relativeLuminance(of: lightForeground)
        return decide(
            darkForegroundLuma: darkLuma,
            lightForegroundLuma: lightLuma,
            samples: samples
        )
    }

    /// Luma-based overload (avoids re-computing luma when callers cache it).
    static func decide(
        darkForegroundLuma: CGFloat,
        lightForegroundLuma: CGFloat,
        samples: [(map: RenderedBackdropReadabilityMap, regions: [NormalizedReadabilityRegion])]
    ) -> LocalForegroundDecision {
        let T = ColorSystemTokens.ReadabilityForeground.self
        var darkWorst: CGFloat?
        var lightWorst: CGFloat?
        for entry in samples {
            for region in entry.regions {
                guard let regionSample = entry.map.sample(region: region) else { continue }
                if let dc = robustContrast(foregroundLuma: darkForegroundLuma, sample: regionSample) {
                    darkWorst = darkWorst.map { min($0, dc) } ?? dc
                }
                if let lc = robustContrast(foregroundLuma: lightForegroundLuma, sample: regionSample) {
                    lightWorst = lightWorst.map { min($0, lc) } ?? lc
                }
            }
        }

        guard let darkScore = darkWorst, let lightScore = lightWorst else {
            return LocalForegroundDecision(
                polarity: .lightOnDarkBackground,
                darkForegroundRobustContrast: darkWorst ?? 0,
                lightForegroundRobustContrast: lightWorst ?? 0,
                requiresContrastAssist: true,
                reason: .noValidSamples
            )
        }

        // Decision order (plan section 6.5). Dark must clear AA AND beat light
        // by the advantage margin; otherwise light wins ties.
        if darkScore >= T.minimumRobustContrast,
           darkScore >= lightScore + T.darkSelectionAdvantage {
            return LocalForegroundDecision(
                polarity: .darkOnLightBackground,
                darkForegroundRobustContrast: darkScore,
                lightForegroundRobustContrast: lightScore,
                requiresContrastAssist: false,
                reason: .darkClearlyBetter
            )
        }
        if lightScore >= T.minimumRobustContrast {
            return LocalForegroundDecision(
                polarity: .lightOnDarkBackground,
                darkForegroundRobustContrast: darkScore,
                lightForegroundRobustContrast: lightScore,
                requiresContrastAssist: false,
                reason: .lightClear
            )
        }
        if darkScore >= T.minimumRobustContrast {
            return LocalForegroundDecision(
                polarity: .darkOnLightBackground,
                darkForegroundRobustContrast: darkScore,
                lightForegroundRobustContrast: lightScore,
                requiresContrastAssist: false,
                reason: .darkOnly
            )
        }
        if max(darkScore, lightScore) >= T.absoluteContrastFloor {
            let darkWins = darkScore >= lightScore
            return LocalForegroundDecision(
                polarity: darkWins ? .darkOnLightBackground : .lightOnDarkBackground,
                darkForegroundRobustContrast: darkScore,
                lightForegroundRobustContrast: lightScore,
                requiresContrastAssist: true,
                reason: .bestEffort
            )
        }
        let darkWins = darkScore >= lightScore + T.darkSelectionAdvantage
        return LocalForegroundDecision(
            polarity: darkWins ? .darkOnLightBackground : .lightOnDarkBackground,
            darkForegroundRobustContrast: darkScore,
            lightForegroundRobustContrast: lightScore,
            requiresContrastAssist: true,
            reason: .fallback
        )
    }
}

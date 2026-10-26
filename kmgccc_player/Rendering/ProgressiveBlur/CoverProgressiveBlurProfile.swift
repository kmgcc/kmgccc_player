//
//  CoverProgressiveBlurProfile.swift
//  kmgccc_player
//
//  Blur radius as a function of the horizontal position on the panorama
//  canvas. The renderer turns it into one Gaussian sigma per pixel column.
//

import Foundation

/// Lengths are in points and scale with the output's pixels per point, so a
/// low-resolution transition source and the display render look the same.
nonisolated struct CoverProgressiveBlurProfile: Sendable, Equatable {
    /// Where the blur starts inside the cover, as a fraction of its width
    /// measured inward from the cover edge.
    var startRatio: Double
    /// Sigma at the cover edge (pt).
    var edgeRadius: Double
    /// Shape of the rise inside the cover; larger keeps the cover sharp longer.
    var innerPower: Double
    /// Largest sigma (pt).
    var maxRadius: Double
    /// Where the fill reaches the maximum, as a fraction of the fill width.
    var endRatio: Double
    /// Shape of the rise across the fill.
    var fillPower: Double
    /// Soft approach to the maximum, as a fraction of it.
    var knee: Double
    /// Largest growth of sigma per pixel. Steeper curves are raised on the
    /// inner side, so adjacent columns' footprints always overlap.
    var maxSlope: Double
    /// Gaussian smoothing of the curve itself (pt).
    var smooth: Double
    /// Width of the cover strip the stretched fill draws from (pt).
    var strip: Double
    /// Samples per sigma; the blur reads the coarsest level that keeps this
    /// many texels per sigma.
    var density: Double = 1.5

    /// Cover on the left, lyrics beside it.
    static let leading = CoverProgressiveBlurProfile(
        startRatio: 0.39, edgeRadius: 31.5, innerPower: 5.0, maxRadius: 114,
        endRatio: 0.40, fillPower: 3.05, knee: 0.60, maxSlope: 1.60, smooth: 12, strip: 9
    )

    /// Cover centred, lyrics hidden.
    static let centered = CoverProgressiveBlurProfile(
        startRatio: 0.02, edgeRadius: 20, innerPower: 5.0, maxRadius: 114,
        endRatio: 0.64, fillPower: 3.05, knee: 0.60, maxSlope: 1.60, smooth: 12, strip: 9
    )

    /// The same curve on a cover `factor` times the size it was tuned for.
    func scaled(by factor: Double) -> CoverProgressiveBlurProfile {
        var copy = self
        copy.edgeRadius *= factor
        copy.maxRadius *= factor
        copy.smooth *= factor
        copy.strip *= factor
        return copy
    }

    var cacheToken: String {
        [startRatio, edgeRadius, innerPower, maxRadius, endRatio, fillPower, knee, maxSlope, smooth, strip, density]
            .map { String(format: "%.3f", $0) }
            .joined(separator: "-")
    }

    /// Sigma at signed distance `d` outward from the cover edge. Every length
    /// is in the caller's unit; `edge` and `maximum` are already scaled.
    private func sigmaOutward(
        _ d: Double,
        coverWidth: Double,
        fillWidth: Double,
        edge: Double,
        maximum: Double
    ) -> Double {
        let inner = max(startRatio * coverWidth, 1e-3)
        if d <= -inner { return 0 }
        let raw: Double
        if d <= 0 {
            raw = edge * pow((d + inner) / inner, innerPower)
        } else {
            let span = max(endRatio * fillWidth, 1)
            let slope = edge * innerPower / inner
            let rest = maximum - edge - slope * span
            raw = rest >= 0
                ? edge + slope * d + rest * pow(d / span, fillPower)
                : edge + (maximum - edge) * d / span
        }
        let kneeWidth = knee * maximum
        if kneeWidth > 0, raw > maximum - kneeWidth {
            return maximum - kneeWidth * exp(-(raw - (maximum - kneeWidth)) / kneeWidth)
        }
        return min(raw, maximum)
    }

    /// The cover edges whose blur the curve contains.
    nonisolated enum Sides: Sendable {
        /// Leading layout: only the fill on the right.
        case right
        case left
        /// Centred layout: the larger value of the two sides.
        case both
    }

    /// One sigma (px) per output column.
    func sigmaLUT(
        width: Int,
        coverX0: Double,
        coverX1: Double,
        sides: Sides,
        pixelsPerPoint: Double
    ) -> [Float] {
        let coverWidth = coverX1 - coverX0
        let edge = edgeRadius * pixelsPerPoint
        let maximum = maxRadius * pixelsPerPoint
        var raw = [Double](repeating: 0, count: width)
        for x in 0..<width {
            let center = Double(x) + 0.5
            var sigma = 0.0
            if sides != .left {
                sigma = sigmaOutward(
                    center - coverX1, coverWidth: coverWidth, fillWidth: Double(width) - coverX1,
                    edge: edge, maximum: maximum
                )
            }
            if sides != .right {
                sigma = max(sigma, sigmaOutward(
                    coverX0 - center, coverWidth: coverWidth, fillWidth: coverX0,
                    edge: edge, maximum: maximum
                ))
            }
            raw[x] = sigma
        }

        // Slope limit from both sides: the inner side rises earlier instead
        // of the fill dropping.
        if width > 1 {
            for x in stride(from: width - 2, through: 0, by: -1) {
                raw[x] = max(raw[x], raw[x + 1] - maxSlope)
            }
            for x in 1..<width {
                raw[x] = max(raw[x], raw[x - 1] - maxSlope)
            }
        }

        // Smoothing removes the corners of the piecewise curve, so the growth
        // rate never jumps.
        let smoothing = smooth * pixelsPerPoint
        guard smoothing >= 0.5 else { return raw.map { Float($0) } }
        let reach = Int((3 * smoothing).rounded(.up))
        var kernel = [Double](repeating: 0, count: 2 * reach + 1)
        var total = 0.0
        for i in -reach...reach {
            let weight = exp(-0.5 * pow(Double(i) / smoothing, 2))
            kernel[i + reach] = weight
            total += weight
        }
        var smoothed = [Float](repeating: 0, count: width)
        for x in 0..<width {
            var sum = 0.0
            for i in -reach...reach {
                sum += kernel[i + reach] * raw[min(width - 1, max(0, x + i))]
            }
            smoothed[x] = Float(sum / total)
        }
        return smoothed
    }

    /// The curve while the cover slides between the two layouts, `progress`
    /// 0 at leading and 1 at centred. Both curves are evaluated at the live
    /// cover position and mixed, so each end is exactly its settled render.
    /// The left fill only exists once the cover has moved; it takes the
    /// centred curve's blur early so the stretched strip never shows sharp.
    static func transitionLUT(
        leading: CoverProgressiveBlurProfile,
        centered: CoverProgressiveBlurProfile,
        progress: Double,
        width: Int,
        coverX0: Double,
        coverX1: Double,
        pixelsPerPoint: Double
    ) -> [Float] {
        let q = min(max(progress, 0), 1)
        let leadingCurve = leading.sigmaLUT(
            width: width, coverX0: coverX0, coverX1: coverX1, sides: .right, pixelsPerPoint: pixelsPerPoint
        )
        if q <= 0 { return leadingCurve }
        let centeredCurve = centered.sigmaLUT(
            width: width, coverX0: coverX0, coverX1: coverX1, sides: .both, pixelsPerPoint: pixelsPerPoint
        )
        if q >= 1 { return centeredCurve }
        let leftCurve = centered.sigmaLUT(
            width: width, coverX0: coverX0, coverX1: coverX1, sides: .left, pixelsPerPoint: pixelsPerPoint
        )
        let t = Float(q)
        let leftWeight = Float(min(1, q / 0.25))
        let early = leftWeight * leftWeight * (3 - 2 * leftWeight)
        return (0..<width).map { x in
            max(leadingCurve[x] + (centeredCurve[x] - leadingCurve[x]) * t, leftCurve[x] * early)
        }
    }
}

import Foundation

/// Normalized second-order IIR coefficients shared by the EQ renderer and the
/// response curve. The denominator is normalized to a0 == 1.
nonisolated struct DSPBiquadCoefficients: Equatable, Sendable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static let identity = DSPBiquadCoefficients(
        b0: 1,
        b1: 0,
        b2: 0,
        a1: 0,
        a2: 0
    )

    var isIdentity: Bool {
        abs(b0 - 1) < 1e-14
            && abs(b1) < 1e-14
            && abs(b2) < 1e-14
            && abs(a1) < 1e-14
            && abs(a2) < 1e-14
    }

    var isStable: Bool {
        [b0, b1, b2, a1, a2].allSatisfy(\.isFinite)
            && abs(a2) < 1
            && 1 + a1 + a2 > 0
            && 1 - a1 + a2 > 0
    }

    func responseDB(at frequencyHz: Double, sampleRate: Double) -> Double {
        guard frequencyHz.isFinite,
              sampleRate.isFinite,
              frequencyHz >= 0,
              sampleRate > 0,
              frequencyHz < sampleRate / 2 else { return 0 }

        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let cosDoubleOmega = cosOmega * cosOmega - sinOmega * sinOmega
        let sinDoubleOmega = 2 * sinOmega * cosOmega

        let numeratorReal = b0 + b1 * cosOmega + b2 * cosDoubleOmega
        let numeratorImaginary = -(b1 * sinOmega + b2 * sinDoubleOmega)
        let denominatorReal = 1 + a1 * cosOmega + a2 * cosDoubleOmega
        let denominatorImaginary = -(a1 * sinOmega + a2 * sinDoubleOmega)
        let numeratorMagnitude = hypot(numeratorReal, numeratorImaginary)
        let denominatorMagnitude = hypot(denominatorReal, denominatorImaginary)
        guard denominatorMagnitude.isFinite, denominatorMagnitude > 1e-15 else { return 0 }
        let magnitude = numeratorMagnitude / denominatorMagnitude
        guard magnitude.isFinite else { return 0 }
        return 20 * log10(max(magnitude, 1e-15))
    }
}

/// RBJ Audio EQ Cookbook biquads used by both the playback processor and the
/// Settings response graph. Coefficients and response calculations stay in
/// Double precision; PCM conversion happens only at the renderer boundary.
nonisolated enum DSPParametricEQMath {
    static func coefficients(
        for band: DSPParametricEQBand,
        sampleRate: Double
    ) -> DSPBiquadCoefficients? {
        guard sampleRate.isFinite, sampleRate > 0,
              band.frequencyHz.isFinite,
              band.gainDB.isFinite,
              band.q.isFinite else { return nil }

        let nyquist = sampleRate / 2
        let frequency = min(max(20, band.frequencyHz), min(20_000, nyquist * 0.98))
        guard frequency > 0, frequency < nyquist else { return nil }

        let qRange: ClosedRange<Double> = switch band.type {
        case .lowShelf, .highShelf: 0.25...1
        default: 0.25...16
        }
        let q = min(max(qRange.lowerBound, band.q), qRange.upperBound)
        let gainDB = min(max(-18, band.gainDB), 18)
        if (band.type == .bell || band.type == .lowShelf || band.type == .highShelf),
           abs(gainDB) < 1e-12 {
            return .identity
        }
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let sine = sin(omega)
        let amplitude = pow(10, gainDB / 40)
        guard amplitude.isFinite, amplitude > 0 else { return nil }

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch band.type {
        case .bell:
            let alpha = sine / (2 * q)
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosine
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosine
            a2 = 1 - alpha / amplitude

        case .lowShelf, .highShelf:
            // In the RBJ shelf form, q is the shelf slope S.
            let alpha = sine / 2 * sqrt((amplitude + 1 / amplitude) * (1 / q - 1) + 2)
            let beta = 2 * sqrt(amplitude) * alpha
            switch band.type {
            case .lowShelf:
                b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + beta)
                b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine)
                b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - beta)
                a0 = (amplitude + 1) + (amplitude - 1) * cosine + beta
                a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosine)
                a2 = (amplitude + 1) + (amplitude - 1) * cosine - beta
            case .highShelf:
                b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + beta)
                b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine)
                b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - beta)
                a0 = (amplitude + 1) - (amplitude - 1) * cosine + beta
                a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosine)
                a2 = (amplitude + 1) - (amplitude - 1) * cosine - beta
            default:
                return nil
            }

        case .lowPass, .highPass, .notch:
            let alpha = sine / (2 * q)
            switch band.type {
            case .lowPass:
                b0 = (1 - cosine) / 2
                b1 = 1 - cosine
                b2 = (1 - cosine) / 2
            case .highPass:
                b0 = (1 + cosine) / 2
                b1 = -(1 + cosine)
                b2 = (1 + cosine) / 2
            case .notch:
                b0 = 1
                b1 = -2 * cosine
                b2 = 1
            default:
                return nil
            }
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        }

        guard a0.isFinite, abs(a0) > 1e-15 else { return nil }
        let result = DSPBiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
        return result.isStable ? result : nil
    }

    /// Combined magnitude response in dB for all enabled EQ bands in node order.
    /// Format-specific channel bypass is applied by `AudioDSPProcessor`; this
    /// format-independent form is also used for the shared editor curve.
    static func responseDB(
        configuration: AudioDSPConfiguration,
        at frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        guard configuration.enabled,
              frequencyHz.isFinite,
              frequencyHz >= 0,
              sampleRate.isFinite,
              sampleRate > 0 else { return 0 }

        var response = 0.0
        for node in configuration.nodes where node.enabled && node.typeID == "peq9" {
            guard let bands = node.parametricEQBands else { continue }
            for band in bands where band.enabled {
                guard let coefficients = coefficients(for: band, sampleRate: sampleRate) else {
                    continue
                }
                response += coefficients.responseDB(at: frequencyHz, sampleRate: sampleRate)
            }
        }
        return response.isFinite ? response : 0
    }

    /// Estimates the positive peak of the combined EQ response. Dense logarithmic
    /// sampling is supplemented around each band center so narrow resonances are
    /// less likely to fall between samples. This is a static headroom estimate,
    /// not a guarantee against every time-domain transient.
    static func estimatedPeakResponseDB(
        configuration: AudioDSPConfiguration,
        sampleRate: Double
    ) -> Double {
        guard configuration.enabled,
              sampleRate.isFinite,
              sampleRate > 0 else { return 0 }
        let upperFrequency = sampleRate * 0.499
        guard upperFrequency > 0, upperFrequency.isFinite else { return 0 }
        let lowerFrequency = min(1, upperFrequency * 0.001)

        var candidates = [Double]()
        candidates.reserveCapacity(1_104)
        candidates.append(0)
        let pointCount = 1_024
        let ratio = upperFrequency / lowerFrequency
        for index in 0...pointCount {
            candidates.append(lowerFrequency * pow(ratio, Double(index) / Double(pointCount)))
        }
        candidates.append(upperFrequency)
        var coefficientsToMeasure = [DSPBiquadCoefficients]()
        coefficientsToMeasure.reserveCapacity(configuration.nodes.count * 9)
        for node in configuration.nodes where node.enabled && node.typeID == "peq9" {
            guard let bands = node.parametricEQBands else { continue }
            for band in bands where band.enabled {
                let center = min(max(20, band.frequencyHz), upperFrequency)
                candidates.append(center)
                let bandwidthFraction = min(0.5, max(0.001, 1 / max(0.25, band.q)))
                candidates.append(max(lowerFrequency, center * (1 - bandwidthFraction)))
                candidates.append(min(upperFrequency, center * (1 + bandwidthFraction)))
                if let coefficients = coefficients(for: band, sampleRate: sampleRate),
                   !coefficients.isIdentity {
                    coefficientsToMeasure.append(coefficients)
                }
            }
        }

        var peak = 0.0
        for frequency in candidates {
            var combinedResponse = 0.0
            for coefficients in coefficientsToMeasure {
                combinedResponse += coefficients.responseDB(
                    at: frequency,
                    sampleRate: sampleRate
                )
            }
            peak = max(peak, combinedResponse)
        }
        return peak
    }
}

import Foundation

/// Keeps a node's long-term loudness equal to its input's, so switching the
/// node changes its character, not its level.
///
/// Both sides are measured with the ITU-R BS.1770 K-weighting (pre-filter
/// shelf and RLB high-pass) summed over the selected channels, then smoothed
/// with the same long time constant. The compensating gain is the square
/// root of their ratio, bounded, and glides linearly across each block.
/// Near-silent input holds the last gain instead of chasing noise.
nonisolated struct DSPLoudnessMatch {
    private struct KWeighting {
        var shelf: DSPNativeBiquadState
        var highPass: DSPNativeBiquadState

        mutating func process(_ sample: Double) -> Double {
            highPass.process(shelf.process(sample))
        }

        mutating func copyState(from source: KWeighting) {
            shelf.copyState(from: source.shelf)
            highPass.copyState(from: source.highPass)
        }

        mutating func reset() {
            shelf.reset()
            highPass.reset()
        }
    }

    static let defaultTimeConstantSeconds = 2.0
    static let defaultMaximumDB = 6.0
    /// Mean-square K-weighted energy below about −70 dB holds the gain.
    private static let silenceEnergy = 1e-7

    private let sampleRate: Double
    private let timeConstantFrames: Double
    private let minimumGain: Double
    private let maximumGain: Double
    private var inputFilters: [KWeighting]
    private var outputFilters: [KWeighting]
    private var inputEnergy = 0.0
    private var outputEnergy = 0.0
    private var hasEstimate = false
    private var pendingInputEnergy = 0.0
    /// Gain reached at the end of the last block.
    private(set) var gain = 1.0

    init?(
        sampleRate: Double,
        channelCount: Int,
        timeConstantSeconds: Double = Self.defaultTimeConstantSeconds,
        maximumDB: Double = Self.defaultMaximumDB
    ) {
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0,
              timeConstantSeconds > 0, maximumDB >= 0,
              let shelf = Self.preFilter(sampleRate: sampleRate),
              let highPass = Self.rlbHighPass(sampleRate: sampleRate) else { return nil }
        self.sampleRate = sampleRate
        timeConstantFrames = timeConstantSeconds * sampleRate
        maximumGain = pow(10, maximumDB / 20)
        minimumGain = 1 / maximumGain
        let filter = KWeighting(
            shelf: DSPNativeBiquadState(coefficients: shelf),
            highPass: DSPNativeBiquadState(coefficients: highPass)
        )
        inputFilters = Array(repeating: filter, count: channelCount)
        outputFilters = Array(repeating: filter, count: channelCount)
    }

    /// Measure the node's input. Call once per block before the node runs.
    mutating func measureInput(
        _ samples: UnsafePointer<Double>,
        frames: Int,
        channels: Int,
        mask: [Bool]
    ) {
        pendingInputEnergy = Self.energy(samples, frames: frames, channels: channels,
                                         mask: mask, filters: &inputFilters)
    }

    /// Measure the node's output for the same block, update the estimate
    /// and apply the compensating gain to the selected channels.
    mutating func applyToOutput(
        _ samples: UnsafeMutablePointer<Double>,
        frames: Int,
        channels: Int,
        mask: [Bool]
    ) {
        guard frames > 0 else { return }
        let outputBlockEnergy = Self.energy(UnsafePointer(samples), frames: frames, channels: channels,
                                            mask: mask, filters: &outputFilters)
        let start = gain
        if pendingInputEnergy > Self.silenceEnergy {
            if hasEstimate {
                let alpha = 1 - exp(-Double(frames) / timeConstantFrames)
                inputEnergy += alpha * (pendingInputEnergy - inputEnergy)
                outputEnergy += alpha * (outputBlockEnergy - outputEnergy)
            } else {
                // Start from unity so a tail still building up does not
                // throw the first blocks far from the input level.
                inputEnergy = pendingInputEnergy
                outputEnergy = pendingInputEnergy
                hasEstimate = true
            }
            if outputEnergy > Self.silenceEnergy * 1e-3 {
                gain = min(maximumGain, max(minimumGain, (inputEnergy / outputEnergy).squareRoot()))
            }
        }
        let step = (gain - start) / Double(frames)
        if step == 0, start == 1 { return }
        for frame in 0..<frames {
            let value = start + step * Double(frame + 1)
            let offset = frame * channels
            for channel in 0..<channels where mask[channel] {
                samples[offset + channel] *= value
            }
        }
    }

    mutating func copyState(from source: DSPLoudnessMatch) {
        guard inputFilters.count == source.inputFilters.count else { return }
        for index in inputFilters.indices {
            inputFilters[index].copyState(from: source.inputFilters[index])
            outputFilters[index].copyState(from: source.outputFilters[index])
        }
        inputEnergy = source.inputEnergy
        outputEnergy = source.outputEnergy
        hasEstimate = source.hasEstimate
        pendingInputEnergy = source.pendingInputEnergy
        gain = source.gain
    }

    mutating func reset() {
        for index in inputFilters.indices {
            inputFilters[index].reset()
            outputFilters[index].reset()
        }
        inputEnergy = 0
        outputEnergy = 0
        hasEstimate = false
        pendingInputEnergy = 0
        gain = 1
    }

    private static func energy(
        _ samples: UnsafePointer<Double>,
        frames: Int,
        channels: Int,
        mask: [Bool],
        filters: inout [KWeighting]
    ) -> Double {
        guard frames > 0 else { return 0 }
        var sum = 0.0
        for channel in 0..<min(channels, filters.count) where mask[channel] {
            var filter = filters[channel]
            for frame in 0..<frames {
                let weighted = filter.process(samples[frame * channels + channel])
                sum += weighted * weighted
            }
            filters[channel] = filter
        }
        return sum / Double(frames)
    }

    /// BS.1770 stage 1, re-derived for any sample rate (the published
    /// 48 kHz coefficients are this design evaluated at 48 kHz).
    static func preFilter(sampleRate: Double) -> DSPBiquadCoefficients? {
        let frequency = 1_681.974450955533
        let gainDB = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * frequency / sampleRate)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let coefficients = DSPBiquadCoefficients(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        return coefficients.isStable ? coefficients : nil
    }

    /// BS.1770 stage 2, the revised low-frequency B-curve high-pass.
    static func rlbHighPass(sampleRate: Double) -> DSPBiquadCoefficients? {
        let frequency = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * frequency / sampleRate)
        let a0 = 1 + k / q + k * k
        let coefficients = DSPBiquadCoefficients(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        return coefficients.isStable ? coefficients : nil
    }
}

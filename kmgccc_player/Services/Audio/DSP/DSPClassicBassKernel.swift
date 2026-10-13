import Foundation

/// Classic virtual bass: envelope-normalized Chebyshev harmonic synthesis.
///
/// The Chebyshev polynomial T_k maps cos θ to cos kθ (Le Brun 1979, Arfib
/// 1979). The bass band is turned into an analytic pair (I, Q) by a 90°
/// phase-splitting allpass network, so A = √(I² + Q²) is its instantaneous
/// amplitude and I/A = cos θ is exact for any waveform, not only a steady
/// sine. A·T_k(I/A) = A·cos kθ then carries the k-th multiple of the bass
/// phase at the bass's own level, the level tracking Oo & Gan recommend for
/// psychoacoustic bass. A peak follower in place of A leaves |I/A| short of
/// 1 between peaks and over it at onsets; the even polynomials then emit a
/// DC offset that rises and falls with every note and is heard as a thump.
/// The quadrature amplitude has no such offset.
///
/// The network's corner frequencies are our own minimax fit, 0.55° from
/// quadrature over 12–300 Hz; the synthesis runs at the source rate with no
/// oversampling and no latency.
nonisolated struct DSPClassicBassKernel: DSPBlockKernel {
    private struct ChannelState {
        var floorHighPass: DSPBiquad
        var lowPass1: DSPBiquad
        var lowPass2: DSPBiquad
        var wetHighPass1: DSPBiquad
        var wetHighPass2: DSPBiquad
        var wetLowPass: DSPBiquad
        var dryHighPass: DSPBiquad
        var dcInput = 0.0
        var dcOutput = 0.0

        mutating func copyState(from source: ChannelState) {
            floorHighPass.copyState(from: source.floorHighPass)
            lowPass1.copyState(from: source.lowPass1)
            lowPass2.copyState(from: source.lowPass2)
            wetHighPass1.copyState(from: source.wetHighPass1)
            wetHighPass2.copyState(from: source.wetHighPass2)
            wetLowPass.copyState(from: source.wetLowPass)
            dryHighPass.copyState(from: source.dryHighPass)
            dcInput = source.dcInput
            dcOutput = source.dcOutput
        }

        mutating func reset() {
            floorHighPass.reset()
            lowPass1.reset()
            lowPass2.reset()
            wetHighPass1.reset()
            wetHighPass2.reset()
            wetLowPass.reset()
            dryHighPass.reset()
            dcInput = 0
            dcOutput = 0
        }
    }

    /// Envelope floor at program level, about −60 dBFS: quieter bass fades
    /// out of the synthesis instead of being normalized up.
    private static let programEpsilon = 0.001
    /// Corner frequencies of the two first-order allpass branches; the
    /// second branch leads the first by 90°.
    private static let laggingCorners = [1.423, 7.784, 43.842, 209.892, 990.936]
    private static let leadingCorners = [3.485, 19.237, 96.719, 480.311, 2_382.655]
    private static var sectionCount: Int { laggingCorners.count }

    private let selectedChannels: [Int]
    private let weights: (w2: Double, w3: Double, w4: Double, w5: Double)
    private let wetGain: Double
    private let tightensDryBass: Bool
    private let outputGain: Double
    private let dcAlpha: Double
    private let laggingCoefficients: [Double]
    private let leadingCoefficients: [Double]
    private var epsilon = DSPClassicBassKernel.programEpsilon
    private var states: [ChannelState]
    /// Per channel and section: previous input and output of the lagging
    /// branch, then of the leading branch.
    private var allpassState: [Double]

    let stateBytes: Int

    init?(
        format: DSPAudioFormat,
        selectedChannels mask: [Bool],
        parameters: DSPClassicBassParameters,
        outputKind: DSPOutputKind?
    ) {
        let sampleRate = format.sampleRate
        guard mask.count == format.channelCount, sampleRate.isFinite, sampleRate > 0 else { return nil }
        let tuning = parameters.resolved(for: outputKind)
        let wetCorner = tuning.cutoffHz * 0.7
        guard let floorHighPass = DSPFilterDesign.section(.highPass, frequencyHz: tuning.floorHz, sampleRate: sampleRate),
              let lowPass1 = DSPFilterDesign.section(.lowPass, frequencyHz: tuning.cutoffHz, sampleRate: sampleRate,
                                                      q: DSPFilterDesign.fourthOrderQs[0]),
              let lowPass2 = DSPFilterDesign.section(.lowPass, frequencyHz: tuning.cutoffHz, sampleRate: sampleRate,
                                                      q: DSPFilterDesign.fourthOrderQs[1]),
              let wetHighPass1 = DSPFilterDesign.section(.highPass, frequencyHz: wetCorner, sampleRate: sampleRate,
                                                          q: DSPFilterDesign.fourthOrderQs[0]),
              let wetHighPass2 = DSPFilterDesign.section(.highPass, frequencyHz: wetCorner, sampleRate: sampleRate,
                                                          q: DSPFilterDesign.fourthOrderQs[1]),
              let wetLowPass = DSPFilterDesign.section(.lowPass, frequencyHz: tuning.cutoffHz * 6, sampleRate: sampleRate),
              let dryHighPass = DSPFilterDesign.section(.highPass, frequencyHz: tuning.cutoffHz * 0.7,
                                                        sampleRate: sampleRate) else { return nil }
        selectedChannels = mask.indices.filter { mask[$0] }
        guard !selectedChannels.isEmpty else { return nil }

        let series = parameters.character == .round ? tuning.profile.roundWeights : tuning.profile.tightWeights
        weights = (series[0], series[1], series[2], series[3])
        wetGain = parameters.intensity * tuning.profile.intensityScale
        switch parameters.tightenDryBass {
        case .automatic: tightensDryBass = tuning.profile.tightensDryBass
        case .on: tightensDryBass = true
        case .off: tightensDryBass = false
        }
        outputGain = pow(10, parameters.outputTrimDB / 20)
        dcAlpha = exp(-2 * Double.pi * 5 / sampleRate)
        // Bilinear first-order allpass (a + z⁻¹)/(1 + a·z⁻¹) per corner.
        func coefficient(_ corner: Double) -> Double {
            let t = tan(Double.pi * min(corner, sampleRate * 0.45) / sampleRate)
            return (t - 1) / (t + 1)
        }
        laggingCoefficients = Self.laggingCorners.map(coefficient)
        leadingCoefficients = Self.leadingCorners.map(coefficient)
        let channel = ChannelState(
            floorHighPass: DSPBiquad(floorHighPass), lowPass1: DSPBiquad(lowPass1), lowPass2: DSPBiquad(lowPass2),
            wetHighPass1: DSPBiquad(wetHighPass1), wetHighPass2: DSPBiquad(wetHighPass2),
            wetLowPass: DSPBiquad(wetLowPass), dryHighPass: DSPBiquad(dryHighPass)
        )
        states = Array(repeating: channel, count: selectedChannels.count)
        allpassState = Array(repeating: 0, count: selectedChannels.count * Self.sectionCount * 4)
        stateBytes = selectedChannels.count * (MemoryLayout<ChannelState>.stride + Self.sectionCount * 32)
    }

    /// Generated level for the static headroom estimate: harmonics add on
    /// top of the dry bass, which is only part of a full-range peak.
    static func staticPeakResponseDB(parameters: DSPClassicBassParameters, outputKind: DSPOutputKind?) -> Double {
        let tuning = parameters.resolved(for: outputKind)
        let series = parameters.character == .round ? tuning.profile.roundWeights : tuning.profile.tightWeights
        let norm = series.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return 20 * log10(1 + 0.5 * parameters.intensity * tuning.profile.intensityScale * norm)
            + parameters.outputTrimDB
    }

    func makeFreshState() -> DSPClassicBassKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPClassicBassKernel) {
        guard states.count == source.states.count else { return }
        for index in states.indices { states[index].copyState(from: source.states[index]) }
        if allpassState.count == source.allpassState.count {
            DSPStateCopy.assign(&allpassState, from: source.allpassState)
        }
    }

    mutating func reset() {
        for index in states.indices { states[index].reset() }
        DSPStateCopy.clear(&allpassState)
    }

    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        guard offsetDB.isFinite else { return }
        epsilon = Self.programEpsilon * pow(10, offsetDB / 20)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        let (w2, w3, w4, w5) = weights
        let count = selectedChannels.count
        let sections = Self.sectionCount
        let epsilonSquared = epsilon * epsilon
        let dcAlpha = dcAlpha
        let wetGain = wetGain
        let outputGain = outputGain
        let tightensDryBass = tightensDryBass
        // Taking the arrays out keeps them uniquely owned while the loop
        // writes through their buffers.
        var channelStates = states
        states = []
        var quadrature = allpassState
        allpassState = []
        defer {
            states = channelStates
            allpassState = quadrature
        }
        selectedChannels.withUnsafeBufferPointer { selected in
            laggingCoefficients.withUnsafeBufferPointer { lagging in
                leadingCoefficients.withUnsafeBufferPointer { leading in
                    channelStates.withUnsafeMutableBufferPointer { states in
                        quadrature.withUnsafeMutableBufferPointer { allpass in
                            for frame in 0..<frames {
                                let base = frame * channels
                                for index in 0..<count {
                                    let offset = base + selected[index]
                                    let band = states[index].lowPass2.process(
                                        states[index].lowPass1.process(states[index].floorHighPass.process(samples[offset])))
                                    // Analytic pair: q lags i by 90° across the bass band.
                                    var q = band
                                    var i = band
                                    let stateBase = index * sections * 4
                                    for section in 0..<sections {
                                        let slot = stateBase + section * 4
                                        let a = lagging[section]
                                        let qOut = a * q + allpass[slot] - a * allpass[slot + 1]
                                        allpass[slot] = q
                                        allpass[slot + 1] = qOut
                                        q = qOut
                                        let b = leading[section]
                                        let iOut = b * i + allpass[slot + 2] - b * allpass[slot + 3]
                                        allpass[slot + 2] = i
                                        allpass[slot + 3] = iOut
                                        i = iOut
                                    }
                                    let amplitudeSquared = i * i + q * q
                                    let amplitude = amplitudeSquared.squareRoot()
                                    var harmonics = 0.0
                                    if amplitude > 1e-15 {
                                        let u = min(1, max(-1, i / amplitude))
                                        // T2…T5 by the recurrence T(k+1) = 2u·T(k) − T(k−1).
                                        let t2 = 2 * u * u - 1
                                        let t3 = 2 * u * t2 - u
                                        let t4 = 2 * u * t3 - t2
                                        let t5 = 2 * u * t4 - t3
                                        // Bass near the program floor fades out smoothly.
                                        let gate = amplitudeSquared / (amplitudeSquared + epsilonSquared)
                                        harmonics = amplitude * gate * (w2 * t2 + w3 * t3 + w4 * t4 + w5 * t5)
                                    }
                                    let dcBlocked = harmonics - states[index].dcInput + dcAlpha * states[index].dcOutput
                                    states[index].dcInput = harmonics
                                    states[index].dcOutput = dcBlocked
                                    let wet = states[index].wetLowPass.process(
                                        states[index].wetHighPass2.process(states[index].wetHighPass1.process(dcBlocked)))
                                    let dry = tightensDryBass
                                        ? states[index].dryHighPass.process(samples[offset])
                                        : samples[offset]
                                    samples[offset] = (dry + wetGain * wet) * outputGain
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

import Foundation

/// Classic virtual bass from a level-normalized analytic harmonic series.
///
/// The bass band is turned into an analytic signal z = I + jQ by a 90°
/// phase-splitting allpass network. For one tone z = a·e^{jθ}, so
/// Re(z^k)/a^{k−1} = a·cos kθ: the k-th harmonic at the bass's own level,
/// the level tracking Oo & Gan recommend for psychoacoustic bass. Because
/// z holds only positive frequencies, z^k holds only sums of them: two bass
/// notes f₁ and f₂ give k·f₁, k·f₂ and sum partials such as f₁ + f₂. This
/// avoids the direct difference products of a real-valued waveshaper;
/// the approximate quadrature and moving level divisor can still make
/// weaker sidebands. The level divisor is a peak
/// follower of |z|, fast to rise and slow to fall, rather than |z| itself:
/// dividing by the instantaneous amplitude, which beats at f₂ − f₁, would
/// write those difference tones back as sidebands. The divisor never falls
/// below |z|, so an onset cannot amplify the higher powers while the
/// follower catches up.
///
/// A low shelf strengthens the original bass without lowering the rest of
/// the music. Independently, powers 2–6 of the selected bass band create
/// consecutive pitch cues in the audible bass and lower midrange. A wet
/// high-pass keeps DC, sub-bass beating and low transient residue out of
/// the addition; the upper rolloff limits the series to at most 800 Hz.
/// The phase-splitting network is our minimax fit, 0.55° from quadrature
/// over 12–300 Hz. Processing has no oversampling or latency.
nonisolated struct DSPClassicBassKernel: DSPBlockKernel {
    private struct ChannelState {
        var floorHighPass: DSPBiquad
        var lowPass1: DSPBiquad
        var lowPass2: DSPBiquad
        var wetHighPass1: DSPBiquad
        var wetHighPass2: DSPBiquad
        var wetLowPass1: DSPBiquad
        var wetLowPass2: DSPBiquad
        var dryHighPass: DSPBiquad
        var bassShelf: DSPBiquad
        var envelope = 0.0
        var dcInput = 0.0
        var dcOutput = 0.0

        mutating func copyState(from source: ChannelState) {
            floorHighPass.copyState(from: source.floorHighPass)
            lowPass1.copyState(from: source.lowPass1)
            lowPass2.copyState(from: source.lowPass2)
            wetHighPass1.copyState(from: source.wetHighPass1)
            wetHighPass2.copyState(from: source.wetHighPass2)
            wetLowPass1.copyState(from: source.wetLowPass1)
            wetLowPass2.copyState(from: source.wetLowPass2)
            dryHighPass.copyState(from: source.dryHighPass)
            bassShelf.copyState(from: source.bassShelf)
            envelope = source.envelope
            dcInput = source.dcInput
            dcOutput = source.dcOutput
        }

        mutating func reset() {
            floorHighPass.reset()
            lowPass1.reset()
            lowPass2.reset()
            wetHighPass1.reset()
            wetHighPass2.reset()
            wetLowPass1.reset()
            wetLowPass2.reset()
            dryHighPass.reset()
            bassShelf.reset()
            envelope = 0
            dcInput = 0
            dcOutput = 0
        }
    }

    /// Envelope floor at program level, about −60 dBFS: quieter bass fades
    /// out of the synthesis instead of being normalized up.
    private static let programEpsilon = 0.001
    /// Level follower: rises within a millisecond, so |z| seldom passes it,
    /// and falls over 200 ms, several beats of two neighbouring bass notes,
    /// so it barely moves within one.
    private static let attackSeconds = 0.001
    private static let releaseSeconds = 0.2
    /// Corner frequencies of the two first-order allpass branches; the
    /// second branch leads the first by 90°.
    private static let laggingCorners = [1.423, 7.784, 43.842, 209.892, 990.936]
    private static let leadingCorners = [3.485, 19.237, 96.719, 480.311, 2_382.655]
    private static var sectionCount: Int { laggingCorners.count }

    private let selectedChannels: [Int]
    private let weights: (w2: Double, w3: Double, w4: Double, w5: Double, w6: Double)
    private let wetGain: Double
    private let tightensDryBass: Bool
    private let outputGain: Double
    private let peakCeiling: Double?
    private let dcAlpha: Double
    private let attack: Double
    private let release: Double
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
        outputKind: DSPOutputKind?,
        outputCeiling: Double? = nil
    ) {
        let sampleRate = format.sampleRate
        guard mask.count == format.channelCount, sampleRate.isFinite, sampleRate > 0 else { return nil }
        let tuning = parameters.resolved(for: outputKind)
        let sourceCutoff = min(tuning.cutoffHz, DSPBassProfile.maximumHarmonicFundamentalHz)
        let wetCorner = max(70, sourceCutoff * 0.75)
        let wetTop = DSPBassProfile.harmonicTop(cutoffHz: sourceCutoff)
        guard let floorHighPass = DSPFilterDesign.section(.highPass, frequencyHz: tuning.floorHz, sampleRate: sampleRate),
              let lowPass1 = DSPFilterDesign.section(.lowPass, frequencyHz: sourceCutoff, sampleRate: sampleRate,
                                                      q: DSPFilterDesign.fourthOrderQs[0]),
              let lowPass2 = DSPFilterDesign.section(.lowPass, frequencyHz: sourceCutoff, sampleRate: sampleRate,
                                                      q: DSPFilterDesign.fourthOrderQs[1]),
              let wetHighPass1 = DSPFilterDesign.section(.highPass, frequencyHz: wetCorner, sampleRate: sampleRate,
                                                          q: DSPFilterDesign.fourthOrderQs[0]),
              let wetHighPass2 = DSPFilterDesign.section(.highPass, frequencyHz: wetCorner, sampleRate: sampleRate,
                                                          q: DSPFilterDesign.fourthOrderQs[1]),
              let wetLowPass1 = DSPFilterDesign.section(.lowPass, frequencyHz: wetTop, sampleRate: sampleRate,
                                                         q: DSPFilterDesign.fourthOrderQs[0]),
              let wetLowPass2 = DSPFilterDesign.section(.lowPass, frequencyHz: wetTop, sampleRate: sampleRate,
                                                         q: DSPFilterDesign.fourthOrderQs[1]),
              let dryHighPass = DSPFilterDesign.section(.highPass, frequencyHz: tuning.cutoffHz * 0.7,
                                                        sampleRate: sampleRate),
              let bassShelf = DSPFilterDesign.section(.lowShelf, frequencyHz: tuning.cutoffHz, sampleRate: sampleRate,
                                                      q: 1, gainDB: parameters.bassGainDB) else { return nil }
        selectedChannels = mask.indices.filter { mask[$0] }
        guard !selectedChannels.isEmpty else { return nil }

        let series = parameters.character == .round ? tuning.profile.roundWeights : tuning.profile.tightWeights
        weights = (series[0], series[1], series[2], series[3], series[4])
        wetGain = tuning.floorHz < sourceCutoff ? parameters.intensity * tuning.profile.intensityScale : 0
        switch parameters.tightenDryBass {
        case .automatic: tightensDryBass = tuning.profile.tightensDryBass
        case .on: tightensDryBass = true
        case .off: tightensDryBass = false
        }
        let gain = pow(10, parameters.outputTrimDB / 20)
        outputGain = gain
        peakCeiling = outputCeiling.map { $0 / gain }
        dcAlpha = exp(-2 * Double.pi * 5 / sampleRate)
        attack = 1 - exp(-1 / (Self.attackSeconds * sampleRate))
        release = 1 - exp(-1 / (Self.releaseSeconds * sampleRate))
        // Bilinear first-order allpass (a + z⁻¹)/(1 + a·z⁻¹) per corner.
        func coefficient(_ corner: Double) -> Double {
            // Bilinear analogue corners also work at the hybrid engine's
            // low rate; clamping a corner at Nyquist spoils quadrature there.
            let t = Double.pi * corner / sampleRate
            return (t - 1) / (t + 1)
        }
        laggingCoefficients = Self.laggingCorners.map(coefficient)
        leadingCoefficients = Self.leadingCorners.map(coefficient)
        let channel = ChannelState(
            floorHighPass: DSPBiquad(floorHighPass), lowPass1: DSPBiquad(lowPass1), lowPass2: DSPBiquad(lowPass2),
            wetHighPass1: DSPBiquad(wetHighPass1), wetHighPass2: DSPBiquad(wetHighPass2),
            wetLowPass1: DSPBiquad(wetLowPass1), wetLowPass2: DSPBiquad(wetLowPass2),
            dryHighPass: DSPBiquad(dryHighPass), bassShelf: DSPBiquad(bassShelf)
        )
        states = Array(repeating: channel, count: selectedChannels.count)
        allpassState = Array(repeating: 0, count: selectedChannels.count * Self.sectionCount * 4)
        stateBytes = selectedChannels.count * (MemoryLayout<ChannelState>.stride + Self.sectionCount * 32)
    }

    /// Bass reinforcement leaves the rest of the track at its original
    /// level. Reserve only an explicit broadband trim; peaks use the chain's
    /// limiter instead of turning the entire track down before this effect.
    static func staticPeakResponseDB(parameters: DSPClassicBassParameters, outputKind: DSPOutputKind?) -> Double {
        parameters.outputTrimDB
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
        // An ordinary bass shelf needs neither quadrature nor synthesis.
        if wetGain == 0 {
            for frame in 0..<frames {
                for index in selectedChannels.indices {
                    let offset = frame * channels + selectedChannels[index]
                    let dry = tightensDryBass ? states[index].dryHighPass.process(samples[offset]) : samples[offset]
                    let enhanced = states[index].bassShelf.process(dry)
                    samples[offset] = DSPBassPeakControl.mix(original: dry, enhanced: enhanced, ceiling: peakCeiling) * outputGain
                }
            }
            return
        }
        let (w2, w3, w4, w5, w6) = weights
        let count = selectedChannels.count
        let sections = Self.sectionCount
        let epsilonSquared = epsilon * epsilon
        let dcAlpha = dcAlpha
        let attack = attack
        let release = release
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
                                    let amplitude = (i * i + q * q).squareRoot()
                                    var envelope = states[index].envelope
                                    envelope += (amplitude > envelope ? attack : release) * (amplitude - envelope)
                                    states[index].envelope = envelope
                                    var harmonics = 0.0
                                    if envelope > 1e-15 {
                                        // Bound the normalised powers while the
                                        // level follower catches up at an onset.
                                        let divisor = max(envelope, amplitude)
                                        let ur = i / divisor
                                        let ui = q / divisor
                                        // Complex powers avoid the direct difference
                                        // products of real Chebyshev polynomials.
                                        let u2r = ur * ur - ui * ui, u2i = 2 * ur * ui
                                        let u3r = u2r * ur - u2i * ui, u3i = u2r * ui + u2i * ur
                                        let u4r = u3r * ur - u3i * ui, u4i = u3r * ui + u3i * ur
                                        let u5r = u4r * ur - u4i * ui, u5i = u4r * ui + u4i * ur
                                        let u6r = u5r * ur - u5i * ui
                                        // Bass near the program floor fades out smoothly.
                                        let envelopeSquared = envelope * envelope
                                        let gate = envelopeSquared / (envelopeSquared + epsilonSquared)
                                        let series = w2 * u2r + w3 * u3r + w4 * u4r + w5 * u5r + w6 * u6r
                                        harmonics = envelope * gate * series
                                    }
                                    let dcBlocked = harmonics - states[index].dcInput + dcAlpha * states[index].dcOutput
                                    states[index].dcInput = harmonics
                                    states[index].dcOutput = dcBlocked
                                    let highPassed = states[index].wetHighPass2.process(
                                        states[index].wetHighPass1.process(dcBlocked))
                                    let wet = states[index].wetLowPass2.process(states[index].wetLowPass1.process(highPassed))
                                    let dry = tightensDryBass
                                        ? states[index].dryHighPass.process(samples[offset])
                                        : samples[offset]
                                    let enhanced = states[index].bassShelf.process(dry + wetGain * wet)
                                    samples[offset] = DSPBassPeakControl.mix(original: dry, enhanced: enhanced, ceiling: peakCeiling) * outputGain
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

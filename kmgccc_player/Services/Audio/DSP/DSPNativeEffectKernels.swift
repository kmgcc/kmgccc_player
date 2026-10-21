import Accelerate
import Foundation

/// State copies between equally shaped kernels. Writing into the existing
/// storage keeps both sides uniquely owned, so neither the copy nor the next
/// processed block allocates.
nonisolated enum DSPStateCopy {
    static func assign<Element>(_ destination: inout [Element], from source: [Element]) {
        guard destination.count == source.count else {
            destination = source
            return
        }
        guard !source.isEmpty else { return }
        destination.withUnsafeMutableBufferPointer { target in
            source.withUnsafeBufferPointer { origin in
                target.baseAddress!.update(from: origin.baseAddress!, count: origin.count)
            }
        }
    }

    static func clear(_ values: inout [Double]) {
        guard !values.isEmpty else { return }
        values.withUnsafeMutableBufferPointer { buffer in
            vDSP_vclrD(buffer.baseAddress!, 1, vDSP_Length(buffer.count))
        }
    }
}

/// Immutable polyphase coefficients shared by the live and preview states of
/// one native nonlinear node. Each FIR is symmetric with 32 source-frame delay;
/// interpolation and reconstruction therefore contribute 64 source frames.
///
/// The sinc cuts at the source Nyquist, so at 44.1 kHz the transition band
/// sits between 20 and 24.1 kHz: the passband stays flat to 20 kHz and only
/// frequencies that fold back above 20 kHz see the transition. A Kaiser
/// window (beta 9) at this fixed length keeps the 0–20 kHz cascade within
/// 0.001 dB and holds images and aliases landing below 20 kHz under −89 dB,
/// about 14 dB lower than the former Blackman window.
nonisolated struct DSPPolyphaseFIRPlan {
    static let kaiserBeta = 9.0

    let factor: Int
    let tapCount: Int
    let historyCount: Int
    let interpolationWeights: [[Double]]
    let decimationWeights: [Double]
    private let interpolationPlans: [DSPFIRDotPlan]
    private let decimationPlan: DSPFIRDotPlan

    init?(factor: Int) {
        guard factor == 2 || factor == 4 else { return nil }
        self.factor = factor
        tapCount = factor * 64 + 1
        let historyCount = 65
        self.historyCount = historyCount

        let center = Double(tapCount - 1) / 2
        let windowScale = 1 / Self.besselI0(Self.kaiserBeta)
        var impulse = [Double](repeating: 0, count: tapCount)
        var sum = 0.0
        for index in impulse.indices {
            let offset = Double(index) - center
            let normalizedOffset = offset / Double(factor)
            let sinc = abs(normalizedOffset) < 1e-14
                ? 1
                : sin(Double.pi * normalizedOffset) / (Double.pi * normalizedOffset)
            let windowPosition = offset / center
            let window = Self.besselI0(
                Self.kaiserBeta * sqrt(max(0, 1 - windowPosition * windowPosition))
            ) * windowScale
            let coefficient = sinc * window / Double(factor)
            impulse[index] = coefficient
            sum += coefficient
        }
        guard sum.isFinite, abs(sum) > 1e-15 else { return nil }
        for index in impulse.indices { impulse[index] /= sum }

        let weights = (0..<factor).map { phase in
            var sourceDelayWeights = [Double](repeating: 0, count: historyCount)
            for delay in 0..<historyCount {
                let tap = phase + delay * factor
                if tap < impulse.count {
                    sourceDelayWeights[delay] = impulse[tap] * Double(factor)
                }
            }
            let phaseSum = sourceDelayWeights.reduce(0, +)
            if phaseSum.isFinite, abs(phaseSum) > 1e-15 {
                for index in sourceDelayWeights.indices { sourceDelayWeights[index] /= phaseSum }
            }
            return Array(sourceDelayWeights.reversed())
        }
        interpolationWeights = weights
        interpolationPlans = weights.map(DSPFIRDotPlan.init)
        let reconstruction = Array(impulse.reversed())
        decimationWeights = reconstruction
        decimationPlan = DSPFIRDotPlan(weights: reconstruction)
    }

    func interpolate(phase: Int, history: DSPMirroredFIRHistory) -> Double {
        history.dot(interpolationPlans[phase])
    }

    func decimate(history: DSPMirroredFIRHistory) -> Double {
        history.dot(decimationPlan)
    }

    /// Zeroth-order modified Bessel function of the first kind, by its power
    /// series; converges in a few dozen terms for the window's arguments.
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        var k = 1.0
        let halfX = x / 2
        while term > 1e-17 * sum {
            term *= (halfX / k) * (halfX / k)
            sum += term
            k += 1
        }
        return sum
    }
}

/// Elide the sinc's exact zero taps and fold symmetric tap pairs. Phase zero
/// reduces to a single delayed sample; no vector-library call is needed.
fileprivate nonisolated struct DSPFIRDotPlan {
    let count: Int
    let left: [Int]
    let right: [Int]
    let weights: [Double]

    init(weights: [Double]) {
        count = weights.count
        var a = [Int](), b = [Int](), c = [Double]()
        var index = 0
        while index < weights.count {
            let mirror = weights.count - 1 - index
            if index <= mirror, abs(weights[index] - weights[mirror]) < 1e-15 {
                let weight = (weights[index] + weights[mirror]) * 0.5
                if abs(weight) > 1e-15 { a.append(index); b.append(mirror); c.append(weight) }
                index += 1
                if index > mirror { break }
            } else {
                // Non-symmetric polyphase arms retain their original taps.
                a.removeAll(keepingCapacity: true)
                b.removeAll(keepingCapacity: true)
                c.removeAll(keepingCapacity: true)
                for tap in weights.indices where abs(weights[tap]) > 1e-15 {
                    a.append(tap); b.append(tap); c.append(weights[tap])
                }
                break
            }
        }
        left = a; right = b; self.weights = c
    }
}

/// Double-precision ring with a mirrored tail so each dot product reads one
/// contiguous window without copying or indexing every tap in Swift.
nonisolated struct DSPMirroredFIRHistory {
    private(set) var storage: [Double]
    private let capacity: Int
    private(set) var cursor = -1

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: 0, count: max(1, capacity) * 2)
    }

    mutating func push(_ sample: Double) {
        cursor = (cursor + 1) % capacity
        storage[cursor] = sample
        storage[cursor + capacity] = sample
    }

    func dot(_ weights: [Double]) -> Double {
        guard cursor >= 0, weights.count == capacity else { return 0 }
        var result = 0.0
        storage.withUnsafeBufferPointer { samples in
            weights.withUnsafeBufferPointer { coefficients in
                guard let sampleBase = samples.baseAddress,
                      let coefficientBase = coefficients.baseAddress else { return }
                vDSP_dotprD(
                    sampleBase.advanced(by: cursor + 1),
                    1,
                    coefficientBase,
                    1,
                    &result,
                    vDSP_Length(capacity)
                )
            }
        }
        return result
    }

    fileprivate func dot(_ plan: DSPFIRDotPlan) -> Double {
        guard cursor >= 0, plan.count == capacity else { return 0 }
        let start = cursor + 1
        return storage.withUnsafeBufferPointer { history in
            plan.weights.withUnsafeBufferPointer { weights in
                plan.left.withUnsafeBufferPointer { left in
                    plan.right.withUnsafeBufferPointer { right in
                        let samples = history.baseAddress!.advanced(by: start)
                        var sum = 0.0
                        for index in weights.indices {
                            let a = left[index], b = right[index]
                            sum += weights[index] * (a == b ? samples[a] : samples[a] + samples[b])
                        }
                        return sum
                    }
                }
            }
        }
    }

    mutating func copyState(from source: DSPMirroredFIRHistory) {
        guard capacity == source.capacity, storage.count == source.storage.count else { return }
        DSPStateCopy.assign(&storage, from: source.storage)
        cursor = source.cursor
    }

    mutating func reset() {
        DSPStateCopy.clear(&storage)
        cursor = -1
    }
}

nonisolated struct DSPNativeBiquadState {
    private let coefficients: DSPBiquadCoefficients
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(coefficients: DSPBiquadCoefficients) {
        self.coefficients = coefficients
    }

    mutating func copyState(from source: DSPNativeBiquadState) {
        x1 = source.x1
        x2 = source.x2
        y1 = source.y1
        y2 = source.y2
    }

    mutating func process(_ input: Double) -> Double {
        let output = coefficients.b0 * input
            + coefficients.b1 * x1
            + coefficients.b2 * x2
            - coefficients.a1 * y1
            - coefficients.a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }
}

/// Exact 64 source-frame delay shared by dry and unrouted channels while a
/// nonlinear wet path traverses its two 32-frame FIR stages.
nonisolated struct DSPFixedDelay64 {
    private var storage = [Double](repeating: 0, count: 64)
    private var cursor = 0

    mutating func process(_ sample: Double) -> Double {
        let delayed = storage[cursor]
        storage[cursor] = sample
        cursor = (cursor + 1) % storage.count
        return delayed
    }

    mutating func copyState(from source: DSPFixedDelay64) {
        DSPStateCopy.assign(&storage, from: source.storage)
        cursor = source.cursor
    }

    mutating func reset() {
        DSPStateCopy.clear(&storage)
        cursor = 0
    }
}

/// Tube coloration in two modes on one oversampling framework.
///
/// Classic drives the whole signal through a biased hyperbolic tangent and
/// mixes it with the dry path. Hi-fi leaves the dry path untouched and adds
/// predominantly low-order harmonics generated separately in three bands below
/// 5 kHz (80–300 Hz, 300 Hz–1.2 kHz, 1.2–5 kHz); intermodulation stays
/// inside each band, so a bass note never modulates the cymbals. The
/// band-split harmonic idea follows JamesDSP's analog modelling; the
/// implementation and tuning are our own.
nonisolated struct DSPTubeKernel {
    /// Digital peaks need room above the tube's nominal operating level.
    /// The wet-path normalization cancels this scale at small amplitudes.
    private static let workingLevel = 0.1
    /// Hi-fi generator bands at the oversampled rate.
    static let hifiBands: [(low: Double, high: Double)] = [(80, 300), (300, 1_200), (1_200, 5_000)]
    /// At a full-scale band peak and amount 0.4, the second harmonic is
    /// about −36 dB relative to the original, before band filtering.
    static let hifiSecondOrderScale = 0.79

    /// Smoothly bound the generator input. A hard clamp here introduces
    /// high-order harmonics before the reconstruction filter can remove them.
    @inline(__always)
    private static func hifiBandSample(_ input: Double) -> Double {
        input / sqrt(1 + 0.25 * input * input)
    }

    /// Static allowance for a unit program peak; filters and DC-block
    /// transients still leave the final peak guarantee to the chain limiter.
    static func staticPeakResponseDB(parameters: DSPTubeParameters) -> Double {
        let inputGain = pow(10, parameters.inputTrimDB / 20)
        let peak: Double
        switch parameters.mode {
        case .classic:
            let biasOutput = tanh(parameters.bias)
            let maximumSlope = 1 / (1 - biasOutput * biasOutput)
            peak = (1 - parameters.mix) + parameters.mix * inputGain * maximumSlope
        case .hifi:
            let bandPeak = hifiBandSample(inputGain * workingLevel)
            let secondOrder = hifiSecondOrderScale * parameters.hifiAmount
            let thirdOrder = secondOrder / 4
            let squared = bandPeak * bandPeak
            peak = 1 + Double(hifiBands.count) * (secondOrder * squared + thirdOrder * squared * bandPeak) / workingLevel
        }
        return 20 * log10(max(1, peak)) + parameters.outputTrimDB
    }

    private struct ChannelState {
        var wetInput: DSPMirroredFIRHistory
        var reconstruction: DSPMirroredFIRHistory
        var dryDelay = DSPFixedDelay64()
        var dcInput = 0.0
        var dcOutput = 0.0
        /// High-pass then low-pass section per hi-fi band.
        var bandFilters: [DSPBiquad]

        init(plan: DSPPolyphaseFIRPlan, allocatesWetState: Bool, bandFilters: [DSPBiquad]) {
            // Front-pair/full-range routing can leave many channels untouched;
            // avoid allocating FIR storage for those channels.
            wetInput = DSPMirroredFIRHistory(
                capacity: allocatesWetState ? plan.historyCount : 1
            )
            reconstruction = DSPMirroredFIRHistory(
                capacity: allocatesWetState ? plan.tapCount : 1
            )
            self.bandFilters = allocatesWetState ? bandFilters : []
        }

        mutating func copyState(from source: ChannelState) {
            wetInput.copyState(from: source.wetInput)
            reconstruction.copyState(from: source.reconstruction)
            dryDelay.copyState(from: source.dryDelay)
            dcInput = source.dcInput
            dcOutput = source.dcOutput
            if bandFilters.count == source.bandFilters.count {
                for index in bandFilters.indices { bandFilters[index].copyState(from: source.bandFilters[index]) }
            }
        }

        mutating func reset() {
            wetInput.reset()
            reconstruction.reset()
            dryDelay.reset()
            dcInput = 0
            dcOutput = 0
            for index in bandFilters.indices { bandFilters[index].reset() }
        }
    }

    private let plan: DSPPolyphaseFIRPlan
    private let selectedChannels: [Bool]
    private let drive: Double
    private let bias: Double
    private let biasOutput: Double
    private let smallSignalNormalization: Double
    private let inputGain: Double
    private let mix: Double
    private let outputGain: Double
    private let dcRemovalEnabled: Bool
    private let dcAlpha: Double
    /// Gain into the shaper: drive, the node's input trim, and the inverse of
    /// the gain staging upstream of the node (see `setProgramLevelOffset`).
    private var shaperGain: Double
    /// Returns the shaped signal to the level it arrived at, at unity
    /// small-signal gain.
    private var wetNormalization: Double
    private let mode: DSPTubeMode
    private let secondOrder: Double
    private let thirdOrder: Double
    /// Hi-fi generator input gain (input trim at program level) and the
    /// scale that returns its output to signal level.
    private var harmonicInputGain: Double
    private var harmonicOutputScale: Double
    private var states: [ChannelState]

    init?(
        format: DSPAudioFormat,
        selectedChannels: [Bool],
        parameters: DSPTubeParameters,
        factor: Int
    ) {
        guard selectedChannels.count == format.channelCount,
              let plan = DSPPolyphaseFIRPlan(factor: factor) else { return nil }
        var bandFilters: [DSPBiquad] = []
        if parameters.mode == .hifi {
            let rate = format.sampleRate * Double(factor)
            for band in Self.hifiBands {
                guard let highPass = DSPFilterDesign.section(.highPass, frequencyHz: band.low, sampleRate: rate),
                      let lowPass = DSPFilterDesign.section(.lowPass, frequencyHz: band.high, sampleRate: rate)
                else { return nil }
                bandFilters += [DSPBiquad(highPass), DSPBiquad(lowPass)]
            }
        }
        mode = parameters.mode
        secondOrder = Self.hifiSecondOrderScale * parameters.hifiAmount
        thirdOrder = secondOrder / 4
        harmonicInputGain = pow(10, parameters.inputTrimDB / 20) * Self.workingLevel
        harmonicOutputScale = 1 / Self.workingLevel
        self.plan = plan
        self.selectedChannels = selectedChannels
        drive = pow(10, parameters.driveDB / 20) * Self.workingLevel
        bias = parameters.bias
        biasOutput = tanh(parameters.bias)
        smallSignalNormalization = max(
            1e-12,
            drive * (1 - biasOutput * biasOutput)
        )
        inputGain = pow(10, parameters.inputTrimDB / 20)
        mix = parameters.mix
        outputGain = pow(10, parameters.outputTrimDB / 20)
        dcRemovalEnabled = parameters.dcRemovalEnabled
        dcAlpha = exp(-2 * Double.pi * parameters.dcBlockHz
            / (format.sampleRate * Double(factor)))
        shaperGain = inputGain * drive
        wetNormalization = 1 / smallSignalNormalization
        states = selectedChannels.map { allocatesWetState in
            ChannelState(plan: plan, allocatesWetState: allocatesWetState, bandFilters: bandFilters)
        }
    }

    private init(copyingConfiguration source: DSPTubeKernel) {
        mode = source.mode
        secondOrder = source.secondOrder
        thirdOrder = source.thirdOrder
        harmonicInputGain = source.harmonicInputGain
        harmonicOutputScale = source.harmonicOutputScale
        plan = source.plan
        selectedChannels = source.selectedChannels
        drive = source.drive
        bias = source.bias
        biasOutput = source.biasOutput
        smallSignalNormalization = source.smallSignalNormalization
        inputGain = source.inputGain
        mix = source.mix
        outputGain = source.outputGain
        dcRemovalEnabled = source.dcRemovalEnabled
        dcAlpha = source.dcAlpha
        shaperGain = source.shaperGain
        wetNormalization = source.wetNormalization
        states = source.states
        reset()
    }

    /// The shaper saturates at an absolute level, so gain the listener adds
    /// upstream (chain input gain, headroom, node trims) would otherwise
    /// decide how hard it is driven. The shaper input is returned to program
    /// level and the wet output scaled back by the same amount: the overall
    /// level still follows those gains, the amount of saturation does not.
    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        guard offsetDB.isFinite else { return }
        let reference = pow(10, -offsetDB / 20)
        shaperGain = inputGain * drive * reference
        wetNormalization = 1 / (smallSignalNormalization * reference)
        harmonicInputGain = inputGain * reference * Self.workingLevel
        harmonicOutputScale = 1 / (reference * Self.workingLevel)
    }

    func makeFreshState() -> DSPTubeKernel {
        DSPTubeKernel(copyingConfiguration: self)
    }

    mutating func copyState(from source: DSPTubeKernel) {
        guard states.count == source.states.count, plan.factor == source.plan.factor,
              selectedChannels == source.selectedChannels else { return }
        for index in states.indices { states[index].copyState(from: source.states[index]) }
    }

    mutating func reset() {
        for index in states.indices { states[index].reset() }
    }

    mutating func processFrame(_ frame: inout [Double]) {
        for channel in frame.indices {
            let dry = frame[channel]
            let delayedDry = states[channel].dryDelay.process(dry)
            if selectedChannels[channel], mode == .hifi {
                states[channel].wetInput.push(dry)
                var harmonicsOutput = 0.0
                for phase in 0..<plan.factor {
                    let upsampled = plan.interpolate(phase: phase, history: states[channel].wetInput)
                    let x = upsampled * harmonicInputGain
                    var generated = 0.0
                    for band in 0..<(states[channel].bandFilters.count / 2) {
                        let highPassed = states[channel].bandFilters[band * 2].process(x)
                        let banded = Self.hifiBandSample(states[channel].bandFilters[band * 2 + 1].process(highPassed))
                        let squared = banded * banded
                        generated += secondOrder * squared + thirdOrder * squared * banded
                    }
                    let dcBlocked = generated - states[channel].dcInput + dcAlpha * states[channel].dcOutput
                    states[channel].dcInput = generated
                    states[channel].dcOutput = dcBlocked
                    states[channel].reconstruction.push(dcBlocked * harmonicOutputScale)
                    if phase == 0 {
                        harmonicsOutput = plan.decimate(history: states[channel].reconstruction)
                    }
                }
                frame[channel] = (delayedDry + harmonicsOutput) * outputGain
            } else if selectedChannels[channel] {
                states[channel].wetInput.push(dry)
                var wetOutput = 0.0
                for phase in 0..<plan.factor {
                    let wetHigh = plan.interpolate(phase: phase, history: states[channel].wetInput)
                    let driven = wetHigh * shaperGain + bias
                    let shaped = (tanh(driven) - biasOutput) * wetNormalization
                    var wet = shaped
                    if dcRemovalEnabled {
                        let dcBlocked = wet - states[channel].dcInput + dcAlpha * states[channel].dcOutput
                        states[channel].dcInput = wet
                        states[channel].dcOutput = dcBlocked
                        wet = dcBlocked
                    }
                    states[channel].reconstruction.push(wet)
                    if phase == 0 {
                        wetOutput = plan.decimate(history: states[channel].reconstruction)
                    }
                }
                frame[channel] = (delayedDry * (1 - mix) + wetOutput * mix) * outputGain
            } else {
                frame[channel] = delayedDry
            }
        }
    }
}

/// Channel-linked lookahead peak limiter.
///
/// Each frame's required gain enters a sliding minimum over the lookahead
/// window, so a peak is seen a full lookahead before it leaves the delay
/// line. That target drives an envelope that falls at once, holds briefly
/// so bass waveforms are not tracked cycle by cycle, then releases on the
/// decibel scale. A moving average of the envelope over the same window
/// spreads every reduction into a ramp as long as the lookahead. Each value
/// in that average is at or below the delayed sample's own requirement, so
/// the output never leaves above the ceiling.
nonisolated struct DSPPeakLimiterKernel {
    static let lookaheadSeconds = 0.005
    private static let holdSeconds = 0.02

    static func lookaheadFrames(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 1 }
        return max(1, Int((sampleRate * lookaheadSeconds).rounded()))
    }

    /// Lookahead at the highest supported rate, for budgets made without a format.
    static let maximumLookaheadFrames = lookaheadFrames(sampleRate: 384_000)

    let latencyFrames: Int
    private let window: Int
    private let channelCount: Int
    private let ceiling: Double
    private let releaseExponent: Double
    private let holdFrames: Int

    static let meterFrames = 1_024
    private(set) var meterBlocks: [Float] = []
    private var minimumGainInChunk = 1.0
    private var meterFrameCount = 0

    private var delay: [Double]
    private var delayCursor = 0
    private var neededGains: [Double]
    private var envelopes: [Double]
    private var envelopeSum: Double
    private var windowCursor = 0
    private var minimumFrames: [Int]
    private var minimumGains: [Double]
    private var minimumHead = 0
    private var minimumCount = 0
    private var frameIndex = 0
    private var envelope = 1.0
    private var holdRemaining = 0

    /// `ceiling` is linear and measured at the point the kernel runs.
    init?(channelCount: Int, sampleRate: Double, ceiling: Double, releaseSeconds: Double) {
        guard channelCount > 0, sampleRate.isFinite, sampleRate > 0,
              ceiling.isFinite, ceiling > 0,
              releaseSeconds.isFinite, releaseSeconds > 0 else { return nil }
        latencyFrames = Self.lookaheadFrames(sampleRate: sampleRate)
        window = latencyFrames + 1
        self.channelCount = channelCount
        self.ceiling = ceiling
        // Release is a time constant on the decibel scale: gainDB *= exponent.
        releaseExponent = exp(-1 / (releaseSeconds * sampleRate))
        holdFrames = Int((Self.holdSeconds * sampleRate).rounded())
        delay = Array(repeating: 0, count: latencyFrames * channelCount)
        neededGains = Array(repeating: 1, count: window)
        envelopes = Array(repeating: 1, count: window)
        envelopeSum = Double(window)
        minimumFrames = Array(repeating: 0, count: window)
        minimumGains = Array(repeating: 1, count: window)
    }

    func makeFreshState() -> DSPPeakLimiterKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPPeakLimiterKernel) {
        guard source.channelCount == channelCount, source.window == window else { return }
        DSPStateCopy.assign(&delay, from: source.delay)
        DSPStateCopy.assign(&neededGains, from: source.neededGains)
        DSPStateCopy.assign(&envelopes, from: source.envelopes)
        DSPStateCopy.assign(&minimumFrames, from: source.minimumFrames)
        DSPStateCopy.assign(&minimumGains, from: source.minimumGains)
        DSPStateCopy.assign(&meterBlocks, from: source.meterBlocks)
        minimumGainInChunk = source.minimumGainInChunk
        meterFrameCount = source.meterFrameCount
        envelopeSum = source.envelopeSum
        delayCursor = source.delayCursor
        windowCursor = source.windowCursor
        minimumHead = source.minimumHead
        minimumCount = source.minimumCount
        frameIndex = source.frameIndex
        envelope = source.envelope
        holdRemaining = source.holdRemaining
    }

    mutating func reset() {
        for index in delay.indices { delay[index] = 0 }
        for index in 0..<window {
            neededGains[index] = 1
            envelopes[index] = 1
        }
        envelopeSum = Double(window)
        delayCursor = 0
        windowCursor = 0
        minimumHead = 0
        minimumCount = 0
        frameIndex = 0
        envelope = 1
        holdRemaining = 0
        meterBlocks.removeAll()
        minimumGainInChunk = 1.0
        meterFrameCount = 0
    }

    mutating func beginBlock() {
        meterBlocks.removeAll(keepingCapacity: true)
        minimumGainInChunk = 1.0
        meterFrameCount = 0
    }

    mutating func flushRemainingMeterChunk() {
        if meterFrameCount > 0 {
            let reductionDB = minimumGainInChunk < 0.999 ? Float(max(0, -20.0 * log10(max(1e-6, minimumGainInChunk)))) : 0.0
            meterBlocks.append(reductionDB)
            minimumGainInChunk = 1.0
            meterFrameCount = 0
        }
    }

    mutating func processFrame(_ frame: inout [Double]) {
        var peak = 0.0
        for channel in 0..<channelCount { peak = max(peak, abs(frame[channel])) }
        let needed = peak > ceiling ? ceiling / peak : 1

        // Sliding minimum over the last `window` frames, amortized O(1).
        if minimumCount > 0, minimumFrames[minimumHead] <= frameIndex - window {
            minimumHead = (minimumHead + 1) % window
            minimumCount -= 1
        }
        while minimumCount > 0 {
            let back = (minimumHead + minimumCount - 1) % window
            guard minimumGains[back] >= needed else { break }
            minimumCount -= 1
        }
        let tail = (minimumHead + minimumCount) % window
        minimumFrames[tail] = frameIndex
        minimumGains[tail] = needed
        minimumCount += 1
        frameIndex += 1
        let target = minimumGains[minimumHead]

        if target <= envelope {
            envelope = target
            holdRemaining = holdFrames
        } else if holdRemaining > 0 {
            holdRemaining -= 1
        } else if envelope < 1 {
            envelope = min(target, pow(envelope, releaseExponent))
        }

        envelopeSum += envelope - envelopes[windowCursor]
        envelopes[windowCursor] = envelope
        neededGains[windowCursor] = needed
        windowCursor = (windowCursor + 1) % window
        if windowCursor == 0 {
            // Clears rounding drift from the running sum once per window.
            envelopeSum = 0
            for value in envelopes { envelopeSum += value }
        }
        // The oldest entry is the frame now leaving the delay line.
        let delayedNeeded = neededGains[windowCursor]
        let gain = min(1, delayedNeeded, envelopeSum / Double(window))

        if gain < minimumGainInChunk {
            minimumGainInChunk = gain
        }
        meterFrameCount += 1
        if meterFrameCount >= Self.meterFrames {
            let reductionDB = minimumGainInChunk < 0.999 ? Float(max(0, -20.0 * log10(max(1e-6, minimumGainInChunk)))) : 0.0
            meterBlocks.append(reductionDB)
            minimumGainInChunk = 1.0
            meterFrameCount = 0
        }

        let offset = delayCursor * channelCount
        for channel in 0..<channelCount {
            let delayed = delay[offset + channel]
            delay[offset + channel] = frame[channel]
            frame[channel] = delayed * gain
        }
        delayCursor = (delayCursor + 1) % latencyFrames
    }
}

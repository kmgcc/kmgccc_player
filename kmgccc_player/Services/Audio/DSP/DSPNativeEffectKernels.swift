import Accelerate
import Foundation

/// Immutable polyphase coefficients shared by the live and preview states of
/// one native nonlinear node. Each FIR is symmetric with 32 source-frame delay;
/// interpolation and reconstruction therefore contribute 64 source frames.
nonisolated struct DSPPolyphaseFIRPlan {
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
        var impulse = [Double](repeating: 0, count: tapCount)
        var sum = 0.0
        for index in impulse.indices {
            let offset = Double(index) - center
            let normalizedOffset = offset / Double(factor)
            let sinc = abs(normalizedOffset) < 1e-14
                ? 1
                : sin(Double.pi * normalizedOffset) / (Double.pi * normalizedOffset)
            let windowPosition = offset / center
            let window = 0.42
                + 0.5 * cos(Double.pi * windowPosition)
                + 0.08 * cos(2 * Double.pi * windowPosition)
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
        for index in storage.indices { storage[index] = source.storage[index] }
        cursor = source.cursor
    }

    mutating func reset() {
        for index in storage.indices { storage[index] = 0 }
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
        for index in storage.indices { storage[index] = source.storage[index] }
        cursor = source.cursor
    }

    mutating func reset() {
        for index in storage.indices { storage[index] = 0 }
        cursor = 0
    }
}

nonisolated struct DSPStereoWidthKernel {
    let leftChannel: Int
    let rightChannel: Int
    let width: Double
    let outputGain: Double

    func processBlock(_ samples: inout [Double], frames: Int, channels: Int) {
        samples.withUnsafeMutableBufferPointer { buffer in
            for frame in 0..<frames {
                let offset = frame * channels
                let left = buffer[offset + leftChannel]
                let right = buffer[offset + rightChannel]
                let mid = (left + right) * 0.5
                let side = (left - right) * 0.5 * width
                buffer[offset + leftChannel] = (mid + side) * outputGain
                buffer[offset + rightChannel] = (mid - side) * outputGain
            }
        }
    }

    func processFrame(_ frame: inout [Double]) {
        let left = frame[leftChannel]
        let right = frame[rightChannel]
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5 * width
        frame[leftChannel] = (mid + side) * outputGain
        frame[rightChannel] = (mid - side) * outputGain
    }
}

nonisolated struct DSPVirtualBassKernel {
    private struct ChannelState {
        var bassInput: DSPMirroredFIRHistory
        var reconstruction: DSPMirroredFIRHistory
        var dryDelay = DSPFixedDelay64()
        var sourceHighPass: DSPNativeBiquadState
        var sourceLowPass: DSPNativeBiquadState
        var wetHighPass: DSPNativeBiquadState
        var wetLowPass: DSPNativeBiquadState
        var dcInput = 0.0
        var dcOutput = 0.0

        init(
            plan: DSPPolyphaseFIRPlan,
            allocatesWetState: Bool,
            sourceHighPass: DSPBiquadCoefficients,
            sourceLowPass: DSPBiquadCoefficients,
            wetHighPass: DSPBiquadCoefficients,
            wetLowPass: DSPBiquadCoefficients
        ) {
            // Unrouted channels only carry the exact dry alignment delay.
            // Keep tiny inert rings so every state has the same value shape,
            // while selected channels alone own the oversampling histories.
            bassInput = DSPMirroredFIRHistory(
                capacity: allocatesWetState ? plan.historyCount : 1
            )
            reconstruction = DSPMirroredFIRHistory(
                capacity: allocatesWetState ? plan.tapCount : 1
            )
            self.sourceHighPass = DSPNativeBiquadState(coefficients: sourceHighPass)
            self.sourceLowPass = DSPNativeBiquadState(coefficients: sourceLowPass)
            self.wetHighPass = DSPNativeBiquadState(coefficients: wetHighPass)
            self.wetLowPass = DSPNativeBiquadState(coefficients: wetLowPass)
        }

        mutating func copyState(from source: ChannelState) {
            bassInput.copyState(from: source.bassInput)
            reconstruction.copyState(from: source.reconstruction)
            dryDelay.copyState(from: source.dryDelay)
            sourceHighPass.copyState(from: source.sourceHighPass)
            sourceLowPass.copyState(from: source.sourceLowPass)
            wetHighPass.copyState(from: source.wetHighPass)
            wetLowPass.copyState(from: source.wetLowPass)
            dcInput = source.dcInput
            dcOutput = source.dcOutput
        }

        mutating func reset() {
            bassInput.reset()
            reconstruction.reset()
            dryDelay.reset()
            sourceHighPass.reset()
            sourceLowPass.reset()
            wetHighPass.reset()
            wetLowPass.reset()
            dcInput = 0
            dcOutput = 0
        }
    }

    private let plan: DSPPolyphaseFIRPlan
    private let selectedChannels: [Bool]
    private let sourceHighPass: DSPBiquadCoefficients
    private let sourceLowPass: DSPBiquadCoefficients
    private let wetHighPass: DSPBiquadCoefficients
    private let wetLowPass: DSPBiquadCoefficients
    private let drive: Double
    private let evenNormalization: Double
    private let oddNormalization: Double
    private let harmonics: Double
    private let wetGain: Double
    private let outputGain: Double
    private let dcAlpha: Double
    private var states: [ChannelState]

    init?(
        format: DSPAudioFormat,
        selectedChannels: [Bool],
        parameters: DSPVirtualBassParameters,
        factor: Int
    ) {
        guard selectedChannels.count == format.channelCount,
              let plan = DSPPolyphaseFIRPlan(factor: factor),
              let sourceHighPass = Self.coefficients(
                type: .highPass,
                frequencyHz: parameters.lowFrequencyHz,
                sampleRate: format.sampleRate
              ),
              let sourceLowPass = Self.coefficients(
                type: .lowPass,
                frequencyHz: parameters.highFrequencyHz,
                sampleRate: format.sampleRate
              ),
              let wetHighPass = Self.coefficients(
                type: .highPass,
                frequencyHz: parameters.highFrequencyHz,
                sampleRate: format.sampleRate * Double(factor)
              ),
              let wetLowPass = Self.coefficients(
                type: .lowPass,
                frequencyHz: min(parameters.highFrequencyHz * 8, format.sampleRate * 0.45),
                sampleRate: format.sampleRate * Double(factor)
              ) else { return nil }

        self.plan = plan
        self.selectedChannels = selectedChannels
        self.sourceHighPass = sourceHighPass
        self.sourceLowPass = sourceLowPass
        self.wetHighPass = wetHighPass
        self.wetLowPass = wetLowPass
        drive = pow(10, parameters.driveDB / 20)
        evenNormalization = max(1e-12, pow(tanh(drive), 2))
        oddNormalization = max(1e-12, pow(tanh(drive), 3))
        harmonics = parameters.harmonics
        wetGain = parameters.amount * parameters.mix
        outputGain = pow(10, parameters.outputTrimDB / 20)
        dcAlpha = exp(-2 * Double.pi * 5 / (format.sampleRate * Double(factor)))
        states = selectedChannels.map { allocatesWetState in
            ChannelState(
                plan: plan,
                allocatesWetState: allocatesWetState,
                sourceHighPass: sourceHighPass,
                sourceLowPass: sourceLowPass,
                wetHighPass: wetHighPass,
                wetLowPass: wetLowPass
            )
        }
    }

    private init(copyingConfiguration source: DSPVirtualBassKernel) {
        plan = source.plan
        selectedChannels = source.selectedChannels
        sourceHighPass = source.sourceHighPass
        sourceLowPass = source.sourceLowPass
        wetHighPass = source.wetHighPass
        wetLowPass = source.wetLowPass
        drive = source.drive
        evenNormalization = source.evenNormalization
        oddNormalization = source.oddNormalization
        harmonics = source.harmonics
        wetGain = source.wetGain
        outputGain = source.outputGain
        dcAlpha = source.dcAlpha
        states = source.selectedChannels.map { allocatesWetState in
            ChannelState(
                plan: source.plan,
                allocatesWetState: allocatesWetState,
                sourceHighPass: source.sourceHighPass,
                sourceLowPass: source.sourceLowPass,
                wetHighPass: source.wetHighPass,
                wetLowPass: source.wetLowPass
            )
        }
    }

    func makeFreshState() -> DSPVirtualBassKernel {
        DSPVirtualBassKernel(copyingConfiguration: self)
    }

    mutating func copyState(from source: DSPVirtualBassKernel) {
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
            if selectedChannels[channel] {
                let highPassed = states[channel].sourceHighPass.process(dry)
                let bassBand = states[channel].sourceLowPass.process(highPassed)
                states[channel].bassInput.push(bassBand)
                var wetOutput = 0.0
                for phase in 0..<plan.factor {
                    let bassHigh = plan.interpolate(phase: phase, history: states[channel].bassInput)
                    let driven = bassHigh * drive
                    let shaped = tanh(driven)
                    let even = shaped * shaped / evenNormalization
                    let odd = shaped * shaped * shaped / oddNormalization
                    var generated = even * (1 - harmonics) + odd * harmonics
                    let dcBlocked = generated - states[channel].dcInput + dcAlpha * states[channel].dcOutput
                    states[channel].dcInput = generated
                    states[channel].dcOutput = dcBlocked
                    // This high-pass attenuates the configured source bass band;
                    // it does not claim exact cancellation of every fundamental.
                    generated = states[channel].wetHighPass.process(dcBlocked)
                    generated = states[channel].wetLowPass.process(generated)
                    states[channel].reconstruction.push(generated)
                    if phase == 0 {
                        wetOutput = plan.decimate(history: states[channel].reconstruction)
                    }
                }
                frame[channel] = (delayedDry + wetOutput * wetGain) * outputGain
            } else {
                frame[channel] = delayedDry
            }
        }
    }

    private static func coefficients(
        type: DSPFilterType,
        frequencyHz: Double,
        sampleRate: Double
    ) -> DSPBiquadCoefficients? {
        DSPParametricEQMath.coefficients(
            for: DSPParametricEQBand(
                enabled: true,
                type: type,
                frequencyHz: frequencyHz,
                q: 0.7071067811865476
            ),
            sampleRate: sampleRate
        )
    }
}

nonisolated struct DSPTubeKernel {
    private struct ChannelState {
        var wetInput: DSPMirroredFIRHistory
        var reconstruction: DSPMirroredFIRHistory
        var dryDelay = DSPFixedDelay64()
        var dcInput = 0.0
        var dcOutput = 0.0

        init(plan: DSPPolyphaseFIRPlan, allocatesWetState: Bool) {
            // Front-pair/full-range routing can leave many channels untouched;
            // avoid allocating FIR storage for those channels.
            wetInput = DSPMirroredFIRHistory(
                capacity: allocatesWetState ? plan.historyCount : 1
            )
            reconstruction = DSPMirroredFIRHistory(
                capacity: allocatesWetState ? plan.tapCount : 1
            )
        }

        mutating func copyState(from source: ChannelState) {
            wetInput.copyState(from: source.wetInput)
            reconstruction.copyState(from: source.reconstruction)
            dryDelay.copyState(from: source.dryDelay)
            dcInput = source.dcInput
            dcOutput = source.dcOutput
        }

        mutating func reset() {
            wetInput.reset()
            reconstruction.reset()
            dryDelay.reset()
            dcInput = 0
            dcOutput = 0
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
    private var states: [ChannelState]

    init?(
        format: DSPAudioFormat,
        selectedChannels: [Bool],
        parameters: DSPTubeParameters,
        factor: Int
    ) {
        guard selectedChannels.count == format.channelCount,
              let plan = DSPPolyphaseFIRPlan(factor: factor) else { return nil }
        self.plan = plan
        self.selectedChannels = selectedChannels
        drive = pow(10, parameters.driveDB / 20)
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
        states = selectedChannels.map { allocatesWetState in
            ChannelState(plan: plan, allocatesWetState: allocatesWetState)
        }
    }

    private init(copyingConfiguration source: DSPTubeKernel) {
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
        states = source.selectedChannels.map { allocatesWetState in
            ChannelState(plan: source.plan, allocatesWetState: allocatesWetState)
        }
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
            if selectedChannels[channel] {
                states[channel].wetInput.push(dry)
                var wetOutput = 0.0
                for phase in 0..<plan.factor {
                    let wetHigh = plan.interpolate(phase: phase, history: states[channel].wetInput)
                    let driven = wetHigh * inputGain * drive + bias
                    let shaped = (tanh(driven) - biasOutput) / smallSignalNormalization
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
        for index in delay.indices { delay[index] = source.delay[index] }
        for index in 0..<window {
            neededGains[index] = source.neededGains[index]
            envelopes[index] = source.envelopes[index]
            minimumFrames[index] = source.minimumFrames[index]
            minimumGains[index] = source.minimumGains[index]
        }
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

        let offset = delayCursor * channelCount
        for channel in 0..<channelCount {
            let delayed = delay[offset + channel]
            delay[offset + channel] = frame[channel]
            frame[channel] = delayed * gain
        }
        delayCursor = (delayCursor + 1) % latencyFrames
    }
}

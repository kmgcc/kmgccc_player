import Foundation

/// Fully resolved reverb design shared by the reverb node and the spatial
/// audio room synthesis.
nonisolated struct DSPReverbDesign: Equatable, Sendable, CustomStringConvertible {
    enum Topology: Equatable, Sendable {
        /// Diffused feedback delay network with `lineCount` lines.
        case feedbackDelayNetwork(lineCount: Int, minimumDelayMs: Double, maximumDelayMs: Double)
        /// Dattorro's 1997 plate tank.
        case plate
    }

    var topology: Topology
    var lowDecaySeconds: Double
    var midDecaySeconds: Double
    var highDecaySeconds: Double
    var preDelayMs: Double
    var lowCutHz: Double
    /// Treble shelf of the wet output, in decibels above 3 kHz.
    var toneDB: Double
    var width: Double
    /// Deterministic seed for delay choices, so a preset always sounds the same.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    static let lowCornerHz = 250.0
    static let highCornerHz = 4_000.0

    init(parameters: DSPReverbParameters) {
        let mid = parameters.midDecaySeconds
        midDecaySeconds = mid
        lowDecaySeconds = mid * parameters.lowDecayRatio
        highDecaySeconds = mid * parameters.effectiveHighDecayRatio
        preDelayMs = parameters.preDelayMs
        lowCutHz = parameters.lowCutHz
        toneDB = 3 * parameters.tone
        width = parameters.width
        let scale = 0.55 + 0.45 * min(max(parameters.size, 0), 1)
        switch parameters.space {
        case .room: topology = .feedbackDelayNetwork(lineCount: 8, minimumDelayMs: 10 * scale, maximumDelayMs: 45 * scale)
        case .studio: topology = .feedbackDelayNetwork(lineCount: 8, minimumDelayMs: 6 * scale, maximumDelayMs: 28 * scale)
        case .hall: topology = .feedbackDelayNetwork(lineCount: 16, minimumDelayMs: 22 * scale, maximumDelayMs: 140 * scale)
        case .plate: topology = .plate
        }
    }

    init(topology: Topology, lowDecaySeconds: Double, midDecaySeconds: Double, highDecaySeconds: Double,
         preDelayMs: Double, lowCutHz: Double, toneDB: Double = 0, width: Double = 1, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.topology = topology
        self.lowDecaySeconds = lowDecaySeconds
        self.midDecaySeconds = midDecaySeconds
        self.highDecaySeconds = highDecaySeconds
        self.preDelayMs = preDelayMs
        self.lowCutHz = lowCutHz
        self.toneDB = toneDB
        self.width = width
        self.seed = seed
    }

    var description: String {
        "\(topology)|\(lowDecaySeconds)|\(midDecaySeconds)|\(highDecaySeconds)|\(preDelayMs)|\(lowCutHz)|\(toneDB)|\(width)|\(seed)"
    }

    /// Decay time at `frequency` under the three-band absorption model the
    /// network realises with its two first-order shelves. Absorption adds in
    /// nepers, so inverse decay times combine with the shelves' weights.
    func decaySeconds(at frequency: Double) -> Double {
        let f = max(frequency, 1)
        let lowWeight = 1 / (1 + pow(f / Self.lowCornerHz, 2))
        let highWeight = 1 / (1 + pow(Self.highCornerHz / f, 2))
        let midWeight = max(0, 1 - lowWeight - highWeight)
        let inverse = lowWeight / lowDecaySeconds + midWeight / midDecaySeconds + highWeight / highDecaySeconds
        return 1 / max(inverse, 1e-6)
    }
}

/// First-order section in transposed direct form.
nonisolated struct DSPFirstOrderSection: Equatable {
    var b0: Double
    var b1: Double
    var a1: Double
    var z = 0.0

    static let identity = DSPFirstOrderSection(b0: 1, b1: 0, a1: 0)

    /// Bilinear shelf with gain `gain` below `frequency`, unity above it.
    static func lowShelf(gain: Double, frequency: Double, sampleRate: Double) -> DSPFirstOrderSection {
        let k = tan(Double.pi * min(frequency, sampleRate * 0.45) / sampleRate)
        let norm = 1 / (1 + k)
        return DSPFirstOrderSection(b0: (1 + gain * k) * norm, b1: (gain * k - 1) * norm, a1: (k - 1) * norm)
    }

    /// Bilinear shelf with unity gain below `frequency`, `gain` above it.
    static func highShelf(gain: Double, frequency: Double, sampleRate: Double) -> DSPFirstOrderSection {
        let k = tan(Double.pi * min(frequency, sampleRate * 0.45) / sampleRate)
        let norm = 1 / (1 + k)
        return DSPFirstOrderSection(b0: (gain + k) * norm, b1: (k - gain) * norm, a1: (k - 1) * norm)
    }

    @inline(__always)
    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z
        z = b1 * input - a1 * output
        return output
    }
}

/// Small deterministic generator for delay choices (SplitMix64).
nonisolated struct DSPDeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// Diffuser and feedback delay network for the room, studio and hall spaces.
///
/// Four diffusion steps of eight delays each mix with a Hadamard matrix and
/// flip polarities, without feedback allpasses (Signalsmith, ADC 2021). The
/// network uses a Householder feedback matrix and mutually prime delays;
/// every other line is gently modulated. Each line's loss is a mid-band gain
/// with a first-order low shelf and high shelf, which sets the decay time in
/// three bands (Jot & Chaigne 1991).
nonisolated struct DSPFeedbackNetwork {
    private var diffuserBuffer: [Double] = []
    private var diffuserOffsets: [Int] = []
    private var diffuserCapacities: [Int] = []
    private var diffuserCursors: [Int] = []
    private var diffuserFlips: [Double] = []
    private var channels = [Double](repeating: 0, count: 8)

    private var buffer: [Double] = []
    private var offsets: [Int] = []
    private var capacities: [Int] = []
    private var delays: [Int] = []
    private var cursors: [Int] = []
    private var lowShelves: [DSPFirstOrderSection] = []
    private var highShelves: [DSPFirstOrderSection] = []
    private var gains: [Double] = []
    private var outputLeft: [Double] = []
    private var outputRight: [Double] = []
    private var modulationSine: [Double] = []
    private var modulationCosine: [Double] = []
    private var modulationStepCos: [Double] = []
    private var modulationStepSin: [Double] = []
    private var filtered: [Double] = []
    private let modulationDepth: Double
    private let lineCount: Int

    var stateBytes: Int { (diffuserBuffer.count + buffer.count) * 8 }

    init(sampleRate: Double, lineCount: Int, minimumMs: Double, maximumMs: Double, design: DSPReverbDesign) {
        self.lineCount = lineCount
        var random = DSPDeterministicRandom(seed: design.seed)
        // Steps halve in length; each line draws its delay inside its own
        // slice of the step so arrivals spread evenly.
        var stepMs = maximumMs * 0.5
        for _ in 0..<4 {
            let range = stepMs / 1_000 * sampleRate
            for channel in 0..<8 {
                let low = range * Double(channel) / 8
                let high = range * Double(channel + 1) / 8
                let delay = max(1, Int(low + random.unit() * (high - low)))
                diffuserOffsets.append(diffuserBuffer.count)
                diffuserCapacities.append(delay + 1)
                diffuserCursors.append(0)
                diffuserBuffer += repeatElement(0, count: delay + 1)
                diffuserFlips.append(random.next() & 1 == 0 ? 1 : -1)
            }
            stepMs *= 0.5
        }

        modulationDepth = (0.0008 * sampleRate).rounded()
        var used = Set<Int>()
        for line in 0..<lineCount {
            let ms = minimumMs * pow(maximumMs / minimumMs, Double(line) / Double(max(1, lineCount - 1)))
            var delay = max(Int(modulationDepth) + 3, Int((ms / 1_000 * sampleRate).rounded()))
            while !Self.isPrime(delay) || used.contains(delay) { delay += 1 }
            used.insert(delay)
            let capacity = delay + Int(modulationDepth) + 4
            offsets.append(buffer.count)
            capacities.append(capacity)
            delays.append(delay)
            cursors.append(0)
            buffer += repeatElement(0, count: capacity)

            func passGain(_ seconds: Double) -> Double {
                pow(10, -3 * Double(delay) / (sampleRate * max(seconds, 0.05)))
            }
            let mid = passGain(design.midDecaySeconds)
            gains.append(mid)
            lowShelves.append(.lowShelf(gain: passGain(design.lowDecaySeconds) / mid,
                                        frequency: DSPReverbDesign.lowCornerHz, sampleRate: sampleRate))
            highShelves.append(.highShelf(gain: passGain(design.highDecaySeconds) / mid,
                                          frequency: DSPReverbDesign.highCornerHz, sampleRate: sampleRate))
            // Orthogonal sign patterns keep the two outputs uncorrelated.
            let sign = line % 2 == 0 ? 1.0 : -1.0
            let scale = 1 / Double(lineCount).squareRoot()
            outputLeft.append(((line / 2) % 2 == 0 ? 1 : sign) * scale)
            outputRight.append(((line / 2) % 2 == 0 ? sign : 1) * scale)
            let increment = 2 * Double.pi * (0.35 + 0.5 * random.unit()) / sampleRate
            modulationStepCos.append(cos(increment))
            modulationStepSin.append(sin(increment))
            let startPhase = 2 * Double.pi * random.unit()
            modulationSine.append(sin(startPhase))
            modulationCosine.append(cos(startPhase))
        }
        filtered = Array(repeating: 0, count: lineCount)
    }

    func hasSameShape(as other: DSPFeedbackNetwork) -> Bool {
        buffer.count == other.buffer.count && diffuserBuffer.count == other.diffuserBuffer.count
            && delays == other.delays
    }

    mutating func copyState(from source: DSPFeedbackNetwork) {
        guard hasSameShape(as: source) else { return }
        DSPStateCopy.assign(&diffuserBuffer, from: source.diffuserBuffer)
        DSPStateCopy.assign(&diffuserCursors, from: source.diffuserCursors)
        DSPStateCopy.assign(&buffer, from: source.buffer)
        DSPStateCopy.assign(&cursors, from: source.cursors)
        for index in lowShelves.indices {
            lowShelves[index].z = source.lowShelves[index].z
            highShelves[index].z = source.highShelves[index].z
        }
        DSPStateCopy.assign(&modulationSine, from: source.modulationSine)
        DSPStateCopy.assign(&modulationCosine, from: source.modulationCosine)
    }

    mutating func reset() {
        DSPStateCopy.clear(&diffuserBuffer)
        DSPStateCopy.clear(&buffer)
        for index in diffuserCursors.indices { diffuserCursors[index] = 0 }
        for index in cursors.indices { cursors[index] = 0 }
        for index in lowShelves.indices {
            lowShelves[index].z = 0
            highShelves[index].z = 0
        }
    }

    mutating func process(left: Double, right: Double) -> (left: Double, right: Double) {
        // Left feeds the first four diffusion channels, right the rest,
        // with alternating polarity.
        channels[0] = left; channels[1] = -left; channels[2] = left; channels[3] = -left
        channels[4] = right; channels[5] = -right; channels[6] = right; channels[7] = -right
        let hadamardScale = 1 / 8.0.squareRoot()
        for step in 0..<4 {
            for channel in 0..<8 {
                let line = step * 8 + channel
                let cursor = diffuserCursors[line]
                let capacity = diffuserCapacities[line]
                let read = cursor + 1 == capacity ? 0 : cursor + 1
                diffuserBuffer[diffuserOffsets[line] + cursor] = channels[channel]
                channels[channel] = diffuserBuffer[diffuserOffsets[line] + read] * diffuserFlips[line]
                diffuserCursors[line] = read
            }
            Self.hadamard8(&channels, scale: hadamardScale)
        }

        var outLeft = 0.0
        var outRight = 0.0
        var sum = 0.0
        for index in 0..<lineCount {
            let offset = offsets[index]
            let capacity = capacities[index]
            let cursor = cursors[index]
            let value: Double
            if index % 2 == 1, modulationDepth > 0 {
                // One step of the quadrature oscillator: no trigonometry per sample.
                let s = modulationSine[index], c = modulationCosine[index]
                let newSine = s * modulationStepCos[index] + c * modulationStepSin[index]
                modulationCosine[index] = c * modulationStepCos[index] - s * modulationStepSin[index]
                modulationSine[index] = newSine
                var position = Double(cursor) - (Double(delays[index]) + modulationDepth * newSine)
                if position < 0 { position += Double(capacity) }
                let whole = Int(position)
                let fraction = position - Double(whole)
                let next = whole + 1 == capacity ? 0 : whole + 1
                let a = buffer[offset + whole]
                value = a + (buffer[offset + next] - a) * fraction
            } else {
                var read = cursor - delays[index]
                if read < 0 { read += capacity }
                value = buffer[offset + read]
            }
            outLeft += value * outputLeft[index]
            outRight += value * outputRight[index]
            let absorbed = highShelves[index].process(lowShelves[index].process(value)) * gains[index]
            filtered[index] = absorbed
            sum += absorbed
        }
        // Householder feedback x − (2/N)·Σx plus the diffused input; a
        // sixteen-line network takes each diffusion channel twice, inverted
        // the second time.
        let householder = 2 / Double(lineCount) * sum
        for index in 0..<lineCount {
            let input = index < 8 ? channels[index] : -channels[index - 8]
            let cursor = cursors[index]
            buffer[offsets[index] + cursor] = filtered[index] - householder + input
            cursors[index] = cursor + 1 == capacities[index] ? 0 : cursor + 1
        }
        return (outLeft, outRight)
    }

    /// In-place fast Walsh–Hadamard transform of eight values.
    @inline(__always)
    private static func hadamard8(_ x: inout [Double], scale: Double) {
        var span = 1
        while span < 8 {
            var start = 0
            while start < 8 {
                for index in start..<(start + span) {
                    let a = x[index], b = x[index + span]
                    x[index] = a + b
                    x[index + span] = a - b
                }
                start += span * 2
            }
            span *= 2
        }
        for index in 0..<8 { x[index] *= scale }
    }

    private static func isPrime(_ value: Int) -> Bool {
        guard value > 1 else { return false }
        if value % 2 == 0 { return value == 2 }
        var divisor = 3
        while divisor * divisor <= value {
            if value % divisor == 0 { return false }
            divisor += 2
        }
        return true
    }
}

/// Dattorro's plate tank ("Effect Design, Part 1", JAES 1997), with the
/// published delay lengths at 29 761 Hz scaled to the running rate.
nonisolated struct DSPPlateTank {
    private static let referenceRate = 29_761.0

    private struct Delay {
        var buffer: [Double]
        var cursor = 0

        init(length: Int) { buffer = Array(repeating: 0, count: max(1, length)) }

        /// Sample written `offset` frames ago (1 = the last write).
        @inline(__always)
        func tap(_ offset: Int) -> Double {
            var index = cursor - offset
            while index < 0 { index += buffer.count }
            return buffer[index]
        }

        /// Writes `value` and returns the sample one full length old.
        @inline(__always)
        mutating func push(_ value: Double) -> Double {
            let output = buffer[cursor]
            buffer[cursor] = value
            cursor = cursor + 1 == buffer.count ? 0 : cursor + 1
            return output
        }

        mutating func clear() {
            DSPStateCopy.clear(&buffer)
            cursor = 0
        }
    }

    private struct Allpass {
        var delay: Delay
        let gain: Double

        @inline(__always)
        mutating func process(_ input: Double) -> Double {
            let delayed = delay.buffer[delay.cursor]
            let feed = input - gain * delayed
            _ = delay.push(feed)
            return delayed + gain * feed
        }
    }

    private var bandwidthState = 0.0
    private let bandwidth = 0.9995
    private var inputAllpasses: [Allpass]
    // Each tank half: modulated allpass, delay, damping, allpass, delay.
    private var modulated: [Delay]
    private let modulatedLength: [Int]
    private var firstDelays: [Delay]
    private var dampingState = [0.0, 0.0]
    private var decayAllpasses: [Allpass]
    private var secondDelays: [Delay]
    private let decay: Double
    private let damping: Double
    private let excursion: Double
    private var oscillator = (sine: 0.0, cosine: 1.0)
    private let oscillatorStep: (cos: Double, sin: Double)
    private var feedback = (0.0, 0.0)
    private let taps: [Int]

    var stateBytes: Int {
        (inputAllpasses.reduce(0) { $0 + $1.delay.buffer.count }
            + modulated.reduce(0) { $0 + $1.buffer.count } + firstDelays.reduce(0) { $0 + $1.buffer.count }
            + decayAllpasses.reduce(0) { $0 + $1.delay.buffer.count }
            + secondDelays.reduce(0) { $0 + $1.buffer.count }) * 8
    }

    init(sampleRate: Double, design: DSPReverbDesign) {
        let scale = sampleRate / Self.referenceRate
        func length(_ samples: Int) -> Int { max(1, Int((Double(samples) * scale).rounded())) }
        inputAllpasses = [
            Allpass(delay: Delay(length: length(142)), gain: 0.75),
            Allpass(delay: Delay(length: length(107)), gain: 0.75),
            Allpass(delay: Delay(length: length(379)), gain: 0.625),
            Allpass(delay: Delay(length: length(277)), gain: 0.625),
        ]
        excursion = 16 * scale
        modulatedLength = [length(672), length(908)]
        let modulationPadding = Int(excursion.rounded(.up)) + 3
        modulated = modulatedLength.map { Delay(length: $0 + modulationPadding) }
        firstDelays = [Delay(length: length(4_453)), Delay(length: length(4_217))]
        decayAllpasses = [Allpass(delay: Delay(length: length(1_800)), gain: 0.5),
                          Allpass(delay: Delay(length: length(2_656)), gain: 0.5)]
        secondDelays = [Delay(length: length(3_720)), Delay(length: length(3_163))]
        // One trip round the tank crosses both halves and four decay gains.
        let loopSeconds = Double(672 + 4_453 + 1_800 + 3_720 + 908 + 4_217 + 2_656 + 3_163) / Self.referenceRate
        decay = min(0.9999, pow(10, -3 * loopSeconds / (4 * max(design.midDecaySeconds, 0.05))))
        damping = min(0.7, max(0.0005, 0.7 * (1 - design.highDecaySeconds / max(design.midDecaySeconds, 0.05))))
        let increment = 2 * Double.pi / sampleRate
        oscillatorStep = (cos(increment), sin(increment))
        // Output taps (left then right), Dattorro's Table 2.
        taps = [266, 2_974, 1_913, 1_996, 1_990, 187, 1_066, 353, 3_627, 1_228, 2_673, 2_111, 335, 121].map(length)
    }

    mutating func copyState(from source: DSPPlateTank) {
        guard taps == source.taps else { return }
        bandwidthState = source.bandwidthState
        for index in inputAllpasses.indices {
            DSPStateCopy.assign(&inputAllpasses[index].delay.buffer, from: source.inputAllpasses[index].delay.buffer)
            inputAllpasses[index].delay.cursor = source.inputAllpasses[index].delay.cursor
        }
        for half in 0..<2 {
            DSPStateCopy.assign(&modulated[half].buffer, from: source.modulated[half].buffer)
            modulated[half].cursor = source.modulated[half].cursor
            DSPStateCopy.assign(&firstDelays[half].buffer, from: source.firstDelays[half].buffer)
            firstDelays[half].cursor = source.firstDelays[half].cursor
            DSPStateCopy.assign(&decayAllpasses[half].delay.buffer, from: source.decayAllpasses[half].delay.buffer)
            decayAllpasses[half].delay.cursor = source.decayAllpasses[half].delay.cursor
            DSPStateCopy.assign(&secondDelays[half].buffer, from: source.secondDelays[half].buffer)
            secondDelays[half].cursor = source.secondDelays[half].cursor
            dampingState[half] = source.dampingState[half]
        }
        oscillator = source.oscillator
        feedback = source.feedback
    }

    mutating func reset() {
        bandwidthState = 0
        for index in inputAllpasses.indices { inputAllpasses[index].delay.clear() }
        for half in 0..<2 {
            modulated[half].clear()
            firstDelays[half].clear()
            decayAllpasses[half].delay.clear()
            secondDelays[half].clear()
            dampingState[half] = 0
        }
        oscillator = (0, 1)
        feedback = (0, 0)
    }

    mutating func process(left: Double, right: Double) -> (left: Double, right: Double) {
        // Mono input, band-limited, then four input diffusers.
        bandwidthState += bandwidth * ((left + right) * 0.5 - bandwidthState)
        var x = bandwidthState
        for index in inputAllpasses.indices { x = inputAllpasses[index].process(x) }

        let sine = oscillator.sine * oscillatorStep.cos + oscillator.cosine * oscillatorStep.sin
        let cosine = oscillator.cosine * oscillatorStep.cos - oscillator.sine * oscillatorStep.sin
        oscillator = (sine, cosine)

        var halfOutputs = (0.0, 0.0)
        for half in 0..<2 {
            // Each half takes the input plus the other half's decayed output.
            let crossFeed = half == 0 ? feedback.1 : feedback.0
            let input = x + crossFeed * decay
            // Modulated decay-diffusion allpass, coefficient −0.70.
            let length = Double(modulatedLength[half]) + excursion * (half == 0 ? sine : cosine)
            let whole = Int(length)
            let fraction = length - Double(whole)
            let a = modulated[half].tap(whole)
            let b = modulated[half].tap(whole + 1)
            let delayed = a + (b - a) * fraction
            let feed = input + 0.7 * delayed
            _ = modulated[half].push(feed)
            let diffused = delayed - 0.7 * feed
            let first = firstDelays[half].push(diffused)
            dampingState[half] += (1 - damping) * (first - dampingState[half])
            let second = decayAllpasses[half].process(dampingState[half] * decay)
            let out = secondDelays[half].push(second)
            if half == 0 { halfOutputs.0 = out } else { halfOutputs.1 = out }
        }
        feedback = halfOutputs

        // Taps 0–6 build the left output, 7–13 the right.
        let left = firstDelays[1].tap(taps[0]) + firstDelays[1].tap(taps[1])
            - decayAllpasses[1].delay.tap(taps[2]) + secondDelays[1].tap(taps[3])
            - firstDelays[0].tap(taps[4]) - decayAllpasses[0].delay.tap(taps[5])
            - secondDelays[0].tap(taps[6])
        let right = firstDelays[0].tap(taps[7]) + firstDelays[0].tap(taps[8])
            - decayAllpasses[0].delay.tap(taps[9]) + secondDelays[0].tap(taps[10])
            - firstDelays[1].tap(taps[11]) - decayAllpasses[1].delay.tap(taps[12])
            - secondDelays[1].tap(taps[13])
        return (left * 0.6, right * 0.6)
    }
}

/// Algorithmic reverb with zero latency: predelay, then the diffused
/// feedback delay network or Dattorro's plate. The wet path is low-cut,
/// shelved by the tone control, widened or narrowed in mid/side, calibrated
/// to the input's pink-noise power and mixed with the dry path on an
/// equal-power law.
nonisolated struct DSPReverbKernel: DSPBlockKernel {
    private let leftChannel: Int
    /// Equal to `leftChannel` for a mono source.
    private let rightChannel: Int
    private let sampleRate: Double
    let design: DSPReverbDesign
    private let dryGain: Double
    private var wetGain: Double

    private var preDelay: [Double]
    private let preDelayLength: Int
    private var preDelayCursor = 0
    private var network: DSPFeedbackNetwork?
    private var plate: DSPPlateTank?
    private var lowCutLeft: DSPBiquad
    private var lowCutRight: DSPBiquad
    private var toneLeft: DSPFirstOrderSection
    private var toneRight: DSPFirstOrderSection

    let stateBytes: Int

    /// - Parameter mix: wet share on an equal-power law; nil renders the
    ///   wet signal alone (room synthesis).
    init?(sampleRate: Double, leftChannel: Int, rightChannel: Int, design: DSPReverbDesign,
          mix: Double?, calibrate: Bool = true) {
        guard sampleRate.isFinite, sampleRate > 0,
              let lowCut = DSPFilterDesign.section(.highPass, frequencyHz: design.lowCutHz, sampleRate: sampleRate)
        else { return nil }
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        self.sampleRate = sampleRate
        self.design = design
        if let mix {
            let m = min(max(mix, 0), 1)
            dryGain = cos(Double.pi / 2 * m)
            wetGain = sin(Double.pi / 2 * m)
        } else {
            dryGain = 0
            wetGain = 1
        }
        preDelayLength = max(0, Int((design.preDelayMs / 1_000 * sampleRate).rounded()))
        preDelay = Array(repeating: 0, count: (preDelayLength + 1) * 2)
        switch design.topology {
        case .feedbackDelayNetwork(let lineCount, let minimumMs, let maximumMs):
            network = DSPFeedbackNetwork(sampleRate: sampleRate, lineCount: lineCount,
                                         minimumMs: minimumMs, maximumMs: maximumMs, design: design)
        case .plate:
            plate = DSPPlateTank(sampleRate: sampleRate, design: design)
        }
        lowCutLeft = DSPBiquad(lowCut)
        lowCutRight = DSPBiquad(lowCut)
        toneLeft = .highShelf(gain: pow(10, design.toneDB / 20), frequency: 3_000, sampleRate: sampleRate)
        toneRight = toneLeft
        stateBytes = preDelay.count * 8 + (network?.stateBytes ?? 0) + (plate?.stateBytes ?? 0)
        if calibrate {
            wetGain *= DSPReverbCalibration.wetGain(sampleRate: sampleRate, design: design)
        }
    }

    func makeFreshState() -> DSPReverbKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPReverbKernel) {
        guard sampleRate == source.sampleRate, preDelay.count == source.preDelay.count else { return }
        DSPStateCopy.assign(&preDelay, from: source.preDelay)
        preDelayCursor = source.preDelayCursor
        if network != nil, let other = source.network { network!.copyState(from: other) }
        if plate != nil, let other = source.plate { plate!.copyState(from: other) }
        lowCutLeft.copyState(from: source.lowCutLeft)
        lowCutRight.copyState(from: source.lowCutRight)
        toneLeft.z = source.toneLeft.z
        toneRight.z = source.toneRight.z
    }

    mutating func reset() {
        DSPStateCopy.clear(&preDelay)
        preDelayCursor = 0
        network?.reset()
        plate?.reset()
        lowCutLeft.reset()
        lowCutRight.reset()
        toneLeft.z = 0
        toneRight.z = 0
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        guard frames > 0 else { return }
        let stereo = leftChannel != rightChannel
        let width = design.width
        // Moving the engines out keeps their storage uniquely owned.
        var network = network
        self.network = nil
        var plate = plate
        self.plate = nil
        defer {
            self.network = network
            self.plate = plate
        }
        for frame in 0..<frames {
            let base = frame * channels
            let dryLeft = samples[base + leftChannel]
            let dryRight = stereo ? samples[base + rightChannel] : dryLeft

            var inLeft = dryLeft
            var inRight = dryRight
            if preDelayLength > 0 {
                let capacity = preDelayLength + 1
                let read = preDelayCursor + 1 == capacity ? 0 : preDelayCursor + 1
                preDelay[preDelayCursor * 2] = dryLeft
                preDelay[preDelayCursor * 2 + 1] = dryRight
                inLeft = preDelay[read * 2]
                inRight = preDelay[read * 2 + 1]
                preDelayCursor = read
            }

            let wet: (left: Double, right: Double)
            if network != nil {
                wet = network!.process(left: inLeft, right: inRight)
            } else if plate != nil {
                wet = plate!.process(left: inLeft, right: inRight)
            } else {
                wet = (0, 0)
            }

            var wetLeft = toneLeft.process(lowCutLeft.process(wet.left))
            var wetRight = toneRight.process(lowCutRight.process(wet.right))
            if width != 1 {
                let mid = (wetLeft + wetRight) * 0.5
                let side = (wetLeft - wetRight) * 0.5 * width
                wetLeft = mid + side
                wetRight = mid - side
            }
            if stereo {
                samples[base + leftChannel] = dryLeft * dryGain + wetLeft * wetGain
                samples[base + rightChannel] = dryRight * dryGain + wetRight * wetGain
            } else {
                samples[base + leftChannel] = dryLeft * dryGain + (wetLeft + wetRight) * 0.5 * wetGain
            }
        }
    }

    /// Static headroom: the calibrated wet path matches the input's power,
    /// so the equal-power sum adds at most this much to a correlated peak.
    static func staticPeakResponseDB(mix: Double) -> Double {
        let m = min(max(mix, 0), 1)
        return 20 * log10(cos(Double.pi / 2 * m) + sin(Double.pi / 2 * m))
    }
}

/// Wet gains that bring a reverb design to the input's pink-noise power,
/// measured once per design and sample rate.
nonisolated enum DSPReverbCalibration {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Double] = [:]

    static func wetGain(sampleRate: Double, design: DSPReverbDesign) -> Double {
        let key = "\(sampleRate)|\(design)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        let gain = measure(sampleRate: sampleRate, design: design)
        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = gain
        lock.unlock()
        return gain
    }

    /// The power gain for pink noise is the energy of the wet impulse
    /// response shaped by a pink filter, over that filter's own energy
    /// (Paul Kellet's three-pole pink filter provides the shape).
    private static func measure(sampleRate: Double, design: DSPReverbDesign) -> Double {
        guard var kernel = DSPReverbKernel(sampleRate: sampleRate, leftChannel: 0, rightChannel: 1,
                                           design: design, mix: nil, calibrate: false) else { return 1 }
        let length = Int(min(6, max(design.lowDecaySeconds, design.midDecaySeconds) * 1.2) * sampleRate)
        var wetEnergy = 0.0
        var referenceEnergy = 0.0
        var pinkLeft = (0.0, 0.0, 0.0)
        var pinkRight = (0.0, 0.0, 0.0)
        var pinkReference = (0.0, 0.0, 0.0)
        let block = 1_024
        var buffer = [Double](repeating: 0, count: block * 2)
        var produced = 0
        while produced < length {
            DSPStateCopy.clear(&buffer)
            if produced == 0 {
                buffer[0] = 1
                buffer[1] = 1
            }
            buffer.withUnsafeMutableBufferPointer { pointer in
                kernel.process(pointer.baseAddress!, frames: block, channels: 2)
            }
            for frame in 0..<block {
                // Mean power of the two ears; their tails are uncorrelated,
                // so each ear's level is what a listener hears.
                let left = pink(buffer[frame * 2], &pinkLeft)
                let right = pink(buffer[frame * 2 + 1], &pinkRight)
                wetEnergy += (left * left + right * right) * 0.5
                let shapedReference = pink(produced + frame == 0 ? 1 : 0, &pinkReference)
                referenceEnergy += shapedReference * shapedReference
            }
            produced += block
        }
        guard wetEnergy > 1e-12 else { return 1 }
        return (referenceEnergy / wetEnergy).squareRoot()
    }

    /// Kellet's economy pink filter, within ±0.5 dB above 10 Hz.
    private static func pink(_ white: Double, _ state: inout (Double, Double, Double)) -> Double {
        state.0 = 0.99765 * state.0 + white * 0.0990460
        state.1 = 0.96300 * state.1 + white * 0.2965164
        state.2 = 0.57000 * state.2 + white * 1.0526913
        return state.0 + state.1 + state.2 + white * 0.1848
    }
}

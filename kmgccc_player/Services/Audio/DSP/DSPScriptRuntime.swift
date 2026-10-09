import Foundation

/// Fixed-memory interpreter for one format-bound immutable script program.
/// All mutable DSP state belongs to this value; previews must use a fresh or
/// element-wise copied runtime so their state never aliases the live runtime.
nonisolated struct DSPScriptRuntime {
    private static let faultFadeFrames = 64

    let program: DSPScriptProgram
    let channelMask: [Bool]
    private let channelMaskMatchesFormat: Bool
    private let channelToStateIndex: [Int]
    private let selectedChannelCount: Int

    private var registers: [Double]
    private let parameterValuesByIndex: [Double]
    private var stateValues: [Double]
    private var delayCursors: [Int]
    private var rawFrame: [Double]
    private var candidateFrame: [Double]
    private var dryLatency: [Double]
    private var lastOutput: [Double]
    private var faultFadeStart: [Double]
    private var latencyCursor = 0
    private var faultFadePosition = 0
    private var currentOutputLine: Int?
    private var currentOutputColumn: Int?

    private(set) var diagnostic: DSPDiagnostic?
    private(set) var isFaulted = false

    init(program: DSPScriptProgram, channelMask: [Bool]) {
        self.program = program
        self.channelMask = channelMask
        let channels = max(0, program.format.channelCount)
        let validMask = channelMask.count == channels
        channelMaskMatchesFormat = validMask
        var map = [Int](repeating: -1, count: channels)
        var selectedCount = 0
        if validMask {
            for channel in 0..<channels where channelMask[channel] {
                map[channel] = selectedCount
                selectedCount += 1
            }
        }
        channelToStateIndex = map
        selectedChannelCount = selectedCount
        registers = [Double](repeating: 0, count: max(0, program.registerCount))
        parameterValuesByIndex = program.parameters.map { program.parameterValues[$0.name] ?? 0 }
        stateValues = [Double](repeating: 0, count: max(0, program.stateStride * selectedCount))
        delayCursors = [Int](repeating: 0, count: max(0, program.delaySlotCount * selectedCount))
        rawFrame = [Double](repeating: 0, count: channels)
        candidateFrame = [Double](repeating: 0, count: channels)
        let latencySamples = max(0, program.latencyFrames * channels)
        dryLatency = [Double](repeating: 0, count: latencySamples)
        lastOutput = [Double](repeating: 0, count: channels)
        faultFadeStart = [Double](repeating: 0, count: channels)

        if !validMask {
            diagnostic = DSPDiagnostic(
                code: "dsp.script.channelMaskMismatch",
                message: "The script channel mask does not match its compiled audio format.",
                fieldPath: "channelMask"
            )
            isFaulted = true
        } else {
            initializeState()
        }
    }

    /// Process one interleaved source frame. `true` entries in `channelMask`
    /// run script bytecode; all other entries carry only declared latency.
    mutating func processFrame(_ frame: inout [Double]) {
        let channelCount = program.format.channelCount
        guard frame.count == channelCount, channelCount > 0 else {
            latchFault(
                code: "dsp.script.frameFormatMismatch",
                message: "The runtime frame does not match the compiled audio format.",
                line: nil,
                column: nil
            )
            return
        }

        var hadInvalidInput = false
        for channel in 0..<channelCount {
            let sample = frame[channel]
            if sample.isFinite {
                rawFrame[channel] = sample
                candidateFrame[channel] = sample
            } else {
                rawFrame[channel] = 0
                candidateFrame[channel] = 0
                hadInvalidInput = true
            }
        }
        if hadInvalidInput {
            latchFault(
                code: "dsp.script.nonFiniteInput",
                message: "The script received a non-finite input sample.",
                line: nil,
                column: nil
            )
        }

        if !isFaulted, channelMaskMatchesFormat {
            for channel in 0..<channelCount where channelMask[channel] {
                guard runProgram(channel: channel) else { break }
                let result = currentScriptOutput
                guard result.isFinite, abs(result) <= Double(Float.greatestFiniteMagnitude) else {
                    latchFault(
                        code: "dsp.script.outputNotRepresentable",
                        message: "The script output cannot be represented as finite Float32 audio.",
                        line: currentOutputLine,
                        column: currentOutputColumn
                    )
                    break
                }
                candidateFrame[channel] = result
            }
        }

        let latency = program.latencyFrames
        let slotBase = latency > 0 ? latencyCursor * channelCount : 0
        for channel in 0..<channelCount {
            let alignedDry: Double
            if latency > 0 {
                let offset = slotBase + channel
                alignedDry = dryLatency[offset]
                dryLatency[offset] = rawFrame[channel]
            } else {
                alignedDry = rawFrame[channel]
            }

            let output: Double
            if isFaulted, channelMask.indices.contains(channel), channelMask[channel] {
                if faultFadePosition < Self.faultFadeFrames {
                    let phase = Double(faultFadePosition + 1) / Double(Self.faultFadeFrames)
                    let weight = 0.5 - 0.5 * cos(Double.pi * phase)
                    output = faultFadeStart[channel] + (alignedDry - faultFadeStart[channel]) * weight
                } else {
                    output = alignedDry
                }
            } else if isFaulted {
                output = alignedDry
            } else if channelMask.indices.contains(channel), channelMask[channel] {
                // The declaration reports delay already produced by the
                // algorithm; it never adds another delay to wet output.
                output = candidateFrame[channel]
            } else {
                output = alignedDry
            }
            frame[channel] = output
            lastOutput[channel] = output
        }
        if latency > 0 {
            latencyCursor += 1
            if latencyCursor == latency { latencyCursor = 0 }
        }
        if isFaulted, faultFadePosition < Self.faultFadeFrames {
            faultFadePosition += 1
        }
    }

    private var currentScriptOutput = 0.0

    private mutating func runProgram(channel: Int) -> Bool {
        let stateChannel = channelToStateIndex[channel]
        guard stateChannel >= 0 else { return true }
        currentScriptOutput = rawFrame[channel]
        var instructionIndex = 0
        while instructionIndex < program.instructions.count {
            let instruction = program.instructions[instructionIndex]
            let nextIndex = instructionIndex + 1
            switch instruction.opcode {
            case let .constant(destination, value):
                registers[destination] = value
            case let .input(destination):
                registers[destination] = rawFrame[channel]
            case let .outputValue(destination):
                registers[destination] = currentScriptOutput
            case let .inputAt(destination, sourceChannel):
                guard sourceChannel >= 0, sourceChannel < rawFrame.count else {
                    latchFault(code: "dsp.script.invalidInputChannel", message: "inputAt addressed a channel outside the source frame.", line: instruction.line, column: instruction.column)
                    return false
                }
                registers[destination] = rawFrame[sourceChannel]
            case let .channel(destination):
                registers[destination] = Double(channel)
            case let .channels(destination):
                registers[destination] = Double(program.format.channelCount)
            case let .sampleRate(destination):
                registers[destination] = program.format.sampleRate
            case let .parameter(destination, index):
                guard parameterValuesByIndex.indices.contains(index) else {
                    latchFault(code: "dsp.script.invalidParameterIndex", message: "The compiled program contains an invalid parameter reference.", line: instruction.line, column: instruction.column)
                    return false
                }
                registers[destination] = parameterValuesByIndex[index]
            case let .loadState(destination, slotIndex):
                guard program.stateSlots.indices.contains(slotIndex) else {
                    latchFault(code: "dsp.script.invalidStateSlot", message: "The compiled program contains an invalid state reference.", line: instruction.line, column: instruction.column)
                    return false
                }
                let slot = program.stateSlots[slotIndex]
                registers[destination] = stateValues[stateChannel * program.stateStride + slot.offset]
            case let .storeState(slotIndex, source):
                guard program.stateSlots.indices.contains(slotIndex) else {
                    latchFault(code: "dsp.script.invalidStateSlot", message: "The compiled program contains an invalid state reference.", line: instruction.line, column: instruction.column)
                    return false
                }
                let slot = program.stateSlots[slotIndex]
                stateValues[stateChannel * program.stateStride + slot.offset] = registers[source]
            case let .unary(destination, operation, source):
                let value = registers[source]
                switch operation {
                case .negate: registers[destination] = -value
                case .logicalNot: registers[destination] = value == 0 ? 1 : 0
                case .absolute: registers[destination] = abs(value)
                case .squareRoot:
                    guard value >= 0 else { latchMathFault(instruction); return false }
                    registers[destination] = sqrt(value)
                case .sine: registers[destination] = sin(value)
                case .cosine: registers[destination] = cos(value)
                case .tangentHyperbolic: registers[destination] = tanh(value)
                case .exponential: registers[destination] = exp(value)
                case .logarithm:
                    guard value > 0 else { latchMathFault(instruction); return false }
                    registers[destination] = log(value)
                case .decibelsToGain: registers[destination] = pow(10, value / 20)
                }
            case let .binary(destination, operation, left, right):
                let lhs = registers[left]
                let rhs = registers[right]
                switch operation {
                case .add: registers[destination] = lhs + rhs
                case .subtract: registers[destination] = lhs - rhs
                case .multiply: registers[destination] = lhs * rhs
                case .divide:
                    guard rhs != 0 else { latchMathFault(instruction); return false }
                    registers[destination] = lhs / rhs
                case .remainder:
                    guard rhs != 0 else { latchMathFault(instruction); return false }
                    registers[destination] = lhs.truncatingRemainder(dividingBy: rhs)
                case .power: registers[destination] = pow(lhs, rhs)
                case .minimum: registers[destination] = min(lhs, rhs)
                case .maximum: registers[destination] = max(lhs, rhs)
                }
            case let .compare(destination, operation, left, right):
                let lhs = registers[left]
                let rhs = registers[right]
                let result: Bool
                switch operation {
                case .lessThan: result = lhs < rhs
                case .lessThanOrEqual: result = lhs <= rhs
                case .greaterThan: result = lhs > rhs
                case .greaterThanOrEqual: result = lhs >= rhs
                case .equal: result = lhs == rhs
                case .notEqual: result = lhs != rhs
                }
                registers[destination] = result ? 1 : 0
            case let .select(destination, condition, whenTrue, whenFalse):
                registers[destination] = registers[condition] != 0 ? registers[whenTrue] : registers[whenFalse]
            case let .copy(destination, source):
                registers[destination] = registers[source]
            case let .jumpIfFalse(condition, target):
                guard target > instructionIndex, target <= program.instructions.count else {
                    latchFault(code: "dsp.script.invalidBranch", message: "The compiled program contains a backward or invalid branch.", line: instruction.line, column: instruction.column)
                    return false
                }
                if registers[condition] == 0 {
                    instructionIndex = target
                    continue
                }
            case let .jump(target):
                guard target > instructionIndex, target <= program.instructions.count else {
                    latchFault(code: "dsp.script.invalidBranch", message: "The compiled program contains a backward or invalid branch.", line: instruction.line, column: instruction.column)
                    return false
                }
                instructionIndex = target
                continue
            case let .mix(destination, dry, wet, amount):
                let dryValue = registers[dry]
                registers[destination] = dryValue + (registers[wet] - dryValue) * registers[amount]
            case let .biquad(destination, input, coefficients, slotIndex):
                guard coefficients.count == 5, program.stateSlots.indices.contains(slotIndex) else {
                    latchFault(code: "dsp.script.invalidBiquad", message: "The compiled program contains invalid biquad data.", line: instruction.line, column: instruction.column)
                    return false
                }
                let slot = program.stateSlots[slotIndex]
                let base = stateChannel * program.stateStride + slot.offset
                let x = registers[input]
                let y = coefficients[0] * x + stateValues[base]
                let nextZ1 = coefficients[1] * x - coefficients[3] * y + stateValues[base + 1]
                let nextZ2 = coefficients[2] * x - coefficients[4] * y
                stateValues[base] = nextZ1
                stateValues[base + 1] = nextZ2
                registers[destination] = y
            case let .delay(destination, input, slotIndex):
                guard program.stateSlots.indices.contains(slotIndex) else {
                    latchFault(code: "dsp.script.invalidDelay", message: "The compiled program contains an invalid delay state.", line: instruction.line, column: instruction.column)
                    return false
                }
                let slot = program.stateSlots[slotIndex]
                guard let ordinal = slot.delayOrdinal, slot.length > 0 else {
                    latchFault(code: "dsp.script.invalidDelay", message: "The compiled program contains an invalid delay layout.", line: instruction.line, column: instruction.column)
                    return false
                }
                let cursorIndex = stateChannel * program.delaySlotCount + ordinal
                let sampleIndex = stateChannel * program.stateStride + slot.offset + delayCursors[cursorIndex]
                registers[destination] = stateValues[sampleIndex]
                stateValues[sampleIndex] = registers[input]
                delayCursors[cursorIndex] += 1
                if delayCursors[cursorIndex] == slot.length { delayCursors[cursorIndex] = 0 }
            case let .smooth(destination, input, coefficientRegister, slotIndex):
                guard program.stateSlots.indices.contains(slotIndex) else {
                    latchFault(code: "dsp.script.invalidSmooth", message: "The compiled program contains an invalid smoothing state.", line: instruction.line, column: instruction.column)
                    return false
                }
                let slot = program.stateSlots[slotIndex]
                let stateIndex = stateChannel * program.stateStride + slot.offset
                let coefficient = registers[coefficientRegister]
                let result = coefficient * registers[input] + (1 - coefficient) * stateValues[stateIndex]
                stateValues[stateIndex] = result
                registers[destination] = result
            case let .output(source):
                currentScriptOutput = registers[source]
                currentOutputLine = instruction.line
                currentOutputColumn = instruction.column
            }

            if case let .constant(destination, _) = instruction.opcode {
                guard registers[destination].isFinite else { latchMathFault(instruction); return false }
            } else if let destination = destinationRegister(instruction.opcode), !registers[destination].isFinite {
                latchMathFault(instruction)
                return false
            }
            if !currentScriptOutput.isFinite {
                latchMathFault(instruction)
                return false
            }
            instructionIndex = nextIndex
        }
        return true
    }

    private mutating func latchMathFault(_ instruction: DSPScriptInstruction) {
        latchFault(
            code: "dsp.script.mathFault",
            message: "The script produced an invalid mathematical result.",
            line: instruction.line,
            column: instruction.column
        )
    }

    private mutating func latchFault(code: String, message: String, line: Int?, column: Int?) {
        guard !isFaulted else { return }
        diagnostic = DSPDiagnostic(
            code: code,
            message: message,
            fieldPath: "process",
            line: line,
            column: column
        )
        isFaulted = true
        faultFadePosition = 0
        for index in faultFadeStart.indices { faultFadeStart[index] = lastOutput[index] }
    }

    private func destinationRegister(_ opcode: DSPScriptOpcode) -> Int? {
        switch opcode {
        case let .constant(destination, _), let .input(destination), let .outputValue(destination),
             let .inputAt(destination, _), let .channel(destination), let .channels(destination),
             let .sampleRate(destination), let .parameter(destination, _), let .loadState(destination, _),
             let .unary(destination, _, _), let .binary(destination, _, _, _),
             let .compare(destination, _, _, _), let .select(destination, _, _, _),
             let .copy(destination, _), let .mix(destination, _, _, _),
             let .biquad(destination, _, _, _), let .delay(destination, _, _),
             let .smooth(destination, _, _, _): return destination
        case .storeState, .jumpIfFalse, .jump, .output: return nil
        }
    }

    private mutating func initializeState() {
        for channelIndex in 0..<selectedChannelCount {
            let base = channelIndex * program.stateStride
            for index in 0..<min(program.stateStride, program.stateInitializerValues.count) {
                stateValues[base + index] = program.stateInitializerValues[index]
            }
        }
    }

    mutating func reset() {
        for index in registers.indices { registers[index] = 0 }
        for index in stateValues.indices { stateValues[index] = 0 }
        for index in delayCursors.indices { delayCursors[index] = 0 }
        for index in rawFrame.indices { rawFrame[index] = 0 }
        for index in candidateFrame.indices { candidateFrame[index] = 0 }
        for index in dryLatency.indices { dryLatency[index] = 0 }
        for index in lastOutput.indices { lastOutput[index] = 0 }
        for index in faultFadeStart.indices { faultFadeStart[index] = 0 }
        latencyCursor = 0
        faultFadePosition = 0
        currentScriptOutput = 0
        currentOutputLine = nil
        currentOutputColumn = nil
        diagnostic = nil
        isFaulted = false
        if channelMaskMatchesFormat {
            initializeState()
        } else {
            latchFault(
                code: "dsp.script.channelMaskMismatch",
                message: "The script channel mask does not match its compiled audio format.",
                line: nil,
                column: nil
            )
        }
    }

    func makeFreshState() -> DSPScriptRuntime {
        DSPScriptRuntime(program: program, channelMask: channelMask)
    }

    mutating func copyState(from source: DSPScriptRuntime) {
        guard stateCopyMatches(source) else {
            latchFault(
                code: "dsp.script.stateCopyMismatch",
                message: "Runtime state can only be copied between matching script programs and channel masks.",
                line: nil,
                column: nil
            )
            return
        }
        copyElements(source.registers, to: &registers)
        copyElements(source.stateValues, to: &stateValues)
        copyElements(source.delayCursors, to: &delayCursors)
        copyElements(source.rawFrame, to: &rawFrame)
        copyElements(source.candidateFrame, to: &candidateFrame)
        copyElements(source.dryLatency, to: &dryLatency)
        copyElements(source.lastOutput, to: &lastOutput)
        copyElements(source.faultFadeStart, to: &faultFadeStart)
        latencyCursor = source.latencyCursor
        faultFadePosition = source.faultFadePosition
        currentScriptOutput = source.currentScriptOutput
        currentOutputLine = source.currentOutputLine
        currentOutputColumn = source.currentOutputColumn
        diagnostic = source.diagnostic
        isFaulted = source.isFaulted
    }

    /// Copies only state that the next `previewFrames` frames can read. Scalar,
    /// biquad and smooth state is always copied; delay and declared-latency
    /// rings copy only their upcoming read window unless the preview wraps the
    /// entire ring. Both runtimes keep independent storage.
    mutating func copyState(from source: DSPScriptRuntime, previewFrames: Int) {
        guard stateCopyMatches(source), previewFrames >= 0 else {
            latchFault(
                code: "dsp.script.stateCopyMismatch",
                message: "Preview state can only be copied from a matching script runtime with a nonnegative frame count.",
                line: nil,
                column: nil
            )
            return
        }
        copyElements(source.registers, to: &registers)
        copyElements(source.delayCursors, to: &delayCursors)
        copyElements(source.rawFrame, to: &rawFrame)
        copyElements(source.candidateFrame, to: &candidateFrame)
        copyElements(source.lastOutput, to: &lastOutput)
        copyElements(source.faultFadeStart, to: &faultFadeStart)
        latencyCursor = source.latencyCursor
        faultFadePosition = source.faultFadePosition
        currentScriptOutput = source.currentScriptOutput
        currentOutputLine = source.currentOutputLine
        currentOutputColumn = source.currentOutputColumn
        diagnostic = source.diagnostic
        isFaulted = source.isFaulted

        // Fill scalar slots and ring cells that this bounded preview can read.
        // Uncopied delay-ring windows are never addressed during this preview.
        let channels = program.format.channelCount
        for channel in 0..<channels {
            let stateChannel = channelToStateIndex[channel]
            guard stateChannel >= 0 else { continue }
            for slot in program.stateSlots {
                let targetBase = stateChannel * program.stateStride + slot.offset
                let sourceBase = stateChannel * source.program.stateStride + slot.offset
                if case .delay = slot.kind {
                    let frameCount = min(previewFrames, slot.length)
                    guard frameCount > 0, slot.length > 0,
                          let ordinal = slot.delayOrdinal else { continue }
                    let cursorIndex = stateChannel * program.delaySlotCount + ordinal
                    let cursor = source.delayCursors[cursorIndex]
                    for step in 0..<frameCount {
                        let ringOffset = (cursor + step) % slot.length
                        stateValues[targetBase + ringOffset] = source.stateValues[sourceBase + ringOffset]
                    }
                } else {
                    for offset in 0..<slot.length {
                        stateValues[targetBase + offset] = source.stateValues[sourceBase + offset]
                    }
                }
            }
        }

        let latency = program.latencyFrames
        if latency > 0, previewFrames > 0 {
            let frameCount = min(previewFrames, latency)
            let channelsToCopy = program.format.channelCount
            for step in 0..<frameCount {
                let ringFrame = (source.latencyCursor + step) % latency
                let offset = ringFrame * channelsToCopy
                for channel in 0..<channelsToCopy {
                    dryLatency[offset + channel] = source.dryLatency[offset + channel]
                }
            }
        }
    }

    private func stateCopyMatches(_ source: DSPScriptRuntime) -> Bool {
        program.sourceHash == source.program.sourceHash
            && program.languageVersion == source.program.languageVersion
            && program.parameterValues == source.program.parameterValues
            && program.format.sampleRate.bitPattern == source.program.format.sampleRate.bitPattern
            && program.format.channelCount == source.program.format.channelCount
            && program.format.rawLayoutData == source.program.format.rawLayoutData
            && program.format.channelLabels == source.program.format.channelLabels
            && program.format.layoutIsKnown == source.program.format.layoutIsKnown
            && program.latencyFrames == source.program.latencyFrames
            && channelMask == source.channelMask
            && program.stateStride == source.program.stateStride
            && program.stateSlots.count == source.program.stateSlots.count
    }

    private func copyElements<T>(_ source: [T], to destination: inout [T]) {
        guard source.count == destination.count else { return }
        for index in source.indices { destination[index] = source[index] }
    }
}

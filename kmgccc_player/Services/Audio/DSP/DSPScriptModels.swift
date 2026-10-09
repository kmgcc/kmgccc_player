import Foundation

nonisolated struct DSPScriptParameter: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let minValue: Double
    let maxValue: Double
    let defaultValue: Double

    var id: String { name }
}

nonisolated enum DSPScriptUnaryOperation: Sendable {
    case negate
    case logicalNot
    case absolute
    case squareRoot
    case sine
    case cosine
    case tangentHyperbolic
    case exponential
    case logarithm
    case decibelsToGain
}

nonisolated enum DSPScriptBinaryOperation: Sendable {
    case add
    case subtract
    case multiply
    case divide
    case remainder
    case power
    case minimum
    case maximum
}

nonisolated enum DSPScriptComparisonOperation: Sendable {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case equal
    case notEqual
}

nonisolated enum DSPScriptStateKind: Sendable {
    case variable
    case biquad
    case delay
    case smooth
}

nonisolated struct DSPScriptStateSlot: Sendable {
    let name: String?
    let kind: DSPScriptStateKind
    let offset: Int
    let length: Int
    let initialValue: Double
    let delayOrdinal: Int?
}

nonisolated enum DSPScriptOpcode: Sendable {
    case constant(destination: Int, value: Double)
    case input(destination: Int)
    case outputValue(destination: Int)
    case inputAt(destination: Int, channel: Int)
    case channel(destination: Int)
    case channels(destination: Int)
    case sampleRate(destination: Int)
    case parameter(destination: Int, index: Int)
    case loadState(destination: Int, slot: Int)
    case storeState(slot: Int, source: Int)
    case unary(destination: Int, operation: DSPScriptUnaryOperation, source: Int)
    case binary(
        destination: Int,
        operation: DSPScriptBinaryOperation,
        left: Int,
        right: Int
    )
    case compare(
        destination: Int,
        operation: DSPScriptComparisonOperation,
        left: Int,
        right: Int
    )
    case select(destination: Int, condition: Int, whenTrue: Int, whenFalse: Int)
    case copy(destination: Int, source: Int)
    case jumpIfFalse(condition: Int, target: Int)
    case jump(target: Int)
    case mix(destination: Int, dry: Int, wet: Int, amount: Int)
    case biquad(
        destination: Int,
        input: Int,
        coefficients: [Double],
        stateSlot: Int
    )
    case delay(destination: Int, input: Int, stateSlot: Int)
    case smooth(destination: Int, input: Int, coefficient: Int, stateSlot: Int)
    case output(source: Int)
}

nonisolated struct DSPScriptInstruction: Sendable {
    let opcode: DSPScriptOpcode
    let line: Int
    let column: Int
    let weight: Int
}

/// Immutable, format-bound compiler output. State layout and bytecode are kept
/// internal; reflected fields are stable for the editor and control APIs.
nonisolated struct DSPScriptProgram: Sendable {
    let sourceHash: String
    let languageVersion: Int
    let parameters: [DSPScriptParameter]
    let parameterValues: [String: Double]
    let format: DSPAudioFormat
    let latencyFrames: Int
    let stateBytes: Int
    /// Weighted VM operations for one selected channel and one source frame.
    let weightedOperationsPerFrame: Int

    let registerCount: Int
    let stateStride: Int
    let delaySlotCount: Int
    let stateSlots: [DSPScriptStateSlot]
    let instructions: [DSPScriptInstruction]
    let stateInitializerValues: [Double]
}

nonisolated struct DSPScriptCompilationError: Error, Sendable, LocalizedError {
    let diagnostics: [DSPDiagnostic]

    var errorDescription: String? {
        diagnostics.first?.message ?? "The DSP script could not be compiled."
    }
}

nonisolated enum DSPScriptFixture: Sendable {
    case silence(durationSeconds: Double)
    case impulse(durationSeconds: Double, amplitude: Double)
    case sine(durationSeconds: Double, frequencyHz: Double, amplitude: Double)
    case sweep(
        durationSeconds: Double,
        startFrequencyHz: Double,
        endFrequencyHz: Double,
        amplitude: Double
    )
    case pinkNoise(durationSeconds: Double, amplitude: Double, seed: UInt64)
    case custom(CanonicalPCM)

    var name: String {
        switch self {
        case .silence: return "silence"
        case .impulse: return "impulse"
        case .sine: return "sine"
        case .sweep: return "sweep"
        case .pinkNoise: return "pinkNoise"
        case .custom: return "customPCM"
        }
    }
}

nonisolated struct DSPScriptResponsePoint: Sendable {
    let frequencyHz: Double
    let gainDB: Double
}

nonisolated struct DSPScriptFixtureResult: Sendable {
    let fixtureName: String
    let frames: Int
    let inputPeak: Double
    let outputPeak: Double
    let inputRMS: Double
    let outputRMS: Double
    let nonFiniteOutputSampleCount: Int
    let scriptFaulted: Bool
    let diagnostics: [DSPDiagnostic]
    let responsePoints: [DSPScriptResponsePoint]
    let estimatedWeightedOperations: UInt64
    let estimatedProcessingMilliseconds: Double
    let elapsedMilliseconds: Double
    let latencyFrames: Int
    let measuredImpulsePeakFrame: Int?
    let expectedLatencyFrames: Int?
}

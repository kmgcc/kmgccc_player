import Foundation

nonisolated struct DSPScriptFixtureError: Error, Sendable, LocalizedError {
    let diagnostics: [DSPDiagnostic]

    var errorDescription: String? {
        diagnostics.first?.message ?? "The DSP script fixture could not be run."
    }
}

/// Runs deterministic, bounded audio inputs through the same fixed-memory VM
/// used by playback. Timings are diagnostic estimates only, never CPU claims.
nonisolated enum DSPScriptFixtureRunner {
    private static let maximumDurationSeconds = 2.0
    private static let cancellationCheckInterval = 256
    private static let maximumTailFrames = 67_584

    static func run(
        program: DSPScriptProgram,
        channelMask: [Bool],
        fixtures: [DSPScriptFixture]
    ) async throws -> [DSPScriptFixtureResult] {
        guard channelMask.count == program.format.channelCount else {
            throw failure("script.fixtureChannelMaskMismatch", "The fixture channel mask must match the compiled format.")
        }
        var results = [DSPScriptFixtureResult]()
        results.reserveCapacity(fixtures.count)
        for fixture in fixtures {
            try Task.checkCancellation()
            results.append(try await runOne(fixture, program: program, channelMask: channelMask))
        }
        return results
    }

    private static func runOne(
        _ fixture: DSPScriptFixture,
        program: DSPScriptProgram,
        channelMask: [Bool]
    ) async throws -> DSPScriptFixtureResult {
        let sampleRate = program.format.sampleRate
        let channels = program.format.channelCount
        guard sampleRate.isFinite, sampleRate > 0, channels > 0 else {
            throw failure("script.fixtureInvalidFormat", "The compiled audio format is not supported by the fixture runner.")
        }

        let sourceFrames: Int
        var generator = FixtureInputGenerator(fixture: fixture, format: program.format)
        switch fixture {
        case let .custom(pcm):
            guard pcm.channelCount == channels,
                  pcm.sampleRate.bitPattern == sampleRate.bitPattern,
                  pcm.frames >= 0,
                  pcm.frames <= Int(sampleRate * maximumDurationSeconds),
                  pcm.data.count == pcm.frames * channels else {
                throw failure("script.fixtureCustomFormatMismatch", "Custom PCM must match the compiled format and stay within the two-second frame limit.")
            }
            sourceFrames = pcm.frames
        case .silence, .impulse, .sine, .sweep, .pinkNoise:
            guard let duration = fixture.durationSeconds,
                  duration.isFinite, duration > 0, duration <= maximumDurationSeconds,
                  duration * sampleRate <= Double(Int.max) else {
                throw failure("script.fixtureDurationOutOfRange", "Fixture duration must be greater than zero and no longer than two seconds.")
            }
            sourceFrames = max(1, Int((duration * sampleRate).rounded(.up)))
            try validateParameters(fixture, sampleRate: sampleRate)
        }

        let intentionalDelay = program.stateSlots.reduce(0) { maximum, slot in
            if case .delay = slot.kind { return max(maximum, slot.length) }
            return maximum
        }
        let tailFrames = min(program.latencyFrames + intentionalDelay, maximumTailFrames)
        let totalFrames = sourceFrames + tailFrames
        var runtime = DSPScriptRuntime(program: program, channelMask: channelMask)
        var frame = [Double](repeating: 0, count: channels)
        var inputSquares = StableSquareSum()
        var outputSquares = StableSquareSum()
        var selectedInputSquares = StableSquareSum()
        var selectedOutputSquares = StableSquareSum()
        var inputPeak = 0.0
        var outputPeak = 0.0
        var nonFiniteOutputSampleCount = 0
        var measuredImpulsePeak = 0.0
        var measuredImpulsePeakFrame: Int?
        let expectedLatency = program.latencyFrames
        let selectedCount = channelMask.reduce(0) { $0 + ($1 ? 1 : 0) }
        let start = ContinuousClock.now

        for frameIndex in 0..<totalFrames {
            if frameIndex < sourceFrames {
                for channel in 0..<channels {
                    let sample = generator.sample(frame: frameIndex, channel: channel, custom: fixture.customPCM)
                    frame[channel] = sample
                    inputSquares.add(sample)
                    if channelMask[channel] { selectedInputSquares.add(sample) }
                    if sample.isFinite { inputPeak = max(inputPeak, abs(sample)) }
                }
            } else {
                for channel in 0..<channels { frame[channel] = 0 }
            }

            runtime.processFrame(&frame)
            for channel in 0..<channels {
                let output = frame[channel]
                if !output.isFinite || abs(output) > Double(Float.greatestFiniteMagnitude) {
                    nonFiniteOutputSampleCount += 1
                    frame[channel] = 0
                    continue
                }
                let floatOutput = Float(output)
                guard floatOutput.isFinite else {
                    nonFiniteOutputSampleCount += 1
                    frame[channel] = 0
                    continue
                }
                let finiteOutput = Double(floatOutput)
                outputSquares.add(finiteOutput)
                if channelMask[channel] { selectedOutputSquares.add(finiteOutput) }
                let magnitude = abs(finiteOutput)
                if magnitude > outputPeak {
                    outputPeak = magnitude
                    if case .impulse = fixture, magnitude > measuredImpulsePeak {
                        measuredImpulsePeak = magnitude
                        measuredImpulsePeakFrame = frameIndex
                    }
                }
            }

            if frameIndex % cancellationCheckInterval == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        let elapsed = start.duration(to: .now)
        let elapsedMilliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        let weightedFrames = Double(program.weightedOperationsPerFrame)
            * Double(selectedCount) * Double(totalFrames)
        let boundedWeighted = min(max(0, weightedFrames), Double(UInt64.max))
        let estimatedOperations = boundedWeighted >= Double(UInt64.max)
            ? UInt64.max
            : UInt64(boundedWeighted.rounded(.down))
        let estimatedMilliseconds = weightedFrames / DSPScriptCompiler.maximumWeightedOperationsPerSecond * 1_000
        let inputRMS = inputSquares.rms(dividingBy: max(1, sourceFrames * channels))
        let outputRMS = outputSquares.rms(dividingBy: max(1, sourceFrames * channels))
        let selectedInputRMS = selectedInputSquares.rms(dividingBy: max(1, sourceFrames * selectedCount))
        let selectedOutputRMS = selectedOutputSquares.rms(dividingBy: max(1, sourceFrames * selectedCount))
        var responsePoints = [DSPScriptResponsePoint]()
        if case let .sine(_, frequency, _) = fixture,
           selectedInputRMS > 0, selectedOutputRMS.isFinite {
            let ratio = selectedOutputRMS / selectedInputRMS
            if ratio.isFinite, ratio > 0 {
                responsePoints.append(DSPScriptResponsePoint(
                    frequencyHz: frequency,
                    gainDB: 20 * log10(ratio)
                ))
            }
        }
        let diagnostics = runtime.diagnostic.map { [$0] } ?? []
        return DSPScriptFixtureResult(
            fixtureName: fixture.name,
            frames: sourceFrames,
            inputPeak: inputPeak,
            outputPeak: outputPeak,
            inputRMS: inputRMS,
            outputRMS: outputRMS,
            nonFiniteOutputSampleCount: nonFiniteOutputSampleCount,
            scriptFaulted: runtime.isFaulted,
            diagnostics: diagnostics,
            responsePoints: responsePoints,
            estimatedWeightedOperations: estimatedOperations,
            estimatedProcessingMilliseconds: estimatedMilliseconds.isFinite ? estimatedMilliseconds : 0,
            elapsedMilliseconds: elapsedMilliseconds.isFinite ? elapsedMilliseconds : 0,
            latencyFrames: program.latencyFrames,
            measuredImpulsePeakFrame: measuredImpulsePeakFrame,
            expectedLatencyFrames: fixture.isImpulse ? expectedLatency : nil
        )
    }

    private static func validateParameters(_ fixture: DSPScriptFixture, sampleRate: Double) throws {
        func amplitudeIsValid(_ amplitude: Double) -> Bool {
            amplitude.isFinite && abs(amplitude) <= 1
        }
        switch fixture {
        case .silence:
            return
        case let .impulse(_, amplitude):
            guard amplitudeIsValid(amplitude) else { throw failure("script.fixtureAmplitudeOutOfRange", "Fixture amplitude must be finite and within -1...1.") }
        case let .sine(_, frequency, amplitude):
            guard frequency.isFinite, frequency > 0, frequency < sampleRate / 2,
                  amplitudeIsValid(amplitude) else {
                throw failure("script.fixtureToneOutOfRange", "A sine fixture requires a frequency below Nyquist and amplitude within -1...1.")
            }
        case let .sweep(_, start, end, amplitude):
            guard start.isFinite, end.isFinite, start > 0, end > 0,
                  start < sampleRate / 2, end < sampleRate / 2,
                  amplitudeIsValid(amplitude) else {
                throw failure("script.fixtureSweepOutOfRange", "A sweep requires positive frequencies below Nyquist and amplitude within -1...1.")
            }
        case let .pinkNoise(_, amplitude, _):
            guard amplitudeIsValid(amplitude) else { throw failure("script.fixtureAmplitudeOutOfRange", "Fixture amplitude must be finite and within -1...1.") }
        case .custom:
            return
        }
    }

    private static func failure(_ code: String, _ message: String) -> DSPScriptFixtureError {
        DSPScriptFixtureError(diagnostics: [DSPDiagnostic(code: code, message: message, fieldPath: "fixture")])
    }
}

nonisolated private extension DSPScriptFixture {
    var durationSeconds: Double? {
        switch self {
        case let .silence(duration), let .impulse(duration, _), let .sine(duration, _, _),
             let .sweep(duration, _, _, _), let .pinkNoise(duration, _, _): return duration
        case .custom: return nil
        }
    }

    var customPCM: CanonicalPCM? {
        if case let .custom(pcm) = self { return pcm }
        return nil
    }

    var isImpulse: Bool {
        if case .impulse = self { return true }
        return false
    }
}

nonisolated private struct StableSquareSum {
    private(set) var scale = 0.0
    private(set) var scaledSum = 0.0

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        let magnitude = abs(value)
        guard magnitude > 0 else { return }
        if scale < magnitude {
            let ratio = scale / magnitude
            scaledSum = 1 + scaledSum * ratio * ratio
            scale = magnitude
        } else {
            let ratio = magnitude / scale
            scaledSum += ratio * ratio
        }
    }

    func rms(dividingBy divisor: Int) -> Double {
        guard divisor > 0, scale > 0, scaledSum.isFinite else { return 0 }
        let value = scale * sqrt(scaledSum / Double(divisor))
        return value.isFinite ? value : 0
    }
}

nonisolated private struct FixtureInputGenerator {
    let fixture: DSPScriptFixture
    let format: DSPAudioFormat
    private var pinkStates: [PinkNoiseState]

    init(fixture: DSPScriptFixture, format: DSPAudioFormat) {
        self.fixture = fixture
        self.format = format
        if case let .pinkNoise(_, _, seed) = fixture {
            pinkStates = (0..<max(0, format.channelCount)).map { PinkNoiseState(seed: seed &+ UInt64($0) &* 0x9E3779B97F4A7C15) }
        } else {
            pinkStates = []
        }
    }

    mutating func sample(frame: Int, channel: Int, custom: CanonicalPCM?) -> Double {
        switch fixture {
        case .silence:
            return 0
        case let .impulse(_, amplitude):
            return frame == 0 ? amplitude : 0
        case let .sine(_, frequency, amplitude):
            return sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate) * amplitude
        case let .sweep(duration, startFrequency, endFrequency, amplitude):
            let time = Double(frame) / format.sampleRate
            let slope = (endFrequency - startFrequency) / duration
            return sin(2 * Double.pi * (startFrequency * time + 0.5 * slope * time * time)) * amplitude
        case let .pinkNoise(_, amplitude, _):
            guard pinkStates.indices.contains(channel) else { return 0 }
            return pinkStates[channel].next() * amplitude
        case .custom:
            guard let custom,
                  frame >= 0, frame < custom.frames,
                  custom.data.indices.contains(frame * custom.channelCount + channel) else { return 0 }
            return Double(custom.data[frame * custom.channelCount + channel])
        }
    }
}

nonisolated private struct PinkNoiseState {
    private var random: UInt64
    private var b0 = 0.0
    private var b1 = 0.0
    private var b2 = 0.0
    private var b3 = 0.0
    private var b4 = 0.0
    private var b5 = 0.0
    private var b6 = 0.0

    init(seed: UInt64) { random = seed == 0 ? 1 : seed }

    mutating func next() -> Double {
        random = random &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        let white = Double(random >> 11) / 9_007_199_254_740_992 * 2 - 1
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
        b6 = white * 0.115926
        return pink
    }
}

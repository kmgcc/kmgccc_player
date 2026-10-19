import Foundation

/// Spatial audio: the left and right channels convolved with binaural room
/// responses, either synthesized for two virtual loudspeakers or imported.
/// Responses carry their own level calibration; a slow loudness match
/// absorbs what remains programme-dependent.
nonisolated struct DSPSpatialAudioKernel: DSPBlockKernel {
    enum PreparationError: Error, Equatable {
        case missingImpulseResponse
        case unusableResponse
    }

    private let leftChannel: Int
    private let rightChannel: Int
    private var engine: DSPConvolutionEngine?
    private let dryGain: Double
    private let wetGain: Double
    private let outputGain: Double
    private var dryDelay: [Double]
    private var dryCursor = 0
    private let channelMask: [Bool]
    private var loudness: DSPLoudnessMatch?
    /// Synthesized speaker distance, after fitting inside the room.
    let effectiveDistance: Double?

    let latencyFrames: Int

    var stateBytes: Int { (engine?.stateBytes ?? 0) + (engine?.spectra.byteCount ?? 0) + dryDelay.count * 8 }

    static func prepare(format: DSPAudioFormat, leftChannel: Int, rightChannel: Int,
                        parameters: DSPSpatialAudioParameters) -> Result<DSPSpatialAudioKernel, PreparationError> {
        let sampleRate = format.sampleRate
        let paths: [[Double]]
        let routes: [DSPConvolutionEngine.Route]
        var distance: Double?
        var directDelayFrames = 0
        switch parameters.source {
        case .room:
            guard let synthesized = DSPRoomSynthesis.responses(parameters: parameters, sampleRate: sampleRate) else {
                return .failure(.unusableResponse)
            }
            paths = synthesized.paths
            distance = synthesized.distance
            directDelayFrames = synthesized.directDelayFrames
            routes = trueStereoRoutes
        case .impulseResponse:
            guard !parameters.impulseResponseID.isEmpty,
                  let channels = DSPImpulseResponseStore.responses(id: parameters.impulseResponseID,
                                                                  sampleRate: sampleRate) else {
                return .failure(.missingImpulseResponse)
            }
            switch channels.count {
            case 1:
                paths = normalized([channels[0]], ears: [[0], [0]])
                routes = [.init(input: 0, output: 0, path: 0), .init(input: 1, output: 1, path: 0)]
            case 2:
                paths = normalized(channels, ears: [[0], [1]])
                routes = [.init(input: 0, output: 0, path: 0), .init(input: 1, output: 1, path: 1)]
            case 4:
                // True stereo order: L→L, L→R, R→L, R→R.
                paths = normalized(channels, ears: [[0, 2], [1, 3]])
                routes = trueStereoRoutes
            default:
                return .failure(.unusableResponse)
            }
        }
        guard let spectra = DSPConvolutionSpectra(responses: paths),
              let engine = DSPConvolutionEngine(spectra: spectra, routes: routes, inputCount: 2, outputCount: 2)
        else { return .failure(.unusableResponse) }
        return .success(DSPSpatialAudioKernel(format: format, leftChannel: leftChannel, rightChannel: rightChannel,
                                              engine: engine, parameters: parameters, distance: distance,
                                              directDelayFrames: directDelayFrames))
    }

    private static let trueStereoRoutes: [DSPConvolutionEngine.Route] = [
        .init(input: 0, output: 0, path: 0), .init(input: 0, output: 1, path: 1),
        .init(input: 1, output: 0, path: 2), .init(input: 1, output: 1, path: 3),
    ]

    /// Scales responses so each ear's pink-noise power equals one input
    /// channel's for uncorrelated inputs; `ears` lists the paths into each ear.
    private static func normalized(_ paths: [[Double]], ears: [[Int]]) -> [[Double]] {
        let reference = DSPRoomSynthesis.pinkEnergy([1])
        let energies = paths.map(DSPRoomSynthesis.pinkEnergy)
        let earEnergy = ears.map { $0.reduce(0) { $0 + energies[$1] } }
        let average = earEnergy.reduce(0, +) / Double(max(1, earEnergy.count))
        guard average > 0 else { return paths }
        let gain = (reference / average).squareRoot()
        return paths.map { $0.map { $0 * gain } }
    }

    init(format: DSPAudioFormat, leftChannel: Int, rightChannel: Int, engine: DSPConvolutionEngine,
         parameters: DSPSpatialAudioParameters, distance: Double?, directDelayFrames: Int) {
        self.leftChannel = leftChannel
        self.rightChannel = rightChannel
        self.engine = engine
        latencyFrames = engine.latencyFrames + directDelayFrames
        let mix = min(max(parameters.mix, 0), 1)
        if parameters.source == .room {
            // The two paths are correlated. A linear blend keeps an identical
            // centre signal at unity instead of adding 3 dB at the midpoint.
            dryGain = 1 - mix
            wetGain = mix
        } else {
            dryGain = cos(Double.pi / 2 * mix)
            wetGain = sin(Double.pi / 2 * mix)
        }
        outputGain = pow(10, parameters.outputTrimDB / 20)
        dryDelay = Array(repeating: 0, count: latencyFrames * 2)
        var mask = Array(repeating: false, count: format.channelCount)
        mask[leftChannel] = true
        mask[rightChannel] = true
        channelMask = mask
        loudness = parameters.loudnessMatchEnabled
            ? DSPLoudnessMatch(sampleRate: format.sampleRate, channelCount: format.channelCount) : nil
        effectiveDistance = distance
    }

    func makeFreshState() -> DSPSpatialAudioKernel {
        var fresh = self
        // The engine is a reference: a fresh state needs its own.
        fresh.engine = engine?.makeFresh()
        fresh.dryDelay = Array(repeating: 0, count: dryDelay.count)
        fresh.dryCursor = 0
        fresh.loudness?.reset()
        return fresh
    }

    mutating func copyState(from source: DSPSpatialAudioKernel) {
        if let engine, let other = source.engine, engine !== other { engine.copyState(from: other) }
        if dryDelay.count == source.dryDelay.count {
            DSPStateCopy.assign(&dryDelay, from: source.dryDelay)
            dryCursor = source.dryCursor
        }
        if let other = source.loudness { loudness?.copyState(from: other) }
    }

    mutating func reset() {
        engine?.reset()
        DSPStateCopy.clear(&dryDelay)
        dryCursor = 0
        loudness?.reset()
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        guard let engine, frames > 0, channels == channelMask.count else { return }
        loudness?.measureInput(UnsafePointer(samples), frames: frames, channels: channels, mask: channelMask)
        let delayFrames = dryDelay.count / 2
        for frame in 0..<frames {
            let base = frame * channels
            let left = samples[base + leftChannel]
            let right = samples[base + rightChannel]
            let wet = engine.processStereo(left, right)
            // Align the common direct arrival as well as the convolution block;
            // the HRTF keeps its relative timing between the ears.
            let slot = dryCursor * 2
            let dryLeft = dryDelay[slot]
            let dryRight = dryDelay[slot + 1]
            dryDelay[slot] = left
            dryDelay[slot + 1] = right
            dryCursor = dryCursor + 1 == delayFrames ? 0 : dryCursor + 1
            samples[base + leftChannel] = dryLeft * dryGain + wet.left * wetGain
            samples[base + rightChannel] = dryRight * dryGain + wet.right * wetGain
        }
        // The trim is the listener's own level: applied after the match.
        loudness?.applyToOutput(samples, frames: frames, channels: channels, mask: channelMask)
        if outputGain != 1 {
            for frame in 0..<frames {
                samples[frame * channels + leftChannel] *= outputGain
                samples[frame * channels + rightChannel] *= outputGain
            }
        }
    }
}

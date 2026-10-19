import Foundation

/// A native effect that processes whole interleaved blocks in place.
nonisolated protocol DSPBlockKernel {
    /// Algorithmic delay the processor compensates.
    var latencyFrames: Int { get }
    /// Mutable state size; large states are not snapshotted every block.
    var stateBytes: Int { get }
    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int)
    mutating func copyState(from source: Self)
    mutating func reset()
    func makeFreshState() -> Self
    /// Gain applied upstream of the node; level-referenced kernels cancel it.
    mutating func setProgramLevelOffset(dB: Double)
}

nonisolated extension DSPBlockKernel {
    var latencyFrames: Int { 0 }
    mutating func setProgramLevelOffset(dB: Double) {}
}

/// Value-typed home for every block kernel inside a runtime node. Each
/// mutation moves the kernel out first, so its storage stays uniquely owned
/// and processing never triggers a copy.
nonisolated enum DSPEffectKernel {
    case classicBass(DSPClassicBassKernel)
    case hybridBass(DSPHybridBassKernel)
    case stereoWidth(DSPStereoWidthKernel)
    case crossfeed(DSPCrossfeedKernel)
    case spatial(DSPSpatialAudioKernel)
    case reverb(DSPReverbKernel)
    case compressor(DSPCompressorKernel)
    case empty

    var latencyFrames: Int {
        switch self {
        case .classicBass(let kernel): kernel.latencyFrames
        case .hybridBass(let kernel): kernel.latencyFrames
        case .stereoWidth(let kernel): kernel.latencyFrames
        case .crossfeed(let kernel): kernel.latencyFrames
        case .spatial(let kernel): kernel.latencyFrames
        case .reverb(let kernel): kernel.latencyFrames
        case .compressor(let kernel): kernel.latencyFrames
        case .empty: 0
        }
    }

    /// Kernels whose state lives in a reference: a copied runtime node would
    /// share it, so the processor never snapshots those active engines.
    var keepsReferenceState: Bool {
        switch self {
        case .spatial: true
        case .hybridBass(let kernel): kernel.keepsReferenceState
        default: false
        }
    }

    var stateBytes: Int {
        switch self {
        case .classicBass(let kernel): kernel.stateBytes
        case .hybridBass(let kernel): kernel.stateBytes
        case .stereoWidth(let kernel): kernel.stateBytes
        case .crossfeed(let kernel): kernel.stateBytes
        case .spatial(let kernel): kernel.stateBytes
        case .reverb(let kernel): kernel.stateBytes
        case .compressor(let kernel): kernel.stateBytes
        case .empty: 0
        }
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        switch self {
        case .classicBass(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .classicBass(kernel)
        case .hybridBass(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .hybridBass(kernel)
        case .stereoWidth(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .stereoWidth(kernel)
        case .crossfeed(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .crossfeed(kernel)
        case .spatial(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .spatial(kernel)
        case .reverb(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .reverb(kernel)
        case .compressor(var kernel):
            self = .empty
            kernel.process(samples, frames: frames, channels: channels)
            self = .compressor(kernel)
        case .empty:
            break
        }
    }

    /// Copies state between kernels of the same kind and shape; anything
    /// else keeps its own (fresh) state.
    mutating func copyState(from source: DSPEffectKernel) {
        switch (self, source) {
        case (.classicBass(var kernel), .classicBass(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .classicBass(kernel)
        case (.hybridBass(var kernel), .hybridBass(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .hybridBass(kernel)
        case (.stereoWidth(var kernel), .stereoWidth(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .stereoWidth(kernel)
        case (.crossfeed(var kernel), .crossfeed(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .crossfeed(kernel)
        case (.spatial(var kernel), .spatial(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .spatial(kernel)
        case (.reverb(var kernel), .reverb(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .reverb(kernel)
        case (.compressor(var kernel), .compressor(let other)):
            self = .empty
            kernel.copyState(from: other)
            self = .compressor(kernel)
        default:
            break
        }
    }

    mutating func reset() {
        switch self {
        case .classicBass(var kernel): self = .empty; kernel.reset(); self = .classicBass(kernel)
        case .hybridBass(var kernel): self = .empty; kernel.reset(); self = .hybridBass(kernel)
        case .stereoWidth(var kernel): self = .empty; kernel.reset(); self = .stereoWidth(kernel)
        case .crossfeed(var kernel): self = .empty; kernel.reset(); self = .crossfeed(kernel)
        case .spatial(var kernel): self = .empty; kernel.reset(); self = .spatial(kernel)
        case .reverb(var kernel): self = .empty; kernel.reset(); self = .reverb(kernel)
        case .compressor(var kernel): self = .empty; kernel.reset(); self = .compressor(kernel)
        case .empty: break
        }
    }

    func makeFreshState() -> DSPEffectKernel {
        switch self {
        case .classicBass(let kernel): .classicBass(kernel.makeFreshState())
        case .hybridBass(let kernel): .hybridBass(kernel.makeFreshState())
        case .stereoWidth(let kernel): .stereoWidth(kernel.makeFreshState())
        case .crossfeed(let kernel): .crossfeed(kernel.makeFreshState())
        case .spatial(let kernel): .spatial(kernel.makeFreshState())
        case .reverb(let kernel): .reverb(kernel.makeFreshState())
        case .compressor(let kernel): .compressor(kernel.makeFreshState())
        case .empty: .empty
        }
    }

    mutating func setProgramLevelOffset(dB: Double) {
        switch self {
        case .classicBass(var kernel): self = .empty; kernel.setProgramLevelOffset(dB: dB); self = .classicBass(kernel)
        case .hybridBass(var kernel): self = .empty; kernel.setProgramLevelOffset(dB: dB); self = .hybridBass(kernel)
        case .compressor(var kernel): self = .empty; kernel.setProgramLevelOffset(dB: dB); self = .compressor(kernel)
        default: break
        }
    }

    /// Gain-reduction readings of the last processed block, four values per
    /// 1024-frame chunk, for kernels that meter.
    var meterBlocks: [Float]? {
        if case .compressor(let kernel) = self { return kernel.meterBlocks }
        return nil
    }
}

/// Second-order sections designed once per kernel, shared by every channel.
nonisolated enum DSPFilterDesign {
    static let butterworthQ = 0.7071067811865476
    /// Section Qs of a fourth-order Butterworth response.
    static let fourthOrderQs = [0.5411961001461970, 1.3065629648763766]
    /// Section Qs of an eighth-order Butterworth response.
    static let eighthOrderQs = [0.5097955791041592, 0.6013448869350453, 0.8999762231364156, 2.5629154477415055]

    static func section(_ type: DSPFilterType, frequencyHz: Double, sampleRate: Double,
                        q: Double = butterworthQ, gainDB: Double = 0) -> DSPBiquadCoefficients? {
        let nyquistSafe = min(frequencyHz, sampleRate * 0.45)
        return DSPParametricEQMath.coefficients(
            for: DSPParametricEQBand(enabled: true, type: type, frequencyHz: max(1, nyquistSafe),
                                     gainDB: gainDB, q: q),
            sampleRate: sampleRate
        )
    }

    /// Second-order allpass with the phase of a fourth-order
    /// Linkwitz–Riley crossover at `frequencyHz` (LP4 + HP4 summed).
    static func linkwitzRileyAllpass(frequencyHz: Double, sampleRate: Double) -> DSPBiquadCoefficients? {
        let omega = 2 * Double.pi * min(frequencyHz, sampleRate * 0.45) / sampleRate
        let alpha = sin(omega) / (2 * butterworthQ)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        let coefficients = DSPBiquadCoefficients(
            b0: (1 - alpha) / a0, b1: -2 * cosine / a0, b2: 1,
            a1: -2 * cosine / a0, a2: (1 - alpha) / a0
        )
        return coefficients.isStable ? coefficients : nil
    }
}

/// Transposed direct form II section with its state, for tight inner loops.
nonisolated struct DSPBiquad {
    var coefficients: DSPBiquadCoefficients
    var z1 = 0.0
    var z2 = 0.0

    init(_ coefficients: DSPBiquadCoefficients) {
        self.coefficients = coefficients
    }

    @inline(__always)
    mutating func process(_ input: Double) -> Double {
        let c = coefficients
        let output = c.b0 * input + z1
        z1 = c.b1 * input - c.a1 * output + z2
        z2 = c.b2 * input - c.a2 * output
        return output
    }

    mutating func copyState(from source: DSPBiquad) {
        z1 = source.z1
        z2 = source.z2
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// Compress only the added bass as it approaches the output's available
/// peak space. The original signal is not multiplied by a gain envelope.
/// Below the knee the result is exactly the unprotected enhancement; the
/// knee has continuous slope and adds no lookahead or release pumping.
nonisolated enum DSPBassPeakControl {
    @inline(__always)
    static func mix(original: Double, enhanced: Double, ceiling: Double?) -> Double {
        guard let ceiling else { return enhanced }
        let added = enhanced - original
        let direction = added < 0 ? -1.0 : 1.0
        let available = max(0, ceiling - direction * original)
        let knee = available * 0.75
        let amount = abs(added)
        guard amount > knee else { return enhanced }
        let span = available - knee
        guard span > 0 else { return original }
        return original + direction * (knee + span * tanh((amount - knee) / span))
    }
}

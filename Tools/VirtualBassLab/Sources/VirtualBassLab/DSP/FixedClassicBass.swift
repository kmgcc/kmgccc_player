import Foundation

/// 工业级无破音经典虚拟低音 (Waves MaxxBass & Philips 架构)
public struct FixedClassicBass: Sendable {
    private struct ChannelState: Sendable {
        var preLowPass: FourthOrderButterworth?
        var floorHighPass: DSPBiquad = DSPBiquad()
        var postHighPass: FourthOrderButterworth?
        var postLowPass: DSPBiquad = DSPBiquad()
        var dryHighPass: DSPBiquad = DSPBiquad()
        var dryBassShelf: DSPBiquad = DSPBiquad()

        var dcBlockerPrevInput = 0.0
        var dcBlockerPrevOutput = 0.0

        mutating func reset() {
            preLowPass?.reset()
            floorHighPass.reset()
            postHighPass?.reset()
            postLowPass.reset()
            dryHighPass.reset()
            dryBassShelf.reset()
            dcBlockerPrevInput = 0.0
            dcBlockerPrevOutput = 0.0
        }
    }

    private let wetGain: Double
    private let tightensDryBass: Bool
    private let outputGain: Double
    private let dcAlpha: Double
    private let characterRound: Double
    private let wetSolo: Bool
    private var states: [ChannelState]

    public init?(sampleRate: Double, channels: Int, cutoffHz: Double = 100, floorHz: Double = 35,
                 intensity: Double = 1.0, bassGainDB: Double = 0.0, tightenDryBass: Bool = false,
                 character: Double = 0.7, wetSolo: Bool = false, outputTrimDB: Double = 0.0) {
        guard sampleRate > 0, channels > 0 else { return nil }
        let sourceCutoff = min(cutoffHz, 150.0)

        guard let preLp = FourthOrderButterworth.lowPass(frequency: sourceCutoff, sampleRate: sampleRate),
              let fHp = DSPBiquadCoefficients.highPass(frequency: floorHz, sampleRate: sampleRate),
              let postHp = FourthOrderButterworth.highPass(frequency: sourceCutoff * 0.85, sampleRate: sampleRate),
              let postLp = DSPBiquadCoefficients.lowPass(frequency: 380.0, sampleRate: sampleRate),
              let dhp = DSPBiquadCoefficients.highPass(frequency: cutoffHz * 0.8, sampleRate: sampleRate),
              let shelf = DSPBiquadCoefficients.lowShelf(frequency: cutoffHz, sampleRate: sampleRate, gainDB: bassGainDB) else {
            return nil
        }

        self.wetGain = 0.75 * intensity
        self.tightensDryBass = tightenDryBass
        self.characterRound = max(0.0, min(1.0, character))
        self.wetSolo = wetSolo
        self.outputGain = pow(10, outputTrimDB / 20)
        self.dcAlpha = exp(-2 * Double.pi * 15 / sampleRate)

        var channel = ChannelState()
        channel.preLowPass = preLp
        channel.floorHighPass = DSPBiquad(fHp)
        channel.postHighPass = postHp
        channel.postLowPass = DSPBiquad(postLp)
        channel.dryHighPass = DSPBiquad(dhp)
        channel.dryBassShelf = DSPBiquad(shelf)

        states = Array(repeating: channel, count: channels)
    }

    public mutating func process(channel: Int, sample: Double) -> Double {
        guard channel < states.count else { return sample }

        let bandPre = states[channel].preLowPass?.process(sample) ?? sample
        let band = states[channel].floorHighPass.process(bandPre)

        // 偶次谐波 (Round，温暖厚实)
        let epsilon = 0.005
        let evenHarmonics = sqrt(band * band + epsilon * epsilon) - epsilon

        // 奇次谐波 (Tight，紧凑打击)
        let oddHarmonics = tanh(1.8 * band)

        // 根据 character 调节 Round(2次) 与 Tight(3次) 的比例
        let roundWeight = 0.4 + 0.5 * characterRound // 0.4 ~ 0.9
        let tightWeight = 1.0 - roundWeight
        let rawHarmonics = roundWeight * evenHarmonics + tightWeight * oddHarmonics

        let dcBlocked = rawHarmonics - states[channel].dcBlockerPrevInput + dcAlpha * states[channel].dcBlockerPrevOutput
        states[channel].dcBlockerPrevInput = rawHarmonics
        states[channel].dcBlockerPrevOutput = dcBlocked

        let postHp = states[channel].postHighPass?.process(dcBlocked) ?? dcBlocked
        let wet = states[channel].postLowPass.process(postHp)

        if wetSolo {
            return Self.safeCeiling(wet * wetGain * 1.5) * outputGain
        }

        var dry = sample
        if tightensDryBass {
            dry = states[channel].dryHighPass.process(dry)
        }
        if states[channel].dryBassShelf.coefficients != .identity {
            dry = states[channel].dryBassShelf.process(dry)
        }

        let dryWeight = tightensDryBass ? 0.70 : max(0.55, 1.0 - 0.20 * (wetGain / 0.75))
        let combined = dryWeight * dry + wetGain * wet

        return Self.safeCeiling(combined) * outputGain
    }

    @inline(__always)
    private static func safeCeiling(_ x: Double, ceiling: Double = 0.98, knee: Double = 0.80) -> Double {
        let absX = abs(x)
        guard absX > knee else { return x }
        let span = ceiling - knee
        let delta = absX - knee
        let compressed = knee + span * tanh(delta / span)
        return x < 0 ? -compressed : compressed
    }
}

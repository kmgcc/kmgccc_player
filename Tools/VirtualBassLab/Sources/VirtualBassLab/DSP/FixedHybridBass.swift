import Foundation

/// 工业级效果拔群混合虚拟低音 (具备独立的“动态/瞬态 Transient”打击雕琢与稳态倍频发生器)
public struct FixedHybridBass: Sendable {
    private struct ChannelState: Sendable {
        var preLowPass: FourthOrderButterworth?
        var floorHighPass: DSPBiquad = DSPBiquad()
        var postHighPass: FourthOrderButterworth?
        var postLowPass: DSPBiquad = DSPBiquad()
        var dryHighPass: DSPBiquad = DSPBiquad()
        var dryBassShelf: DSPBiquad = DSPBiquad()

        // 瞬态/稳态双包络检测
        var fastEnvelope = 0.0
        var slowEnvelope = 0.0

        // 直流隔离状态
        var dcBlockerPrevInput = 0.0
        var dcBlockerPrevOutput = 0.0

        mutating func reset() {
            preLowPass?.reset()
            floorHighPass.reset()
            postHighPass?.reset()
            postLowPass.reset()
            dryHighPass.reset()
            dryBassShelf.reset()
            fastEnvelope = 0.0
            slowEnvelope = 0.0
            dcBlockerPrevInput = 0.0
            dcBlockerPrevOutput = 0.0
        }
    }

    private let wetGain: Double
    private let transientGain: Double
    private let tightensDryBass: Bool
    private let characterRound: Double
    private let wetSolo: Bool
    private let outputGain: Double
    private let dcAlpha: Double
    private let fastAttackAlpha: Double
    private let fastReleaseAlpha: Double
    private let slowAttackAlpha: Double
    private let slowReleaseAlpha: Double
    private var states: [ChannelState]

    public init?(sampleRate: Double, channels: Int, cutoffHz: Double = 100, floorHz: Double = 35,
                 intensity: Double = 1.0, transient: Double = 1.0, bassGainDB: Double = 0.0,
                 tightenDryBass: Bool = false, character: Double = 0.7, wetSolo: Bool = false,
                 outputTrimDB: Double = 0.0) {
        guard sampleRate > 0, channels > 0 else { return nil }
        let sourceCutoff = min(cutoffHz, 150.0)

        guard let preLp = FourthOrderButterworth.lowPass(frequency: sourceCutoff, sampleRate: sampleRate),
              let fHp = DSPBiquadCoefficients.highPass(frequency: floorHz, sampleRate: sampleRate),
              let postHp = FourthOrderButterworth.highPass(frequency: sourceCutoff * 0.85, sampleRate: sampleRate),
              let postLp = DSPBiquadCoefficients.lowPass(frequency: 400.0, sampleRate: sampleRate),
              let dhp = DSPBiquadCoefficients.highPass(frequency: cutoffHz * 0.8, sampleRate: sampleRate),
              let shelf = DSPBiquadCoefficients.lowShelf(frequency: cutoffHz, sampleRate: sampleRate, gainDB: bassGainDB) else {
            return nil
        }

        self.wetGain = 0.85 * intensity
        self.transientGain = max(0.0, transient)
        self.tightensDryBass = tightenDryBass
        self.characterRound = max(0.0, min(1.0, character))
        self.wetSolo = wetSolo
        self.outputGain = pow(10, outputTrimDB / 20)
        self.dcAlpha = exp(-2 * Double.pi * 15 / sampleRate)

        // 快速包络 (捕捉鼓点敲击瞬态): 1.5ms / 20ms
        fastAttackAlpha = 1 - exp(-1 / (0.0015 * sampleRate))
        fastReleaseAlpha = 1 - exp(-1 / (0.020 * sampleRate))

        // 慢速包络 (捕捉稳态延音): 25ms / 150ms
        slowAttackAlpha = 1 - exp(-1 / (0.025 * sampleRate))
        slowReleaseAlpha = 1 - exp(-1 / (0.150 * sampleRate))

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

        // 双包络瞬态/稳态检测
        let absBand = abs(band)
        var fast = states[channel].fastEnvelope
        fast += (absBand > fast ? fastAttackAlpha : fastReleaseAlpha) * (absBand - fast)
        states[channel].fastEnvelope = fast

        var slow = states[channel].slowEnvelope
        slow += (absBand > slow ? slowAttackAlpha : slowReleaseAlpha) * (absBand - slow)
        states[channel].slowEnvelope = slow

        // 瞬态打击强度：快速包络突增的部分
        let delta = max(0, fast - slow)
        let transientRatio = min(1.0, (delta / (slow + 1e-4)) * 2.0)
        let tonalRatio = max(0.0, 1.0 - transientRatio)

        // 1. 【音调稳态分支】纯净倍频发生器
        let doubler = 2.2 * band * band

        // 2. 【瞬态打击分支】受“动态/瞬态 (Transient)”参数专控的冲击饱和
        // 当 transientGain 拉大时，底鼓瞬间爆发出紧凑清脆的冲击波
        let transientPunch = tanh(3.0 * band) * (fast + 1e-3) * (1.0 + 1.2 * transientGain)

        // 模糊融合加权
        let rawHarmonics = tonalRatio * doubler + transientRatio * transientPunch

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

        let dryWeight = tightensDryBass ? 0.68 : max(0.50, 1.0 - 0.22 * (wetGain / 0.85))
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

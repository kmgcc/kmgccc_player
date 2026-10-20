import Foundation

/// 工业级无破音混合虚拟低音 (4阶 LR 双边滤波 + 光滑无除法 NLD + 动态瞬态打击塑形)
/// 专为底鼓节奏设计：稳态温润饱满，鼓点瞬间爆发紧凑凝聚的冲击感，同时绝无马达颤音与破音
public struct FixedHybridBass: Sendable {
    private struct ChannelState: Sendable {
        var preLp1: DSPBiquad = DSPBiquad()
        var preLp2: DSPBiquad = DSPBiquad()

        // 慢速双包络瞬态/稳态分析器 (不跟随 15Hz 拍频，只检测大动态突发音符)
        var fastEnvelope: Double = 0.0
        var slowEnvelope: Double = 0.0

        var dcPrevInput: Double = 0.0
        var dcPrevOutput: Double = 0.0

        var postHp1: DSPBiquad = DSPBiquad()
        var postHp2: DSPBiquad = DSPBiquad()
        var postLp: DSPBiquad = DSPBiquad()

        var dryHighPass: DSPBiquad = DSPBiquad()
        var dryBassShelf: DSPBiquad = DSPBiquad()

        mutating func reset() {
            preLp1.reset()
            preLp2.reset()
            fastEnvelope = 0.0
            slowEnvelope = 0.0
            dcPrevInput = 0.0
            dcPrevOutput = 0.0
            postHp1.reset()
            postHp2.reset()
            postLp.reset()
            dryHighPass.reset()
            dryBassShelf.reset()
        }
    }

    private var wetGain: Double
    private var transientGain: Double
    private var tightensDryBass: Bool
    private var characterRound: Double
    private var wetSolo: Bool
    private var outputGain: Double
    private var sampleRate: Double
    private var dcAlpha: Double
    private var fastAttackAlpha: Double
    private var fastReleaseAlpha: Double
    private var slowAttackAlpha: Double
    private var slowReleaseAlpha: Double
    private var states: [ChannelState]
    private var currentCutoff: Double
    private var currentBassGainDB: Double

    public init?(sampleRate: Double, channels: Int, cutoffHz: Double = 100, floorHz: Double = 25,
                 intensity: Double = 1.0, transient: Double = 1.0, bassGainDB: Double = 0.0,
                 tightenDryBass: Bool = false, character: Double = 0.7, wetSolo: Bool = false,
                 outputTrimDB: Double = 0.0) {
        guard sampleRate > 0, channels > 0 else { return nil }
        self.sampleRate = sampleRate
        self.currentCutoff = cutoffHz
        self.currentBassGainDB = bassGainDB

        let sourceCutoff = min(cutoffHz, 130.0)
        let postHpFreq = max(55.0, sourceCutoff * 0.85)

        guard let preLpCoeff = DSPBiquadCoefficients.lowPass(frequency: sourceCutoff, sampleRate: sampleRate, q: 0.7071067811865476),
              let postHpCoeff = DSPBiquadCoefficients.highPass(frequency: postHpFreq, sampleRate: sampleRate, q: 0.7071067811865476),
              let postLpCoeff = DSPBiquadCoefficients.lowPass(frequency: 380.0, sampleRate: sampleRate, q: 0.7071067811865476),
              let dhpCoeff = DSPBiquadCoefficients.highPass(frequency: cutoffHz * 0.85, sampleRate: sampleRate, q: 0.7071067811865476),
              let shelfCoeff = DSPBiquadCoefficients.lowShelf(frequency: cutoffHz, sampleRate: sampleRate, gainDB: bassGainDB) else {
            return nil
        }

        self.wetGain = 1.25 * intensity
        self.transientGain = max(0.0, transient)
        self.tightensDryBass = tightenDryBass
        self.characterRound = max(0.0, min(1.0, character))
        self.wetSolo = wetSolo
        self.outputGain = pow(10, outputTrimDB / 20)
        self.dcAlpha = exp(-2.0 * Double.pi * 15.0 / sampleRate)

        // 双包络时间常数：平缓释放，杜绝跟随拍频颤音
        fastAttackAlpha = 1.0 - exp(-1.0 / (0.005 * sampleRate))
        fastReleaseAlpha = 1.0 - exp(-1.0 / (0.080 * sampleRate))
        slowAttackAlpha = 1.0 - exp(-1.0 / (0.040 * sampleRate))
        slowReleaseAlpha = 1.0 - exp(-1.0 / (0.300 * sampleRate))

        var channel = ChannelState()
        channel.preLp1 = DSPBiquad(preLpCoeff)
        channel.preLp2 = DSPBiquad(preLpCoeff)
        channel.postHp1 = DSPBiquad(postHpCoeff)
        channel.postHp2 = DSPBiquad(postHpCoeff)
        channel.postLp = DSPBiquad(postLpCoeff)
        channel.dryHighPass = DSPBiquad(dhpCoeff)
        channel.dryBassShelf = DSPBiquad(shelfCoeff)

        states = Array(repeating: channel, count: channels)
    }

    public mutating func update(params: VirtualBassParams) {
        self.wetGain = 1.25 * params.intensity
        self.transientGain = max(0.0, params.transient)
        self.tightensDryBass = params.tightenDryBass
        self.characterRound = max(0.0, min(1.0, params.character))
        self.wetSolo = params.wetSolo
        self.outputGain = pow(10, params.outputTrimDB / 20)

        if abs(params.cutoffHz - currentCutoff) > 0.5 || abs(params.bassGainDB - currentBassGainDB) > 0.1 {
            currentCutoff = params.cutoffHz
            currentBassGainDB = params.bassGainDB
            let sourceCutoff = min(currentCutoff, 130.0)
            let postHpFreq = max(55.0, sourceCutoff * 0.85)
            if let preLpCoeff = DSPBiquadCoefficients.lowPass(frequency: sourceCutoff, sampleRate: sampleRate, q: 0.7071067811865476),
               let postHpCoeff = DSPBiquadCoefficients.highPass(frequency: postHpFreq, sampleRate: sampleRate, q: 0.7071067811865476),
               let dhpCoeff = DSPBiquadCoefficients.highPass(frequency: currentCutoff * 0.85, sampleRate: sampleRate, q: 0.7071067811865476),
               let shelfCoeff = DSPBiquadCoefficients.lowShelf(frequency: currentCutoff, sampleRate: sampleRate, gainDB: currentBassGainDB) {
                for ch in 0..<states.count {
                    states[ch].preLp1.c = preLpCoeff
                    states[ch].preLp2.c = preLpCoeff
                    states[ch].postHp1.c = postHpCoeff
                    states[ch].postHp2.c = postHpCoeff
                    states[ch].dryHighPass.c = dhpCoeff
                    states[ch].dryBassShelf.c = shelfCoeff
                }
            }
        }
    }

    public mutating func process(channel: Int, sample: Double) -> Double {
        guard channel < states.count else { return sample }

        // 1. 前级 4 阶 LR 低通
        let l1 = states[channel].preLp1.process(sample)
        let band = states[channel].preLp2.process(l1)

        // 2. 宏观瞬态检测 (只检测整体乐句中的底鼓敲击，平缓释放)
        let absBand = abs(band)
        var fast = states[channel].fastEnvelope
        fast += (absBand > fast ? fastAttackAlpha : fastReleaseAlpha) * (absBand - fast)
        states[channel].fastEnvelope = fast

        var slow = states[channel].slowEnvelope
        slow += (absBand > slow ? slowAttackAlpha : slowReleaseAlpha) * (absBand - slow)
        states[channel].slowEnvelope = slow

        let delta = max(0.0, fast - slow)
        let transientRatio = min(1.0, 2.5 * (delta / (slow + 0.010)))

        // 3. 光滑无除法非线性发生器
        let driven = band * 2.2
        let deltaK = 0.08
        let h2 = (sqrt(driven * driven + deltaK * deltaK) - deltaK) * 2.2
        let h3 = tanh(1.5 * driven)

        // 稳态主打圆润 2 次谐波；鼓点瞬态发生时，根据 transient 动态增厚 3 次谐波打击质感
        let baseW3 = 0.55 - 0.35 * characterRound // 0.20 ~ 0.55
        let dynamicW3 = min(0.75, baseW3 + 0.30 * transientRatio * min(1.6, transientGain))
        let dynamicW2 = 1.0 - dynamicW3
        let rawHarmonics = dynamicW2 * h2 + dynamicW3 * h3

        // 4. DC Blocker
        let dcBlocked = rawHarmonics - states[channel].dcPrevInput + dcAlpha * states[channel].dcPrevOutput
        states[channel].dcPrevInput = rawHarmonics
        states[channel].dcPrevOutput = dcBlocked

        // 5. 后级 4 阶 LR 高通 (彻底阻断差频次声波与基频残留)
        let hp1 = states[channel].postHp1.process(dcBlocked)
        let hpFinal = states[channel].postHp2.process(hp1)

        // 6. 后级 2 阶低通 (380Hz)
        let wetFiltered = states[channel].postLp.process(hpFinal)

        // 7. 瞬态打击动态驱动增益 (Punch)
        let dynamicDrive = 1.0 + 0.35 * transientRatio * min(1.6, transientGain)
        let wet = DSPSafeSaturation.process(wetFiltered * wetGain * dynamicDrive, ceiling: 0.45)

        if wetSolo {
            return wet * outputGain
        }

        var dry = sample
        if tightensDryBass {
            dry = states[channel].dryHighPass.process(dry)
        }
        if states[channel].dryBassShelf.c != .identity {
            dry = states[channel].dryBassShelf.process(dry)
        }

        // 8. 自适应裕量避让与总输出安全限幅
        let dryDuck = tightensDryBass ? 0.75 : (1.0 / (1.0 + 0.28 * min(wetGain, 2.5)))
        let combined = dry * dryDuck + wet
        let limited = DSPSafeSaturation.safeLimit(combined, ceiling: 0.98)

        return limited * outputGain
    }
}

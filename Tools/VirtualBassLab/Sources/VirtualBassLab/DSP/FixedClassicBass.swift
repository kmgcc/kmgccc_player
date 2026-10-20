import Foundation

/// 工业级无破音纯净经典虚拟低音 (4阶 LR 双边滤波 + 光滑无除法对称/反对称 NLD + 磁带软饱和)
/// 彻底根除因包络除法与瞬时调幅引发的 10~20Hz 拍频颤音与“摩托车引擎噗噗声”
public struct FixedClassicBass: Sendable {
    private struct ChannelState: Sendable {
        // 前级 4 阶 Linkwitz-Riley 低通 (提取超低频基频)
        var preLp1: DSPBiquad = DSPBiquad()
        var preLp2: DSPBiquad = DSPBiquad()

        // 直流切除滤波器 (DC Blocker)
        var dcPrevInput: Double = 0.0
        var dcPrevOutput: Double = 0.0

        // 后级 4 阶 Linkwitz-Riley 高通 (彻底阻断差频次声波与基频残留)
        var postHp1: DSPBiquad = DSPBiquad()
        var postHp2: DSPBiquad = DSPBiquad()

        // 后级 2 阶低通 (切除人声高频杂质)
        var postLp: DSPBiquad = DSPBiquad()

        // 干声切除超低频高通 (模拟小喇叭) 与 低频搁架
        var dryHighPass: DSPBiquad = DSPBiquad()
        var dryBassShelf: DSPBiquad = DSPBiquad()

        mutating func reset() {
            preLp1.reset()
            preLp2.reset()
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
    private var tightensDryBass: Bool
    private var outputGain: Double
    private var characterRound: Double
    private var wetSolo: Bool
    private var sampleRate: Double
    private var dcAlpha: Double
    private var states: [ChannelState]
    private var currentCutoff: Double
    private var currentBassGainDB: Double

    public init?(sampleRate: Double, channels: Int, cutoffHz: Double = 100, floorHz: Double = 25,
                 intensity: Double = 1.0, bassGainDB: Double = 0.0, tightenDryBass: Bool = false,
                 character: Double = 0.7, wetSolo: Bool = false, outputTrimDB: Double = 0.0) {
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
        self.tightensDryBass = tightenDryBass
        self.characterRound = max(0.0, min(1.0, character))
        self.wetSolo = wetSolo
        self.outputGain = pow(10, outputTrimDB / 20)
        self.dcAlpha = exp(-2.0 * Double.pi * 15.0 / sampleRate)

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

        // 1. 前级 4 阶 Linkwitz-Riley 低通提取基频 (24dB/oct 滚降，阻断中高频进入 NLD)
        let l1 = states[channel].preLp1.process(sample)
        let band = states[channel].preLp2.process(l1)

        // 2. 纯净平滑无除法对称/反对称非线性器件 (处处光滑连续，绝对无分母调制与突突马达声)
        let driven = band * 2.2
        let delta = 0.08
        // 偶次谐波 (8度音，负责温润厚实): 处处光滑的全波软整流
        let h2 = (sqrt(driven * driven + delta * delta) - delta) * 2.2
        // 奇次谐波 (12度音，负责紧凑清晰): 纯净平滑三次软饱和
        let h3 = tanh(1.5 * driven)

        // 根据 character 调节 Round(2次为主) 与 Tight(3次加厚) 的音色平衡
        let w2 = 0.40 + 0.40 * characterRound // 0.40 ~ 0.80
        let w3 = 1.0 - w2                     // 0.60 ~ 0.20
        let rawHarmonics = w2 * h2 + w3 * h3

        // 3. 一阶直流斩波滤波 (DC Blocker, 彻底切除全波整流产生的直流分量)
        let dcBlocked = rawHarmonics - states[channel].dcPrevInput + dcAlpha * states[channel].dcPrevOutput
        states[channel].dcPrevInput = rawHarmonics
        states[channel].dcPrevOutput = dcBlocked

        // 4. 后级 4 阶 Linkwitz-Riley 高通滤波 (彻底切断差频次声波与基频残留，阻断喇叭剧烈乱抖)
        let hp1 = states[channel].postHp1.process(dcBlocked)
        let hpFinal = states[channel].postHp2.process(hp1)

        // 5. 后级 2 阶低通滤波 (380Hz，消除中频人声杂音)
        let wetFiltered = states[channel].postLp.process(hpFinal)

        // 6. 模拟磁带平滑软饱和 (Ceiling 0.45，杜绝削顶破音)
        let wet = DSPSafeSaturation.process(wetFiltered * wetGain, ceiling: 0.45)

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

        // 7. 自适应裕量避让与总输出安全限幅
        let dryDuck = tightensDryBass ? 0.75 : (1.0 / (1.0 + 0.28 * min(wetGain, 2.5)))
        let combined = dry * dryDuck + wet
        let limited = DSPSafeSaturation.safeLimit(combined, ceiling: 0.98)

        return limited * outputGain
    }
}

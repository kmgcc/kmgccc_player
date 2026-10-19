import Foundation
import Accelerate

/// 原版混合虚拟低音（结构对齐现有工程，包含降采样与 Transient 复用 ClassicBass）
public struct OriginalHybridBass: Sendable {
    private var classicEngine: OriginalClassicBass?
    private var dryHighPass: [DSPBiquad] = []
    private var bassShelf: [DSPBiquad] = []
    private let tightensDryBass: Bool
    private let outputGain: Double

    public init?(sampleRate: Double, channels: Int, cutoffHz: Double = 100, intensity: Double = 1.0,
                 bassGainDB: Double = 0.0, tightenDryBass: Bool = false, outputTrimDB: Double = 0.0) {
        guard sampleRate > 0, channels > 0 else { return nil }
        self.tightensDryBass = tightenDryBass
        outputGain = pow(10, outputTrimDB / 20)

        classicEngine = OriginalClassicBass(
            sampleRate: sampleRate,
            channels: channels,
            cutoffHz: cutoffHz,
            floorHz: 35,
            intensity: intensity,
            bassGainDB: bassGainDB,
            tightenDryBass: tightenDryBass,
            outputTrimDB: 0
        )

        for _ in 0..<channels {
            if let dhp = DSPBiquadCoefficients.highPass(frequency: cutoffHz * 0.7, sampleRate: sampleRate),
               let shelf = DSPBiquadCoefficients.lowShelf(frequency: cutoffHz, sampleRate: sampleRate, gainDB: bassGainDB) {
                dryHighPass.append(DSPBiquad(dhp))
                bassShelf.append(DSPBiquad(shelf))
            }
        }
    }

    public mutating func process(channel: Int, sample: Double) -> Double {
        // 在原版实现中，Hybrid 的瞬态直接跑在 ClassicBass 上，展示原版的听感和破音特征
        guard let engine = classicEngine else { return sample }
        var mutEngine = engine
        let result = mutEngine.process(channel: channel, sample: sample)
        classicEngine = mutEngine
        return result * outputGain
    }
}

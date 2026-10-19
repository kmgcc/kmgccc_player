import Foundation

/// 原始经典虚拟低音（还原现有工程实现，用于对比复现“噗噗噗”杂音与硬削波破音）
public struct OriginalClassicBass: Sendable {
    private struct ChannelState: Sendable {
        var floorHighPass = DSPBiquad()
        var lowPass1 = DSPBiquad()
        var lowPass2 = DSPBiquad()
        var wetHighPass1 = DSPBiquad()
        var wetHighPass2 = DSPBiquad()
        var wetLowPass1 = DSPBiquad()
        var wetLowPass2 = DSPBiquad()
        var dryHighPass = DSPBiquad()
        var bassShelf = DSPBiquad()
        var envelope = 0.0
        var dcInput = 0.0
        var dcOutput = 0.0

        mutating func reset() {
            floorHighPass.reset()
            lowPass1.reset()
            lowPass2.reset()
            wetHighPass1.reset()
            wetHighPass2.reset()
            wetLowPass1.reset()
            wetLowPass2.reset()
            dryHighPass.reset()
            bassShelf.reset()
            envelope = 0
            dcInput = 0
            dcOutput = 0
        }
    }

    private static let laggingCorners = [1.423, 7.784, 43.842, 209.892, 990.936]
    private static let leadingCorners = [3.485, 19.237, 96.719, 480.311, 2_382.655]
    private static var sectionCount: Int { laggingCorners.count }

    private let weights: (w2: Double, w3: Double, w4: Double, w5: Double, w6: Double)
    private let wetGain: Double
    private let tightensDryBass: Bool
    private let outputGain: Double
    private let dcAlpha: Double
    private let attack: Double
    private let release: Double
    private let laggingCoefficients: [Double]
    private let leadingCoefficients: [Double]
    private var states: [ChannelState]
    private var allpassState: [Double]

    public init?(sampleRate: Double, channels: Int, cutoffHz: Double = 100, floorHz: Double = 35,
                 intensity: Double = 1.0, bassGainDB: Double = 0.0, tightenDryBass: Bool = false,
                 outputTrimDB: Double = 0.0) {
        guard sampleRate > 0, channels > 0 else { return nil }
        let sourceCutoff = min(cutoffHz, 120.0)
        let wetCorner = max(70, sourceCutoff * 0.75)
        let wetTop = min(800.0, max(300.0, 5 * sourceCutoff))

        guard let fHp = DSPBiquadCoefficients.highPass(frequency: floorHz, sampleRate: sampleRate),
              let lp1 = DSPBiquadCoefficients.lowPass(frequency: sourceCutoff, sampleRate: sampleRate, q: FourthOrderButterworth.qs[0]),
              let lp2 = DSPBiquadCoefficients.lowPass(frequency: sourceCutoff, sampleRate: sampleRate, q: FourthOrderButterworth.qs[1]),
              let whp1 = DSPBiquadCoefficients.highPass(frequency: wetCorner, sampleRate: sampleRate, q: FourthOrderButterworth.qs[0]),
              let whp2 = DSPBiquadCoefficients.highPass(frequency: wetCorner, sampleRate: sampleRate, q: FourthOrderButterworth.qs[1]),
              let wlp1 = DSPBiquadCoefficients.lowPass(frequency: wetTop, sampleRate: sampleRate, q: FourthOrderButterworth.qs[0]),
              let wlp2 = DSPBiquadCoefficients.lowPass(frequency: wetTop, sampleRate: sampleRate, q: FourthOrderButterworth.qs[1]),
              let dhp = DSPBiquadCoefficients.highPass(frequency: cutoffHz * 0.7, sampleRate: sampleRate),
              let shelf = DSPBiquadCoefficients.lowShelf(frequency: cutoffHz, sampleRate: sampleRate, gainDB: bassGainDB) else {
            return nil
        }

        weights = (0.75, 0.40, 0.20, 0.08, 0.03)
        wetGain = floorHz < sourceCutoff ? intensity * 1.0 : 0
        self.tightensDryBass = tightenDryBass
        outputGain = pow(10, outputTrimDB / 20)
        dcAlpha = exp(-2 * Double.pi * 5 / sampleRate)
        attack = 1 - exp(-1 / (0.001 * sampleRate))
        release = 1 - exp(-1 / (0.2 * sampleRate))

        func coefficient(_ corner: Double) -> Double {
            let t = Double.pi * corner / sampleRate
            return (t - 1) / (t + 1)
        }
        laggingCoefficients = Self.laggingCorners.map(coefficient)
        leadingCoefficients = Self.leadingCorners.map(coefficient)

        var channel = ChannelState()
        channel.floorHighPass = DSPBiquad(fHp)
        channel.lowPass1 = DSPBiquad(lp1)
        channel.lowPass2 = DSPBiquad(lp2)
        channel.wetHighPass1 = DSPBiquad(whp1)
        channel.wetHighPass2 = DSPBiquad(whp2)
        channel.wetLowPass1 = DSPBiquad(wlp1)
        channel.wetLowPass2 = DSPBiquad(wlp2)
        channel.dryHighPass = DSPBiquad(dhp)
        channel.bassShelf = DSPBiquad(shelf)

        states = Array(repeating: channel, count: channels)
        allpassState = Array(repeating: 0, count: channels * Self.sectionCount * 4)
    }

    public mutating func process(channel: Int, sample: Double) -> Double {
        guard channel < states.count else { return sample }
        let sections = Self.sectionCount
        let (w2, w3, w4, w5, w6) = weights
        let epsilon = 0.001
        let epsilonSquared = epsilon * epsilon

        let band = states[channel].lowPass2.process(
            states[channel].lowPass1.process(states[channel].floorHighPass.process(sample)))

        var q = band
        var i = band
        let stateBase = channel * sections * 4
        for section in 0..<sections {
            let slot = stateBase + section * 4
            let a = laggingCoefficients[section]
            let qOut = a * q + allpassState[slot] - a * allpassState[slot + 1]
            allpassState[slot] = q
            allpassState[slot + 1] = qOut
            q = qOut
            let b = leadingCoefficients[section]
            let iOut = b * i + allpassState[slot + 2] - b * allpassState[slot + 3]
            allpassState[slot + 2] = i
            allpassState[slot + 3] = iOut
            i = iOut
        }

        let amplitude = (i * i + q * q).squareRoot()
        var envelope = states[channel].envelope
        envelope += (amplitude > envelope ? attack : release) * (amplitude - envelope)
        states[channel].envelope = envelope

        var harmonics = 0.0
        if envelope > 1e-15 {
            // 【原版问题点 1】：拍频波峰时 max(envelope, amplitude) 导数断裂，产生拍频跳跃
            let divisor = max(envelope, amplitude)
            let ur = i / divisor
            let ui = q / divisor

            // 【原版问题点 2】：高阶展开带来巨额差频互调失真
            let u2r = ur * ur - ui * ui, u2i = 2 * ur * ui
            let u3r = u2r * ur - u2i * ui, u3i = u2r * ui + u2i * ur
            let u4r = u3r * ur - u3i * ui, u4i = u3r * ui + u3i * ur
            let u5r = u4r * ur - u4i * ui, u5i = u4r * ui + u4i * ur
            let u6r = u5r * ur - u5i * ui

            let envelopeSquared = envelope * envelope
            let gate = envelopeSquared / (envelopeSquared + epsilonSquared)
            let series = w2 * u2r + w3 * u3r + w4 * u4r + w5 * u5r + w6 * u6r
            harmonics = envelope * gate * series
        }

        let dcBlocked = harmonics - states[channel].dcInput + dcAlpha * states[channel].dcOutput
        states[channel].dcInput = harmonics
        states[channel].dcOutput = dcBlocked

        let highPassed = states[channel].wetHighPass2.process(states[channel].wetHighPass1.process(dcBlocked))
        let wet = states[channel].wetLowPass2.process(states[channel].wetLowPass1.process(highPassed))

        let dry = tightensDryBass ? states[channel].dryHighPass.process(sample) : sample

        // 【原版问题点 3】：湿声居然又进了 bassShelf 提升
        let enhanced = states[channel].bassShelf.process(dry + wetGain * wet)

        // 【原版问题点 4】：逐采样点瞬时 tanh 硬截断，导致尖锐数字破音（噗噗噗）
        let limited = originalMix(original: dry, enhanced: enhanced, ceiling: 1.0)
        return limited * outputGain
    }

    private func originalMix(original: Double, enhanced: Double, ceiling: Double) -> Double {
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

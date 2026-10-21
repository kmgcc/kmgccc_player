import Foundation

public struct DSPAudioFormat: Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct VirtualBassParams: Equatable, Sendable {
    public var cutoffHz: Double = 100.0
    public var intensity: Double = 1.0
    public var transient: Double = 1.0
    public var character: Double = 0.7
    public var wetSolo: Bool = false
    public var bassGainDB: Double = 0.0
    public var outputTrimDB: Double = 0.0
    public var tightenDryBass: Bool = false

    public init() {}
}

public struct DSPBiquadCoefficients: Equatable, Sendable {
    public let b0: Double
    public let b1: Double
    public let b2: Double
    public let a1: Double
    public let a2: Double

    public static let identity = DSPBiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public var isStable: Bool {
        [b0, b1, b2, a1, a2].allSatisfy(\.isFinite)
            && abs(a2) < 1
            && 1 + a1 + a2 > 0
            && 1 - a1 + a2 > 0
    }

    public static func lowPass(frequency: Double, sampleRate: Double, q: Double = 0.7071067811865476) -> DSPBiquadCoefficients? {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate * 0.49 else { return nil }
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosw = cos(omega)
        let a0 = 1 + alpha
        let b1 = 1 - cosw
        let b0 = b1 / 2
        let b2 = b0
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return DSPBiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.7071067811865476) -> DSPBiquadCoefficients? {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate * 0.49 else { return nil }
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosw = cos(omega)
        let a0 = 1 + alpha
        let b1 = -(1 + cosw)
        let b0 = (1 + cosw) / 2
        let b2 = b0
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return DSPBiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    public static func lowShelf(frequency: Double, sampleRate: Double, gainDB: Double, q: Double = 1.0) -> DSPBiquadCoefficients? {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate * 0.49 else { return nil }
        if abs(gainDB) < 1e-6 { return .identity }
        let a = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(omega)
        let sinw = sin(omega)
        let alpha = sinw / (2 * q)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha

        let a0 = (a + 1) + (a - 1) * cosw + twoSqrtAAlpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosw)
        let a2 = (a + 1) + (a - 1) * cosw - twoSqrtAAlpha
        let b0 = a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
        let b2 = a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha)

        return DSPBiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

public struct DSPBiquad: Sendable {
    public var coefficients: DSPBiquadCoefficients
    public var z1 = 0.0
    public var z2 = 0.0

    public var c: DSPBiquadCoefficients {
        get { coefficients }
        set { coefficients = newValue }
    }

    public init(_ coefficients: DSPBiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    @inline(__always)
    public mutating func process(_ input: Double) -> Double {
        let c = coefficients
        let output = c.b0 * input + z1
        z1 = c.b1 * input - c.a1 * output + z2
        z2 = c.b2 * input - c.a2 * output
        return output
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

public struct FourthOrderButterworth: Sendable {
    private var section1: DSPBiquad
    private var section2: DSPBiquad

    public static let qs = [0.5411961001461970, 1.3065629648763766]

    public static func highPass(frequency: Double, sampleRate: Double) -> FourthOrderButterworth? {
        guard let s1 = DSPBiquadCoefficients.highPass(frequency: frequency, sampleRate: sampleRate, q: qs[0]),
              let s2 = DSPBiquadCoefficients.highPass(frequency: frequency, sampleRate: sampleRate, q: qs[1]) else { return nil }
        return FourthOrderButterworth(section1: DSPBiquad(s1), section2: DSPBiquad(s2))
    }

    public static func lowPass(frequency: Double, sampleRate: Double) -> FourthOrderButterworth? {
        guard let s1 = DSPBiquadCoefficients.lowPass(frequency: frequency, sampleRate: sampleRate, q: qs[0]),
              let s2 = DSPBiquadCoefficients.lowPass(frequency: frequency, sampleRate: sampleRate, q: qs[1]) else { return nil }
        return FourthOrderButterworth(section1: DSPBiquad(s1), section2: DSPBiquad(s2))
    }

    public init(section1: DSPBiquad, section2: DSPBiquad) {
        self.section1 = section1
        self.section2 = section2
    }

    @inline(__always)
    public mutating func process(_ input: Double) -> Double {
        section2.process(section1.process(input))
    }

    public mutating func reset() {
        section1.reset()
        section2.reset()
    }
}

public struct LinkwitzRiley4: Sendable {
    private var s1: DSPBiquad
    private var s2: DSPBiquad

    public static func highPass(frequency: Double, sampleRate: Double) -> LinkwitzRiley4? {
        guard let c1 = DSPBiquadCoefficients.highPass(frequency: frequency, sampleRate: sampleRate, q: 0.7071067811865476),
              let c2 = DSPBiquadCoefficients.highPass(frequency: frequency, sampleRate: sampleRate, q: 0.7071067811865476) else { return nil }
        return LinkwitzRiley4(s1: DSPBiquad(c1), s2: DSPBiquad(c2))
    }

    public static func lowPass(frequency: Double, sampleRate: Double) -> LinkwitzRiley4? {
        guard let c1 = DSPBiquadCoefficients.lowPass(frequency: frequency, sampleRate: sampleRate, q: 0.7071067811865476),
              let c2 = DSPBiquadCoefficients.lowPass(frequency: frequency, sampleRate: sampleRate, q: 0.7071067811865476) else { return nil }
        return LinkwitzRiley4(s1: DSPBiquad(c1), s2: DSPBiquad(c2))
    }

    public init(s1: DSPBiquad, s2: DSPBiquad) {
        self.s1 = s1
        self.s2 = s2
    }

    public mutating func update(coefficients c: DSPBiquadCoefficients) {
        s1.c = c
        s2.c = c
    }

    @inline(__always)
    public mutating func process(_ input: Double) -> Double {
        s2.process(s1.process(input))
    }

    public mutating func reset() {
        s1.reset()
        s2.reset()
    }
}

/// 工业级高保真 10 阶 IIR Weaver 全通正交分解网络
/// (两路 5 阶双线性变换全通滤波器，全频带幅频响应恒为严格 1.0 (0dB)，低频 20Hz~300Hz 相位差精确保持在 90° ± 0.55°)
public struct DSPAllpassHilbertSplitter: Sendable {
    public static let laggingCorners = [1.423, 7.784, 43.842, 209.892, 990.936]
    public static let leadingCorners = [3.485, 19.237, 96.719, 480.311, 2382.655]
    public static var sectionCount: Int { laggingCorners.count }

    private var laggingCoeffs: [Double] = []
    private var leadingCoeffs: [Double] = []
    private var laggingXPrev: [Double] = []
    private var laggingYPrev: [Double] = []
    private var leadingXPrev: [Double] = []
    private var leadingYPrev: [Double] = []

    public init(sampleRate: Double = 44100.0) {
        updateSampleRate(sampleRate)
    }

    public mutating func updateSampleRate(_ sampleRate: Double) {
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        laggingCoeffs = Self.laggingCorners.map { corner in
            let t = Double.pi * corner / sr
            return (t - 1.0) / (t + 1.0)
        }
        leadingCoeffs = Self.leadingCorners.map { corner in
            let t = Double.pi * corner / sr
            return (t - 1.0) / (t + 1.0)
        }
        laggingXPrev = Array(repeating: 0.0, count: Self.sectionCount)
        laggingYPrev = Array(repeating: 0.0, count: Self.sectionCount)
        leadingXPrev = Array(repeating: 0.0, count: Self.sectionCount)
        leadingYPrev = Array(repeating: 0.0, count: Self.sectionCount)
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> (i: Double, q: Double) {
        var i = x
        for k in 0..<Self.sectionCount {
            let a = leadingCoeffs[k]
            let y = a * i + leadingXPrev[k] - a * leadingYPrev[k]
            leadingXPrev[k] = i
            leadingYPrev[k] = y
            i = y
        }

        var q = x
        for k in 0..<Self.sectionCount {
            let a = laggingCoeffs[k]
            let y = a * q + laggingXPrev[k] - a * laggingYPrev[k]
            laggingXPrev[k] = q
            laggingYPrev[k] = y
            q = y
        }

        return (i, q)
    }

    public mutating func reset() {
        for k in 0..<Self.sectionCount {
            laggingXPrev[k] = 0.0
            laggingYPrev[k] = 0.0
            leadingXPrev[k] = 0.0
            leadingYPrev[k] = 0.0
        }
    }
}

/// 平滑峰值包络跟踪器与无穷次可微软门限除数发生器
/// (彻底根除 max(envelope, amplitude) 或硬限幅引发的低频拍频折角、跳变与“噗噗噗”马达杂音)
public struct DSPSmoothPeakFollower: Sendable {
    private var attackAlpha: Double
    private var releaseAlpha: Double
    private var envelope: Double = 0.0
    public var epsilon: Double = 0.002 // 约 -54 dBFS 软门限，保证极小信号时不除以 0

    public init(sampleRate: Double = 44100.0, attackMs: Double = 1.5, releaseMs: Double = 100.0) {
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        self.attackAlpha = 1.0 - exp(-1.0 / (max(0.0005, attackMs * 0.001) * sr))
        self.releaseAlpha = 1.0 - exp(-1.0 / (max(0.010, releaseMs * 0.001) * sr))
    }

    public mutating func updateSampleRate(_ sampleRate: Double, attackMs: Double = 1.5, releaseMs: Double = 100.0) {
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        self.attackAlpha = 1.0 - exp(-1.0 / (max(0.0005, attackMs * 0.001) * sr))
        self.releaseAlpha = 1.0 - exp(-1.0 / (max(0.010, releaseMs * 0.001) * sr))
    }

    @inline(__always)
    public mutating func process(amplitude: Double) -> (envelope: Double, divisor: Double) {
        if amplitude > envelope {
            envelope += attackAlpha * (amplitude - envelope)
        } else {
            envelope += releaseAlpha * (amplitude - envelope)
        }
        // C-infinity 级连续平滑软门限
        let divisor = sqrt(envelope * envelope + epsilon * epsilon)
        return (envelope, divisor)
    }

    public mutating func reset() {
        envelope = 0.0
    }
}

/// 模拟磁带平滑软饱和曲线 (防削波超限)
public struct DSPSafeSaturation {
    @inline(__always)
    public static func process(_ x: Double, ceiling: Double = 0.45) -> Double {
        ceiling * tanh(x / ceiling)
    }

    @inline(__always)
    public static func safeLimit(_ x: Double, ceiling: Double = 0.98, knee: Double = 0.85) -> Double {
        let absX = abs(x)
        guard absX > knee else { return x }
        let span = ceiling - knee
        let delta = absX - knee
        let compressed = knee + span * tanh(delta / span)
        return x < 0 ? -compressed : compressed
    }
}

/// 兼容保留结构
public struct AppleALCTracker: Sendable {
    private var attackAlpha: Double
    private var releaseAlpha: Double
    private var holdSamples: Int
    private var env: Double = 0.0
    private var holdCount: Int = 0

    public init(sampleRate: Double = 44100.0, attackMs: Double = 2.0, holdMs: Double = 15.0, releaseMs: Double = 80.0) {
        let sr = sampleRate > 0 ? sampleRate : 44100.0
        attackAlpha = 1.0 - exp(-1.0 / (max(0.0005, attackMs * 0.001) * sr))
        releaseAlpha = 1.0 - exp(-1.0 / (max(0.010, releaseMs * 0.001) * sr))
        holdSamples = Int(holdMs * 0.001 * sr)
    }

    @inline(__always)
    public mutating func process(_ x: Double) -> Double {
        let absX = abs(x)
        if absX > env {
            env += attackAlpha * (absX - env)
            holdCount = holdSamples
        } else {
            if holdCount > 0 {
                holdCount -= 1
            } else {
                env += releaseAlpha * (absX - env)
            }
        }
        return max(0.008, env)
    }

    public mutating func reset() {
        env = 0.0
        holdCount = 0
    }
}

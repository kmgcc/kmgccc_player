import Foundation

public struct DSPAudioFormat: Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
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

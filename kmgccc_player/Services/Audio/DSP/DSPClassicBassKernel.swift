import Accelerate
import Foundation

/// 90° phase-splitting allpass network yielding an analytic pair (re + j·im).
nonisolated struct DSPQuadratureNetwork: Sendable {
    private static let laggingCorners = [1.423, 7.784, 43.842, 209.892, 990.936]
    private static let leadingCorners = [3.485, 19.237, 96.719, 480.311, 2382.655]

    private var lagCoeffs: [Double]
    private var leadCoeffs: [Double]
    private var lagX: [Double]
    private var lagY: [Double]
    private var leadX: [Double]
    private var leadY: [Double]

    var re: Double = 0
    var im: Double = 0

    init(sampleRate: Double) {
        func coeff(_ corner: Double) -> Double {
            let t = Double.pi * corner / sampleRate
            return (t - 1.0) / (t + 1.0)
        }
        self.lagCoeffs = Self.laggingCorners.map(coeff)
        self.leadCoeffs = Self.leadingCorners.map(coeff)
        let n = Self.laggingCorners.count
        self.lagX = Array(repeating: 0, count: n)
        self.lagY = Array(repeating: 0, count: n)
        self.leadX = Array(repeating: 0, count: n)
        self.leadY = Array(repeating: 0, count: n)
    }

    @inline(__always)
    mutating func process(_ x: Double) {
        var a = x
        var b = x
        let n = lagCoeffs.count
        for i in 0..<n {
            let c = lagCoeffs[i]
            let y = c * a + lagX[i] - c * lagY[i]
            lagX[i] = a
            lagY[i] = y
            a = y
        }
        for i in 0..<n {
            let c = leadCoeffs[i]
            let y = c * b + leadX[i] - c * leadY[i]
            leadX[i] = b
            leadY[i] = y
            b = y
        }
        self.re = a
        self.im = -b
    }

    mutating func reset() {
        for i in lagX.indices { lagX[i] = 0; lagY[i] = 0 }
        for i in leadX.indices { leadX[i] = 0; leadY[i] = 0 }
        re = 0
        im = 0
    }

    mutating func copyState(from source: DSPQuadratureNetwork) {
        lagX = source.lagX
        lagY = source.lagY
        leadX = source.leadX
        leadY = source.leadY
        re = source.re
        im = source.im
    }
}

/// ISO 226:2003 equal-loudness contour calculations.
nonisolated enum DSPISOLoudness {
    static let frequencies = [20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0, 250.0, 315.0, 400.0, 500.0, 630.0, 800.0, 1000.0]
    static let af = [0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330, 0.315, 0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250]
    static let lu = [-31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5, -3.1, -2.0, -1.1, -0.4, 0.0, 0.3, 0.5, 0.0]
    static let tf = [78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4, 11.4, 8.6, 6.2, 4.4, 3.0, 2.2, 2.4]

    static func params(frequency: Double) -> (af: Double, lu: Double, tf: Double) {
        let f = min(max(frequency, frequencies[0]), frequencies.last!)
        let x = log(f)
        var i = 0
        while i < frequencies.count - 2 && log(frequencies[i + 1]) < x { i += 1 }
        let x0 = log(frequencies[i])
        let x1 = log(frequencies[i + 1])
        let t = (x - x0) / (x1 - x0)
        return (
            af: af[i] + (af[i + 1] - af[i]) * t,
            lu: lu[i] + (lu[i + 1] - lu[i]) * t,
            tf: tf[i] + (tf[i + 1] - tf[i]) * t
        )
    }

    static func splForPhon(frequency: Double, phon: Double) -> Double {
        let p = params(frequency: frequency)
        let term1 = 4.47e-3 * (pow(10.0, 0.025 * phon) - 1.15)
        let term2 = pow(0.4 * pow(10.0, (p.tf + p.lu) / 10.0 - 9.0), p.af)
        let afVal = max(1e-12, term1 + term2)
        return (10.0 / p.af) * log10(afVal) - p.lu + 94.0
    }

    static func phonForSpl(frequency: Double, spl: Double) -> Double {
        var lo = -10.0, hi = 130.0
        for _ in 0..<50 {
            let mid = 0.5 * (lo + hi)
            if splForPhon(frequency: frequency, phon: mid) < spl {
                lo = mid
            } else {
                hi = mid
            }
        }
        return 0.5 * (lo + hi)
    }

    static func equalLoudnessShiftDB(f0: Double, fh: Double, spl: Double) -> Double {
        let phon = phonForSpl(frequency: f0, spl: spl)
        return splForPhon(frequency: fh, phon: phon) - spl
    }
}

/// Fits fixed-corner low shelves + broadband gain to a target frequency curve using damped Gauss-Newton.
nonisolated func fitPreEQShelves(
    sampleRate: Double,
    grid: [Double],
    wantDB: [Double],
    corners: [Double]
) -> (sections: [DSPBiquadCoefficients], offsetDB: Double) {
    guard !corners.isEmpty else {
        let avgOffset = wantDB.isEmpty ? 0.0 : wantDB.reduce(0.0, +) / Double(wantDB.count)
        return ([], avgOffset)
    }

    let pCount = corners.count + 1
    var gains = Array(repeating: 0.0, count: corners.count)
    var offset = 0.0

    func shelvesDB(currentGains: [Double], freq: Double) -> Double {
        var sum = 0.0
        for i in corners.indices {
            if currentGains[i] != 0,
               let sec = DSPFilterDesign.section(.lowShelf, frequencyHz: corners[i], sampleRate: sampleRate, q: 1.0, gainDB: currentGains[i]) {
                let resp = dspBiquadResponse(sections: [sec], frequencyHz: freq, sampleRate: sampleRate)
                sum += 20.0 * log10(max(1e-6, hypot(resp.re, resp.im)))
            }
        }
        return sum
    }

    for _ in 0..<10 {
        let base = grid.map { shelvesDB(currentGains: gains, freq: $0) }
        let r = grid.indices.map { wantDB[$0] - base[$0] - offset }

        var jMat = Array(repeating: Array(repeating: 0.0, count: pCount), count: grid.count)
        for i in corners.indices {
            var gPerturb = gains
            gPerturb[i] += 0.5
            for j in grid.indices {
                jMat[j][i] = (shelvesDB(currentGains: gPerturb, freq: grid[j]) - base[j]) / 0.5
            }
        }
        for j in grid.indices {
            jMat[j][pCount - 1] = 1.0
        }

        var aMat = Array(repeating: Array(repeating: 0.0, count: pCount), count: pCount)
        var bVec = Array(repeating: 0.0, count: pCount)
        for j in grid.indices {
            for a in 0..<pCount {
                bVec[a] += jMat[j][a] * r[j]
                for c in 0..<pCount {
                    aMat[a][c] += jMat[j][a] * jMat[j][c]
                }
            }
        }
        for a in 0..<pCount {
            aMat[a][a] += 0.05
        }

        let d = solveLinearSystem4x4(A: aMat, b: bVec)
        for i in corners.indices {
            gains[i] = max(-12.0, min(24.0, gains[i] + d[i]))
        }
        offset += d[pCount - 1]
    }

    var sections: [DSPBiquadCoefficients] = []
    for i in corners.indices {
        if let sec = DSPFilterDesign.section(.lowShelf, frequencyHz: corners[i], sampleRate: sampleRate, q: 1.0, gainDB: gains[i]) {
            sections.append(sec)
        }
    }
    return (sections, offset)
}

nonisolated func solveLinearSystem4x4(A: [[Double]], b: [Double]) -> [Double] {
    let n = b.count
    var m = A.indices.map { A[$0] + [b[$0]] }
    for c in 0..<n {
        var p = c
        for r in (c + 1)..<n {
            if abs(m[r][c]) > abs(m[p][c]) { p = r }
        }
        m.swapAt(c, p)
        let d = abs(m[c][c]) > 1e-12 ? m[c][c] : 1e-12
        for r in (c + 1)..<n {
            let f = m[r][c] / d
            for k in c...n {
                m[r][k] -= f * m[c][k]
            }
        }
    }
    var x = Array(repeating: 0.0, count: n)
    for r in (0..<n).reversed() {
        var s = m[r][n]
        for k in (r + 1)..<n {
            s -= m[r][k] * x[k]
        }
        let d = abs(m[r][r]) > 1e-12 ? m[r][r] : 1e-12
        x[r] = s / d
    }
    return x
}

/// Classic virtual bass engine using Quadrature Analytic Harmonics
/// with ISO 226 equal loudness matching and crest-factor normalization.
nonisolated struct DSPClassicBassKernel: DSPBlockKernel {
    var latencyFrames: Int { 0 }
    var stateBytes: Int { MemoryLayout<Self>.stride }

    private let selectedChannels: [Int]
    private let sampleRate: Double
    private let retainsRealBass: Bool
    private let amountGain: Double
    private let outGain: Double
    private let peakCeiling: Double?

    // Filters
    private var floorHP: DSPBiquadCascade
    private var srcLP: DSPBiquadCascade
    private var dryHP: [DSPBiquadCascade]
    private var quad: DSPQuadratureNetwork
    private var eq: DSPBiquadCascade
    private var postHP: DSPBiquadCascade
    private var postLP: DSPBiquadCascade

    // Analytic generator weights and follower
    private let weights: [Double]
    private let K: Int
    private let releaseCoeff: Double
    private var followerG: Double = 1e-9

    init?(
        format: DSPAudioFormat,
        selectedChannels mask: [Bool],
        parameters: DSPClassicBassParameters,
        outputKind: DSPOutputKind?,
        outputCeiling: Double? = nil
    ) {
        let fs = format.sampleRate
        guard mask.count == format.channelCount, fs.isFinite, fs > 0 else { return nil }
        selectedChannels = mask.indices.filter { mask[$0] }
        guard !selectedChannels.isEmpty else { return nil }
        self.sampleRate = fs

        let settings = parameters.resolved(for: outputKind)
        let fc = max(40.0, min(160.0, settings.cutoffHz))
        let floorHz = max(20.0, min(45.0, fc * 0.7))
        self.retainsRealBass = settings.retainsRealBass

        // Intensity mapping: -12 dB ~ +12 dB (50% = 0 dB)
        if settings.intensity <= 0.001 {
            self.amountGain = 0.0
        } else {
            let intensityDB = -12.0 + 24.0 * settings.intensity
            self.amountGain = pow(10.0, intensityDB / 20.0)
        }

        // Floor highpass: 4th-order Butterworth at floorHz
        guard let fhp1 = DSPFilterDesign.section(.highPass, frequencyHz: floorHz, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]),
              let fhp2 = DSPFilterDesign.section(.highPass, frequencyHz: floorHz, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[1]) else { return nil }
        self.floorHP = DSPBiquadCascade([fhp1, fhp2])

        // Source lowpass: 4th-order Butterworth at 1.25 fc
        guard let slp1 = DSPFilterDesign.section(.lowPass, frequencyHz: 1.25 * fc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]),
              let slp2 = DSPFilterDesign.section(.lowPass, frequencyHz: 1.25 * fc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[1]) else { return nil }
        self.srcLP = DSPBiquadCascade([slp1, slp2])

        // Dry crossover highpass per channel (if not retaining real bass, 4th-order LR at 0.85 fc)
        var dryHPList: [DSPBiquadCascade] = []
        if !retainsRealBass {
            let xover = 0.85 * fc
            guard let dhp1 = DSPFilterDesign.section(.highPass, frequencyHz: xover, sampleRate: fs, q: DSPFilterDesign.butterworthQ),
                  let dhp2 = DSPFilterDesign.section(.highPass, frequencyHz: xover, sampleRate: fs, q: DSPFilterDesign.butterworthQ) else { return nil }
            for _ in selectedChannels {
                dryHPList.append(DSPBiquadCascade([dhp1, dhp2]))
            }
        }
        self.dryHP = dryHPList

        self.quad = DSPQuadratureNetwork(sampleRate: fs)

        // Post-highpass: 6th-order (36 dB/oct, tight6) at 0.95 fc (LR4 + 1st section of BW4)
        let hpFc = 0.95 * fc
        guard let php1 = DSPFilterDesign.section(.highPass, frequencyHz: hpFc, sampleRate: fs, q: DSPFilterDesign.butterworthQ),
              let php2 = DSPFilterDesign.section(.highPass, frequencyHz: hpFc, sampleRate: fs, q: DSPFilterDesign.butterworthQ),
              let php3 = DSPFilterDesign.section(.highPass, frequencyHz: hpFc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]) else { return nil }
        let postHPCoeffs = [php1, php2, php3]
        self.postHP = DSPBiquadCascade(postHPCoeffs)

        // Post-lowpass: 4th-order Butterworth tracking min(2 * fc, 320 Hz)
        let lpFc = min(2.0 * fc, 320.0)
        guard let plp1 = DSPFilterDesign.section(.lowPass, frequencyHz: lpFc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]),
              let plp2 = DSPFilterDesign.section(.lowPass, frequencyHz: lpFc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[1]) else { return nil }
        let postLPCoeffs = [plp1, plp2]
        self.postLP = DSPBiquadCascade(postLPCoeffs)

        // Harmonic series orders and geometric decay
        let slopeDB = max(-20.0, min(-8.0, settings.impactDB))
        let rho = pow(10.0, slopeDB / 20.0)
        let maxK = max(3, min(12, Int(((1.25 * fc) / floorHz).rounded(.up)) + 2))
        self.K = maxK

        var w = Array(repeating: 0.0, count: maxK + 1)
        var sumW = 0.0
        for k in 2...maxK {
            w[k] = pow(rho, Double(k - 2))
            sumW += w[k]
        }
        // Crest-factor normalization
        let wScale = 1.0 / max(1.0, sumW * 0.72)
        for k in 2...maxK {
            w[k] *= wScale
        }
        self.weights = w

        // ISO 226 equal-loudness pre-EQ model fitting
        let postCoeffs = postHPCoeffs + postLPCoeffs
        let match = 0.25
        let loudnessRefDB = 84.0

        func modelAt(f0: Double) -> (powerDB: Double, targetDB: Double) {
            var pw = 0.0
            var fp = 0.0
            for k in 2...maxK {
                let resp = dspBiquadResponse(sections: postCoeffs, frequencyHz: Double(k) * f0, sampleRate: fs)
                let m = w[k] * hypot(resp.re, resp.im)
                pw += m * m
                fp += m * m * Double(k) * f0
            }
            let safePw = max(pw, 1e-30)
            let shift = match * DSPISOLoudness.equalLoudnessShiftDB(f0: max(f0, 20.0), fh: fp / safePw, spl: loudnessRefDB)
            return (powerDB: 10.0 * log10(safePw), targetDB: shift)
        }

        let lo = 1.2 * floorHz
        let hi = 0.75 * fc
        var grid: [Double] = []
        if hi > lo {
            for i in 0..<32 {
                grid.append(lo * pow(hi / lo, Double(i) / 31.0))
            }
        } else {
            grid.append(sqrt(floorHz * fc))
        }

        let wantDB = grid.map { f -> Double in
            let m = modelAt(f0: f)
            return max(-9.0, min(4.5, m.targetDB - m.powerDB))
        }

        let corners = [2.0, 3.0, 4.0]
            .map { (0.8 * fc) / $0 }
            .filter { $0 > 0.75 * floorHz && hi > lo }

        let fit = fitPreEQShelves(sampleRate: fs, grid: grid, wantDB: wantDB, corners: corners)
        self.eq = DSPBiquadCascade(fit.sections)
        self.outGain = pow(10.0, fit.offsetDB / 20.0)

        // Follower release: 120 ms
        self.releaseCoeff = exp(-1.0 / (0.12 * fs))

        self.peakCeiling = outputCeiling
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        guard amountGain > 0 || !retainsRealBass else { return }
        let count = selectedChannels.count
        let invCount = 1.0 / Double(count)

        for frame in 0..<frames {
            let base = frame * channels

            // 1. Mono bass extraction
            var mid = 0.0
            for i in 0..<count {
                mid += samples[base + selectedChannels[i]]
            }
            mid *= invCount

            let bass = floorHP.process(mid)
            let filtered = srcLP.process(bass)
            let eqBass = eq.process(filtered)

            // 2. 90° quadrature phase splitting
            quad.process(eqBass)
            let zr = quad.re
            let zi = quad.im
            let a = sqrt(zr * zr + zi * zi)
            followerG = max(a, followerG * releaseCoeff, 1e-9)

            // 3. Polynomial harmonic generation
            let g = followerG
            let ur = zr / g
            let ui = zi / g
            var pr = ur
            var pi = ui
            var acc = 0.0

            for k in 2...K {
                let nr = pr * ur - pi * ui
                pi = pr * ui + pi * ur
                pr = nr
                acc += weights[k] * pr
            }

            // 4. Bandpass and soft saturation ceiling
            let rawH = postLP.process(postHP.process(g * acc)) * outGain
            let h = (tanh(rawH * 0.9) / 0.9) * amountGain

            // 5. Channel mixing with peak control
            for i in 0..<count {
                let offset = base + selectedChannels[i]
                let original = samples[offset]
                let dry = retainsRealBass ? original : dryHP[i].process(original)
                let enhanced = dry + h
                samples[offset] = DSPBassPeakControl.mix(original: original, enhanced: enhanced, ceiling: peakCeiling)
            }
        }
    }

    func makeFreshState() -> DSPClassicBassKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPClassicBassKernel) {
        floorHP.copyState(from: source.floorHP)
        srcLP.copyState(from: source.srcLP)
        if dryHP.count == source.dryHP.count {
            for i in dryHP.indices { dryHP[i].copyState(from: source.dryHP[i]) }
        }
        quad.copyState(from: source.quad)
        eq.copyState(from: source.eq)
        postHP.copyState(from: source.postHP)
        postLP.copyState(from: source.postLP)
        followerG = source.followerG
    }

    mutating func reset() {
        floorHP.reset()
        srcLP.reset()
        for i in dryHP.indices { dryHP[i].reset() }
        quad.reset()
        eq.reset()
        postHP.reset()
        postLP.reset()
        followerG = 1e-9
    }

    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        // Analytic follower dynamically tracks level
    }

    static func staticPeakResponseDB(parameters: DSPClassicBassParameters, outputKind: DSPOutputKind?) -> Double {
        0.0
    }
}

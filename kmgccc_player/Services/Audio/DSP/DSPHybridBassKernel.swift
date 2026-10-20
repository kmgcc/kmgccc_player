import Accelerate
import Foundation

/// Cascade of second-order IIR biquad sections.
nonisolated struct DSPBiquadCascade: Sendable {
    var sections: [DSPBiquad]

    init(_ sections: [DSPBiquad] = []) {
        self.sections = sections
    }

    init(_ coefficients: [DSPBiquadCoefficients]) {
        self.sections = coefficients.map(DSPBiquad.init)
    }

    @inline(__always)
    mutating func process(_ input: Double) -> Double {
        var x = input
        for i in 0..<sections.count {
            x = sections[i].process(x)
        }
        return x
    }

    mutating func reset() {
        for i in 0..<sections.count {
            sections[i].reset()
        }
    }

    mutating func copyState(from source: DSPBiquadCascade) {
        guard sections.count == source.sections.count else { return }
        for i in 0..<sections.count {
            sections[i].copyState(from: source.sections[i])
        }
    }
}

/// Peak follower with hold, exponential release, and one-pole smoothing
/// after Apple's US10382857B1 (FIGS. 5B/6).
nonisolated struct DSPPeakHoldFollower: Sendable {
    var holdSamples: Int
    var release: Double
    var smooth: Double
    var nearPeak: Double
    var floor: Double

    var peak: Double = 0
    var out: Double = 0
    var holdLeft: Int = 0

    init(
        sampleRate: Double,
        holdMs: Double = 180,
        releaseMs: Double = 450,
        smoothMs: Double = 15,
        nearPeak: Double = 0.9,
        floor: Double = 1e-5
    ) {
        self.holdSamples = Int((holdMs * 1e-3 * sampleRate).rounded())
        self.release = exp(-1.0 / (max(1.0, releaseMs) * 1e-3 * sampleRate))
        self.smooth = 1.0 - exp(-1.0 / (smoothMs * 1e-3 * sampleRate))
        self.nearPeak = nearPeak
        self.floor = floor
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let a = abs(x)
        if a >= peak {
            peak = a
            holdLeft = holdSamples
        } else if holdLeft > 0 {
            holdLeft -= 1
            if a >= nearPeak * peak {
                holdLeft = holdSamples
            }
        } else {
            peak = max(a, peak * release)
        }
        if peak >= out {
            out = peak
        } else {
            out += (peak - out) * smooth
        }
        return max(out, floor)
    }

    mutating func reset() {
        peak = 0
        out = 0
        holdLeft = 0
    }

    mutating func copyState(from source: DSPPeakHoldFollower) {
        peak = source.peak
        out = source.out
        holdLeft = source.holdLeft
    }
}

/// Integer-sample delay line.
nonisolated struct DSPIntegerDelay: Sendable {
    private var buffer: [Double]
    private var pos: Int = 0
    private var delay: Int = 0

    var storageBytes: Int { buffer.count * MemoryLayout<Double>.stride }

    init(maxSamples: Int) {
        self.buffer = Array(repeating: 0, count: max(2, maxSamples + 1))
    }

    mutating func setDelay(_ samples: Int) {
        self.delay = max(0, min(buffer.count - 1, samples))
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let n = buffer.count
        buffer[pos] = x
        var r = pos - delay
        if r < 0 { r += n }
        pos += 1
        if pos >= n { pos = 0 }
        return buffer[r]
    }

    mutating func reset() {
        DSPStateCopy.clear(&buffer)
        pos = 0
    }

    mutating func copyState(from source: DSPIntegerDelay) {
        if buffer.count == source.buffer.count {
            DSPStateCopy.assign(&buffer, from: source.buffer)
            pos = source.pos
            delay = source.delay
        }
    }
}

/// Computes the group delay (in seconds) of a cascade of biquads at frequency f.
nonisolated func dspBiquadGroupDelay(sections: [DSPBiquadCoefficients], frequencyHz: Double, sampleRate: Double) -> Double {
    let df = max(0.01, frequencyHz * 1e-4)
    let (r1, i1) = dspBiquadResponse(sections: sections, frequencyHz: frequencyHz - df, sampleRate: sampleRate)
    let (r2, i2) = dspBiquadResponse(sections: sections, frequencyHz: frequencyHz + df, sampleRate: sampleRate)
    var dphi = atan2(i2, r2) - atan2(i1, r1)
    while dphi > Double.pi { dphi -= 2 * Double.pi }
    while dphi < -Double.pi { dphi += 2 * Double.pi }
    return -dphi / (2 * Double.pi * 2 * df)
}

nonisolated func dspBiquadResponse(sections: [DSPBiquadCoefficients], frequencyHz: Double, sampleRate: Double) -> (re: Double, im: Double) {
    let w = 2 * Double.pi * frequencyHz / sampleRate
    let c1 = cos(w), s1 = -sin(w)
    let c2 = cos(2 * w), s2 = -sin(2 * w)
    var re = 1.0, im = 0.0
    for c in sections {
        let nr = c.b0 + c.b1 * c1 + c.b2 * c2
        let ni = c.b1 * s1 + c.b2 * s2
        let dr = 1.0 + c.a1 * c1 + c.a2 * c2
        let di = c.a1 * s1 + c.a2 * s2
        let den = dr * dr + di * di
        guard den > 1e-12 else { continue }
        let hr = (nr * dr + ni * di) / den
        let hi = (ni * dr - nr * di) / den
        let r = re * hr - im * hi
        im = re * hi + im * hr
        re = r
    }
    return (re, im)
}

/// Virtual bass engine using Level-Normalized Nonlinear Distortion (NLD)
/// with adaptive cutoff-drive dynamic linkage and smooth C-infinity saturation.
nonisolated struct DSPHybridBassKernel: DSPBlockKernel {
    var latencyFrames: Int { 0 }
    var keepsReferenceState: Bool { false }

    private let selectedChannels: [Int]
    private let sampleRate: Double
    private let retainsRealBass: Bool
    private let amountGain: Double
    private let drive_eff: Double
    private let baseGain: Double
    private let peakCeiling: Double?

    // Filters
    private var floorHP: DSPBiquadCascade
    private var srcLP: DSPBiquadCascade
    private var dryHP: [DSPBiquadCascade]
    private var dcBlock: DSPBiquadCascade
    private var postHP: DSPBiquadCascade
    private var postLP: DSPBiquadCascade

    // Envelope followers
    private var f1: DSPPeakHoldFollower
    private var f2: DSPPeakHoldFollower

    // Delay line for g1
    private var g1Delay: DSPIntegerDelay

    let stateBytes: Int

    init?(
        format: DSPAudioFormat,
        selectedChannels mask: [Bool],
        parameters: DSPHybridBassParameters,
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
        self.retainsRealBass = settings.retainsRealBass

        // Intensity mapping: -12 dB ~ +12 dB (50% = 0 dB)
        if settings.intensity <= 0.001 {
            self.amountGain = 0.0
        } else {
            let intensityDB = -12.0 + 24.0 * settings.intensity
            self.amountGain = pow(10.0, intensityDB / 20.0)
        }

        // Adaptive drive: baseDrive = 0.2 + 0.8 * impact, drive_eff = baseDrive * (60 / fc)^1.05
        let baseDrive = 0.2 + 0.8 * settings.impact
        let driveScale = pow(60.0 / fc, 1.05)
        self.drive_eff = max(0.05, min(2.5, baseDrive * driveScale))

        // Floor highpass: 4th-order Butterworth at 45 Hz
        guard let fhp1 = DSPFilterDesign.section(.highPass, frequencyHz: 45.0, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]),
              let fhp2 = DSPFilterDesign.section(.highPass, frequencyHz: 45.0, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[1]) else { return nil }
        self.floorHP = DSPBiquadCascade([fhp1, fhp2])

        // Source lowpass: 4th-order Linkwitz-Riley at min(fc, 95 Hz)
        let srcFc = min(fc, 95.0)
        guard let slp1 = DSPFilterDesign.section(.lowPass, frequencyHz: srcFc, sampleRate: fs, q: DSPFilterDesign.butterworthQ),
              let slp2 = DSPFilterDesign.section(.lowPass, frequencyHz: srcFc, sampleRate: fs, q: DSPFilterDesign.butterworthQ) else { return nil }
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

        // DC blocker: 2nd-order critically damped (Q=0.5) at 20 Hz
        guard let dcb1 = DSPFilterDesign.section(.highPass, frequencyHz: 20.0, sampleRate: fs, q: 0.5),
              let dcb2 = DSPFilterDesign.section(.highPass, frequencyHz: 20.0, sampleRate: fs, q: 0.5) else { return nil }
        self.dcBlock = DSPBiquadCascade([dcb1, dcb2])

        // Post-highpass: 6th-order (36 dB/oct, tight6) at 0.95 fc (LR4 + 1st section of BW4)
        let hpFc = 0.95 * fc
        guard let php1 = DSPFilterDesign.section(.highPass, frequencyHz: hpFc, sampleRate: fs, q: DSPFilterDesign.butterworthQ),
              let php2 = DSPFilterDesign.section(.highPass, frequencyHz: hpFc, sampleRate: fs, q: DSPFilterDesign.butterworthQ),
              let php3 = DSPFilterDesign.section(.highPass, frequencyHz: hpFc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]) else { return nil }
        let postHPCoeffs = [php1, php2, php3]
        self.postHP = DSPBiquadCascade(postHPCoeffs)

        // Post-lowpass: 4th-order Butterworth tracking min(2 * fc, 300 Hz)
        let lpFc = min(2.0 * fc, 300.0)
        guard let plp1 = DSPFilterDesign.section(.lowPass, frequencyHz: lpFc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[0]),
              let plp2 = DSPFilterDesign.section(.lowPass, frequencyHz: lpFc, sampleRate: fs, q: DSPFilterDesign.fourthOrderQs[1]) else { return nil }
        let postLPCoeffs = [plp1, plp2]
        self.postLP = DSPBiquadCascade(postLPCoeffs)

        // Equal-loudness base gain boost when cutoff is low (capped at +3 dB)
        let lowCutoffBoost = max(0.0, min(3.0, (100.0 - fc) / 50.0 * 3.0))
        self.baseGain = pow(10.0, lowCutoffBoost / 20.0) * 1.15

        // Envelope followers: hold 180ms, release 450ms, smooth 15ms
        self.f1 = DSPPeakHoldFollower(sampleRate: fs, holdMs: 180.0, releaseMs: 450.0, smoothMs: 15.0, nearPeak: 0.9, floor: 1e-5)
        self.f2 = DSPPeakHoldFollower(sampleRate: fs, holdMs: 180.0, releaseMs: 450.0, smoothMs: 15.0, nearPeak: 0.9, floor: 1e-7)

        // Delay line matching post-filter group delay at 2 * fc
        let fh = 2.0 * fc
        let postDelaySec = dspBiquadGroupDelay(sections: postHPCoeffs + postLPCoeffs, frequencyHz: fh, sampleRate: fs)
        let postDelaySamples = max(1, Int((postDelaySec * fs).rounded()))
        var delayLine = DSPIntegerDelay(maxSamples: max(postDelaySamples + 16, Int(0.05 * fs)))
        delayLine.setDelay(postDelaySamples)
        self.g1Delay = delayLine

        self.peakCeiling = outputCeiling
        self.stateBytes = MemoryLayout<Self>.stride + delayLine.storageBytes
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
            let x = srcLP.process(bass)

            // 2. Primary follower
            let g1 = f1.process(x)

            // 3. Normalized NLD with smooth C-infinity triode saturation
            let u = tanh((x / g1) * drive_eff)
            let yRaw = tanh(u) + 0.42 * (u * u)
            let y = dcBlock.process(yRaw)

            // 4. Bandpass
            let hb = postLP.process(postHP.process(y))

            // 5. Secondary follower and dynamic gain recovery
            let g1d = g1Delay.process(g1)
            let g2 = f2.process(hb)
            let gainRatio = min(4.0, g1d / max(1e-6, g2))

            // 6. Output harmonic with soft saturation ceiling
            let rawH = hb * gainRatio * baseGain
            let h = (tanh(rawH * 0.9) / 0.9) * amountGain

            // 7. Channel mixing with peak control
            for i in 0..<count {
                let offset = base + selectedChannels[i]
                let original = samples[offset]
                let dry = retainsRealBass ? original : dryHP[i].process(original)
                let enhanced = dry + h
                samples[offset] = DSPBassPeakControl.mix(original: original, enhanced: enhanced, ceiling: peakCeiling)
            }
        }
    }

    func makeFreshState() -> DSPHybridBassKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPHybridBassKernel) {
        floorHP.copyState(from: source.floorHP)
        srcLP.copyState(from: source.srcLP)
        if dryHP.count == source.dryHP.count {
            for i in dryHP.indices { dryHP[i].copyState(from: source.dryHP[i]) }
        }
        dcBlock.copyState(from: source.dcBlock)
        postHP.copyState(from: source.postHP)
        postLP.copyState(from: source.postLP)
        f1.copyState(from: source.f1)
        f2.copyState(from: source.f2)
        g1Delay.copyState(from: source.g1Delay)
    }

    mutating func reset() {
        floorHP.reset()
        srcLP.reset()
        for i in dryHP.indices { dryHP[i].reset() }
        dcBlock.reset()
        postHP.reset()
        postLP.reset()
        f1.reset()
        f2.reset()
        g1Delay.reset()
    }

    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        // Peak followers track audio level dynamically; offset not required
    }

    static func staticPeakResponseDB(parameters: DSPHybridBassParameters) -> Double {
        0.0
    }
}

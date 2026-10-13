import Accelerate
import Foundation

/// Hybrid virtual bass after Moliner, Rämö & Välimäki, "Virtual Bass System
/// with Fuzzy Separation of Tones and Transients" (DAFx 2020, CC BY 3.0).
///
/// The mid channel's low band is resampled to 4096 Hz and analysed with a
/// 512-point Hann STFT, hop 64. Median filtering along time and frequency
/// (Fitzgerald) gives tonalness R_s, transientness R_t and noisiness
/// R_n = 1 − √|R_s − R_t|, which split each frame into tonal, transient and
/// noise parts that sum exactly to the input (paper eqs. 7–13).
///
/// - Transients: low-passed at f_c, half-wave rectified fuzz exponential
///   (HWR-FEXP1), band-passed from f_c to 4f_c and raised by g.
/// - Tones: a phase vocoder finds f0 below f_c (rejecting a second harmonic
///   of a lower peak) and its harmonics within τ·k·f0. Detected harmonics are
///   rescaled inside a Tukey region of interest with their phase kept;
///   missing ones are pitch-shifted copies of the fundamental's region with
///   Lagrange fractional-bin interpolation and per-frame phase propagation
///   (Laroche–Dolson). Target levels follow a Bark-band spectral envelope
///   held between two slopes, α_low and α_high dB per octave above f_c.
/// - Noise: untouched.
///
/// Only the added content is synthesized: the transient harmonics and the
/// change the vocoder makes to the tonal spectrum. It is resampled back and
/// added to the dry signal delayed by the same latency, so the dry path is
/// never altered except by the optional speaker high-pass.
///
/// Our choices where the paper gives no number: median lengths of 13 frames
/// and 9 bins; IIR instead of order-500 FIR band filters, which saves about
/// 60 ms, with an eighth-order high-pass after the rectifier so the IIR
/// band-pass still rejects the fundamental and DC the rectifier makes; an
/// analysis threshold 60 dB below programme full scale; detected harmonics
/// are only raised, never cut; the timbre limits are anchored at the
/// strongest bass partial; a fundamental holds across frames while it stays
/// within 6 dB of the strongest candidate, and a lower-octave candidate
/// must be within 12 dB of it; synthesized harmonics stay within 12 dB of
/// the fundamental's own region; frames without a transient or without a
/// fundamental skip their branch, so cost follows the content.
nonisolated final class DSPHybridBassEngine {
    static let lowRate = 4_096.0
    static let frameSize = 512
    static let hop = 64
    static let binCount = frameSize / 2 + 1
    static let timeMedianLength = 13
    static let frequencyMedianLength = 9
    /// Low-rate frames from a sample's arrival to its final synthesis.
    static let synthesisDelay = 896
    private static let downHalfWidth = 6.0
    private static let upHalfWidth = 6.0

    let latencyFrames: Int
    private let ratio: Double
    private let cutoff: Double
    private let harmonicCount: Int
    private let tolerance: Double
    private let alphaLow: Double
    private let alphaHigh: Double
    private let harmonicGain: Double
    private let transientGain: Double
    private var reference = 1.0

    // Resampling kernels: windowed sinc tables, 256 points per unit.
    private let downTable: [Double]
    private let downWidth: Double
    private let downScale: Double
    private let upTable: [Double]
    private let upScale: Double

    // Full-rate mid input for the downsampler.
    private var midRing: [Double]
    private let midMask: Int
    private var inputCount = 0
    private var nextLowSample = 0

    // Low-rate analysis.
    private var lowRing = [Double](repeating: 0, count: 1_024)
    private var lowCount = 0
    private let window: [Double]
    private var spectraReal: [Double]
    private var spectraImaginary: [Double]
    private var magnitudes: [Double]
    private var frameCount = 0
    private var transientOverlap = [Double](repeating: 0, count: 2_048)
    private var tonalOverlap = [Double](repeating: 0, count: 2_048)
    private var generated = [Double](repeating: 0, count: 256)
    private var synthesizedCount = 0
    private var lowPass: [DSPBiquad]
    private var bandHighPass: [DSPBiquad]
    private var bandLowPass: [DSPBiquad]
    private var phaseReal = [Double](repeating: 1, count: 16)
    private var phaseImaginary = [Double](repeating: 0, count: 16)
    /// Fundamental of the last tonal frame, 0 when there was none.
    private var previousFundamentalBin = 0.0

    // FFT.
    private let setup: FFTSetupD
    private let roundTrip: Double
    private let fftReal: UnsafeMutablePointer<Double>
    private let fftImaginary: UnsafeMutablePointer<Double>
    private let fftTime: UnsafeMutablePointer<Double>
    private var scratch: [Double]
    private var toneMagnitude: [Double]
    private var sReal: [Double]
    private var sImaginary: [Double]
    private var tReal: [Double]
    private var tImaginary: [Double]
    private var dReal: [Double]
    private var dImaginary: [Double]
    private let barkCenters: [Double]

    var stateBytes: Int {
        (midRing.count + lowRing.count + spectraReal.count * 3 + transientOverlap.count * 2) * 8
    }

    init?(sampleRate: Double, parameters: DSPHybridBassParameters, outputKind: DSPOutputKind?) {
        guard sampleRate.isFinite, sampleRate >= 8_192,
              let setup = DSPFFTSetups.setup(log2n: 9),
              let productScale = DSPConvolutionLevel.productScale(setup: setup, log2n: 9) else { return nil }
        self.setup = setup
        roundTrip = 1 / (2 * productScale)
        let tuning = parameters.resolvedCutoff(for: outputKind)
        cutoff = tuning.cutoffHz
        harmonicCount = Int(parameters.harmonicCount.rounded())
        tolerance = parameters.harmonicTolerance
        alphaLow = parameters.timbreLowDBPerOctave
        alphaHigh = parameters.timbreHighDBPerOctave
        // Intensity 0.5 places the harmonics on the timbre envelope.
        harmonicGain = 2 * parameters.intensity
        // g = 10 dB at transient 0.5, scaled with intensity like the tones.
        transientGain = parameters.transient > 0
            ? pow(10, (10 + 20 * log10(2 * parameters.transient)) / 20) * harmonicGain : 0

        ratio = sampleRate / Self.lowRate
        // Anti-alias at 1.7 kHz, half-width in full-rate samples.
        downWidth = Self.downHalfWidth * ratio
        let downCutoff = 1_700 / sampleRate
        downTable = Self.sincTable(halfWidth: downWidth, cutoff: downCutoff, resolution: 256 / ratio)
        downScale = 2 * downCutoff
        let upCutoff = 1_800 / Self.lowRate
        upTable = Self.sincTable(halfWidth: Self.upHalfWidth, cutoff: upCutoff, resolution: 256)
        upScale = 2 * upCutoff
        latencyFrames = Self.latencyFrames(sampleRate: sampleRate)

        var size = 64
        while size < Int(2 * downWidth) + 8 { size *= 2 }
        midRing = Array(repeating: 0, count: size)
        midMask = size - 1

        window = (0..<Self.frameSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.frameSize)) }
        let ringCount = Self.timeMedianLength * Self.binCount
        spectraReal = Array(repeating: 0, count: ringCount)
        spectraImaginary = Array(repeating: 0, count: ringCount)
        magnitudes = Array(repeating: 0, count: ringCount)
        scratch = Array(repeating: 0, count: Self.binCount)
        toneMagnitude = Array(repeating: 0, count: Self.binCount)
        sReal = Array(repeating: 0, count: Self.binCount)
        sImaginary = Array(repeating: 0, count: Self.binCount)
        tReal = Array(repeating: 0, count: Self.binCount)
        tImaginary = Array(repeating: 0, count: Self.binCount)
        dReal = Array(repeating: 0, count: Self.binCount)
        dImaginary = Array(repeating: 0, count: Self.binCount)

        // The rectifier turns the transient into DC, the fundamental and its
        // harmonics; an eighth-order high-pass keeps the first two (about
        // 30 dB down an octave below f_c) out of the added bass.
        let cutoff = tuning.cutoffHz
        let lowPassSections = DSPFilterDesign.fourthOrderQs.compactMap {
            DSPFilterDesign.section(.lowPass, frequencyHz: cutoff, sampleRate: Self.lowRate, q: $0)
        }
        let highPassSections = DSPFilterDesign.eighthOrderQs.compactMap {
            DSPFilterDesign.section(.highPass, frequencyHz: cutoff, sampleRate: Self.lowRate, q: $0)
        }
        let upperSections = DSPFilterDesign.fourthOrderQs.compactMap {
            DSPFilterDesign.section(.lowPass, frequencyHz: min(4 * cutoff, 1_800), sampleRate: Self.lowRate, q: $0)
        }
        guard lowPassSections.count == 2, highPassSections.count == 4, upperSections.count == 2 else { return nil }
        lowPass = lowPassSections.map(DSPBiquad.init)
        bandHighPass = highPassSections.map(DSPBiquad.init)
        bandLowPass = upperSections.map(DSPBiquad.init)

        fftReal = .allocate(capacity: Self.frameSize / 2)
        fftImaginary = .allocate(capacity: Self.frameSize / 2)
        fftTime = .allocate(capacity: Self.frameSize)
        // Zwicker critical-band centres below the 2048 Hz Nyquist frequency.
        barkCenters = [50, 150, 250, 350, 450, 570, 700, 840, 1_000, 1_170, 1_370, 1_600, 1_850]
    }

    deinit {
        fftReal.deallocate()
        fftImaginary.deallocate()
        fftTime.deallocate()
    }

    /// Full-rate frames from input to output: the synthesis delay plus both
    /// resampling kernels' look-ahead, about 220 ms at any rate.
    static func latencyFrames(sampleRate: Double) -> Int {
        let ratio = sampleRate / lowRate
        return Int(((upHalfWidth + Double(synthesisDelay)) * ratio + downHalfWidth * ratio).rounded(.up)) + 2
    }

    /// A silent engine with the same design.
    func makeFresh(sampleRate: Double, parameters: DSPHybridBassParameters,
                   outputKind: DSPOutputKind?) -> DSPHybridBassEngine? {
        let fresh = DSPHybridBassEngine(sampleRate: sampleRate, parameters: parameters, outputKind: outputKind)
        fresh?.reference = reference
        return fresh
    }

    func setProgramLevel(reference: Double) {
        self.reference = reference
    }

    func copyState(from source: DSPHybridBassEngine) {
        guard source.ratio == ratio, source.midRing.count == midRing.count else { return }
        DSPStateCopy.assign(&midRing, from: source.midRing)
        inputCount = source.inputCount
        nextLowSample = source.nextLowSample
        DSPStateCopy.assign(&lowRing, from: source.lowRing)
        lowCount = source.lowCount
        DSPStateCopy.assign(&spectraReal, from: source.spectraReal)
        DSPStateCopy.assign(&spectraImaginary, from: source.spectraImaginary)
        DSPStateCopy.assign(&magnitudes, from: source.magnitudes)
        frameCount = source.frameCount
        DSPStateCopy.assign(&transientOverlap, from: source.transientOverlap)
        DSPStateCopy.assign(&tonalOverlap, from: source.tonalOverlap)
        DSPStateCopy.assign(&generated, from: source.generated)
        synthesizedCount = source.synthesizedCount
        for index in lowPass.indices { lowPass[index].copyState(from: source.lowPass[index]) }
        for index in bandHighPass.indices { bandHighPass[index].copyState(from: source.bandHighPass[index]) }
        for index in bandLowPass.indices { bandLowPass[index].copyState(from: source.bandLowPass[index]) }
        previousFundamentalBin = source.previousFundamentalBin
        DSPStateCopy.assign(&phaseReal, from: source.phaseReal)
        DSPStateCopy.assign(&phaseImaginary, from: source.phaseImaginary)
    }

    func reset() {
        DSPStateCopy.clear(&midRing)
        inputCount = 0
        nextLowSample = 0
        DSPStateCopy.clear(&lowRing)
        lowCount = 0
        DSPStateCopy.clear(&spectraReal)
        DSPStateCopy.clear(&spectraImaginary)
        DSPStateCopy.clear(&magnitudes)
        frameCount = 0
        DSPStateCopy.clear(&transientOverlap)
        DSPStateCopy.clear(&tonalOverlap)
        DSPStateCopy.clear(&generated)
        synthesizedCount = 0
        for index in lowPass.indices { lowPass[index].reset() }
        for index in bandHighPass.indices { bandHighPass[index].reset() }
        for index in bandLowPass.indices { bandLowPass[index].reset() }
        previousFundamentalBin = 0
        for index in phaseReal.indices {
            phaseReal[index] = 1
            phaseImaginary[index] = 0
        }
    }

    /// Feeds one full-rate mid sample and returns the generated bass for the
    /// sample one latency earlier.
    func process(mid: Double) -> Double {
        midRing[inputCount & midMask] = mid
        inputCount += 1
        // Every low-rate sample whose kernel window is complete.
        while Double(nextLowSample) * ratio + downWidth <= Double(inputCount - 1) {
            pushLowSample(downsample(at: Double(nextLowSample) * ratio))
            nextLowSample += 1
        }
        // Output for full-rate time inputCount − 1 − latency, in low-rate units.
        let sourceTime = Double(inputCount - 1 - latencyFrames) / ratio
        guard sourceTime >= 0 else { return 0 }
        return upsample(at: sourceTime)
    }

    // MARK: Resampling

    private static func sincTable(halfWidth: Double, cutoff: Double, resolution: Double) -> [Double] {
        let count = Int((halfWidth * resolution).rounded(.up)) + 2
        return (0..<count).map { index in
            let t = Double(index) / resolution
            guard t < halfWidth else { return 0 }
            let x = 2 * cutoff * t
            let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let w = 0.5 + 0.5 * t / halfWidth
            let blackman = 0.42 - 0.5 * cos(2 * Double.pi * w) + 0.08 * cos(4 * Double.pi * w)
            return sinc * blackman
        }
    }

    @inline(__always)
    private func tableValue(_ table: [Double], distance: Double, resolution: Double) -> Double {
        let position = abs(distance) * resolution
        let index = Int(position)
        guard index + 1 < table.count else { return 0 }
        let fraction = position - Double(index)
        return table[index] + (table[index + 1] - table[index]) * fraction
    }

    private func downsample(at position: Double) -> Double {
        let first = Int((position - downWidth).rounded(.up))
        let last = Int((position + downWidth).rounded(.down))
        let resolution = 256 / ratio
        var sum = 0.0
        for index in max(0, first)...max(0, last) where index < inputCount && inputCount - index <= midRing.count {
            sum += midRing[index & midMask] * tableValue(downTable, distance: Double(index) - position,
                                                         resolution: resolution)
        }
        return sum * downScale
    }

    private func upsample(at position: Double) -> Double {
        let first = Int((position - Self.upHalfWidth).rounded(.up))
        let last = Int((position + Self.upHalfWidth).rounded(.down))
        var sum = 0.0
        for index in max(0, first)...max(0, last) where index < synthesizedCount
            && synthesizedCount - index <= generated.count {
            sum += generated[index & (generated.count - 1)]
                * tableValue(upTable, distance: Double(index) - position, resolution: 256)
        }
        return sum * upScale
    }

    // MARK: Low-rate analysis and synthesis

    private func pushLowSample(_ value: Double) {
        lowRing[lowCount & 1_023] = value
        lowCount += 1
        if lowCount % Self.hop == 0 {
            analyseFrame()
        }
        // Final once every overlapping frame has been synthesized.
        let final = lowCount - Self.synthesisDelay
        if final >= 0 {
            synthesize(sample: final)
        }
    }

    private func synthesize(sample index: Int) {
        let slot = index & 2_047
        let transient = transientOverlap[slot]
        let tonal = tonalOverlap[slot]
        transientOverlap[slot] = 0
        tonalOverlap[slot] = 0
        // Transient branch: LPF at f_c, HWR-FEXP1, band-pass f_c…4f_c, gain g.
        var low = transient
        for section in lowPass.indices { low = lowPass[section].process(low) }
        // Drive so that a −10 dBFS programme transient reaches the knee.
        let drive = 3 * reference
        let x = low * drive
        let shaped = x > 0 ? (1 - exp(-x)) / (1 - exp(-1)) : 0
        var banded = shaped / drive
        for section in bandHighPass.indices { banded = bandHighPass[section].process(banded) }
        for section in bandLowPass.indices { banded = bandLowPass[section].process(banded) }
        generated[index & (generated.count - 1)] = banded * transientGain + tonal
        synthesizedCount = index + 1
    }

    private func analyseFrame() {
        let size = Self.frameSize
        let bins = Self.binCount
        // Newest frame: the last 512 low-rate samples, windowed.
        for index in 0..<size {
            fftTime[index] = lowRing[(lowCount - size + index) & 1_023] * window[index]
        }
        forwardTransform()
        let slot = frameCount % Self.timeMedianLength
        let base = slot * bins
        for bin in 0..<bins {
            let re = scratchReal(bin), im = scratchImaginary(bin)
            spectraReal[base + bin] = re
            spectraImaginary[base + bin] = im
            magnitudes[base + bin] = (re * re + im * im).squareRoot()
        }
        frameCount += 1
        let half = Self.timeMedianLength / 2
        guard frameCount > half else { return }
        // The frame half a median length back now has its full context.
        let frame = frameCount - 1 - half
        separateAndProcess(frame: frame)
    }

    private func scratchReal(_ bin: Int) -> Double {
        if bin == 0 { return fftReal[0] }
        if bin == Self.binCount - 1 { return fftImaginary[0] }
        return fftReal[bin]
    }

    private func scratchImaginary(_ bin: Int) -> Double {
        bin == 0 || bin == Self.binCount - 1 ? 0 : fftImaginary[bin]
    }

    private func forwardTransform() {
        var split = DSPDoubleSplitComplex(realp: fftReal, imagp: fftImaginary)
        fftTime.withMemoryRebound(to: DSPDoubleComplex.self, capacity: Self.frameSize / 2) { complex in
            vDSP_ctozD(complex, 2, &split, 1, vDSP_Length(Self.frameSize / 2))
        }
        vDSP_fft_zripD(setup, &split, 1, 9, FFTDirection(kFFTDirection_Forward))
    }

    /// Inverse transforms a full spectrum and overlap-adds it, synthesis
    /// windowed, into `overlap` at the frame's position.
    private func overlapAdd(real: [Double], imaginary: [Double], frame: Int, into overlap: inout [Double]) {
        let bins = Self.binCount
        fftReal[0] = real[0]
        fftImaginary[0] = real[bins - 1]
        for bin in 1..<(bins - 1) {
            fftReal[bin] = real[bin]
            fftImaginary[bin] = imaginary[bin]
        }
        var split = DSPDoubleSplitComplex(realp: fftReal, imagp: fftImaginary)
        vDSP_fft_zripD(setup, &split, 1, 9, FFTDirection(kFFTDirection_Inverse))
        fftTime.withMemoryRebound(to: DSPDoubleComplex.self, capacity: Self.frameSize / 2) { complex in
            vDSP_ztocD(&split, 1, complex, 2, vDSP_Length(Self.frameSize / 2))
        }
        // Hann analysis and synthesis at hop N/8 sum to 3 (periodic window).
        let scale = 1 / (roundTrip * 3)
        let start = (frame + 1) * Self.hop - Self.frameSize
        for index in 0..<Self.frameSize {
            let position = start + index
            guard position >= 0 else { continue }
            overlap[position & 2_047] += fftTime[index] * window[index] * scale
        }
    }

    // MARK: Fuzzy separation (paper section 2)

    private func separateAndProcess(frame: Int) {
        let bins = Self.binCount
        let half = Self.timeMedianLength / 2
        let base = (frame % Self.timeMedianLength) * bins
        var transientEnergy = 0.0
        let analysisLimit = min(bins - 1, Int(cutoff * 1.5 / 8) + 2)
        for bin in 0..<bins {
            // Tonal estimate: median across time; transient: across frequency.
            for offset in 0..<Self.timeMedianLength {
                let slot = (frame - half + offset + Self.timeMedianLength * 4) % Self.timeMedianLength
                scratch[offset] = magnitudes[slot * bins + bin]
            }
            let tonal = Self.median(&scratch, count: Self.timeMedianLength)
            let fHalf = Self.frequencyMedianLength / 2
            var count = 0
            for neighbour in max(0, bin - fHalf)...min(bins - 1, bin + fHalf) {
                scratch[count] = magnitudes[base + neighbour]
                count += 1
            }
            let transient = Self.median(&scratch, count: count)
            let tonal2 = tonal * tonal, transient2 = transient * transient
            let rs = tonal2 + transient2 > 0 ? tonal2 / (tonal2 + transient2) : 0.5
            let rt = 1 - rs
            let rn = 1 - abs(rs - rt).squareRoot()
            let re = spectraReal[base + bin], im = spectraImaginary[base + bin]
            sReal[bin] = re * (rs - rn / 2)
            sImaginary[bin] = im * (rs - rn / 2)
            tReal[bin] = re * (rt - rn / 2)
            tImaginary[bin] = im * (rt - rn / 2)
            if bin <= analysisLimit { transientEnergy += tReal[bin] * tReal[bin] + tImaginary[bin] * tImaginary[bin] }
        }
        // A frame with no transient energy in the bass skips the branch.
        let threshold = Self.amplitudeToMagnitude(0.001) / max(reference, 1e-9)
        if transientEnergy > threshold * threshold {
            overlapAdd(real: tReal, imaginary: tImaginary, frame: frame, into: &transientOverlap)
        }
        if processTones(frame: frame) {
            overlapAdd(real: dReal, imaginary: dImaginary, frame: frame, into: &tonalOverlap)
        }
    }

    /// Peak magnitude of a sinusoid of amplitude `amplitude` in this STFT:
    /// N/4 for the Hann window, twice that in vDSP's packed scaling.
    private static func amplitudeToMagnitude(_ amplitude: Double) -> Double {
        amplitude * Double(frameSize) / 2
    }

    private static func median(_ values: inout [Double], count: Int) -> Double {
        // Insertion sort: at most thirteen values.
        for i in 1..<count {
            let value = values[i]
            var j = i - 1
            while j >= 0, values[j] > value {
                values[j + 1] = values[j]
                j -= 1
            }
            values[j + 1] = value
        }
        return values[count / 2]
    }

    // MARK: Phase vocoder (paper section 4)

    private struct Peak {
        let bin: Double
        let magnitude: Double
    }

    /// Builds the spectral change D(f) = S′(f) − S(f); false when nothing changes.
    private func processTones(frame: Int) -> Bool {
        let bins = Self.binCount
        let binHz = Self.lowRate / Double(Self.frameSize)
        let threshold = Self.amplitudeToMagnitude(0.001) / max(reference, 1e-9)
        var magnitude = toneMagnitude
        toneMagnitude = []
        defer { toneMagnitude = magnitude }
        var peakMaximum = 0.0
        for bin in 0..<bins {
            magnitude[bin] = (sReal[bin] * sReal[bin] + sImaginary[bin] * sImaginary[bin]).squareRoot()
            peakMaximum = max(peakMaximum, magnitude[bin])
        }
        guard peakMaximum > threshold, harmonicGain > 0 else { return false }

        // Relaxed peak picking with parabolic interpolation (on dB values).
        var peaks: [Peak] = []
        let firstBin = max(1, Int((cutoff / 4 / binHz).rounded(.down)))
        let lastBin = min(bins - 2, Int(1_800 / binHz))
        for bin in firstBin...lastBin where magnitude[bin] > threshold
            && magnitude[bin] > magnitude[bin - 1] && magnitude[bin] >= magnitude[bin + 1] {
            let a = 20 * log10(max(magnitude[bin - 1], 1e-12))
            let b = 20 * log10(magnitude[bin])
            let c = 20 * log10(max(magnitude[bin + 1], 1e-12))
            let denominator = a - 2 * b + c
            let offset = denominator != 0 ? 0.5 * (a - c) / denominator : 0
            let peakDB = b - 0.25 * (a - c) * offset
            peaks.append(Peak(bin: Double(bin) + offset, magnitude: pow(10, peakDB / 20)))
        }
        let cutoffBin = cutoff / binHz
        let candidates = peaks.filter { $0.bin >= cutoffBin / 4 && $0.bin < cutoffBin }
        guard let strongest = candidates.max(by: { $0.magnitude < $1.magnitude }) else {
            previousFundamentalBin = 0
            return false
        }
        var fundamental = strongest
        // The previous fundamental holds while it stays comparably strong,
        // so the synthesis does not flip between two candidates (our choice).
        if previousFundamentalBin > 0,
           let held = Self.nearest(candidates, to: previousFundamentalBin),
           abs(held.bin - previousFundamentalBin) < max(1, tolerance * previousFundamentalBin),
           held.magnitude >= strongest.magnitude * 0.5 {
            fundamental = held
        }
        // A candidate that is the second harmonic of a lower peak yields to
        // it, unless that peak is too faint to carry the harmonics: copying
        // a weak region up to the target level raises its noise with it.
        if let lower = candidates.first(where: {
            abs($0.bin * 2 - fundamental.bin) < tolerance * fundamental.bin
                && $0.magnitude >= fundamental.magnitude * 0.25
        }) {
            fundamental = lower
        }
        let f0 = fundamental.bin
        previousFundamentalBin = f0

        // Harmonic orders so that every processed partial lies above f_c (eq. 15).
        let firstOrder: Int
        if f0 >= cutoffBin / 2 { firstOrder = 2 } else if f0 >= cutoffBin / 3 { firstOrder = 3 } else { firstOrder = 4 }
        let orders = firstOrder..<(firstOrder + harmonicCount)

        // Spectral envelope from a Bark-band triangular filter bank (eq. 18).
        var bandValues: [Double] = []
        for (index, center) in barkCenters.enumerated() {
            let low = index > 0 ? barkCenters[index - 1] : 0
            let high = index + 1 < barkCenters.count ? barkCenters[index + 1] : Self.lowRate / 2
            var weighted = 0.0, total = 0.0
            for bin in 0..<bins {
                let f = Double(bin) * binHz
                let weight = f <= center
                    ? (f - low) / max(center - low, 1)
                    : (high - f) / max(high - center, 1)
                guard weight > 0 else { continue }
                weighted += weight * magnitude[bin]
                total += weight
            }
            bandValues.append(20 * log10(max(total > 0 ? weighted / total : 0, 1e-12)))
        }
        func envelopeDB(_ bin: Double) -> Double {
            Self.cubic(barkCenters, bandValues, at: bin * binHz)
        }
        // Scale the envelope to the strongest of f0 and its in-band
        // harmonics below f_c (eq. 19 and the note after it).
        var referenceMagnitude = fundamental.magnitude
        var referenceBin = f0
        for order in 2...3 where Double(order) * f0 < cutoffBin {
            if let peak = Self.nearest(peaks, to: Double(order) * f0), abs(peak.bin - Double(order) * f0) < tolerance * Double(order) * f0,
               peak.magnitude > referenceMagnitude {
                referenceMagnitude = peak.magnitude
                referenceBin = peak.bin
            }
        }
        let anchorDB = 20 * log10(referenceMagnitude)
        let envelopeOffset = anchorDB - envelopeDB(referenceBin)
        let intensityDB = 20 * log10(harmonicGain)

        for bin in 0..<bins {
            dReal[bin] = 0
            dImaginary[bin] = 0
        }
        var changed = false
        let roiHalf = 3.0
        let hopPhase = 2 * Double.pi * Double(Self.hop) / Double(Self.frameSize)
        for order in orders {
            let targetBin = Double(order) * f0
            guard targetBin < Double(bins - 4) else { break }
            // Limited timbre matching (eqs. 20–22). The slopes run per octave
            // from the strongest bass partial, not from the envelope at f_c:
            // the coarse Bark bands put that point 10–20 dB under the bass,
            // which left the harmonics barely audible (our choice).
            let octaves = log2(max(targetBin / referenceBin, 1))
            let lowLimit = anchorDB - alphaLow * octaves
            let highLimit = anchorDB - alphaHigh * octaves
            let envelope = envelopeDB(targetBin) + envelopeOffset
            let weightDB = min(highLimit, max(lowLimit, envelope)) + intensityDB
            let weight = pow(10, weightDB / 20)

            if let peak = Self.nearest(peaks, to: targetBin), abs(peak.bin - targetBin) < tolerance * targetBin {
                // Detected: rescale its region, phase untouched (eq. 23).
                // Only ever raised: an enhancer that thins existing
                // harmonics takes away the bass it is meant to add.
                let factor = max(1, weight / peak.magnitude) - 1
                guard factor > 0 else { continue }
                let low = Int((peak.bin - roiHalf).rounded(.up)), high = Int((peak.bin + roiHalf).rounded(.down))
                for bin in max(0, low)...min(bins - 1, high) {
                    let w = Self.roi(Double(bin) - peak.bin) * factor
                    dReal[bin] += sReal[bin] * w
                    dImaginary[bin] += sImaginary[bin] * w
                }
                changed = true
            } else {
                // Missing: shift the fundamental's region up to k·f0 (eq. 25)
                // with its phase advanced by the shift per hop (eq. 24).
                let shift = targetBin - f0
                let rotation = hopPhase * shift
                let zr = phaseReal[order] * cos(rotation) - phaseImaginary[order] * sin(rotation)
                let zi = phaseReal[order] * sin(rotation) + phaseImaginary[order] * cos(rotation)
                let norm = (zr * zr + zi * zi).squareRoot()
                phaseReal[order] = zr / max(norm, 1e-12)
                phaseImaginary[order] = zi / max(norm, 1e-12)
                // At most 12 dB above the fundamental's own region.
                let gain = min(4, weight / max(fundamental.magnitude, 1e-12))
                let low = Int((targetBin - roiHalf).rounded(.up)), high = Int((targetBin + roiHalf).rounded(.down))
                for bin in max(1, low)...min(bins - 2, high) {
                    let source = Double(bin) - shift
                    let window = Self.roi(source - f0)
                    guard window > 0 else { continue }
                    let value = lagrange(at: source)
                    let shiftedReal = (value.re * phaseReal[order] - value.im * phaseImaginary[order]) * gain * window
                    let shiftedImaginary = (value.re * phaseImaginary[order] + value.im * phaseReal[order]) * gain * window
                    // Replace whatever was at the harmonic's place (eq. 26).
                    let existing = Self.roi(Double(bin) - targetBin)
                    dReal[bin] += shiftedReal - sReal[bin] * existing
                    dImaginary[bin] += shiftedImaginary - sImaginary[bin] * existing
                }
                changed = true
            }
        }
        return changed
    }

    /// Third-order Lagrange interpolation of the tonal spectrum between bins.
    private func lagrange(at position: Double) -> (re: Double, im: Double) {
        let bins = Self.binCount
        let base = Int(position.rounded(.down)) - 1
        let t = position - Double(base)
        var re = 0.0, im = 0.0
        for j in 0..<4 {
            var weight = 1.0
            for m in 0..<4 where m != j { weight *= (t - Double(m)) / Double(j - m) }
            let bin = min(bins - 1, max(0, base + j))
            re += sReal[bin] * weight
            im += sImaginary[bin] * weight
        }
        return (re, im)
    }

    /// Tukey region of interest: flat over ±1.5 bins, tapering to ±3, a
    /// little wider than the Hann main lobe.
    private static func roi(_ distance: Double) -> Double {
        let d = abs(distance)
        if d <= 1.5 { return 1 }
        if d >= 3 { return 0 }
        return 0.5 * (1 + cos(Double.pi * (d - 1.5) / 1.5))
    }

    private static func nearest(_ peaks: [Peak], to bin: Double) -> Peak? {
        peaks.min { abs($0.bin - bin) < abs($1.bin - bin) }
    }

    /// Cubic interpolation of band values (Catmull–Rom), held at the ends.
    private static func cubic(_ xs: [Double], _ ys: [Double], at x: Double) -> Double {
        guard let first = xs.first, let last = xs.last else { return 0 }
        if x <= first { return ys[0] }
        if x >= last { return ys[ys.count - 1] }
        var index = 0
        while index + 1 < xs.count, xs[index + 1] < x { index += 1 }
        let p0 = ys[max(0, index - 1)], p1 = ys[index], p2 = ys[index + 1], p3 = ys[min(ys.count - 1, index + 2)]
        let t = (x - xs[index]) / (xs[index + 1] - xs[index])
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }
}

/// Node wrapper: the engine runs on the mid signal and its output joins
/// every selected channel's delayed dry signal.
nonisolated struct DSPHybridBassKernel: DSPBlockKernel {
    private var engine: DSPHybridBassEngine?
    private let parameters: DSPHybridBassParameters
    private let outputKind: DSPOutputKind?
    private let sampleRate: Double
    private let selectedChannels: [Int]
    private var dryDelay: [Double]
    private var dryCursor = 0
    private var dryHighPass: [DSPBiquad]
    private let tightensDryBass: Bool
    private let outputGain: Double
    private var reference = 1.0
    let latencyFrames: Int

    var stateBytes: Int { dryDelay.count * 8 + (engine?.stateBytes ?? 0) }

    init?(format: DSPAudioFormat, selectedChannels mask: [Bool], parameters: DSPHybridBassParameters,
          outputKind: DSPOutputKind?) {
        guard mask.count == format.channelCount,
              let engine = DSPHybridBassEngine(sampleRate: format.sampleRate, parameters: parameters,
                                               outputKind: outputKind) else { return nil }
        selectedChannels = mask.indices.filter { mask[$0] }
        guard !selectedChannels.isEmpty else { return nil }
        let tuning = parameters.resolvedCutoff(for: outputKind)
        guard let highPass = DSPFilterDesign.section(.highPass, frequencyHz: tuning.cutoffHz * 0.7,
                                                     sampleRate: format.sampleRate) else { return nil }
        self.engine = engine
        self.parameters = parameters
        self.outputKind = outputKind
        sampleRate = format.sampleRate
        latencyFrames = engine.latencyFrames
        dryDelay = Array(repeating: 0, count: max(1, engine.latencyFrames) * selectedChannels.count)
        dryHighPass = Array(repeating: DSPBiquad(highPass), count: selectedChannels.count)
        switch parameters.tightenDryBass {
        case .automatic: tightensDryBass = tuning.kind == .speakers
        case .on: tightensDryBass = true
        case .off: tightensDryBass = false
        }
        outputGain = pow(10, parameters.outputTrimDB / 20)
    }

    func makeFreshState() -> DSPHybridBassKernel {
        var fresh = self
        fresh.engine = engine?.makeFresh(sampleRate: sampleRate, parameters: parameters, outputKind: outputKind)
        fresh.dryDelay = Array(repeating: 0, count: dryDelay.count)
        fresh.dryCursor = 0
        for index in fresh.dryHighPass.indices { fresh.dryHighPass[index].reset() }
        return fresh
    }

    mutating func copyState(from source: DSPHybridBassKernel) {
        if let engine, let other = source.engine, engine !== other { engine.copyState(from: other) }
        if dryDelay.count == source.dryDelay.count {
            DSPStateCopy.assign(&dryDelay, from: source.dryDelay)
            dryCursor = source.dryCursor
        }
        if dryHighPass.count == source.dryHighPass.count {
            for index in dryHighPass.indices { dryHighPass[index].copyState(from: source.dryHighPass[index]) }
        }
    }

    mutating func reset() {
        engine?.reset()
        DSPStateCopy.clear(&dryDelay)
        dryCursor = 0
        for index in dryHighPass.indices { dryHighPass[index].reset() }
    }

    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        guard offsetDB.isFinite else { return }
        reference = pow(10, -offsetDB / 20)
        engine?.setProgramLevel(reference: reference)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        guard let engine else { return }
        let count = selectedChannels.count
        let delayFrames = dryDelay.count / count
        for frame in 0..<frames {
            let base = frame * channels
            var mid = 0.0
            for index in 0..<count { mid += samples[base + selectedChannels[index]] }
            mid /= Double(count)
            let generated = engine.process(mid: mid)
            let slot = dryCursor * count
            for index in 0..<count {
                let channel = base + selectedChannels[index]
                var dry = samples[channel]
                if tightensDryBass { dry = dryHighPass[index].process(dry) }
                let delayed = dryDelay[slot + index]
                dryDelay[slot + index] = dry
                samples[channel] = (delayed + generated) * outputGain
            }
            dryCursor = dryCursor + 1 == delayFrames ? 0 : dryCursor + 1
        }
    }

    static func staticPeakResponseDB(parameters: DSPHybridBassParameters) -> Double {
        20 * log10(1 + parameters.intensity) + parameters.outputTrimDB
    }
}

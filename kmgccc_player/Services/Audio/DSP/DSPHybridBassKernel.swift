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
/// - Transients: the isolated bass uses the classic level-normalized
///   analytic series, adding only its harmonics. Its level follows the
///   attack instead of collapsing quadratically on quiet kicks.
/// - Tones: the STFT finds f0 below f_c (rejecting a second harmonic of a
///   lower peak). Target levels for k·f0 follow a Bark-band spectral
///   envelope held between two slopes, α_low and α_high dB per octave.
///   Existing harmonics are raised in their own phase (paper eq. 23).
///   Missing harmonics use one Hann main lobe at k·f0, locked to the
///   fundamental's phase. A separate 1024-point analysis resolves nearby
///   bass notes; phase advance refines its frequency between frames.
///   It uses history and lookahead already available to the separator,
///   without adding latency. Unlike the paper's shifted spectral regions,
///   one partial does not copy nearby notes to inharmonic frequencies.
/// - Noise: untouched.
///
/// Only the harmonic addition is synthesized and resampled back. The
/// delayed original and addition share an independently controlled shelf.
/// The selected cutoff controls the source band, with a 10% transition
/// above it. Consecutive partials start in the target's audible bass band
/// and roll off at a cutoff-dependent upper limit, at most 800 Hz.
///
/// Our choices where the paper gives no number: median lengths of 13 frames
/// and 9 bins; IIR instead of order-500 FIR band filters, which saves about
/// 60 ms; analytic rather than half-wave transient shaping; an
/// analysis threshold 60 dB below programme full scale; harmonics are only
/// added, never cut or replaced; the timbre limits are anchored at the
/// first audible generated partial, at the observed bass level; a fundamental
/// holds across frames while it stays within 6 dB of the strongest candidate,
/// and a lower-octave candidate
/// must be within 12 dB of it. Timbre slopes and a gentle order ceiling bound
/// the added series. The phase history uses the common window centre, so
/// a nearest-bin change does not silence a stable tone.
nonisolated final class DSPHybridBassEngine {
    static let lowRate = 4_096.0
    static let frameSize = 512
    static let tonalFrameSize = 1_024
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
    private let harmonicTop: Double
    private let harmonicFloor: Double
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
    private var lowRing = [Double](repeating: 0, count: 2_048)
    private var lowCount = 0
    private let window: [Double]
    private let tonalWindow: [Double]
    private var fundamentalMagnitudes = [Double](repeating: 0, count: DSPHybridBassEngine.tonalFrameSize / 2 + 1)
    private var spectraReal: [Double]
    private var spectraImaginary: [Double]
    private var magnitudes: [Double]
    private var frameCount = 0
    private var transientOverlap = [Double](repeating: 0, count: 2_048)
    private var tonalOverlap = [Double](repeating: 0, count: 2_048)
    private var generated = [Double](repeating: 0, count: 256)
    private var synthesizedCount = 0
    private var transientHarmonics: DSPClassicBassKernel
    /// Fundamental of the last tonal frame, 0 when there was none.
    private var previousFundamentalBin = 0.0
    private var previousTonalFrame = -1
    private var previousTonalPhase = 0.0

    // FFT.
    private let setup: FFTSetupD
    private let tonalSetup: FFTSetupD
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
        (midRing.count + lowRing.count + spectraReal.count * 3 + transientOverlap.count * 2
            + fundamentalMagnitudes.count + Self.tonalFrameSize * 2) * 8 + transientHarmonics.stateBytes
    }

    init?(sampleRate: Double, parameters: DSPHybridBassParameters, outputKind: DSPOutputKind?) {
        guard sampleRate.isFinite, sampleRate >= 8_192,
              let setup = DSPFFTSetups.setup(log2n: 9),
              let tonalSetup = DSPFFTSetups.setup(log2n: 10),
              let productScale = DSPConvolutionLevel.productScale(setup: setup, log2n: 9) else { return nil }
        self.setup = setup
        self.tonalSetup = tonalSetup
        roundTrip = 1 / (2 * productScale)
        let tuning = parameters.resolvedCutoff(for: outputKind)
        let sourceCutoff = min(tuning.cutoffHz, DSPBassProfile.maximumHarmonicFundamentalHz)
        self.cutoff = sourceCutoff
        harmonicTop = DSPBassProfile.harmonicTop(cutoffHz: sourceCutoff)
        harmonicFloor = max(30, min(sourceCutoff, DSPBassProfile.profile(for: tuning.kind).cutoffHz))
        harmonicCount = Int(parameters.harmonicCount.rounded())
        tolerance = parameters.harmonicTolerance
        alphaLow = parameters.timbreLowDBPerOctave
        alphaHigh = parameters.timbreHighDBPerOctave
        // Virtual harmonics must be audible with the independent shelf off.
        harmonicGain = 0.7 * parameters.intensity
        transientGain = parameters.transient * min(parameters.intensity, 1)

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
        tonalWindow = (0..<Self.tonalFrameSize).map {
            0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.tonalFrameSize))
        }
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

        var transientParameters = DSPClassicBassParameters()
        transientParameters.target = parameters.target
        transientParameters.bassGainDB = 0
        transientParameters.intensity = 1
        transientParameters.cutoffHz = sourceCutoff
        transientParameters.floorHz = DSPBassProfile.minimumHarmonicFundamentalHz
        transientParameters.tightenDryBass = .off
        let lowFormat = DSPAudioFormat(sampleRate: Self.lowRate, channelCount: 1, rawLayoutData: nil,
                                      channelLabels: nil, layoutIsKnown: false)
        guard let generator = DSPClassicBassKernel(format: lowFormat, selectedChannels: [true],
                                                   parameters: transientParameters, outputKind: outputKind) else { return nil }
        transientHarmonics = generator

        fftReal = .allocate(capacity: Self.tonalFrameSize / 2)
        fftImaginary = .allocate(capacity: Self.tonalFrameSize / 2)
        fftTime = .allocate(capacity: Self.tonalFrameSize)
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
        fresh?.setProgramLevel(reference: reference)
        return fresh
    }

    func setProgramLevel(reference: Double) {
        self.reference = reference
        transientHarmonics.setProgramLevelOffset(dB: -20 * log10(max(reference, 1e-9)))
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
        transientHarmonics.copyState(from: source.transientHarmonics)
        previousFundamentalBin = source.previousFundamentalBin
        previousTonalFrame = source.previousTonalFrame
        previousTonalPhase = source.previousTonalPhase
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
        transientHarmonics.reset()
        previousFundamentalBin = 0
        previousTonalFrame = -1
        previousTonalPhase = 0
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
        lowRing[lowCount & (lowRing.count - 1)] = value
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
        // A normalized harmonic series follows quiet kicks as well as loud
        // ones. Subtract the unprocessed transient: this branch adds only
        // harmonics, with no negative fundamental from a tanh tangent.
        var addedTransient = 0.0
        if transientGain > 0 {
            addedTransient = transientHarmonics.processTransientHarmonic(sample: transient) * transientGain
        }
        generated[index & (generated.count - 1)] = addedTransient + tonal
        synthesizedCount = index + 1
    }

    private func analyseFrame() {
        let size = Self.frameSize
        let bins = Self.binCount
        // Newest frame: the last 512 low-rate samples, windowed.
        for index in 0..<size {
            fftTime[index] = lowRing[(lowCount - size + index) & (lowRing.count - 1)] * window[index]
        }
        forwardTransform(size: size, setup: setup, log2n: 9)
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

    private func forwardTransform(size: Int, setup: FFTSetupD, log2n: vDSP_Length) {
        var split = DSPDoubleSplitComplex(realp: fftReal, imagp: fftImaginary)
        fftTime.withMemoryRebound(to: DSPDoubleComplex.self, capacity: size / 2) { complex in
            vDSP_ctozD(complex, 2, &split, 1, vDSP_Length(size / 2))
        }
        vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
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

    /// The separator already waits six hops past a frame. That is enough
    /// future PCM for a longer, centred pitch analysis, while the 2048-sample
    /// ring retains its earlier half. Synthesis still uses 512 samples.
    private func analyseFundamental(frame: Int, threshold: Double, tonalMagnitude: [Double])
        -> (peak: Peak, centrePhase: Double, coherent: Bool)? {
        let size = Self.tonalFrameSize
        let start = (frame + 1) * Self.hop - Self.frameSize / 2 - size / 2
        for index in 0..<size {
            fftTime[index] = lowRing[(start + index) & (lowRing.count - 1)] * tonalWindow[index]
        }
        forwardTransform(size: size, setup: tonalSetup, log2n: 10)
        // Express long-window peaks in the short STFT's bin and level units.
        let binScale = Double(Self.frameSize) / Double(size)
        for bin in fundamentalMagnitudes.indices {
            let re = bin == fundamentalMagnitudes.count - 1 ? fftImaginary[0] : fftReal[bin]
            let im = bin == 0 || bin == fundamentalMagnitudes.count - 1 ? 0 : fftImaginary[bin]
            fundamentalMagnitudes[bin] = (re * re + im * im).squareRoot() * binScale
        }
        let binHz = Self.lowRate / Double(size)
        let floorBin = DSPBassProfile.minimumHarmonicFundamentalHz / (Self.lowRate / Double(Self.frameSize))
        let cutoffBin = cutoff * 1.1 / (Self.lowRate / Double(Self.frameSize))
        let first = max(1, Int((DSPBassProfile.minimumHarmonicFundamentalHz / binHz).rounded(.down)))
        let last = min(fundamentalMagnitudes.count - 2, Int((cutoff * 1.1 / binHz).rounded(.up)))
        let base = (frame % Self.timeMedianLength) * Self.binCount
        var candidates: [Peak] = []
        for peak in Self.peaks(fundamentalMagnitudes, first: first, last: last, threshold: threshold,
                               binScale: binScale) where peak.bin >= floorBin && peak.bin < cutoffBin {
            let bin = min(Self.binCount - 1, max(0, Int(peak.bin.rounded())))
            let tonalFraction = tonalMagnitude[bin] / max(magnitudes[base + bin], 1e-12)
            // A percussive or noisy peak must not become a pitched oscillator.
            guard tonalFraction >= 0.5 else { continue }
            candidates.append(Peak(bin: peak.bin, magnitude: peak.magnitude * min(1, tonalFraction)))
        }
        guard let strongest = candidates.max(by: { $0.magnitude < $1.magnitude }) else {
            previousFundamentalBin = 0
            previousTonalFrame = -1
            return nil
        }
        var fundamental = strongest
        if previousFundamentalBin > 0,
           let held = Self.nearest(candidates, to: previousFundamentalBin),
           abs(held.bin - previousFundamentalBin) < max(0.5, tolerance * previousFundamentalBin),
           held.magnitude >= strongest.magnitude * 0.5 {
            fundamental = held
        }
        for order in [3.0, 2.0] {
            if let lower = candidates.first(where: {
                abs($0.bin * order - fundamental.bin) < tolerance * fundamental.bin
                    && $0.magnitude >= fundamental.magnitude * 0.25
            }) {
                fundamental = lower
                break
            }
        }
        let peakBin = Int((fundamental.bin / binScale).rounded())
        let phase = atan2(fftImaginary[peakBin], fftReal[peakBin])
        let centrePhase = phase + (peakBin.isMultiple(of: 2) ? 0 : Double.pi)
        let continues = previousTonalFrame + 1 == frame && previousFundamentalBin > 0
            && abs(fundamental.bin - previousFundamentalBin) < max(0.5, tolerance * fundamental.bin)
        var coherent = false
        if continues {
            // Instantaneous frequency from the phase advance. Parabolic
            // magnitudes alone are biased between bins and wobble when
            // another bass note enters the same short-window main lobe.
            // Compare phases at the common window centre. The nearest FFT
            // bin can alternate for a perfectly stable half-bin tone; raw
            // bin phases differ by pi and must not reset its coherence.
            let expected = 2 * Double.pi * Double(Self.hop) * previousFundamentalBin / Double(Self.frameSize)
            let difference = centrePhase - previousTonalPhase - expected
            let residual = atan2(sin(difference), cos(difference))
            let refined = previousFundamentalBin + residual * Double(Self.frameSize) / (2 * Double.pi * Double(Self.hop))
            if abs(refined - fundamental.bin) < 0.5 * binScale,
               refined >= floorBin, refined < cutoffBin {
                fundamental = Peak(bin: refined, magnitude: fundamental.magnitude)
                coherent = true
            }
        }
        previousFundamentalBin = fundamental.bin
        previousTonalFrame = frame
        previousTonalPhase = centrePhase
        return (fundamental, centrePhase, coherent)
    }

    private static func peaks(_ magnitude: [Double], first: Int, last: Int, threshold: Double,
                              binScale: Double = 1) -> [Peak] {
        var peaks: [Peak] = []
        for bin in first...last where magnitude[bin] > threshold
            && magnitude[bin] > magnitude[bin - 1] && magnitude[bin] >= magnitude[bin + 1] {
            let a = 20 * log10(max(magnitude[bin - 1], 1e-12))
            let b = 20 * log10(magnitude[bin])
            let c = 20 * log10(max(magnitude[bin + 1], 1e-12))
            let denominator = a - 2 * b + c
            let offset = denominator != 0 ? 0.5 * (a - c) / denominator : 0
            let peakDB = b - 0.25 * (a - c) * offset
            peaks.append(Peak(bin: (Double(bin) + offset) * binScale, magnitude: pow(10, peakDB / 20)))
        }
        return peaks
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

        // Short-window peaks retain the phase of existing upper harmonics.
        let firstBin = max(1, Int((DSPBassProfile.minimumHarmonicFundamentalHz / binHz).rounded(.down)))
        let lastBin = min(bins - 2, Int(1_800 / binHz))
        let peaks = Self.peaks(magnitude, first: firstBin, last: lastBin, threshold: threshold)
        let cutoffBin = cutoff / binHz
        guard let analysis = analyseFundamental(frame: frame, threshold: threshold, tonalMagnitude: magnitude) else {
            return false
        }
        let fundamental = analysis.peak
        let f0 = fundamental.bin
        // Keep the complete requested band active. Fade in a short shoulder
        // above it, rather than muting notes at the selected cutoff itself.
        let edge = min(1, max(0, (f0 / cutoffBin - 1) / 0.1))
        let bandGain = harmonicGain * 0.5 * (1 + cos(Double.pi * edge))
        guard bandGain > 0 else { return false }

        // Consecutive partials above the transducer turnover convey the
        // missing pitch. Always starting at order 2 wasted most of the series
        // below that turnover on deep bass notes.
        let firstOrder = max(2, Int((harmonicFloor / (f0 * binHz)).rounded(.up)))
        let orders = firstOrder..<(firstOrder + harmonicCount)
        let firstHarmonicBin = Double(firstOrder) * f0

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
        let intensityDB = 20 * log10(max(bandGain, 1e-12))

        for bin in 0..<bins {
            dReal[bin] = 0
            dImaginary[bin] = 0
        }
        var changed = false
        for order in orders {
            let targetBin = Double(order) * f0
            guard targetBin < min(Double(bins - 4), harmonicTop / binHz) else { break }
            // Anchor the audible series to the observed bass level. Starting
            // both slopes at f0 and then applying another order-squared cap
            // penalized the first useful harmonic twice on deep notes.
            let octaves = log2(max(targetBin / max(referenceBin, firstHarmonicBin), 1))
            let lowLimit = anchorDB - alphaLow * octaves
            let highLimit = anchorDB - alphaHigh * octaves
            let envelope = envelopeDB(targetBin) + envelopeOffset
            let weightDB = min(highLimit, max(lowLimit, envelope)) + intensityDB
            // Bound the series to the observed bass and the selected amount,
            // even when the envelope includes unrelated instruments or voices.
            let orderScale = Double(order) / Double(firstOrder)
            let maximum = fundamental.magnitude * bandGain / orderScale.squareRoot()
            let weight = min(pow(10, weightDB / 20), maximum)

            let nearbyPeak = Self.nearest(peaks, to: targetBin)
            if let peak = nearbyPeak, abs(peak.bin - targetBin) < min(0.75, tolerance * targetBin) {
                // Adding a new sinusoid in k·phi0 can cancel an existing
                // harmonic. Raise its own complex spectrum instead (eq. 23),
                // with at most 12 dB boost and a narrow region of influence.
                let factor = min(3, max(0, weight / peak.magnitude - 1))
                guard factor > 0 else { continue }
                let low = Int((peak.bin - 1.5).rounded(.up))
                let high = Int((peak.bin + 1.5).rounded(.down))
                for bin in max(1, low)...min(bins - 2, high) {
                    let gain = factor * Self.roi(Double(bin) - peak.bin)
                    dReal[bin] += sReal[bin] * gain
                    dImaginary[bin] += sImaginary[bin] * gain
                }
                changed = true
                continue
            }
            // One coherent bass observation precedes a new pitched partial.
            // Leave a neighbouring independent tone alone rather than laying
            // a second, slightly detuned oscillator over it.
            guard analysis.coherent else { continue }
            if let peak = nearbyPeak, abs(peak.bin - targetBin) < 2, peak.magnitude > weight * 0.25 {
                continue
            }

            // Only the shortfall is added: a harmonic already present at
            // the target level is left as it is, and nothing is removed.
            let nearestBin = min(bins - 1, Int(targetBin.rounded()))
            let present = magnitude[nearestBin] / max(Self.hannLobe(Double(nearestBin) - targetBin), 0.5)
            let added = weight - present
            guard added > 0 else { continue }

            // One clean partial at k·f0 with phase k·φ0: the Hann main lobe
            // written straight into the spectrum, phase-locked to the
            // fundamental frame by frame like a waveshaper's harmonic. A
            // copied region would carry every other component near f0 up
            // with it, shifted by a fixed number of hertz into inharmonic
            // places, which is heard as mud (our choice over eqs. 23–26).
            let phase = Double(order) * analysis.centrePhase
            let cosine = cos(phase), sine = sin(phase)
            let low = Int((targetBin - 2).rounded(.up)), high = Int((targetBin + 2).rounded(.down))
            for bin in max(1, low)...min(bins - 2, high) {
                let lobe = added * Self.hannLobe(Double(bin) - targetBin) * (bin % 2 == 0 ? 1 : -1)
                dReal[bin] += lobe * cosine
                dImaginary[bin] += lobe * sine
            }
            changed = true
        }
        return changed
    }

    private static func roi(_ distance: Double) -> Double {
        let d = abs(distance)
        if d <= 0.5 { return 1 }
        if d >= 1.5 { return 0 }
        return 0.5 * (1 + cos(Double.pi * (d - 0.5)))
    }

    /// Transform of the periodic Hann window, offset `d` bins from the tone,
    /// normalized to 1 at the tone: sinc(d)/(1 − d²), zero at ±2.
    private static func hannLobe(_ d: Double) -> Double {
        let x = abs(d)
        if x < 1e-9 { return 1 }
        if abs(x - 1) < 1e-9 { return 0.5 }
        if x >= 2 { return 0 }
        return sin(Double.pi * x) / (Double.pi * x * (1 - x * x))
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
    private var bassShelf: [DSPBiquad]
    private let tightensDryBass: Bool
    private let outputGain: Double
    private let peakCeiling: Double?
    private var reference = 1.0
    let latencyFrames: Int

    var stateBytes: Int { dryDelay.count * 8 + (engine?.stateBytes ?? 0) }
    var keepsReferenceState: Bool { engine != nil }

    init?(format: DSPAudioFormat, selectedChannels mask: [Bool], parameters: DSPHybridBassParameters,
          outputKind: DSPOutputKind?, outputCeiling: Double? = nil) {
        guard mask.count == format.channelCount else { return nil }
        let engine: DSPHybridBassEngine?
        if parameters.intensity > 0 {
            guard let prepared = DSPHybridBassEngine(sampleRate: format.sampleRate, parameters: parameters,
                                                      outputKind: outputKind) else { return nil }
            engine = prepared
        } else {
            engine = nil
        }
        selectedChannels = mask.indices.filter { mask[$0] }
        guard !selectedChannels.isEmpty else { return nil }
        let tuning = parameters.resolvedCutoff(for: outputKind)
        guard let highPass = DSPFilterDesign.section(.highPass, frequencyHz: tuning.cutoffHz * 0.8,
                                                     sampleRate: format.sampleRate),
              let shelf = DSPFilterDesign.section(.lowShelf, frequencyHz: tuning.cutoffHz, sampleRate: format.sampleRate,
                                                 q: 1, gainDB: parameters.bassGainDB) else { return nil }
        self.engine = engine
        self.parameters = parameters
        self.outputKind = outputKind
        sampleRate = format.sampleRate
        latencyFrames = engine?.latencyFrames ?? 0
        dryDelay = Array(repeating: 0, count: max(1, latencyFrames) * selectedChannels.count)
        dryHighPass = Array(repeating: DSPBiquad(highPass), count: selectedChannels.count)
        bassShelf = Array(repeating: DSPBiquad(shelf), count: selectedChannels.count)
        switch parameters.tightenDryBass {
        case .automatic: tightensDryBass = false
        case .on: tightensDryBass = true
        case .off: tightensDryBass = false
        }
        let gain = pow(10, parameters.outputTrimDB / 20)
        outputGain = gain
        peakCeiling = outputCeiling.map { $0 / gain }
    }

    func makeFreshState() -> DSPHybridBassKernel {
        var fresh = self
        fresh.engine = engine?.makeFresh(sampleRate: sampleRate, parameters: parameters, outputKind: outputKind)
        fresh.dryDelay = Array(repeating: 0, count: dryDelay.count)
        fresh.dryCursor = 0
        for index in fresh.dryHighPass.indices { fresh.dryHighPass[index].reset() }
        for index in fresh.bassShelf.indices { fresh.bassShelf[index].reset() }
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
        if bassShelf.count == source.bassShelf.count {
            for index in bassShelf.indices { bassShelf[index].copyState(from: source.bassShelf[index]) }
        }
    }

    mutating func reset() {
        engine?.reset()
        DSPStateCopy.clear(&dryDelay)
        dryCursor = 0
        for index in dryHighPass.indices { dryHighPass[index].reset() }
        for index in bassShelf.indices { bassShelf[index].reset() }
    }

    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        guard offsetDB.isFinite else { return }
        reference = pow(10, -offsetDB / 20)
        engine?.setProgramLevel(reference: reference)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        let count = selectedChannels.count
        let delayFrames = dryDelay.count / count
        let intensity = parameters.intensity
        let dryDucking = tightensDryBass ? 0.68 : (1.0 / (1.0 + 0.45 * min(intensity, 2.0)))
        let wetCeiling = 0.32

        for frame in 0..<frames {
            let base = frame * channels
            var mid = 0.0
            for index in 0..<count { mid += samples[base + selectedChannels[index]] }
            mid /= Double(count)
            let rawGenerated = engine?.process(mid: mid) ?? 0
            let scaledGenerated = wetCeiling * tanh(rawGenerated / wetCeiling)

            let slot = dryCursor * count
            for index in 0..<count {
                let channel = base + selectedChannels[index]
                var dry = samples[channel]
                if tightensDryBass { dry = dryHighPass[index].process(dry) }
                let delayed: Double
                if latencyFrames > 0 {
                    delayed = dryDelay[slot + index]
                    dryDelay[slot + index] = dry
                } else {
                    delayed = dry
                }
                let dryWithShelf = bassShelf[index].coefficients != .identity ? bassShelf[index].process(delayed) : delayed
                let enhanced = dryWithShelf * dryDucking + scaledGenerated
                samples[channel] = DSPBassPeakControl.mix(original: delayed, enhanced: enhanced, ceiling: peakCeiling) * outputGain
            }
            dryCursor = dryCursor + 1 == delayFrames ? 0 : dryCursor + 1
        }
    }

    static func staticPeakResponseDB(parameters: DSPHybridBassParameters) -> Double {
        // An additive bass effect must not pre-attenuate vocals and treble.
        parameters.outputTrimDB
    }
}

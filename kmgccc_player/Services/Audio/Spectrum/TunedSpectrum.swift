//
//  TunedSpectrum.swift
//  myPlayer2
//
//  kmgccc_player - Tuned MRU spectrum, streaming form.
//
//  Replaces the old nine-band heuristic processor. The math is the locked
//  chain reverse-engineered from the iPhone Dynamic Island recordings and
//  fitted against eight 60fps captures (docs: ios-mru-waveform/
//  TUNED_ALGORITHM.md). Nothing here is adaptive-by-ear: every constant is
//  the fitted one.
//
//  Signal flow, per tick (one 2048-point Hann FFT, shared by every band count):
//
//    2048-point Hann FFT  -> six Apple bands      (20-81-170-527-1500-4500-10000)
//                        -> n bands, n > 6: the same spectrum, bin-aligned and
//                           split per band; a band that is a whole Apple band
//                           keeps Apple's own value
//        acc_i = density_i * parentBinCount / windowCalibration[parent]
//        v_i   = clip((acc_i * g(f_i)) ^ e(f_i), 0, 1)
//            g/e/K are the six fitted constants, smoothstep-interpolated in log f
//
//    attack boost (per band):
//        ref   = 0.5*v + 0.3*v[t-1] + 0.2*v[t-2]
//        rise  = max(0, v - ref), soft deadband 0.01..0.06
//        gate  = clamp(1 - slow/0.35, 0, 1),  slow = 0.8 s one-pole
//        out   = clip(v + (K*gate + 1.05) * rise * shape, 0, 1)
//
//  The display spring is NOT here: every surface already owns one
//  (CapsuleSpectrumDynamics). This class publishes the pre-spring target.
//
//  Band count: surfaces ask for 9 (< = baseline) or 36 (adaptive sub-bands),
//  and resample further themselves. The low edge moves to 40 Hz above six
//  bands because 20-40 Hz is empty in every reference track, and each band is
//  capped by the number of FFT bins it actually contains.
//

import Foundation

// MARK: - Chain constants

/// The locked tuned parameters. Do not retune these in the app — they are
/// fitted against the reference recordings.
nonisolated enum TunedSpectrumParameters {
    /// Per-band gain, fitted on the six Apple bands.
    static let gains: [Double] = [0.706, 0.706, 0.433, 0.433, 0.339, 0.300]
    /// Per-band display exponent.
    static let exponents: [Double] = [1.15, 0.85, 0.75, 0.85, 0.70, 0.75]
    /// Attack-boost peak gain per band.
    static let punch: [Double] = [3.45, 2.07, 3.45, 11.5, 1.38, 1.38]

    /// Reference envelope kernel (tick-aligned: current, -1, -2).
    static let referenceKernel: [Double] = [0.5, 0.3, 0.2]
    /// Floor of the attack boost.
    static let punchBase: Double = 1.05
    /// Level below which the boost fades out (slow envelope / gateLo).
    static let gateLow: Double = 0.35
    /// Time constant of the slow envelope used by the gate.
    static let slowTau: Double = 0.8
    /// Soft deadband on the rise: below `low` no boost, above `high` full.
    static let deadbandLow: Double = 0.01
    static let deadbandHigh: Double = 0.06

    /// Display low edge once the count exceeds six bands.
    static let multiBandLowEdge: Double = 40

    /// Front-end calibration from the 2048-point window back onto the numbers the
    /// six-band curve was fitted on (the 1024-point window Apple uses).
    ///
    /// Summing |X| over a band counts bins; halving the bin width doubles the bin
    /// count in every band, so the same music returns a bigger sum. Solved per
    /// band on the eight reference tracks so the *displayed* six-bar mean matches
    /// the 1024-point path band for band (the chains are per-band independent, so
    /// each constant is a 1-D root find). Band 1 lands below its raw ratio because
    /// the 1024-point window inflates it with leakage from the band below.
    ///
    ///     raw ratio   1.879  2.079  1.374  1.345  1.393  1.419
    ///     solved      1.828  1.765  1.324  1.351  1.369  1.424
    ///
    /// Six-bar means, 8 tracks: 0.354 0.327 0.608 0.581 0.495 0.311 — identical
    /// on both front ends.
    static let windowCalibration: [Double] = [1.828, 1.765, 1.324, 1.351, 1.369, 1.424]
}

// MARK: - One band-count chain

/// State for one band count: three ticks of history, the slow gate envelope,
/// and the per-band calibration resolved at the layout's band centres.
nonisolated final class TunedSpectrumChain {
    let bandCount: Int
    private let layout: BandLayout
    private let gain: [Double]
    private let exponent: [Double]
    private let punch: [Double]

    /// Latest three pre-boost values, newest first.
    private var history: [[Double]]
    private var slow: [Double]
    private(set) var output: [Float]

    init(bandCount: Int, binWidth: Double) {
        self.bandCount = bandCount
        self.layout = BandLayout.make(
            count: bandCount,
            binWidth: binWidth,
            lowEdge: TunedSpectrumParameters.multiBandLowEdge
        )
        let centres = layout.centres
        self.gain = centres.map { BandLayout.smoothCal(TunedSpectrumParameters.gains, at: $0) }
        self.exponent = centres.map { BandLayout.smoothCal(TunedSpectrumParameters.exponents, at: $0) }
        self.punch = centres.map { BandLayout.smoothCal(TunedSpectrumParameters.punch, at: $0) }

        let n = max(1, layout.count)
        self.history = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        self.slow = [Double](repeating: 0, count: n)
        self.output = [Float](repeating: 0, count: n)
    }

    var bandLayout: BandLayout { layout }

    /// Consume one tick of band energy and advance the chain.
    func step(acc: [Double], dt: Double) {
        let n = output.count

        // 1. Normalize each band on its own (no shared contour).
        var value = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let raw = acc[i] * gain[i]
            value[i] = min(1.0, max(0.0, pow(max(0.0, raw), exponent[i])))
        }

        // 2. Slow envelope for the gate, advanced in real time.
        let alpha = 1.0 - exp(-max(0.001, min(0.2, dt)) / TunedSpectrumParameters.slowTau)
        for i in 0..<n { slow[i] += (value[i] - slow[i]) * alpha }

        // 3. Attack boost against the 3-tick reference.
        var smoothed = [Double](repeating: 0, count: n)
        for (k, weight) in TunedSpectrumParameters.referenceKernel.enumerated() {
            let source = history[min(k, 2)]
            for i in 0..<n { smoothed[i] += weight * source[i] }
        }
        let low = TunedSpectrumParameters.deadbandLow
        let high = TunedSpectrumParameters.deadbandHigh
        for i in 0..<n {
            let rise = max(0.0, value[i] - smoothed[i])
            let gate = min(1.0, max(0.0, 1.0 - slow[i] / TunedSpectrumParameters.gateLow))
            let amount = punch[i] * gate + TunedSpectrumParameters.punchBase
            let shape = high > low ? min(1.0, max(0.0, (rise - low) / (high - low))) : 1.0
            output[i] = Float(min(1.0, max(0.0, value[i] + amount * rise * shape)))
        }

        // 4. Rotate history (newest first).
        history[2] = history[1]
        history[1] = history[0]
        history[0] = value
    }

    func decay(dt: Double) {
        step(acc: [Double](repeating: 0, count: max(1, output.count)), dt: dt)
    }

    func reset() {
        for index in history.indices {
            for i in history[index].indices { history[index][i] = 0 }
        }
        for i in slow.indices { slow[i] = 0 }
        for i in output.indices { output[i] = 0 }
    }
}

// MARK: - Streaming engine

/// Owns the two analysis windows and the per-count chains. The service feeds it
/// the latest PCM window; it advances on the tuned hop (2048 samples) no matter
/// what cadence the caller uses, so the chain's timing constants stay true.
nonisolated final class TunedSpectrumEngine: @unchecked Sendable {
    static let shared = TunedSpectrumEngine()

    /// Band counts the surfaces ask for. The baseline is Apple's own six bands,
    /// so the contour is the reverse-engineered one, not a resampling of it.
    /// Nine stays for surfaces built around nine capsules (the cassette skin).
    static let baselineBandCount = 6
    static let cassetteBandCount = 9
    static let detailedBandCount = 36

    /// One analysis window for every band count: 2048 points, 23.4 Hz per bin at
    /// 48 kHz. The six-band path is calibrated back onto the 1024-point numbers
    /// it was fitted on (see `TunedSpectrumParameters.windowCalibration`), and
    /// every wider layout sums the *same* spectrum over its own edges — there is
    /// no second window and no second scale.
    private static let windowSize = 2048

    private var chains: [Int: TunedSpectrumChain] = [:]
    private var sampleRate: Double = 48_000
    private var layoutBinWidth: Double = 48_000.0 / 1024.0

    private var lastPCM: [Float] = []
    private var elapsedSinceTick: Double = 0

    private init() {}

    // MARK: Ingest

    /// Latest analysis window from the hub. `pcm` is the most recent block,
    /// oldest sample first.
    func ingest(pcm: [Float], sampleRate: Double) {
        guard !pcm.isEmpty, sampleRate > 0 else { return }
        if abs(sampleRate - self.sampleRate) > 0.5 {
            self.sampleRate = sampleRate
            self.layoutBinWidth = sampleRate / Double(Self.windowSize)
            chains.removeAll()   // layouts depend on the bin width
        }
        lastPCM = pcm
    }

    func reset() {
        chains.values.forEach { $0.reset() }
        lastPCM = []
        elapsedSinceTick = 0
    }

    // MARK: Tick

    /// Advances the chain if enough time has passed. Safe to call at any rate
    /// (the service ticks at 30Hz, the chain runs at hop/fs).
    func advance(dt: Double) {
        guard !lastPCM.isEmpty else { return }
        // One step per service tick. Gating on the FFT hop made the chain run at
        // half the caller's rate (33ms ticks + 46ms hop = one step every 66ms),
        // which is what read as "much slower than the demo": the attack boost and
        // the three-tap reference then spanned ~200ms instead of ~128ms.
        elapsedSinceTick = 0
        processTick(dt: max(0.001, min(0.2, dt)))
    }

    /// Feeds silence so a stalled stream decays instead of freezing.
    func advanceSilence(dt: Double) {
        guard !lastPCM.isEmpty else { return }
        elapsedSinceTick = 0
        let stepSeconds = max(0.001, min(0.2, dt))
        for chain in chains.values { chain.decay(dt: stepSeconds) }
    }

    // MARK: Output

    /// Band values for a requested count. Counts without their own chain are
    /// resampled from the nearest one.
    func wave(bandCount: Int) -> [Float] {
        if let exact = chains[bandCount], exact.bandCount == bandCount {
            return exact.output
        }
        // Interpolate from the nearest chain that actually exists.
        let source: Int
        if bandCount < Self.cassetteBandCount {
            source = Self.baselineBandCount
        } else if bandCount < Self.detailedBandCount {
            source = Self.cassetteBandCount
        } else {
            source = Self.detailedBandCount
        }
        guard let chain = chains[source] else {
            return [Float](repeating: 0, count: max(1, bandCount))
        }
        return Self.resample(chain.output, to: bandCount)
    }

    static func resample(_ wave: [Float], to count: Int) -> [Float] {
        let count = max(1, count)
        guard !wave.isEmpty else { return [Float](repeating: 0, count: count) }
        if wave.count == count { return wave }
        let span = Float(wave.count - 1)
        let targetSpan = Float(count - 1)
        return (0..<count).map { index in
            let position = targetSpan > 0 ? Float(index) * span / targetSpan : 0
            let lower = min(wave.count - 1, Int(position))
            let upper = min(wave.count - 1, lower + 1)
            let fraction = position - Float(lower)
            return wave[lower] + (wave[upper] - wave[lower]) * fraction
        }
    }

    // MARK: Analysis

    private func processTick(dt: Double) {
        let size = Self.windowSize
        guard lastPCM.count >= size else { return }
        let window = Array(lastPCM.suffix(size))

        ensureChains()

        // One FFT. Every layout below is a summation of this same magnitude
        // spectrum, so 6, 9 and 36 bars can never disagree about the signal.
        let mags = BandAnalyzer.magnitudes(samples: window, fftSize: size)
        guard !mags.isEmpty else { return }
        let binWidth = sampleRate / Double(size)

        // Apple's own six bands, on the same spectrum, scaled back to the
        // 1024-point numbers. A sub-band that turns out to be exactly one whole
        // Apple band takes this value verbatim, so widening from six bars never
        // shifts a band that was not split.
        let appleRow = BandAnalyzer.bands(
            magnitudes: mags,
            binWidth: binWidth,
            layout: BandLayout(edges: BandLayout.appleEdges)
        )
        let coarse = (0..<6).map { appleRow[$0] / TunedSpectrumParameters.windowCalibration[$0] }

        for (count, chain) in chains {
            if count == Self.baselineBandCount {
                chain.step(acc: coarse, dt: dt)
                continue
            }
            let layout = chain.bandLayout
            let rows = BandAnalyzer.bands(
                magnitudes: mags,
                binWidth: binWidth,
                layout: layout,
                cleanAssignment: true
            )
            // Same spectrum, same normalisation: a sub-band's density times the
            // parent's bin count is already on the six-band scale.
            let weights = layout.densityScale
            var acc = [Double](repeating: 0, count: layout.count)
            for index in 0..<layout.count {
                let parent = min(max(layout.parent[index], 0), 5)
                let scale = TunedSpectrumParameters.windowCalibration[parent]
                if Self.isWholeParentBand(index, layout: layout) {
                    acc[index] = coarse[parent]
                } else {
                    acc[index] = rows[index] * weights[index] / scale
                }
            }
            chain.step(acc: acc, dt: dt)
        }
    }

    /// True when band `index` covers exactly one whole Apple band.
    static func isWholeParentBand(_ index: Int, layout: BandLayout) -> Bool {
        let parent = min(max(layout.parent[index], 0), 5)
        let edges = BandLayout.appleEdges
        return abs(layout.edges[index] - edges[parent]) < 0.01
            && abs(layout.edges[index + 1] - edges[parent + 1]) < 0.01
    }

    private func ensureChains() {
        let needed = [Self.baselineBandCount, Self.cassetteBandCount, Self.detailedBandCount]
        for count in needed where chains[count] == nil {
            chains[count] = TunedSpectrumChain(bandCount: count, binWidth: layoutBinWidth)
        }
    }
}

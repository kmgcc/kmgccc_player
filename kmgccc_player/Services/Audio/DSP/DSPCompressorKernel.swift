import Foundation

/// Three-band compressor followed by a full-band stage.
///
/// Two fourth-order Linkwitz–Riley crossovers split low, mid and high; the
/// low band also passes the high crossover's allpass, so the three bands sum
/// to a flat magnitude response. Each band and the full-band stage use a
/// feed-forward log-domain gain computer with a soft knee and the smooth
/// decoupled peak detector of Giannoulis, Massberg & Reiss (JAES 2012),
/// whose release follows how long the programme stayed above threshold.
/// Detection is stereo-linked across the selected channels and referenced to
/// programme level, so thresholds do not move with the chain's gain staging.
/// There is no dry mix: added to the band-split signal it would comb.
nonisolated struct DSPCompressorKernel: DSPBlockKernel {
    private struct Detector {
        var thresholdDB: Double
        var ratio: Double
        var makeupDB: Double
        var attack: Double
        var release: Double
        var peak = 0.0
        var smoothed = 0.0

        /// Gain reduction in decibels for a level in decibels.
        @inline(__always)
        func reduction(levelDB: Double, kneeDB: Double) -> Double {
            let over = levelDB - thresholdDB
            let slope = 1 / ratio - 1
            if 2 * over < -kneeDB { return 0 }
            if kneeDB > 0, 2 * abs(over) <= kneeDB {
                let x = over + kneeDB / 2
                return -slope * x * x / (2 * kneeDB)
            }
            return -slope * over
        }

        @inline(__always)
        mutating func update(target: Double) -> Double {
            peak = max(target, release * peak + (1 - release) * target)
            smoothed = attack * smoothed + (1 - attack) * peak
            return smoothed
        }
    }

    private struct ChannelFilters {
        var lowPass: [DSPBiquad]
        var highPass: [DSPBiquad]
        var midLowPass: [DSPBiquad]
        var midHighPass: [DSPBiquad]
        var lowAllpass: DSPBiquad

        mutating func copyState(from source: ChannelFilters) {
            for index in 0..<2 {
                lowPass[index].copyState(from: source.lowPass[index])
                highPass[index].copyState(from: source.highPass[index])
                midLowPass[index].copyState(from: source.midLowPass[index])
                midHighPass[index].copyState(from: source.midHighPass[index])
            }
            lowAllpass.copyState(from: source.lowAllpass)
        }

        mutating func reset() {
            for index in 0..<2 {
                lowPass[index].reset()
                highPass[index].reset()
                midLowPass[index].reset()
                midHighPass[index].reset()
            }
            lowAllpass.reset()
        }
    }

    private static let silenceDB = -120.0

    private let selectedChannels: [Int]
    private let channelMask: [Bool]
    private let kneeDB: Double
    private let lookaheadFrames: Int
    private let outputGain: Double
    private var referenceGain = 1.0
    private var detectors: [Detector]
    private var filters: [ChannelFilters]
    /// Band samples waiting out the lookahead, per channel and band.
    private var lookaheadRing: [Double]
    private var ringCursor = 0
    private var bandScratch: [Double]
    private var loudness: DSPLoudnessMatch?
    /// Largest reduction in the last block for low, mid, high and the
    /// full-band stage, in decibels.
    private(set) var gainReductionDB: [Float] = [0, 0, 0, 0]
    /// Frames per meter reading; matches the renderer's analysis chunks.
    static let meterFrames = 1_024
    /// Readings of the last processed block, four values per chunk of
    /// `meterFrames` frames in order.
    private(set) var meterBlocks: [Float] = []

    var latencyFrames: Int { lookaheadFrames }
    let stateBytes: Int

    init?(format: DSPAudioFormat, selectedChannels mask: [Bool], parameters: DSPCompressorParameters) {
        let sampleRate = format.sampleRate
        guard mask.count == format.channelCount, sampleRate.isFinite, sampleRate > 0,
              parameters.bands.count == DSPCompressorBandKey.allCases.count else { return nil }
        selectedChannels = mask.indices.filter { mask[$0] }
        channelMask = mask
        guard !selectedChannels.isEmpty else { return nil }
        // A fourth-order Linkwitz–Riley filter is two identical
        // second-order Butterworth sections.
        let qs = [DSPFilterDesign.butterworthQ, DSPFilterDesign.butterworthQ]
        func pair(_ type: DSPFilterType, _ frequency: Double) -> [DSPBiquad]? {
            var sections: [DSPBiquad] = []
            for q in qs {
                guard let section = DSPFilterDesign.section(type, frequencyHz: frequency, sampleRate: sampleRate, q: q)
                else { return nil }
                sections.append(DSPBiquad(section))
            }
            return sections
        }
        guard let lowPass = pair(.lowPass, parameters.lowCrossoverHz),
              let highPass = pair(.highPass, parameters.lowCrossoverHz),
              let midLowPass = pair(.lowPass, parameters.highCrossoverHz),
              let midHighPass = pair(.highPass, parameters.highCrossoverHz),
              let allpass = DSPFilterDesign.linkwitzRileyAllpass(frequencyHz: parameters.highCrossoverHz,
                                                                  sampleRate: sampleRate) else { return nil }
        filters = Array(repeating: ChannelFilters(lowPass: lowPass, highPass: highPass, midLowPass: midLowPass,
                                                  midHighPass: midHighPass, lowAllpass: DSPBiquad(allpass)),
                        count: selectedChannels.count)

        let times = parameters.speed.times
        func coefficient(_ milliseconds: Double) -> Double { exp(-1 / (milliseconds / 1_000 * sampleRate)) }
        detectors = DSPCompressorBandKey.allCases.enumerated().map { index, key in
            let band = parameters.bands[index]
            // The full-band stage glues rather than polices: twice as slow.
            let scale = key == .master ? 2.0 : 1.0
            return Detector(thresholdDB: band.thresholdDB, ratio: max(1, band.ratio), makeupDB: band.gainDB,
                            attack: coefficient(times.attackMs * scale),
                            release: coefficient(times.releaseMs * scale))
        }
        kneeDB = parameters.kneeDB
        lookaheadFrames = Int((parameters.lookaheadMs / 1_000 * sampleRate).rounded())
        outputGain = pow(10, parameters.outputTrimDB / 20)
        lookaheadRing = Array(repeating: 0, count: max(1, lookaheadFrames) * selectedChannels.count * 3)
        bandScratch = Array(repeating: 0, count: selectedChannels.count * 3)
        loudness = parameters.loudnessMatchEnabled
            ? DSPLoudnessMatch(sampleRate: sampleRate, channelCount: format.channelCount) : nil
        stateBytes = (lookaheadRing.count + bandScratch.count) * 8 + selectedChannels.count * 512
    }

    func makeFreshState() -> DSPCompressorKernel {
        var fresh = self
        fresh.reset()
        return fresh
    }

    mutating func copyState(from source: DSPCompressorKernel) {
        guard filters.count == source.filters.count else { return }
        for index in filters.indices { filters[index].copyState(from: source.filters[index]) }
        for index in detectors.indices {
            detectors[index].peak = source.detectors[index].peak
            detectors[index].smoothed = source.detectors[index].smoothed
        }
        if lookaheadRing.count == source.lookaheadRing.count {
            DSPStateCopy.assign(&lookaheadRing, from: source.lookaheadRing)
            ringCursor = source.ringCursor
        }
        if let other = source.loudness { loudness?.copyState(from: other) }
        gainReductionDB = source.gainReductionDB
    }

    mutating func reset() {
        for index in filters.indices { filters[index].reset() }
        for index in detectors.indices {
            detectors[index].peak = 0
            detectors[index].smoothed = 0
        }
        DSPStateCopy.clear(&lookaheadRing)
        ringCursor = 0
        loudness?.reset()
        gainReductionDB = [0, 0, 0, 0]
    }

    mutating func setProgramLevelOffset(dB offsetDB: Double) {
        guard offsetDB.isFinite else { return }
        referenceGain = pow(10, -offsetDB / 20)
    }

    mutating func process(_ samples: UnsafeMutablePointer<Double>, frames: Int, channels: Int) {
        guard frames > 0, channels == channelMask.count else { return }
        let mask = channelMask
        loudness?.measureInput(UnsafePointer(samples), frames: frames, channels: channels, mask: mask)

        let count = selectedChannels.count
        let kneeDB = kneeDB
        let reference = referenceGain
        let lookahead = lookaheadFrames
        let outputGain = outputGain
        var channelFilters = filters
        filters = []
        var detectors = detectors
        self.detectors = []
        var ring = lookaheadRing
        lookaheadRing = []
        var bands = bandScratch
        bandScratch = []
        var cursor = ringCursor
        var maximumReduction = (0.0, 0.0, 0.0, 0.0)
        var meter = meterBlocks
        meterBlocks = []
        meter.removeAll(keepingCapacity: true)

        selectedChannels.withUnsafeBufferPointer { selected in
            channelFilters.withUnsafeMutableBufferPointer { filters in
                ring.withUnsafeMutableBufferPointer { ring in
                    bands.withUnsafeMutableBufferPointer { band in
                        for frame in 0..<frames {
                            let base = frame * channels
                            var bandPeaks = (0.0, 0.0, 0.0)
                            for index in 0..<count {
                                let x = samples[base + selected[index]]
                                var low = filters[index].lowPass[1].process(filters[index].lowPass[0].process(x))
                                low = filters[index].lowAllpass.process(low)
                                let rest = filters[index].highPass[1].process(filters[index].highPass[0].process(x))
                                let mid = filters[index].midLowPass[1].process(filters[index].midLowPass[0].process(rest))
                                let high = filters[index].midHighPass[1].process(filters[index].midHighPass[0].process(rest))
                                band[index * 3] = low
                                band[index * 3 + 1] = mid
                                band[index * 3 + 2] = high
                                bandPeaks.0 = max(bandPeaks.0, abs(low))
                                bandPeaks.1 = max(bandPeaks.1, abs(mid))
                                bandPeaks.2 = max(bandPeaks.2, abs(high))
                            }

                            var gains = (1.0, 1.0, 1.0)
                            for bandIndex in 0..<3 {
                                let peak = bandIndex == 0 ? bandPeaks.0 : bandIndex == 1 ? bandPeaks.1 : bandPeaks.2
                                let levelDB = peak * reference > 1e-6
                                    ? 20 * log10(peak * reference) : Self.silenceDB
                                let target = detectors[bandIndex].reduction(levelDB: levelDB, kneeDB: kneeDB)
                                let reduction = detectors[bandIndex].update(target: target)
                                let gainDB = detectors[bandIndex].makeupDB - reduction
                                let gain = gainDB == 0 ? 1 : pow(10, gainDB / 20)
                                switch bandIndex {
                                case 0:
                                    gains.0 = gain
                                    maximumReduction.0 = max(maximumReduction.0, reduction)
                                case 1:
                                    gains.1 = gain
                                    maximumReduction.1 = max(maximumReduction.1, reduction)
                                default:
                                    gains.2 = gain
                                    maximumReduction.2 = max(maximumReduction.2, reduction)
                                }
                            }

                            // Gains computed from the newest samples apply to
                            // samples one lookahead older.
                            var sumPeak = 0.0
                            for index in 0..<count {
                                var low = band[index * 3], mid = band[index * 3 + 1], high = band[index * 3 + 2]
                                if lookahead > 0 {
                                    let slot = (cursor * count + index) * 3
                                    let delayedLow = ring[slot], delayedMid = ring[slot + 1], delayedHigh = ring[slot + 2]
                                    ring[slot] = low
                                    ring[slot + 1] = mid
                                    ring[slot + 2] = high
                                    low = delayedLow
                                    mid = delayedMid
                                    high = delayedHigh
                                }
                                let summed = low * gains.0 + mid * gains.1 + high * gains.2
                                band[index * 3] = summed
                                sumPeak = max(sumPeak, abs(summed))
                            }
                            if lookahead > 0 { cursor = (cursor + 1) % lookahead }

                            let levelDB = sumPeak * reference > 1e-6 ? 20 * log10(sumPeak * reference) : Self.silenceDB
                            let target = detectors[3].reduction(levelDB: levelDB, kneeDB: kneeDB)
                            let reduction = detectors[3].update(target: target)
                            maximumReduction.3 = max(maximumReduction.3, reduction)
                            let masterDB = detectors[3].makeupDB - reduction
                            let masterGain = masterDB == 0 ? 1 : pow(10, masterDB / 20)
                            for index in 0..<count {
                                samples[base + selected[index]] = band[index * 3] * masterGain
                            }
                            // One meter reading per analysis chunk of the block.
                            if (frame + 1) % Self.meterFrames == 0 || frame == frames - 1 {
                                meter.append(Float(maximumReduction.0))
                                meter.append(Float(maximumReduction.1))
                                meter.append(Float(maximumReduction.2))
                                meter.append(Float(maximumReduction.3))
                                maximumReduction = (0, 0, 0, 0)
                            }
                        }
                    }
                }
            }
        }
        filters = channelFilters
        self.detectors = detectors
        lookaheadRing = ring
        bandScratch = bands
        ringCursor = cursor
        meterBlocks = meter
        if meter.count >= 4 {
            for index in 0..<4 { gainReductionDB[index] = meter[meter.count - 4 + index] }
        }
        // The trim is the listener's own level: applied after the match.
        loudness?.applyToOutput(samples, frames: frames, channels: channels, mask: mask)
        if outputGain != 1 {
            for frame in 0..<frames {
                for index in selectedChannels { samples[frame * channels + index] *= outputGain }
            }
        }
    }
}

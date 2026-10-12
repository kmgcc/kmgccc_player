import AVFoundation
import Accelerate
import AudioToolbox
import Foundation

/// Streaming ITU-R BS.1770 integrated loudness and true-peak analyzer.
///
/// Each channel runs the two K-weighting biquads in batches with `vDSP_biquad`,
/// and `vDSP_svesq` sums 100 ms sub-block energies. A 400 ms gating block
/// with 75 % overlap is exactly four adjacent sub-blocks, so the integrated
/// value is gated over the actual block energies rather than a quantized
/// distribution. True peak uses the BS.1770 Annex 2 four-phase, 12-tap
/// interpolator through `vDSP_conv`, with history carried across chunks.
nonisolated final class LoudnessAnalyzer: @unchecked Sendable {
    private static let maximumSupportedChannelCount = 64
    /// About 55 hours of 100 ms sub-blocks; longer input keeps only the
    /// histogram, whose 0.1 LU bins bound the error below 0.05 LU.
    private static let maximumRetainedSubBlocks = 2_000_000
    private static let truePeakTapsPerPhase = 12

    /// ITU-R BS.1770 Annex 2 interpolation filter, listed per phase.
    nonisolated static let truePeakPhases: [[Double]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000,
         -0.0594482421875, 0.1373291015625, 0.9721679687500, -0.1022949218750,
         0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250,
         -0.1665039062500, 0.4650878906250, 0.7797851562500, -0.2003173828125,
         0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000,
         -0.2003173828125, 0.7797851562500, 0.4650878906250, -0.1665039062500,
         0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750,
         -0.1022949218750, 0.9721679687500, 0.1373291015625, -0.0594482421875,
         0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]

    let format: DSPAudioFormat
    private let analysisChannelCount: Int
    private let channelWeights: [Double]?
    private let subBlockFrames: Int

    private var biquadSetup: vDSP_biquad_Setup?
    /// Per channel: 2 sections × 2 + 2 delay elements.
    private var biquadDelays: [[Float]]
    private var weightedScratch: [Float] = []
    /// Replacement samples for a chunk that contains non-finite values.
    private var finiteBuffer: UnsafeMutablePointer<Float>?
    private var finiteCapacity = 0

    private var subBlockEnergies: [Double] = []
    private var subBlockAccumulator = 0.0
    private var subBlockFill = 0
    private var retainsSubBlocks = true
    private var histogram = LoudnessEnergyHistogram()
    private var blockCount: Int64 = 0
    private var didExceedEnergyHistogramRange = false

    /// Reversed per-phase taps for correlation through `vDSP_conv`.
    private let reversedPhaseTaps: [[Float]]
    private var peakHistory: [[Float]]
    private var peakScratch: [Float] = []
    private var peakOutput: [Float] = []

    private(set) var receivedFrames: Int64 = 0
    private var maximumSamplePeak: Float = 0
    private var maximumInterpolatedPeak: Float = 0
    private var nonFiniteSampleCount = 0
    private var didFinish = false

    init(format: DSPAudioFormat) {
        self.format = format
        let count = (1...Self.maximumSupportedChannelCount).contains(format.channelCount) ? format.channelCount : 0
        analysisChannelCount = count
        channelWeights = Self.channelWeights(for: format)

        let validRate = format.sampleRate.isFinite && format.sampleRate >= 8_000 && format.sampleRate <= 768_000
        subBlockFrames = validRate ? max(1, Int((format.sampleRate * 0.1).rounded())) : 0
        if validRate, let coefficients = Self.kWeightingCoefficients(sampleRate: format.sampleRate) {
            biquadSetup = coefficients.withUnsafeBufferPointer {
                vDSP_biquad_CreateSetup($0.baseAddress!, 2)
            }
        }
        biquadDelays = Array(repeating: Array(repeating: 0, count: 2 * 2 + 2), count: count)
        reversedPhaseTaps = Self.truePeakPhases.map { $0.reversed().map(Float.init) }
        peakHistory = Array(
            repeating: Array(repeating: 0, count: Self.truePeakTapsPerPhase - 1),
            count: count
        )
    }

    deinit {
        if let biquadSetup { vDSP_biquad_DestroySetup(biquadSetup) }
        finiteBuffer?.deallocate()
    }

    /// Appends planar Float32 PCM. `channelData[c]` holds `frameCount` samples.
    func append(channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        guard !didFinish, frameCount > 0, analysisChannelCount > 0 else { return }
        let channels = analysisChannelCount
        if weightedScratch.count < frameCount { weightedScratch = Array(repeating: 0, count: frameCount) }
        var frameEnergies = [Double](repeating: 0, count: 0)
        let measuresLoudness = biquadSetup != nil && channelWeights != nil && subBlockFrames > 0
        // Sub-block boundaries inside this chunk.
        var boundaries: [Int] = []
        if measuresLoudness {
            var position = subBlockFrames - subBlockFill
            while position <= frameCount {
                boundaries.append(position)
                position += subBlockFrames
            }
            frameEnergies = Array(repeating: 0, count: boundaries.count + 1)
        }

        for channel in 0..<channels {
            let source = channelData[channel]
            let input = sanitizedInput(source, frameCount: frameCount)
            var magnitude: Float = 0
            vDSP_maxmgv(input, 1, &magnitude, vDSP_Length(frameCount))
            maximumSamplePeak = max(maximumSamplePeak, magnitude)
            measureTruePeak(channel: channel, input: input, frameCount: frameCount)

            guard measuresLoudness, let setup = biquadSetup, let weights = channelWeights,
                  weights[channel] > 0 else { continue }
            weightedScratch.withUnsafeMutableBufferPointer { weighted in
                biquadDelays[channel].withUnsafeMutableBufferPointer { delay in
                    vDSP_biquad(setup, delay.baseAddress!, input, 1, weighted.baseAddress!, 1, vDSP_Length(frameCount))
                }
                var start = 0
                for (index, end) in (boundaries + [frameCount]).enumerated() where end > start {
                    var sum: Float = 0
                    vDSP_svesq(weighted.baseAddress! + start, 1, &sum, vDSP_Length(end - start))
                    frameEnergies[index] += Double(sum) * weights[channel]
                    start = end
                }
            }
        }

        if measuresLoudness {
            var start = 0
            for (index, end) in (boundaries + [frameCount]).enumerated() {
                subBlockAccumulator += frameEnergies[index]
                subBlockFill += end - start
                start = end
                if subBlockFill == subBlockFrames {
                    closeSubBlock(subBlockAccumulator / Double(subBlockFrames))
                    subBlockAccumulator = 0
                    subBlockFill = 0
                }
            }
        }
        receivedFrames += Int64(frameCount)
    }

    func finish(playbackAACGaplessTrimEnabled: Bool = false) -> LoudnessMeasurement {
        if !didFinish {
            didFinish = true
            // Flush the interpolator tail with zeros, as at the end of a file.
            for channel in 0..<analysisChannelCount {
                let tail = [Float](repeating: 0, count: Self.truePeakTapsPerPhase - 1)
                tail.withUnsafeBufferPointer {
                    measureTruePeak(channel: channel, input: $0.baseAddress!, frameCount: tail.count)
                }
            }
        }

        var diagnostics: [DSPDiagnostic] = []
        let rateIsValid = format.sampleRate.isFinite && format.sampleRate >= 8_000 && format.sampleRate <= 768_000
        if !rateIsValid {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessUnsupportedFormat",
                message: "This sample rate is outside the supported analysis range.",
                fieldPath: "loudness.format.sampleRate"
            ))
        }
        if channelWeights == nil {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessUnsupportedLayout",
                message: "The source channel layout is unknown or contains a channel position without a defined loudness weight.",
                fieldPath: "loudness.format.channelLayout"
            ))
        }
        if nonFiniteSampleCount > 0 {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessNonFiniteSamples",
                message: "Non-finite decoded samples were excluded from the measurement.",
                fieldPath: "loudness.samples"
            ))
        }
        if !retainsSubBlocks {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessHistogramIntegrated",
                message: "This very long source was gated from its 0.1 LU block histogram.",
                fieldPath: "loudness.integratedLUFS"
            ))
        }

        let integrated: Double?
        if rateIsValid, channelWeights != nil {
            integrated = retainsSubBlocks
                ? Self.integratedLUFS(from: gatingBlockEnergies())
                : Self.integratedLUFS(from: histogram)
        } else {
            integrated = nil
        }
        let status: LoudnessMeasurementStatus
        if !rateIsValid || analysisChannelCount == 0 {
            status = .unsupportedFormat
        } else if channelWeights == nil {
            status = .unsupportedLayout
        } else if blockCount == 0 {
            status = .tooShort
        } else if !retainsSubBlocks && didExceedEnergyHistogramRange {
            status = .resourceLimit
        } else if integrated == nil {
            status = .silence
        } else {
            status = .available
        }

        let samplePeak = Double(maximumSamplePeak)
        let truePeak = max(Double(maximumInterpolatedPeak), samplePeak)
        return LoudnessMeasurement(
            status: status,
            format: format,
            validStartFrame: 0,
            validEndFrame: receivedFrames,
            analyzerVersion: LoudnessMeasurement.currentAnalyzerVersion,
            decoderRuleVersion: LoudnessMeasurement.currentDecoderRuleVersion,
            trimPolicyVersion: LoudnessMeasurement.currentTrimPolicyVersion,
            analysisFrameRange: "provided-decoded-frames-v2",
            playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled,
            integratedLUFS: integrated,
            samplePeakDBFS: samplePeak > 0 ? 20 * log10(samplePeak) : nil,
            truePeakDBTP: truePeak > 0 ? 20 * log10(truePeak) : nil,
            gatedBlockEnergyHistogram: histogram,
            gatedBlockCount: blockCount,
            blockFrames: subBlockFrames * 4,
            blockStepFrames: subBlockFrames,
            confidence: integrated == nil ? 0 : 0.9,
            diagnostics: diagnostics
        )
    }

    // MARK: - Gating

    nonisolated static func integratedLUFS(from blockEnergies: [Double]) -> Double? {
        let validEnergies = blockEnergies.filter { $0.isFinite && $0 > 0 }
        guard !validEnergies.isEmpty else { return nil }
        let absoluteGateEnergies = validEnergies.filter { levelLUFS($0) > -70 }
        guard let absoluteMean = mean(absoluteGateEnergies) else { return nil }
        let relativeThreshold = levelLUFS(absoluteMean) - 10
        let finalGateEnergies = absoluteGateEnergies.filter { levelLUFS($0) > relativeThreshold }
        guard let gatedMean = mean(finalGateEnergies) else { return nil }
        let result = levelLUFS(gatedMean)
        return result.isFinite ? result : nil
    }

    nonisolated static func integratedLUFS(from histogram: LoudnessEnergyHistogram) -> Double? {
        let absoluteMean = gatedMeanEnergy(histogram, minimumLevelLUFS: LoudnessEnergyHistogram.minimumLUFS)
        guard let absoluteMean else { return nil }
        let relativeThreshold = levelLUFS(absoluteMean) - 10
        guard let finalMean = gatedMeanEnergy(histogram, minimumLevelLUFS: relativeThreshold) else { return nil }
        let result = levelLUFS(finalMean)
        return result.isFinite ? result : nil
    }

    private nonisolated static func gatedMeanEnergy(
        _ histogram: LoudnessEnergyHistogram,
        minimumLevelLUFS: Double
    ) -> Double? {
        var sum = 0.0
        var count = 0.0
        for (index, binCount) in histogram.nonEmptyBins {
            let level = LoudnessEnergyHistogram.minimumLUFS
                + (Double(index) + 0.5) * LoudnessEnergyHistogram.binWidthLU
            guard level > minimumLevelLUFS else { continue }
            let energy = pow(10, (level + 0.691) / 10)
            sum += energy * Double(binCount)
            count += Double(binCount)
        }
        guard sum.isFinite, sum > 0, count > 0 else { return nil }
        return sum / count
    }

    private func closeSubBlock(_ energy: Double) {
        if retainsSubBlocks {
            subBlockEnergies.append(energy)
            if subBlockEnergies.count > Self.maximumRetainedSubBlocks {
                retainsSubBlocks = false
                subBlockEnergies.removeAll(keepingCapacity: false)
            }
        } else {
            rollingSubBlocks.append(energy)
            if rollingSubBlocks.count > 4 { rollingSubBlocks.removeFirst() }
        }
        let recent: ArraySlice<Double> = retainsSubBlocks ? subBlockEnergies.suffix(4) : rollingSubBlocks[...]
        guard recent.count == 4 else { return }
        let blockEnergy = recent.reduce(0, +) / 4
        blockCount += 1
        if !histogram.add(linearEnergy: blockEnergy) { didExceedEnergyHistogramRange = true }
    }

    private var rollingSubBlocks: [Double] = []

    private func gatingBlockEnergies() -> [Double] {
        guard subBlockEnergies.count >= 4 else { return [] }
        var blocks = [Double]()
        blocks.reserveCapacity(subBlockEnergies.count - 3)
        var window = subBlockEnergies[0] + subBlockEnergies[1] + subBlockEnergies[2]
        for index in 3..<subBlockEnergies.count {
            window += subBlockEnergies[index]
            blocks.append(window / 4)
            window -= subBlockEnergies[index - 3]
        }
        return blocks
    }

    // MARK: - Peaks

    private func sanitizedInput(_ source: UnsafeMutablePointer<Float>, frameCount: Int) -> UnsafePointer<Float> {
        var allFinite = true
        for index in 0..<frameCount where !source[index].isFinite {
            allFinite = false
            break
        }
        guard !allFinite else { return UnsafePointer(source) }
        if finiteCapacity < frameCount {
            finiteBuffer?.deallocate()
            finiteBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            finiteCapacity = frameCount
        }
        let buffer = finiteBuffer!
        for index in 0..<frameCount {
            let sample = source[index]
            if sample.isFinite {
                buffer[index] = sample
            } else {
                buffer[index] = 0
                nonFiniteSampleCount += 1
            }
        }
        return UnsafePointer(buffer)
    }

    private func measureTruePeak(channel: Int, input: UnsafePointer<Float>, frameCount: Int) {
        let history = Self.truePeakTapsPerPhase - 1
        let total = history + frameCount
        if peakScratch.count < total { peakScratch = Array(repeating: 0, count: total) }
        if peakOutput.count < frameCount { peakOutput = Array(repeating: 0, count: frameCount) }
        peakScratch.withUnsafeMutableBufferPointer { scratch in
            peakHistory[channel].withUnsafeBufferPointer { previous in
                scratch.baseAddress!.update(from: previous.baseAddress!, count: history)
            }
            (scratch.baseAddress! + history).update(from: input, count: frameCount)
            peakOutput.withUnsafeMutableBufferPointer { output in
                for taps in reversedPhaseTaps {
                    taps.withUnsafeBufferPointer { filter in
                        vDSP_conv(scratch.baseAddress!, 1, filter.baseAddress!, 1,
                                  output.baseAddress!, 1, vDSP_Length(frameCount), vDSP_Length(taps.count))
                    }
                    var peak: Float = 0
                    vDSP_maxmgv(output.baseAddress!, 1, &peak, vDSP_Length(frameCount))
                    if peak.isFinite { maximumInterpolatedPeak = max(maximumInterpolatedPeak, peak) }
                }
            }
            peakHistory[channel].withUnsafeMutableBufferPointer { next in
                next.baseAddress!.update(from: scratch.baseAddress! + total - history, count: history)
            }
        }
    }

    // MARK: - Coefficients

    private nonisolated static func mean(_ energies: [Double]) -> Double? {
        guard !energies.isEmpty else { return nil }
        let total = energies.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        return total / Double(energies.count)
    }

    private nonisolated static func levelLUFS(_ energy: Double) -> Double {
        -0.691 + 10 * log10(energy)
    }

    private nonisolated static func channelWeights(for format: DSPAudioFormat) -> [Double]? {
        guard format.layoutIsKnown,
              let labels = format.channelLabels,
              labels.count == format.channelCount,
              format.channelCount > 0,
              format.channelCount <= maximumSupportedChannelCount else { return nil }
        var weights: [Double] = []
        weights.reserveCapacity(labels.count)
        for label in labels {
            switch label {
            case UInt32(kAudioChannelLabel_LFEScreen), UInt32(kAudioChannelLabel_LFE2), UInt32(kAudioChannelLabel_LFE3):
                weights.append(0)
            case UInt32(kAudioChannelLabel_Mono),
                 UInt32(kAudioChannelLabel_Left),
                 UInt32(kAudioChannelLabel_Right),
                 UInt32(kAudioChannelLabel_Center),
                 UInt32(kAudioChannelLabel_LeftCenter),
                 UInt32(kAudioChannelLabel_RightCenter),
                 UInt32(kAudioChannelLabel_LeftTotal),
                 UInt32(kAudioChannelLabel_RightTotal),
                 UInt32(kAudioChannelLabel_LeftWide),
                 UInt32(kAudioChannelLabel_RightWide):
                weights.append(1)
            case UInt32(kAudioChannelLabel_LeftSurround),
                 UInt32(kAudioChannelLabel_RightSurround),
                 UInt32(kAudioChannelLabel_LeftSurroundDirect),
                 UInt32(kAudioChannelLabel_RightSurroundDirect),
                 UInt32(kAudioChannelLabel_CenterSurround),
                 UInt32(kAudioChannelLabel_CenterSurroundDirect),
                 UInt32(kAudioChannelLabel_RearSurroundLeft),
                 UInt32(kAudioChannelLabel_RearSurroundRight):
                weights.append(1.41)
            default:
                return nil
            }
        }
        return weights
    }

    /// Two cascaded sections (pre-filter shelf, then RLB high-pass) in the
    /// `vDSP_biquad` coefficient order b0, b1, b2, a1, a2.
    private nonisolated static func kWeightingCoefficients(sampleRate: Double) -> [Double]? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let shelfFrequency = 1_681.974450955533
        let shelfGainDB = 3.999843853973347
        let shelfQ = 0.7071752369554196
        let shelfK = tan(Double.pi * shelfFrequency / sampleRate)
        let shelfVh = pow(10, shelfGainDB / 20)
        let shelfVb = pow(shelfVh, 0.4996667741545416)
        let shelfK2 = shelfK * shelfK
        let shelfA0 = 1 + shelfK / shelfQ + shelfK2
        guard shelfA0.isFinite, shelfA0 != 0 else { return nil }

        let highPassFrequency = 38.13547087602444
        let highPassQ = 0.5003270373238773
        let highPassK = tan(Double.pi * highPassFrequency / sampleRate)
        let highPassK2 = highPassK * highPassK
        let highPassA0 = 1 + highPassK / highPassQ + highPassK2
        guard highPassA0.isFinite, highPassA0 != 0 else { return nil }

        return [
            (shelfVh + shelfVb * shelfK / shelfQ + shelfK2) / shelfA0,
            2 * (shelfK2 - shelfVh) / shelfA0,
            (shelfVh - shelfVb * shelfK / shelfQ + shelfK2) / shelfA0,
            2 * (shelfK2 - 1) / shelfA0,
            (1 - shelfK / shelfQ + shelfK2) / shelfA0,
            1 / highPassA0,
            -2 / highPassA0,
            1 / highPassA0,
            2 * (highPassK2 - 1) / highPassA0,
            (1 - highPassK / highPassQ + highPassK2) / highPassA0,
        ]
    }
}

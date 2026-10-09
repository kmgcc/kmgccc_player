import AVFoundation
import AudioToolbox
import Foundation

/// Streaming K-weighted loudness and per-channel peak analyzer. Storage is
/// limited to filter state, one 400 ms energy ring, 48 recent samples per
/// channel, and the compact 100 ms energy history needed for gating.
nonisolated final class LoudnessAnalyzer: @unchecked Sendable {
    private static let maximumSupportedChannelCount = 64

    private struct Biquad {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0

        mutating func process(_ input: Double) -> Double {
            let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = input
            y2 = y1
            y1 = output
            return output
        }
    }

    private static let truePeakTapCount = 48
    private static let truePeakRingFrameCount = 64
    private static let truePeakLeftReach = 23
    private static let truePeakRightReach = 24

    let format: DSPAudioFormat
    private let analysisChannelCount: Int

    private let channelWeights: [Double]?
    private var firstStage: [Biquad]
    private var secondStage: [Biquad]
    private let blockFrames: Int
    private let blockStepFrames: Int
    private var blockEnergyRing: [Double]
    private var rollingEnergy = 0.0
    private var gatedBlockEnergyHistogram = LoudnessEnergyHistogram()
    private var gatedBlockCount: Int64 = 0
    private var didExceedEnergyHistogramRange = false

    private let truePeakFactor: Int
    private let truePeakCoefficients: [[Double]]
    private var truePeakRing: [[Double]]
    private var truePeakNextCenter = 0
    private var receivedFrames = 0
    private var maximumSamplePeak = 0.0
    private var maximumInterpolatedPeak = 0.0
    private var nonFiniteSampleCount = 0
    private var didFinish = false

    init(format: DSPAudioFormat) {
        self.format = format
        let analysisChannelCount = (1...Self.maximumSupportedChannelCount).contains(format.channelCount)
            ? format.channelCount
            : 0
        self.analysisChannelCount = analysisChannelCount
        let count = analysisChannelCount
        let weights = Self.channelWeights(for: format)
        channelWeights = weights

        let validRate = format.sampleRate.isFinite
            && format.sampleRate >= 8_000
            && format.sampleRate <= 768_000
        let coefficients = validRate ? Self.kWeightingCoefficients(sampleRate: format.sampleRate) : nil
        if let coefficients {
            firstStage = Array(repeating: coefficients.0, count: count)
            secondStage = Array(repeating: coefficients.1, count: count)
        } else {
            firstStage = []
            secondStage = []
        }

        blockFrames = validRate ? max(1, Int((format.sampleRate * 0.4).rounded())) : 0
        blockStepFrames = validRate ? max(1, Int((format.sampleRate * 0.1).rounded())) : 0
        blockEnergyRing = Array(repeating: 0, count: blockFrames)

        // Fourfold or greater interpolation keeps the true-peak estimate
        // independent of the original file's sample-grid phase.
        truePeakFactor = 4
        truePeakCoefficients = Self.makeTruePeakCoefficients(oversampleFactor: truePeakFactor)
        truePeakRing = Array(
            repeating: Array(repeating: 0, count: Self.truePeakRingFrameCount),
            count: count
        )
    }

    func append(channelData: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        guard !didFinish, frameCount > 0, analysisChannelCount > 0 else { return }
        let channels = analysisChannelCount
        for frame in 0..<frameCount {
            var weightedFrameEnergy = 0.0
            let ringSlot = receivedFrames % Self.truePeakRingFrameCount

            for channel in 0..<channels {
                let rawSample = Double(channelData[channel][frame])
                let sample: Double
                if rawSample.isFinite {
                    sample = rawSample
                } else {
                    sample = 0
                    nonFiniteSampleCount += 1
                }

                let magnitude = abs(sample)
                if magnitude > maximumSamplePeak { maximumSamplePeak = magnitude }
                truePeakRing[channel][ringSlot] = sample

                if let channelWeights, channelWeights[channel] > 0,
                   channel < firstStage.count {
                    let weighted = secondStage[channel].process(firstStage[channel].process(sample))
                    weightedFrameEnergy += channelWeights[channel] * weighted * weighted
                }
            }

            if blockFrames > 0 {
                let energySlot = receivedFrames % blockFrames
                if receivedFrames >= blockFrames {
                    rollingEnergy -= blockEnergyRing[energySlot]
                }
                blockEnergyRing[energySlot] = weightedFrameEnergy
                rollingEnergy += weightedFrameEnergy
                let currentFrameCount = receivedFrames + 1
                if currentFrameCount >= blockFrames,
                   (currentFrameCount - blockFrames) % blockStepFrames == 0 {
                    let energy = max(0, rollingEnergy / Double(blockFrames))
                    gatedBlockCount += 1
                    if !gatedBlockEnergyHistogram.add(linearEnergy: energy) {
                        didExceedEnergyHistogramRange = true
                    }
                }
            }

            receivedFrames += 1
            processAvailableTruePeakCenters()
        }
    }

    func finish(playbackAACGaplessTrimEnabled: Bool = false) -> LoudnessMeasurement {
        if !didFinish {
            didFinish = true
            while truePeakNextCenter < receivedFrames {
                measureTruePeak(center: truePeakNextCenter)
                truePeakNextCenter += 1
            }
        }

        var diagnostics: [DSPDiagnostic] = []
        let rateIsValid = format.sampleRate.isFinite
            && format.sampleRate >= 8_000
            && format.sampleRate <= 768_000
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
        diagnostics.append(DSPDiagnostic(
            code: "audio.loudnessTruePeakFixturePending",
            message: "True peak uses a 4x, 48-tap windowed-sinc estimate; standard-fixture agreement has not been verified.",
            fieldPath: "loudness.truePeak"
        ))
        diagnostics.append(DSPDiagnostic(
            code: "audio.loudnessEnergyHistogramQuantized",
            message: "Album block energies use a fixed 0.1 LU histogram; the integrated and gating-boundary error requires standard-fixture validation.",
            fieldPath: "loudness.gatedBlockEnergyHistogram"
        ))
        if didExceedEnergyHistogramRange {
            diagnostics.append(DSPDiagnostic(
                code: "audio.loudnessEnergyHistogramRange",
                message: "A block exceeded the bounded energy histogram range, so integrated loudness is unavailable.",
                fieldPath: "loudness.integratedLUFS"
            ))
        }

        let integrated = rateIsValid && channelWeights != nil
            ? Self.integratedLUFS(from: gatedBlockEnergyHistogram)
            : nil
        let status: LoudnessMeasurementStatus
        if !rateIsValid || analysisChannelCount == 0 {
            status = .unsupportedFormat
        } else if channelWeights == nil {
            status = .unsupportedLayout
        } else if gatedBlockCount == 0 {
            status = .tooShort
        } else if didExceedEnergyHistogramRange {
            status = .resourceLimit
        } else if integrated == nil {
            status = .silence
        } else {
            status = .available
        }

        let samplePeakDBFS = maximumSamplePeak > 0
            ? 20 * log10(maximumSamplePeak)
            : nil
        let truePeakDBTP = maximumInterpolatedPeak > 0
            ? 20 * log10(maximumInterpolatedPeak)
            : nil
        return LoudnessMeasurement(
            status: status,
            format: format,
            validStartFrame: 0,
            validEndFrame: Int64(receivedFrames),
            analyzerVersion: LoudnessMeasurement.currentAnalyzerVersion,
            decoderRuleVersion: LoudnessMeasurement.currentDecoderRuleVersion,
            trimPolicyVersion: LoudnessMeasurement.currentTrimPolicyVersion,
            analysisFrameRange: "provided-decoded-frames-v2",
            playbackAACGaplessTrimEnabled: playbackAACGaplessTrimEnabled,
            integratedLUFS: integrated,
            samplePeakDBFS: samplePeakDBFS,
            truePeakDBTP: truePeakDBTP,
            gatedBlockEnergyHistogram: gatedBlockEnergyHistogram,
            gatedBlockCount: gatedBlockCount,
            blockFrames: blockFrames,
            blockStepFrames: blockStepFrames,
            confidence: integrated == nil ? 0 : 0.6,
            diagnostics: diagnostics
        )
    }

    nonisolated static func integratedLUFS(from blockEnergies: [Double]) -> Double? {
        let validEnergies = blockEnergies.filter { $0.isFinite && $0 > 0 }
        guard !validEnergies.isEmpty else { return nil }
        let absoluteGateEnergies = validEnergies.filter { levelLUFS($0) > -70 }
        guard let absoluteMean = mean(absoluteGateEnergies) else { return nil }
        let relativeThreshold = levelLUFS(absoluteMean) - 10
        let finalGateEnergies = absoluteGateEnergies.filter {
            levelLUFS($0) > relativeThreshold
        }
        guard let gatedMean = mean(finalGateEnergies) else { return nil }
        let result = levelLUFS(gatedMean)
        return result.isFinite ? result : nil
    }

    nonisolated static func integratedLUFS(from histogram: LoudnessEnergyHistogram) -> Double? {
        guard histogram.counts.count == LoudnessEnergyHistogram.binCount else { return nil }
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
        for index in histogram.counts.indices where histogram.counts[index] > 0 {
            let level = LoudnessEnergyHistogram.minimumLUFS
                + (Double(index) + 0.5) * LoudnessEnergyHistogram.binWidthLU
            guard level > minimumLevelLUFS else { continue }
            let energy = pow(10, (level + 0.691) / 10)
            let repetitions = Double(histogram.counts[index])
            sum += energy * repetitions
            count += repetitions
        }
        guard sum.isFinite, sum > 0, count > 0 else { return nil }
        return sum / count
    }

    private nonisolated func processAvailableTruePeakCenters() {
        while truePeakNextCenter + Self.truePeakRightReach < receivedFrames {
            measureTruePeak(center: truePeakNextCenter)
            truePeakNextCenter += 1
        }
    }

    private nonisolated func measureTruePeak(center: Int) {
        for channel in 0..<analysisChannelCount {
            for phase in 0..<truePeakFactor {
                let coefficients = truePeakCoefficients[phase]
                var value = 0.0
                for tap in 0..<Self.truePeakTapCount {
                    let inputFrame = center + tap - Self.truePeakLeftReach
                    value += sample(channel: channel, frame: inputFrame) * coefficients[tap]
                }
                maximumInterpolatedPeak = max(maximumInterpolatedPeak, abs(value))
            }
        }
    }

    private nonisolated func sample(channel: Int, frame: Int) -> Double {
        guard frame >= 0, frame < receivedFrames,
              channel >= 0, channel < truePeakRing.count else { return 0 }
        let oldestAvailableFrame = max(0, receivedFrames - Self.truePeakRingFrameCount)
        guard frame >= oldestAvailableFrame else { return 0 }
        return truePeakRing[channel][frame % Self.truePeakRingFrameCount]
    }

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
            if label == UInt32(kAudioChannelLabel_LFEScreen) {
                weights.append(0)
                continue
            }

            switch label {
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

    private nonisolated static func kWeightingCoefficients(
        sampleRate: Double
    ) -> (Biquad, Biquad)? {
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
        let shelf = Biquad(
            b0: (shelfVh + shelfVb * shelfK / shelfQ + shelfK2) / shelfA0,
            b1: 2 * (shelfK2 - shelfVh) / shelfA0,
            b2: (shelfVh - shelfVb * shelfK / shelfQ + shelfK2) / shelfA0,
            a1: 2 * (shelfK2 - 1) / shelfA0,
            a2: (1 - shelfK / shelfQ + shelfK2) / shelfA0
        )

        let highPassFrequency = 38.13547087602444
        let highPassQ = 0.5003270373238773
        let highPassK = tan(Double.pi * highPassFrequency / sampleRate)
        let highPassK2 = highPassK * highPassK
        let highPassA0 = 1 + highPassK / highPassQ + highPassK2
        guard highPassA0.isFinite, highPassA0 != 0 else { return nil }
        let highPass = Biquad(
            b0: 1 / highPassA0,
            b1: -2 / highPassA0,
            b2: 1 / highPassA0,
            a1: 2 * (highPassK2 - 1) / highPassA0,
            a2: (1 - highPassK / highPassQ + highPassK2) / highPassA0
        )
        return (shelf, highPass)
    }

    private nonisolated static func makeTruePeakCoefficients(
        oversampleFactor: Int
    ) -> [[Double]] {
        (0..<max(1, oversampleFactor)).map { phase in
            let fraction = Double(phase) / Double(max(1, oversampleFactor))
            var coefficients: [Double] = []
            coefficients.reserveCapacity(truePeakTapCount)
            var sum = 0.0
            for tap in 0..<truePeakTapCount {
                let offset = Double(tap - truePeakLeftReach) - fraction
                let sinc = abs(offset) < 1e-12
                    ? 1
                    : sin(Double.pi * offset) / (Double.pi * offset)
                let normalized = offset / 24.5
                let window = 0.42
                    + 0.5 * cos(Double.pi * normalized)
                    + 0.08 * cos(2 * Double.pi * normalized)
                let coefficient = sinc * window
                coefficients.append(coefficient)
                sum += coefficient
            }
            if sum.isFinite, abs(sum) > 1e-12 {
                for index in coefficients.indices {
                    coefficients[index] /= sum
                }
            }
            return coefficients
        }
    }
}

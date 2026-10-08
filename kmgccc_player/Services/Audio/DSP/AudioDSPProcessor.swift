import AVFoundation
import Foundation

/// Pipeline-confined runtime for the currently supported DSP node set.
/// Coefficients, channel routing, headroom and filter state are prepared once;
/// `process(_:)` performs only the per-frame recurrence and gain operations.
nonisolated final class AudioDSPProcessor: @unchecked Sendable {
    private struct RuntimeFilter {
        let coefficients: DSPBiquadCoefficients
        var state1: [Double]
        var state2: [Double]

        mutating func process(_ input: Double, channel: Int) -> Double {
            let output = coefficients.b0 * input + state1[channel]
            state1[channel] = coefficients.b1 * input
                - coefficients.a1 * output
                + state2[channel]
            state2[channel] = coefficients.b2 * input - coefficients.a2 * output
            return output
        }

        mutating func reset() {
            for index in state1.indices { state1[index] = 0 }
            for index in state2.indices { state2[index] = 0 }
        }
    }

    private struct RuntimeNode {
        let nodeID: UUID
        let channelMask: [Bool]
        var filters: [RuntimeFilter]
    }

    let format: DSPAudioFormat
    let diagnostics: [DSPDiagnostic]
    let headroomDB: Double
    let isBypassed: Bool

    private let inputGain: Double
    private let outputGain: Double
    private var nodes: [RuntimeNode]

    init(configuration: AudioDSPConfiguration, format: DSPAudioFormat) {
        self.format = format

        var preparedNodes: [RuntimeNode] = []
        var warnings: [DSPDiagnostic] = []
        preparedNodes.reserveCapacity(configuration.nodes.count)

        if configuration.enabled {
            for node in configuration.nodes where node.enabled {
                guard node.typeID == "peq9" else {
                    warnings.append(DSPDiagnostic(
                        code: "unsupportedNode",
                        message: "Enabled DSP node is not available in this renderer.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].typeID",
                        nodeID: node.nodeID,
                        retryable: false
                    ))
                    continue
                }

                let channelMask: [Bool]
                switch node.channelPolicy {
                case "allChannels":
                    channelMask = Array(repeating: true, count: format.channelCount)
                case "fullRange":
                    guard format.layoutIsKnown,
                          let labels = format.channelLabels,
                          labels.count == format.channelCount else {
                        warnings.append(DSPDiagnostic(
                            code: "unknownChannelLayout",
                            message: "The EQ was bypassed because this source has no complete channel map.",
                            fieldPath: "nodes[\(node.nodeID.uuidString)].channelPolicy",
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                        continue
                    }
                    channelMask = labels.map {
                        $0 != UInt32(kAudioChannelLabel_LFEScreen)
                            && $0 != UInt32(kAudioChannelLabel_LFE2)
                            && $0 != UInt32(kAudioChannelLabel_LFE3)
                    }
                default:
                    warnings.append(DSPDiagnostic(
                        code: "unsupportedChannelPolicy",
                        message: "The EQ was bypassed because its channel policy is not supported.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].channelPolicy",
                        nodeID: node.nodeID,
                        retryable: false
                    ))
                    continue
                }

                guard let bands = node.parametricEQBands, bands.count == 9 else {
                    warnings.append(DSPDiagnostic(
                        code: "invalidEQBandCount",
                        message: "A 9-band EQ node must contain exactly nine bands.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.bands",
                        nodeID: node.nodeID,
                        retryable: false
                    ))
                    continue
                }

                var filters: [RuntimeFilter] = []
                filters.reserveCapacity(bands.count)
                for (bandIndex, band) in bands.enumerated() where band.enabled {
                    guard Self.isFinite(band) else {
                        warnings.append(DSPDiagnostic(
                            code: "invalidEQParameter",
                            message: "The EQ band contains a non-finite parameter and was bypassed.",
                            fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.bands[\(bandIndex)]",
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                        continue
                    }

                    if Self.wasNormalized(band, sampleRate: format.sampleRate) {
                        warnings.append(DSPDiagnostic(
                            code: "eqParameterNormalized",
                            message: "The EQ band was bounded to the renderer's supported range.",
                            fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.bands[\(bandIndex)]",
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                    }

                    guard let coefficients = DSPParametricEQMath.coefficients(
                        for: band,
                        sampleRate: format.sampleRate
                    ) else {
                        warnings.append(DSPDiagnostic(
                            code: "invalidEQCoefficients",
                            message: "The EQ band could not produce stable coefficients and was bypassed.",
                            fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.bands[\(bandIndex)]",
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                        continue
                    }
                    guard !coefficients.isIdentity else { continue }
                    filters.append(RuntimeFilter(
                        coefficients: coefficients,
                        state1: Array(repeating: 0, count: format.channelCount),
                        state2: Array(repeating: 0, count: format.channelCount)
                    ))
                }

                if !filters.isEmpty, channelMask.contains(true) {
                    preparedNodes.append(RuntimeNode(
                        nodeID: node.nodeID,
                        channelMask: channelMask,
                        filters: filters
                    ))
                }
            }
        }

        let normalizedInputTrimDB = Self.normalizedTrim(
            configuration.inputTrimDB,
            fieldPath: "inputTrimDB",
            warnings: &warnings
        )
        let normalizedOutputTrimDB = Self.normalizedTrim(
            configuration.outputTrimDB,
            fieldPath: "outputTrimDB",
            warnings: &warnings
        )
        let marginDB: Double
        if configuration.headroom.marginDB.isFinite {
            marginDB = min(max(0, configuration.headroom.marginDB), 12)
            if abs(marginDB - configuration.headroom.marginDB) > 1e-9 {
                warnings.append(DSPDiagnostic(
                    code: "headroomMarginNormalized",
                    message: "The headroom margin was bounded to its supported range.",
                    fieldPath: "headroom.marginDB",
                    retryable: false
                ))
            }
        } else {
            marginDB = 0
            warnings.append(DSPDiagnostic(
                code: "invalidHeadroomMargin",
                message: "The non-finite headroom margin was ignored.",
                fieldPath: "headroom.marginDB",
                retryable: false
            ))
        }
        let hasEQWork = !preparedNodes.isEmpty
        let hasTrimWork = abs(normalizedInputTrimDB) > 1e-12
            || abs(normalizedOutputTrimDB) > 1e-12
        let hasEffectWork = hasEQWork || hasTrimWork
        var numericPreparationFailed = false
        let automaticHeadroomDB: Double
        if configuration.enabled,
           hasEffectWork,
           configuration.headroom.mode == .automatic,
            marginDB.isFinite {
            let pathPeakDB = Self.maximumPathPeakResponseDB(
                configuration: configuration,
                preparedNodes: preparedNodes,
                channelCount: format.channelCount,
                sampleRate: format.sampleRate
            )
            let estimatedPeakDB = pathPeakDB + normalizedInputTrimDB + normalizedOutputTrimDB
            if estimatedPeakDB.isFinite {
                automaticHeadroomDB = -max(0, estimatedPeakDB) - marginDB
            } else {
                automaticHeadroomDB = 0
                numericPreparationFailed = true
                warnings.append(DSPDiagnostic(
                    code: "headroomEstimateUnavailable",
                    message: "The combined response exceeded the supported numeric range; DSP processing was bypassed.",
                    fieldPath: "headroom",
                    retryable: false
                ))
            }
        } else {
            automaticHeadroomDB = 0
        }
        let preparedInputGain: Double
        if configuration.enabled,
           let gain = Self.linearGain(
               normalizedInputTrimDB + automaticHeadroomDB,
               fieldPath: "headroom.automaticGain",
               warnings: &warnings
           ) {
            preparedInputGain = gain
        } else if configuration.enabled {
            preparedInputGain = 1
            numericPreparationFailed = true
        } else {
            preparedInputGain = 1
        }
        let preparedOutputGain: Double
        if configuration.enabled,
           let gain = Self.linearGain(
               normalizedOutputTrimDB,
               fieldPath: "outputTrimDB",
               warnings: &warnings
           ) {
            preparedOutputGain = gain
        } else if configuration.enabled {
            preparedOutputGain = 1
            numericPreparationFailed = true
        } else {
            preparedOutputGain = 1
        }
        self.headroomDB = numericPreparationFailed ? 0 : automaticHeadroomDB
        self.inputGain = numericPreparationFailed ? 1 : preparedInputGain
        self.outputGain = numericPreparationFailed ? 1 : preparedOutputGain
        self.nodes = numericPreparationFailed ? [] : preparedNodes
        self.diagnostics = warnings
        self.isBypassed = numericPreparationFailed
            || !configuration.enabled
            || (preparedNodes.isEmpty
                && abs(preparedInputGain - 1) < 1e-12
                && abs(preparedOutputGain - 1) < 1e-12)
    }

    func reset() {
        for nodeIndex in nodes.indices {
            for filterIndex in nodes[nodeIndex].filters.indices {
                nodes[nodeIndex].filters[filterIndex].reset()
            }
        }
    }

    /// Advance recursive state while discarding output. Call with source-time
    /// ordered raw history ending at the selected replacement boundary.
    func warm(with rawHistory: [CanonicalPCM]) {
        for pcm in rawHistory {
            _ = process(pcm)
        }
    }

    func process(_ input: CanonicalPCM) -> CanonicalPCM {
        guard !isBypassed,
              input.frames > 0,
              input.channelCount == format.channelCount,
              abs(input.sampleRate - format.sampleRate) < 0.5 else { return input }

        var output = input.data
        let channelCount = input.channelCount
        for frame in 0..<input.frames {
            let frameBase = frame * channelCount
            for channel in 0..<channelCount {
                let sampleIndex = frameBase + channel
                var sample = Double(output[sampleIndex]) * inputGain
                for nodeIndex in nodes.indices where nodes[nodeIndex].channelMask[channel] {
                    for filterIndex in nodes[nodeIndex].filters.indices {
                        sample = nodes[nodeIndex].filters[filterIndex].process(sample, channel: channel)
                    }
                }
                sample *= outputGain
                output[sampleIndex] = Float(sample)
            }
        }

        return CanonicalPCM(
            frames: input.frames,
            channelCount: input.channelCount,
            sampleRate: input.sampleRate,
            data: output
        )
    }

    /// Raised-cosine weights are built once per apply request, then reused for
    /// every output block in its short transition. No trigonometry is performed
    /// in the per-sample filter loop.
    static func transitionWeights(sampleRate: Double, durationMilliseconds: Double = 30) -> [Double] {
        guard sampleRate.isFinite, sampleRate > 0,
              durationMilliseconds.isFinite, durationMilliseconds > 0 else { return [] }
        let frames = max(1, Int((sampleRate * durationMilliseconds / 1_000).rounded()))
        guard frames > 1 else { return [1] }
        return (0..<frames).map { frame in
            let position = Double(frame) / Double(frames - 1)
            return (1 - cos(Double.pi * position)) / 2
        }
    }

    static func crossfade(
        old: CanonicalPCM,
        new: CanonicalPCM,
        weights: [Double],
        transitionOffsetSeconds: Double,
        weightSampleRate: Double
    ) -> CanonicalPCM {
        guard old.frames == new.frames,
              old.channelCount == new.channelCount,
              old.sampleRate == new.sampleRate,
              !weights.isEmpty,
              weightSampleRate.isFinite,
              weightSampleRate > 0 else { return new }

        var mixed = new.data
        for frame in 0..<new.frames {
            let elapsedAtWeightRate = (transitionOffsetSeconds
                + Double(frame) / new.sampleRate) * weightSampleRate
            let weightIndex = min(
                weights.count - 1,
                max(0, Int(elapsedAtWeightRate.rounded(.down)))
            )
            let newWeight = weights[weightIndex]
            let oldWeight = 1 - newWeight
            let base = frame * new.channelCount
            for channel in 0..<new.channelCount {
                let index = base + channel
                mixed[index] = Float(Double(old.data[index]) * oldWeight
                    + Double(new.data[index]) * newWeight)
            }
        }
        return CanonicalPCM(
            frames: new.frames,
            channelCount: new.channelCount,
            sampleRate: new.sampleRate,
            data: mixed
        )
    }

    private static func linearGain(
        _ gainDB: Double,
        fieldPath: String,
        warnings: inout [DSPDiagnostic]
    ) -> Double? {
        guard gainDB.isFinite else {
            warnings.append(DSPDiagnostic(
                code: "gainNotRepresentable",
                message: "The requested gain could not be represented; DSP processing was bypassed.",
                fieldPath: fieldPath,
                retryable: false
            ))
            return nil
        }
        let gain = pow(10, gainDB / 20)
        guard gain.isFinite, gain > 0 else {
            warnings.append(DSPDiagnostic(
                code: "gainNotRepresentable",
                message: "The required gain fell outside the supported numeric range; DSP processing was bypassed.",
                fieldPath: fieldPath,
                retryable: false
            ))
            return nil
        }
        return gain
    }

    private static func maximumPathPeakResponseDB(
        configuration: AudioDSPConfiguration,
        preparedNodes: [RuntimeNode],
        channelCount: Int,
        sampleRate: Double
    ) -> Double {
        var pathNodeIDs = [[UUID]]()
        var seenPaths = Set<String>()
        for channel in 0..<channelCount {
            let nodeIDs = preparedNodes.compactMap { node in
                node.channelMask[channel] ? node.nodeID : nil
            }
            let signature = nodeIDs.map(\.uuidString).joined(separator: ",")
            if seenPaths.insert(signature).inserted {
                pathNodeIDs.append(nodeIDs)
            }
        }

        var peakDB = 0.0
        for nodeIDs in pathNodeIDs where !nodeIDs.isEmpty {
            var pathConfiguration = configuration
            let includedNodeIDs = Set(nodeIDs)
            pathConfiguration.nodes.removeAll { !includedNodeIDs.contains($0.nodeID) }
            peakDB = max(
                peakDB,
                DSPParametricEQMath.estimatedPeakResponseDB(
                    configuration: pathConfiguration,
                    sampleRate: sampleRate
                )
            )
        }
        return peakDB
    }

    private static func normalizedTrim(
        _ trimDB: Double,
        fieldPath: String,
        warnings: inout [DSPDiagnostic]
    ) -> Double {
        guard trimDB.isFinite else {
            warnings.append(DSPDiagnostic(
                code: "invalidTrim",
                message: "The non-finite trim was ignored.",
                fieldPath: fieldPath,
                retryable: false
            ))
            return 0
        }
        let bounded = min(max(-24, trimDB), 24)
        if abs(bounded - trimDB) > 1e-9 {
            warnings.append(DSPDiagnostic(
                code: "trimNormalized",
                message: "The trim was bounded to its supported range.",
                fieldPath: fieldPath,
                retryable: false
            ))
        }
        return bounded
    }

    private static func isFinite(_ band: DSPParametricEQBand) -> Bool {
        band.frequencyHz.isFinite && band.gainDB.isFinite && band.q.isFinite
    }

    private static func wasNormalized(_ band: DSPParametricEQBand, sampleRate: Double) -> Bool {
        guard sampleRate.isFinite, sampleRate > 0 else { return false }
        let maxFrequency = min(20_000, sampleRate * 0.49)
        let frequency = min(max(20, band.frequencyHz), maxFrequency)
        let gain = min(max(-18, band.gainDB), 18)
        let maxQ = band.type == .lowShelf || band.type == .highShelf ? 1.0 : 16.0
        let q = min(max(0.25, band.q), maxQ)
        return abs(frequency - band.frequencyHz) > 1e-9
            || abs(gain - band.gainDB) > 1e-9
            || abs(q - band.q) > 1e-9
    }
}

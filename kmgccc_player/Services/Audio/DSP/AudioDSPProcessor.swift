import AVFoundation
import Foundation

/// Pipeline-confined runtime for the currently supported DSP node set.
/// Coefficients, channel routing, headroom and filter state are prepared once.
/// `process(_:lookahead:)` advances source state once and previews only the
/// future frames required to return PCM at its original media time.
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
        let contributesToHeadroom: Bool
        var staticPeakResponseDB: Double
        var filters: [RuntimeFilter]
        var effect: RuntimeEffect?
        var flatGain: Double?
        var stereoWidthKernel: DSPStereoWidthKernel?
        var virtualBassKernel: DSPVirtualBassKernel?
        var tubeKernel: DSPTubeKernel?
        var scriptRuntime: DSPScriptRuntime?
        var scriptLatencyFrames: Int = 0
        var scriptEstimatedOperationsPerSecond: Double = 0
    }

    private enum RuntimeEffect {
        case flatGain
        case stereoWidth
        case virtualBass
        case tube
        case script

        var requiresLookahead: Bool {
            switch self {
            case .virtualBass, .tube: true
            case .flatGain, .stereoWidth, .script: false
            }
        }
    }

    let format: DSPAudioFormat
    private let preparationDiagnostics: [DSPDiagnostic]
    private var scriptFaults: [UUID: DSPDiagnostic] = [:]
    private var outputFault: DSPDiagnostic?
    var diagnostics: [DSPDiagnostic] {
        preparationDiagnostics + scriptFaults.values.sorted { $0.id < $1.id }
            + (outputFault.map { [$0] } ?? [])
    }
    let headroomDB: Double
    let isBypassed: Bool
    let processingLatencyFrames: Int
    let peakGuarantee: String

    private let inputGain: Double
    private let outputGain: Double
    private var nodes: [RuntimeNode]
    private var previewNodes: [RuntimeNode]
    private var frameScratch: [Double] = []
    private var futureInputScratch: [Float] = []

    init(
        configuration: AudioDSPConfiguration,
        format: DSPAudioFormat,
        context: DSPEqualLoudnessContext = .appOnly
    ) {
        self.format = format

        var preparedNodes: [RuntimeNode] = []
        var warnings: [DSPDiagnostic] = []
        preparedNodes.reserveCapacity(configuration.nodes.count)
        var scriptCount = 0
        var scriptOperationsPerSecond = 0.0

        if configuration.enabled {
            for node in configuration.nodes where node.enabled {
                guard node.algorithmVersion == 1 else {
                    warnings.append(DSPDiagnostic(
                        code: "unsupportedNodeVersion",
                        message: "The DSP node algorithm version is not available in this renderer.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].algorithmVersion",
                        nodeID: node.nodeID,
                        retryable: false
                    ))
                    continue
                }

                if node.typeID == DSPNodeConfiguration.scriptTypeID {
                    if let preparedNode = Self.prepareScriptNode(node, format: format, warnings: &warnings) {
                        let totalCost = scriptOperationsPerSecond + preparedNode.scriptEstimatedOperationsPerSecond
                        if scriptCount < 4, totalCost <= DSPScriptCompiler.maximumChainWeightedOperationsPerSecond {
                            preparedNodes.append(preparedNode)
                            scriptCount += 1
                            scriptOperationsPerSecond = totalCost
                        } else {
                            warnings.append(DSPDiagnostic(code: "dsp.scriptBudgetExceeded",
                                message: "The script chain exceeds its node or estimated processing budget for this format.",
                                fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.source", nodeID: node.nodeID))
                        }
                    }
                    continue
                }

                if Self.isNativeEffect(node.typeID) {
                    if let preparedNode = Self.prepareNativeNode(
                        node,
                        format: format,
                        warnings: &warnings
                    ) {
                        preparedNodes.append(preparedNode)
                    }
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
                            message: "The effect was bypassed because this source has no complete channel map.",
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
                        message: "The effect was bypassed because its channel policy is not supported.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].channelPolicy",
                        nodeID: node.nodeID,
                        retryable: false
                    ))
                    continue
                }

                let bands: [DSPParametricEQBand]
                let contributesToHeadroom: Bool
                switch node.typeID {
                case DSPNodeConfiguration.parametricEQTypeID:
                    guard let eqBands = node.parametricEQBands,
                          eqBands.count == 9 else {
                        warnings.append(DSPDiagnostic(
                            code: "invalidEQBandCount",
                            message: "A 9-band EQ node must contain exactly nine bands.",
                            fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.bands",
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                        continue
                    }
                    bands = eqBands
                    contributesToHeadroom = true

                case DSPNodeConfiguration.equalLoudnessTypeID:
                    guard let parameters = node.equalLoudnessParameters,
                          let shelfBands = DSPEqualLoudnessMath.bands(node: node, context: context) else {
                        warnings.append(DSPDiagnostic(
                            code: "invalidEqualLoudnessParameter",
                            message: "The equal-loudness node has unsupported or incomplete parameters.",
                            fieldPath: "nodes[\(node.nodeID.uuidString)].parameters",
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                        continue
                    }
                    bands = shelfBands
                    contributesToHeadroom = parameters.headroomMode == .automatic

                default:
                    warnings.append(DSPDiagnostic(
                        code: "unsupportedNode",
                        message: "Enabled DSP node is not available in this renderer.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].typeID",
                        nodeID: node.nodeID,
                        retryable: false
                    ))
                    continue
                }

                var filters: [RuntimeFilter] = []
                filters.reserveCapacity(bands.count)
                for (bandIndex, band) in bands.enumerated() where band.enabled {
                    let parameterPath = node.typeID == DSPNodeConfiguration.parametricEQTypeID
                        ? "nodes[\(node.nodeID.uuidString)].parameters.bands[\(bandIndex)]"
                        : "nodes[\(node.nodeID.uuidString)].parameters"
                    guard Self.isFinite(band) else {
                        warnings.append(DSPDiagnostic(
                            code: "invalidEQParameter",
                            message: "The effect filter contains a non-finite parameter and was bypassed.",
                            fieldPath: parameterPath,
                            nodeID: node.nodeID,
                            retryable: false
                        ))
                        continue
                    }

                    if Self.wasNormalized(band, sampleRate: format.sampleRate) {
                        warnings.append(DSPDiagnostic(
                            code: "eqParameterNormalized",
                            message: "The effect filter was bounded to the renderer's supported range.",
                            fieldPath: parameterPath,
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
                            message: "The effect filter could not produce stable coefficients and was bypassed.",
                            fieldPath: parameterPath,
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
                        contributesToHeadroom: contributesToHeadroom,
                        staticPeakResponseDB: 0,
                        filters: filters,
                        effect: nil,
                        flatGain: nil,
                        stereoWidthKernel: nil,
                        virtualBassKernel: nil,
                        tubeKernel: nil
                    ))
                }
            }
        }

        // Preview executes the entire prepared chain for its combined latency.
        // Account for that work as well as the source-frame VM cost. A format
        // change can invalidate a previously valid chain; isolate scripts from
        // the end until the remaining prepared chain fits the nominal budget.
        while true {
            let latency = preparedNodes.reduce(0) { total, node in
                total + (node.effect?.requiresLookahead == true ? 64 : 0) + node.scriptLatencyFrames
            }
            let baseCost = preparedNodes.reduce(0.0) { $0 + $1.scriptEstimatedOperationsPerSecond }
            let cost = DSPScriptCompiler.estimatedRendererOperationsPerSecond(
                baseOperationsPerSecond: baseCost, latencyFrames: latency)
            guard cost > DSPScriptCompiler.maximumChainWeightedOperationsPerSecond,
                  let index = preparedNodes.lastIndex(where: { $0.scriptRuntime != nil }) else { break }
            let node = preparedNodes.remove(at: index)
            warnings.append(DSPDiagnostic(code: "dsp.scriptBudgetExceeded",
                message: "The script was bypassed because combined latency preview exceeds the renderer processing budget.",
                fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.source", nodeID: node.nodeID))
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
        let hasHeadroomNodeWork = preparedNodes.contains(where: \.contributesToHeadroom)
        let hasTrimWork = abs(normalizedInputTrimDB) > 1e-12
            || abs(normalizedOutputTrimDB) > 1e-12
        let hasHeadroomWork = hasHeadroomNodeWork || hasTrimWork
        var numericPreparationFailed = false
        let automaticHeadroomDB: Double
        if configuration.enabled,
           hasHeadroomWork,
           configuration.headroom.mode == .automatic,
            marginDB.isFinite {
            let pathPeakDB = Self.maximumPathPeakResponseDB(
                configuration: configuration,
                preparedNodes: preparedNodes,
                channelCount: format.channelCount,
                sampleRate: format.sampleRate,
                context: context
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
        let finalNodes = numericPreparationFailed ? [] : preparedNodes
        self.nodes = finalNodes
        previewNodes = finalNodes.map(Self.makeFreshRuntimeState)
        self.preparationDiagnostics = warnings
        let processorBypassed = numericPreparationFailed
            || !configuration.enabled
            || (preparedNodes.isEmpty
                && abs(preparedInputGain - 1) < 1e-12
                && abs(preparedOutputGain - 1) < 1e-12)
        self.isBypassed = processorBypassed
        processingLatencyFrames = numericPreparationFailed
            ? 0
            : preparedNodes.reduce(into: 0) { total, node in
                if node.effect?.requiresLookahead == true { total += 64 }
                total += node.scriptLatencyFrames
            }
        if processorBypassed {
            self.peakGuarantee = "bypassed"
        } else if preparedNodes.contains(where: { $0.effect?.requiresLookahead == true || $0.scriptRuntime != nil }) {
            self.peakGuarantee = "unavailable"
        } else {
            self.peakGuarantee = "estimatedLinearResponse"
        }
    }

    func reset() {
        Self.resetRuntimeStates(&nodes)
        Self.resetRuntimeStates(&previewNodes)
        scriptFaults.removeAll(keepingCapacity: true)
        outputFault = nil
    }

    /// Advance recursive state while discarding output. Call with source-time
    /// ordered raw history ending at the selected replacement boundary.
    func warm(with rawHistory: [CanonicalPCM]) {
        for pcm in rawHistory {
            guard isCompatible(pcm), !isBypassed else { continue }
            var warmupOutput: [Float] = []
            processCore(pcm, nodes: &nodes, output: &warmupOutput, frameValues: &frameScratch)
        }
    }

    /// Process input-time PCM and use up to one processing-latency of future PCM
    /// to return an output block mapped to the input's original presentation time.
    /// A missing or short lookahead is zero-filled, which is the EOF behavior.
    func process(_ input: CanonicalPCM, lookahead: CanonicalPCM? = nil) -> CanonicalPCM {
        guard isCompatible(input), input.frames > 0 else { return input }
        guard !isBypassed, outputFault == nil else { return input }

        var currentOutput: [Float] = []
        processCore(input, nodes: &nodes, output: &currentOutput, frameValues: &frameScratch)
        guard outputFault == nil else { return input }
        guard processingLatencyFrames > 0 else {
            return CanonicalPCM(
                frames: input.frames,
                channelCount: input.channelCount,
                sampleRate: input.sampleRate,
                data: currentOutput
            )
        }

        let latency = processingLatencyFrames
        Self.copyRuntimeStates(from: nodes, to: &previewNodes, previewFrames: latency)
        let channelCount = format.channelCount
        let futureSampleCount = latency * channelCount
        if futureInputScratch.count != futureSampleCount {
            futureInputScratch = Array(repeating: 0, count: futureSampleCount)
        } else {
            for index in futureInputScratch.indices {
                futureInputScratch[index] = 0
            }
        }
        if let lookahead, isCompatible(lookahead), lookahead.frames > 0 {
            let copiedFrames = min(latency, lookahead.frames)
            let copiedSamples = copiedFrames * channelCount
            for index in 0..<copiedSamples {
                futureInputScratch[index] = lookahead.data[index]
            }
        }
        let futureInput = CanonicalPCM(
            frames: latency,
            channelCount: channelCount,
            sampleRate: format.sampleRate,
            data: futureInputScratch
        )
        var futureOutput: [Float] = []
        processCore(
            futureInput,
            nodes: &previewNodes,
            output: &futureOutput,
            frameValues: &frameScratch
        )
        guard outputFault == nil else { return input }

        for frame in 0..<input.frames {
            let sourceFrame = frame + latency
            let destinationOffset = frame * channelCount
            if sourceFrame < input.frames {
                let sourceOffset = sourceFrame * channelCount
                for channel in 0..<channelCount {
                    currentOutput[destinationOffset + channel] = currentOutput[sourceOffset + channel]
                }
            } else {
                let sourceOffset = (sourceFrame - input.frames) * channelCount
                for channel in 0..<channelCount {
                    currentOutput[destinationOffset + channel] = futureOutput[sourceOffset + channel]
                }
            }
        }

        return CanonicalPCM(
            frames: input.frames,
            channelCount: input.channelCount,
            sampleRate: input.sampleRate,
            data: currentOutput
        )
    }

    private func isCompatible(_ pcm: CanonicalPCM) -> Bool {
        guard pcm.channelCount == format.channelCount,
              pcm.channelCount > 0,
              pcm.frames > 0,
              pcm.data.count / pcm.channelCount >= pcm.frames,
              pcm.sampleRate.isFinite else { return false }
        return abs(pcm.sampleRate - format.sampleRate) < 0.5
    }

    private func processCore(
        _ input: CanonicalPCM,
        nodes: inout [RuntimeNode],
        output: inout [Float],
        frameValues: inout [Double]
    ) {
        let requiredSamples = input.frames * input.channelCount
        if output.count != requiredSamples {
            output = Array(repeating: 0, count: requiredSamples)
        }
        if frameValues.count != input.channelCount {
            frameValues = Array(repeating: 0, count: input.channelCount)
        }
        guard outputFault == nil else {
            output = Array(repeating: 0, count: requiredSamples)
            return
        }
        let channelCount = input.channelCount

        for frameIndex in 0..<input.frames {
            let base = frameIndex * channelCount
            for channel in 0..<channelCount {
                frameValues[channel] = Double(input.data[base + channel]) * inputGain
            }

            for nodeIndex in nodes.indices {
                switch nodes[nodeIndex].effect {
                case .some(.flatGain):
                    let gain = nodes[nodeIndex].flatGain ?? 1
                    for channel in 0..<channelCount where nodes[nodeIndex].channelMask[channel] {
                        frameValues[channel] *= gain
                    }
                case .some(.stereoWidth):
                    nodes[nodeIndex].stereoWidthKernel?.processFrame(&frameValues)
                case .some(.virtualBass):
                    nodes[nodeIndex].virtualBassKernel?.processFrame(&frameValues)
                case .some(.tube):
                    nodes[nodeIndex].tubeKernel?.processFrame(&frameValues)
                case .some(.script):
                    nodes[nodeIndex].scriptRuntime?.processFrame(&frameValues)
                case nil:
                    for channel in 0..<channelCount where nodes[nodeIndex].channelMask[channel] {
                        var sample = frameValues[channel]
                        for filterIndex in nodes[nodeIndex].filters.indices {
                            sample = nodes[nodeIndex].filters[filterIndex].process(sample, channel: channel)
                        }
                        frameValues[channel] = sample
                    }
                }
            }

            for channel in 0..<channelCount {
                let sample = frameValues[channel] * outputGain
                guard sample.isFinite, abs(sample) <= Double(Float.greatestFiniteMagnitude) else {
                    outputFault = DSPDiagnostic(code: "dsp.nonFiniteChainOutput",
                        message: "The DSP chain output exceeds finite Float32 audio and was bypassed.",
                        fieldPath: "processing.output", retryable: true)
                    collectScriptFaults(from: nodes)
                    return
                }
                output[base + channel] = Float(sample)
            }
        }
        collectScriptFaults(from: nodes)
    }

    private static func resetRuntimeStates(_ nodes: inout [RuntimeNode]) {
        for nodeIndex in nodes.indices {
            for filterIndex in nodes[nodeIndex].filters.indices {
                nodes[nodeIndex].filters[filterIndex].reset()
            }
            nodes[nodeIndex].virtualBassKernel?.reset()
            nodes[nodeIndex].tubeKernel?.reset()
            nodes[nodeIndex].scriptRuntime?.reset()
        }
    }

    private static func copyRuntimeStates(from source: [RuntimeNode], to destination: inout [RuntimeNode], previewFrames: Int) {
        guard source.count == destination.count else { return }
        for nodeIndex in source.indices {
            guard source[nodeIndex].nodeID == destination[nodeIndex].nodeID else { return }
            for filterIndex in source[nodeIndex].filters.indices {
                guard source[nodeIndex].filters.indices.contains(filterIndex),
                      destination[nodeIndex].filters.indices.contains(filterIndex) else { continue }
                for index in source[nodeIndex].filters[filterIndex].state1.indices {
                    destination[nodeIndex].filters[filterIndex].state1[index]
                        = source[nodeIndex].filters[filterIndex].state1[index]
                }
                for index in source[nodeIndex].filters[filterIndex].state2.indices {
                    destination[nodeIndex].filters[filterIndex].state2[index]
                        = source[nodeIndex].filters[filterIndex].state2[index]
                }
            }
            if let sourceBass = source[nodeIndex].virtualBassKernel {
                destination[nodeIndex].virtualBassKernel?.copyState(from: sourceBass)
            }
            if let sourceTube = source[nodeIndex].tubeKernel {
                destination[nodeIndex].tubeKernel?.copyState(from: sourceTube)
            }
            if let sourceScript = source[nodeIndex].scriptRuntime {
                destination[nodeIndex].scriptRuntime?.copyState(from: sourceScript, previewFrames: previewFrames)
            }
        }
    }

    private static func makeFreshRuntimeState(_ source: RuntimeNode) -> RuntimeNode {
        var fresh = source
        for index in fresh.filters.indices {
            fresh.filters[index].reset()
        }
        fresh.virtualBassKernel = source.virtualBassKernel?.makeFreshState()
        fresh.tubeKernel = source.tubeKernel?.makeFreshState()
        fresh.scriptRuntime = source.scriptRuntime?.makeFreshState()
        return fresh
    }

    private func collectScriptFaults(from nodes: [RuntimeNode]) {
        for node in nodes {
            guard let runtime = node.scriptRuntime, runtime.isFaulted,
                  var diagnostic = runtime.diagnostic else { continue }
            diagnostic.nodeID = node.nodeID
            diagnostic.fieldPath = "nodes[\(node.nodeID.uuidString)].runtime"
            scriptFaults[node.nodeID] = diagnostic
        }
    }

    private static func prepareScriptNode(
        _ node: DSPNodeConfiguration, format: DSPAudioFormat, warnings: inout [DSPDiagnostic]
    ) -> RuntimeNode? {
        do {
            guard node.quality == "standard", let parameters = node.scriptParameters,
                  DSPNodeConfiguration.supportedChannelPolicies(forTypeID: node.typeID).contains(node.channelPolicy) else {
                throw DSPScriptCompilationError(diagnostics: [DSPDiagnostic(code: "dsp.scriptConfiguration",
                    message: "The script configuration is incomplete or unsupported.")])
            }
            let mask: [Bool]
            if node.channelPolicy == "allChannels" {
                mask = Array(repeating: true, count: format.channelCount)
            } else {
                guard format.layoutIsKnown, let labels = format.channelLabels,
                      labels.count == format.channelCount else {
                    warnings.append(DSPDiagnostic(code: "dsp.scriptLayoutUnsupported",
                        message: "The script requires a complete channel map or explicit allChannels policy.",
                        fieldPath: "nodes[\(node.nodeID.uuidString)].channelPolicy", nodeID: node.nodeID))
                    return nil
                }
                let lfe: Set<UInt32> = [UInt32(kAudioChannelLabel_LFEScreen), UInt32(kAudioChannelLabel_LFE2), UInt32(kAudioChannelLabel_LFE3)]
                mask = labels.map { !lfe.contains($0) }
            }
            guard mask.contains(true) else { return nil }
            let program = try DSPScriptCompiler.compile(source: parameters.source,
                languageVersion: parameters.languageVersion, parameterValues: parameters.values, format: format)
            return RuntimeNode(nodeID: node.nodeID, channelMask: mask, contributesToHeadroom: false,
                staticPeakResponseDB: 0, filters: [], effect: .script,
                scriptRuntime: DSPScriptRuntime(program: program, channelMask: mask),
                scriptLatencyFrames: program.latencyFrames,
                scriptEstimatedOperationsPerSecond: Double(program.weightedOperationsPerFrame)
                    * format.sampleRate * Double(format.channelCount))
        } catch {
            let diagnostics = (error as? DSPScriptCompilationError)?.diagnostics ?? [DSPDiagnostic(
                code: "dsp.scriptPreparation", message: "The script could not be prepared.")]
            warnings.append(contentsOf: diagnostics.map { value in
                var diagnostic = value
                diagnostic.nodeID = node.nodeID
                diagnostic.fieldPath = "nodes[\(node.nodeID.uuidString)].parameters.source"
                return diagnostic
            })
            return nil
        }
    }

    private static func isNativeEffect(_ typeID: String) -> Bool {
        typeID == DSPNodeConfiguration.stereoWidthTypeID
            || typeID == DSPNodeConfiguration.virtualBassTypeID
            || typeID == DSPNodeConfiguration.tubeTypeID
    }

    private static func prepareNativeNode(
        _ node: DSPNodeConfiguration,
        format: DSPAudioFormat,
        warnings: inout [DSPDiagnostic]
    ) -> RuntimeNode? {
        let basePath = "nodes[\(node.nodeID.uuidString)].parameters"
        func warn(_ code: String, _ message: String, field: String) {
            warnings.append(DSPDiagnostic(
                code: code,
                message: message,
                fieldPath: field,
                nodeID: node.nodeID,
                retryable: false
            ))
        }
        func bounded(_ value: Double, range: ClosedRange<Double>, key: String) -> Double? {
            guard value.isFinite else {
                warn(
                    "invalidNativeParameter",
                    "The native effect was bypassed because a parameter is not finite.",
                    field: "\(basePath).\(key)"
                )
                return nil
            }
            let result = min(max(range.lowerBound, value), range.upperBound)
            if abs(result - value) > 1e-9 {
                warn(
                    "nativeParameterNormalized",
                    "The native effect parameter was bounded to its supported range.",
                    field: "\(basePath).\(key)"
                )
            }
            return result
        }
        func rejectPolicy() {
            warn(
                "unsupportedChannelPolicy",
                "The effect was bypassed because its channel policy is not supported.",
                field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
            )
        }
        func rejectQuality() {
            warn(
                "unsupportedQuality",
                "The effect was bypassed because its quality setting is not supported.",
                field: "nodes[\(node.nodeID.uuidString)].quality"
            )
        }
        func invalidParameters() {
            warn(
                "invalidNativeParameterSet",
                "The native effect was bypassed because its parameters are incomplete or invalid.",
                field: basePath
            )
        }

        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0 else {
            warn(
                "invalidDSPFormat",
                "The native effect was bypassed because the source format is invalid.",
                field: "format"
            )
            return nil
        }

        let labels = format.channelLabels
        let hasCompleteLayout = format.layoutIsKnown && labels?.count == format.channelCount
        let channelLabels = hasCompleteLayout ? labels : nil
        let leftLabel = UInt32(kAudioChannelLabel_Left)
        let rightLabel = UInt32(kAudioChannelLabel_Right)
        let lfeLabels: Set<UInt32> = [
            UInt32(kAudioChannelLabel_LFEScreen),
            UInt32(kAudioChannelLabel_LFE2),
            UInt32(kAudioChannelLabel_LFE3),
        ]
        func frontPairMask() -> [Bool]? {
            guard let channelLabels else { return nil }
            let left = channelLabels.indices.filter { channelLabels[$0] == leftLabel }
            let right = channelLabels.indices.filter { channelLabels[$0] == rightLabel }
            guard left.count == 1, right.count == 1 else { return nil }
            var mask = Array(repeating: false, count: format.channelCount)
            mask[left[0]] = true
            mask[right[0]] = true
            return mask
        }

        let channelMask: [Bool]
        switch node.typeID {
        case DSPNodeConfiguration.stereoWidthTypeID:
            guard node.channelPolicy == "frontPair" else {
                rejectPolicy()
                return nil
            }
            guard let mask = frontPairMask() else {
                warn(
                    "frontStereoPairUnavailable",
                    "Stereo width was bypassed because the source has no explicit left and right channels.",
                    field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                )
                return nil
            }
            channelMask = mask

        case DSPNodeConfiguration.virtualBassTypeID:
            switch node.channelPolicy {
            case "frontPair":
                guard let mask = frontPairMask() else {
                    warn(
                        "frontStereoPairUnavailable",
                        "Virtual bass was bypassed because the source has no explicit left and right channels.",
                        field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                    )
                    return nil
                }
                channelMask = mask
            case "fullRange":
                guard hasCompleteLayout, format.channelCount <= 2,
                      let channelLabels,
                      (format.channelCount == 1
                        ? channelLabels[0] == UInt32(kAudioChannelLabel_Mono)
                        : Set(channelLabels) == Set([leftLabel, rightLabel])) else {
                    warn(
                        "virtualBassLayoutUnsupported",
                        "Virtual bass full-range processing requires a known mono or stereo source.",
                        field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                    )
                    return nil
                }
                channelMask = Array(repeating: true, count: format.channelCount)
            default:
                rejectPolicy()
                return nil
            }

        case DSPNodeConfiguration.tubeTypeID:
            switch node.channelPolicy {
            case "allChannels":
                channelMask = Array(repeating: true, count: format.channelCount)
            case "fullRange":
                guard hasCompleteLayout, let channelLabels else {
                    warn(
                        "unknownChannelLayout",
                        "Tube processing was bypassed because the source has no complete channel map.",
                        field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                    )
                    return nil
                }
                channelMask = channelLabels.map { !lfeLabels.contains($0) }
            default:
                rejectPolicy()
                return nil
            }

        default:
            return nil
        }
        guard channelMask.contains(true) else {
            warn(
                "emptyChannelSelection",
                "The effect was bypassed because its channel policy selects no channels.",
                field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
            )
            return nil
        }

        let emptyNode = RuntimeNode(
            nodeID: node.nodeID,
            channelMask: channelMask,
            contributesToHeadroom: true,
            staticPeakResponseDB: 0,
            filters: [],
            effect: nil,
            flatGain: nil,
            stereoWidthKernel: nil,
            virtualBassKernel: nil,
            tubeKernel: nil
        )

        switch node.typeID {
        case DSPNodeConfiguration.stereoWidthTypeID:
            guard node.quality == "standard" else {
                rejectQuality()
                return nil
            }
            guard let raw = node.stereoWidthParameters,
                  let width = bounded(raw.width, range: DSPStereoWidthParameters.widthRange, key: "width"),
                  let outputTrimDB = bounded(
                    raw.outputTrimDB,
                    range: DSPStereoWidthParameters.outputTrimRange,
                    key: "outputTrimDB"
                  ) else {
                invalidParameters()
                return nil
            }
            if abs(width - 1) < 1e-12, abs(outputTrimDB) < 1e-12 { return nil }
            var runtimeNode = emptyNode
            runtimeNode.staticPeakResponseDB = 20 * log10(max(1, width)) + outputTrimDB
            if abs(width - 1) < 1e-12 {
                runtimeNode.effect = .flatGain
                runtimeNode.flatGain = pow(10, outputTrimDB / 20)
                return runtimeNode
            }
            guard let pair = frontPairMask(),
                  let channelLabels,
                  let left = pair.indices.first(where: { pair[$0] && channelLabels[$0] == leftLabel }),
                  let right = pair.indices.first(where: { pair[$0] && channelLabels[$0] == rightLabel }) else {
                return nil
            }
            runtimeNode.effect = .stereoWidth
            runtimeNode.stereoWidthKernel = DSPStereoWidthKernel(
                leftChannel: left,
                rightChannel: right,
                width: width,
                outputGain: pow(10, outputTrimDB / 20)
            )
            return runtimeNode

        case DSPNodeConfiguration.virtualBassTypeID:
            guard node.quality == "oversampling2x" || node.quality == "oversampling4x" else {
                rejectQuality()
                return nil
            }
            guard let raw = node.virtualBassParameters,
                  let lowFrequencyHz = bounded(
                    raw.lowFrequencyHz,
                    range: DSPVirtualBassParameters.lowFrequencyRange,
                    key: "lowFrequencyHz"
                  ),
                  let highFrequencyHz = bounded(
                    raw.highFrequencyHz,
                    range: DSPVirtualBassParameters.highFrequencyRange,
                    key: "highFrequencyHz"
                  ),
                  let amount = bounded(raw.amount, range: DSPVirtualBassParameters.amountRange, key: "amount"),
                  let driveDB = bounded(raw.driveDB, range: DSPVirtualBassParameters.driveRange, key: "driveDB"),
                  let harmonics = bounded(
                    raw.harmonics,
                    range: DSPVirtualBassParameters.harmonicsRange,
                    key: "harmonics"
                  ),
                  let mix = bounded(raw.mix, range: DSPVirtualBassParameters.mixRange, key: "mix"),
                  let outputTrimDB = bounded(
                    raw.outputTrimDB,
                    range: DSPVirtualBassParameters.outputTrimRange,
                    key: "outputTrimDB"
                  ),
                  lowFrequencyHz < highFrequencyHz else {
                invalidParameters()
                return nil
            }
            let wetGain = amount * mix
            if wetGain == 0 {
                return nil
            }
            let parameters = DSPVirtualBassParameters(
                lowFrequencyHz: lowFrequencyHz,
                highFrequencyHz: highFrequencyHz,
                amount: amount,
                driveDB: driveDB,
                harmonics: harmonics,
                mix: mix,
                outputTrimDB: outputTrimDB
            )
            let factor = node.quality == "oversampling4x" ? 4 : 2
            guard let kernel = DSPVirtualBassKernel(
                format: format,
                selectedChannels: channelMask,
                parameters: parameters,
                factor: factor
            ) else {
                warn(
                    "nativeKernelPreparationFailed",
                    "Virtual bass could not prepare stable filters for this source format.",
                    field: basePath
                )
                return nil
            }
            var runtimeNode = emptyNode
            runtimeNode.effect = .virtualBass
            runtimeNode.virtualBassKernel = kernel
            let drive = pow(10, driveDB / 20)
            let evenBound = 1 / max(1e-12, pow(tanh(drive), 2))
            runtimeNode.staticPeakResponseDB = 20 * log10(1 + wetGain * 4 * evenBound) + outputTrimDB
            warn(
                "nonlinearPeakGuaranteeUnavailable",
                "Virtual bass uses static headroom only; it has no peak guarantee.",
                field: basePath
            )
            return runtimeNode

        case DSPNodeConfiguration.tubeTypeID:
            guard node.quality == "oversampling2x" || node.quality == "oversampling4x" else {
                rejectQuality()
                return nil
            }
            guard let raw = node.tubeParameters,
                  let driveDB = bounded(raw.driveDB, range: DSPTubeParameters.driveRange, key: "driveDB"),
                  let bias = bounded(raw.bias, range: DSPTubeParameters.biasRange, key: "bias"),
                  let mix = bounded(raw.mix, range: DSPTubeParameters.mixRange, key: "mix"),
                  let inputTrimDB = bounded(
                    raw.inputTrimDB,
                    range: DSPTubeParameters.inputTrimRange,
                    key: "inputTrimDB"
                  ),
                  let outputTrimDB = bounded(
                    raw.outputTrimDB,
                    range: DSPTubeParameters.outputTrimRange,
                    key: "outputTrimDB"
                  ),
                  let dcBlockHz = bounded(
                    raw.dcBlockHz,
                    range: DSPTubeParameters.dcBlockFrequencyRange,
                    key: "dcBlockHz"
                  ) else {
                invalidParameters()
                return nil
            }
            if mix == 0 {
                return nil
            }
            let parameters = DSPTubeParameters(
                driveDB: driveDB,
                bias: bias,
                mix: mix,
                inputTrimDB: inputTrimDB,
                outputTrimDB: outputTrimDB,
                dcRemovalEnabled: raw.dcRemovalEnabled,
                dcBlockHz: dcBlockHz
            )
            let factor = node.quality == "oversampling4x" ? 4 : 2
            guard let kernel = DSPTubeKernel(
                format: format,
                selectedChannels: channelMask,
                parameters: parameters,
                factor: factor
            ) else {
                warn(
                    "nativeKernelPreparationFailed",
                    "Tube processing could not prepare for this source format.",
                    field: basePath
                )
                return nil
            }
            var runtimeNode = emptyNode
            runtimeNode.effect = .tube
            runtimeNode.tubeKernel = kernel
            let drive = pow(10, driveDB / 20)
            let biasedSlope = max(1e-12, drive * (1 - pow(tanh(bias), 2)))
            let shapedBound = (1 + abs(tanh(bias))) / biasedSlope
            let dcBound = raw.dcRemovalEnabled ? 2.0 : 1.0
            runtimeNode.staticPeakResponseDB = 20 * log10(1 + mix * shapedBound * dcBound) + outputTrimDB
            warn(
                "nonlinearPeakGuaranteeUnavailable",
                "Tube processing uses static headroom only; it has no peak guarantee.",
                field: basePath
            )
            return runtimeNode

        default:
            return nil
        }
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
        sampleRate: Double,
        context: DSPEqualLoudnessContext
    ) -> Double {
        var pathNodeIDs = [[UUID]]()
        var seenPaths = Set<String>()
        for channel in 0..<channelCount {
            let nodeIDs = preparedNodes.compactMap { node in
                node.channelMask[channel] && node.contributesToHeadroom ? node.nodeID : nil
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
            let linearPeakDB = DSPParametricEQMath.estimatedPeakResponseDB(
                configuration: pathConfiguration,
                context: context,
                sampleRate: sampleRate
            )
            let nativePeakDB = preparedNodes.reduce(0.0) { total, node in
                includedNodeIDs.contains(node.nodeID) ? total + node.staticPeakResponseDB : total
            }
            peakDB = max(peakDB, linearPeakDB + nativePeakDB)
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

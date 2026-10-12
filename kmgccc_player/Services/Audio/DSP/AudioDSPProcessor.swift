import AVFoundation
import Accelerate
import Foundation

/// Pipeline-confined runtime for the currently supported DSP node set.
/// Coefficients, channel routing, headroom and filter state are prepared once.
/// `process(_:lookahead:)` advances source state once and previews only the
/// future frames required to return PCM at its original media time.
nonisolated final class AudioDSPProcessor: @unchecked Sendable {
    fileprivate struct RuntimeFilter {
        static let defaultRampFrames = 128

        let bandIndex: Int
        let coefficients: DSPBiquadCoefficients
        /// Coefficient glide length used when this filter takes over from a
        /// previous processor's state.
        let rampLength: Int
        var delay: [Double]
        var rampStart: DSPBiquadCoefficients?
        var rampRemaining = 0

        init(bandIndex: Int, coefficients: DSPBiquadCoefficients, rampLength: Int = Self.defaultRampFrames, delay: [Double]) {
            self.bandIndex = bandIndex
            self.coefficients = coefficients
            self.rampLength = max(1, rampLength)
            self.delay = delay
        }

        /// An identity filter with settled state is exactly a pass-through.
        var isIdle: Bool {
            rampRemaining == 0 && coefficients.isIdentity && delay.allSatisfy { $0 == 0 }
        }

        mutating func processBlock(_ samples: inout [Double], frames: Int, channels: Int, mask: [Bool]) {
            guard !isIdle else { return }
            let target = coefficients
            let start = rampStart ?? target
            let remaining = rampRemaining
            let length = rampLength
            delay.withUnsafeMutableBufferPointer { state in
                samples.withUnsafeMutableBufferPointer { buffer in
                    for channel in 0..<channels where mask[channel] {
                        var z1 = state[channel * 2]
                        var z2 = state[channel * 2 + 1]
                        let rampFrames = min(frames, remaining)
                        for frame in 0..<rampFrames {
                            let c = Self.interpolated(start, target, remaining: remaining - frame, length: length)
                            let offset = frame * channels + channel
                            let input = buffer[offset]
                            let output = c.b0 * input + z1
                            z1 = c.b1 * input - c.a1 * output + z2
                            z2 = c.b2 * input - c.a2 * output
                            buffer[offset] = output
                        }
                        for frame in rampFrames..<frames {
                            let offset = frame * channels + channel
                            let input = buffer[offset]
                            let output = target.b0 * input + z1
                            z1 = target.b1 * input - target.a1 * output + z2
                            z2 = target.b2 * input - target.a2 * output
                            buffer[offset] = output
                        }
                        state[channel * 2] = z1
                        state[channel * 2 + 1] = z2
                    }
                }
            }
            rampRemaining = max(0, remaining - frames)
            if rampRemaining == 0 { rampStart = nil }
        }

        mutating func reset() {
            for index in delay.indices { delay[index] = 0 }
            rampStart = nil
            rampRemaining = 0
        }

        private static func interpolated(
            _ start: DSPBiquadCoefficients,
            _ end: DSPBiquadCoefficients,
            remaining: Int,
            length: Int
        ) -> DSPBiquadCoefficients {
            guard remaining > 0, length > 0 else { return end }
            let t = Double(length + 1 - remaining) / Double(length)
            return DSPBiquadCoefficients(b0: start.b0 + (end.b0 - start.b0) * t,
                b1: start.b1 + (end.b1 - start.b1) * t, b2: start.b2 + (end.b2 - start.b2) * t,
                a1: start.a1 + (end.a1 - start.a1) * t, a2: start.a2 + (end.a2 - start.a2) * t)
        }

        mutating func restore(from source: RuntimeFilter) {
            delay = source.delay
            if coefficients == source.coefficients {
                rampStart = source.rampStart
                rampRemaining = source.rampRemaining
            } else {
                rampStart = Self.interpolated(source.rampStart ?? source.coefficients,
                    source.coefficients, remaining: source.rampRemaining, length: source.rampLength)
                rampRemaining = rampLength
            }
        }

        /// A filter that did not exist before glides in from a flat response.
        mutating func rampFromIdentity() {
            guard !coefficients.isIdentity else { return }
            rampStart = .identity
            rampRemaining = rampLength
        }
    }

    fileprivate struct RuntimeNode {
        let nodeID: UUID
        var typeID: String = ""
        var configurationParameters: [String: DSPJSONValue] = [:]
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

    fileprivate enum RuntimeEffect {
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

    /// The automatic estimate is a static worst case that stacks the peak of
    /// every stage. Compensating it without a bound silences any chain with a
    /// few boosted stages, so the broadband cut stops here and reports the rest.
    static let maximumAutomaticHeadroomDB = 12.0

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
    private let configuration: AudioDSPConfiguration
    private var nodes: [RuntimeNode]
    private var previewNodes: [RuntimeNode]
    private var frameScratch: [Double] = []
    private var sampleScratch: [Double] = []
    private var futureInputScratch: [Float] = []
    private var futureOutputScratch: [Float] = []
    private var warmupScratch: [Float] = []

    /// Immutable source-time state. Large script delay lines use history replay
    /// instead of imposing a multi-megabyte copy on every playback block.
    struct StateSnapshot: @unchecked Sendable {
        fileprivate let configuration: AudioDSPConfiguration
        fileprivate let nodes: [RuntimeNode]
        fileprivate let format: DSPAudioFormat

        func matches(_ candidate: AudioDSPConfiguration) -> Bool {
            let old = configuration.enabled ? configuration.nodes.filter(\.enabled) : []
            let new = candidate.enabled ? candidate.nodes.filter(\.enabled) : []
            return old.count == new.count && zip(old, new).allSatisfy {
                $0.nodeID == $1.nodeID && $0.typeID == $1.typeID
                    && $0.algorithmVersion == $1.algorithmVersion
                    && $0.quality == $1.quality && $0.channelPolicy == $1.channelPolicy
                    && ($0.typeID != DSPNodeConfiguration.scriptTypeID || $0.parameters == $1.parameters)
            }
        }
    }

    func stateSnapshot() -> StateSnapshot? {
        let scriptBytes = nodes.reduce(0) { $0 + ($1.scriptRuntime?.program.stateBytes ?? 0) }
        guard scriptBytes <= 64 * 1_024 else { return nil }
        return StateSnapshot(configuration: configuration, nodes: nodes, format: format)
    }

    /// Parameter-channel handover. Every node that still exists keeps its
    /// filter, oversampler and delay state; changed coefficients glide from
    /// the old values and newly switched-on filters glide in from a flat
    /// response. A script whose values changed starts fresh, because its
    /// prepare block gives no continuity guarantee; the renderer's short
    /// output crossfade covers that node.
    func inheritState(from source: AudioDSPProcessor) {
        guard source.format == format else { return }
        for index in nodes.indices {
            guard let old = source.nodes.first(where: {
                $0.nodeID == nodes[index].nodeID && $0.typeID == nodes[index].typeID
            }), old.channelMask == nodes[index].channelMask else {
                for filterIndex in nodes[index].filters.indices {
                    nodes[index].filters[filterIndex].rampFromIdentity()
                }
                continue
            }
            for filterIndex in nodes[index].filters.indices {
                if let filter = old.filters.first(where: { $0.bandIndex == nodes[index].filters[filterIndex].bandIndex }) {
                    nodes[index].filters[filterIndex].restore(from: filter)
                } else {
                    nodes[index].filters[filterIndex].rampFromIdentity()
                }
            }
            if let bass = old.virtualBassKernel { nodes[index].virtualBassKernel?.copyState(from: bass) }
            if let tube = old.tubeKernel { nodes[index].tubeKernel?.copyState(from: tube) }
            if let script = old.scriptRuntime,
               old.configurationParameters == nodes[index].configurationParameters {
                nodes[index].scriptRuntime?.copyState(from: script)
            }
        }
    }

    /// True when every prepared node is a settled pass-through.
    private static func hasAudibleWork(_ nodes: [RuntimeNode]) -> Bool {
        nodes.contains { node in
            node.effect != nil || node.filters.contains { !$0.coefficients.isIdentity }
        }
    }

    @discardableResult
    func restoreState(_ snapshot: StateSnapshot) -> Bool {
        guard snapshot.format == format, snapshot.matches(configuration) else { return false }
        for index in nodes.indices {
            guard let old = snapshot.nodes.first(where: { $0.nodeID == nodes[index].nodeID }),
                  old.channelMask == nodes[index].channelMask else { continue }
            for filterIndex in nodes[index].filters.indices {
                if let filter = old.filters.first(where: { $0.bandIndex == nodes[index].filters[filterIndex].bandIndex }) {
                    nodes[index].filters[filterIndex].restore(from: filter)
                }
            }
            if let bass = old.virtualBassKernel { nodes[index].virtualBassKernel?.copyState(from: bass) }
            if let tube = old.tubeKernel { nodes[index].tubeKernel?.copyState(from: tube) }
            if let script = old.scriptRuntime { nodes[index].scriptRuntime?.copyState(from: script) }
        }
        return true
    }

    var needsWarmup: Bool {
        nodes.contains { !$0.filters.isEmpty || $0.virtualBassKernel != nil || $0.tubeKernel != nil || $0.scriptRuntime != nil }
    }

    init(
        configuration: AudioDSPConfiguration,
        format: DSPAudioFormat,
        context: DSPEqualLoudnessContext = .inactive
    ) {
        self.format = format
        self.configuration = configuration

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
                    if var preparedNode = Self.prepareScriptNode(node, format: format, warnings: &warnings) {
                        preparedNode.typeID = node.typeID
                        preparedNode.configurationParameters = node.parameters
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
                    if var preparedNode = Self.prepareNativeNode(
                        node,
                        format: format,
                        warnings: &warnings
                    ) {
                        preparedNode.typeID = node.typeID
                        preparedNode.configurationParameters = node.parameters
                        preparedNodes.append(preparedNode)
                    }
                    continue
                }

                // The channel scope follows the source: a scope it cannot
                // honour widens to every channel instead of dropping the node.
                let policy = DSPNodeConfiguration.effectiveChannelPolicy(
                    forTypeID: node.typeID,
                    requested: node.channelPolicy,
                    format: format
                )
                let channelMask: [Bool]
                if policy == "fullRange", let fullRange = format.fullRangeChannelMask {
                    channelMask = fullRange
                } else {
                    channelMask = Array(repeating: true, count: format.channelCount)
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

                // Equal-loudness shelves stay in the chain at 0 dB so a volume
                // change glides their coefficients instead of adding or
                // removing a filter. A settled flat shelf costs nothing.
                let isEqualLoudness = node.typeID == DSPNodeConfiguration.equalLoudnessTypeID
                let rampLength = isEqualLoudness
                    ? max(RuntimeFilter.defaultRampFrames, Int((format.sampleRate * 0.08).rounded()))
                    : RuntimeFilter.defaultRampFrames
                var filters: [RuntimeFilter] = []
                filters.reserveCapacity(bands.count)
                for (bandIndex, band) in bands.enumerated() where band.enabled || isEqualLoudness {
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
                    guard !coefficients.isIdentity || isEqualLoudness else { continue }
                    filters.append(RuntimeFilter(
                        bandIndex: bandIndex,
                        coefficients: coefficients,
                        rampLength: rampLength,
                        delay: Array(repeating: 0, count: format.channelCount * 2)
                    ))
                }

                if !filters.isEmpty, channelMask.contains(true) {
                    preparedNodes.append(RuntimeNode(
                        nodeID: node.nodeID,
                        typeID: node.typeID,
                        configurationParameters: node.parameters,
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
        let hasHeadroomNodeWork = preparedNodes.contains { node in
            node.contributesToHeadroom
                && (node.effect != nil || node.filters.contains { !$0.coefficients.isIdentity })
        }
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
                let requiredDB = max(0, estimatedPeakDB) + marginDB
                if requiredDB > Self.maximumAutomaticHeadroomDB {
                    automaticHeadroomDB = -Self.maximumAutomaticHeadroomDB
                    warnings.append(DSPDiagnostic(
                        code: "headroomLimited",
                        message: "Automatic headroom was limited to \(Int(Self.maximumAutomaticHeadroomDB)) dB.",
                        fieldPath: "headroom",
                        retryable: false
                    ))
                } else {
                    automaticHeadroomDB = -requiredDB
                }
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
            || (!Self.hasAudibleWork(preparedNodes)
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
            processCore(pcm, nodes: &nodes, output: &warmupScratch, frameValues: &frameScratch,
                samples: &sampleScratch, discardOutput: true)
        }
    }

    /// Process input-time PCM and use up to one processing-latency of future PCM
    /// to return an output block mapped to the input's original presentation time.
    /// A missing or short lookahead is zero-filled, which is the EOF behavior.
    func process(_ input: CanonicalPCM, lookahead: CanonicalPCM? = nil) -> CanonicalPCM {
        guard isCompatible(input), input.frames > 0 else { return input }
        guard !isBypassed, outputFault == nil else { return input }

        var currentOutput: [Float] = []
        processCore(input, nodes: &nodes, output: &currentOutput, frameValues: &frameScratch, samples: &sampleScratch)
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
        processCore(
            futureInput,
            nodes: &previewNodes,
            output: &futureOutputScratch,
            frameValues: &frameScratch,
            samples: &sampleScratch
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
                    currentOutput[destinationOffset + channel] = futureOutputScratch[sourceOffset + channel]
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
        frameValues: inout [Double],
        samples: inout [Double],
        discardOutput: Bool = false
    ) {
        let count = input.frames * input.channelCount
        guard count > 0, outputFault == nil else { return }
        if samples.count != count { samples = Array(repeating: 0, count: count) }
        if frameValues.count != input.channelCount {
            frameValues = Array(repeating: 0, count: input.channelCount)
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            input.data.withUnsafeBufferPointer { source in
                vDSP_vspdp(source.baseAddress!, 1, buffer.baseAddress!, 1, vDSP_Length(count))
            }
            if inputGain != 1 {
                var gain = inputGain
                vDSP_vsmulD(buffer.baseAddress!, 1, &gain, buffer.baseAddress!, 1, vDSP_Length(count))
            }
        }
        let channels = input.channelCount
        // Node/filter dispatch and recursive state access happen once per block.
        // Each biquad holds its two delays in scalars through the sample loop.
        for index in nodes.indices {
            switch nodes[index].effect {
            case nil:
                let mask = nodes[index].channelMask
                for filter in nodes[index].filters.indices {
                    nodes[index].filters[filter].processBlock(&samples, frames: input.frames, channels: channels, mask: mask)
                }
            case .some(.flatGain):
                let gain = nodes[index].flatGain ?? 1
                let mask = nodes[index].channelMask
                samples.withUnsafeMutableBufferPointer { buffer in
                    for channel in 0..<channels where mask[channel] {
                        for frame in 0..<input.frames { buffer[frame * channels + channel] *= gain }
                    }
                }
            case .some(.stereoWidth):
                if let kernel = nodes[index].stereoWidthKernel {
                    kernel.processBlock(&samples, frames: input.frames, channels: channels)
                }
            case .some(.virtualBass), .some(.tube), .some(.script):
                for frame in 0..<input.frames {
                    let offset = frame * channels
                    for channel in 0..<channels { frameValues[channel] = samples[offset + channel] }
                    switch nodes[index].effect {
                    case .some(.virtualBass): nodes[index].virtualBassKernel?.processFrame(&frameValues)
                    case .some(.tube): nodes[index].tubeKernel?.processFrame(&frameValues)
                    case .some(.script): nodes[index].scriptRuntime?.processFrame(&frameValues)
                    default: break
                    }
                    for channel in 0..<channels { samples[offset + channel] = frameValues[channel] }
                }
            }
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            if outputGain != 1 {
                var gain = outputGain
                vDSP_vsmulD(buffer.baseAddress!, 1, &gain, buffer.baseAddress!, 1, vDSP_Length(count))
            }
        }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) }) else {
            outputFault = DSPDiagnostic(code: "dsp.nonFiniteChainOutput",
                message: "The DSP chain output exceeds finite Float32 audio and was bypassed.",
                fieldPath: "processing.output", retryable: true)
            collectScriptFaults(from: nodes)
            return
        }
        if !discardOutput {
            if output.count != count { output = Array(repeating: 0, count: count) }
            samples.withUnsafeBufferPointer { buffer in
                output.withUnsafeMutableBufferPointer { destination in
                    vDSP_vdpsp(buffer.baseAddress!, 1, destination.baseAddress!, 1, vDSP_Length(count))
                }
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
                let sourceFilter = source[nodeIndex].filters[filterIndex]
                for index in sourceFilter.delay.indices {
                    destination[nodeIndex].filters[filterIndex].delay[index] = sourceFilter.delay[index]
                }
                destination[nodeIndex].filters[filterIndex].rampStart = sourceFilter.rampStart
                destination[nodeIndex].filters[filterIndex].rampRemaining = sourceFilter.rampRemaining
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
            guard node.quality == "standard", let parameters = node.scriptParameters else {
                throw DSPScriptCompilationError(diagnostics: [DSPDiagnostic(code: "dsp.scriptConfiguration",
                    message: "The script configuration is incomplete or unsupported.")])
            }
            let policy = DSPNodeConfiguration.effectiveChannelPolicy(
                forTypeID: node.typeID,
                requested: node.channelPolicy,
                format: format
            )
            let mask: [Bool]
            if policy == "fullRange", let fullRange = format.fullRangeChannelMask {
                mask = fullRange
            } else {
                mask = Array(repeating: true, count: format.channelCount)
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

        func frontPairMask() -> [Bool]? {
            guard let pair = format.frontStereoPair else { return nil }
            var mask = Array(repeating: false, count: format.channelCount)
            mask[pair.left] = true
            mask[pair.right] = true
            return mask
        }

        let policy = DSPNodeConfiguration.effectiveChannelPolicy(
            forTypeID: node.typeID,
            requested: node.channelPolicy,
            format: format
        )
        let channelMask: [Bool]
        switch node.typeID {
        case DSPNodeConfiguration.stereoWidthTypeID:
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
            if policy == "frontPair", let mask = frontPairMask() {
                channelMask = mask
            } else {
                guard format.isMonoOrStereoLayout else {
                    warn(
                        "virtualBassLayoutUnsupported",
                        "Virtual bass requires an identifiable front pair or a mono or stereo source.",
                        field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                    )
                    return nil
                }
                channelMask = Array(repeating: true, count: format.channelCount)
            }

        case DSPNodeConfiguration.tubeTypeID:
            if policy == "fullRange", let fullRange = format.fullRangeChannelMask {
                channelMask = fullRange
            } else {
                channelMask = Array(repeating: true, count: format.channelCount)
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
            guard let pair = format.frontStereoPair else { return nil }
            runtimeNode.effect = .stereoWidth
            runtimeNode.stereoWidthKernel = DSPStereoWidthKernel(
                leftChannel: pair.left,
                rightChannel: pair.right,
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
                guard outputTrimDB != 0 else { return nil }
                var runtimeNode = emptyNode
                runtimeNode.effect = .flatGain
                runtimeNode.flatGain = pow(10, outputTrimDB / 20)
                runtimeNode.staticPeakResponseDB = outputTrimDB
                return runtimeNode
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
                guard outputTrimDB != 0 else { return nil }
                var runtimeNode = emptyNode
                runtimeNode.effect = .flatGain
                runtimeNode.flatGain = pow(10, outputTrimDB / 20)
                runtimeNode.staticPeakResponseDB = outputTrimDB
                return runtimeNode
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

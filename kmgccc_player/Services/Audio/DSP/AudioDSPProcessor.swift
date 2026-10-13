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
        /// Broadband gain the node adds to its selected channels (its output
        /// trim). Level-referenced nodes downstream cancel it.
        var levelOffsetDB: Double = 0
        var filters: [RuntimeFilter]
        var effect: RuntimeEffect?
        var flatGain: Double?
        var tubeKernel: DSPTubeKernel?
        var blockKernel: DSPEffectKernel?
        var limiterKernel: DSPPeakLimiterKernel?
        var scriptRuntime: DSPScriptRuntime?
        var scriptLatencyFrames: Int = 0
        var scriptEstimatedOperationsPerSecond: Double = 0

        /// Algorithmic delay this node adds: the fixed 64 frames of the
        /// oversampled tube, a block kernel's own, the limiter's lookahead,
        /// or a script's.
        var latencyFrames: Int {
            if let limiterKernel { return limiterKernel.latencyFrames }
            if let blockKernel { return blockKernel.latencyFrames }
            return (effect == .tube ? 64 : 0) + scriptLatencyFrames
        }
    }

    fileprivate enum RuntimeEffect: Equatable {
        case flatGain
        case tube
        case block
        case limiter
        case script

        /// Effects whose output peak the static headroom cannot bound.
        var isNonlinearOrDelayed: Bool {
            switch self {
            case .tube, .block, .limiter, .script: true
            case .flatGain: false
            }
        }
    }

    /// Runtime type of the safety limiter; like the equal-loudness stage it
    /// is never a member of `AudioDSPConfiguration.nodes`.
    static let limiterTypeID = "limiter"

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
    /// Throwaway copy of the chain used only to drain zero padding past a
    /// stream end, a time gap or a format boundary. Created on first need.
    private var previewNodes: [RuntimeNode]?
    /// Source frames past the start of the next expected block that the live
    /// chain has already consumed. The live state runs ahead by the real
    /// lookahead it was given, so each source frame passes through the chain
    /// exactly once; only zero padding is ever processed on a copy.
    private var aheadFrames = 0
    private var frameScratch: [Double] = []
    private var sampleScratch: [Double] = []
    private var paddingScratch: [Float] = []
    private var paddingOutputScratch: [Float] = []
    private var warmupScratch: [Float] = []

    var processingNodeIDs: [UUID] { nodes.map(\.nodeID) }
    let idleProcessingNodeIDs: [UUID]
    var hasProcessingFault: Bool { outputFault != nil }
    var faultedProcessingNodeIDs: Set<UUID> { Set(scriptFaults.keys) }

    /// Immutable state at a block start, including how far the chain had run
    /// ahead. Large script delay lines use history replay instead of imposing
    /// a multi-megabyte copy on every playback block.
    struct StateSnapshot: @unchecked Sendable {
        fileprivate let configuration: AudioDSPConfiguration
        fileprivate let nodes: [RuntimeNode]
        fileprivate let format: DSPAudioFormat
        fileprivate let aheadFrames: Int

        func matches(_ candidate: AudioDSPConfiguration) -> Bool {
            let old = configuration.enabled ? configuration.processingNodes.filter(\.enabled) : []
            let new = candidate.enabled ? candidate.processingNodes.filter(\.enabled) : []
            return old.count == new.count && zip(old, new).allSatisfy {
                $0.nodeID == $1.nodeID && $0.typeID == $1.typeID
                    && $0.algorithmVersion == $1.algorithmVersion
                    && $0.quality == $1.quality && $0.channelPolicy == $1.channelPolicy
                    && ($0.typeID != DSPNodeConfiguration.scriptTypeID || $0.parameters == $1.parameters)
            }
        }
    }

    /// Snapshots are taken every playback block. A copy-on-write snapshot
    /// makes the next block copy every state it touches, so chains with
    /// large or reference-held state replay raw history instead.
    func stateSnapshot() -> StateSnapshot? {
        let scriptBytes = nodes.reduce(0) { $0 + ($1.scriptRuntime?.program.stateBytes ?? 0) }
        guard scriptBytes <= 64 * 1_024 else { return nil }
        let kernelBytes = nodes.reduce(0) { $0 + ($1.blockKernel?.stateBytes ?? 0) }
        guard kernelBytes <= 512 * 1_024,
              !nodes.contains(where: { $0.blockKernel?.keepsReferenceState == true }) else { return nil }
        return StateSnapshot(configuration: configuration, nodes: nodes, format: format, aheadFrames: aheadFrames)
    }

    /// Parameter-channel handover. Every node that still exists keeps its
    /// filter, oversampler and delay state; changed coefficients glide from
    /// the old values and newly switched-on filters glide in from a flat
    /// response. A script whose values changed starts fresh, because its
    /// prepare block gives no continuity guarantee; the renderer's short
    /// output crossfade covers that node.
    func inheritState(from source: AudioDSPProcessor) {
        guard source.format == format else { return }
        // The inherited state already holds the source's run-ahead frames.
        // A chain with less latency re-reads the excess; the renderer's
        // output crossfade covers that short overlap.
        aheadFrames = min(source.aheadFrames, processingLatencyFrames)
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
            if let kernel = old.blockKernel { nodes[index].blockKernel?.copyState(from: kernel) }
            if let tube = old.tubeKernel { nodes[index].tubeKernel?.copyState(from: tube) }
            if let limiter = old.limiterKernel { nodes[index].limiterKernel?.copyState(from: limiter) }
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
        aheadFrames = min(snapshot.aheadFrames, processingLatencyFrames)
        for index in nodes.indices {
            guard let old = snapshot.nodes.first(where: { $0.nodeID == nodes[index].nodeID }),
                  old.channelMask == nodes[index].channelMask else { continue }
            for filterIndex in nodes[index].filters.indices {
                if let filter = old.filters.first(where: { $0.bandIndex == nodes[index].filters[filterIndex].bandIndex }) {
                    nodes[index].filters[filterIndex].restore(from: filter)
                }
            }
            if let kernel = old.blockKernel { nodes[index].blockKernel?.copyState(from: kernel) }
            if let tube = old.tubeKernel { nodes[index].tubeKernel?.copyState(from: tube) }
            if let limiter = old.limiterKernel { nodes[index].limiterKernel?.copyState(from: limiter) }
            if let script = old.scriptRuntime { nodes[index].scriptRuntime?.copyState(from: script) }
        }
        return true
    }

    var needsWarmup: Bool {
        nodes.contains {
            !$0.filters.isEmpty || $0.blockKernel != nil || $0.tubeKernel != nil
                || $0.limiterKernel != nil || $0.scriptRuntime != nil
        }
    }

    init(
        configuration: AudioDSPConfiguration,
        format: DSPAudioFormat,
        context: DSPEqualLoudnessContext = .inactive
    ) {
        self.format = format
        self.configuration = configuration

        var preparedNodes: [RuntimeNode] = []
        var idleNodeIDs: [UUID] = []
        var warnings: [DSPDiagnostic] = []
        preparedNodes.reserveCapacity(configuration.nodes.count + 1)
        var scriptCount = 0
        var scriptOperationsPerSecond = 0.0

        if configuration.enabled {
            for node in configuration.processingNodes where node.enabled {
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
                let nodeWarningCount = warnings.count

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

                if DSPNodeConfiguration.nativeEffectTypeIDs.contains(node.typeID) {
                    if var preparedNode = Self.prepareNativeNode(
                        node,
                        format: format,
                        context: context,
                        warnings: &warnings
                    ) {
                        preparedNode.typeID = node.typeID
                        preparedNode.configurationParameters = node.parameters
                        preparedNodes.append(preparedNode)
                    } else if warnings.count == nodeWarningCount {
                        // prepareNativeNode has validated the format, layout
                        // and parameters and returned an exact pass-through.
                        idleNodeIDs.append(node.nodeID)
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
                    let stage = configuration.equalLoudness
                    guard let shelfBands = DSPEqualLoudnessMath.bands(stage: stage, context: context) else { continue }
                    bands = shelfBands
                    contributesToHeadroom = true

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
                    let parameterPath = isEqualLoudness
                        ? "equalLoudness.parameters"
                        : "nodes[\(node.nodeID.uuidString)].parameters.bands[\(bandIndex)]"
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
                        tubeKernel: nil
                    ))
                } else if filters.isEmpty, channelMask.contains(true), warnings.count == nodeWarningCount {
                    idleNodeIDs.append(node.nodeID)
                }
            }
        }

        // The chain runs ahead of its output, so each source frame is
        // processed once and latency adds no renderer work. A format change
        // can still invalidate a previously valid chain: isolate scripts from
        // the end until the remaining chain fits the cost and lookahead budgets.
        let latencyBudget = RendererDSPLookahead.maximumFrames(sampleRate: format.sampleRate)
        while true {
            let latency = preparedNodes.reduce(0) { total, node in
                total + node.latencyFrames
            } + (configuration.limiter.enabled ? DSPPeakLimiterKernel.lookaheadFrames(sampleRate: format.sampleRate) : 0)
            let baseCost = preparedNodes.reduce(0.0) { $0 + $1.scriptEstimatedOperationsPerSecond }
            let cost = DSPScriptCompiler.estimatedRendererOperationsPerSecond(
                baseOperationsPerSecond: baseCost, latencyFrames: latency)
            let overCost = cost > DSPScriptCompiler.maximumChainWeightedOperationsPerSecond
            let overLatency = latency > latencyBudget
            guard overCost || overLatency,
                  let index = preparedNodes.lastIndex(where: { node in
                      node.scriptRuntime != nil || (overLatency && node.latencyFrames > 0)
                  }) else { break }
            let node = preparedNodes.remove(at: index)
            if node.scriptRuntime != nil {
                warnings.append(DSPDiagnostic(code: "dsp.scriptBudgetExceeded",
                    message: "The script was bypassed because the chain exceeds the renderer processing or lookahead budget.",
                    fieldPath: "nodes[\(node.nodeID.uuidString)].parameters.source", nodeID: node.nodeID))
            } else {
                warnings.append(DSPDiagnostic(code: "dsp.latencyBudgetExceeded",
                    message: "The effect was bypassed because the chain exceeds the renderer lookahead budget.",
                    fieldPath: "nodes[\(node.nodeID.uuidString)]", nodeID: node.nodeID))
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
        let attenuationRange = DSPHeadroomConfiguration.maximumAttenuationRange
        let requestedMaximumDB = configuration.headroom.maximumAttenuationDB
        let maximumAttenuationDB: Double
        if requestedMaximumDB.isFinite {
            maximumAttenuationDB = min(max(attenuationRange.lowerBound, requestedMaximumDB), attenuationRange.upperBound)
            if abs(maximumAttenuationDB - requestedMaximumDB) > 1e-9 {
                warnings.append(DSPDiagnostic(
                    code: "headroomMaximumNormalized",
                    message: "The maximum headroom attenuation was bounded to its supported range.",
                    fieldPath: "headroom.maximumAttenuationDB",
                    retryable: false
                ))
            }
        } else {
            maximumAttenuationDB = DSPHeadroomConfiguration.defaultMaximumAttenuationDB
            warnings.append(DSPDiagnostic(
                code: "invalidHeadroomMaximum",
                message: "The non-finite maximum headroom attenuation was replaced by the default.",
                fieldPath: "headroom.maximumAttenuationDB",
                retryable: false
            ))
        }
        let hasHeadroomWork = preparedNodes.contains { node in
            node.contributesToHeadroom
                && (node.effect != nil || node.filters.contains { !$0.coefficients.isIdentity })
        }
        var numericPreparationFailed = false
        let automaticHeadroomDB: Double
        if configuration.enabled,
           hasHeadroomWork,
           configuration.headroom.mode == .automatic {
            let pathPeakDB = Self.maximumPathPeakResponseDB(
                configuration: configuration,
                preparedNodes: preparedNodes,
                channelCount: format.channelCount,
                sampleRate: format.sampleRate,
                context: context
            )
            // Headroom answers only the boost the stages add. A lowered input
            // already leaves room; raised input and output gains are the
            // listener's chosen level and are never cancelled here.
            let estimatedPeakDB = pathPeakDB + min(0, normalizedInputTrimDB)
            if estimatedPeakDB.isFinite {
                automaticHeadroomDB = -min(max(0, estimatedPeakDB), maximumAttenuationDB)
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
        if configuration.enabled, !numericPreparationFailed {
            Self.applyProgramLevelReference(
                to: &preparedNodes,
                chainGainDB: normalizedInputTrimDB + automaticHeadroomDB,
                channelCount: format.channelCount
            )
        }
        // The limiter guards a chain that does something; a pass-through
        // chain keeps the source untouched. It runs before the output gain
        // with its ceiling divided by that gain, which equals limiting the
        // final output and keeps the rack order: nodes, equal loudness,
        // limiter, output.
        let hasProcessingWork = Self.hasAudibleWork(preparedNodes)
            || abs(preparedInputGain - 1) >= 1e-12
            || abs(preparedOutputGain - 1) >= 1e-12
        let limiter = configuration.limiter
        let ceilingDB = limiter.ceilingDB.isFinite
            ? min(max(limiter.ceilingDB, DSPLimiterConfiguration.ceilingRange.lowerBound),
                  DSPLimiterConfiguration.ceilingRange.upperBound)
            : DSPLimiterConfiguration.defaultCeilingDB
        let releaseMilliseconds = limiter.releaseMilliseconds.isFinite
            ? min(max(limiter.releaseMilliseconds, DSPLimiterConfiguration.releaseRange.lowerBound),
                  DSPLimiterConfiguration.releaseRange.upperBound)
            : DSPLimiterConfiguration.defaultReleaseMilliseconds
        if configuration.enabled,
           limiter.enabled,
           hasProcessingWork,
           !numericPreparationFailed,
           let kernel = DSPPeakLimiterKernel(
               channelCount: format.channelCount,
               sampleRate: format.sampleRate,
               ceiling: pow(10, ceilingDB / 20) / preparedOutputGain,
               releaseSeconds: releaseMilliseconds / 1_000
           ) {
            preparedNodes.append(RuntimeNode(
                nodeID: DSPLimiterConfiguration.nodeID,
                typeID: Self.limiterTypeID,
                channelMask: Array(repeating: true, count: format.channelCount),
                contributesToHeadroom: false,
                staticPeakResponseDB: 0,
                filters: [],
                effect: .limiter,
                limiterKernel: kernel
            ))
            warnings.removeAll { $0.code == "nonlinearPeakGuaranteeUnavailable" }
        }
        self.headroomDB = numericPreparationFailed ? 0 : automaticHeadroomDB
        self.inputGain = numericPreparationFailed ? 1 : preparedInputGain
        self.outputGain = numericPreparationFailed ? 1 : preparedOutputGain
        let finalNodes = numericPreparationFailed ? [] : preparedNodes
        self.idleProcessingNodeIDs = numericPreparationFailed ? [] : idleNodeIDs
        self.nodes = finalNodes
        self.preparationDiagnostics = warnings
        let processorBypassed = numericPreparationFailed
            || !configuration.enabled
            || (!Self.hasAudibleWork(preparedNodes)
                && abs(preparedInputGain - 1) < 1e-12
                && abs(preparedOutputGain - 1) < 1e-12)
        self.isBypassed = processorBypassed
        processingLatencyFrames = numericPreparationFailed
            ? 0
            : preparedNodes.reduce(0) { $0 + $1.latencyFrames }
        if processorBypassed {
            self.peakGuarantee = "bypassed"
        } else if preparedNodes.contains(where: { $0.limiterKernel != nil }) {
            self.peakGuarantee = "samplePeakLimited"
        } else if preparedNodes.contains(where: { $0.effect?.isNonlinearOrDelayed == true }) {
            self.peakGuarantee = "unavailable"
        } else {
            self.peakGuarantee = "estimatedLinearResponse"
        }
    }

    func reset() {
        Self.resetRuntimeStates(&nodes)
        if previewNodes != nil { Self.resetRuntimeStates(&previewNodes!) }
        aheadFrames = 0
        scriptFaults.removeAll(keepingCapacity: true)
        outputFault = nil
    }

    /// Advance recursive state while discarding output. Call with source-time
    /// ordered raw history ending at the selected replacement boundary; the
    /// next processed block starts exactly there.
    func warm(with rawHistory: [CanonicalPCM]) {
        aheadFrames = 0
        for pcm in rawHistory {
            guard isCompatible(pcm), !isBypassed else { continue }
            pcm.data.withUnsafeBufferPointer { source in
                processCore(UnsafeBufferPointer(rebasing: source[0..<(pcm.frames * pcm.channelCount)]),
                    nil, channels: pcm.channelCount, nodes: &nodes, output: &warmupScratch,
                    frameValues: &frameScratch, samples: &sampleScratch, discardOutput: true)
            }
        }
    }

    /// Process input-time PCM and use up to one processing-latency of future PCM
    /// to return an output block mapped to the input's original presentation time.
    /// A missing or short lookahead is zero-filled, which is the EOF behavior.
    func process(
        _ input: CanonicalPCM,
        lookahead: CanonicalPCM? = nil,
        loadMeasurement: DSPProcessingLoadAccumulator? = nil
    ) -> CanonicalPCM {
        guard isCompatible(input), input.frames > 0 else { return input }
        guard outputFault == nil,
              !isBypassed || (loadMeasurement != nil && configuration.enabled && !idleProcessingNodeIDs.isEmpty) else { return input }

        let sampled = loadMeasurement?.beginBlock(frames: input.frames, sampleRate: input.sampleRate) ?? false
        let measurement = sampled ? loadMeasurement : nil
        let started = sampled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if let measurement {
                let ended = DispatchTime.now().uptimeNanoseconds
                measurement.finishBlock(nanoseconds: ended - started, at: ended, succeeded: outputFault == nil)
            }
        }
        guard !isBypassed else { return input }

        // Coordinates below count frames from the start of this block: the
        // input occupies 0..<frames and the lookahead follows it. The output
        // for frame f leaves the chain while frame f + latency goes in.
        let channels = input.channelCount
        let frames = input.frames
        let latency = processingLatencyFrames
        var realFuture = 0
        if latency > 0, let lookahead, isCompatible(lookahead) {
            realFuture = min(latency, lookahead.frames)
        }
        let liveEnd = frames + realFuture
        let liveStart = min(aheadFrames, latency, liveEnd)

        // The live chain consumes only real audio it has not seen yet.
        var liveOutput: [Float] = []
        if liveEnd > liveStart {
            input.data.withUnsafeBufferPointer { inputBuffer in
                let fromInput: UnsafeBufferPointer<Float>? = liveStart < frames
                    ? UnsafeBufferPointer(rebasing: inputBuffer[(liveStart * channels)..<(frames * channels)])
                    : nil
                guard realFuture > 0, let lookahead else {
                    processCore(fromInput, nil, channels: channels, nodes: &nodes, output: &liveOutput,
                        frameValues: &frameScratch, samples: &sampleScratch, loadMeasurement: measurement)
                    return
                }
                lookahead.data.withUnsafeBufferPointer { futureBuffer in
                    let futureStart = max(0, liveStart - frames)
                    let fromFuture = UnsafeBufferPointer(
                        rebasing: futureBuffer[(futureStart * channels)..<(realFuture * channels)])
                    processCore(fromInput, fromFuture, channels: channels, nodes: &nodes, output: &liveOutput,
                        frameValues: &frameScratch, samples: &sampleScratch, loadMeasurement: measurement)
                }
            }
            guard outputFault == nil else { return input }
        }
        aheadFrames = realFuture

        // Steady state: the chain is a full latency ahead and the lookahead
        // was real, so the live output is exactly this block.
        if liveStart == latency, liveEnd - liveStart == frames {
            return CanonicalPCM(frames: frames, channelCount: channels, sampleRate: input.sampleRate, data: liveOutput)
        }

        // Past a stream end, a gap or a format boundary the remaining latency
        // drains through zeros on a throwaway copy, never on the live chain.
        let paddedFrames = latency - realFuture
        if paddedFrames > 0 {
            if previewNodes == nil { previewNodes = nodes.map(Self.makeFreshRuntimeState) }
            Self.copyRuntimeStates(from: nodes, to: &previewNodes!, previewFrames: paddedFrames)
            let paddedSamples = paddedFrames * channels
            if paddingScratch.count != paddedSamples {
                paddingScratch = Array(repeating: 0, count: paddedSamples)
            }
            paddingScratch.withUnsafeBufferPointer { zeros in
                processCore(zeros, nil, channels: channels, nodes: &previewNodes!, output: &paddingOutputScratch,
                    frameValues: &frameScratch, samples: &sampleScratch, loadMeasurement: measurement)
            }
            guard outputFault == nil else { return input }
        }

        var output = [Float](repeating: 0, count: frames * channels)
        let liveFrames = max(0, min(frames, liveEnd - latency))
        output.withUnsafeMutableBufferPointer { destination in
            if liveFrames > 0 {
                liveOutput.withUnsafeBufferPointer { live in
                    let offset = (latency - liveStart) * channels
                    destination.baseAddress!.update(from: live.baseAddress!.advanced(by: offset),
                                                    count: liveFrames * channels)
                }
            }
            if liveFrames < frames {
                paddingOutputScratch.withUnsafeBufferPointer { padded in
                    let offset = (liveFrames + latency - liveEnd) * channels
                    destination.baseAddress!.advanced(by: liveFrames * channels)
                        .update(from: padded.baseAddress!.advanced(by: offset),
                                count: (frames - liveFrames) * channels)
                }
            }
        }
        return CanonicalPCM(frames: frames, channelCount: channels, sampleRate: input.sampleRate, data: output)
    }

    /// Meter readings of the last live block, split into the renderer's
    /// analysis chunks: element `i` holds every metering node's values for
    /// chunk `i`. Empty when no node meters.
    func meterReadingsByChunk() -> [[DSPNodeMeterReading]] {
        var result: [[DSPNodeMeterReading]] = []
        for node in nodes {
            guard let blocks = node.blockKernel?.meterBlocks, blocks.count >= 4 else { continue }
            let chunks = blocks.count / 4
            if result.count < chunks { result += Array(repeating: [], count: chunks - result.count) }
            for chunk in 0..<chunks {
                result[chunk].append(DSPNodeMeterReading(nodeID: node.nodeID,
                                                         values: Array(blocks[(chunk * 4)..<(chunk * 4 + 4)])))
            }
        }
        return result
    }

    private func isCompatible(_ pcm: CanonicalPCM) -> Bool {
        guard pcm.channelCount == format.channelCount,
              pcm.channelCount > 0,
              pcm.frames > 0,
              pcm.data.count / pcm.channelCount >= pcm.frames,
              pcm.sampleRate.isFinite else { return false }
        return abs(pcm.sampleRate - format.sampleRate) < 0.5
    }

    /// Runs interleaved source frames through `nodes`. The frames arrive as
    /// up to two consecutive spans, so a block and its lookahead are read in
    /// place without being joined first.
    private func processCore(
        _ first: UnsafeBufferPointer<Float>?,
        _ second: UnsafeBufferPointer<Float>?,
        channels: Int,
        nodes: inout [RuntimeNode],
        output: inout [Float],
        frameValues: inout [Double],
        samples: inout [Double],
        discardOutput: Bool = false,
        loadMeasurement: DSPProcessingLoadAccumulator? = nil
    ) {
        let firstCount = first?.count ?? 0
        let secondCount = second?.count ?? 0
        let count = firstCount + secondCount
        guard count > 0, channels > 0, outputFault == nil else { return }
        let frames = count / channels
        if samples.count != count { samples = Array(repeating: 0, count: count) }
        if frameValues.count != channels {
            frameValues = Array(repeating: 0, count: channels)
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            if let first, firstCount > 0 {
                vDSP_vspdp(first.baseAddress!, 1, buffer.baseAddress!, 1, vDSP_Length(firstCount))
            }
            if let second, secondCount > 0 {
                vDSP_vspdp(second.baseAddress!, 1, buffer.baseAddress!.advanced(by: firstCount), 1,
                           vDSP_Length(secondCount))
            }
            if inputGain != 1 {
                var gain = inputGain
                vDSP_vsmulD(buffer.baseAddress!, 1, &gain, buffer.baseAddress!, 1, vDSP_Length(count))
            }
        }
        // Node/filter dispatch and recursive state access happen once per block.
        // Each biquad holds its two delays in scalars through the sample loop.
        for index in nodes.indices {
            let started = loadMeasurement != nil ? DispatchTime.now().uptimeNanoseconds : 0
            switch nodes[index].effect {
            case nil:
                let mask = nodes[index].channelMask
                for filter in nodes[index].filters.indices {
                    nodes[index].filters[filter].processBlock(&samples, frames: frames, channels: channels, mask: mask)
                }
            case .some(.flatGain):
                let gain = nodes[index].flatGain ?? 1
                let mask = nodes[index].channelMask
                samples.withUnsafeMutableBufferPointer { buffer in
                    for channel in 0..<channels where mask[channel] {
                        for frame in 0..<frames { buffer[frame * channels + channel] *= gain }
                    }
                }
            case .some(.block):
                samples.withUnsafeMutableBufferPointer { buffer in
                    nodes[index].blockKernel?.process(buffer.baseAddress!, frames: frames, channels: channels)
                }
            case .some(.tube), .some(.limiter), .some(.script):
                for frame in 0..<frames {
                    let offset = frame * channels
                    for channel in 0..<channels { frameValues[channel] = samples[offset + channel] }
                    switch nodes[index].effect {
                    case .some(.tube): nodes[index].tubeKernel?.processFrame(&frameValues)
                    case .some(.limiter): nodes[index].limiterKernel?.processFrame(&frameValues)
                    case .some(.script): nodes[index].scriptRuntime?.processFrame(&frameValues)
                    default: break
                    }
                    for channel in 0..<channels { samples[offset + channel] = frameValues[channel] }
                }
            }
            if let loadMeasurement {
                loadMeasurement.recordNode(at: index, nanoseconds: DispatchTime.now().uptimeNanoseconds - started)
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
            nodes[nodeIndex].blockKernel?.reset()
            nodes[nodeIndex].tubeKernel?.reset()
            nodes[nodeIndex].limiterKernel?.reset()
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
                DSPStateCopy.assign(&destination[nodeIndex].filters[filterIndex].delay, from: sourceFilter.delay)
                destination[nodeIndex].filters[filterIndex].rampStart = sourceFilter.rampStart
                destination[nodeIndex].filters[filterIndex].rampRemaining = sourceFilter.rampRemaining
            }
            if let sourceKernel = source[nodeIndex].blockKernel {
                destination[nodeIndex].blockKernel?.copyState(from: sourceKernel)
            }
            if let sourceTube = source[nodeIndex].tubeKernel {
                destination[nodeIndex].tubeKernel?.copyState(from: sourceTube)
            }
            if let sourceLimiter = source[nodeIndex].limiterKernel {
                destination[nodeIndex].limiterKernel?.copyState(from: sourceLimiter)
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
        fresh.blockKernel = source.blockKernel?.makeFreshState()
        fresh.tubeKernel = source.tubeKernel?.makeFreshState()
        fresh.limiterKernel = source.limiterKernel?.makeFreshState()
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

    /// Prepares a native effect. A parameter set that cannot be read or holds
    /// an out-of-range value bypasses the node with a diagnostic; settings
    /// that leave the signal untouched return nil without one, an exact
    /// pass-through.
    private static func prepareNativeNode(
        _ node: DSPNodeConfiguration,
        format: DSPAudioFormat,
        context: DSPEqualLoudnessContext,
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

        guard DSPNodeConfiguration.supportedQualities(forTypeID: node.typeID).contains(node.quality) else {
            rejectQuality()
            return nil
        }
        guard let issues = node.nativeParameterIssues else {
            invalidParameters()
            return nil
        }
        guard issues.isEmpty else {
            for issue in issues {
                warn("invalidNativeParameter",
                     "The native effect was bypassed because a parameter is out of range.",
                     field: "\(basePath).\(issue.key)")
            }
            return nil
        }

        let policy = DSPNodeConfiguration.effectiveChannelPolicy(
            forTypeID: node.typeID,
            requested: node.channelPolicy,
            format: format
        )
        let channelMask: [Bool]
        if DSPNodeConfiguration.frontPairTypeIDs.contains(node.typeID) {
            guard let mask = frontPairMask() else {
                warn(
                    "frontStereoPairUnavailable",
                    "The effect was bypassed because the source has no explicit left and right channels.",
                    field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                )
                return nil
            }
            channelMask = mask
        } else if DSPNodeConfiguration.pairOrStereoTypeIDs.contains(node.typeID) {
            if policy == "frontPair", let mask = frontPairMask() {
                channelMask = mask
            } else {
                guard format.isMonoOrStereoLayout else {
                    warn(
                        "stereoLayoutUnsupported",
                        "The effect requires an identifiable front pair or a mono or stereo source.",
                        field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
                    )
                    return nil
                }
                channelMask = Array(repeating: true, count: format.channelCount)
            }
        } else if policy == "fullRange", let fullRange = format.fullRangeChannelMask {
            channelMask = fullRange
        } else {
            channelMask = Array(repeating: true, count: format.channelCount)
        }
        guard channelMask.contains(true) else {
            warn(
                "emptyChannelSelection",
                "The effect was bypassed because its channel policy selects no channels.",
                field: "nodes[\(node.nodeID.uuidString)].channelPolicy"
            )
            return nil
        }
        let selected = channelMask.indices.filter { channelMask[$0] }
        // The pair a stereo kernel works on; a mono source uses one channel twice.
        let pair = (left: selected[0], right: selected.count > 1 ? selected[1] : selected[0])

        let emptyNode = RuntimeNode(
            nodeID: node.nodeID,
            channelMask: channelMask,
            contributesToHeadroom: true,
            staticPeakResponseDB: 0,
            filters: [],
            effect: nil,
            flatGain: nil,
            tubeKernel: nil
        )
        func trimOnly(_ trimDB: Double) -> RuntimeNode? {
            guard trimDB != 0 else { return nil }
            var runtimeNode = emptyNode
            runtimeNode.effect = .flatGain
            runtimeNode.flatGain = pow(10, trimDB / 20)
            runtimeNode.staticPeakResponseDB = trimDB
            runtimeNode.levelOffsetDB = trimDB
            return runtimeNode
        }
        func blockNode(_ kernel: DSPEffectKernel?, peakDB: Double, trimDB: Double, nonlinear: Bool) -> RuntimeNode? {
            guard let kernel else {
                warn(
                    "nativeKernelPreparationFailed",
                    "The effect could not prepare stable filters for this source format.",
                    field: basePath
                )
                return nil
            }
            var runtimeNode = emptyNode
            runtimeNode.effect = .block
            runtimeNode.blockKernel = kernel
            runtimeNode.staticPeakResponseDB = peakDB
            runtimeNode.levelOffsetDB = trimDB
            if nonlinear {
                warn(
                    "nonlinearPeakGuaranteeUnavailable",
                    "The effect uses static headroom only; it has no peak guarantee.",
                    field: basePath
                )
            }
            return runtimeNode
        }

        switch node.typeID {
        case DSPNodeConfiguration.classicBassTypeID:
            guard let parameters = node.effectParameters(DSPClassicBassParameters.self) else { return nil }
            let kind = context.outputKind
            let tightens = parameters.tightenDryBass == .on
                || (parameters.tightenDryBass == .automatic && parameters.resolved(for: kind).profile.tightensDryBass)
            if parameters.intensity == 0, !tightens { return trimOnly(parameters.outputTrimDB) }
            let kernel = DSPClassicBassKernel(format: format, selectedChannels: channelMask,
                                              parameters: parameters, outputKind: kind)
            return blockNode(kernel.map(DSPEffectKernel.classicBass),
                             peakDB: DSPClassicBassKernel.staticPeakResponseDB(parameters: parameters, outputKind: kind),
                             trimDB: parameters.outputTrimDB, nonlinear: true)

        case DSPNodeConfiguration.hybridBassTypeID:
            guard let parameters = node.effectParameters(DSPHybridBassParameters.self) else { return nil }
            let kernel = DSPHybridBassKernel(format: format, selectedChannels: channelMask,
                                             parameters: parameters, outputKind: context.outputKind)
            return blockNode(kernel.map(DSPEffectKernel.hybridBass),
                             peakDB: DSPHybridBassKernel.staticPeakResponseDB(parameters: parameters),
                             trimDB: parameters.outputTrimDB, nonlinear: true)

        case DSPNodeConfiguration.stereoWidthTypeID:
            guard let parameters = node.stereoWidthParameters else { return nil }
            guard abs(parameters.width - 1) >= 1e-12 else { return trimOnly(parameters.outputTrimDB) }
            let kernel = DSPStereoWidthKernel(leftChannel: pair.left, rightChannel: pair.right,
                                              sampleRate: format.sampleRate, parameters: parameters)
            // The loudness gain may add up to 3 dB on a narrowed image.
            let peakDB = (parameters.loudnessMatchEnabled && parameters.width < 1 ? 3 : 0)
                + 20 * log10(max(1, parameters.width)) + parameters.outputTrimDB
            return blockNode(kernel.map(DSPEffectKernel.stereoWidth), peakDB: peakDB,
                             trimDB: parameters.outputTrimDB, nonlinear: false)

        case DSPNodeConfiguration.crossfeedTypeID:
            guard let parameters = node.effectParameters(DSPCrossfeedParameters.self) else { return nil }
            let kernel = DSPCrossfeedKernel(leftChannel: pair.left, rightChannel: pair.right,
                                            sampleRate: format.sampleRate, parameters: parameters)
            return blockNode(kernel.map(DSPEffectKernel.crossfeed), peakDB: 0, trimDB: 0, nonlinear: false)

        case DSPNodeConfiguration.spatialAudioTypeID:
            guard let parameters = node.effectParameters(DSPSpatialAudioParameters.self) else { return nil }
            switch DSPSpatialAudioKernel.prepare(format: format, leftChannel: pair.left, rightChannel: pair.right,
                                                 parameters: parameters) {
            case .success(let kernel):
                return blockNode(.spatial(kernel), peakDB: parameters.outputTrimDB,
                                 trimDB: parameters.outputTrimDB, nonlinear: false)
            case .failure(.missingImpulseResponse):
                warn(
                    "dsp.impulseResponseMissing",
                    "Spatial audio was bypassed because its impulse response file is missing.",
                    field: "\(basePath).impulseResponseID"
                )
                return nil
            case .failure:
                warn(
                    "nativeKernelPreparationFailed",
                    "Spatial audio could not prepare its responses for this source format.",
                    field: basePath
                )
                return nil
            }

        case DSPNodeConfiguration.reverbTypeID:
            guard let parameters = node.effectParameters(DSPReverbParameters.self) else { return nil }
            guard parameters.mix > 0 else { return nil }
            let kernel = DSPReverbKernel(sampleRate: format.sampleRate, leftChannel: pair.left,
                                         rightChannel: pair.right, design: DSPReverbDesign(parameters: parameters),
                                         mix: parameters.mix)
            return blockNode(kernel.map(DSPEffectKernel.reverb),
                             peakDB: DSPReverbKernel.staticPeakResponseDB(mix: parameters.mix),
                             trimDB: 0, nonlinear: false)

        case DSPNodeConfiguration.compressorTypeID:
            guard let parameters = node.effectParameters(DSPCompressorParameters.self) else { return nil }
            let kernel = DSPCompressorKernel(format: format, selectedChannels: channelMask, parameters: parameters)
            let makeupDB = parameters.loudnessMatchEnabled ? 0
                : max(0, parameters.bands.prefix(3).map(\.gainDB).max() ?? 0) + parameters.band(.master).gainDB
            return blockNode(kernel.map(DSPEffectKernel.compressor), peakDB: makeupDB + parameters.outputTrimDB,
                             trimDB: parameters.outputTrimDB, nonlinear: true)

        case DSPNodeConfiguration.tubeTypeID:
            guard let parameters = node.tubeParameters else { return nil }
            if parameters.isDry { return trimOnly(parameters.outputTrimDB) }
            let factor = node.quality == DSPNodeConfiguration.oversampling4xQuality ? 4 : 2
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
            // The classic shaper is normalized to unity small-signal gain, so
            // the wet path follows its input trim; saturation only lowers the
            // peak. Hi-fi adds harmonics a few percent of the band level. The
            // rare excess is left to the safety limiter.
            let wetLevel = pow(10, parameters.inputTrimDB / 20)
            let peak = parameters.mode == .classic
                ? (1 - parameters.mix) + parameters.mix * wetLevel
                : 1 + 0.1 * parameters.hifiAmount * wetLevel
            runtimeNode.staticPeakResponseDB = 20 * log10(max(1, peak)) + parameters.outputTrimDB
            runtimeNode.levelOffsetDB = parameters.outputTrimDB
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
            if !includedNodeIDs.contains(DSPEqualLoudnessStage.nodeID) {
                pathConfiguration.equalLoudness.enabled = false
            }
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

    /// Level-referenced nodes see program level regardless of gain staging:
    /// each one cancels the broadband gain applied before it, which is the
    /// chain input gain with its automatic headroom plus the trims of earlier
    /// nodes on its channels. Tonal stages such as EQ boosts still drive it,
    /// as an equalizer ahead of an analog saturator would.
    private static func applyProgramLevelReference(
        to nodes: inout [RuntimeNode],
        chainGainDB: Double,
        channelCount: Int
    ) {
        var channelGainDB = Array(repeating: chainGainDB, count: channelCount)
        for index in nodes.indices {
            let mask = nodes[index].channelMask
            var upstreamDB = -Double.infinity
            for channel in 0..<min(channelCount, mask.count) where mask[channel] {
                upstreamDB = max(upstreamDB, channelGainDB[channel])
            }
            if upstreamDB.isFinite {
                nodes[index].tubeKernel?.setProgramLevelOffset(dB: upstreamDB)
                nodes[index].blockKernel?.setProgramLevelOffset(dB: upstreamDB)
            }
            let offset = nodes[index].levelOffsetDB
            guard offset != 0 else { continue }
            for channel in 0..<min(channelCount, mask.count) where mask[channel] {
                channelGainDB[channel] += offset
            }
        }
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

import Foundation
import PlayerAutomationProtocol

/// Processing load and imported impulse responses. Load is measured only
/// while someone observes it, so a request holds its own observer for the
/// sampling window, beside any settings window already observing.
extension AutomationDSPHandler {
    /// Display reference lines shared with the settings cards; see
    /// docs/audio-dsp-processing-load.md.
    private static let chainBudgetStops = [0.25, 0.5, 0.8]
    private static let nodeBudgetStops = [0.05, 0.15, 0.3]

    func processingLoad(_ parameters: AutomationParameters, request: AutomationRequest,
                        controller: AudioDSPController) async throws -> AutomationJSONValue {
        let sampleMs = try parameters.integer("sampleMs", default: 1_500)
        guard (0...10_000).contains(sampleMs) else { throw AutomationParameterError.outOfRange("sampleMs") }
        let presentation = controller.processingLoad
        let startCount = presentation.publishedCount
        let started = Date()
        let canMeasure = controller.configuration.enabled && controller.isSourceLocal
        if sampleMs > 0, canMeasure {
            let observerID = UUID()
            controller.setProcessingLoadVisible(true, observerID: observerID)
            defer { controller.setProcessingLoadVisible(false, observerID: observerID) }
            let deadline = min(started.addingTimeInterval(Double(sampleMs) / 1_000),
                               request.context.deadline ?? .distantFuture)
            while Date() < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let configuration = controller.configuration
        let snapshot = presentation.snapshot
        let reason: String?
        if !configuration.enabled { reason = "dspDisabled" }
        else if !controller.isSourceLocal { reason = "externalSource" }
        else if snapshot == nil { reason = "noProcessedAudio" }
        else { reason = nil }

        func load(_ value: DSPProcessingLoad?, stops: [Double]) -> AutomationJSONValue {
            guard let value else { return .null }
            return .object([
                "averageRatio": .number(value.averageRatio),
                "sampledPeakRatio": .number(value.sampledPeakRatio),
                "budgetLevel": .string(Self.budgetLevel(value.averageRatio, stops: stops))
            ])
        }
        func row(_ id: UUID, kind: String, position: Int?, enabled: Bool) -> AutomationJSONValue {
            .object([
                "nodeID": .string(id.uuidString), "typeID": .string(kind),
                "position": position.map { .number(Double($0)) } ?? .null,
                "enabled": .boolean(enabled),
                "load": load(snapshot?.nodes[id], stops: Self.nodeBudgetStops)
            ])
        }
        var nodes = configuration.nodes.enumerated().map { index, node in
            row(node.nodeID, kind: node.typeID, position: index, enabled: node.enabled)
        }
        nodes.append(row(DSPEqualLoudnessStage.nodeID, kind: "equalLoudness", position: nil,
                         enabled: configuration.equalLoudness.enabled))
        nodes.append(row(DSPLimiterConfiguration.nodeID, kind: "limiter", position: nil,
                         enabled: configuration.limiter.enabled))

        let warnings = controller.status.warnings
        let faulted = Set(warnings.filter { $0.fieldPath?.hasSuffix(".runtime") == true }.compactMap(\.nodeID))
        let chain = snapshot?.chain
        return .object([
            "available": .boolean(snapshot != nil),
            "fresh": .boolean(presentation.publishedCount > startCount),
            "reason": reason.map(AutomationJSONValue.string) ?? .null,
            "sampledMilliseconds": .number((Date().timeIntervalSince(started) * 1_000).rounded()),
            "measuredAt": presentation.publishedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "metric": .string("Processing seconds per source second; 1 means the chain only just keeps up with playback."),
            "desiredRevision": .string(controller.revisionString),
            "measuredRevision": snapshot.map { .string($0.revision) } ?? .null,
            "format": snapshot.map { .object([
                "sampleRate": .number($0.format.sampleRate),
                "channelCount": .number(Double($0.format.channelCount))
            ]) } ?? .null,
            "chain": load(chain, stops: Self.chainBudgetStops),
            "nodes": .array(nodes),
            "overload": .object([
                "realtimeExceeded": chain.map { .boolean($0.averageRatio >= 1) } ?? .null,
                "peakRealtimeExceeded": chain.map { .boolean($0.sampledPeakRatio >= 1) } ?? .null,
                "budgetLevel": chain.map { .string(Self.budgetLevel($0.averageRatio, stops: Self.chainBudgetStops)) } ?? .null,
                "chainRuntimeBypassed": .boolean(warnings.contains { $0.code == "dsp.nonFiniteChainOutput" }),
                "faultedNodeIDs": .array(faulted.sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) })
            ]),
            "budgetStops": .object([
                "chain": .array(Self.chainBudgetStops.map(AutomationJSONValue.number)),
                "node": .array(Self.nodeBudgetStops.map(AutomationJSONValue.number)),
                "levels": .array(["low", "moderate", "high", "critical"].map(AutomationJSONValue.string)),
                "note": .string("Display reference lines, not measured dropout thresholds.")
            ])
        ])
    }

    private static func budgetLevel(_ ratio: Double, stops: [Double]) -> String {
        let levels = ["low", "moderate", "high"]
        for (index, stop) in stops.enumerated() where ratio < stop { return levels[index] }
        return "critical"
    }

    func impulseResponses(_ controller: AudioDSPController) async -> AutomationJSONValue {
        let stored = await Task.detached(priority: .userInitiated) {
            DSPImpulseResponseStore.storedResponses()
        }.value
        var names: [String: Set<String>] = [:]
        var currentNodes: [String: [AutomationJSONValue]] = [:]
        var presetIDs: [String: [AutomationJSONValue]] = [:]
        for node in controller.configuration.nodes {
            guard let spatial = node.effectParameters(DSPSpatialAudioParameters.self),
                  !spatial.impulseResponseID.isEmpty else { continue }
            names[spatial.impulseResponseID, default: []].insert(spatial.impulseResponseName)
            currentNodes[spatial.impulseResponseID, default: []].append(.object([
                "nodeID": .string(node.nodeID.uuidString),
                "active": .boolean(node.enabled && spatial.source == .impulseResponse)
            ]))
        }
        for preset in controller.presets {
            let ids = Set(preset.configuration.nodes.compactMap { node -> String? in
                guard let spatial = node.effectParameters(DSPSpatialAudioParameters.self),
                      !spatial.impulseResponseID.isEmpty else { return nil }
                names[spatial.impulseResponseID, default: []].insert(spatial.impulseResponseName)
                return spatial.impulseResponseID
            })
            for id in ids { presetIDs[id, default: []].append(.string(preset.presetID.uuidString)) }
        }
        return .object(["impulseResponses": .array(stored.map { response in
            .object([
                "impulseResponseID": .string(response.id),
                "names": .array((names[response.id] ?? []).filter { !$0.isEmpty }.sorted().map(AutomationJSONValue.string)),
                "channelCount": .number(Double(response.channelCount)),
                "sampleRate": .number(response.sampleRate),
                "durationSeconds": .number(response.durationSeconds),
                "currentNodes": .array(currentNodes[response.id] ?? []),
                "presetIDs": .array(presetIDs[response.id] ?? [])
            ])
        })])
    }

    func importImpulseResponse(_ parameters: AutomationParameters, expectedRevision: String?, dryRun: Bool,
                               request: AutomationRequest, controller: AudioDSPController) async throws -> AutomationResponse {
        let raw = try parameters.string("path", required: true)!
        guard (raw as NSString).expandingTildeInPath.hasPrefix("/") else { throw AutomationParameterError.invalidValue("path") }
        let url = URL(fileURLWithPath: AutomationInteraction.expandPath(raw))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AutomationParameterError.missingResource("path")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .failure(for: request, error: AutomationError(
                code: .permissionDenied, message: "The App cannot read this file.", retryable: false,
                details: .object(["path": .string(url.path)])
            ))
        }
        let nodeID = try parameters.uuid("nodeID")
        func spatialNodeIndex(_ configuration: AudioDSPConfiguration) throws -> Int? {
            guard let nodeID else { return nil }
            guard let index = configuration.nodes.firstIndex(where: { $0.nodeID == nodeID }),
                  configuration.nodes[index].typeID == DSPNodeConfiguration.spatialAudioTypeID else {
                throw AutomationParameterError.invalidValue("nodeID")
            }
            return index
        }
        _ = try spatialNodeIndex(controller.configuration)
        if dryRun {
            return result(.object([
                "path": .string(url.path), "nodeID": nodeID.map { .string($0.uuidString) } ?? .null,
                "applied": .boolean(false), "dryRun": .boolean(true)
            ]), for: request)
        }

        let imported: DSPImpulseResponseStore.Imported
        do {
            imported = try await Task.detached(priority: .userInitiated) {
                try DSPImpulseResponseStore.importFile(at: url)
            }.value
        } catch {
            throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                code: "dsp.impulseResponseInvalid",
                message: (error as? LocalizedError)?.errorDescription ?? "无法读取这个音频文件。",
                fieldPath: "path", retryable: false
            )])
        }
        var response: [String: AutomationJSONValue] = [
            "impulseResponseID": .string(imported.id), "name": .string(imported.name),
            "channelCount": .number(Double(imported.channelCount)),
            "durationSeconds": .number(imported.durationSeconds),
            "applied": .boolean(false)
        ]
        // The file is read off the main actor; the node is resolved again
        // against the configuration current after the import.
        var candidate = controller.configuration
        if let index = try spatialNodeIndex(candidate),
           var spatial = candidate.nodes[index].effectParameters(DSPSpatialAudioParameters.self) {
            spatial.source = .impulseResponse
            spatial.impulseResponseID = imported.id
            spatial.impulseResponseName = imported.name
            candidate.nodes[index].setEffectParameters(spatial)
            _ = try controller.validate(candidate)
            _ = try controller.apply(candidate, expectedRevision: expectedRevision, dryRun: false)
            controller.commitPendingApply()
            response["applied"] = .boolean(true)
            response["status"] = try value(controller.status)
        }
        return result(.object(response), for: request)
    }
}

import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationDSPHandler {
    private weak var appSession: AppSessionHost?

    init(appSession: AppSessionHost?) { self.appSession = appSession }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        guard let controller = appSession?.audioDSPController else {
            return .failure(for: request, error: AutomationError(
                code: .serverUnavailable, message: "The player App is unavailable.", retryable: true
            ))
        }
        do {
            await controller.ensureLoaded()
            let parameters = try AutomationParameters(request)
            let dryRun = try parameters.boolean("dryRun", default: false)
            let expectedRevision = try parameters.string("expectedRevision")
            if let expectedRevision, expectedRevision != controller.revisionString {
                throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                    code: "dsp.revisionConflict", message: "DSP configuration changed.",
                    fieldPath: "expectedRevision", retryable: true
                )])
            }
            switch request.method {
            case AutomationMethod.dspSchema:
                return result(.object([
                    "schemaVersion": .number(1),
                    "configuration": AutomationDSPToolCatalog.configurationSchema,
                    "preset": AutomationDSPToolCatalog.presetSchema,
                    "nodes": .array([.object([
                        "typeID": .string("peq9"), "algorithmVersion": .number(1),
                        "channelPolicies": .array([.string("fullRange"), .string("allChannels")]),
                        "quality": .array([.string("standard")]),
                        "parameters": AutomationDSPToolCatalog.equalizerParametersSchema
                    ])]),
                    "operationPaths": .object([
                        "setParameter": .string("Relative to node parameters, e.g. bands.0.gainDB."),
                        "setTrim": .string("value is an object containing inputTrimDB and/or outputTrimDB."),
                        "setHeadroom": .string("value contains mode and marginDB."),
                        "setOrder": .string("nodeIDs must contain every existing node exactly once.")
                    ]),
                    "scope": .string("app"), "renderer": .string("AVSampleBufferAudioRenderer"),
                    "builtInPresetID": .string(DSPPresetDocument.flatPresetID.uuidString),
                    "globalsExcluded": .array([.string("playPauseFade"), .string("loudnessNormalization")])
                ]), for: request)
            case AutomationMethod.dspState:
                return result(try state(controller), for: request)
            case AutomationMethod.dspValidate, AutomationMethod.dspPatch:
                let candidate = try candidateConfiguration(parameters, current: controller.configuration)
                _ = try controller.validate(candidate)
                let preview = request.method == AutomationMethod.dspValidate || dryRun
                let status = try controller.apply(candidate, expectedRevision: expectedRevision, dryRun: preview)
                if !preview { controller.commitPendingApply() }
                return result(.object([
                    "configuration": try value(candidate), "status": try value(preview ? status : controller.status),
                    "applied": .boolean(!preview), "dryRun": .boolean(preview)
                ]), for: request)
            case AutomationMethod.dspWait:
                let id = try parameters.uuid("requestID", required: true)!
                let timeout = try parameters.integer("timeoutMs", default: 5_000)
                guard (0...30_000).contains(timeout) else { throw AutomationParameterError.outOfRange("timeoutMs") }
                let deadline = min(Date().addingTimeInterval(Double(timeout) / 1_000), request.context.deadline ?? .distantFuture)
                guard var status = controller.requestStatus(id: id) else {
                    throw AutomationParameterError.invalidValue("requestID")
                }
                while [.preparing, .scheduled].contains(status.state), Date() < deadline {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(20))
                    guard let latest = controller.requestStatus(id: id) else {
                        throw AutomationParameterError.invalidValue("requestID")
                    }
                    status = latest
                }
                let timedOut = [.preparing, .scheduled].contains(status.state)
                return result(.object(["status": try value(status), "timedOut": .boolean(timedOut)]), for: request)
            case AutomationMethod.dspPresetsList:
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 200)
                guard (0...100_000).contains(offset), (1...200).contains(limit) else {
                    throw AutomationParameterError.outOfRange("offset/limit")
                }
                return result(.object([
                    "presets": try value(Array(controller.presets.dropFirst(offset).prefix(limit))),
                    "total": .number(Double(controller.presets.count)),
                    "builtInPresetIDs": .array([.string(DSPPresetDocument.flatPresetID.uuidString)]),
                    "selectedPresetID": controller.selectedPresetID.map { .string($0.uuidString) } ?? .null,
                    "isModified": .boolean(controller.isModified)
                ]), for: request)
            case AutomationMethod.dspPresetsGet, AutomationMethod.dspPresetsExport:
                let document = try await controller.preset(id: parameters.uuid("presetID", required: true)!)
                return result(try value(document), for: request)
            case AutomationMethod.dspPresetsSave:
                let name = try presetName(parameters.string("name", required: true)!)
                let id = try parameters.uuid("presetID")
                if let id { _ = try await mutablePreset(id, parameters: parameters, controller: controller) }
                let candidate: AudioDSPConfiguration
                if let raw = parameters.values["configuration"] {
                    candidate = try decodeConfiguration(raw)
                } else { candidate = controller.configuration }
                _ = try controller.validate(candidate)
                if dryRun {
                    return result(.object(["configuration": try value(candidate), "name": .string(name), "dryRun": .boolean(true)]), for: request)
                }
                let document = try await controller.savePreset(name: name, id: id,
                    expectedPresetRevision: parameters.string("expectedPresetRevision"), configuration: candidate)
                return result(try value(document), for: request)
            case AutomationMethod.dspPresetsSelect:
                let id = try parameters.uuid("presetID", required: true)!
                let document = try await checkedPreset(id, parameters: parameters, controller: controller)
                _ = try controller.validate(document.configuration)
                if dryRun { return result(.object(["document": try value(document), "dryRun": .boolean(true)]), for: request) }
                _ = try controller.selectPreset(id: id, expectedRevision: expectedRevision,
                    expectedPresetRevision: document.revisionString)
                controller.commitPendingApply()
                return result(try value(controller.status), for: request)
            case AutomationMethod.dspPresetsRename, AutomationMethod.dspPresetsDelete, AutomationMethod.dspPresetsDuplicate:
                let id = try parameters.uuid("presetID", required: true)!
                let document = request.method == AutomationMethod.dspPresetsDuplicate
                    ? try await checkedPreset(id, parameters: parameters, controller: controller)
                    : try await mutablePreset(id, parameters: parameters, controller: controller)
                let name = request.method == AutomationMethod.dspPresetsDelete
                    ? document.name : try presetName(parameters.string("name", required: true)!)
                if dryRun { return result(.object(["document": try value(document), "name": .string(name), "dryRun": .boolean(true)]), for: request) }
                switch request.method {
                case AutomationMethod.dspPresetsRename:
                    return result(try value(await controller.renamePreset(id: id, name: name,
                        expectedPresetRevision: parameters.string("expectedPresetRevision"))), for: request)
                case AutomationMethod.dspPresetsDuplicate:
                    return result(try value(await controller.duplicatePreset(id: id, name: name,
                        expectedPresetRevision: document.revisionString)), for: request)
                default:
                    try await controller.deletePreset(id: id, expectedPresetRevision: parameters.string("expectedPresetRevision"))
                    return result(.object(["deletedPresetID": .string(id.uuidString)]), for: request)
                }
            case AutomationMethod.dspPresetsImport:
                guard let raw = parameters.values["document"] else { throw AutomationParameterError.missing("document") }
                guard case .object(let fields) = raw,
                      Set(fields.keys) == Set(["schemaVersion", "presetID", "name", "revisionString", "configuration"]),
                      let configuration = fields["configuration"] else { throw AutomationParameterError.invalidValue("document") }
                _ = try decodeConfiguration(configuration)
                let document: DSPPresetDocument = try decode(raw)
                let preview = try controller.importPreview(document: document)
                if !dryRun && !preview.canImport {
                    throw DSPConfigurationValidationError(diagnostics: preview.diagnostics)
                }
                if dryRun {
                    return result(.object([
                        "document": try value(preview.document), "isCompatible": .boolean(preview.isCompatible),
                        "canImport": .boolean(preview.canImport),
                        "warnings": try value(preview.warnings), "diagnostics": try value(preview.diagnostics),
                        "dryRun": .boolean(true)
                    ]), for: request)
                }
                let saved = try await controller.importPreset(preview)
                return result(.object([
                    "document": try value(saved), "isCompatible": .boolean(preview.isCompatible),
                    "canImport": .boolean(true), "saved": .boolean(true), "applied": .boolean(false),
                    "warnings": try value(preview.warnings), "diagnostics": try value(preview.diagnostics)
                ]), for: request)
            case AutomationMethod.dspErrorsGet:
                return result(.object(["revisionString": .string(controller.revisionString),
                    "lastError": try controller.lastError.map(value) ?? .null,
                    "diagnostics": try value(controller.diagnostics), "warnings": try value(controller.status.warnings)]), for: request)
            case AutomationMethod.dspErrorsClear:
                controller.clearErrors()
                return result(.object(["cleared": .boolean(true)]), for: request)
            default:
                return AutomationResponseSupport.unsupportedMethod(for: request)
            }
        } catch let error as DSPConfigurationValidationError {
            reportMutationError(error, request: request, controller: controller)
            let conflict = error.diagnostics.contains { $0.code == "dsp.revisionConflict" }
            return .failure(for: request, error: AutomationError(
                code: conflict ? .conflict : .invalidRequest, message: error.localizedDescription,
                retryable: conflict, details: try? value(error.diagnostics)
            ))
        } catch let error as DSPPresetStoreError {
            reportMutationError(error, request: request, controller: controller)
            let code: AutomationErrorCode
            let retryable: Bool
            switch error {
            case .revisionConflict: code = .conflict; retryable = true
            case .fileOperation: code = .internalError; retryable = true
            default: code = .invalidRequest; retryable = false
            }
            return .failure(for: request, error: AutomationError(code: code, message: error.localizedDescription, retryable: retryable))
        } catch {
            reportMutationError(error, request: request, controller: controller)
            return AutomationResponseSupport.invalidParameters(for: request, error: error)
        }
    }

    private func reportMutationError(_ error: Error, request: AutomationRequest, controller: AudioDSPController) {
        guard AutomationToolCatalog.descriptor(for: request.method)?.readOnly == false else { return }
        if case .object(let values)? = request.params, case .boolean(true)? = values["dryRun"] { return }
        controller.report(error: error)
    }

    private func state(_ controller: AudioDSPController) throws -> AutomationJSONValue {
        .object([
            "configuration": try value(controller.configuration),
            "desiredRevision": .string(controller.revisionString),
            "preparedRevision": controller.preparedRevision.map(AutomationJSONValue.string) ?? .null,
            "effectiveRevision": controller.effectiveRevision.map(AutomationJSONValue.string) ?? .null,
            "audibleRevision": controller.audibleRevision.map(AutomationJSONValue.string) ?? .null,
            "status": try value(controller.status),
            "applicationPresentationLeadSeconds": controller.status.state == .inactiveExternalSource
                ? .null : appSession?.activeLibraryBinding.activeSession.map {
                    AutomationJSONValue.number($0.audioDSPPresentationLeadSeconds)
                } ?? .null,
            "outputClockDomain": .string("rendererDevice"),
            "selectedPresetID": controller.selectedPresetID.map { .string($0.uuidString) } ?? .null,
            "isModified": .boolean(controller.isModified), "diagnostics": try value(controller.diagnostics)
        ])
    }

    private func checkedPreset(_ id: UUID, parameters: AutomationParameters, controller: AudioDSPController) async throws -> DSPPresetDocument {
        let document = try await controller.preset(id: id)
        if let expected = try parameters.string("expectedPresetRevision"), expected != document.revisionString {
            throw DSPPresetStoreError.revisionConflict
        }
        return document
    }

    private func mutablePreset(_ id: UUID, parameters: AutomationParameters, controller: AudioDSPController) async throws -> DSPPresetDocument {
        guard id != DSPPresetDocument.flatPresetID else { throw DSPPresetStoreError.immutableBuiltIn }
        return try await checkedPreset(id, parameters: parameters, controller: controller)
    }

    private func presetName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DSPPresetStoreError.invalidName }
        return trimmed
    }

    private func candidateConfiguration(_ parameters: AutomationParameters, current: AudioDSPConfiguration) throws -> AudioDSPConfiguration {
        guard (parameters.values["configuration"] != nil) != (parameters.values["operations"] != nil) else {
            throw AutomationParameterError.invalidValue("Supply configuration or operations, exclusively.")
        }
        if let raw = parameters.values["configuration"] { return try decodeConfiguration(raw) }
        let operations = try parameters.objectArray("operations", required: true)
        guard operations.count <= 128 else { throw AutomationParameterError.outOfRange("operations") }
        var candidate = current
        for fields in operations {
            guard Set(fields.keys).isSubset(of: ["op", "nodeID", "path", "value", "node", "nodeIDs"]),
                  case .string(let op)? = fields["op"] else { throw AutomationParameterError.invalidValue("operations") }
            let allowed: Set<String>
            switch op {
            case "setMaster", "setTrim", "setHeadroom": allowed = ["op", "value"]
            case "setParameter": allowed = ["op", "nodeID", "path", "value"]
            case "setEnabled": allowed = ["op", "nodeID", "value"]
            case "addNode": allowed = ["op", "node"]
            case "removeNode": allowed = ["op", "nodeID"]
            case "setOrder": allowed = ["op", "nodeIDs"]
            default: throw AutomationParameterError.invalidValue("op")
            }
            guard Set(fields.keys).isSubset(of: allowed) else { throw AutomationParameterError.invalidValue("operations") }
            let raw = fields["value"]
            func nodeIndex() throws -> Int {
                guard case .string(let id)? = fields["nodeID"], let uuid = UUID(uuidString: id),
                      let index = candidate.nodes.firstIndex(where: { $0.nodeID == uuid }) else {
                    throw AutomationParameterError.invalidValue("nodeID")
                }
                return index
            }
            switch op {
            case "setMaster":
                guard case .boolean(let enabled)? = raw else { throw AutomationParameterError.invalidValue("value") }
                candidate.enabled = enabled
            case "setTrim":
                guard case .object(let values)? = raw, !values.isEmpty,
                      Set(values.keys).isSubset(of: ["inputTrimDB", "outputTrimDB"]) else { throw AutomationParameterError.invalidValue("value") }
                if let value = values["inputTrimDB"] { candidate.inputTrimDB = try decode(value) }
                if let value = values["outputTrimDB"] { candidate.outputTrimDB = try decode(value) }
            case "setHeadroom":
                guard let raw else { throw AutomationParameterError.missing("value") }
                guard case .object(let values) = raw,
                      Set(values.keys) == Set(["mode", "marginDB"]) else { throw AutomationParameterError.invalidValue("value") }
                candidate.headroom = try decode(raw)
            case "setEnabled":
                let index = try nodeIndex()
                guard case .boolean(let enabled)? = raw else { throw AutomationParameterError.invalidValue("value") }
                candidate.nodes[index].enabled = enabled
            case "setParameter":
                let index = try nodeIndex()
                guard case .string(let path)? = fields["path"], let raw else { throw AutomationParameterError.missing("path/value") }
                let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !parts.isEmpty, parts.count <= 16, !parts.contains("") else { throw AutomationParameterError.invalidValue("path") }
                let root = try replacing(.object(candidate.nodes[index].parameters), path: parts[...], value: decode(raw))
                guard case .object(let parameters) = root else { throw AutomationParameterError.invalidValue("path") }
                candidate.nodes[index].parameters = parameters
            case "addNode":
                guard let raw = fields["node"] else { throw AutomationParameterError.missing("node") }
                guard case .object(let node) = raw,
                      Set(node.keys) == Set(["nodeID", "typeID", "algorithmVersion", "enabled", "channelPolicy", "quality", "parameters"]) else {
                    throw AutomationParameterError.invalidValue("node")
                }
                candidate.nodes.append(try decode(raw))
            case "removeNode":
                candidate.nodes.remove(at: try nodeIndex())
            case "setOrder":
                guard let raw = fields["nodeIDs"] else { throw AutomationParameterError.missing("nodeIDs") }
                let ids: [UUID] = try decode(raw)
                guard ids.count == candidate.nodes.count, Set(ids).count == ids.count,
                      Set(ids) == Set(candidate.nodes.map(\.nodeID)) else { throw AutomationParameterError.invalidValue("nodeIDs") }
                let byID = Dictionary(uniqueKeysWithValues: candidate.nodes.map { ($0.nodeID, $0) })
                candidate.nodes = ids.compactMap { byID[$0] }
            default: throw AutomationParameterError.invalidValue("op")
            }
        }
        return candidate
    }

    private func replacing(_ current: DSPJSONValue, path: ArraySlice<String>, value: DSPJSONValue) throws -> DSPJSONValue {
        guard let key = path.first else { return value }
        let tail = path.dropFirst()
        switch current {
        case .object(var fields):
            if tail.isEmpty { fields[key] = value }
            else {
                guard let nested = fields[key] else { throw AutomationParameterError.invalidValue("path") }
                fields[key] = try replacing(nested, path: tail, value: value)
            }
            return .object(fields)
        case .array(var array):
            guard let index = Int(key), array.indices.contains(index) else { throw AutomationParameterError.invalidValue("path") }
            array[index] = try replacing(array[index], path: tail, value: value)
            return .array(array)
        default: throw AutomationParameterError.invalidValue("path")
        }
    }

    private func decodeConfiguration(_ raw: AutomationJSONValue) throws -> AudioDSPConfiguration {
        guard case .object(let fields) = raw,
              Set(fields.keys) == Set(["enabled", "inputTrimDB", "outputTrimDB", "headroom", "nodes"]) else {
            throw AutomationParameterError.invalidValue("configuration")
        }
        guard case .object(let headroom)? = fields["headroom"],
              Set(headroom.keys) == Set(["mode", "marginDB"]),
              case .array(let nodes)? = fields["nodes"] else { throw AutomationParameterError.invalidValue("configuration") }
        for node in nodes {
            guard case .object(let values) = node,
                  Set(values.keys) == Set(["nodeID", "typeID", "algorithmVersion", "enabled", "channelPolicy", "quality", "parameters"]) else {
                throw AutomationParameterError.invalidValue("nodes")
            }
        }
        return try decode(raw)
    }

    private func decode<T: Decodable>(_ raw: AutomationJSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: AutomationWireCoding.encoder().encode(raw))
    }

    private func value<T: Encodable>(_ value: T) throws -> AutomationJSONValue {
        try AutomationWireCoding.decoder().decode(AutomationJSONValue.self, from: JSONEncoder().encode(value))
    }

    private func result(_ value: AutomationJSONValue, for request: AutomationRequest) -> AutomationResponse {
        AutomationResponseSupport.encodeResult(value, for: request)
    }
}

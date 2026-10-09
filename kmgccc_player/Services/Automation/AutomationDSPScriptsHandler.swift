import Foundation
import PlayerAutomationProtocol

@MainActor
struct AutomationDSPScriptsHandler {
    private weak var appSession: AppSessionHost?
    init(appSession: AppSessionHost?) { self.appSession = appSession }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        guard let app = appSession else {
            return .failure(for: request, error: AutomationError(code: .serverUnavailable,
                message: "The player App is unavailable.", retryable: true))
        }
        let owner = app.audioDSPController
        let scripts = app.audioDSPScriptController
        scripts.bind(dspController: owner)
        await owner.ensureLoaded()
        do {
            let parameters = try AutomationParameters(request)
            switch request.method {
            case AutomationMethod.dspScriptsGet:
                let node = try scriptNode(parameters.uuid("nodeID", required: true)!, owner: owner)
                let draft = try await scripts.getDraft(nodeID: node.nodeID)
                let code = node.scriptParameters!
                let format = try format(parameters, owner: owner)
                var reflection: AutomationJSONValue = .null
                var diagnostics = [DSPDiagnostic]()
                do {
                    let program = try await scripts.compile(source: code.source,
                        languageVersion: code.languageVersion, parameterValues: code.values, format: format)
                    reflection = try programValue(program)
                } catch let error as DSPScriptCompilationError { diagnostics = error.diagnostics }
                return result(.object(["node": try value(node), "draft": try optionalValue(draft),
                    "effectiveProgram": reflection, "compileDiagnostics": try value(diagnostics),
                    "runtimeDiagnostics": try value(owner.status.warnings.filter { $0.nodeID == node.nodeID }),
                    "desiredRevision": .string(owner.revisionString)]), for: request)

            case AutomationMethod.dspScriptsUpdate:
                let node = try scriptNode(parameters.uuid("nodeID", required: true)!, owner: owner)
                let existing = try await scripts.getDraft(nodeID: node.nodeID)
                let active = node.scriptParameters!
                let source = try parameters.string("source", required: true)!
                let version = try parameters.integer("languageVersion", default: existing?.languageVersion ?? active.languageVersion)
                let values = try parameterValues(parameters, fallback: existing?.values ?? active.values)
                let expected = try parameters.string("expectedRevision")
                if let expected, expected != owner.revisionString {
                    throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(code: "dsp.revisionConflict",
                        message: "The DSP configuration changed.", fieldPath: "expectedRevision", retryable: true)])
                }
                let expectedDraft = try parameters.string("expectedDraftRevision")
                if let expectedDraft, expectedDraft != existing?.revisionString { throw DSPScriptControllerError.draftRevisionConflict }
                if try parameters.boolean("dryRun", default: false) {
                    let program = try await scripts.compile(source: source, languageVersion: version,
                        parameterValues: values, format: try format(parameters, owner: owner))
                    return result(.object(["dryRun": .boolean(true), "applied": .boolean(false),
                        "program": try programValue(program)]), for: request)
                }
                let draft = try await scripts.updateDraft(nodeID: node.nodeID, languageVersion: version,
                    source: source, values: values, expectedDraftRevision: expectedDraft)
                guard try parameters.boolean("apply", default: false) else {
                    return result(.object(["draft": try value(draft), "applied": .boolean(false)]), for: request)
                }
                _ = try await scripts.compileDraft(nodeID: node.nodeID,
                    format: try format(parameters, owner: owner), expectedDraftRevision: draft.revisionString)
                let status = try scripts.applyCompiledDraft(nodeID: node.nodeID,
                    expectedDraftRevision: draft.revisionString, expectedConfigurationRevision: expected)
                return result(.object(["draft": try value(draft), "applied": .boolean(true),
                    "status": try value(status)]), for: request)

            case AutomationMethod.dspScriptsCompile:
                let preparedFormat = try format(parameters, owner: owner)
                if let source = try parameters.string("source") {
                    if let id = try parameters.uuid("nodeID") {
                        _ = try scriptNode(id, owner: owner)
                        if let expected = try parameters.string("expectedDraftRevision"),
                           expected != (try await scripts.getDraft(nodeID: id))?.revisionString {
                            throw DSPScriptControllerError.draftRevisionConflict
                        }
                    } else if parameters.values["expectedDraftRevision"] != nil {
                        throw AutomationParameterError.invalidValue("nodeID")
                    }
                    let program = try await scripts.compile(source: source,
                        languageVersion: parameters.integer("languageVersion", default: 1),
                        parameterValues: parameterValues(parameters, fallback: [:]), format: preparedFormat)
                    return result(.object(["program": try programValue(program), "diagnostics": .array([]),
                        "applied": .boolean(false)]), for: request)
                }
                guard parameters.values["values"] == nil, parameters.values["languageVersion"] == nil else {
                    throw AutomationParameterError.invalidValue("source")
                }
                let node = try scriptNode(parameters.uuid("nodeID", required: true)!, owner: owner)
                if try await scripts.getDraft(nodeID: node.nodeID) != nil {
                    let compiled = try await scripts.compileDraft(nodeID: node.nodeID, format: preparedFormat,
                        expectedDraftRevision: parameters.string("expectedDraftRevision"))
                    return result(.object(["draftRevision": .string(compiled.draftRevision),
                        "program": try programValue(compiled.program),
                        "diagnostics": .array([]), "applied": .boolean(false)]), for: request)
                }
                guard parameters.values["expectedDraftRevision"] == nil else {
                    throw DSPScriptControllerError.draftRevisionConflict
                }
                let code = node.scriptParameters!
                let program = try await scripts.compile(source: code.source, languageVersion: code.languageVersion,
                    parameterValues: code.values, format: preparedFormat)
                return result(.object(["program": try programValue(program), "diagnostics": .array([]),
                    "applied": .boolean(false)]), for: request)

            case AutomationMethod.dspScriptsTest:
                let node = try scriptNode(parameters.uuid("nodeID", required: true)!, owner: owner)
                let draft = try await scripts.getDraft(nodeID: node.nodeID)
                if let expected = try parameters.string("expectedDraftRevision"), expected != draft?.revisionString {
                    throw AutomationParameterError.invalidValue("expectedDraftRevision")
                }
                let code = draft.map { DSPScriptNodeParameters(languageVersion: $0.languageVersion,
                    source: $0.source, values: $0.values) } ?? node.scriptParameters!
                let testedRevision = draft?.revisionString ?? owner.revisionString
                let preparedFormat = try format(parameters, owner: owner)
                let program = try await scripts.compile(source: code.source, languageVersion: code.languageVersion,
                    parameterValues: code.values, format: preparedFormat)
                let fixtures = try AutomationDSPScriptFixtures.parse(parameters.values["fixtures"], format: preparedFormat)
                if try parameters.boolean("dryRun", default: false) {
                    return result(.object(["dryRun": .boolean(true), "program": try programValue(program),
                        "fixtureNames": .array(fixtures.fixtures.map { .string($0.name) }),
                        "retrySupported": .boolean(fixtures.retryConfiguration != nil)]), for: request)
                }
                let access = AutomationSessionAccess(appSession: app)
                guard let session = access.activeSession(for: request) else { return access.noActiveLibraryResponse(for: request) }
                guard let job = startTestJob(session: session, nodeID: node.nodeID, program: program,
                    revision: testedRevision, usesDraft: draft != nil, fixtures: fixtures) else {
                    throw AutomationParameterError.invalidValue("activeLibrary")
                }
                return result(.object(["job": try value(AutomationJobProjection.makeJobSummary(job)),
                    "sourceHash": .string(program.sourceHash), "currentPlaybackUnchanged": .boolean(true),
                    "retrySupported": .boolean(fixtures.retryConfiguration != nil)]), for: request)

            case AutomationMethod.dspNodesRetry:
                let id = try parameters.uuid("nodeID", required: true)!
                guard let node = owner.configuration.nodes.first(where: { $0.nodeID == id }) else {
                    throw AutomationParameterError.invalidValue("nodeID")
                }
                var candidate = owner.configuration
                candidate.nodes[candidate.nodes.firstIndex(where: { $0.nodeID == node.nodeID })!].enabled = true
                let preview = try parameters.boolean("dryRun", default: false)
                let status = try owner.apply(candidate, expectedRevision: parameters.string("expectedRevision"), dryRun: preview)
                if !preview { owner.commitPendingApply() }
                return result(.object(["status": try value(status), "applied": .boolean(!preview)]), for: request)
            default: throw AutomationParameterError.invalidValue("method")
            }
        } catch let error as DSPScriptCompilationError {
            return .failure(for: request, error: AutomationError(code: .invalidRequest,
                message: "The DSP script could not be compiled.", retryable: false,
                details: .object(["diagnostics": (try? value(error.diagnostics)) ?? .array([]),
                    "currentPlaybackUnchanged": .boolean(true),
                    "draftRetained": .boolean(request.method == AutomationMethod.dspScriptsUpdate)])))
        } catch let error as DSPConfigurationValidationError {
            let conflict = error.diagnostics.contains { $0.code == "dsp.revisionConflict" }
            return .failure(for: request, error: AutomationError(code: conflict ? .conflict : .invalidRequest,
                message: error.localizedDescription, retryable: error.diagnostics.contains(where: \.retryable),
                details: .object(["diagnostics": (try? value(error.diagnostics)) ?? .array([])])))
        } catch let error as DSPScriptControllerError {
            let conflict: Bool
            let retryable: Bool
            switch error {
            case .draftRevisionConflict, .staleCompile, .formatChanged:
                conflict = true
                retryable = true
            case .operationLimitReached:
                conflict = false
                retryable = true
            default:
                conflict = false
                retryable = false
            }
            return .failure(for: request, error: AutomationError(code: conflict ? .conflict : .invalidRequest,
                message: error.localizedDescription, retryable: retryable,
                details: .object(["currentRevision": .string(owner.revisionString),
                                  "currentPlaybackUnchanged": .boolean(true)])))
        } catch let error as DSPScriptDraftStoreError {
            return .failure(for: request, error: AutomationError(code: error == .revisionConflict ? .conflict : .invalidRequest,
                message: error.localizedDescription, retryable: error == .revisionConflict,
                details: .object(["currentPlaybackUnchanged": .boolean(true)])))
        } catch { return AutomationResponseSupport.invalidParameters(for: request, error: error) }
    }

    func retryTestJob(_ descriptor: LibraryOperationTaskDescriptor,
                      session: LibrarySession) async throws -> LibraryOperationTaskDescriptor? {
        guard let app = appSession, let spec = descriptor.retrySpec,
              spec.kind == .dspScriptTest, let id = spec.scriptNodeID,
              let revision = spec.scriptRevision, let rate = spec.scriptSampleRate,
              let channels = spec.scriptChannelCount else { return nil }
        let owner = app.audioDSPController
        await owner.ensureLoaded()
        app.audioDSPScriptController.bind(dspController: owner)
        let node = try scriptNode(id, owner: owner)
        let draft = try await app.audioDSPScriptController.getDraft(nodeID: id)
        let code: DSPScriptNodeParameters
        if spec.scriptUsesDraft == true {
            guard let draft, draft.revisionString == revision else { throw AutomationParameterError.invalidValue("draftRevision") }
            code = DSPScriptNodeParameters(languageVersion: draft.languageVersion, source: draft.source, values: draft.values)
        } else {
            guard owner.revisionString == revision else { throw AutomationParameterError.invalidValue("desiredRevision") }
            code = node.scriptParameters!
        }
        let format = DSPAudioFormat(sampleRate: rate, channelCount: channels,
            rawLayoutData: nil, channelLabels: nil, layoutIsKnown: false)
        let program = try await app.audioDSPScriptController.compile(source: code.source,
            languageVersion: code.languageVersion, parameterValues: code.values, format: format)
        guard app.activeLibraryBinding.activeSession === session else { return nil }
        let savedFixtures = spec.scriptFixtures == .array([]) ? nil : spec.scriptFixtures
        let fixtures = try AutomationDSPScriptFixtures.parse(savedFixtures, format: format)
        return startTestJob(session: session, nodeID: id, program: program, revision: revision,
                            usesDraft: spec.scriptUsesDraft == true, fixtures: fixtures)
    }

    private func startTestJob(session: LibrarySession, nodeID: UUID, program: DSPScriptProgram,
                              revision: String, usesDraft: Bool,
                              fixtures: AutomationDSPScriptFixtures) -> LibraryOperationTaskDescriptor? {
        let retry = fixtures.retryConfiguration.map { specification in
            LibraryOperationRetrySpec.dspScriptTest(nodeID: nodeID, revision: revision,
                sampleRate: program.format.sampleRate, channelCount: program.format.channelCount,
                usesDraft: usesDraft, fixtures: specification)
        }
        return session.startAutomationJob(totalCount: fixtures.fixtures.count, retrySpec: retry) { reporter in
            let task = Task.detached(priority: .utility) {
                try await DSPScriptFixtureRunner.run(program: program,
                    channelMask: Array(repeating: true, count: program.format.channelCount),
                    fixtures: fixtures.fixtures)
            }
            do {
                let results = try await withTaskCancellationHandler(operation: {
                    try await task.value
                }, onCancel: { task.cancel() })
                try Task.checkCancellation()
                reporter.recordResult(.object(["nodeID": .string(nodeID.uuidString),
                    "sourceHash": .string(program.sourceHash), "testedRevision": .string(revision),
                    "program": try Self.encodeProgram(program),
                    "channelScope": .string("syntheticAllChannels"),
                    "fixtures": .array(results.map(Self.fixtureValue))]))
                if results.contains(where: { $0.scriptFaulted || $0.nonFiniteOutputSampleCount > 0 || !$0.diagnostics.isEmpty }) {
                    reporter.recordFailure("The script fixture encountered a runtime error.", itemID: nodeID)
                }
                reporter.recordProgress(completedCount: fixtures.fixtures.count,
                    totalCount: fixtures.fixtures.count, phase: "Script fixtures complete")
            } catch is CancellationError {
                task.cancel()
            } catch {
                reporter.recordFailure("The script fixture failed: \(error.localizedDescription)", itemID: nodeID)
            }
        }
    }

    nonisolated static func fixtureValue(_ result: DSPScriptFixtureResult) -> AutomationJSONValue {
        .object(["fixtureName": .string(result.fixtureName), "frames": .number(Double(result.frames)),
            "inputPeak": .number(result.inputPeak), "outputPeak": .number(result.outputPeak),
            "inputRMS": .number(result.inputRMS), "outputRMS": .number(result.outputRMS),
            "nonFiniteOutputSampleCount": .number(Double(result.nonFiniteOutputSampleCount)),
            "scriptFaulted": .boolean(result.scriptFaulted),
            "costEstimateBasis": .string("Weighted operations divided by the configured budget; not a device CPU prediction."),
            "responsePoints": .array(result.responsePoints.map {
                .object(["frequencyHz": .number($0.frequencyHz), "gainDB": .number($0.gainDB)])
            }), "estimatedWeightedOperations": .number(Double(result.estimatedWeightedOperations)),
            "estimatedProcessingMilliseconds": .number(result.estimatedProcessingMilliseconds),
            "elapsedMilliseconds": .number(result.elapsedMilliseconds), "latencyFrames": .number(Double(result.latencyFrames)),
            "measuredImpulsePeakFrame": result.measuredImpulsePeakFrame.map { .number(Double($0)) } ?? .null,
            "expectedLatencyFrames": result.expectedLatencyFrames.map { .number(Double($0)) } ?? .null,
            "diagnostics": (try? AutomationWireCoding.decoder().decode(AutomationJSONValue.self,
                from: AutomationWireCoding.encoder().encode(result.diagnostics))) ?? .array([])])
    }

    private func format(_ parameters: AutomationParameters, owner: AudioDSPController) throws -> DSPAudioFormat {
        guard let raw = parameters.values["format"] else {
            return owner.status.format ?? DSPAudioFormat(sampleRate: 48_000, channelCount: 2,
                rawLayoutData: nil, channelLabels: [1, 2], layoutIsKnown: true)
        }
        guard case .object(let fields) = raw, Set(fields.keys) == Set(["sampleRate", "channelCount"]),
              case .number(let rate)? = fields["sampleRate"], case .number(let count)? = fields["channelCount"],
              rate.isFinite, (8_000...768_000).contains(rate), let channels = Int(exactly: count),
              (1...32).contains(channels) else { throw AutomationParameterError.invalidValue("format") }
        return DSPAudioFormat(sampleRate: rate, channelCount: channels, rawLayoutData: nil,
                              channelLabels: nil, layoutIsKnown: false)
    }

    private func scriptNode(_ id: UUID, owner: AudioDSPController) throws -> DSPNodeConfiguration {
        guard let node = owner.configuration.nodes.first(where: { $0.nodeID == id }),
              node.typeID == DSPNodeConfiguration.scriptTypeID, node.scriptParameters != nil else {
            throw AutomationParameterError.invalidValue("nodeID")
        }
        return node
    }

    private func parameterValues(_ parameters: AutomationParameters,
                                 fallback: [String: Double]) throws -> [String: Double] {
        guard let raw = parameters.values["values"] else { return fallback }
        guard case .object(let fields) = raw, fields.count <= 32 else { throw AutomationParameterError.invalidValue("values") }
        var result = [String: Double]()
        for (key, raw) in fields {
            guard case .number(let value) = raw, value.isFinite else { throw AutomationParameterError.invalidValue("values.\(key)") }
            result[key] = value
        }
        return result
    }

    private func programValue(_ program: DSPScriptProgram) throws -> AutomationJSONValue { try Self.encodeProgram(program) }
    nonisolated private static func encodeProgram(_ program: DSPScriptProgram) throws -> AutomationJSONValue {
        .object(["sourceHash": .string(program.sourceHash), "languageVersion": .number(Double(program.languageVersion)),
            "parameters": try AutomationWireCoding.decoder().decode(AutomationJSONValue.self,
                from: AutomationWireCoding.encoder().encode(program.parameters)),
            "parameterValues": .object(program.parameterValues.mapValues(AutomationJSONValue.number)),
            "sampleRate": .number(program.format.sampleRate), "channelCount": .number(Double(program.format.channelCount)),
            "latencyFrames": .number(Double(program.latencyFrames)), "stateBytes": .number(Double(program.stateBytes)),
            "weightedOperationsPerFramePerChannel": .number(Double(program.weightedOperationsPerFrame))])
    }
    private func optionalValue<T: Encodable>(_ value: T?) throws -> AutomationJSONValue {
        guard let value else { return .null }
        return try self.value(value)
    }
    private func value<T: Encodable>(_ value: T) throws -> AutomationJSONValue {
        try AutomationWireCoding.decoder().decode(AutomationJSONValue.self, from: AutomationWireCoding.encoder().encode(value))
    }
    private func result(_ value: AutomationJSONValue, for request: AutomationRequest) -> AutomationResponse {
        AutomationResponseSupport.encodeResult(value, for: request)
    }
}

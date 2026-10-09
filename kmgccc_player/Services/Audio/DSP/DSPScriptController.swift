import Foundation
import Observation

nonisolated enum DSPScriptOperationPhase: String, Codable, Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed
    case cancelled
}

nonisolated struct DSPScriptCompileResult: Sendable {
    var nodeID: UUID
    var draftRevision: String
    var requestID: UUID
    var sourceHash: String
    var languageVersion: Int
    var format: DSPAudioFormat
    var parameters: [DSPScriptParameter]
    var parameterValues: [String: Double]
    var latencyFrames: Int
    var stateBytes: Int
    var weightedOperationsPerFrame: Int
    var estimatedWeightedOperationsPerSecond: Double
    var compiledAt: Date
    var program: DSPScriptProgram
}

nonisolated struct DSPScriptNodeActivity: Sendable {
    var compilePhase: DSPScriptOperationPhase = .idle
    var compileRequestID: UUID?
    var compileDiagnostics: [DSPDiagnostic] = []
    var compileResult: DSPScriptCompileResult?
    var testPhase: DSPScriptOperationPhase = .idle
    var testRequestID: UUID?
    var testDiagnostics: [DSPDiagnostic] = []
    var testResult: DSPScriptFixtureResult?
}

nonisolated enum DSPScriptControllerError: Error, LocalizedError, Sendable {
    case notBound
    case missingDraft
    case missingScriptNode
    case draftRevisionConflict
    case staleCompile
    case formatChanged
    case invalidFixtureResult
    case operationLimitReached

    nonisolated var errorDescription: String? {
        switch self {
        case .notBound:
            "脚本服务尚未连接到 DSP 配置。"
        case .missingDraft:
            "找不到该节点的脚本草稿。"
        case .missingScriptNode:
            "当前效果链中已没有此脚本节点。"
        case .draftRevisionConflict:
            "脚本草稿已更新，请重新编译。"
        case .staleCompile:
            "脚本或编译请求已更新，请重新编译。"
        case .formatChanged:
            "音频格式已变化，请按当前格式重新编译。"
        case .invalidFixtureResult:
            "脚本测试没有返回结果。"
        case .operationLimitReached:
            "同时处理的脚本节点过多，请稍后重试。"
        }
    }
}

/// Owns per-node editable drafts and explicit compile/test operations. The
/// playback configuration remains owned by AudioDSPController.
@Observable
@MainActor
final class DSPScriptController {
    private(set) var drafts: [UUID: DSPScriptDraftDocument] = [:]
    private(set) var activityByNodeID: [UUID: DSPScriptNodeActivity] = [:]
    private(set) var lastError: DSPDiagnostic?
    private(set) var isBound = false

    @ObservationIgnored private let draftStore: DSPScriptDraftStore
    @ObservationIgnored private weak var dspController: AudioDSPController?
    @ObservationIgnored private var compileTasks: [UUID: Task<DSPScriptProgram, Error>] = [:]
    @ObservationIgnored private var compileTaskRequestIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var latestCompileRequestIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var testTasks: [UUID: Task<[DSPScriptFixtureResult], Error>] = [:]
    @ObservationIgnored private var testTaskRequestIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var latestTestRequestIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var nodeGenerations: [UUID: UInt64] = [:]
    @ObservationIgnored private var nodeAccessOrder: [UUID] = []

    private static let maximumCachedNodeStates = 32

    init(draftStore: DSPScriptDraftStore = DSPScriptDraftStore()) {
        self.draftStore = draftStore
    }

    /// Called once from AppSessionHost.setupDependencies after both owners exist.
    func bind(dspController: AudioDSPController) {
        if self.dspController === dspController { return }
        cancelAllOperations()
        self.dspController = dspController
        isBound = true
    }

    /// Reads only. A missing draft remains absent until the caller explicitly
    /// seeds it from a current script node with updateDraft.
    func getDraft(nodeID: UUID) async throws -> DSPScriptDraftDocument? {
        let generation = nodeGenerations[nodeID, default: 0]
        do {
            let document = try await draftStore.getDraft(nodeID: nodeID)
            guard nodeGenerations[nodeID, default: 0] == generation else {
                return drafts[nodeID]
            }
            if let document {
                drafts[nodeID] = document
                touchNode(nodeID)
            } else {
                drafts.removeValue(forKey: nodeID)
            }
            return document
        } catch {
            if nodeGenerations[nodeID, default: 0] == generation {
                if drafts[nodeID] == nil,
                   activityByNodeID[nodeID] == nil,
                   compileTasks[nodeID] == nil,
                   testTasks[nodeID] == nil {
                    nodeGenerations.removeValue(forKey: nodeID)
                }
                record(error, nodeID: nodeID, fieldPath: "scriptDraft")
            }
            throw error
        }
    }

    @discardableResult
    func updateDraft(
        nodeID: UUID,
        languageVersion: Int,
        source: String,
        values: [String: Double],
        expectedDraftRevision: String? = nil
    ) async throws -> DSPScriptDraftDocument {
        let generation = nodeGenerations[nodeID, default: 0] &+ 1
        nodeGenerations[nodeID] = generation
        do {
            let document = try await draftStore.updateDraft(
                nodeID: nodeID,
                languageVersion: languageVersion,
                source: source,
                values: values,
                expectedRevision: expectedDraftRevision
            )
            if nodeGenerations[nodeID] == generation {
                invalidateOperationsForDraftChange(nodeID: nodeID)
                drafts[nodeID] = document
                touchNode(nodeID)
                lastError = nil
            }
            return document
        } catch {
            if nodeGenerations[nodeID] == generation {
                if drafts[nodeID] == nil,
                   activityByNodeID[nodeID] == nil,
                   compileTasks[nodeID] == nil,
                   testTasks[nodeID] == nil {
                    nodeGenerations.removeValue(forKey: nodeID)
                }
                record(error, nodeID: nodeID, fieldPath: "scriptDraft")
            }
            throw error
        }
    }

    /// Compiles an ephemeral source snapshot without changing or creating a draft.
    func compile(
        source: String,
        languageVersion: Int = 1,
        parameterValues: [String: Double] = [:],
        format: DSPAudioFormat
    ) async throws -> DSPScriptProgram {
        try Self.validateCompileInput(source: source, values: parameterValues, format: format)
        return try await Self.compileOffMain(
            source: source,
            languageVersion: languageVersion,
            parameterValues: parameterValues,
            format: format
        )
    }

    @discardableResult
    func compileDraft(
        nodeID: UUID,
        format: DSPAudioFormat,
        expectedDraftRevision: String? = nil
    ) async throws -> DSPScriptCompileResult {
        guard let draft = try await getDraft(nodeID: nodeID) else {
            throw DSPScriptControllerError.missingDraft
        }
        if let expectedDraftRevision, draft.revisionString != expectedDraftRevision {
            throw DSPScriptControllerError.draftRevisionConflict
        }
        try Self.validateCompileInput(source: draft.source, values: draft.values, format: format)
        guard canStartNodeOperation(nodeID) else {
            let error = DSPScriptControllerError.operationLimitReached
            record(error, nodeID: nodeID, fieldPath: "script.source")
            throw error
        }

        cancelCompile(nodeID: nodeID)
        cancelTest(nodeID: nodeID)
        let requestID = UUID()
        latestCompileRequestIDs[nodeID] = requestID
        var activity = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        activity.compilePhase = .running
        activity.compileRequestID = requestID
        activity.compileDiagnostics = []
        activity.compileResult = nil
        activity.testPhase = .idle
        activity.testRequestID = nil
        activity.testDiagnostics = []
        activity.testResult = nil
        activityByNodeID[nodeID] = activity
        touchNode(nodeID)

        let source = draft.source
        let languageVersion = draft.languageVersion
        let values = draft.values
        let compileTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try DSPScriptCompiler.compile(
                source: source,
                languageVersion: languageVersion,
                parameterValues: values,
                format: format
            )
        }
        compileTasks[nodeID] = compileTask
        compileTaskRequestIDs[nodeID] = requestID

        let program: DSPScriptProgram
        do {
            program = try await withTaskCancellationHandler {
                try await compileTask.value
            } onCancel: {
                compileTask.cancel()
            }
        } catch {
            if latestCompileRequestIDs[nodeID] == requestID,
               compileTaskRequestIDs[nodeID] == requestID {
                var failed = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
                failed.compilePhase = error is CancellationError ? .cancelled : .failed
                failed.compileDiagnostics = Self.diagnostics(for: error, nodeID: nodeID, fieldPath: "script.source")
                failed.compileResult = nil
                activityByNodeID[nodeID] = failed
                compileTasks.removeValue(forKey: nodeID)
                compileTaskRequestIDs.removeValue(forKey: nodeID)
                if error is CancellationError {
                    latestCompileRequestIDs[nodeID] = UUID()
                }
                touchNode(nodeID)
                if !(error is CancellationError) {
                    record(error, nodeID: nodeID, fieldPath: "script.source")
                }
            }
            throw error
        }

        guard latestCompileRequestIDs[nodeID] == requestID,
              compileTaskRequestIDs[nodeID] == requestID else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            finishCancelledCompile(nodeID: nodeID, requestID: requestID)
            throw CancellationError()
        }

        let persistedDraft: DSPScriptDraftDocument?
        do {
            persistedDraft = try await draftStore.getDraft(nodeID: nodeID)
        } catch {
            if latestCompileRequestIDs[nodeID] == requestID,
               compileTaskRequestIDs[nodeID] == requestID {
                compileTasks.removeValue(forKey: nodeID)
                compileTaskRequestIDs.removeValue(forKey: nodeID)
                var failed = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
                failed.compilePhase = .failed
                failed.compileDiagnostics = Self.diagnostics(for: error, nodeID: nodeID, fieldPath: "scriptDraft")
                failed.compileResult = nil
                activityByNodeID[nodeID] = failed
                touchNode(nodeID)
                record(error, nodeID: nodeID, fieldPath: "scriptDraft")
            }
            throw error
        }
        guard latestCompileRequestIDs[nodeID] == requestID,
              compileTaskRequestIDs[nodeID] == requestID else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            finishCancelledCompile(nodeID: nodeID, requestID: requestID)
            throw CancellationError()
        }
        guard let persistedDraft,
              persistedDraft.revisionString == draft.revisionString else {
            compileTasks.removeValue(forKey: nodeID)
            compileTaskRequestIDs.removeValue(forKey: nodeID)
            if let persistedDraft { drafts[nodeID] = persistedDraft }
            var stale = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
            stale.compilePhase = .failed
            stale.compileDiagnostics = Self.diagnostics(
                for: DSPScriptControllerError.staleCompile,
                nodeID: nodeID,
                fieldPath: "script.source"
            )
            stale.compileResult = nil
            activityByNodeID[nodeID] = stale
            touchNode(nodeID)
            record(DSPScriptControllerError.staleCompile, nodeID: nodeID, fieldPath: "script.source")
            throw DSPScriptControllerError.staleCompile
        }
        compileTasks.removeValue(forKey: nodeID)
        compileTaskRequestIDs.removeValue(forKey: nodeID)

        let estimatedOperations = Double(program.weightedOperationsPerFrame)
            * Double(format.channelCount)
            * format.sampleRate
        let result = DSPScriptCompileResult(
            nodeID: nodeID,
            draftRevision: draft.revisionString,
            requestID: requestID,
            sourceHash: program.sourceHash,
            languageVersion: program.languageVersion,
            format: format,
            parameters: program.parameters,
            parameterValues: program.parameterValues,
            latencyFrames: program.latencyFrames,
            stateBytes: program.stateBytes,
            weightedOperationsPerFrame: program.weightedOperationsPerFrame,
            estimatedWeightedOperationsPerSecond: estimatedOperations,
            compiledAt: Date(),
            program: program
        )
        var succeeded = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        succeeded.compilePhase = .succeeded
        succeeded.compileRequestID = requestID
        succeeded.compileDiagnostics = []
        succeeded.compileResult = result
        activityByNodeID[nodeID] = succeeded
        touchNode(nodeID)
        lastError = nil
        return result
    }

    @discardableResult
    func testDraft(
        nodeID: UUID,
        format: DSPAudioFormat,
        fixture: DSPScriptFixture,
        expectedDraftRevision: String? = nil
    ) async throws -> DSPScriptFixtureResult {
        let compiled: DSPScriptCompileResult
        if let draft = try await getDraft(nodeID: nodeID),
           let cached = activityByNodeID[nodeID]?.compileResult,
           cached.draftRevision == draft.revisionString,
           cached.format == format,
           expectedDraftRevision == nil || expectedDraftRevision == draft.revisionString {
            compiled = cached
        } else {
            compiled = try await compileDraft(
                nodeID: nodeID,
                format: format,
                expectedDraftRevision: expectedDraftRevision
            )
        }
        guard expectedDraftRevision == nil || compiled.draftRevision == expectedDraftRevision else {
            throw DSPScriptControllerError.draftRevisionConflict
        }

        guard canStartNodeOperation(nodeID) else {
            let error = DSPScriptControllerError.operationLimitReached
            record(error, nodeID: nodeID, fieldPath: "script.test")
            throw error
        }
        cancelTest(nodeID: nodeID)
        let requestID = UUID()
        latestTestRequestIDs[nodeID] = requestID
        var activity = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        activity.testPhase = .running
        activity.testRequestID = requestID
        activity.testDiagnostics = []
        activity.testResult = nil
        activityByNodeID[nodeID] = activity
        touchNode(nodeID)

        let channelMask = Array(repeating: true, count: format.channelCount)
        let testTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await DSPScriptFixtureRunner.run(
                program: compiled.program,
                channelMask: channelMask,
                fixtures: [fixture]
            )
        }
        testTasks[nodeID] = testTask
        testTaskRequestIDs[nodeID] = requestID

        do {
            let results = try await withTaskCancellationHandler {
                try await testTask.value
            } onCancel: {
                testTask.cancel()
            }
            guard latestTestRequestIDs[nodeID] == requestID,
                  !Task.isCancelled,
                  testTaskRequestIDs[nodeID] == requestID else {
                throw CancellationError()
            }
            guard let result = results.first, results.count == 1 else {
                throw DSPScriptControllerError.invalidFixtureResult
            }
            let persistedDraft = try await draftStore.getDraft(nodeID: nodeID)
            guard latestTestRequestIDs[nodeID] == requestID,
                  !Task.isCancelled,
                  testTaskRequestIDs[nodeID] == requestID else {
                throw CancellationError()
            }
            guard persistedDraft?.revisionString == compiled.draftRevision else {
                throw DSPScriptControllerError.staleCompile
            }
            testTasks.removeValue(forKey: nodeID)
            testTaskRequestIDs.removeValue(forKey: nodeID)
            let testDiagnostics = result.diagnostics.map { diagnostic in
                DSPDiagnostic(
                    code: diagnostic.code,
                    message: diagnostic.message,
                    fieldPath: diagnostic.fieldPath ?? "script.test.runtime",
                    nodeID: diagnostic.nodeID ?? nodeID,
                    retryable: diagnostic.retryable,
                    line: diagnostic.line,
                    column: diagnostic.column
                )
            }
            let failureDiagnostics: [DSPDiagnostic]
            if result.scriptFaulted && testDiagnostics.isEmpty {
                failureDiagnostics = [DSPDiagnostic(
                    code: "dsp.script.fixtureFault",
                    message: "测试运行触发脚本故障。",
                    fieldPath: "script.test.runtime",
                    nodeID: nodeID,
                    retryable: true
                )]
            } else {
                failureDiagnostics = testDiagnostics
            }
            var finished = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
            finished.testPhase = failureDiagnostics.isEmpty ? .succeeded : .failed
            finished.testRequestID = requestID
            finished.testDiagnostics = failureDiagnostics
            finished.testResult = result
            activityByNodeID[nodeID] = finished
            touchNode(nodeID)
            if let diagnostic = failureDiagnostics.first {
                lastError = diagnostic
            } else if lastError?.nodeID == nodeID {
                lastError = nil
            }
            return result
        } catch {
            if testTaskRequestIDs[nodeID] == requestID {
                testTasks.removeValue(forKey: nodeID)
                testTaskRequestIDs.removeValue(forKey: nodeID)
            }
            if latestTestRequestIDs[nodeID] == requestID {
                var failed = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
                failed.testPhase = error is CancellationError ? .cancelled : .failed
                failed.testDiagnostics = Self.diagnostics(for: error, nodeID: nodeID, fieldPath: "script.test")
                failed.testResult = nil
                activityByNodeID[nodeID] = failed
                touchNode(nodeID)
                if error is CancellationError {
                    testTasks.removeValue(forKey: nodeID)
                    testTaskRequestIDs.removeValue(forKey: nodeID)
                } else {
                    record(error, nodeID: nodeID, fieldPath: "script.test")
                }
            }
            throw error
        }
    }

    @discardableResult
    func applyCompiledDraft(
        nodeID: UUID,
        expectedDraftRevision: String,
        expectedConfigurationRevision: String? = nil
    ) throws -> DSPApplyStatus {
        guard let dspController else { throw DSPScriptControllerError.notBound }
        guard let draft = drafts[nodeID] else { throw DSPScriptControllerError.missingDraft }
        touchNode(nodeID)
        guard draft.revisionString == expectedDraftRevision,
              let compiled = activityByNodeID[nodeID]?.compileResult,
              compiled.draftRevision == expectedDraftRevision,
              latestCompileRequestIDs[nodeID] == compiled.requestID else {
            lastError = Self.diagnostics(
                for: DSPScriptControllerError.staleCompile,
                nodeID: nodeID,
                fieldPath: "script.source"
            ).first
            throw DSPScriptControllerError.staleCompile
        }
        if let activeFormat = dspController.status.format, activeFormat != compiled.format {
            lastError = Self.diagnostics(
                for: DSPScriptControllerError.formatChanged,
                nodeID: nodeID,
                fieldPath: "script.source"
            ).first
            throw DSPScriptControllerError.formatChanged
        }
        guard var candidateNode = dspController.configuration.nodes.first(where: { $0.nodeID == nodeID }),
              candidateNode.typeID == DSPNodeConfiguration.scriptTypeID,
              candidateNode.algorithmVersion == 1,
              var script = candidateNode.scriptParameters else {
            throw DSPScriptControllerError.missingScriptNode
        }
        script.languageVersion = compiled.languageVersion
        script.source = draft.source
        script.values = compiled.parameterValues
        candidateNode.scriptParameters = script
        var candidate = dspController.configuration
        guard let index = candidate.nodes.firstIndex(where: { $0.nodeID == nodeID }) else {
            throw DSPScriptControllerError.missingScriptNode
        }
        candidate.nodes[index] = candidateNode
        let status = try dspController.apply(candidate, expectedRevision: expectedConfigurationRevision)
        dspController.commitPendingApply()
        return status
    }

    func cancelCompile(nodeID: UUID, requestID: UUID? = nil) {
        guard let latest = latestCompileRequestIDs[nodeID], requestID == nil || requestID == latest else { return }
        compileTasks[nodeID]?.cancel()
        compileTasks.removeValue(forKey: nodeID)
        compileTaskRequestIDs.removeValue(forKey: nodeID)
        latestCompileRequestIDs[nodeID] = UUID()
        var activity = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        activity.compilePhase = .cancelled
        activity.compileDiagnostics = []
        activity.compileResult = nil
        activityByNodeID[nodeID] = activity
    }

    private func finishCancelledCompile(nodeID: UUID, requestID: UUID) {
        guard latestCompileRequestIDs[nodeID] == requestID,
              compileTaskRequestIDs[nodeID] == requestID else { return }
        compileTasks.removeValue(forKey: nodeID)
        compileTaskRequestIDs.removeValue(forKey: nodeID)
        latestCompileRequestIDs[nodeID] = UUID()
        var activity = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        activity.compilePhase = .cancelled
        activity.compileDiagnostics = []
        activity.compileResult = nil
        activityByNodeID[nodeID] = activity
        touchNode(nodeID)
    }

    func cancelTest(nodeID: UUID, requestID: UUID? = nil) {
        guard let latest = latestTestRequestIDs[nodeID], requestID == nil || requestID == latest else { return }
        testTasks[nodeID]?.cancel()
        testTasks.removeValue(forKey: nodeID)
        testTaskRequestIDs.removeValue(forKey: nodeID)
        latestTestRequestIDs[nodeID] = UUID()
        var activity = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        activity.testPhase = .cancelled
        activity.testDiagnostics = []
        activity.testResult = nil
        activityByNodeID[nodeID] = activity
    }

    func clearDiagnostics() {
        lastError = nil
        for nodeID in Array(activityByNodeID.keys) {
            guard var activity = activityByNodeID[nodeID] else { continue }
            activity.compileDiagnostics = []
            activity.testDiagnostics = []
            activityByNodeID[nodeID] = activity
        }
    }

    func clearErrors() {
        clearDiagnostics()
    }

    private func invalidateOperationsForDraftChange(nodeID: UUID) {
        cancelCompile(nodeID: nodeID)
        cancelTest(nodeID: nodeID)
        nodeGenerations[nodeID, default: 0] &+= 1
        var activity = activityByNodeID[nodeID] ?? DSPScriptNodeActivity()
        activity.compilePhase = .idle
        activity.compileDiagnostics = []
        activity.compileResult = nil
        activity.testPhase = .idle
        activity.testDiagnostics = []
        activity.testResult = nil
        activityByNodeID[nodeID] = activity
    }

    private func touchNode(_ nodeID: UUID) {
        nodeAccessOrder.removeAll { $0 == nodeID }
        nodeAccessOrder.append(nodeID)
        trimCachedNodeStates(protecting: nodeID)
    }

    private func trimCachedNodeStates(protecting nodeID: UUID) {
        var cachedIDs = Set(drafts.keys).union(activityByNodeID.keys)
        let activeScriptIDs = Set(
            (dspController?.configuration.nodes ?? [])
                .filter { $0.typeID == DSPNodeConfiguration.scriptTypeID }
                .map(\.nodeID)
        )
        var protectedIDs = activeScriptIDs
        if protectedIDs.count < Self.maximumCachedNodeStates {
            protectedIDs.insert(nodeID)
        }
        while cachedIDs.count > Self.maximumCachedNodeStates {
            guard let evictedID = nodeAccessOrder.first(where: {
                cachedIDs.contains($0)
                    && !protectedIDs.contains($0)
                    && compileTasks[$0] == nil
                    && testTasks[$0] == nil
            }) else { break }
            drafts.removeValue(forKey: evictedID)
            activityByNodeID.removeValue(forKey: evictedID)
            latestCompileRequestIDs.removeValue(forKey: evictedID)
            latestTestRequestIDs.removeValue(forKey: evictedID)
            nodeGenerations.removeValue(forKey: evictedID)
            nodeAccessOrder.removeAll { $0 == evictedID }
            cachedIDs.remove(evictedID)
        }
        nodeAccessOrder.removeAll { !cachedIDs.contains($0) }
    }

    private func canStartNodeOperation(_ nodeID: UUID) -> Bool {
        var activeIDs = Set(
            (dspController?.configuration.nodes ?? [])
                .filter { $0.typeID == DSPNodeConfiguration.scriptTypeID }
                .map(\.nodeID)
        )
        activeIDs.formUnion(compileTasks.keys)
        activeIDs.formUnion(testTasks.keys)
        activeIDs.insert(nodeID)
        return activeIDs.count <= Self.maximumCachedNodeStates
    }

    private func cancelAllOperations() {
        for task in compileTasks.values { task.cancel() }
        for task in testTasks.values { task.cancel() }
        compileTasks.removeAll()
        compileTaskRequestIDs.removeAll()
        testTasks.removeAll()
        testTaskRequestIDs.removeAll()
        for nodeID in Array(latestCompileRequestIDs.keys) { latestCompileRequestIDs[nodeID] = UUID() }
        for nodeID in Array(latestTestRequestIDs.keys) { latestTestRequestIDs[nodeID] = UUID() }
    }

    private func record(_ error: Error, nodeID: UUID?, fieldPath: String) {
        lastError = Self.diagnostics(for: error, nodeID: nodeID, fieldPath: fieldPath).first
    }

    private nonisolated static func diagnostics(
        for error: Error,
        nodeID: UUID?,
        fieldPath: String
    ) -> [DSPDiagnostic] {
        if let compilation = error as? DSPScriptCompilationError {
            return compilation.diagnostics.map { diagnostic in
                DSPDiagnostic(
                    code: diagnostic.code,
                    message: diagnostic.message,
                    fieldPath: diagnostic.fieldPath ?? fieldPath,
                    nodeID: diagnostic.nodeID ?? nodeID,
                    retryable: diagnostic.retryable,
                    line: diagnostic.line,
                    column: diagnostic.column
                )
            }
        }
        if let validation = error as? DSPConfigurationValidationError {
            return validation.diagnostics
        }
        return [DSPDiagnostic(
            code: "dsp.scriptOperationFailed",
            message: error.localizedDescription,
            fieldPath: fieldPath,
            nodeID: nodeID,
            retryable: true
        )]
    }

    private nonisolated static func validateCompileInput(
        source: String,
        values: [String: Double],
        format: DSPAudioFormat
    ) throws {
        guard source.utf8.count <= DSPScriptCompiler.maximumSourceBytes,
              values.count <= DSPScriptCompiler.maximumParameterCount,
              values.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite }),
              format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0,
              format.channelCount <= DSPScriptCompiler.maximumChannelCount else {
            throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                code: "dsp.scriptConfiguration",
                message: "脚本源码、参数或音频格式超出支持范围。",
                fieldPath: "script"
            )])
        }
    }

    private nonisolated static func compileOffMain(
        source: String,
        languageVersion: Int,
        parameterValues: [String: Double],
        format: DSPAudioFormat
    ) async throws -> DSPScriptProgram {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try DSPScriptCompiler.compile(
                source: source,
                languageVersion: languageVersion,
                parameterValues: parameterValues,
                format: format
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

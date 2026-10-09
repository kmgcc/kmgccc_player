//
//  AudioDSPController.swift
//  myPlayer2
//
//  App-owned configuration, apply state, and preset operations for audio DSP.
//

import Foundation
import Observation

nonisolated struct DSPConfigurationValidationError: Error, LocalizedError, Sendable {
    var diagnostics: [DSPDiagnostic]

    nonisolated var errorDescription: String? {
        diagnostics.first?.message ?? "音频配置无效。"
    }
}

@Observable
@MainActor
final class AudioDSPController {
    private(set) var configuration: AudioDSPConfiguration
    private(set) var revisionString: String
    private(set) var presets: [DSPPresetDocument]
    private(set) var selectedPresetID: UUID?
    private(set) var isModified = false
    private(set) var status: DSPApplyStatus
    private(set) var preparedRevision: String?
    private(set) var effectiveRevision: String?
    private(set) var audibleRevision: String?
    private(set) var lastError: DSPDiagnostic?
    private(set) var diagnostics: [DSPDiagnostic] = []

    var applyConfiguration: (@MainActor (AudioDSPConfiguration, String, UUID) -> Void)?

    @ObservationIgnored private let store: DSPPresetStore
    @ObservationIgnored private var sourceIsLocal = true
    @ObservationIgnored private var latestRequestID: UUID?
    @ObservationIgnored private var pendingApplyTask: Task<Void, Never>?
    @ObservationIgnored private var draftWriteTask: Task<Void, Never>?
    @ObservationIgnored private var pendingConfiguration: AudioDSPConfiguration?
    @ObservationIgnored private var pendingRevision: String?
    @ObservationIgnored private var pendingRequestID: UUID?
    @ObservationIgnored private var hasReceivedUserConfiguration = false
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var requestStatusByID: [UUID: DSPApplyStatus] = [:]
    @ObservationIgnored private var requestStatusOrder: [UUID] = []

    init(store: DSPPresetStore? = nil) {
        let initialRevision = UUID().uuidString
        let initialConfiguration = AudioDSPConfiguration.defaultFlat
        self.store = store ?? DSPPresetStore.shared
        configuration = initialConfiguration
        revisionString = initialRevision
        presets = [.flat]
        selectedPresetID = DSPPresetDocument.flatPresetID
        status = DSPApplyStatus(revisionString: initialRevision)
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapPresets()
        }
    }

    @discardableResult
    func validate(_ candidate: AudioDSPConfiguration) throws -> AudioDSPConfiguration {
        let issues = Self.validationDiagnostics(for: candidate, format: status.format)
        guard issues.isEmpty else {
            throw DSPConfigurationValidationError(diagnostics: issues)
        }
        return candidate
    }

    @discardableResult
    func apply(
        _ candidate: AudioDSPConfiguration,
        expectedRevision: String? = nil,
        dryRun: Bool = false
    ) throws -> DSPApplyStatus {
        if let expectedRevision, expectedRevision != revisionString {
            throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                code: "dsp.revisionConflict",
                message: "音频配置已更新，请重新载入后再试。",
                fieldPath: "expectedRevision",
                retryable: true
            )])
        }

        let validated = try validate(candidate)
        guard !dryRun else {
            return DSPApplyStatus(revisionString: revisionString, state: .ready)
        }

        hasReceivedUserConfiguration = true
        supersedeLatestPendingRequest()
        pendingApplyTask?.cancel()
        let nextRevision = UUID().uuidString
        let requestID = UUID()
        configuration = validated
        revisionString = nextRevision
        latestRequestID = requestID
        pendingConfiguration = validated
        pendingRevision = nextRevision
        pendingRequestID = requestID
        lastError = nil
        diagnostics = []
        refreshModifiedState()
        scheduleWorkingDraftWrite()

        if !sourceIsLocal {
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: nextRevision,
                state: .inactiveExternalSource
            )
            remember(status)
            pendingConfiguration = nil
            pendingRevision = nil
            pendingRequestID = nil
            preparedRevision = nil
            effectiveRevision = nil
            audibleRevision = nil
            return status
        }

        if applyConfiguration == nil {
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: nextRevision,
                state: .ready
            )
            remember(status)
            preparedRevision = nextRevision
            effectiveRevision = nextRevision
            audibleRevision = nil
            pendingConfiguration = nil
            pendingRevision = nil
            pendingRequestID = nil
            return status
        }

        status = DSPApplyStatus(
            requestID: requestID,
            revisionString: nextRevision,
            state: .preparing,
            format: status.format
        )
        remember(status)
        scheduleApplyAfterDebounce()
        return status
    }

    /// Coalesces continuous edits into one renderer request. Call this when an
    /// interaction ends so the final value is sent without waiting for debounce.
    func commitPendingApply() {
        pendingApplyTask?.cancel()
        pendingApplyTask = nil
        dispatchPendingApply()
        scheduleWorkingDraftWrite(immediate: true)
    }

    /// Convenience path for UI bindings. Validation failures stay visible in
    /// the shared controller state instead of escaping a SwiftUI setter.
    func updateConfiguration(
        commit: Bool = false,
        _ update: (inout AudioDSPConfiguration) -> Void
    ) {
        var candidate = configuration
        update(&candidate)
        // Quantized sliders can produce the same value across many pointer
        // events. Keep revisions, persistence and renderer requests unchanged.
        guard candidate != configuration else {
            if commit { commitPendingApply() }
            return
        }
        do {
            _ = try apply(candidate)
            if commit { commitPendingApply() }
        } catch {
            record(error)
        }
    }

    func bindPlayback(
        apply handler: @escaping @MainActor (AudioDSPConfiguration, String, UUID) -> Void
    ) {
        supersedeLatestPendingRequest()
        applyConfiguration = handler
        guard sourceIsLocal else {
            let requestID = UUID()
            latestRequestID = requestID
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: revisionString,
                state: .inactiveExternalSource
            )
            remember(status)
            return
        }
        pendingConfiguration = configuration
        pendingRevision = revisionString
        pendingRequestID = UUID()
        latestRequestID = pendingRequestID
        status = DSPApplyStatus(
            requestID: pendingRequestID,
            revisionString: revisionString,
            state: .preparing
        )
        remember(status)
        dispatchPendingApply()
    }

    func setSourceIsLocal(_ isLocal: Bool) {
        guard sourceIsLocal != isLocal else { return }
        supersedeLatestPendingRequest()
        sourceIsLocal = isLocal
        pendingApplyTask?.cancel()
        pendingApplyTask = nil
        pendingConfiguration = nil
        pendingRevision = nil
        pendingRequestID = nil
        latestRequestID = nil
        if isLocal {
            let requestID = UUID()
            latestRequestID = requestID
            guard applyConfiguration != nil else {
                status = DSPApplyStatus(
                    requestID: requestID,
                    revisionString: revisionString,
                    state: .ready
                )
                remember(status)
                return
            }
            pendingConfiguration = configuration
            pendingRevision = revisionString
            pendingRequestID = requestID
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: revisionString,
                state: .preparing
            )
            remember(status)
            dispatchPendingApply()
        } else {
            preparedRevision = nil
            effectiveRevision = nil
            audibleRevision = nil
            let requestID = UUID()
            latestRequestID = requestID
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: revisionString,
                state: .inactiveExternalSource
            )
            remember(status)
        }
    }

    func detachPlayback() {
        supersedeLatestPendingRequest()
        pendingApplyTask?.cancel()
        pendingApplyTask = nil
        pendingConfiguration = nil
        pendingRevision = nil
        pendingRequestID = nil
        latestRequestID = nil
        applyConfiguration = nil
        audibleRevision = nil
        preparedRevision = revisionString
        effectiveRevision = revisionString
        let requestID = UUID()
        latestRequestID = requestID
        status = DSPApplyStatus(requestID: requestID, revisionString: revisionString, state: .ready)
        remember(status)
    }

    func receive(_ event: DSPApplyEvent) {
        guard let existing = requestStatusByID[event.requestID],
              existing.revisionString == event.revisionString else { return }

        var eventStatus = event.status
        if existing.state == .audible && event.state == .superseded {
            eventStatus = existing
        } else if existing.state == .superseded,
                  [.preparing, .scheduled].contains(event.state) {
            eventStatus = existing
        }
        remember(eventStatus)

        guard event.requestID == latestRequestID,
              event.revisionString == revisionString else { return }

        status = eventStatus
        diagnostics = event.diagnostics
        lastError = event.state == .failed ? event.diagnostics.first : nil
        switch event.state {
        case .ready:
            preparedRevision = event.revisionString
            effectiveRevision = event.revisionString
            audibleRevision = nil
        case .preparing:
            break
        case .scheduled:
            preparedRevision = event.revisionString
            effectiveRevision = event.revisionString
        case .audible:
            preparedRevision = event.revisionString
            effectiveRevision = event.revisionString
            audibleRevision = event.revisionString
        case .superseded:
            break
        case .failed:
            break
        case .inactiveExternalSource:
            preparedRevision = nil
            effectiveRevision = nil
            audibleRevision = nil
        }
    }

    func requestStatus(id: UUID) -> DSPApplyStatus? {
        requestStatusByID[id]
    }

    func report(error: Error) {
        record(error)
    }

    /// Clears displayed error history without changing the active configuration
    /// or issuing another renderer request.
    func clearErrors() {
        diagnostics = []
        lastError = nil
        status = DSPApplyStatus(
            requestID: status.requestID,
            revisionString: status.revisionString,
            state: status.state,
            format: status.format,
            scheduledPTS: status.scheduledPTS,
            audiblePTS: status.audiblePTS,
            headroomDB: status.headroomDB,
            processingLatencyFrames: status.processingLatencyFrames,
            mediaMappingLatencyFrames: status.mediaMappingLatencyFrames,
            peakGuarantee: status.peakGuarantee,
            warnings: status.warnings,
            diagnostics: [],
            rebuffered: status.rebuffered
        )
        remember(status)
    }

    func reloadPresets() async {
        let result = await store.load()
        merge(result)
    }

    /// Waits for the one-time store bootstrap so automation callers can read a
    /// stable in-memory preset snapshot without reopening the directory.
    func ensureLoaded() async {
        await bootstrapTask?.value
    }

    func preset(id: UUID) async throws -> DSPPresetDocument {
        if id == DSPPresetDocument.flatPresetID { return .flat }
        if let document = presets.first(where: { $0.presetID == id }) {
            return document
        }
        return try await store.preset(id: id)
    }

    @discardableResult
    func savePreset(
        name: String,
        id: UUID? = nil,
        expectedPresetRevision: String? = nil,
        configuration explicitConfiguration: AudioDSPConfiguration? = nil
    ) async throws -> DSPPresetDocument {
        let savedConfiguration = try validate(explicitConfiguration ?? configuration)
        var expectedStoreRevision = expectedPresetRevision
        if expectedStoreRevision == nil, let id {
            if let existing = presets.first(where: { $0.presetID == id }) {
                expectedStoreRevision = existing.revisionString
            } else if let existing = try? await store.preset(id: id) {
                expectedStoreRevision = existing.revisionString
            }
        }
        let document = DSPPresetDocument(
            presetID: id ?? UUID(),
            name: name,
            configuration: savedConfiguration
        )
        let saved = try await store.save(document, expectedRevision: expectedStoreRevision)
        await reloadPresets()
        if saved.configuration == configuration {
            selectedPresetID = saved.presetID
            refreshModifiedState()
            scheduleWorkingDraftWrite(immediate: true)
        }
        return saved
    }

    @discardableResult
    func renamePreset(
        id: UUID,
        name: String,
        expectedPresetRevision: String? = nil
    ) async throws -> DSPPresetDocument {
        guard id != DSPPresetDocument.flatPresetID else {
            throw DSPPresetStoreError.immutableBuiltIn
        }
        var document = try await store.preset(id: id)
        if let expectedPresetRevision,
           document.revisionString != expectedPresetRevision {
            throw DSPPresetStoreError.revisionConflict
        }
        document.name = name
        let saved = try await store.save(
            document,
            expectedRevision: expectedPresetRevision ?? document.revisionString
        )
        await reloadPresets()
        refreshModifiedState()
        return saved
    }

    @discardableResult
    func duplicatePreset(id: UUID, name: String, expectedPresetRevision: String? = nil) async throws -> DSPPresetDocument {
        let expected = expectedPresetRevision ?? presets.first(where: { $0.presetID == id })?.revisionString
        let source = try await store.preset(id: id)
        if let expected, source.revisionString != expected { throw DSPPresetStoreError.revisionConflict }
        let copied = try await store.importPreset(source, name: name)
        await reloadPresets()
        return copied
    }

    func deletePreset(id: UUID, expectedPresetRevision: String? = nil) async throws {
        var expectedStoreRevision = expectedPresetRevision
        if expectedStoreRevision == nil {
            if let existing = presets.first(where: { $0.presetID == id }) {
                expectedStoreRevision = existing.revisionString
            } else {
                let existing = try await store.preset(id: id)
                expectedStoreRevision = existing.revisionString
            }
        }
        try await store.delete(id: id, expectedRevision: expectedStoreRevision)
        await reloadPresets()
        if selectedPresetID == id {
            selectedPresetID = nil
            isModified = true
            scheduleWorkingDraftWrite(immediate: true)
        }
    }

    func selectPreset(id: UUID, expectedRevision: String? = nil, expectedPresetRevision: String? = nil) throws -> DSPApplyStatus {
        if let expectedRevision, expectedRevision != revisionString {
            throw DSPConfigurationValidationError(diagnostics: [DSPDiagnostic(
                code: "dsp.revisionConflict",
                message: "音频配置已更新，请重新载入后再试。",
                fieldPath: "expectedRevision",
                retryable: true
            )])
        }
        guard let document = presets.first(where: { $0.presetID == id }) else {
            throw DSPPresetStoreError.notFound
        }
        if let expectedPresetRevision, expectedPresetRevision != document.revisionString {
            throw DSPPresetStoreError.revisionConflict
        }
        let validated = try validate(document.configuration)
        let previousID = selectedPresetID
        selectedPresetID = id
        do {
            let newStatus = try apply(validated)
            refreshModifiedState()
            return newStatus
        } catch {
            selectedPresetID = previousID
            throw error
        }
    }

    func importPreview(from url: URL) async throws -> DSPPresetImportPreview? {
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        guard let decoded = await store.importPreview(from: data) else { return nil }
        guard decoded.isCompatible else { return decoded }
        return try importPreview(document: decoded.document)
    }

    func importPreview(document: DSPPresetDocument) throws -> DSPPresetImportPreview {
        guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DSPPresetImportPreview(document: document, isCompatible: false, warnings: [],
                diagnostics: [DSPDiagnostic(code: "dsp.invalidPresetName", message: "预设名称不能为空。", fieldPath: "name")])
        }
        guard document.schemaVersion == DSPPresetDocument.schemaVersion else {
            return DSPPresetImportPreview(
                document: document,
                isCompatible: false,
                warnings: [],
                diagnostics: [DSPDiagnostic(
                    code: "dsp.presetIncompatible",
                    message: DSPPresetStoreError.unsupportedSchema(document.schemaVersion).localizedDescription,
                    fieldPath: "schemaVersion"
                )]
            )
        }
        do {
            _ = try validate(document.configuration)
            return DSPPresetImportPreview(
                document: document,
                isCompatible: true,
                warnings: Self.disabledUnknownNodeWarnings(in: document.configuration),
                diagnostics: []
            )
        } catch let error as DSPConfigurationValidationError {
            return DSPPresetImportPreview(
                document: document,
                isCompatible: false,
                canImport: error.diagnostics.allSatisfy {
                    $0.code == "dsp.unsupportedNode" || $0.code == "dsp.unsupportedParameter"
                },
                warnings: Self.disabledUnknownNodeWarnings(in: document.configuration),
                diagnostics: error.diagnostics
            )
        }
    }

    @discardableResult
    func importPreset(
        _ preview: DSPPresetImportPreview,
        name: String? = nil
    ) async throws -> DSPPresetDocument {
        let checked = try importPreview(document: preview.document)
        guard checked.canImport else { throw DSPPresetStoreError.incompatibleImport }
        let saved = try await store.importPreset(preview.document, name: name)
        await reloadPresets()
        return saved
    }

    func exportPreset(id: UUID) async throws -> Data {
        let document = try await store.preset(id: id)
        return try await store.export(document)
    }

    private func bootstrapPresets() async {
        let result = await store.load()
        merge(result)
        guard !hasReceivedUserConfiguration else { return }
        guard let draft = result.workingDraft else { return }
        do {
            let restored = try validate(draft.configuration)
            configuration = restored
            revisionString = draft.revisionString
            selectedPresetID = draft.selectedPresetID.flatMap { id in
                presets.contains(where: { $0.presetID == id }) ? id : nil
            }
            refreshModifiedState()
            if sourceIsLocal, applyConfiguration != nil {
                supersedeLatestPendingRequest()
                pendingConfiguration = restored
                pendingRevision = draft.revisionString
                pendingRequestID = UUID()
                latestRequestID = pendingRequestID
                status = DSPApplyStatus(
                    requestID: pendingRequestID,
                    revisionString: draft.revisionString,
                    state: .preparing
                )
                remember(status)
                dispatchPendingApply()
            } else if !sourceIsLocal {
                let requestID = UUID()
                latestRequestID = requestID
                status = DSPApplyStatus(
                    requestID: requestID,
                    revisionString: draft.revisionString,
                    state: .inactiveExternalSource
                )
                remember(status)
            } else {
                let requestID = UUID()
                latestRequestID = requestID
                status = DSPApplyStatus(
                    requestID: requestID,
                    revisionString: draft.revisionString,
                    state: .ready
                )
                remember(status)
                preparedRevision = draft.revisionString
                effectiveRevision = draft.revisionString
            }
        } catch {
            record(error)
        }
    }

    private func merge(_ result: DSPPresetStoreLoadResult) {
        presets = [.flat] + result.presets
        diagnostics = result.diagnostics
        lastError = result.diagnostics.first
        refreshModifiedState()
    }

    private func refreshModifiedState() {
        guard let selectedPresetID,
              let selected = presets.first(where: { $0.presetID == selectedPresetID })
        else {
            isModified = true
            return
        }
        isModified = configuration != selected.configuration
    }

    private func scheduleApplyAfterDebounce() {
        pendingApplyTask?.cancel()
        pendingApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            self.pendingApplyTask = nil
            self.dispatchPendingApply()
        }
    }

    private func dispatchPendingApply() {
        guard let configuration = pendingConfiguration,
              let revision = pendingRevision,
              let requestID = pendingRequestID,
              requestID == latestRequestID
        else { return }
        pendingConfiguration = nil
        pendingRevision = nil
        pendingRequestID = nil

        guard sourceIsLocal else {
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: revision,
                state: .inactiveExternalSource
            )
            remember(status)
            return
        }

        if let applyConfiguration {
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: revision,
                state: .preparing,
                format: status.format
            )
            remember(status)
            applyConfiguration(configuration, revision, requestID)
        } else {
            status = DSPApplyStatus(
                requestID: requestID,
                revisionString: revision,
                state: .ready
            )
            remember(status)
            preparedRevision = revision
            effectiveRevision = revision
        }
    }

    private func scheduleWorkingDraftWrite(immediate: Bool = false) {
        draftWriteTask?.cancel()
        let draft = DSPWorkingDraftDocument(
            revisionString: revisionString,
            selectedPresetID: selectedPresetID,
            configuration: configuration
        )
        draftWriteTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            do {
                try await self.store.saveWorkingDraft(draft)
            } catch {
                self.record(error)
            }
        }
    }

    private func supersedeLatestPendingRequest() {
        guard let latestRequestID,
              var latest = requestStatusByID[latestRequestID],
              [.preparing, .scheduled].contains(latest.state) else { return }
        latest.state = .superseded
        remember(latest)
    }

    private func remember(_ requestStatus: DSPApplyStatus) {
        guard let requestID = requestStatus.requestID else { return }
        if requestStatusByID[requestID] == nil {
            requestStatusOrder.append(requestID)
        }
        requestStatusByID[requestID] = requestStatus
        while requestStatusOrder.count > 64 {
            let expiredRequestID = requestStatusOrder.removeFirst()
            requestStatusByID[expiredRequestID] = nil
        }
    }

    private func record(_ error: Error) {
        if let validationError = error as? DSPConfigurationValidationError {
            diagnostics = validationError.diagnostics
            lastError = validationError.diagnostics.first
            return
        }

        let diagnostic = DSPDiagnostic(
            code: (error as? DSPPresetStoreError).map(Self.errorCode(for:)) ?? "dsp.operationFailed",
            message: error.localizedDescription,
            retryable: true
        )
        diagnostics = [diagnostic]
        lastError = diagnostic
    }

    private static func errorCode(for error: DSPPresetStoreError) -> String {
        switch error {
        case .invalidName: "dsp.invalidPresetName"
        case .immutableBuiltIn: "dsp.immutablePreset"
        case .notFound: "dsp.presetNotFound"
        case .revisionConflict: "dsp.revisionConflict"
        case .corruptExistingFile: "dsp.presetFileInvalid"
        case .unsupportedSchema: "dsp.presetIncompatible"
        case .incompatibleImport: "dsp.presetIncompatible"
        case .fileOperation: "dsp.presetStoreWriteFailed"
        }
    }

    private static func validationDiagnostics(
        for configuration: AudioDSPConfiguration,
        format: DSPAudioFormat?
    ) -> [DSPDiagnostic] {
        var result: [DSPDiagnostic] = []
        func add(
            _ code: String,
            _ message: String,
            _ path: String,
            nodeID: UUID? = nil,
            retryable: Bool = false,
            line: Int? = nil,
            column: Int? = nil
        ) {
            result.append(DSPDiagnostic(
                code: code,
                message: message,
                fieldPath: path,
                nodeID: nodeID,
                retryable: retryable,
                line: line,
                column: column
            ))
        }

        if configuration.nodes.count > AudioDSPConfiguration.maximumNodeCount {
            add("dsp.invalidParameter", "效果节点不能超过 32 个。", "nodes")
        }
        if !configuration.inputTrimDB.isFinite || !(-24...24).contains(configuration.inputTrimDB) {
            add("dsp.invalidParameter", "输入增益范围为 −24 至 +24 dB。", "inputTrimDB")
        }
        if !configuration.outputTrimDB.isFinite || !(-24...24).contains(configuration.outputTrimDB) {
            add("dsp.invalidParameter", "输出增益范围为 −24 至 +24 dB。", "outputTrimDB")
        }
        if !configuration.headroom.marginDB.isFinite || !(0...12).contains(configuration.headroom.marginDB) {
            add("dsp.invalidParameter", "余量范围为 0 至 12 dB。", "headroom.marginDB")
        }

        let scriptNodeCount = configuration.nodes.filter {
            $0.typeID == DSPNodeConfiguration.scriptTypeID
        }.count
        if scriptNodeCount > 4 {
            add("dsp.invalidParameter", "效果链最多包含 4 个脚本。", "nodes")
        }
        var totalScriptOperationsPerSecond = 0.0
        var scriptLatencyFrames = 0
        let nativeLatencyFrames = configuration.nodes.filter { $0.enabled }.reduce(0) { total, node in
            if node.typeID == DSPNodeConfiguration.virtualBassTypeID,
               let parameters = node.virtualBassParameters, parameters.amount * parameters.mix > 0 {
                return total + 64
            }
            if node.typeID == DSPNodeConfiguration.tubeTypeID,
               let parameters = node.tubeParameters, parameters.mix > 0 { return total + 64 }
            return total
        }
        var seenIDs = Set<UUID>()
        for (index, node) in configuration.nodes.enumerated() {
            let prefix = "nodes.\(index)"
            if !seenIDs.insert(node.nodeID).inserted {
                add("dsp.invalidParameter", "效果节点 ID 必须唯一。", "\(prefix).nodeID", nodeID: node.nodeID)
            }
            if node.typeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || node.algorithmVersion < 1 || node.quality.isEmpty || node.channelPolicy.isEmpty {
                add("dsp.invalidParameter", "效果节点信息不完整。", prefix, nodeID: node.nodeID)
            }
            guard node.enabled else { continue }
            guard node.typeID == DSPNodeConfiguration.parametricEQTypeID
                    || node.typeID == DSPNodeConfiguration.equalLoudnessTypeID
                    || node.typeID == DSPNodeConfiguration.stereoWidthTypeID
                    || node.typeID == DSPNodeConfiguration.virtualBassTypeID
                    || node.typeID == DSPNodeConfiguration.tubeTypeID
                    || node.typeID == DSPNodeConfiguration.scriptTypeID else {
                add(
                    "dsp.unsupportedNode",
                    "启用的效果“\(node.typeID)”与当前版本不兼容。",
                    "\(prefix).typeID",
                    nodeID: node.nodeID
                )
                continue
            }
            if node.algorithmVersion != 1 {
                add(
                    "dsp.unsupportedNode",
                    "此效果算法版本不受支持。",
                    "\(prefix).algorithmVersion",
                    nodeID: node.nodeID
                )
                continue
            }
            let supportedChannelPolicies = DSPNodeConfiguration.supportedChannelPolicies(forTypeID: node.typeID)
            if !supportedChannelPolicies.contains(node.channelPolicy) {
                add(
                    "dsp.unsupportedParameter",
                    "此声道策略暂不支持。",
                    "\(prefix).channelPolicy",
                    nodeID: node.nodeID
                )
            }
            let supportedQualities = DSPNodeConfiguration.supportedQualities(forTypeID: node.typeID)
            if !supportedQualities.contains(node.quality) {
                add(
                    "dsp.unsupportedParameter",
                    "此效果质量模式暂不支持。",
                    "\(prefix).quality",
                    nodeID: node.nodeID
                )
            }
            guard supportedQualities.contains(node.quality),
                  supportedChannelPolicies.contains(node.channelPolicy) else { continue }

            if node.typeID == DSPNodeConfiguration.scriptTypeID {
                for parameterKey in node.parameters.keys.sorted()
                    where !DSPScriptNodeParameters.supportedParameterKeys.contains(parameterKey) {
                    add(
                        "dsp.unsupportedParameter",
                        "此脚本参数暂不支持：\(parameterKey)。",
                        "\(prefix).parameters.\(parameterKey)",
                        nodeID: node.nodeID
                    )
                }
                guard let script = node.scriptParameters else {
                    add("dsp.invalidParameter", "脚本参数不完整。", "\(prefix).parameters", nodeID: node.nodeID)
                    continue
                }
                guard script.source.utf8.count <= DSPScriptCompiler.maximumSourceBytes else {
                    add("dsp.invalidParameter", "脚本源码不能超过 64 KiB。", "\(prefix).parameters.source", nodeID: node.nodeID)
                    continue
                }
                guard script.values.count <= DSPScriptCompiler.maximumParameterCount,
                      script.values.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite }) else {
                    add("dsp.invalidParameter", "脚本参数名或数值无效。", "\(prefix).parameters.values", nodeID: node.nodeID)
                    continue
                }

                do {
                    let parameters: [DSPScriptParameter]
                    if let format {
                        let program = try DSPScriptCompiler.compile(
                            source: script.source,
                            languageVersion: script.languageVersion,
                            parameterValues: script.values,
                            format: format
                        )
                        parameters = program.parameters
                        let estimatedOperationsPerSecond = Double(program.weightedOperationsPerFrame)
                            * Double(format.channelCount)
                            * format.sampleRate
                        if !estimatedOperationsPerSecond.isFinite
                            || estimatedOperationsPerSecond > Double(DSPScriptCompiler.maximumWeightedOperationsPerSecond) {
                            add(
                                "dsp.invalidParameter",
                                "脚本估算处理成本超过单节点上限。",
                                "\(prefix).parameters.source",
                                nodeID: node.nodeID
                            )
                        }
                        totalScriptOperationsPerSecond += estimatedOperationsPerSecond
                        scriptLatencyFrames += program.latencyFrames
                        if program.stateBytes < 0 || program.stateBytes > DSPScriptCompiler.maximumStateBytes {
                            add(
                                "dsp.invalidParameter",
                                "脚本状态内存超过支持范围。",
                                "\(prefix).parameters.source",
                                nodeID: node.nodeID
                            )
                        }
                        if !(0...DSPScriptCompiler.maximumLatencyFrames).contains(program.latencyFrames) {
                            add(
                                "dsp.invalidParameter",
                                "脚本延迟超过支持范围。",
                                "\(prefix).parameters.source",
                                nodeID: node.nodeID
                            )
                        }
                    } else {
                        parameters = try DSPScriptCompiler.validateSource(
                            source: script.source,
                            languageVersion: script.languageVersion,
                            parameterValues: script.values
                        )
                    }

                    let declared = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0) })
                    for parameter in parameters {
                        if parameter.name.isEmpty
                            || !parameter.minValue.isFinite
                            || !parameter.maxValue.isFinite
                            || !parameter.defaultValue.isFinite
                            || parameter.minValue >= parameter.maxValue
                            || !(parameter.minValue...parameter.maxValue).contains(parameter.defaultValue) {
                            add(
                                "dsp.invalidParameter",
                                "脚本声明了无效的参数范围。",
                                "\(prefix).parameters.source",
                                nodeID: node.nodeID
                            )
                        }
                    }
                    for (name, value) in script.values {
                        guard let parameter = declared[name] else {
                            add(
                                "dsp.unsupportedParameter",
                                "脚本没有声明参数“\(name)”。",
                                "\(prefix).parameters.values.\(name)",
                                nodeID: node.nodeID
                            )
                            continue
                        }
                        if !value.isFinite || !(parameter.minValue...parameter.maxValue).contains(value) {
                            add(
                                "dsp.invalidParameter",
                                "脚本参数“\(name)”超出声明范围。",
                                "\(prefix).parameters.values.\(name)",
                                nodeID: node.nodeID
                            )
                        }
                    }

                } catch let error as DSPScriptCompilationError {
                    for diagnostic in error.diagnostics {
                        add(
                            diagnostic.code,
                            diagnostic.message,
                            diagnostic.fieldPath ?? "\(prefix).parameters.source",
                            nodeID: diagnostic.nodeID ?? node.nodeID,
                            retryable: diagnostic.retryable,
                            line: diagnostic.line,
                            column: diagnostic.column
                        )
                    }
                } catch {
                    add(
                        "dsp.scriptCompileFailed",
                        error.localizedDescription,
                        "\(prefix).parameters.source",
                        nodeID: node.nodeID,
                        retryable: true
                    )
                }
                continue
            }

            if node.typeID == DSPNodeConfiguration.stereoWidthTypeID {
                for parameterKey in node.parameters.keys.sorted()
                    where !DSPStereoWidthParameters.supportedParameterKeys.contains(parameterKey) {
                    add(
                        "dsp.unsupportedParameter",
                        "此立体声扩展参数暂不支持：\(parameterKey)。",
                        "\(prefix).parameters.\(parameterKey)",
                        nodeID: node.nodeID
                    )
                }
                guard let parameters = node.stereoWidthParameters else {
                    add("dsp.invalidParameter", "立体声扩展参数不完整。", "\(prefix).parameters", nodeID: node.nodeID)
                    continue
                }
                if !parameters.width.isFinite || !DSPStereoWidthParameters.widthRange.contains(parameters.width) {
                    add("dsp.invalidParameter", "宽度范围为 0 至 2。", "\(prefix).parameters.width", nodeID: node.nodeID)
                }
                if !parameters.outputTrimDB.isFinite
                    || !DSPStereoWidthParameters.outputTrimRange.contains(parameters.outputTrimDB) {
                    add("dsp.invalidParameter", "输出增益范围为 −24 至 +6 dB。", "\(prefix).parameters.outputTrimDB", nodeID: node.nodeID)
                }
                continue
            }

            if node.typeID == DSPNodeConfiguration.virtualBassTypeID {
                for parameterKey in node.parameters.keys.sorted()
                    where !DSPVirtualBassParameters.supportedParameterKeys.contains(parameterKey) {
                    add(
                        "dsp.unsupportedParameter",
                        "此虚拟低音参数暂不支持：\(parameterKey)。",
                        "\(prefix).parameters.\(parameterKey)",
                        nodeID: node.nodeID
                    )
                }
                guard let parameters = node.virtualBassParameters else {
                    add("dsp.invalidParameter", "虚拟低音参数不完整。", "\(prefix).parameters", nodeID: node.nodeID)
                    continue
                }
                if !parameters.lowFrequencyHz.isFinite
                    || !DSPVirtualBassParameters.lowFrequencyRange.contains(parameters.lowFrequencyHz) {
                    add("dsp.invalidParameter", "低频范围为 20 至 180 Hz。", "\(prefix).parameters.lowFrequencyHz", nodeID: node.nodeID)
                }
                if !parameters.highFrequencyHz.isFinite
                    || !DSPVirtualBassParameters.highFrequencyRange.contains(parameters.highFrequencyHz) {
                    add("dsp.invalidParameter", "高频范围为 40 至 300 Hz。", "\(prefix).parameters.highFrequencyHz", nodeID: node.nodeID)
                }
                if parameters.lowFrequencyHz.isFinite, parameters.highFrequencyHz.isFinite,
                   parameters.lowFrequencyHz >= parameters.highFrequencyHz {
                    add("dsp.invalidParameter", "频带下限必须低于上限。", "\(prefix).parameters.highFrequencyHz", nodeID: node.nodeID)
                }
                if !parameters.amount.isFinite || !DSPVirtualBassParameters.amountRange.contains(parameters.amount) {
                    add("dsp.invalidParameter", "强度范围为 0 至 1。", "\(prefix).parameters.amount", nodeID: node.nodeID)
                }
                if !parameters.driveDB.isFinite || !DSPVirtualBassParameters.driveRange.contains(parameters.driveDB) {
                    add("dsp.invalidParameter", "驱动范围为 0 至 18 dB。", "\(prefix).parameters.driveDB", nodeID: node.nodeID)
                }
                if !parameters.harmonics.isFinite || !DSPVirtualBassParameters.harmonicsRange.contains(parameters.harmonics) {
                    add("dsp.invalidParameter", "谐波倾向范围为 0 至 1。", "\(prefix).parameters.harmonics", nodeID: node.nodeID)
                }
                if !parameters.mix.isFinite || !DSPVirtualBassParameters.mixRange.contains(parameters.mix) {
                    add("dsp.invalidParameter", "混合范围为 0 至 1。", "\(prefix).parameters.mix", nodeID: node.nodeID)
                }
                if !parameters.outputTrimDB.isFinite
                    || !DSPVirtualBassParameters.outputTrimRange.contains(parameters.outputTrimDB) {
                    add("dsp.invalidParameter", "输出增益范围为 −24 至 +6 dB。", "\(prefix).parameters.outputTrimDB", nodeID: node.nodeID)
                }
                continue
            }

            if node.typeID == DSPNodeConfiguration.tubeTypeID {
                for parameterKey in node.parameters.keys.sorted()
                    where !DSPTubeParameters.supportedParameterKeys.contains(parameterKey) {
                    add(
                        "dsp.unsupportedParameter",
                        "此电子管参数暂不支持：\(parameterKey)。",
                        "\(prefix).parameters.\(parameterKey)",
                        nodeID: node.nodeID
                    )
                }
                guard let parameters = node.tubeParameters else {
                    add("dsp.invalidParameter", "电子管参数不完整。", "\(prefix).parameters", nodeID: node.nodeID)
                    continue
                }
                if !parameters.driveDB.isFinite || !DSPTubeParameters.driveRange.contains(parameters.driveDB) {
                    add("dsp.invalidParameter", "驱动范围为 0 至 18 dB。", "\(prefix).parameters.driveDB", nodeID: node.nodeID)
                }
                if !parameters.bias.isFinite || !DSPTubeParameters.biasRange.contains(parameters.bias) {
                    add("dsp.invalidParameter", "偏置范围为 −0.5 至 +0.5。", "\(prefix).parameters.bias", nodeID: node.nodeID)
                }
                if !parameters.mix.isFinite || !DSPTubeParameters.mixRange.contains(parameters.mix) {
                    add("dsp.invalidParameter", "混合范围为 0 至 1。", "\(prefix).parameters.mix", nodeID: node.nodeID)
                }
                if !parameters.inputTrimDB.isFinite
                    || !DSPTubeParameters.inputTrimRange.contains(parameters.inputTrimDB) {
                    add("dsp.invalidParameter", "输入增益范围为 −24 至 +12 dB。", "\(prefix).parameters.inputTrimDB", nodeID: node.nodeID)
                }
                if !parameters.outputTrimDB.isFinite
                    || !DSPTubeParameters.outputTrimRange.contains(parameters.outputTrimDB) {
                    add("dsp.invalidParameter", "输出增益范围为 −24 至 +6 dB。", "\(prefix).parameters.outputTrimDB", nodeID: node.nodeID)
                }
                if !parameters.dcBlockHz.isFinite
                    || !DSPTubeParameters.dcBlockFrequencyRange.contains(parameters.dcBlockHz) {
                    add("dsp.invalidParameter", "直流阻隔频率范围为 5 至 40 Hz。", "\(prefix).parameters.dcBlockHz", nodeID: node.nodeID)
                }
                continue
            }

            if node.typeID == DSPNodeConfiguration.equalLoudnessTypeID {
                for parameterKey in node.parameters.keys.sorted()
                    where !DSPEqualLoudnessParameters.supportedParameterKeys.contains(parameterKey) {
                    add(
                        "dsp.unsupportedParameter",
                        "此等响参数暂不支持：\(parameterKey)。",
                        "\(prefix).parameters.\(parameterKey)",
                        nodeID: node.nodeID
                    )
                }
                guard let parameters = node.equalLoudnessParameters else {
                    add(
                        "dsp.invalidParameter",
                        "等响补偿参数不完整。",
                        "\(prefix).parameters",
                        nodeID: node.nodeID
                    )
                    continue
                }
                if !parameters.strength.isFinite
                    || !DSPEqualLoudnessParameters.strengthRange.contains(parameters.strength) {
                    add("dsp.invalidParameter", "强度范围为 0 至 1。", "\(prefix).parameters.strength", nodeID: node.nodeID)
                }
                if !parameters.maxBassGainDB.isFinite
                    || !DSPEqualLoudnessParameters.maxBassGainRange.contains(parameters.maxBassGainDB) {
                    add("dsp.invalidParameter", "低频补偿范围为 0 至 12 dB。", "\(prefix).parameters.maxBassGainDB", nodeID: node.nodeID)
                }
                if !parameters.maxTrebleGainDB.isFinite
                    || !DSPEqualLoudnessParameters.maxTrebleGainRange.contains(parameters.maxTrebleGainDB) {
                    add("dsp.invalidParameter", "高频补偿范围为 0 至 6 dB。", "\(prefix).parameters.maxTrebleGainDB", nodeID: node.nodeID)
                }
                if !parameters.bassFrequencyHz.isFinite
                    || !DSPEqualLoudnessParameters.bassFrequencyRange.contains(parameters.bassFrequencyHz) {
                    add("dsp.invalidParameter", "低架频率范围为 20 至 500 Hz。", "\(prefix).parameters.bassFrequencyHz", nodeID: node.nodeID)
                }
                if !parameters.trebleFrequencyHz.isFinite
                    || !DSPEqualLoudnessParameters.trebleFrequencyRange.contains(parameters.trebleFrequencyHz) {
                    add("dsp.invalidParameter", "高架频率范围为 1,000 至 20,000 Hz。", "\(prefix).parameters.trebleFrequencyHz", nodeID: node.nodeID)
                }
                if !parameters.bassQ.isFinite
                    || !DSPEqualLoudnessParameters.shelfSlopeRange.contains(parameters.bassQ) {
                    add("dsp.invalidParameter", "低架斜率 S 范围为 0.25 至 1。", "\(prefix).parameters.bassQ", nodeID: node.nodeID)
                }
                if !parameters.trebleQ.isFinite
                    || !DSPEqualLoudnessParameters.shelfSlopeRange.contains(parameters.trebleQ) {
                    add("dsp.invalidParameter", "高架斜率 S 范围为 0.25 至 1。", "\(prefix).parameters.trebleQ", nodeID: node.nodeID)
                }
                if !parameters.compensationWindowDB.isFinite
                    || !DSPEqualLoudnessParameters.compensationWindowRange.contains(parameters.compensationWindowDB) {
                    add("dsp.invalidParameter", "补偿窗口范围为 1 至 60 dB。", "\(prefix).parameters.compensationWindowDB", nodeID: node.nodeID)
                }
                continue
            }

            for parameterKey in node.parameters.keys.sorted() where parameterKey != "bands" {
                add(
                    "dsp.unsupportedParameter",
                    "此均衡器参数暂不支持：\(parameterKey)。",
                    "\(prefix).parameters.\(parameterKey)",
                    nodeID: node.nodeID
                )
            }
            guard let bands = node.parametricEQBands else {
                add(
                    "dsp.invalidParameter",
                    "均衡器需要完整的九段参数。",
                    "\(prefix).parameters.bands",
                    nodeID: node.nodeID
                )
                continue
            }
            let knownBandParameterKeys: Set<String> = ["enabled", "type", "frequencyHz", "gainDB", "q"]
            if case .array(let bandValues)? = node.parameters["bands"] {
                for (bandIndex, value) in bandValues.enumerated()
                    where bands.indices.contains(bandIndex) && bands[bandIndex].enabled {
                    guard case .object(let fields) = value else { continue }
                    for parameterKey in fields.keys.sorted() where !knownBandParameterKeys.contains(parameterKey) {
                        add(
                            "dsp.unsupportedParameter",
                            "此均衡器参数暂不支持：\(parameterKey)。",
                            "\(prefix).parameters.bands.\(bandIndex).\(parameterKey)",
                            nodeID: node.nodeID
                        )
                    }
                }
            }
            for (bandIndex, band) in bands.enumerated() where band.enabled {
                let bandPath = "\(prefix).parameters.bands.\(bandIndex)"
                if !band.frequencyHz.isFinite || !DSPParametricEQBand.frequencyRange.contains(band.frequencyHz) {
                    add(
                        "dsp.invalidParameter",
                        "频率范围为 20 至 20,000 Hz。",
                        "\(bandPath).frequencyHz",
                        nodeID: node.nodeID
                    )
                }
                if !band.gainDB.isFinite || !DSPParametricEQBand.gainRange.contains(band.gainDB) {
                    add(
                        "dsp.invalidParameter",
                        "增益范围为 −18 至 +18 dB。",
                        "\(bandPath).gainDB",
                        nodeID: node.nodeID
                    )
                }
                let qRange = band.type.usesSlope
                    ? DSPParametricEQBand.shelfSlopeRange
                    : DSPParametricEQBand.qRange
                if !band.q.isFinite || !qRange.contains(band.q) {
                    add(
                        "dsp.invalidParameter",
                        band.type.usesSlope
                            ? "架式滤波器斜率范围为 0.25 至 1。"
                            : "Q 值范围为 0.25 至 16。",
                        "\(bandPath).q",
                        nodeID: node.nodeID
                    )
                }
            }
        }
        let renderCost = DSPScriptCompiler.estimatedRendererOperationsPerSecond(
            baseOperationsPerSecond: totalScriptOperationsPerSecond,
            latencyFrames: scriptLatencyFrames + nativeLatencyFrames)
        if format != nil, renderCost > DSPScriptCompiler.maximumChainWeightedOperationsPerSecond {
            add("dsp.invalidParameter", "含延迟预览的脚本总成本不能超过 48 M 次估算运算/秒。", "nodes")
        }
        return result
    }

    private static func disabledUnknownNodeWarnings(
        in configuration: AudioDSPConfiguration
    ) -> [DSPDiagnostic] {
        configuration.nodes.enumerated().compactMap { index, node in
            guard !node.enabled,
                  node.typeID != DSPNodeConfiguration.parametricEQTypeID
            else { return nil }
            return DSPDiagnostic(
                code: "dsp.disabledUnknownNodePreserved",
                message: "已保留停用的未知效果：\(node.typeID)。",
                fieldPath: "nodes.\(index)",
                nodeID: node.nodeID
            )
        }
    }
}

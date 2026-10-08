import Foundation
import PlayerAutomationIPC
import PlayerAutomationProtocol

enum AutomationBatchExecutionContext {
    @TaskLocal static var aggregateConfirmationApproved = false
}

@MainActor
final class AutomationIPCServer {

    private struct PendingIdempotency {
        let fingerprint: String
        var waiters: [(requestID: UUID, continuation: CheckedContinuation<AutomationResponse, Never>)]
    }

    private static let socketDirectoryName = "Automation"
    private static let socketFileName = "automation.sock"

    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }

    private let filesHandler: AutomationFilesHandler
    private let artworkHandler: AutomationArtworkHandler
    private let lyricsHandler: AutomationLyricsHandler
    private let listener: AutomationIPCListener
    private weak var appSession: AppSessionHost?
    private let scopePolicyStore: AutomationScopePolicyStore
    private let idempotencyStore: AutomationIdempotencyStore
    private let selectionStore: AutomationSelectionStore
    private let automationBundleIdentifier: String
    private let appSupportDirectoryURL: URL?
    private var cachedGrantedScopes: Set<AutomationScope>?
    private var idempotencyCache: [String: (fingerprint: String, response: AutomationResponse)] = [:]
    private var idempotencyOrder: [String] = []
    private var pendingIdempotency: [String: PendingIdempotency] = [:]
    private let idempotencyCacheLimit = 256
    private(set) var isRunning = false

    init(
        appSession: AppSessionHost,
        bundleIdentifier: String? = nil,
        socketURL: URL? = nil,
        appSupportDirectoryURL: URL? = nil,
        ioTimeout: TimeInterval = 120
    ) throws {
        self.appSession = appSession
        filesHandler = AutomationFilesHandler(appSession: appSession)
        lyricsHandler = AutomationLyricsHandler(appSession: appSession)
        artworkHandler = AutomationArtworkHandler(appSession: appSession)
        let resolvedBundleIdentifier = bundleIdentifier ?? AutomationAppIdentity.bundleIdentifier
        self.automationBundleIdentifier = resolvedBundleIdentifier
        self.appSupportDirectoryURL = appSupportDirectoryURL
        scopePolicyStore = AutomationScopePolicyStore(
            bundleIdentifier: resolvedBundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        idempotencyStore = AutomationIdempotencyStore(
            bundleIdentifier: resolvedBundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        selectionStore = AutomationSelectionStore(
            bundleIdentifier: resolvedBundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        let socketPath = (socketURL ?? Self.socketURL(bundleIdentifier: resolvedBundleIdentifier)).path
        let sharedSecret = try AutomationIPCSecretStore.loadOrCreate(
            forSocketPath: socketPath
        )
        let configuration = try AutomationIPCConfiguration(
            maximumFrameBytes: 1_048_576,
            maximumConcurrentConnections: 8,
            ioTimeout: ioTimeout,
            sharedSecret: sharedSecret
        )
        listener = try AutomationIPCListener(
            socketPath: socketPath,
            configuration: configuration
        )
        for entry in idempotencyStore.load() {
            idempotencyCache[entry.key] = (entry.fingerprint, entry.response)
            idempotencyOrder.append(entry.key)
        }
    }

    static var defaultSocketURL: URL {
        socketURL(bundleIdentifier: AutomationAppIdentity.bundleIdentifier)
    }

    private static func socketURL(bundleIdentifier: String) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent(
                bundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent(socketDirectoryName, isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
    }

    func start() async throws {
        guard !isRunning else { return }
        try await listener.start(cancellableHandler: { [weak self] request, cancellation in
            guard let self else {
                return AutomationResponse.failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            return await self.handle(request, cancellation: cancellation)
        })
        isRunning = true
        Log.info("[Automation] automation IPC server started", category: .library)
    }

    func stop() async {
        await listener.stop()
        isRunning = false
        Log.info("[Automation] IPC server stopped", category: .library)
    }

    private func handle(
        _ request: AutomationRequest,
        cancellation: AutomationIPCCancellationToken? = nil
    ) async -> AutomationResponse {
        if let key = request.context.idempotencyKey,
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cacheKey = "\(request.method):\(key)"
            let fingerprint = requestFingerprint(for: request)
            if let cached = idempotencyCache[cacheKey] {
                guard cached.fingerprint == fingerprint else {
                    let response = AutomationResponse.failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The idempotency key was already used with different request parameters.",
                            details: .object(["idempotencyKey": .string(key)])
                        )
                    )
                    recordAudit(for: request, response: response)
                    return response
                }
                let response = AutomationResponseSupport.responseForRequest(cached.response, requestID: request.requestID)
                recordAudit(for: request, response: response)
                return response
            }

            if let pending = pendingIdempotency[cacheKey] {
                guard pending.fingerprint == fingerprint else {
                    let response = AutomationResponse.failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The idempotency key was already used with different request parameters.",
                            details: .object(["idempotencyKey": .string(key)])
                        )
                    )
                    recordAudit(for: request, response: response)
                    return response
                }
                let response = await withCheckedContinuation { continuation in
                    pendingIdempotency[cacheKey]?.waiters.append(
                        (requestID: request.requestID, continuation: continuation)
                    )
                }
                recordAudit(for: request, response: response)
                return response
            }

            pendingIdempotency[cacheKey] = PendingIdempotency(
                fingerprint: fingerprint,
                waiters: []
            )
            let response = await execute(request, cancellation: cancellation)
            let waiters = pendingIdempotency[cacheKey]?.waiters ?? []
            if waiters.isEmpty {
                cancelJobReturnedByCancelledRequest(
                    response,
                    request: request,
                    cancellation: cancellation
                )
            }
            if response.error == nil, usesIdempotencyCache(for: request) {
                idempotencyCache[cacheKey] = (fingerprint, response)
                idempotencyOrder.append(cacheKey)
                while idempotencyOrder.count > idempotencyCacheLimit {
                    let expired = idempotencyOrder.removeFirst()
                    idempotencyCache.removeValue(forKey: expired)
                }
                try? idempotencyStore.save(idempotencyCache, order: idempotencyOrder)
            }
            let completedWaiters = pendingIdempotency.removeValue(forKey: cacheKey)?.waiters ?? []
            for waiter in completedWaiters {
                waiter.continuation.resume(
                    returning: AutomationResponseSupport.responseForRequest(response, requestID: waiter.requestID)
                )
            }
            recordAudit(for: request, response: response)
            return response
        }

        let response = await execute(request, cancellation: cancellation)
        cancelJobReturnedByCancelledRequest(
            response,
            request: request,
            cancellation: cancellation
        )
        recordAudit(for: request, response: response)
        return response
    }

    private func cancelJobReturnedByCancelledRequest(
        _ response: AutomationResponse,
        request: AutomationRequest,
        cancellation: AutomationIPCCancellationToken?
    ) {
        guard let cancellation,
              response.error == nil,
              AutomationToolCatalog.descriptor(for: request.method)?.supportsJobs == true,
              let summary = jobSummary(in: response.result),
              let libraryID = summary.libraryID ?? request.context.libraryID,
              let appSession else {
            return
        }
        cancellation.onCancel { [weak appSession] in
            Task { @MainActor in
                guard let appSession else { return }
                _ = appSession.cancelLibraryJob(id: summary.id, libraryID: libraryID)
            }
        }
    }

    private func jobSummary(in value: AutomationJSONValue?) -> AutomationJobSummary? {
        guard let value else { return nil }
        if case .object(let fields) = value {
            if let nested = fields["job"], let summary = jobSummary(in: nested) {
                return summary
            }
            if case .array(let jobs) = fields["jobs"], jobs.count == 1 {
                return jobSummary(in: jobs[0])
            }
        }
        guard let data = try? AutomationWireCoding.encoder().encode(value) else { return nil }
        return try? AutomationWireCoding.decoder().decode(AutomationJobSummary.self, from: data)
    }

    private func execute(
        _ request: AutomationRequest,
        cancellation: AutomationIPCCancellationToken? = nil
    ) async -> AutomationResponse {
        if let failure = validateRequest(request) { return failure }

        if isBackgroundJobRequest(request) {
            return await submitBackgroundJob(for: request)
        }

        switch request.method {
        case AutomationMethod.operationsBatch:
            return await submitOperationsBatch(for: request)

        case AutomationMethod.systemPing:
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationPingResult(),
                for: request
            )

        case AutomationMethod.systemInfo:
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                ?? "development"
            let info = AutomationSystemInfo(
                appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? "kmgccc_player",
                appVersion: appVersion,
                capabilities: AutomationToolCatalog.all.map(\.name),
                isReady: appSession?.hasCompletedInitialSetup == true,
                activeLibraryID: appSession?.activeLibraryBinding.context?.id
            )
            return AutomationResponseSupport.encodeResult(info, for: request)

        case AutomationMethod.libraryList,
             AutomationMethod.libraryGet,
             AutomationMethod.libraryCreate,
             AutomationMethod.libraryOpen,
             AutomationMethod.librarySwitch,
             AutomationMethod.libraryRename,
             AutomationMethod.libraryRelocate,
             AutomationMethod.libraryRemove,
             AutomationMethod.libraryImport,
             AutomationMethod.libraryTracks,
             AutomationMethod.libraryStats,
             AutomationMethod.libraryReport,
             AutomationMethod.libraryBundleExport,
             AutomationMethod.librarySelectionList,
             AutomationMethod.librarySelectionCreate,
             AutomationMethod.librarySelectionGet,
             AutomationMethod.librarySelectionDelete:
            return await AutomationLibraryHandler(appSession: appSession, selectionStore: selectionStore).handle(request, grantedScopes: grantedScopes)

        case AutomationMethod.playlistList,
             AutomationMethod.playlistCreate,
             AutomationMethod.playlistAddTracks,
             AutomationMethod.playlistAddSelection,
             AutomationMethod.playlistRemoveTracks,
             AutomationMethod.playlistGet,
             AutomationMethod.playlistDiff,
             AutomationMethod.playlistExport,
             AutomationMethod.playlistImport,
             AutomationMethod.playlistRename,
             AutomationMethod.playlistDelete,
             AutomationMethod.playlistReplaceTracks,
             AutomationMethod.playlistReorder:
            return await AutomationPlaylistHandler(appSession: appSession, selectionStore: selectionStore).handle(request, grantedScopes: grantedScopes, executeChild: { await self.execute($0) })

        case AutomationMethod.sourceList,
             AutomationMethod.sourceGet,
             AutomationMethod.sourceConfigExport,
             AutomationMethod.sourceConfigImport,
             AutomationMethod.sourceRename,
             AutomationMethod.sourceRefresh,
             AutomationMethod.sourceCreate,
             AutomationMethod.sourceBindPlaylist,
             AutomationMethod.sourceSetExcludedPath,
             AutomationMethod.sourceSetMonitorPolicy,
             AutomationMethod.sourceRemove:
            return await AutomationSourceHandler(appSession: appSession).handle(request)

        case AutomationMethod.filesInspect,
             AutomationMethod.filesReveal,
             AutomationMethod.filesExport,
             AutomationMethod.filesRename,
             AutomationMethod.filesMove,
             AutomationMethod.filesDelete:
            return await filesHandler.handle(request)

        case AutomationMethod.playbackState,
             AutomationMethod.playbackPlay,
             AutomationMethod.playbackPlayPlaylist,
             AutomationMethod.playbackToggle,
             AutomationMethod.playbackPause,
             AutomationMethod.playbackNext,
             AutomationMethod.playbackPrevious,
             AutomationMethod.playbackSeek,
             AutomationMethod.playbackSetVolume,
             AutomationMethod.playbackSetMode,
             AutomationMethod.queueGet,
             AutomationMethod.queueUpcoming,
             AutomationMethod.queueReplace,
             AutomationMethod.queueEnqueue,
             AutomationMethod.queueEnqueueNext,
             AutomationMethod.queueRemove,
             AutomationMethod.queueReorder,
             AutomationMethod.queueClear:
            return await AutomationPlaybackHandler(appSession: appSession).handle(request)

        case AutomationMethod.historyList,
             AutomationMethod.historyStats,
             AutomationMethod.historyClear:
            return await AutomationHistoryHandler(appSession: appSession).handle(request)

        case AutomationMethod.artworkSearch,
             AutomationMethod.artworkApplyCandidate,
             AutomationMethod.artworkGet,
             AutomationMethod.artworkApply:
            return await artworkHandler.handle(request)

        case AutomationMethod.metadataGet,
             AutomationMethod.metadataEmbeddedGet,
             AutomationMethod.metadataEmbeddedPatch,
             AutomationMethod.metadataExport,
             AutomationMethod.metadataImport,
             AutomationMethod.metadataSearch,
             AutomationMethod.metadataApplyCandidate,
             AutomationMethod.metadataPatch:
            return await AutomationMetadataHandler(appSession: appSession).handle(request, grantedScopes: grantedScopes)

        case AutomationMethod.lyricsGet,
             AutomationMethod.lyricsSearch,
             AutomationMethod.lyricsCandidates,
             AutomationMethod.lyricsCompare,
             AutomationMethod.lyricsApply,
             AutomationMethod.lyricsClean,
             AutomationMethod.lyricsRefresh:
            return await lyricsHandler.handle(request)

        case AutomationMethod.jobsList,
             AutomationMethod.jobsGet,
             AutomationMethod.jobsWait,
             AutomationMethod.jobsCancel,
             AutomationMethod.jobsRetry:
            return await AutomationJobsHandler(appSession: appSession).handle(request, cancellation: cancellation)

        case AutomationMethod.diagnosticsHealth,
             AutomationMethod.storageInspect,
             AutomationMethod.storageValidate,
             AutomationMethod.storageRepair,
             AutomationMethod.storageOrphans,
             AutomationMethod.storageBackup,
             AutomationMethod.storageDiff,
             AutomationMethod.storageReload:
            return await AutomationStorageHandler(appSession: appSession, automationBundleIdentifier: automationBundleIdentifier, appSupportDirectoryURL: appSupportDirectoryURL).handle(request)

        case AutomationMethod.dspSchema, AutomationMethod.dspState,
             AutomationMethod.dspValidate, AutomationMethod.dspPatch, AutomationMethod.dspWait,
             AutomationMethod.dspPresetsList, AutomationMethod.dspPresetsGet,
             AutomationMethod.dspPresetsSave, AutomationMethod.dspPresetsSelect,
             AutomationMethod.dspPresetsRename, AutomationMethod.dspPresetsDelete,
             AutomationMethod.dspPresetsDuplicate, AutomationMethod.dspPresetsImport,
             AutomationMethod.dspPresetsExport, AutomationMethod.dspErrorsGet, AutomationMethod.dspErrorsClear:
            return await AutomationDSPHandler(appSession: appSession).handle(request)

        case AutomationMethod.settingsGet,
             AutomationMethod.settingsPatch,
             AutomationMethod.settingsSchema,
             AutomationMethod.settingsValidate,
             AutomationMethod.settingsReset,
             AutomationMethod.audioGet,
             AutomationMethod.audioPatch:
            return await AutomationSettingsHandler(appSession: appSession).handle(request)

        case AutomationMethod.automationCapabilities,
             AutomationMethod.automationScopes,
             AutomationMethod.automationGrantScope,
             AutomationMethod.automationRevokeScope:
            return await executePolicyRequest(request)

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private func validateRequest(_ request: AutomationRequest) -> AutomationResponse? {
        guard AutomationProtocol.supportedVersions.contains(request.protocolVersion) else {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .unsupportedVersion,
                    message: "Unsupported automation protocol version \(request.protocolVersion).",
                    details: .object([
                        "supportedVersions": .array(
                            AutomationProtocol.supportedVersions.map { .number(Double($0)) }
                        )
                    ])
                )
            )
        }

        if let caller = request.context.caller?.lowercased() {
            let enabled: Bool?
            switch caller {
            case "mcp": enabled = AppSettings.shared.automationMCPEnabled
            case "cli": enabled = AppSettings.shared.automationCLIEnabled
            default: enabled = nil
            }
            if enabled == false {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .authorizationRequired,
                        message: "The \(caller.uppercased()) control plane is disabled in App Settings.",
                        details: .object([
                            "controlPlane": .string(caller),
                            "setting": .string(caller == "mcp" ? "automationMCPEnabled" : "automationCLIEnabled")
                        ])
                    )
                )
            }
        }

        let unknownParameterKeys = AutomationToolCatalog.unknownParameterKeys(
            for: request.method,
            params: request.params
        )
        if !unknownParameterKeys.isEmpty {
            return AutomationResponseSupport.invalidParameters(
                for: request,
                error: AutomationParameterError.unknown(unknownParameterKeys)
            )
        }

        if let descriptor = AutomationToolCatalog.descriptor(for: request.method) {
            let granted = grantedScopes()
            var required = Set(descriptor.scopes)
            // A destructive preview is still read-only. Let an Agent inspect
            // the impact with the normal library scope before requesting the
            // separately protected delete scope for the real mutation.
            if request.method == AutomationMethod.filesDelete,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.filesDelete)
            }
            if request.method == AutomationMethod.libraryRemove,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.libraryDelete)
            }
            if case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"],
               let writeScope = Self.batchWriteScope(for: request.method) {
                required.remove(writeScope)
            }
            if request.method == AutomationMethod.metadataEmbeddedPatch,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.metadataWrite)
                required.remove(.filesWrite)
            }
            if request.method == AutomationMethod.metadataImport,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.metadataWrite)
            }
            if request.method == AutomationMethod.sourceConfigImport,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.sourceWrite)
            }
            if request.method == AutomationMethod.libraryImport,
               case .object(let values) = request.params {
                if case .boolean(true) = values["dryRun"] {
                    required.remove(.libraryWrite)
                } else {
                    if values["targetPlaylistID"] != nil { required.insert(.playlistWrite) }
                    if appSession?.activeLibraryBinding.context?.mode == .referenced {
                        required.insert(.sourceWrite)
                    }
                }
            }
            if request.method == AutomationMethod.jobsRetry,
               case .object(let values) = request.params,
               case .string(let rawJobID)? = values["jobID"],
               let jobID = UUID(uuidString: rawJobID),
               let retrySpec = appSession?.libraryJobDescriptors()
                   .first(where: {
                       $0.id == jobID && $0.libraryID == request.context.libraryID
                   })?.retrySpec,
               retrySpec.kind == .libraryImport {
                required.insert(.libraryWrite)
                if retrySpec.targetPlaylistID != nil { required.insert(.playlistWrite) }
                if appSession?.activeLibraryBinding.context?.mode == .referenced {
                    required.insert(.sourceWrite)
                }
            }
            if requiresHistoryRead(for: request) {
                required.insert(.historyRead)
            }
            if !granted.isSuperset(of: required) {
                let denied = required.subtracting(granted)
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .authorizationRequired,
                        message: "The App automation policy has not granted all scopes required by this capability.",
                        details: .object([
                            "requiredScopes": .array(required.map(\.rawValue).sorted().map { .string($0) }),
                            "deniedScopes": .array(denied.map(\.rawValue).sorted().map { .string($0) })
                        ])
                    )
                )
            }
        }

        return nil
    }

    private func executePolicyRequest(_ request: AutomationRequest) async -> AutomationResponse {
        switch request.method {
        case AutomationMethod.automationCapabilities:
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationCapabilityResult(
                    grantedScopes: Array(grantedScopes()),
                    deniedScopes: AutomationScope.allCases.filter {
                        !grantedScopes().contains($0)
                    },
                    notes: [
                        "Normal library and playback mutations execute directly once the local App policy authorizes them.",
                        "High-risk operations require dryRun/preview, caller acknowledgement and a foreground App confirmation.",
                        "Library lifecycle management is available through App-owned create/open/switch/rename/relocate operations; library deletion remains separately denied by default.",
                        "A missing referenced file preserves its Track, metadata, history and Playlist membership by default."
                    ]
                ),
                for: request
            )

        case AutomationMethod.automationScopes:
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                scopeStatusResult(),
                for: request
            )

        case AutomationMethod.automationGrantScope:
            do {
                let parameters = try AutomationParameters(request)
                guard let rawScope = try parameters.string("scope", required: true),
                      let scope = AutomationScope(rawValue: rawScope) else {
                    throw AutomationParameterError.invalidValue("scope")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationScopeMutationResult(
                            scope: scope,
                            granted: grantedScopes().contains(scope),
                            message: "Preview only. Granting a scope changes the App-owned automation policy."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "授予自动化权限需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["scope": .string(scope.rawValue)])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "授予自动化权限？",
                    message: "要允许外部自动化使用“\(scope.rawValue)”能力吗？"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                var scopes = grantedScopes()
                scopes.insert(scope)
                try scopePolicyStore.save(scopes)
                cachedGrantedScopes = scopes
                return AutomationResponseSupport.encodeResult(
                    AutomationScopeMutationResult(
                        scope: scope,
                        granted: true,
                        message: "Scope granted and persisted by the App."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.automationRevokeScope:
            do {
                let parameters = try AutomationParameters(request)
                guard let rawScope = try parameters.string("scope", required: true),
                      let scope = AutomationScope(rawValue: rawScope) else {
                    throw AutomationParameterError.invalidValue("scope")
                }
                var scopes = grantedScopes()
                scopes.remove(scope)
                try scopePolicyStore.save(scopes)
                cachedGrantedScopes = scopes
                return AutomationResponseSupport.encodeResult(
                    AutomationScopeMutationResult(
                        scope: scope,
                        granted: false,
                        message: "Scope revoked for future automation calls."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        default:
            return AutomationResponseSupport.unsupportedMethod(for: request)
        }
    }

    private func grantedScopes() -> Set<AutomationScope> {
        if let cachedGrantedScopes {
            return cachedGrantedScopes
        }
        let loaded = scopePolicyStore.load()
        cachedGrantedScopes = loaded
        return loaded
    }

    private func requiresHistoryRead(for request: AutomationRequest) -> Bool {
        let values: [String: AutomationJSONValue]
        if case .object(let object) = request.params {
            values = object
        } else {
            values = [:]
        }
        switch request.method {
        case AutomationMethod.libraryTracks, AutomationMethod.libraryReport:
            if values["includePreferenceStats"] == .boolean(true) { return true }
            if let filter = values["filter"],
               AutomationTrackPreferenceQuery.requiresHistoryRead(in: filter) {
                return true
            }
            if case .array(let sort)? = values["sort"],
               AutomationTrackPreferenceQuery.requiresHistoryRead(sort: sort) {
                return true
            }
            return false
        case AutomationMethod.librarySelectionCreate:
            guard let filter = values["filter"] else { return false }
            return AutomationTrackPreferenceQuery.requiresHistoryRead(in: filter)
        case AutomationMethod.librarySelectionList,
             AutomationMethod.librarySelectionGet,
             AutomationMethod.playlistAddSelection:
            guard let session = sessionAccess.activeSession(for: request),
                  let snapshots = try? selectionStore.load(libraryID: session.context.id) else {
                return false
            }
            if request.method == AutomationMethod.librarySelectionList {
                return snapshots.contains { snapshot in
                    snapshot.filter.map(AutomationTrackPreferenceQuery.requiresHistoryRead(in:)) == true
                }
            }
            guard case .string(let rawID)? = values["selectionID"],
                  let selectionID = UUID(uuidString: rawID),
                  let snapshot = snapshots.first(where: { $0.summary.id == selectionID }),
                  let filter = snapshot.filter else {
                return false
            }
            return AutomationTrackPreferenceQuery.requiresHistoryRead(in: filter)
        default:
            return false
        }
    }

    private func scopeStatusResult() -> AutomationCapabilityResult {
        let granted = grantedScopes()
        let denied = Set(AutomationScope.allCases).subtracting(granted)
        return AutomationCapabilityResult(
            grantedScopes: Array(granted),
            deniedScopes: Array(denied),
            notes: [
                "Scope state is App-owned and persisted per user on this Mac.",
                "library.delete, files.delete and storage.write are denied by default and require foreground confirmation before granting."
            ]
        )
    }

    private func requestFingerprint(for request: AutomationRequest) -> String {
        // An idempotency key is scoped to the logical caller context as well
        // as the method. Otherwise the same key and payload could replay a
        // response from one active library when a caller later targets a
        // different library (or a different control plane).
        let effectiveLibraryID = request.context.libraryID
            ?? appSession?.activeLibraryBinding.context?.id
        var context: [String: AutomationJSONValue] = [:]
        if let effectiveLibraryID {
            context["libraryID"] = .string(effectiveLibraryID.uuidString)
        }
        if let principalSessionID = request.context.principalSessionID {
            context["principalSessionID"] = .string(principalSessionID.uuidString)
        }
        if let caller = request.context.caller {
            context["caller"] = .string(caller)
        }
        let value = AutomationJSONValue.object([
            "context": .object(context),
            "params": request.params ?? .null
        ])
        guard let data = try? AutomationWireCoding.encoder().encode(value) else {
            return "<unencodable>"
        }
        return data.base64EncodedString()
    }

    /// Keep a small, privacy-preserving and bounded audit trail. Request
    /// parameters are intentionally excluded: paths, titles and other library
    /// content do not belong in a general automation audit log. A single
    /// previous segment is retained when the active JSONL file reaches the
    /// bound, so a noisy or stuck caller cannot grow App Support forever.
    private func recordAudit(for request: AutomationRequest, response: AutomationResponse) {
        let directory = AutomationSupportPaths.automationSupportDirectory(
            bundleIdentifier: automationBundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        let url = directory.appendingPathComponent("audit.jsonl", isDirectory: false)
        var values: [String: AutomationJSONValue] = [
            "timestamp": .string(ISO8601DateFormatter().string(from: response.serverTime)),
            "requestID": .string(request.requestID.uuidString),
            "method": .string(request.method),
            "caller": .string(request.context.caller ?? "unknown"),
            "success": .boolean(response.error == nil),
            "confirmationRequested": .boolean(auditConfirmationRequested(request)),
            "confirmationOutcome": .string(auditConfirmationOutcome(request, response: response))
        ]
        if let descriptor = AutomationToolCatalog.descriptor(for: request.method) {
            values["risk"] = .string(descriptor.risk.rawValue)
            values["scopes"] = .array(descriptor.scopes.map { .string($0.rawValue) })
            values["targetKind"] = .string(auditTargetKind(for: request.method))
            if let targetCount = auditTargetCount(request) {
                values["targetCount"] = .number(Double(targetCount))
            }
        }
        if let libraryID = request.context.libraryID ?? appSession?.activeLibraryBinding.context?.id {
            values["libraryID"] = .string(libraryID.uuidString)
        }
        if let error = response.error {
            values["errorCode"] = .string(error.code.rawValue)
        }
        if let summary = auditSummary(response), !summary.isEmpty {
            values["summary"] = .string(summary)
        }
        if let jobID = auditJobID(response.result) {
            values["jobID"] = .string(jobID)
        }
        guard let data = try? AutomationWireCoding.encoder().encode(
            AutomationJSONValue.object(values)
        ) else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let maximumBytes = 1_048_576
            let line = data + Data([0x0A])
            if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize,
               fileSize + line.count > maximumBytes {
                let rotatedURL = directory.appendingPathComponent("audit.jsonl.1")
                if FileManager.default.fileExists(atPath: rotatedURL.path) {
                    try FileManager.default.removeItem(at: rotatedURL)
                }
                try FileManager.default.moveItem(at: url, to: rotatedURL)
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } catch {
            Log.debug("[Automation] audit write failed: \(error)", category: .library)
        }
    }

    private func auditConfirmationRequested(_ request: AutomationRequest) -> Bool {
        guard case .object(let values) = request.params,
              case .boolean(let confirmed) = values["confirm"] else {
            return false
        }
        return confirmed
    }

    private func auditConfirmationOutcome(
        _ request: AutomationRequest,
        response: AutomationResponse
    ) -> String {
        guard auditConfirmationRequested(request) else {
            return "not-requested"
        }
        if response.error == nil { return "accepted" }
        switch response.error?.code {
        case .interactionRequired:
            return "app-confirmation-required"
        case .authorizationRequired:
            return "denied"
        default:
            return "failed"
        }
    }

    private func auditTargetKind(for method: String) -> String {
        switch method {
        case AutomationMethod.libraryCreate,
             AutomationMethod.libraryOpen,
             AutomationMethod.libraryGet,
             AutomationMethod.librarySwitch,
             AutomationMethod.libraryRename,
             AutomationMethod.libraryRelocate,
             AutomationMethod.libraryRemove,
             AutomationMethod.libraryImport,
             AutomationMethod.libraryBundleExport,
             AutomationMethod.libraryReport: return "library"
        case AutomationMethod.libraryTracks,
             AutomationMethod.libraryStats,
             AutomationMethod.librarySelectionList,
             AutomationMethod.librarySelectionCreate,
             AutomationMethod.librarySelectionGet,
             AutomationMethod.librarySelectionDelete: return "selection"
        case AutomationMethod.playlistAddTracks,
             AutomationMethod.playlistAddSelection,
             AutomationMethod.playlistRemoveTracks,
             AutomationMethod.playlistReplaceTracks,
             AutomationMethod.playlistReorder,
             AutomationMethod.playlistDiff,
             AutomationMethod.playlistImport,
             AutomationMethod.playlistExport: return "playlist"
        case AutomationMethod.sourceGet,
             AutomationMethod.sourceRename,
             AutomationMethod.sourceRefresh,
             AutomationMethod.sourceBindPlaylist,
             AutomationMethod.sourceSetExcludedPath,
             AutomationMethod.sourceSetMonitorPolicy,
             AutomationMethod.sourceRemove: return "source"
        case AutomationMethod.filesInspect,
             AutomationMethod.filesReveal,
             AutomationMethod.filesExport,
             AutomationMethod.filesRename,
             AutomationMethod.filesMove,
             AutomationMethod.filesDelete: return "files"
        case AutomationMethod.metadataGet,
             AutomationMethod.metadataEmbeddedGet,
             AutomationMethod.metadataEmbeddedPatch,
             AutomationMethod.metadataSearch,
             AutomationMethod.metadataApplyCandidate,
             AutomationMethod.metadataPatch: return "metadata"
        case AutomationMethod.artworkSearch,
             AutomationMethod.artworkGet,
             AutomationMethod.artworkApply,
             AutomationMethod.artworkApplyCandidate: return "artwork"
        case AutomationMethod.lyricsGet,
             AutomationMethod.lyricsSearch,
             AutomationMethod.lyricsCandidates,
             AutomationMethod.lyricsCompare,
             AutomationMethod.lyricsApply,
             AutomationMethod.lyricsClean,
             AutomationMethod.lyricsRefresh,
             AutomationMethod.playbackPlayPlaylist,
             AutomationMethod.playbackToggle,
             AutomationMethod.queueReplace,
             AutomationMethod.queueEnqueue,
             AutomationMethod.queueEnqueueNext,
             AutomationMethod.queueRemove,
             AutomationMethod.queueReorder,
             AutomationMethod.queueUpcoming: return "tracks"
        case AutomationMethod.historyList,
             AutomationMethod.historyStats,
             AutomationMethod.historyClear: return "history"
        case AutomationMethod.storageInspect,
             AutomationMethod.storageValidate,
             AutomationMethod.storageOrphans,
             AutomationMethod.storageBackup,
             AutomationMethod.storageDiff,
             AutomationMethod.storageReload,
             AutomationMethod.storageRepair: return "storage"
        case AutomationMethod.settingsGet,
             AutomationMethod.settingsSchema,
             AutomationMethod.settingsPatch,
             AutomationMethod.settingsValidate,
             AutomationMethod.settingsReset: return "settings"
        case AutomationMethod.audioGet,
             AutomationMethod.audioPatch: return "audio"
        default: return method.hasPrefix("dsp.") ? "audio" : "operation"
        }
    }

    private func auditTargetCount(_ request: AutomationRequest) -> Int? {
        guard case .object(let values) = request.params else { return nil }
        for key in ["trackIDs", "playlistIDs", "sourceIDs", "libraryIDs", "paths"] {
            if case .array(let items) = values[key] {
                return items.count
            }
        }
        return values["trackID"] != nil
            || values["playlistID"] != nil
            || values["sourceID"] != nil
            || values["libraryID"] != nil
            || values["selectionID"] != nil
            || values["candidateID"] != nil
            ? 1
            : nil
    }

    private func auditSummary(_ response: AutomationResponse) -> String? {
        if let message = response.error?.message {
            return String(message.prefix(256))
        }
        guard case .object(let values) = response.result,
              case .string(let message) = values["message"] else {
            return nil
        }
        return String(message.prefix(256))
    }

    private func auditJobID(_ value: AutomationJSONValue?) -> String? {
        guard case .object(let values) = value else { return nil }
        if case .object(let job) = values["job"],
           case .string(let id) = job["id"] {
            return id
        }
        if case .string(let id) = values["jobID"] {
            return id
        }
        return nil
    }

    private func isBackgroundJobRequest(_ request: AutomationRequest) -> Bool {
        guard request.method == AutomationMethod.metadataSearch
                || request.method == AutomationMethod.artworkSearch
                || request.method == AutomationMethod.lyricsSearch
                || request.method == AutomationMethod.storageValidate
                || request.method == AutomationMethod.diagnosticsHealth,
              case .object(let values) = request.params,
              case .boolean(true)? = values["background"] else {
            return false
        }
        return true
    }

    private func usesIdempotencyCache(for request: AutomationRequest) -> Bool {
        AutomationToolCatalog.descriptor(for: request.method)?.readOnly == false
            || isBackgroundJobRequest(request)
    }

    private func submitBackgroundJob(for request: AutomationRequest) async -> AutomationResponse {
        if let deadline = request.context.deadline, deadline <= Date() {
            return AutomationResponseSupport.requestDeadlineExpired(for: request)
        }
        guard let session = sessionAccess.activeSession(for: request), let appSession else {
            return sessionAccess.noActiveLibraryResponse(for: request)
        }
        guard case .object(var params) = request.params else {
            return AutomationResponseSupport.invalidParameters(for: request)
        }
        params["background"] = .boolean(false)
        let backgroundRequest = AutomationRequest(
            method: request.method,
            params: .object(params),
            context: AutomationRequestContext(
                principalSessionID: request.context.principalSessionID,
                libraryID: session.context.id,
                caller: request.context.caller
            ),
            requestID: request.requestID,
            protocolVersion: request.protocolVersion
        )
        guard let job = appSession.startAutomationJob(
            totalCount: 1,
            libraryID: session.context.id,
            work: { [weak self] reporter in
                guard let self,
                      self.sessionAccess.activeSession(for: backgroundRequest) === session else {
                    reporter.recordFailure("The submitted Library is no longer active.")
                    return
                }
                let response = await self.execute(backgroundRequest)
                if let encoded = try? AutomationWireCoding.encoder().encode(response),
                   let value = try? AutomationWireCoding.decoder().decode(
                       AutomationJSONValue.self,
                       from: encoded
                   ) {
                    reporter.recordResult(value)
                }
                if let error = response.error {
                    reporter.recordFailure(error.message)
                }
                let phase: String
                switch backgroundRequest.method {
                case AutomationMethod.metadataSearch: phase = "Metadata search complete"
                case AutomationMethod.artworkSearch: phase = "Artwork search complete"
                case AutomationMethod.lyricsSearch: phase = "Lyrics search complete"
                case AutomationMethod.storageValidate: phase = "Storage validation complete"
                case AutomationMethod.diagnosticsHealth: phase = "Diagnostics complete"
                default: phase = "Operation complete"
                }
                reporter.recordProgress(completedCount: 1, totalCount: 1, phase: phase)
            }
        ) else {
            return sessionAccess.noActiveLibraryResponse(for: request)
        }
        return AutomationResponseSupport.encodeResult(
            AutomationJobSubmissionResult(
                job: AutomationJobProjection.makeJobSummary(job),
                message: "The request was accepted as a library-scoped Job. Use jobs.wait or jobs.get for its original result."
            ),
            for: request
        )
    }

    private func submitOperationsBatch(for request: AutomationRequest) async -> AutomationResponse {
        if let deadline = request.context.deadline, deadline <= Date() {
            return AutomationResponseSupport.requestDeadlineExpired(for: request)
        }
        guard let session = sessionAccess.activeSession(for: request), let appSession else {
            return sessionAccess.noActiveLibraryResponse(for: request)
        }
        do {
            let parameters = try AutomationParameters(request)
            guard case .object(let batchParams) = request.params,
                  case .array(let values)? = batchParams["operations"],
                  !values.isEmpty, values.count <= 100 else {
                throw AutomationParameterError.outOfRange("operations")
            }
            let forceDryRun = try parameters.boolean("dryRun", default: false)
            let confirm = try parameters.boolean("confirm", default: false)
            var operations: [AutomationBatchOperation] = []
            operations.reserveCapacity(values.count)
            for (index, value) in values.enumerated() {
                guard case .object(let fields) = value,
                      case .string(let method)? = fields["method"] else {
                    throw AutomationParameterError.invalidValue("operations[\(index)]")
                }
                guard method != AutomationMethod.operationsBatch,
                      Self.batchAllowedMethods.contains(method) else {
                    throw AutomationParameterError.invalidValue("operations[\(index)].method")
                }
                let childParams = fields["params"]
                guard childParams == nil || childParams == .null || AutomationResponseSupport.isObject(childParams) else {
                    // Keep malformed per-item parameters in the Job so the
                    // caller receives the same indexed error envelope as any
                    // other handler-level parameter failure.
                    operations.append(AutomationBatchOperation(method: method, params: childParams))
                    continue
                }
                operations.append(AutomationBatchOperation(method: method, params: childParams))
            }

            var requiredScopes = Set<AutomationScope>()
            var distinctTargets = Set<String>()
            var writeOperationCount = 0
            for operation in operations {
                guard let descriptor = AutomationToolCatalog.descriptor(for: operation.method) else {
                    throw AutomationParameterError.invalidValue("operations.method")
                }
                var scopes = Set(descriptor.scopes)
                var itemDryRun = forceDryRun
                if case .object(let itemParams) = operation.params,
                   case .boolean(true)? = itemParams["dryRun"] {
                    itemDryRun = true
                }
                if itemDryRun, let writeScope = Self.batchWriteScope(for: operation.method) {
                    scopes.remove(writeScope)
                } else if !itemDryRun {
                    writeOperationCount += 1
                    distinctTargets.formUnion(batchTargetKeys(for: operation))
                }
                requiredScopes.formUnion(scopes)
            }
            let granted = grantedScopes()
            guard granted.isSuperset(of: requiredScopes) else {
                let denied = requiredScopes.subtracting(granted)
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .authorizationRequired,
                        message: "The App automation policy has not granted all scopes required by this batch.",
                        details: .object([
                            "requiredScopes": .array(requiredScopes.map(\.rawValue).sorted().map(AutomationJSONValue.string)),
                            "deniedScopes": .array(denied.map(\.rawValue).sorted().map(AutomationJSONValue.string))
                        ])
                    )
                )
            }

            let requiresConfirmation = !forceDryRun
                && (writeOperationCount >= 10 || distinctTargets.count >= 10)
            if requiresConfirmation {
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "批量资产修改需要 confirm=true，并由播放器在前台一次性确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.operationsBatch),
                            "operationCount": .number(Double(writeOperationCount)),
                            "distinctTargetCount": .number(Double(distinctTargets.count)),
                            "threshold": .number(10),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "执行 \(writeOperationCount) 项资料库修改？",
                    message: "这些操作将按顺序应用到 \(distinctTargets.count) 个目标，并逐项保留执行结果。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
            }

            if let deadline = request.context.deadline, deadline <= Date() {
                return AutomationResponseSupport.requestDeadlineExpired(for: request)
            }
            let boundLibraryID = session.context.id
            let snapshotOperations = operations
            let plannedWriteCount = writeOperationCount
            guard let job = appSession.startAutomationJob(
                totalCount: snapshotOperations.count,
                libraryID: boundLibraryID,
                work: { [weak self, snapshotOperations, plannedWriteCount] reporter in
                    guard let self else { return }
                    var itemResults: [AutomationJSONValue] = []
                    var failedIndices: [Int] = []
                    var conflictedTrackIDs = Set<UUID>()
                    var conflictedTargets = Set<String>()
                    itemResults.reserveCapacity(snapshotOperations.count)

                    func resultSnapshot() -> AutomationJSONValue {
                        .object([
                            "libraryID": .string(boundLibraryID.uuidString),
                            "dryRun": .boolean(forceDryRun || plannedWriteCount == 0),
                            "requestedCount": .number(Double(snapshotOperations.count)),
                            "completedCount": .number(Double(itemResults.count)),
                            "failedCount": .number(Double(failedIndices.count)),
                            "failedItemIndices": .array(failedIndices.map { .number(Double($0)) }),
                            "conflictCount": .number(Double(conflictedTargets.count)),
                            "conflictedTrackIDs": .array(conflictedTrackIDs.sorted { $0.uuidString < $1.uuidString }.map { .string($0.uuidString) }),
                            "conflictedTargets": .array(conflictedTargets.sorted().map(AutomationJSONValue.string)),
                            "items": .array(itemResults)
                        ])
                    }

                    for (index, operation) in snapshotOperations.enumerated() {
                        guard !Task.isCancelled else { break }
                        let childRequest = self.makeBatchChildRequest(
                            operation,
                            parent: request,
                            libraryID: boundLibraryID,
                            forceDryRun: forceDryRun,
                            aggregateConfirmationApproved: requiresConfirmation
                        )
                        guard self.sessionAccess.activeSession(for: childRequest) === session else {
                            failedIndices.append(index)
                            reporter.recordFailure(
                                "The Library changed before batch item \(index) could run.",
                                itemID: self.batchPrimaryTargetID(for: operation)
                            )
                            break
                        }
                        let response = await AutomationBatchExecutionContext.$aggregateConfirmationApproved
                            .withValue(requiresConfirmation) {
                                await self.execute(childRequest)
                            }
                        let responseValue = AutomationResponseSupport.jsonValue(for: response)
                            ?? .object(["error": .string("Unable to encode item response.")])
                        itemResults.append(.object([
                            "index": .number(Double(index)),
                            "method": .string(operation.method),
                            "response": responseValue
                        ]))
                        if let error = response.error {
                            failedIndices.append(index)
                            reporter.recordFailure(
                                "Item \(index) (\(operation.method)): \(error.message)",
                                itemID: self.batchPrimaryTargetID(for: operation)
                            )
                        }
                        let itemConflicts = self.conflictedTargets(in: response.result)
                        if !itemConflicts.isEmpty {
                            for target in itemConflicts where conflictedTargets.insert(target).inserted {
                                let rawTargetID = String(target.split(separator: ":").last ?? "")
                                let targetID = UUID(uuidString: rawTargetID)
                                if target.hasPrefix("track:"), let targetID {
                                    conflictedTrackIDs.insert(targetID)
                                }
                                reporter.recordFailure(
                                    "Item \(index) (\(operation.method)) conflicted on \(target); refresh that target before retrying.",
                                    itemID: target.hasPrefix("album:") ? nil : targetID
                                )
                            }
                        }
                        reporter.recordProgress(
                            completedCount: index + 1,
                            totalCount: snapshotOperations.count,
                            phase: "Item \(index + 1) of \(snapshotOperations.count)"
                        )
                        reporter.recordResult(resultSnapshot())
                    }
                    reporter.recordResult(resultSnapshot())
                }
            ) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationJobSubmissionResult(
                    job: AutomationJobProjection.makeJobSummary(job),
                    message: "Batch accepted. Each item result and any revision conflicts are persisted in the Job; use jobs.wait or jobs.get."
                ),
                for: request
            )
        } catch {
            return AutomationResponseSupport.invalidParameters(for: request, error: error)
        }
    }

    private static let batchAllowedMethods: Set<String> = [
        AutomationMethod.metadataPatch,
        AutomationMethod.metadataApplyCandidate,
        AutomationMethod.artworkApply,
        AutomationMethod.artworkApplyCandidate,
        AutomationMethod.lyricsApply,
        AutomationMethod.lyricsClean
    ]

    private static func batchWriteScope(for method: String) -> AutomationScope? {
        switch method {
        case AutomationMethod.metadataPatch, AutomationMethod.metadataApplyCandidate:
            return .metadataWrite
        case AutomationMethod.artworkApply, AutomationMethod.artworkApplyCandidate:
            return .artworkWrite
        case AutomationMethod.lyricsApply, AutomationMethod.lyricsClean:
            return .lyricsWrite
        default:
            return nil
        }
    }

    private func makeBatchChildRequest(
        _ operation: AutomationBatchOperation,
        parent: AutomationRequest,
        libraryID: UUID,
        forceDryRun: Bool,
        aggregateConfirmationApproved: Bool
    ) -> AutomationRequest {
        var params: [String: AutomationJSONValue]
        if case .object(let values) = operation.params {
            params = values
        } else {
            params = [:]
        }
        if forceDryRun {
            params["dryRun"] = .boolean(true)
        }
        if aggregateConfirmationApproved,
           operation.method == AutomationMethod.metadataPatch
                || operation.method == AutomationMethod.artworkApply {
            params["confirm"] = .boolean(true)
        }
        return AutomationRequest(
            method: operation.method,
            params: .object(params),
            context: AutomationRequestContext(
                principalSessionID: parent.context.principalSessionID,
                libraryID: libraryID,
                caller: parent.context.caller
            ),
            protocolVersion: parent.protocolVersion
        )
    }

    private func batchTargetKeys(for operation: AutomationBatchOperation) -> Set<String> {
        guard case .object(let params) = operation.params else { return [] }
        var targets = Set<String>()
        if case .string(let raw)? = params["trackID"] { targets.insert("track:\(raw)") }
        if case .array(let values)? = params["trackIDs"] {
            for value in values {
                if case .string(let raw) = value { targets.insert("track:\(raw)") }
            }
        }
        for key in ["artistID", "albumKey", "playlistID"] {
            if case .string(let raw)? = params[key], !raw.isEmpty {
                let prefix = key == "artistID" ? "artist" : key == "albumKey" ? "album" : "playlist"
                targets.insert("\(prefix):\(raw)")
            }
        }
        return targets
    }

    private func batchPrimaryTargetID(for operation: AutomationBatchOperation) -> UUID? {
        guard case .object(let params) = operation.params else { return nil }
        if case .string(let raw)? = params["trackID"] { return UUID(uuidString: raw) }
        if case .array(let values)? = params["trackIDs"] {
            for value in values {
                if case .string(let raw) = value, let id = UUID(uuidString: raw) { return id }
            }
        }
        return nil
    }

    private func conflictedTargets(in value: AutomationJSONValue?) -> [String] {
        guard let value else { return [] }
        var result = Set<String>()
        func visit(_ value: AutomationJSONValue) {
            guard case .object(let fields) = value else {
                if case .array(let values) = value { values.forEach(visit) }
                return
            }
            for (key, nested) in fields {
                if key.hasPrefix("conflicted"),
                   case .array(let targets) = nested,
                   key.hasSuffix("IDs") || key.hasSuffix("Keys") {
                    let prefix: String
                    if key.contains("Artist") { prefix = "artist" }
                    else if key.contains("Album") { prefix = "album" }
                    else if key.contains("Playlist") { prefix = "playlist" }
                    else { prefix = "track" }
                    for target in targets {
                        if case .string(let raw) = target {
                            result.insert("\(prefix):\(raw)")
                        }
                    }
                } else {
                    visit(nested)
                }
            }
        }
        visit(value)
        return result.sorted()
    }

}

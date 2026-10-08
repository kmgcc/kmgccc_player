import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

private enum AutomationBatchExecutionContext {
    @TaskLocal static var aggregateConfirmationApproved = false
}

private nonisolated struct AutomationStorageBackupManifest: Codable {
    let schemaVersion: Int
    let libraryID: UUID
    let mode: String
    let createdAt: Date
    let files: [File]

    struct File: Codable {
        let relativePath: String
        let sha256: String
        let byteCount: Int64
    }
}

nonisolated struct AutomationStorageBackupPruneResult: Sendable, Equatable {
    let removedBackupCount: Int
    let failures: [String]
}

/// Keeps storage.backup recoverable without letting repeated automation runs
/// accumulate one full metadata/artwork snapshot per invocation.
nonisolated enum AutomationStorageBackupRetention {
    static let maximumBackupCount = 1

    static func pruneOlderBackups(
        at rootURL: URL,
        keeping retainedBackupURL: URL,
        fileManager: FileManager = .default
    ) -> AutomationStorageBackupPruneResult {
        let root = rootURL.standardizedFileURL
        let retained = retainedBackupURL.standardizedFileURL
        guard retained.path.hasPrefix(root.path + "/") else {
            return AutomationStorageBackupPruneResult(
                removedBackupCount: 0,
                failures: ["Refused to prune a backup outside the backup root."]
            )
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return AutomationStorageBackupPruneResult(
                removedBackupCount: 0,
                failures: ["Failed to enumerate automation backup snapshots."]
            )
        }

        var removedBackupCount = 0
        var failures: [String] = []
        for entry in entries {
            guard entry.standardizedFileURL.path != retained.path else {
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            do {
                try fileManager.removeItem(at: entry)
                removedBackupCount += 1
            } catch {
                if failures.count < 50 {
                    failures.append(
                        "Failed to remove old automation backup \(entry.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }

        return AutomationStorageBackupPruneResult(
            removedBackupCount: removedBackupCount,
            failures: failures
        )
    }
}

private nonisolated struct AutomationStorageInventoryItem {
    let relativePath: String
    let sourceURL: URL
    let sha256: String
    let byteCount: Int64
}

private nonisolated struct AutomationStorageInventory {
    let items: [AutomationStorageInventoryItem]
    let omittedFileCount: Int
    let failures: [String]
}

@MainActor
final class AutomationIPCServer {
    private enum ArtworkTarget {
        case track(Track)
        case artist(ArtistEntry)
        case album(AlbumEntry)
        case playlist(Playlist)

        var type: String {
            switch self {
            case .track: return "track"
            case .artist: return "artist"
            case .album: return "album"
            case .playlist: return "playlist"
            }
        }

        var stableIdentity: String {
            switch self {
            case .track(let track): return "track:\(track.id.uuidString)"
            case .artist(let artist): return "artist:\(artist.id.uuidString)"
            case .album(let album): return "album:\(album.canonicalKey)"
            case .playlist(let playlist): return "playlist:\(playlist.id.uuidString)"
            }
        }
    }

    private enum MetadataTarget {
        case track(Track)
        case artist(ArtistEntry)
        case album(AlbumEntry)
        case playlist(Playlist)
    }

    private struct PendingIdempotency {
        let fingerprint: String
        var waiters: [(requestID: UUID, continuation: CheckedContinuation<AutomationResponse, Never>)]
    }

    private static let socketDirectoryName = "Automation"
    private static let socketFileName = "automation.sock"

    private var sessionAccess: AutomationSessionAccess { AutomationSessionAccess(appSession: appSession) }
    private var queries: AutomationLibraryQueries { AutomationLibraryQueries(appSession: appSession) }

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
    private var lyricsCandidateCache: [UUID: CachedLyricsCandidates] = [:]
    private var artworkCandidateCache: [String: CachedArtworkCandidate] = [:]
    private var artworkCandidateOrder: [String] = []
    private let idempotencyCacheLimit = 256
    private let lyricsCandidateCacheLimit = 256
    private let artworkCandidateCacheLimit = 64
    private(set) var isRunning = false

    private struct CachedLyricsCandidates {
        let mode: LDDCMode
        let translation: Bool
        let result: LyricsSearchHelper.SearchResult
    }

    private struct CachedArtworkCandidate {
        let libraryID: UUID
        let targetIdentity: String
        let trackID: UUID?
        let artistID: UUID?
        let albumKey: String?
        let revision: String
        let candidate: AutomationArtworkCandidate
        let expiresAt: Date
    }

    private struct PlannedMetadataImport {
        let record: AutomationMetadataDocumentTrack
        let targetTrackID: UUID?
        let patch: LibraryAutomationMetadataPatch?
        let expectedRevision: String?
        let fields: [String]
        var status: String
        var message: String
    }

    init(
        appSession: AppSessionHost,
        bundleIdentifier: String? = nil,
        socketURL: URL? = nil,
        appSupportDirectoryURL: URL? = nil,
        ioTimeout: TimeInterval = 120
    ) throws {
        self.appSession = appSession
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

        case AutomationMethod.libraryList:
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            let registry = await appSession.musicLibraryRegistrySnapshot()
            let summaries = registry.libraries.map {
                queries.makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationLibraryListResult(
                    libraries: summaries,
                    activeLibraryID: registry.activeLibraryID
                ),
                for: request
            )

        case AutomationMethod.libraryGet:
            guard let appSession else {
                return .failure(for: request, error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true))
            }
            do {
                let parameters = try AutomationParameters(request)
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let bookmark = registry.libraries.first(where: { $0.id == libraryID }) else {
                    return .failure(for: request, error: AutomationError(code: .invalidRequest, message: "The requested Library is not registered.", details: .object(["libraryID": .string(libraryID.uuidString)])))
                }
                return AutomationResponseSupport.encodeResult(AutomationLibraryGetResult(
                    library: queries.makeLibrarySummary(bookmark, activeLibraryID: registry.activeLibraryID),
                    activeLibraryID: registry.activeLibraryID
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryCreate:
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let modeRaw = try parameters.string("mode", required: true)!
                guard let mode = MusicLibraryMode(rawValue: modeRaw) else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let displayName = try parameters.string("displayName", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty, displayName.count <= 255 else {
                    throw AutomationParameterError.outOfRange("displayName")
                }
                let requestedParentPath = try parameters.string("parentPath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let allowAlternateDestination = try parameters.boolean(
                    "allowAlternateDestinationWhenOccupied",
                    default: false
                )
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: false,
                            dryRun: true,
                            path: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                            message: "Preview only. The App will ask for a parent folder, create the library root without overwriting unknown files, and activate the new library after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "创建资料库会切换当前资料库，需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryCreate),
                            "mode": .string(mode.rawValue),
                            "displayName": .string(displayName)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "创建并切换资料库？",
                    message: "要创建“\(displayName)”资料库并切换到它吗？当前播放会话将随之切换。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let selectedURL = await AutomationInteraction.requestLibraryDirectory(
                    requestedPath: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                    title: "选择资料库位置",
                    prompt: "选择",
                    allowsCreatingDirectories: true
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return AutomationResponseSupport.libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let result = try await appSession.createMusicLibrary(
                    mode: mode,
                    parentURL: selectedURL,
                    displayName: displayName,
                    initialImportSelection: nil,
                    initialImportPolicy: .background,
                    allowAlternateDestinationWhenOccupied: allowAlternateDestination
                )
                let registry = await appSession.musicLibraryRegistrySnapshot()
                switch result {
                case .created(let context, _):
                    let summary = registry.library(id: context.id).map {
                        queries.makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: true,
                            dryRun: false,
                            confirmed: true,
                            libraryID: context.id,
                            library: summary,
                            activeLibraryID: registry.activeLibraryID,
                            path: context.rootURL.path,
                            message: "Library created and activated."
                        ),
                        for: request
                    )
                case .existingLibrary(let context):
                    let summary = registry.library(id: context.id).map {
                        queries.makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: false,
                            dryRun: false,
                            confirmed: true,
                            libraryID: context.id,
                            library: summary,
                            activeLibraryID: registry.activeLibraryID,
                            path: context.rootURL.path,
                            message: "A library already exists at the selected location; no new library was created."
                        ),
                        for: request
                    )
                case .existingLibraryModeMismatch(let context, let requestedMode):
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "A library already exists at the selected location with a different storage mode.",
                            details: .object([
                                "libraryID": .string(context.id.uuidString),
                                "requestedMode": .string(requestedMode.rawValue),
                                "actualMode": .string(context.mode.rawValue),
                                "path": .string(context.rootURL.path)
                            ])
                        )
                    )
                }
            } catch {
                return AutomationResponseSupport.libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryOpen:
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let requestedPath = try parameters.string("path")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryOpen,
                            applied: false,
                            dryRun: true,
                            path: requestedPath.map(AutomationInteraction.expandPath(_:)),
                            message: "Preview only. The App will ask for the existing library folder, register it if needed, and activate it after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "打开资料库会切换当前资料库，需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["operation": .string(AutomationMethod.libraryOpen)])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "打开并切换资料库？",
                    message: "要打开所选资料库并切换到它吗？当前播放会话将随之切换。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let selectedURL = await AutomationInteraction.requestLibraryDirectory(
                    requestedPath: requestedPath.map(AutomationInteraction.expandPath(_:)),
                    title: "选择现有资料库",
                    prompt: "打开",
                    allowsCreatingDirectories: false
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return AutomationResponseSupport.libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let unavailableSourceIDs = try await appSession.openMusicLibrary(at: selectedURL)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                let activeID = registry.activeLibraryID
                let active = activeID.flatMap(registry.library(id:))
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryOpen,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: activeID,
                        library: active.map { queries.makeLibrarySummary($0, activeLibraryID: activeID) },
                        activeLibraryID: activeID,
                        path: active?.lastKnownPath,
                        unavailableSourceIDs: unavailableSourceIDs,
                        message: "Library opened and activated."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.librarySwitch:
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.librarySwitch,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "Preview only. Set dryRun=false and confirm=true to activate this registered library."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "切换当前资料库需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.librarySwitch),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard libraryID != registry.activeLibraryID else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.librarySwitch,
                            applied: false,
                            dryRun: false,
                            confirmed: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "The requested library is already active."
                        ),
                        for: request
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "切换当前资料库？",
                    message: "要切换到“\(target.displayName)”吗？当前播放会话将关闭并重新打开所选资料库。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let unavailableSourceIDs = try await appSession.activateRegisteredLibrary(id: libraryID)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updatedActiveID = updatedRegistry.activeLibraryID
                let active = updatedActiveID.flatMap(updatedRegistry.library(id:))
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.librarySwitch,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: active.map { queries.makeLibrarySummary($0, activeLibraryID: updatedActiveID) },
                        activeLibraryID: updatedActiveID,
                        path: active?.lastKnownPath,
                        unavailableSourceIDs: unavailableSourceIDs,
                        message: "Library switched and activated."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryRename:
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let displayName = try parameters.string("displayName", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty, displayName.count <= 255 else {
                    throw AutomationParameterError.outOfRange("displayName")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRename,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "Preview only. The display name will change; library files and storage mode will remain unchanged."
                        ),
                        for: request
                    )
                }
                try await appSession.renameMusicLibrary(id: libraryID, displayName: displayName)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updated = updatedRegistry.library(id: libraryID)
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRename,
                        applied: true,
                        dryRun: false,
                        libraryID: libraryID,
                        library: updated.map { queries.makeLibrarySummary($0, activeLibraryID: updatedRegistry.activeLibraryID) },
                        activeLibraryID: updatedRegistry.activeLibraryID,
                        path: updated?.lastKnownPath ?? target.lastKnownPath,
                        message: "Library renamed."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryRelocate:
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let requestedParentPath = try parameters.string("parentPath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRelocate,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                            message: "Preview only. The App will ask for a destination parent folder and move the complete library through its recovery transaction after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "迁移资料库会改变磁盘上的文件位置，需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryRelocate),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "迁移资料库？",
                    message: "要将“\(target.displayName)”移动到新位置吗？移动后当前播放会话将重新打开。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let selectedURL = await AutomationInteraction.requestLibraryDirectory(
                    requestedPath: requestedParentPath.map(AutomationInteraction.expandPath(_:)),
                    title: "选择新的资料库位置",
                    prompt: "移到这里",
                    allowsCreatingDirectories: true
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return AutomationResponseSupport.libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let result = try await appSession.relocateMusicLibrary(id: libraryID, to: selectedURL)
                let newContext: LibraryContext
                let message: String
                switch result {
                case .moved(let context, let transfer):
                    newContext = context
                    message = transfer == .copiedAcrossVolumes
                        ? "Library relocated and the old copy was moved to the macOS Trash."
                        : "Library relocated."
                case .movedWithOldCopyRemaining(let context, _):
                    newContext = context
                    message = "Library relocated, but the old copy remains because it could not be moved to the macOS Trash."
                }
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updated = updatedRegistry.library(id: libraryID)
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRelocate,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: updated.map { queries.makeLibrarySummary($0, activeLibraryID: updatedRegistry.activeLibraryID) },
                        activeLibraryID: updatedRegistry.activeLibraryID,
                        path: newContext.rootURL.path,
                        message: message
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryRemove:
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let libraryID = try parameters.uuid("libraryID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                guard let target = registry.library(id: libraryID) else {
                    throw AutomationParameterError.missingResource("libraryID")
                }
                let targetSummary = queries.makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRemove,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: target.lastKnownPath,
                            message: "Preview only. The App will move the library root to the macOS Trash and select a safe successor when needed after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "将资料库移到 macOS 废纸篓需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryRemove),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "将资料库移到废纸篓？",
                    message: "要将“\(target.displayName)”及其资料库数据移到 macOS 废纸篓吗？其他资料库会保留，并继续使用可用的资料库。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                _ = try await appSession.removeMusicLibrary(id: libraryID)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let activeID = updatedRegistry.activeLibraryID
                let active = activeID.flatMap(updatedRegistry.library(id:))
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRemove,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: active.map { queries.makeLibrarySummary($0, activeLibraryID: activeID) },
                        activeLibraryID: activeID,
                        path: target.lastKnownPath,
                        message: "Library moved to the macOS Trash; the App selected the next active library."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.libraryLifecycleFailure(for: request, error: error)
            }

        case AutomationMethod.libraryImport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                guard case .array(let paths) = parameters.values["filePaths"],
                      !paths.isEmpty, paths.count <= 5_000 else {
                    throw AutomationParameterError.invalidValue("filePaths")
                }
                var urls: [URL] = []
                var seen = Set<String>()
                for value in paths {
                    guard case .string(let rawPath) = value,
                          !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          (rawPath as NSString).expandingTildeInPath.hasPrefix("/") else {
                        throw AutomationParameterError.invalidValue("filePaths")
                    }
                    let url = URL(fileURLWithPath: AutomationInteraction.expandPath(rawPath))
                    if seen.insert(url.resolvingSymlinksInPath().path).inserted { urls.append(url) }
                }
                let playlistID = try parameters.uuid("targetPlaylistID")
                if let playlistID,
                   !session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) {
                    throw AutomationParameterError.missingResource("targetPlaylistID")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let enrichmentPolicyRaw = try parameters.string("enrichmentPolicy")
                    ?? LibraryImportEnrichmentPolicy.standard.rawValue
                guard let enrichmentPolicy = LibraryImportEnrichmentPolicy(rawValue: enrichmentPolicyRaw) else {
                    throw AutomationParameterError.invalidValue("enrichmentPolicy")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(AutomationLibraryImportResult(
                        libraryID: session.context.id, mode: session.context.mode.rawValue,
                        filePaths: urls.map(\.path), targetPlaylistID: playlistID,
                        dryRun: true,
                        enrichmentPolicy: enrichmentPolicy.rawValue,
                        message: "Preview only; no scan, conversion, authorization, import or enrichment has started."
                    ), for: request)
                }
                // Directly readable paths use the App's existing access. A
                // sandboxed App requests the same system picker as UI import.
                // Missing files are reported individually by the import pipeline.
                let inaccessible = urls.filter {
                    FileManager.default.fileExists(atPath: $0.path)
                        && !FileManager.default.isReadableFile(atPath: $0.path)
                }
                var selectedURLs = urls
                if !inaccessible.isEmpty {
                    guard let picked = await session.fileImportService.pickImportURLs(triggeredAt: Date()) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                    let pickedPaths = Set(picked.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
                    guard inaccessible.allSatisfy({ pickedPaths.contains($0.resolvingSymlinksInPath().path) }) else {
                        return AutomationResponseSupport.permissionDenied(for: request, path: inaccessible[0].path)
                    }
                    selectedURLs = urls.map { url in
                        picked.first { $0.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path } ?? url
                    }
                }
                let selection = LibraryInitialImportSelection(urls: selectedURLs)
                defer { selection.release() }
                if let denied = selectedURLs.first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                        && !FileManager.default.isReadableFile(atPath: $0.path)
                }) {
                    return AutomationResponseSupport.permissionDenied(for: request, path: denied.path)
                }
                guard sessionAccess.activeSession(for: request) === session,
                      let job = session.startAutomationImport(
                        selection: selection,
                        playlistID: playlistID,
                        enrichmentPolicy: enrichmentPolicy
                      ) else {
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                return AutomationResponseSupport.encodeResult(AutomationLibraryImportResult(
                    libraryID: session.context.id, mode: session.context.mode.rawValue,
                    filePaths: selectedURLs.map(\.path), targetPlaylistID: playlistID,
                    job: AutomationJobProjection.makeJobSummary(job),
                    enrichmentPolicy: enrichmentPolicy.rawValue,
                    message: "Import started. Use jobs.wait or jobs.get for Track IDs, per-file mappings, failures and enrichment status."
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryTracks:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let query = try parameters.string("query")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let playlistID = try parameters.uuid("playlistID")
                let sourceID = try parameters.uuid("sourceID")
                let relativePathPrefix = try parameters.string("relativePathPrefix")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let requestedIDs = try parameters.uuidArray("ids")
                let filter = try parameters.object("filter")
                if let filter {
                    try queries.validateTrackFilter(.object(filter))
                }
                let sort = try parameters.array("sort")
                let includePreferenceStats = try parameters.boolean(
                    "includePreferenceStats", default: false
                )
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                let expectedRevision = try parameters.string("expectedRevision")
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }

                let viewModel = session.libraryViewModel
                let allTracks = viewModel.allTracks
                let usesPreferenceData = includePreferenceStats
                    || filter.map { AutomationTrackPreferenceQuery.requiresHistoryRead(in: .object($0)) } == true
                    || AutomationTrackPreferenceQuery.requiresHistoryRead(sort: sort)
                let preferenceStatsByTrackID = usesPreferenceData
                    ? viewModel.preferenceStats(for: allTracks.map(\.id))
                    : [:]
                let playlistTrackIDs: Set<UUID>?
                if let playlistID {
                    guard let playlist = viewModel.playlists.first(where: { $0.id == playlistID }) else {
                        return .failure(
                            for: request,
                            error: AutomationError(
                                code: .invalidRequest,
                                message: "The requested playlist does not exist.",
                                details: .object(["playlistID": .string(playlistID.uuidString)])
                            )
                        )
                    }
                    playlistTrackIDs = Set(playlist.tracks.map(\.id))
                } else {
                    playlistTrackIDs = nil
                }

                let revision = queries.libraryTracksRevision(
                    tracks: allTracks,
                    playlists: viewModel.playlists,
                    preferenceStatsByTrackID: usesPreferenceData ? preferenceStatsByTrackID : nil
                )
                if let expectedRevision, expectedRevision != revision {
                    return AutomationResponseSupport.libraryTracksRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: revision
                    )
                }

                var filteredTracks: [Track] = []
                filteredTracks.reserveCapacity(allTracks.count)
                for track in allTracks {
                    if !requestedIDs.isEmpty, !requestedIDs.contains(track.id) { continue }
                    if let playlistTrackIDs, !playlistTrackIDs.contains(track.id) { continue }
                    let memberships = track.mediaLocator.referencedFile?.allSourceMemberships ?? []
                    if let sourceID, !memberships.contains(where: { $0.sourceID == sourceID }) {
                        continue
                    }
                    if let relativePathPrefix, !relativePathPrefix.isEmpty,
                       !memberships.contains(where: {
                           $0.relativePath == relativePathPrefix
                               || $0.relativePath.hasPrefix(relativePathPrefix + "/")
                       }) {
                        continue
                    }
                    if let query, !query.isEmpty,
                       !track.title.localizedCaseInsensitiveContains(query),
                       !track.artist.localizedCaseInsensitiveContains(query),
                       !track.album.localizedCaseInsensitiveContains(query) {
                        continue
                    }
                    if let filter,
                       try !queries.matchesTrackFilter(
                           track,
                           filter: .object(filter),
                           playlists: viewModel.playlists,
                           preferenceStatsByTrackID: preferenceStatsByTrackID
                       ) {
                        continue
                    }
                    filteredTracks.append(track)
                }
                let orderedTracks = try queries.sortTracks(
                    filteredTracks,
                    using: sort,
                    preferenceStatsByTrackID: preferenceStatsByTrackID
                )
                let pageStart = min(offset, orderedTracks.count)
                let pageEnd = min(pageStart + limit, orderedTracks.count)
                let page = Array(orderedTracks[pageStart..<pageEnd]).map {
                    queries.makeTrackSummary(
                        $0,
                        playlists: viewModel.playlists,
                        includeFilePath: grantedScopes().contains(.filesRead),
                        includePreferenceStats: includePreferenceStats,
                        preferenceStats: preferenceStatsByTrackID[$0.id]
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryTracksResult(
                        tracks: page,
                        total: orderedTracks.count,
                        offset: offset,
                        limit: limit,
                        nextOffset: pageEnd < orderedTracks.count ? pageEnd : nil,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryStats:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            let viewModel = session.libraryViewModel
            let tracks = viewModel.allTracks
            let revision = queries.libraryTracksRevision(tracks: tracks, playlists: viewModel.playlists)
            let linkedSourceIDs = Set(tracks.flatMap { track in
                track.mediaLocator.referencedFile?.allSourceMemberships.map(\.sourceID) ?? []
            })
            return AutomationResponseSupport.encodeResult(AutomationLibraryStatsResult(
                libraryID: session.context.id,
                mode: session.context.mode.rawValue,
                trackCount: tracks.count,
                availableTrackCount: tracks.filter { $0.availability == .available }.count,
                missingTrackCount: tracks.filter { $0.availability == .missing }.count,
                recoverableTrackCount: tracks.filter { $0.availability.isRecoverable }.count,
                playlistCount: viewModel.playlists.count,
                linkedSourceCount: linkedSourceIDs.count,
                artistCount: viewModel.runtimeArtists.count,
                albumCount: viewModel.runtimeAlbums.count,
                lyricsTrackCount: tracks.filter { $0.ttmlLyricsFileName != nil || $0.lyricsFileName != nil }.count,
                artworkTrackCount: tracks.filter { $0.artworkFileName != nil }.count,
                totalDurationSeconds: tracks.reduce(0) { $0 + max(0, $1.duration) },
                revision: revision
            ), for: request)

        case AutomationMethod.libraryReport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                let playlistLimit = try parameters.integer("playlistLimit", default: 100)
                let playlistOffset = try parameters.integer("playlistOffset", default: 0)
                let expectedRevision = try parameters.string("expectedRevision")
                let includeFilePaths = try parameters.boolean("includeFilePaths", default: false)
                let includePreferenceStats = try parameters.boolean(
                    "includePreferenceStats", default: false
                )
                guard (1...100).contains(limit), offset >= 0,
                      (1...100).contains(playlistLimit), playlistOffset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                guard !includeFilePaths || grantedScopes().contains(.filesRead) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .authorizationRequired,
                            message: "Including local file paths requires the files.read scope.",
                            details: .object(["requiredScope": .string(AutomationScope.filesRead.rawValue)])
                        )
                    )
                }
                let viewModel = session.libraryViewModel
                let allTracks = viewModel.allTracks
                let playlists = viewModel.playlists
                let preferenceStatsByTrackID = includePreferenceStats
                    ? viewModel.preferenceStats(for: allTracks.map(\.id))
                    : [:]
                let revision = queries.libraryTracksRevision(
                    tracks: allTracks,
                    playlists: playlists,
                    preferenceStatsByTrackID: includePreferenceStats
                        ? preferenceStatsByTrackID
                        : nil
                )
                if let expectedRevision, expectedRevision != revision {
                    return AutomationResponseSupport.libraryTracksRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: revision
                    )
                }
                let start = min(offset, allTracks.count)
                let end = min(start + limit, allTracks.count)
                let trackPage = Array(allTracks[start..<end]).map {
                    queries.makeTrackSummary(
                        $0,
                        playlists: playlists,
                        includeFilePath: includeFilePaths,
                        includePreferenceStats: includePreferenceStats,
                        preferenceStats: preferenceStatsByTrackID[$0.id]
                    )
                }
                let playlistStart = min(playlistOffset, playlists.count)
                let playlistEnd = min(playlistStart + playlistLimit, playlists.count)
                let playlistPage = Array(playlists[playlistStart..<playlistEnd])
                let linkedSourceIDs = Set(allTracks.flatMap { track in
                    track.mediaLocator.referencedFile?.allSourceMemberships.map(\.sourceID) ?? []
                })
                let stats = AutomationLibraryStatsResult(
                    libraryID: session.context.id,
                    mode: session.context.mode.rawValue,
                    trackCount: allTracks.count,
                    availableTrackCount: allTracks.filter { $0.availability == .available }.count,
                    missingTrackCount: allTracks.filter { $0.availability == .missing }.count,
                    recoverableTrackCount: allTracks.filter { $0.availability.isRecoverable }.count,
                    playlistCount: playlists.count,
                    linkedSourceCount: linkedSourceIDs.count,
                    artistCount: viewModel.runtimeArtists.count,
                    albumCount: viewModel.runtimeAlbums.count,
                    lyricsTrackCount: allTracks.filter { $0.ttmlLyricsFileName != nil || $0.lyricsFileName != nil }.count,
                    artworkTrackCount: allTracks.filter { $0.artworkFileName != nil }.count,
                    totalDurationSeconds: allTracks.reduce(0) { $0 + max(0, $1.duration) },
                    revision: revision
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryReportResult(
                        stats: stats,
                        tracks: trackPage,
                        playlists: playlistPage.map(queries.makePlaylistSummary),
                        offset: offset,
                        limit: limit,
                        nextOffset: end < allTracks.count ? end : nil,
                        playlistOffset: playlistOffset,
                        playlistLimit: playlistLimit,
                        nextPlaylistOffset: playlistEnd < playlists.count ? playlistEnd : nil,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.libraryBundleExport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let viewModel = session.libraryViewModel
                let libraryTracks = viewModel.allTracks
                let libraryPlaylists = viewModel.playlists
                let revision = queries.libraryTracksRevision(tracks: libraryTracks, playlists: libraryPlaylists)
                var failures: [String] = []
                let tracks: [LibraryBundleExportTrackInput] = libraryTracks.map { track in
                    let audioURL: URL?
                    do {
                        if case .referenced = track.mediaLocator {
                            audioURL = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session).url
                        } else {
                            audioURL = AutomationFileAccess.automationTrackFileURL(track, in: session)
                        }
                    } catch {
                        audioURL = nil
                    }
                    let existingAudio = audioURL.flatMap {
                        FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil
                    }
                    var trackFailures: [String] = []
                    if existingAudio == nil {
                        let failure = "\(track.id.uuidString): audio unavailable"
                        trackFailures.append(failure)
                        failures.append(failure)
                    }
                    func existingAsset(_ url: URL?) -> URL? {
                        guard let url,
                              FileManager.default.fileExists(atPath: url.path),
                              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
                        return url
                    }
                    return LibraryBundleExportTrackInput(
                        metadata: makeMetadataDocumentTrack(
                            track,
                            revision: viewModel.automationTrackRevision(for: track)
                        ),
                        audioURL: existingAudio,
                        artworkURL: existingAsset(track.existingArtworkURL()),
                        lyricsURL: existingAsset(track.resolvedLyricsURL()),
                        ttmlURL: existingAsset(track.resolvedTTMLURL()),
                        failures: trackFailures
                    )
                }
                let playlists = libraryPlaylists.map {
                    LibraryBundleExportPlaylistInput(
                        id: $0.id,
                        name: $0.name,
                        description: $0.userDescription,
                        trackIDs: $0.tracks.map(\.id)
                    )
                }
                let estimatedBytes = LibraryBundleExportService.estimatedBytes(for: tracks)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLibraryBundleExportResult(
                            libraryID: session.context.id,
                            dryRun: true,
                            trackCount: tracks.count,
                            estimatedBytes: estimatedBytes,
                            failures: failures,
                            message: "Preview only. The package will include path-free Track metadata, Playlist membership, and available audio, artwork and lyrics files."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "Export a complete Library bundle?",
                        details: .object([
                            "trackCount": .number(Double(tracks.count)),
                            "estimatedBytes": .number(Double(estimatedBytes)),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "导出完整资料库？",
                    message: "将把 \(tracks.count) 首歌曲及可用封面、歌词复制到新资料库包，估算 \(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let destinationURL = await AutomationInteraction.requestExportDirectory() else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let destination = destinationURL.standardizedFileURL
                let libraryRoot = session.context.rootURL.standardizedFileURL
                guard destination.path != libraryRoot.path,
                      !destination.path.hasPrefix(libraryRoot.path + "/") else {
                    throw AutomationParameterError.invalidValue("destination folder inside active Library")
                }
                let hasScopedAccess = destinationURL.startAccessingSecurityScopedResource()
                guard sessionAccess.activeSession(for: request) === session else {
                    if hasScopedAccess { destinationURL.stopAccessingSecurityScopedResource() }
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                guard let job = session.startAutomationLibraryBundleExport(
                        destinationDirectory: destinationURL,
                        destinationScopeStarted: hasScopedAccess,
                        revision: revision,
                        tracks: tracks,
                        playlists: playlists
                      ) else {
                    return sessionAccess.noActiveLibraryResponse(for: request)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryBundleExportResult(
                        libraryID: session.context.id,
                        dryRun: false,
                        applied: true,
                        confirmed: true,
                        trackCount: tracks.count,
                        estimatedBytes: estimatedBytes,
                        outputDirectory: destination.path,
                        job: AutomationJobProjection.makeJobSummary(job),
                        failures: failures,
                        message: "Library bundle export started. Poll the returned Job for progress and the completed package location."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.librarySelectionList:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let snapshots = try selectionStore.load(libraryID: session.context.id)
                let viewModel = session.libraryViewModel
                let usesPreferenceData = snapshots.contains { snapshot in
                    snapshot.filter.map(AutomationTrackPreferenceQuery.requiresHistoryRead(in:)) == true
                }
                let preferenceStatsByTrackID = usesPreferenceData
                    ? viewModel.preferenceStats(for: viewModel.allTracks.map(\.id))
                    : [:]
                let currentRevision = queries.libraryTracksRevision(
                    tracks: viewModel.allTracks,
                    playlists: viewModel.playlists,
                    preferenceStatsByTrackID: usesPreferenceData ? preferenceStatsByTrackID : nil
                )
                let selections = try snapshots.map {
                    try queries.resolveSelection($0, viewModel: viewModel).summary
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionListResult(
                        libraryID: session.context.id,
                        currentRevision: currentRevision,
                        selections: selections
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.librarySelectionCreate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let hasTrackIDs = parameters.values["trackIDs"] != nil
                let filter = parameters.values["filter"]
                guard hasTrackIDs != (filter != nil) else {
                    throw AutomationParameterError.invalidValue("trackIDs/filter")
                }
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    allowEmpty: true,
                    maximumCount: 10_000
                )
                let name = try parameters.string("name")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard requestedTrackIDs.count <= 10_000,
                      Set(requestedTrackIDs).count == requestedTrackIDs.count else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                if let name, (name.isEmpty || name.count > 120) {
                    throw AutomationParameterError.invalidValue("name")
                }
                let viewModel = session.libraryViewModel
                let usesPreferenceData = filter.map {
                    AutomationTrackPreferenceQuery.requiresHistoryRead(in: $0)
                } == true
                let preferenceStatsByTrackID = usesPreferenceData
                    ? viewModel.preferenceStats(for: viewModel.allTracks.map(\.id))
                    : [:]
                let currentRevision = queries.libraryTracksRevision(
                    tracks: viewModel.allTracks,
                    playlists: viewModel.playlists,
                    preferenceStatsByTrackID: usesPreferenceData ? preferenceStatsByTrackID : nil
                )
                if let expectedRevision, expectedRevision != currentRevision {
                    return AutomationResponseSupport.libraryTracksRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: currentRevision
                    )
                }
                if let filter {
                    try queries.validateTrackFilter(filter)
                }
                let selectedTrackIDs: [UUID]
                if let filter {
                    selectedTrackIDs = try viewModel.allTracks.compactMap { track in
                        try queries.matchesTrackFilter(
                            track,
                            filter: filter,
                            playlists: viewModel.playlists,
                            preferenceStatsByTrackID: preferenceStatsByTrackID
                        ) ? track.id : nil
                    }
                    guard selectedTrackIDs.count <= 10_000 else {
                        throw AutomationParameterError.outOfRange("filter.resultCount")
                    }
                } else {
                    selectedTrackIDs = requestedTrackIDs
                }
                let availableIDs = Set(viewModel.allTracks.map(\.id))
                let missingIDs = selectedTrackIDs.filter { !availableIDs.contains($0) }
                guard missingIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "A selection snapshot can contain only Tracks in the active Library.",
                            details: .object([
                                "missingTrackIDs": .array(missingIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let now = Date()
                let selectionID = UUID()
                let summary = AutomationSelectionSummary(
                    id: selectionID,
                    name: name?.isEmpty == true ? nil : name,
                    trackCount: selectedTrackIDs.count,
                    revision: queries.selectionRevision(
                        libraryID: session.context.id,
                        trackIDs: selectedTrackIDs
                    ),
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                    isDynamic: filter != nil
                )
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSelectionCreateResult(
                            libraryID: session.context.id,
                            selection: summary,
                            trackIDs: selectedTrackIDs,
                            applied: false,
                            dryRun: true
                        ),
                        for: request
                    )
                }
                var snapshots = try selectionStore.load(libraryID: session.context.id)
                snapshots.append(
                    AutomationSelectionSnapshot(
                        libraryID: session.context.id,
                        summary: summary,
                        trackIDs: filter == nil ? selectedTrackIDs : [],
                        filter: filter
                    )
                )
                try selectionStore.save(snapshots, libraryID: session.context.id, now: now)
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionCreateResult(
                        libraryID: session.context.id,
                        selection: summary,
                        trackIDs: selectedTrackIDs,
                        applied: true,
                        dryRun: false
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.librarySelectionGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let selectionID = try parameters.uuid("selectionID", required: true)!
                let snapshots = try selectionStore.load(libraryID: session.context.id)
                guard let snapshot = snapshots.first(where: { $0.summary.id == selectionID }) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The requested selection snapshot does not exist or has expired.",
                            details: .object(["selectionID": .string(selectionID.uuidString)])
                        )
                    )
                }
                let resolved = try queries.resolveSelection(snapshot, viewModel: session.libraryViewModel)
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionDetailResult(
                        libraryID: session.context.id,
                        selection: resolved.summary,
                        trackIDs: resolved.trackIDs,
                        filter: snapshot.filter
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.librarySelectionDelete:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let selectionID = try parameters.uuid("selectionID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                var snapshots = try selectionStore.load(libraryID: session.context.id)
                guard snapshots.contains(where: { $0.summary.id == selectionID }) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The requested selection snapshot does not exist or has expired.",
                            details: .object(["selectionID": .string(selectionID.uuidString)])
                        )
                    )
                }
                if !dryRun {
                    snapshots.removeAll { $0.summary.id == selectionID }
                    try selectionStore.save(snapshots, libraryID: session.context.id)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSelectionDeleteResult(
                        libraryID: session.context.id,
                        selectionID: selectionID,
                        deleted: !dryRun,
                        dryRun: dryRun
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.playlistList:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                AutomationPlaylistListResult(
                    playlists: session.libraryViewModel.playlists.map(queries.makePlaylistSummary)
                ),
                for: request
            )

        case AutomationMethod.sourceList:
            guard sessionAccess.activeSession(for: request) != nil else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let descriptors = try await appSession.referencedSources()
                let sources = descriptors.map { descriptor in
                    makeSourceSummary(descriptor)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceListResult(sources: sources),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to read referenced source state.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.sourceGet:
            guard sessionAccess.activeSession(for: request)?.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                guard let descriptor = try await appSession.referencedSources().first(where: { $0.id == sourceID }) else {
                    return .failure(for: request, error: AutomationError(code: .invalidRequest, message: "The requested Source does not exist.", details: .object(["sourceID": .string(sourceID.uuidString)])))
                }
                return AutomationResponseSupport.encodeResult(AutomationSourceGetResult(source: makeSourceSummary(descriptor)), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceConfigExport:
            guard let session = sessionAccess.activeSession(for: request), session.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard AutomationResponseSupport.isEmptyParameters(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let descriptors = try await appSession.referencedSources()
                let configurations = descriptors.map(makeSourceConfiguration)
                let document = AutomationSourceConfigurationDocument(
                    originLibraryID: session.context.id,
                    sources: configurations
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceConfigurationExportResult(
                        libraryID: session.context.id,
                        revision: sourceConfigurationRevision(
                            libraryID: session.context.id,
                            configurations: configurations
                        ),
                        document: document
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to export Source policy configuration.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.sourceConfigImport:
            guard let session = sessionAccess.activeSession(for: request), session.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                guard let rawDocument = parameters.values["document"] else {
                    throw AutomationParameterError.missing("document")
                }
                let documentData = try AutomationWireCoding.encoder().encode(rawDocument)
                let document = try AutomationWireCoding.decoder().decode(
                    AutomationSourceConfigurationDocument.self,
                    from: documentData
                )
                guard document.schemaVersion == 1,
                      document.sources.count <= 100,
                      Set(document.sources.map(\.sourceID)).count == document.sources.count else {
                    throw AutomationParameterError.invalidValue("document")
                }
                let sourceIDMapValues = try parameters.object("sourceIDMap") ?? [:]
                guard sourceIDMapValues.count <= 100 else {
                    throw AutomationParameterError.outOfRange("sourceIDMap")
                }
                var sourceIDMap: [UUID: UUID] = [:]
                for (rawSourceID, rawTargetID) in sourceIDMapValues {
                    guard let sourceID = UUID(uuidString: rawSourceID),
                          case .string(let targetIDString) = rawTargetID,
                          let targetID = UUID(uuidString: targetIDString) else {
                        throw AutomationParameterError.invalidValue("sourceIDMap")
                    }
                    sourceIDMap[sourceID] = targetID
                }
                let exportedIDs = Set(document.sources.map(\.sourceID))
                guard Set(sourceIDMap.keys).isSubset(of: exportedIDs) else {
                    throw AutomationParameterError.invalidValue("sourceIDMap")
                }
                if document.originLibraryID != session.context.id,
                   !document.sources.isEmpty,
                   Set(sourceIDMap.keys) != exportedIDs {
                    throw AutomationParameterError.invalidValue("sourceIDMap.crossLibraryRequired")
                }

                let currentSources = try await appSession.referencedSources()
                let currentByID = Dictionary(uniqueKeysWithValues: currentSources.map { ($0.id, $0) })
                let currentConfigurations = currentSources.map(makeSourceConfiguration)
                let currentRevision = sourceConfigurationRevision(
                    libraryID: session.context.id,
                    configurations: currentConfigurations
                )
                if let expectedRevision = try parameters.string("expectedRevision"),
                   expectedRevision != currentRevision {
                    return AutomationResponseSupport.revisionConflict(for: request, expected: expectedRevision, actual: currentRevision)
                }

                var targetConfigurations: [AutomationSourceConfiguration] = []
                var usedTargetIDs = Set<UUID>()
                var totalExcludedPathCount = 0
                for configuration in document.sources {
                    let displayName = configuration.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let targetID = sourceIDMap[configuration.sourceID] ?? configuration.sourceID
                    guard !displayName.isEmpty,
                          displayName.count <= 120,
                          let policy = ReferencedSourceMonitorPolicy(rawValue: configuration.monitorPolicy),
                          usedTargetIDs.insert(targetID).inserted,
                          let current = currentByID[targetID] else {
                        throw AutomationParameterError.invalidValue("document.sources")
                    }
                    guard Set(configuration.excludedRelativePaths).count == configuration.excludedRelativePaths.count,
                          configuration.excludedRelativePaths.allSatisfy({
                              TrackMediaLocator.isSafeRelativePath($0) && $0.count <= 1024
                          }) else {
                        throw AutomationParameterError.invalidValue("document.sources.excludedRelativePaths")
                    }
                    totalExcludedPathCount += configuration.excludedRelativePaths.count
                    guard totalExcludedPathCount <= 1_000,
                          current.mode == .directory || configuration.excludedRelativePaths.isEmpty else {
                        throw AutomationParameterError.invalidValue("document.sources")
                    }
                    targetConfigurations.append(AutomationSourceConfiguration(
                        sourceID: targetID,
                        displayName: displayName,
                        monitorPolicy: policy.rawValue,
                        excludedRelativePaths: configuration.excludedRelativePaths
                    ))
                }
                let changed = targetConfigurations.filter { configuration in
                    guard let current = currentByID[configuration.sourceID] else { return true }
                    return makeSourceConfiguration(current) != configuration
                }
                let unchangedIDs = targetConfigurations.map(\.sourceID).filter { targetID in
                    !changed.contains(where: { $0.sourceID == targetID })
                }
                var previewByID = Dictionary(
                    uniqueKeysWithValues: currentConfigurations.map { ($0.sourceID, $0) }
                )
                for configuration in targetConfigurations {
                    previewByID[configuration.sourceID] = configuration
                }
                let previewConfigurations = Array(previewByID.values)
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceConfigurationImportResult(
                            libraryID: session.context.id,
                            applied: false,
                            dryRun: true,
                            revision: currentRevision,
                            configurations: previewConfigurations,
                            unchangedSourceIDs: unchangedIDs
                        ),
                        for: request
                    )
                }
                guard !changed.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceConfigurationImportResult(
                            libraryID: session.context.id,
                            applied: false,
                            dryRun: false,
                            revision: currentRevision,
                            configurations: previewConfigurations,
                            unchangedSourceIDs: unchangedIDs
                        ),
                        for: request
                    )
                }
                guard try parameters.boolean("confirm", default: false) else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "Apply the Source policy changes from this configuration?",
                        details: .object([
                            "sourceCount": .number(Double(changed.count)),
                            "expectedRevision": .string(currentRevision),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "导入来源配置？",
                    message: "这会更新来源显示名、自动监听策略和排除路径；未授权路径与书签会留在本机。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }

                var failures: [AutomationSourceConfigurationFailure] = []
                for configuration in changed {
                    guard let current = currentByID[configuration.sourceID] else { continue }
                    do {
                        if current.displayName != configuration.displayName {
                            _ = try await appSession.renameReferencedSource(
                                id: configuration.sourceID,
                                displayName: configuration.displayName,
                                libraryID: session.context.id
                            )
                        }
                        if current.monitorPolicy.rawValue != configuration.monitorPolicy,
                           let policy = ReferencedSourceMonitorPolicy(rawValue: configuration.monitorPolicy) {
                            try await appSession.setReferencedSourceMonitorPolicy(
                                id: configuration.sourceID,
                                policy: policy,
                                libraryID: session.context.id
                            )
                        }
                        let previousExclusions = Set(current.excludedRelativePaths)
                        let nextExclusions = Set(configuration.excludedRelativePaths)
                        for path in previousExclusions.subtracting(nextExclusions).sorted() {
                            try await appSession.setReferencedSourceExcludedPath(
                                id: configuration.sourceID,
                                relativePath: path,
                                excluded: false,
                                libraryID: session.context.id
                            )
                        }
                        for path in nextExclusions.subtracting(previousExclusions).sorted() {
                            try await appSession.setReferencedSourceExcludedPath(
                                id: configuration.sourceID,
                                relativePath: path,
                                excluded: true,
                                libraryID: session.context.id
                            )
                        }
                    } catch {
                        failures.append(AutomationSourceConfigurationFailure(
                            sourceID: configuration.sourceID,
                            message: "The Source update stopped after an App persistence error."
                        ))
                    }
                }
                let finalSources = try await appSession.referencedSources()
                let finalConfigurations = finalSources.map(makeSourceConfiguration)
                let finalByID = Dictionary(uniqueKeysWithValues: finalSources.map { ($0.id, $0) })
                let updatedIDs = changed.compactMap { configuration -> UUID? in
                    guard let before = currentByID[configuration.sourceID],
                          let after = finalByID[configuration.sourceID],
                          makeSourceConfiguration(before) != makeSourceConfiguration(after) else {
                        return nil
                    }
                    return configuration.sourceID
                }
                let finalRevision = sourceConfigurationRevision(
                    libraryID: session.context.id,
                    configurations: finalConfigurations
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceConfigurationImportResult(
                        libraryID: session.context.id,
                        applied: !updatedIDs.isEmpty,
                        dryRun: false,
                        revision: finalRevision,
                        configurations: finalConfigurations,
                        updatedSourceIDs: updatedIDs,
                        unchangedSourceIDs: unchangedIDs,
                        failures: failures
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRename:
            guard let session = sessionAccess.activeSession(for: request), session.context.mode == .referenced else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(code: .serverUnavailable, message: "The player App is no longer available.", retryable: true)
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let displayName = try parameters.string("displayName", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty, displayName.count <= 120 else {
                    throw AutomationParameterError.invalidValue("displayName")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let current = try await appSession.referencedSources().first(where: { $0.id == sourceID }) else {
                    return .failure(for: request, error: AutomationError(code: .invalidRequest, message: "The requested Source does not exist.", details: .object(["sourceID": .string(sourceID.uuidString)])))
                }
                if dryRun {
                    var preview = current
                    preview.displayName = displayName
                    return AutomationResponseSupport.encodeResult(AutomationSourceRenameResult(source: makeSourceSummary(preview), applied: false, dryRun: true), for: request)
                }
                let renamed = try await appSession.renameReferencedSource(
                    id: sourceID,
                    displayName: displayName,
                    libraryID: session.context.id
                )
                return AutomationResponseSupport.encodeResult(AutomationSourceRenameResult(source: makeSourceSummary(renamed), applied: true, dryRun: false), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRefresh:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard session.context.mode == .referenced else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                let descriptors = try await appSession.referencedSources()
                guard let descriptor = descriptors.first(where: { $0.id == sourceID }) else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceRefreshResult(
                            sourceID: sourceID,
                            applied: false,
                            dryRun: true,
                            source: makeSourceSummary(descriptor),
                            libraryTrackCount: session.libraryViewModel.allTracks.count,
                            message: "Preview only. Set dryRun=false to scan and import new files."
                        ),
                        for: request
                    )
                }
                guard let job = appSession.startSourceRefreshJob(
                    sourceID: sourceID,
                    libraryID: session.context.id
                ) else {
                    throw AutomationParameterError.invalidValue("sourceID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceRefreshResult(
                        sourceID: sourceID,
                        applied: false,
                        dryRun: false,
                        source: makeSourceSummary(descriptor),
                        libraryTrackCount: session.libraryViewModel.allTracks.count,
                        issues: [],
                        completed: false,
                        job: AutomationJobProjection.makeJobSummary(job),
                        message: "Source refresh started as a Job; existing Tracks will be reused."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistCreate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let name = try parameters.string("name", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 255 else {
                    throw AutomationParameterError.outOfRange("name")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistCreate,
                            applied: false,
                            dryRun: true,
                            playlist: nil,
                            message: "Preview only. Set dryRun=false and confirm=true to create the playlist."
                        ),
                        for: request
                    )
                }
                do {
                    let playlist = try await session.libraryViewModel.createPlaylistForAutomation(name: name)
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistCreate,
                            applied: true,
                            dryRun: false,
                            playlist: queries.makePlaylistSummary(playlist),
                            message: "Playlist created."
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.mutationFailure(for: request, error: error)
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistAddTracks:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    required: true,
                    maximumCount: 10_000
                )
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let trackByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingTrackIDs = requestedTrackIDs.filter { trackByID[$0] == nil }
                guard missingTrackIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "One or more requested tracks are not in the active library.",
                            details: .object([
                                "missingTrackIDs": .array(missingTrackIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let existingIDs = Set(playlist.tracks.map(\.id))
                let changedTrackIDs = requestedTrackIDs.filter { !existingIDs.contains($0) }
                let skippedTrackIDs = requestedTrackIDs.filter { existingIDs.contains($0) }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Preview only. Set dryRun=false and confirm=true to apply."
                        ),
                        for: request
                    )
                }
                guard !changedTrackIDs.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: false,
                            dryRun: false,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: [],
                            skippedTrackIDs: skippedTrackIDs,
                            message: "No playlist membership changes were needed."
                        ),
                        for: request
                    )
                }
                do {
                    try await session.libraryViewModel.addTracksToPlaylistForAutomation(
                        changedTrackIDs.compactMap { trackByID[$0] },
                        playlist: playlist,
                        expectedRevision: expectedRevision
                    )
                    let updatedPlaylist = session.libraryViewModel.playlists.first {
                        $0.id == playlistID
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: true,
                            dryRun: false,
                            playlist: updatedPlaylist.map(queries.makePlaylistSummary),
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Playlist membership updated; library Tracks were reused."
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.mutationFailure(for: request, error: error)
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistAddSelection:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let selectionID = try parameters.uuid("selectionID", required: true)!
                let expectedRevision = try parameters.string("expectedRevision")
                let expectedSelectionRevision = try parameters.string("expectedSelectionRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let snapshots = try selectionStore.load(libraryID: session.context.id)
                guard let snapshot = snapshots.first(where: { $0.summary.id == selectionID }) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The requested selection snapshot does not exist or has expired.",
                            details: .object(["selectionID": .string(selectionID.uuidString)])
                        )
                    )
                }
                let resolved = try queries.resolveSelection(snapshot, viewModel: session.libraryViewModel)
                if let expectedSelectionRevision,
                   expectedSelectionRevision != resolved.summary.revision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The saved selection changed after it was read.",
                            details: .object([
                                "expectedRevision": .string(expectedSelectionRevision),
                                "actualRevision": .string(resolved.summary.revision)
                            ])
                        )
                    )
                }
                let availableIDs = Set(session.libraryViewModel.allTracks.map(\.id))
                let missingIDs = resolved.trackIDs.filter { !availableIDs.contains($0) }
                guard missingIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "Some Tracks in the saved selection no longer exist in the active Library.",
                            details: .object([
                                "selectionID": .string(selectionID.uuidString),
                                "missingTrackIDs": .array(missingIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                var values: [String: AutomationJSONValue] = [
                    "playlistID": .string(playlistID.uuidString),
                    "trackIDs": .array(resolved.trackIDs.map { .string($0.uuidString) }),
                    "dryRun": .boolean(dryRun)
                ]
                if let expectedRevision {
                    values["expectedRevision"] = .string(expectedRevision)
                }
                let nestedRequest = AutomationRequest(
                    method: AutomationMethod.playlistAddTracks,
                    params: .object(values),
                    context: request.context,
                    requestID: request.requestID,
                    protocolVersion: request.protocolVersion
                )
                let nestedResponse = await execute(nestedRequest)
                if let error = nestedResponse.error {
                    return .failure(for: request, error: error)
                }
                guard let nestedResult = nestedResponse.result else {
                    throw AutomationParameterError.invalidValue("playlistMutationResult")
                }
                let resultData = try AutomationWireCoding.encoder().encode(nestedResult)
                let mutation = try AutomationWireCoding.decoder().decode(
                    AutomationPlaylistMutationResult.self,
                    from: resultData
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistSelectionMutationResult(
                        selectionID: selectionID,
                        selectionRevision: resolved.summary.revision,
                        mutation: mutation
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.selectionStoreFailure(for: request, error: error)
            }

        case AutomationMethod.playlistRemoveTracks:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    required: true,
                    maximumCount: 10_000
                )
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let trackByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingTrackIDs = requestedTrackIDs.filter { trackByID[$0] == nil }
                guard missingTrackIDs.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "One or more requested tracks are not in the active library.",
                            details: .object([
                                "missingTrackIDs": .array(missingTrackIDs.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let existingIDs = Set(playlist.tracks.map(\.id))
                let changedTrackIDs = requestedTrackIDs.filter { existingIDs.contains($0) }
                let skippedTrackIDs = requestedTrackIDs.filter { !existingIDs.contains($0) }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Preview only. Set dryRun=false and confirm=true to apply."
                        ),
                        for: request
                    )
                }
                guard !changedTrackIDs.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: false,
                            dryRun: false,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: [],
                            skippedTrackIDs: skippedTrackIDs,
                            message: "No playlist membership changes were needed."
                        ),
                        for: request
                    )
                }
                do {
                    try await session.libraryViewModel.removeTracksFromPlaylistForAutomation(
                        changedTrackIDs.compactMap { trackByID[$0] },
                        playlist: playlist,
                        expectedRevision: expectedRevision
                    )
                    let updatedPlaylist = session.libraryViewModel.playlists.first {
                        $0.id == playlistID
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: true,
                            dryRun: false,
                            playlist: updatedPlaylist.map(queries.makePlaylistSummary),
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Playlist membership updated; library Tracks and files were retained."
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.mutationFailure(for: request, error: error)
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistDetailResult(
                        playlist: queries.makePlaylistSummary(playlist),
                        trackIDs: playlist.tracks.map(\.id)
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistDiff:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistIDs = try parameters.uuidArray("playlistIDs", required: true)
                guard (2...100).contains(playlistIDs.count), Set(playlistIDs).count == playlistIDs.count else {
                    throw AutomationParameterError.invalidValue("playlistIDs")
                }
                let operation = try parameters.string("operation", required: true)!
                guard ["union", "intersection", "difference"].contains(operation) else {
                    throw AutomationParameterError.invalidValue("operation")
                }
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                let playlistsByID = Dictionary(uniqueKeysWithValues: session.libraryViewModel.playlists.map { ($0.id, $0) })
                guard playlistIDs.allSatisfy({ playlistsByID[$0] != nil }) else {
                    throw AutomationParameterError.missingResource("playlistIDs")
                }
                let orderedMemberships = playlistIDs.map { id in playlistsByID[id]!.tracks.map(\.id) }
                let membershipSets = orderedMemberships.map(Set.init)
                let resultIDs: [UUID]
                switch operation {
                case "union":
                    var seen = Set<UUID>()
                    resultIDs = orderedMemberships.flatMap { $0 }.filter { seen.insert($0).inserted }
                case "intersection":
                    resultIDs = orderedMemberships[0].filter { id in membershipSets.dropFirst().allSatisfy { $0.contains(id) } }
                default:
                    let excluded = membershipSets.dropFirst().reduce(into: Set<UUID>()) { $0.formUnion($1) }
                    resultIDs = orderedMemberships[0].filter { !excluded.contains($0) }
                }
                let summaries = playlistIDs.compactMap { id in playlistsByID[id].map(queries.makePlaylistSummary) }
                let revision = "v1-" + summaries.map(\.revision).joined(separator: ":")
                let start = min(offset, resultIDs.count)
                let page = Array(resultIDs[start..<min(start + limit, resultIDs.count)])
                return AutomationResponseSupport.encodeResult(AutomationPlaylistDiffResult(
                    operation: operation, inputPlaylistIDs: playlistIDs,
                    trackIDs: page, total: resultIDs.count, revision: revision
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistExport:
            guard let session = sessionAccess.activeSession(for: request) else { return sessionAccess.noActiveLibraryResponse(for: request) }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let includePaths = try parameters.boolean("includePaths", default: false)
                guard !includePaths || grantedScopes().contains(.filesRead) else {
                    return .failure(for: request, error: AutomationError(code: .authorizationRequired, message: "Absolute file paths require the files.read scope."))
                }
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                var rows = ["#EXTM3U"]
                var pathCount = 0
                for track in playlist.tracks {
                    let duration = track.duration.isFinite ? max(0, Int(track.duration)) : 0
                    let label = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " - ")
                    rows.append("#EXTINF:\(duration),\(label)")
                    if includePaths, let fileURL = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                        rows.append(fileURL.absoluteString)
                        pathCount += 1
                    } else {
                        rows.append("player-track://\(track.id.uuidString)")
                    }
                }
                return AutomationResponseSupport.encodeResult(AutomationPlaylistExportResult(
                    playlist: queries.makePlaylistSummary(playlist),
                    m3uText: rows.joined(separator: "\n") + "\n",
                    exportedTrackCount: playlist.tracks.count,
                    filePathEntryCount: pathCount
                ), for: request)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistImport:
            guard let session = sessionAccess.activeSession(for: request) else { return sessionAccess.noActiveLibraryResponse(for: request) }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let m3uText = try parameters.string("m3uText", required: true)!
                guard m3uText.utf8.count <= 5_000_000 else { throw AutomationParameterError.outOfRange("m3uText") }
                let operation = try parameters.string("operation") ?? "append"
                guard operation == "append" || operation == "replace" else { throw AutomationParameterError.invalidValue("operation") }
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(for: request, expected: expectedRevision, actual: summary.revision)
                }
                let tracks = session.libraryViewModel.allTracks
                let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
                var trackIDByPath: [String: UUID] = [:]
                var managedIDByRelativePath: [String: UUID] = [:]
                for track in tracks {
                    if let fileURL = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                        let path = fileURL.standardizedFileURL.path
                        if trackIDByPath[path] == nil { trackIDByPath[path] = track.id }
                    }
                    if let relativePath = track.mediaLocator.managedLibraryRelativePath {
                        managedIDByRelativePath[relativePath] = track.id
                    }
                }
                let entries = m3uText.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                guard entries.count <= 10_000 else { throw AutomationParameterError.outOfRange("m3uText") }
                var matchedTrackIDs: [UUID] = []
                var unmatchedEntries: [String] = []
                for entry in entries {
                    if let url = URL(string: entry), url.scheme == "player-track",
                       let id = UUID(uuidString: url.host ?? url.path), tracksByID[id] != nil {
                        matchedTrackIDs.append(id)
                        continue
                    }
                    let entryURL = URL(string: entry).flatMap { $0.isFileURL ? $0 : nil }
                    let path = entryURL?.path ?? (entry.removingPercentEncoding ?? entry)
                    if let id = trackIDByPath[URL(fileURLWithPath: path).standardizedFileURL.path]
                        ?? managedIDByRelativePath[path] {
                        matchedTrackIDs.append(id)
                    } else {
                        unmatchedEntries.append(entry)
                    }
                }
                var seen = Set<UUID>()
                let uniqueMatched = matchedTrackIDs.filter { seen.insert($0).inserted }
                let targetIDs: [UUID]
                if operation == "append" {
                    var allSeen = Set<UUID>()
                    targetIDs = (playlist.tracks.map(\.id) + uniqueMatched).filter { allSeen.insert($0).inserted }
                } else {
                    targetIDs = uniqueMatched
                }
                guard dryRun || targetIDs != playlist.tracks.map(\.id) else {
                    return AutomationResponseSupport.encodeResult(AutomationPlaylistImportResult(
                        playlist: summary, operation: operation, applied: false, dryRun: false,
                        matchedTrackIDs: matchedTrackIDs, unmatchedEntries: unmatchedEntries
                    ), for: request)
                }
                if !dryRun {
                    try await session.libraryViewModel.replacePlaylistTracksForAutomation(
                        targetIDs.compactMap { tracksByID[$0] }, playlist: playlist,
                        expectedRevision: expectedRevision
                    )
                }
                let updatedPlaylist = session.libraryViewModel.playlists.first { $0.id == playlistID } ?? playlist
                return AutomationResponseSupport.encodeResult(AutomationPlaylistImportResult(
                    playlist: queries.makePlaylistSummary(dryRun ? playlist : updatedPlaylist),
                    operation: operation,
                    applied: !dryRun,
                    dryRun: dryRun,
                    matchedTrackIDs: matchedTrackIDs,
                    unmatchedEntries: unmatchedEntries
                ), for: request)
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistRename:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let name = try parameters.string("name", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 255 else {
                    throw AutomationParameterError.outOfRange("name")
                }
                let description = try parameters.string("description")
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRename,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            message: "Preview only. Set dryRun=false to rename the playlist."
                        ),
                        for: request
                    )
                }
                let updated = try await session.libraryViewModel.renamePlaylistForAutomation(
                    playlist,
                    name: name,
                    description: description,
                    expectedRevision: expectedRevision
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: AutomationMethod.playlistRename,
                        applied: true,
                        dryRun: false,
                        playlist: queries.makePlaylistSummary(updated),
                        message: "Playlist renamed."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistDelete:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("id", required: true)!
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("id")
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistDelete,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            message: "Preview only. This removes the playlist membership but retains Tracks and files."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "删除播放列表需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "playlistID": .string(playlistID.uuidString),
                            "trackCount": .number(Double(summary.trackCount))
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "删除播放列表？",
                    message: "要删除“\(summary.name)”及其 \(summary.trackCount) 条歌曲关系吗？歌曲和音频文件会保留。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                try await session.libraryViewModel.deletePlaylistForAutomation(
                    playlist,
                    expectedRevision: expectedRevision
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: AutomationMethod.playlistDelete,
                        applied: true,
                        dryRun: false,
                        playlist: nil,
                        message: "Playlist deleted; library Tracks and files were retained."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistReplaceTracks, AutomationMethod.playlistReorder:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    required: true,
                    allowEmpty: true
                )
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let currentIDs = playlist.tracks.map(\.id)
                if request.method == AutomationMethod.playlistReorder,
                   Set(requestedTrackIDs) != Set(currentIDs) {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let trackByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missing = requestedTrackIDs.filter { trackByID[$0] == nil }
                guard missing.isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "One or more requested Tracks are not in the active library.",
                            details: .object([
                                "missingTrackIDs": .array(missing.map { .string($0.uuidString) })
                            ])
                        )
                    )
                }
                let summary = queries.makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return AutomationResponseSupport.revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                let operation = request.method
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: operation,
                            applied: false,
                            dryRun: true,
                            playlist: summary,
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: requestedTrackIDs,
                            message: "Preview only. Set dryRun=false to apply the ordered membership."
                        ),
                        for: request
                    )
                }
                try await session.libraryViewModel.replacePlaylistTracksForAutomation(
                    requestedTrackIDs.compactMap { trackByID[$0] },
                    playlist: playlist,
                    expectedRevision: expectedRevision
                )
                let updated = session.libraryViewModel.playlists.first { $0.id == playlistID }
                return AutomationResponseSupport.encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: operation,
                        applied: true,
                        dryRun: false,
                        playlist: updated.map(queries.makePlaylistSummary),
                        requestedTrackIDs: requestedTrackIDs,
                        changedTrackIDs: requestedTrackIDs,
                        message: "Playlist membership order updated; no files were imported or deleted."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.sourceCreate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                guard session.context.mode == .referenced else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let parameters = try AutomationParameters(request)
                let modeRaw = try parameters.string("mode") ?? ReferencedSourceMode.directory.rawValue
                guard let mode = ReferencedSourceMode(rawValue: modeRaw) else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let requestedPath = try parameters.string("path")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let playlistID = try parameters.uuid("playlistID")
                let dryRun = try parameters.boolean("dryRun", default: false)
                if let playlistID,
                   !session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            selectedPath: requestedPath,
                            message: "Preview only. The App will request a security-scoped folder/file selection when needed."
                        ),
                        for: request
                    )
                }

                let descriptors = try await appSession.referencedSources()
                let normalizedRequestedPath = requestedPath.map(AutomationInteraction.expandPath(_:))
                if let requestedPath = normalizedRequestedPath,
                   let existing = descriptors.first(where: { descriptor in
                       descriptor.mode == mode
                           && URL(fileURLWithPath: descriptor.lastKnownPath)
                               .standardizedFileURL.path == requestedPath
                   }) {
                    if let playlistID {
                        try await appSession.bindReferencedSource(
                            id: existing.id,
                            to: playlistID,
                            libraryID: session.context.id
                        )
                    }
                    let refreshed = try await appSession.referencedSources()
                        .first(where: { $0.id == existing.id }) ?? existing
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            playlistBindingApplied: playlistID != nil,
                            source: makeSourceSummary(refreshed),
                            selectedPath: refreshed.lastKnownPath,
                            message: playlistID == nil
                                ? "The requested Source already exists; no duplicate Source was created."
                                : "The requested Source already exists; no duplicate Source was created and the Playlist binding was applied."
                        ),
                        for: request
                    )
                }

                let inheritedAuthorization: Bool = {
                    guard let requestedPath = normalizedRequestedPath else { return false }
                    let requestedURL = URL(fileURLWithPath: requestedPath, isDirectory: mode == .directory)
                    guard FileManager.default.fileExists(atPath: requestedURL.path) else { return false }
                    let isDirectory = (try? requestedURL.resourceValues(
                        forKeys: [.isDirectoryKey]
                    ).isDirectory) == true
                    guard isDirectory == (mode == .directory) else { return false }
                    guard let sourceScope = session.referencedSourceScope else { return false }
                    return sourceScope.authorizedDirectorySourceID(containing: requestedURL) != nil
                        || sourceScope.isTrustedAutomationPath(requestedURL)
                }()
                let selectedURL: URL?
                if inheritedAuthorization, let normalizedRequestedPath {
                    selectedURL = URL(
                        fileURLWithPath: normalizedRequestedPath,
                        isDirectory: mode == .directory
                    )
                } else {
                    selectedURL = try await AutomationInteraction.requestSourceURL(
                        mode: mode,
                        requestedPath: normalizedRequestedPath
                    )
                }
                guard let selectedURL else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess || inheritedAuthorization else {
                    let path = selectedURL.path
                    selection.release()
                    return AutomationResponseSupport.permissionDenied(
                        for: request,
                        path: path
                    )
                }
                guard let job = appSession.startSourceImportJob(
                    selection: selection,
                    playlistID: playlistID,
                    libraryID: session.context.id
                ) else {
                    selection.release()
                    throw AutomationParameterError.invalidValue("path")
                }
                selection.release()
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: false,
                        completed: false,
                        selectedPath: selectedURL.path,
                        job: AutomationJobProjection.makeJobSummary(job),
                        message: playlistID == nil
                            ? "Source authorization accepted; import/reconcile started as a Job."
                            : "Source authorization accepted; import/reconcile and Playlist binding started as a Job."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceBindPlaylist:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let relativePath = try parameters.string("relativePath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard session.libraryViewModel.playlists.contains(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                if let relativePath, !relativePath.isEmpty,
                   !TrackMediaLocator.isSafeRelativePath(relativePath) {
                    throw AutomationParameterError.invalidValue("relativePath")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. The Source-to-Playlist binding will be persisted."
                        ),
                        for: request
                    )
                }
                try await appSession.bindReferencedSource(
                    id: sourceID,
                    to: playlistID,
                    relativePath: relativePath,
                    libraryID: session.context.id
                )
                let updated = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: "Source-to-Playlist binding updated."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceSetExcludedPath:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let relativePath = try parameters.string("relativePath", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let excluded = try parameters.boolean("excluded", default: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard !relativePath.isEmpty,
                      TrackMediaLocator.isSafeRelativePath(relativePath) else {
                    throw AutomationParameterError.invalidValue("relativePath")
                }
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                guard descriptor.mode == .directory else {
                    throw AutomationParameterError.invalidValue("sourceID")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: excluded
                                ? "Preview only. The relative path will be excluded from future scans; existing Track authority is preserved."
                                : "Preview only. The relative path will be included in future scans."
                        ),
                        for: request
                    )
                }
                try await appSession.setReferencedSourceExcludedPath(
                    id: sourceID,
                    relativePath: relativePath,
                    excluded: excluded,
                    libraryID: session.context.id
                )
                let updated = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: excluded
                            ? "Source path excluded; existing Tracks were retained."
                            : "Source path included and the Source was reconciled."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceSetMonitorPolicy:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("sourceID", required: true)!
                let rawPolicy = try parameters.string("policy", required: true)!
                guard let policy = ReferencedSourceMonitorPolicy(rawValue: rawPolicy),
                      policy != .inherit else {
                    throw AutomationParameterError.invalidValue("policy")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("sourceID")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. Automatic monitoring will be \(policy == .on ? "enabled" : "disabled"); explicit source.refresh remains available."
                        ),
                        for: request
                    )
                }
                try await appSession.setReferencedSourceMonitorPolicy(
                    id: sourceID,
                    policy: policy,
                    libraryID: session.context.id
                )
                let updated = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: policy == .on
                            ? "Automatic Source monitoring enabled."
                            : "Automatic Source monitoring disabled; manual refresh remains available."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRemove:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let sourceID = try parameters.uuid("id", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let descriptor = try await appSession.referencedSources()
                    .first(where: { $0.id == sourceID })
                guard let descriptor else {
                    throw AutomationParameterError.missingResource("id")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. Removing the Source authority retains user files; Tracks with no other source become missing."
                        ),
                        for: request
                    )
                }
                let isTrusted = session.referencedSourceScope?.isTrustedAutomationPath(
                    URL(fileURLWithPath: descriptor.lastKnownPath)
                ) == true
                if !isTrusted {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "移除来源需要 confirm=true，并由播放器在前台确认。",
                            details: .object(["sourceID": .string(sourceID.uuidString)])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "移除来源？",
                        message: "要从当前资料库移除“\(descriptor.displayName)”吗？原文件不会删除，相关歌曲可能暂时不可用。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }
                try await appSession.removeReferencedSource(
                    id: sourceID,
                    libraryID: session.context.id
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        selectedPath: descriptor.lastKnownPath,
                        message: "Source removed; physical files were retained."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesInspect:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesInspect,
                        applied: false,
                        dryRun: true,
                        files: tracks.map { AutomationFileAccess.makeFileSummary($0) },
                        message: "Physical file state inspected; no file system mutation was applied."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesReveal:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                guard trackIDs.count <= 50 else {
                    throw AutomationParameterError.outOfRange("trackIDs")
                }
                let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                let dryRun = try parameters.boolean("dryRun", default: false)
                var files: [AutomationFileSummary] = []
                var urls: [URL] = []
                var failures: [String] = []
                for track in tracks {
                    do {
                        let url: URL
                        if case .referenced = track.mediaLocator {
                            url = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session).url
                        } else if let managedURL = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                            url = managedURL
                        } else {
                            throw AutomationFileOperationError.fileUnavailable(track.id)
                        }
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            throw AutomationFileOperationError.fileUnavailable(track.id)
                        }
                        urls.append(url)
                        files.append(AutomationFileAccess.makeFileSummary(track, pathOverride: url.path, existsOverride: true))
                    } catch {
                        failures.append("\(track.id.uuidString): \(error.localizedDescription)")
                    }
                }
                if !dryRun, !urls.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesReveal,
                        applied: !dryRun && !urls.isEmpty,
                        dryRun: dryRun,
                        affectedTrackIDs: files.map(\.trackID),
                        files: files,
                        failures: failures,
                        message: dryRun
                            ? "Preview only. Authorized existing files would be revealed in Finder."
                            : "Authorized existing files were revealed in Finder."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesExport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                guard trackIDs.count <= 500 else {
                    throw AutomationParameterError.outOfRange("trackIDs")
                }
                let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                guard let destinationURL = await AutomationInteraction.requestExportDirectory() else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                let hasScopedAccess = destinationURL.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { destinationURL.stopAccessingSecurityScopedResource() }
                }
                let destination = destinationURL.standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw AutomationParameterError.invalidValue("destination folder")
                }
                let libraryRoot = session.context.rootURL.standardizedFileURL
                guard destination.path != libraryRoot.path,
                      !destination.path.hasPrefix(libraryRoot.path + "/") else {
                    throw AutomationParameterError.invalidValue("destination folder inside active Library")
                }

                var files: [AutomationFileSummary] = []
                var failures: [String] = []
                for track in tracks {
                    do {
                        let source: URL
                        if case .referenced = track.mediaLocator {
                            source = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session).url
                        } else if let managed = AutomationFileAccess.automationTrackFileURL(track, in: session) {
                            source = managed
                        } else {
                            throw AutomationFileOperationError.fileUnavailable(track.id)
                        }
                        guard FileManager.default.fileExists(atPath: source.path) else {
                            throw AutomationFileOperationError.fileUnavailable(track.id)
                        }
                        let output = uniqueExportURL(for: source.lastPathComponent, in: destination)
                        try FileManager.default.copyItem(at: source, to: output)
                        files.append(AutomationFileAccess.makeFileSummary(track, pathOverride: output.path, existsOverride: true))
                    } catch {
                        failures.append("\(track.id.uuidString): \(error.localizedDescription)")
                    }
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesExport,
                        applied: !files.isEmpty,
                        dryRun: false,
                        affectedTrackIDs: files.map(\.trackID),
                        files: files,
                        failures: failures,
                        message: "Audio files were copied to the App-authorized destination; Library originals were retained."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesRename, AutomationMethod.filesMove:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let operations = try parameters.objectArray("operations", required: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let plans = try makeFilePlans(
                    method: request.method,
                    operations: operations,
                    session: session
                )
                let files = plans.map { AutomationFileAccess.makeFileSummary($0.track) }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationFileOperationResult(
                            operation: request.method,
                            applied: false,
                            dryRun: true,
                            affectedTrackIDs: plans.map(\.trackID),
                            files: files,
                            message: "Preview only. Set dryRun=false to apply the planned file operation."
                        ),
                        for: request
                    )
                }

                let isTrusted = plans.allSatisfy { plan in
                    guard let sourceScope = session.referencedSourceScope else { return false }
                    return sourceScope.isTrustedAutomationPath(plan.from)
                        && (plan.destination.map { sourceScope.isTrustedAutomationPath($0) } ?? true)
                }
                if plans.count > 1 && !isTrusted {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "批量重命名或移动文件需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(request.method),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: request.method == AutomationMethod.filesRename
                            ? "重命名多个音乐文件？"
                            : "移动多个音乐文件？",
                        message: "这会改变 \(plans.count) 个音乐文件在磁盘上的位置，播放器随后会重新扫描相关来源。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }

                try await session.runLibraryOperation(as: .other) {
                    try self.applyFilePlans(plans)
                }
                let sourceIDs = Set(plans.flatMap(\.sourceIDs))
                let jobs = sourceRefreshJobs(
                    sourceIDs: sourceIDs,
                    appSession: appSession,
                    libraryID: session.context.id
                )
                let appliedFiles = plans.map { plan in
                    AutomationFileAccess.makeFileSummary(
                        plan.track,
                        pathOverride: plan.destination?.path,
                        existsOverride: plan.destination.map { FileManager.default.fileExists(atPath: $0.path) }
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: request.method,
                        applied: true,
                        dryRun: false,
                        confirmed: plans.count > 1 && (confirm || isTrusted),
                        affectedTrackIDs: plans.map(\.trackID),
                        files: appliedFiles,
                        jobs: jobs,
                        message: "File operation applied. Source reconciliation Jobs were started to update Track locations."
                    ),
                    for: request
                )
            } catch let error as AutomationFileOperationError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "The file operation failed; no further file mutation was attempted.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.filesDelete:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let plans = try makeFileDeletePlans(trackIDs: trackIDs, session: session)
                let files = plans.map { AutomationFileAccess.makeFileSummary($0.track) }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationFileOperationResult(
                            operation: AutomationMethod.filesDelete,
                            applied: false,
                            dryRun: true,
                            affectedTrackIDs: plans.map(\.trackID),
                            files: files,
                            message: "Preview only. Files will be moved to the macOS Trash after confirm=true and foreground confirmation. Tracks and Playlist membership will be preserved."
                        ),
                        for: request
                    )
                }
                let isTrusted = plans.allSatisfy { plan in
                    session.referencedSourceScope?.isTrustedAutomationPath(plan.from) == true
                }
                if !isTrusted {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "将音乐文件移到废纸篓需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.filesDelete),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "将音乐文件移到废纸篓？",
                        message: "要将 \(plans.count) 个音乐文件移到 macOS 废纸篓吗？歌曲、元数据、播放记录和播放列表关系会保留。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }

                let outcome = try await session.runLibraryOperation(as: .other) {
                    var succeeded: [UUID] = []
                    var failures: [String] = []
                    for plan in plans {
                        do {
                            try await MacOSLibraryRecycler().recycle(plan.from)
                            succeeded.append(plan.trackID)
                        } catch {
                            failures.append("\(plan.trackID.uuidString): \(error.localizedDescription)")
                        }
                    }
                    return (succeeded, failures)
                }
                let successfulPlans = plans.filter { outcome.0.contains($0.trackID) }
                let jobs = sourceRefreshJobs(
                    sourceIDs: Set(successfulPlans.flatMap(\.sourceIDs)),
                    appSession: appSession,
                    libraryID: session.context.id
                )
                let appliedFiles = plans.map { plan in
                    AutomationFileAccess.makeFileSummary(
                        plan.track,
                        existsOverride: outcome.0.contains(plan.trackID) ? false : nil
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesDelete,
                        applied: !outcome.0.isEmpty,
                        dryRun: false,
                        confirmed: confirm || isTrusted,
                        affectedTrackIDs: outcome.0,
                        files: appliedFiles,
                        jobs: jobs,
                        failures: outcome.1,
                        message: "Selected files were moved to the macOS Trash; the App started Source refresh Jobs to mark them missing without deleting Library records."
                    ),
                    for: request
                )
            } catch let error as AutomationFileOperationError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "The file deletion operation failed.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

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

        case AutomationMethod.artworkSearch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 5)
                guard (1...5).contains(limit) else {
                    throw AutomationParameterError.outOfRange("limit")
                }
                let target = try resolveArtworkTarget(
                    from: parameters,
                    session: session,
                    allowPlaylist: false
                )
                let targetRevision = artworkRevision(for: target, session: session)
                let candidates: [CoverCandidate]
                let queryTitle: String?
                let queryArtist: String?
                let queryAlbum: String?
                let trackID: UUID?
                let artistID: UUID?
                let albumKey: String?
                switch target {
                case .track(let track):
                    candidates = await session.searchArtworkCandidatesForAutomation(
                        trackID: track.id,
                        limit: limit
                    )
                    queryTitle = track.title
                    queryArtist = track.artist.isEmpty ? nil : track.artist
                    queryAlbum = track.album.isEmpty ? nil : track.album
                    trackID = track.id
                    artistID = nil
                    albumKey = nil
                case .artist(let entry):
                    candidates = await session.searchArtistArtworkCandidatesForAutomation(
                        artistID: entry.id,
                        limit: limit
                    )
                    queryTitle = nil
                    queryArtist = entry.displayName
                    queryAlbum = nil
                    trackID = nil
                    artistID = entry.id
                    albumKey = nil
                case .album(let entry):
                    candidates = await session.searchAlbumArtworkCandidatesForAutomation(
                        albumKey: entry.canonicalKey,
                        limit: limit
                    )
                    queryTitle = nil
                    queryArtist = entry.primaryArtistDisplayName.isEmpty
                        ? nil
                        : entry.primaryArtistDisplayName
                    queryAlbum = entry.displayTitle
                    trackID = nil
                    artistID = nil
                    albumKey = entry.canonicalKey
                case .playlist:
                    throw AutomationParameterError.invalidValue("playlistID")
                }
                let rankedCandidates = candidates.map {
                    cacheArtworkCandidate(
                        $0,
                        target: target,
                        revision: targetRevision,
                        session: session,
                        queryTitle: queryTitle,
                        queryArtist: queryArtist,
                        queryAlbum: queryAlbum
                    )
                }.sorted { lhs, rhs in
                    let leftQuality = lhs.matchQuality ?? 0
                    let rightQuality = rhs.matchQuality ?? 0
                    if leftQuality != rightQuality { return leftQuality > rightQuality }
                    if lhs.resolution != rhs.resolution { return lhs.resolution > rhs.resolution }
                    return lhs.id < rhs.id
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationArtworkSearchResult(
                        targetType: target.type,
                        trackID: trackID,
                        artistID: artistID,
                        albumKey: albumKey,
                        queryTitle: queryTitle,
                        queryArtist: queryArtist,
                        queryAlbum: queryAlbum,
                        candidates: rankedCandidates,
                        message: rankedCandidates.isEmpty
                            ? "No artwork candidates were returned by the configured providers."
                            : "Artwork candidates include provider-neutral metadata/image matchQuality alongside each provider's own confidence. Results are ordered by matchQuality, then resolution and stable ID. Each candidate has a Library- and artwork-revision-bound ID for preview and direct apply. Inline imageBase64 remains available for Agent review."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkApplyCandidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let candidateID = try parameters.string("candidateID", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidateID.isEmpty else {
                    throw AutomationParameterError.invalidValue("candidateID")
                }
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                pruneArtworkCandidateCache(now: Date())
                guard let cached = artworkCandidateCache[candidateID],
                      cached.expiresAt > Date(),
                      cached.libraryID == session.context.id else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The artwork candidate is unknown, expired, or belongs to another Library. Search artwork again to obtain a current candidate ID.",
                            details: .object(["candidateID": .string(candidateID)])
                        )
                    )
                }
                if let expectedRevision, expectedRevision != cached.revision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The supplied revision does not match the revision captured when this artwork candidate was searched.",
                            details: .object([
                                "expectedRevision": .string(expectedRevision),
                                "candidateRevision": .string(cached.revision)
                            ])
                        )
                    )
                }

                var resolvedValues: [String: AutomationJSONValue] = [
                    "imageBase64": .string(cached.candidate.imageBase64),
                    "expectedRevision": .string(cached.revision),
                    "dryRun": .boolean(dryRun),
                    "confirm": .boolean(confirm)
                ]
                if let trackID = cached.trackID {
                    resolvedValues["trackID"] = .string(trackID.uuidString)
                } else if let artistID = cached.artistID {
                    resolvedValues["artistID"] = .string(artistID.uuidString)
                } else if let albumKey = cached.albumKey {
                    resolvedValues["albumKey"] = .string(albumKey)
                } else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "The artwork candidate no longer has a supported target.",
                            details: .object(["candidateID": .string(candidateID)])
                        )
                    )
                }
                let applyRequest = AutomationRequest(
                    method: AutomationMethod.artworkApply,
                    params: .object(resolvedValues),
                    context: request.context,
                    requestID: request.requestID,
                    protocolVersion: request.protocolVersion
                )
                let applyParameters = try AutomationParameters(applyRequest)
                let resolvedTarget = try resolveArtworkTarget(
                    from: applyParameters,
                    session: session,
                    allowPlaylist: false
                )
                guard resolvedTarget.stableIdentity == cached.targetIdentity else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The artwork candidate target changed after search.",
                            details: .object(["candidateID": .string(candidateID)])
                        )
                    )
                }
                return try await applyArtworkToSingleTarget(
                    parameters: applyParameters,
                    request: request,
                    session: session
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs")
                let artworks: [AutomationArtworkInfo]
                let revision: String
                if !trackIDs.isEmpty {
                    guard try !hasArtworkTargetParameters(parameters, excludingTrackIDs: true) else {
                        throw AutomationParameterError.invalidValue("trackIDs")
                    }
                    let tracksByID = Dictionary(
                        uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                    )
                    guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                        throw AutomationParameterError.invalidValue("trackIDs")
                    }
                    artworks = trackIDs.compactMap { id in
                        tracksByID[id].map {
                            makeArtworkInfo(.track($0), session: session)
                        }
                    }
                    revision = queries.libraryTracksRevision(
                        tracks: session.libraryViewModel.allTracks,
                        playlists: session.libraryViewModel.playlists
                    )
                } else {
                    let target = try resolveArtworkTarget(
                        from: parameters,
                        session: session,
                        allowPlaylist: true
                    )
                    artworks = [makeArtworkInfo(target, session: session)]
                    revision = artworkRevision(for: target, session: session)
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationArtworkGetResult(
                        artworks: artworks,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkApply:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs")
                if trackIDs.isEmpty {
                    return try await applyArtworkToSingleTarget(
                        parameters: parameters,
                        request: request,
                        session: session
                    )
                }
                guard try !hasArtworkTargetParameters(parameters, excludingTrackIDs: true) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let clear = try parameters.boolean("clear", default: false)
                let imagePath = try parameters.string("imagePath")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let imageBase64 = try parameters.string("imageBase64")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedRevisions = try makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                guard !(clear && (imagePath != nil || imageBase64 != nil)) else {
                    throw AutomationParameterError.invalidValue("clear")
                }
                guard !(imagePath != nil && imageBase64 != nil) else {
                    throw AutomationParameterError.invalidValue("imagePath/imageBase64")
                }
                if let imageBase64, imageBase64.isEmpty {
                    throw AutomationParameterError.invalidValue("imageBase64")
                }
                if let imagePath, imagePath.isEmpty {
                    throw AutomationParameterError.invalidValue("imagePath")
                }

                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let candidates = trackIDs.compactMap { tracksByID[$0] }
                let conflictIDs = candidates.compactMap { track -> UUID? in
                    guard let expected = expectedRevisions[track.id],
                          expected != session.libraryViewModel.automationTrackRevision(for: track),
                          expected != session.libraryViewModel.automationArtworkRevision(for: track) else {
                        return nil
                    }
                    return track.id
                }
                let changedIDs = candidates.compactMap { track -> UUID? in
                    guard !conflictIDs.contains(track.id) else { return nil }
                    if clear {
                        return track.loadArtworkDataIfNeeded() != nil || track.artworkFileName != nil
                            ? track.id
                            : nil
                    }
                    return track.id
                }
                let skippedIDs = candidates.map(\.id).filter {
                    !changedIDs.contains($0) && !conflictIDs.contains($0)
                }
                let inputKind = clear
                    ? "clear"
                    : imageBase64 != nil
                        ? "imageBase64"
                        : imagePath != nil
                            ? "imagePath"
                            : "picker"

                if !dryRun, trackIDs.count >= 10 {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "批量应用封面需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.artworkApply),
                                "trackCount": .number(Double(trackIDs.count)),
                                "threshold": .number(10),
                                "requiresForegroundConfirmation": .boolean(true)
                            ])
                        )
                    }
                }

                guard !dryRun else {
                    if let imageBase64 {
                        let encoded = imageBase64.hasPrefix("data:")
                            ? (imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "")
                            : imageBase64
                        guard let data = Data(base64Encoded: encoded),
                              data.count <= 16 * 1024 * 1024,
                              ArtworkDataNormalizer.isDecodableImage(data) else {
                            throw AutomationParameterError.invalidValue("imageBase64")
                        }
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationArtworkMutationResult(
                            applied: false,
                            dryRun: true,
                            input: inputKind,
                            updatedTrackIDs: changedIDs,
                            skippedTrackIDs: skippedIDs,
                            conflictedTrackIDs: conflictIDs,
                            message: "Preview only. App-owned artwork will be replaced or cleared; original audio-file tags will not be changed. Batches of 10 or more require confirm=true and foreground confirmation."
                        ),
                        for: request
                    )
                }

                if trackIDs.count >= 10,
                   !AutomationBatchExecutionContext.aggregateConfirmationApproved {
                    guard await AutomationInteraction.confirmDestructiveOperation(
                        title: "应用到 \(trackIDs.count) 首歌曲？",
                        message: clear
                            ? "要清除这 \(trackIDs.count) 首歌曲的封面吗？原音频文件不会修改。"
                            : "要将所选封面应用到这 \(trackIDs.count) 首歌曲吗？原音频文件不会修改。"
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                }

                let resolvedInput: (kind: String, data: Data?)
                if clear {
                    resolvedInput = ("clear", nil)
                } else if let imageBase64 {
                    let encoded = imageBase64.hasPrefix("data:")
                        ? (imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "")
                        : imageBase64
                    guard let data = Data(base64Encoded: encoded),
                          data.count <= 16 * 1024 * 1024,
                          ArtworkDataNormalizer.isDecodableImage(data) else {
                        throw AutomationParameterError.invalidValue("imageBase64")
                    }
                    resolvedInput = ("imageBase64", data)
                } else if let imagePath,
                           let data = try? Data(contentsOf: URL(fileURLWithPath: AutomationInteraction.expandPath(imagePath))),
                           data.count <= 16 * 1024 * 1024,
                           ArtworkDataNormalizer.isDecodableImage(data) {
                    resolvedInput = ("imagePath", ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data)
                } else {
                    guard let selectedURL = try await AutomationInteraction.requestArtworkURL(
                        requestedPath: imagePath.map(AutomationInteraction.expandPath(_:))
                    ) else {
                        return AutomationResponseSupport.interactionCancelled(for: request)
                    }
                    let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                        let accessed = selectedURL.startAccessingSecurityScopedResource()
                        defer {
                            if accessed { selectedURL.stopAccessingSecurityScopedResource() }
                        }
                        return try? Data(contentsOf: selectedURL)
                    }.value
                    guard let data,
                          data.count <= 16 * 1024 * 1024,
                          ArtworkDataNormalizer.isDecodableImage(data) else {
                        throw AutomationParameterError.invalidValue("imagePath")
                    }
                    resolvedInput = (imagePath == nil ? "picker" : "imagePath", data)
                }

                let outcome = try await session.libraryViewModel.applyArtworkForAutomation(
                    trackIDs: trackIDs,
                    artworkData: resolvedInput.data,
                    expectedRevisions: expectedRevisions
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationArtworkMutationResult(
                        applied: !outcome.updatedTrackIDs.isEmpty,
                        dryRun: false,
                        confirmed: trackIDs.count >= 10,
                        input: resolvedInput.kind,
                        updatedTrackIDs: outcome.updatedTrackIDs,
                        skippedTrackIDs: outcome.skippedTrackIDs,
                        conflictedTrackIDs: outcome.conflictedTrackIDs,
                        message: outcome.conflictedTrackIDs.isEmpty
                            ? "App-owned artwork updated; original audio-file tags were not changed."
                            : "Some Tracks changed after the query and were left untouched."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.metadataGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let entityType = try parameters.string("entityType")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let query = try parameters.string("query")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }
                let artistID = try parameters.uuid("artistID")
                let albumKey = try parameters.string("albumKey")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let playlistID = try parameters.uuid("playlistID")
                let requestedEntityCount = [artistID != nil, albumKey != nil, playlistID != nil]
                    .filter { $0 }
                    .count
                var trackIDs = try parameters.uuidArray("trackIDs")
                if let trackID = try parameters.uuid("trackID") {
                    trackIDs.append(trackID)
                }
                if let entityType {
                    guard ["artist", "album", "playlist"].contains(entityType),
                          trackIDs.isEmpty,
                          requestedEntityCount == 0 else {
                        throw AutomationParameterError.invalidValue("entityType")
                    }
                    return AutomationResponseSupport.encodeResult(
                        makeMetadataCollectionResult(
                            entityType: entityType,
                            query: query,
                            offset: offset,
                            limit: limit,
                            session: session
                        ),
                        for: request
                    )
                }
                guard (query == nil || query?.isEmpty == true) && limit == 100 && offset == 0 else {
                    throw AutomationParameterError.invalidValue("query/limit/offset")
                }
                if !trackIDs.isEmpty && requestedEntityCount > 0 {
                    throw AutomationParameterError.invalidValue("trackID/artistID/albumKey/playlistID")
                }
                if trackIDs.isEmpty && requestedEntityCount > 0 {
                    let target = try resolveMetadataTarget(
                        artistID: artistID,
                        albumKey: albumKey,
                        playlistID: playlistID,
                        session: session
                    )
                    return AutomationResponseSupport.encodeResult(
                        makeMetadataGetResult(for: target, session: session),
                        for: request
                    )
                }
                trackIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
                guard !trackIDs.isEmpty else {
                    throw AutomationParameterError.missing("trackID or trackIDs")
                }
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingIDs = trackIDs.filter { tracksByID[$0] == nil }
                guard missingIDs.isEmpty else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let tracks = trackIDs.compactMap { tracksByID[$0] }
                return AutomationResponseSupport.encodeResult(
                    AutomationLibraryTracksResult(
                        tracks: tracks.map {
                            queries.makeTrackSummary(
                                $0,
                                playlists: session.libraryViewModel.playlists,
                                includeFilePath: grantedScopes().contains(.filesRead)
                            )
                        },
                        total: tracks.count,
                        offset: 0,
                        limit: tracks.count,
                        revision: queries.libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        )
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataEmbeddedGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                var trackIDs = try parameters.uuidArray("trackIDs", maximumCount: 100)
                if let trackID = try parameters.uuid("trackID") {
                    guard trackIDs.isEmpty else {
                        throw AutomationParameterError.invalidValue("trackID/trackIDs")
                    }
                    trackIDs = [trackID]
                }
                guard !trackIDs.isEmpty, Set(trackIDs).count == trackIDs.count else {
                    throw AutomationParameterError.missing("trackID or trackIDs")
                }
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                var results: [AutomationEmbeddedTagTrack] = []
                for trackID in trackIDs {
                    guard let track = tracksByID[trackID] else { continue }
                    do {
                        let fileURL = try AutomationFileAccess.embeddedAudioFileURL(for: track, session: session)
                        let snapshot = await readEmbeddedTags(from: fileURL)
                        results.append(AutomationEmbeddedTagTrack(
                            id: track.id,
                            fileName: fileURL.lastPathComponent,
                            format: fileURL.pathExtension.lowercased(),
                            supportedForWrite: snapshot.supportedForWrite,
                            trackRevision: session.libraryViewModel.automationTrackRevision(for: track),
                            values: snapshot.values,
                            status: snapshot.status,
                            message: snapshot.message
                        ))
                    } catch {
                        results.append(AutomationEmbeddedTagTrack(
                            id: track.id,
                            fileName: "",
                            format: "",
                            supportedForWrite: false,
                            trackRevision: session.libraryViewModel.automationTrackRevision(for: track),
                            status: "unavailable",
                            message: "The active audio file is unavailable or not authorized."
                        ))
                    }
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationEmbeddedTagsResult(
                        dryRun: false,
                        applied: false,
                        libraryRevision: queries.libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        ),
                        tracks: results,
                        message: "Tags were read from the active audio files; App metadata was not changed."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataEmbeddedPatch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                var trackIDs = try parameters.uuidArray("trackIDs", maximumCount: 100)
                if let trackID = try parameters.uuid("trackID") {
                    guard trackIDs.isEmpty else {
                        throw AutomationParameterError.invalidValue("trackID/trackIDs")
                    }
                    trackIDs = [trackID]
                }
                guard !trackIDs.isEmpty, Set(trackIDs).count == trackIDs.count else {
                    throw AutomationParameterError.missing("trackID or trackIDs")
                }
                guard let rawFields = try parameters.object("fields"), !rawFields.isEmpty,
                      rawFields.count <= 16 else {
                    throw AutomationParameterError.missing("fields")
                }
                var fields: [String: String?] = [:]
                for (name, value) in rawFields {
                    guard MP3EmbeddedTagService.supportedFields.contains(name) else {
                        throw AutomationParameterError.invalidValue("fields.\(name)")
                    }
                    switch value {
                    case .string(let text) where text.count <= 16_384:
                        fields.updateValue(text, forKey: name)
                    case .null:
                        fields.updateValue(nil, forKey: name)
                    default:
                        throw AutomationParameterError.invalidValue("fields.\(name)")
                    }
                }
                let expectedRevisions = try makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                guard trackIDs.allSatisfy({ expectedRevisions[$0] != nil }) else {
                    throw AutomationParameterError.missing("expectedRevisions for every Track")
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                guard trackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                var previews: [AutomationEmbeddedTagTrack] = []
                var writeRequests: [MP3EmbeddedTagService.WriteRequest] = []
                for trackID in trackIDs {
                    guard let track = tracksByID[trackID] else { continue }
                    let trackRevision = session.libraryViewModel.automationTrackRevision(for: track)
                    guard expectedRevisions[trackID] == trackRevision else {
                        previews.append(AutomationEmbeddedTagTrack(
                            id: trackID,
                            fileName: "",
                            format: "",
                            supportedForWrite: false,
                            trackRevision: trackRevision,
                            status: "conflict",
                            message: "Track metadata changed after the write was reviewed."
                        ))
                        continue
                    }
                    do {
                        let fileURL = try AutomationFileAccess.embeddedAudioFileURL(for: track, session: session)
                        guard fileURL.pathExtension.lowercased() == "mp3" else {
                            previews.append(AutomationEmbeddedTagTrack(
                                id: trackID,
                                fileName: fileURL.lastPathComponent,
                                format: fileURL.pathExtension.lowercased(),
                                supportedForWrite: false,
                                trackRevision: trackRevision,
                                status: "unsupported",
                                message: "Only MP3 files with safely editable ID3v2 tags can be written."
                            ))
                            continue
                        }
                        let currentTags = try MP3EmbeddedTagService.read(from: fileURL)
                        let currentValues = embeddedTagValues(currentTags)
                        previews.append(AutomationEmbeddedTagTrack(
                            id: trackID,
                            fileName: fileURL.lastPathComponent,
                            format: "mp3",
                            supportedForWrite: true,
                            trackRevision: trackRevision,
                            values: currentValues,
                            status: "ready"
                        ))
                        writeRequests.append(MP3EmbeddedTagService.WriteRequest(
                            trackID: trackID,
                            fileURL: fileURL,
                            fileName: fileURL.lastPathComponent,
                            expectedTrackRevision: trackRevision,
                            fields: fields
                        ))
                    } catch {
                        previews.append(AutomationEmbeddedTagTrack(
                            id: trackID,
                            fileName: "",
                            format: "mp3",
                            supportedForWrite: false,
                            trackRevision: trackRevision,
                            status: "unsupported",
                            message: MP3EmbeddedTagService.publicMessage(for: error)
                        ))
                    }
                }
                let libraryRevision = queries.libraryTracksRevision(
                    tracks: session.libraryViewModel.allTracks,
                    playlists: session.libraryViewModel.playlists
                )
                guard !writeRequests.isEmpty else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationEmbeddedTagsResult(
                            dryRun: dryRun,
                            applied: false,
                            libraryRevision: libraryRevision,
                            tracks: previews,
                            message: "No eligible MP3 files were found; no files were changed."
                        ),
                        for: request
                    )
                }
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationEmbeddedTagsResult(
                            dryRun: true,
                            applied: false,
                            libraryRevision: libraryRevision,
                            tracks: previews,
                            message: "Preview only. The listed ID3 fields are ready for an atomic MP3 update."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "写入原音频标签需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "trackCount": .number(Double(writeRequests.count)),
                            "fields": .array(fields.keys.sorted().map(AutomationJSONValue.string)),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "写入 \(writeRequests.count) 个 MP3 文件标签？",
                    message: "将按预览写入 ID3 标签并替换原音频文件；每首歌曲分别校验，失败的文件保持原样。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }
                guard let descriptor = session.startAutomationEmbeddedTagWrite(requests: writeRequests) else {
                    throw AutomationParameterError.invalidValue("library session is closing")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationEmbeddedTagsResult(
                        dryRun: false,
                        applied: false,
                        libraryRevision: libraryRevision,
                        tracks: previews,
                        job: AutomationJobProjection.makeJobSummary(descriptor),
                        message: "The embedded-tag Job was started. Query jobs.get for per-file completion and failures."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.metadataExport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let requestedTrackIDs = try parameters.uuidArray(
                    "trackIDs",
                    maximumCount: 100
                )
                let allTracks = session.libraryViewModel.allTracks
                let revision = queries.libraryTracksRevision(
                    tracks: allTracks,
                    playlists: session.libraryViewModel.playlists
                )
                let pageTracks: [Track]
                let offset: Int
                let limit: Int
                let total: Int
                if !requestedTrackIDs.isEmpty {
                    guard Set(requestedTrackIDs).count == requestedTrackIDs.count,
                          parameters.values["offset"] == nil,
                          parameters.values["limit"] == nil else {
                        throw AutomationParameterError.invalidValue("trackIDs/limit/offset")
                    }
                    let tracksByID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
                    guard requestedTrackIDs.allSatisfy({ tracksByID[$0] != nil }) else {
                        throw AutomationParameterError.missingResource("trackIDs")
                    }
                    pageTracks = requestedTrackIDs.compactMap { tracksByID[$0] }
                    offset = 0
                    limit = pageTracks.count
                    total = pageTracks.count
                } else {
                    limit = try parameters.integer("limit", default: 100)
                    offset = try parameters.integer("offset", default: 0)
                    guard (1...100).contains(limit), offset >= 0 else {
                        throw AutomationParameterError.outOfRange("limit/offset")
                    }
                    let ordered = allTracks.sorted {
                        if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    total = ordered.count
                    pageTracks = Array(ordered.dropFirst(min(offset, ordered.count)).prefix(limit))
                }
                let nextOffset = offset + pageTracks.count < total
                    ? offset + pageTracks.count
                    : nil
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataDocument(
                        sourceLibraryID: session.context.id,
                        revision: revision,
                        offset: offset,
                        limit: limit,
                        total: total,
                        nextOffset: nextOffset,
                        tracks: pageTracks.map { track in
                            makeMetadataDocumentTrack(
                                track,
                                revision: session.libraryViewModel.automationTrackRevision(for: track)
                            )
                        }
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataImport:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                guard let rawDocument = parameters.values["document"] else {
                    throw AutomationParameterError.missing("document")
                }
                let documentData = try AutomationWireCoding.encoder().encode(rawDocument)
                let document = try AutomationWireCoding.decoder().decode(
                    AutomationMetadataDocument.self,
                    from: documentData
                )
                guard document.schemaVersion == 1,
                      (1...100).contains(document.tracks.count),
                      Set(document.tracks.map(\.id)).count == document.tracks.count else {
                    throw AutomationParameterError.invalidValue("document")
                }
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let overwriteExistingFields = try parameters.boolean("overwriteExistingFields", default: false)
                let currentTracks = session.libraryViewModel.allTracks
                let currentRevision = queries.libraryTracksRevision(
                    tracks: currentTracks,
                    playlists: session.libraryViewModel.playlists
                )
                if let expectedRevision, expectedRevision != currentRevision {
                    return AutomationResponseSupport.revisionConflict(for: request, expected: expectedRevision, actual: currentRevision)
                }

                let sourceIDs = Set(document.tracks.map(\.id))
                let rawIDMap = try parameters.object("trackIDMap") ?? [:]
                guard rawIDMap.count <= 500 else {
                    throw AutomationParameterError.outOfRange("trackIDMap")
                }
                var trackIDMap: [UUID: UUID] = [:]
                for (sourceIDValue, targetIDValue) in rawIDMap {
                    guard let sourceID = UUID(uuidString: sourceIDValue),
                          sourceIDs.contains(sourceID),
                          case .string(let targetValue) = targetIDValue,
                          let targetID = UUID(uuidString: targetValue) else {
                        throw AutomationParameterError.invalidValue("trackIDMap")
                    }
                    trackIDMap[sourceID] = targetID
                }
                if document.sourceLibraryID != session.context.id,
                   Set(trackIDMap.keys) != sourceIDs {
                    throw AutomationParameterError.invalidValue("trackIDMap.crossLibraryRequired")
                }
                let targetIDs = document.tracks.compactMap { record in
                    trackIDMap[record.id] ?? (document.sourceLibraryID == session.context.id ? record.id : nil)
                }
                guard Set(targetIDs).count == targetIDs.count else {
                    throw AutomationParameterError.invalidValue("trackIDMap.duplicateTargets")
                }
                let currentByID = Dictionary(uniqueKeysWithValues: currentTracks.map { ($0.id, $0) })
                var planned: [PlannedMetadataImport] = []
                for record in document.tracks {
                    _ = try makeMetadataPatch(record.fields)
                    let targetID = trackIDMap[record.id]
                        ?? (document.sourceLibraryID == session.context.id ? record.id : nil)
                    guard let targetID, let track = currentByID[targetID] else {
                        planned.append(PlannedMetadataImport(
                            record: record,
                            targetTrackID: targetID,
                            patch: nil,
                            expectedRevision: nil,
                            fields: [],
                            status: "missing",
                            message: "No active-library Track matches this document entry."
                        ))
                        continue
                    }
                    let trackRevision = session.libraryViewModel.automationTrackRevision(for: track)
                    if document.sourceLibraryID == session.context.id,
                       record.revision != trackRevision {
                        planned.append(PlannedMetadataImport(
                            record: record,
                            targetTrackID: targetID,
                            patch: nil,
                            expectedRevision: trackRevision,
                            fields: [],
                            status: "conflict",
                            message: "The Track metadata changed after this document was exported."
                        ))
                        continue
                    }
                    let values = metadataImportFields(
                        record.fields,
                        currentTrack: track,
                        overwriteExistingFields: overwriteExistingFields
                    )
                    let patch = try makeMetadataPatch(values)
                    let changes = metadataPatchChanges(track, patch: patch)
                    planned.append(PlannedMetadataImport(
                        record: record,
                        targetTrackID: targetID,
                        patch: patch,
                        expectedRevision: trackRevision,
                        fields: changes ? Array(patch.fields) : [],
                        status: changes ? "ready" : "unchanged",
                        message: changes ? "Metadata fields are ready to apply." : "No eligible metadata fields would change."
                    ))
                }
                var items = planned.map {
                    AutomationMetadataImportItem(
                        sourceTrackID: $0.record.id,
                        targetTrackID: $0.targetTrackID,
                        status: $0.status,
                        fields: $0.fields,
                        message: $0.message
                    )
                }
                if dryRun || planned.contains(where: { $0.status == "missing" }) {
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataImportResult(
                            libraryID: session.context.id,
                            sourceLibraryID: document.sourceLibraryID,
                            dryRun: dryRun,
                            applied: false,
                            items: items,
                            revision: currentRevision,
                            message: dryRun
                                ? "Preview only; no metadata was written."
                                : "No metadata was written because one or more target Tracks are missing."
                        ),
                        for: request
                    )
                }
                let readyCount = planned.filter { $0.status == "ready" }.count
                guard readyCount > 0 else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataImportResult(
                            libraryID: session.context.id,
                            sourceLibraryID: document.sourceLibraryID,
                            dryRun: false,
                            applied: false,
                            items: items,
                            revision: currentRevision,
                            message: "No eligible metadata fields required an update."
                        ),
                        for: request
                    )
                }
                guard try parameters.boolean("confirm", default: false) else {
                    return AutomationResponseSupport.confirmationRequired(
                        for: request,
                        message: "Import this Track metadata document?",
                        details: .object([
                            "trackCount": .number(Double(readyCount)),
                            "sourceLibraryID": .string(document.sourceLibraryID.uuidString),
                            "expectedRevision": .string(currentRevision),
                            "requiresForegroundConfirmation": .boolean(true)
                        ])
                    )
                }
                guard await AutomationInteraction.confirmDestructiveOperation(
                    title: "导入曲目元数据？",
                    message: "要为 \(readyCount) 首歌曲写入元数据吗？默认只补充空字段。"
                ) else {
                    return AutomationResponseSupport.interactionCancelled(for: request)
                }

                var itemBySourceID = Dictionary(uniqueKeysWithValues: items.map { ($0.sourceTrackID, $0) })
                for item in planned where item.status == "ready" {
                    guard let targetID = item.targetTrackID,
                          let patch = item.patch,
                          let expectedTrackRevision = item.expectedRevision else {
                        continue
                    }
                    do {
                        let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                            trackIDs: [targetID],
                            patch: patch,
                            expectedRevisions: [targetID: expectedTrackRevision]
                        )
                        let status: String
                        let message: String
                        if outcome.updatedTrackIDs.contains(targetID) {
                            status = "updated"
                            message = "Metadata was written through the App-owned persistence path."
                        } else if outcome.conflictedTrackIDs.contains(targetID) {
                            status = "conflict"
                            message = "The Track changed after preview; no metadata was written."
                        } else {
                            status = "unchanged"
                            message = "The Track already had these metadata values."
                        }
                        itemBySourceID[item.record.id] = AutomationMetadataImportItem(
                            sourceTrackID: item.record.id,
                            targetTrackID: targetID,
                            status: status,
                            fields: item.fields,
                            message: message
                        )
                    } catch {
                        itemBySourceID[item.record.id] = AutomationMetadataImportItem(
                            sourceTrackID: item.record.id,
                            targetTrackID: targetID,
                            status: "failed",
                            fields: item.fields,
                            message: "The App could not persist this Track's metadata."
                        )
                    }
                }
                items = planned.compactMap { itemBySourceID[$0.record.id] }
                let applied = items.contains { $0.status == "updated" }
                let hasFailure = items.contains { ["failed", "conflict", "missing"].contains($0.status) }
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataImportResult(
                        libraryID: session.context.id,
                        sourceLibraryID: document.sourceLibraryID,
                        dryRun: false,
                        applied: applied,
                        items: items,
                        revision: queries.libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        ),
                        message: hasFailure
                            ? "Metadata import finished with conflicts or item failures; inspect each item status."
                            : "Track metadata import completed through the App-owned persistence path."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataSearch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                var providerWarnings: [String: String] = [:]
                var candidates: [AutomationMetadataCandidate] = []
                do {
                    let qqCandidates = try await session.libraryViewModel.searchTrackMetadataCandidatesForAutomation(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration
                    )
                    candidates.append(contentsOf: qqCandidates.map { candidate in
                        let artist = candidate.artist ?? candidate.artistName
                        return AutomationMetadataCandidate(
                            candidateID: candidate.songMid,
                            provider: candidate.source,
                            title: candidate.title,
                            artist: artist,
                            album: candidate.album,
                            durationSeconds: candidate.duration,
                            confidence: candidate.confidence,
                            matchQuality: AutomationMetadataQualityEvaluator.score(
                                queryTitle: track.title,
                                queryArtist: track.artist,
                                queryAlbum: track.album,
                                queryDurationSeconds: track.duration,
                                candidateTitle: candidate.title,
                                candidateArtist: artist,
                                candidateAlbum: candidate.album,
                                candidateDurationSeconds: candidate.duration.map(Double.init)
                            ),
                            imageURL: candidate.imageURL
                        )
                    })
                } catch {
                    providerWarnings["QQMusic"] = error.localizedDescription
                }
                do {
                    let musicBrainzCandidates = try await MusicBrainzAutomationProvider.shared.search(
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        durationSeconds: track.duration
                    )
                    candidates.append(contentsOf: musicBrainzCandidates.map { candidate in
                        AutomationMetadataCandidate(
                            candidateID: "musicbrainz:\(candidate.recordingID)",
                            provider: "MusicBrainz",
                            title: candidate.title,
                            artist: candidate.artist,
                            album: candidate.album,
                            durationSeconds: candidate.durationSeconds,
                            confidence: nil,
                            matchQuality: AutomationMetadataQualityEvaluator.score(
                                queryTitle: track.title,
                                queryArtist: track.artist,
                                queryAlbum: track.album,
                                queryDurationSeconds: track.duration,
                                candidateTitle: candidate.title,
                                candidateArtist: candidate.artist,
                                candidateAlbum: candidate.album,
                                candidateDurationSeconds: candidate.durationSeconds.map(Double.init)
                            ),
                            imageURL: nil
                        )
                    })
                } catch {
                    providerWarnings["MusicBrainz"] = error.localizedDescription
                }
                candidates.sort {
                    let leftQuality = $0.matchQuality ?? -1
                    let rightQuality = $1.matchQuality ?? -1
                    if leftQuality != rightQuality { return leftQuality > rightQuality }
                    if $0.provider != $1.provider { return $0.provider < $1.provider }
                    return ($0.candidateID ?? "") < ($1.candidateID ?? "")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataSearchResult(
                        trackID: track.id,
                        queryTitle: track.title,
                        queryArtist: track.artist,
                        queryAlbum: track.album,
                        candidates: candidates,
                        revision: session.libraryViewModel.automationTrackRevision(for: track),
                        message: candidates.isEmpty
                            ? (providerWarnings.isEmpty
                                ? "Metadata providers returned no candidates."
                                : "No provider returned candidates; inspect providerWarnings for failures.")
                            : (providerWarnings.isEmpty
                                ? "Candidates were ranked with provider-neutral field matching; no metadata was changed."
                                : "Candidates are available from some providers; inspect providerWarnings for incomplete results."),
                        providerWarnings: providerWarnings.isEmpty ? nil : providerWarnings
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataApplyCandidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                let candidateID = try parameters.string("candidateID", required: true)!
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidateID.isEmpty,
                      let initialTrack = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID/candidateID")
                }
                let initialRevision = session.libraryViewModel.automationTrackRevision(for: initialTrack)
                let expectedRevision = try parameters.string("expectedRevision")
                let dryRun = try parameters.boolean("dryRun", default: false)
                let overwriteExistingFields = try parameters.boolean("overwriteExistingFields", default: false)
                if let expectedRevision, expectedRevision != initialRevision {
                    let mutation = AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: dryRun,
                        conflictedTrackIDs: [trackID],
                        message: "The Track changed after the candidate was selected. Search again before applying."
                    )
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataCandidateApplyResult(
                            trackID: trackID,
                            candidateID: candidateID,
                            dryRun: dryRun,
                            overwriteExistingFields: overwriteExistingFields,
                            previewPatch: [:],
                            mutation: mutation
                        ),
                        for: request
                    )
                }

                var titleValue: String?
                var artistValue: String?
                var albumValue: String?
                var descriptionValue: String?
                var genreTags: [String] = []
                var languageValue: String?
                var labelValue: String?
                var releaseDateValue: Date?
                var qqMusicSongMID: String?
                var metadataSource: String
                var metadataFetchedAt = Date()
                var metadataConfidence: Double?
                var musicBrainzReleaseID: String?

                if candidateID.hasPrefix("musicbrainz:") {
                    let recordingID = String(candidateID.dropFirst("musicbrainz:".count))
                    let candidates: [MusicBrainzAutomationCandidate]
                    do {
                        candidates = try await MusicBrainzAutomationProvider.shared.search(
                            title: initialTrack.title,
                            artist: initialTrack.artist,
                            album: initialTrack.album,
                            durationSeconds: initialTrack.duration
                        )
                    } catch {
                        return AutomationResponseSupport.metadataProviderUnavailable(error, provider: "MusicBrainz", for: request)
                    }
                    guard candidates.contains(where: { $0.recordingID == recordingID }) else {
                        throw AutomationParameterError.missingResource("candidateID")
                    }
                    let detail: MusicBrainzAutomationCandidate?
                    do {
                        detail = try await MusicBrainzAutomationProvider.shared.recording(id: recordingID)
                    } catch {
                        return AutomationResponseSupport.metadataProviderUnavailable(error, provider: "MusicBrainz", for: request)
                    }
                    guard let detail else {
                        throw AutomationParameterError.missingResource("metadata candidate detail")
                    }
                    titleValue = detail.title
                    artistValue = detail.artist
                    albumValue = detail.album
                    genreTags = detail.genreTags
                    releaseDateValue = Self.musicBrainzReleaseDate(detail.releaseDate)
                    musicBrainzReleaseID = detail.releaseID
                    metadataSource = MetadataDetailSource.musicbrainz.rawValue
                } else {
                    let candidates: [QQMusicArtworkCandidate]
                    do {
                        candidates = try await session.libraryViewModel.searchTrackMetadataCandidatesForAutomation(
                            title: initialTrack.title,
                            artist: initialTrack.artist,
                            album: initialTrack.album,
                            duration: initialTrack.duration
                        )
                    } catch {
                        return AutomationResponseSupport.metadataProviderUnavailable(error, provider: "QQMusic", for: request)
                    }
                    guard candidates.contains(where: { $0.songMid == candidateID }) else {
                        throw AutomationParameterError.missingResource("candidateID")
                    }
                    let detail: TrackMetadataDetail
                    do {
                        detail = try await session.libraryViewModel.fetchTrackMetadataDetailForAutomation(
                            candidateID,
                            title: initialTrack.title,
                            artist: initialTrack.artist,
                            album: initialTrack.album,
                            duration: initialTrack.duration
                        )
                    } catch {
                        return AutomationResponseSupport.metadataProviderUnavailable(error, provider: "QQMusic", for: request)
                    }
                    titleValue = detail.title
                    artistValue = detail.artist
                    albumValue = detail.album
                    descriptionValue = detail.description
                    genreTags = detail.genreTags
                    languageValue = detail.language
                    labelValue = detail.labelOrCompany
                    releaseDateValue = detail.releaseDate
                    qqMusicSongMID = detail.qqMusicSongMid
                    metadataSource = detail.source.rawValue
                    metadataFetchedAt = detail.fetchedAt ?? Date()
                    metadataConfidence = detail.confidence
                }
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }

                var patchValues: [String: AutomationJSONValue] = [:]
                func addString(_ key: String, value: String?, current: String) {
                    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                          overwriteExistingFields || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    patchValues[key] = .string(value)
                }
                addString("title", value: titleValue, current: track.title)
                addString("artist", value: artistValue, current: track.artist)
                addString("album", value: albumValue, current: track.album)
                addString("description", value: descriptionValue, current: track.userDescription)
                if !genreTags.isEmpty && (overwriteExistingFields || track.genreTags.isEmpty) {
                    patchValues["genreTags"] = .array(genreTags.map(AutomationJSONValue.string))
                }
                addString("language", value: languageValue, current: track.language)
                addString("labelOrCompany", value: labelValue, current: track.labelOrCompany)
                if let releaseDate = releaseDateValue,
                   overwriteExistingFields || track.releaseDate == nil {
                    patchValues["releaseDate"] = .string(ISO8601DateFormatter().string(from: releaseDate))
                }
                if let qqMusicSongMID {
                    patchValues["qqMusicSongMid"] = .string(qqMusicSongMID)
                }
                addString("musicBrainzReleaseID", value: musicBrainzReleaseID, current: track.musicBrainzReleaseID ?? "")
                patchValues["metadataSource"] = .string(metadataSource)
                patchValues["metadataFetchedAt"] = .string(
                    ISO8601DateFormatter().string(from: metadataFetchedAt)
                )
                if let metadataConfidence, metadataConfidence.isFinite {
                    patchValues["metadataConfidence"] = .number(metadataConfidence)
                }

                let currentRevision = session.libraryViewModel.automationTrackRevision(for: track)
                let conflicted = currentRevision != initialRevision
                    || (expectedRevision != nil && expectedRevision != currentRevision)
                let patch = try makeMetadataPatch(patchValues)
                let changed = !conflicted && metadataPatchChanges(track, patch: patch)
                let outcome: LibraryAutomationMetadataMutationOutcome
                if dryRun || conflicted || !changed {
                    outcome = LibraryAutomationMetadataMutationOutcome(
                        updatedTrackIDs: [],
                        skippedTrackIDs: !conflicted && !changed ? [trackID] : [],
                        conflictedTrackIDs: conflicted ? [trackID] : []
                    )
                } else {
                    outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                        trackIDs: [trackID],
                        patch: patch,
                        expectedRevisions: [trackID: initialRevision]
                    )
                }
                let mutation = AutomationMetadataMutationResult(
                    applied: !dryRun && !outcome.updatedTrackIDs.isEmpty,
                    dryRun: dryRun,
                    updatedTrackIDs: outcome.updatedTrackIDs,
                    skippedTrackIDs: outcome.skippedTrackIDs,
                    conflictedTrackIDs: outcome.conflictedTrackIDs,
                    message: dryRun
                        ? "Preview only. Existing values are preserved unless overwriteExistingFields is true."
                        : "The selected metadata candidate was applied through the App-owned metadata persistence path."
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataCandidateApplyResult(
                        trackID: trackID,
                        candidateID: candidateID,
                        dryRun: dryRun,
                        overwriteExistingFields: overwriteExistingFields,
                        previewPatch: patchValues,
                        mutation: mutation
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataPatch:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs")
                let hasSingularTrack = try parameters.uuid("trackID") != nil
                let hasEntityTarget = try hasMetadataEntityTarget(parameters)
                if trackIDs.isEmpty || hasEntityTarget || hasSingularTrack {
                    if !trackIDs.isEmpty || (hasSingularTrack && hasEntityTarget) {
                        throw AutomationParameterError.invalidValue("metadata target")
                    }
                    return try await applyMetadataToSingleTarget(
                        parameters: parameters,
                        request: request,
                        session: session
                    )
                }
                guard let patchValues = try parameters.object("patch"), !patchValues.isEmpty else {
                    throw AutomationParameterError.missing("patch")
                }
                let patch = try makeMetadataPatch(patchValues)
                let expectedRevisions = try makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
                )
                let missingIDs = trackIDs.filter { tracksByID[$0] == nil }
                guard missingIDs.isEmpty else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                let candidates = trackIDs.compactMap { tracksByID[$0] }
                let changedIDs = candidates.compactMap { track -> UUID? in
                    guard metadataPatchChanges(track, patch: patch) else { return nil }
                    guard let expected = expectedRevisions[track.id] else {
                        return track.id
                    }
                    return expected == session.libraryViewModel.automationTrackRevision(for: track)
                        ? track.id
                        : nil
                }
                let conflictIDs: [UUID] = candidates.compactMap { (track: Track) -> UUID? in
                    guard let expected = expectedRevisions[track.id],
                          expected != session.libraryViewModel.automationTrackRevision(for: track) else {
                        return nil
                    }
                    return track.id
                }
                guard !dryRun else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationMetadataMutationResult(
                            applied: false,
                            dryRun: true,
                            updatedTrackIDs: changedIDs,
                            skippedTrackIDs: candidates.map(\.id).filter { !changedIDs.contains($0) && !conflictIDs.contains($0) },
                            conflictedTrackIDs: conflictIDs,
                            message: "Preview only. This updates App-owned metadata and never writes embedded file tags."
                        ),
                        for: request
                    )
                }
                if trackIDs.count >= 10 {
                    guard confirm else {
                        return AutomationResponseSupport.confirmationRequired(
                            for: request,
                            message: "批量修改歌曲信息需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.metadataPatch),
                                "trackCount": .number(Double(trackIDs.count)),
                                "threshold": .number(10),
                                "requiresForegroundConfirmation": .boolean(true)
                            ])
                        )
                    }
                    if !AutomationBatchExecutionContext.aggregateConfirmationApproved {
                        guard await AutomationInteraction.confirmDestructiveOperation(
                            title: "修改 \(trackIDs.count) 首歌曲的信息？",
                            message: "要将这些歌曲的信息更新到播放器资料库吗？原音频文件和内嵌标签不会修改。"
                        ) else {
                            return AutomationResponseSupport.interactionCancelled(for: request)
                        }
                    }
                }
                let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                    trackIDs: trackIDs,
                    patch: patch,
                    expectedRevisions: expectedRevisions
                )
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: !outcome.updatedTrackIDs.isEmpty,
                        dryRun: false,
                        updatedTrackIDs: outcome.updatedTrackIDs,
                        skippedTrackIDs: outcome.skippedTrackIDs,
                        conflictedTrackIDs: outcome.conflictedTrackIDs,
                        message: outcome.conflictedTrackIDs.isEmpty
                            ? "App metadata updated; original file tags were not changed."
                            : "Some Tracks changed after the query and were left untouched."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.mutationFailure(for: request, error: error)
            }

        case AutomationMethod.lyricsGet:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsDetail(
                        trackID: trackID,
                        status: queries.trackLyricsStatus(track),
                        ttml: track.ttmlLyricText,
                        plainText: track.lyricsText
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsSearch, AutomationMethod.lyricsCandidates:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                let requestedMode = try parameters.string("mode") ?? LDDCMode.verbatim.rawValue
                guard let mode = LDDCMode(rawValue: requestedMode) else {
                    throw AutomationParameterError.invalidValue("mode")
                }
                let translation = try parameters.boolean("translation", default: true)
                let requestedRefresh = try parameters.boolean("refresh", default: false)
                let shouldRefresh = request.method == AutomationMethod.lyricsSearch
                    || requestedRefresh
                let cache = lyricsCandidateCache[trackID]
                let usedCache = !shouldRefresh
                    && cache?.mode == mode
                    && cache?.translation == translation
                let result: LyricsSearchHelper.SearchResult
                if usedCache, let cache {
                    result = cache.result
                } else {
                    result = await LyricsSearchHelper.performFullSearch(
                        title: track.title,
                        artist: track.artist.isEmpty ? nil : track.artist,
                        album: track.album.isEmpty ? nil : track.album,
                        duration: track.duration > 0 ? track.duration : nil,
                        mode: mode,
                        translation: translation,
                        searchCoordinator: session.cacheServices.lyricsSearchCoordinator
                    )
                    lyricsCandidateCache[trackID] = CachedLyricsCandidates(
                        mode: mode,
                        translation: translation,
                        result: result
                    )
                    trimLyricsCandidateCacheIfNeeded()
                }
                return AutomationResponseSupport.encodeResult(
                    makeLyricsSearchResult(
                        trackID: trackID,
                        track: track,
                        mode: mode,
                        result: result,
                        fromCache: usedCache
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsCompare:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                guard let candidateValues = try parameters.object("candidate") else {
                    throw AutomationParameterError.missing("candidate")
                }
                let candidate = try makeAutomationLyricsCandidate(from: candidateValues)
                let currentQuality = queries.currentLyricsQuality(track)
                let candidateQuality = lyricsQuality(for: candidate)
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsComparisonResult(
                        trackID: trackID,
                        currentStatus: queries.trackLyricsStatus(track),
                        currentQuality: currentQuality,
                        candidate: candidate,
                        candidateQuality: candidateQuality,
                        shouldReplace: candidateQuality > currentQuality,
                        message: candidateQuality > currentQuality
                            ? "The candidate is a higher synchronization quality than the current lyrics."
                            : "The current lyrics are equal or higher quality; no replacement is recommended."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsApply:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                let candidateValues = try parameters.object("candidate")
                let customTTML = try parameters.string("ttmlText")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hasCandidate = candidateValues != nil
                let hasCustomTTML = customTTML?.isEmpty == false
                guard hasCandidate != hasCustomTTML else {
                    throw AutomationParameterError.invalidValue("candidate/ttmlText")
                }
                let force = try parameters.boolean("force", default: false)
                let translation = try parameters.boolean("translation", default: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let cleanMetadata = try parameters.boolean("cleanMetadata", default: true)
                let expectedRevision = try parameters.string("expectedRevision")
                let currentQuality = queries.currentLyricsQuality(track)
                let candidate: AutomationLyricsCandidate?
                let estimatedQuality: Int
                let effectiveCustomTTML: String?
                if let candidateValues {
                    let parsedCandidate = try makeAutomationLyricsCandidate(from: candidateValues)
                    candidate = parsedCandidate
                    estimatedQuality = lyricsQuality(for: parsedCandidate)
                    effectiveCustomTTML = nil
                } else {
                    guard let rawCustom = customTTML,
                          LyricsFormatSupport.validateTTML(rawCustom).isValid else {
                        throw AutomationParameterError.invalidValue("ttmlText")
                    }
                    candidate = nil
                    let sanitized = cleanMetadata
                        ? LyricsFormatSupport.sanitizeTTML(rawCustom, trackTitle: track.title, artist: track.artist).sanitized
                        : rawCustom
                    effectiveCustomTTML = sanitized
                    estimatedQuality = LyricsFormatSupport.isWordSyncedTTML(sanitized) ? 2 : 1
                }
                if let expectedRevision,
                   expectedRevision != session.libraryViewModel.automationTrackRevision(for: track) {
                    return AutomationResponseSupport.trackRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: session.libraryViewModel.automationTrackRevision(for: track)
                    )
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsApplyResult(
                            trackID: trackID,
                            applied: false,
                            dryRun: true,
                            force: force,
                            input: candidate == nil ? "ttmlText" : "candidate",
                            candidate: candidate,
                            ttmlByteCount: effectiveCustomTTML?.utf8.count,
                            currentQuality: currentQuality,
                            candidateQuality: estimatedQuality,
                            message: candidate == nil
                                ? "Preview only. The supplied TTML text will replace the current lyrics directly."
                                : force
                                ? "Preview only. The selected candidate will replace the current lyrics."
                                : "Preview only. The candidate will replace the current lyrics only when its fetched quality is higher."
                        ),
                        for: request
                    )
                }
                if let effectiveCustomTTML {
                    let outcome = await session.applyCustomTTMLForAutomation(
                        trackID: trackID,
                        ttml: effectiveCustomTTML,
                        expectedRevision: expectedRevision
                    )
                    if outcome.conflicted {
                        return AutomationResponseSupport.trackRevisionConflict(
                            for: request,
                            expected: expectedRevision ?? "unknown",
                            actual: session.libraryViewModel.allTracks
                                .first(where: { $0.id == trackID })
                                .map { session.libraryViewModel.automationTrackRevision(for: $0) }
                                ?? "unknown"
                        )
                    }
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsApplyResult(
                            trackID: trackID,
                            applied: outcome.applied,
                            dryRun: false,
                            force: force,
                            input: "ttmlText",
                            candidate: nil,
                            ttmlByteCount: effectiveCustomTTML.utf8.count,
                            currentQuality: outcome.currentQuality,
                            candidateQuality: outcome.candidateQuality,
                            message: outcome.message
                        ),
                        for: request
                    )
                }
                guard let candidate else {
                    throw AutomationParameterError.invalidValue("candidate/ttmlText")
                }
                let lddcCandidate = try makeLDDCCandidate(from: candidate)
                guard let ttml = await LyricsSearchHelper.fetchTTMLForAutomation(
                    candidate: lddcCandidate,
                    mode: try lddcMode(for: candidate),
                    translation: translation,
                    amllDBService: session.cacheServices.amllDBService
                ) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .internalError,
                            message: "The selected lyrics candidate could not be fetched or converted.",
                            retryable: true,
                            details: .object([
                                "trackID": .string(trackID.uuidString),
                                "candidateID": .string(candidate.id)
                            ])
                        )
                    )
                }
                let effectiveCandidateTTML = cleanMetadata
                    ? LyricsFormatSupport.sanitizeTTML(ttml, trackTitle: track.title, artist: track.artist).sanitized
                    : ttml
                let fetchedQuality = LyricsFormatSupport.isWordSyncedTTML(effectiveCandidateTTML) ? 2 : 1
                let outcome = await session.applyAutomationLyrics(
                    trackID: trackID,
                    ttml: effectiveCandidateTTML,
                    candidateQuality: fetchedQuality,
                    force: force,
                    expectedRevision: expectedRevision
                )
                if outcome.conflicted {
                    return AutomationResponseSupport.trackRevisionConflict(
                        for: request,
                        expected: expectedRevision ?? "unknown",
                        actual: session.libraryViewModel.allTracks
                            .first(where: { $0.id == trackID })
                            .map { session.libraryViewModel.automationTrackRevision(for: $0) }
                            ?? "unknown"
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsApplyResult(
                        trackID: trackID,
                        applied: outcome.applied,
                        dryRun: false,
                        force: force,
                        input: "candidate",
                        candidate: candidate,
                        currentQuality: outcome.currentQuality,
                        candidateQuality: outcome.candidateQuality,
                        message: outcome.message
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsClean:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                guard let ttml = queries.resolveTTMLText(for: track),
                      !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .invalidRequest,
                            message: "Track does not have TTML lyrics to clean.",
                            details: .object(["trackID": .string(trackID.uuidString)])
                        )
                    )
                }
                let (sanitized, removedCount) = LyricsFormatSupport.sanitizeTTML(
                    ttml,
                    trackTitle: track.title,
                    artist: track.artist
                )
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsCleanResult(
                            trackID: trackID,
                            cleaned: removedCount > 0,
                            dryRun: true,
                            removedLines: removedCount,
                            message: removedCount > 0
                                ? "Preview only. \(removedCount) preamble/trailing metadata line(s) will be stripped."
                                : "Lyrics are already clean. No metadata noise lines found.",
                            preview: removedCount > 0 ? sanitized : nil
                        ),
                        for: request
                    )
                }
                if removedCount > 0 {
                    let outcome = await session.applyCustomTTMLForAutomation(
                        trackID: trackID,
                        ttml: sanitized,
                        expectedRevision: nil
                    )
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsCleanResult(
                            trackID: trackID,
                            cleaned: outcome.applied,
                            dryRun: false,
                            removedLines: removedCount,
                            message: outcome.applied
                                ? "Successfully stripped \(removedCount) metadata line(s) and synchronized lyrics start."
                                : outcome.message,
                            preview: nil
                        ),
                        for: request
                    )
                } else {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsCleanResult(
                            trackID: trackID,
                            cleaned: false,
                            dryRun: false,
                            removedLines: 0,
                            message: "Lyrics are already clean. No metadata noise lines found.",
                            preview: nil
                        ),
                        for: request
                    )
                }
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsRefresh:
            guard let session = sessionAccess.activeSession(for: request), let appSession else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let force = try parameters.boolean("force", default: false)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let existingIDs = Set(session.libraryViewModel.allTracks.map(\.id))
                guard trackIDs.allSatisfy(existingIDs.contains) else {
                    throw AutomationParameterError.invalidValue("trackIDs")
                }
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        AutomationLyricsRefreshResult(
                            applied: false,
                            dryRun: true,
                            selectedTrackIDs: trackIDs,
                            message: "Preview only. The selected Tracks will be processed by the existing provider pipeline."
                        ),
                        for: request
                    )
                }
                guard let descriptor = appSession.startLyricsRefreshJob(
                    trackIDs: trackIDs,
                    force: force,
                    libraryID: session.context.id
                ) else {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .serverUnavailable,
                            message: "The lyrics Job could not be started.",
                            retryable: true
                        )
                    )
                }
                return AutomationResponseSupport.encodeResult(
                    AutomationLyricsRefreshResult(
                        applied: true,
                        dryRun: false,
                        selectedTrackIDs: trackIDs,
                        job: AutomationJobProjection.makeJobSummary(descriptor),
                        message: "Lyrics refresh Job accepted; query jobs.get for progress and failures."
                    ),
                    for: request
                )
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsList,
             AutomationMethod.jobsGet,
             AutomationMethod.jobsWait,
             AutomationMethod.jobsCancel,
             AutomationMethod.jobsRetry:
            return await AutomationJobsHandler(appSession: appSession).handle(request, cancellation: cancellation)

        case AutomationMethod.diagnosticsHealth:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard let appSession else {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .serverUnavailable,
                        message: "The player App is no longer available.",
                        retryable: true
                    )
                )
            }
            do {
                let parameters = try AutomationParameters(request)
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 100)
                guard offset >= 0, (1...100).contains(limit) else {
                    throw AutomationParameterError.outOfRange("offset/limit")
                }
                let tracks = session.libraryViewModel.allTracks
                let missing = tracks.filter { $0.availability == .missing }.count
                let unavailable = tracks.filter { $0.availability != .available }.count
                let missingLyrics = tracks.filter { queries.trackLyricsStatus($0) == "none" }.count
                let missingArtwork = tracks.filter { !$0.hasArtwork }.count
                let incompleteMetadata = tracks.filter { track in
                    [track.title, track.artist, track.album].contains {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }.count
                let sources = try await appSession.referencedSources()
                let sourceIssues = sources
                    .filter { $0.status != .available }
                    .map { "\($0.displayName): \($0.status.rawValue) (\($0.lastKnownPath))" }
                let jobs = session.libraryJobDescriptorsSnapshot()
                let runningJobs = jobs.filter {
                    switch $0.state {
                    case .queued, .running, .checkpointed: return true
                    case .completed, .partialFailure, .failed, .cancelled: return false
                    }
                }.count
                let failedJobs = jobs.filter {
                    switch $0.state {
                    case .failed, .partialFailure: return true
                    case .queued, .running, .checkpointed, .completed, .cancelled: return false
                    }
                }
                let failedJobSummaries = failedJobs.flatMap { job in
                    let prefix = job.partialFailureSummaries.prefix(3)
                    if prefix.isEmpty {
                        return ["\(job.id.uuidString): \(job.state.rawValue)"]
                    }
                    return prefix.map { "\(job.id.uuidString): \($0)" }
                }.prefix(50)
                let diskSnapshot = try? await storageDiskSnapshot(for: session)
                let playlistReferenceIssues = diskSnapshot.map {
                    makePlaylistReferenceIssues($0.playlistReferenceIssues)
                } ?? []
                var storageValidation = "notRun"
                var storageValidationMessage: String?
                var storageValidationError: Error?
                do {
                    try await LibraryUpgradeSessionValidator.validate(
                        context: session.context,
                        libraryViewModel: session.libraryViewModel,
                        repository: session.repository,
                        searchIndex: session.searchIndex,
                        playbackHistoryStore: session.playbackHistoryStore
                    )
                    storageValidation = "passed"
                } catch {
                    storageValidation = "failed"
                    storageValidationMessage = String(describing: error)
                    storageValidationError = error
                }
                let issues = diagnosticsIssues(
                    tracks: tracks,
                    sources: sources,
                    jobs: jobs,
                    playlistReferences: playlistReferenceIssues,
                    storageError: storageValidationError,
                    diskSnapshot: diskSnapshot,
                    in: session
                )
                let mediaIssues = mediaPresenceIssues(for: tracks, in: session).map {
                    AutomationDiagnosticIssue(
                        id: $0.id,
                        code: $0.code,
                        trackID: $0.trackID,
                        path: $0.path,
                        reason: $0.reason
                    )
                }.sorted { $0.id < $1.id }
                let checks = [
                    "library": "ok",
                    "sources": sourceIssues.isEmpty ? "ok" : "attention",
                    "missingTracks": missing == 0 ? "ok" : "attention",
                    "unavailableTracks": unavailable == 0 ? "ok" : "attention",
                    "lyricsCoverage": missingLyrics == 0 ? "complete" : "partial",
                    "artworkCoverage": missingArtwork == 0 ? "complete" : "partial",
                    "metadataCoverage": incompleteMetadata == 0 ? "complete" : "partial",
                    "jobs": runningJobs == 0 ? (failedJobs.isEmpty ? "idle" : "attention") : "running",
                    "playlistReferences": playlistReferenceIssues.isEmpty ? "ok" : "attention",
                    "mediaPresence": mediaIssues.isEmpty ? "ok" : "attention",
                    "storage": storageValidation == "passed" ? "ok" : "attention"
                ]
                return AutomationResponseSupport.encodeResult(
                    AutomationDiagnosticsResult(
                        healthy: sourceIssues.isEmpty
                            && unavailable == 0
                            && failedJobs.isEmpty
                            && playlistReferenceIssues.isEmpty
                            && mediaIssues.isEmpty
                            && storageValidation == "passed",
                        libraryID: session.context.id,
                        trackCount: tracks.count,
                        playlistCount: session.libraryViewModel.playlists.count,
                        missingTrackCount: missing,
                        unavailableTrackCount: unavailable,
                        missingLyricsTrackCount: missingLyrics,
                        missingArtworkTrackCount: missingArtwork,
                        incompleteMetadataTrackCount: incompleteMetadata,
                        sourceCount: sources.count,
                        sourceIssues: sourceIssues,
                        runningJobCount: runningJobs,
                        checks: checks,
                        failedJobCount: failedJobs.count,
                        failedJobSummaries: Array(failedJobSummaries),
                        playlistReferenceIssues: Array(playlistReferenceIssues.prefix(100)),
                        storageValidation: storageValidation,
                        storageValidationMessage: storageValidationMessage,
                        issues: Array(issues.dropFirst(offset).prefix(limit)),
                        issueCount: issues.count,
                        offset: offset,
                        limit: limit,
                        hasMore: offset + limit < issues.count,
                        mediaIssues: Array(mediaIssues.dropFirst(offset).prefix(limit)),
                        mediaIssueCount: mediaIssues.count,
                        mediaHasMore: offset + limit < mediaIssues.count
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to collect library diagnostics.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.settingsGet,
             AutomationMethod.settingsPatch,
             AutomationMethod.settingsSchema,
             AutomationMethod.settingsValidate,
             AutomationMethod.settingsReset,
             AutomationMethod.audioGet,
             AutomationMethod.audioPatch:
            return await AutomationSettingsHandler(appSession: appSession).handle(request)

        case AutomationMethod.storageInspect:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            return AutomationResponseSupport.encodeResult(
                storageResult(for: session, validation: "notRun"),
                for: request
            )

        case AutomationMethod.storageValidate:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let offset = try parameters.integer("offset", default: 0)
                let limit = try parameters.integer("limit", default: 100)
                guard offset >= 0, (1...100).contains(limit) else {
                    throw AutomationParameterError.outOfRange("offset/limit")
                }
                let diskSnapshot = try? await storageDiskSnapshot(for: session)
                do {
                    try await LibraryUpgradeSessionValidator.validate(
                        context: session.context,
                        libraryViewModel: session.libraryViewModel,
                        repository: session.repository,
                        searchIndex: session.searchIndex,
                        playbackHistoryStore: session.playbackHistoryStore
                    )
                    return AutomationResponseSupport.encodeResult(
                        storageResult(
                            for: session,
                            validation: "passed",
                            validationMessage: "The App-owned storage validator passed.",
                            diskSnapshot: diskSnapshot,
                            includeMediaPresenceIssues: true,
                            offset: offset,
                            limit: limit
                        ),
                        for: request
                    )
                } catch {
                    return AutomationResponseSupport.encodeResult(
                        storageResult(
                            for: session,
                            validation: "failed",
                            validationMessage: String(describing: error),
                            message: "Storage validation found an issue; no repair was attempted.",
                            validationError: error,
                            diskSnapshot: diskSnapshot,
                            includeMediaPresenceIssues: true,
                            offset: offset,
                            limit: limit
                        ),
                        for: request
                    )
                }
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            }

        case AutomationMethod.storageRepair:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                if dryRun {
                    return AutomationResponseSupport.encodeResult(
                        storageResult(
                            for: session,
                            validation: "notRun",
                            message: "Preview only. Repair can recreate missing App-owned directories and the default scoped-settings file; it never edits Track, Playlist, Source or cache contents."
                        ),
                        for: request
                    )
                }
                try LibraryScaffoldingRepair.repairIfNeeded(at: session.context.rootURL)
                await session.libraryViewModel.reloadLibrary()
                return AutomationResponseSupport.encodeResult(
                    storageResult(
                        for: session,
                        validation: "notRun",
                        message: "Library scaffolding repair completed. Run storage.validate to verify all invariants."
                    ),
                    for: request
                )
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Library scaffolding repair failed.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageOrphans:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let snapshot = try await storageDiskSnapshot(for: session)
                return AutomationResponseSupport.encodeResult(
                    AutomationStorageOrphansResult(
                        libraryID: session.context.id,
                        playlistReferenceIssues: makePlaylistReferenceIssues(
                            snapshot.playlistReferenceIssues
                        ),
                        message: snapshot.playlistReferenceIssues.isEmpty
                            ? "No Playlist references point to missing Track sidecars."
                            : "Playlist references were inspected; no data was changed."
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to inspect Playlist references.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageBackup:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let context = session.context
                let result = try await session.runLibraryOperation(as: .other) {
                    try await Task.detached(priority: .utility) {
                        try Self.createStorageBackup(
                            context: context,
                            bundleIdentifier: self.automationBundleIdentifier,
                            appSupportDirectoryURL: self.appSupportDirectoryURL
                        )
                    }.value
                }
                return AutomationResponseSupport.encodeResult(result, for: request)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to create the Library metadata backup.",
                        retryable: true,
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageDiff:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let backupPath = try parameters.string("backupPath", required: true)!
                let context = session.context
                let result = try await Task.detached(priority: .utility) {
                    try Self.storageDiff(
                        context: context,
                        backupPath: backupPath,
                        bundleIdentifier: self.automationBundleIdentifier,
                        appSupportDirectoryURL: self.appSupportDirectoryURL
                    )
                }.value
                return AutomationResponseSupport.encodeResult(result, for: request)
            } catch let error as AutomationParameterError {
                return AutomationResponseSupport.invalidParameters(for: request, error: error)
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to compare the Library metadata backup.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.storageReload:
            guard let session = sessionAccess.activeSession(for: request) else {
                return sessionAccess.noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || AutomationResponseSupport.isObject(request.params) else {
                return AutomationResponseSupport.invalidParameters(for: request)
            }
            do {
                let _: Void = try await session.runLibraryOperation(as: .other) {
                    await session.libraryViewModel.reloadLibrary()
                }
                return AutomationResponseSupport.encodeResult(
                    storageResult(
                        for: session,
                        validation: "notRun",
                        message: "The active Library was reloaded from its current App-owned storage. Run storage.validate afterward."
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to reload the active Library.",
                        retryable: true,
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

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
            return .failure(
                for: request,
                error: AutomationError(
                    code: .methodNotFound,
                    message: "Unsupported automation method: \(request.method)."
                )
            )
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

    private static func musicBrainzReleaseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components[0].count == 4,
              let year = Int(components[0]), year > 0 else {
            return nil
        }
        var dateComponents = DateComponents(year: year, month: 1, day: 1)
        if components.count >= 2 {
            guard components[1].count == 2,
                  let month = Int(components[1]), (1...12).contains(month) else {
                return nil
            }
            dateComponents.month = month
        }
        if components.count == 3 {
            guard components[2].count == 2,
                  let day = Int(components[2]), (1...31).contains(day) else {
                return nil
            }
            dateComponents.day = day
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: dateComponents) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == dateComponents.year,
              resolved.month == dateComponents.month,
              resolved.day == dateComponents.day else {
            return nil
        }
        return date
    }

    private func metadataImportFields(
        _ values: [String: AutomationJSONValue],
        currentTrack: Track,
        overwriteExistingFields: Bool
    ) -> [String: AutomationJSONValue] {
        guard !overwriteExistingFields else { return values }
        var result: [String: AutomationJSONValue] = [:]
        for (key, value) in values {
            guard value != .null else { continue }
            let existingValueIsEmpty: Bool
            switch key {
            case "title": existingValueIsEmpty = currentTrack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "artist": existingValueIsEmpty = currentTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "album": existingValueIsEmpty = currentTrack.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "albumArtist": existingValueIsEmpty = currentTrack.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            case "description": existingValueIsEmpty = currentTrack.userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "genreTags": existingValueIsEmpty = currentTrack.genreTags.isEmpty
            case "language": existingValueIsEmpty = currentTrack.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "labelOrCompany": existingValueIsEmpty = currentTrack.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case "releaseDate": existingValueIsEmpty = currentTrack.releaseDate == nil
            case "qqMusicSongMid": existingValueIsEmpty = currentTrack.qqMusicSongMid?.isEmpty ?? true
            case "metadataSource": existingValueIsEmpty = currentTrack.metadataSource?.isEmpty ?? true
            case "metadataFetchedAt": existingValueIsEmpty = currentTrack.metadataFetchedAt == nil
            case "metadataConfidence": existingValueIsEmpty = currentTrack.metadataConfidence == nil
            case "musicBrainzReleaseID": existingValueIsEmpty = currentTrack.musicBrainzReleaseID?.isEmpty ?? true
            case "lyricsTimeOffsetMs": existingValueIsEmpty = currentTrack.lyricsTimeOffsetMs == 0
            case "artistCredits": existingValueIsEmpty = currentTrack.artistCredits.isEmpty
            default: existingValueIsEmpty = false
            }
            if existingValueIsEmpty { result[key] = value }
        }
        return result
    }

    private func makeMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationMetadataPatch {
        let allowed: Set<String> = [
            "title", "artist", "album", "albumArtist", "description",
            "genreTags", "language", "labelOrCompany", "releaseDate",
            "qqMusicSongMid", "metadataSource", "metadataFetchedAt",
            "metadataConfidence", "musicBrainzReleaseID", "lyricsTimeOffsetMs",
            "artistCredits"
        ]
        guard Set(values.keys).isSubset(of: allowed) else {
            throw AutomationParameterError.invalidValue("patch")
        }
        func stringValue(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null: return nil
            case .string(let string): return string
            default:
                throw AutomationParameterError.invalidType(key, expected: "string or null")
            }
        }
        func stringArrayValue(_ key: String) throws -> [String]? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .array(let array):
                let strings = try array.map { value -> String in
                    guard case .string(let string) = value else {
                        throw AutomationParameterError.invalidType(key, expected: "array of strings")
                    }
                    return string
                }
                return strings
            default:
                throw AutomationParameterError.invalidType(key, expected: "array of strings or null")
            }
        }
        func dateValue(_ key: String) throws -> Date? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .string(let string):
                guard let date = ISO8601DateFormatter().date(from: string) else {
                    throw AutomationParameterError.invalidValue(key)
                }
                return date
            default:
                throw AutomationParameterError.invalidType(key, expected: "ISO-8601 string or null")
            }
        }
        func numberValue(
            _ key: String,
            range: ClosedRange<Double>? = nil
        ) throws -> Double? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .number(let number):
                guard number.isFinite, range?.contains(number) ?? true else {
                    throw AutomationParameterError.outOfRange(key)
                }
                return number
            default:
                throw AutomationParameterError.invalidType(key, expected: "number or null")
            }
        }
        func artistCreditsValue(_ key: String) throws -> [TrackCredit]? {
            guard let value = values[key] else { return nil }
            switch value {
            case .null:
                return nil
            case .array(let array):
                guard array.count <= 500 else {
                    throw AutomationParameterError.outOfRange(key)
                }
                return try array.map { value in
                    guard case .object(let object) = value else {
                        throw AutomationParameterError.invalidType(key, expected: "array of credit objects")
                    }
                    guard case .string(let displayName)? = object["displayName"],
                          !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AutomationParameterError.invalidValue("\(key).displayName")
                    }
                    let id: UUID
                    if let rawID = object["id"] {
                        guard case .string(let stringID) = rawID,
                              let parsedID = UUID(uuidString: stringID) else {
                            throw AutomationParameterError.invalidValue("\(key).id")
                        }
                        id = parsedID
                    } else {
                        id = UUID()
                    }
                    let canonicalName: String?
                    if let value = object["canonicalName"] {
                        switch value {
                        case .null:
                            canonicalName = nil
                        case .string(let string):
                            canonicalName = string
                        default:
                            throw AutomationParameterError.invalidType(
                                "\(key).canonicalName",
                                expected: "string or null"
                            )
                        }
                    } else {
                        canonicalName = nil
                    }
                    let role: TrackCreditRole
                    if let value = object["role"] {
                        guard case .string(let rawRole) = value,
                              let parsedRole = TrackCreditRole(rawValue: rawRole) else {
                            throw AutomationParameterError.invalidValue("\(key).role")
                        }
                        role = parsedRole
                    } else {
                        role = .primary
                    }
                    return TrackCredit(
                        id: id,
                        displayName: displayName,
                        role: role,
                        canonicalName: canonicalName
                    )
                }
            default:
                throw AutomationParameterError.invalidType(key, expected: "array of credit objects or null")
            }
        }
        return LibraryAutomationMetadataPatch(
            fields: Set(values.keys),
            title: try stringValue("title"),
            artist: try stringValue("artist"),
            album: try stringValue("album"),
            albumArtist: try stringValue("albumArtist"),
            userDescription: try stringValue("description"),
            genreTags: try stringArrayValue("genreTags"),
            language: try stringValue("language"),
            labelOrCompany: try stringValue("labelOrCompany"),
            releaseDate: try dateValue("releaseDate"),
            qqMusicSongMid: try stringValue("qqMusicSongMid"),
            metadataSource: try stringValue("metadataSource"),
            metadataFetchedAt: try dateValue("metadataFetchedAt"),
            metadataConfidence: try numberValue("metadataConfidence", range: 0...1),
            musicBrainzReleaseID: try stringValue("musicBrainzReleaseID"),
            lyricsTimeOffsetMs: try numberValue("lyricsTimeOffsetMs", range: -120_000...120_000),
            artistCredits: try artistCreditsValue("artistCredits")
        )
    }

    private func patchStringValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> String? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw AutomationParameterError.invalidType(key, expected: "string or null")
        }
    }

    private func patchStringArrayValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> [String]? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .array(let values):
            return try values.map { value in
                guard case .string(let string) = value else {
                    throw AutomationParameterError.invalidType(key, expected: "array of strings or null")
                }
                return string
            }
        default:
            throw AutomationParameterError.invalidType(key, expected: "array of strings or null")
        }
    }

    private func patchDateValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> Date? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .string(let string):
            guard let date = ISO8601DateFormatter().date(from: string) else {
                throw AutomationParameterError.invalidValue(key)
            }
            return date
        default:
            throw AutomationParameterError.invalidType(key, expected: "ISO-8601 string or null")
        }
    }

    private func patchIntValue(
        _ values: [String: AutomationJSONValue],
        key: String,
        range: ClosedRange<Int>? = nil
    ) throws -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .number(let number):
            guard number.isFinite, number.rounded() == number else {
                throw AutomationParameterError.invalidValue(key)
            }
            let integer = Int(number)
            guard range?.contains(integer) ?? true else {
                throw AutomationParameterError.outOfRange(key)
            }
            return integer
        default:
            throw AutomationParameterError.invalidType(key, expected: "integer or null")
        }
    }

    private func patchConfidenceValue(
        _ values: [String: AutomationJSONValue],
        key: String
    ) throws -> Double? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null:
            return nil
        case .number(let number):
            guard number.isFinite, (0...1).contains(number) else {
                throw AutomationParameterError.outOfRange(key)
            }
            return number
        default:
            throw AutomationParameterError.invalidType(key, expected: "number or null")
        }
    }

    private func makeArtistMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationArtistMetadataPatch {
        let allowed: Set<String> = [
            "displayName", "description", "genreTags", "region", "foreignName",
            "qqMusicSingerMid", "metadataSource", "metadataFetchedAt", "metadataConfidence"
        ]
        guard Set(values.keys).isSubset(of: allowed), !values.isEmpty else {
            throw AutomationParameterError.invalidValue("patch")
        }
        return LibraryAutomationArtistMetadataPatch(
            fields: Set(values.keys),
            displayName: try patchStringValue(values, key: "displayName"),
            description: try patchStringValue(values, key: "description"),
            genreTags: try patchStringArrayValue(values, key: "genreTags"),
            region: try patchStringValue(values, key: "region"),
            foreignName: try patchStringValue(values, key: "foreignName"),
            qqMusicSingerMid: try patchStringValue(values, key: "qqMusicSingerMid"),
            metadataSource: try patchStringValue(values, key: "metadataSource"),
            metadataFetchedAt: try patchDateValue(values, key: "metadataFetchedAt"),
            metadataConfidence: try patchConfidenceValue(values, key: "metadataConfidence")
        )
    }

    private func makeAlbumMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationAlbumMetadataPatch {
        let allowed: Set<String> = [
            "displayTitle", "description", "year", "releaseYear", "releaseDate", "albumType",
            "genreTags", "language", "labelOrCompany", "qqMusicAlbumMid", "metadataSource",
            "metadataFetchedAt", "metadataConfidence"
        ]
        guard Set(values.keys).isSubset(of: allowed), !values.isEmpty else {
            throw AutomationParameterError.invalidValue("patch")
        }
        return LibraryAutomationAlbumMetadataPatch(
            fields: Set(values.keys),
            displayTitle: try patchStringValue(values, key: "displayTitle"),
            description: try patchStringValue(values, key: "description"),
            year: try patchIntValue(values, key: "year", range: 0...9999),
            releaseYear: try patchIntValue(values, key: "releaseYear", range: 0...9999),
            releaseDate: try patchDateValue(values, key: "releaseDate"),
            albumType: try patchStringValue(values, key: "albumType"),
            genreTags: try patchStringArrayValue(values, key: "genreTags"),
            language: try patchStringValue(values, key: "language"),
            labelOrCompany: try patchStringValue(values, key: "labelOrCompany"),
            qqMusicAlbumMid: try patchStringValue(values, key: "qqMusicAlbumMid"),
            metadataSource: try patchStringValue(values, key: "metadataSource"),
            metadataFetchedAt: try patchDateValue(values, key: "metadataFetchedAt"),
            metadataConfidence: try patchConfidenceValue(values, key: "metadataConfidence")
        )
    }

    private func artistMetadataPatchChanges(
        _ entry: ArtistEntry,
        patch: LibraryAutomationArtistMetadataPatch
    ) -> Bool {
        if patch.fields.contains("displayName"),
           let value = patch.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           entry.displayName != value {
            return true
        }
        if patch.fields.contains("description"), entry.description != (patch.description ?? "") { return true }
        if patch.fields.contains("genreTags"), entry.genreTags != (patch.genreTags ?? []) { return true }
        if patch.fields.contains("region"), entry.region != (patch.region ?? "") { return true }
        if patch.fields.contains("foreignName"), entry.foreignName != (patch.foreignName ?? "") { return true }
        if patch.fields.contains("qqMusicSingerMid"), entry.qqMusicSingerMid != patch.qqMusicSingerMid { return true }
        if patch.fields.contains("metadataSource"), entry.metadataSource != patch.metadataSource { return true }
        if patch.fields.contains("metadataFetchedAt"), entry.metadataFetchedAt != patch.metadataFetchedAt { return true }
        if patch.fields.contains("metadataConfidence"), entry.metadataConfidence != patch.metadataConfidence { return true }
        return false
    }

    private func albumMetadataPatchChanges(
        _ entry: AlbumEntry,
        patch: LibraryAutomationAlbumMetadataPatch
    ) -> Bool {
        if patch.fields.contains("displayTitle"),
           let value = patch.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           entry.displayTitle != value {
            return true
        }
        if patch.fields.contains("description"), entry.description != (patch.description ?? "") { return true }
        if patch.fields.contains("year"), entry.year != patch.year { return true }
        if patch.fields.contains("releaseYear"), entry.releaseYear != patch.releaseYear { return true }
        if patch.fields.contains("releaseDate"), entry.releaseDate != patch.releaseDate { return true }
        if patch.fields.contains("albumType"), entry.albumType != (patch.albumType ?? "") { return true }
        if patch.fields.contains("genreTags"), entry.genreTags != (patch.genreTags ?? []) { return true }
        if patch.fields.contains("language"), entry.language != (patch.language ?? "") { return true }
        if patch.fields.contains("labelOrCompany"), entry.labelOrCompany != (patch.labelOrCompany ?? "") { return true }
        if patch.fields.contains("qqMusicAlbumMid"), entry.qqMusicAlbumMid != patch.qqMusicAlbumMid { return true }
        if patch.fields.contains("metadataSource"), entry.metadataSource != patch.metadataSource { return true }
        if patch.fields.contains("metadataFetchedAt"), entry.metadataFetchedAt != patch.metadataFetchedAt { return true }
        if patch.fields.contains("metadataConfidence"), entry.metadataConfidence != patch.metadataConfidence { return true }
        return false
    }

    private func makePlaylistMetadataPatchValues(
        _ values: [String: AutomationJSONValue]
    ) throws -> (fields: Set<String>, name: String?, description: String?) {
        let allowed: Set<String> = ["name", "description"]
        guard !values.isEmpty, Set(values.keys).isSubset(of: allowed) else {
            throw AutomationParameterError.invalidValue("patch")
        }
        let name: String?
        if values["name"] != nil {
            switch values["name"] {
            case .null:
                name = nil
            case .string(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 255 else {
                    throw AutomationParameterError.outOfRange("patch.name")
                }
                name = trimmed
            default:
                throw AutomationParameterError.invalidType("patch.name", expected: "string or null")
            }
        } else {
            name = nil
        }

        let description: String?
        if values["description"] != nil {
            switch values["description"] {
            case .null:
                description = ""
            case .string(let value):
                description = value
            default:
                throw AutomationParameterError.invalidType("patch.description", expected: "string or null")
            }
        } else {
            description = nil
        }
        return (Set(values.keys), name, description)
    }

    private func hasArtworkTargetParameters(
        _ parameters: AutomationParameters,
        excludingTrackIDs: Bool = false
    ) throws -> Bool {
        let trackID = try parameters.uuid("trackID")
        let artistID = try parameters.uuid("artistID")
        let albumKey = try parameters.string("albumKey")
        let playlistID = try parameters.uuid("playlistID")
        if excludingTrackIDs {
            return trackID != nil || artistID != nil || albumKey != nil || playlistID != nil
        }
        return trackID != nil || artistID != nil || albumKey != nil || playlistID != nil
    }

    private func resolveArtworkTarget(
        from parameters: AutomationParameters,
        session: LibrarySession,
        allowPlaylist: Bool
    ) throws -> ArtworkTarget {
        let trackID = try parameters.uuid("trackID")
        let artistID = try parameters.uuid("artistID")
        let rawAlbumKey = try parameters.string("albumKey")
        let albumKey = rawAlbumKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistID = try parameters.uuid("playlistID")
        let targetCount = [trackID != nil, artistID != nil, albumKey != nil, playlistID != nil]
            .filter { $0 }
            .count
        guard targetCount == 1 else {
            throw AutomationParameterError.missing("exactly one of trackID, artistID, albumKey or playlistID")
        }

        if let trackID {
            guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                throw AutomationParameterError.missingResource("trackID")
            }
            return .track(track)
        }
        if let artistID {
            guard let artist = session.libraryViewModel.artistEntries.first(where: { $0.id == artistID }) else {
                throw AutomationParameterError.missingResource("artistID")
            }
            return .artist(artist)
        }
        if let albumKey {
            guard !albumKey.isEmpty else {
                throw AutomationParameterError.invalidValue("albumKey")
            }
            guard let album = session.libraryViewModel.albumEntries.first(where: { $0.canonicalKey == albumKey }) else {
                throw AutomationParameterError.missingResource("albumKey")
            }
            return .album(album)
        }
        guard allowPlaylist else {
            throw AutomationParameterError.invalidValue("playlistID")
        }
        guard let playlistID,
              let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
            throw AutomationParameterError.missingResource("playlistID")
        }
        return .playlist(playlist)
    }

    private func makeArtworkInfo(
        _ target: ArtworkTarget,
        session: LibrarySession
    ) -> AutomationArtworkInfo {
        switch target {
        case .track(let track):
            let data = track.loadArtworkDataIfNeeded()
            return AutomationArtworkInfo(
                targetType: target.type,
                trackID: track.id,
                available: data != nil || track.artworkFileName != nil,
                fileName: track.artworkFileName,
                byteCount: data?.count,
                sha256: artworkDigest(data),
                revision: session.libraryViewModel.automationArtworkRevision(for: track)
            )
        case .artist(let entry):
            return AutomationArtworkInfo(
                targetType: target.type,
                artistID: entry.id,
                available: entry.hasArtwork,
                fileName: entry.artworkFileName,
                byteCount: entry.artworkData?.count,
                sha256: artworkDigest(entry.artworkData),
                revision: session.libraryViewModel.automationArtworkRevision(for: entry)
            )
        case .album(let entry):
            return AutomationArtworkInfo(
                targetType: target.type,
                albumKey: entry.canonicalKey,
                available: entry.hasArtwork,
                fileName: entry.artworkFileName,
                byteCount: entry.artworkData?.count,
                sha256: artworkDigest(entry.artworkData),
                revision: session.libraryViewModel.automationArtworkRevision(for: entry)
            )
        case .playlist(let playlist):
            let sidecar = session.libraryService.loadPlaylistSidecar(playlistID: playlist.id)
            let fileName: String?
            switch sidecar?.headerArtworkSource ?? .none {
            case .custom:
                fileName = sidecar?.customHeaderArtworkFileName
            case .generated:
                fileName = sidecar?.generatedHeaderArtworkFileName
            case .none:
                fileName = nil
            }
            let data = fileName.flatMap {
                try? Data(contentsOf: session.libraryService.paths.playlistsRootURL.appendingPathComponent($0))
            }
            return AutomationArtworkInfo(
                targetType: target.type,
                playlistID: playlist.id,
                available: data != nil || fileName != nil,
                fileName: fileName,
                byteCount: data?.count,
                sha256: artworkDigest(data),
                revision: session.libraryViewModel.automationArtworkRevision(for: playlist)
            )
        }
    }

    private func artworkDigest(_ data: Data?) -> String? {
        guard let data else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func artworkRevision(
        for target: ArtworkTarget,
        session: LibrarySession
    ) -> String {
        switch target {
        case .track(let track): return session.libraryViewModel.automationArtworkRevision(for: track)
        case .artist(let entry): return session.libraryViewModel.automationArtworkRevision(for: entry)
        case .album(let entry): return session.libraryViewModel.automationArtworkRevision(for: entry)
        case .playlist(let playlist): return session.libraryViewModel.automationArtworkRevision(for: playlist)
        }
    }

    private struct ResolvedArtworkInput {
        let kind: String
        let data: Data?
    }

    private func resolveArtworkInput(
        clear: Bool,
        imagePath: String?,
        imageBase64: String?
    ) async throws -> ResolvedArtworkInput? {
        if clear {
            return ResolvedArtworkInput(kind: "clear", data: nil)
        }
        if let imageBase64 {
            let encoded = imageBase64.hasPrefix("data:")
                ? (imageBase64.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "")
                : imageBase64
            guard let data = Data(base64Encoded: encoded),
                  data.count <= 16 * 1024 * 1024,
                  ArtworkDataNormalizer.isDecodableImage(data) else {
                throw AutomationParameterError.invalidValue("imageBase64")
            }
            let normalized = ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data
            return ResolvedArtworkInput(kind: "imageBase64", data: normalized)
        }

        if let imagePath {
            let expanded = AutomationInteraction.expandPath(imagePath)
            let directURL = URL(fileURLWithPath: expanded)
            if let data = try? Data(contentsOf: directURL),
               data.count <= 16 * 1024 * 1024,
               ArtworkDataNormalizer.isDecodableImage(data) {
                return ResolvedArtworkInput(
                    kind: "imagePath",
                    data: ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data
                )
            }
        }

        guard let selectedURL = try await AutomationInteraction.requestArtworkURL(
            requestedPath: imagePath.map(AutomationInteraction.expandPath(_:))
        ) else {
            return nil
        }
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            let accessed = selectedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { selectedURL.stopAccessingSecurityScopedResource() }
            }
            return try? Data(contentsOf: selectedURL)
        }.value
        guard let data,
              data.count <= 16 * 1024 * 1024,
              ArtworkDataNormalizer.isDecodableImage(data) else {
            throw AutomationParameterError.invalidValue("imagePath")
        }
        return ResolvedArtworkInput(
            kind: imagePath == nil ? "picker" : "imagePath",
            data: ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data
        )
    }

    private func applyArtworkToSingleTarget(
        parameters: AutomationParameters,
        request: AutomationRequest,
        session: LibrarySession
    ) async throws -> AutomationResponse {
        guard try hasArtworkTargetParameters(parameters) else {
            throw AutomationParameterError.missing("artwork target")
        }
        guard try parameters.object("expectedRevisions") == nil else {
            throw AutomationParameterError.invalidValue("expectedRevisions")
        }
        let target = try resolveArtworkTarget(from: parameters, session: session, allowPlaylist: true)
        let clear = try parameters.boolean("clear", default: false)
        let imagePath = try parameters.string("imagePath")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageBase64 = try parameters.string("imageBase64")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedRevision = try parameters.string("expectedRevision")
        let dryRun = try parameters.boolean("dryRun", default: false)
        let confirm = try parameters.boolean("confirm", default: false)
        guard !(clear && (imagePath != nil || imageBase64 != nil)) else {
            throw AutomationParameterError.invalidValue("clear")
        }
        guard !(imagePath != nil && imageBase64 != nil) else {
            throw AutomationParameterError.invalidValue("imagePath/imageBase64")
        }
        if let imagePath, imagePath.isEmpty { throw AutomationParameterError.invalidValue("imagePath") }
        if let imageBase64, imageBase64.isEmpty { throw AutomationParameterError.invalidValue("imageBase64") }

        let info = makeArtworkInfo(target, session: session)
        let actualRevision = artworkRevision(for: target, session: session)
        let compatibleRevision: String? = {
            switch target {
            case .track(let track): return session.libraryViewModel.automationTrackRevision(for: track)
            case .artist(let entry): return session.libraryViewModel.automationArtistRevision(for: entry)
            case .album(let entry): return session.libraryViewModel.automationAlbumRevision(for: entry)
            case .playlist(let playlist): return session.libraryViewModel.automationPlaylistRevision(for: playlist)
            }
        }()
        let isConflict = expectedRevision.map {
            $0 != actualRevision && $0 != compatibleRevision
        } ?? false
        let targetID: UUID? = {
            switch target {
            case .track(let track): return track.id
            case .artist(let entry): return entry.id
            case .album, .playlist: return nil
            }
        }()
        let targetArtistID: UUID? = {
            if case .artist(let entry) = target { return entry.id }
            return nil
        }()
        let targetTrackIDs: [UUID] = {
            if case .track(let track) = target { return [track.id] }
            return []
        }()
        let targetArtistIDs: [UUID] = {
            if case .artist(let entry) = target { return [entry.id] }
            return []
        }()
        let targetAlbumIDs = ifCaseAlbumID(target)
        let targetPlaylistIDs = ifCasePlaylistID(target).map { [$0] } ?? []
        let changed = !isConflict && (clear ? info.available : true)
        let inputKind = clear ? "clear" : imageBase64 != nil ? "imageBase64" : imagePath != nil ? "imagePath" : "picker"

        func result(
            applied: Bool,
            dryRun: Bool,
            confirmed: Bool,
            input: String,
            outcome: LibraryAutomationEntityArtworkMutationOutcome? = nil,
            trackOutcome: LibraryAutomationArtworkMutationOutcome? = nil,
            conflict: Bool = false,
            previewChanged: Bool? = nil,
            message: String
        ) -> AutomationResponse {
            let conflictedTrackIDs: [UUID]
            let conflictedArtistIDs: [UUID]
            let conflictedAlbumIDs: [UUID]
            let conflictedPlaylistIDs: [UUID]
            if let trackOutcome {
                conflictedTrackIDs = trackOutcome.conflictedTrackIDs
                conflictedArtistIDs = []
                conflictedAlbumIDs = []
                conflictedPlaylistIDs = []
            } else if let outcome {
                conflictedTrackIDs = []
                conflictedArtistIDs = outcome.conflictedArtistIDs
                conflictedAlbumIDs = outcome.conflictedAlbumIDs
                conflictedPlaylistIDs = outcome.conflictedPlaylistIDs
            } else if conflict {
                conflictedTrackIDs = targetID.flatMap { targetArtistID == nil ? [$0] : [] } ?? []
                conflictedArtistIDs = targetArtistID.map { [$0] } ?? []
                conflictedAlbumIDs = ifCaseAlbumID(target)
                conflictedPlaylistIDs = ifCasePlaylistID(target).map { [$0] } ?? []
            } else {
                conflictedTrackIDs = []
                conflictedArtistIDs = []
                conflictedAlbumIDs = []
                conflictedPlaylistIDs = []
            }
            let previewUpdatedTrackIDs = previewChanged == true ? targetTrackIDs : []
            let previewSkippedTrackIDs = previewChanged == false ? targetTrackIDs : []
            let previewUpdatedArtistIDs = previewChanged == true ? targetArtistIDs : []
            let previewSkippedArtistIDs = previewChanged == false ? targetArtistIDs : []
            let previewUpdatedAlbumIDs = previewChanged == true ? targetAlbumIDs : []
            let previewSkippedAlbumIDs = previewChanged == false ? targetAlbumIDs : []
            let previewUpdatedPlaylistIDs = previewChanged == true ? targetPlaylistIDs : []
            let previewSkippedPlaylistIDs = previewChanged == false ? targetPlaylistIDs : []
            return AutomationResponseSupport.encodeResult(
                AutomationArtworkMutationResult(
                    targetType: target.type,
                    trackID: targetID.flatMap { targetArtistID == nil ? $0 : nil },
                    artistID: targetArtistID,
                    albumKey: ifCaseAlbumKey(target),
                    playlistID: ifCasePlaylistID(target),
                    applied: applied,
                    dryRun: dryRun,
                    confirmed: confirmed,
                    input: input,
                    updatedTrackIDs: trackOutcome?.updatedTrackIDs ?? previewUpdatedTrackIDs,
                    skippedTrackIDs: trackOutcome?.skippedTrackIDs ?? previewSkippedTrackIDs,
                    conflictedTrackIDs: conflictedTrackIDs,
                    updatedArtistIDs: outcome?.updatedArtistIDs ?? previewUpdatedArtistIDs,
                    skippedArtistIDs: outcome?.skippedArtistIDs ?? previewSkippedArtistIDs,
                    conflictedArtistIDs: conflictedArtistIDs,
                    updatedAlbumIDs: outcome?.updatedAlbumIDs ?? previewUpdatedAlbumIDs,
                    skippedAlbumIDs: outcome?.skippedAlbumIDs ?? previewSkippedAlbumIDs,
                    conflictedAlbumIDs: conflictedAlbumIDs,
                    updatedPlaylistIDs: outcome?.updatedPlaylistIDs ?? previewUpdatedPlaylistIDs,
                    skippedPlaylistIDs: outcome?.skippedPlaylistIDs ?? previewSkippedPlaylistIDs,
                    conflictedPlaylistIDs: conflictedPlaylistIDs,
                    message: message
                ),
                for: request
            )
        }

        if isConflict {
            return result(
                applied: false,
                dryRun: dryRun,
                confirmed: false,
                input: inputKind,
                conflict: true,
                message: "The target artwork changed after it was queried; nothing was written."
            )
        }

        if dryRun {
            if let imageBase64 {
                _ = try await resolveArtworkInput(clear: false, imagePath: nil, imageBase64: imageBase64)
            }
            return result(
                applied: false,
                dryRun: true,
                confirmed: false,
                input: inputKind,
                previewChanged: changed,
                message: changed
                    ? "Preview only. App-owned artwork will be replaced or cleared; original audio-file tags will not be changed."
                    : "Preview only. The target is already clear and would be skipped."
            )
        }

        let resolvedInput = try await resolveArtworkInput(
            clear: clear,
            imagePath: imagePath,
            imageBase64: imageBase64
        )
        guard let resolvedInput else {
            return AutomationResponseSupport.interactionCancelled(for: request)
        }

        switch target {
        case .track(let track):
            let outcome = try await session.libraryViewModel.applyArtworkForAutomation(
                trackIDs: [track.id],
                artworkData: resolvedInput.data,
                expectedRevisions: expectedRevision.map { [track.id: $0] } ?? [:]
            )
            return result(
                applied: !outcome.updatedTrackIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                trackOutcome: outcome,
                message: "App-owned artwork updated; original audio-file tags were not changed."
            )
        case .artist(let entry):
            let outcome = try await session.libraryViewModel.applyArtistArtworkForAutomation(
                artistID: entry.id,
                artworkData: resolvedInput.data,
                expectedRevision: expectedRevision
            )
            return result(
                applied: !outcome.updatedArtistIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                outcome: outcome,
                message: "App-owned Artist artwork updated."
            )
        case .album(let entry):
            let outcome = try await session.libraryViewModel.applyAlbumArtworkForAutomation(
                albumID: entry.id,
                artworkData: resolvedInput.data,
                expectedRevision: expectedRevision
            )
            return result(
                applied: !outcome.updatedAlbumIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                outcome: outcome,
                message: "App-owned Album artwork updated."
            )
        case .playlist(let playlist):
            let outcome = try await session.libraryViewModel.applyPlaylistArtworkForAutomation(
                playlistID: playlist.id,
                artworkData: resolvedInput.data,
                expectedRevision: expectedRevision
            )
            return result(
                applied: !outcome.updatedPlaylistIDs.isEmpty,
                dryRun: false,
                confirmed: confirm,
                input: resolvedInput.kind,
                outcome: outcome,
                message: "App-owned Playlist artwork updated."
            )
        }
    }

    private func applyMetadataToSingleTarget(
        parameters: AutomationParameters,
        request: AutomationRequest,
        session: LibrarySession
    ) async throws -> AutomationResponse {
        guard let patchValues = try parameters.object("patch"), !patchValues.isEmpty else {
            throw AutomationParameterError.missing("patch")
        }
        let expectedRevision = try parameters.string("expectedRevision")
        guard try parameters.object("expectedRevisions") == nil else {
            throw AutomationParameterError.invalidValue("expectedRevisions")
        }
        let dryRun = try parameters.boolean("dryRun", default: false)
        let target: MetadataTarget
        if let trackID = try parameters.uuid("trackID") {
            guard try !hasMetadataEntityTarget(parameters) else {
                throw AutomationParameterError.invalidValue("metadata target")
            }
            guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                throw AutomationParameterError.missingResource("trackID")
            }
            target = .track(track)
        } else {
            target = try resolveMetadataTarget(
                artistID: try parameters.uuid("artistID"),
                albumKey: try parameters.string("albumKey")?.trimmingCharacters(in: .whitespacesAndNewlines),
                playlistID: try parameters.uuid("playlistID"),
                session: session
            )
        }

        switch target {
        case .track(let track):
            let patch = try makeMetadataPatch(patchValues)
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationTrackRevision(for: track)
            let changed = !conflict && metadataPatchChanges(track, patch: patch)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedTrackIDs: changed ? [track.id] : [],
                        skippedTrackIDs: !changed && !conflict ? [track.id] : [],
                        conflictedTrackIDs: conflict ? [track.id] : [],
                        message: "Preview only. This updates App-owned metadata and never writes embedded file tags."
                    ),
                    for: request
                )
            }
            let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                trackIDs: [track.id],
                patch: patch,
                expectedRevisions: expectedRevision.map { [track.id: $0] } ?? [:]
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: !outcome.updatedTrackIDs.isEmpty,
                    dryRun: false,
                    updatedTrackIDs: outcome.updatedTrackIDs,
                    skippedTrackIDs: outcome.skippedTrackIDs,
                    conflictedTrackIDs: outcome.conflictedTrackIDs,
                    message: "App metadata updated; original file tags were not changed."
                ),
                for: request
            )
        case .artist(let entry):
            let patch = try makeArtistMetadataPatch(patchValues)
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationArtistRevision(for: entry)
            let changed = !conflict && artistMetadataPatchChanges(entry, patch: patch)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedArtistIDs: changed ? [entry.id] : [],
                        skippedArtistIDs: !changed && !conflict ? [entry.id] : [],
                        conflictedArtistIDs: conflict ? [entry.id] : [],
                        message: "Preview only. Artist metadata is App-owned and sidecar-backed."
                    ),
                    for: request
                )
            }
            let outcome = try await session.libraryViewModel.applyArtistMetadataPatchForAutomation(
                artistID: entry.id,
                patch: patch,
                expectedRevision: expectedRevision
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: !outcome.updatedArtistIDs.isEmpty,
                    dryRun: false,
                    updatedArtistIDs: outcome.updatedArtistIDs,
                    skippedArtistIDs: outcome.skippedArtistIDs,
                    conflictedArtistIDs: outcome.conflictedArtistIDs,
                    message: "Artist metadata updated in the App-owned sidecar."
                ),
                for: request
            )
        case .album(let entry):
            let patch = try makeAlbumMetadataPatch(patchValues)
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationAlbumRevision(for: entry)
            let changed = !conflict && albumMetadataPatchChanges(entry, patch: patch)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedAlbumIDs: changed ? [entry.id] : [],
                        skippedAlbumIDs: !changed && !conflict ? [entry.id] : [],
                        conflictedAlbumIDs: conflict ? [entry.id] : [],
                        message: "Preview only. Album metadata is App-owned and sidecar-backed."
                    ),
                    for: request
                )
            }
            let outcome = try await session.libraryViewModel.applyAlbumMetadataPatchForAutomation(
                albumID: entry.id,
                patch: patch,
                expectedRevision: expectedRevision
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: !outcome.updatedAlbumIDs.isEmpty,
                    dryRun: false,
                    updatedAlbumIDs: outcome.updatedAlbumIDs,
                    skippedAlbumIDs: outcome.skippedAlbumIDs,
                    conflictedAlbumIDs: outcome.conflictedAlbumIDs,
                    message: "Album metadata updated in the App-owned sidecar."
                ),
                for: request
            )
        case .playlist(let playlist):
            let patch = try makePlaylistMetadataPatchValues(patchValues)
            let desiredName = patch.fields.contains("name") ? (patch.name ?? playlist.name) : playlist.name
            let desiredDescription = patch.fields.contains("description") ? (patch.description ?? playlist.userDescription) : playlist.userDescription
            let conflict = expectedRevision != nil && expectedRevision != session.libraryViewModel.automationPlaylistRevision(for: playlist)
            let changed = !conflict && (desiredName != playlist.name || desiredDescription != playlist.userDescription)
            if dryRun {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: true,
                        updatedPlaylistIDs: changed ? [playlist.id] : [],
                        skippedPlaylistIDs: !changed && !conflict ? [playlist.id] : [],
                        conflictedPlaylistIDs: conflict ? [playlist.id] : [],
                        message: "Preview only. Playlist name and description are App-owned metadata."
                    ),
                    for: request
                )
            }
            guard !conflict else {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: false,
                        conflictedPlaylistIDs: [playlist.id],
                        message: "The Playlist changed after it was queried; nothing was written."
                    ),
                    for: request
                )
            }
            guard changed else {
                return AutomationResponseSupport.encodeResult(
                    AutomationMetadataMutationResult(
                        applied: false,
                        dryRun: false,
                        skippedPlaylistIDs: [playlist.id],
                        message: "Playlist metadata already matches the requested values."
                    ),
                    for: request
                )
            }
            let updated = try await session.libraryViewModel.renamePlaylistForAutomation(
                playlist,
                name: desiredName,
                description: desiredDescription,
                expectedRevision: expectedRevision
            )
            return AutomationResponseSupport.encodeResult(
                AutomationMetadataMutationResult(
                    applied: true,
                    dryRun: false,
                    updatedPlaylistIDs: [updated.id],
                    message: "Playlist metadata updated."
                ),
                for: request
            )
        }
    }

    private func ifCaseAlbumKey(_ target: ArtworkTarget) -> String? {
        if case .album(let entry) = target { return entry.canonicalKey }
        return nil
    }

    private func ifCaseAlbumID(_ target: ArtworkTarget) -> [UUID] {
        if case .album(let entry) = target { return [entry.id] }
        return []
    }

    private func ifCasePlaylistID(_ target: ArtworkTarget) -> UUID? {
        if case .playlist(let playlist) = target { return playlist.id }
        return nil
    }

    private func hasMetadataEntityTarget(_ parameters: AutomationParameters) throws -> Bool {
        let artistID = try parameters.uuid("artistID")
        let albumKey = try parameters.string("albumKey")
        let playlistID = try parameters.uuid("playlistID")
        return artistID != nil || albumKey != nil || playlistID != nil
    }

    private func resolveMetadataTarget(
        artistID: UUID?,
        albumKey: String?,
        playlistID: UUID?,
        session: LibrarySession
    ) throws -> MetadataTarget {
        let normalizedAlbumKey = albumKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = [artistID != nil, normalizedAlbumKey != nil, playlistID != nil]
            .filter { $0 }
            .count
        guard count == 1 else {
            throw AutomationParameterError.missing("exactly one of artistID, albumKey or playlistID")
        }
        if let artistID {
            guard let entry = session.libraryViewModel.artistEntries.first(where: { $0.id == artistID }) else {
                throw AutomationParameterError.missingResource("artistID")
            }
            return .artist(entry)
        }
        if let normalizedAlbumKey {
            guard !normalizedAlbumKey.isEmpty else {
                throw AutomationParameterError.invalidValue("albumKey")
            }
            guard let entry = session.libraryViewModel.albumEntries.first(where: {
                $0.canonicalKey == normalizedAlbumKey
            }) else {
                throw AutomationParameterError.missingResource("albumKey")
            }
            return .album(entry)
        }
        guard let playlistID,
              let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
            throw AutomationParameterError.missingResource("playlistID")
        }
        return .playlist(playlist)
    }

    private func makeMetadataGetResult(
        for target: MetadataTarget,
        session: LibrarySession
    ) -> AutomationMetadataGetResult {
        switch target {
        case .track(let track):
            return AutomationMetadataGetResult(
                tracks: [queries.makeTrackSummary(track, playlists: session.libraryViewModel.playlists)],
                total: 1,
                revision: session.libraryViewModel.automationTrackRevision(for: track)
            )
        case .artist(let entry):
            return AutomationMetadataGetResult(
                artists: [makeArtistMetadata(entry, session: session)],
                total: 1,
                revision: session.libraryViewModel.automationArtistRevision(for: entry)
            )
        case .album(let entry):
            return AutomationMetadataGetResult(
                albums: [makeAlbumMetadata(entry, session: session)],
                total: 1,
                revision: session.libraryViewModel.automationAlbumRevision(for: entry)
            )
        case .playlist(let playlist):
            return AutomationMetadataGetResult(
                playlists: [queries.makePlaylistSummary(playlist)],
                total: 1,
                revision: queries.makePlaylistSummary(playlist).revision
            )
        }
    }

    private func makeMetadataCollectionResult(
        entityType: String,
        query: String?,
        offset: Int,
        limit: Int,
        session: LibrarySession
    ) -> AutomationMetadataGetResult {
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = normalizedQuery?.isEmpty == false

        switch entityType {
        case "artist":
            let allEntries = session.libraryViewModel.artistEntries.sorted {
                let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
            let filtered = hasQuery
                ? allEntries.filter { entry in
                    [entry.displayName, entry.canonicalName, entry.description, entry.foreignName]
                        .contains { $0.localizedCaseInsensitiveContains(normalizedQuery!) }
                }
                : allEntries
            let pageStart = min(offset, filtered.count)
            let pageEnd = min(pageStart + limit, filtered.count)
            let page = Array(filtered[pageStart..<pageEnd]).map {
                makeArtistMetadata($0, session: session)
            }
            return AutomationMetadataGetResult(
                artists: page,
                total: filtered.count,
                offset: offset,
                limit: limit,
                nextOffset: pageEnd < filtered.count ? pageEnd : nil,
                revision: metadataCollectionRevision(
                    entityType: entityType,
                    entries: allEntries.map {
                        ($0.id, session.libraryViewModel.automationArtistRevision(for: $0))
                    }
                )
            )

        case "album":
            let allEntries = session.libraryViewModel.albumEntries.sorted {
                let titleOrder = $0.displayTitle.localizedStandardCompare($1.displayTitle)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                if $0.primaryArtistDisplayName != $1.primaryArtistDisplayName {
                    return $0.primaryArtistDisplayName.localizedStandardCompare($1.primaryArtistDisplayName)
                        == .orderedAscending
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            let filtered = hasQuery
                ? allEntries.filter { entry in
                    [
                        entry.displayTitle,
                        entry.canonicalKey,
                        entry.primaryArtistDisplayName,
                        entry.primaryArtistCanonicalName,
                        entry.description
                    ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery!) }
                }
                : allEntries
            let pageStart = min(offset, filtered.count)
            let pageEnd = min(pageStart + limit, filtered.count)
            let page = Array(filtered[pageStart..<pageEnd]).map {
                makeAlbumMetadata($0, session: session)
            }
            return AutomationMetadataGetResult(
                albums: page,
                total: filtered.count,
                offset: offset,
                limit: limit,
                nextOffset: pageEnd < filtered.count ? pageEnd : nil,
                revision: metadataCollectionRevision(
                    entityType: entityType,
                    entries: allEntries.map {
                        ($0.id, session.libraryViewModel.automationAlbumRevision(for: $0))
                    }
                )
            )

        case "playlist":
            let allEntries = session.libraryViewModel.playlists.sorted {
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
            let filtered = hasQuery
                ? allEntries.filter {
                    $0.name.localizedCaseInsensitiveContains(normalizedQuery!)
                        || $0.userDescription.localizedCaseInsensitiveContains(normalizedQuery!)
                }
                : allEntries
            let pageStart = min(offset, filtered.count)
            let pageEnd = min(pageStart + limit, filtered.count)
            let page = Array(filtered[pageStart..<pageEnd]).map(queries.makePlaylistSummary)
            return AutomationMetadataGetResult(
                playlists: page,
                total: filtered.count,
                offset: offset,
                limit: limit,
                nextOffset: pageEnd < filtered.count ? pageEnd : nil,
                revision: metadataCollectionRevision(
                    entityType: entityType,
                    entries: allEntries.map {
                        ($0.id, session.libraryViewModel.automationPlaylistRevision(for: $0))
                    }
                )
            )

        default:
            // The request handler validates this before calling the helper.
            return AutomationMetadataGetResult(total: 0, revision: "v1-invalid")
        }
    }

    private func metadataCollectionRevision(
        entityType: String,
        entries: [(id: UUID, revision: String)]
    ) -> String {
        var fingerprint = entityType
        for entry in entries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            fingerprint.append("\n")
            fingerprint.append(entry.id.uuidString)
            fingerprint.append("\n")
            fingerprint.append(entry.revision)
        }
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1-\(digest)"
    }

    private func makeArtistMetadata(
        _ entry: ArtistEntry,
        session: LibrarySession
    ) -> AutomationArtistMetadata {
        AutomationArtistMetadata(
            id: entry.id,
            canonicalName: entry.canonicalName,
            displayName: entry.displayName,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            description: entry.description,
            genreTags: entry.genreTags,
            region: entry.region,
            foreignName: entry.foreignName,
            qqMusicSingerMid: entry.qqMusicSingerMid,
            metadataSource: entry.metadataSource,
            metadataFetchedAt: entry.metadataFetchedAt,
            metadataConfidence: entry.metadataConfidence,
            artworkAvailable: entry.hasArtwork,
            artworkFileName: entry.artworkFileName,
            trackCount: entry.trackCount,
            albumCount: entry.albumCount,
            totalDuration: entry.totalDuration,
            isOrphaned: entry.isOrphaned,
            revision: session.libraryViewModel.automationArtistRevision(for: entry)
        )
    }

    private func makeAlbumMetadata(
        _ entry: AlbumEntry,
        session: LibrarySession
    ) -> AutomationAlbumMetadata {
        AutomationAlbumMetadata(
            id: entry.id,
            canonicalKey: entry.canonicalKey,
            displayTitle: entry.displayTitle,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            primaryArtistCanonicalName: entry.primaryArtistCanonicalName,
            primaryArtistDisplayName: entry.primaryArtistDisplayName,
            description: entry.description,
            year: entry.year,
            releaseYear: entry.releaseYear,
            releaseDate: entry.releaseDate,
            albumType: entry.albumType,
            genreTags: entry.genreTags,
            language: entry.language,
            labelOrCompany: entry.labelOrCompany,
            qqMusicAlbumMid: entry.qqMusicAlbumMid,
            metadataSource: entry.metadataSource,
            metadataFetchedAt: entry.metadataFetchedAt,
            metadataConfidence: entry.metadataConfidence,
            artworkAvailable: entry.hasArtwork,
            artworkFileName: entry.artworkFileName,
            trackCount: entry.trackCount,
            totalDuration: entry.totalDuration,
            isOrphaned: entry.isOrphaned,
            revision: session.libraryViewModel.automationAlbumRevision(for: entry)
        )
    }

    private func storageDiskSnapshot(
        for session: LibrarySession
    ) async throws -> LibraryUpgradeSessionValidator.DiskSnapshot {
        let context = session.context
        return try await Task.detached(priority: .utility) {
            try LibraryUpgradeSessionValidator.inspectDisk(context: context)
        }.value
    }

    private func makePlaylistReferenceIssues(
        _ issues: [LibraryUpgradeSessionValidator.LibraryStoragePlaylistReferenceIssue]
    ) -> [AutomationPlaylistReferenceIssue] {
        issues.map {
            AutomationPlaylistReferenceIssue(
                playlistID: $0.playlistID,
                playlistName: $0.playlistName,
                missingTrackIDs: $0.missingTrackIDs
            )
        }
    }

    private nonisolated static func automationStorageBackupRoot(
        libraryID: UUID,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) -> URL {
        return automationSupportDirectory(
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(libraryID.uuidString, isDirectory: true)
    }

    private nonisolated static func automationSupportDirectory(
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) -> URL {
        let appSupport = appSupportDirectoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
    }

    private nonisolated static let automationStorageBackupRoots: Set<String> = [
        "Settings",
        "Sources",
        "Tracks",
        "Playlists",
        "Artists",
        "Albums"
    ]

    private nonisolated static let automationStorageBackupExtensions: Set<String> = [
        "json",
        "ttml",
        "lrc",
        "txt",
        "png",
        "jpg",
        "jpeg",
        "webp",
        "heic"
    ]

    private nonisolated static func storageInventory(
        at rootURL: URL
    ) throws -> AutomationStorageInventory {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootPath = root.path
        guard fileManager.fileExists(atPath: rootPath) else {
            throw AutomationParameterError.missingResource("library storage")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AutomationParameterError.invalidValue("library storage")
        }

        var items: [AutomationStorageInventoryItem] = []
        var omittedFileCount = 0
        var failures: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
                omittedFileCount += 1
                if failures.count < 50 {
                    failures.append("Skipped file outside Library root: \(url.path)")
                }
                continue
            }

            guard url.path.hasPrefix(rootPath + "/") else {
                omittedFileCount += 1
                continue
            }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first,
                  (first == "library.json"
                    || automationStorageBackupRoots.contains(String(first))),
                  automationStorageBackupExtensions.contains(url.pathExtension.lowercased()) else {
                omittedFileCount += 1
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                items.append(
                    AutomationStorageInventoryItem(
                        relativePath: relativePath,
                        sourceURL: url,
                        sha256: digest,
                        byteCount: Int64(data.count)
                    )
                )
            } catch {
                if failures.count < 50 {
                    failures.append("Failed to read \(relativePath): \(error.localizedDescription)")
                }
            }
        }
        return AutomationStorageInventory(
            items: items.sorted { $0.relativePath < $1.relativePath },
            omittedFileCount: omittedFileCount,
            failures: failures
        )
    }

    private nonisolated static func createStorageBackup(
        context: LibraryContext,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) throws -> AutomationStorageBackupResult {
        let createdAt = Date()
        let inventory = try storageInventory(at: context.rootURL)
        let fileManager = FileManager.default
        let root = automationStorageBackupRoot(
            libraryID: context.id,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let destination = root.appendingPathComponent(
            "\(stamp)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var copiedFiles: [AutomationStorageBackupManifest.File] = []
        var copiedBytes: Int64 = 0
        var failures = inventory.failures
        for item in inventory.items {
            let target = destination.appendingPathComponent(item.relativePath)
            do {
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: item.sourceURL, to: target)
                copiedFiles.append(
                    AutomationStorageBackupManifest.File(
                        relativePath: item.relativePath,
                        sha256: item.sha256,
                        byteCount: item.byteCount
                    )
                )
                copiedBytes += item.byteCount
            } catch {
                if failures.count < 50 {
                    failures.append("Failed to back up \(item.relativePath): \(error.localizedDescription)")
                }
            }
        }

        let manifest = AutomationStorageBackupManifest(
            schemaVersion: 1,
            libraryID: context.id,
            mode: context.mode.rawValue,
            createdAt: createdAt,
            files: copiedFiles.sorted { $0.relativePath < $1.relativePath }
        )
        let manifestURL = destination.appendingPathComponent("automation-backup.json")
        try AutomationWireCoding.encoder().encode(manifest).write(
            to: manifestURL,
            options: .atomic
        )
        let pruneResult = AutomationStorageBackupRetention.pruneOlderBackups(
            at: root,
            keeping: destination,
            fileManager: fileManager
        )
        failures.append(contentsOf: pruneResult.failures)
        return AutomationStorageBackupResult(
            libraryID: context.id,
            backupPath: destination.path,
            createdAt: createdAt,
            copiedFileCount: copiedFiles.count,
            omittedFileCount: inventory.omittedFileCount,
            copiedBytes: copiedBytes,
            failures: Array(failures.prefix(50)),
            message: "Created a metadata-only backup and retained only the newest snapshot. Audio files, indexes, caches and live SQLite stores were intentionally omitted."
        )
    }

    private nonisolated static func storageBackupManifest(
        context: LibraryContext,
        backupPath: String,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) throws -> (URL, AutomationStorageBackupManifest) {
        let candidate = URL(fileURLWithPath: backupPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = automationStorageBackupRoot(
            libraryID: context.id,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidateValues = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
        guard candidate.path.hasPrefix(root.path + "/"),
              candidateValues?.isDirectory == true else {
            throw AutomationParameterError.invalidValue("backupPath")
        }
        let manifestURL = candidate
            .appendingPathComponent("automation-backup.json")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let manifestValues = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey])
        guard manifestURL.path.hasPrefix(candidate.path + "/"),
              manifestValues?.isRegularFile == true,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? AutomationWireCoding.decoder().decode(
                  AutomationStorageBackupManifest.self,
                  from: data
              ),
              manifest.schemaVersion == 1,
              manifest.libraryID == context.id else {
            throw AutomationParameterError.invalidValue("backupPath")
        }
        return (candidate, manifest)
    }

    private nonisolated static func storageDiff(
        context: LibraryContext,
        backupPath: String,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier,
        appSupportDirectoryURL: URL? = nil
    ) throws -> AutomationStorageDiffResult {
        let (backupURL, manifest) = try storageBackupManifest(
            context: context,
            backupPath: backupPath,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectoryURL: appSupportDirectoryURL
        )
        let current = try storageInventory(at: context.rootURL)
        let currentByPath = Dictionary(uniqueKeysWithValues: current.items.map {
            ($0.relativePath, $0)
        })
        let backupByPath = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.relativePath, $0)
        })
        let currentPaths = Set(currentByPath.keys)
        let backupPaths = Set(backupByPath.keys)
        let added = currentPaths.subtracting(backupPaths).sorted()
        let removed = backupPaths.subtracting(currentPaths).sorted()
        let changed = currentPaths.intersection(backupPaths).filter { path in
            currentByPath[path]?.sha256 != backupByPath[path]?.sha256
        }.sorted()
        let unchangedCount = currentPaths.intersection(backupPaths).count - changed.count
        let maximumReportedPaths = 500
        let truncated = added.count > maximumReportedPaths
            || removed.count > maximumReportedPaths
            || changed.count > maximumReportedPaths
        return AutomationStorageDiffResult(
            libraryID: context.id,
            backupPath: backupURL.path,
            added: Array(added.prefix(maximumReportedPaths)),
            removed: Array(removed.prefix(maximumReportedPaths)),
            changed: Array(changed.prefix(maximumReportedPaths)),
            unchangedCount: unchangedCount,
            truncated: truncated,
            message: current.failures.isEmpty
                ? "Compared current JSON/sidecar and enrichment files with the selected backup; no files were changed."
                : "Compared the selected backup, but some current files could not be read: \(current.failures.joined(separator: "; "))"
        )
    }

    private func storageResult(
        for session: LibrarySession,
        validation: String,
        validationMessage: String? = nil,
        message: String = "The App-owned Library storage layout was inspected.",
        validationError: Error? = nil,
        diskSnapshot: LibraryUpgradeSessionValidator.DiskSnapshot? = nil,
        includeMediaPresenceIssues: Bool = false,
        offset: Int = 0,
        limit: Int = 100
    ) -> AutomationStorageResult {
        let fileManager = FileManager.default
        let paths = session.context.paths
        let manifest = try? MusicLibraryManifest.read(from: paths.manifestURL)
        let rootPath = session.context.rootURL.standardizedFileURL.path
        let missingDirectories = paths.requiredDirectories.compactMap { url -> String? in
            guard !fileManager.fileExists(atPath: url.path) else { return nil }
            let path = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
        }
        let pageOffset = max(0, offset)
        let pageLimit = max(1, min(100, limit))
        var issues = missingDirectories.map { relativePath in
            AutomationStorageIssue(
                id: "missing-directory:\(relativePath)",
                code: "storage.required-directory.missing",
                path: session.context.rootURL.appendingPathComponent(relativePath).path,
                reason: "The App-owned Library directory is missing."
            )
        }
        if !fileManager.fileExists(atPath: paths.manifestURL.path) {
            issues.append(AutomationStorageIssue(
                id: "manifest-missing",
                code: "storage.manifest.missing",
                path: paths.manifestURL.path,
                reason: "The Library manifest file is missing."
            ))
        } else if manifest == nil {
            issues.append(AutomationStorageIssue(
                id: "manifest-invalid",
                code: "storage.manifest.invalid",
                path: paths.manifestURL.path,
                reason: "The Library manifest could not be decoded."
            ))
        }
        for reference in diskSnapshot?.playlistReferenceIssues ?? [] {
            for trackID in reference.missingTrackIDs {
                issues.append(AutomationStorageIssue(
                    id: "playlist-reference:\(reference.playlistID.uuidString):\(trackID.uuidString)",
                    code: "storage.playlist.reference-missing",
                    trackID: trackID,
                    path: paths.playlistURL(for: reference.playlistID).path,
                    reason: "Playlist \(reference.playlistName) references Track \(trackID.uuidString), which is absent from the Track index."
                ))
            }
        }
        if let validationError,
           let issue = storageValidationIssue(validationError, session: session, diskSnapshot: diskSnapshot) {
            if !issues.contains(where: { $0.id == issue.id }) { issues.append(issue) }
        }
        let media = includeMediaPresenceIssues
            ? mediaPresenceIssues(for: session.libraryViewModel.allTracks, in: session)
            : []
        let sortedIssues = issues.sorted { $0.id < $1.id }
        let sortedMedia = media.sorted { $0.id < $1.id }
        return AutomationStorageResult(
            libraryID: session.context.id,
            mode: session.context.mode.rawValue,
            rootPath: rootPath,
            schemaVersion: manifest?.schemaVersion,
            manifestPresent: fileManager.fileExists(atPath: paths.manifestURL.path),
            missingRequiredDirectories: missingDirectories,
            validation: validation,
            validationMessage: validationMessage,
            issues: Array(sortedIssues.dropFirst(pageOffset).prefix(pageLimit)),
            issueCount: sortedIssues.count,
            offset: pageOffset,
            limit: pageLimit,
            hasMore: pageOffset + pageLimit < sortedIssues.count,
            mediaIssues: Array(sortedMedia.dropFirst(pageOffset).prefix(pageLimit)),
            mediaIssueCount: sortedMedia.count,
            mediaHasMore: pageOffset + pageLimit < sortedMedia.count,
            message: message
        )
    }

    private func mediaPresenceIssues(
        for tracks: [Track],
        in session: LibrarySession
    ) -> [AutomationStorageIssue] {
        let fileManager = FileManager.default
        return tracks.compactMap { track in
            let candidates = AutomationFileAccess.automationTrackFileURLs(track, in: session)
                .map { $0.standardizedFileURL }
            if candidates.contains(where: { fileManager.fileExists(atPath: $0.path) && fileManager.isReadableFile(atPath: $0.path) }) {
                return nil
            }
            let paths = candidates.map(\.path)
            let expectedPath = paths.first ?? (track.originalFilePath.isEmpty ? nil : track.originalFilePath)
            let pathSummary = paths.isEmpty ? "No absolute media path is recorded." : "Recorded candidate paths: \(paths.joined(separator: ", "))."
            return AutomationStorageIssue(
                id: "media-path:\(track.id.uuidString)",
                code: "media.path.missing-or-inaccessible",
                trackID: track.id,
                path: expectedPath,
                reason: "None of the recorded paths currently exists and is readable by the App. This check does not decode the audio file, and it does not prove permanent deletion or distinguish an offline source from denied access. Cached availability is \(track.availability.rawValue). \(pathSummary)"
            )
        }
    }

    private func storageValidationIssue(
        _ error: Error,
        session: LibrarySession,
        diskSnapshot: LibraryUpgradeSessionValidator.DiskSnapshot?
    ) -> AutomationStorageIssue? {
        let paths = session.context.paths
        let reason = String(describing: error)
        let code: String
        let path: String
        switch error as? LibraryUpgradeValidationError {
        case .manifestMismatch:
            code = "storage.manifest.identity-mismatch"
            path = paths.manifestURL.path
        case .damagedTrackSidecar:
            code = "storage.track-sidecar.invalid"
            path = firstInvalidTrackSidecar(in: session) ?? paths.tracksRootURL.path
        case .damagedPlaylistSidecar:
            code = "storage.playlist-sidecar.invalid"
            path = firstInvalidPlaylistSidecar(in: session) ?? paths.playlistsRootURL.path
        case .duplicateTrackID:
            code = "storage.track-id.duplicate"
            path = paths.tracksRootURL.path
        case .trackCountMismatch:
            code = "storage.track-count.mismatch"
            path = session.context.rootURL.path
        case .playlistReferenceMissing:
            if let issue = diskSnapshot?.playlistReferenceIssues.first {
                code = "storage.playlist.reference-missing"
                path = paths.playlistURL(for: issue.playlistID).path
            } else {
                code = "storage.playlist.reference-missing"
                path = paths.playlistsRootURL.path
            }
        case .storageModeMismatch:
            code = "storage.mode.mismatch"
            path = paths.manifestURL.path
        case .trackIndexUnavailable, .trackIndexMismatch:
            code = "storage.track-index.invalid"
            path = paths.trackIndexStoreURL.path
        case .searchIndexMismatch:
            code = "storage.search-index.invalid"
            path = paths.searchIndexStoreURL.path
        case .historyStoreMismatch:
            code = "storage.playback-history.invalid"
            path = paths.playbackHistoryStoreURL.path
        case .sqliteIntegrityFailed(let fileName):
            code = "storage.sqlite.integrity-failed"
            path = [paths.trackIndexStoreURL, paths.searchIndexStoreURL, paths.playbackHistoryStoreURL]
                .first(where: { $0.lastPathComponent == fileName })?.path
                ?? session.context.rootURL.appendingPathComponent(fileName).path
        case .legacyIndexCleanupFailed:
            code = "storage.legacy-index.cleanup-failed"
            path = session.context.rootURL.path
        case .journalIdentityMismatch, .journalNotRegistered:
            code = "storage.journal.invalid"
            path = session.context.rootURL.path
        case nil:
            code = "storage.validation.failed"
            path = session.context.rootURL.path
        }
        let nextStep: String
        switch error as? LibraryUpgradeValidationError {
        case .manifestMismatch, .storageModeMismatch:
            nextStep = "Check the Library manifest against the active Library binding before taking further action."
        case .damagedTrackSidecar, .duplicateTrackID, .trackCountMismatch:
            nextStep = "Inspect the reported Tracks path and compare the sidecar entries with the App-owned Track index."
        case .damagedPlaylistSidecar, .playlistReferenceMissing:
            nextStep = "Inspect the reported Playlist sidecar and compare its Track IDs with the App-owned Track index."
        case .trackIndexUnavailable, .trackIndexMismatch:
            nextStep = "Preserve a backup before using an App-owned recovery flow if the mismatch remains."
        case .searchIndexMismatch:
            nextStep = "Allow the App-owned search index to finish rebuilding, then run storage.validate again."
        case .historyStoreMismatch, .sqliteIntegrityFailed:
            nextStep = "Preserve a backup before using an App-owned recovery or restore flow."
        case .legacyIndexCleanupFailed, .journalIdentityMismatch, .journalNotRegistered:
            nextStep = "Keep the Library unchanged and inspect the App-owned migration or recovery state."
        case nil:
            nextStep = "Inspect this App-owned Library location and rerun storage.validate for a focused result."
        }
        return AutomationStorageIssue(
            id: "\(code):\(path)",
            code: code,
            path: path,
            reason: "\(reason) \(nextStep)"
        )
    }

    private func firstInvalidTrackSidecar(in session: LibrarySession) -> String? {
        let root = session.context.paths.tracksRootURL
        let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let decoder = AutomationWireCoding.decoder()
        for directory in directories ?? [] {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metaURL = directory.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(TrackSidecar.self, from: data),
                  UUID(uuidString: directory.lastPathComponent) == sidecar.id else {
                return metaURL.path
            }
        }
        return nil
    }

    private func firstInvalidPlaylistSidecar(in session: LibrarySession) -> String? {
        let root = session.context.paths.playlistsRootURL
        let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let decoder = AutomationWireCoding.decoder()
        for url in files ?? [] where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  (try? decoder.decode(PlaylistSidecar.self, from: data)) != nil else {
                return url.path
            }
        }
        return nil
    }

    private func diagnosticsIssues(
        tracks: [Track],
        sources: [ReferencedSourceDescriptor],
        jobs: [LibraryOperationTaskDescriptor],
        playlistReferences: [AutomationPlaylistReferenceIssue],
        storageError: Error?,
        diskSnapshot: LibraryUpgradeSessionValidator.DiskSnapshot?,
        in session: LibrarySession
    ) -> [AutomationDiagnosticIssue] {
        var issues: [AutomationDiagnosticIssue] = []
        for source in sources where source.status != .available {
            issues.append(AutomationDiagnosticIssue(
                id: "source:\(source.id.uuidString)",
                code: "source.\(source.status.rawValue)",
                sourceID: source.id,
                path: source.lastKnownPath,
                reason: "Source status is \(source.status.rawValue)."
            ))
        }
        for track in tracks {
            let path = AutomationFileAccess.automationTrackFileURL(track, in: session)?.path
            if track.availability != .available {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-availability:\(track.id.uuidString)",
                    code: "track.availability.\(track.availability.rawValue)",
                    trackID: track.id,
                    path: path,
                    reason: "Cached Track availability is \(track.availability.rawValue)."
                ))
            }
            if queries.trackLyricsStatus(track) == "none" {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-lyrics:\(track.id.uuidString)",
                    code: "track.lyrics.missing",
                    trackID: track.id,
                    path: path,
                    reason: "The Track has no persisted lyrics."
                ))
            }
            if !track.hasArtwork {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-artwork:\(track.id.uuidString)",
                    code: "track.artwork.missing",
                    trackID: track.id,
                    path: path,
                    reason: "The Track has no App-owned artwork."
                ))
            }
            let incompleteFields = ["title": track.title, "artist": track.artist, "album": track.album]
                .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.key)
                .sorted()
            if !incompleteFields.isEmpty {
                issues.append(AutomationDiagnosticIssue(
                    id: "track-metadata:\(track.id.uuidString)",
                    code: "track.metadata.incomplete",
                    trackID: track.id,
                    path: path,
                    reason: "Missing metadata fields: \(incompleteFields.joined(separator: ", "))."
                ))
            }
        }
        for issue in playlistReferences {
            for trackID in issue.missingTrackIDs {
                issues.append(AutomationDiagnosticIssue(
                    id: "playlist-reference:\(issue.playlistID.uuidString):\(trackID.uuidString)",
                    code: "playlist.reference.missing-track",
                    trackID: trackID,
                    playlistID: issue.playlistID,
                    reason: "Playlist \(issue.playlistName) references a missing Track."
                ))
            }
        }
        for job in jobs where job.state == .failed || job.state == .partialFailure {
            issues.append(AutomationDiagnosticIssue(
                id: "job:\(job.id.uuidString)",
                code: "job.\(job.state.rawValue)",
                reason: job.partialFailureSummaries.prefix(3).joined(separator: "; ").isEmpty
                    ? "Job ended in state \(job.state.rawValue)."
                    : job.partialFailureSummaries.prefix(3).joined(separator: "; ")
            ))
        }
        if let storageError,
           let issue = storageValidationIssue(storageError, session: session, diskSnapshot: diskSnapshot) {
            issues.append(AutomationDiagnosticIssue(
                id: issue.id,
                code: issue.code,
                path: issue.path,
                reason: issue.reason
            ))
        }
        return issues.sorted { $0.id < $1.id }
    }

    private func makeTrackRevisions(
        from values: [String: AutomationJSONValue]?
    ) throws -> [UUID: String] {
        guard let values else { return [:] }
        var result: [UUID: String] = [:]
        for (rawID, value) in values {
            guard let id = UUID(uuidString: rawID),
                  case .string(let revision) = value,
                  !revision.isEmpty else {
                throw AutomationParameterError.invalidValue("expectedRevisions")
            }
            result[id] = revision
        }
        return result
    }

    private func metadataPatchChanges(
        _ track: Track,
        patch: LibraryAutomationMetadataPatch
    ) -> Bool {
        if patch.fields.contains("title"), track.title != (patch.title ?? "") { return true }
        if patch.fields.contains("artist"), track.artist != (patch.artist ?? "") { return true }
        if patch.fields.contains("album"), track.album != (patch.album ?? "") { return true }
        if patch.fields.contains("albumArtist"), track.albumArtist != patch.albumArtist { return true }
        if patch.fields.contains("description"), track.userDescription != (patch.userDescription ?? "") { return true }
        if patch.fields.contains("genreTags"), track.genreTags != (patch.genreTags ?? []) { return true }
        if patch.fields.contains("language"), track.language != (patch.language ?? "") { return true }
        if patch.fields.contains("labelOrCompany"), track.labelOrCompany != (patch.labelOrCompany ?? "") { return true }
        if patch.fields.contains("releaseDate"), track.releaseDate != patch.releaseDate { return true }
        if patch.fields.contains("qqMusicSongMid"), track.qqMusicSongMid != patch.qqMusicSongMid { return true }
        if patch.fields.contains("metadataSource"), track.metadataSource != patch.metadataSource { return true }
        if patch.fields.contains("metadataFetchedAt"), track.metadataFetchedAt != patch.metadataFetchedAt { return true }
        if patch.fields.contains("metadataConfidence"), track.metadataConfidence != patch.metadataConfidence { return true }
        if patch.fields.contains("musicBrainzReleaseID"), track.musicBrainzReleaseID != patch.musicBrainzReleaseID { return true }
        if patch.fields.contains("lyricsTimeOffsetMs"), track.lyricsTimeOffsetMs != (patch.lyricsTimeOffsetMs ?? 0) { return true }
        if patch.fields.contains("artistCredits") {
            if let artistCredits = patch.artistCredits {
                if track.artistCredits != artistCredits { return true }
            } else if track.artistCreditsData != nil {
                return true
            }
        }
        return false
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
        let directory = Self.automationSupportDirectory(
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
        default: return "operation"
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

    private func makeLyricsSearchResult(
        trackID: UUID,
        track: Track,
        mode: LDDCMode,
        result: LyricsSearchHelper.SearchResult,
        fromCache: Bool
    ) -> AutomationLyricsSearchResult {
        AutomationLyricsSearchResult(
            trackID: trackID,
            queryTitle: result.queryTitle,
            queryArtist: result.queryArtist,
            queryAlbum: result.queryAlbum,
            mode: mode.rawValue,
            candidates: result.candidates.map {
                makeAutomationLyricsCandidate($0, mode: mode)
            },
            amlldbCount: result.amlldbCount,
            lddcCount: result.lddcCount,
            message: fromCache
                ? "Returned the last cached provider search for this Track."
                : (result.candidates.isEmpty
                    ? "No lyrics candidates were returned by the configured providers."
                    : "Lyrics candidates were searched and ranked by the existing App provider pipeline.")
        )
    }

    private func cacheArtworkCandidate(
        _ candidate: CoverCandidate,
        target: ArtworkTarget,
        revision: String,
        session: LibrarySession,
        queryTitle: String?,
        queryArtist: String?,
        queryAlbum: String?
    ) -> AutomationArtworkCandidate {
        pruneArtworkCandidateCache(now: Date())
        let imageDigest = artworkDigest(candidate.imageData) ?? "unavailable"
        let identity = [
            session.context.id.uuidString,
            target.stableIdentity,
            artworkSourceName(candidate.source),
            candidate.sourceItemId ?? "",
            imageDigest
        ].joined(separator: "\n")
        let candidateDigest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let candidateID = "art-v1-" + candidateDigest
        let wireCandidate = makeArtworkCandidate(
            candidate,
            candidateID: candidateID,
            queryTitle: queryTitle,
            queryArtist: queryArtist,
            queryAlbum: queryAlbum
        )
        let trackID: UUID?
        let artistID: UUID?
        let albumKey: String?
        switch target {
        case .track(let track):
            trackID = track.id
            artistID = nil
            albumKey = nil
        case .artist(let artist):
            trackID = nil
            artistID = artist.id
            albumKey = nil
        case .album(let album):
            trackID = nil
            artistID = nil
            albumKey = album.canonicalKey
        case .playlist:
            return wireCandidate
        }
        artworkCandidateCache[candidateID] = CachedArtworkCandidate(
            libraryID: session.context.id,
            targetIdentity: target.stableIdentity,
            trackID: trackID,
            artistID: artistID,
            albumKey: albumKey,
            revision: revision,
            candidate: wireCandidate,
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        artworkCandidateOrder.removeAll { $0 == candidateID }
        artworkCandidateOrder.append(candidateID)
        while artworkCandidateOrder.count > artworkCandidateCacheLimit {
            let expired = artworkCandidateOrder.removeFirst()
            artworkCandidateCache.removeValue(forKey: expired)
        }
        return wireCandidate
    }

    private func pruneArtworkCandidateCache(now: Date) {
        artworkCandidateOrder.removeAll { candidateID in
            guard let candidate = artworkCandidateCache[candidateID],
                  candidate.expiresAt > now else {
                artworkCandidateCache.removeValue(forKey: candidateID)
                return true
            }
            return false
        }
    }

    private func makeArtworkCandidate(
        _ candidate: CoverCandidate,
        candidateID: String? = nil,
        queryTitle: String?,
        queryArtist: String?,
        queryAlbum: String?
    ) -> AutomationArtworkCandidate {
        let inlineData = inlineArtworkData(candidate.imageData)
        return AutomationArtworkCandidate(
            candidateID: candidateID,
            source: artworkSourceName(candidate.source),
            sourceItemID: candidate.sourceItemId,
            imageBase64: inlineData.base64EncodedString(),
            imageMIMEType: artworkMIMEType(for: inlineData),
            byteCount: inlineData.count,
            originalByteCount: inlineData == candidate.imageData ? nil : candidate.imageData.count,
            width: candidate.width,
            height: candidate.height,
            resolution: candidate.resolution,
            confidence: candidate.confidence,
            matchQuality: AutomationArtworkQualityEvaluator.score(
                queryTitle: queryTitle,
                queryArtist: queryArtist,
                queryAlbum: queryAlbum,
                candidateTitle: candidate.matchedTitle,
                candidateArtist: candidate.matchedArtist,
                candidateAlbum: candidate.matchedAlbum,
                width: candidate.width,
                height: candidate.height
            ),
            matchedTitle: candidate.matchedTitle,
            matchedArtist: candidate.matchedArtist,
            matchedAlbum: candidate.matchedAlbum,
            imageURL: candidate.imageURL
        )
    }

    /// The App IPC response frame is intentionally capped at 1 MiB. Provider
    /// images can be multi-megabyte PNGs, so keep the Agent-review payload
    /// useful and bounded while preserving the original URL/size metadata.
    private func inlineArtworkData(_ data: Data) -> Data {
        let maximumBytes = 100_000
        guard data.count > maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return data
        }

        var maxPixelSize = 640
        var quality = 0.82
        var bestData: Data?
        for _ in 0..<5 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                break
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                break
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { break }
            let encoded = output as Data
            bestData = encoded
            if encoded.count <= maximumBytes {
                return encoded
            }
            maxPixelSize = max(256, maxPixelSize * 3 / 4)
            quality *= 0.78
        }
        return bestData ?? data
    }

    private func artworkSourceName(_ source: CoverSource) -> String {
        switch source {
        case .sacad: return "sacad"
        case .netease: return "netease"
        case .qqmusic: return "qqmusic"
        }
    }

    private func artworkMIMEType(for data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.subdata(in: 8..<12) == Data("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    private func makeAutomationLyricsCandidate(
        _ candidate: LDDCCandidate,
        mode: LDDCMode
    ) -> AutomationLyricsCandidate {
        AutomationLyricsCandidate(
            source: candidate.source,
            songID: candidate.songId,
            score: candidate.score,
            normalizedScore: candidate.normalizedScore(),
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            durationMs: candidate.durationMs,
            mode: mode.rawValue,
            extra: candidate.extra
        )
    }

    private func makeAutomationLyricsCandidate(
        from values: [String: AutomationJSONValue]
    ) throws -> AutomationLyricsCandidate {
        guard case .string(let source) = values["source"], !source.isEmpty,
              case .string(let songID) = values["songID"], !songID.isEmpty,
              case .string(let title) = values["title"], !title.isEmpty,
              case .string(let mode) = values["mode"],
              LDDCMode(rawValue: mode) != nil else {
            throw AutomationParameterError.invalidValue("candidate")
        }
        let score = try jsonDouble(values["score"], key: "candidate.score", default: 0)
        let normalizedScore = try jsonDouble(
            values["normalizedScore"],
            key: "candidate.normalizedScore",
            default: source == "AMLLDB" ? score * 100 : score
        )
        let durationMs = try jsonInt(values["durationMs"], key: "candidate.durationMs")
        var extra: [String: String]?
        if case .object(let rawExtra) = values["extra"] {
            extra = rawExtra.reduce(into: [:]) { result, entry in
                if case .string(let value) = entry.value {
                    result[entry.key] = value
                }
            }
        }
        return AutomationLyricsCandidate(
            source: source,
            songID: songID,
            score: score,
            normalizedScore: normalizedScore,
            title: title,
            artist: optionalJSONString(values["artist"]),
            album: optionalJSONString(values["album"]),
            durationMs: durationMs,
            mode: mode,
            extra: extra
        )
    }

    private func makeLDDCCandidate(
        from candidate: AutomationLyricsCandidate
    ) throws -> LDDCCandidate {
        guard LDDCSource(rawValue: candidate.source) != nil else {
            throw AutomationParameterError.invalidValue("candidate.source")
        }
        return LDDCCandidate(
            source: candidate.source,
            songId: candidate.songID,
            score: candidate.score,
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            durationMs: candidate.durationMs,
            extra: candidate.extra
        )
    }

    private func lddcMode(
        for candidate: AutomationLyricsCandidate
    ) throws -> LDDCMode {
        guard let mode = LDDCMode(rawValue: candidate.mode) else {
            throw AutomationParameterError.invalidValue("candidate.mode")
        }
        return mode
    }

    private func lyricsQuality(for candidate: AutomationLyricsCandidate) -> Int {
        candidate.mode == LDDCMode.verbatim.rawValue ? 2 : 1
    }

    private func trimLyricsCandidateCacheIfNeeded() {
        guard lyricsCandidateCache.count > lyricsCandidateCacheLimit else { return }
        let removeCount = lyricsCandidateCache.count - lyricsCandidateCacheLimit
        for trackID in lyricsCandidateCache.keys.prefix(removeCount) {
            lyricsCandidateCache.removeValue(forKey: trackID)
        }
    }

    private func optionalJSONString(_ value: AutomationJSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func jsonDouble(
        _ value: AutomationJSONValue?,
        key: String,
        default defaultValue: Double
    ) throws -> Double {
        guard let value else { return defaultValue }
        guard case .number(let number) = value, number.isFinite else {
            throw AutomationParameterError.invalidType(key, expected: "number")
        }
        return number
    }

    private func jsonInt(
        _ value: AutomationJSONValue?,
        key: String
    ) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw AutomationParameterError.invalidType(key, expected: "integer")
        }
        return Int(number)
    }

    private func uniqueExportURL(for fileName: String, in directory: URL) -> URL {
        let sourceName = URL(fileURLWithPath: fileName)
        let baseName = sourceName.deletingPathExtension().lastPathComponent
        let fileExtension = sourceName.pathExtension
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let uniqueName = fileExtension.isEmpty
                ? "\(baseName) (\(suffix))"
                : "\(baseName) (\(suffix)).\(fileExtension)"
            candidate = directory.appendingPathComponent(uniqueName, isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    @discardableResult

    private func readEmbeddedTags(from url: URL) async -> (
        values: [String: String], supportedForWrite: Bool, status: String, message: String?
    ) {
        if url.pathExtension.lowercased() == "mp3" {
            do {
                let values = embeddedTagValues(try MP3EmbeddedTagService.read(from: url))
                return (
                    values,
                    true,
                    values.isEmpty ? "empty" : "read",
                    values.isEmpty ? "No supported ID3 values were found." : nil
                )
            } catch {
                return ([:], false, "unsupported", MP3EmbeddedTagService.publicMessage(for: error))
            }
        }
        let extracted = await ImportMetadataExtractor.extractMetadata(from: url)
        var values: [String: String] = [:]
        if let value = extracted.tagFields.title { values["title"] = value }
        if let value = extracted.tagFields.artist { values["artist"] = value }
        if let value = extracted.tagFields.album { values["album"] = value }
        if let value = extracted.tagFields.albumArtist { values["albumArtist"] = value }
        if let value = extracted.tagFields.releaseYear { values["year"] = String(value) }
        return (
            values,
            false,
            values.isEmpty ? "empty" : "read",
            "Tags can be read through AVFoundation, but embedded-tag writes are currently supported only for MP3."
        )
    }

    private func embeddedTagValues(_ tags: MP3EmbeddedTagService.TagValues) -> [String: String] {
        var values: [String: String] = [:]
        for field in MP3EmbeddedTagService.supportedFields.subtracting(["comment", "lyrics"]) {
            if let value = tags[field] {
                values[field] = String(value.prefix(16_384))
            }
        }
        return values
    }

    private func makeMetadataDocumentTrack(_ track: Track, revision: String) -> AutomationMetadataDocumentTrack {
        func nullableString(_ value: String?) -> AutomationJSONValue {
            value.map(AutomationJSONValue.string) ?? .null
        }
        func nullableDate(_ value: Date?) -> AutomationJSONValue {
            value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        }
        let fields: [String: AutomationJSONValue] = [
            "title": .string(track.title),
            "artist": .string(track.artist),
            "album": .string(track.album),
            "albumArtist": nullableString(track.albumArtist),
            "description": .string(track.userDescription),
            "genreTags": .array(track.genreTags.map(AutomationJSONValue.string)),
            "language": .string(track.language),
            "labelOrCompany": .string(track.labelOrCompany),
            "releaseDate": nullableDate(track.releaseDate),
            "qqMusicSongMid": nullableString(track.qqMusicSongMid),
            "metadataSource": nullableString(track.metadataSource),
            "metadataFetchedAt": nullableDate(track.metadataFetchedAt),
            "metadataConfidence": track.metadataConfidence.map(AutomationJSONValue.number) ?? .null,
            "musicBrainzReleaseID": nullableString(track.musicBrainzReleaseID),
            "lyricsTimeOffsetMs": .number(track.lyricsTimeOffsetMs),
            "artistCredits": .array(track.artistCredits.map { credit in
                .object([
                    "id": .string(credit.id.uuidString),
                    "displayName": .string(credit.displayName),
                    "canonicalName": nullableString(credit.canonicalName),
                    "role": .string(credit.role.rawValue)
                ])
            })
        ]
        return AutomationMetadataDocumentTrack(
            id: track.id,
            revision: revision,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            fields: fields
        )
    }

    private func makeSourceSummary(
        _ descriptor: ReferencedSourceDescriptor
    ) -> AutomationSourceSummary {
        AutomationSourceSummary(
            id: descriptor.id,
            mode: descriptor.mode.rawValue,
            displayName: descriptor.displayName,
            path: descriptor.lastKnownPath,
            status: descriptor.status.rawValue,
            lastScan: descriptor.lastScan,
            playlistIDs: descriptor.playlistBindings.map(\.playlistID),
            excludedRelativePaths: descriptor.excludedRelativePaths,
            monitorPolicy: descriptor.monitorPolicy.rawValue
        )
    }

    private func makeSourceConfiguration(
        _ descriptor: ReferencedSourceDescriptor
    ) -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(
            sourceID: descriptor.id,
            displayName: descriptor.displayName,
            monitorPolicy: descriptor.monitorPolicy.rawValue,
            excludedRelativePaths: descriptor.excludedRelativePaths
        )
    }

    private func sourceConfigurationRevision(
        libraryID: UUID,
        configurations: [AutomationSourceConfiguration]
    ) -> String {
        let document = AutomationSourceConfigurationDocument(
            originLibraryID: libraryID,
            sources: configurations
        )
        guard let data = try? AutomationWireCoding.encoder().encode(document) else {
            return "source-config-v1-unavailable"
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "source-config-v1-" + digest
    }

    private struct AutomationFilePlan {
        let track: Track
        let trackID: UUID
        let from: URL
        let destination: URL?
        let sourceIDs: Set<UUID>
    }

    private func makeFilePlans(
        method: String,
        operations: [[String: AutomationJSONValue]],
        session: LibrarySession
    ) throws -> [AutomationFilePlan] {
        guard session.context.mode == .referenced,
              let sourceScope = session.referencedSourceScope else {
            throw AutomationFileOperationError.referencedLibraryRequired
        }
        let tracksByID = Dictionary(
            uniqueKeysWithValues: session.libraryViewModel.allTracks.map { ($0.id, $0) }
        )
        var seenTrackIDs = Set<UUID>()
        var plans: [AutomationFilePlan] = []

        for operation in operations {
            guard case let .string(rawTrackID) = operation["trackID"],
                  let trackID = UUID(uuidString: rawTrackID),
                  seenTrackIDs.insert(trackID).inserted else {
                throw AutomationParameterError.invalidValue("operations.trackID")
            }
            guard let track = tracksByID[trackID] else {
                throw AutomationFileOperationError.trackNotFound(trackID)
            }
            let current = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session)
            let destination: URL

            if method == AutomationMethod.filesRename {
                guard case let .string(rawName) = operation["name"] else {
                    throw AutomationParameterError.missing("operations.name")
                }
                let name = try normalizedFileName(rawName, preservingExtensionOf: current.url)
                destination = current.url.deletingLastPathComponent()
                    .appendingPathComponent(name)
                    .standardizedFileURL
            } else {
                guard case let .string(rawSourceID) = operation["sourceID"],
                      let sourceID = UUID(uuidString: rawSourceID) else {
                    throw AutomationParameterError.invalidValue("operations.sourceID")
                }
                guard case let .string(rawRelativePath) = operation["relativePath"] else {
                    throw AutomationParameterError.missing("operations.relativePath")
                }
                let relativePath = rawRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let root = try AutomationFileAccess.authorizedDirectoryRoot(sourceID: sourceID, sourceScope: sourceScope)
                guard TrackMediaLocator.isSafeRelativePath(relativePath) else {
                    throw AutomationFileOperationError.unsafeRelativePath(relativePath)
                }
                destination = root.appendingPathComponent(relativePath).standardizedFileURL
                guard AutomationFileAccess.isAuthorizedPath(destination, inside: root) else {
                    throw AutomationFileOperationError.unsafeRelativePath(relativePath)
                }
            }

            guard current.url.path != destination.path else {
                throw AutomationFileOperationError.destinationIsCurrentFile(destination.path)
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw AutomationFileOperationError.destinationExists(destination.path)
            }
            var affectedSourceIDs = current.sourceIDs
            if method == AutomationMethod.filesMove,
               case let .string(rawSourceID) = operation["sourceID"],
               let destinationSourceID = UUID(uuidString: rawSourceID) {
                affectedSourceIDs.insert(destinationSourceID)
            }
            plans.append(
                AutomationFilePlan(
                    track: track,
                    trackID: trackID,
                    from: current.url,
                    destination: destination,
                    sourceIDs: affectedSourceIDs
                )
            )
        }

        let destinationPaths = plans.compactMap(\.destination).map { $0.path }
        guard Set(destinationPaths).count == destinationPaths.count else {
            throw AutomationFileOperationError.duplicateDestination
        }
        let sourcePaths = Set(plans.map { $0.from.path })
        guard plans.compactMap(\.destination).allSatisfy({ !sourcePaths.contains($0.path) }) else {
            throw AutomationFileOperationError.destinationOverlapsSelection
        }
        return plans
    }

    private func makeFileDeletePlans(
        trackIDs: [UUID],
        session: LibrarySession
    ) throws -> [AutomationFilePlan] {
        guard session.context.mode == .referenced else {
            throw AutomationFileOperationError.referencedLibraryRequired
        }
        let tracks = try AutomationFileAccess.automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
        return try tracks.map { track in
            let current = try AutomationFileAccess.currentAuthorizedFile(for: track, session: session)
            return AutomationFilePlan(
                track: track,
                trackID: track.id,
                from: current.url,
                destination: nil,
                sourceIDs: current.sourceIDs
            )
        }
    }

    private func normalizedFileName(
        _ rawName: String,
        preservingExtensionOf source: URL
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\") else {
            throw AutomationFileOperationError.invalidFileName
        }
        if source.pathExtension.isEmpty || name.contains(".") {
            return name
        }
        return "\(name).\(source.pathExtension)"
    }

    private func applyFilePlans(_ plans: [AutomationFilePlan]) throws {
        var applied: [AutomationFilePlan] = []
        do {
            for plan in plans {
                guard let destination = plan.destination else { continue }
                let parent = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: plan.from, to: destination)
                applied.append(plan)
            }
        } catch {
            for plan in applied.reversed() {
                guard let destination = plan.destination else { continue }
                try? FileManager.default.moveItem(at: destination, to: plan.from)
            }
            throw AutomationFileOperationError.operationFailed(error.localizedDescription)
        }
    }

    private func sourceRefreshJobs(
        sourceIDs: Set<UUID>,
        appSession: AppSessionHost,
        libraryID: UUID
    ) -> [AutomationJobSummary] {
        sourceIDs
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { sourceID in
                appSession.startSourceRefreshJob(sourceID: sourceID, libraryID: libraryID)
            }
            .map(AutomationJobProjection.makeJobSummary)
    }

    private func sourceIssueMessage(_ issue: ReferencedSourceScopeIssue) -> String {
        switch issue {
        case .offline(let sourceID):
            return "\(sourceID.uuidString): offline"
        case .permissionDenied(let sourceID):
            return "\(sourceID.uuidString): permission denied"
        case .staleRefreshFailed(let sourceID):
            return "\(sourceID.uuidString): stale bookmark refresh failed"
        case .statusPersistenceFailed(let sourceID):
            return "\(sourceID.uuidString): status persistence failed"
        }
    }

}

import AppKit
import CryptoKit
import Foundation
import PlayerAutomationIPC
import PlayerAutomationProtocol

private struct AutomationScopePolicyFile: Codable {
    var schemaVersion = 1
    var grantedScopes: [String]
}

private struct AutomationIdempotencyFile: Codable {
    var schemaVersion = 1
    var entries: [String: Entry]

    struct Entry: Codable {
        let fingerprint: String
        let response: AutomationResponse
        let storedAt: Date
    }
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

/// The scope file is deliberately small and App-owned. It is not a second
/// authentication mechanism: the AF_UNIX peer/secret check still gates the
/// process, while this store decides which catalog capabilities the caller may
/// invoke. Dangerous scopes are denied by default until a foreground App
/// confirmation grants them.
private final class AutomationScopePolicyStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("scopes.json", isDirectory: false)
    }

    var defaultGrantedScopes: Set<AutomationScope> {
        Set(AutomationScope.allCases).subtracting([.filesDelete, .storageWrite])
    }

    /// A missing policy is the first-run high-autonomy default. A present but
    /// unreadable policy is different: fail closed to read-only capabilities
    /// rather than silently restoring write access after corruption.
    var readOnlyGrantedScopes: Set<AutomationScope> {
        Set(AutomationScope.allCases.filter { scope in
            scope.rawValue.hasSuffix(".read")
        })
    }

    func load() -> Set<AutomationScope> {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return defaultGrantedScopes
        }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(AutomationScopePolicyFile.self, from: data),
              payload.schemaVersion == 1 else {
            return readOnlyGrantedScopes
        }
        return Set(payload.grantedScopes.compactMap(AutomationScope.init(rawValue:)))
    }

    func save(_ scopes: Set<AutomationScope>) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = AutomationScopePolicyFile(
            grantedScopes: scopes.map(\.rawValue).sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }
}

/// Successful mutation responses are small enough to make idempotency useful
/// across an App restart. The response is stored in App-owned private support
/// storage, never in the public audit log, and is evicted with the same bound
/// as the in-memory cache.
private final class AutomationIdempotencyStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("idempotency.json", isDirectory: false)
    }

    func load() -> [(key: String, fingerprint: String, response: AutomationResponse)] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(AutomationIdempotencyFile.self, from: data),
              payload.schemaVersion == 1 else {
            return []
        }
        return payload.entries.map { key, entry in
            (key: key, fingerprint: entry.fingerprint, response: entry.response)
        }
    }

    func save(
        _ entries: [String: (fingerprint: String, response: AutomationResponse)],
        order: [String]
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let orderedKeys = order.reversed().filter { entries[$0] != nil }
        var stored: [String: AutomationIdempotencyFile.Entry] = [:]
        for key in orderedKeys {
            guard let entry = entries[key] else { continue }
            stored[key] = AutomationIdempotencyFile.Entry(
                fingerprint: entry.fingerprint,
                response: entry.response,
                storedAt: entry.response.serverTime
            )
        }
        let payload = AutomationIdempotencyFile(entries: stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: fileURL, options: .atomic)
    }
}

/// The App-owned automation endpoint. It exposes DTOs only; no repository or
/// sidecar parser crosses the process boundary. CLI, MCP and future in-process
/// AI callers all reach the same App-owned capability handler.
@MainActor
final class AutomationIPCServer {
    private struct PendingIdempotency {
        let fingerprint: String
        var waiters: [(requestID: UUID, continuation: CheckedContinuation<AutomationResponse, Never>)]
    }

    private static let socketDirectoryName = "Automation"
    private static let socketFileName = "automation.sock"

    private let listener: AutomationIPCListener
    private weak var appSession: AppSessionHost?
    private let scopePolicyStore = AutomationScopePolicyStore()
    private let idempotencyStore = AutomationIdempotencyStore()
    private var cachedGrantedScopes: Set<AutomationScope>?
    private var idempotencyCache: [String: (fingerprint: String, response: AutomationResponse)] = [:]
    private var idempotencyOrder: [String] = []
    private var pendingIdempotency: [String: PendingIdempotency] = [:]
    private var lyricsCandidateCache: [UUID: CachedLyricsCandidates] = [:]
    private let idempotencyCacheLimit = 256
    private let lyricsCandidateCacheLimit = 256
    private(set) var isRunning = false

    private struct CachedLyricsCandidates {
        let mode: LDDCMode
        let translation: Bool
        let result: LyricsSearchHelper.SearchResult
    }

    init(appSession: AppSessionHost) throws {
        self.appSession = appSession
        let socketPath = Self.defaultSocketURL.path
        let sharedSecret = try AutomationIPCSecretStore.loadOrCreate(
            forSocketPath: socketPath
        )
        let configuration = try AutomationIPCConfiguration(
            maximumFrameBytes: 1_048_576,
            maximumConcurrentConnections: 8,
            ioTimeout: 10,
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
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent(socketDirectoryName, isDirectory: true)
            .appendingPathComponent(socketFileName, isDirectory: false)
    }

    func start() async throws {
        guard !isRunning else { return }
        try await listener.start { [weak self] request in
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
            return await self.handle(request)
        }
        isRunning = true
        Log.info("[Automation] automation IPC server started", category: .library)
    }

    func stop() async {
        await listener.stop()
        isRunning = false
        Log.info("[Automation] IPC server stopped", category: .library)
    }

    private func handle(_ request: AutomationRequest) async -> AutomationResponse {
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
                let response = responseForRequest(cached.response, requestID: request.requestID)
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
            let response = await execute(request)
            if response.error == nil,
               AutomationToolCatalog.descriptor(for: request.method)?.readOnly == false {
                idempotencyCache[cacheKey] = (fingerprint, response)
                idempotencyOrder.append(cacheKey)
                while idempotencyOrder.count > idempotencyCacheLimit {
                    let expired = idempotencyOrder.removeFirst()
                    idempotencyCache.removeValue(forKey: expired)
                }
                try? idempotencyStore.save(idempotencyCache, order: idempotencyOrder)
            }
            let waiters = pendingIdempotency.removeValue(forKey: cacheKey)?.waiters ?? []
            for waiter in waiters {
                waiter.continuation.resume(
                    returning: responseForRequest(response, requestID: waiter.requestID)
                )
            }
            recordAudit(for: request, response: response)
            return response
        }

        let response = await execute(request)
        recordAudit(for: request, response: response)
        return response
    }

    private func execute(_ request: AutomationRequest) async -> AutomationResponse {
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

        switch request.method {
        case AutomationMethod.systemPing:
            guard isEmptyParameters(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                AutomationPingResult(),
                for: request
            )

        case AutomationMethod.systemInfo:
            guard isEmptyParameters(request.params) else {
                return invalidParameters(for: request)
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
            return encodeResult(info, for: request)

        case AutomationMethod.libraryList:
            guard isEmptyParameters(request.params) else {
                return invalidParameters(for: request)
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
            let summaries = registry.libraries.map { bookmark in
                AutomationLibrarySummary(
                    id: bookmark.id,
                    displayName: bookmark.displayName,
                    mode: bookmark.modeProjection == .managed ? .managed : .referenced,
                    isActive: bookmark.id == registry.activeLibraryID
                )
            }
            return encodeResult(
                AutomationLibraryListResult(
                    libraries: summaries,
                    activeLibraryID: registry.activeLibraryID
                ),
                for: request
            )

        case AutomationMethod.libraryTracks:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let sort = try parameters.array("sort")
                let limit = try parameters.integer("limit", default: 100)
                let offset = try parameters.integer("offset", default: 0)
                guard (1...500).contains(limit), offset >= 0 else {
                    throw AutomationParameterError.outOfRange("limit/offset")
                }

                let viewModel = session.libraryViewModel
                let allTracks = viewModel.allTracks
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
                       try !matchesTrackFilter(
                           track,
                           filter: .object(filter),
                           playlists: viewModel.playlists
                       ) {
                        continue
                    }
                    filteredTracks.append(track)
                }
                let orderedTracks = try sortTracks(filteredTracks, using: sort)
                let pageStart = min(offset, orderedTracks.count)
                let pageEnd = min(pageStart + limit, orderedTracks.count)
                let page = Array(orderedTracks[pageStart..<pageEnd]).map {
                    makeTrackSummary(
                        $0,
                        playlists: viewModel.playlists,
                        includeFilePath: grantedScopes().contains(.filesRead)
                    )
                }
                return encodeResult(
                    AutomationLibraryTracksResult(
                        tracks: page,
                        total: orderedTracks.count,
                        offset: offset,
                        limit: limit,
                        nextOffset: pageEnd < orderedTracks.count ? pageEnd : nil
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistList:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard isEmptyParameters(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                AutomationPlaylistListResult(
                    playlists: session.libraryViewModel.playlists.map(makePlaylistSummary)
                ),
                for: request
            )

        case AutomationMethod.sourceList:
            guard activeSession(for: request) != nil else {
                return noActiveLibraryResponse(for: request)
            }
            guard isEmptyParameters(request.params) else {
                return invalidParameters(for: request)
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
                return encodeResult(
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

        case AutomationMethod.sourceRefresh:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                return encodeResult(
                    AutomationSourceRefreshResult(
                        sourceID: sourceID,
                        applied: false,
                        dryRun: false,
                        source: makeSourceSummary(descriptor),
                        libraryTrackCount: session.libraryViewModel.allTracks.count,
                        issues: [],
                        completed: false,
                        job: makeJobSummary(job),
                        message: "Source refresh started as a Job; existing Tracks will be reused."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistCreate:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                    return encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistCreate,
                            applied: true,
                            dryRun: false,
                            playlist: makePlaylistSummary(playlist),
                            message: "Playlist created."
                        ),
                        for: request
                    )
                } catch {
                    return mutationFailure(for: request, error: error)
                }
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistAddTracks:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray("trackIDs", required: true)
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
                let summary = makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return encodeResult(
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
                    return encodeResult(
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
                    return encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistAddTracks,
                            applied: true,
                            dryRun: false,
                            playlist: updatedPlaylist.map(makePlaylistSummary),
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Playlist membership updated; library Tracks were reused."
                        ),
                        for: request
                    )
                } catch {
                    return mutationFailure(for: request, error: error)
                }
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistRemoveTracks:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                let requestedTrackIDs = try parameters.uuidArray("trackIDs", required: true)
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
                let summary = makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return encodeResult(
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
                    return encodeResult(
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
                    return encodeResult(
                        AutomationPlaylistMutationResult(
                            operation: AutomationMethod.playlistRemoveTracks,
                            applied: true,
                            dryRun: false,
                            playlist: updatedPlaylist.map(makePlaylistSummary),
                            requestedTrackIDs: requestedTrackIDs,
                            changedTrackIDs: changedTrackIDs,
                            skippedTrackIDs: skippedTrackIDs,
                            message: "Playlist membership updated; library Tracks and files were retained."
                        ),
                        for: request
                    )
                } catch {
                    return mutationFailure(for: request, error: error)
                }
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let playlistID = try parameters.uuid("playlistID", required: true)!
                guard let playlist = session.libraryViewModel.playlists.first(where: { $0.id == playlistID }) else {
                    throw AutomationParameterError.missingResource("playlistID")
                }
                return encodeResult(
                    AutomationPlaylistDetailResult(
                        playlist: makePlaylistSummary(playlist),
                        trackIDs: playlist.tracks.map(\.id)
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.playlistRename:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let summary = makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return encodeResult(
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
                return encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: AutomationMethod.playlistRename,
                        applied: true,
                        dryRun: false,
                        playlist: makePlaylistSummary(updated),
                        message: "Playlist renamed."
                    ),
                    for: request
                )
            } catch {
                return mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistDelete:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let summary = makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                if dryRun {
                    return encodeResult(
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
                    return confirmationRequired(
                        for: request,
                        message: "Deleting a playlist requires confirm=true; the App will still ask for foreground confirmation.",
                        details: .object([
                            "playlistID": .string(playlistID.uuidString),
                            "trackCount": .number(Double(summary.trackCount))
                        ])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "Delete playlist?",
                    message: "Delete \(summary.name) and its \(summary.trackCount) memberships? Tracks and audio files will be retained."
                ) else {
                    return interactionCancelled(for: request)
                }
                try await session.libraryViewModel.deletePlaylistForAutomation(
                    playlist,
                    expectedRevision: expectedRevision
                )
                return encodeResult(
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
                return mutationFailure(for: request, error: error)
            }

        case AutomationMethod.playlistReplaceTracks, AutomationMethod.playlistReorder:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let summary = makePlaylistSummary(playlist)
                if let expectedRevision, expectedRevision != summary.revision {
                    return revisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: summary.revision
                    )
                }
                let operation = request.method
                if dryRun {
                    return encodeResult(
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
                return encodeResult(
                    AutomationPlaylistMutationResult(
                        operation: operation,
                        applied: true,
                        dryRun: false,
                        playlist: updated.map(makePlaylistSummary),
                        requestedTrackIDs: requestedTrackIDs,
                        changedTrackIDs: requestedTrackIDs,
                        message: "Playlist membership order updated; no files were imported or deleted."
                    ),
                    for: request
                )
            } catch {
                return mutationFailure(for: request, error: error)
            }

        case AutomationMethod.sourceCreate:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            selectedPath: requestedPath,
                            message: "Preview only. The App will request a security-scoped folder/file selection when needed."
                        ),
                        for: request
                    )
                }

                let descriptors = try await appSession.referencedSources()
                let normalizedRequestedPath = requestedPath.map(expandPath(_:))
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
                    return encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(refreshed),
                            selectedPath: refreshed.lastKnownPath,
                            message: "The requested Source already exists; no duplicate Source was created."
                        ),
                        for: request
                    )
                }

                let selectedURL = try await requestSourceURL(
                    mode: mode,
                    requestedPath: normalizedRequestedPath
                )
                guard let selectedURL else {
                    return interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard let job = appSession.startSourceImportJob(
                    selection: selection,
                    playlistID: playlistID,
                    libraryID: session.context.id
                ) else {
                    selection.release()
                    throw AutomationParameterError.invalidValue("path")
                }
                selection.release()
                return encodeResult(
                    AutomationSourceCreateResult(
                        applied: false,
                        completed: false,
                        selectedPath: selectedURL.path,
                        job: makeJobSummary(job),
                        message: playlistID == nil
                            ? "Source authorization accepted; import/reconcile started as a Job."
                            : "Source authorization accepted; import/reconcile and Playlist binding started as a Job."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceBindPlaylist:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                return encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        source: updated.map(makeSourceSummary),
                        message: "Source-to-Playlist binding updated."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceSetExcludedPath:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                return encodeResult(
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
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceSetMonitorPolicy:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                return encodeResult(
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
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.sourceRemove:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
                        AutomationSourceCreateResult(
                            applied: false,
                            source: makeSourceSummary(descriptor),
                            message: "Preview only. Removing the Source authority retains user files; Tracks with no other source become missing."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "Removing a Source requires confirm=true; the App will still ask for foreground confirmation.",
                        details: .object(["sourceID": .string(sourceID.uuidString)])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "Remove source?",
                    message: "Remove \(descriptor.displayName) from the active library? Files will not be deleted; affected Tracks may become missing."
                ) else {
                    return interactionCancelled(for: request)
                }
                try await appSession.removeReferencedSource(
                    id: sourceID,
                    libraryID: session.context.id
                )
                return encodeResult(
                    AutomationSourceCreateResult(
                        applied: true,
                        selectedPath: descriptor.lastKnownPath,
                        message: "Source removed; physical files were retained."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesInspect:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                let tracks = try automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
                return encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesInspect,
                        applied: false,
                        dryRun: true,
                        files: tracks.map { makeFileSummary($0) },
                        message: "Physical file state inspected; no file system mutation was applied."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.filesRename, AutomationMethod.filesMove:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let files = plans.map { makeFileSummary($0.track) }
                if dryRun {
                    return encodeResult(
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

                if plans.count > 1 {
                    guard confirm else {
                        return confirmationRequired(
                            for: request,
                            message: "Bulk file rename/move requires confirm=true and a foreground App confirmation.",
                            details: .object([
                                "operation": .string(request.method),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await confirmDestructiveOperation(
                        title: request.method == AutomationMethod.filesRename
                            ? "Rename multiple music files?"
                            : "Move multiple music files?",
                        message: "This will change the locations of \(plans.count) real music files. The App will rescan the affected Sources afterward."
                    ) else {
                        return interactionCancelled(for: request)
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
                    makeFileSummary(
                        plan.track,
                        pathOverride: plan.destination?.path,
                        existsOverride: plan.destination.map { FileManager.default.fileExists(atPath: $0.path) }
                    )
                }
                return encodeResult(
                    AutomationFileOperationResult(
                        operation: request.method,
                        applied: true,
                        dryRun: false,
                        confirmed: plans.count > 1 && confirm,
                        affectedTrackIDs: plans.map(\.trackID),
                        files: appliedFiles,
                        jobs: jobs,
                        message: "File operation applied. Source reconciliation Jobs were started to update Track locations."
                    ),
                    for: request
                )
            } catch let error as AutomationFileOperationError {
                return invalidParameters(for: request, error: error)
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
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let files = plans.map { makeFileSummary($0.track) }
                if dryRun {
                    return encodeResult(
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
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "Moving real music files to the Trash requires confirm=true and a foreground App confirmation.",
                        details: .object([
                            "operation": .string(AutomationMethod.filesDelete),
                            "fileCount": .number(Double(plans.count))
                        ])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "Move music files to Trash?",
                    message: "Move \(plans.count) real music file(s) to the macOS Trash? Tracks, metadata, history and Playlist membership will remain in the Library and become missing after Source refresh."
                ) else {
                    return interactionCancelled(for: request)
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
                    makeFileSummary(
                        plan.track,
                        existsOverride: outcome.0.contains(plan.trackID) ? false : nil
                    )
                }
                return encodeResult(
                    AutomationFileOperationResult(
                        operation: AutomationMethod.filesDelete,
                        applied: !outcome.0.isEmpty,
                        dryRun: false,
                        confirmed: true,
                        affectedTrackIDs: outcome.0,
                        files: appliedFiles,
                        jobs: jobs,
                        failures: outcome.1,
                        message: "Selected files were moved to the macOS Trash; the App started Source refresh Jobs to mark them missing without deleting Library records."
                    ),
                    for: request
                )
            } catch let error as AutomationFileOperationError {
                return invalidParameters(for: request, error: error)
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

        case AutomationMethod.playbackState:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                makePlaybackState(session.playbackCoordinator),
                for: request
            )

        case AutomationMethod.playbackPlay,
             AutomationMethod.playbackPause,
             AutomationMethod.playbackNext,
             AutomationMethod.playbackPrevious,
             AutomationMethod.playbackSeek,
             AutomationMethod.playbackSetVolume,
             AutomationMethod.playbackSetMode:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                switch request.method {
                case AutomationMethod.playbackPlay:
                    let singleTrackID = try parameters.uuid("trackID")
                    let trackIDs = try parameters.uuidArray("trackIDs", allowEmpty: true)
                    let startIndex = try parameters.integer("startIndex", default: 0)
                    if let singleTrackID {
                        guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == singleTrackID }) else {
                            throw AutomationParameterError.missingResource("trackID")
                        }
                        session.playbackCoordinator.play(track: track)
                    } else if !trackIDs.isEmpty {
                        let tracks = try automationTracks(
                            ids: trackIDs,
                            in: session.libraryViewModel.allTracks
                        )
                        guard (0..<tracks.count).contains(startIndex) else {
                            throw AutomationParameterError.outOfRange("startIndex")
                        }
                        session.playbackCoordinator.playTracks(
                            tracks,
                            startingAt: startIndex
                        )
                    } else {
                        session.playbackCoordinator.resume()
                    }
                case AutomationMethod.playbackPause:
                    guard request.params == nil || request.params == .null || isObject(request.params) else {
                        throw AutomationParameterError.invalidShape
                    }
                    session.playbackCoordinator.pause()
                case AutomationMethod.playbackNext:
                    session.playbackCoordinator.next()
                case AutomationMethod.playbackPrevious:
                    session.playbackCoordinator.previous()
                case AutomationMethod.playbackSeek:
                    guard let seconds = try parameters.double("seconds") else {
                        throw AutomationParameterError.missing("seconds")
                    }
                    guard seconds >= 0 else { throw AutomationParameterError.outOfRange("seconds") }
                    session.playbackCoordinator.seek(to: seconds)
                case AutomationMethod.playbackSetVolume:
                    guard let volume = try parameters.double("volume") else {
                        throw AutomationParameterError.missing("volume")
                    }
                    guard (0...1).contains(volume) else {
                        throw AutomationParameterError.outOfRange("volume")
                    }
                    session.playbackCoordinator.setVolume(volume)
                case AutomationMethod.playbackSetMode:
                    let rawMode = try parameters.string("mode", required: true)!
                    guard let mode = PlaybackOrderMode(rawValue: rawMode) else {
                        throw AutomationParameterError.invalidValue("mode")
                    }
                    session.playbackCoordinator.setPlaybackOrderMode(mode, announceChange: false)
                default:
                    break
                }
                return encodeResult(
                    makePlaybackState(session.playbackCoordinator),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.queueGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(makeQueueResult(session), for: request)

        case AutomationMethod.queueReplace,
             AutomationMethod.queueEnqueue,
             AutomationMethod.queueEnqueueNext,
             AutomationMethod.queueClear:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let player = session.playerViewModel
                let current = player.currentQueueTracks
                let currentRevision = player.automationQueueRevision
                let expectedRevision = try parameters.string("expectedRevision")
                if let expectedRevision, expectedRevision != currentRevision {
                    return .failure(
                        for: request,
                        error: AutomationError(
                            code: .conflict,
                            message: "The queue changed since it was queried.",
                            retryable: true,
                            details: .object([
                                "expectedRevision": .string(expectedRevision),
                                "actualRevision": .string(currentRevision)
                            ])
                        )
                    )
                }
                let dryRun = try parameters.boolean("dryRun", default: false)
                let nextIDs: [UUID]
                let mutationTracks: [Track]
                switch request.method {
                case AutomationMethod.queueClear:
                    nextIDs = []
                    mutationTracks = []
                case AutomationMethod.queueReplace:
                    nextIDs = try parameters.uuidArray("trackIDs", required: true, allowEmpty: true)
                    mutationTracks = try automationTracks(ids: nextIDs, in: session.libraryViewModel.allTracks)
                case AutomationMethod.queueEnqueue:
                    let appended = try parameters.uuidArray("trackIDs", required: true)
                    nextIDs = current.map(\.id) + appended
                    mutationTracks = try automationTracks(ids: appended, in: session.libraryViewModel.allTracks)
                case AutomationMethod.queueEnqueueNext:
                    let appended = try parameters.uuidArray("trackIDs", required: true)
                    mutationTracks = try automationTracks(ids: appended, in: session.libraryViewModel.allTracks)
                    let currentTrackID = session.playbackCoordinator.presentation.localTrack?.id
                    nextIDs = predictedQueueAfterEnqueueNext(
                        currentIDs: current.map(\.id),
                        currentTrackID: currentTrackID,
                        insertedIDs: mutationTracks.map(\.id)
                    )
                default:
                    throw AutomationParameterError.invalidValue("method")
                }
                if dryRun {
                    return encodeResult(
                        makeQueueResult(
                            session,
                            trackIDs: nextIDs,
                            revision: currentRevision
                        ),
                        for: request
                    )
                }
                switch request.method {
                case AutomationMethod.queueEnqueueNext:
                    let inserted = session.playbackCoordinator.insertTracksAfterCurrent(mutationTracks)
                    if inserted == 0 {
                        player.updateQueueTracks(current + mutationTracks)
                    }
                case AutomationMethod.queueEnqueue:
                    player.updateQueueTracks(current + mutationTracks)
                default:
                    player.updateQueueTracks(mutationTracks)
                }
                return encodeResult(makeQueueResult(session), for: request)
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.historyList:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let limit = try parameters.integer("limit", default: 100)
                guard (1...500).contains(limit) else {
                    throw AutomationParameterError.outOfRange("limit")
                }
                let from = try parameters.date("from")
                let to = try parameters.date("to")
                let items: [PlaybackHistoryItem]
                if let from {
                    items = session.playbackHistoryStore.fetchItems(
                        from: from,
                        to: to,
                        limit: limit
                    )
                } else {
                    items = session.playbackHistoryStore.fetchItems(limit: limit)
                }
                return encodeResult(
                    AutomationHistoryListResult(
                        items: items.map(makeHistoryItem),
                        revision: "v1-\(session.playbackHistoryStore.revision)"
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.historyClear:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let confirm = try parameters.boolean("confirm", default: false)
                let count = session.playbackHistoryStore.fetchItems().count
                if dryRun {
                    return encodeResult(
                        AutomationHistoryListResult(
                            items: [],
                            revision: "v1-\(session.playbackHistoryStore.revision)"
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "Clearing listening history requires confirm=true; the App will still ask for foreground confirmation.",
                        details: .object(["recordCount": .number(Double(count))])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "Clear listening history?",
                    message: "Delete \(count) listening history records? This cannot be undone from the App."
                ) else {
                    return interactionCancelled(for: request)
                }
                guard session.playbackHistoryStore.clearAll() else {
                    throw AutomationParameterError.invalidValue("history")
                }
                return encodeResult(
                    AutomationHistoryListResult(
                        items: [],
                        revision: "v1-\(session.playbackHistoryStore.revision)"
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                var trackIDs = try parameters.uuidArray("trackIDs")
                if let trackID = try parameters.uuid("trackID") {
                    trackIDs.append(trackID)
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
                return encodeResult(
                    AutomationLibraryTracksResult(
                        tracks: tracks.map {
                            makeTrackSummary(
                                $0,
                                playlists: session.libraryViewModel.playlists,
                                includeFilePath: grantedScopes().contains(.filesRead)
                            )
                        },
                        total: tracks.count,
                        offset: 0,
                        limit: tracks.count
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.metadataPatch:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackIDs = try parameters.uuidArray("trackIDs", required: true)
                guard let patchValues = try parameters.object("patch"), !patchValues.isEmpty else {
                    throw AutomationParameterError.missing("patch")
                }
                let patch = try makeMetadataPatch(patchValues)
                let expectedRevisions = try makeTrackRevisions(
                    from: parameters.object("expectedRevisions")
                )
                let dryRun = try parameters.boolean("dryRun", default: false)
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
                    return encodeResult(
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
                let outcome = try await session.libraryViewModel.applyMetadataPatchForAutomation(
                    trackIDs: trackIDs,
                    patch: patch,
                    expectedRevisions: expectedRevisions
                )
                return encodeResult(
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
                return mutationFailure(for: request, error: error)
            }

        case AutomationMethod.lyricsGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                return encodeResult(
                    AutomationLyricsDetail(
                        trackID: trackID,
                        status: trackLyricsStatus(track),
                        ttml: track.ttmlLyricText,
                        plainText: track.lyricsText
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsSearch, AutomationMethod.lyricsCandidates:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                return encodeResult(
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
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsCompare:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let currentQuality = currentLyricsQuality(track)
                let candidateQuality = lyricsQuality(for: candidate)
                return encodeResult(
                    AutomationLyricsComparisonResult(
                        trackID: trackID,
                        currentStatus: trackLyricsStatus(track),
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
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsApply:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let force = try parameters.boolean("force", default: false)
                let translation = try parameters.boolean("translation", default: true)
                let dryRun = try parameters.boolean("dryRun", default: false)
                let expectedRevision = try parameters.string("expectedRevision")
                let currentQuality = currentLyricsQuality(track)
                let estimatedQuality = lyricsQuality(for: candidate)
                if let expectedRevision,
                   expectedRevision != session.libraryViewModel.automationTrackRevision(for: track) {
                    return trackRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: session.libraryViewModel.automationTrackRevision(for: track)
                    )
                }
                if dryRun {
                    return encodeResult(
                        AutomationLyricsApplyResult(
                            trackID: trackID,
                            applied: false,
                            dryRun: true,
                            force: force,
                            candidate: candidate,
                            currentQuality: currentQuality,
                            candidateQuality: estimatedQuality,
                            message: force
                                ? "Preview only. The selected candidate will replace the current lyrics."
                                : "Preview only. The candidate will replace the current lyrics only when its fetched quality is higher."
                        ),
                        for: request
                    )
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
                let fetchedQuality = ttml.localizedCaseInsensitiveContains("<span") ? 2 : 1
                let outcome = await session.applyAutomationLyrics(
                    trackID: trackID,
                    ttml: ttml,
                    candidateQuality: fetchedQuality,
                    force: force,
                    expectedRevision: expectedRevision
                )
                if outcome.conflicted {
                    return trackRevisionConflict(
                        for: request,
                        expected: expectedRevision ?? "unknown",
                        actual: session.libraryViewModel.allTracks
                            .first(where: { $0.id == trackID })
                            .map { session.libraryViewModel.automationTrackRevision(for: $0) }
                            ?? "unknown"
                    )
                }
                return encodeResult(
                    AutomationLyricsApplyResult(
                        trackID: trackID,
                        applied: outcome.applied,
                        dryRun: false,
                        force: force,
                        candidate: candidate,
                        currentQuality: outcome.currentQuality,
                        candidateQuality: outcome.candidateQuality,
                        message: outcome.message
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.lyricsRefresh:
            guard let session = activeSession(for: request), let appSession else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                return encodeResult(
                    AutomationLyricsRefreshResult(
                        applied: true,
                        dryRun: false,
                        selectedTrackIDs: trackIDs,
                        job: makeJobSummary(descriptor),
                        message: "Lyrics refresh Job accepted; query jobs.get for progress and failures."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsList:
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
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                AutomationJobListResult(
                    jobs: appSession.libraryJobDescriptors().map(makeJobSummary)
                ),
                for: request
            )

        case AutomationMethod.jobsGet:
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
                let jobID = try parameters.uuid("jobID", required: true)!
                guard let job = appSession.libraryJobDescriptors().first(where: { $0.id == jobID }) else {
                    throw AutomationParameterError.missingResource("jobID")
                }
                return encodeResult(makeJobSummary(job), for: request)
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsCancel:
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
                let jobID = try parameters.uuid("jobID", required: true)!
                guard appSession.cancelLibraryJob(
                    id: jobID,
                    libraryID: request.context.libraryID
                ) else {
                    throw AutomationParameterError.missingResource("jobID")
                }
                return encodeResult(
                    AutomationJSONValue.object([
                        "jobID": .string(jobID.uuidString),
                        "cancelRequested": .boolean(true)
                    ]),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.jobsRetry:
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
                let jobID = try parameters.uuid("jobID", required: true)!
                guard let descriptor = appSession.libraryJobDescriptors()
                    .first(where: { $0.id == jobID }) else {
                    throw AutomationParameterError.missingResource("jobID")
                }
                guard descriptor.retrySpec != nil else {
                    throw AutomationParameterError.invalidValue("jobID")
                }
                guard descriptor.state == .failed
                    || descriptor.state == .partialFailure
                    || descriptor.state == .cancelled else {
                    throw AutomationParameterError.invalidValue("jobID")
                }
                guard let retryJob = appSession.retryLibraryJob(
                    id: jobID,
                    libraryID: request.context.libraryID
                ) else {
                    throw AutomationParameterError.invalidValue("jobID")
                }
                return encodeResult(
                    AutomationJobRetryResult(
                        originalJobID: jobID,
                        accepted: true,
                        job: makeJobSummary(retryJob),
                        message: "Job retry accepted; query jobs.get for the new Job's progress."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.diagnosticsHealth:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let tracks = session.libraryViewModel.allTracks
                let missing = tracks.filter { $0.availability == .missing }.count
                let unavailable = tracks.filter { $0.availability != .available }.count
                let sources = try await appSession.referencedSources()
                let sourceIssues = sources
                    .filter { $0.status != .available }
                    .map { "\($0.displayName): \($0.status.rawValue) (\($0.lastKnownPath))" }
                let jobs = appSession.libraryJobDescriptors()
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
                }
                let checks = [
                    "library": "ok",
                    "sources": sourceIssues.isEmpty ? "ok" : "attention",
                    "missingTracks": missing == 0 ? "ok" : "attention",
                    "unavailableTracks": unavailable == 0 ? "ok" : "attention",
                    "jobs": runningJobs == 0 ? (failedJobs.isEmpty ? "idle" : "attention") : "running",
                    "playlistReferences": playlistReferenceIssues.isEmpty ? "ok" : "attention",
                    "storage": storageValidation == "passed" ? "ok" : "attention"
                ]
                return encodeResult(
                    AutomationDiagnosticsResult(
                        healthy: sourceIssues.isEmpty
                            && unavailable == 0
                            && failedJobs.isEmpty
                            && playlistReferenceIssues.isEmpty
                            && storageValidation == "passed",
                        libraryID: session.context.id,
                        trackCount: tracks.count,
                        playlistCount: session.libraryViewModel.playlists.count,
                        missingTrackCount: missing,
                        unavailableTrackCount: unavailable,
                        sourceCount: sources.count,
                        sourceIssues: sourceIssues,
                        runningJobCount: runningJobs,
                        checks: checks,
                        failedJobCount: failedJobs.count,
                        failedJobSummaries: Array(failedJobSummaries),
                        playlistReferenceIssues: playlistReferenceIssues,
                        storageValidation: storageValidation,
                        storageValidationMessage: storageValidationMessage
                    ),
                    for: request
                )
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

        case AutomationMethod.settingsGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                let settings = try await appSession.libraryScopedSettings()
                let values = automationSettingsValues(settings)
                return encodeResult(
                    AutomationSettingsResult(
                        libraryID: session.context.id,
                        values: values,
                        revision: automationSettingsRevision(values),
                        message: "Only persistent settings with an App-owned automation contract are returned."
                    ),
                    for: request
                )
            } catch {
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .internalError,
                        message: "Failed to read automation settings.",
                        details: .object(["reason": .string(String(describing: error))])
                    )
                )
            }

        case AutomationMethod.settingsPatch:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    throw AutomationParameterError.invalidValue("values")
                }
                let parameters = try AutomationParameters(request)
                let requestedValues = try parameters.object("values") ?? [:]
                guard !requestedValues.isEmpty else {
                    throw AutomationParameterError.invalidValue("values")
                }
                let supportedKeys: Set<String> = ["referencedTrackDeletePolicy"]
                guard Set(requestedValues.keys).isSubset(of: supportedKeys) else {
                    throw AutomationParameterError.invalidValue("values")
                }
                let current = try await appSession.libraryScopedSettings()
                let currentValues = automationSettingsValues(current)
                let currentRevision = automationSettingsRevision(currentValues)
                if let expectedRevision = try parameters.string("expectedRevision"),
                   expectedRevision != currentRevision {
                    return settingsRevisionConflict(
                        for: request,
                        expected: expectedRevision,
                        actual: currentRevision
                    )
                }
                let requestedPolicy: ReferencedTrackDeletePolicy?
                if let rawValue = requestedValues["referencedTrackDeletePolicy"] {
                    guard case .string(let rawPolicy) = rawValue,
                          let policy = ReferencedTrackDeletePolicy(rawValue: rawPolicy) else {
                        throw AutomationParameterError.invalidValue("values.referencedTrackDeletePolicy")
                    }
                    requestedPolicy = policy
                } else {
                    requestedPolicy = nil
                }
                var next = current
                if let requestedPolicy {
                    next.referencedTrackDeletePolicy = requestedPolicy
                }
                let nextValues = automationSettingsValues(next)
                let dryRun = try parameters.boolean("dryRun", default: false)
                if dryRun {
                    return encodeResult(
                        AutomationSettingsResult(
                            libraryID: session.context.id,
                            values: nextValues,
                            revision: automationSettingsRevision(nextValues),
                            applied: false,
                            dryRun: true,
                            message: "Preview only. No persistent setting was changed."
                        ),
                        for: request
                    )
                }
                if requestedPolicy == .recycleSource {
                    let confirm = try parameters.boolean("confirm", default: false)
                    guard confirm else {
                        return confirmationRequired(
                            for: request,
                            message: "Enabling recycleSource changes the future behavior of referenced Track deletion and requires App confirmation.",
                            details: .object([
                                "setting": .string("referencedTrackDeletePolicy"),
                                "value": .string(ReferencedTrackDeletePolicy.recycleSource.rawValue)
                            ])
                        )
                    }
                    guard await confirmDestructiveOperation(
                        title: "Change referenced Track deletion policy?",
                        message: "Future referenced Track removals may move their source files to the Trash."
                    ) else {
                        return interactionCancelled(for: request)
                    }
                }
                if let requestedPolicy {
                    try await appSession.setReferencedTrackDeletePolicy(
                        requestedPolicy,
                        libraryID: session.context.id
                    )
                }
                return encodeResult(
                    AutomationSettingsResult(
                        libraryID: session.context.id,
                        values: nextValues,
                        revision: automationSettingsRevision(nextValues),
                        applied: true,
                        message: "Persistent automation settings updated by the App."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.storageInspect:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                storageResult(for: session, validation: "notRun"),
                for: request
            )

        case AutomationMethod.storageValidate:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            do {
                try await LibraryUpgradeSessionValidator.validate(
                    context: session.context,
                    libraryViewModel: session.libraryViewModel,
                    repository: session.repository,
                    searchIndex: session.searchIndex,
                    playbackHistoryStore: session.playbackHistoryStore
                )
                return encodeResult(
                    storageResult(
                        for: session,
                        validation: "passed",
                        validationMessage: "The App-owned storage validator passed."
                    ),
                    for: request
                )
            } catch {
                return encodeResult(
                    storageResult(
                        for: session,
                        validation: "failed",
                        validationMessage: String(describing: error),
                        message: "Storage validation found an issue; no repair was attempted."
                    ),
                    for: request
                )
            }

        case AutomationMethod.storageRepair:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let dryRun = try parameters.boolean("dryRun", default: false)
                if dryRun {
                    return encodeResult(
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
                return encodeResult(
                    storageResult(
                        for: session,
                        validation: "notRun",
                        message: "Library scaffolding repair completed. Run storage.validate to verify all invariants."
                    ),
                    for: request
                )
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
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            do {
                let snapshot = try await storageDiskSnapshot(for: session)
                return encodeResult(
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
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            do {
                let context = session.context
                let result = try await session.runLibraryOperation(as: .other) {
                    try await Task.detached(priority: .utility) {
                        try Self.createStorageBackup(context: context)
                    }.value
                }
                return encodeResult(result, for: request)
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
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let backupPath = try parameters.string("backupPath", required: true)!
                let context = session.context
                let result = try await Task.detached(priority: .utility) {
                    try Self.storageDiff(context: context, backupPath: backupPath)
                }.value
                return encodeResult(result, for: request)
            } catch let error as AutomationParameterError {
                return invalidParameters(for: request, error: error)
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
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            do {
                let _: Void = try await session.runLibraryOperation(as: .other) {
                    await session.libraryViewModel.reloadLibrary()
                }
                return encodeResult(
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
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
                AutomationCapabilityResult(
                    grantedScopes: Array(grantedScopes()),
                    deniedScopes: AutomationScope.allCases.filter {
                        !grantedScopes().contains($0)
                    },
                    notes: [
                        "Normal library and playback mutations execute directly once the local App policy authorizes them.",
                        "High-risk operations require dryRun/preview, caller acknowledgement and a foreground App confirmation.",
                        "A missing referenced file preserves its Track, metadata, history and Playlist membership by default."
                    ]
                ),
                for: request
            )

        case AutomationMethod.automationScopes:
            guard request.params == nil || request.params == .null || isObject(request.params) else {
                return invalidParameters(for: request)
            }
            return encodeResult(
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
                    return encodeResult(
                        AutomationScopeMutationResult(
                            scope: scope,
                            granted: grantedScopes().contains(scope),
                            message: "Preview only. Granting a scope changes the App-owned automation policy."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "Granting an automation scope requires confirm=true and a foreground App confirmation.",
                        details: .object(["scope": .string(scope.rawValue)])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "Grant automation scope?",
                    message: "Allow external automation to use the \(scope.rawValue) capability?"
                ) else {
                    return interactionCancelled(for: request)
                }
                var scopes = grantedScopes()
                scopes.insert(scope)
                try scopePolicyStore.save(scopes)
                cachedGrantedScopes = scopes
                return encodeResult(
                    AutomationScopeMutationResult(
                        scope: scope,
                        granted: true,
                        message: "Scope granted and persisted by the App."
                    ),
                    for: request
                )
            } catch {
                return mutationFailure(for: request, error: error)
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
                return encodeResult(
                    AutomationScopeMutationResult(
                        scope: scope,
                        granted: false,
                        message: "Scope revoked for future automation calls."
                    ),
                    for: request
                )
            } catch {
                return mutationFailure(for: request, error: error)
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

    private func responseForRequest(
        _ response: AutomationResponse,
        requestID: UUID
    ) -> AutomationResponse {
        AutomationResponse(
            requestID: requestID,
            result: response.result,
            error: response.error,
            serverTime: response.serverTime,
            protocolVersion: response.protocolVersion
        )
    }

    private func grantedScopes() -> Set<AutomationScope> {
        if let cachedGrantedScopes {
            return cachedGrantedScopes
        }
        let loaded = scopePolicyStore.load()
        cachedGrantedScopes = loaded
        return loaded
    }

    private func makeMetadataPatch(
        _ values: [String: AutomationJSONValue]
    ) throws -> LibraryAutomationMetadataPatch {
        let allowed: Set<String> = [
            "title", "artist", "album", "albumArtist", "description",
            "genreTags", "releaseDate"
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
        let releaseDate: Date?
        if let value = values["releaseDate"] {
            switch value {
            case .null:
                releaseDate = nil
            case .string(let string):
                guard let date = ISO8601DateFormatter().date(from: string) else {
                    throw AutomationParameterError.invalidValue("releaseDate")
                }
                releaseDate = date
            default:
                throw AutomationParameterError.invalidType("releaseDate", expected: "ISO-8601 string or null")
            }
        } else {
            releaseDate = nil
        }
        return LibraryAutomationMetadataPatch(
            fields: Set(values.keys),
            title: try stringValue("title"),
            artist: try stringValue("artist"),
            album: try stringValue("album"),
            albumArtist: try stringValue("albumArtist"),
            userDescription: try stringValue("description"),
            genreTags: try stringArrayValue("genreTags"),
            releaseDate: releaseDate
        )
    }

    private func automationSettingsValues(
        _ settings: LibraryScopedSettings
    ) -> [String: AutomationJSONValue] {
        [
            "referencedTrackDeletePolicy": .string(
                settings.referencedTrackDeletePolicy.rawValue
            )
        ]
    }

    private func automationSettingsRevision(
        _ values: [String: AutomationJSONValue]
    ) -> String {
        guard case .string(let policy) = values["referencedTrackDeletePolicy"] else {
            return "v1-unknown"
        }
        return "v1-" + policy
    }

    private func settingsRevisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        return .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The persistent automation settings changed since they were queried.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
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
        libraryID: UUID
    ) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(libraryID.uuidString, isDirectory: true)
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
        context: LibraryContext
    ) throws -> AutomationStorageBackupResult {
        let createdAt = Date()
        let inventory = try storageInventory(at: context.rootURL)
        let fileManager = FileManager.default
        let root = automationStorageBackupRoot(libraryID: context.id)
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
        return AutomationStorageBackupResult(
            libraryID: context.id,
            backupPath: destination.path,
            createdAt: createdAt,
            copiedFileCount: copiedFiles.count,
            omittedFileCount: inventory.omittedFileCount,
            copiedBytes: copiedBytes,
            failures: Array(failures.prefix(50)),
            message: "Created a metadata-only backup. Audio files, indexes, caches and live SQLite stores were intentionally omitted."
        )
    }

    private nonisolated static func storageBackupManifest(
        context: LibraryContext,
        backupPath: String
    ) throws -> (URL, AutomationStorageBackupManifest) {
        let candidate = URL(fileURLWithPath: backupPath).standardizedFileURL
        let root = automationStorageBackupRoot(libraryID: context.id).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else {
            throw AutomationParameterError.invalidValue("backupPath")
        }
        let manifestURL = candidate.appendingPathComponent("automation-backup.json")
        guard let data = try? Data(contentsOf: manifestURL),
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
        backupPath: String
    ) throws -> AutomationStorageDiffResult {
        let (backupURL, manifest) = try storageBackupManifest(
            context: context,
            backupPath: backupPath
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
        message: String = "The App-owned Library storage layout was inspected."
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
        return AutomationStorageResult(
            libraryID: session.context.id,
            mode: session.context.mode.rawValue,
            rootPath: rootPath,
            schemaVersion: manifest?.schemaVersion,
            manifestPresent: fileManager.fileExists(atPath: paths.manifestURL.path),
            missingRequiredDirectories: missingDirectories,
            validation: validation,
            validationMessage: validationMessage,
            message: message
        )
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
        if patch.fields.contains("releaseDate"), track.releaseDate != patch.releaseDate { return true }
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
                "files.delete and storage.write are denied by default and require foreground confirmation before granting."
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
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let directory = appSupport
            .appendingPathComponent("kmgccc.player", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
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
        case AutomationMethod.libraryTracks: return "selection"
        case AutomationMethod.playlistAddTracks,
             AutomationMethod.playlistRemoveTracks,
             AutomationMethod.playlistReplaceTracks,
             AutomationMethod.playlistReorder: return "playlist"
        case AutomationMethod.sourceRefresh,
             AutomationMethod.sourceBindPlaylist,
             AutomationMethod.sourceSetExcludedPath,
             AutomationMethod.sourceSetMonitorPolicy,
             AutomationMethod.sourceRemove: return "source"
        case AutomationMethod.filesInspect,
             AutomationMethod.filesRename,
             AutomationMethod.filesMove,
             AutomationMethod.filesDelete: return "files"
        case AutomationMethod.metadataGet,
             AutomationMethod.metadataPatch,
             AutomationMethod.lyricsGet,
             AutomationMethod.lyricsSearch,
             AutomationMethod.lyricsCandidates,
             AutomationMethod.lyricsCompare,
             AutomationMethod.lyricsApply,
             AutomationMethod.lyricsRefresh,
             AutomationMethod.queueReplace,
             AutomationMethod.queueEnqueue,
             AutomationMethod.queueEnqueueNext: return "tracks"
        case AutomationMethod.storageInspect,
             AutomationMethod.storageValidate,
             AutomationMethod.storageOrphans,
             AutomationMethod.storageBackup,
             AutomationMethod.storageDiff,
             AutomationMethod.storageReload,
             AutomationMethod.storageRepair: return "storage"
        default: return "operation"
        }
    }

    private func auditTargetCount(_ request: AutomationRequest) -> Int? {
        guard case .object(let values) = request.params else { return nil }
        for key in ["trackIDs", "playlistIDs", "sourceIDs", "paths"] {
            if case .array(let items) = values[key] {
                return items.count
            }
        }
        return values["trackID"] != nil || values["playlistID"] != nil || values["sourceID"] != nil
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

    private func isObject(_ value: AutomationJSONValue?) -> Bool {
        guard let value else { return false }
        if case .object = value { return true }
        return false
    }

    /// CLI requests commonly omit params while MCP tools/call conventionally
    /// supplies an empty arguments object. Both represent a no-argument call.
    private func isEmptyParameters(_ value: AutomationJSONValue?) -> Bool {
        guard let value else { return true }
        switch value {
        case .null:
            return true
        case .object(let values):
            return values.isEmpty
        default:
            return false
        }
    }

    private func automationTracks(ids: [UUID], in allTracks: [Track]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
        let missing = ids.filter { byID[$0] == nil }
        guard missing.isEmpty else {
            throw AutomationParameterError.invalidValue("trackIDs")
        }
        return ids.compactMap { byID[$0] }
    }

    private func makePlaybackState(
        _ coordinator: PlaybackCoordinator
    ) -> AutomationPlaybackState {
        let presentation = coordinator.presentation
        let currentTrack = presentation.localTrack
        let playbackMode = presentation.localPlaybackOrderMode?.rawValue
            ?? AppSettings.shared.playbackOrderMode.rawValue
        return AutomationPlaybackState(
            source: coordinator.activeSource.rawValue,
            isPlaying: presentation.isPlaying,
            currentTrackID: currentTrack?.id,
            currentTitle: presentation.title.isEmpty ? nil : presentation.title,
            currentArtist: presentation.artist.isEmpty ? nil : presentation.artist,
            position: max(0, presentation.currentTime),
            duration: max(0, presentation.duration),
            volume: min(max(presentation.volume, 0), 1),
            playbackMode: playbackMode
        )
    }

    private func makeQueueResult(
        _ session: LibrarySession,
        trackIDs: [UUID]? = nil,
        revision: String? = nil
    ) -> AutomationQueueResult {
        AutomationQueueResult(
            trackIDs: trackIDs ?? session.playerViewModel.currentQueueTracks.map(\.id),
            currentTrackID: session.playbackCoordinator.presentation.localTrack?.id,
            revision: revision ?? session.playerViewModel.automationQueueRevision
        )
    }

    /// Mirrors the ordinary (non-shuffle) queue insertion contract for a
    /// dry-run result. The playback owner remains authoritative for the real
    /// mutation; this helper only makes sure a preview never treats the whole
    /// existing queue as newly inserted tracks.
    private func predictedQueueAfterEnqueueNext(
        currentIDs: [UUID],
        currentTrackID: UUID?,
        insertedIDs: [UUID]
    ) -> [UUID] {
        var seen = Set<UUID>()
        let uniqueInserted = insertedIDs.filter { seen.insert($0).inserted }
        guard let currentTrackID,
              currentIDs.contains(currentTrackID) else {
            return currentIDs + uniqueInserted
        }

        let eligibleInserted = uniqueInserted.filter { $0 != currentTrackID }
        let insertionSet = Set(eligibleInserted)
        var queue = currentIDs.filter { !insertionSet.contains($0) }
        guard let updatedCurrentIndex = queue.firstIndex(of: currentTrackID) else {
            return currentIDs + uniqueInserted
        }
        queue.insert(contentsOf: eligibleInserted, at: updatedCurrentIndex + 1)
        return queue
    }

    private func makeHistoryItem(_ item: PlaybackHistoryItem) -> AutomationHistoryItem {
        AutomationHistoryItem(
            id: item.id,
            trackID: item.trackID,
            playedAt: item.playedAt,
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            playedSeconds: item.playedSeconds
        )
    }

    private func makeJobSummary(
        _ descriptor: LibraryOperationTaskDescriptor
    ) -> AutomationJobSummary {
        let kind: String
        switch descriptor.kind {
        case .importFiles: kind = "importFiles"
        case .sourceScan: kind = "sourceScan"
        case .ncmConversion: kind = "ncmConversion"
        case .enrichment: kind = "enrichment"
        case .indexUpdate: kind = "indexUpdate"
        case .other: kind = "other"
        }
        let state: AutomationJobState
        switch descriptor.state {
        case .queued: state = .queued
        case .running: state = .running
        case .checkpointed: state = .checkpointed
        case .completed: state = .completed
        case .partialFailure: state = .partialFailure
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        return AutomationJobSummary(
            id: descriptor.id,
            kind: kind,
            libraryID: descriptor.libraryID,
            state: state,
            createdAt: descriptor.createdAt,
            startedAt: descriptor.startedAt,
            finishedAt: descriptor.finishedAt,
            checkpoint: descriptor.lastCheckpointLabel,
            completedCount: descriptor.completedCount ?? 0,
            totalCount: descriptor.totalCount,
            currentPhase: descriptor.currentPhase,
            failures: descriptor.partialFailureSummaries,
            failedItemIDs: descriptor.failedItemIDs,
            retryable: descriptor.retrySpec != nil
                && (descriptor.state == .failed
                    || descriptor.state == .partialFailure
                    || descriptor.state == .cancelled)
        )
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

    private func currentLyricsQuality(_ track: Track) -> Int {
        if let ttml = track.ttmlLyricText,
           !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ttml.localizedCaseInsensitiveContains("<span") ? 2 : 1
        }
        if track.ttmlLyricsFileName != nil { return 1 }
        if let plain = track.lyricsText,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.looksLikeLRC(plain) ? 1 : 0
        }
        return 0
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

    private func trackRevisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The Track changed while the lyrics candidate was being prepared.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }

    private func expandPath(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    /// The picker is intentionally owned by the App. A raw path from an
    /// external process is not treated as authorization; when it is not an
    /// already-known Source, the user must select the directory/file through
    /// AppKit so a security-scoped bookmark can be created.
    private func requestSourceURL(
        mode: ReferencedSourceMode,
        requestedPath: String?
    ) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = mode == .directory
        panel.canChooseFiles = mode == .file
        panel.allowsMultipleSelection = false
        panel.title = mode == .directory ? "Choose a music folder" : "Choose a music file"
        panel.prompt = "Add Source"
        if let requestedPath {
            let requestedURL = URL(fileURLWithPath: requestedPath)
            panel.directoryURL = FileManager.default.fileExists(atPath: requestedURL.path)
                && requestedURL.hasDirectoryPath
                ? requestedURL
                : requestedURL.deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    private func confirmDestructiveOperation(title: String, message: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func interactionCancelled(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .interactionRequired,
                message: "The App interaction was cancelled or is not available; no mutation was applied.",
                retryable: false
            )
        )
    }

    private func activeSession(for request: AutomationRequest) -> LibrarySession? {
        guard let session = appSession?.activeLibraryBinding.activeSession else {
            return nil
        }
        guard request.context.libraryID == nil
            || request.context.libraryID == session.context.id else {
            return nil
        }
        return session
    }

    private func noActiveLibraryResponse(for request: AutomationRequest) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: appSession == nil ? .serverUnavailable : .libraryNotActive,
                message: appSession == nil
                    ? "The player App is no longer available."
                    : "The requested library is not active.",
                retryable: true
            )
        )
    }

    private func confirmationRequired(
        for request: AutomationRequest,
        message: String = "This mutation requires dryRun=false and confirm=true.",
        details: AutomationJSONValue? = nil
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .authorizationRequired,
                message: message,
                details: details ?? .object([
                    "required": .array([.string("dryRun=false"), .string("confirm=true")])
                ])
            )
        )
    }

    private func revisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The playlist changed since it was queried.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }

    private func mutationFailure(
        for request: AutomationRequest,
        error: Error
    ) -> AutomationResponse {
        if let error = error as? LibraryAutomationMutationError {
            switch error {
            case .sessionQuiescing:
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .conflict,
                        message: error.localizedDescription,
                        retryable: true
                    )
                )
            case .revisionConflict(let expected, let actual):
                return revisionConflict(
                    for: request,
                    expected: expected,
                    actual: actual
                )
            case .playlistNotFound(let playlistID):
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .invalidRequest,
                        message: error.localizedDescription,
                        details: .object(["playlistID": .string(playlistID.uuidString)])
                    )
                )
            case .resultUnavailable:
                break
            }
        }
        return .failure(
            for: request,
            error: AutomationError(
                code: .internalError,
                message: "The playlist mutation failed.",
                details: .object(["reason": .string(String(describing: error))])
            )
        )
    }

    private func matchesTrackFilter(
        _ track: Track,
        filter: AutomationJSONValue,
        playlists: [Playlist]
    ) throws -> Bool {
        guard case .object(let values) = filter else {
            throw AutomationParameterError.invalidType("filter", expected: "object")
        }

        if let all = values["all"] {
            guard case .array(let filters) = all else {
                throw AutomationParameterError.invalidType("filter.all", expected: "array")
            }
            for child in filters where try !matchesTrackFilter(track, filter: child, playlists: playlists) {
                return false
            }
        }
        if let any = values["any"] {
            guard case .array(let filters) = any, !filters.isEmpty else {
                throw AutomationParameterError.invalidType("filter.any", expected: "non-empty array")
            }
            var matched = false
            for child in filters where try matchesTrackFilter(track, filter: child, playlists: playlists) {
                matched = true
                break
            }
            if !matched { return false }
        }
        if let not = values["not"] {
            if try matchesTrackFilter(track, filter: not, playlists: playlists) { return false }
        }

        let memberships = track.mediaLocator.referencedFile?.allSourceMemberships ?? []
        let playlistIDs = Set(
            playlists.lazy.filter { playlist in
                playlist.tracks.contains { $0.id == track.id }
            }.map(\.id)
        )
        let audio = track.mediaLocator.referencedFile?.locations.first?.audioProperties
            ?? track.audioProperties
        let lyricsStatus = trackLyricsStatus(track)
        let artworkAvailable = track.artworkData != nil || track.artworkFileName != nil

        for (key, value) in values where key != "all" && key != "any" && key != "not" {
            switch key {
            case "id":
                guard case .string(let raw) = value, UUID(uuidString: raw) == track.id else { return false }
            case "ids":
                guard case .array(let rawIDs) = value else {
                    throw AutomationParameterError.invalidType("filter.ids", expected: "array")
                }
                let ids = try rawIDs.map { value -> UUID in
                    guard case .string(let raw) = value, let id = UUID(uuidString: raw) else {
                        throw AutomationParameterError.invalidValue("filter.ids")
                    }
                    return id
                }
                if !ids.contains(track.id) { return false }
            case "text":
                guard case .string(let text) = value else {
                    throw AutomationParameterError.invalidType("filter.text", expected: "string")
                }
                if !track.title.localizedCaseInsensitiveContains(text)
                    && !track.artist.localizedCaseInsensitiveContains(text)
                    && !track.album.localizedCaseInsensitiveContains(text) {
                    return false
                }
            case "titleContains":
                if try contains(value, key: key, in: track.title) == false { return false }
            case "artistContains":
                if try contains(value, key: key, in: track.artist) == false { return false }
            case "albumContains":
                if try contains(value, key: key, in: track.album) == false { return false }
            case "genreContains":
                let genres = track.genreTags.joined(separator: " ")
                if try contains(value, key: key, in: genres) == false { return false }
            case "sourceID":
                guard case .string(let raw) = value, let sourceID = UUID(uuidString: raw) else {
                    throw AutomationParameterError.invalidValue("filter.sourceID")
                }
                if !memberships.contains(where: { $0.sourceID == sourceID }) { return false }
            case "playlistID":
                guard case .string(let raw) = value, let playlistID = UUID(uuidString: raw) else {
                    throw AutomationParameterError.invalidValue("filter.playlistID")
                }
                if !playlistIDs.contains(playlistID) { return false }
            case "availability":
                guard case .string(let availability) = value else {
                    throw AutomationParameterError.invalidType("filter.availability", expected: "string")
                }
                if track.availability.rawValue != availability { return false }
            case "missing":
                guard case .boolean(let missing) = value else {
                    throw AutomationParameterError.invalidType("filter.missing", expected: "boolean")
                }
                if (track.availability == .missing) != missing { return false }
            case "hasLyrics":
                guard case .boolean(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.hasLyrics", expected: "boolean")
                }
                if (lyricsStatus != "none") != expected { return false }
            case "lyricsStatus":
                guard case .string(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.lyricsStatus", expected: "string")
                }
                if lyricsStatus != expected { return false }
            case "hasArtwork":
                guard case .boolean(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.hasArtwork", expected: "boolean")
                }
                if artworkAvailable != expected { return false }
            case "addedAfter":
                if let date = try filterDate(value, key: key), track.addedAt <= date { return false }
            case "addedBefore":
                if let date = try filterDate(value, key: key), track.addedAt >= date { return false }
            case "releaseAfter":
                guard let releaseDate = track.releaseDate,
                      let date = try filterDate(value, key: key), releaseDate > date else { return false }
            case "releaseBefore":
                guard let releaseDate = track.releaseDate,
                      let date = try filterDate(value, key: key), releaseDate < date else { return false }
            case "durationMin":
                guard case .number(let minimum) = value else {
                    throw AutomationParameterError.invalidType("filter.durationMin", expected: "number")
                }
                if track.duration < minimum { return false }
            case "durationMax":
                guard case .number(let maximum) = value else {
                    throw AutomationParameterError.invalidType("filter.durationMax", expected: "number")
                }
                if track.duration > maximum { return false }
            case "metadataConfidenceMin":
                guard case .number(let minimum) = value else {
                    throw AutomationParameterError.invalidType("filter.metadataConfidenceMin", expected: "number")
                }
                if (track.metadataConfidence ?? 0) < minimum { return false }
            case "codec":
                guard case .string(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.codec", expected: "string")
                }
                if audio?.codec?.localizedCaseInsensitiveCompare(expected) != .orderedSame { return false }
            case "format":
                guard case .string(let expected) = value else {
                    throw AutomationParameterError.invalidType("filter.format", expected: "string")
                }
                if audio?.format?.localizedCaseInsensitiveCompare(expected) != .orderedSame { return false }
            case "sampleRateHz":
                guard case .number(let expected) = value,
                      expected.isFinite,
                      expected.rounded() == expected else {
                    throw AutomationParameterError.invalidValue("filter.sampleRateHz")
                }
                if audio?.sampleRateHz != Int(expected) { return false }
            case "bitDepth":
                guard case .number(let expected) = value,
                      expected.isFinite,
                      expected.rounded() == expected else {
                    throw AutomationParameterError.invalidValue("filter.bitDepth")
                }
                if audio?.bitDepth != Int(expected) { return false }
            default:
                throw AutomationParameterError.invalidValue("filter.\(key)")
            }
        }
        return true
    }

    private func contains(
        _ value: AutomationJSONValue,
        key: String,
        in text: String
    ) throws -> Bool {
        guard case .string(let needle) = value else {
            throw AutomationParameterError.invalidType("filter.\(key)", expected: "string")
        }
        return text.localizedCaseInsensitiveContains(needle)
    }

    private func filterDate(_ value: AutomationJSONValue, key: String) throws -> Date? {
        guard case .string(let raw) = value,
              let date = ISO8601DateFormatter().date(from: raw) else {
            throw AutomationParameterError.invalidValue("filter.\(key)")
        }
        return date
    }

    private func sortTracks(
        _ tracks: [Track],
        using values: [AutomationJSONValue]
    ) throws -> [Track] {
        struct SortKey {
            let field: String
            let descending: Bool
        }
        var keys: [SortKey] = []
        for value in values {
            guard case .object(let object) = value,
                  case .string(let field) = object["field"] else {
                throw AutomationParameterError.invalidValue("sort[(index)]")
            }
            let direction: String
            if case .string(let rawDirection) = object["direction"] {
                direction = rawDirection
            } else {
                direction = "asc"
            }
            guard direction == "asc" || direction == "desc" else {
                throw AutomationParameterError.invalidValue("sort[(index)].direction")
            }
            guard ["title", "artist", "album", "duration", "addedAt", "releaseDate", "availability", "codec", "sampleRateHz", "filePath"].contains(field) else {
                throw AutomationParameterError.invalidValue("sort[(index)].field")
            }
            keys.append(SortKey(field: field, descending: direction == "desc"))
        }
        let effectiveKeys = keys.isEmpty
            ? [SortKey(field: "title", descending: false), SortKey(field: "artist", descending: false), SortKey(field: "album", descending: false)]
            : keys
        return tracks.sorted { lhs, rhs in
            for key in effectiveKeys {
                let comparison = compareTracks(lhs, rhs, field: key.field)
                if comparison == .orderedSame { continue }
                return key.descending
                    ? comparison == .orderedDescending
                    : comparison == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func compareTracks(_ lhs: Track, _ rhs: Track, field: String) -> ComparisonResult {
        let lhsAudio = lhs.mediaLocator.referencedFile?.locations.first?.audioProperties ?? lhs.audioProperties
        let rhsAudio = rhs.mediaLocator.referencedFile?.locations.first?.audioProperties ?? rhs.audioProperties
        switch field {
        case "title": return lhs.title.localizedStandardCompare(rhs.title)
        case "artist": return lhs.artist.localizedStandardCompare(rhs.artist)
        case "album": return lhs.album.localizedStandardCompare(rhs.album)
        case "availability": return lhs.availability.rawValue.localizedStandardCompare(rhs.availability.rawValue)
        case "codec": return (lhsAudio?.codec ?? "").localizedStandardCompare(rhsAudio?.codec ?? "")
        case "filePath": return trackPath(lhs).localizedStandardCompare(trackPath(rhs))
        case "duration": return lhs.duration == rhs.duration ? .orderedSame : (lhs.duration < rhs.duration ? .orderedAscending : .orderedDescending)
        case "sampleRateHz":
            let left = lhsAudio?.sampleRateHz ?? 0
            let right = rhsAudio?.sampleRateHz ?? 0
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case "addedAt": return lhs.addedAt == rhs.addedAt ? .orderedSame : (lhs.addedAt < rhs.addedAt ? .orderedAscending : .orderedDescending)
        case "releaseDate":
            let left = lhs.releaseDate ?? .distantPast
            let right = rhs.releaseDate ?? .distantPast
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        default: return .orderedSame
        }
    }

    private func trackPath(_ track: Track) -> String {
        track.mediaLocator.referencedFile?.locations.first?.lastKnownPath
            ?? track.originalFilePath
    }

    private func trackLyricsStatus(_ track: Track) -> String {
        if let ttml = track.ttmlLyricText, !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ttml.localizedCaseInsensitiveContains("<span") ? "wordSynced" : "lineSynced"
        }
        if track.ttmlLyricsFileName != nil { return "lineSynced" }
        if let plain = track.lyricsText, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.looksLikeLRC(plain) ? "lineSynced" : "plain"
        }
        if track.lyricsFileName != nil { return "plain" }
        return "none"
    }

    private func makeTrackSummary(
        _ track: Track,
        playlists: [Playlist] = [],
        includeFilePath: Bool = true
    ) -> AutomationTrackSummary {
        let sourceMemberships = (track.mediaLocator.referencedFile?.allSourceMemberships ?? [])
            .map {
                AutomationTrackSourceMembership(
                    sourceID: $0.sourceID,
                    relativePath: $0.relativePath
                )
            }
            .sorted {
                if $0.sourceID != $1.sourceID {
                    return $0.sourceID.uuidString < $1.sourceID.uuidString
                }
                return $0.relativePath < $1.relativePath
            }
        let audio = track.mediaLocator.referencedFile?.locations.first?.audioProperties
            ?? track.audioProperties
        let playlistIDs = playlists.lazy
            .filter { playlist in playlist.tracks.contains { $0.id == track.id } }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        return AutomationTrackSummary(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            availability: track.availability.rawValue,
            addedAt: track.addedAt,
            importedAt: track.importedAt,
            sourceMemberships: sourceMemberships,
            albumArtist: track.albumArtist,
            genreTags: track.genreTags,
            releaseDate: track.releaseDate,
            metadataSource: track.metadataSource,
            metadataConfidence: track.metadataConfidence,
            lyricsStatus: trackLyricsStatus(track),
            artworkAvailable: track.artworkData != nil || track.artworkFileName != nil,
            format: audio?.format,
            codec: audio?.codec,
            sampleRateHz: audio?.sampleRateHz,
            bitDepth: audio?.bitDepth,
            channelCount: audio?.channelCount,
            filePath: includeFilePath ? trackPath(track) : nil,
            playlistIDs: playlistIDs
        )
    }

    private func makePlaylistSummary(_ playlist: Playlist) -> AutomationPlaylistSummary {
        AutomationPlaylistSummary(
            id: playlist.id,
            name: playlist.name,
            description: playlist.userDescription,
            createdAt: playlist.createdAt,
            trackCount: playlist.trackCount,
            totalDuration: playlist.totalDuration,
            revision: appSession?.libraryVM?.automationPlaylistRevision(for: playlist) ?? "v1-0"
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

    private struct AutomationFilePlan {
        let track: Track
        let trackID: UUID
        let from: URL
        let destination: URL?
        let sourceIDs: Set<UUID>
    }

    private func makeFileSummary(
        _ track: Track,
        pathOverride: String? = nil,
        existsOverride: Bool? = nil
    ) -> AutomationFileSummary {
        let locator = track.mediaLocator.referencedFile
        let memberships = locator?.allSourceMemberships ?? []
        let path = pathOverride ?? trackPath(track)
        return AutomationFileSummary(
            trackID: track.id,
            path: path,
            exists: existsOverride ?? FileManager.default.fileExists(atPath: path),
            availability: track.availability.rawValue,
            sourceIDs: memberships.map(\.sourceID),
            relativePaths: memberships.map(\.relativePath)
        )
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
            let current = try currentAuthorizedFile(for: track, session: session)
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
                let root = try authorizedDirectoryRoot(sourceID: sourceID, sourceScope: sourceScope)
                guard TrackMediaLocator.isSafeRelativePath(relativePath) else {
                    throw AutomationFileOperationError.unsafeRelativePath(relativePath)
                }
                destination = root.appendingPathComponent(relativePath).standardizedFileURL
                guard isAuthorizedPath(destination, inside: root) else {
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
        let tracks = try automationTracks(ids: trackIDs, in: session.libraryViewModel.allTracks)
        return try tracks.map { track in
            let current = try currentAuthorizedFile(for: track, session: session)
            return AutomationFilePlan(
                track: track,
                trackID: track.id,
                from: current.url,
                destination: nil,
                sourceIDs: current.sourceIDs
            )
        }
    }

    private func currentAuthorizedFile(
        for track: Track,
        session: LibrarySession
    ) throws -> (url: URL, sourceIDs: Set<UUID>) {
        guard case let .referenced(locator) = track.mediaLocator else {
            throw AutomationFileOperationError.referencedFileRequired(track.id)
        }
        guard let sourceScope = session.referencedSourceScope else {
            throw AutomationFileOperationError.referencedLibraryRequired
        }
        let sourceIDs = Set(locator.allSourceMemberships.map(\.sourceID))
        for location in locator.locations {
            for membership in location.sourceMemberships {
                guard let authorizedRoot = sourceScope.authorizedRoots[membership.sourceID],
                      isDirectoryRoot(authorizedRoot.url),
                      TrackMediaLocator.isSafeRelativePath(membership.relativePath) else {
                    continue
                }
                let candidate = authorizedRoot.url
                    .appendingPathComponent(membership.relativePath)
                    .standardizedFileURL
                guard isAuthorizedPath(candidate, inside: authorizedRoot.url),
                      FileManager.default.fileExists(atPath: candidate.path),
                      !isDirectoryRoot(candidate) else {
                    continue
                }
                return (candidate, sourceIDs)
            }
        }
        if sourceIDs.isEmpty {
            throw AutomationFileOperationError.noSourceMembership(track.id)
        }
        throw AutomationFileOperationError.fileUnavailable(track.id)
    }

    private func authorizedDirectoryRoot(
        sourceID: UUID,
        sourceScope: ReferencedSourceScope
    ) throws -> URL {
        guard let root = sourceScope.authorizedRoots[sourceID]?.url else {
            throw AutomationFileOperationError.sourceNotAuthorized(sourceID)
        }
        guard isDirectoryRoot(root) else {
            throw AutomationFileOperationError.sourceMustBeDirectory(sourceID)
        }
        return root.standardizedFileURL
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

    private func isDirectoryRoot(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if let isDirectory = values?.isDirectory {
            return isDirectory
        }
        return url.hasDirectoryPath
    }

    private func isAuthorizedPath(_ candidate: URL, inside root: URL) -> Bool {
        let standardizedCandidate = candidate.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard standardizedCandidate.path == standardizedRoot.path
            || standardizedCandidate.path.hasPrefix(standardizedRoot.path + "/") else {
            return false
        }

        // The lexical check above blocks traversal. Resolve the nearest
        // existing ancestor as well so a symlinked directory cannot redirect
        // a newly-created destination outside the authorized Source.
        var existingAncestor = standardizedCandidate
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != existingAncestor.deletingLastPathComponent().path {
            existingAncestor.deleteLastPathComponent()
        }
        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL.path
        return canonicalAncestor == canonicalRoot
            || canonicalAncestor.hasPrefix(canonicalRoot + "/")
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
            .map(makeJobSummary)
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

    private func invalidParameters(
        for request: AutomationRequest,
        error: Error? = nil
    ) -> AutomationResponse {
        if let error = error as? LibraryOperationError,
           error == .sessionQuiescing {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .conflict,
                    message: "The active library is changing; retry after the operation completes.",
                    retryable: true
                )
            )
        }
        guard error == nil
            || error is AutomationParameterError
            || error is AutomationFileOperationError else {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .internalError,
                    message: "The automation operation failed.",
                    details: .object(["reason": .string(String(describing: error!))])
                )
            )
        }
        return .failure(
            for: request,
            error: AutomationError(
                code: .invalidRequest,
                message: error?.localizedDescription ?? "The request parameters are invalid."
            )
        )
    }

    private func encodeResult<Value: Encodable>(
        _ value: Value,
        for request: AutomationRequest
    ) -> AutomationResponse {
        do {
            let data = try AutomationWireCoding.encoder().encode(value)
            let json = try AutomationWireCoding.decoder().decode(
                AutomationJSONValue.self,
                from: data
            )
            return .success(for: request, result: json)
        } catch {
            return .failure(
                for: request,
                error: AutomationError(
                    code: .internalError,
                    message: "Failed to encode automation response.",
                    details: .object(["reason": .string(String(describing: error))])
                )
            )
        }
    }
}

private struct AutomationParameters {
    let values: [String: AutomationJSONValue]

    init(_ request: AutomationRequest) throws {
        switch request.params {
        case nil, .some(.null):
            values = [:]
        case .some(.object(let values)):
            self.values = values
        default:
            throw AutomationParameterError.invalidShape
        }
    }

    func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = values[key] else {
            if required {
                throw AutomationParameterError.missing(key)
            }
            return nil
        }
        guard case .string(let string) = value else {
            throw AutomationParameterError.invalidType(key, expected: "string")
        }
        return string
    }

    func uuid(_ key: String, required: Bool = false) throws -> UUID? {
        guard let string = try string(key, required: required) else {
            return nil
        }
        guard let uuid = UUID(uuidString: string) else {
            throw AutomationParameterError.invalidValue(key)
        }
        return uuid
    }

    func uuidArray(
        _ key: String,
        required: Bool = false,
        allowEmpty: Bool = false
    ) throws -> [UUID] {
        guard let value = values[key] else {
            if required {
                throw AutomationParameterError.missing(key)
            }
            return []
        }
        guard case .array(let values) = value else {
            throw AutomationParameterError.invalidType(key, expected: "array of UUID strings")
        }
        guard (allowEmpty || !values.isEmpty), values.count <= 5_000 else {
            throw AutomationParameterError.outOfRange(key)
        }

        var result: [UUID] = []
        var seen = Set<UUID>()
        for value in values {
            guard case .string(let string) = value,
                  let uuid = UUID(uuidString: string) else {
                throw AutomationParameterError.invalidValue(key)
            }
            if seen.insert(uuid).inserted {
                result.append(uuid)
            }
        }
        return result
    }

    func integer(_ key: String, default defaultValue: Int) throws -> Int {
        guard let value = values[key] else {
            return defaultValue
        }
        guard case .number(let number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw AutomationParameterError.invalidType(key, expected: "integer")
        }
        return Int(number)
    }

    func boolean(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = values[key] else {
            return defaultValue
        }
        guard case .boolean(let boolean) = value else {
            throw AutomationParameterError.invalidType(key, expected: "boolean")
        }
        return boolean
    }

    func double(_ key: String, default defaultValue: Double? = nil) throws -> Double? {
        guard let value = values[key] else { return defaultValue }
        guard case .number(let number) = value, number.isFinite else {
            throw AutomationParameterError.invalidType(key, expected: "number")
        }
        return number
    }

    func object(_ key: String) throws -> [String: AutomationJSONValue]? {
        guard let value = values[key] else { return nil }
        guard case .object(let object) = value else {
            throw AutomationParameterError.invalidType(key, expected: "object")
        }
        return object
    }

    func objectArray(
        _ key: String,
        required: Bool = false
    ) throws -> [[String: AutomationJSONValue]] {
        guard let value = values[key] else {
            if required { throw AutomationParameterError.missing(key) }
            return []
        }
        guard case .array(let array) = value else {
            throw AutomationParameterError.invalidType(key, expected: "array of objects")
        }
        guard !array.isEmpty, array.count <= 5_000 else {
            throw AutomationParameterError.outOfRange(key)
        }
        return try array.map { value in
            guard case .object(let object) = value else {
                throw AutomationParameterError.invalidType(key, expected: "array of objects")
            }
            return object
        }
    }

    func array(_ key: String) throws -> [AutomationJSONValue] {
        guard let value = values[key] else { return [] }
        guard case .array(let array) = value else {
            throw AutomationParameterError.invalidType(key, expected: "array")
        }
        return array
    }

    func date(_ key: String) throws -> Date? {
        guard let string = try string(key) else { return nil }
        guard let date = ISO8601DateFormatter().date(from: string) else {
            throw AutomationParameterError.invalidValue(key)
        }
        return date
    }
}

private enum AutomationParameterError: Error, LocalizedError {
    case invalidShape
    case missing(String)
    case missingResource(String)
    case invalidType(String, expected: String)
    case invalidValue(String)
    case outOfRange(String)

    var errorDescription: String? {
        switch self {
        case .invalidShape:
            return "Request parameters must be a JSON object."
        case .missing(let key):
            return "Missing required parameter '\(key)'."
        case .missingResource(let key):
            return "The requested \(key) does not exist."
        case .invalidType(let key, let expected):
            return "Parameter '\(key)' must be \(expected)."
        case .invalidValue(let key):
            return "Parameter '\(key)' has an invalid value."
        case .outOfRange(let key):
            return "Parameter '\(key)' is outside the supported range."
        }
    }
}

private enum AutomationFileOperationError: Error, LocalizedError {
    case referencedLibraryRequired
    case referencedFileRequired(UUID)
    case trackNotFound(UUID)
    case noSourceMembership(UUID)
    case fileUnavailable(UUID)
    case sourceNotAuthorized(UUID)
    case sourceMustBeDirectory(UUID)
    case unsafeRelativePath(String)
    case invalidFileName
    case destinationIsCurrentFile(String)
    case destinationExists(String)
    case duplicateDestination
    case destinationOverlapsSelection
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .referencedLibraryRequired:
            return "Physical file automation currently requires a referenced music library."
        case .referencedFileRequired(let trackID):
            return "Track \(trackID.uuidString) does not point to a referenced external file."
        case .trackNotFound(let trackID):
            return "Track \(trackID.uuidString) was not found in the active Library."
        case .noSourceMembership(let trackID):
            return "Track \(trackID.uuidString) has no authorized Source membership."
        case .fileUnavailable(let trackID):
            return "The current physical file for Track \(trackID.uuidString) is missing or unavailable."
        case .sourceNotAuthorized(let sourceID):
            return "Source \(sourceID.uuidString) is not currently authorized by the App."
        case .sourceMustBeDirectory(let sourceID):
            return "Source \(sourceID.uuidString) is a single-file Source; choose an authorized directory Source for this operation."
        case .unsafeRelativePath(let path):
            return "The destination path is not a safe Source-relative path: \(path)"
        case .invalidFileName:
            return "The new file name must be a single non-empty path component."
        case .destinationIsCurrentFile(let path):
            return "The destination is already the current file: \(path)"
        case .destinationExists(let path):
            return "The destination file already exists: \(path)"
        case .duplicateDestination:
            return "Multiple file operations resolve to the same destination."
        case .destinationOverlapsSelection:
            return "A file operation would overwrite another selected file; no mutation was applied."
        case .operationFailed(let reason):
            return "The physical file operation failed: \(reason)"
        }
    }
}

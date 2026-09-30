import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PlayerAutomationIPC
import PlayerAutomationProtocol
import UniformTypeIdentifiers

private nonisolated enum AutomationAppIdentity {
    static var bundleIdentifier: String {
        for executablePath in executablePaths {
            if let bundleIdentifier = bundleIdentifier(atExecutablePath: executablePath) {
                return bundleIdentifier
            }
        }
        return Bundle.main.bundleIdentifier ?? "kmgccc.player"
    }

    private static var executablePaths: [String] {
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(getpid(), buffer.baseAddress, UInt32(buffer.count))
        }
        if length > 0 {
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            paths.append(String(decoding: bytes, as: UTF8.self))
        }
        if let argument = ProcessInfo.processInfo.arguments.first,
           !argument.isEmpty {
            paths.append(argument)
        }
        return paths
    }

    private static func bundleIdentifier(atExecutablePath executablePath: String) -> String? {
        let infoURL = URL(fileURLWithPath: executablePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let bundleIdentifier = propertyList["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty
        else {
            return nil
        }
        return bundleIdentifier
    }
}

private struct AutomationScopePolicyFile: Codable {
    var schemaVersion = 2
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

/// The scope file is deliberately small and App-owned. It is not a second
/// authentication mechanism: the AF_UNIX peer/secret check still gates the
/// process, while this store decides which catalog capabilities the caller may
/// invoke. Dangerous scopes are denied by default until a foreground App
/// confirmation grants them.
private final class AutomationScopePolicyStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier
    ) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("scopes.json", isDirectory: false)
    }

    var defaultGrantedScopes: Set<AutomationScope> {
        Set(AutomationScope.allCases).subtracting([.filesDelete, .storageWrite, .libraryDelete])
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
              payload.schemaVersion == 1 || payload.schemaVersion == 2 else {
            return readOnlyGrantedScopes
        }
        var scopes = Set(payload.grantedScopes.compactMap(AutomationScope.init(rawValue:)))
        // Schema 1 predates the explicit lifecycle scope. It was not possible
        // to deny library lifecycle separately in that schema, so migrate the
        // new non-destructive management scope while keeping the new delete
        // scope denied by default.
        if payload.schemaVersion == 1 {
            scopes.insert(.libraryManage)
        }
        return scopes
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

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier
    ) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        fileURL = appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
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

    private let listener: AutomationIPCListener
    private weak var appSession: AppSessionHost?
    private let scopePolicyStore: AutomationScopePolicyStore
    private let idempotencyStore: AutomationIdempotencyStore
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
        let bundleIdentifier = AutomationAppIdentity.bundleIdentifier
        scopePolicyStore = AutomationScopePolicyStore(bundleIdentifier: bundleIdentifier)
        idempotencyStore = AutomationIdempotencyStore(bundleIdentifier: bundleIdentifier)
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
            .appendingPathComponent(
                AutomationAppIdentity.bundleIdentifier,
                isDirectory: true
            )
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

        let unknownParameterKeys = AutomationToolCatalog.unknownParameterKeys(
            for: request.method,
            params: request.params
        )
        if !unknownParameterKeys.isEmpty {
            return invalidParameters(
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
            if request.method == AutomationMethod.metadataPatch,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.metadataWrite)
            }
            if request.method == AutomationMethod.artworkApply,
               case .object(let values) = request.params,
               case .boolean(true) = values["dryRun"] {
                required.remove(.artworkWrite)
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
            let summaries = registry.libraries.map {
                makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
            }
            return encodeResult(
                AutomationLibraryListResult(
                    libraries: summaries,
                    activeLibraryID: registry.activeLibraryID
                ),
                for: request
            )

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
                    return encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryCreate,
                            applied: false,
                            dryRun: true,
                            path: requestedParentPath.map(expandPath(_:)),
                            message: "Preview only. The App will ask for a parent folder, create the library root without overwriting unknown files, and activate the new library after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "创建资料库会切换当前资料库，需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryCreate),
                            "mode": .string(mode.rawValue),
                            "displayName": .string(displayName)
                        ])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "创建并切换资料库？",
                    message: "要创建“\(displayName)”资料库并切换到它吗？当前播放会话将随之切换。"
                ) else {
                    return interactionCancelled(for: request)
                }
                guard let selectedURL = await requestLibraryDirectory(
                    requestedPath: requestedParentPath.map(expandPath(_:)),
                    title: "选择资料库位置",
                    prompt: "选择",
                    allowsCreatingDirectories: true
                ) else {
                    return interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return libraryPermissionDenied(for: request, path: path)
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
                        makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
                    }
                    return encodeResult(
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
                        makeLibrarySummary($0, activeLibraryID: registry.activeLibraryID)
                    }
                    return encodeResult(
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
                return libraryLifecycleFailure(for: request, error: error)
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
                    return encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryOpen,
                            applied: false,
                            dryRun: true,
                            path: requestedPath.map(expandPath(_:)),
                            message: "Preview only. The App will ask for the existing library folder, register it if needed, and activate it after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "打开资料库会切换当前资料库，需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["operation": .string(AutomationMethod.libraryOpen)])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "打开并切换资料库？",
                    message: "要打开所选资料库并切换到它吗？当前播放会话将随之切换。"
                ) else {
                    return interactionCancelled(for: request)
                }
                guard let selectedURL = await requestLibraryDirectory(
                    requestedPath: requestedPath.map(expandPath(_:)),
                    title: "选择现有资料库",
                    prompt: "打开",
                    allowsCreatingDirectories: false
                ) else {
                    return interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return libraryPermissionDenied(for: request, path: path)
                }
                defer { selection.release() }
                let unavailableSourceIDs = try await appSession.openMusicLibrary(at: selectedURL)
                let registry = await appSession.musicLibraryRegistrySnapshot()
                let activeID = registry.activeLibraryID
                let active = activeID.flatMap(registry.library(id:))
                return encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryOpen,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: activeID,
                        library: active.map { makeLibrarySummary($0, activeLibraryID: activeID) },
                        activeLibraryID: activeID,
                        path: active?.lastKnownPath,
                        unavailableSourceIDs: unavailableSourceIDs,
                        message: "Library opened and activated."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
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
                let targetSummary = makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return encodeResult(
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
                    return confirmationRequired(
                        for: request,
                        message: "切换当前资料库需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.librarySwitch),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard libraryID != registry.activeLibraryID else {
                    return encodeResult(
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
                guard await confirmDestructiveOperation(
                    title: "切换当前资料库？",
                    message: "要切换到“\(target.displayName)”吗？当前播放会话将关闭并重新打开所选资料库。"
                ) else {
                    return interactionCancelled(for: request)
                }
                let unavailableSourceIDs = try await appSession.activateRegisteredLibrary(id: libraryID)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let updatedActiveID = updatedRegistry.activeLibraryID
                let active = updatedActiveID.flatMap(updatedRegistry.library(id:))
                return encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.librarySwitch,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: active.map { makeLibrarySummary($0, activeLibraryID: updatedActiveID) },
                        activeLibraryID: updatedActiveID,
                        path: active?.lastKnownPath,
                        unavailableSourceIDs: unavailableSourceIDs,
                        message: "Library switched and activated."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
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
                let targetSummary = makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return encodeResult(
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
                return encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRename,
                        applied: true,
                        dryRun: false,
                        libraryID: libraryID,
                        library: updated.map { makeLibrarySummary($0, activeLibraryID: updatedRegistry.activeLibraryID) },
                        activeLibraryID: updatedRegistry.activeLibraryID,
                        path: updated?.lastKnownPath ?? target.lastKnownPath,
                        message: "Library renamed."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
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
                let targetSummary = makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return encodeResult(
                        AutomationLibraryLifecycleResult(
                            operation: AutomationMethod.libraryRelocate,
                            applied: false,
                            dryRun: true,
                            libraryID: libraryID,
                            library: targetSummary,
                            activeLibraryID: registry.activeLibraryID,
                            path: requestedParentPath.map(expandPath(_:)),
                            message: "Preview only. The App will ask for a destination parent folder and move the complete library through its recovery transaction after confirm=true."
                        ),
                        for: request
                    )
                }
                guard confirm else {
                    return confirmationRequired(
                        for: request,
                        message: "迁移资料库会改变磁盘上的文件位置，需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryRelocate),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "迁移资料库？",
                    message: "要将“\(target.displayName)”移动到新位置吗？移动后当前播放会话将重新打开。"
                ) else {
                    return interactionCancelled(for: request)
                }
                guard let selectedURL = await requestLibraryDirectory(
                    requestedPath: requestedParentPath.map(expandPath(_:)),
                    title: "选择新的资料库位置",
                    prompt: "移到这里",
                    allowsCreatingDirectories: true
                ) else {
                    return interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess else {
                    let path = selectedURL.path
                    selection.release()
                    return libraryPermissionDenied(for: request, path: path)
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
                return encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRelocate,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: updated.map { makeLibrarySummary($0, activeLibraryID: updatedRegistry.activeLibraryID) },
                        activeLibraryID: updatedRegistry.activeLibraryID,
                        path: newContext.rootURL.path,
                        message: message
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
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
                let targetSummary = makeLibrarySummary(target, activeLibraryID: registry.activeLibraryID)
                if dryRun {
                    return encodeResult(
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
                    return confirmationRequired(
                        for: request,
                        message: "将资料库移到 macOS 废纸篓需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "operation": .string(AutomationMethod.libraryRemove),
                            "libraryID": .string(libraryID.uuidString)
                        ])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "将资料库移到废纸篓？",
                    message: "要将“\(target.displayName)”及其资料库数据移到 macOS 废纸篓吗？其他资料库会保留，并继续使用可用的资料库。"
                ) else {
                    return interactionCancelled(for: request)
                }
                _ = try await appSession.removeMusicLibrary(id: libraryID)
                let updatedRegistry = await appSession.musicLibraryRegistrySnapshot()
                let activeID = updatedRegistry.activeLibraryID
                let active = activeID.flatMap(updatedRegistry.library(id:))
                return encodeResult(
                    AutomationLibraryLifecycleResult(
                        operation: AutomationMethod.libraryRemove,
                        applied: true,
                        dryRun: false,
                        confirmed: true,
                        libraryID: libraryID,
                        library: active.map { makeLibrarySummary($0, activeLibraryID: activeID) },
                        activeLibraryID: activeID,
                        path: target.lastKnownPath,
                        message: "Library moved to the macOS Trash; the App selected the next active library."
                    ),
                    for: request
                )
            } catch {
                return libraryLifecycleFailure(for: request, error: error)
            }

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
                let expectedRevision = try parameters.string("expectedRevision")
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

                let revision = libraryTracksRevision(
                    tracks: allTracks,
                    playlists: viewModel.playlists
                )
                if let expectedRevision, expectedRevision != revision {
                    return libraryTracksRevisionConflict(
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
                        nextOffset: pageEnd < orderedTracks.count ? pageEnd : nil,
                        revision: revision
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
                        message: "删除播放列表需要 confirm=true，并由播放器在前台确认。",
                        details: .object([
                            "playlistID": .string(playlistID.uuidString),
                            "trackCount": .number(Double(summary.trackCount))
                        ])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "删除播放列表？",
                    message: "要删除“\(summary.name)”及其 \(summary.trackCount) 条歌曲关系吗？歌曲和音频文件会保留。"
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
                    selectedURL = try await requestSourceURL(
                        mode: mode,
                        requestedPath: normalizedRequestedPath
                    )
                }
                guard let selectedURL else {
                    return interactionCancelled(for: request)
                }
                let selection = LibraryInitialImportSelection(urls: [selectedURL])
                guard selection.hasUsableAccess || inheritedAuthorization else {
                    let path = selectedURL.path
                    selection.release()
                    return permissionDenied(
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
                let isTrusted = session.referencedSourceScope?.isTrustedAutomationPath(
                    URL(fileURLWithPath: descriptor.lastKnownPath)
                ) == true
                if !isTrusted {
                    guard confirm else {
                        return confirmationRequired(
                            for: request,
                            message: "移除来源需要 confirm=true，并由播放器在前台确认。",
                            details: .object(["sourceID": .string(sourceID.uuidString)])
                        )
                    }
                    guard await confirmDestructiveOperation(
                        title: "移除来源？",
                        message: "要从当前资料库移除“\(descriptor.displayName)”吗？原文件不会删除，相关歌曲可能暂时不可用。"
                    ) else {
                        return interactionCancelled(for: request)
                    }
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

                let isTrusted = plans.allSatisfy { plan in
                    guard let sourceScope = session.referencedSourceScope else { return false }
                    return sourceScope.isTrustedAutomationPath(plan.from)
                        && (plan.destination.map { sourceScope.isTrustedAutomationPath($0) } ?? true)
                }
                if plans.count > 1 && !isTrusted {
                    guard confirm else {
                        return confirmationRequired(
                            for: request,
                            message: "批量重命名或移动文件需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(request.method),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await confirmDestructiveOperation(
                        title: request.method == AutomationMethod.filesRename
                            ? "重命名多个音乐文件？"
                            : "移动多个音乐文件？",
                        message: "这会改变 \(plans.count) 个音乐文件在磁盘上的位置，播放器随后会重新扫描相关来源。"
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
                        confirmed: plans.count > 1 && (confirm || isTrusted),
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
                let isTrusted = plans.allSatisfy { plan in
                    session.referencedSourceScope?.isTrustedAutomationPath(plan.from) == true
                }
                if !isTrusted {
                    guard confirm else {
                        return confirmationRequired(
                            for: request,
                            message: "将音乐文件移到废纸篓需要 confirm=true，并由播放器在前台确认。",
                            details: .object([
                                "operation": .string(AutomationMethod.filesDelete),
                                "fileCount": .number(Double(plans.count))
                            ])
                        )
                    }
                    guard await confirmDestructiveOperation(
                        title: "将音乐文件移到废纸篓？",
                        message: "要将 \(plans.count) 个音乐文件移到 macOS 废纸篓吗？歌曲、元数据、播放记录和播放列表关系会保留。"
                    ) else {
                        return interactionCancelled(for: request)
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
                if let from, let to, from > to {
                    throw AutomationParameterError.invalidValue("from/to")
                }
                let items: [PlaybackHistoryItem]
                if from != nil || to != nil {
                    items = session.playbackHistoryStore.fetchItems(
                        from: from ?? .distantPast,
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
                        message: "清除播放记录需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["recordCount": .number(Double(count))])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "清除播放记录？",
                    message: "要删除 \(count) 条播放记录吗？此操作无法在播放器中撤销。"
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

        case AutomationMethod.artworkSearch:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                return encodeResult(
                    AutomationArtworkSearchResult(
                        targetType: target.type,
                        trackID: trackID,
                        artistID: artistID,
                        albumKey: albumKey,
                        queryTitle: queryTitle,
                        queryArtist: queryArtist,
                        queryAlbum: queryAlbum,
                        candidates: candidates.map(makeArtworkCandidate),
                        message: candidates.isEmpty
                            ? "No artwork candidates were returned by the configured providers."
                            : "Artwork candidates were searched and ranked by the existing App provider pipeline. Inline imageBase64 is provided for Agent review."
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    revision = libraryTracksRevision(
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
                return encodeResult(
                    AutomationArtworkGetResult(
                        artworks: artworks,
                        revision: revision
                    ),
                    for: request
                )
            } catch {
                return invalidParameters(for: request, error: error)
            }

        case AutomationMethod.artworkApply:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                        return confirmationRequired(
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
                    return encodeResult(
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

                if trackIDs.count >= 10 {
                    guard await confirmDestructiveOperation(
                        title: "应用到 \(trackIDs.count) 首歌曲？",
                        message: clear
                            ? "要清除这 \(trackIDs.count) 首歌曲的封面吗？原音频文件不会修改。"
                            : "要将所选封面应用到这 \(trackIDs.count) 首歌曲吗？原音频文件不会修改。"
                    ) else {
                        return interactionCancelled(for: request)
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
                           let data = try? Data(contentsOf: URL(fileURLWithPath: expandPath(imagePath))),
                           data.count <= 16 * 1024 * 1024,
                           ArtworkDataNormalizer.isDecodableImage(data) {
                    resolvedInput = ("imagePath", ArtworkDataNormalizer.normalizedJPEGData(from: data) ?? data)
                } else {
                    guard let selectedURL = try await requestArtworkURL(
                        requestedPath: imagePath.map(expandPath(_:))
                    ) else {
                        return interactionCancelled(for: request)
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
                return encodeResult(
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
                return mutationFailure(for: request, error: error)
            }

        case AutomationMethod.metadataGet:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
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
                    return encodeResult(
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
                    return encodeResult(
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
                        limit: tracks.count,
                        revision: libraryTracksRevision(
                            tracks: session.libraryViewModel.allTracks,
                            playlists: session.libraryViewModel.playlists
                        )
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
                if trackIDs.count >= 10 {
                    guard confirm else {
                        return confirmationRequired(
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
                    guard await confirmDestructiveOperation(
                        title: "修改 \(trackIDs.count) 首歌曲的信息？",
                        message: "要将这些歌曲的信息更新到播放器资料库吗？原音频文件和内嵌标签不会修改。"
                    ) else {
                        return interactionCancelled(for: request)
                    }
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
                let currentQuality = currentLyricsQuality(track)
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
                        input: "candidate",
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

        case AutomationMethod.lyricsClean:
            guard let session = activeSession(for: request) else {
                return noActiveLibraryResponse(for: request)
            }
            do {
                let parameters = try AutomationParameters(request)
                let trackID = try parameters.uuid("trackID", required: true)!
                let dryRun = try parameters.boolean("dryRun", default: false)
                guard let track = session.libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
                    throw AutomationParameterError.missingResource("trackID")
                }
                guard let ttml = resolveTTMLText(for: track),
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
                    return encodeResult(
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
                    return encodeResult(
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
                    return encodeResult(
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
            guard activeSession(for: request) != nil else {
                return noActiveLibraryResponse(for: request)
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
            guard activeSession(for: request) != nil else {
                return noActiveLibraryResponse(for: request)
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
            guard activeSession(for: request) != nil else {
                return noActiveLibraryResponse(for: request)
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
            guard activeSession(for: request) != nil else {
                return noActiveLibraryResponse(for: request)
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
                            message: "启用“同时处理原文件”会改变以后删除引用歌曲的方式，需要播放器确认。",
                            details: .object([
                                "setting": .string("referencedTrackDeletePolicy"),
                                "value": .string(ReferencedTrackDeletePolicy.recycleSource.rawValue)
                            ])
                        )
                    }
                    guard await confirmDestructiveOperation(
                        title: "更改引用歌曲的删除方式？",
                        message: "以后删除引用歌曲时，来源文件可能会移到废纸篓。"
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
                        "Library lifecycle management is available through App-owned create/open/switch/rename/relocate operations; library deletion remains separately denied by default.",
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
                        message: "授予自动化权限需要 confirm=true，并由播放器在前台确认。",
                        details: .object(["scope": .string(scope.rawValue)])
                    )
                }
                guard await confirmDestructiveOperation(
                    title: "授予自动化权限？",
                    message: "要允许外部自动化使用“\(scope.rawValue)”能力吗？"
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
            let expanded = expandPath(imagePath)
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

        guard let selectedURL = try await requestArtworkURL(
            requestedPath: imagePath.map(expandPath(_:))
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
            return encodeResult(
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
            return interactionCancelled(for: request)
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
                return encodeResult(
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
            return encodeResult(
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
                return encodeResult(
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
            return encodeResult(
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
                return encodeResult(
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
            return encodeResult(
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
                return encodeResult(
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
                return encodeResult(
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
                return encodeResult(
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
            return encodeResult(
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
                tracks: [makeTrackSummary(track, playlists: session.libraryViewModel.playlists)],
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
                playlists: [makePlaylistSummary(playlist)],
                total: 1,
                revision: makePlaylistSummary(playlist).revision
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
            let page = Array(filtered[pageStart..<pageEnd]).map(makePlaylistSummary)
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
        return automationSupportDirectory()
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(libraryID.uuidString, isDirectory: true)
    }

    private nonisolated static func automationSupportDirectory(
        bundleIdentifier: String = AutomationAppIdentity.bundleIdentifier
    ) -> URL {
        let appSupport = FileManager.default.urls(
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
        backupPath: String
    ) throws -> (URL, AutomationStorageBackupManifest) {
        let candidate = URL(fileURLWithPath: backupPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = automationStorageBackupRoot(libraryID: context.id)
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
        let directory = Self.automationSupportDirectory()
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
             AutomationMethod.librarySwitch,
             AutomationMethod.libraryRename,
             AutomationMethod.libraryRelocate,
             AutomationMethod.libraryRemove: return "library"
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
             AutomationMethod.metadataPatch: return "metadata"
        case AutomationMethod.artworkSearch,
             AutomationMethod.artworkGet,
             AutomationMethod.artworkApply: return "artwork"
        case AutomationMethod.lyricsGet,
             AutomationMethod.lyricsSearch,
             AutomationMethod.lyricsCandidates,
             AutomationMethod.lyricsCompare,
             AutomationMethod.lyricsApply,
             AutomationMethod.lyricsClean,
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
        for key in ["trackIDs", "playlistIDs", "sourceIDs", "libraryIDs", "paths"] {
            if case .array(let items) = values[key] {
                return items.count
            }
        }
        return values["trackID"] != nil
            || values["playlistID"] != nil
            || values["sourceID"] != nil
            || values["libraryID"] != nil
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

    private func makeArtworkCandidate(
        _ candidate: CoverCandidate
    ) -> AutomationArtworkCandidate {
        let inlineData = inlineArtworkData(candidate.imageData)
        return AutomationArtworkCandidate(
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

    private func resolveTTMLText(for track: Track) -> String? {
        if let text = track.ttmlLyricText, !text.isEmpty {
            return text
        }
        if let text = track.loadTTMLLyricsIfNeeded(), !text.isEmpty {
            return text
        }
        if let fileName = track.ttmlLyricsFileName,
           let paths = appSession?.activeLibraryBinding.activeSession?.context.paths,
           let url = paths.trackAssetURL(for: track.id, fileName: fileName),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            track.ttmlLyricText = text
            return text
        }
        return nil
    }

    private func resolvePlainLyricsText(for track: Track) -> String? {
        if let text = track.lyricsText, !text.isEmpty {
            return text
        }
        if let text = track.loadLyricsIfNeeded(), !text.isEmpty {
            return text
        }
        if let fileName = track.lyricsFileName,
           let paths = appSession?.activeLibraryBinding.activeSession?.context.paths,
           let url = paths.trackAssetURL(for: track.id, fileName: fileName),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            track.lyricsText = text
            return text
        }
        return nil
    }

    private func currentLyricsQuality(_ track: Track) -> Int {
        if let ttml = resolveTTMLText(for: track),
           !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.isWordSyncedTTML(ttml) ? 2 : 1
        }
        if track.ttmlLyricsFileName != nil { return 1 }
        if let plain = resolvePlainLyricsText(for: track),
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

    /// The picker is owned by the App. A raw path is accepted without another
    /// panel only when an existing Source root or the user-selected trusted
    /// audio root already covers it.
    private func requestSourceURL(
        mode: ReferencedSourceMode,
        requestedPath: String?
    ) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = mode == .directory
        panel.canChooseFiles = mode == .file
        panel.allowsMultipleSelection = false
        panel.title = mode == .directory ? "选择音乐文件夹" : "选择音乐文件"
        panel.prompt = "添加来源"
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

    /// Artwork input is always authorized by an App-owned open panel. A
    /// caller-provided path is only used to choose the panel's initial folder;
    /// it is never treated as sandbox authorization by itself.
    private func requestArtworkURL(requestedPath: String?) async throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.title = "选择封面"
        panel.prompt = "使用封面"
        if let requestedPath {
            let requestedURL = URL(fileURLWithPath: requestedPath)
            let requestedIsDirectory = (try? requestedURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
            panel.directoryURL = FileManager.default.fileExists(atPath: requestedURL.path)
                && requestedIsDirectory
                ? requestedURL
                : requestedURL.deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    /// Library lifecycle operations use the same App-owned picker boundary as
    /// Source creation. A requested path is only a navigation hint; the
    /// selected URL is still authorized by the App and retained until the
    /// lifecycle transaction has captured its own bookmark.
    private func requestLibraryDirectory(
        requestedPath: String?,
        title: String,
        prompt: String,
        allowsCreatingDirectories: Bool
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = allowsCreatingDirectories
        panel.title = title
        panel.prompt = prompt
        if let requestedPath {
            let requestedURL = URL(fileURLWithPath: requestedPath)
            let requestedIsDirectory = (try? requestedURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
            panel.directoryURL = FileManager.default.fileExists(atPath: requestedURL.path)
                && requestedIsDirectory
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
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
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

    private func permissionDenied(
        for request: AutomationRequest,
        path: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .permissionDenied,
                message: "The selected Source could not be authorized; no import Job was started.",
                retryable: false,
                details: .object([
                    "path": .string(path),
                    "reason": .string("securityScopedAccess")
                ])
            )
        )
    }

    private func libraryPermissionDenied(
        for request: AutomationRequest,
        path: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .permissionDenied,
                message: "The selected library location could not be authorized; no library lifecycle mutation was applied.",
                retryable: false,
                details: .object([
                    "path": .string(path),
                    "reason": .string("securityScopedAccess")
                ])
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
        message: String = "此操作需要 dryRun=false，并提供 confirm=true。",
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
        if error is AutomationParameterError || error is AutomationFileOperationError {
            return invalidParameters(for: request, error: error)
        }
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

    private func libraryLifecycleFailure(
        for request: AutomationRequest,
        error: Error
    ) -> AutomationResponse {
        if error is AutomationParameterError || error is AutomationFileOperationError {
            return invalidParameters(for: request, error: error)
        }

        let reason = String(describing: error)
        func failure(
            _ code: AutomationErrorCode,
            _ message: String,
            retryable: Bool = false
        ) -> AutomationResponse {
            .failure(
                for: request,
                error: AutomationError(
                    code: code,
                    message: message,
                    retryable: retryable,
                    details: .object(["reason": .string(reason)])
                )
            )
        }

        switch error {
        case let error as RegisteredLibraryActivationError:
            switch error {
            case .notRegistered:
                return failure(.invalidRequest, "The requested library is not registered.")
            case .reconnectRequired(let libraryID):
                return .failure(
                    for: request,
                    error: AutomationError(
                        code: .interactionRequired,
                        message: "The registered library is unavailable at its last known path. Call library.open and select its current folder before switching again.",
                        details: .object([
                            "libraryID": .string(libraryID.uuidString),
                            "nextAction": .string(AutomationMethod.libraryOpen),
                            "reason": .string(reason)
                        ])
                    )
                )
            }

        case let error as LibraryCreationError:
            switch error {
            case .invalidDisplayName:
                return failure(.invalidRequest, "The library display name is invalid.")
            case .destinationContainsUnknownItems, .invalidExistingLibrary:
                return failure(.conflict, "The selected library location already contains data that cannot be safely reused.")
            case .stagingFailed, .validationFailed:
                return failure(.internalError, "The new library could not be staged or validated.", retryable: true)
            case .registryCommitFailed, .sessionActivationFailed, .recoveryFailed:
                return failure(.internalError, "The new library could not be activated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryOpenError:
            switch error {
            case .libraryNotFound, .invalidManifest, .libraryNotRegistered,
                 .reconnectIdentifierMismatch, .reconnectModeMismatch:
                return failure(.invalidRequest, "The selected location is not a usable registered music library.")
            case .pathConflict:
                return failure(.conflict, "The selected library path is already registered to another library.")
            case .bookmarkFailed, .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the selected library location.")
            case .transactionInProgress:
                return failure(.conflict, "Another library lifecycle operation is in progress.", retryable: true)
            case .activationFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be activated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryRelocationError:
            switch error {
            case .libraryNotRegistered:
                return failure(.invalidRequest, "The requested library is not registered.")
            case .destinationExists:
                return failure(.conflict, "The destination already contains a library or other data.")
            case .validationFailed:
                return failure(.invalidRequest, "The registered library failed validation and was not moved.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library or destination location.")
            case .transactionInProgress, .pendingRepair, .recoveryConflict:
                return failure(.conflict, "The library has an unfinished lifecycle transaction; repair or retry after the App reports it is ready.", retryable: true)
            case .closeFailed, .copyFailed, .publicationFailed, .newSessionFailed,
                 .registryCommitFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be relocated safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryRemovalError:
            switch error {
            case .libraryNotRegistered, .manifestMismatch:
                return failure(.invalidRequest, "The requested library is not a valid registered library.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library location.")
            case .transactionInProgress, .pendingRepair:
                return failure(.conflict, "The library has an unfinished removal transaction; repair or retry after the App reports it is ready.", retryable: true)
            case .closeFailed, .recycleFailed, .intentWriteFailed, .recoveryFailed:
                return failure(.internalError, "The library could not be moved to the macOS Trash safely; the App preserved its recovery boundary.", retryable: true)
            }

        case let error as LibraryDisplayNameUpdateError:
            switch error {
            case .invalidDisplayName:
                return failure(.invalidRequest, "The library display name is invalid.")
            case .libraryNotRegistered, .manifestMismatch:
                return failure(.invalidRequest, "The requested library is not a valid registered library.")
            case .securityScopeDenied:
                return failure(.permissionDenied, "The App could not authorize the library location.")
            case .transactionInProgress:
                return failure(.conflict, "Another library lifecycle operation is in progress.", retryable: true)
            case .manifestWriteFailed, .registryWriteFailedRolledBack,
                 .registryWriteFailedRollbackFailed:
                return failure(.internalError, "The library name could not be updated safely.", retryable: true)
            }

        default:
            return failure(.internalError, "The library lifecycle operation failed.", retryable: true)
        }
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
        let artworkAvailable = track.hasArtwork

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

    /// Build a deterministic snapshot token from the fields exposed by
    /// `library.tracks`, including the order of the library and Playlist
    /// membership. The token is intentionally opaque so callers can use it
    /// for optimistic pagination without receiving any additional metadata.
    private func libraryTracksRevision(
        tracks: [Track],
        playlists: [Playlist]
    ) -> String {
        var playlistIDsByTrackID: [UUID: Set<UUID>] = [:]
        for playlist in playlists {
            for track in playlist.tracks {
                playlistIDsByTrackID[track.id, default: []].insert(playlist.id)
            }
        }
        let summaries = tracks.map { track in
            makeTrackSummary(
                track,
                playlists: [],
                includeFilePath: false,
                playlistIDsOverride: Array(
                    playlistIDsByTrackID[track.id, default: []]
                ).sorted { $0.uuidString < $1.uuidString }
            )
        }
        guard let data = try? AutomationWireCoding.encoder().encode(summaries) else {
            return "v1-unavailable"
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1-" + digest
    }

    private func libraryTracksRevisionConflict(
        for request: AutomationRequest,
        expected: String,
        actual: String
    ) -> AutomationResponse {
        .failure(
            for: request,
            error: AutomationError(
                code: .conflict,
                message: "The Library changed while the Track results were being paginated.",
                retryable: true,
                details: .object([
                    "expectedRevision": .string(expected),
                    "actualRevision": .string(actual)
                ])
            )
        )
    }

    private func trackLyricsStatus(_ track: Track) -> String {
        if let ttml = resolveTTMLText(for: track), !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.isWordSyncedTTML(ttml) ? "wordSynced" : "lineSynced"
        }
        if track.ttmlLyricsFileName != nil { return "lineSynced" }
        if let plain = resolvePlainLyricsText(for: track), !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.looksLikeLRC(plain) ? "lineSynced" : "plain"
        }
        if let lyricsFileName = track.lyricsFileName {
            return lyricsFileName.lowercased().hasSuffix(".lrc") ? "lineSynced" : "plain"
        }
        return "none"
    }

    private func makeTrackSummary(
        _ track: Track,
        playlists: [Playlist] = [],
        includeFilePath: Bool = true,
        playlistIDsOverride: [UUID]? = nil
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
        let playlistIDs: [UUID]
        if let playlistIDsOverride {
            playlistIDs = playlistIDsOverride.sorted { $0.uuidString < $1.uuidString }
        } else {
            playlistIDs = playlists
                .filter { playlist in playlist.tracks.contains { $0.id == track.id } }
                .map(\.id)
                .sorted { $0.uuidString < $1.uuidString }
        }
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
            artistCredits: track.artistCredits.map {
                AutomationTrackCredit(
                    id: $0.id,
                    displayName: $0.displayName,
                    canonicalName: $0.canonicalName,
                    role: $0.role.rawValue
                )
            },
            albumArtist: track.albumArtist,
            userDescription: track.userDescription,
            genreTags: track.genreTags,
            language: track.language,
            labelOrCompany: track.labelOrCompany,
            releaseDate: track.releaseDate,
            qqMusicSongMid: track.qqMusicSongMid,
            metadataSource: track.metadataSource,
            metadataFetchedAt: track.metadataFetchedAt,
            metadataConfidence: track.metadataConfidence,
            musicBrainzReleaseID: track.musicBrainzReleaseID,
            lyricsTimeOffsetMs: track.lyricsTimeOffsetMs,
            lyricsStatus: trackLyricsStatus(track),
            artworkAvailable: track.hasArtwork,
            artworkFileName: track.artworkFileName,
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
        let service = appSession?.activeLibraryBinding.activeSession?.libraryService
        let sidecar = service?.loadPlaylistSidecar(playlistID: playlist.id)
        let artworkSource = sidecar?.headerArtworkSource ?? .none
        let artworkFileName: String?
        switch artworkSource {
        case .custom:
            artworkFileName = sidecar?.customHeaderArtworkFileName
        case .generated:
            artworkFileName = sidecar?.generatedHeaderArtworkFileName
        case .none:
            artworkFileName = nil
        }
        return AutomationPlaylistSummary(
            id: playlist.id,
            name: playlist.name,
            description: playlist.userDescription,
            createdAt: playlist.createdAt,
            trackCount: playlist.trackCount,
            totalDuration: playlist.totalDuration,
            revision: appSession?.libraryVM?.automationPlaylistRevision(for: playlist) ?? "v1-0",
            artworkAvailable: artworkFileName != nil,
            artworkSource: artworkSource.rawValue,
            artworkFileName: artworkFileName,
            artworkRevision: sidecar?.artworkRevision
        )
    }

    private func makeLibrarySummary(
        _ bookmark: MusicLibraryBookmark,
        activeLibraryID: UUID?
    ) -> AutomationLibrarySummary {
        AutomationLibrarySummary(
            id: bookmark.id,
            displayName: bookmark.displayName,
            mode: bookmark.modeProjection == .managed ? .managed : .referenced,
            isActive: bookmark.id == activeLibraryID
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
                message: error?.localizedDescription ?? "The request parameters are invalid.",
                details: error.flatMap { error in
                    guard case let AutomationParameterError.unknown(keys) = error else {
                        return nil
                    }
                    return .object([
                        "unknownParameters": .array(keys.map { .string($0) })
                    ])
                }
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
            let unknown = AutomationToolCatalog.unknownParameterKeys(
                for: request.method,
                params: .object(values)
            )
            guard unknown.isEmpty else {
                throw AutomationParameterError.unknown(unknown)
            }
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
    case unknown([String])
    case missing(String)
    case missingResource(String)
    case invalidType(String, expected: String)
    case invalidValue(String)
    case outOfRange(String)

    var errorDescription: String? {
        switch self {
        case .invalidShape:
            return "Request parameters must be a JSON object."
        case .unknown(let keys):
            return "Unknown parameter(s): " + keys.joined(separator: ", ") + "."
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

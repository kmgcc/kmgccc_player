import Foundation

nonisolated struct LibraryOpenInspection: Sendable, Equatable {
    let context: LibraryContext
    let descriptor: MusicLibraryBookmark
    let previousDescriptor: MusicLibraryBookmark?
    /// A stale registry row that still claims the selected path. Opening may
    /// replace this row in the index, but never removes the physical root.
    let stalePathConflictLibraryID: UUID?
}

nonisolated struct LibraryOpenResult: Sendable, Equatable {
    let context: LibraryContext
    let didRegister: Bool
    let didRefreshBookmark: Bool
}

nonisolated enum LibraryOpenError: Error, Equatable {
    case libraryNotFound
    case invalidManifest
    case pathConflict
    case bookmarkFailed
    case activationFailed
    case registryCommitFailed
    case recoveryFailed
    case transactionInProgress
    case securityScopeDenied
    case libraryNotRegistered
    case libraryChanged
    case reconnectIdentifierMismatch(expected: UUID, actual: UUID)
    case reconnectModeMismatch(expected: MusicLibraryMode, actual: MusicLibraryMode)
}

nonisolated enum LibraryOpenFailure {
    static func message(for error: any Error) -> String {
        if let error = error as? LibraryOpenError {
            switch error {
            case .libraryNotFound:
                return "所选位置没有资料库。"
            case .invalidManifest:
                return "资料库文件无法读取或格式不兼容。"
            case .pathConflict:
                return "所选位置与已登记的资料库冲突。"
            case .bookmarkFailed, .securityScopeDenied:
                return "无法访问资料库，请重新选择文件夹授权。"
            case .activationFailed:
                return "资料库加载失败，请重试。"
            case .registryCommitFailed:
                return "无法保存资料库列表，请检查磁盘空间和访问权限。"
            case .recoveryFailed:
                return "资料库切换失败，原资料库恢复失败，请重新打开。"
            case .transactionInProgress:
                return "资料库正在处理其他操作，请稍后重试。"
            case .libraryNotRegistered:
                return "资料库列表已变化，请重新选择。"
            case .libraryChanged:
                return "资料库位置或内容已变化，请重新选择。"
            case .reconnectIdentifierMismatch:
                return "所选位置属于另一资料库。"
            case .reconnectModeMismatch:
                return "所选资料库的存储方式不一致。"
            }
        }
        if let error = error as? LibraryWriterLeaseError { return error.localizedDescription }
        if let error = error as? LibraryMetadataReadError { return error.localizedDescription }
        if let error = error as? MusicLibraryRegistryError { return error.localizedDescription }
        if let error = error as? LibraryRelocationError {
            switch error {
            case .pendingRepair, .recoveryConflict, .recoveryFailed:
                return "资料库迁移需要处理，请检查原位置和目标位置的资料库。"
            case .pendingMutations:
                return error.localizedDescription
            default: break
            }
        }
        if let error = error as? LibraryRemovalError {
            return error.localizedDescription
        }
        if error is LibraryLifecycleTransactionGateError {
            return message(for: LibraryOpenError.transactionInProgress)
        }
        if let error = error as? LibraryRootAccessError {
            switch error {
            case .permissionDenied: return message(for: LibraryOpenError.securityScopeDenied)
            case .identityMismatch: return message(for: LibraryOpenError.libraryChanged)
            case .inTrash: return message(for: LibraryOpenError.libraryNotFound)
            }
        }
        if let error = error as? RegisteredLibraryActivationError {
            switch error {
            case .notRegistered: return message(for: LibraryOpenError.libraryNotRegistered)
            case .reconnectRequired: return "找不到资料库，请重新选择位置。"
            }
        }
        return "无法打开资料库，请重试。"
    }
}

@MainActor
final class LibraryOpenService {
    private let registryStore: MusicLibraryRegistryStore
    private let sessionController: LibrarySessionController
    private let bookmarkResolver: any BookmarkResolving
    private let fileOperator: any LibraryLifecycleFileOperating
    private let gate: LibraryLifecycleTransactionGate
    private let requiresSecurityScope: Bool
    private let recoveryStateStore: LibraryRecoveryStateStore
    private var generation: UInt64

    init(
        registryStore: MusicLibraryRegistryStore,
        sessionController: LibrarySessionController,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        fileOperator: any LibraryLifecycleFileOperating = ProductionLibraryLifecycleFileOperator(),
        gate: LibraryLifecycleTransactionGate = LibraryLifecycleTransactionGate(),
        requiresSecurityScope: Bool = false,
        initialGeneration: UInt64 = 1
    ) {
        self.registryStore = registryStore
        self.sessionController = sessionController
        self.bookmarkResolver = bookmarkResolver
        self.fileOperator = fileOperator
        self.gate = gate
        self.requiresSecurityScope = requiresSecurityScope
        self.recoveryStateStore = LibraryRecoveryStateStore(
            fileURL: registryStore.fileURL.deletingLastPathComponent()
                .appendingPathComponent("LibraryRecoveryState.json")
        )
        self.generation = initialGeneration
    }

    func inspect(
        selectedURL: URL,
        expectedContext: LibraryContext? = nil,
        allowStalePathConflictRepair: Bool = false
    ) async throws -> LibraryOpenInspection {
        try Task.checkCancellation()
        let root = try await resolveLibraryRoot(selectedURL)
        try Task.checkCancellation()
        guard !LibraryRootLocationPolicy.isInTrash(root) else { throw LibraryOpenError.libraryNotFound }
        let didStart = bookmarkResolver.startAccessing(root)
        guard didStart || !requiresSecurityScope else { throw LibraryOpenError.securityScopeDenied }
        defer { if didStart { bookmarkResolver.stopAccessing(root) } }

        let manifest: MusicLibraryManifest
        do {
            manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: root).manifestURL)
            if let expectedContext {
                guard manifest.libraryID == expectedContext.id,
                      manifest.mode == expectedContext.mode,
                      root == expectedContext.rootURL else {
                    throw LibraryOpenError.libraryChanged
                }
            }
            do {
                try await fileOperator.validateLibrary(at: root, expectedID: manifest.libraryID, expectedMode: manifest.mode)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Libraries migrated from the pre-manifest layout can miss
                // scaffolding (directories, scoped settings). Repair once and
                // revalidate; genuinely invalid libraries still fail.
                let active = sessionController.activeLibraryContext
                let repairLease: LibraryWriterLease?
                if active?.id == manifest.libraryID && active?.rootURL == root {
                    repairLease = nil // The active session already owns the lease.
                } else {
                    repairLease = try LibraryWriterLease.acquire(paths: LibraryPaths(rootURL: root))
                }
                defer { repairLease?.release() }
                try await fileOperator.repairLibraryScaffolding(at: root)
                try await fileOperator.validateLibrary(at: root, expectedID: manifest.libraryID, expectedMode: manifest.mode)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LibraryOpenError {
            throw error
        } catch let error as LibraryWriterLeaseError {
            throw error
        } catch {
            Log.error("[LibraryOpen] inspection failed root=\(root.path): \(error)", category: .library)
            throw LibraryOpenError.invalidManifest
        }
        let registry = await registryStore.snapshot()
        if let registered = registry.library(id: manifest.libraryID),
           registered.modeProjection != manifest.mode {
            throw LibraryOpenError.reconnectModeMismatch(expected: registered.modeProjection, actual: manifest.mode)
        }
        let normalizedRoot = root.standardizedFileURL
        let pathConflict = registry.libraries.first(where: {
            $0.id != manifest.libraryID
                && URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL == normalizedRoot
        })
        let stalePathConflictLibraryID = allowStalePathConflictRepair
            ? pathConflict.flatMap { conflict in
                isStalePathConflict(conflict, at: normalizedRoot) ? conflict.id : nil
            }
            : nil
        if pathConflict != nil, stalePathConflictLibraryID == nil {
            throw LibraryOpenError.pathConflict
        }

        let bookmark: Data
        do { bookmark = try bookmarkResolver.refreshBookmark(for: root) }
        catch {
            Log.error("[LibraryOpen] bookmark creation failed root=\(root.path): \(error)", category: .library)
            throw LibraryOpenError.bookmarkFailed
        }
        let descriptor = try MusicLibraryBookmark.make(manifest: manifest, rootURL: root, bookmarkData: bookmark)
        generation &+= 1
        return LibraryOpenInspection(
            context: LibraryContext(manifest: manifest, rootURL: root, rootBookmarkData: bookmark, generation: generation),
            descriptor: descriptor,
            previousDescriptor: registry.library(id: manifest.libraryID),
            stalePathConflictLibraryID: stalePathConflictLibraryID
        )
    }

    func open(
        selectedURL: URL,
        activate: Bool = true,
        expectedContext: LibraryContext? = nil,
        allowStalePathConflictRepair: Bool = false
    ) async throws -> LibraryOpenResult {
        try Task.checkCancellation()
        // Inspection can repair scaffolding; serialize it with activation and
        // other lifecycle writes, not just the final registry commit.
        do { try gate.acquire() }
        catch { throw LibraryOpenError.transactionInProgress }
        defer { gate.release() }
        let inspection = try await inspect(
            selectedURL: selectedURL,
            expectedContext: expectedContext,
            allowStalePathConflictRepair: allowStalePathConflictRepair
        )
        guard activate else {
            return LibraryOpenResult(context: inspection.context, didRegister: false, didRefreshBookmark: false)
        }
        return try await commitActivation(inspection, gateAlreadyHeld: true)
    }

    func activateRegisteredLibrary(id: UUID) async throws -> LibraryOpenResult {
        try Task.checkCancellation()
        do { try gate.acquire() }
        catch { throw LibraryOpenError.transactionInProgress }
        defer { gate.release() }
        let context = try await LibraryStartupContextResolver(
            registryStore: registryStore,
            bookmarkResolver: bookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        ).resolveRegistered(libraryID: id)
        let lease = try LibraryRootAccessLease(
            context: context,
            resolver: bookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        defer { lease.release() }
        let inspection = try await inspect(selectedURL: context.rootURL, expectedContext: context)
        return try await commitActivation(inspection, gateAlreadyHeld: true)
    }

    func reconnectRegisteredLibrary(
        id: UUID,
        selectedURL: URL
    ) async throws -> LibraryOpenResult {
        try Task.checkCancellation()
        do { try gate.acquire() }
        catch { throw LibraryOpenError.transactionInProgress }
        defer { gate.release() }
        let registry = await registryStore.snapshot()
        guard let registered = registry.library(id: id) else {
            throw LibraryOpenError.libraryNotRegistered
        }
        let inspection = try await inspect(selectedURL: selectedURL)
        guard inspection.context.id == id else {
            throw LibraryOpenError.reconnectIdentifierMismatch(
                expected: id,
                actual: inspection.context.id
            )
        }
        guard inspection.context.mode == registered.modeProjection else {
            throw LibraryOpenError.reconnectModeMismatch(
                expected: registered.modeProjection,
                actual: inspection.context.mode
            )
        }
        return try await commitActivation(inspection, gateAlreadyHeld: true)
    }

    func commitActivation(_ inspection: LibraryOpenInspection, gateAlreadyHeld: Bool = false) async throws -> LibraryOpenResult {
        if !gateAlreadyHeld {
            do { try gate.acquire() }
            catch { throw LibraryOpenError.transactionInProgress }
        }
        defer { if !gateAlreadyHeld { gate.release() } }
        try Task.checkCancellation()

        let lease: LibraryRootAccessLease
        do {
            lease = try LibraryRootAccessLease(
                context: inspection.context,
                resolver: bookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
        } catch LibraryRootAccessError.identityMismatch {
            throw LibraryOpenError.libraryChanged
        } catch LibraryRootAccessError.inTrash {
            throw LibraryOpenError.libraryNotFound
        } catch {
            Log.error("[LibraryOpen] root access failed library=\(inspection.context.id): \(error)", category: .library)
            throw LibraryOpenError.securityScopeDenied
        }
        defer { lease.release() }
        do {
            try await fileOperator.validateLibrary(
                at: inspection.context.rootURL,
                expectedID: inspection.context.id,
                expectedMode: inspection.context.mode
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("[LibraryOpen] activation validation failed library=\(inspection.context.id): \(error)", category: .library)
            throw LibraryOpenError.libraryChanged
        }
        try Task.checkCancellation()
        let beforeRegistry = await registryStore.snapshot()
        let previousSession = sessionController.activeLibraryContext
        var failure = LibraryOpenError.registryCommitFailed
        var didAttemptSwitch = false
        do {
            if let staleID = inspection.stalePathConflictLibraryID {
                guard let staleDescriptor = beforeRegistry.library(id: staleID),
                      URL(fileURLWithPath: staleDescriptor.lastKnownPath).standardizedFileURL
                        == inspection.context.rootURL.standardizedFileURL else {
                    throw LibraryOpenError.pathConflict
                }
                // Repair only the registry row. The root remains in place and
                // is registered under the manifest identity below.
                try await registryStore.remove(libraryID: staleID, idempotent: true)
            }
            try await registryStore.register(inspection.descriptor)
            try Task.checkCancellation()
            failure = .activationFailed
            didAttemptSwitch = true
            try await sessionController.switchToLibrary(inspection.context)
            failure = .registryCommitFailed
            try await registryStore.setActiveLibrary(id: inspection.context.id, manifestMode: inspection.context.mode)
        } catch {
            Log.error("[LibraryOpen] activation failed library=\(inspection.context.id) stage=\(failure): \(error)", category: .library)
            let registryConflict = (error as? MusicLibraryRegistryError) == .externalModification
                || (error as? MusicLibraryRegistryError) == .registryLocked
            let didRecover = await Task { @MainActor in
                var recovered = true
                do {
                    if didAttemptSwitch,
                       self.sessionController.activeLibraryContext != previousSession || previousSession == nil {
                        try await restoreLifecycleSession(previousSession, using: self.sessionController)
                    }
                } catch {
                    recovered = false
                    Log.error("[LibraryOpen] session rollback failed: \(error)", category: .library)
                }
                // If recovery left a live session, keep its registry row and
                // publish that actual selection instead of restoring a stale
                // active ID for a different library.
                do {
                    if registryConflict {
                        // Another process owns a newer state; never replace it
                        // with the snapshot taken before this activation.
                    } else if !recovered, let active = self.sessionController.activeLibraryContext {
                        try await self.registryStore.setActiveLibrary(id: active.id, manifestMode: active.mode)
                    } else {
                        try await self.registryStore.rollbackActivation(
                            before: beforeRegistry,
                            target: inspection.descriptor,
                            staleID: inspection.stalePathConflictLibraryID
                        )
                    }
                } catch {
                    recovered = false
                    Log.error("[LibraryOpen] registry rollback failed: \(error)", category: .library)
                }
                return recovered
            }.value
            guard didRecover else {
                // Persist the failed adjudication instead of leaving only a
                // transient error. The live session (if any) and the durable
                // selection are recorded together so the next launch reports
                // the same state even when they disagree.
                let live = sessionController.activeLibraryContext
                let snapshot = await registryStore.snapshot()
                recoveryStateStore.save(
                    LibraryRecoveryState(
                        message: LibraryOpenFailure.message(for: error),
                        intendedLibraryID: previousSession?.id ?? inspection.context.id,
                        activeLibraryID: live?.id ?? snapshot.activeLibraryID,
                        hasLiveSession: live != nil
                    )
                )
                throw LibraryOpenError.recoveryFailed
            }
            if error is CancellationError { throw CancellationError() }
            if let error = error as? LibraryOpenError { throw error }
            if let error = error as? LibraryWriterLeaseError { throw error }
            if let error = error as? LibraryMetadataReadError { throw error }
            if let error = error as? MusicLibraryRegistryError { throw error }
            throw failure
        }
        recoveryStateStore.clear()
        return LibraryOpenResult(
            context: sessionController.activeLibraryContext ?? inspection.context,
            didRegister: beforeRegistry.library(id: inspection.context.id) == nil,
            didRefreshBookmark: beforeRegistry.library(id: inspection.context.id)?.rootBookmarkData != inspection.descriptor.rootBookmarkData
                || beforeRegistry.library(id: inspection.context.id)?.lastKnownPath != inspection.descriptor.lastKnownPath
        )
    }

    /// This runs after activation. A failed source status read must not turn a
    /// successfully opened library into an opening failure.
    nonisolated static func unavailableReferencedSourceIDs(in store: ReferencedSourceStore) async -> [UUID]? {
        do {
            return try await store.loadAll()
                .filter { $0.status != .available }
                .map(\.id)
                .sorted { $0.uuidString < $1.uuidString }
        } catch is CancellationError {
            return []
        } catch {
            Log.warning("[LibraryOpen] post-activation source check failed: \(error)", category: .library)
            return nil
        }
    }

    private func isStalePathConflict(
        _ descriptor: MusicLibraryBookmark,
        at normalizedRoot: URL
    ) -> Bool {
        do {
            // The registry row may point to a root that has already been
            // removed or replaced. For this explicit recovery path, the
            // durable evidence is the row's recorded path plus the current
            // root's valid manifest; do not require the old bookmark to
            // resolve before repairing its stale index entry.
            guard URL(fileURLWithPath: descriptor.lastKnownPath).standardizedFileURL == normalizedRoot else {
                return false
            }
            let manifest = try MusicLibraryManifest.read(
                from: LibraryPaths(rootURL: normalizedRoot).manifestURL
            )
            return manifest.libraryID != descriptor.id || manifest.mode != descriptor.modeProjection
        } catch {
            // An unreadable conflict is not safe to take over; retain the
            // original reconnect/path-conflict behaviour.
            return false
        }
    }

    private func resolveLibraryRoot(_ selectedURL: URL) async throws -> URL {
        let selected = selectedURL.standardizedFileURL
        if await fileOperator.itemExists(at: LibraryPaths(rootURL: selected).manifestURL) { return selected }
        let child = selected.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
        if await fileOperator.itemExists(at: LibraryPaths(rootURL: child).manifestURL) { return child }
        throw LibraryOpenError.libraryNotFound
    }
}

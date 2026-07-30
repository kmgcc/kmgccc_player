import Foundation

nonisolated struct LibraryOpenInspection: Sendable, Equatable {
    let context: LibraryContext
    let descriptor: MusicLibraryBookmark
    let previousDescriptor: MusicLibraryBookmark?
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
    case recoveryFailed
    case transactionInProgress
    case securityScopeDenied
    case libraryNotRegistered
    case reconnectIdentifierMismatch(expected: UUID, actual: UUID)
    case reconnectModeMismatch(expected: MusicLibraryMode, actual: MusicLibraryMode)
}

@MainActor
final class LibraryOpenService {
    private let registryStore: MusicLibraryRegistryStore
    private let sessionController: LibrarySessionController
    private let bookmarkResolver: any BookmarkResolving
    private let fileOperator: any LibraryLifecycleFileOperating
    private let gate: LibraryLifecycleTransactionGate
    private let requiresSecurityScope: Bool
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
        self.generation = initialGeneration
    }

    func inspect(selectedURL: URL) async throws -> LibraryOpenInspection {
        let root = try await resolveLibraryRoot(selectedURL)
        let didStart = bookmarkResolver.startAccessing(root)
        guard didStart || !requiresSecurityScope else { throw LibraryOpenError.securityScopeDenied }
        defer { if didStart { bookmarkResolver.stopAccessing(root) } }

        let manifest: MusicLibraryManifest
        do {
            manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: root).manifestURL)
            do {
                try await fileOperator.validateLibrary(at: root, expectedID: manifest.libraryID, expectedMode: manifest.mode)
            } catch {
                // Libraries migrated from the pre-manifest layout can miss
                // scaffolding (directories, scoped settings). Repair once and
                // revalidate; genuinely invalid libraries still fail.
                try await fileOperator.repairLibraryScaffolding(at: root)
                try await fileOperator.validateLibrary(at: root, expectedID: manifest.libraryID, expectedMode: manifest.mode)
            }
        } catch {
            throw LibraryOpenError.invalidManifest
        }
        let registry = await registryStore.snapshot()
        let normalizedRoot = root.standardizedFileURL
        if registry.libraries.contains(where: {
            $0.id != manifest.libraryID
                && URL(fileURLWithPath: $0.lastKnownPath).standardizedFileURL == normalizedRoot
        }) { throw LibraryOpenError.pathConflict }

        let bookmark: Data
        do { bookmark = try bookmarkResolver.refreshBookmark(for: root) }
        catch { throw LibraryOpenError.bookmarkFailed }
        let descriptor = try MusicLibraryBookmark.make(manifest: manifest, rootURL: root, bookmarkData: bookmark)
        generation &+= 1
        return LibraryOpenInspection(
            context: LibraryContext(manifest: manifest, rootURL: root, rootBookmarkData: bookmark, generation: generation),
            descriptor: descriptor,
            previousDescriptor: registry.library(id: manifest.libraryID)
        )
    }

    func open(selectedURL: URL, activate: Bool = true) async throws -> LibraryOpenResult {
        let inspection = try await inspect(selectedURL: selectedURL)
        guard activate else {
            return LibraryOpenResult(context: inspection.context, didRegister: false, didRefreshBookmark: false)
        }
        do { try gate.acquire() }
        catch { throw LibraryOpenError.transactionInProgress }
        defer { gate.release() }
        return try await commitActivation(inspection, gateAlreadyHeld: true)
    }

    func reconnectRegisteredLibrary(
        id: UUID,
        selectedURL: URL
    ) async throws -> LibraryOpenResult {
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
        do { try gate.acquire() }
        catch { throw LibraryOpenError.transactionInProgress }
        defer { gate.release() }
        return try await commitActivation(inspection, gateAlreadyHeld: true)
    }

    func commitActivation(_ inspection: LibraryOpenInspection, gateAlreadyHeld: Bool = false) async throws -> LibraryOpenResult {
        if !gateAlreadyHeld {
            do { try gate.acquire() }
            catch { throw LibraryOpenError.transactionInProgress }
        }
        defer { if !gateAlreadyHeld { gate.release() } }

        let lease: LibraryRootAccessLease
        do {
            lease = try LibraryRootAccessLease(
                descriptor: inspection.descriptor,
                resolver: bookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
        } catch { throw LibraryOpenError.securityScopeDenied }
        _ = lease
        let beforeRegistry = await registryStore.snapshot()
        let previousSession = sessionController.activeLibraryContext
        do {
            try await registryStore.register(inspection.descriptor)
            try await sessionController.switchToLibrary(inspection.context)
            try await registryStore.setActiveLibrary(id: inspection.context.id, manifestMode: inspection.context.mode)
        } catch {
            do {
                try await restoreLifecycleSession(previousSession, using: sessionController)
                try await registryStore.replaceSnapshot(beforeRegistry)
            } catch {
                throw LibraryOpenError.recoveryFailed
            }
            throw LibraryOpenError.activationFailed
        }
        return LibraryOpenResult(
            context: inspection.context,
            didRegister: inspection.previousDescriptor == nil,
            didRefreshBookmark: inspection.previousDescriptor?.rootBookmarkData != inspection.descriptor.rootBookmarkData
                || inspection.previousDescriptor?.lastKnownPath != inspection.descriptor.lastKnownPath
        )
    }

    private func resolveLibraryRoot(_ selectedURL: URL) async throws -> URL {
        let selected = selectedURL.standardizedFileURL
        if await fileOperator.itemExists(at: LibraryPaths(rootURL: selected).manifestURL) { return selected }
        let child = selected.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
        if await fileOperator.itemExists(at: LibraryPaths(rootURL: child).manifestURL) { return child }
        throw LibraryOpenError.libraryNotFound
    }
}

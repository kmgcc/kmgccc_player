import Foundation

nonisolated enum LibraryLifecycleTransactionGateError: Error, Equatable {
    case transactionInProgress
}

@MainActor
final class LibraryLifecycleTransactionGate {
    private var isHeld = false

    func acquire() throws {
        guard !isHeld else { throw LibraryLifecycleTransactionGateError.transactionInProgress }
        isHeld = true
    }

    func release() {
        precondition(isHeld)
        isHeld = false
    }
}

nonisolated final class LibraryRootAccessLease: @unchecked Sendable {
    let rootURL: URL
    let isStale: Bool
    private let scopeLease: SecurityScopedResourceLease

    init(descriptor: MusicLibraryBookmark, resolver: any BookmarkResolving, requiresSecurityScope: Bool) throws {
        let resolution = try resolver.resolve(descriptor.rootBookmarkData)
        rootURL = resolution.url.standardizedFileURL
        guard !LibraryRootLocationPolicy.isInTrash(rootURL) else { throw LibraryRootAccessError.inTrash }
        isStale = resolution.isStale
        let didStart = resolver.startAccessing(rootURL)
        guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: rootURL.path)) else {
            throw LibraryRootAccessError.permissionDenied
        }
        scopeLease = didStart
            ? SecurityScopedResourceLease { resolver.stopAccessing(resolution.url.standardizedFileURL) }
            : .none
    }

    init(context: LibraryContext, resolver: any BookmarkResolving, requiresSecurityScope: Bool) throws {
        let expectedRoot = context.rootURL.standardizedFileURL
        guard !LibraryRootLocationPolicy.isInTrash(expectedRoot) else { throw LibraryRootAccessError.inTrash }
        let resolution: (url: URL, isStale: Bool)
        do {
            resolution = try resolver.resolve(context.rootBookmarkData)
        } catch {
            guard !requiresSecurityScope,
                  FileManager.default.isReadableFile(atPath: expectedRoot.path) else {
                throw LibraryRootAccessError.permissionDenied
            }
            rootURL = expectedRoot
            isStale = false
            scopeLease = .none
            return
        }

        rootURL = resolution.url.standardizedFileURL
        isStale = resolution.isStale
        guard !LibraryRootLocationPolicy.isInTrash(rootURL) else { throw LibraryRootAccessError.inTrash }
        guard rootURL == expectedRoot else {
            throw LibraryRootAccessError.identityMismatch
        }
        let didStart = resolver.startAccessing(rootURL)
        guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: rootURL.path)) else {
            throw LibraryRootAccessError.permissionDenied
        }
        scopeLease = didStart
            ? SecurityScopedResourceLease { resolver.stopAccessing(resolution.url.standardizedFileURL) }
            : .none
    }

    func release() { scopeLease.release() }
}

nonisolated enum LibraryRootAccessError: Error, Equatable {
    case permissionDenied
    case identityMismatch
    case inTrash
}

nonisolated enum LibraryRootLocationPolicy {
    static func isInTrash(_ rootURL: URL) -> Bool {
        let components = rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    static func isFactoryDefaultRegistration(
        _ descriptor: MusicLibraryBookmark,
        defaultRootURL: URL = LibraryLocationStore.defaultLibraryRootURL
    ) -> Bool {
        let recordedRoot = URL(fileURLWithPath: descriptor.lastKnownPath).standardizedFileURL
        if recordedRoot.path == defaultRootURL.standardizedFileURL.path { return true }
        // Earlier builds persisted a bookmark's Trash destination. The bare
        // legacy root name identifies that controlled default root; current
        // user-created libraries always have a named directory suffix.
        return isInTrash(recordedRoot)
            && recordedRoot.lastPathComponent == LibraryPaths.rootDirectoryName
    }

    static func canFlush(_ context: LibraryContext) throws -> Bool {
        guard !isInTrash(context.rootURL) else { return false }
        do {
            let values = try context.rootURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == false { return false }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        return manifest.libraryID == context.id && manifest.mode == context.mode
    }
}

@MainActor
protocol LibrarySessionValidating: AnyObject {
    func validate(_ context: LibraryContext) async throws
}

@MainActor
final class LibrarySessionFactoryValidator: LibrarySessionValidating {
    private let factory: any LibrarySessionBuilding

    init(factory: any LibrarySessionBuilding) {
        self.factory = factory
    }

    func validate(_ context: LibraryContext) async throws {
        let session = try await factory.makeSession(for: context)
        do {
            try await session.load()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}

nonisolated enum RegisteredLibraryActivationError: Error, Equatable {
    case notRegistered
    case reconnectRequired(UUID)
}

nonisolated enum LibraryStartupResolution: Sendable, Equatable {
    case context(LibraryContext)
    case noActive
    case unavailable
}

/// A failure to establish the single-writer boundary is not evidence that the
/// user's active library disappeared. Startup must stay unavailable and leave
/// the registered library untouched instead of silently creating and
/// activating a second empty library at an alternate path.
nonisolated enum LibraryStartupFailurePolicy {
    static func permitsFactoryDefaultFallback(after error: any Error) -> Bool {
        error is LibraryWriterLeaseError == false
    }
}

@MainActor
struct LibraryStartupContextResolver {
    let registryStore: MusicLibraryRegistryStore
    let bookmarkResolver: any BookmarkResolving
    let requiresSecurityScope: Bool

    init(
        registryStore: MusicLibraryRegistryStore,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) {
        self.registryStore = registryStore
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
    }

    func resolve(
        allowSuccessorAfterRemoval removedMode: MusicLibraryMode? = nil,
        generation: UInt64 = 1
    ) async -> LibraryStartupResolution {
        await removeTrashedLibraries()
        let registry = await registryStore.snapshot()
        guard registry.pendingFactoryDefaultReplacement != true else { return .noActive }
        var seen = Set<UUID>()
        if let activeID = registry.activeLibraryID {
            seen.insert(activeID)
            if let descriptor = registry.library(id: activeID),
               let context = await resolve(descriptor, generation: generation) {
                return .context(context)
            }
        }

        var ids: [UUID] = []
        if let removedMode {
            if let recent = registry.recentLibraryID(for: removedMode) { ids.append(recent) }
            ids.append(contentsOf: registry.libraries.filter { $0.modeProjection == removedMode }.map(\.id))
        } else {
            ids.append(contentsOf: [registry.recentManagedLibraryID, registry.recentReferencedLibraryID].compactMap { $0 })
        }
        ids.append(contentsOf: registry.libraries.map(\.id))
        for id in ids {
            guard seen.insert(id).inserted,
                  let descriptor = registry.library(id: id),
                  let context = await resolve(descriptor, generation: generation) else { continue }
            return .context(context)
        }
        return registry.activeLibraryID == nil ? .noActive : .unavailable
    }

    func resolveRegistered(libraryID: UUID, generation: UInt64 = 1) async throws -> LibraryContext {
        await removeTrashedLibraries()
        let registry = await registryStore.snapshot()
        guard let descriptor = registry.library(id: libraryID) else {
            throw RegisteredLibraryActivationError.notRegistered
        }
        guard let context = await resolve(descriptor, generation: generation) else {
            throw RegisteredLibraryActivationError.reconnectRequired(libraryID)
        }
        return context
    }

    /// A bookmark follows a root into the Trash. Remove only its registry
    /// entry; offline and unreadable roots retain their reconnect path.
    @discardableResult
    func removeTrashedLibraries() async -> Set<UUID> {
        let registry = await registryStore.snapshot()
        var removedIDs = Set<UUID>()
        for descriptor in registry.libraries {
            let root = (try? bookmarkResolver.resolve(descriptor.rootBookmarkData).url)
                ?? URL(fileURLWithPath: descriptor.lastKnownPath, isDirectory: true)
            guard LibraryRootLocationPolicy.isInTrash(root) else { continue }
            do {
                try await registryStore.remove(
                    libraryID: descriptor.id,
                    requireFactoryDefaultReplacement: LibraryRootLocationPolicy.isFactoryDefaultRegistration(descriptor)
                )
                removedIDs.insert(descriptor.id)
            } catch {
                Log.error("[LibrarySession] failed to remove trashed library registration library=\(descriptor.id): \(error)", category: .library)
            }
        }
        return removedIDs
    }

    private func resolve(_ descriptor: MusicLibraryBookmark, generation: UInt64) async -> LibraryContext? {
        do {
            let lease = try LibraryRootAccessLease(
                descriptor: descriptor,
                resolver: bookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
            let manifest = try MusicLibraryManifest.read(from: LibraryPaths(rootURL: lease.rootURL).manifestURL)
            guard manifest.libraryID == descriptor.id, manifest.mode == descriptor.modeProjection else { return nil }
            let bookmark = lease.isStale
                ? try bookmarkResolver.refreshBookmark(for: lease.rootURL)
                : descriptor.rootBookmarkData
            if lease.isStale || descriptor.lastKnownPath != lease.rootURL.path {
                try await registryStore.updateBookmark(
                    libraryID: descriptor.id,
                    bookmarkData: bookmark,
                    lastKnownPath: lease.rootURL.path,
                    modeProjection: manifest.mode
                )
            }
            return LibraryContext(
                manifest: manifest,
                rootURL: lease.rootURL,
                rootBookmarkData: bookmark,
                generation: generation
            )
        } catch { return nil }
    }
}

@MainActor
func restoreLifecycleSession(
    _ previous: LibraryContext?,
    using controller: LibrarySessionController
) async throws {
    if let previous {
        try await controller.switchToLibrary(previous)
    } else {
        try await controller.closeActiveSession()
    }
}

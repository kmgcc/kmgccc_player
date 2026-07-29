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
        let registry = await registryStore.snapshot()
        if let activeID = registry.activeLibraryID {
            guard let descriptor = registry.library(id: activeID),
                  let context = await resolve(descriptor, generation: generation) else {
                return .unavailable
            }
            return .context(context)
        }
        guard let removedMode else { return .noActive }

        var ids: [UUID] = []
        if let recent = registry.recentLibraryID(for: removedMode) { ids.append(recent) }
        ids.append(contentsOf: registry.libraries.filter { $0.modeProjection == removedMode }.map(\.id))
        ids.append(contentsOf: registry.libraries.map(\.id))
        var seen = Set<UUID>()
        for id in ids {
            guard seen.insert(id).inserted,
                  let descriptor = registry.library(id: id),
                  let context = await resolve(descriptor, generation: generation) else { continue }
            return .context(context)
        }
        return .noActive
    }

    func resolveRegistered(libraryID: UUID, generation: UInt64 = 1) async throws -> LibraryContext {
        let registry = await registryStore.snapshot()
        guard let descriptor = registry.library(id: libraryID) else {
            throw RegisteredLibraryActivationError.notRegistered
        }
        guard let context = await resolve(descriptor, generation: generation) else {
            throw RegisteredLibraryActivationError.reconnectRequired(libraryID)
        }
        return context
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

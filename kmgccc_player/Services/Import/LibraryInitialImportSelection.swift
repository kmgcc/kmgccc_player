import Foundation

nonisolated struct LibraryInitialImportResult: Sendable, Equatable {
    let requested: Int
    let planned: Int
    let imported: Int
    let failures: [ImportInputFailure]
    let sourceIDs: [UUID]

    var didSucceed: Bool { imported > 0 || !sourceIDs.isEmpty }
    var isPartial: Bool { didSucceed && (!failures.isEmpty || imported < planned) }
}

nonisolated enum LibraryInitialImportError: Error, Equatable {
    case initialImportFailed(LibraryInitialImportResult)
}

nonisolated enum CreateMusicLibraryResult: Sendable, Equatable {
    case created(LibraryContext, initialImport: LibraryInitialImportResult?)
    case existingLibrary(LibraryContext)
    case existingLibraryModeMismatch(LibraryContext, requestedMode: MusicLibraryMode)
}

/// Owns the security scopes granted by the setup picker until the newly created
/// library has durably registered sources and committed its initial import.
@MainActor
final class LibraryInitialImportSelection {
    let urls: [URL]
    private var leases: [SecurityScopedResourceLease]

    init(
        urls: [URL],
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver()
    ) {
        self.urls = urls
        leases = urls.compactMap { url in
            guard bookmarkResolver.startAccessing(url) else { return nil }
            return SecurityScopedResourceLease {
                bookmarkResolver.stopAccessing(url)
            }
        }
    }

    func release() {
        let active = leases
        leases.removeAll()
        for lease in active { lease.release() }
    }

    deinit {
        for lease in leases { lease.release() }
    }
}

import Foundation

nonisolated enum LibraryImportSourceEntryKind: String, Sendable {
    case directory
    case individualFiles
}

/// A user-facing grouping of the URLs selected in one import operation.
/// Directories remain separate entries; all individually selected files are
/// deliberately represented by one entry so the confirmation UI stays small.
nonisolated struct LibraryImportSourceEntry: Identifiable, Hashable, Sendable {
    let id: String
    let kind: LibraryImportSourceEntryKind
    let urls: [URL]
    let displayName: String

    var detail: String {
        switch kind {
        case .directory:
            return urls.first?.path ?? ""
        case .individualFiles:
            return "\(urls.count) 首歌曲"
        }
    }

    static func makeEntries(from urls: [URL]) -> [LibraryImportSourceEntry] {
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            let canonical = canonicalPath(url)
            guard !result.contains(where: { canonicalPath($0) == canonical }) else { return }
            result.append(url)
        }
        let directories = uniqueURLs.filter(isDirectory)
        let files = uniqueURLs.filter { !isDirectory($0) }

        var entries = directories.map {
            LibraryImportSourceEntry(
                kind: .directory,
                urls: [$0],
                displayName: $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent
            )
        }
        if !files.isEmpty {
            let firstName = files[0].deletingPathExtension().lastPathComponent
            let displayName: String
            if files.count == 1 {
                displayName = firstName.isEmpty ? "所选歌曲" : firstName
            } else {
                displayName = "\(firstName.isEmpty ? "所选歌曲" : firstName) 等歌曲"
            }
            entries.append(
                LibraryImportSourceEntry(
                    kind: .individualFiles,
                    urls: files,
                    displayName: displayName
                )
            )
        }
        return entries
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isDirectory(_ url: URL) -> Bool {
        url.hasDirectoryPath
            || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private init(kind: LibraryImportSourceEntryKind, urls: [URL], displayName: String) {
        self.kind = kind
        self.urls = urls
        self.displayName = displayName
        id = "\(kind.rawValue):\(urls.map(Self.canonicalPath).joined(separator: "\u{1F}"))"
    }
}

nonisolated struct LibraryInitialImportSource: Sendable, Equatable {
    let id: UUID
    let mode: ReferencedSourceMode
    let path: String
    let displayName: String
}

nonisolated struct LibraryInitialImportResult: Sendable, Equatable {
    let requested: Int
    let planned: Int
    let imported: Int
    let failures: [ImportInputFailure]
    let sourceIDs: [UUID]
    /// Sources prepared by a referenced import, including their selected root.
    /// This preserves the folder-to-source mapping needed for playlist binding.
    let sources: [LibraryInitialImportSource]
    /// Imported or reused tracks keyed by their original input path. This is
    /// used only to populate one playlist for a group of individually selected
    /// files and never becomes library identity.
    let importedTrackIDsByPath: [String: UUID]

    init(
        requested: Int,
        planned: Int,
        imported: Int,
        failures: [ImportInputFailure],
        sourceIDs: [UUID],
        sources: [LibraryInitialImportSource] = [],
        importedTrackIDsByPath: [String: UUID] = [:]
    ) {
        self.requested = requested
        self.planned = planned
        self.imported = imported
        self.failures = failures
        self.sourceIDs = sourceIDs
        self.sources = sources
        self.importedTrackIDsByPath = importedTrackIDsByPath
    }

    var didSucceed: Bool { imported > 0 || !sourceIDs.isEmpty }
    /// `planned` counts physical files discovered on disk. A directory may
    /// legitimately contain both an NCM source and the MP3 generated from it;
    /// both can resolve to one library track, so a count mismatch is not a
    /// factual import failure.
    var isPartial: Bool { didSucceed && !failures.isEmpty }
}

nonisolated enum LibraryInitialImportError: Error, Equatable {
    case initialImportFailed(LibraryInitialImportResult)
}

/// Controls whether the setup flow waits for the first import.  Creating the
/// library itself is a short lifecycle transaction; importing and enriching
/// its first sources is session-scoped background work.
nonisolated enum LibraryInitialImportPolicy: Sendable, Equatable {
    case waitForCompletion
    case background
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
    let createPlaylistsForDirectories: Bool
    let playlistSourceEntries: [LibraryImportSourceEntry]
    private let bookmarkResolver: any BookmarkResolving
    private var leases: [SecurityScopedResourceLease]

    init(
        urls: [URL],
        createPlaylistsForDirectories: Bool = false,
        playlistSourceEntries: [LibraryImportSourceEntry] = [],
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver()
    ) {
        self.urls = urls
        self.bookmarkResolver = bookmarkResolver
        self.playlistSourceEntries = playlistSourceEntries
        self.createPlaylistsForDirectories = createPlaylistsForDirectories
            || playlistSourceEntries.contains { $0.kind == .directory }
        let groupedRoots = SecurityScopeAuthorization.groupedRoots(for: urls)
        var failedRoots: [URL] = []
        leases = groupedRoots.compactMap { root in
            guard bookmarkResolver.startAccessing(root) else {
                failedRoots.append(root)
                return nil
            }
            return SecurityScopedResourceLease {
                bookmarkResolver.stopAccessing(root)
            }
        }
        // A resolver may grant a file but reject its parent (for example a
        // stale picker URL). Preserve that rare fallback without making it
        // the normal path for multi-file drags.
        for url in urls where urls.count == 1 {
            let path = SecurityScopeAuthorization.canonicalPath(url)
            guard failedRoots.contains(where: { root in
                let rootPath = SecurityScopeAuthorization.canonicalPath(root)
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }), bookmarkResolver.startAccessing(url) else { continue }
            leases.append(SecurityScopedResourceLease {
                bookmarkResolver.stopAccessing(url)
            })
        }
    }

    func release() {
        let active = leases
        leases.removeAll()
        for lease in active { lease.release() }
    }

    /// Duplicate the selection's security-scope ownership for work that must
    /// continue after the setup panel releases its own picker leases.
    @MainActor
    func retainedCopy() -> LibraryInitialImportSelection {
        LibraryInitialImportSelection(
            urls: urls,
            createPlaylistsForDirectories: createPlaylistsForDirectories,
            playlistSourceEntries: playlistSourceEntries,
            bookmarkResolver: bookmarkResolver
        )
    }

    deinit {
        for lease in leases { lease.release() }
    }
}

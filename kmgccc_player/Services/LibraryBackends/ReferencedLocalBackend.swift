//
//  ReferencedLocalBackend.swift
//  kmgccc_player
//

import Foundation

@MainActor
final class ReferencedLocalBackend: LibraryStorageBackend {
    let mode: MusicLibraryMode = .referenced
    private let paths: LibraryPaths
    private let sourceStore: ReferencedSourceStore
    private let sourceScope: ReferencedSourceScope
    private let bookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool
    private var selectionLeases: [URL: SecurityScopedResourceLease] = [:]

    init(
        paths: LibraryPaths,
        sourceStore: ReferencedSourceStore,
        sourceScope: ReferencedSourceScope,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) {
        self.paths = paths
        self.sourceStore = sourceStore
        self.sourceScope = sourceScope
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
    }

    func prepareInputs(_ selectedURLs: [URL]) async -> ImportInputPlan {
        var sourceIDs: [URL: UUID] = [:]
        var sources: [ImportSourceSelection] = []
        var failures: [ImportInputFailure] = []
        let existingDescriptors: [ReferencedSourceDescriptor]
        do {
            existingDescriptors = try await sourceStore.loadAll()
        } catch {
            return ImportInputPlan(
                files: [],
                directorySources: [],
                failures: [.init(url: paths.sourcesRootURL, message: error.localizedDescription)]
            )
        }
        var existingByCanonicalPath: [String: ReferencedSourceDescriptor] = [:]
        for descriptor in existingDescriptors {
            if let resolved = try? bookmarkResolver.resolve(descriptor.rootBookmarkData) {
                existingByCanonicalPath[canonicalPath(resolved.url)] = descriptor
            }
        }
        var seenDirectoryPaths = Set<String>()
        let uniqueSelections = selectedURLs.filter { selected in
            guard selected.hasDirectoryPath else { return true }
            return seenDirectoryPaths.insert(canonicalPath(selected)).inserted
        }

        for selected in uniqueSelections {
            let didStart = bookmarkResolver.startAccessing(selected)
            guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: selected.path)) else {
                failures.append(.init(url: selected, message: "Permission denied"))
                continue
            }
            selectionLeases[selected] = didStart
                ? SecurityScopedResourceLease { [bookmarkResolver] in bookmarkResolver.stopAccessing(selected) }
                : .none

            guard selected.hasDirectoryPath else { continue }
            do {
                let canonical = canonicalPath(selected)
                if let existing = existingByCanonicalPath[canonical] {
                    sourceIDs[selected] = existing.id
                    sources.append(.init(source: existing, rootURL: selected))
                    if let lease = selectionLeases.removeValue(forKey: selected) {
                        sourceScope.add(sourceID: existing.id, url: selected, lease: lease)
                    }
                    continue
                }
                let id = UUID()
                let bookmark = try bookmarkResolver.refreshBookmark(for: selected)
                let descriptor = ReferencedSourceDescriptor(
                    id: id,
                    rootBookmarkData: bookmark,
                    lastKnownPath: selected.path,
                    displayName: selected.lastPathComponent
                )
                try await sourceStore.save(descriptor)
                existingByCanonicalPath[canonical] = descriptor
                sourceIDs[selected] = id
                sources.append(.init(source: descriptor, rootURL: selected))
                if let lease = selectionLeases.removeValue(forKey: selected) {
                    sourceScope.add(sourceID: id, url: selected, lease: lease)
                }
            } catch {
                failures.append(.init(url: selected, message: error.localizedDescription))
            }
        }

        let readableSelections = uniqueSelections.filter { selected in
            selectionLeases[selected] != nil || sourceIDs[selected] != nil
        }
        let scanned = await ImportInputScanner.scan(
            selectedURLs: readableSelections,
            directorySources: sourceIDs
        )
        return ImportInputPlan(
            files: scanned.files,
            directorySources: sources,
            failures: failures + scanned.failures
        )
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func makePlacement(
        for file: ImportDiscoveredFile,
        trackID _: UUID,
        stagingDirectoryURL _: URL
    ) async throws -> ImportPlacement {
        guard file.url.pathExtension.lowercased() != "ncm" else {
            throw LibraryBackendError.unsupportedReferencedNCM
        }
        let bookmark: Data
        do {
            bookmark = try bookmarkResolver.refreshBookmark(for: file.url)
        } catch {
            throw LibraryBackendError.bookmarkCreationFailed
        }
        return .referenced(ReferencedFileLocator(
            fileBookmarkData: bookmark,
            sourceMemberships: file.memberships,
            primarySourceID: file.primarySourceID,
            lastKnownPath: file.url.path,
            fingerprint: file.fingerprint
        ))
    }

    func validate(_ placement: ImportPlacement) throws {
        guard placement.storageKind == .referenced else {
            throw LibraryBackendError.modeMismatch(expected: mode, actual: placement.storageKind)
        }
    }

    func finishImportBatch() {
        let leases = selectionLeases.values
        selectionLeases.removeAll()
        for lease in leases { lease.release() }
    }

    func close() async {
        finishImportBatch()
        sourceScope.close()
    }
}

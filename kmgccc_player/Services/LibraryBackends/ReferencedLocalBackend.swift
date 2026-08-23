//
//  ReferencedLocalBackend.swift
//  kmgccc_player
//

import Foundation

@MainActor
final class ReferencedLocalBackend: LibraryStorageBackend {
    let mode: MusicLibraryMode = .referenced
    private(set) var lastPreparedInputPlan: ImportInputPlan?
    private let paths: LibraryPaths
    private let sourceStore: ReferencedSourceStore
    private let sourceScope: ReferencedSourceScope
    private let bookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool
    private var selectionLeases: [URL: SecurityScopedResourceLease] = [:]
    /// File sources created during the latest `prepareInputs` batch. Pruned
    /// when their file does not survive the import pipeline.
    private var batchCreatedFileSources: [(id: UUID, path: String)] = []

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
        batchCreatedFileSources = []
        var sourceIDs: [URL: UUID] = [:]
        var sources: [ImportSourceSelection] = []
        var failures: [ImportInputFailure] = []
        let existingDescriptors: [ReferencedSourceDescriptor]
        do {
            existingDescriptors = try await sourceStore.loadAll()
        } catch {
            let plan = ImportInputPlan(
                files: [],
                directorySources: [],
                failures: [.init(url: paths.sourcesRootURL, message: error.localizedDescription)]
            )
            lastPreparedInputPlan = plan
            return plan
        }
        var existingByCanonicalPath: [String: ReferencedSourceDescriptor] = [:]
        var directoryRootPaths: [String] = []
        var directorySourceRoots: [String: (url: URL, id: UUID)] = [:]
        for descriptor in existingDescriptors {
            if descriptor.mode == .directory {
                // Coverage of files by directory sources must not depend on
                // bookmark resolution alone: a stale or unresolvable bookmark
                // would otherwise spawn a duplicate file source.
                let lastKnownURL = URL(fileURLWithPath: descriptor.lastKnownPath, isDirectory: true)
                let lastKnownCanonical = canonicalPath(lastKnownURL)
                directoryRootPaths.append(lastKnownCanonical)
                existingByCanonicalPath[lastKnownCanonical] = descriptor
                directorySourceRoots[lastKnownCanonical] = (lastKnownURL, descriptor.id)
                if let resolved = try? bookmarkResolver.resolve(descriptor.rootBookmarkData) {
                    let canonical = canonicalPath(resolved.url)
                    existingByCanonicalPath[canonical] = descriptor
                    directorySourceRoots[canonical] = (resolved.url, descriptor.id)
                    if canonical != lastKnownCanonical {
                        directoryRootPaths.append(canonical)
                    }
                }
            } else if let resolved = try? bookmarkResolver.resolve(descriptor.rootBookmarkData) {
                existingByCanonicalPath[canonicalPath(resolved.url)] = descriptor
            }
        }
        var seenSelectionPaths = Set<String>()
        var readableSelectionPaths = Set<String>()
        // Directories first so a file inside a same-batch directory selection
        // is recognized as covered by that directory source.
        let uniqueSelections = selectedURLs.filter { selected in
            seenSelectionPaths.insert(canonicalPath(selected)).inserted
        }.sorted { lhs, rhs in
            (lhs.hasDirectoryPath ? 0 : 1) < (rhs.hasDirectoryPath ? 0 : 1)
        }

        for selected in uniqueSelections {
            let canonical = canonicalPath(selected)
            let isDirectory = selected.hasDirectoryPath

            // A file chosen from an already-authorized directory must inherit
            // that directory source. Starting access on the child file can
            // fail even while the folder is readable, and it also loses the
            // source membership needed by automatic/NCM imports.
            if !isDirectory,
               let covered = directorySourceRoots
                   .filter({ path, _ in canonical == path || canonical.hasPrefix(path + "/") })
                   .max(by: { lhs, rhs in lhs.key.count < rhs.key.count }),
               sourceScope.authorizedRoots[covered.value.id] != nil {
                let rootURL = sourceScope.authorizedRoots[covered.value.id]?.url ?? covered.value.url
                sourceIDs[rootURL] = covered.value.id
                readableSelectionPaths.insert(canonical)
                continue
            }

            let didStart = bookmarkResolver.startAccessing(selected)
            guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: selected.path)) else {
                failures.append(.init(url: selected, message: "Permission denied"))
                continue
            }
            selectionLeases[selected] = didStart
                ? SecurityScopedResourceLease { [bookmarkResolver] in bookmarkResolver.stopAccessing(selected) }
                : .none

            // Single audio files become first-class file sources so they show
            // up in the source list and can be monitored and removed.
            guard isDirectory || AudioFormatSupport.importableExtensions.contains(selected.pathExtension.lowercased()) else { continue }
            readableSelectionPaths.insert(canonical)
            if !isDirectory,
               directoryRootPaths.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) {
                // Already managed by a directory source; no separate file
                // source is created for it.
                continue
            }
            do {
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
                    mode: isDirectory ? .directory : .file,
                    rootBookmarkData: bookmark,
                    lastKnownPath: selected.path,
                    displayName: selected.lastPathComponent
                )
                try await sourceStore.save(descriptor)
                existingByCanonicalPath[canonical] = descriptor
                if isDirectory {
                    directoryRootPaths.append(canonical)
                    directorySourceRoots[canonical] = (selected, id)
                } else {
                    batchCreatedFileSources.append((id: id, path: canonical))
                }
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
            readableSelectionPaths.contains(canonicalPath(selected))
        }
        let scanned = await ImportInputScanner.scan(
            selectedURLs: readableSelections,
            directorySources: sourceIDs
        )
        let plan = ImportInputPlan(
            files: scanned.files,
            directorySources: sources,
            failures: failures + scanned.failures
        )
        lastPreparedInputPlan = plan
        return plan
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func pruneUnimportedFileSources(importedURLs: Set<String>, importedSourceIDs: Set<UUID>) async {
        guard !batchCreatedFileSources.isEmpty else { return }
        let created = batchCreatedFileSources
        batchCreatedFileSources = []
        var removedIDs = Set<UUID>()
        for entry in created where !importedURLs.contains(entry.path) && !importedSourceIDs.contains(entry.id) {
            do {
                try await sourceStore.remove(id: entry.id)
                sourceScope.remove(sourceID: entry.id)
                removedIDs.insert(entry.id)
            } catch {
                Log.warning(
                    "[ReferencedSource] failed to prune unimported file source \(entry.id): \(error)",
                    category: .library
                )
            }
        }
        guard !removedIDs.isEmpty, let plan = lastPreparedInputPlan else { return }
        lastPreparedInputPlan = ImportInputPlan(
            files: plan.files,
            directorySources: plan.directorySources.filter { !removedIDs.contains($0.source.id) },
            failures: plan.failures
        )
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

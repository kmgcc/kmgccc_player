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
    private let playlistMembershipStore: ReferencedPlaylistMembershipStore
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
        playlistMembershipStore: ReferencedPlaylistMembershipStore? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false
    ) {
        self.paths = paths
        self.sourceStore = sourceStore
        self.sourceScope = sourceScope
        self.playlistMembershipStore = playlistMembershipStore
            ?? ReferencedPlaylistMembershipStore(paths: paths)
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
        // Session-start authorization can legitimately fail (source volume
        // not yet mounted, transient denial, stale refresh) and nothing else
        // retries it within the session. Re-arm persisted directory sources
        // before the selection loop so folder inheritance and NCM
        // parent-directory checks see them; failures are non-fatal because
        // the loop below keeps its per-file fallbacks. File sources are
        // skipped: they never cover other files, so re-arming them would
        // only mass-start access.
        let hydrationIssues = await sourceScope.authorizeMissing(
            descriptors: existingDescriptors.filter { $0.mode == .directory },
            store: sourceStore,
            bookmarkResolver: bookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        if !hydrationIssues.isEmpty {
            Log.warning(
                "[ReferencedSource] deferred directory authorization retried, unavailable count=\(hydrationIssues.count)",
                category: .library
            )
        }
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

            // A file chosen from an already-known directory source must
            // inherit that source. Starting access on the child file can
            // fail even while the folder is readable, and it also loses the
            // source membership needed by automatic/NCM imports. Inheritance
            // is coverage-based rather than authorization-based: if the
            // scope root is still missing (hydration failed above), the
            // scanner's own readability checks decide the outcome instead of
            // per-file access attempts.
            if !isDirectory,
               let covered = directorySourceRoots
                   .filter({ path, _ in canonical == path || canonical.hasPrefix(path + "/") })
                   .max(by: { lhs, rhs in lhs.key.count < rhs.key.count }) {
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

    func bindSourcesToPlaylist(
        _ sourceIDs: Set<UUID>,
        playlistID: UUID
    ) async throws -> [UUID: UUID] {
        try await ensureSourcePlaylistBindings(
            sourceIDs,
            playlistID: playlistID
        ).bindingsBySourceID
    }

    private func ensureSourcePlaylistBindings(
        _ sourceIDs: Set<UUID>,
        playlistID: UUID
    ) async throws -> (
        bindingsBySourceID: [UUID: UUID],
        createdBindings: [(sourceID: UUID, bindingID: UUID)]
    ) {
        var result: [UUID: UUID] = [:]
        var newlyCreatedBindings: [(sourceID: UUID, bindingID: UUID)] = []
        do {
            for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let ensured = try await sourceStore.ensurePlaylistBindingWithCreation(
                    sourceID: sourceID,
                    playlistID: playlistID
                )
                if ensured.didCreate {
                    newlyCreatedBindings.append((sourceID, ensured.binding.id))
                }
                result[sourceID] = ensured.binding.id
            }
            return (result, newlyCreatedBindings)
        } catch {
            for created in newlyCreatedBindings.reversed() {
                do {
                    try await sourceStore.removePlaylistBinding(
                        sourceID: created.sourceID,
                        bindingID: created.bindingID
                    )
                } catch {
                    Log.error(
                        "[ReferencedBackend] failed to roll back playlist binding source=\(created.sourceID.uuidString) binding=\(created.bindingID.uuidString): \(error.localizedDescription)",
                        category: .library
                    )
                }
            }
            throw error
        }
    }

    func recordSourceMemberships(_ tracks: [Track], playlistID: UUID) async {
        for track in tracks {
            guard case let .referenced(locator) = track.mediaLocator else { continue }
            for sourceID in Set(locator.allSourceMemberships.map(\.sourceID)) {
                guard let bindings = try? await sourceStore.bindings(for: sourceID) else { continue }
                let bindingIDs = bindings
                    .filter { $0.playlistID == playlistID }
                    .map(\.id)
                guard !bindingIDs.isEmpty else { continue }
                do {
                    try await playlistMembershipStore.recordSourceContribution(
                        playlistID: playlistID,
                        trackID: track.id,
                        bindingIDs: bindingIDs
                    )
                } catch {
                    Log.warning(
                        "[ReferencedLocalBackend] failed to persist playlist source membership: \(error)",
                        category: .library
                    )
                }
            }
        }
    }

    func commitPlaylistImportSourceEffects(
        tracks: [Track],
        sourceIDs: Set<UUID>,
        playlistID: UUID
    ) async throws {
        let bindingTransaction = try await ensureSourcePlaylistBindings(
            sourceIDs,
            playlistID: playlistID
        )
        let bindingsBySourceID = bindingTransaction.bindingsBySourceID

        do {
            var entries: [(playlistID: UUID, trackID: UUID, bindingID: UUID)] = []
            for track in tracks {
                guard case let .referenced(locator) = track.mediaLocator else { continue }
                for sourceID in Set(locator.allSourceMemberships.map(\.sourceID)) {
                    guard let bindingID = bindingsBySourceID[sourceID] else { continue }
                    entries.append((playlistID, track.id, bindingID))
                }
            }
            try await playlistMembershipStore.recordSourceContributions(entries)
        } catch {
            for created in bindingTransaction.createdBindings.reversed() {
                do {
                    try await sourceStore.removePlaylistBinding(
                        sourceID: created.sourceID,
                        bindingID: created.bindingID
                    )
                } catch {
                    Log.error(
                        "[ReferencedBackend] failed to roll back import binding source=\(created.sourceID.uuidString) binding=\(created.bindingID.uuidString): \(error.localizedDescription)",
                        category: .library
                    )
                }
            }
            throw error
        }
    }

    func recordManualPlaylistAddition(playlistID: UUID, trackIDs: [UUID]) async {
        do {
            try await playlistMembershipStore.recordManualAddition(
                playlistID: playlistID,
                trackIDs: trackIDs
            )
        } catch {
            Log.warning(
                "[ReferencedLocalBackend] failed to persist manual playlist addition: \(error)",
                category: .library
            )
        }
    }

    func recordManualPlaylistRemoval(playlistID: UUID, trackIDs: [UUID]) async {
        do {
            let bindingIDs = try await sourceStore.allBindings()
                .filter { $0.binding.playlistID == playlistID }
                .map { $0.binding.id }
            try await playlistMembershipStore.recordManualRemoval(
                playlistID: playlistID,
                trackIDs: trackIDs,
                bindingIDs: bindingIDs
            )
        } catch {
            Log.warning(
                "[ReferencedLocalBackend] failed to persist manual playlist removal: \(error)",
                category: .library
            )
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

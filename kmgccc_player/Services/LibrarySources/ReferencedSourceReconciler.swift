import Foundation

nonisolated enum ReferencedSourceReconcileError: Error, Equatable {
    case authorityCommitFailed([UUID])
    case invalidReconnectIntent
    case reconnectAuthorizationFailed(UUID)
}

/// What a reconcile actually changed in runtime/repository state.
///
/// File-monitor callbacks use this to decide whether the UI needs to pull a
/// fresh library snapshot: an empty-diff rescan (the common case for periodic
/// and FS-event-triggered scans) previously triggered a full
/// `reloadLibrary()` on every debounce, which dominated interaction latency
/// on large referenced libraries.
nonisolated struct ReferencedReconcileChanges: Sendable, Equatable {
    var importedFiles = 0
    var committedTrackMutations = 0
    var appliedRuntimeMutations = 0
    var playlistMembershipChanges = 0

    var isEmpty: Bool {
        importedFiles == 0
            && committedTrackMutations == 0
            && appliedRuntimeMutations == 0
            && playlistMembershipChanges == 0
    }

    static func += (lhs: inout ReferencedReconcileChanges, rhs: ReferencedReconcileChanges) {
        lhs.importedFiles += rhs.importedFiles
        lhs.committedTrackMutations += rhs.committedTrackMutations
        lhs.appliedRuntimeMutations += rhs.appliedRuntimeMutations
        lhs.playlistMembershipChanges += rhs.playlistMembershipChanges
    }
}

/// Outcome of a best-effort multi-source reconcile pass.
nonisolated struct ReferencedSourceReconcileOutcome: Sendable, Equatable {
    var failedSourceIDs: Set<UUID>
    var changes: ReferencedReconcileChanges
}

nonisolated enum ReferencedSourceNotice: Sendable, Equatable {
    case filesImported(sourceID: UUID, count: Int)
    case unavailable(sourceID: UUID, status: ReferencedSourceStatus)
    case fileFailures(sourceID: UUID, failures: [ReferencedSourceScanFailure])
    case scanFailures(sourceID: UUID, failures: [ReferencedSourceScanFailure])
    case reconcileFailures(sourceID: UUID, failures: [ReferencedSourceScanFailure])
    case monitorFailure(sourceIDs: [UUID], summary: String)
}

nonisolated protocol ReferencedSourceNoticePublishing: Sendable {
    func publish(_ notice: ReferencedSourceNotice) async
}

actor LogReferencedSourceNoticePublisher: ReferencedSourceNoticePublishing {
    func publish(_ notice: ReferencedSourceNotice) {
        Log.warning("[ReferencedSource] notice=\(String(describing: notice))", category: .library)
    }
}

/// Bridges source-monitor notices into the main-actor UI without making the
/// reconciler depend on a view model. The actor keeps the publisher Sendable;
/// the closure hops to the main actor only when a notice is delivered.
actor SidebarReferencedSourceNoticePublisher: ReferencedSourceNoticePublishing {
    private let handler: @MainActor @Sendable (ReferencedSourceNotice) -> Void

    init(handler: @escaping @MainActor @Sendable (ReferencedSourceNotice) -> Void) {
        self.handler = handler
    }

    func publish(_ notice: ReferencedSourceNotice) async {
        await handler(notice)
    }
}

@MainActor
protocol AutomaticReferencedFileImporting: AnyObject {
    func importAutomatically(_ urls: [URL]) async -> [Track]
}

extension FileImportService: AutomaticReferencedFileImporting {}

@MainActor
final class ReferencedSourceReconciler {
    private let context: LibraryContext
    private let repository: any LibraryRepositoryProtocol
    private let importer: any AutomaticReferencedFileImporting
    private let mutationCoordinator: LibraryMutationCoordinator?
    private let sourceStore: ReferencedSourceStore
    private let sourceScope: ReferencedSourceScope
    private let scanner: ReferencedSourceScanner
    private let ignoredItemsStore: IgnoredReferencedItemsStore
    private let ncmRegistry: NCMConversionRegistry
    private let manifestStore: ReferencedSourceScanManifestStore
    private let intentStore: LibraryReconcileIntentStore
    private let playlistMembershipStore: ReferencedPlaylistMembershipStore
    private let bookmarkResolver: any BookmarkResolving
    private let noticePublisher: any ReferencedSourceNoticePublishing
    private let requiresSecurityScope: Bool
    private var isClosed = false

    init(
        context: LibraryContext,
        repository: any LibraryRepositoryProtocol,
        importer: any AutomaticReferencedFileImporting,
        mutationCoordinator: LibraryMutationCoordinator? = nil,
        sourceStore: ReferencedSourceStore,
        sourceScope: ReferencedSourceScope,
        scanner: ReferencedSourceScanner,
        ignoredItemsStore: IgnoredReferencedItemsStore? = nil,
        ncmRegistry: NCMConversionRegistry? = nil,
        playlistMembershipStore: ReferencedPlaylistMembershipStore? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false,
        noticePublisher: any ReferencedSourceNoticePublishing = LogReferencedSourceNoticePublisher()
    ) {
        precondition(context.mode == .referenced)
        self.context = context
        self.repository = repository
        self.importer = importer
        self.mutationCoordinator = mutationCoordinator
        self.sourceStore = sourceStore
        self.sourceScope = sourceScope
        self.scanner = scanner
        self.ignoredItemsStore = ignoredItemsStore ?? IgnoredReferencedItemsStore(paths: context.paths)
        self.ncmRegistry = ncmRegistry ?? NCMConversionRegistry(paths: context.paths)
        manifestStore = ReferencedSourceScanManifestStore(paths: context.paths)
        intentStore = LibraryReconcileIntentStore(paths: context.paths)
        self.playlistMembershipStore = playlistMembershipStore
            ?? ReferencedPlaylistMembershipStore(paths: context.paths)
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
        self.noticePublisher = noticePublisher
    }

    var sourceRoots: [UUID: URL] {
        sourceScope.authorizedRoots.mapValues(\.url)
    }

    func allSourceIDs() async throws -> Set<UUID> {
        Set(try await sourceStore.loadAll().map(\.id))
    }

    /// Creates and binds one playlist per selected directory source. The
    /// binding is persisted on the source descriptor so later reconciles keep
    /// the playlist synchronized with the source rather than treating it as a
    /// one-time import snapshot.
    func createPlaylistsForSources(_ sourceIDs: [UUID]) async throws {
        let orderedSourceIDs = Set(sourceIDs).sorted { $0.uuidString < $1.uuidString }
        try await runShortMutation(
            kind: .sourceReconcileCommit,
            targetIDs: orderedSourceIDs.map(\.uuidString)
        ) {
            for sourceID in orderedSourceIDs {
                try await self.syncBoundPlaylists(sourceID: sourceID, createIfMissing: true)
            }
        }
    }

    /// Adds explicit source-to-playlist edges for a playlist that already
    /// exists (for example the setup wizard's “selected files” grouping).
    /// Directory sources and single-file sources use the same edge model.
    func bindSourcesToPlaylist(_ sourceIDs: Set<UUID>, playlistID: UUID) async throws {
        let orderedSourceIDs = sourceIDs.sorted { $0.uuidString < $1.uuidString }
        try await runShortMutation(
            kind: .sourceReconcileCommit,
            targetIDs: orderedSourceIDs.map(\.uuidString) + [playlistID.uuidString]
        ) {
            var createdBindings: [(sourceID: UUID, bindingID: UUID)] = []
            do {
                for sourceID in orderedSourceIDs {
                    let ensured = try await self.sourceStore.ensurePlaylistBindingWithCreation(
                        sourceID: sourceID,
                        playlistID: playlistID
                    )
                    if ensured.didCreate {
                        createdBindings.append((sourceID: sourceID, bindingID: ensured.binding.id))
                    }
                    _ = try await self.syncBoundPlaylists(sourceID: sourceID, createIfMissing: false)
                }
            } catch {
                for created in createdBindings.reversed() {
                    do {
                        try await self.sourceStore.removePlaylistBinding(
                            sourceID: created.sourceID,
                            bindingID: created.bindingID
                        )
                    } catch {
                        Log.error(
                            "[ReferencedSource] failed to roll back binding \(created.bindingID): \(error.localizedDescription)",
                            category: .library
                        )
                    }
                }
                throw error
            }
        }
    }

    /// Removes one source-to-playlist edge while preserving both the external
    /// source and the library tracks. Only playlist items whose last live
    /// ownership was this edge are removed from that playlist; a manual item,
    /// or an item contributed by another binding, remains visible.
    @discardableResult
    func unbindSourceFromPlaylist(sourceID: UUID, bindingID: UUID) async throws -> Int {
        try await runShortMutation(
            kind: .sourceReconcileCommit,
            targetIDs: [sourceID.uuidString, bindingID.uuidString]
        ) {
            try await self.unbindSourceFromPlaylistUncoordinated(
                sourceID: sourceID,
                bindingID: bindingID
            )
        }
    }

    private func unbindSourceFromPlaylistUncoordinated(
        sourceID: UUID,
        bindingID: UUID
    ) async throws -> Int {
        guard !isClosed, await sourceStore.contains(id: sourceID) else { return 0 }

        // Seed the durable membership sidecar before removing the edge. This
        // keeps old libraries (which only had playlistManagedTrackIDs) from
        // losing their manual/source distinction during the first unbind.
        _ = try await syncBoundPlaylists(sourceID: sourceID, createIfMissing: false)
        let descriptor = try await sourceStore.load(id: sourceID)
        guard let binding = descriptor.playlistBindings.first(where: { $0.id == bindingID }) else {
            return 0
        }

        let playlist = (await repository.fetchPlaylists()).first { $0.id == binding.playlistID }
        let membershipSnapshot = try await playlistMembershipStore.snapshot()
        let memberships = try await playlistMembershipStore.memberships(for: binding.playlistID)
        let tracksByID = Dictionary(
            uniqueKeysWithValues: await repository.fetchTracks(in: nil).map { ($0.id, $0) }
        )
        let originalPlaylistTracks = playlist?.tracks
        let originalPlaylistItemAddedAt = await repository.fetchPlaylistItemAddedAtMap()[binding.playlistID] ?? [:]
        let playlistTrackIDs = Set(playlist?.tracks.map(\.id) ?? [])
        var tracksToRemove: [Track] = []

        do {
            for membership in memberships where membership.sourceBindingIDs.contains(bindingID) {
                try await playlistMembershipStore.removeSourceContribution(
                    playlistID: binding.playlistID,
                    trackID: membership.trackID,
                    bindingID: bindingID
                )
                let remainsLive = try await playlistMembershipStore.membership(
                    playlistID: binding.playlistID,
                    trackID: membership.trackID
                )?.isLive == true
                if !remainsLive,
                   playlistTrackIDs.contains(membership.trackID),
                   let track = tracksByID[membership.trackID] {
                    tracksToRemove.append(track)
                }
            }

            if let playlist, !tracksToRemove.isEmpty {
                try await repository.removeTracks(tracksToRemove, from: playlist)
            }
            try await sourceStore.removePlaylistBinding(sourceID: sourceID, bindingID: bindingID)
        } catch {
            do {
                try await playlistMembershipStore.restore(membershipSnapshot)
            } catch {
                Log.error(
                    "[ReferencedSource] failed to restore memberships after unbind failure: \(error.localizedDescription)",
                    category: .library
                )
            }
            if let playlist, let originalPlaylistTracks {
                do {
                    try await repository.replacePlaylistTracks(
                        originalPlaylistTracks,
                        in: playlist,
                        itemAddedAt: originalPlaylistItemAddedAt
                    )
                } catch {
                    Log.error(
                        "[ReferencedSource] failed to restore playlist after unbind failure: \(error.localizedDescription)",
                        category: .library
                    )
                }
            }
            throw error
        }
        return tracksToRemove.count
    }

    @discardableResult
    func refreshSources() async throws -> [ReferencedSourceScopeIssue] {
        let descriptors = try await sourceStore.loadAll()
        let issues = await sourceScope.start(
            descriptors: descriptors,
            store: sourceStore,
            bookmarkResolver: bookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        _ = await reconcileBestEffort(sourceIDs: Set(descriptors.map(\.id)))
        return issues
    }

    /// Reauthorizes and reconciles one source. This is the operation exposed
    /// by a source row's “重新扫描” action; it must not restart or rescan
    /// unrelated folders in the same referenced library.
    @discardableResult
    func refreshSource(_ sourceID: UUID) async throws -> [ReferencedSourceScopeIssue] {
        guard !isClosed, await sourceStore.contains(id: sourceID) else { return [] }
        let descriptor = try await sourceStore.load(id: sourceID)
        // Reauthorization may update the source status/bookmark, so keep the
        // durable part under the short mutation owner. The scan itself is a
        // long operation and must not hold the mutation queue while reading a
        // large folder or importing discovered files.
        var issues: [ReferencedSourceScopeIssue] = []
        try await runShortMutation(
            kind: .sourceReconcileCommit,
            targetIDs: [sourceID.uuidString]
        ) {
            issues = await self.sourceScope.refresh(
                descriptors: [descriptor],
                store: self.sourceStore,
                bookmarkResolver: self.bookmarkResolver,
                requiresSecurityScope: self.requiresSecurityScope
            )
        }
        _ = try await reconcile(sourceIDs: [sourceID])
        return issues
    }

    /// Updates a source-level directory exclusion and immediately reconciles
    /// that source. The scanner owns the filter; the reconciler still owns
    /// Track/source authority and playlist membership, so an exclusion cannot
    /// silently mutate only one projection.
    func setExcludedRelativePath(
        sourceID: UUID,
        relativePath: String,
        excluded: Bool
    ) async throws {
        guard !isClosed, await sourceStore.contains(id: sourceID) else { return }
        try await runShortMutation(kind: .sourceReconcileCommit, targetIDs: [sourceID.uuidString]) {
            _ = try await self.sourceStore.setExcludedRelativePath(
                sourceID: sourceID,
                relativePath: relativePath,
                excluded: excluded
            )
        }
        _ = try await reconcile(sourceIDs: [sourceID])
    }

    /// Repairs tracks whose memberships reference a source descriptor that
    /// no longer exists on disk (for example a batch file source pruned
    /// after an NCM conversion, or a crash before descriptor persistence).
    /// Only primary memberships can be mapped to a concrete file: when the
    /// file still exists, a file-mode descriptor is recreated with the
    /// original sourceID and the membership is normalized to the
    /// file-source layout; when the file is gone, the orphaned membership
    /// is stripped so the track settles as missing.
    @discardableResult
    func repairOrphanedFileSources() async throws -> Int {
        // The identity scan and bookmark resolution can touch every track.
        // Keep that long read outside the mutation queue; only each durable
        // descriptor/authority commit below enters the short owner.
        try await repairOrphanedFileSourcesUncoordinated()
    }

    private func repairOrphanedFileSourcesUncoordinated() async throws -> Int {
        guard !isClosed else { return 0 }
        let knownIDs = Set(try await sourceStore.loadAll().map(\.id))
        let tracks = await repository.fetchTracks(in: nil)
        var mutations: [ReferencedSourceLocatorMutation] = []
        var created = 0
        var persistedSourceIDs = Set<UUID>()
        for track in tracks {
            guard case var .referenced(locator) = track.mediaLocator else { continue }
            let orphans = locator.allSourceMemberships.filter { !knownIDs.contains($0.sourceID) }
            guard !orphans.isEmpty else { continue }
            var locatorChanged = false
            for orphan in orphans {
                guard let location = locator.locations.first(where: {
                    $0.sourceMemberships.contains { $0.sourceID == orphan.sourceID }
                }) else { continue }
                let fileURL = URL(fileURLWithPath: location.lastKnownPath)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    // The source record is lost and the file is gone:
                    // settle as missing.
                    locator.removeSourcePreservingRecovery(orphan.sourceID)
                    locatorChanged = true
                    continue
                }
                guard let bookmark = try? bookmarkResolver.refreshBookmark(for: fileURL) else {
                    // The file exists but authorization is temporarily
                    // unavailable — never destroy memberships on a
                    // transient failure.
                    Log.warning(
                        "[ReferencedSource] orphan repair deferred (bookmark failed) track=\(track.id)",
                        category: .library
                    )
                    continue
                }
                let descriptor = ReferencedSourceDescriptor(
                    id: orphan.sourceID,
                    mode: .file,
                    rootBookmarkData: bookmark,
                    lastKnownPath: fileURL.path,
                    displayName: fileURL.lastPathComponent
                )
                if persistedSourceIDs.insert(descriptor.id).inserted {
                    try await runShortMutation(
                        kind: .sourceReconcileCommit,
                        targetIDs: [descriptor.id.uuidString]
                    ) {
                        try await self.sourceStore.save(descriptor)
                    }
                    created += 1
                }
                locator.refreshLocation(
                    for: orphan.sourceID,
                    fileBookmarkData: bookmark,
                    lastKnownPath: fileURL.path,
                    fingerprint: location.fingerprint
                )
                locator.setSourceMembership(.init(
                    sourceID: orphan.sourceID,
                    relativePath: fileURL.lastPathComponent
                ))
                locatorChanged = true
            }
            guard locatorChanged else { continue }
            locator.primarySourceID = primarySourceID(locator.sourceMemberships)
            mutations.append(.init(
                trackID: track.id,
                locator: locator,
                availability: locator.allSourceMemberships.isEmpty ? .missing : track.availability
            ))
        }

        if created > 0 {
            // Re-arm the scope before committing track locators. If a later
            // sidecar write fails, the recreated descriptors are still
            // reachable by the normal source scan and can converge on retry.
            let descriptors = try await sourceStore.loadAll()
            _ = await sourceScope.start(
                descriptors: descriptors,
                store: sourceStore,
                bookmarkResolver: bookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
        }
        if !mutations.isEmpty {
            let result = try await runShortMutation(
                kind: .sourceReconcileCommit,
                targetIDs: mutations.map { $0.trackID.uuidString }
            ) {
                await self.repository.commitReferencedSourceMutations(mutations)
            }
            guard result.failedTrackIDs.isEmpty else {
                Log.error(
                    "[ReferencedSource] orphan repair authority commit failed tracks=\(result.failedTrackIDs)",
                    category: .library
                )
                throw ReferencedSourceReconcileError.authorityCommitFailed(result.failedTrackIDs)
            }
            Log.warning(
                "[ReferencedSource] repaired orphaned memberships tracks=\(mutations.count) recreatedSources=\(created)",
                category: .library
            )
        }
        return created
    }

    @discardableResult
    func replayPending(sourceID: UUID? = nil) async throws -> ReferencedReconcileChanges {
        var changes = ReferencedReconcileChanges()
        guard !isClosed else { return changes }
        for intent in try await intentStore.pending(libraryID: context.id, sourceID: sourceID) {
            try validate(intent)
            try await restoreReconnectAuthorizationIfNeeded(intent)
            switch intent.state {
            case .prepared:
                changes += try await drivePrepared(intent)
            case .sidecarsCommitted:
                changes.appliedRuntimeMutations += intent.mutations.count
                await repository.attachReferencedSourceMutations(intent.mutations)
                let applied = try await intentStore.advance(intent, to: .runtimeApplied)
                changes.playlistMembershipChanges += try await finalize(applied)
            case .runtimeApplied:
                changes.playlistMembershipChanges += try await finalize(intent)
            }
        }
        return changes
    }

    @discardableResult
    func reconcile(sourceIDs: Set<UUID>) async throws -> ReferencedReconcileChanges {
        var changes = ReferencedReconcileChanges()
        guard !isClosed else { return changes }
        for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !isClosed else { return changes }
            changes += try await replayPending(sourceID: sourceID)
            guard try await intentStore.pending(libraryID: context.id, sourceID: sourceID).isEmpty else {
                continue
            }
            guard await sourceStore.contains(id: sourceID) else { continue }
            let descriptor = try await sourceStore.load(id: sourceID)
            guard let root = sourceScope.authorizedRoots[sourceID]?.url else {
                let status: ReferencedSourceStatus = descriptor.status == .permissionDenied
                    ? .permissionDenied
                    : .offline
                changes += try await applyUnavailable(sourceID: sourceID, status: status)
                continue
            }
            var effectiveRoot = root
            var result = try await scanner.scan(
                context: context,
                sourceID: sourceID,
                rootURL: root,
                excludedRelativePaths: Set(descriptor.excludedRelativePaths)
            )
            if result.diff.sourceStatus != .available {
                // The authorized URL is path-stale after a rename/move while
                // the app was running; the bookmark still follows the inode.
                // Re-resolve authorization for THIS source only (refresh,
                // not start — start would drop every other source's root)
                // before declaring the source unavailable.
                let issues = await sourceScope.refresh(
                    descriptors: [descriptor],
                    store: sourceStore,
                    bookmarkResolver: bookmarkResolver,
                    requiresSecurityScope: requiresSecurityScope
                )
                if issues.isEmpty,
                   let refreshedRoot = sourceScope.authorizedRoots[sourceID]?.url,
                   refreshedRoot != root {
                    effectiveRoot = refreshedRoot
                    result = try await scanner.scan(
                        context: context,
                        sourceID: sourceID,
                        rootURL: refreshedRoot,
                        excludedRelativePaths: Set(descriptor.excludedRelativePaths)
                    )
                }
            }
            changes += try await apply(result, rootURL: effectiveRoot)
        }
        return changes
    }

    /// Reconcile each source independently. One broken or temporarily
    /// unavailable folder must not prevent the remaining folders from being
    /// imported or their playlists from being synchronized.
    @discardableResult
    func reconcileBestEffort(sourceIDs: Set<UUID>) async -> ReferencedSourceReconcileOutcome {
        var failed = Set<UUID>()
        var changes = ReferencedReconcileChanges()
        for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                changes += try await reconcile(sourceIDs: [sourceID])
            } catch is CancellationError {
                // A refresh, session switch, or shutdown can intentionally
                // cancel the in-flight scan. It is not a source failure and
                // must not turn into a sidebar error notice or failed state.
                break
            } catch {
                failed.insert(sourceID)
                await reportMonitorFailure(sourceIDs: [sourceID], error: error)
            }
        }
        return ReferencedSourceReconcileOutcome(failedSourceIDs: failed, changes: changes)
    }

    func removeSource(_ sourceID: UUID) async throws {
        guard !isClosed else { return }
        let tracks = await repository.fetchTracks(in: nil)
        var mutations: [ReferencedSourceLocatorMutation] = []
        for track in tracks {
            guard case var .referenced(locator) = track.mediaLocator,
                  locator.containsSource(sourceID) else { continue }
            locator.removeSourcePreservingRecovery(sourceID)
            locator.primarySourceID = primarySourceID(locator.sourceMemberships)
            let availability: TrackAvailability = locator.allSourceMemberships.isEmpty ? .missing : track.availability
            mutations.append(.init(trackID: track.id, locator: locator, availability: availability))
        }
        let diff = ReferencedSourceDiff(
            libraryID: context.id,
            libraryGeneration: context.generation,
            sourceID: sourceID,
            scanGeneration: 0,
            sourceStatus: .available
        )
        let intent = try await intentStore.prepare(
            diff,
            mutations: mutations,
            operation: .sourceRemoval
        )
        try await drivePrepared(intent)
    }

    func reconnectSource(
        descriptor: ReferencedSourceDescriptor,
        rootURL: URL,
        lease: SecurityScopedResourceLease,
        mutations: [ReferencedSourceLocatorMutation],
        proposedManifest: ReferencedSourceScanManifest
    ) async throws {
        guard !isClosed,
              descriptor.id == proposedManifest.sourceID,
              proposedManifest.libraryID == context.id else {
            lease.release()
            throw ReferencedSourceReconcileError.invalidReconnectIntent
        }
        let diff = ReferencedSourceDiff(
            libraryID: context.id,
            libraryGeneration: context.generation,
            sourceID: descriptor.id,
            scanGeneration: proposedManifest.generation,
            sourceStatus: .available
        )
        let intent: LibraryReconcileIntent
        do {
            intent = try await intentStore.prepare(
                diff,
                mutations: mutations,
                proposedManifest: proposedManifest,
                proposedSourceDescriptor: descriptor,
                operation: .sourceReconnect
            )
        } catch {
            lease.release()
            throw error
        }
        sourceScope.add(sourceID: descriptor.id, url: rootURL, lease: lease)
        try await drivePrepared(intent, rootURL: rootURL)
    }

    func reportMonitorFailure(sourceIDs: Set<UUID>, error: Error) async {
        let summary = String(String(describing: error).prefix(512))
        Log.error("[ReferencedSource] monitor reconcile failed sources=\(sourceIDs.count) error=\(summary)", category: .library)
        await noticePublisher.publish(.monitorFailure(
            sourceIDs: sourceIDs.sorted { $0.uuidString < $1.uuidString },
            summary: summary
        ))
    }

    func close() { isClosed = true }

    private func runShortMutation<Value: Sendable>(
        kind: LibraryMutationKind,
        targetIDs: [String] = [],
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        if let mutationCoordinator {
            return try await mutationCoordinator.run(
                kind: kind,
                targetIDs: targetIDs,
                work
            )
        }
        return try await work()
    }

    @discardableResult
    private func apply(_ result: ReferencedSourceScanResult, rootURL: URL) async throws -> ReferencedReconcileChanges {
        let diff = result.diff
        guard diff.sourceStatus == .available else {
            return try await applyUnavailable(sourceID: diff.sourceID, status: diff.sourceStatus)
        }
        let intent = try await intentStore.prepare(
            diff,
            proposedManifest: result.proposedManifest
        )
        return try await drivePrepared(intent, rootURL: rootURL)
    }

    @discardableResult
    private func drivePrepared(
        _ original: LibraryReconcileIntent,
        rootURL explicitRootURL: URL? = nil
    ) async throws -> ReferencedReconcileChanges {
        var changes = ReferencedReconcileChanges()
        var intent = original
        if intent.operation == .reconcile,
           intent.diff.sourceStatus == .available,
           intent.mutations.isEmpty || intent.proposedManifest?.entries.contains(where: { $0.trackID == nil }) == true {
            guard let rootURL = explicitRootURL ?? sourceScope.authorizedRoots[intent.sourceID]?.url else { return changes }
            let isFileRoot = rootIsFile(rootURL)
            let imported = intent.diff.added.isEmpty
                ? []
                : await importer.importAutomatically(intent.diff.added.map {
                    url(forRelativePath: $0.relativePath, root: rootURL, rootIsFile: isFileRoot)
                })
            changes.importedFiles += imported.count
            guard !isClosed else { return changes }
            let firstScanPresentPaths: Set<String>? = (
                intent.operation == .reconcile
                    && intent.diff.scanGeneration == 1
                    && intent.diff.failures.isEmpty
            )
                ? Set(intent.proposedManifest?.entries.map(\.relativePath) ?? [])
                : nil
            let mutations = await makeMutations(
                diff: intent.diff,
                rootURL: rootURL,
                importedTracks: imported,
                firstScanPresentPaths: firstScanPresentPaths
            )
            intent = try await intentStore.updateMutations(intent, mutations: mutations)
            let tracks = await repository.fetchTracks(in: nil)
            let physicalTrackIDs = physicalTrackIDMap(tracks)
            let ncmSourceTrackIDs = ncmSourceTrackIDMap(tracks)
            let unresolvedAdded = intent.diff.added.filter { added in
                physicalTrackIDs[ReferencedPhysicalIdentityKey(added.fingerprint)] == nil
                    && added.fingerprint.identity.flatMap({ ncmSourceTrackIDs[$0] }) == nil
            }
            if !unresolvedAdded.isEmpty {
                await noticePublisher.publish(.fileFailures(
                    sourceID: intent.sourceID,
                    failures: unresolvedAdded.map {
                        ReferencedSourceScanFailure(
                            relativePath: $0.relativePath,
                            summary: "未能导入"
                        )
                    }
                ))
            }
            if var manifest = intent.proposedManifest {
                for index in manifest.entries.indices {
                    let entry = manifest.entries[index]
                    manifest.entries[index].trackID = physicalTrackIDs[ReferencedPhysicalIdentityKey(entry.fingerprint)]
                        ?? entry.fingerprint.identity.flatMap { ncmSourceTrackIDs[$0] }
                        ?? entry.trackID
                }
                intent = try await intentStore.updateManifest(intent, manifest: manifest)
            }
        }

        let targetIDs = intent.affectedTrackIDs.map(\.uuidString)
        if let mutationCoordinator {
            return try await mutationCoordinator.run(
                kind: .sourceReconcileCommit,
                targetIDs: targetIDs
            ) {
                try await self.commitPrepared(intent, accumulating: changes)
            }
        }
        return try await commitPrepared(intent, accumulating: changes)
    }

    private func commitPrepared(
        _ original: LibraryReconcileIntent,
        accumulating initialChanges: ReferencedReconcileChanges
    ) async throws -> ReferencedReconcileChanges {
        var changes = initialChanges
        var intent = original
        let alreadyCommitted = Set(intent.committedTrackIDs)
        let pending = intent.mutations.filter { !alreadyCommitted.contains($0.trackID) }
        if !pending.isEmpty {
            let result = await repository.commitReferencedSourceMutations(pending)
            changes.committedTrackMutations += result.persistedTrackIDs.count
            intent = try await intentStore.recordAuthorityCommits(intent, trackIDs: result.persistedTrackIDs)
            if !result.failedTrackIDs.isEmpty {
                let failedIDs = Set(result.failedTrackIDs)
                let failures = pending
                    .filter { failedIDs.contains($0.trackID) }
                    .map { mutation in
                        ReferencedSourceScanFailure(
                            relativePath: mutation.locator.allSourceMemberships.first {
                                $0.sourceID == intent.sourceID
                            }?.relativePath,
                            summary: "资料库信息保存失败"
                        )
                    }
                await noticePublisher.publish(.reconcileFailures(
                    sourceID: intent.sourceID,
                    failures: failures.isEmpty
                        ? result.failedTrackIDs.map { _ in
                            ReferencedSourceScanFailure(
                                relativePath: nil,
                                summary: "资料库信息保存失败"
                            )
                        }
                        : failures
                ))
                throw ReferencedSourceReconcileError.authorityCommitFailed(result.failedTrackIDs)
            }
        }
        guard Set(intent.committedTrackIDs) == Set(intent.mutations.map(\.trackID)) else { return changes }
        intent = try await intentStore.advance(intent, to: .sidecarsCommitted)
        // `attachReferencedSourceMutations(_:)` no-ops on an empty array; only
        // count it as a change when there is something to apply.
        changes.appliedRuntimeMutations += intent.mutations.count
        await repository.attachReferencedSourceMutations(intent.mutations)
        intent = try await intentStore.advance(intent, to: .runtimeApplied)
        changes.playlistMembershipChanges += try await finalize(intent)
        return changes
    }

    /// Returns the number of bound-playlist membership changes made while
    /// finalizing, so callers can tell real state changes from no-op scans.
    private func finalize(_ intent: LibraryReconcileIntent) async throws -> Int {
        var playlistMembershipChanges = 0
        switch intent.operation {
        case .reconcile:
            if let manifest = intent.proposedManifest { try await manifestStore.save(manifest) }
            var descriptor = try await sourceStore.load(id: intent.sourceID)
            descriptor.status = intent.diff.sourceStatus
            if intent.diff.sourceStatus == .available { descriptor.lastScan = Date() }
            try await sourceStore.save(descriptor)
            playlistMembershipChanges += try await syncBoundPlaylists(sourceID: intent.sourceID, createIfMissing: false)
            let addedTrackIDs = Set(intent.diff.added.compactMap { added in
                intent.proposedManifest?.entries.first {
                    $0.relativePath == added.relativePath
                }?.trackID
            })
            if intent.diff.scanGeneration > 1, !addedTrackIDs.isEmpty {
                await noticePublisher.publish(.filesImported(
                    sourceID: intent.sourceID,
                    count: addedTrackIDs.count
                ))
            }
            if intent.diff.sourceStatus != .available {
                await noticePublisher.publish(.unavailable(sourceID: intent.sourceID, status: intent.diff.sourceStatus))
            }
            if !intent.diff.failures.isEmpty {
                await noticePublisher.publish(.scanFailures(
                    sourceID: intent.sourceID,
                    failures: intent.diff.failures
                ))
            }
        case .sourceReconnect:
            guard let manifest = intent.proposedManifest,
                  let descriptor = intent.proposedSourceDescriptor else {
                throw ReferencedSourceReconcileError.invalidReconnectIntent
            }
            try await manifestStore.save(manifest)
            try await sourceStore.save(descriptor)
            playlistMembershipChanges += try await syncBoundPlaylists(sourceID: intent.sourceID, createIfMissing: false)
        case .sourceRemoval:
            // Source removal is intentionally idempotent. A process crash can
            // happen after the descriptor is deleted but before the reconcile
            // intent is removed; replay must still be able to finish by
            // cleaning the manifest and dropping the authorization scope.
            guard await sourceStore.contains(id: intent.sourceID) else {
                try await manifestStore.remove(sourceID: intent.sourceID)
                sourceScope.remove(sourceID: intent.sourceID)
                break
            }
            // Remove the source contribution from bound playlists before the
            // orphaned track rows are deleted. Manual memberships and tracks
            // still contributed by another source remain intact.
            playlistMembershipChanges += try await syncBoundPlaylists(
                sourceID: intent.sourceID,
                createIfMissing: false
            )
            let candidateOrphanedTrackIDs = Set(intent.mutations.compactMap { mutation in
                mutation.locator.allSourceMemberships.isEmpty ? mutation.trackID : nil
            })
            // Older libraries may not have a membership sidecar yet. At this
            // point source contributions have already been removed from bound
            // playlists, so any candidate still present in a playlist is a
            // manual owner and must be recorded before the orphan decision.
            if !candidateOrphanedTrackIDs.isEmpty {
                for playlist in await repository.fetchPlaylists() {
                    let manualTrackIDs = playlist.tracks
                        .map(\.id)
                        .filter { candidateOrphanedTrackIDs.contains($0) }
                    if !manualTrackIDs.isEmpty {
                        try await playlistMembershipStore.ensureManualMemberships(
                            playlistID: playlist.id,
                            trackIDs: manualTrackIDs
                        )
                    }
                }
            }

            var orphanedTrackIDs = Set<UUID>()
            for mutation in intent.mutations where mutation.locator.allSourceMemberships.isEmpty {
                // A track can outlive all physical sources when it is still a
                // manually curated playlist item. The source contribution was
                // removed above; only a truly unowned track is deletable.
                let hasLiveMembership = (try? await playlistMembershipStore.hasLiveMembership(
                    trackID: mutation.trackID
                )) == true
                if !hasLiveMembership {
                    orphanedTrackIDs.insert(mutation.trackID)
                }
            }
            let orphanedTracks = await repository.fetchTracks(in: nil).filter {
                orphanedTrackIDs.contains($0.id)
            }
            try await prepareRemovedNCMRecords(for: orphanedTracks)
            if !orphanedTracks.isEmpty {
                try await repository.deleteTracks(orphanedTracks)
            }
            try await manifestStore.remove(sourceID: intent.sourceID)
            sourceScope.remove(sourceID: intent.sourceID)
            try await sourceStore.remove(id: intent.sourceID)
        }
        try await intentStore.remove(intent)
        return playlistMembershipChanges
    }

    @discardableResult
    /// Reconciles every source-to-playlist edge without treating the source
    /// as owning the playlist itself. A missing playlist is intentionally not
    /// recreated: deleting a playlist removes the edge through the view-model
    /// callback, and a stale descriptor must never resurrect user data.
    private func syncBoundPlaylists(sourceID: UUID, createIfMissing: Bool) async throws -> Int {
        var descriptor = try await sourceStore.load(id: sourceID)
        guard descriptor.mode == .directory || descriptor.mode == .file else { return 0 }

        var createdPlaylist: Playlist?
        var createdBindingID: UUID?
        if descriptor.playlistBindings.isEmpty, createIfMissing {
            let playlist = try await repository.createPlaylist(name: descriptor.displayName)
            do {
                let ensured = try await sourceStore.ensurePlaylistBindingWithCreation(
                    sourceID: sourceID,
                    playlistID: playlist.id
                )
                createdPlaylist = playlist
                createdBindingID = ensured.didCreate ? ensured.binding.id : nil
                descriptor.playlistBindings = [ensured.binding]
            } catch {
                do {
                    try await repository.deletePlaylist(playlist)
                } catch {
                    Log.error(
                        "[ReferencedSource] failed to roll back playlist created for source \(sourceID): \(error.localizedDescription)",
                        category: .library
                    )
                }
                throw error
            }
        }
        do {
            guard !descriptor.playlistBindings.isEmpty else { return 0 }

        let playlists = await repository.fetchPlaylists()
        let tracks = await repository.fetchTracks(in: nil)
        var membershipChanges = 0
        var changedDescriptor = descriptor

        for binding in descriptor.playlistBindings {
            guard let playlist = playlists.first(where: { $0.id == binding.playlistID }) else {
                // The playlist may have been deleted by another process or an
                // older build. Do not recreate it from a source sidecar, and
                // converge stale binding/membership metadata so a failed
                // post-delete cleanup cannot leave a permanent dead edge.
                try await playlistMembershipStore.removePlaylist(playlistID: binding.playlistID)
                changedDescriptor.playlistBindings.removeAll { $0.id == binding.id }
                continue
            }

            let sourceTracks = tracks.filter { track in
                guard case let .referenced(locator) = track.mediaLocator else { return false }
                return locator.allSourceMemberships.contains { membership in
                    guard membership.sourceID == sourceID else { return false }
                    guard let relativePath = binding.relativePath else { return true }
                    return relativePath == membership.relativePath
                        || membership.relativePath.hasPrefix(relativePath + "/")
                }
            }

            let excludedTrackIDs = Set(binding.excludedTrackIDs)
                .union(
                    (try? await playlistMembershipStore.memberships(for: playlist.id))?
                        .filter { $0.excludedBindingIDs.contains(binding.id) }
                        .map(\.trackID)
                        ?? []
                )
            let eligibleTracks = sourceTracks.filter { !excludedTrackIDs.contains($0.id) }
            let eligibleTrackIDs = Set(eligibleTracks.map(\.id))

            // Preserve old playlist sidecars during the schema transition:
            // entries previously recorded as source-managed are seeded as a
            // source contribution; the remaining pre-existing entries are
            // manual and must survive future source scans.
            let legacyManagedIDs = Set(binding.legacyManagedTrackIDs ?? [])
            let manualTrackIDs = playlist.tracks
                .map(\.id)
                .filter {
                    !legacyManagedIDs.contains($0)
                        && !eligibleTrackIDs.contains($0)
                }
            try await playlistMembershipStore.ensureManualMemberships(
                playlistID: playlist.id,
                trackIDs: manualTrackIDs
            )
            if !legacyManagedIDs.isEmpty {
                try await playlistMembershipStore.recordSourceContributions(
                    legacyManagedIDs.map { (
                        playlistID: playlist.id,
                        trackID: $0,
                        bindingID: binding.id
                    ) }
                )
            }

            let existingMemberships = try await playlistMembershipStore.memberships(for: playlist.id)
            let contributedTrackIDs = Set(
                existingMemberships
                    .filter { $0.sourceBindingIDs.contains(binding.id) }
                    .map(\.trackID)
            )
            let staleIDs = contributedTrackIDs.subtracting(eligibleTrackIDs)
            let currentPlaylistTracks = Dictionary(uniqueKeysWithValues: playlist.tracks.map { ($0.id, $0) })
            for staleID in staleIDs {
                try await playlistMembershipStore.removeSourceContribution(
                    playlistID: playlist.id,
                    trackID: staleID,
                    bindingID: binding.id
                )
                guard let membership = try await playlistMembershipStore.membership(
                    playlistID: playlist.id,
                    trackID: staleID
                ), membership.isLive else {
                    guard let staleTrack = currentPlaylistTracks[staleID] else { continue }
                    membershipChanges += 1
                    try await repository.removeTracks([staleTrack], from: playlist)
                    continue
                }
            }

            // One snapshot replaces the previous per-track membership
            // queries; stale contributions were removed above, so it reflects
            // current store state without an actor hop per track.
            let membershipsByTrackID = Dictionary(
                uniqueKeysWithValues: (try await playlistMembershipStore.memberships(for: playlist.id))
                    .map { ($0.trackID, $0) }
            )
            try await playlistMembershipStore.recordSourceContributions(
                eligibleTracks.compactMap { track in
                    guard !(membershipsByTrackID[track.id]?.excludedBindingIDs.contains(binding.id) ?? false)
                    else { return nil }
                    return (playlistID: playlist.id, trackID: track.id, bindingID: binding.id)
                }
            )

            // §8.3 ordering rule: a first bind adds source songs in stable
            // relative-path order; later additions append without reshuffling.
            // Only the append set below consumes this order — existing
            // playlist entries are never reordered.
            let sortKeysByTrackID = Dictionary(
                eligibleTracks.map { track in
                    (
                        track.id,
                        sourceSortKey(
                            for: track,
                            sourceID: sourceID,
                            bindingRelativePath: binding.relativePath
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
            let orderedEligibleTracks = eligibleTracks.sorted { lhs, rhs in
                let comparison = sortKeysByTrackID[lhs.id, default: ""]
                    .localizedStandardCompare(sortKeysByTrackID[rhs.id, default: ""])
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }

            let currentPlaylistIDs = Set(playlist.tracks.map(\.id))
            let missingTracks = orderedEligibleTracks.filter { !currentPlaylistIDs.contains($0.id) }
            if !missingTracks.isEmpty {
                membershipChanges += missingTracks.count
                try await repository.addTracks(missingTracks, to: playlist)
            }

            if let index = changedDescriptor.playlistBindings.firstIndex(where: { $0.id == binding.id }) {
                changedDescriptor.playlistBindings[index].legacyManagedTrackIDs = eligibleTrackIDs.sorted {
                    $0.uuidString < $1.uuidString
                }
            }
        }

        if changedDescriptor != descriptor {
            try await sourceStore.save(changedDescriptor)
        }
        return membershipChanges
        } catch {
            if let createdBindingID {
                do {
                    try await sourceStore.removePlaylistBinding(
                        sourceID: sourceID,
                        bindingID: createdBindingID
                    )
                } catch {
                    Log.error(
                        "[ReferencedSource] failed to roll back binding \(createdBindingID) after playlist sync failure: \(error.localizedDescription)",
                        category: .library
                    )
                }
            }
            if let createdPlaylist {
                do {
                    try await playlistMembershipStore.removePlaylist(playlistID: createdPlaylist.id)
                } catch {
                    Log.error(
                        "[ReferencedSource] failed to roll back membership for playlist \(createdPlaylist.id): \(error.localizedDescription)",
                        category: .library
                    )
                }
                do {
                    try await repository.deletePlaylist(createdPlaylist)
                } catch {
                    Log.error(
                        "[ReferencedSource] failed to roll back playlist \(createdPlaylist.id): \(error.localizedDescription)",
                        category: .library
                    )
                }
            }
            throw error
        }
    }

    /// Stable §8.3 sort key: the track's lexicographically smallest matching
    /// source-membership relative path for this binding. Deterministic across
    /// scans because paths mirror the scanned tree layout.
    private func sourceSortKey(
        for track: Track,
        sourceID: UUID,
        bindingRelativePath: String?
    ) -> String {
        guard case let .referenced(locator) = track.mediaLocator else { return "" }
        let matchingPaths = locator.allSourceMemberships.compactMap { membership -> String? in
            guard membership.sourceID == sourceID else { return nil }
            guard let root = bindingRelativePath else { return membership.relativePath }
            return (membership.relativePath == root || membership.relativePath.hasPrefix(root + "/"))
                ? membership.relativePath
                : nil
        }
        return matchingPaths.min {
            $0 != $1 && $0.localizedStandardCompare($1) == .orderedAscending
        } ?? ""
    }

    private func physicalTrackIDMap(_ tracks: [Track]) -> [ReferencedPhysicalIdentityKey: UUID] {
        tracks.reduce(into: [:]) { result, track in
            guard case let .referenced(locator) = track.mediaLocator else { return }
            for location in locator.locations {
                guard let fingerprint = location.fingerprint else { continue }
                result[ReferencedPhysicalIdentityKey(fingerprint)] = track.id
            }
        }
    }

    private func ncmSourceTrackIDMap(_ tracks: [Track]) -> [ReferencedFileIdentity: UUID] {
        tracks.reduce(into: [:]) { result, track in
            guard case let .referenced(locator) = track.mediaLocator else { return }
            for location in locator.locations {
                guard let sourceIdentity = location.ncmSourceIdentity else { continue }
                result[sourceIdentity] = track.id
            }
        }
    }

    private func makeMutations(
        diff: ReferencedSourceDiff,
        rootURL: URL,
        importedTracks: [Track],
        firstScanPresentPaths: Set<String>? = nil
    ) async -> [ReferencedSourceLocatorMutation] {
        let allTracks = await repository.fetchTracks(in: nil)
        let tracksByID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
        let isFileRoot = rootIsFile(rootURL)
        var changes: [UUID: ReferencedSourceLocatorMutation] = [:]

        for track in allTracks {
            guard case var .referenced(locator) = track.mediaLocator else { continue }
            var didRepairGeneratedOutputMembership = false
            if let generatedRelativePath = generatedOutputRelativePath(
                for: track,
                locator: locator,
                rootURL: rootURL
            ), locator.allSourceMemberships.contains(where: {
                $0.sourceID == diff.sourceID && $0.relativePath == generatedRelativePath
            }) {
                locator.removeSourceMembership(
                    sourceID: diff.sourceID,
                    relativePath: generatedRelativePath
                )
                didRepairGeneratedOutputMembership = true
            }
            guard didRepairGeneratedOutputMembership || track.availability != .available else { continue }
            guard locator.containsSource(diff.sourceID) || didRepairGeneratedOutputMembership else { continue }
            changes[track.id] = .init(
                trackID: track.id,
                locator: locator,
                availability: locator.allSourceMemberships.isEmpty ? .missing : .available
            )
        }

        for track in importedTracks {
            guard case var .referenced(locator) = track.mediaLocator else { continue }

            // For an NCM track the playback locator points at the generated
            // MP3/FLAC in the conversion folder, while the source membership
            // must continue to point at the original .ncm input.  The source
            // scanner deliberately hides generated products, so replacing an
            // existing membership with `lastKnownPath` here makes the first
            // scan immediately remove the real source and mark the track
            // unavailable.  Only synthesize a membership for an imported
            // track that does not already carry this source's authoritative
            // membership.
            if !locator.containsSource(diff.sourceID),
               let relative = relativePath(URL(fileURLWithPath: locator.lastKnownPath), root: rootURL) {
                setMembership(sourceID: diff.sourceID, relativePath: relative, locator: &locator)
            }
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }
        for move in diff.moved {
            guard let track = tracksByID[move.trackID], case var .referenced(locator) = track.mediaLocator else { continue }
            let resolvedURL = url(forRelativePath: move.newRelativePath, root: rootURL, rootIsFile: isFileRoot)
            refresh(
                locator: &locator,
                sourceID: diff.sourceID,
                url: resolvedURL,
                fingerprint: move.fingerprint
            )
            setMembership(sourceID: diff.sourceID, relativePath: move.newRelativePath, locator: &locator)
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }
        for replacement in diff.replacements {
            guard let track = tracksByID[replacement.trackID], case var .referenced(locator) = track.mediaLocator else { continue }
            let resolvedURL = url(forRelativePath: replacement.relativePath, root: rootURL, rootIsFile: isFileRoot)
            refresh(
                locator: &locator,
                sourceID: diff.sourceID,
                url: resolvedURL,
                fingerprint: replacement.newFingerprint
            )
            setMembership(sourceID: diff.sourceID, relativePath: replacement.relativePath, locator: &locator)
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }
        let presentTrackIDs = Set(importedTracks.map(\.id) + diff.moved.map(\.trackID) + diff.replacements.map(\.trackID))
        for missing in diff.missing {
            guard !presentTrackIDs.contains(missing.trackID),
                  let track = tracksByID[missing.trackID], case var .referenced(locator) = track.mediaLocator else { continue }
            locator.removeSourcePreservingRecovery(diff.sourceID)
            locator.primarySourceID = primarySourceID(locator.sourceMemberships)
            changes[track.id] = .init(
                trackID: track.id,
                locator: locator,
                availability: locator.allSourceMemberships.isEmpty ? .missing : track.availability
            )
        }

        // First successful scan is authoritative: with no previous manifest
        // the diff cannot express deletions that happened before it (e.g. a
        // converted product deleted right after the initial import), so
        // memberships whose file is absent from the scan are settled here.
        if let firstScanPresentPaths {
            for track in allTracks {
                guard case var .referenced(locator) = track.mediaLocator else { continue }
                let sourceMemberships = locator.allSourceMemberships.filter {
                    $0.sourceID == diff.sourceID
                }
                // A newly imported track has its source membership in the
                // pending mutation, not on the Track object yet. It must not
                // be mistaken for a stale pre-existing membership and
                // overwritten as missing in this same transaction.
                guard !sourceMemberships.isEmpty,
                      !sourceMemberships.contains(where: {
                          firstScanPresentPaths.contains($0.relativePath)
                      }) else { continue }
                locator.removeSourcePreservingRecovery(diff.sourceID)
                locator.primarySourceID = primarySourceID(locator.sourceMemberships)
                changes[track.id] = .init(
                    trackID: track.id,
                    locator: locator,
                    availability: locator.allSourceMemberships.isEmpty ? .missing : track.availability
                )
            }
        }
        return changes.values.sorted { $0.trackID.uuidString < $1.trackID.uuidString }
    }

    private func refresh(
        locator: inout ReferencedFileLocator,
        sourceID: UUID,
        url: URL,
        fingerprint: ReferencedFileFingerprint
    ) {
        let bookmark = (try? bookmarkResolver.refreshBookmark(for: url))
            ?? locator.fileBookmarkData
        locator.refreshLocation(
            for: sourceID,
            fileBookmarkData: bookmark,
            lastKnownPath: url.path,
            fingerprint: fingerprint
        )
    }

    private func setMembership(sourceID: UUID, relativePath: String, locator: inout ReferencedFileLocator) {
        locator.setSourceMembership(.init(sourceID: sourceID, relativePath: relativePath))
        locator.sourceMemberships.sort {
            if $0.relativePath.count != $1.relativePath.count { return $0.relativePath.count < $1.relativePath.count }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }
        locator.primarySourceID = primarySourceID(locator.sourceMemberships)
    }

    private func generatedOutputRelativePath(
        for track: Track,
        locator: ReferencedFileLocator,
        rootURL: URL
    ) -> String? {
        let outputURL = URL(fileURLWithPath: locator.lastKnownPath).standardizedFileURL
        guard !locator.lastKnownPath.isEmpty else { return nil }
        let associationMatches = track.ncmConversionAssociation.map {
            URL(fileURLWithPath: $0.outputPath).standardizedFileURL.path == outputURL.path
        } ?? false
        let isInNCMOutputDirectory = outputURL.deletingLastPathComponent().lastPathComponent
            == ReferencedNCMConversionService.outputDirectoryName
        let markerMatches = isInNCMOutputDirectory
            ? locator.fingerprint.map {
                NCMGeneratedOutputMarkerStore.isGeneratedOutput(
                    outputURL,
                    fingerprint: $0
                )
            } ?? false
            : false
        guard associationMatches || markerMatches else { return nil }
        return relativePath(outputURL, root: rootURL)
    }

    private func primarySourceID(_ memberships: [ReferencedSourceMembership]) -> UUID? {
        memberships.min {
            if $0.relativePath.count != $1.relativePath.count { return $0.relativePath.count < $1.relativePath.count }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }?.sourceID
    }

    private func prepareRemovedNCMRecords(for tracks: [Track]) async throws {
        var recordsByID: [UUID: NCMConversionRecord] = [:]
        for track in tracks {
            guard let operationID = track.ncmConversionAssociation?.operationID,
                  let record = try await ncmRegistry.record(operationID: operationID) else { continue }
            recordsByID[operationID] = record
        }
        let records = recordsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let items = records.flatMap { record in
            var recordItems = [IgnoredReferencedItem(
                fingerprint: record.sourceFingerprint,
                lastKnownPath: record.sourcePath,
                reason: .ncmSourceRemoval
            )]
            if let outputFingerprint = record.outputFingerprint {
                recordItems.append(IgnoredReferencedItem(
                    fingerprint: outputFingerprint,
                    lastKnownPath: record.expectedOutputPath,
                    reason: .ncmOutputRemoval
                ))
            }
            return recordItems
        }
        let inserted = try await ignoredItemsStore.add(items)
        var changedOperationIDs: [UUID] = []
        do {
            for record in records where record.state != .removed {
                _ = try await ncmRegistry.markRemoved(operationID: record.id)
                changedOperationIDs.append(record.id)
            }
        } catch {
            for operationID in changedOperationIDs.reversed() {
                try? await ncmRegistry.restoreAfterFailedRemoval(operationID: operationID)
            }
            try? await ignoredItemsStore.remove(matching: inserted)
            throw error
        }
    }

    private func relativePath(_ url: URL, root: URL) -> String? {
        let candidate = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        // A file source's root is the file itself; the membership path is the
        // file name, matching the scanner's single-entry layout.
        if candidate == base { return root.lastPathComponent }
        guard candidate.hasPrefix(base + "/") else { return nil }
        return String(candidate.dropFirst(base.count + 1))
    }

    private func url(forRelativePath relativePath: String, root rootURL: URL, rootIsFile: Bool) -> URL {
        rootIsFile ? rootURL : rootURL.appendingPathComponent(relativePath)
    }

    private func rootIsFile(_ rootURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    @discardableResult
    private func applyUnavailable(
        sourceID: UUID,
        status: ReferencedSourceStatus
    ) async throws -> ReferencedReconcileChanges {
        let unavailable: TrackAvailability = status == .permissionDenied
            ? .permissionDenied
            : .volumeUnavailable
        let authorizedSourceIDs = Set(sourceScope.authorizedRoots.keys).subtracting([sourceID])
        let tracks = await repository.fetchTracks(in: nil)
        let mutations = tracks.compactMap { track -> ReferencedSourceLocatorMutation? in
            guard case let .referenced(locator) = track.mediaLocator,
                  locator.containsSource(sourceID) else { return nil }
            let hasOtherAvailableMembership = locator.allSourceMemberships.contains {
                authorizedSourceIDs.contains($0.sourceID)
            }
            let availability: TrackAvailability = hasOtherAvailableMembership ? .available : unavailable
            guard track.availability != availability else { return nil }
            return .init(trackID: track.id, locator: locator, availability: availability)
        }
        let diff = ReferencedSourceDiff(
            libraryID: context.id,
            libraryGeneration: context.generation,
            sourceID: sourceID,
            scanGeneration: 0,
            sourceStatus: status
        )
        let intent = try await intentStore.prepare(diff, mutations: mutations)
        return try await drivePrepared(intent)
    }

    private func validate(_ intent: LibraryReconcileIntent) throws {
        // `libraryGeneration` identifies the session/activation that created
        // the intent, not the persistent library itself. A prepared intent is
        // precisely the recovery record that must survive a crash or app
        // restart, both of which allocate a new session generation. The
        // persistent library UUID is the durable identity boundary here.
        guard intent.libraryID == context.id else {
            throw LibrarySessionFactoryError.manifestIdentityMismatch
        }
    }

    private func restoreReconnectAuthorizationIfNeeded(
        _ intent: LibraryReconcileIntent
    ) async throws {
        guard intent.operation == .sourceReconnect else { return }
        guard let descriptor = intent.proposedSourceDescriptor else {
            throw ReferencedSourceReconcileError.invalidReconnectIntent
        }
        if sourceScope.authorizedRoots[descriptor.id]?.url.standardizedFileURL.path
            == descriptor.lastKnownPath {
            return
        }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarkResolver.resolve(descriptor.rootBookmarkData)
        } catch {
            throw ReferencedSourceReconcileError.reconnectAuthorizationFailed(descriptor.id)
        }
        let didStart = bookmarkResolver.startAccessing(resolved.url)
        guard didStart
                || (!requiresSecurityScope
                    && FileManager.default.isReadableFile(atPath: resolved.url.path)) else {
            throw ReferencedSourceReconcileError.reconnectAuthorizationFailed(descriptor.id)
        }
        let lease = didStart
            ? SecurityScopedResourceLease { [bookmarkResolver] in
                bookmarkResolver.stopAccessing(resolved.url)
            }
            : .none
        sourceScope.add(sourceID: descriptor.id, url: resolved.url, lease: lease)
    }
}

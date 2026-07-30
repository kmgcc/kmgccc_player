import Foundation

nonisolated enum ReferencedSourceReconcileError: Error, Equatable {
    case authorityCommitFailed([UUID])
    case invalidReconnectIntent
    case reconnectAuthorizationFailed(UUID)
}

nonisolated enum ReferencedSourceNotice: Sendable, Equatable {
    case unavailable(sourceID: UUID, status: ReferencedSourceStatus)
    case fileFailures(sourceID: UUID, count: Int)
    case reconcileFailures(sourceID: UUID, trackIDs: [UUID])
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
    private let sourceStore: ReferencedSourceStore
    private let sourceScope: ReferencedSourceScope
    private let scanner: ReferencedSourceScanner
    private let ignoredItemsStore: IgnoredReferencedItemsStore
    private let ncmRegistry: NCMConversionRegistry
    private let manifestStore: ReferencedSourceScanManifestStore
    private let intentStore: LibraryReconcileIntentStore
    private let bookmarkResolver: any BookmarkResolving
    private let noticePublisher: any ReferencedSourceNoticePublishing
    private let requiresSecurityScope: Bool
    private var isClosed = false

    init(
        context: LibraryContext,
        repository: any LibraryRepositoryProtocol,
        importer: any AutomaticReferencedFileImporting,
        sourceStore: ReferencedSourceStore,
        sourceScope: ReferencedSourceScope,
        scanner: ReferencedSourceScanner,
        ignoredItemsStore: IgnoredReferencedItemsStore? = nil,
        ncmRegistry: NCMConversionRegistry? = nil,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false,
        noticePublisher: any ReferencedSourceNoticePublishing = LogReferencedSourceNoticePublisher()
    ) {
        precondition(context.mode == .referenced)
        self.context = context
        self.repository = repository
        self.importer = importer
        self.sourceStore = sourceStore
        self.sourceScope = sourceScope
        self.scanner = scanner
        self.ignoredItemsStore = ignoredItemsStore ?? IgnoredReferencedItemsStore(paths: context.paths)
        self.ncmRegistry = ncmRegistry ?? NCMConversionRegistry(paths: context.paths)
        manifestStore = ReferencedSourceScanManifestStore(paths: context.paths)
        intentStore = LibraryReconcileIntentStore(paths: context.paths)
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

    @discardableResult
    func refreshSources() async throws -> [ReferencedSourceScopeIssue] {
        let descriptors = try await sourceStore.loadAll()
        let issues = await sourceScope.start(
            descriptors: descriptors,
            store: sourceStore,
            bookmarkResolver: bookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        try await reconcile(sourceIDs: Set(descriptors.map(\.id)))
        return issues
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
        guard !isClosed else { return 0 }
        let knownIDs = Set(try await sourceStore.loadAll().map(\.id))
        let tracks = await repository.fetchTracks(in: nil)
        var mutations: [ReferencedSourceLocatorMutation] = []
        var created = 0
        for track in tracks {
            guard case var .referenced(locator) = track.mediaLocator else { continue }
            let orphans = locator.sourceMemberships.filter { !knownIDs.contains($0.sourceID) }
            guard !orphans.isEmpty else { continue }
            var locatorChanged = false
            for orphan in orphans where locator.primarySourceID == orphan.sourceID {
                let fileURL = URL(fileURLWithPath: locator.lastKnownPath)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    // The source record is lost and the file is gone:
                    // settle as missing.
                    locator.sourceMemberships.removeAll { $0.sourceID == orphan.sourceID }
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
                try await sourceStore.save(descriptor)
                created += 1
                if let index = locator.sourceMemberships.firstIndex(where: { $0.sourceID == orphan.sourceID }) {
                    locator.sourceMemberships[index].relativePath = fileURL.lastPathComponent
                    locatorChanged = true
                }
            }
            guard locatorChanged else { continue }
            locator.primarySourceID = primarySourceID(locator.sourceMemberships)
            mutations.append(.init(
                trackID: track.id,
                locator: locator,
                availability: locator.sourceMemberships.isEmpty ? .missing : track.availability
            ))
        }
        if !mutations.isEmpty {
            _ = await repository.commitReferencedSourceMutations(mutations)
            Log.warning(
                "[ReferencedSource] repaired orphaned memberships tracks=\(mutations.count) recreatedSources=\(created)",
                category: .library
            )
        }
        if created > 0 {
            // Re-arm the scope so the recreated roots become authorized and
            // eligible for monitoring before the next reconcile.
            let descriptors = try await sourceStore.loadAll()
            _ = await sourceScope.start(
                descriptors: descriptors,
                store: sourceStore,
                bookmarkResolver: bookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
        }
        return created
    }

    func replayPending(sourceID: UUID? = nil) async throws {
        guard !isClosed else { return }
        for intent in try await intentStore.pending(libraryID: context.id, sourceID: sourceID) {
            try validate(intent)
            try await restoreReconnectAuthorizationIfNeeded(intent)
            switch intent.state {
            case .prepared:
                try await drivePrepared(intent)
            case .sidecarsCommitted:
                await repository.attachReferencedSourceMutations(intent.mutations)
                let applied = try await intentStore.advance(intent, to: .runtimeApplied)
                try await finalize(applied)
            case .runtimeApplied:
                try await finalize(intent)
            }
        }
    }

    func reconcile(sourceIDs: Set<UUID>) async throws {
        guard !isClosed else { return }
        for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard !isClosed else { return }
            try await replayPending(sourceID: sourceID)
            guard try await intentStore.pending(libraryID: context.id, sourceID: sourceID).isEmpty else {
                continue
            }
            guard await sourceStore.contains(id: sourceID) else { continue }
            let descriptor = try await sourceStore.load(id: sourceID)
            guard let root = sourceScope.authorizedRoots[sourceID]?.url else {
                let status: ReferencedSourceStatus = descriptor.status == .permissionDenied
                    ? .permissionDenied
                    : .offline
                try await applyUnavailable(sourceID: sourceID, status: status)
                continue
            }
            var effectiveRoot = root
            var result = try await scanner.scan(context: context, sourceID: sourceID, rootURL: root)
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
                    result = try await scanner.scan(context: context, sourceID: sourceID, rootURL: refreshedRoot)
                }
            }
            try await apply(result, rootURL: effectiveRoot)
        }
    }

    func removeSource(_ sourceID: UUID) async throws {
        guard !isClosed else { return }
        let tracks = await repository.fetchTracks(in: nil)
        var mutations: [ReferencedSourceLocatorMutation] = []
        var orphanedTracks: [Track] = []
        for track in tracks {
            guard case var .referenced(locator) = track.mediaLocator,
                  locator.sourceMemberships.contains(where: { $0.sourceID == sourceID }) else { continue }
            locator.sourceMemberships.removeAll { $0.sourceID == sourceID }
            locator.primarySourceID = primarySourceID(locator.sourceMemberships)
            let availability: TrackAvailability = locator.sourceMemberships.isEmpty ? .missing : track.availability
            if locator.sourceMemberships.isEmpty {
                orphanedTracks.append(track)
            }
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

    private func apply(_ result: ReferencedSourceScanResult, rootURL: URL) async throws {
        let diff = result.diff
        guard diff.sourceStatus == .available else {
            try await applyUnavailable(sourceID: diff.sourceID, status: diff.sourceStatus)
            return
        }
        let intent = try await intentStore.prepare(
            diff,
            proposedManifest: result.proposedManifest
        )
        try await drivePrepared(intent, rootURL: rootURL)
    }

    private func drivePrepared(
        _ original: LibraryReconcileIntent,
        rootURL explicitRootURL: URL? = nil
    ) async throws {
        var intent = original
        if intent.operation == .reconcile,
           intent.diff.sourceStatus == .available,
           intent.mutations.isEmpty || intent.proposedManifest?.entries.contains(where: { $0.trackID == nil }) == true {
            guard let rootURL = explicitRootURL ?? sourceScope.authorizedRoots[intent.sourceID]?.url else { return }
            let isFileRoot = rootIsFile(rootURL)
            let imported = intent.diff.added.isEmpty
                ? []
                : await importer.importAutomatically(intent.diff.added.map {
                    url(forRelativePath: $0.relativePath, root: rootURL, rootIsFile: isFileRoot)
                })
            guard !isClosed else { return }
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
            guard intent.diff.added.allSatisfy({ physicalTrackIDs[ReferencedPhysicalIdentityKey($0.fingerprint)] != nil }) else {
                return
            }
            if var manifest = intent.proposedManifest {
                for index in manifest.entries.indices {
                    manifest.entries[index].trackID = physicalTrackIDs[ReferencedPhysicalIdentityKey(manifest.entries[index].fingerprint)]
                }
                intent = try await intentStore.updateManifest(intent, manifest: manifest)
            }
        }

        let alreadyCommitted = Set(intent.committedTrackIDs)
        let pending = intent.mutations.filter { !alreadyCommitted.contains($0.trackID) }
        if !pending.isEmpty {
            let result = await repository.commitReferencedSourceMutations(pending)
            intent = try await intentStore.recordAuthorityCommits(intent, trackIDs: result.persistedTrackIDs)
            if !result.failedTrackIDs.isEmpty {
                await noticePublisher.publish(.reconcileFailures(sourceID: intent.sourceID, trackIDs: result.failedTrackIDs))
                throw ReferencedSourceReconcileError.authorityCommitFailed(result.failedTrackIDs)
            }
        }
        guard Set(intent.committedTrackIDs) == Set(intent.mutations.map(\.trackID)) else { return }
        intent = try await intentStore.advance(intent, to: .sidecarsCommitted)
        await repository.attachReferencedSourceMutations(intent.mutations)
        intent = try await intentStore.advance(intent, to: .runtimeApplied)
        try await finalize(intent)
    }

    private func finalize(_ intent: LibraryReconcileIntent) async throws {
        switch intent.operation {
        case .reconcile:
            if let manifest = intent.proposedManifest { try await manifestStore.save(manifest) }
            var descriptor = try await sourceStore.load(id: intent.sourceID)
            descriptor.status = intent.diff.sourceStatus
            if intent.diff.sourceStatus == .available { descriptor.lastScan = Date() }
            try await sourceStore.save(descriptor)
            if intent.diff.sourceStatus != .available {
                await noticePublisher.publish(.unavailable(sourceID: intent.sourceID, status: intent.diff.sourceStatus))
            }
            if !intent.diff.failures.isEmpty {
                await noticePublisher.publish(.fileFailures(sourceID: intent.sourceID, count: intent.diff.failures.count))
            }
        case .sourceReconnect:
            guard let manifest = intent.proposedManifest,
                  let descriptor = intent.proposedSourceDescriptor else {
                throw ReferencedSourceReconcileError.invalidReconnectIntent
            }
            try await manifestStore.save(manifest)
            try await sourceStore.save(descriptor)
        case .sourceRemoval:
            let orphanedTrackIDs = Set(intent.mutations.compactMap { mutation in
                mutation.locator.sourceMemberships.isEmpty ? mutation.trackID : nil
            })
            let orphanedTracks = await repository.fetchTracks(in: nil).filter {
                orphanedTrackIDs.contains($0.id)
            }
            try await prepareRemovedNCMRecords(for: orphanedTracks)
            if !orphanedTracks.isEmpty {
                await repository.deleteTracks(orphanedTracks)
            }
            try await manifestStore.remove(sourceID: intent.sourceID)
            sourceScope.remove(sourceID: intent.sourceID)
            try await sourceStore.remove(id: intent.sourceID)
        }
        try await intentStore.remove(intent)
    }

    private func physicalTrackIDMap(_ tracks: [Track]) -> [ReferencedPhysicalIdentityKey: UUID] {
        tracks.reduce(into: [:]) { result, track in
            guard case let .referenced(locator) = track.mediaLocator,
                  let fingerprint = locator.fingerprint else { return }
            result[ReferencedPhysicalIdentityKey(fingerprint)] = track.id
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
            guard track.availability != .available,
                  case let .referenced(locator) = track.mediaLocator,
                  locator.sourceMemberships.contains(where: { $0.sourceID == diff.sourceID }) else { continue }
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }

        for track in importedTracks {
            guard case var .referenced(locator) = track.mediaLocator,
                  let relative = relativePath(URL(fileURLWithPath: locator.lastKnownPath), root: rootURL) else { continue }
            setMembership(sourceID: diff.sourceID, relativePath: relative, locator: &locator)
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }
        for move in diff.moved {
            guard let track = tracksByID[move.trackID], case var .referenced(locator) = track.mediaLocator else { continue }
            let resolvedURL = url(forRelativePath: move.newRelativePath, root: rootURL, rootIsFile: isFileRoot)
            refresh(locator: &locator, url: resolvedURL, fingerprint: move.fingerprint)
            setMembership(sourceID: diff.sourceID, relativePath: move.newRelativePath, locator: &locator)
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }
        for replacement in diff.replacements {
            guard let track = tracksByID[replacement.trackID], case var .referenced(locator) = track.mediaLocator else { continue }
            let resolvedURL = url(forRelativePath: replacement.relativePath, root: rootURL, rootIsFile: isFileRoot)
            refresh(locator: &locator, url: resolvedURL, fingerprint: replacement.newFingerprint)
            setMembership(sourceID: diff.sourceID, relativePath: replacement.relativePath, locator: &locator)
            changes[track.id] = .init(trackID: track.id, locator: locator, availability: .available)
        }
        let presentTrackIDs = Set(importedTracks.map(\.id) + diff.moved.map(\.trackID) + diff.replacements.map(\.trackID))
        for missing in diff.missing {
            guard !presentTrackIDs.contains(missing.trackID),
                  let track = tracksByID[missing.trackID], case var .referenced(locator) = track.mediaLocator else { continue }
            locator.sourceMemberships.removeAll { $0.sourceID == diff.sourceID }
            locator.primarySourceID = primarySourceID(locator.sourceMemberships)
            changes[track.id] = .init(
                trackID: track.id,
                locator: locator,
                availability: locator.sourceMemberships.isEmpty ? .missing : track.availability
            )
        }

        // First successful scan is authoritative: with no previous manifest
        // the diff cannot express deletions that happened before it (e.g. a
        // converted product deleted right after the initial import), so
        // memberships whose file is absent from the scan are settled here.
        if let firstScanPresentPaths {
            for track in allTracks {
                guard case var .referenced(locator) = track.mediaLocator,
                      let membership = locator.sourceMemberships.first(where: { $0.sourceID == diff.sourceID }),
                      !firstScanPresentPaths.contains(membership.relativePath) else { continue }
                locator.sourceMemberships.removeAll { $0.sourceID == diff.sourceID }
                locator.primarySourceID = primarySourceID(locator.sourceMemberships)
                changes[track.id] = .init(
                    trackID: track.id,
                    locator: locator,
                    availability: locator.sourceMemberships.isEmpty ? .missing : track.availability
                )
            }
        }
        return changes.values.sorted { $0.trackID.uuidString < $1.trackID.uuidString }
    }

    private func refresh(locator: inout ReferencedFileLocator, url: URL, fingerprint: ReferencedFileFingerprint) {
        locator.fileBookmarkData = (try? bookmarkResolver.refreshBookmark(for: url)) ?? locator.fileBookmarkData
        locator.lastKnownPath = url.path
        locator.fingerprint = fingerprint
    }

    private func setMembership(sourceID: UUID, relativePath: String, locator: inout ReferencedFileLocator) {
        locator.sourceMemberships.removeAll { $0.sourceID == sourceID }
        locator.sourceMemberships.append(.init(sourceID: sourceID, relativePath: relativePath))
        locator.sourceMemberships.sort {
            if $0.relativePath.count != $1.relativePath.count { return $0.relativePath.count < $1.relativePath.count }
            return $0.sourceID.uuidString < $1.sourceID.uuidString
        }
        locator.primarySourceID = primarySourceID(locator.sourceMemberships)
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

    private func applyUnavailable(
        sourceID: UUID,
        status: ReferencedSourceStatus
    ) async throws {
        let unavailable: TrackAvailability = status == .permissionDenied
            ? .permissionDenied
            : .volumeUnavailable
        let authorizedSourceIDs = Set(sourceScope.authorizedRoots.keys).subtracting([sourceID])
        let tracks = await repository.fetchTracks(in: nil)
        let mutations = tracks.compactMap { track -> ReferencedSourceLocatorMutation? in
            guard case let .referenced(locator) = track.mediaLocator,
                  locator.sourceMemberships.contains(where: { $0.sourceID == sourceID }) else { return nil }
            let hasOtherAvailableMembership = locator.sourceMemberships.contains {
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
        try await drivePrepared(intent)
    }

    private func validate(_ intent: LibraryReconcileIntent) throws {
        guard intent.libraryID == context.id, intent.libraryGeneration == context.generation else {
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

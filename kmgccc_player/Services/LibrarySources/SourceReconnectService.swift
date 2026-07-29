import AVFoundation
import Foundation

nonisolated enum SourceReconnectServiceError: Error, Equatable, LocalizedError {
    case unavailableInManagedLibrary
    case sourceNotFound(UUID)
    case invalidCandidateRoot(String)
    case noCandidateRoots
    case invalidConflictSelection(UUID)
    case duplicateCandidateSelection(String)
    case trackNotFound(UUID)
    case trackIsNotReferenced(UUID)
    case trackIsNotStandaloneMissing(UUID)
    case unsupportedAudioFormat(String)
    case selectedFileUnavailable(String)
    case selectedFileChanged(String)
    case replacementConfirmationRequired
    case authorityCommitFailed([UUID])
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailableInManagedLibrary:
            return "管理型资料库不需要重新连接引用来源。"
        case .sourceNotFound:
            return "找不到需要重新连接的来源。"
        case .invalidCandidateRoot:
            return "所选文件夹无法作为来源。"
        case .noCandidateRoots:
            return "请至少选择一个候选文件夹。"
        case .invalidConflictSelection:
            return "冲突文件不在所选候选位置中。"
        case .duplicateCandidateSelection:
            return "同一个文件不能绑定到多首歌曲。"
        case .trackNotFound:
            return "找不到需要重新定位的歌曲。"
        case .trackIsNotReferenced:
            return "这首歌曲不使用外部文件。"
        case .trackIsNotStandaloneMissing:
            return "只有未连接且不属于文件夹来源的歌曲可以单独重新定位。"
        case .unsupportedAudioFormat:
            return "所选文件格式不受支持。"
        case .selectedFileUnavailable:
            return "所选文件当前不可读取。"
        case .selectedFileChanged:
            return "所选文件已发生变化，请重新选择。"
        case .replacementConfirmationRequired:
            return "所选文件与原文件身份不同，需要确认替换。"
        case .authorityCommitFailed:
            return "歌曲位置未能完整保存。"
        case .authorizationFailed:
            return "无法取得所选位置的访问权限。"
        }
    }
}

@MainActor
final class SourceReconnectService {
    private let context: LibraryContext
    private let repository: any LibraryRepositoryProtocol
    private let sourceStore: ReferencedSourceStore
    private let sourceScope: ReferencedSourceScope
    private let reconciler: ReferencedSourceReconciler
    private let manifestStore: ReferencedSourceScanManifestStore
    private let bookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool
    private let matcher: SourceReconnectMatcher

    init(
        context: LibraryContext,
        repository: any LibraryRepositoryProtocol,
        sourceStore: ReferencedSourceStore,
        sourceScope: ReferencedSourceScope,
        reconciler: ReferencedSourceReconciler,
        bookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false,
        matcher: SourceReconnectMatcher = SourceReconnectMatcher()
    ) {
        precondition(context.mode == .referenced)
        self.context = context
        self.repository = repository
        self.sourceStore = sourceStore
        self.sourceScope = sourceScope
        self.reconciler = reconciler
        manifestStore = ReferencedSourceScanManifestStore(paths: context.paths)
        self.bookmarkResolver = bookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
        self.matcher = matcher
    }

    func prepareSourceReconnect(
        sourceID: UUID,
        candidateRoots: [URL]
    ) async throws -> SourceReconnectPreparation {
        guard context.mode == .referenced else {
            throw SourceReconnectServiceError.unavailableInManagedLibrary
        }
        let roots = uniqueStandardizedURLs(candidateRoots)
        guard !roots.isEmpty else { throw SourceReconnectServiceError.noCandidateRoots }
        guard await sourceStore.contains(id: sourceID) else {
            throw SourceReconnectServiceError.sourceNotFound(sourceID)
        }
        let descriptor = try await sourceStore.load(id: sourceID)
        let tracks = await repository.fetchTracks(in: nil)
        let manifest = try await manifestStore.load(sourceID: sourceID, libraryID: context.id)
        let expected = expectedFiles(sourceID: sourceID, tracks: tracks, manifest: manifest)
        let plans = try await withThrowingTaskGroup(of: SourceReconnectPlan.self) { group in
            for root in roots {
                group.addTask { [matcher] in
                    let candidates = try await Self.scanCandidates(rootURL: root)
                    return matcher.makePlan(rootURL: root, expected: expected, candidates: candidates)
                }
            }
            var values: [SourceReconnectPlan] = []
            for try await value in group { values.append(value) }
            return values.sorted {
                if $0.recoveredCount != $1.recoveredCount {
                    return $0.recoveredCount > $1.recoveredCount
                }
                return $0.rootURL.path < $1.rootURL.path
            }
        }
        return SourceReconnectPreparation(
            sourceID: sourceID,
            sourceDisplayName: descriptor.displayName,
            plans: plans
        )
    }

    func reconnectSource(
        preparation: SourceReconnectPreparation,
        planID: String,
        conflictSelections: [UUID: URL]
    ) async throws {
        guard let plan = preparation.plans.first(where: { $0.id == planID }) else {
            throw SourceReconnectServiceError.invalidCandidateRoot(planID)
        }
        guard await sourceStore.contains(id: preparation.sourceID) else {
            throw SourceReconnectServiceError.sourceNotFound(preparation.sourceID)
        }

        var accepted = plan.matches
        for conflict in plan.conflicts {
            guard let selectedURL = conflictSelections[conflict.expected.trackID] else { continue }
            guard let candidate = conflict.candidates.first(where: {
                $0.url.standardizedFileURL == selectedURL.standardizedFileURL
            }) else {
                throw SourceReconnectServiceError.invalidConflictSelection(conflict.expected.trackID)
            }
            accepted.append(SourceReconnectMatch(
                trackID: conflict.expected.trackID,
                previousRelativePath: conflict.expected.relativePath,
                candidate: candidate,
                basis: .fingerprint
            ))
        }
        let selectedPaths = accepted.map { $0.candidate.url.standardizedFileURL.path }
        if let duplicate = Dictionary(grouping: selectedPaths, by: { $0 })
            .first(where: { $0.value.count > 1 })?.key {
            throw SourceReconnectServiceError.duplicateCandidateSelection(duplicate)
        }

        let rootAccess = try acquireAccess(to: plan.rootURL)
        do {
            let rootBookmark = try bookmarkResolver.refreshBookmark(for: plan.rootURL)
            let descriptor = try await sourceStore.reconnectDescriptor(
                sourceID: preparation.sourceID,
                rootBookmarkData: rootBookmark,
                rootURL: plan.rootURL
            )
            let mutations = try await sourceReconnectMutations(
                sourceID: preparation.sourceID,
                accepted: accepted
            )
            let previousManifest = try await manifestStore.load(
                sourceID: preparation.sourceID,
                libraryID: context.id
            )
            let manifest = ReferencedSourceScanManifest(
                libraryID: context.id,
                sourceID: preparation.sourceID,
                generation: (previousManifest?.generation ?? 0) &+ 1,
                lastSuccessfulScan: Date(),
                entries: accepted.map { match in
                    ReferencedSourceScanEntry(
                        relativePath: match.candidate.relativePath,
                        identity: match.candidate.fingerprint.identity,
                        fingerprint: match.candidate.fingerprint,
                        trackID: match.trackID,
                        availability: .available,
                        lastSeenGeneration: (previousManifest?.generation ?? 0) &+ 1
                    )
                }.sorted { $0.relativePath < $1.relativePath }
            )
            try await reconciler.reconnectSource(
                descriptor: descriptor,
                rootURL: plan.rootURL,
                lease: rootAccess,
                mutations: mutations,
                proposedManifest: manifest
            )
        } catch {
            if sourceScope.authorizedRoots[preparation.sourceID]?.url.standardizedFileURL
                != plan.rootURL.standardizedFileURL {
                rootAccess.release()
            }
            throw error
        }
        try await reconciler.reconcile(sourceIDs: [preparation.sourceID])
    }

    func prepareTrackRelocation(
        trackID: UUID,
        selectedURL: URL
    ) async throws -> TrackRelocationProposal {
        guard AudioFormatSupport.playableExtensions.contains(selectedURL.pathExtension.lowercased()) else {
            throw SourceReconnectServiceError.unsupportedAudioFormat(selectedURL.pathExtension)
        }
        guard let track = await repository.fetchTracks(ids: [trackID]).first else {
            throw SourceReconnectServiceError.trackNotFound(trackID)
        }
        guard case let .referenced(locator) = track.mediaLocator else {
            throw SourceReconnectServiceError.trackIsNotReferenced(trackID)
        }
        guard track.availability != .available, locator.sourceMemberships.isEmpty else {
            throw SourceReconnectServiceError.trackIsNotStandaloneMissing(trackID)
        }
        let fileAccess = try acquireAccess(to: selectedURL)
        defer { fileAccess.release() }
        let fingerprint = try Self.fingerprint(selectedURL)
        let duration = await Self.duration(of: selectedURL)
        return TrackRelocationProposal(
            trackID: trackID,
            selectedURL: selectedURL.standardizedFileURL,
            fingerprint: fingerprint,
            duration: duration,
            identityMatches: Self.identityMatches(
                locator.fingerprint,
                selected: fingerprint
            )
        )
    }

    func relocateTrack(
        _ proposal: TrackRelocationProposal,
        confirmedReplacement: Bool
    ) async throws {
        if proposal.requiresReplacementConfirmation, !confirmedReplacement {
            throw SourceReconnectServiceError.replacementConfirmationRequired
        }
        guard let track = await repository.fetchTracks(ids: [proposal.trackID]).first else {
            throw SourceReconnectServiceError.trackNotFound(proposal.trackID)
        }
        guard case var .referenced(locator) = track.mediaLocator else {
            throw SourceReconnectServiceError.trackIsNotReferenced(proposal.trackID)
        }
        guard track.availability != .available, locator.sourceMemberships.isEmpty else {
            throw SourceReconnectServiceError.trackIsNotStandaloneMissing(proposal.trackID)
        }

        let fileAccess = try acquireAccess(to: proposal.selectedURL)
        defer { fileAccess.release() }
        let fingerprint = try Self.fingerprint(proposal.selectedURL)
        guard fingerprint == proposal.fingerprint else {
            throw SourceReconnectServiceError.selectedFileChanged(proposal.selectedURL.path)
        }
        locator.fileBookmarkData = try bookmarkResolver.refreshBookmark(for: proposal.selectedURL)
        locator.lastKnownPath = proposal.selectedURL.path
        locator.fingerprint = fingerprint
        locator.sourceMemberships = memberships(for: proposal.selectedURL)
        locator.primarySourceID = primarySourceID(locator.sourceMemberships)

        let mutation = ReferencedSourceLocatorMutation(
            trackID: track.id,
            locator: locator,
            availability: .available
        )
        let result = await repository.commitReferencedSourceMutations([mutation])
        guard result.failedTrackIDs.isEmpty else {
            throw SourceReconnectServiceError.authorityCommitFailed(result.failedTrackIDs)
        }
        await repository.attachReferencedSourceMutations([mutation])
    }

    private func sourceReconnectMutations(
        sourceID: UUID,
        accepted: [SourceReconnectMatch]
    ) async throws -> [ReferencedSourceLocatorMutation] {
        let allTracks = await repository.fetchTracks(in: nil)
        let tracksByID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
        let acceptedByTrackID = Dictionary(uniqueKeysWithValues: accepted.map { ($0.trackID, $0) })
        var mutations: [ReferencedSourceLocatorMutation] = []

        for track in allTracks {
            guard case var .referenced(locator) = track.mediaLocator,
                  locator.sourceMemberships.contains(where: { $0.sourceID == sourceID }) else {
                continue
            }
            if let match = acceptedByTrackID[track.id] {
                locator.fileBookmarkData = try bookmarkResolver.refreshBookmark(for: match.candidate.url)
                locator.lastKnownPath = match.candidate.url.path
                locator.fingerprint = match.candidate.fingerprint
                locator.sourceMemberships.removeAll { $0.sourceID == sourceID }
                locator.sourceMemberships.append(.init(
                    sourceID: sourceID,
                    relativePath: match.candidate.relativePath
                ))
                locator.sourceMemberships.sort(by: membershipOrder)
                locator.primarySourceID = primarySourceID(locator.sourceMemberships)
                mutations.append(.init(trackID: track.id, locator: locator, availability: .available))
            } else {
                let availability: TrackAvailability = hasReadableAlternative(
                    locator,
                    excluding: sourceID
                ) ? .available : .missing
                mutations.append(.init(trackID: track.id, locator: locator, availability: availability))
            }
        }
        guard accepted.allSatisfy({ tracksByID[$0.trackID] != nil }) else {
            let missing = accepted.first(where: { tracksByID[$0.trackID] == nil })!.trackID
            throw SourceReconnectServiceError.trackNotFound(missing)
        }
        return mutations.sorted { $0.trackID.uuidString < $1.trackID.uuidString }
    }

    private func expectedFiles(
        sourceID: UUID,
        tracks: [Track],
        manifest: ReferencedSourceScanManifest?
    ) -> [SourceReconnectExpectedFile] {
        let manifestByTrackID = (manifest?.entries ?? []).reduce(
            into: [UUID: ReferencedSourceScanEntry]()
        ) { entries, entry in
            guard let trackID = entry.trackID, entries[trackID] == nil else { return }
            entries[trackID] = entry
        }
        return tracks.compactMap { track in
            guard case let .referenced(locator) = track.mediaLocator,
                  let membership = locator.sourceMemberships.first(where: {
                      $0.sourceID == sourceID
                  }) else {
                return nil
            }
            let entry = manifestByTrackID[track.id]
            return SourceReconnectExpectedFile(
                trackID: track.id,
                relativePath: entry?.relativePath ?? membership.relativePath,
                fingerprint: entry?.fingerprint ?? locator.fingerprint,
                duration: track.duration
            )
        }
    }

    private func memberships(for url: URL) -> [ReferencedSourceMembership] {
        sourceScope.authorizedRoots.compactMap { sourceID, root in
            Self.relativePath(url, root: root.url).map {
                ReferencedSourceMembership(sourceID: sourceID, relativePath: $0)
            }
        }.sorted(by: membershipOrder)
    }

    private func hasReadableAlternative(
        _ locator: ReferencedFileLocator,
        excluding sourceID: UUID
    ) -> Bool {
        locator.sourceMemberships.contains { membership in
            guard membership.sourceID != sourceID,
                  let root = sourceScope.authorizedRoots[membership.sourceID]?.url else {
                return false
            }
            return FileManager.default.isReadableFile(
                atPath: root.appendingPathComponent(membership.relativePath).path
            )
        }
    }

    private func acquireAccess(to url: URL) throws -> SecurityScopedResourceLease {
        let didStart = bookmarkResolver.startAccessing(url)
        guard didStart || (!requiresSecurityScope && FileManager.default.isReadableFile(atPath: url.path)) else {
            throw SourceReconnectServiceError.authorizationFailed(url.path)
        }
        return didStart
            ? SecurityScopedResourceLease { [bookmarkResolver] in
                bookmarkResolver.stopAccessing(url)
            }
            : .none
    }

    private func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    private func membershipOrder(
        _ lhs: ReferencedSourceMembership,
        _ rhs: ReferencedSourceMembership
    ) -> Bool {
        if lhs.relativePath.count != rhs.relativePath.count {
            return lhs.relativePath.count < rhs.relativePath.count
        }
        return lhs.sourceID.uuidString < rhs.sourceID.uuidString
    }

    private func primarySourceID(_ memberships: [ReferencedSourceMembership]) -> UUID? {
        memberships.sorted(by: membershipOrder).first?.sourceID
    }

    private nonisolated static func scanCandidates(
        rootURL: URL
    ) async throws -> [SourceReconnectCandidateFile] {
        try await Task.detached(priority: .utility) {
            let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: root.path) else {
                throw SourceReconnectServiceError.invalidCandidateRoot(root.path)
            }
            var pending = [root]
            var visited = Set<String>()
            var candidates: [SourceReconnectCandidateFile] = []
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isRegularFileKey,
                .isPackageKey,
                .isHiddenKey,
                .isSymbolicLinkKey,
                .fileResourceIdentifierKey,
                .volumeUUIDStringKey,
            ]
            while let directory = pending.popLast() {
                try Task.checkCancellation()
                let directoryValues = try directory.resourceValues(
                    forKeys: [.fileResourceIdentifierKey, .volumeUUIDStringKey]
                )
                let key = "\(directoryValues.volumeUUIDString ?? ""):"
                    + String(describing: directoryValues.fileResourceIdentifier)
                guard visited.insert(key).inserted else { continue }
                for child in try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                ) {
                    try Task.checkCancellation()
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isHidden == true || values.isPackage == true { continue }
                    let resolved = values.isSymbolicLink == true
                        ? child.resolvingSymlinksInPath().standardizedFileURL
                        : child.standardizedFileURL
                    guard contains(resolved, root: root) else { continue }
                    if values.isDirectory == true {
                        pending.append(resolved)
                        continue
                    }
                    guard values.isRegularFile == true,
                          AudioFormatSupport.playableExtensions.contains(
                              resolved.pathExtension.lowercased()
                          ),
                          let relative = relativePath(resolved, root: root) else {
                        continue
                    }
                    let fingerprint = try Self.fingerprint(resolved)
                    candidates.append(SourceReconnectCandidateFile(
                        rootURL: root,
                        url: resolved,
                        relativePath: relative,
                        fingerprint: fingerprint,
                        duration: await duration(of: resolved)
                    ))
                }
            }
            return candidates.sorted { $0.relativePath < $1.relativePath }
        }.value
    }

    private nonisolated static func fingerprint(
        _ url: URL
    ) throws -> ReferencedFileFingerprint {
        do {
            return try ReferencedFileIdentityProvider().fingerprint(for: url)
        } catch {
            throw SourceReconnectServiceError.selectedFileUnavailable(url.path)
        }
    }

    private nonisolated static func duration(of url: URL) async -> Double {
        do {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            return duration.isFinite && duration >= 0 ? duration : 0
        } catch {
            return 0
        }
    }

    private nonisolated static func identityMatches(
        _ original: ReferencedFileFingerprint?,
        selected: ReferencedFileFingerprint
    ) -> Bool {
        guard let original else { return false }
        if let identity = original.identity,
           identity.volumeUUID?.isEmpty == false,
           identity.resourceIdentifierArchive?.isEmpty == false {
            return identity == selected.identity
        }
        return original.fileSize == selected.fileSize
            && abs(original.modifiedAt - selected.modifiedAt) < 0.001
    }

    private nonisolated static func contains(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private nonisolated static func relativePath(_ url: URL, root: URL) -> String? {
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard contains(candidate, root: base), candidate.path != base.path else { return nil }
        return String(candidate.path.dropFirst(base.path.count + 1))
    }
}

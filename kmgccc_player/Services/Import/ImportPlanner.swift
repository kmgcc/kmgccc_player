//
//  ImportPlanner.swift
//  kmgccc_player
//
//  §16: decision side of the Planner/Committer split. Owns input-plan
//  interpretation, identity-reuse orchestration (via TrackIdentityResolver),
//  NCM conversion dispatch, resolved-file coalescing, dedup snapshots,
//  candidate preparation and placement resolution. It never presents UI: the
//  import service applies the storage-mode duplicate policy after planning.
//  Planning is side-effect free with respect
//  to playlist membership and source bindings; those are committed only after
//  the track import succeeds.
//

import CryptoKit
import Foundation

/// §16: planner-owned vocabulary; was a private nested type before extraction.
struct ImportCandidate: Sendable {
    let progressID: String
    let displayName: String
    let fileURL: URL
    let metadata: ImportPreview
    let discoveredFile: ImportDiscoveredFile
    let trackID: UUID?
    let placement: ImportPlacement?
    let existingDuplicateTrackID: UUID?
    let ncmOperationID: UUID?
    let ncmAssociation: NCMConversionAssociation?
    let ncmLocator: ReferencedFileLocator?
    let recoveryTrackID: UUID?
    /// 文件标签 layer captured during candidate preparation (§10.1).
    let embeddedSnapshot: EmbeddedMetadataSnapshot?
    /// Free-form technical properties known before the import task runs
    /// (NCM metadata); the task reads real file properties otherwise.
    let audioPropertiesOverride: TrackAudioProperties?
    /// Advisory compilation suggestions inferred from the directory batch
    /// (§10.4). Suggestion-only: never written back to files.
    let enrichmentSuggestions: [EnrichmentSuggestion]?

    nonisolated init(
        progressID: String,
        displayName: String,
        fileURL: URL,
        metadata: ImportPreview,
        discoveredFile: ImportDiscoveredFile,
        trackID: UUID?,
        placement: ImportPlacement?,
        existingDuplicateTrackID: UUID?,
        ncmOperationID: UUID?,
        ncmAssociation: NCMConversionAssociation?,
        ncmLocator: ReferencedFileLocator?,
        recoveryTrackID: UUID?,
        embeddedSnapshot: EmbeddedMetadataSnapshot? = nil,
        audioPropertiesOverride: TrackAudioProperties? = nil,
        enrichmentSuggestions: [EnrichmentSuggestion]? = nil
    ) {
        self.progressID = progressID
        self.displayName = displayName
        self.fileURL = fileURL
        self.metadata = metadata
        self.discoveredFile = discoveredFile
        self.trackID = trackID
        self.placement = placement
        self.existingDuplicateTrackID = existingDuplicateTrackID
        self.ncmOperationID = ncmOperationID
        self.ncmAssociation = ncmAssociation
        self.ncmLocator = ncmLocator
        self.recoveryTrackID = recoveryTrackID
        self.embeddedSnapshot = embeddedSnapshot
        self.audioPropertiesOverride = audioPropertiesOverride
        self.enrichmentSuggestions = enrichmentSuggestions
    }

    func prepared(trackID: UUID, placement: ImportPlacement) -> ImportCandidate {
        ImportCandidate(
            progressID: progressID,
            displayName: displayName,
            fileURL: fileURL,
            metadata: metadata,
            discoveredFile: discoveredFile,
            trackID: trackID,
            placement: placement,
            existingDuplicateTrackID: existingDuplicateTrackID,
            ncmOperationID: ncmOperationID,
            ncmAssociation: ncmAssociation,
            ncmLocator: ncmLocator,
            recoveryTrackID: recoveryTrackID,
            embeddedSnapshot: embeddedSnapshot,
            audioPropertiesOverride: audioPropertiesOverride,
            enrichmentSuggestions: enrichmentSuggestions
        )
    }
}

/// §16: planner-owned vocabulary; was a private nested type before extraction.
struct ResolvedImportFile: Sendable {
    let progressID: String
    let displayName: String
    let fileURL: URL
    let ncmResult: NCMConversionResult?
    let discoveredFile: ImportDiscoveredFile
    let referencedNCMOutput: ReferencedNCMConversionOutput?
}

struct ExistingTrackMatch: Sendable {
    let id: UUID
    let duration: Double
    let preview: TrackPreview
}

struct ExistingTrackMatchSnapshot: Sendable {
    let matches: [ExistingTrackMatch]
}

struct CandidatePreparationResult: Sendable {
    let index: Int
    let candidate: ImportCandidate
    let duplicateRow: DuplicatePairRow?
}

/// The executable plan handed from planning to persistence. `policyDecision`
/// records how duplicate rows were resolved so the committer (and future
/// passes) can reason about the run without re-deriving it.
struct ImportExecutionPlan {
    enum DuplicatePolicyDecision: Equatable {
        /// No duplicate rows were detected.
        case none
        /// Interactive dialog confirmed; selected rows already folded into placements.
        case userSelected
        /// Automatic mode: similarity matches imported as new tracks.
        case automaticImportAllAsNew
        /// Interactive referenced-mode import: similarity matches reuse the
        /// existing Track and merge the newly selected physical location.
        case automaticReuseExisting
    }

    let reusedTracks: [Track]
    let reusedTrackIDs: Set<UUID>
    let conversions: [ResolvedImportFile]
    let uniqueCandidates: [ImportCandidate]
    let duplicateRows: [DuplicatePairRow]
    let duplicateCandidates: [ImportCandidate]
    let policyDecision: DuplicatePolicyDecision
    let placements: [ImportCandidate]
}

@MainActor
final class ImportPlanner {
    private let repository: LibraryRepositoryProtocol
    private let storageBackend: any LibraryStorageBackend
    private let paths: LibraryPaths
    private let referencedNCMConversionService: ReferencedNCMConversionService?
    private let operationCoordinator: LibraryOperationCoordinator
    private let ncmConversionPipeline: ManagedNCMConversionPipeline

    init(
        repository: LibraryRepositoryProtocol,
        storageBackend: any LibraryStorageBackend,
        paths: LibraryPaths,
        referencedNCMConversionService: ReferencedNCMConversionService?,
        // Kept as a source-compatible parameter for callers created before
        // manual retry cleanup moved to FileImportService's preflight.
        ignoredItemsStore: IgnoredReferencedItemsStore? = nil,
        operationCoordinator: LibraryOperationCoordinator,
        ncmConversionPipeline: ManagedNCMConversionPipeline
    ) {
        self.repository = repository
        self.storageBackend = storageBackend
        self.paths = paths
        self.referencedNCMConversionService = referencedNCMConversionService
        _ = ignoredItemsStore
        self.operationCoordinator = operationCoordinator
        self.ncmConversionPipeline = ncmConversionPipeline
    }

    // MARK: - Input interpretation

    struct InputInterpretation {
        /// Source bindings are part of the final playlist commit, never input
        /// planning, so cancellation cannot leave empty/stale bindings.
        let playlistSourceIDs: Set<UUID>
        let reusedTracks: [Track]
        let reusedTrackIDs: Set<UUID>
        let referencedReuseLocators: [UUID: ReferencedFileLocator]
        let filesToImport: [ImportDiscoveredFile]
        let eligibleNCMFiles: [ImportDiscoveredFile]
    }

    func interpretInputs(
        inputPlan: ImportInputPlan,
        libraryTracks: [Track],
        isManualSelection: Bool,
        session: ImportSession
    ) async -> InputInterpretation {
        let playlistSourceIDs = Set(
            inputPlan.directorySources.map(\.source.id)
                + inputPlan.files.flatMap { $0.memberships.map(\.sourceID) }
        )
        var newFiles: [ImportDiscoveredFile] = []
        var reusedTracks: [Track] = []
        var reusedTrackIDs = Set<UUID>()
        var referencedReuseLocators: [UUID: ReferencedFileLocator] = [:]
        let identityResolver = TrackIdentityResolver()
        // Managed-mode identity reuse matches by canonical source path. Index
        // the library once per import instead of scanning every track per file.
        var existingTracksByCanonicalPath: [String: Track] = [:]
        if storageBackend.mode != .referenced {
            for track in libraryTracks where !track.originalFilePath.isEmpty {
                let canonicalPath = TrackIdentityResolver.canonicalPath(track.originalFilePath)
                if existingTracksByCanonicalPath[canonicalPath] == nil {
                    existingTracksByCanonicalPath[canonicalPath] = track
                }
            }
        }
        for file in inputPlan.files {
            if storageBackend.mode == .referenced {
                guard let fingerprint = file.fingerprint else {
                    newFiles.append(file)
                    continue
                }
                var reuse: DigestTierReuseMatch?
                if let fingerprintMatch = await repository.track(matching: fingerprint) {
                    reuse = DigestTierReuseMatch(
                        track: fingerprintMatch,
                        incomingDigest: nil,
                        computedDigests: [:]
                    )
                } else {
                    reuse = await digestTierReuse(
                        for: file,
                        fingerprint: fingerprint,
                        libraryTracks: libraryTracks,
                        identityResolver: identityResolver
                    )
                }
                guard let reuseTarget = reuse?.track else {
                    newFiles.append(file)
                    continue
                }
                do {
                    let placement = try await storageBackend.makePlacement(
                        for: file,
                        trackID: reuseTarget.id,
                        stagingDirectoryURL: session.stagingDirectoryURL
                    )
                    guard case let .referenced(referencedLocator) = placement else {
                        throw LibraryBackendError.modeMismatch(expected: .referenced, actual: placement.storageKind)
                    }
                    var locator = referencedLocator
                    if let incomingDigest = reuse?.incomingDigest {
                        _ = locator.setContentDigest(
                            incomingDigest,
                            atLocationID: locator.primaryLocationID
                        )
                    }
                    let existingLocator = referencedReuseLocators[reuseTarget.id]
                        ?? reuseTarget.mediaLocator.referencedFile
                    if let existingLocator {
                        for location in existingLocator.locations {
                            locator.mergeLocation(location)
                        }
                    }
                    for (locationID, digest) in (reuse?.computedDigests ?? [:])
                        .sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                        _ = locator.setContentDigest(digest, atLocationID: locationID)
                    }
                    referencedReuseLocators[reuseTarget.id] = locator
                    if reusedTrackIDs.insert(reuseTarget.id).inserted {
                        reusedTracks.append(reuseTarget)
                    }
                } catch {
                    Log.warning("[Import] identity reuse failed track=\(reuseTarget.id.uuidString)", category: .import)
                    newFiles.append(file)
                }
            } else {
                let inputPath = TrackIdentityResolver.canonicalPath(file.url.path)
                var existingTrack = existingTracksByCanonicalPath[inputPath]
                if existingTrack == nil {
                    existingTrack = await provenanceTierReuse(
                        for: file,
                        libraryTracks: libraryTracks,
                        identityResolver: identityResolver
                    )
                }
                guard let existingTrack else {
                    newFiles.append(file)
                    continue
                }
                if reusedTrackIDs.insert(existingTrack.id).inserted {
                    reusedTracks.append(existingTrack)
                }
            }
        }
        operationCoordinator.recordCheckpoint("身份复用完成")
        let filesToImport = newFiles.filter { $0.url.pathExtension.lowercased() != "ncm" }
        let ncmFiles = newFiles.filter { $0.url.pathExtension.lowercased() == "ncm" }
        for failure in inputPlan.failures {
            Log.warning(
                "[Import] input skipped name=\(failure.url.lastPathComponent) reason=\(failure.message)",
                category: .import
            )
        }
        let eligibleNCMFiles = storageBackend.mode == .managed || referencedNCMConversionService != nil
            ? ncmFiles
            : []
        return InputInterpretation(
            playlistSourceIDs: playlistSourceIDs,
            reusedTracks: reusedTracks,
            reusedTrackIDs: reusedTrackIDs,
            referencedReuseLocators: referencedReuseLocators,
            filesToImport: filesToImport,
            eligibleNCMFiles: eligibleNCMFiles
        )
    }

    // MARK: - Conversions

    struct ConversionOutcome {
        let resolvedFiles: [ResolvedImportFile]
        let reusedTracks: [Track]
        let reusedTrackIDs: Set<UUID>
        let failures: [ImportInputFailure]
        /// Managed pipeline finished but cancellation was requested right
        /// after; the caller owns rollback.
        let cancelledAfterManagedConversion: Bool
    }

    func resolveConversions(
        filesToImport: [ImportDiscoveredFile],
        eligibleNCMFiles: [ImportDiscoveredFile],
        reusedTracks: [Track],
        reusedTrackIDs: Set<UUID>,
        session: ImportSession,
        cancellationToken: ImportCancellationToken,
        progressController: BatchImportProgressDialogController
    ) async -> ConversionOutcome {
        var reusedTracks = reusedTracks
        var reusedTrackIDs = reusedTrackIDs
        var failures: [ImportInputFailure] = []

        var resolvedFiles: [ResolvedImportFile] = filesToImport.map {
            ResolvedImportFile(
                progressID: $0.url.path,
                displayName: $0.url.lastPathComponent,
                fileURL: $0.url,
                ncmResult: nil,
                discoveredFile: $0,
                referencedNCMOutput: nil
            )
        }

        if !eligibleNCMFiles.isEmpty, storageBackend.mode == .managed {
            Log.debug("Found \(eligibleNCMFiles.count) managed NCM files to convert", category: .import)
            let results = await ncmConversionPipeline.convertNCMFiles(
                eligibleNCMFiles.map(\.url),
                progressController: progressController,
                session: session,
                cancellationToken: cancellationToken
            )
            if await isImportCancellationRequested(progressController, cancellationToken) {
                return ConversionOutcome(
                    resolvedFiles: resolvedFiles,
                    reusedTracks: reusedTracks,
                    reusedTrackIDs: reusedTrackIDs,
                    failures: failures,
                    cancelledAfterManagedConversion: true
                )
            }
            for output in results {
                guard let result = output.result else { continue }
                resolvedFiles.append(
                    ResolvedImportFile(
                        progressID: output.sourceURL.path,
                        displayName: output.displayName,
                        fileURL: result.audioFileURL,
                        ncmResult: result,
                        discoveredFile: ImportDiscoveredFile(
                            url: result.audioFileURL,
                            memberships: [],
                            primarySourceID: nil,
                            fingerprint: try? ReferencedFileIdentityProvider().fingerprint(for: result.audioFileURL)
                        ),
                        referencedNCMOutput: nil
                    )
                )
            }
        } else if !eligibleNCMFiles.isEmpty, let referencedNCMConversionService {
            for file in eligibleNCMFiles {
                do {
                    try await cancellationToken.checkCancellation()
                    operationCoordinator.recordCheckpoint("NCM 转换 \(file.url.lastPathComponent)")
                    let output = try await referencedNCMConversionService.convert(file)
                    resolvedFiles.append(ResolvedImportFile(
                        progressID: file.url.path,
                        displayName: file.url.lastPathComponent,
                        fileURL: output.result.audioFileURL,
                        ncmResult: output.result,
                        discoveredFile: ImportDiscoveredFile(
                            url: output.result.audioFileURL,
                            memberships: output.locator.allSourceMemberships,
                            primarySourceID: output.locator.primarySourceID,
                            fingerprint: output.locator.fingerprint
                        ),
                        referencedNCMOutput: output
                    ))
                    progressController.updateItem(
                        id: file.url.path,
                        title: output.result.metadata.title,
                        artist: output.result.metadata.artistName,
                        stage: .ncmConversion,
                        status: .success,
                        detail: "NCM 转换完成，等待导入"
                    )
                } catch ReferencedNCMConversionError.committedConversion(let trackID) {
                    if let existing = await repository.fetchTracks(ids: [trackID]).first {
                        if let locator = try? await referencedNCMConversionService.restoreCommittedOutputLocator(for: file) {
                            existing.mediaLocator = .referenced(locator)
                            existing.fileBookmarkData = locator.fileBookmarkData
                            existing.originalFilePath = locator.lastKnownPath
                            existing.availability = .available
                            await repository.persistTrackMetaOnly(
                                existing,
                                reason: "ncmCommittedReuse"
                            )
                        }
                        if reusedTrackIDs.insert(existing.id).inserted {
                            reusedTracks.append(existing)
                        }
                        progressController.updateItem(
                            id: file.url.path,
                            title: existing.title,
                            artist: existing.artist,
                            stage: .ncmConversion,
                            status: .success,
                            detail: "已复用此前转换的歌曲"
                        )
                    }
                } catch {
                    failures.append(.init(
                        url: file.url,
                        message: error.localizedDescription
                    ))
                    progressController.updateItem(
                        id: file.url.path,
                        stage: .ncmConversion,
                        status: .failed,
                        detail: "NCM 转换失败",
                        issueMessage: error.localizedDescription
                    )
                }
            }
        } else {
            progressController.update(
                stage: .convertingNCM,
                progress: FileImportService.progress(for: .convertingNCM, completed: 0, total: 0),
                detail: "未检测到 NCM 文件，跳过转换阶段",
                completedCount: 0,
                totalCount: 0
            )
        }

        // A legacy source folder may contain both the original MP3 product and
        // its NCM input. Once the NCM path is resolved, both entries can point
        // at the same physical output. Collapse that pair before metadata
        // deduplication so differing tags cannot create two Track records.
        resolvedFiles = coalescedResolvedFiles(resolvedFiles)

        return ConversionOutcome(
            resolvedFiles: resolvedFiles,
            reusedTracks: reusedTracks,
            reusedTrackIDs: reusedTrackIDs,
            failures: failures,
            cancelledAfterManagedConversion: false
        )
    }

    // MARK: - Candidate preparation

    struct CandidatePreparation {
        let unique: [ImportCandidate]
        let duplicates: [DuplicatePairRow]
        let duplicateCandidates: [ImportCandidate]
    }

    func prepareCandidates(
        resolvedFiles: [ResolvedImportFile],
        libraryTracks: [Track],
        metadataOverride: ImportMetadataOverride?,
        cancellationToken: ImportCancellationToken,
        progressController: BatchImportProgressDialogController
    ) async -> CandidatePreparation {
        let existingByDedupKey = Dictionary(grouping: libraryTracks) {
            LibraryNormalization.normalizedDedupKey(title: $0.title, artist: $0.artist)
        }
        let existingSnapshots = existingByDedupKey.mapValues { matches in
            ExistingTrackMatchSnapshot(
                matches: matches.map {
                    ExistingTrackMatch(
                        id: $0.id,
                        duration: $0.duration,
                        preview: TrackPreview(
                            title: $0.title,
                            artist: $0.artist,
                            artworkData: $0.artworkData
                        )
                    )
                }
            )
        }

        let prepared = await prepareImportCandidates(
            files: resolvedFiles,
            existingMatches: existingSnapshots,
            metadataOverride: metadataOverride,
            progressController: progressController,
            cancellationToken: cancellationToken
        )

        return CandidatePreparation(
            unique: prepared.unique,
            duplicates: prepared.duplicates,
            duplicateCandidates: prepared.duplicateCandidates
        )
    }

    // MARK: - Placements

    struct PlacementResolution {
        let placements: [ImportCandidate]
        let failures: [ImportInputFailure]
    }

    func resolvePlacements(
        uniqueCandidates: [ImportCandidate],
        selectedDuplicates: [ImportCandidate],
        session: ImportSession,
        progressController: BatchImportProgressDialogController
    ) async -> PlacementResolution {
        let selectedCandidates = uniqueCandidates + selectedDuplicates
        var finalCandidates: [ImportCandidate] = []
        var failures: [ImportInputFailure] = []
        for candidate in selectedCandidates {
            let trackID = candidate.recoveryTrackID ?? UUID()
            do {
                let placement: ImportPlacement
                if let locator = candidate.ncmLocator {
                    placement = .referenced(locator)
                } else {
                    placement = try await storageBackend.makePlacement(
                        for: candidate.discoveredFile,
                        trackID: trackID,
                        stagingDirectoryURL: session.stagingDirectoryURL
                    )
                }
                try storageBackend.validate(placement)
                if let operationID = candidate.ncmOperationID,
                   let referencedNCMConversionService {
                    try await referencedNCMConversionService.associateTrack(
                        operationID: operationID,
                        trackID: trackID
                    )
                }
                finalCandidates.append(candidate.prepared(trackID: trackID, placement: placement))
            } catch {
                failures.append(.init(
                    url: candidate.fileURL,
                    message: error.localizedDescription
                ))
                progressController.updateItem(
                    id: candidate.progressID,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    stage: .importing,
                    status: .failed,
                    detail: "导入失败",
                    issueMessage: error.localizedDescription
                )
            }
        }
        return PlacementResolution(placements: finalCandidates, failures: failures)
    }

    // MARK: - Identity reuse tiers

    private struct DigestTierReuseMatch {
        let track: Track
        let incomingDigest: String?
        let computedDigests: [UUID: String]
    }

    /// Plan §11 tier 4: content-digest matching, consulted only after the
    /// physical-identity lookup missed. Candidates are pre-filtered by exact
    /// byte size before any hashing, so this can never degrade into an
    /// unconditional library-wide digest sweep. Computed digests are carried
    /// into the final reuse locator and persisted with that commit; planning
    /// itself never writes a sidecar.
    private func digestTierReuse(
        for file: ImportDiscoveredFile,
        fingerprint: ReferencedFileFingerprint,
        libraryTracks: [Track],
        identityResolver: TrackIdentityResolver
    ) async -> DigestTierReuseMatch? {
        let candidates = libraryTracks.compactMap { track -> ReferencedTrackCandidate? in
            guard case let .referenced(locator) = track.mediaLocator else { return nil }
            return ReferencedTrackCandidate(
                trackID: track.id,
                locations: locator.locations.map { location in
                    ReferencedLocationSnapshot(
                        id: location.id,
                        fingerprint: location.fingerprint,
                        ncmSourceIdentity: location.ncmSourceIdentity,
                        contentDigest: location.contentDigest,
                        lastKnownPath: location.lastKnownPath
                    )
                }
            )
        }
        let result = await identityResolver.resolveReferencedMatch(
            incomingFingerprint: fingerprint,
            incomingURL: file.url,
            candidates: candidates
        )
        if !result.ambiguousTrackIDs.isEmpty {
            Log.warning(
                "[Import] content digest match ambiguous across \(result.ambiguousTrackIDs.count) tracks; importing as new",
                category: .import
            )
        }
        guard case let .matched(trackID, .contentDigest) = result.resolution,
              let track = libraryTracks.first(where: { $0.id == trackID }) else {
            return nil
        }
        return DigestTierReuseMatch(
            track: track,
            incomingDigest: result.incomingDigest,
            computedDigests: result.computedDigests
        )
    }

    /// Managed-mode fallback after the canonical-path index missed (renamed or
    /// moved original): consult the import provenance captured at commit time.
    private func provenanceTierReuse(
        for file: ImportDiscoveredFile,
        libraryTracks: [Track],
        identityResolver: TrackIdentityResolver
    ) async -> Track? {
        let candidates = libraryTracks.compactMap { track -> ManagedTrackCandidate? in
            let managedAudioURL: URL?
            if case let .managed(libraryRelativePath) = track.mediaLocator {
                managedAudioURL = paths.rootURL.appendingPathComponent(libraryRelativePath)
            } else {
                managedAudioURL = nil
            }
            return ManagedTrackCandidate(
                trackID: track.id,
                originalFilePath: track.originalFilePath,
                provenance: track.importProvenance,
                managedAudioURL: managedAudioURL
            )
        }
        let result = await identityResolver.resolveManagedMatch(
            incomingCanonicalPath: TrackIdentityResolver.canonicalPath(file.url.path),
            incomingFingerprint: file.fingerprint,
            incomingURL: file.url,
            candidates: candidates
        )
        if !result.ambiguousTrackIDs.isEmpty {
            Log.warning(
                "[Import] provenance match ambiguous across \(result.ambiguousTrackIDs.count) tracks; importing as new",
                category: .import
            )
        }
        guard case let .matched(trackID, _) = result.resolution,
              let track = libraryTracks.first(where: { $0.id == trackID }) else {
            return nil
        }
        return track
    }

    // MARK: - Coalescing

    private func coalescedResolvedFiles(_ files: [ResolvedImportFile]) -> [ResolvedImportFile] {
        guard storageBackend.mode == .referenced else { return files }

        var result: [ResolvedImportFile] = []
        var indexByIdentity: [ReferencedPhysicalIdentityKey: Int] = [:]
        for file in files {
            guard let fingerprint = file.discoveredFile.fingerprint else {
                result.append(file)
                continue
            }
            let key = ReferencedPhysicalIdentityKey(fingerprint)
            guard let existingIndex = indexByIdentity[key] else {
                indexByIdentity[key] = result.count
                result.append(file)
                continue
            }

            let existing = result[existingIndex]
            let preferred: ResolvedImportFile
            if existing.referencedNCMOutput == nil, file.referencedNCMOutput != nil {
                preferred = file
            } else {
                preferred = existing
            }
            let mergedMemberships = Array(Set(
                existing.discoveredFile.memberships
                    + file.discoveredFile.memberships
            )).sorted {
                if $0.relativePath.count != $1.relativePath.count {
                    return $0.relativePath.count < $1.relativePath.count
                }
                return $0.sourceID.uuidString < $1.sourceID.uuidString
            }
            let mergedDiscoveredFile = ImportDiscoveredFile(
                url: preferred.discoveredFile.url,
                memberships: mergedMemberships,
                primarySourceID: preferred.discoveredFile.primarySourceID
                    ?? existing.discoveredFile.primarySourceID
                    ?? file.discoveredFile.primarySourceID,
                fingerprint: preferred.discoveredFile.fingerprint ?? fingerprint
            )
            result[existingIndex] = ResolvedImportFile(
                progressID: preferred.progressID,
                displayName: preferred.displayName,
                fileURL: preferred.fileURL,
                ncmResult: preferred.ncmResult,
                discoveredFile: mergedDiscoveredFile,
                referencedNCMOutput: preferred.referencedNCMOutput
            )
        }
        return result
    }

    // MARK: - Candidate preparation core

    private func prepareImportCandidates(
        files: [ResolvedImportFile],
        existingMatches: [String: ExistingTrackMatchSnapshot],
        metadataOverride: ImportMetadataOverride?,
        progressController: BatchImportProgressDialogController,
        cancellationToken: ImportCancellationToken
    ) async -> (
        unique: [ImportCandidate],
        duplicates: [DuplicatePairRow],
        duplicateCandidates: [ImportCandidate]
    ) {
        guard !files.isEmpty else { return ([], [], []) }

        progressController.update(
            stage: .readingMetadata,
            progress: FileImportService.progress(for: .readingMetadata, completed: 0, total: files.count),
            detail: "正在解析歌曲元数据并检查重复项",
            completedCount: 0,
            totalCount: files.count
        )

        var orderedResults = Array<CandidatePreparationResult?>(repeating: nil, count: files.count)
        var iterator = Array(files.enumerated()).makeIterator()
        let maxConcurrent = PerAudioFileImportTask.metadataConcurrency(for: files.count)
        var completedCount = 0

        await withTaskGroup(of: CandidatePreparationResult.self) { group in
            for _ in 0..<min(maxConcurrent, files.count) {
                guard let (index, file) = iterator.next() else { break }
                progressController.updateItem(
                    id: file.progressID,
                    stage: .metadata,
                    status: .active,
                    detail: "正在读取歌曲标题、歌手和专辑信息"
                )
                group.addTask {
                    await Self.buildCandidatePreparationResult(
                        index: index,
                        file: file,
                        existingMatches: existingMatches,
                        metadataOverride: metadataOverride,
                        cancellationToken: cancellationToken
                    )
                }
            }

            while let output = await group.next() {
                orderedResults[output.index] = output
                completedCount += 1

                progressController.update(
                    stage: .readingMetadata,
                    progress: FileImportService.progress(
                        for: .readingMetadata,
                        completed: completedCount,
                        total: files.count
                    ),
                    detail: "已解析 \(completedCount) / \(files.count) 首歌曲",
                    completedCount: completedCount,
                    totalCount: files.count
                )

                let itemStatus: BatchImportItemStatus = output.duplicateRow == nil ? .success : .warning
                let itemDetail = output.duplicateRow == nil
                    ? "歌曲信息解析完成，未发现重复"
                    : "检测到重复歌曲，等待用户选择"
                progressController.updateItem(
                    id: output.candidate.progressID,
                    title: output.candidate.metadata.title,
                    artist: output.candidate.metadata.artist,
                    stage: .duplicateCheck,
                    status: await isImportCancellationRequested(progressController, cancellationToken) ? .cancelled : itemStatus,
                    detail: await isImportCancellationRequested(progressController, cancellationToken) ? "用户已取消" : itemDetail
                )

                if await isImportCancellationRequested(progressController, cancellationToken) {
                    group.cancelAll()
                    continue
                }

                if let (index, file) = iterator.next() {
                    progressController.updateItem(
                        id: file.progressID,
                        stage: .metadata,
                        status: .active,
                        detail: "正在读取歌曲标题、歌手和专辑信息"
                    )
                    group.addTask {
                        await Self.buildCandidatePreparationResult(
                            index: index,
                            file: file,
                            existingMatches: existingMatches,
                            metadataOverride: metadataOverride,
                            cancellationToken: cancellationToken
                        )
                    }
                }
            }
        }

        var uniqueCandidates: [ImportCandidate] = []
        var duplicateRows: [DuplicatePairRow] = []
        var duplicateCandidates: [ImportCandidate] = []

        for output in orderedResults.compactMap({ $0 }) {
            if let duplicateRow = output.duplicateRow {
                duplicateRows.append(duplicateRow)
                duplicateCandidates.append(output.candidate)
            } else {
                uniqueCandidates.append(output.candidate)
            }
        }

        let inferredSuggestions = Self.folderInferenceSuggestions(from: uniqueCandidates + duplicateCandidates)
        if !inferredSuggestions.isEmpty {
            uniqueCandidates = Self.attachingSuggestions(inferredSuggestions, to: uniqueCandidates)
            duplicateCandidates = Self.attachingSuggestions(inferredSuggestions, to: duplicateCandidates)
        }

        return (uniqueCandidates, duplicateRows, duplicateCandidates)
    }

    // MARK: - §10.3/§10.4 evidence helpers

    nonisolated private static func embeddedSnapshot(
        from fields: ImportMetadataExtractor.ExtractedMetadataFields,
        durationSeconds: Double
    ) -> EmbeddedMetadataSnapshot? {
        embeddedSnapshot(
            title: fields.title,
            artist: fields.artist,
            album: fields.album,
            albumArtist: fields.albumArtist,
            releaseYear: fields.releaseYear,
            compilation: fields.compilation,
            musicBrainzReleaseID: fields.musicBrainzReleaseID,
            durationSeconds: durationSeconds
        )
    }

    nonisolated private static func embeddedSnapshot(
        title: String?,
        artist: String?,
        album: String?,
        albumArtist: String?,
        releaseYear: Int? = nil,
        compilation: Bool? = nil,
        musicBrainzReleaseID: String? = nil,
        durationSeconds: Double
    ) -> EmbeddedMetadataSnapshot? {
        let hasAnyValue = title != nil || artist != nil || album != nil || albumArtist != nil
            || releaseYear != nil || compilation != nil || musicBrainzReleaseID != nil
        guard hasAnyValue else { return nil }
        return EmbeddedMetadataSnapshot(
            title: title,
            artistDisplay: artist,
            album: album,
            albumArtist: albumArtist,
            releaseYear: releaseYear,
            compilation: compilation,
            musicBrainzReleaseID: musicBrainzReleaseID,
            durationSeconds: durationSeconds > 0 ? durationSeconds : nil,
            capturedAt: Date()
        )
    }

    /// NCM containers expose bitrate/format/duration in their decrypted
    /// header, so the converted output's technical properties are free data.
    nonisolated static func audioProperties(fromNCM metadata: NCMMetadata) -> TrackAudioProperties {
        let bitrateKbps: Int? = {
            guard metadata.bitrate > 0 else { return nil }
            return metadata.bitrate >= 1000 ? metadata.bitrate / 1000 : metadata.bitrate
        }()
        return TrackAudioProperties(
            format: metadata.format.isEmpty ? nil : metadata.format.uppercased(),
            codec: metadata.format.isEmpty ? nil : metadata.format.uppercased(),
            bitrateKbps: bitrateKbps,
            sampleRateHz: nil,
            bitDepth: nil,
            channelCount: nil
        )
    }

    /// §10.4 folder inference, suggestion-only: a directory batch sharing one
    /// normalized album with ≥2 distinct track artists and no explicit
    /// compilation marker may be a compilation. Emits at most one advisory
    /// suggestion per affected track; ids are derived from the canonical file
    /// path so re-running the pass never duplicates stored entries.
    nonisolated static func folderInferenceSuggestions(
        from candidates: [ImportCandidate],
        now: Date = Date()
    ) -> [String: [EnrichmentSuggestion]] {
        struct BatchKey: Hashable {
            let directoryPath: String
            let albumKey: String
        }

        var batches: [BatchKey: [ImportCandidate]] = [:]
        for candidate in candidates {
            guard candidate.embeddedSnapshot?.compilation == nil else { continue }
            let albumKey = LibraryNormalization.normalizedAlbumKey(album: candidate.metadata.album)
            guard !albumKey.isEmpty,
                  albumKey != LibraryNormalization.normalizedAlbumKey(album: nil) else { continue }
            let key = BatchKey(
                directoryPath: TrackIdentityResolver.canonicalPath(
                    candidate.fileURL.deletingLastPathComponent().path
                ),
                albumKey: albumKey
            )
            batches[key, default: []].append(candidate)
        }

        var results: [String: [EnrichmentSuggestion]] = [:]
        for batch in batches.values where batch.count >= 2 {
            let distinctArtists = Set(batch.map {
                LibraryNormalization.normalizeArtist($0.metadata.artist)
            })
            guard distinctArtists.count >= 2 else { continue }

            for candidate in batch {
                let suggestion = EnrichmentSuggestion(
                    id: stableSuggestionID(
                        filePath: TrackIdentityResolver.canonicalPath(candidate.fileURL.path),
                        albumKey: LibraryNormalization.normalizedAlbumKey(album: candidate.metadata.album)
                    ),
                    source: "folder-inference",
                    album: candidate.metadata.album.isEmpty ? nil : candidate.metadata.album,
                    compilation: true,
                    confidence: 0.6,
                    createdAt: now
                )
                results[candidate.progressID, default: []].append(suggestion)
            }
        }
        return results
    }

    nonisolated private static func attachingSuggestions(
        _ suggestionsByProgressID: [String: [EnrichmentSuggestion]],
        to candidates: [ImportCandidate]
    ) -> [ImportCandidate] {
        candidates.map { candidate in
            guard let suggestions = suggestionsByProgressID[candidate.progressID] else {
                return candidate
            }
            return ImportCandidate(
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                fileURL: candidate.fileURL,
                metadata: candidate.metadata,
                discoveredFile: candidate.discoveredFile,
                trackID: candidate.trackID,
                placement: candidate.placement,
                existingDuplicateTrackID: candidate.existingDuplicateTrackID,
                ncmOperationID: candidate.ncmOperationID,
                ncmAssociation: candidate.ncmAssociation,
                ncmLocator: candidate.ncmLocator,
                recoveryTrackID: candidate.recoveryTrackID,
                embeddedSnapshot: candidate.embeddedSnapshot,
                audioPropertiesOverride: candidate.audioPropertiesOverride,
                enrichmentSuggestions: suggestions
            )
        }
    }

    nonisolated private static func stableSuggestionID(filePath: String, albumKey: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(filePath)|\(albumKey)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated private static func buildCandidatePreparationResult(
        index: Int,
        file: ResolvedImportFile,
        existingMatches: [String: ExistingTrackMatchSnapshot],
        metadataOverride: ImportMetadataOverride?,
        cancellationToken: ImportCancellationToken
    ) async -> CandidatePreparationResult {
        if (try? await cancellationToken.checkCancellation()) == nil {
            let preview = ImportPreview(
                title: file.displayName,
                artist: "",
                album: "",
                albumArtist: nil,
                duration: 0,
                lyrics: nil,
                artworkData: nil
            )
            return CandidatePreparationResult(
                index: index,
                candidate: ImportCandidate(
                    progressID: file.progressID,
                    displayName: file.displayName,
                    fileURL: file.fileURL,
                    metadata: preview,
                    discoveredFile: file.discoveredFile,
                    trackID: nil,
                    placement: nil,
                    existingDuplicateTrackID: nil,
                    ncmOperationID: file.referencedNCMOutput?.operationID,
                    ncmAssociation: file.referencedNCMOutput?.association,
                    ncmLocator: file.referencedNCMOutput?.locator,
                    recoveryTrackID: file.referencedNCMOutput?.trackID
                ),
                duplicateRow: nil
            )
        }
        let preview: ImportPreview
        var embeddedSnapshot: EmbeddedMetadataSnapshot?
        var audioPropertiesOverride: TrackAudioProperties?
        if let ncmResult = file.ncmResult {
            let normalizedCoverData = ncmResult.coverData.flatMap {
                ArtworkDataNormalizer.normalizedJPEGData(
                    from: $0,
                    maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
                )
            }
            preview = ImportPreview(
                title: ncmResult.metadata.title,
                artist: ncmResult.metadata.artistName,
                album: ncmResult.metadata.album,
                albumArtist: nil,
                duration: ncmResult.metadata.durationSeconds,
                lyrics: nil,
                artworkData: normalizedCoverData,
                artistCredits: TrackCredit.fromNCMArtists(ncmResult.metadata.artist)
            )
            embeddedSnapshot = Self.embeddedSnapshot(
                title: ncmResult.metadata.title,
                artist: ncmResult.metadata.artistName,
                album: ncmResult.metadata.album,
                albumArtist: nil,
                durationSeconds: ncmResult.metadata.durationSeconds
            )
            audioPropertiesOverride = Self.audioProperties(fromNCM: ncmResult.metadata)
        } else {
            let raw = await ImportMetadataExtractor.extractMetadata(from: file.fileURL)
            if (try? await cancellationToken.checkCancellation()) == nil {
                let preview = ImportPreview(
                    title: file.displayName,
                    artist: "",
                    album: "",
                    albumArtist: nil,
                    duration: 0,
                    lyrics: nil,
                    artworkData: nil
                )
                return CandidatePreparationResult(
                    index: index,
                    candidate: ImportCandidate(
                        progressID: file.progressID,
                        displayName: file.displayName,
                        fileURL: file.fileURL,
                        metadata: preview,
                        discoveredFile: file.discoveredFile,
                        trackID: nil,
                        placement: nil,
                        existingDuplicateTrackID: nil,
                        ncmOperationID: file.referencedNCMOutput?.operationID,
                        ncmAssociation: file.referencedNCMOutput?.association,
                        ncmLocator: file.referencedNCMOutput?.locator,
                        recoveryTrackID: file.referencedNCMOutput?.trackID
                    ),
                    duplicateRow: nil
                )
        }

        // §10.1 projection: the extracted tag values form the 文件标签
            // layer; filename fallback stays tier 4. With no other layers
            // present this reproduces today's preview byte-for-byte. The
            // fallback mirrors extractMetadata's own extension-stripped
            // default so the no-tag path stays identical.
            embeddedSnapshot = Self.embeddedSnapshot(from: raw.tagFields, durationSeconds: raw.duration)
            let projected = EffectiveMetadata.project(
                embedded: embeddedSnapshot,
                fileNameFallback: file.fileURL.deletingPathExtension().lastPathComponent
            )
            preview = ImportPreview(
                title: projected.title,
                artist: projected.artistDisplay ?? NSLocalizedString("library.unknown_artist", comment: ""),
                album: projected.album ?? "",
                albumArtist: raw.albumArtist,
                duration: raw.duration,
                lyrics: raw.lyrics,
                artworkData: nil
            )
        }

        let effectivePreview = applyingMetadataOverride(metadataOverride, to: preview)
        let candidate = ImportCandidate(
            progressID: file.progressID,
            displayName: file.displayName,
            fileURL: file.fileURL,
            metadata: effectivePreview,
            discoveredFile: file.discoveredFile,
            trackID: nil,
            placement: nil,
            existingDuplicateTrackID: nil,
            ncmOperationID: file.referencedNCMOutput?.operationID,
            ncmAssociation: file.referencedNCMOutput?.association,
            ncmLocator: file.referencedNCMOutput?.locator,
            recoveryTrackID: file.referencedNCMOutput?.trackID,
            embeddedSnapshot: embeddedSnapshot,
            audioPropertiesOverride: audioPropertiesOverride
        )
        let dedupKey = LibraryNormalization.normalizedDedupKey(
            title: effectivePreview.title,
            artist: effectivePreview.artist
        )

        let groupMatches = existingMatches[dedupKey]?.matches ?? []
        let classification = TrackIdentityResolver.classifyMetadataSimilarity(
            dedupKey: dedupKey,
            incomingDuration: effectivePreview.duration,
            candidates: groupMatches.map { SimilarityCandidate(trackID: $0.id, duration: $0.duration) }
        )
        guard case let .possibleDuplicate(existingTrackIDs) = classification else {
            return CandidatePreparationResult(index: index, candidate: candidate, duplicateRow: nil)
        }

        let matchesByID = Dictionary(uniqueKeysWithValues: groupMatches.map { ($0.id, $0) })

        let duplicateCandidate = ImportCandidate(
            progressID: candidate.progressID,
            displayName: candidate.displayName,
            fileURL: candidate.fileURL,
            metadata: candidate.metadata,
            discoveredFile: candidate.discoveredFile,
            trackID: candidate.trackID,
            placement: candidate.placement,
            existingDuplicateTrackID: existingTrackIDs.first,
            ncmOperationID: candidate.ncmOperationID,
            ncmAssociation: candidate.ncmAssociation,
            ncmLocator: candidate.ncmLocator,
            recoveryTrackID: candidate.recoveryTrackID,
            embeddedSnapshot: candidate.embeddedSnapshot,
            audioPropertiesOverride: candidate.audioPropertiesOverride,
            enrichmentSuggestions: candidate.enrichmentSuggestions
        )

        let duplicateRow = DuplicatePairRow(
            id: file.progressID,
            fileURL: file.fileURL,
            incoming: effectivePreview,
            existing: existingTrackIDs.first.flatMap { matchesByID[$0]?.preview },
            existingCount: existingTrackIDs.count,
            dedupKey: dedupKey
        )
        return CandidatePreparationResult(
            index: index,
            candidate: duplicateCandidate,
            duplicateRow: duplicateRow
        )
    }

    nonisolated private static func applyingMetadataOverride(
        _ metadataOverride: ImportMetadataOverride?,
        to preview: ImportPreview
    ) -> ImportPreview {
        guard let metadataOverride, !metadataOverride.isEmpty else { return preview }

        let artistOverride = metadataOverride.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumOverride = metadataOverride.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveArtist: String
        let effectiveAlbumArtist: String?
        let effectiveArtistCredits: [TrackCredit]?
        if let artistOverride, !artistOverride.isEmpty {
            effectiveArtist = artistOverride
            effectiveAlbumArtist = artistOverride
            effectiveArtistCredits = [TrackCredit(displayName: artistOverride, role: .primary)]
        } else {
            effectiveArtist = preview.artist
            effectiveAlbumArtist = preview.albumArtist
            effectiveArtistCredits = preview.artistCredits
        }
        let effectiveAlbum: String
        if let albumOverride, !albumOverride.isEmpty {
            effectiveAlbum = albumOverride
        } else {
            effectiveAlbum = preview.album
        }

        return ImportPreview(
            title: preview.title,
            artist: effectiveArtist,
            album: effectiveAlbum,
            albumArtist: effectiveAlbumArtist,
            duration: preview.duration,
            lyrics: preview.lyrics,
            artworkData: preview.artworkData,
            artistCredits: effectiveArtistCredits
        )
    }
}

/// Same semantics as FileImportService's helper: a dialog-level cancel request
/// is promoted into the token so every worker observes it.
private func isImportCancellationRequested(
    _ progressController: BatchImportProgressDialogController,
    _ cancellationToken: ImportCancellationToken
) async -> Bool {
    if progressController.isCancellationRequested {
        await cancellationToken.requestCancel()
        return true
    }
    return await cancellationToken.isCancelled || Task.isCancelled
}

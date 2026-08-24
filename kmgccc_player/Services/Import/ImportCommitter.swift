//
//  ImportCommitter.swift
//  kmgccc_player
//
//  §16: persistence side of the Planner/Committer split. Owns batch execution,
//  staged-audio commit, library/playlist save, NCM markCommitted wiring,
//  cancellation rollback (via ImportRollbackService) and residue cleanup.
//  Decision-making lives in ImportPlanner; this type only executes.
//

import Foundation

/// §16: committer-owned vocabulary; was a private nested type before extraction.
struct ImportedTrackRecord {
    let progressID: String
    let displayName: String
    let track: Track
    let needsLyricsEnrichment: Bool
    let needsCoverEnrichment: Bool
    let needsTrackMetadataEnrichment: Bool
    let needsArtistMetadataEnrichment: Bool
    let needsAlbumMetadataEnrichment: Bool
    let needsArtistArtworkEnrichment: Bool
    let needsAlbumArtworkEnrichment: Bool

    var needsAnyEnrichment: Bool {
        needsLyricsEnrichment
            || needsCoverEnrichment
            || needsTrackMetadataEnrichment
            || needsArtistMetadataEnrichment
            || needsAlbumMetadataEnrichment
            || needsArtistArtworkEnrichment
            || needsAlbumArtworkEnrichment
    }
}

struct ImportBatchResult {
    let records: [ImportedTrackRecord]
    let createdTrackIDs: Set<UUID>
    let failures: [ImportInputFailure]
    let cancelled: Bool
}

@MainActor
final class ImportCommitter {
    private let repository: LibraryRepositoryProtocol
    private let libraryService: LocalLibraryService
    private let storageBackend: any LibraryStorageBackend
    private let paths: LibraryPaths
    private let importEnrichmentService: ImportEnrichmentService
    private let referencedNCMConversionService: ReferencedNCMConversionService?

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService,
        storageBackend: any LibraryStorageBackend,
        paths: LibraryPaths,
        importEnrichmentService: ImportEnrichmentService,
        referencedNCMConversionService: ReferencedNCMConversionService?
    ) {
        self.repository = repository
        self.libraryService = libraryService
        self.storageBackend = storageBackend
        self.paths = paths
        self.importEnrichmentService = importEnrichmentService
        self.referencedNCMConversionService = referencedNCMConversionService
    }

    // MARK: - Batch execution

    func executeBatch(
        _ candidates: [ImportCandidate],
        progressController: BatchImportProgressDialogController,
        enrichmentMode: ImportEnrichmentMode,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> ImportBatchResult {
        await importCandidatesWithProgress(
            candidates,
            progressController: progressController,
            enrichmentMode: enrichmentMode,
            session: session,
            cancellationToken: cancellationToken
        )
    }

    private func importCandidatesWithProgress(
        _ candidates: [ImportCandidate],
        progressController: BatchImportProgressDialogController,
        enrichmentMode: ImportEnrichmentMode,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> ImportBatchResult {
        guard !candidates.isEmpty else {
            return ImportBatchResult(records: [], createdTrackIDs: [], failures: [], cancelled: false)
        }

        var orderedRecords = Array<ImportedTrackRecord?>(repeating: nil, count: candidates.count)
        var iterator = Array(candidates.enumerated()).makeIterator()
        let maxConcurrent = PerAudioFileImportTask.importConcurrency(for: candidates.count)
        var processedCount = 0
        var importedCount = 0
        var failedCount = 0
        var createdTrackIDs: Set<UUID> = []
        var failures: [ImportInputFailure] = []
        var cancelled = false
        let stagingDirectoryURL = session.stagingDirectoryURL

        await withTaskGroup(of: ImportTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, candidates.count) {
                guard let (index, candidate) = iterator.next() else { break }
                progressController.updateItem(
                    id: candidate.progressID,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    stage: .importing,
                    status: .active,
                    detail: "正在导入歌曲文件与内嵌信息"
                )
                group.addTask {
                    await PerAudioFileImportTask.performImportTask(
                        index: index,
                        candidate: candidate,
                        stagingDirectoryURL: stagingDirectoryURL,
                        cancellationToken: cancellationToken
                    )
                }
            }

            while let output = await group.next() {
                processedCount += 1
                createdTrackIDs.insert(output.trackID)

                if let payload = output.payload {
                    if case let .managed(relativePath) = payload.mediaLocator,
                       let stagedAudioURL = payload.stagedAudioURL {
                        session.registerStagedTrack(ImportStagedTrackFile(
                            trackID: payload.id,
                            stagedAudioURL: stagedAudioURL,
                            libraryRelativePath: relativePath
                        ))
                    }
                    importedCount += 1
                    let track = makeTrack(from: payload)
                    orderedRecords[output.index] = ImportedTrackRecord(
                        progressID: output.progressID,
                        displayName: output.displayName,
                        track: track,
                        needsLyricsEnrichment: output.needsLyricsEnrichment,
                        needsCoverEnrichment: output.needsCoverEnrichment,
                        needsTrackMetadataEnrichment: output.needsTrackMetadataEnrichment,
                        needsArtistMetadataEnrichment: output.needsArtistMetadataEnrichment,
                        needsAlbumMetadataEnrichment: output.needsAlbumMetadataEnrichment,
                        needsArtistArtworkEnrichment: output.needsArtistArtworkEnrichment,
                        needsAlbumArtworkEnrichment: output.needsAlbumArtworkEnrichment
                    )

                    let needsEnrichment = output.needsLyricsEnrichment
                        || output.needsCoverEnrichment
                        || output.needsTrackMetadataEnrichment
                        || output.needsArtistMetadataEnrichment
                        || output.needsAlbumMetadataEnrichment
                        || output.needsArtistArtworkEnrichment
                        || output.needsAlbumArtworkEnrichment
                    let detail = needsEnrichment
                        ? ImportImmediateEnrichmentEngine.pendingEnrichmentDetail(
                            needsLyrics: output.needsLyricsEnrichment,
                            needsCover: output.needsCoverEnrichment,
                            needsTrackMetadata: output.needsTrackMetadataEnrichment,
                            needsArtistMetadata: output.needsArtistMetadataEnrichment,
                            needsAlbumMetadata: output.needsAlbumMetadataEnrichment,
                            needsArtistArtwork: output.needsArtistArtworkEnrichment,
                            needsAlbumArtwork: output.needsAlbumArtworkEnrichment,
                            deferred: enrichmentMode.defersEnrichment
                        )
                        : "歌曲文件已就绪，已有歌词与封面"
                    progressController.updateItem(
                        id: output.progressID,
                        title: output.metadata.title,
                        artist: output.metadata.artist,
                        stage: needsEnrichment ? .enrichingMetadata : .importing,
                        status: needsEnrichment ? .waiting : .success,
                        detail: detail
                    )
                } else {
                    failedCount += 1
                    failures.append(.init(
                        url: candidates[output.index].fileURL,
                        message: output.errorDescription ?? "文件复制或解析阶段失败"
                    ))
                    progressController.updateItem(
                        id: output.progressID,
                        title: output.metadata.title,
                        artist: output.metadata.artist,
                        stage: .importing,
                        status: .failed,
                        detail: "导入失败",
                        issueMessage: output.errorDescription ?? "文件复制或解析阶段失败"
                    )
                }

                let detail =
                    failedCount == 0
                    ? "已导入 \(importedCount) / \(candidates.count)"
                    : "已导入 \(importedCount) / \(candidates.count)，失败 \(failedCount) 首"
                progressController.update(
                    stage: .importingFiles,
                    progress: FileImportService.progress(
                        for: .importingFiles,
                        completed: processedCount,
                        total: candidates.count
                    ),
                    detail: detail,
                    completedCount: processedCount,
                    totalCount: candidates.count
                )

                if await isImportCancellationRequested(progressController, cancellationToken) {
                    cancelled = true
                    group.cancelAll()
                    while let (_, skippedCandidate) = iterator.next() {
                        progressController.updateItem(
                            id: skippedCandidate.progressID,
                            title: skippedCandidate.metadata.title,
                            artist: skippedCandidate.metadata.artist,
                            stage: .importing,
                            status: .cancelled,
                            detail: "用户已取消，未开始导入"
                        )
                    }
                    continue
                }

                if let (index, candidate) = iterator.next() {
                    progressController.updateItem(
                        id: candidate.progressID,
                        title: candidate.metadata.title,
                        artist: candidate.metadata.artist,
                        stage: .importing,
                        status: .active,
                        detail: "正在导入歌曲文件与内嵌信息"
                    )
                    group.addTask {
                        await PerAudioFileImportTask.performImportTask(
                            index: index,
                            candidate: candidate,
                            stagingDirectoryURL: stagingDirectoryURL,
                            cancellationToken: cancellationToken
                        )
                    }
                }
            }
        }

        return ImportBatchResult(
            records: orderedRecords.compactMap { $0 },
            createdTrackIDs: createdTrackIDs,
            failures: failures,
            cancelled: cancelled
        )
    }

    // MARK: - Save

    func saveImportedTracks(
        _ importedTracks: [Track],
        to playlist: Playlist?,
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> Bool {
        progressController.update(
            stage: .savingLibrary,
            progress: FileImportService.progress(for: .savingLibrary, completed: 0, total: 2),
            detail: "正在提交导入文件",
            completedCount: 0,
            totalCount: 2
        )

        guard !(await isImportCancellationRequested(progressController, cancellationToken)) else {
            return false
        }

        do {
            try await commitStagedAudioFiles(
                for: Set(importedTracks.map(\.id)),
                session: session,
                cancellationToken: cancellationToken
            )
        } catch is CancellationError {
            return false
        } catch {
            Log.error(
                "[Import] failed to commit staged audio files: \(error.localizedDescription)",
                category: .import
            )
            return false
        }

        guard !(await isImportCancellationRequested(progressController, cancellationToken)) else {
            return false
        }

        let referencedNCMConversionService = self.referencedNCMConversionService
        let tracksByID = Dictionary(uniqueKeysWithValues: importedTracks.map { ($0.id, $0) })
        let commitResult = await repository.commitImportedTracks(importedTracks) { persistedIDs in
            guard let referencedNCMConversionService else { return Set(persistedIDs) }
            var visible = Set<UUID>()
            for trackID in persistedIDs {
                guard let operationID = tracksByID[trackID]?.ncmConversionAssociation?.operationID else {
                    visible.insert(trackID)
                    continue
                }
                do {
                    try await referencedNCMConversionService.markCommitted(
                        operationID: operationID,
                        trackID: trackID
                    )
                    visible.insert(trackID)
                } catch {
                    Log.error(
                        "[Import] NCM registry commit failed operation=\(operationID.uuidString)",
                        category: .import
                    )
                }
            }
            return visible
        }
        let persistedIDs = Set(commitResult.persistedTrackIDs)
        let persistedTracks = importedTracks.filter { persistedIDs.contains($0.id) }
        guard !persistedTracks.isEmpty else { return false }
        session.markCommitted(trackIDs: persistedTracks.map(\.id))
        progressController.update(
            stage: .savingLibrary,
            progress: FileImportService.progress(for: .savingLibrary, completed: 1, total: 2),
            detail: "歌曲已写入资料库，正在加入播放列表",
            completedCount: 1,
            totalCount: 2
        )

        if !persistedTracks.isEmpty, let playlist {
            await repository.addTracks(persistedTracks, to: playlist)
            await storageBackend.recordSourceMemberships(persistedTracks, playlistID: playlist.id)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: FileImportService.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )
        return true
    }

    private func commitStagedAudioFiles(
        for trackIDs: Set<UUID>,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async throws {
        guard !trackIDs.isEmpty else { return }
        if storageBackend.mode == .referenced {
            guard session.stagedFiles(for: trackIDs).isEmpty else {
                throw LibraryBackendError.modeMismatch(expected: .referenced, actual: .managed)
            }
            return
        }
        let stagedFiles = session.stagedFiles(for: trackIDs)
        guard stagedFiles.count == trackIDs.count else {
            let missingCount = trackIDs.count - stagedFiles.count
            throw NSError(
                domain: "FileImportService.ImportSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(missingCount) staged import files"]
            )
        }

        let capturedPaths = paths
        try await Task.detached(priority: .userInitiated) { @Sendable in
            let fileManager = FileManager.default
            try capturedPaths.createRequiredDirectories(fileManager: fileManager)

            for file in stagedFiles {
                try await cancellationToken.checkCancellation()
                guard let destinationURL = capturedPaths.libraryURL(
                    from: file.libraryRelativePath
                ) else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let destinationFolder = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: destinationFolder,
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                if fileManager.fileExists(atPath: destinationFolder.path),
                   !fileManager.fileExists(atPath: file.stagedAudioURL.path) {
                    throw NSError(
                        domain: "FileImportService.ImportSession",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Staged audio file is missing"]
                    )
                }
                try fileManager.moveItem(at: file.stagedAudioURL, to: destinationURL)
            }
        }.value

        session.markFinalized(trackIDs: stagedFiles.map(\.trackID))
    }

    // MARK: - Rollback & cleanup

    func finishCancelledImport(
        session: ImportSession,
        importedRecords: [ImportedTrackRecord],
        createdTrackIDs: Set<UUID>,
        to playlist: Playlist?,
        progressController: BatchImportProgressDialogController,
        totalCount: Int
    ) async -> [Track] {
        let importedTracks = importedRecords.map(\.track)
        progressController.update(
            stage: .cancelling,
            progress: 0.995,
            detail: "正在回滚本次导入并清理临时文件",
            completedCount: 0,
            totalCount: max(totalCount, importedTracks.count)
        )

        await importEnrichmentService.cancelEnrichment(for: createdTrackIDs.union(Set(importedTracks.map(\.id))))
        let rollbackReport = await ImportRollbackService(
            repository: repository,
            libraryService: libraryService
        ).rollback(
            session: session,
            importedTracks: importedTracks,
            createdTrackIDs: createdTrackIDs,
            reason: "importCancelled"
        )

        let cleanupReport = await cleanupFailedImportResidue(reason: "importCancelled")
        let retainedCount = 0
        let cleanedCount = cleanupReport.deletedCount
        let incompleteCount = createdTrackIDs.count

        progressController.update(
            stage: .cancelled,
            progress: 1.0,
            detail: "已取消，已回滚本次导入并清理临时文件",
            completedCount: retainedCount,
            totalCount: max(totalCount, retainedCount)
        )

        Log.info(
            "[Import] cancelled retained=\(retainedCount) createdTrackDirs=\(createdTrackIDs.count) incomplete=\(incompleteCount) rollbackDb=\(rollbackReport.deletedDatabaseTrackCount) rollbackFolders=\(rollbackReport.deletedTrackFolderCount) rollbackFolderFailures=\(rollbackReport.failedTrackFolderDeleteCount) cleaned=\(cleanedCount) cleanupFailures=\(cleanupReport.failedDeleteCount)",
            category: .import
        )
        try? await Task.sleep(nanoseconds: 700_000_000)
        return []
    }

    @discardableResult
    func cleanupFailedImportResidue(reason: String) async -> TrackDirectoryCleanupReport {
        let tracks = await repository.fetchTracks(in: nil)
        let referencedTrackIDs = Set(tracks.map(\.id))
        let capturedPaths = paths
        let report = await Task.detached(priority: .utility) { @Sendable in
            LibraryMaintenanceService().cleanupFailedImportTrackDirectories(
                tracksRootURL: capturedPaths.tracksRootURL,
                referencedTrackIDs: referencedTrackIDs,
                importActivity: LibraryImportActivitySnapshot(
                    isImporting: false,
                    activeTrackIDs: []
                ),
                reason: reason
            )
        }.value
        return report
    }

    // MARK: - Track construction

    private func makeTrack(from payload: ImportedTrackPayload) -> Track {
        let track = Track(
            id: payload.id,
            title: payload.title,
            artist: payload.artist,
            artistCredits: payload.artistCredits,
            album: payload.album,
            albumArtist: payload.albumArtist,
            duration: payload.duration,
            importedAt: payload.importedAt,
            fileBookmarkData: Data(),
            originalFilePath: payload.originalFilePath,
            mediaLocator: payload.mediaLocator,
            artworkData: payload.artworkData,
            ttmlLyricText: payload.ttmlLyricText,
            lyricsText: payload.lyricsText,
            libraryRootSnapshot: paths.rootURL.path,
            ncmConversionAssociation: payload.ncmConversionAssociation,
            importProvenance: payload.importProvenance,
            audioProperties: payload.audioProperties
        )
        if let suggestions = payload.enrichmentSuggestions, !suggestions.isEmpty {
            var merged = track.enrichmentSuggestions ?? []
            merged.appendDeduplicatingByIDs(suggestions)
            track.enrichmentSuggestions = merged
        }
        return track
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

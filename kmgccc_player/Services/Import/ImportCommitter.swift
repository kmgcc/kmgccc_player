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
    var originalInputFilePaths: [String] = []
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

        if candidates.contains(where: { $0.discoveredFile.mediaSelection != nil }) {
            do { try SharedMediaAssetStore.enableFormat(at: paths) }
            catch {
                return ImportBatchResult(records: [], createdTrackIDs: [], failures: candidates.map {
                    ImportInputFailure(url: $0.fileURL, message: error.localizedDescription)
                }, cancelled: false)
            }
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
                    detail: AudioFormatSupport.isVideoContainer(candidate.fileURL)
                        ? "正在提取音轨和封面" : "正在导入歌曲文件与内嵌信息"
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
                    session.registerStagedAssets(
                        payload.stagedAssets, for: payload.id,
                        generatedAudioURL: payload.generatedReferencedAudioURL
                    )
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
                    track.markMetadataFieldsAsManual(candidates[output.index].manuallyEditedFields)
                    orderedRecords[output.index] = ImportedTrackRecord(
                        progressID: output.progressID,
                        displayName: output.displayName,
                        track: track,
                        originalInputFilePaths: candidates[output.index].originalInputFilePaths,
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
                    let enrichmentIsPending = needsEnrichment && !enrichmentMode.skipsEnrichment
                    let detail: String
                    if !needsEnrichment {
                        detail = "歌曲文件已就绪，已有歌词与封面"
                    } else if enrichmentMode.skipsEnrichment {
                        detail = "保留文件内信息，跳过在线补全"
                    } else {
                        detail = ImportImmediateEnrichmentEngine.pendingEnrichmentDetail(
                            needsLyrics: output.needsLyricsEnrichment,
                            needsCover: output.needsCoverEnrichment,
                            needsTrackMetadata: output.needsTrackMetadataEnrichment,
                            needsArtistMetadata: output.needsArtistMetadataEnrichment,
                            needsAlbumMetadata: output.needsAlbumMetadataEnrichment,
                            needsArtistArtwork: output.needsArtistArtworkEnrichment,
                            needsAlbumArtwork: output.needsAlbumArtworkEnrichment,
                            deferred: enrichmentMode.defersEnrichment
                        )
                    }
                    progressController.updateItem(
                        id: output.progressID,
                        title: output.metadata.title,
                        artist: output.metadata.artist,
                        stage: enrichmentIsPending ? .enrichingMetadata : .importing,
                        status: enrichmentIsPending ? .waiting : .success,
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
                        detail: AudioFormatSupport.isVideoContainer(candidate.fileURL)
                            ? "正在提取音轨和封面" : "正在导入歌曲文件与内嵌信息"
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

        let groupedIndices = Dictionary(grouping: candidates.indices.filter {
            candidates[$0].discoveredFile.mediaSelection != nil
        }, by: { candidates[$0].discoveredFile.mediaSelection!.groupID })
        for indices in groupedIndices.values where indices.contains(where: { orderedRecords[$0] == nil }) {
            for index in indices where orderedRecords[index] != nil {
                orderedRecords[index] = nil
                failures.append(.init(url: candidates[index].fileURL, message: "专辑分轨准备失败，请重试此专辑"))
                progressController.updateItem(id: candidates[index].progressID, title: candidates[index].metadata.title,
                    artist: candidates[index].metadata.artist, stage: .importing, status: .failed,
                    detail: "专辑分轨准备失败")
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
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken,
        didCommitAudio: @MainActor () async throws -> Void = {},
        didCommitTracks: @MainActor ([UUID]) async -> Void = { _ in }
    ) async -> [Track]? {
        progressController.update(
            stage: .savingLibrary,
            progress: FileImportService.progress(for: .savingLibrary, completed: 0, total: 2),
            detail: "正在提交导入文件",
            completedCount: 0,
            totalCount: 2
        )

        guard !(await isImportCancellationRequested(progressController, cancellationToken)) else {
            return nil
        }

        do {
            try await commitStagedAudioFiles(
                for: Set(importedTracks.map(\.id)),
                session: session,
                cancellationToken: cancellationToken
            )
            try await didCommitAudio()
        } catch is CancellationError {
            session.retainTrackFolders(trackIDs: importedTracks.map(\.id))
            return nil
        } catch {
            session.retainTrackFolders(trackIDs: importedTracks.map(\.id))
            Log.error(
                "[Import] failed to commit staged audio files: \(error.localizedDescription)",
                category: .import
            )
            return nil
        }

        guard !(await isImportCancellationRequested(progressController, cancellationToken)) else {
            session.retainTrackFolders(trackIDs: importedTracks.map(\.id))
            return nil
        }

        let programGroups = Dictionary(grouping: importedTracks.filter { $0.mediaSelection != nil },
            by: { $0.mediaSelection!.groupID })
        var programTransactions: [AudioProgramImportTransaction] = []
        do {
            for (groupID, tracks) in programGroups {
                programTransactions.append(try AudioProgramImportTransaction.begin(groupID: groupID,
                    trackIDs: Set(tracks.map(\.id)), paths: paths))
            }
        } catch {
            Log.error("[Import] cannot prepare program commit: \(error.localizedDescription)", category: .import)
            return nil
        }
        do { try await prepareProgramAlbums(importedTracks) }
        catch {
            Log.error("[Import] cannot prepare shared album artwork: \(error.localizedDescription)", category: .import)
            return nil
        }
        let capturedTransactions = programTransactions
        let capturedPaths = paths
        let referencedNCMConversionService = self.referencedNCMConversionService
        let tracksByID = Dictionary(uniqueKeysWithValues: importedTracks.map { ($0.id, $0) })
        let commitResult = await repository.commitImportedTracks(importedTracks) { persistedIDs in
            var permitted = Set(persistedIDs)
            for transaction in capturedTransactions {
                guard transaction.trackIDs.isSubset(of: permitted) else {
                    permitted.subtract(transaction.trackIDs)
                    continue
                }
                do { try transaction.complete(paths: capturedPaths) }
                catch {
                    permitted.subtract(transaction.trackIDs)
                    Log.error("[Import] program commit incomplete: \(error.localizedDescription)", category: .import)
                }
            }
            guard let referencedNCMConversionService else { return permitted }
            var visible = Set<UUID>()
            for trackID in persistedIDs where permitted.contains(trackID) {
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
        let unpersisted = importedTracks.filter { !persistedIDs.contains($0.id) }
        session.retainTrackFolders(trackIDs: unpersisted.map(\.id))
        guard !persistedTracks.isEmpty else { return nil }
        session.markCommitted(trackIDs: persistedTracks.map(\.id))
        await didCommitTracks(persistedTracks.map(\.id))
        progressController.update(
            stage: .savingLibrary,
            progress: FileImportService.progress(for: .savingLibrary, completed: 1, total: 2),
            detail: "歌曲已写入资料库，正在整理关联信息",
            completedCount: 1,
            totalCount: 2
        )

        progressController.update(
            stage: .savingLibrary,
            progress: FileImportService.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )
        return persistedTracks
    }

    private func prepareProgramAlbums(_ tracks: [Track]) async throws {
        let groups = Dictionary(grouping: tracks.filter { $0.audioProgramAlbum != nil }, by: { $0.audioProgramAlbum!.id })
        let entries = await repository.fetchAlbumEntries()
        for (_, members) in groups {
            guard let first = members.first, let program = first.audioProgramAlbum else { continue }
            var entry = entries.first { $0.canonicalKey == program.key }
                ?? entries.first { $0.id == program.id } ?? AlbumEntry(
                id: program.id, canonicalKey: program.key, displayTitle: first.album,
                primaryArtistCanonicalName: LibraryNormalization.normalizeArtist(program.artist),
                primaryArtistDisplayName: program.artist, createdAt: Date(), updatedAt: Date(),
                trackCount: members.count, totalDuration: members.reduce(0) { $0 + $1.duration }, isOrphaned: false)
            entry.canonicalKey = program.key
            if !entry.manuallyEditedFields.contains("title") && !entry.manuallyEditedFields.contains("displayTitle") { entry.displayTitle = first.album }
            var numbers = entry.catalogTrackNumbers ?? [:]
            for track in members { numbers[track.id] = track.mediaSelection?.trackNumber }
            entry.catalogTrackNumbers = numbers
            if !entry.hasArtwork, let data = members.compactMap(\.artworkData).first {
                entry.artworkData = data
                entry.artworkFileName = "artwork.png"
            }
            try await repository.updateAlbumEntry(entry)
            for track in members {
                var properties = track.mediaLocator.referencedFile?.primaryAudioProperties ?? track.audioProperties ?? TrackAudioProperties()
                properties.mediaSelection?.albumResourceID = entry.id
                if case .referenced(var locator) = track.mediaLocator {
                    locator.primaryAudioProperties = properties
                    track.mediaLocator = .referenced(locator)
                } else { track.audioProperties = properties }
                if entry.hasArtwork && track.artworkIsUserSelected != true { track.artworkData = nil }
            }
        }
    }

    private func commitStagedAudioFiles(
        for trackIDs: Set<UUID>,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async throws {
        guard !trackIDs.isEmpty else { return }
        let stagedFiles = session.stagedFiles(for: trackIDs)
        if stagedFiles.contains(where: { $0.libraryRelativePath.hasPrefix("MediaAssets/") }) {
            try SharedMediaAssetStore.enableFormat(at: paths)
        }
        if storageBackend.mode == .referenced {
            guard stagedFiles.isEmpty else {
                throw LibraryBackendError.modeMismatch(expected: .referenced, actual: .managed)
            }
        }
        if storageBackend.mode == .managed, stagedFiles.count != trackIDs.count {
            let missingCount = trackIDs.count - stagedFiles.count
            throw NSError(
                domain: "FileImportService.ImportSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(missingCount) staged import files"]
            )
        }

        let files = stagedFiles.map {
            ImportStagedAssetFile(stagedURL: $0.stagedAudioURL, libraryRelativePath: $0.libraryRelativePath)
        } + session.stagedAssetFiles(for: trackIDs)
        let sessionID = session.id

        let capturedPaths = paths
        try await Task.detached(priority: .userInitiated) { @Sendable in
            let fileManager = FileManager.default
            try capturedPaths.createRequiredDirectories(fileManager: fileManager)

            // Claim only folders this session creates. A folder that already
            // exists belongs to the user or another writer and must never be
            // deleted later as import residue.
            for staged in stagedFiles {
                try await cancellationToken.checkCancellation()
                let folder = capturedPaths.trackFolderURL(for: staged.trackID)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    continue
                }
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                try ImportTrackFolderMarker(
                    trackID: staged.trackID,
                    sessionID: sessionID
                ).write(to: folder, fileManager: fileManager)
            }

            var movedPaths = Set<String>()
            for file in files {
                guard movedPaths.insert(file.libraryRelativePath).inserted else { continue }
                try await cancellationToken.checkCancellation()
                guard let destinationURL = capturedPaths.libraryURL(
                    from: file.libraryRelativePath
                ) else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                guard fileManager.fileExists(atPath: file.stagedURL.path) else {
                    throw NSError(
                        domain: "FileImportService.ImportSession",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Staged audio file is missing"]
                    )
                }
                let destinationFolder = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: destinationFolder,
                    withIntermediateDirectories: true
                )
                if file.stagedURL.standardizedFileURL == destinationURL.standardizedFileURL { continue }
                // moveItem refuses an existing destination. Never remove a
                // file that may have appeared since staging began.
                try fileManager.moveItem(at: file.stagedURL, to: destinationURL)
            }
        }.value

        session.markFinalized(trackIDs: Array(trackIDs))
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

        let cleanupReport = await cleanupFailedImportResidue(
            reason: "importCancelled",
            protecting: session.retainedTrackFolderIDs
        )
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
    func cleanupFailedImportResidue(
        reason: String,
        protecting retainedTrackIDs: Set<UUID> = []
    ) async -> TrackDirectoryCleanupReport {
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
                protectedTrackIDs: retainedTrackIDs,
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
            motionArtwork: payload.motionArtwork,
            artworkIsUserSelected: payload.artworkIsUserSelected ? true : nil,
            embeddedMetadataSnapshot: payload.embeddedSnapshot,
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
        track.artworkNeedsUpgrade = !payload.artworkIsUserSelected && (payload.artworkData.map {
            ArtworkDataNormalizer.isBelowPreferredResolution($0)
        } ?? false)
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

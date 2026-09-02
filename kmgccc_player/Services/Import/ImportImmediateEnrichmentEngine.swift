//
//  ImportImmediateEnrichmentEngine.swift
//  kmgccc_player
//
//  §16 extraction: immediate-mode online enrichment moved verbatim out of
//  FileImportService. Holds only service dependencies (never views); progress
//  reporting flows through the same BatchImportProgressDialogController calls,
//  preserving call order.
//

import Foundation

internal struct ImportEnrichmentSnapshot: Sendable {
    let progressID: String
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let needsLyrics: Bool
    let needsCover: Bool
    let needsTrackMetadata: Bool
    let needsArtistMetadata: Bool
    let needsAlbumMetadata: Bool
    let needsArtistArtwork: Bool
    let needsAlbumArtwork: Bool
}

internal struct ImportEnrichmentTaskOutput: Sendable {
    let progressID: String
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let lyricOutcome: ImportLyricsLookupOutcome?
    let coverOutcome: ImportCoverLookupOutcome?
    let trackMetadataOutcome: ImportTrackMetadataOutcome?
    let artistMetadataOutcome: ImportArtistMetadataOutcome?
    let albumMetadataOutcome: ImportAlbumMetadataOutcome?
    let artistArtworkOutcome: ImportArtistArtworkOutcome?
    let albumArtworkOutcome: ImportAlbumArtworkOutcome?
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

@MainActor
final class ImportImmediateEnrichmentEngine {
    private let repository: LibraryRepositoryProtocol
    private let mutationCoordinator: LibraryMutationCoordinator?
    private let qqMusicCoverService: QQMusicCoverService
    private let artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator
    private let lyricsSearchCoordinator: LyricsSearchCoordinator
    private let amllDBService: AMLLDBService

    init(
        repository: LibraryRepositoryProtocol,
        mutationCoordinator: LibraryMutationCoordinator? = nil,
        qqMusicCoverService: QQMusicCoverService,
        artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator,
        lyricsSearchCoordinator: LyricsSearchCoordinator,
        amllDBService: AMLLDBService
    ) {
        self.repository = repository
        self.mutationCoordinator = mutationCoordinator
        self.qqMusicCoverService = qqMusicCoverService
        self.artistArtworkProviderCoordinator = artistArtworkProviderCoordinator
        self.lyricsSearchCoordinator = lyricsSearchCoordinator
        self.amllDBService = amllDBService
    }

    func enrichImportedRecords(
        importedRecords: [ImportedTrackRecord],
        progressController: BatchImportProgressDialogController,
        cancellationToken: ImportCancellationToken
    ) async -> Bool {
        guard !importedRecords.isEmpty else { return false }

        progressController.update(
            stage: .enrichingMetadata,
            progress: FileImportService.progress(
                for: .enrichingMetadata,
                completed: 0,
                total: importedRecords.count
            ),
            detail: "准备补全 \(importedRecords.count) 首歌曲的歌词与封面",
            completedCount: 0,
            totalCount: importedRecords.count
        )

        let artistEntriesByCanonical = ImportEnrichmentService.artistEntriesByCanonical(
            await repository.fetchArtistEntries()
        )
        let albumEntriesByCanonical = ImportEnrichmentService.albumEntriesByCanonical(
            await repository.fetchAlbumEntries()
        )
        var claimedArtistMetadata: Set<String> = []
        var claimedArtistArtwork: Set<String> = []
        var claimedAlbumMetadata: Set<String> = []
        var claimedAlbumArtwork: Set<String> = []
        var snapshots: [ImportEnrichmentSnapshot] = []
        snapshots.reserveCapacity(importedRecords.count)

        for record in importedRecords {
            let artistKey = LibraryNormalization.normalizeArtist(record.track.artist)
            let albumKey = LibraryNormalization.normalizedAlbumKey(album: record.track.album)
            let albumDedupKey = "\(artistKey)•\(albumKey)"
            let needsArtistMetadata = record.needsArtistMetadataEnrichment
                && ImportEnrichmentService.artistMetadataNeedsEnrichment(
                    artist: record.track.artist,
                    entriesByCanonical: artistEntriesByCanonical
                )
                && claimedArtistMetadata.insert(artistKey).inserted
            let needsArtistArtwork = record.needsArtistArtworkEnrichment
                && ImportEnrichmentService.artistArtworkNeedsEnrichment(
                    artist: record.track.artist,
                    entriesByCanonical: artistEntriesByCanonical
                )
                && claimedArtistArtwork.insert(artistKey).inserted
            let needsAlbumMetadata = record.needsAlbumMetadataEnrichment
                && ImportEnrichmentService.albumMetadataNeedsEnrichment(
                    album: record.track.album,
                    entriesByCanonical: albumEntriesByCanonical
                )
                && claimedAlbumMetadata.insert(albumDedupKey).inserted
            let needsAlbumArtwork = record.needsAlbumArtworkEnrichment
                && ImportEnrichmentService.albumArtworkNeedsEnrichment(
                    album: record.track.album,
                    entriesByCanonical: albumEntriesByCanonical
                )
                && claimedAlbumArtwork.insert(albumDedupKey).inserted

            snapshots.append(ImportEnrichmentSnapshot(
                progressID: record.progressID,
                id: record.track.id,
                title: record.track.title,
                artist: record.track.artist,
                album: record.track.album,
                duration: record.track.duration > 0 ? record.track.duration : nil,
                needsLyrics: record.needsLyricsEnrichment,
                needsCover: record.needsCoverEnrichment,
                needsTrackMetadata: record.needsTrackMetadataEnrichment,
                needsArtistMetadata: needsArtistMetadata,
                needsAlbumMetadata: needsAlbumMetadata,
                needsArtistArtwork: needsArtistArtwork,
                needsAlbumArtwork: needsAlbumArtwork
            ))
        }
        let recordsByTrackID = Dictionary(
            uniqueKeysWithValues: importedRecords.map { ($0.track.id, $0) }
        )
        let maxConcurrent = PerAudioFileImportTask.enrichmentConcurrency(for: snapshots.count)
        var iterator = snapshots.makeIterator()
        var completedCount = 0
        var stats = ImmediateEnrichmentStats()
        var outputs: [ImportEnrichmentTaskOutput] = []
        var cancelled = false

        await withTaskGroup(of: ImportEnrichmentTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, snapshots.count) {
                guard let snapshot = iterator.next() else { break }
                progressController.updateItem(
                    id: snapshot.progressID,
                    title: snapshot.title,
                    artist: snapshot.artist,
                    stage: .enrichingMetadata,
                    status: .active,
                    detail: Self.activeEnrichmentDetail(
                        needsLyrics: snapshot.needsLyrics,
                        needsCover: snapshot.needsCover,
                        needsTrackMetadata: snapshot.needsTrackMetadata,
                        needsArtistMetadata: snapshot.needsArtistMetadata,
                        needsAlbumMetadata: snapshot.needsAlbumMetadata,
                        needsArtistArtwork: snapshot.needsArtistArtwork,
                        needsAlbumArtwork: snapshot.needsAlbumArtwork
                    )
                )
                group.addTask {
                    [qqMusicCoverService, artistArtworkProviderCoordinator, lyricsSearchCoordinator, amllDBService] in
                    await Self.performImmediateEnrichmentTask(
                        snapshot: snapshot,
                        cancellationToken: cancellationToken,
                        qqMusicCoverService: qqMusicCoverService,
                        artistArtworkProviderCoordinator: artistArtworkProviderCoordinator,
                        lyricsSearchCoordinator: lyricsSearchCoordinator,
                        amllDBService: amllDBService
                    )
                }
            }

            while let output = await group.next() {
                if await isImportCancellationRequested(progressController, cancellationToken) {
                    cancelled = true
                    group.cancelAll()
                    progressController.updateItem(
                        id: output.progressID,
                        title: output.title,
                        artist: output.artist,
                        stage: .enrichingMetadata,
                        status: .cancelled,
                        detail: "用户已取消"
                    )
                    continue
                }
                completedCount += 1
                outputs.append(output)

                let (status, detail, outputStats) =
                    Self.applyImmediateEnrichmentResult(
                        output,
                        to: recordsByTrackID[output.trackID]
                    )
                stats.lyricSuccess += outputStats.lyricSuccess
                stats.coverSuccess += outputStats.coverSuccess
                stats.trackMetadataSuccess += outputStats.trackMetadataSuccess
                stats.artistMetadataSuccess += outputStats.artistMetadataSuccess
                stats.albumMetadataSuccess += outputStats.albumMetadataSuccess
                stats.artistArtworkSuccess += outputStats.artistArtworkSuccess
                stats.albumArtworkSuccess += outputStats.albumArtworkSuccess
                stats.noResults += outputStats.noResults
                stats.failures += outputStats.failures

                progressController.updateItem(
                    id: output.progressID,
                    title: output.title,
                    artist: output.artist,
                    stage: .enrichingMetadata,
                    status: status,
                    detail: detail
                )

                if case .warning = status, detail.contains("失败") {
                    Log.warning(
                        "Immediate import enrichment completed with warning for \(output.title) - \(output.artist)",
                        category: .import
                    )
                }

                progressController.update(
                    stage: .enrichingMetadata,
                    progress: FileImportService.progress(
                        for: .enrichingMetadata,
                        completed: completedCount,
                        total: snapshots.count
                    ),
                    detail: Self.enrichmentProgressDetail(
                        completed: completedCount,
                        total: snapshots.count,
                        stats: stats
                    ),
                    completedCount: completedCount,
                    totalCount: snapshots.count
                )

                if let snapshot = iterator.next() {
                    progressController.updateItem(
                        id: snapshot.progressID,
                        title: snapshot.title,
                        artist: snapshot.artist,
                        stage: .enrichingMetadata,
                        status: .active,
                        detail: Self.activeEnrichmentDetail(
                            needsLyrics: snapshot.needsLyrics,
                            needsCover: snapshot.needsCover,
                            needsTrackMetadata: snapshot.needsTrackMetadata,
                            needsArtistMetadata: snapshot.needsArtistMetadata,
                            needsAlbumMetadata: snapshot.needsAlbumMetadata,
                            needsArtistArtwork: snapshot.needsArtistArtwork,
                            needsAlbumArtwork: snapshot.needsAlbumArtwork
                        )
                    )
                    group.addTask {
                        [qqMusicCoverService, artistArtworkProviderCoordinator, lyricsSearchCoordinator, amllDBService] in
                        await Self.performImmediateEnrichmentTask(
                            snapshot: snapshot,
                            cancellationToken: cancellationToken,
                            qqMusicCoverService: qqMusicCoverService,
                            artistArtworkProviderCoordinator: artistArtworkProviderCoordinator,
                            lyricsSearchCoordinator: lyricsSearchCoordinator,
                            amllDBService: amllDBService
                        )
                    }
                }
            }
        }

        let finalCancellationRequested = await isImportCancellationRequested(progressController, cancellationToken)
        if cancelled || finalCancellationRequested {
            return true
        }

        await persistImmediateArtistAlbumResults(
            outputs,
            recordsByTrackID: recordsByTrackID,
            cancellationToken: cancellationToken
        )
        return await isImportCancellationRequested(progressController, cancellationToken)
    }

    private func applyArtistMetadataDetail(
        _ detail: ArtistMetadataDetail,
        artist: String
    ) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        let entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        return await commitMetadataEntry(id: result.value.id) {
            try await self.repository.updateArtistEntry(result.value)
        }
    }

    private func applyArtistArtworkData(_ data: Data, artist: String) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        var entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        return await commitMetadataEntry(id: entry.id) {
            try await self.repository.updateArtistEntry(entry)
        }
    }

    private func applyAlbumMetadataDetail(
        _ detail: AlbumMetadataDetail,
        album: String,
        artist: String
    ) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        let entry = await latestAlbumEntry(album: album, artist: artist)
        let result = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: entry)
        guard result.changed else { return false }
        return await commitMetadataEntry(id: result.value.id) {
            try await self.repository.updateAlbumEntry(result.value)
        }
    }

    private func applyAlbumArtworkData(_ data: Data, album: String, artist: String) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        var entry = await latestAlbumEntry(album: album, artist: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        return await commitMetadataEntry(id: entry.id) {
            try await self.repository.updateAlbumEntry(entry)
        }
    }

    private func commitMetadataEntry(
        id: UUID,
        _ work: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            if let mutationCoordinator {
                return try await mutationCoordinator.run(
                    kind: .enrichmentCommit,
                    targetIDs: [id.uuidString]
                ) {
                    try await work()
                    return true
                }
            }
            try await work()
            return true
        } catch {
            Log.error(
                "[ImportImmediateEnrichment] metadata entry commit rejected: \(error)",
                category: .import
            )
            return false
        }
    }

    private func latestArtistEntry(canonical: String, displayName: String) async -> ArtistEntry {
        let entries = await repository.fetchArtistEntries()
        if let entry = entries.first(where: { $0.canonicalName == canonical }) {
            return entry
        }

        let now = Date()
        return ArtistEntry(
            id: UUID(),
            canonicalName: canonical,
            displayName: LibraryNormalization.displayArtist(displayName),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            albumCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func latestAlbumEntry(album: String, artist: String) async -> AlbumEntry {
        let albumKey = LibraryNormalization.normalizedAlbumKey(album: album)
        let entries = await repository.fetchAlbumEntries()
        if let entry = entries.first(where: { $0.canonicalKey == albumKey }) {
            return entry
        }

        let now = Date()
        return AlbumEntry(
            id: UUID(),
            canonicalKey: albumKey,
            displayTitle: LibraryNormalization.displayAlbum(album),
            primaryArtistCanonicalName: LibraryNormalization.normalizeArtist(artist),
            primaryArtistDisplayName: LibraryNormalization.displayArtist(artist),
            createdAt: now,
            updatedAt: now,
            trackCount: 0,
            totalDuration: 0,
            isOrphaned: true
        )
    }

    private func persistImmediateArtistAlbumResults(
        _ outputs: [ImportEnrichmentTaskOutput],
        recordsByTrackID: [UUID: ImportedTrackRecord],
        cancellationToken: ImportCancellationToken
    ) async {
        var discoveredAlbumKeys: Set<String> = []
        for output in outputs {
            if (try? await cancellationToken.checkCancellation()) == nil { return }
            let effectiveAlbum = recordsByTrackID[output.trackID]?.track.album ?? output.album

            if case .completed(let detail) = output.artistMetadataOutcome {
                if await applyArtistMetadataDetail(detail, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate artistMetadata persisted \(output.artist)",
                        category: .import
                    )
                }
            }

            if case .completed(let data) = output.artistArtworkOutcome {
                if await applyArtistArtworkData(data, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate artistArtwork persisted \(output.artist)",
                        category: .import
                    )
                }
            }

            if case .completed(let detail) = output.albumMetadataOutcome {
                if await applyAlbumMetadataDetail(detail, album: effectiveAlbum, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate albumMetadata persisted \(effectiveAlbum)",
                        category: .import
                    )
                }
            }

            if case .completed(let data) = output.albumArtworkOutcome {
                if await applyAlbumArtworkData(data, album: effectiveAlbum, artist: output.artist) {
                    Log.info(
                        "[ImportEnrichment] immediate albumArtwork persisted \(effectiveAlbum)",
                        category: .import
                    )
                }
            }

            if LibraryNormalization.isUnknownAlbum(output.album),
               !LibraryNormalization.isUnknownAlbum(effectiveAlbum) {
                if (try? await cancellationToken.checkCancellation()) == nil { return }
                let albumDedupKey = "\(LibraryNormalization.normalizeArtist(output.artist))•\(LibraryNormalization.normalizedAlbumKey(album: effectiveAlbum))"
                guard discoveredAlbumKeys.insert(albumDedupKey).inserted else { continue }

                let metadataOutcome = await MetadataEnrichmentWorker.fetchAlbumMetadata(
                    album: effectiveAlbum,
                    artist: output.artist
                )
                if case .completed(let detail) = metadataOutcome {
                    _ = await applyAlbumMetadataDetail(detail, album: effectiveAlbum, artist: output.artist)
                }

                let artworkOutcome = await MetadataEnrichmentWorker.fetchAlbumArtwork(
                    album: effectiveAlbum,
                    artist: output.artist,
                    qqMusicCoverService: qqMusicCoverService
                )
                if case .completed(let data) = artworkOutcome {
                    _ = await applyAlbumArtworkData(data, album: effectiveAlbum, artist: output.artist)
                }
            }
        }
    }

    nonisolated private static func performImmediateEnrichmentTask(
        snapshot: ImportEnrichmentSnapshot,
        cancellationToken: ImportCancellationToken,
        qqMusicCoverService: QQMusicCoverService,
        artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator,
        lyricsSearchCoordinator: LyricsSearchCoordinator,
        amllDBService: AMLLDBService
    ) async -> ImportEnrichmentTaskOutput {
        if (try? await cancellationToken.checkCancellation()) == nil {
            return ImportEnrichmentTaskOutput(
                progressID: snapshot.progressID,
                trackID: snapshot.id,
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                lyricOutcome: nil,
                coverOutcome: nil,
                trackMetadataOutcome: nil,
                artistMetadataOutcome: nil,
                albumMetadataOutcome: nil,
                artistArtworkOutcome: nil,
                albumArtworkOutcome: nil
            )
        }
        async let lyricOutcome: ImportLyricsLookupOutcome? = snapshot.needsLyrics
            ? ImportEnrichmentWorker.fetchLyrics(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration,
                lyricsSearchCoordinator: lyricsSearchCoordinator,
                amllDBService: amllDBService
            )
            : nil
        async let coverOutcome: ImportCoverLookupOutcome? = snapshot.needsCover
            ? ImportEnrichmentWorker.fetchCover(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration,
                qqMusicCoverService: qqMusicCoverService
            )
            : nil

        async let trackMetadataOutcome: ImportTrackMetadataOutcome? = snapshot.needsTrackMetadata
            ? MetadataEnrichmentWorker.fetchTrackMetadata(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                duration: snapshot.duration
            )
            : nil
        async let artistMetadataOutcome: ImportArtistMetadataOutcome? = snapshot.needsArtistMetadata
            ? MetadataEnrichmentWorker.fetchArtistMetadata(name: snapshot.artist)
            : nil
        async let albumMetadataOutcome: ImportAlbumMetadataOutcome? = snapshot.needsAlbumMetadata
            ? MetadataEnrichmentWorker.fetchAlbumMetadata(
                album: snapshot.album,
                artist: snapshot.artist
            )
            : nil
        async let artistArtworkOutcome: ImportArtistArtworkOutcome? = snapshot.needsArtistArtwork
            ? MetadataEnrichmentWorker.fetchArtistArtwork(
                artist: snapshot.artist,
                artistArtworkProviderCoordinator: artistArtworkProviderCoordinator
            )
            : nil
        async let albumArtworkOutcome: ImportAlbumArtworkOutcome? = snapshot.needsAlbumArtwork
            ? MetadataEnrichmentWorker.fetchAlbumArtwork(
                album: snapshot.album,
                artist: snapshot.artist,
                qqMusicCoverService: qqMusicCoverService
            )
            : nil

        let resolvedLyricOutcome = await lyricOutcome
        let resolvedCoverOutcome = await coverOutcome
        let resolvedTrackMetadataOutcome = await trackMetadataOutcome
        let resolvedArtistMetadataOutcome = await artistMetadataOutcome
        let resolvedAlbumMetadataOutcome = await albumMetadataOutcome
        let resolvedArtistArtworkOutcome = await artistArtworkOutcome
        let resolvedAlbumArtworkOutcome = await albumArtworkOutcome

        return ImportEnrichmentTaskOutput(
            progressID: snapshot.progressID,
            trackID: snapshot.id,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            lyricOutcome: resolvedLyricOutcome,
            coverOutcome: resolvedCoverOutcome,
            trackMetadataOutcome: resolvedTrackMetadataOutcome,
            artistMetadataOutcome: resolvedArtistMetadataOutcome,
            albumMetadataOutcome: resolvedAlbumMetadataOutcome,
            artistArtworkOutcome: resolvedArtistArtworkOutcome,
            albumArtworkOutcome: resolvedAlbumArtworkOutcome
        )
    }

    private struct ImmediateEnrichmentStats: Sendable {
        var lyricSuccess = 0
        var coverSuccess = 0
        var trackMetadataSuccess = 0
        var artistMetadataSuccess = 0
        var albumMetadataSuccess = 0
        var artistArtworkSuccess = 0
        var albumArtworkSuccess = 0
        var noResults = 0
        var failures = 0
    }

    // MainActor-isolated: writes enriched fields back onto main-actor Track models.
    private static func applyImmediateEnrichmentResult(
        _ output: ImportEnrichmentTaskOutput,
        to record: ImportedTrackRecord?
    ) -> (BatchImportItemStatus, String, ImmediateEnrichmentStats) {
        guard let record else {
            var stats = ImmediateEnrichmentStats()
            stats.failures = 1
            return (.warning, "补全结果未能写回，歌曲已保留导入", stats)
        }

        var detailParts: [String] = []
        var status: BatchImportItemStatus = .success
        var stats = ImmediateEnrichmentStats()

        if let lyricOutcome = output.lyricOutcome {
            switch lyricOutcome {
            case .completed(let ttml):
                if record.track.ttmlLyricText == nil {
                    record.track.ttmlLyricText = ttml
                }
                stats.lyricSuccess += 1
                detailParts.append("歌词已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到歌词")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("歌词补全失败")
            }
        }

        if let coverOutcome = output.coverOutcome {
            switch coverOutcome {
            case .completed(let artworkData):
                if record.track.artworkData == nil {
                    record.track.artworkData = artworkData
                }
                stats.coverSuccess += 1
                detailParts.append("封面已补全")
            case .noResults:
                stats.noResults += 1
                status = .warning
                detailParts.append("未找到封面")
            case .failed:
                stats.failures += 1
                status = .warning
                detailParts.append("封面补全失败")
            }
        }

        if let trackMetadataOutcome = output.trackMetadataOutcome {
            // Catalog enrichment is optional for a successful import. The row
            // severity is determined by the essential lyrics and track cover.
            switch trackMetadataOutcome {
            case .completed(let detail):
                let changed = MetadataDetailCoordinator.shared.applyMissingFields(detail, to: record.track)
                if changed {
                    stats.trackMetadataSuccess += 1
                    detailParts.append("歌曲信息已补全")
                }
            case .noResults:
                stats.noResults += 1
                detailParts.append("未找到歌曲信息")
            case .failed:
                stats.failures += 1
                detailParts.append("歌曲信息补全失败")
            }
        }

        if let artistMetadataOutcome = output.artistMetadataOutcome {
            switch artistMetadataOutcome {
            case .completed:
                stats.artistMetadataSuccess += 1
                detailParts.append("歌手信息已补全")
            case .noResults:
                stats.noResults += 1
                detailParts.append("未找到歌手信息")
            case .failed:
                stats.failures += 1
                detailParts.append("歌手信息补全失败")
            }
        }

        if let albumMetadataOutcome = output.albumMetadataOutcome {
            switch albumMetadataOutcome {
            case .completed:
                stats.albumMetadataSuccess += 1
                detailParts.append("专辑信息已补全")
            case .noResults:
                stats.noResults += 1
                detailParts.append("未找到专辑信息")
            case .failed:
                stats.failures += 1
                detailParts.append("专辑信息补全失败")
            }
        }

        if let artistArtworkOutcome = output.artistArtworkOutcome {
            switch artistArtworkOutcome {
            case .completed:
                stats.artistArtworkSuccess += 1
                detailParts.append("歌手封面已补全")
            case .noResults:
                stats.noResults += 1
                detailParts.append("未找到歌手封面")
            case .failed:
                stats.failures += 1
                detailParts.append("歌手封面补全失败")
            }
        }

        if let albumArtworkOutcome = output.albumArtworkOutcome {
            switch albumArtworkOutcome {
            case .completed:
                stats.albumArtworkSuccess += 1
                detailParts.append("专辑封面已补全")
            case .noResults:
                stats.noResults += 1
                detailParts.append("未找到专辑封面")
            case .failed:
                stats.failures += 1
                detailParts.append("专辑封面补全失败")
            }
        }

        if detailParts.isEmpty {
            detailParts.append("歌曲已导入")
        }

        return (status, detailParts.joined(separator: "，"), stats)
    }

    nonisolated private static func enrichmentProgressDetail(
        completed: Int,
        total: Int,
        stats: ImmediateEnrichmentStats
    ) -> String {
        var parts = ["已处理 \(completed) / \(total)"]
        let metaSuccess = stats.trackMetadataSuccess + stats.artistMetadataSuccess + stats.albumMetadataSuccess
        let artSuccess = stats.coverSuccess + stats.artistArtworkSuccess + stats.albumArtworkSuccess
        if stats.lyricSuccess > 0 {
            parts.append("歌词 \(stats.lyricSuccess)")
        }
        if artSuccess > 0 {
            parts.append("封面 \(artSuccess)")
        }
        if metaSuccess > 0 {
            parts.append("信息 \(metaSuccess)")
        }
        if stats.noResults > 0 {
            parts.append("未找到 \(stats.noResults)")
        }
        if stats.failures > 0 {
            parts.append("失败 \(stats.failures)")
        }
        return parts.joined(separator: "，")
    }

    /// Shared by the engine and the committer-side batch executor to label a
    /// freshly imported row before its enrichment round starts.
    nonisolated static func pendingEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool,
        needsTrackMetadata: Bool = false,
        needsArtistMetadata: Bool = false,
        needsAlbumMetadata: Bool = false,
        needsArtistArtwork: Bool = false,
        needsAlbumArtwork: Bool = false,
        deferred: Bool
    ) -> String {
        let work = enrichmentWorkLabel(
            needsLyrics: needsLyrics,
            needsCover: needsCover,
            needsTrackMetadata: needsTrackMetadata,
            needsArtistMetadata: needsArtistMetadata,
            needsAlbumMetadata: needsAlbumMetadata,
            needsArtistArtwork: needsArtistArtwork,
            needsAlbumArtwork: needsAlbumArtwork
        )
        if deferred {
            return "歌曲文件已就绪，导入后将在后台补全\(work)"
        }
        return "歌曲文件已就绪，等待补全\(work)"
    }

    nonisolated private static func activeEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool,
        needsTrackMetadata: Bool = false,
        needsArtistMetadata: Bool = false,
        needsAlbumMetadata: Bool = false,
        needsArtistArtwork: Bool = false,
        needsAlbumArtwork: Bool = false
    ) -> String {
        let work = enrichmentWorkLabel(
            needsLyrics: needsLyrics,
            needsCover: needsCover,
            needsTrackMetadata: needsTrackMetadata,
            needsArtistMetadata: needsArtistMetadata,
            needsAlbumMetadata: needsAlbumMetadata,
            needsArtistArtwork: needsArtistArtwork,
            needsAlbumArtwork: needsAlbumArtwork
        )
        return "正在补全\(work)"
    }

    nonisolated private static func enrichmentWorkLabel(
        needsLyrics: Bool,
        needsCover: Bool,
        needsTrackMetadata: Bool = false,
        needsArtistMetadata: Bool = false,
        needsAlbumMetadata: Bool = false,
        needsArtistArtwork: Bool = false,
        needsAlbumArtwork: Bool = false
    ) -> String {
        var parts: [String] = []
        if needsLyrics { parts.append("歌词") }
        if needsCover { parts.append("封面") }
        if needsTrackMetadata { parts.append("歌曲信息") }
        if needsArtistMetadata { parts.append("歌手信息") }
        if needsAlbumMetadata { parts.append("专辑信息") }
        if needsArtistArtwork { parts.append("歌手封面") }
        if needsAlbumArtwork { parts.append("专辑封面") }
        if parts.isEmpty {
            return "导入信息"
        }
        if parts.count == 1 {
            return parts[0]
        }
        return parts.joined(separator: "、")
    }
}

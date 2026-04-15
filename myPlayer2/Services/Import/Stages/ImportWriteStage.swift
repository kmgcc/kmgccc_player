//
//  ImportWriteStage.swift
//  myPlayer2
//

import Foundation

@MainActor
enum ImportWriteStage {
    static func importFile(
        url: URL,
        metadata: (
            title: String, artist: String, album: String, albumArtist: String?, duration: Double,
            lyrics: String?
        ),
        preloadedArtworkData: Data?
    ) async -> Track? {
        let candidate = ImportCandidate(
            progressID: url.path,
            displayName: url.lastPathComponent,
            fileURL: url,
            metadata: ImportPreview(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                albumArtist: metadata.albumArtist,
                duration: metadata.duration,
                lyrics: metadata.lyrics,
                artworkData: preloadedArtworkData
            )
        )

        let output = await performImportTask(index: 0, candidate: candidate)
        guard let payload = output.payload else {
            if let errorDescription = output.errorDescription {
                print("❌ Failed to import \(url.lastPathComponent): \(errorDescription)")
            }
            return nil
        }
        return makeTrack(from: payload)
    }

    static func importCandidates(
        _ candidates: [ImportCandidate],
        progressController: BatchImportProgressDialogController,
        enrichmentMode: ImportEnrichmentMode,
        libraryService _: LocalLibraryService
    ) async -> [ImportedTrackRecord] {
        guard !candidates.isEmpty else { return [] }

        var orderedRecords = Array<ImportedTrackRecord?>(repeating: nil, count: candidates.count)
        var iterator = Array(candidates.enumerated()).makeIterator()
        let maxConcurrent = importConcurrency(for: candidates.count)
        var processedCount = 0
        var importedCount = 0
        var failedCount = 0

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
                    await performImportTask(index: index, candidate: candidate)
                }
            }

            while let output = await group.next() {
                processedCount += 1

                if let payload = output.payload {
                    importedCount += 1
                    let track = makeTrack(from: payload)
                    orderedRecords[output.index] = ImportedTrackRecord(
                        progressID: output.progressID,
                        displayName: output.displayName,
                        track: track,
                        needsLyricsEnrichment: output.needsLyricsEnrichment,
                        needsCoverEnrichment: output.needsCoverEnrichment
                    )

                    let needsEnrichment = output.needsLyricsEnrichment || output.needsCoverEnrichment
                    let detail = needsEnrichment
                        ? pendingEnrichmentDetail(
                            needsLyrics: output.needsLyricsEnrichment,
                            needsCover: output.needsCoverEnrichment,
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
                    progress: BatchImportStage.progress(
                        for: .importingFiles,
                        completed: processedCount,
                        total: candidates.count
                    ),
                    detail: detail,
                    completedCount: processedCount,
                    totalCount: candidates.count
                )

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
                        await performImportTask(index: index, candidate: candidate)
                    }
                }
            }
        }

        return orderedRecords.compactMap { $0 }
    }

    static func save(
        _ importedTracks: [Track],
        to playlist: Playlist,
        progressController: BatchImportProgressDialogController,
        repository: LibraryRepositoryProtocol
    ) async {
        progressController.update(
            stage: .savingLibrary,
            progress: BatchImportStage.progress(for: .savingLibrary, completed: 0, total: 2),
            detail: "正在写入资料库和播放列表",
            completedCount: 0,
            totalCount: 2
        )

        await repository.addTracks(importedTracks)
        progressController.update(
            stage: .savingLibrary,
            progress: BatchImportStage.progress(for: .savingLibrary, completed: 1, total: 2),
            detail: "歌曲已写入资料库，正在加入播放列表",
            completedCount: 1,
            totalCount: 2
        )

        if !importedTracks.isEmpty {
            print("🔗 Adding \(importedTracks.count) tracks to playlist '\(playlist.name)'")
            await repository.addTracks(importedTracks, to: playlist)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: BatchImportStage.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )
    }

    private static func makeTrack(from payload: ImportedTrackPayload) -> Track {
        Track(
            id: payload.id,
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            albumArtist: payload.albumArtist,
            duration: payload.duration,
            importedAt: payload.importedAt,
            fileBookmarkData: Data(),
            originalFilePath: payload.originalFilePath,
            libraryRelativePath: payload.libraryRelativePath,
            artworkData: payload.artworkData,
            ttmlLyricText: payload.ttmlLyricText,
            lyricsText: payload.lyricsText
        )
    }

    nonisolated private static func pendingEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool,
        deferred: Bool
    ) -> String {
        let work = enrichmentWorkLabel(needsLyrics: needsLyrics, needsCover: needsCover)
        if deferred {
            return "歌曲文件已就绪，导入后将在后台补全\(work)"
        }
        return "歌曲文件已就绪，等待补全\(work)"
    }

    nonisolated private static func enrichmentWorkLabel(
        needsLyrics: Bool,
        needsCover: Bool
    ) -> String {
        switch (needsLyrics, needsCover) {
        case (true, true):
            return "歌词与封面"
        case (true, false):
            return "歌词"
        case (false, true):
            return "封面"
        case (false, false):
            return "导入信息"
        }
    }

    nonisolated private static func performImportTask(
        index: Int,
        candidate: ImportCandidate
    ) async -> ImportTaskOutput {
        let trackId = UUID()
        let importedAt = Date()

        async let extractedArtworkTask: Data? = {
            if let preloadedArtworkData = candidate.metadata.artworkData {
                return preloadedArtworkData
            }
            return await MetadataExtractionStage.extractArtwork(from: candidate.fileURL)
        }()
        async let embeddedLyricsTask = MetadataExtractionStage.prepareEmbeddedTTMLLyrics(candidate.metadata.lyrics)

        do {
            let libraryRelativePath = try importAudioFileToLibrary(
                from: candidate.fileURL,
                trackId: trackId
            )

            let artworkData = await extractedArtworkTask
            let ttmlLyricText = await embeddedLyricsTask

            return ImportTaskOutput(
                index: index,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: ImportedTrackPayload(
                    id: trackId,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    album: candidate.metadata.album,
                    albumArtist: candidate.metadata.albumArtist,
                    duration: candidate.metadata.duration,
                    importedAt: importedAt,
                    originalFilePath: candidate.fileURL.path,
                    libraryRelativePath: libraryRelativePath,
                    artworkData: artworkData,
                    ttmlLyricText: ttmlLyricText,
                    lyricsText: nil
                ),
                needsLyricsEnrichment: ttmlLyricText == nil,
                needsCoverEnrichment: artworkData == nil,
                errorDescription: nil
            )
        } catch {
            let _ = await extractedArtworkTask
            let _ = await embeddedLyricsTask
            return ImportTaskOutput(
                index: index,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    nonisolated private static func importAudioFileToLibrary(
        from sourceURL: URL,
        trackId: UUID
    ) throws -> String {
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: LocalLibraryPaths.libraryRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: LocalLibraryPaths.tracksRootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: LocalLibraryPaths.playlistsRootURL,
            withIntermediateDirectories: true
        )

        let trackFolder = LocalLibraryPaths.trackFolderURL(for: trackId)
        try fileManager.createDirectory(at: trackFolder, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExt = ext.isEmpty ? "audio" : ext
        let audioFileName = "audio.\(safeExt)"
        let destURL = trackFolder.appendingPathComponent(audioFileName)

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)

        return "Tracks/\(trackId.uuidString)/\(audioFileName)"
    }

    nonisolated private static func importConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(6, max(3, cpuCount)))
    }
}

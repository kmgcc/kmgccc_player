//
//  DuplicateChecker.swift
//  myPlayer2
//

import Foundation

@MainActor
enum DuplicateChecker {
    static func prepare(
        files: [ResolvedImportFile],
        existingMatches: [String: ExistingTrackMatchSnapshot],
        progressController: BatchImportProgressDialogController
    ) async -> (unique: [ImportCandidate], duplicates: [DuplicatePairRow]) {
        guard !files.isEmpty else { return ([], []) }

        progressController.update(
            stage: .readingMetadata,
            progress: BatchImportStage.progress(for: .readingMetadata, completed: 0, total: files.count),
            detail: "正在解析歌曲元数据并检查重复项",
            completedCount: 0,
            totalCount: files.count
        )

        var orderedResults = Array<CandidatePreparationResult?>(repeating: nil, count: files.count)
        var iterator = Array(files.enumerated()).makeIterator()
        let maxConcurrent = metadataConcurrency(for: files.count)
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
                    await buildCandidatePreparationResult(
                        index: index,
                        file: file,
                        existingMatches: existingMatches
                    )
                }
            }

            while let output = await group.next() {
                orderedResults[output.index] = output
                completedCount += 1

                progressController.update(
                    stage: .readingMetadata,
                    progress: BatchImportStage.progress(
                        for: .readingMetadata,
                        completed: completedCount,
                        total: files.count
                    ),
                    detail: "已解析 \(completedCount) / \(files.count) 首歌曲",
                    completedCount: completedCount,
                    totalCount: files.count
                )

                let itemStatus: BatchImportItemStatus = output.duplicateRow == nil ? .success : .warning
                let itemDetail = output.duplicateRow == nil ? "歌曲信息解析完成，未发现重复" : "检测到重复歌曲，等待用户选择"
                progressController.updateItem(
                    id: output.candidate.progressID,
                    title: output.candidate.metadata.title,
                    artist: output.candidate.metadata.artist,
                    stage: .duplicateCheck,
                    status: itemStatus,
                    detail: itemDetail
                )

                if let (index, file) = iterator.next() {
                    progressController.updateItem(
                        id: file.progressID,
                        stage: .metadata,
                        status: .active,
                        detail: "正在读取歌曲标题、歌手和专辑信息"
                    )
                    group.addTask {
                        await buildCandidatePreparationResult(
                            index: index,
                            file: file,
                            existingMatches: existingMatches
                        )
                    }
                }
            }
        }

        var uniqueCandidates: [ImportCandidate] = []
        var duplicateRows: [DuplicatePairRow] = []

        for output in orderedResults.compactMap({ $0 }) {
            if let duplicateRow = output.duplicateRow {
                duplicateRows.append(duplicateRow)
            } else {
                uniqueCandidates.append(output.candidate)
            }
        }

        return (uniqueCandidates, duplicateRows)
    }

    nonisolated private static func buildCandidatePreparationResult(
        index: Int,
        file: ResolvedImportFile,
        existingMatches: [String: ExistingTrackMatchSnapshot]
    ) async -> CandidatePreparationResult {
        let preview: ImportPreview
        if let ncmResult = file.ncmResult {
            preview = ImportPreview(
                title: ncmResult.metadata.title,
                artist: ncmResult.metadata.artistName,
                album: ncmResult.metadata.album,
                albumArtist: nil,
                duration: ncmResult.metadata.durationSeconds,
                lyrics: nil,
                artworkData: ncmResult.coverData
            )
        } else {
            let raw = await MetadataExtractionStage.extractMetadata(from: file.fileURL)
            preview = ImportPreview(
                title: raw.title,
                artist: raw.artist,
                album: raw.album,
                albumArtist: raw.albumArtist,
                duration: raw.duration,
                lyrics: raw.lyrics,
                artworkData: nil
            )
        }

        let candidate = ImportCandidate(
            progressID: file.progressID,
            displayName: file.displayName,
            fileURL: file.fileURL,
            metadata: preview
        )
        let dedupKey = LibraryNormalization.normalizedDedupKey(
            title: preview.title,
            artist: preview.artist
        )

        guard let existingMatch = existingMatches[dedupKey], existingMatch.count > 0 else {
            return CandidatePreparationResult(index: index, candidate: candidate, duplicateRow: nil)
        }

        let duplicateRow = DuplicatePairRow(
            id: file.progressID,
            fileURL: file.fileURL,
            incoming: preview,
            existing: existingMatch.preview,
            existingCount: existingMatch.count,
            dedupKey: dedupKey
        )
        return CandidatePreparationResult(
            index: index,
            candidate: candidate,
            duplicateRow: duplicateRow
        )
    }

    nonisolated private static func metadataConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(12, max(4, cpuCount * 2)))
    }
}

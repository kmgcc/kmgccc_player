//
//  ImportEnrichmentStage.swift
//  myPlayer2
//

import Foundation

@MainActor
enum ImportEnrichmentStage {
    static func runImmediate(
        importedRecords: [ImportedTrackRecord],
        progressController: BatchImportProgressDialogController
    ) async {
        guard !importedRecords.isEmpty else { return }

        progressController.update(
            stage: .enrichingMetadata,
            progress: BatchImportStage.progress(
                for: .enrichingMetadata,
                completed: 0,
                total: importedRecords.count
            ),
            detail: "准备补全 \(importedRecords.count) 首歌曲的歌词与封面",
            completedCount: 0,
            totalCount: importedRecords.count
        )

        let snapshots = importedRecords.map {
            ImportEnrichmentSnapshot(
                progressID: $0.progressID,
                id: $0.track.id,
                title: $0.track.title,
                artist: $0.track.artist,
                album: $0.track.album,
                duration: $0.track.duration > 0 ? $0.track.duration : nil,
                needsLyrics: $0.needsLyricsEnrichment,
                needsCover: $0.needsCoverEnrichment
            )
        }
        let recordsByTrackID = Dictionary(
            uniqueKeysWithValues: importedRecords.map { ($0.track.id, $0) }
        )
        let maxConcurrent = enrichmentConcurrency(for: snapshots.count)
        var iterator = snapshots.makeIterator()
        var completedCount = 0
        var lyricSuccessCount = 0
        var coverSuccessCount = 0
        var noResultCount = 0
        var failedCount = 0

        await withTaskGroup(of: ImportEnrichmentTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, snapshots.count) {
                guard let snapshot = iterator.next() else { break }
                progressController.updateItem(
                    id: snapshot.progressID,
                    title: snapshot.title,
                    artist: snapshot.artist,
                    stage: .enrichingMetadata,
                    status: .active,
                    detail: activeEnrichmentDetail(
                        needsLyrics: snapshot.needsLyrics,
                        needsCover: snapshot.needsCover
                    )
                )
                group.addTask {
                    await performImmediateEnrichmentTask(snapshot: snapshot)
                }
            }

            while let output = await group.next() {
                completedCount += 1

                let (status, detail, lyricStats, coverStats, misses, failures) =
                    applyImmediateEnrichmentResult(
                        output,
                        to: recordsByTrackID[output.trackID]
                    )
                lyricSuccessCount += lyricStats
                coverSuccessCount += coverStats
                noResultCount += misses
                failedCount += failures

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
                    progress: BatchImportStage.progress(
                        for: .enrichingMetadata,
                        completed: completedCount,
                        total: snapshots.count
                    ),
                    detail: enrichmentProgressDetail(
                        completed: completedCount,
                        total: snapshots.count,
                        lyricSuccessCount: lyricSuccessCount,
                        coverSuccessCount: coverSuccessCount,
                        noResultCount: noResultCount,
                        failedCount: failedCount
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
                        detail: activeEnrichmentDetail(
                            needsLyrics: snapshot.needsLyrics,
                            needsCover: snapshot.needsCover
                        )
                    )
                    group.addTask {
                        await performImmediateEnrichmentTask(snapshot: snapshot)
                    }
                }
            }
        }
    }

    static func scheduleDeferred(
        records: [ImportedTrackRecord],
        enrichmentService: ImportEnrichmentService
    ) {
        enrichmentService.enqueueTracks(records.map(\.track))
    }

    nonisolated private static func performImmediateEnrichmentTask(
        snapshot: ImportEnrichmentSnapshot
    ) async -> ImportEnrichmentTaskOutput {
        let lyricTask = snapshot.needsLyrics
            ? Task {
                await ImportEnrichmentWorker.fetchLyrics(
                    title: snapshot.title,
                    artist: snapshot.artist,
                    album: snapshot.album,
                    duration: snapshot.duration
                )
            }
            : nil
        let coverTask = snapshot.needsCover
            ? Task {
                await ImportEnrichmentWorker.fetchCover(
                    artist: snapshot.artist,
                    album: snapshot.album
                )
            }
            : nil

        return ImportEnrichmentTaskOutput(
            progressID: snapshot.progressID,
            trackID: snapshot.id,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            lyricOutcome: await lyricTask?.value,
            coverOutcome: await coverTask?.value
        )
    }

    private static func applyImmediateEnrichmentResult(
        _ output: ImportEnrichmentTaskOutput,
        to record: ImportedTrackRecord?
    ) -> (BatchImportItemStatus, String, Int, Int, Int, Int) {
        guard let record else {
            return (.warning, "补全结果未能写回，歌曲已保留导入", 0, 0, 0, 1)
        }

        var detailParts: [String] = []
        var status: BatchImportItemStatus = .success
        var lyricSuccessCount = 0
        var coverSuccessCount = 0
        var noResultCount = 0
        var failedCount = 0

        if let lyricOutcome = output.lyricOutcome {
            switch lyricOutcome {
            case .completed(let ttml):
                if record.track.ttmlLyricText == nil {
                    record.track.ttmlLyricText = ttml
                }
                lyricSuccessCount += 1
                detailParts.append("歌词已补全")
            case .noResults:
                noResultCount += 1
                status = .warning
                detailParts.append("未找到歌词")
            case .failed:
                failedCount += 1
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
                coverSuccessCount += 1
                detailParts.append("封面已补全")
            case .noResults:
                noResultCount += 1
                status = .warning
                detailParts.append("未找到封面")
            case .failed:
                failedCount += 1
                status = .warning
                detailParts.append("封面补全失败")
            }
        }

        if detailParts.isEmpty {
            detailParts.append("歌曲已导入")
        }

        return (
            status,
            detailParts.joined(separator: "，"),
            lyricSuccessCount,
            coverSuccessCount,
            noResultCount,
            failedCount
        )
    }

    nonisolated private static func enrichmentProgressDetail(
        completed: Int,
        total: Int,
        lyricSuccessCount: Int,
        coverSuccessCount: Int,
        noResultCount: Int,
        failedCount: Int
    ) -> String {
        var parts = ["已处理 \(completed) / \(total)"]
        if lyricSuccessCount > 0 {
            parts.append("歌词 \(lyricSuccessCount)")
        }
        if coverSuccessCount > 0 {
            parts.append("封面 \(coverSuccessCount)")
        }
        if noResultCount > 0 {
            parts.append("未找到 \(noResultCount)")
        }
        if failedCount > 0 {
            parts.append("失败 \(failedCount)")
        }
        return parts.joined(separator: "，")
    }

    nonisolated private static func activeEnrichmentDetail(
        needsLyrics: Bool,
        needsCover: Bool
    ) -> String {
        "正在补全\(enrichmentWorkLabel(needsLyrics: needsLyrics, needsCover: needsCover))"
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

    nonisolated private static func enrichmentConcurrency(for count: Int) -> Int {
        guard count > 0 else { return 1 }
        let cpuCount = max(1, ProcessInfo.processInfo.processorCount)
        return min(count, min(4, max(2, cpuCount / 2)))
    }
}

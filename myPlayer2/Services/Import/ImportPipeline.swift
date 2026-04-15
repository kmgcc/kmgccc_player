//
//  ImportPipeline.swift
//  myPlayer2
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ImportPipeline {
    nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ncm",
    ]

    static let supportedUTTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        .aiff,
        .wav,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "m4a") ?? .mpeg4Audio,
        UTType(filenameExtension: "alac") ?? .audio,
        UTType(filenameExtension: "ncm") ?? .audio,
    ].compactMap { $0 }

    static func pickURLs(triggeredAt _: Date) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的音乐文件"
        panel.message = "可选择音乐文件，或包含音乐文件的文件夹。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedUTTypes
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            Log.warning("Import panel host window unavailable", category: .import)
            return nil
        }

        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { modalResponse in
                continuation.resume(returning: modalResponse)
            }
        }

        guard response == .OK else { return nil }
        return panel.urls
    }

    @discardableResult
    static func run(
        urls selectedURLs: [URL],
        to playlist: Playlist,
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService,
        importEnrichmentService: ImportEnrichmentService
    ) async -> Int {
        Log.debug(
            "importSelectedURLs called for playlist: '\(playlist.name)' (id=\(playlist.id)) count=\(selectedURLs.count)",
            category: .import
        )
        let progressController = BatchImportProgressDialogController()
        defer { progressController.closeNow() }
        progressController.update(
            stage: .scanning,
            progress: BatchImportStage.progress(for: .scanning, completed: 0, total: selectedURLs.count),
            detail: "正在扫描所选文件和文件夹中的音频文件",
            completedCount: 0,
            totalCount: selectedURLs.count
        )

        // CRITICAL: Start accessing security-scoped resources IMMEDIATELY
        // NSOpenPanel returns security-scoped URLs that expire if not accessed
        var accessingURLs: [URL] = []
        for url in selectedURLs {
            let didStart = url.startAccessingSecurityScopedResource()
            Log.trace("startAccessingSecurityScopedResource for '\(url.lastPathComponent)': \(didStart)", category: .import)

            // Additional diagnostics
            Log.trace("   ↳ URL.isFileURL: \(url.isFileURL)", category: .import)
            Log.trace("   ↳ URL.path: \(url.path)", category: .import)
            let isReadable = FileManager.default.isReadableFile(atPath: url.path)
            Log.trace("   ↳ FileManager.isReadableFile: \(isReadable)", category: .import)

            if didStart {
                accessingURLs.append(url)
            } else {
                Log.warning("Failed to start accessing security-scoped resource!", category: .import)
            }
        }

        // Ensure we stop accessing at the end
        defer {
            for url in accessingURLs {
                url.stopAccessingSecurityScopedResource()
                Log.trace("stopAccessingSecurityScopedResource for '\(url.lastPathComponent)'", category: .import)
            }
        }

        // Collect all audio files (including from directories) - OFF MAIN THREAD
        let (filesToImport, ncmFiles) = await Task.detached(priority: .userInitiated) {
            var filesToImport: [URL] = []
            var ncmFiles: [URL] = []

            for url in selectedURLs {
                if url.hasDirectoryPath {
                    let audioFiles = ImportPipeline.findAudioFiles(in: url)
                    for file in audioFiles {
                        if ImportPipeline.isNCMFile(file) {
                            ncmFiles.append(file)
                        } else {
                            filesToImport.append(file)
                        }
                    }
                } else if ImportPipeline.isAudioFile(url) {
                    if ImportPipeline.isNCMFile(url) {
                        ncmFiles.append(url)
                    } else {
                        filesToImport.append(url)
                    }
                }
            }
            return (filesToImport, ncmFiles)
        }.value
        let discoveredFileCount = filesToImport.count + ncmFiles.count
        progressController.update(
            stage: .scanning,
            progress: BatchImportStage.progress(
                for: .scanning,
                completed: discoveredFileCount,
                total: max(discoveredFileCount, 1)
            ),
            detail: discoveredFileCount > 0 ? "已找到 \(discoveredFileCount) 个可导入文件" : "未找到支持的音频文件",
            completedCount: discoveredFileCount,
            totalCount: discoveredFileCount
        )

        guard discoveredFileCount > 0 else {
            Log.info("No supported audio files found in selection", category: .import)
            return 0
        }

        let discoveredItems = (filesToImport + ncmFiles).map {
            BatchImportProgressItemSeed(id: $0.path, fileName: $0.lastPathComponent)
        }
        progressController.setItems(discoveredItems)
        for fileURL in filesToImport {
            progressController.updateItem(
                id: fileURL.path,
                stage: .metadata,
                status: .waiting,
                detail: "等待解析歌曲信息"
            )
        }
        for sourceURL in ncmFiles {
            progressController.updateItem(
                id: sourceURL.path,
                stage: .ncmConversion,
                status: .waiting,
                detail: "等待转换 NCM 文件"
            )
        }

        var resolvedFiles: [ResolvedImportFile] = filesToImport.map {
            ResolvedImportFile(
                progressID: $0.path,
                displayName: $0.lastPathComponent,
                fileURL: $0,
                ncmResult: nil
            )
        }

        if !ncmFiles.isEmpty {
            Log.debug("Found \(ncmFiles.count) NCM files to convert", category: .import)
            let results = await NCMConversionStage.convert(
                ncmFiles,
                progressController: progressController
            )
            for output in results {
                guard let result = output.result else { continue }
                resolvedFiles.append(
                    ResolvedImportFile(
                        progressID: output.sourceURL.path,
                        displayName: output.displayName,
                        fileURL: result.audioFileURL,
                        ncmResult: result
                    )
                )
            }
        } else {
            progressController.update(
                stage: .convertingNCM,
                progress: BatchImportStage.progress(for: .convertingNCM, completed: 0, total: 0),
                detail: "未检测到 NCM 文件，跳过转换阶段",
                completedCount: 0,
                totalCount: 0
            )
        }

        Log.debug("Found \(resolvedFiles.count) audio files to import to '\(playlist.name)'", category: .import)

        let libraryTracks = await repository.fetchTracks(in: nil)
        let existingByDedupKey = Dictionary(grouping: libraryTracks) {
            LibraryNormalization.normalizedDedupKey(title: $0.title, artist: $0.artist)
        }
        let existingSnapshots = existingByDedupKey.mapValues { matches in
            ExistingTrackMatchSnapshot(
                preview: matches.first.map {
                    TrackPreview(
                        title: $0.title,
                        artist: $0.artist,
                        artworkData: $0.artworkData
                    )
                },
                count: matches.count
            )
        }

        let preparedCandidates = await DuplicateChecker.prepare(
            files: resolvedFiles,
            existingMatches: existingSnapshots,
            progressController: progressController
        )
        let uniqueCandidates = preparedCandidates.unique
        let duplicateRows = preparedCandidates.duplicates

        var selectedDuplicates: [ImportCandidate] = []
        if !duplicateRows.isEmpty {
            Log.debug("Found \(duplicateRows.count) duplicates, presenting dialog...", category: .import)
            progressController.update(
                stage: .waitingForDuplicateChoice,
                progress: BatchImportStage.progress(
                    for: .waitingForDuplicateChoice,
                    completed: duplicateRows.count,
                    total: duplicateRows.count
                ),
                detail: "发现 \(duplicateRows.count) 首重复歌曲，等待选择是否继续导入",
                completedCount: duplicateRows.count,
                totalCount: duplicateRows.count
            )
            if let selectedRows = presentDuplicateSelectionDialog(duplicateRows) {
                Log.info("Dialog confirmed. Selected duplicates to import: \(selectedRows.count)", category: .import)
                let selectedIDSet = Set(selectedRows.map(\.id))
                selectedDuplicates = duplicateRows.compactMap { row in
                    if selectedIDSet.contains(row.id) {
                        progressController.updateItem(
                            id: row.id,
                            title: row.incoming.title,
                            artist: row.incoming.artist,
                            stage: .duplicateCheck,
                            status: .success,
                            detail: "已选择继续导入重复歌曲"
                        )
                        return ImportCandidate(
                            progressID: row.id,
                            displayName: row.fileURL.lastPathComponent,
                            fileURL: row.fileURL,
                            metadata: row.incoming
                        )
                    }

                    progressController.updateItem(
                        id: row.id,
                        title: row.incoming.title,
                        artist: row.incoming.artist,
                        stage: .duplicateCheck,
                        status: .skipped,
                        detail: "检测到重复，已跳过导入"
                    )
                    return nil
                }
            } else {
                Log.debug("User cancelled import via duplicate dialog (result was nil)", category: .import)
                return 0
            }
        }

        Log.debug("--------------------------------------------------", category: .import)
        Log.debug("Import Logic Verification:", category: .import)
        Log.debug("   Unique Candidates : \(uniqueCandidates.count)", category: .import)
        Log.debug("   Duplicate Rows    : \(duplicateRows.count)", category: .import)
        Log.debug("   Selected Dups     : \(selectedDuplicates.count)", category: .import)

        let finalCandidates = uniqueCandidates + selectedDuplicates
        Log.debug("   -> FINAL Candidates: \(finalCandidates.count)", category: .import)
        Log.debug("--------------------------------------------------", category: .import)

        progressController.update(
            stage: .importingFiles,
            progress: BatchImportStage.progress(for: .importingFiles, completed: 0, total: finalCandidates.count),
            detail: finalCandidates.isEmpty
                ? "没有需要导入的新歌曲"
                : "准备导入 \(finalCandidates.count) 首歌曲",
            completedCount: 0,
            totalCount: finalCandidates.count
        )

        let enrichmentMode: ImportEnrichmentMode =
            AppSettings.shared.deferImportEnrichment ? .deferred : .immediate
        let importedRecords = await ImportWriteStage.importCandidates(
            finalCandidates,
            progressController: progressController,
            enrichmentMode: enrichmentMode,
            libraryService: libraryService
        )

        guard !importedRecords.isEmpty else {
            print("⚠️ No tracks to import")
            return 0
        }

        let importedTracks = importedRecords.map(\.track)

        switch enrichmentMode {
        case .immediate:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                await ImportEnrichmentStage.runImmediate(
                    importedRecords: recordsNeedingEnrichment,
                    progressController: progressController
                )
            } else {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: BatchImportStage.progress(for: .enrichingMetadata, completed: 0, total: 0),
                    detail: "所有歌曲已有歌词与封面，跳过在线补全",
                    completedCount: 0,
                    totalCount: 0
                )
            }

            await ImportWriteStage.save(
                importedTracks,
                to: playlist,
                progressController: progressController,
                repository: repository
            )
        case .deferred:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: BatchImportStage.progress(
                        for: .enrichingMetadata,
                        completed: 0,
                        total: recordsNeedingEnrichment.count
                    ),
                    detail: "导入完成后将在后台补全 \(recordsNeedingEnrichment.count) 首歌曲的歌词与封面",
                    completedCount: 0,
                    totalCount: recordsNeedingEnrichment.count
                )
            } else {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: BatchImportStage.progress(for: .enrichingMetadata, completed: 0, total: 0),
                    detail: "所有歌曲已有歌词与封面，无需后台补全",
                    completedCount: 0,
                    totalCount: 0
                )
            }

            await ImportWriteStage.save(
                importedTracks,
                to: playlist,
                progressController: progressController,
                repository: repository
            )

            if !recordsNeedingEnrichment.isEmpty {
                ImportEnrichmentStage.scheduleDeferred(
                    records: recordsNeedingEnrichment,
                    enrichmentService: importEnrichmentService
                )
            }
        }

        for record in importedRecords {
            progressController.completeImportedItem(id: record.progressID)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: BatchImportStage.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )

        progressController.update(
            stage: .completed,
            progress: 1.0,
            detail: "已成功导入 \(importedRecords.count) 首歌曲到“\(playlist.name)”",
            completedCount: importedTracks.count,
            totalCount: finalCandidates.count
        )
        try? await Task.sleep(nanoseconds: 500_000_000)

        print("✅ Import complete: \(importedRecords.count) imported")
        return importedRecords.count
    }

    /// Recursively find audio files in a directory.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func findAudioFiles(in directory: URL) -> [URL] {
        var audioFiles: [URL] = []

        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return audioFiles
        }

        for case let fileURL as URL in enumerator {
            if isAudioFile(fileURL) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles
    }

    /// Check if a URL is a supported audio file.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// Check if a URL is an NCM file.
    /// Made nonisolated static to allow calling from background tasks.
    nonisolated private static func isNCMFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "ncm"
    }

    private static func presentDuplicateSelectionDialog(_ duplicateRows: [DuplicatePairRow])
        -> [DuplicatePairRow]?
    {
        DuplicateImportDialogPresenter.present(rows: duplicateRows)
    }
}

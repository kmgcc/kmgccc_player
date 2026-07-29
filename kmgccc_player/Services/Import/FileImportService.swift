//
//  FileImportService.swift
//  myPlayer2
//
//  kmgccc_player - File Import Service
//  Imports audio files into a SPECIFIC PLAYLIST using NSOpenPanel.
//  Creates security-scoped bookmarks for sandbox access.
//

import AVFoundation
import AppKit
import Combine
import CoreServices
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Types

/// Errors surfaced per-file during import. `errorDescription` is shown to the
/// user in the batch import progress dialog, so messages are user-facing.
nonisolated enum AudioImportError: LocalizedError, Sendable {
    /// AVFoundation / Core Audio could not decode the file's audio.
    case undecodable(fileName: String)

    var errorDescription: String? {
        switch self {
        case .undecodable(let fileName):
            return "“\(fileName)”当前无法解码，文件可能已损坏或编码不受支持"
        }
    }
}

nonisolated struct ImportPreview: Sendable {
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let duration: Double
    let lyrics: String?
    let artworkData: Data?
}

nonisolated struct TrackPreview: Sendable {
    let title: String
    let artist: String
    let artworkData: Data?
}

nonisolated struct DuplicatePairRow: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let incoming: ImportPreview
    let existing: TrackPreview?
    let existingCount: Int
    let dedupKey: String
}

// MARK: - Service

/// Service for importing audio files into a playlist.
/// Supports mp3, m4a, aac, alac, flac, wav.
@MainActor
final class FileImportService: FileImportServiceProtocol {
    private struct ImportCandidate: Sendable {
        let progressID: String
        let displayName: String
        let fileURL: URL
        let metadata: ImportPreview
        let discoveredFile: ImportDiscoveredFile
        let trackID: UUID?
        let placement: ImportPlacement?
        let ncmOperationID: UUID?
        let ncmAssociation: NCMConversionAssociation?
        let ncmLocator: ReferencedFileLocator?
        let recoveryTrackID: UUID?

        func prepared(trackID: UUID, placement: ImportPlacement) -> ImportCandidate {
            ImportCandidate(
                progressID: progressID,
                displayName: displayName,
                fileURL: fileURL,
                metadata: metadata,
                discoveredFile: discoveredFile,
                trackID: trackID,
                placement: placement,
                ncmOperationID: ncmOperationID,
                ncmAssociation: ncmAssociation,
                ncmLocator: ncmLocator,
                recoveryTrackID: recoveryTrackID
            )
        }
    }

    private struct ResolvedImportFile: Sendable {
        let progressID: String
        let displayName: String
        let fileURL: URL
        let ncmResult: NCMConversionResult?
        let discoveredFile: ImportDiscoveredFile
        let referencedNCMOutput: ReferencedNCMConversionOutput?
    }

    private struct ImportedTrackRecord {
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

    private struct ImportedTrackPayload: Sendable {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let albumArtist: String?
        let duration: Double
        let importedAt: Date
        let originalFilePath: String
        let mediaLocator: TrackMediaLocator
        let stagedAudioURL: URL?
        let artworkData: Data?
        let ttmlLyricText: String?
        let lyricsText: String?
        let ncmConversionAssociation: NCMConversionAssociation?
    }

    private struct ExistingTrackMatchSnapshot: Sendable {
        let preview: TrackPreview?
        let count: Int
    }

    private struct CandidatePreparationResult: Sendable {
        let index: Int
        let candidate: ImportCandidate
        let duplicateRow: DuplicatePairRow?
    }

    private struct NCMConversionTaskOutput: Sendable {
        let sourceURL: URL
        let displayName: String
        let result: NCMConversionResult?
        let errorDescription: String?
    }

    private struct ImportTaskOutput: Sendable {
        let index: Int
        let trackID: UUID
        let progressID: String
        let displayName: String
        let metadata: ImportPreview
        let payload: ImportedTrackPayload?
        let needsLyricsEnrichment: Bool
        let needsCoverEnrichment: Bool
        let needsTrackMetadataEnrichment: Bool
        let needsArtistMetadataEnrichment: Bool
        let needsAlbumMetadataEnrichment: Bool
        let needsArtistArtworkEnrichment: Bool
        let needsAlbumArtworkEnrichment: Bool
        let errorDescription: String?
    }

    private struct ImportBatchResult {
        let records: [ImportedTrackRecord]
        let createdTrackIDs: Set<UUID>
        let cancelled: Bool
    }

    private struct ImportEnrichmentSnapshot: Sendable {
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

    private struct ImportEnrichmentTaskOutput: Sendable {
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

    // MARK: - Supported Types

    // Format support is centralized in `AudioFormatSupport` so the picker
    // filter, the import whitelist, and library scanning cannot drift apart.
    nonisolated static let supportedExtensions: Set<String> = AudioFormatSupport.importableExtensions

    static let supportedUTTypes: [UTType] = AudioFormatSupport.openPanelContentTypes

    private let repository: LibraryRepositoryProtocol
    private let libraryService: LocalLibraryService
    nonisolated let paths: LibraryPaths
    private let importEnrichmentService: ImportEnrichmentService
    private let storageBackend: any LibraryStorageBackend
    private let referencedNCMConversionService: ReferencedNCMConversionService?
    private let qqMusicCoverService: QQMusicCoverService
    private let lyricsSearchCoordinator: LyricsSearchCoordinator
    private let amllDBService: AMLLDBService
    private let uiPresentationObserver: (() -> Void)?
    private var importInProgress = false

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService,
        importEnrichmentService: ImportEnrichmentService,
        storageBackend: any LibraryStorageBackend,
        referencedNCMConversionService: ReferencedNCMConversionService? = nil,
        qqMusicCoverService: QQMusicCoverService = .shared,
        lyricsSearchCoordinator: LyricsSearchCoordinator = .shared,
        amllDBService: AMLLDBService = .shared,
        uiPresentationObserver: (() -> Void)? = nil
    ) {
        self.repository = repository
        self.libraryService = libraryService
        self.paths = libraryService.paths
        self.importEnrichmentService = importEnrichmentService
        self.storageBackend = storageBackend
        self.referencedNCMConversionService = referencedNCMConversionService
        self.qqMusicCoverService = qqMusicCoverService
        self.lyricsSearchCoordinator = lyricsSearchCoordinator
        self.amllDBService = amllDBService
        self.uiPresentationObserver = uiPresentationObserver
        Log.debug("FileImportService initialized", category: .import)
    }

    // MARK: - Public Methods

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        await importEnrichmentService.cancelEnrichment(for: trackIDs)
    }

    func pickImportURLs(triggeredAt _: Date) async -> [URL]? {
        uiPresentationObserver?()
        let panel = NSOpenPanel()
        panel.title = "选择要导入的音乐文件"
        panel.message = "可选择音乐文件，或包含音乐文件的文件夹。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedUTTypes
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

    /// Import selected files/folders into a specific playlist.
    @discardableResult
    func importSelectedURLs(
        _ selectedURLs: [URL],
        to playlist: Playlist,
        metadataOverride: ImportMetadataOverride? = nil
    ) async -> Int {
        await importURLs(
            selectedURLs,
            to: playlist,
            metadataOverride: metadataOverride,
            presentation: .interactive
        ).count
    }

    /// Production entry used by referenced-source reconciliation. It uses the same
    /// metadata, sidecar, and visibility pipeline without presenting AppKit UI.
    func importAutomatically(_ urls: [URL]) async -> [Track] {
        await importURLs(urls, to: nil, metadataOverride: nil, presentation: .automatic)
    }

    /// Setup entry. The caller retains `selection` across this entire call so the
    /// backend can sign durable folder/file bookmarks before picker access expires.
    func importInitialSelection(_ selection: LibraryInitialImportSelection) async -> LibraryInitialImportResult {
        let imported = await importURLs(
            selection.urls,
            to: nil,
            metadataOverride: nil,
            presentation: .automatic
        )
        let plan = storageBackend.lastPreparedInputPlan
        var failures = plan?.failures ?? []
        if let plan, imported.count < plan.files.count {
            failures.append(contentsOf: plan.files.dropFirst(imported.count).map {
                ImportInputFailure(url: $0.url, message: "Import failed")
            })
        } else if let plan, plan.files.isEmpty, !selection.urls.isEmpty {
            failures.append(contentsOf: selection.urls.map {
                ImportInputFailure(url: $0, message: "No supported audio found")
            })
        }
        return LibraryInitialImportResult(
            requested: selection.urls.count,
            planned: plan?.files.count ?? 0,
            imported: imported.count,
            failures: failures,
            sourceIDs: plan?.directorySources.map(\.source.id) ?? []
        )
    }

    private enum ImportPresentation {
        case interactive
        case automatic
    }

    private func importURLs(
        _ selectedURLs: [URL],
        to playlist: Playlist?,
        metadataOverride: ImportMetadataOverride?,
        presentation: ImportPresentation
    ) async -> [Track] {
        var crashBreadcrumbResult = "not_completed"
        var crashBreadcrumbImportedCount = 0
        CrashBreadcrumbRecorder.shared.record(
            .libraryImportStarted,
            metadata: [.count: .integer(Int64(selectedURLs.count))]
        )
        defer {
            CrashBreadcrumbRecorder.shared.record(
                .libraryImportFinished,
                metadata: [
                    .result: .string(crashBreadcrumbResult),
                    .count: .integer(Int64(crashBreadcrumbImportedCount)),
                ]
            )
        }
        Log.debug(
            "import URLs destination=\(playlist?.id.uuidString ?? "library") count=\(selectedURLs.count) override=\(String(describing: metadataOverride))",
            category: .import
        )

        guard !importInProgress else {
            crashBreadcrumbResult = "rejected_concurrent"
            Log.warning(
                "[Import] rejected concurrent import request destination=\(playlist?.id.uuidString ?? "library")",
                category: .import
            )
            return []
        }
        importInProgress = true
        await LibraryImportCoordinator.shared.beginBatch(reason: "fileImport")
        defer {
            importInProgress = false
            Task {
                await LibraryImportCoordinator.shared.endBatch(reason: "fileImport")
            }
        }

        let cancellationToken = ImportCancellationToken()
        let importSession: ImportSession
        do {
            importSession = try ImportSession(paths: paths)
        } catch {
            Log.error(
                "[Import] failed to create import session: \(error.localizedDescription)",
                category: .import
            )
            return []
        }

        if presentation == .interactive { uiPresentationObserver?() }
        let progressController = BatchImportProgressDialogController(
            presentsWindow: presentation == .interactive,
            onCancelRequested: {
                Task {
                    await cancellationToken.requestCancel()
                }
            }
        )
        defer { progressController.closeNow() }
        progressController.update(
            stage: .scanning,
            progress: Self.progress(for: .scanning, completed: 0, total: selectedURLs.count),
            detail: "正在扫描所选文件和文件夹中的音频文件",
            completedCount: 0,
            totalCount: selectedURLs.count
        )

        // The backend captures panel/drag scopes before this suspension returns.
        let inputPlan = await storageBackend.prepareInputs(selectedURLs)
        defer { storageBackend.finishImportBatch() }
        var newFiles: [ImportDiscoveredFile] = []
        var reusedTracks: [Track] = []
        for file in inputPlan.files {
            guard storageBackend.mode == .referenced, let fingerprint = file.fingerprint,
                  let existingTrack = await repository.track(matching: fingerprint) else {
                newFiles.append(file)
                continue
            }
            do {
                let placement = try await storageBackend.makePlacement(
                    for: file,
                    trackID: existingTrack.id,
                    stagingDirectoryURL: importSession.stagingDirectoryURL
                )
                guard case let .referenced(locator) = placement else {
                    throw LibraryBackendError.modeMismatch(expected: .referenced, actual: placement.storageKind)
                }
                try await repository.mergeReferencedLocator(locator, into: existingTrack)
                reusedTracks.append(existingTrack)
            } catch {
                Log.warning("[Import] identity reuse failed track=\(existingTrack.id.uuidString)", category: .import)
            }
        }
        if !reusedTracks.isEmpty, let playlist {
            await repository.addTracks(reusedTracks, to: playlist)
        }
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
        let discoveredFileCount = filesToImport.count + eligibleNCMFiles.count
        progressController.update(
            stage: .scanning,
            progress: Self.progress(for: .scanning, completed: discoveredFileCount, total: max(discoveredFileCount, 1)),
            detail: discoveredFileCount > 0 ? "已找到 \(discoveredFileCount) 个可导入文件" : "未找到支持的音频文件",
            completedCount: discoveredFileCount,
            totalCount: discoveredFileCount
        )

        guard discoveredFileCount > 0 else {
            Log.info("No supported audio files found in selection", category: .import)
            importSession.cleanupStaging()
            return reusedTracks
        }

        if await isImportCancellationRequested(progressController, cancellationToken) {
            return await finishCancelledImport(
                session: importSession,
                importedRecords: [],
                createdTrackIDs: [],
                to: playlist,
                progressController: progressController,
                totalCount: discoveredFileCount
            )
        }

        let discoveredItems = (filesToImport + eligibleNCMFiles).map {
            BatchImportProgressItemSeed(id: $0.url.path, fileName: $0.url.lastPathComponent)
        }
        progressController.setItems(discoveredItems)
        for file in filesToImport {
            progressController.updateItem(
                id: file.url.path,
                stage: .metadata,
                status: .waiting,
                detail: "等待解析歌曲信息"
            )
        }
        for sourceFile in eligibleNCMFiles {
            let sourceURL = sourceFile.url
            progressController.updateItem(
                id: sourceURL.path,
                stage: .ncmConversion,
                status: .waiting,
                detail: "等待转换 NCM 文件"
            )
        }

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
            let results = await convertNCMFiles(
                eligibleNCMFiles.map(\.url),
                progressController: progressController,
                session: importSession,
                cancellationToken: cancellationToken
            )
            if await isImportCancellationRequested(progressController, cancellationToken) {
                return await finishCancelledImport(
                    session: importSession,
                    importedRecords: [],
                    createdTrackIDs: [],
                    to: playlist,
                    progressController: progressController,
                    totalCount: discoveredFileCount
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
                    let output = try await referencedNCMConversionService.convert(file)
                    resolvedFiles.append(ResolvedImportFile(
                        progressID: file.url.path,
                        displayName: file.url.lastPathComponent,
                        fileURL: output.result.audioFileURL,
                        ncmResult: output.result,
                        discoveredFile: ImportDiscoveredFile(
                            url: output.result.audioFileURL,
                            memberships: output.locator.sourceMemberships,
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
                        reusedTracks.append(existing)
                        if let playlist { await repository.addTracks([existing], to: playlist) }
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
                progress: Self.progress(for: .convertingNCM, completed: 0, total: 0),
                detail: "未检测到 NCM 文件，跳过转换阶段",
                completedCount: 0,
                totalCount: 0
            )
        }

        Log.debug("Found \(resolvedFiles.count) audio files to import", category: .import)

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

        let preparedCandidates = await prepareImportCandidates(
            files: resolvedFiles,
            existingMatches: existingSnapshots,
            metadataOverride: metadataOverride,
            progressController: progressController,
            cancellationToken: cancellationToken
        )
        let uniqueCandidates = preparedCandidates.unique
        let duplicateRows = preparedCandidates.duplicates

        if await isImportCancellationRequested(progressController, cancellationToken) {
            return await finishCancelledImport(
                session: importSession,
                importedRecords: [],
                createdTrackIDs: [],
                to: playlist,
                progressController: progressController,
                totalCount: discoveredFileCount
            )
        }

        var selectedDuplicates: [ImportCandidate] = []
        if !duplicateRows.isEmpty, presentation == .interactive {
            Log.debug("Found \(duplicateRows.count) duplicates, presenting dialog...", category: .import)
            progressController.update(
                stage: .waitingForDuplicateChoice,
                progress: Self.progress(for: .waitingForDuplicateChoice, completed: duplicateRows.count, total: duplicateRows.count),
                detail: "发现 \(duplicateRows.count) 首重复歌曲，等待选择是否继续导入",
                completedCount: duplicateRows.count,
                totalCount: duplicateRows.count
            )
            if let selectedRows = presentDuplicateSelectionDialog(duplicateRows) {
                Log.info("Dialog confirmed. Selected duplicates to import: \(selectedRows.count)", category: .import)
                let selectedIDSet = Set(selectedRows.map(\.id))
                let candidatesByID = Dictionary(
                    uniqueKeysWithValues: (uniqueCandidates + preparedCandidates.duplicateCandidates).map { ($0.progressID, $0) }
                )
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
                        return candidatesByID[row.id]
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
                return []
            }
        }

        // Logic Verification Logs
        Log.debug("--------------------------------------------------", category: .import)
        Log.debug("Import Logic Verification:", category: .import)
        Log.debug("   Unique Candidates : \(uniqueCandidates.count)", category: .import)
        Log.debug("   Duplicate Rows    : \(duplicateRows.count)", category: .import)
        Log.debug("   Selected Dups     : \(selectedDuplicates.count)", category: .import)

        let selectedCandidates = uniqueCandidates + selectedDuplicates
        var finalCandidates: [ImportCandidate] = []
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
                        stagingDirectoryURL: importSession.stagingDirectoryURL
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
        Log.debug("   -> FINAL Candidates: \(finalCandidates.count)", category: .import)
        Log.debug("--------------------------------------------------", category: .import)

        progressController.update(
            stage: .importingFiles,
            progress: Self.progress(for: .importingFiles, completed: 0, total: finalCandidates.count),
            detail: finalCandidates.isEmpty
                ? "没有需要导入的新歌曲"
                : "准备导入 \(finalCandidates.count) 首歌曲",
            completedCount: 0,
            totalCount: finalCandidates.count
        )

        let enrichmentMode: ImportEnrichmentMode =
            AppSettings.shared.deferImportEnrichment ? .deferred : .immediate
        let importBatch = await importCandidatesWithProgress(
            finalCandidates,
            progressController: progressController,
            enrichmentMode: enrichmentMode,
            session: importSession,
            cancellationToken: cancellationToken
        )
        let importedRecords = importBatch.records

        let importCancellationRequested = await isImportCancellationRequested(progressController, cancellationToken)
        if importBatch.cancelled || importCancellationRequested {
            return await finishCancelledImport(
                session: importSession,
                importedRecords: importedRecords,
                createdTrackIDs: importBatch.createdTrackIDs,
                to: playlist,
                progressController: progressController,
                totalCount: finalCandidates.count
            )
        }

        guard !importedRecords.isEmpty else {
            print("⚠️ No tracks to import")
            importSession.cleanupStaging()
            _ = await cleanupFailedImportResidue(reason: "importNoSuccessfulTracks")
            return reusedTracks
        }

        let importedTracks = importedRecords.map(\.track)

        switch enrichmentMode {
        case .immediate:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                let enrichmentCancelled = await enrichImportedRecordsWithProgress(
                    importedRecords: recordsNeedingEnrichment,
                    progressController: progressController,
                    cancellationToken: cancellationToken
                )
                let enrichmentCancellationRequested = await isImportCancellationRequested(progressController, cancellationToken)
                if enrichmentCancelled || enrichmentCancellationRequested {
                    return await finishCancelledImport(
                        session: importSession,
                        importedRecords: importedRecords,
                        createdTrackIDs: importBatch.createdTrackIDs,
                        to: playlist,
                        progressController: progressController,
                        totalCount: finalCandidates.count
                    )
                }
            } else {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(for: .enrichingMetadata, completed: 0, total: 0),
                    detail: "所有歌曲已有歌词与封面，跳过在线补全",
                    completedCount: 0,
                    totalCount: 0
                )
            }

            let didSave = await saveImportedTracks(
                importedTracks,
                to: playlist,
                progressController: progressController,
                session: importSession,
                cancellationToken: cancellationToken
            )
            guard didSave else {
                return await finishCancelledImport(
                    session: importSession,
                    importedRecords: importedRecords,
                    createdTrackIDs: importBatch.createdTrackIDs,
                    to: playlist,
                    progressController: progressController,
                    totalCount: finalCandidates.count
                )
            }
        case .deferred:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(
                        for: .enrichingMetadata,
                        completed: 0,
                        total: recordsNeedingEnrichment.count
                    ),
                    detail: "导入完成后将在后台补全 \(recordsNeedingEnrichment.count) 首歌曲的信息",
                    completedCount: 0,
                    totalCount: recordsNeedingEnrichment.count
                )
            } else {
                progressController.update(
                    stage: .enrichingMetadata,
                    progress: Self.progress(for: .enrichingMetadata, completed: 0, total: 0),
                    detail: "所有歌曲已有歌词与封面，无需后台补全",
                    completedCount: 0,
                    totalCount: 0
                )
            }

            let didSave = await saveImportedTracks(
                importedTracks,
                to: playlist,
                progressController: progressController,
                session: importSession,
                cancellationToken: cancellationToken
            )
            guard didSave else {
                return await finishCancelledImport(
                    session: importSession,
                    importedRecords: importedRecords,
                    createdTrackIDs: importBatch.createdTrackIDs,
                    to: playlist,
                    progressController: progressController,
                    totalCount: finalCandidates.count
                )
            }

            if !recordsNeedingEnrichment.isEmpty {
                await importEnrichmentService.enqueueTracks(recordsNeedingEnrichment.map(\.track))
            }
        }

        _ = await cleanupFailedImportResidue(reason: "importCompleted")
        importSession.cleanupStaging()

        for record in importedRecords {
            progressController.completeImportedItem(id: record.progressID)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 2, total: 2),
            detail: "资料库与播放列表保存完成",
            completedCount: 2,
            totalCount: 2
        )

        progressController.update(
            stage: .completed,
            progress: 1.0,
            detail: playlist.map { "已成功导入 \(importedRecords.count) 首歌曲到“\($0.name)”" }
                ?? "已成功导入 \(importedRecords.count) 首歌曲",
            completedCount: importedTracks.count,
            totalCount: finalCandidates.count
        )
        try? await Task.sleep(nanoseconds: 500_000_000)

        print("✅ Import complete: \(importedRecords.count) imported")
        crashBreadcrumbResult = "completed"
        crashBreadcrumbImportedCount = importedRecords.count + reusedTracks.count
        return importedTracks + reusedTracks
    }

    // MARK: - Private Methods

    private func importCandidatesWithProgress(
        _ candidates: [ImportCandidate],
        progressController: BatchImportProgressDialogController,
        enrichmentMode: ImportEnrichmentMode,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> ImportBatchResult {
        guard !candidates.isEmpty else {
            return ImportBatchResult(records: [], createdTrackIDs: [], cancelled: false)
        }

        var orderedRecords = Array<ImportedTrackRecord?>(repeating: nil, count: candidates.count)
        var iterator = Array(candidates.enumerated()).makeIterator()
        let maxConcurrent = Self.importConcurrency(for: candidates.count)
        var processedCount = 0
        var importedCount = 0
        var failedCount = 0
        var createdTrackIDs: Set<UUID> = []
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
                    await Self.performImportTask(
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
                        ? Self.pendingEnrichmentDetail(
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
                    progress: Self.progress(
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
                        await Self.performImportTask(
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
            cancelled: cancelled
        )
    }

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

    private func saveImportedTracks(
        _ importedTracks: [Track],
        to playlist: Playlist?,
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> Bool {
        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 0, total: 2),
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
            progress: Self.progress(for: .savingLibrary, completed: 1, total: 2),
            detail: "歌曲已写入资料库，正在加入播放列表",
            completedCount: 1,
            totalCount: 2
        )

        if !persistedTracks.isEmpty, let playlist {
            print("🔗 Adding \(persistedTracks.count) tracks to playlist '\(playlist.name)'")
            await repository.addTracks(persistedTracks, to: playlist)
        }

        progressController.update(
            stage: .savingLibrary,
            progress: Self.progress(for: .savingLibrary, completed: 2, total: 2),
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

    private func finishCancelledImport(
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
    private func cleanupFailedImportResidue(reason: String) async -> TrackDirectoryCleanupReport {
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

    private func makeTrack(from payload: ImportedTrackPayload) -> Track {
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
            mediaLocator: payload.mediaLocator,
            artworkData: payload.artworkData,
            ttmlLyricText: payload.ttmlLyricText,
            lyricsText: payload.lyricsText,
            libraryRootSnapshot: paths.rootURL.path,
            ncmConversionAssociation: payload.ncmConversionAssociation
        )
    }
    
    private func prepareImportCandidates(
        files: [ResolvedImportFile],
        existingMatches: [String: ExistingTrackMatchSnapshot],
        metadataOverride: ImportMetadataOverride?,
        progressController: BatchImportProgressDialogController,
        cancellationToken: ImportCancellationToken
    ) async -> (unique: [ImportCandidate], duplicates: [DuplicatePairRow], duplicateCandidates: [ImportCandidate]) {
        guard !files.isEmpty else { return ([], [], []) }

        progressController.update(
            stage: .readingMetadata,
            progress: Self.progress(for: .readingMetadata, completed: 0, total: files.count),
            detail: "正在解析歌曲元数据并检查重复项",
            completedCount: 0,
            totalCount: files.count
        )

        var orderedResults = Array<CandidatePreparationResult?>(repeating: nil, count: files.count)
        var iterator = Array(files.enumerated()).makeIterator()
        let maxConcurrent = Self.metadataConcurrency(for: files.count)
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
                    progress: Self.progress(
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

        return (uniqueCandidates, duplicateRows, duplicateCandidates)
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
                    ncmOperationID: file.referencedNCMOutput?.operationID,
                    ncmAssociation: file.referencedNCMOutput?.association,
                    ncmLocator: file.referencedNCMOutput?.locator,
                    recoveryTrackID: file.referencedNCMOutput?.trackID
                ),
                duplicateRow: nil
            )
        }
        let preview: ImportPreview
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
                artworkData: normalizedCoverData
            )
        } else {
            let raw = await Self.extractMetadata(from: file.fileURL)
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
                        ncmOperationID: file.referencedNCMOutput?.operationID,
                        ncmAssociation: file.referencedNCMOutput?.association,
                        ncmLocator: file.referencedNCMOutput?.locator,
                        recoveryTrackID: file.referencedNCMOutput?.trackID
                    ),
                    duplicateRow: nil
                )
            }
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

        let effectivePreview = applyingMetadataOverride(metadataOverride, to: preview)
        let candidate = ImportCandidate(
            progressID: file.progressID,
            displayName: file.displayName,
            fileURL: file.fileURL,
            metadata: effectivePreview,
            discoveredFile: file.discoveredFile,
            trackID: nil,
            placement: nil,
            ncmOperationID: file.referencedNCMOutput?.operationID,
            ncmAssociation: file.referencedNCMOutput?.association,
            ncmLocator: file.referencedNCMOutput?.locator,
            recoveryTrackID: file.referencedNCMOutput?.trackID
        )
        let dedupKey = LibraryNormalization.normalizedDedupKey(
            title: effectivePreview.title,
            artist: effectivePreview.artist
        )

        guard let existingMatch = existingMatches[dedupKey], existingMatch.count > 0 else {
            return CandidatePreparationResult(index: index, candidate: candidate, duplicateRow: nil)
        }

        let duplicateRow = DuplicatePairRow(
            id: file.progressID,
            fileURL: file.fileURL,
            incoming: effectivePreview,
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

    nonisolated private static func applyingMetadataOverride(
        _ metadataOverride: ImportMetadataOverride?,
        to preview: ImportPreview
    ) -> ImportPreview {
        guard let metadataOverride, !metadataOverride.isEmpty else { return preview }

        let artistOverride = metadataOverride.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumOverride = metadataOverride.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveArtist: String
        let effectiveAlbumArtist: String?
        if let artistOverride, !artistOverride.isEmpty {
            effectiveArtist = artistOverride
            effectiveAlbumArtist = artistOverride
        } else {
            effectiveArtist = preview.artist
            effectiveAlbumArtist = preview.albumArtist
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
            artworkData: preview.artworkData
        )
    }

    // MARK: - Immediate Enrichment

    private func enrichImportedRecordsWithProgress(
        importedRecords: [ImportedTrackRecord],
        progressController: BatchImportProgressDialogController,
        cancellationToken: ImportCancellationToken
    ) async -> Bool {
        guard !importedRecords.isEmpty else { return false }

        progressController.update(
            stage: .enrichingMetadata,
            progress: Self.progress(
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
        let maxConcurrent = Self.enrichmentConcurrency(for: snapshots.count)
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
                group.addTask { [qqMusicCoverService, lyricsSearchCoordinator, amllDBService] in
                    await Self.performImmediateEnrichmentTask(
                        snapshot: snapshot,
                        cancellationToken: cancellationToken,
                        qqMusicCoverService: qqMusicCoverService,
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
                    progress: Self.progress(
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
                    group.addTask { [qqMusicCoverService, lyricsSearchCoordinator, amllDBService] in
                        await Self.performImmediateEnrichmentTask(
                            snapshot: snapshot,
                            cancellationToken: cancellationToken,
                            qqMusicCoverService: qqMusicCoverService,
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
        await repository.updateArtistEntry(result.value)
        return true
    }

    private func applyArtistArtworkData(_ data: Data, artist: String) async -> Bool {
        let canonical = LibraryNormalization.normalizeArtist(artist)
        guard canonical != LibraryNormalization.normalizeArtist(nil) else { return false }
        var entry = await latestArtistEntry(canonical: canonical, displayName: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateArtistEntry(entry)
        return true
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
        await repository.updateAlbumEntry(result.value)
        return true
    }

    private func applyAlbumArtworkData(_ data: Data, album: String, artist: String) async -> Bool {
        guard !LibraryNormalization.isUnknownAlbum(album) else { return false }
        var entry = await latestAlbumEntry(album: album, artist: artist)
        guard entry.artworkData == nil else { return false }
        entry.artworkData = data
        entry.artworkFileName = "artwork.png"
        entry.updatedAt = Date()
        await repository.updateAlbumEntry(entry)
        return true
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
                    artist: output.artist
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
            ? MetadataEnrichmentWorker.fetchArtistArtwork(artist: snapshot.artist)
            : nil
        async let albumArtworkOutcome: ImportAlbumArtworkOutcome? = snapshot.needsAlbumArtwork
            ? MetadataEnrichmentWorker.fetchAlbumArtwork(
                album: snapshot.album,
                artist: snapshot.artist
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

    nonisolated private static func pendingEnrichmentDetail(
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

    /// Extract metadata from audio file using AVAsset.
    /// Made nonisolated static to allow concurrent execution from TaskGroup.
    nonisolated private static func extractMetadata(from url: URL) async -> (
        title: String, artist: String, album: String, albumArtist: String?, duration: Double,
        lyrics: String?
    ) {
        let asset = AVURLAsset(url: url)

        var fields = ExtractedMetadataFields()
        var duration: Double = 0

        do {
            let durationTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(durationTime)
        } catch {
            Log.warning("[Import] duration load via AVURLAsset failed: \(error.localizedDescription)", category: .import)
        }

        // Fallback: some containers (notably bare ADTS `.aac` streams) don't
        // report a usable duration through AVURLAsset. Ask Core Audio directly
        // before giving up, so we never persist a 0-second track for a file
        // that is actually decodable.
        if !(duration > 0) || !duration.isFinite {
            if let audioFile = try? AVAudioFile(forReading: url) {
                let sampleRate = audioFile.processingFormat.sampleRate
                if sampleRate > 0 {
                    duration = Double(audioFile.length) / sampleRate
                }
            }
        }

        do {
            let common = try await asset.load(.commonMetadata)
            fields = await metadataFields(byApplying: common, to: fields)
        } catch {
            Log.warning("[Import] common metadata load failed: \(error.localizedDescription)", category: .import)
        }
        do {
            let full = try await asset.load(.metadata)
            fields = await metadataFields(byApplying: full, to: fields)
        } catch {
            Log.warning("[Import] full metadata load failed: \(error.localizedDescription)", category: .import)
        }

        // 4. Fallback: Try Spotlight Metadata (MDItem) if AVAsset failed
        // This handles cases where file has atypical tags or is only recognized by system indexers
        if fields.title == nil || fields.artist == nil {
            if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                // Title
                if fields.title == nil {
                    if let mdTitle = MDItemCopyAttribute(mdItem, kMDItemTitle) as? String {
                        fields.title = mdTitle
                    }
                }

                // Artist (Authors)
                if fields.artist == nil {
                    if let mdAuthors = MDItemCopyAttribute(mdItem, kMDItemAuthors) as? [String],
                        let firstAuthor = mdAuthors.first
                    {
                        fields.artist = firstAuthor
                    }
                }

                // Album
                if fields.album == nil {
                    if let mdAlbum = MDItemCopyAttribute(mdItem, kMDItemAlbum) as? String {
                        fields.album = mdAlbum
                    }
                }
            }
        }

        // Apply defaults
        let finalTitle = fields.title ?? url.deletingPathExtension().lastPathComponent
        let finalArtist = fields.artist ?? NSLocalizedString("library.unknown_artist", comment: "")
        let finalAlbum = fields.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalAlbumArtist = fields.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            finalTitle,
            finalArtist,
            finalAlbum,
            finalAlbumArtist?.isEmpty == true ? nil : finalAlbumArtist,
            duration,
            fields.lyrics
        )
    }

    /// Extract artwork from audio file.
    nonisolated static func extractArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)

        do {
            let common = try await asset.load(.commonMetadata)
            if let data = await normalizedArtworkData(in: common) {
                return data
            }
        } catch {
            Log.warning("[Import] common artwork metadata load failed: \(error.localizedDescription)", category: .import)
        }
        do {
            let full = try await asset.load(.metadata)
            if let data = await normalizedArtworkData(in: full) {
                return data
            }
        } catch {
            Log.warning("[Import] full artwork metadata load failed: \(error.localizedDescription)", category: .import)
        }

        return nil
    }

    nonisolated private struct ExtractedMetadataFields: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var lyrics: String?
    }

    nonisolated private static func metadataFields(
        byApplying items: [AVMetadataItem],
        to existingFields: ExtractedMetadataFields
    ) async -> ExtractedMetadataFields {
        var fields = existingFields

        for item in items {
            if let key = item.commonKey?.rawValue {
                switch key {
                case "title":
                    if fields.title == nil { fields.title = try? await item.load(.stringValue) }
                case "artist":
                    if fields.artist == nil { fields.artist = try? await item.load(.stringValue) }
                case "albumName":
                    if fields.album == nil { fields.album = try? await item.load(.stringValue) }
                case "albumArtist":
                    if fields.albumArtist == nil { fields.albumArtist = try? await item.load(.stringValue) }
                case "lyrics":
                    if fields.lyrics == nil { fields.lyrics = try? await item.load(.stringValue) }
                default:
                    break
                }
            }

            if let keyString = (item.key as? String)?.uppercased() {
                if fields.title == nil && keyString == "TITLE" {
                    fields.title = try? await item.load(.stringValue)
                }
                if fields.artist == nil && keyString == "ARTIST" {
                    fields.artist = try? await item.load(.stringValue)
                }
                if fields.album == nil && (keyString == "ALBUM" || keyString == "ALBUMTITLE") {
                    fields.album = try? await item.load(.stringValue)
                }
                if fields.albumArtist == nil
                    && (keyString == "ALBUMARTIST" || keyString == "ALBUM ARTIST"
                        || keyString == "ALBUM_ARTIST")
                {
                    fields.albumArtist = try? await item.load(.stringValue)
                }
                if fields.lyrics == nil
                    && (keyString == "LYRICS" || keyString == "UNSYNCEDLYRICS"
                        || keyString == "USLT")
                {
                    fields.lyrics = try? await item.load(.stringValue)
                }
            }

            if fields.lyrics == nil,
               let identifier = item.identifier?.rawValue,
               identifier == "id3/USLT" {
                fields.lyrics = try? await item.load(.stringValue)
            }
        }

        return fields
    }

    nonisolated private static func normalizedArtworkData(in items: [AVMetadataItem]) async -> Data? {
        for item in items {
            guard let key = item.commonKey?.rawValue, key == "artwork" else { continue }
            guard let data = try? await item.load(.dataValue) else { continue }
            if let normalizedData = ArtworkDataNormalizer.normalizedJPEGData(
                from: data,
                maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
            ) {
                return normalizedData
            }
            Log.warning("[Import] embedded artwork decode failed", category: .import)
        }

        return nil
    }


    /// Convert NCM files and return conversion results with metadata.
    private func convertNCMFiles(
        _ ncmFiles: [URL],
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken
    ) async -> [NCMConversionTaskOutput] {
        guard !ncmFiles.isEmpty else { return [] }

        progressController.update(
            stage: .convertingNCM,
            progress: Self.progress(for: .convertingNCM, completed: 0, total: ncmFiles.count),
            detail: "准备转换 \(ncmFiles.count) 个 NCM 文件",
            completedCount: 0,
            totalCount: ncmFiles.count
        )

        var results: [NCMConversionTaskOutput] = []
        var iterator = ncmFiles.makeIterator()
        let maxConcurrent = Self.ncmConcurrency(for: ncmFiles.count)
        var completedCount = 0
        var failureCount = 0
        let outputDirectoryURL = session.stagingDirectoryURL
            .appendingPathComponent("NCM", isDirectory: true)

        await withTaskGroup(of: NCMConversionTaskOutput.self) { group in
            for _ in 0..<min(maxConcurrent, ncmFiles.count) {
                guard let sourceURL = iterator.next() else { break }
                progressController.updateItem(
                    id: sourceURL.path,
                    stage: .ncmConversion,
                    status: .active,
                    detail: "正在解密并转换 NCM 文件"
                )
                group.addTask {
                    await Self.runNCMConversionTask(
                        sourceURL: sourceURL,
                        outputDirectoryURL: outputDirectoryURL,
                        cancellationToken: cancellationToken
                    )
                }
            }

            while let output = await group.next() {
                completedCount += 1
                results.append(output)
                let cancelled = await isImportCancellationRequested(progressController, cancellationToken)
                if output.result != nil {
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        title: output.result?.metadata.title,
                        artist: output.result?.metadata.artistName,
                        stage: .ncmConversion,
                        status: cancelled ? .cancelled : .success,
                        detail: cancelled ? "用户已取消" : "NCM 转换完成，等待导入"
                    )
                } else {
                    failureCount += 1
                    progressController.updateItem(
                        id: output.sourceURL.path,
                        stage: .ncmConversion,
                        status: cancelled ? .cancelled : .failed,
                        detail: cancelled ? "用户已取消" : "NCM 转换失败",
                        issueMessage: output.errorDescription
                    )
                }

                let detail =
                    failureCount == 0
                    ? "已转换 \(completedCount) / \(ncmFiles.count)"
                    : "已处理 \(completedCount) / \(ncmFiles.count)，失败 \(failureCount) 个"
                progressController.update(
                    stage: .convertingNCM,
                    progress: Self.progress(
                        for: .convertingNCM,
                        completed: completedCount,
                        total: ncmFiles.count
                    ),
                    detail: detail,
                    completedCount: completedCount,
                    totalCount: ncmFiles.count
                )

                if cancelled {
                    group.cancelAll()
                    continue
                }

                if let sourceURL = iterator.next() {
                    progressController.updateItem(
                        id: sourceURL.path,
                        stage: .ncmConversion,
                        status: .active,
                        detail: "正在解密并转换 NCM 文件"
                    )
                    group.addTask {
                        await Self.runNCMConversionTask(
                            sourceURL: sourceURL,
                            outputDirectoryURL: outputDirectoryURL,
                            cancellationToken: cancellationToken
                        )
                    }
                }
            }
        }

        return results
    }

    nonisolated private static func runNCMConversionTask(
        sourceURL: URL,
        outputDirectoryURL: URL,
        cancellationToken: ImportCancellationToken
    ) async -> NCMConversionTaskOutput {
        do {
            try await cancellationToken.checkCancellation()
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: true
            )
            let converter = NCMConverter()
            let result = try await converter.convert(
                from: sourceURL,
                outputDir: outputDirectoryURL,
                fetchCover: true,
                progressHandler: nil
            )
            try await cancellationToken.checkCancellation()
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: result,
                errorDescription: nil
            )
        } catch is CancellationError {
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: nil,
                errorDescription: "已取消"
            )
        } catch {
            Log.warning("NCM conversion failed for \(sourceURL.lastPathComponent): \(error)", category: .import)
            return NCMConversionTaskOutput(
                sourceURL: sourceURL,
                displayName: sourceURL.lastPathComponent,
                result: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    nonisolated private static func progress(
        for stage: BatchImportStage,
        completed: Int,
        total: Int
    ) -> Double {
        let range = stage.progressRange
        guard total > 0 else { return range.upperBound }
        let ratio = min(max(Double(completed) / Double(total), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * ratio
    }

    nonisolated private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    nonisolated private static func performImportTask(
        index: Int,
        candidate: ImportCandidate,
        stagingDirectoryURL: URL,
        cancellationToken: ImportCancellationToken
    ) async -> ImportTaskOutput {
        guard let trackId = candidate.trackID, let placement = candidate.placement else {
            return ImportTaskOutput(
                index: index,
                trackID: UUID(),
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
                errorDescription: "Import placement was not prepared"
            )
        }
        let importedAt = Date()
        await LibraryImportCoordinator.shared.beginTrack(trackId)
        defer {
            Task {
                await LibraryImportCoordinator.shared.endTrack(trackId)
            }
        }

        async let extractedArtworkTask: Data? = {
            if let preloadedArtworkData = candidate.metadata.artworkData {
                return ArtworkDataNormalizer.normalizedJPEGData(
                    from: preloadedArtworkData,
                    maxPixelSize: ArtworkDataNormalizer.importMaxPixelSize
                )
            }
            return await Self.extractArtwork(from: candidate.fileURL)
        }()
        async let embeddedLyricsTask = Self.prepareEmbeddedTTMLLyrics(candidate.metadata.lyrics)

        do {
            try await cancellationToken.checkCancellation()
            try Self.ensureAudioIsDecodable(
                candidate.fileURL,
                knownDuration: candidate.metadata.duration
            )
            try await cancellationToken.checkCancellation()

            let artworkData = await extractedArtworkTask
            let ttmlLyricText = await embeddedLyricsTask
            try await cancellationToken.checkCancellation()

            return ImportTaskOutput(
                index: index,
                trackID: trackId,
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
                    mediaLocator: {
                        switch placement {
                        case .managed(_, let relativePath): return .managed(libraryRelativePath: relativePath)
                        case .referenced(let locator): return .referenced(locator)
                        }
                    }(),
                    stagedAudioURL: {
                        if case .managed(let stagedURL, _) = placement { return stagedURL }
                        return nil
                    }(),
                    artworkData: artworkData,
                    ttmlLyricText: ttmlLyricText,
                    lyricsText: nil,
                    ncmConversionAssociation: candidate.ncmAssociation
                ),
                needsLyricsEnrichment: ttmlLyricText == nil,
                needsCoverEnrichment: artworkData == nil,
                needsTrackMetadataEnrichment: true,
                needsArtistMetadataEnrichment: true,
                needsAlbumMetadataEnrichment: true,
                needsArtistArtworkEnrichment: true,
                needsAlbumArtworkEnrichment: true,
                errorDescription: nil
            )
        } catch is CancellationError {
            let _ = await extractedArtworkTask
            let _ = await embeddedLyricsTask
            return ImportTaskOutput(
                index: index,
                trackID: trackId,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
                errorDescription: "已取消"
            )
        } catch {
            let _ = await extractedArtworkTask
            let _ = await embeddedLyricsTask
            return ImportTaskOutput(
                index: index,
                trackID: trackId,
                progressID: candidate.progressID,
                displayName: candidate.displayName,
                metadata: candidate.metadata,
                payload: nil,
                needsLyricsEnrichment: false,
                needsCoverEnrichment: false,
                needsTrackMetadataEnrichment: false,
                needsArtistMetadataEnrichment: false,
                needsAlbumMetadataEnrichment: false,
                needsArtistArtworkEnrichment: false,
                needsAlbumArtworkEnrichment: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    nonisolated private static func prepareEmbeddedTTMLLyrics(_ embeddedLyrics: String?) async -> String? {
        guard let embeddedLyrics, !embeddedLyrics.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }
        if let ttml = LyricsFormatSupport.normalizedTTMLText(embeddedLyrics) {
            return ttml
        }
        guard LyricsFormatSupport.looksLikeLRC(embeddedLyrics) else {
            Log.warning("[Import] embedded lyrics skipped: unsupported non-TTML/non-LRC format", category: .lyrics)
            return nil
        }
        do {
            let converted = try await TTMLConverter.shared.convertToTTML(
                rawLyrics: embeddedLyrics,
                stripMetadata: true
            )
            guard let ttml = LyricsFormatSupport.normalizedTTMLText(converted) else {
                Log.warning("[Import] embedded lyrics conversion produced invalid TTML", category: .lyrics)
                return nil
            }
            return ttml
        } catch {
            Log.warning("[Import] embedded lyrics conversion failed: \(error.localizedDescription)", category: .lyrics)
            return nil
        }
    }


    /// Final safety net before copying a file into the library: if we never
    /// determined a positive duration, confirm Core Audio can at least open the
    /// file. This turns "silently imported a 0-second broken track" into a
    /// clear, per-file import failure. Files with a known duration short-circuit
    /// (the common case), so valid audio is never rejected here.
    nonisolated private static func ensureAudioIsDecodable(
        _ url: URL,
        knownDuration: Double
    ) throws {
        if knownDuration > 0, knownDuration.isFinite { return }
        do {
            _ = try AVAudioFile(forReading: url)
        } catch {
            Log.warning(
                "[Import] rejected undecodable file '\(url.lastPathComponent)': \(error.localizedDescription)",
                category: .import
            )
            throw AudioImportError.undecodable(fileName: url.lastPathComponent)
        }
    }


    nonisolated private static func metadataConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.metadataReadConcurrency(for: count)
    }

    nonisolated private static func ncmConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.ncmConversionConcurrency(for: count)
    }

    nonisolated private static func importConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.audioPreparationConcurrency(for: count)
    }

    nonisolated private static func enrichmentConcurrency(for count: Int) -> Int {
        ImportConcurrencyLimiter.networkEnrichmentConcurrency(for: count)
    }

    @MainActor
    private func presentDuplicateSelectionDialog(_ duplicateRows: [DuplicatePairRow])
        -> [DuplicatePairRow]?
    {
        return DuplicateImportDialogPresenter.present(
            rows: duplicateRows
        )
    }
}

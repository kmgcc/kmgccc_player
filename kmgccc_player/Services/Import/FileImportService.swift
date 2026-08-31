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

nonisolated enum ImportEffectCommitError: LocalizedError, Sendable {
    case missingReusedTrack(UUID)

    var errorDescription: String? {
        switch self {
        case .missingReusedTrack(let trackID):
            return "复用歌曲在提交前已不存在（\(trackID.uuidString)）"
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
    let artistCredits: [TrackCredit]?

    init(
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        duration: Double,
        lyrics: String?,
        artworkData: Data?,
        artistCredits: [TrackCredit]? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.lyrics = lyrics
        self.artworkData = artworkData
        self.artistCredits = artistCredits
    }
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
///
/// §16: thin orchestrator. Decisions live in `ImportPlanner`, persistence in
/// `ImportCommitter`; this type owns the slot gate, public API, progress
/// dialog lifecycle, duplicate-dialog presentation and counters.
@MainActor
final class FileImportService: FileImportServiceProtocol {
    /// Queue entry for a waiting import slot. Only ever touched on the main
    /// actor; task cancellation reaches it through an ID lookup after hopping
    /// back from the nonisolated cancellation handler.
    private final class ImportSlotWaiter {
        let id = UUID()
        var continuation: CheckedContinuation<Void, Never>?
        var isCancelled = false
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
    private let operationCoordinator: LibraryOperationCoordinator
    private let mutationCoordinator: LibraryMutationCoordinator?
    private let referencedNCMConversionService: ReferencedNCMConversionService?
    private let ignoredItemsStore: IgnoredReferencedItemsStore?
    private let qqMusicCoverService: QQMusicCoverService
    private let artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator
    private let lyricsSearchCoordinator: LyricsSearchCoordinator
    private let amllDBService: AMLLDBService
    private let uiPresentationObserver: (() -> Void)?
    private let libraryID: UUID
    private let sessionGeneration: UInt64
    private let immediateEnrichmentEngine: ImportImmediateEnrichmentEngine
    private let ncmConversionPipeline: ManagedNCMConversionPipeline
    private let planner: ImportPlanner
    private let committer: ImportCommitter
    /// Main-actor queue state. The queue deliberately does not use
    /// `Task<[Track], Never>`: SwiftData `Track` objects are main-actor
    /// persistent models and cannot cross a task's Sendable result boundary.
    private var importSlotIsBusy = false
    private var importSlotWaiters: [ImportSlotWaiter] = []
    private var importDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var acceptsImports = true
    private var lastImportFailures: [ImportInputFailure] = []
    private var lastImportPossibleDuplicateCount = 0
    private var lastImportPendingNCMCount = 0
    private var lastImportAlreadyInPlaylistCount = 0

    init(
        repository: LibraryRepositoryProtocol,
        libraryService: LocalLibraryService,
        importEnrichmentService: ImportEnrichmentService,
        storageBackend: any LibraryStorageBackend,
        operationCoordinator: LibraryOperationCoordinator,
        mutationCoordinator: LibraryMutationCoordinator? = nil,
        referencedNCMConversionService: ReferencedNCMConversionService? = nil,
        ignoredItemsStore: IgnoredReferencedItemsStore? = nil,
        qqMusicCoverService: QQMusicCoverService,
        artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator,
        lyricsSearchCoordinator: LyricsSearchCoordinator,
        amllDBService: AMLLDBService,
        uiPresentationObserver: (() -> Void)? = nil,
        libraryID: UUID = .zero,
        sessionGeneration: UInt64 = 0
    ) {
        self.repository = repository
        self.libraryService = libraryService
        self.paths = libraryService.paths
        self.importEnrichmentService = importEnrichmentService
        self.storageBackend = storageBackend
        self.operationCoordinator = operationCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.referencedNCMConversionService = referencedNCMConversionService
        self.ignoredItemsStore = ignoredItemsStore
        self.qqMusicCoverService = qqMusicCoverService
        self.artistArtworkProviderCoordinator = artistArtworkProviderCoordinator
        self.lyricsSearchCoordinator = lyricsSearchCoordinator
        self.amllDBService = amllDBService
        self.uiPresentationObserver = uiPresentationObserver
        self.libraryID = libraryID
        self.sessionGeneration = sessionGeneration
        self.immediateEnrichmentEngine = ImportImmediateEnrichmentEngine(
            repository: repository,
            mutationCoordinator: mutationCoordinator,
            qqMusicCoverService: qqMusicCoverService,
            artistArtworkProviderCoordinator: artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: lyricsSearchCoordinator,
            amllDBService: amllDBService
        )
        self.ncmConversionPipeline = ManagedNCMConversionPipeline(
            operationCoordinator: operationCoordinator
        )
        self.planner = ImportPlanner(
            repository: repository,
            storageBackend: storageBackend,
            paths: libraryService.paths,
            referencedNCMConversionService: referencedNCMConversionService,
            operationCoordinator: operationCoordinator,
            ncmConversionPipeline: self.ncmConversionPipeline
        )
        self.committer = ImportCommitter(
            repository: repository,
            libraryService: libraryService,
            storageBackend: storageBackend,
            paths: libraryService.paths,
            importEnrichmentService: importEnrichmentService,
            referencedNCMConversionService: referencedNCMConversionService
        )
        Log.debug("FileImportService initialized", category: .import)
    }

    // MARK: - Public Methods

    func cancelEnrichment(for trackIDs: Set<UUID>) async {
        await importEnrichmentService.cancelEnrichment(for: trackIDs)
    }

    /// Stops accepting new imports and waits for the service-owned import
    /// queue. Window toolbar/drop imports do not always pass through the
    /// session operation wrapper, so the service must expose its own close
    /// boundary as well.
    func quiesce() async {
        acceptsImports = false
        guard importSlotIsBusy || !importSlotWaiters.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            importDrainWaiters.append(continuation)
        }
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

    @discardableResult
    func importSelectedURLs(
        _ selectedURLs: [URL],
        context: LibraryImportContext
    ) async -> LibraryImportResult {
        guard context.libraryID == libraryID || libraryID == .zero,
              context.sessionGeneration == sessionGeneration || sessionGeneration == 0 else {
            Log.warning(
                "[Import] rejected stale context library=\(context.libraryID) generation=\(context.sessionGeneration)",
                category: .import
            )
            return .staleContext
        }
        guard !selectedURLs.isEmpty else {
            return LibraryImportResult(
                importedTrackCount: 0,
                reusedTrackCount: 0,
                playlistMembershipAdditions: 0,
                sourceBindingCount: 0,
                failures: [],
                wasRejectedAsStale: false
            )
        }

        let playlist: Playlist?
        switch context.destination {
        case .libraryOnly:
            playlist = nil
        case .playlist(let playlistID):
            playlist = (await repository.fetchPlaylists()).first { $0.id == playlistID }
            guard playlist != nil else {
                return LibraryImportResult(
                    importedTrackCount: 0,
                    reusedTrackCount: 0,
                    playlistMembershipAdditions: 0,
                    sourceBindingCount: 0,
                    failures: [
                        .init(
                            url: selectedURLs[0],
                            message: "目标播放列表已不存在，导入已取消"
                        )
                    ],
                    wasRejectedAsStale: false
                )
            }
        }

        let beforeTrackIDs = Set((await repository.fetchTracks(in: nil)).map(\.id))
        let beforePlaylistCount = playlist?.trackCount ?? 0
        let tracks = await importURLs(
            selectedURLs,
            to: playlist,
            metadataOverride: context.metadataOverride,
            presentation: .interactive,
            isManualSelection: true,
            origin: context.origin
        )
        let newTrackCount = tracks.filter { !beforeTrackIDs.contains($0.id) }.count
        let sourceBindingCount: Int
        if case .playlist = context.destination {
            sourceBindingCount = Set(tracks.flatMap { track -> [UUID] in
                guard case let .referenced(locator) = track.mediaLocator else { return [] }
                return locator.allSourceMemberships.map(\.sourceID)
            }).count
        } else {
            sourceBindingCount = 0
        }
        let playlistMembershipAdditions = max(0, (playlist?.trackCount ?? beforePlaylistCount) - beforePlaylistCount)
        return LibraryImportResult(
            importedTrackCount: newTrackCount,
            reusedTrackCount: max(0, tracks.count - newTrackCount),
            playlistMembershipAdditions: playlistMembershipAdditions,
            sourceBindingCount: sourceBindingCount,
            failures: lastImportFailures,
            wasRejectedAsStale: false,
            possibleDuplicatesCount: lastImportPossibleDuplicateCount,
            pendingNCMCount: lastImportPendingNCMCount,
            alreadyInPlaylistCount: lastImportAlreadyInPlaylistCount
        )
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
            presentation: .interactive,
            isManualSelection: true,
            origin: .playlistDrop
        ).count
    }

    /// Production entry used by referenced-source reconciliation. It uses the same
    /// metadata, sidecar, and visibility pipeline without presenting AppKit UI.
    func importAutomatically(_ urls: [URL]) async -> [Track] {
        await importURLs(
            urls,
            to: nil,
            metadataOverride: nil,
            presentation: .automatic,
            isManualSelection: false,
            origin: .sourceMonitor
        )
    }

    /// Setup entry. The caller retains `selection` across this entire call so the
    /// backend can sign durable folder/file bookmarks before picker access expires.
    func importInitialSelection(_ selection: LibraryInitialImportSelection) async -> LibraryInitialImportResult {
        let imported = await importURLs(
            selection.urls,
            to: nil,
            metadataOverride: nil,
            presentation: .automatic,
            isManualSelection: true,
            origin: .setup
        )
        let plan = storageBackend.lastPreparedInputPlan
        var failures = plan?.failures ?? []
        failures.append(contentsOf: lastImportFailures)
        if let plan, plan.files.isEmpty, !selection.urls.isEmpty, plan.failures.isEmpty {
            failures.append(contentsOf: selection.urls.map {
                ImportInputFailure(url: $0, message: "No supported audio found")
            })
        }
        var seenFailurePaths = Set<String>()
        failures = failures.filter {
            seenFailurePaths.insert(LibraryImportSourceEntry.canonicalPath($0.url)).inserted
        }
        let sources = plan?.directorySources.map { prepared in
            LibraryInitialImportSource(
                id: prepared.source.id,
                mode: prepared.source.mode,
                path: LibraryImportSourceEntry.canonicalPath(prepared.rootURL),
                displayName: prepared.source.displayName
            )
        } ?? []
        var importedTrackIDsByPath: [String: UUID] = [:]
        for track in imported {
            guard !track.originalFilePath.isEmpty else { continue }
            importedTrackIDsByPath[LibraryImportSourceEntry.canonicalPath(
                URL(fileURLWithPath: track.originalFilePath)
            )] = track.id
        }
        return LibraryInitialImportResult(
            requested: selection.urls.count,
            planned: plan?.files.count ?? 0,
            imported: imported.count,
            failures: failures,
            sourceIDs: sources.map(\.id),
            sources: sources,
            importedTrackIDsByPath: importedTrackIDsByPath
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
        presentation: ImportPresentation,
        isManualSelection: Bool,
        origin: LibraryImportOrigin
    ) async -> [Track] {
        guard acceptsImports else {
            Log.warning("[Import] request rejected because the library session is quiescing", category: .import)
            return []
        }
        let tracks = await enqueueImport { [weak self] in
            guard let self else { return [] }
            return await self.performImport(
                selectedURLs,
                to: playlist,
                metadataOverride: metadataOverride,
                presentation: presentation,
                isManualSelection: isManualSelection,
                origin: origin
            )
        }
        if storageBackend.mode == .referenced {
            // Single-file sources are created up front in prepareInputs;
            // files that did not survive the import pipeline (for example
            // corrupt audio) must not leave a source behind.
            let importedURLs = Set(tracks.compactMap { track -> String? in
                if case let .referenced(locator) = track.mediaLocator {
                    return URL(fileURLWithPath: locator.lastKnownPath)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                }
                return nil
            })
            // NCM conversion outputs keep the `.ncm` input's source
            // membership, so the file source must survive pruning even
            // though the imported path is the converted product.
            let importedSourceIDs = Set(tracks.flatMap { track -> [UUID] in
                guard case let .referenced(locator) = track.mediaLocator else { return [] }
                return locator.allSourceMemberships.map(\.sourceID)
            })
            await storageBackend.pruneUnimportedFileSources(
                importedURLs: importedURLs,
                importedSourceIDs: importedSourceIDs
            )
        }
        return tracks
    }

    /// Serializes imports per session. A second request waits for the first
    /// transaction instead of being silently dropped by an `inProgress` flag.
    /// Returns `false` when the waiting task was cancelled, so the queued
    /// request is rejected instead of leaking its continuation.
    private func enqueueImport(
        _ work: @escaping @MainActor () async -> [Track]
    ) async -> [Track] {
        guard await acquireImportSlot() else {
            Log.info("[Import] request cancelled while waiting for the import slot", category: .import)
            return []
        }
        defer { releaseImportSlot() }
        return await work()
    }

    private func acquireImportSlot() async -> Bool {
        guard importSlotIsBusy else {
            importSlotIsBusy = true
            return true
        }

        let waiter = ImportSlotWaiter()
        let waiterID = waiter.id
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    // Cancelled before the waiter entered the queue.
                    waiter.isCancelled = true
                    continuation.resume()
                    return
                }
                waiter.continuation = continuation
                importSlotWaiters.append(waiter)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelImportSlotWaiter(matching: waiterID)
            }
        }
        return !waiter.isCancelled
    }

    private func cancelImportSlotWaiter(matching id: UUID) {
        guard let index = importSlotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = importSlotWaiters.remove(at: index)
        waiter.isCancelled = true
        waiter.continuation?.resume()
        waiter.continuation = nil
    }

    private func releaseImportSlot() {
        if !importSlotWaiters.isEmpty {
            let next = importSlotWaiters.removeFirst()
            next.continuation?.resume()
            return
        }

        importSlotIsBusy = false
        let drainWaiters = importDrainWaiters
        importDrainWaiters.removeAll()
        drainWaiters.forEach { $0.resume() }
    }

    private func performImport(
        _ selectedURLs: [URL],
        to playlist: Playlist?,
        metadataOverride: ImportMetadataOverride?,
        presentation: ImportPresentation,
        isManualSelection: Bool,
        origin: LibraryImportOrigin
    ) async -> [Track] {
        lastImportFailures = []
        lastImportPossibleDuplicateCount = 0
        lastImportPendingNCMCount = 0
        lastImportAlreadyInPlaylistCount = 0
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
            "import URLs destination=\(playlist?.id.uuidString ?? "library") origin=\(origin.rawValue) count=\(selectedURLs.count) override=\(String(describing: metadataOverride))",
            category: .import
        )

        await LibraryImportCoordinator.shared.beginBatch(reason: "fileImport")
        defer {
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
        await prepareManualRetryIfNeeded(
            inputPlan: inputPlan,
            isManualSelection: isManualSelection
        )
        operationCoordinator.recordCheckpoint("输入规划完成")

        let libraryTracks = await repository.fetchTracks(in: nil)
        let beforePlaylistTrackIDs = Set((await repository.fetchTracks(in: playlist)).map(\.id))

        // §16 planning phase 1: input interpretation + identity reuse.
        let interpretation = await planner.interpretInputs(
            inputPlan: inputPlan,
            libraryTracks: libraryTracks,
            isManualSelection: isManualSelection,
            session: importSession
        )
        var reusedTracks = interpretation.reusedTracks
        var reusedTrackIDs = interpretation.reusedTrackIDs
        lastImportPendingNCMCount = interpretation.eligibleNCMFiles.count
        let discoveredFileCount = interpretation.filesToImport.count + interpretation.eligibleNCMFiles.count
        progressController.update(
            stage: .scanning,
            progress: Self.progress(for: .scanning, completed: discoveredFileCount, total: max(discoveredFileCount, 1)),
            detail: discoveredFileCount > 0 ? "已找到 \(discoveredFileCount) 个可导入文件" : "未找到支持的音频文件",
            completedCount: discoveredFileCount,
            totalCount: discoveredFileCount
        )

        guard discoveredFileCount > 0 else {
            Log.info("No supported audio files found in selection", category: .import)
            if await isImportCancellationRequested(progressController, cancellationToken) {
                importSession.cleanupStaging()
                return []
            }
            do {
                try await commitImportEffects(
                    tracks: reusedTracks,
                    referencedReuseLocators: interpretation.referencedReuseLocators,
                    sourceIDs: interpretation.playlistSourceIDs,
                    to: playlist
                )
            } catch {
                lastImportFailures.append(.init(
                    url: selectedURLs[0],
                    message: "无法保存播放列表导入结果：\(error.localizedDescription)"
                ))
                importSession.cleanupStaging()
                return []
            }
            importSession.cleanupStaging()
            lastImportAlreadyInPlaylistCount = playlist.map { _ in
                reusedTracks.filter { beforePlaylistTrackIDs.contains($0.id) }.count
            } ?? 0
            crashBreadcrumbResult = "completed"
            crashBreadcrumbImportedCount = reusedTracks.count
            return reusedTracks
        }

        if await isImportCancellationRequested(progressController, cancellationToken) {
            return await committer.finishCancelledImport(
                session: importSession,
                importedRecords: [],
                createdTrackIDs: [],
                to: playlist,
                progressController: progressController,
                totalCount: discoveredFileCount
            )
        }

        let discoveredItems = (interpretation.filesToImport + interpretation.eligibleNCMFiles).map {
            BatchImportProgressItemSeed(id: $0.url.path, fileName: $0.url.lastPathComponent)
        }
        progressController.setItems(discoveredItems)
        for file in interpretation.filesToImport {
            progressController.updateItem(
                id: file.url.path,
                stage: .metadata,
                status: .waiting,
                detail: "等待解析歌曲信息"
            )
        }
        for sourceFile in interpretation.eligibleNCMFiles {
            let sourceURL = sourceFile.url
            progressController.updateItem(
                id: sourceURL.path,
                stage: .ncmConversion,
                status: .waiting,
                detail: "等待转换 NCM 文件"
            )
        }

        // §16 planning phase 2: NCM conversion dispatch + coalescing.
        let conversion = await planner.resolveConversions(
            filesToImport: interpretation.filesToImport,
            eligibleNCMFiles: interpretation.eligibleNCMFiles,
            reusedTracks: reusedTracks,
            reusedTrackIDs: reusedTrackIDs,
            session: importSession,
            cancellationToken: cancellationToken,
            progressController: progressController
        )
        let resolvedFiles = conversion.resolvedFiles
        reusedTracks = conversion.reusedTracks
        reusedTrackIDs = conversion.reusedTrackIDs
        lastImportFailures.append(contentsOf: conversion.failures)
        if conversion.cancelledAfterManagedConversion {
            return await committer.finishCancelledImport(
                session: importSession,
                importedRecords: [],
                createdTrackIDs: [],
                to: playlist,
                progressController: progressController,
                totalCount: discoveredFileCount
            )
        }

        Log.debug("Found \(resolvedFiles.count) audio files to import", category: .import)

        // §16 planning phase 3: dedup snapshots + candidate preparation.
        let preparedCandidates = await planner.prepareCandidates(
            resolvedFiles: resolvedFiles,
            libraryTracks: libraryTracks,
            metadataOverride: metadataOverride,
            cancellationToken: cancellationToken,
            progressController: progressController
        )
        let uniqueCandidates = preparedCandidates.unique
        let duplicateRows = preparedCandidates.duplicates
        lastImportPossibleDuplicateCount = duplicateRows.count

        if await isImportCancellationRequested(progressController, cancellationToken) {
            return await committer.finishCancelledImport(
                session: importSession,
                importedRecords: [],
                createdTrackIDs: [],
                to: playlist,
                progressController: progressController,
                totalCount: discoveredFileCount
            )
        }

        // Duplicate policy stays UI-owned: the planner only produced the
        // decision inputs above.
        var selectedDuplicates: [ImportCandidate] = []
        var policyDecision: ImportExecutionPlan.DuplicatePolicyDecision =
            duplicateRows.isEmpty ? .none : .automaticImportAllAsNew
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
                policyDecision = .userSelected
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
                return await committer.finishCancelledImport(
                    session: importSession,
                    importedRecords: [],
                    createdTrackIDs: [],
                    to: playlist,
                    progressController: progressController,
                    totalCount: discoveredFileCount
                )
            }
        }

        if presentation == .automatic, !duplicateRows.isEmpty {
            // Metadata similarity may only produce possible-duplicate
            // suggestions (plan rule 11.5). Automatic runs have no user to
            // confirm a merge, so similarity-only matches are imported as new
            // tracks instead of being silently reused. Genuine same-file
            // re-imports were already resolved by the physical fingerprint
            // lookup above.
            selectedDuplicates = preparedCandidates.duplicateCandidates
            for candidate in selectedDuplicates {
                progressController.updateItem(
                    id: candidate.progressID,
                    title: candidate.metadata.title,
                    artist: candidate.metadata.artist,
                    stage: .duplicateCheck,
                    status: .warning,
                    detail: "疑似重复歌曲，未自动合并，将作为新歌曲导入"
                )
            }
        }

        // Logic Verification Logs
        Log.debug("--------------------------------------------------", category: .import)
        Log.debug("Import Logic Verification:", category: .import)
        Log.debug("   Unique Candidates : \(uniqueCandidates.count)", category: .import)
        Log.debug("   Duplicate Rows    : \(duplicateRows.count)", category: .import)
        Log.debug("   Selected Dups     : \(selectedDuplicates.count)", category: .import)

        operationCoordinator.recordCheckpoint("重复判定完成")

        // §16 planning phase 4: placements bound to track IDs.
        let placementResolution = await planner.resolvePlacements(
            uniqueCandidates: uniqueCandidates,
            selectedDuplicates: selectedDuplicates,
            session: importSession,
            progressController: progressController
        )
        lastImportFailures.append(contentsOf: placementResolution.failures)
        let finalCandidates = placementResolution.placements
        Log.debug("   -> FINAL Candidates: \(finalCandidates.count)", category: .import)
        Log.debug("--------------------------------------------------", category: .import)

        let executionPlan = ImportExecutionPlan(
            reusedTracks: reusedTracks,
            reusedTrackIDs: reusedTrackIDs,
            conversions: resolvedFiles,
            uniqueCandidates: uniqueCandidates,
            duplicateRows: duplicateRows,
            duplicateCandidates: preparedCandidates.duplicateCandidates,
            policyDecision: policyDecision,
            placements: finalCandidates
        )

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
        let importBatch = await committer.executeBatch(
            executionPlan.placements,
            progressController: progressController,
            enrichmentMode: enrichmentMode,
            session: importSession,
            cancellationToken: cancellationToken
        )
        lastImportFailures.append(contentsOf: importBatch.failures)
        let importedRecords = importBatch.records
        operationCoordinator.recordCheckpoint("提交导入完成")

        let importCancellationRequested = await isImportCancellationRequested(progressController, cancellationToken)
        if importBatch.cancelled || importCancellationRequested {
            return await committer.finishCancelledImport(
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
            if reusedTracks.isEmpty, !finalCandidates.isEmpty {
                importSession.cleanupStaging()
                _ = await committer.cleanupFailedImportResidue(reason: "importNoSuccessfulTracks")
                return []
            }
            do {
                try await commitImportEffects(
                    tracks: reusedTracks,
                    referencedReuseLocators: interpretation.referencedReuseLocators,
                    sourceIDs: interpretation.playlistSourceIDs,
                    to: playlist
                )
            } catch {
                lastImportFailures.append(.init(
                    url: selectedURLs[0],
                    message: "无法保存播放列表导入结果：\(error.localizedDescription)"
                ))
                importSession.cleanupStaging()
                _ = await committer.cleanupFailedImportResidue(reason: "importPlaylistCommitFailed")
                return []
            }
            importSession.cleanupStaging()
            _ = await committer.cleanupFailedImportResidue(reason: "importNoSuccessfulTracks")
            lastImportAlreadyInPlaylistCount = playlist.map { _ in
                reusedTracks.filter { beforePlaylistTrackIDs.contains($0.id) }.count
            } ?? 0
            crashBreadcrumbResult = "completed"
            crashBreadcrumbImportedCount = reusedTracks.count
            return reusedTracks
        }

        let importedTracks = importedRecords.map(\.track)
        var persistedTracks: [Track] = []
        var deferredEnrichmentTracks: [Track] = []

        switch enrichmentMode {
        case .immediate:
            let recordsNeedingEnrichment = importedRecords.filter(\.needsAnyEnrichment)
            if !recordsNeedingEnrichment.isEmpty {
                let enrichmentCancelled = await immediateEnrichmentEngine.enrichImportedRecords(
                    importedRecords: recordsNeedingEnrichment,
                    progressController: progressController,
                    cancellationToken: cancellationToken
                )
                let enrichmentCancellationRequested = await isImportCancellationRequested(progressController, cancellationToken)
                if enrichmentCancelled || enrichmentCancellationRequested {
                    return await committer.finishCancelledImport(
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

            guard let savedTracks = await saveImportedTracksUnderMutation(
                importedTracks,
                progressController: progressController,
                session: importSession,
                cancellationToken: cancellationToken,
                failureURL: selectedURLs[0]
            ) else {
                return await committer.finishCancelledImport(
                    session: importSession,
                    importedRecords: importedRecords,
                    createdTrackIDs: importBatch.createdTrackIDs,
                    to: playlist,
                    progressController: progressController,
                    totalCount: finalCandidates.count
                )
            }
            persistedTracks = savedTracks
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

            guard let savedTracks = await saveImportedTracksUnderMutation(
                importedTracks,
                progressController: progressController,
                session: importSession,
                cancellationToken: cancellationToken,
                failureURL: selectedURLs[0]
            ) else {
                return await committer.finishCancelledImport(
                    session: importSession,
                    importedRecords: importedRecords,
                    createdTrackIDs: importBatch.createdTrackIDs,
                    to: playlist,
                    progressController: progressController,
                    totalCount: finalCandidates.count
                )
            }
            persistedTracks = savedTracks
            let persistedIDs = Set(savedTracks.map(\.id))
            deferredEnrichmentTracks = recordsNeedingEnrichment
                .map(\.track)
                .filter { persistedIDs.contains($0.id) }
        }

        if await isImportCancellationRequested(progressController, cancellationToken) {
            return await committer.finishCancelledImport(
                session: importSession,
                importedRecords: importedRecords,
                createdTrackIDs: importBatch.createdTrackIDs,
                to: playlist,
                progressController: progressController,
                totalCount: finalCandidates.count
            )
        }

        do {
            try await commitImportEffects(
                tracks: persistedTracks + reusedTracks,
                referencedReuseLocators: interpretation.referencedReuseLocators,
                sourceIDs: interpretation.playlistSourceIDs,
                to: playlist
            )
        } catch {
            lastImportFailures.append(.init(
                url: selectedURLs[0],
                message: "无法保存播放列表导入结果：\(error.localizedDescription)"
            ))
            return await committer.finishCancelledImport(
                session: importSession,
                importedRecords: importedRecords,
                createdTrackIDs: importBatch.createdTrackIDs,
                to: playlist,
                progressController: progressController,
                totalCount: finalCandidates.count
            )
        }

        if !deferredEnrichmentTracks.isEmpty {
            await importEnrichmentService.enqueueTracks(deferredEnrichmentTracks)
        }

        operationCoordinator.recordCheckpoint("信息补全阶段完成")

        _ = await committer.cleanupFailedImportResidue(reason: "importCompleted")
        importSession.cleanupStaging()

        let persistedTrackIDs = Set(persistedTracks.map(\.id))
        for record in importedRecords where persistedTrackIDs.contains(record.track.id) {
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
            detail: playlist.map { "已成功导入 \(persistedTracks.count) 首歌曲到“\($0.name)”" }
                ?? "已成功导入 \(persistedTracks.count) 首歌曲",
            completedCount: persistedTracks.count,
            totalCount: finalCandidates.count
        )
        try? await Task.sleep(nanoseconds: 500_000_000)

        lastImportAlreadyInPlaylistCount = playlist.map { destination in
            (persistedTracks + reusedTracks).filter {
                beforePlaylistTrackIDs.contains($0.id)
            }.count
        } ?? 0
        print("✅ Import complete: \(persistedTracks.count) imported")
        crashBreadcrumbResult = "completed"
        crashBreadcrumbImportedCount = persistedTracks.count + reusedTracks.count
        return persistedTracks + reusedTracks
    }

    /// Manual selection is an explicit request to retry items previously
    /// ignored by automatic source scans. Keep that durable state transition
    /// in the import orchestrator (the preflight boundary), rather than
    /// hiding a write inside the otherwise read-only planner.
    private func prepareManualRetryIfNeeded(
        inputPlan: ImportInputPlan,
        isManualSelection: Bool
    ) async {
        guard isManualSelection, let ignoredItemsStore else { return }
        let fingerprints = inputPlan.files.compactMap(\.fingerprint)
        do {
            try await ignoredItemsStore.remove(matching: fingerprints)
            if let referencedNCMConversionService {
                for file in inputPlan.files where file.url.pathExtension.lowercased() == "ncm" {
                    let related = try await referencedNCMConversionService.allowManualRetry(file)
                    try await ignoredItemsStore.remove(matching: related)
                }
            }
        } catch {
            Log.error(
                "[Import] failed to clear ignored item before manual import: \(error.localizedDescription)",
                category: .import
            )
        }
    }

    /// Playlist membership and referenced-source bindings are one final
    /// commit point. Nothing in planning calls this method, so duplicate
    /// dialogs, cancellation and failed imports leave the playlist untouched.
    private func commitImportEffects(
        tracks: [Track],
        referencedReuseLocators: [UUID: ReferencedFileLocator],
        sourceIDs: Set<UUID>,
        to playlist: Playlist?
    ) async throws {
        let targetIDs = Array(Set(tracks.map(\.id) + Array(referencedReuseLocators.keys)))
            .sorted { $0.uuidString < $1.uuidString }
            .map(\.uuidString)
        if let mutationCoordinator {
            return try await mutationCoordinator.run(
                kind: .importCommit,
                targetIDs: targetIDs
            ) {
                try await self.commitImportEffectsUncoordinated(
                    tracks: tracks,
                    referencedReuseLocators: referencedReuseLocators,
                    sourceIDs: sourceIDs,
                    to: playlist
                )
            }
        }
        try await commitImportEffectsUncoordinated(
            tracks: tracks,
            referencedReuseLocators: referencedReuseLocators,
            sourceIDs: sourceIDs,
            to: playlist
        )
    }

    private func commitImportEffectsUncoordinated(
        tracks: [Track],
        referencedReuseLocators: [UUID: ReferencedFileLocator],
        sourceIDs: Set<UUID>,
        to playlist: Playlist?
    ) async throws {
        var originalLocators: [(track: Track, locator: TrackMediaLocator)] = []
        do {
            // Source descriptors created during prepareInputs are provisional;
            // persist them only once the import reaches its final commit.
            try await storageBackend.commitPreparedSources()
            for trackID in referencedReuseLocators.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let incoming = referencedReuseLocators[trackID],
                      let track = await repository.fetchTracks(ids: [trackID]).first else {
                    throw ImportEffectCommitError.missingReusedTrack(trackID)
                }
                originalLocators.append((track, track.mediaLocator))
                try await repository.mergeReferencedLocator(incoming, into: track)
            }

            guard let playlist else { return }
            var seenTrackIDs = Set<UUID>()
            let uniqueTracks = tracks.filter { seenTrackIDs.insert($0.id).inserted }
            try await storageBackend.commitPlaylistImportSourceEffects(
                tracks: uniqueTracks,
                sourceIDs: sourceIDs,
                playlistID: playlist.id,
                commitPlaylist: {
                    guard !uniqueTracks.isEmpty else { return }
                    try await self.repository.addTracks(uniqueTracks, to: playlist)
                }
            )
        } catch {
            await storageBackend.rollbackPreparedSources()
            for original in originalLocators.reversed() {
                original.track.mediaLocator = original.locator
                await repository.persistTrackMetaOnly(
                    original.track,
                    reason: "importEffectRollback"
                )
            }
            throw error
        }
    }

    private func saveImportedTracksUnderMutation(
        _ tracks: [Track],
        progressController: BatchImportProgressDialogController,
        session: ImportSession,
        cancellationToken: ImportCancellationToken,
        failureURL: URL
    ) async -> [Track]? {
        do {
            if let mutationCoordinator {
                let savedIDs: [UUID]? = try await mutationCoordinator.run(
                    kind: .importCommit,
                    targetIDs: tracks.map { $0.id.uuidString }
                ) {
                    await self.committer.saveImportedTracks(
                        tracks,
                        progressController: progressController,
                        session: session,
                        cancellationToken: cancellationToken
                    )?.map(\.id)
                }
                guard let savedIDs else { return nil }
                let savedByID = Dictionary(uniqueKeysWithValues:
                    await repository.fetchTracks(ids: savedIDs).map { ($0.id, $0) }
                )
                return savedIDs.compactMap { savedByID[$0] }
            }
            return await committer.saveImportedTracks(
                tracks,
                progressController: progressController,
                session: session,
                cancellationToken: cancellationToken
            )
        } catch {
            lastImportFailures.append(.init(
                url: failureURL,
                message: "无法提交资料库写入：\(error.localizedDescription)"
            ))
            Log.error("[Import] mutation commit failed: \(error)", category: .import)
            return nil
        }
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

    nonisolated static func progress(
        for stage: BatchImportStage,
        completed: Int,
        total: Int
    ) -> Double {
        let range = stage.progressRange
        guard total > 0 else { return range.upperBound }
        let ratio = min(max(Double(completed) / Double(total), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * ratio
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

import Foundation
import SwiftData

@MainActor
final class LibrarySession: LibrarySessionLifecycle {
    let context: LibraryContext
    private let rootAccessLease: LibraryRootAccessLease
    let modelContainer: ModelContainer
    let cacheServices: LibraryCacheServices
    let repository: SwiftDataLibraryRepository
    let libraryService: LocalLibraryService
    let preferenceStatsService: PreferenceStatsService
    let preferenceResetService: PreferenceResetService
    let searchIndex: LibrarySearchIndex
    let playbackHistoryStore: PlaybackHistoryStore
    let playbackHistoryViewModel: PlaybackHistoryViewModel
    let homeViewModel: HomeViewModel
    let libraryViewModel: LibraryViewModel
    let importEnrichmentService: ImportEnrichmentService
    let fileImportService: FileImportService
    let storageBackend: any LibraryStorageBackend
    let referencedSourceStore: ReferencedSourceStore?
    let referencedSourceScope: ReferencedSourceScope?
    let referencedSourceReconciler: ReferencedSourceReconciler?
    let sourceReconnectService: SourceReconnectService?
    let libraryChangeMonitor: LibraryChangeMonitor?
    let playerViewModel: PlayerViewModel
    let playbackCoordinator: PlaybackCoordinator
    let lyricsViewModel: LyricsViewModel
    let ledMeterProvider: LEDMeterServiceProvider

    private let playbackService: AVAudioPlaybackService
    private var isLoaded = false
    private var isClosed = false
    private(set) var didCompleteLegacyUpgrade = false

    init(
        context: LibraryContext,
        rootAccessLease: LibraryRootAccessLease,
        modelContainer: ModelContainer,
        cacheServices: LibraryCacheServices,
        repository: SwiftDataLibraryRepository,
        libraryService: LocalLibraryService,
        preferenceStatsService: PreferenceStatsService,
        preferenceResetService: PreferenceResetService,
        searchIndex: LibrarySearchIndex,
        playbackHistoryStore: PlaybackHistoryStore,
        playbackHistoryViewModel: PlaybackHistoryViewModel,
        homeViewModel: HomeViewModel,
        libraryViewModel: LibraryViewModel,
        importEnrichmentService: ImportEnrichmentService,
        fileImportService: FileImportService,
        storageBackend: any LibraryStorageBackend,
        referencedSourceStore: ReferencedSourceStore?,
        referencedSourceScope: ReferencedSourceScope?,
        referencedSourceReconciler: ReferencedSourceReconciler?,
        sourceReconnectService: SourceReconnectService?,
        libraryChangeMonitor: LibraryChangeMonitor?,
        playbackService: AVAudioPlaybackService,
        playerViewModel: PlayerViewModel,
        playbackCoordinator: PlaybackCoordinator,
        lyricsViewModel: LyricsViewModel,
        ledMeterProvider: LEDMeterServiceProvider
    ) {
        self.context = context
        self.rootAccessLease = rootAccessLease
        self.modelContainer = modelContainer
        self.cacheServices = cacheServices
        self.repository = repository
        self.libraryService = libraryService
        self.preferenceStatsService = preferenceStatsService
        self.preferenceResetService = preferenceResetService
        self.searchIndex = searchIndex
        self.playbackHistoryStore = playbackHistoryStore
        self.playbackHistoryViewModel = playbackHistoryViewModel
        self.homeViewModel = homeViewModel
        self.libraryViewModel = libraryViewModel
        self.importEnrichmentService = importEnrichmentService
        self.fileImportService = fileImportService
        self.storageBackend = storageBackend
        self.referencedSourceStore = referencedSourceStore
        self.referencedSourceScope = referencedSourceScope
        self.referencedSourceReconciler = referencedSourceReconciler
        self.sourceReconnectService = sourceReconnectService
        self.libraryChangeMonitor = libraryChangeMonitor
        self.playbackService = playbackService
        self.playerViewModel = playerViewModel
        self.playbackCoordinator = playbackCoordinator
        self.lyricsViewModel = lyricsViewModel
        self.ledMeterProvider = ledMeterProvider
    }

    func load() async throws {
        precondition(!isClosed)
        guard !isLoaded else { return }
        try context.paths.createRequiredDirectories()
        await libraryViewModel.reloadLibrary()
        try Task.checkCancellation()
        if let referencedSourceReconciler {
            // Reconcile touches the same SQLite stores as the rest of the
            // session and can fail on transient contention (another
            // instance mid-write, WAL checkpoint). A reconcile failure
            // must not make the whole library unreadable — degrade to a
            // loaded session and let the change monitor retry later.
            do {
                try await referencedSourceReconciler.repairOrphanedFileSources()
            } catch {
                Log.warning(
                    "[LibrarySession] referenced orphan repair deferred after load failure: \(error)",
                    category: .library
                )
            }
            do {
                let sourceIDs = try await referencedSourceReconciler.allSourceIDs()
                // Replay and scan each source independently. One stale pending
                // intent (for example a failed conversion in one folder) must
                // not prevent the other sources from loading or make the
                // library appear empty on the next launch.
                _ = await referencedSourceReconciler.reconcileBestEffort(
                    sourceIDs: sourceIDs
                )
            } catch {
                Log.warning(
                    "[LibrarySession] referenced reconcile deferred after load failure: \(error)",
                    category: .library
                )
            }
        }
        let upgrade = LegacyLibraryUpgradeCoordinator(
            context: context,
            storageLocations: cacheServices.storageLocations
        ) { [context, libraryViewModel, repository, searchIndex, playbackHistoryStore] in
            try await LibraryUpgradeSessionValidator.validate(
                context: context,
                libraryViewModel: libraryViewModel,
                repository: repository,
                searchIndex: searchIndex,
                playbackHistoryStore: playbackHistoryStore
            )
        }
        didCompleteLegacyUpgrade = await upgrade.runIfNeeded() == .completed
        if let referencedSourceReconciler, let libraryChangeMonitor {
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: referencedSourceReconciler.sourceRoots
            )
        } else if context.mode == .managed, let libraryChangeMonitor {
            try await startManagedLibraryMonitor(libraryChangeMonitor)
        }
        isLoaded = true
    }

    func importInitialSelection(_ selection: LibraryInitialImportSelection) async throws -> LibraryInitialImportResult {
        guard !isClosed else {
            let result = LibraryInitialImportResult(
                requested: selection.urls.count,
                planned: 0,
                imported: 0,
                failures: selection.urls.map { ImportInputFailure(url: $0, message: "Session closed") },
                sourceIDs: []
            )
            throw LibraryInitialImportError.initialImportFailed(result)
        }
        let result = await fileImportService.importInitialSelection(selection)
        if !selection.playlistSourceEntries.isEmpty {
            // Bind playlists as soon as source descriptors exist. A source
            // scan may have item-level failures (for example an old NCM
            // conversion), but that must not discard the user's playlist
            // choice or block the remaining sources.
            try await createAutomaticPlaylists(
                for: selection.playlistSourceEntries,
                result: result
            )
            await libraryViewModel.reloadLibrary()
        } else if context.mode == .referenced,
                  selection.createPlaylistsForDirectories,
                  !result.sourceIDs.isEmpty {
            // Compatibility path for older callers that only supplied the
            // original boolean option. New UI always supplies explicit entries.
            try await referencedSourceReconciler?.createPlaylistsForSources(result.sourceIDs)
            await libraryViewModel.reloadLibrary()
        }
        if context.mode == .referenced, !result.sourceIDs.isEmpty {
            do {
                _ = try await refreshReferencedSources()
            } catch {
                // Keep the sources and any playlists already created. The
                // monitor can retry the scan, and the UI notice contains the
                // actionable failure instead of turning the whole import into
                // a library-creation failure.
                Log.warning(
                    "[LibrarySession] initial referenced refresh deferred: \(error)",
                    category: .library
                )
            }
            await libraryViewModel.reloadLibrary()
        }
        guard selection.urls.isEmpty || result.didSucceed else {
            throw LibraryInitialImportError.initialImportFailed(result)
        }
        return result
    }

    private func createAutomaticPlaylists(
        for entries: [LibraryImportSourceEntry],
        result: LibraryInitialImportResult
    ) async throws {
        var boundDirectorySourceIDs: [UUID] = []

        for entry in entries {
            switch entry.kind {
            case .directory:
                guard let rootURL = entry.urls.first else { continue }
                if context.mode == .referenced {
                    let canonicalRoot = LibraryImportSourceEntry.canonicalPath(rootURL)
                    if let source = result.sources.first(where: {
                        $0.mode == .directory
                            && LibraryImportSourceEntry.canonicalPath(URL(fileURLWithPath: $0.path)) == canonicalRoot
                    }) {
                        boundDirectorySourceIDs.append(source.id)
                    }
                } else {
                    let tracks = await importedTracks(for: entry, result: result)
                    if !tracks.isEmpty {
                        let playlist = await repository.createPlaylist(name: entry.displayName)
                        await repository.addTracks(tracks, to: playlist)
                    }
                }

            case .individualFiles:
                let tracks = await importedTracks(for: entry, result: result)
                guard !tracks.isEmpty else { continue }
                let playlist = await repository.createPlaylist(
                    name: automaticPlaylistName(for: entry, tracks: tracks)
                )
                await repository.addTracks(tracks, to: playlist)
            }
        }

        if context.mode == .referenced, !boundDirectorySourceIDs.isEmpty {
            try await referencedSourceReconciler?.createPlaylistsForSources(boundDirectorySourceIDs)
        }
    }

    private func importedTracks(
        for entry: LibraryImportSourceEntry,
        result: LibraryInitialImportResult
    ) async -> [Track] {
        let selectedPaths = Set(entry.urls.map(LibraryImportSourceEntry.canonicalPath))
        let importedIDs = result.importedTrackIDsByPath.compactMap { path, trackID in
            switch entry.kind {
            case .directory:
                let root = entry.urls.first.map(LibraryImportSourceEntry.canonicalPath) ?? ""
                return path == root || path.hasPrefix(root + "/") ? trackID : nil
            case .individualFiles:
                return selectedPaths.contains(path) ? trackID : nil
            }
        }
        guard !importedIDs.isEmpty else { return [] }
        let tracks = await repository.fetchTracks(ids: Array(Set(importedIDs)))
        var order: [UUID: Int] = [:]
        for (index, trackID) in importedIDs.enumerated() {
            order[trackID] = min(order[trackID] ?? index, index)
        }
        return tracks.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    private func automaticPlaylistName(for entry: LibraryImportSourceEntry, tracks: [Track]) -> String {
        guard entry.kind == .individualFiles else { return entry.displayName }
        let title = tracks.first?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstTitle = title?.isEmpty == false ? title! : entry.displayName
        return entry.urls.count > 1 ? "\(firstTitle) 等歌曲" : firstTitle
    }

    @discardableResult
    func refreshReferencedSources() async throws -> [ReferencedSourceScopeIssue] {
        guard !isClosed,
              let referencedSourceReconciler,
              let libraryChangeMonitor else { return [] }
        await libraryChangeMonitor.stopAndWait()
        do {
            let issues = try await referencedSourceReconciler.refreshSources()
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: referencedSourceReconciler.sourceRoots
            )
            return issues
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: referencedSourceReconciler.sourceRoots
            )
            throw error
        }
    }

    func removeReferencedSource(_ sourceID: UUID) async throws {
        guard !isClosed,
              let referencedSourceReconciler,
              let libraryChangeMonitor else { return }
        let originalRoots = referencedSourceReconciler.sourceRoots
        await libraryChangeMonitor.stopAndWait()
        do {
            try await referencedSourceReconciler.removeSource(sourceID)
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: referencedSourceReconciler.sourceRoots
            )
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: originalRoots
            )
            throw error
        }
    }

    func prepareSourceReconnect(
        sourceID: UUID,
        candidateRoots: [URL]
    ) async throws -> SourceReconnectPreparation {
        guard !isClosed, let sourceReconnectService else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        return try await sourceReconnectService.prepareSourceReconnect(
            sourceID: sourceID,
            candidateRoots: candidateRoots
        )
    }

    func reconnectSource(
        preparation: SourceReconnectPreparation,
        planID: String,
        conflictSelections: [UUID: URL]
    ) async throws {
        guard !isClosed,
              let sourceReconnectService,
              let referencedSourceReconciler,
              let libraryChangeMonitor else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        let originalRoots = referencedSourceReconciler.sourceRoots
        await libraryChangeMonitor.stopAndWait()
        do {
            try await sourceReconnectService.reconnectSource(
                preparation: preparation,
                planID: planID,
                conflictSelections: conflictSelections
            )
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: referencedSourceReconciler.sourceRoots
            )
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: sourceReconnectServiceRoots(
                    fallback: originalRoots,
                    reconciler: referencedSourceReconciler
                )
            )
            throw error
        }
    }

    func prepareTrackRelocation(
        trackID: UUID,
        selectedURL: URL
    ) async throws -> TrackRelocationProposal {
        guard !isClosed, let sourceReconnectService else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        return try await sourceReconnectService.prepareTrackRelocation(
            trackID: trackID,
            selectedURL: selectedURL
        )
    }

    func relocateTrack(
        _ proposal: TrackRelocationProposal,
        confirmedReplacement: Bool
    ) async throws {
        guard !isClosed, let sourceReconnectService else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        try await sourceReconnectService.relocateTrack(
            proposal,
            confirmedReplacement: confirmedReplacement
        )
    }

    private func startReferencedSourceMonitor(
        _ monitor: LibraryChangeMonitor,
        reconciler: ReferencedSourceReconciler,
        roots: [UUID: URL]
    ) async throws {
        let libraryID = context.id
        let libraryFilter = ManagedLibraryFileEventFilter(paths: context.paths)
        let libraryRootPath = context.rootURL.standardizedFileURL.path
        var monitoredRoots = roots
        monitoredRoots[libraryID] = context.rootURL

        try await monitor.start(
            sourceRoots: monitoredRoots,
            eventFilter: { event in
                let eventPath = URL(fileURLWithPath: event.path).standardizedFileURL.path
                guard eventPath == libraryRootPath || eventPath.hasPrefix(libraryRootPath + "/") else {
                    return true
                }
                return libraryFilter.shouldProcess(event)
            },
            initiallyDirty: false
        ) { [weak reconciler, weak libraryViewModel] dirtyIDs, _ in
            if dirtyIDs.contains(libraryID) {
                await libraryViewModel?.reloadLibrary()
            }

            let sourceIDs = dirtyIDs.subtracting([libraryID])
            guard !sourceIDs.isEmpty, let reconciler else { return }
            let outcome = await reconciler.reconcileBestEffort(sourceIDs: sourceIDs)
            if !outcome.failedSourceIDs.isEmpty {
                await monitor.markFailed(sourceIDs: outcome.failedSourceIDs)
            }
            // Only pull a fresh snapshot into the UI when the reconcile
            // actually changed repository/runtime state. Empty-diff rescans
            // (the common case for FS-event debounces) used to trigger a full
            // `reloadLibrary()` every time, which stalled the UI on large
            // referenced libraries.
            if !outcome.changes.isEmpty {
                await libraryViewModel?.reloadLibrary()
            }
        }
    }

    private func startManagedLibraryMonitor(_ monitor: LibraryChangeMonitor) async throws {
        let libraryID = context.id
        let filter = ManagedLibraryFileEventFilter(paths: context.paths)
        try await monitor.start(
            sourceRoots: [libraryID: context.rootURL],
            eventFilter: { filter.shouldProcess($0) },
            initiallyDirty: false
        ) { [weak libraryViewModel] libraryIDs, _ in
            guard libraryIDs.contains(libraryID), let libraryViewModel else { return }
            await libraryViewModel.reloadLibrary()
        }
    }

    private func sourceReconnectServiceRoots(
        fallback: [UUID: URL],
        reconciler: ReferencedSourceReconciler
    ) -> [UUID: URL] {
        let current = reconciler.sourceRoots
        return current.isEmpty ? fallback : current
    }

    func flush() async throws {
        guard !isClosed else { return }
        preferenceStatsService.saveAllPendingNow(
            trackProvider: { [weak libraryViewModel] trackID in
                libraryViewModel?.allTracks.first { $0.id == trackID }
            },
            synchronously: true
        )
    }

    func quiesce() async {
        guard !isClosed else { return }
        await libraryChangeMonitor?.stopAndWait()
        playerViewModel.stop()
        playerViewModel.stopLevelMeter()
        libraryViewModel.prepareForSessionClose()
        let trackIDs = Set(libraryViewModel.allTracks.map(\.id))
        await importEnrichmentService.cancelEnrichment(for: trackIDs)
    }

    func close() async {
        guard !isClosed else { return }
        await libraryChangeMonitor?.stopAndWait()
        referencedSourceReconciler?.close()
        await importEnrichmentService.close()
        isClosed = true
        libraryViewModel.prepareForSessionClose()
        playbackCoordinator.close()
        await searchIndex.close()
        await storageBackend.close()
        await cacheServices.close()
        preferenceStatsService.clearCache()
        rootAccessLease.release()
        isLoaded = false
    }
}

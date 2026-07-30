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
        if let referencedSourceReconciler, let libraryChangeMonitor {
            // Reconcile touches the same SQLite stores as the rest of the
            // session and can fail on transient contention (another
            // instance mid-write, WAL checkpoint). A reconcile failure
            // must not make the whole library unreadable — degrade to a
            // loaded session and let the change monitor retry later.
            do {
                try await referencedSourceReconciler.replayPending()
                try await referencedSourceReconciler.repairOrphanedFileSources()
                let sourceIDs = try await referencedSourceReconciler.allSourceIDs()
                try await referencedSourceReconciler.reconcile(sourceIDs: sourceIDs)
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
        if context.mode == .referenced, !result.sourceIDs.isEmpty {
            _ = try await refreshReferencedSources()
        }
        guard selection.urls.isEmpty || result.didSucceed else {
            throw LibraryInitialImportError.initialImportFailed(result)
        }
        return result
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
            do {
                try await reconciler.reconcile(sourceIDs: sourceIDs)
            } catch {
                await monitor.markFailed(sourceIDs: sourceIDs)
                await reconciler.reportMonitorFailure(sourceIDs: sourceIDs, error: error)
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

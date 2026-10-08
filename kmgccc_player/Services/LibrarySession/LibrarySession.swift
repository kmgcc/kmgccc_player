import Foundation
import PlayerAutomationProtocol
import SwiftData

struct LibraryAutomationLyricsApplyOutcome: Sendable {
    let applied: Bool
    let conflicted: Bool
    let currentQuality: Int
    let candidateQuality: Int
    let message: String
}

@MainActor
struct LibraryAutomationJobReporter {
    private let operationCoordinator: LibraryOperationCoordinator

    init(operationCoordinator: LibraryOperationCoordinator) {
        self.operationCoordinator = operationCoordinator
    }

    func recordProgress(completedCount: Int, totalCount: Int, phase: String) {
        operationCoordinator.recordProgress(
            completedCount: completedCount,
            totalCount: totalCount,
            phase: phase
        )
    }

    func recordCheckpoint(_ label: String) {
        operationCoordinator.recordCheckpoint(label)
    }

    func recordFailure(_ summary: String, itemID: UUID? = nil) {
        operationCoordinator.recordPartialFailure(summary, itemID: itemID)
    }

    func recordResult(_ result: AutomationJSONValue) {
        operationCoordinator.recordResult(result)
    }
}

@MainActor
final class LibrarySession: LibrarySessionLifecycle {
    let context: LibraryContext
    private let rootAccessLease: LibraryRootAccessLease
    private let writerLease: LibraryWriterLease
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

    var audioDSPPresentationLeadSeconds: Double { playbackService.audioOutputDelay }

    func bindAudioDSP(_ controller: AudioDSPController) {
        playbackService.bindAudioDSP(controller)
    }

    private let playbackService: AVAudioPlaybackService
    private let operationCoordinator: LibraryOperationCoordinator
    private let mutationCoordinator: LibraryMutationCoordinator
    private var isLoaded = false
    private var isClosed = false
    private(set) var didCompleteLegacyUpgrade = false
    private(set) var initialReconcileOutcome: InitialReconcileOutcome?

    init(
        context: LibraryContext,
        rootAccessLease: LibraryRootAccessLease,
        writerLease: LibraryWriterLease,
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
        operationCoordinator: LibraryOperationCoordinator,
        mutationCoordinator: LibraryMutationCoordinator,
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
        self.writerLease = writerLease
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
        self.operationCoordinator = operationCoordinator
        self.mutationCoordinator = mutationCoordinator
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
            initialReconcileOutcome = try await Self.runInitialReconcile(
                reconciler: referencedSourceReconciler,
                operationCoordinator: operationCoordinator
            )
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
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
        } else if context.mode == .managed, let libraryChangeMonitor {
            try await startManagedLibraryMonitor(libraryChangeMonitor)
        }
        isLoaded = true
    }

    /// Switch-time first reconcile contract: every known source is attempted
    /// exactly once before activation completes; one failing source never
    /// skips the rest and never blocks activation. A genuinely cancelled
    /// switch aborts without reporting source failures.
    static func runInitialReconcile(
        reconciler: ReferencedSourceReconciler,
        operationCoordinator: LibraryOperationCoordinator
    ) async throws -> InitialReconcileOutcome {
        let startedAt = Date()

        // Reconcile touches the same SQLite stores as the rest of the session
        // and can fail on transient contention (another instance mid-write,
        // WAL checkpoint). Degrade to activation and let the change monitor
        // retry later — only cancellation aborts the switch.
        do {
            _ = try await operationCoordinator.run {
                try await reconciler.repairOrphanedFileSources()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.warning(
                "[LibrarySession] referenced orphan repair deferred after load failure: \(error)",
                category: .library
            )
        }

        struct AttemptLedger: Sendable {
            var attempted: Set<UUID> = []
            var failures: [InitialReconcileOutcome.SourceFailure] = []
        }

        let ledger = try await operationCoordinator.run(as: .sourceScan) { () -> AttemptLedger in
            var ledger = AttemptLedger()
            let sourceIDs = try await reconciler.automaticSourceIDs()
            for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                operationCoordinator.recordCheckpoint("来源扫描 \(sourceID.uuidString.prefix(8))")
                do {
                    _ = try await reconciler.reconcile(sourceIDs: [sourceID])
                    ledger.attempted.insert(sourceID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = String(String(describing: error).prefix(512))
                    ledger.attempted.insert(sourceID)
                    ledger.failures.append(.init(sourceID: sourceID, reason: reason))
                    await reconciler.reportMonitorFailure(sourceIDs: [sourceID], error: error)
                    Log.warning(
                        "[LibrarySession] initial reconcile failed source=\(sourceID): \(reason)",
                        category: .library
                    )
                }
            }
            return ledger
        }

        return InitialReconcileOutcome(
            attemptedSourceIDs: ledger.attempted,
            failedSources: ledger.failures,
            startedAt: startedAt,
            finishedAt: Date()
        )
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
        return try await runLibraryOperation(as: .importFiles) { [weak self] in
            guard let self else {
                throw LibraryInitialImportError.initialImportFailed(
                    LibraryInitialImportResult(
                        requested: selection.urls.count,
                        planned: 0,
                        imported: 0,
                        failures: selection.urls.map {
                            ImportInputFailure(url: $0, message: "Session released")
                        },
                        sourceIDs: []
                    )
                )
            }
            return try await self.performInitialImport(selection)
        }
    }

    private func performInitialImport(
        _ selection: LibraryInitialImportSelection
    ) async throws -> LibraryInitialImportResult {
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

    /// Executes a library mutation or scan while retaining it in the session's
    /// lifetime registry. Callers must use this wrapper for user-initiated
    /// asynchronous work instead of creating an unowned Task around the
    /// session.
    func runLibraryOperation<Value: Sendable>(
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await operationCoordinator.run(work)
    }

    func runLibraryOperation<Value: Sendable>(
        as kind: LibraryTaskKind,
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await operationCoordinator.run(as: kind, work)
    }

    /// Installs a push-based observer for the coordinator's task-state
    /// changes (plan §14). Hosts copy `taskDescriptors` inside the callback
    /// instead of polling task state.
    func bindLibraryTaskStateObserver(_ onChange: (@MainActor () -> Void)?) {
        operationCoordinator.onTasksDidChange = onChange
    }

    /// Current live task descriptors for hosts that surface session-wide
    /// task state.
    func libraryTaskDescriptorsSnapshot() -> [LibraryOperationTaskDescriptor] {
        operationCoordinator.taskDescriptors
    }

    /// Returns live and recently completed operation snapshots for the
    /// automation Job surface. The coordinator restores its bounded history
    /// from the library-scoped automation Job file; domain data remains
    /// durable in the library's own stores.
    func libraryJobDescriptorsSnapshot() -> [LibraryOperationTaskDescriptor] {
        let live = operationCoordinator.taskDescriptors
        let recent = operationCoordinator.recentTaskDescriptors.filter { recent in
            !live.contains(where: { $0.id == recent.id })
        }
        return (live + recent).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Starts generic App automation work as a library-scoped, cancellable
    /// Job. The caller reports item results through the same durable owner.
    @discardableResult
    func startAutomationJob(
        totalCount: Int,
        work: @escaping @MainActor (LibraryAutomationJobReporter) async -> Void
    ) -> LibraryOperationTaskDescriptor? {
        guard !isClosed, totalCount > 0 else { return nil }
        let started = operationCoordinator.start({ [weak self] in
            guard let self else { return }
            let reporter = LibraryAutomationJobReporter(operationCoordinator: self.operationCoordinator)
            reporter.recordProgress(completedCount: 0, totalCount: totalCount, phase: "Starting")
            await work(reporter)
        }, kind: .automation)
        guard started else { return nil }
        return operationCoordinator.taskDescriptors.last
    }

    @discardableResult
    func cancelLibraryJob(id: UUID) -> Bool {
        operationCoordinator.cancel(operationID: id)
    }

    /// Re-enqueues a failed/cancelled automation Job when its operation type
    /// carries a durable, safe retry specification. Unsupported Jobs remain
    /// observable but cannot be guessed or reconstructed from arbitrary data.
    @discardableResult
    func retryAutomationJob(
        id: UUID,
        importSelection: LibraryInitialImportSelection? = nil
    ) -> LibraryOperationTaskDescriptor? {
        guard let descriptor = operationCoordinator.taskDescriptor(operationID: id),
              descriptor.state == .failed
                || descriptor.state == .partialFailure
                || descriptor.state == .cancelled,
              let retrySpec = descriptor.retrySpec else {
            return nil
        }
        switch retrySpec.kind {
        case .lyricsRefresh:
            return startAutomationLyricsRefresh(
                trackIDs: descriptor.failedItemIDs.isEmpty
                    ? retrySpec.trackIDs
                    : descriptor.failedItemIDs,
                force: retrySpec.force
            )
        case .sourceRefresh:
            guard let sourceID = retrySpec.sourceID else { return nil }
            return startAutomationSourceRefresh(sourceID: sourceID)
        case .libraryImport:
            guard let importSelection,
                  let enrichmentPolicy = LibraryImportEnrichmentPolicy(
                    rawValue: retrySpec.enrichmentPolicy
                  ),
                  retrySpec.targetPlaylistID.map({ playlistID in
                      libraryViewModel.playlists.contains { $0.id == playlistID }
                  }) ?? true else {
                return nil
            }
            return startAutomationImport(
                selection: importSelection,
                playlistID: retrySpec.targetPlaylistID,
                retryEnrichment: enrichmentPolicy == .standard,
                enrichmentPolicy: enrichmentPolicy
            )
        }
    }

    /// Starts the provider-backed lyrics maintenance workflow without making
    /// the IPC request wait for a whole library. The operation is owned by the
    /// session coordinator, so progress/cancellation remain valid across CLI,
    /// MCP and UI observers during the current App launch.
    func startAutomationLyricsRefresh(
        trackIDs: [UUID],
        force: Bool
    ) -> LibraryOperationTaskDescriptor? {
        let uniqueIDs = Array(Set(trackIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !isClosed, !uniqueIDs.isEmpty else { return nil }
        let started = operationCoordinator.start({ [weak self] in
            guard let self else { return }
            await self.runAutomationLyricsRefresh(trackIDs: uniqueIDs, force: force)
        }, kind: .enrichment, retrySpec: .lyricsRefresh(trackIDs: uniqueIDs, force: force))
        guard started else { return nil }
        return operationCoordinator.taskDescriptors.last
    }

    private func runAutomationLyricsRefresh(trackIDs: [UUID], force: Bool) async {
        let tracksByID = Dictionary(
            uniqueKeysWithValues: libraryViewModel.allTracks.map { ($0.id, $0) }
        )
        let total = trackIDs.count
        var completed = 0
        for trackID in trackIDs {
            if Task.isCancelled { return }
            defer {
                completed += 1
                operationCoordinator.recordProgress(
                    completedCount: completed,
                    totalCount: total,
                    phase: "lyrics"
                )
            }
            guard let track = tracksByID[trackID] else {
                operationCoordinator.recordPartialFailure(
                    "\(trackID.uuidString): Track not found",
                    itemID: trackID
                )
                continue
            }
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                operationCoordinator.recordPartialFailure(
                    "\(trackID.uuidString): missing title",
                    itemID: trackID
                )
                continue
            }
            let expectedRevision = libraryViewModel.automationTrackRevision(for: track)
            let wordSyncedTTML = await LyricsSearchHelper.searchAndFetchBestLyrics(
                title: title,
                artist: track.artist.isEmpty ? nil : track.artist,
                album: track.album.isEmpty ? nil : track.album,
                duration: track.duration > 0 ? track.duration : nil,
                mode: .verbatim,
                searchCoordinator: cacheServices.lyricsSearchCoordinator,
                amllDBService: cacheServices.amllDBService
            )
            guard !Task.isCancelled else { return }
            let wordQuality = wordSyncedTTML.map { lyricsQuality($0) } ?? 0
            let ttml: String?
            if wordQuality >= 2 {
                ttml = wordSyncedTTML
            } else {
                let lineSyncedTTML = await LyricsSearchHelper.searchAndFetchBestLyrics(
                    title: title,
                    artist: track.artist.isEmpty ? nil : track.artist,
                    album: track.album.isEmpty ? nil : track.album,
                    duration: track.duration > 0 ? track.duration : nil,
                    mode: .line,
                    searchCoordinator: cacheServices.lyricsSearchCoordinator,
                    amllDBService: cacheServices.amllDBService
                )
                ttml = lineSyncedTTML ?? wordSyncedTTML
            }
            guard let ttml,
                  !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                operationCoordinator.recordPartialFailure(
                    "\(trackID.uuidString): no usable lyrics candidate",
                    itemID: trackID
                )
                continue
            }
            let outcome = await applyAutomationLyrics(
                trackID: trackID,
                ttml: ttml,
                candidateQuality: lyricsQuality(ttml),
                force: force,
                expectedRevision: expectedRevision
            )
            if outcome.conflicted {
                operationCoordinator.recordPartialFailure(
                    "\(trackID.uuidString): lyrics changed while the candidate was fetched",
                    itemID: trackID
                )
            } else if outcome.applied {
                operationCoordinator.recordCheckpoint("applied lyrics \(trackID.uuidString)")
            } else if outcome.message.hasPrefix("kept") {
                operationCoordinator.recordCheckpoint("kept current lyrics \(trackID.uuidString)")
            } else {
                operationCoordinator.recordPartialFailure(
                    "\(trackID.uuidString): \(outcome.message)",
                    itemID: trackID
                )
            }
        }
    }

    /// Searches all configured artwork providers and returns the merged result
    /// after the transient coordinator has finished aggregating them.
    /// The search path deliberately reuses the same provider services as the
    /// interactive cover editor. The coordinator is transient because its
    /// published candidate/selection state belongs to one request, while the
    /// provider services and their caches remain session-owned.
    func searchArtworkCandidatesForAutomation(
        trackID: UUID,
        limit: Int
    ) async -> [CoverCandidate] {
        guard let track = libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
            return []
        }

        let coordinator = CoverSearchCoordinator(
            coverDownloadService: cacheServices.coverDownloadService,
            netEaseCoverService: cacheServices.netEaseCoverService,
            qqMusicCoverService: cacheServices.qqMusicCoverService
        )
        await coordinator.search(
            artist: track.artist,
            album: track.album,
            title: track.title,
            duration: track.duration.isFinite && track.duration > 0 ? track.duration : nil
        )
        return Array(coordinator.candidates.prefix(max(1, min(limit, 5))))
    }

    func searchArtistArtworkCandidatesForAutomation(
        artistID: UUID,
        limit: Int
    ) async -> [CoverCandidate] {
        guard let entry = libraryViewModel.artistEntries.first(where: { $0.id == artistID }) else {
            return []
        }
        do {
            let candidates = try await cacheServices.artistArtworkProviderCoordinator.searchCandidates(
                artist: entry.displayName,
                limit: max(1, min(limit, 5))
            )
            return Array(candidates.prefix(max(1, min(limit, 5))))
        } catch {
            return []
        }
    }

    func searchAlbumArtworkCandidatesForAutomation(
        albumKey: String,
        limit: Int
    ) async -> [CoverCandidate] {
        guard let entry = libraryViewModel.albumEntries.first(where: { $0.canonicalKey == albumKey }) else {
            return []
        }
        let coordinator = CoverSearchCoordinator(
            coverDownloadService: cacheServices.coverDownloadService,
            netEaseCoverService: cacheServices.netEaseCoverService,
            qqMusicCoverService: cacheServices.qqMusicCoverService
        )
        await coordinator.search(
            artist: entry.primaryArtistDisplayName,
            album: entry.displayTitle
        )
        return Array(coordinator.candidates.prefix(max(1, min(limit, 5))))
    }

    /// Applies a fetched candidate through the same App-owned persistence
    /// boundary used by the batch Job. The revision is checked immediately
    /// before writing so a UI edit made while a remote candidate was fetched
    /// cannot be silently overwritten.
    func applyAutomationLyrics(
        trackID: UUID,
        ttml: String,
        candidateQuality: Int,
        force: Bool,
        expectedRevision: String? = nil
    ) async -> LibraryAutomationLyricsApplyOutcome {
        guard let track = libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: false,
                currentQuality: 0,
                candidateQuality: candidateQuality,
                message: "Track not found"
            )
        }
        let currentQuality = automationLyricsQuality(track)
        if let expectedRevision,
           expectedRevision != libraryViewModel.automationTrackRevision(for: track) {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: true,
                currentQuality: currentQuality,
                candidateQuality: candidateQuality,
                message: "Track metadata changed after the lyrics query"
            )
        }
        guard force || candidateQuality > currentQuality else {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: false,
                currentQuality: currentQuality,
                candidateQuality: candidateQuality,
                message: "kept current lyrics because the candidate is not better"
            )
        }
        track.ttmlLyricText = ttml
        track.lyricsText = nil
        track.lyricsFileName = nil
        let persistence = await libraryViewModel.saveTrackEdits(
            track,
            mode: .metaAndLyrics,
            reason: "automationLyricsApply"
        )
        guard persistence.persistedTrackIDs.contains(trackID) else {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: false,
                currentQuality: currentQuality,
                candidateQuality: candidateQuality,
                message: "persistence failed"
            )
        }
        return LibraryAutomationLyricsApplyOutcome(
            applied: true,
            conflicted: false,
            currentQuality: currentQuality,
            candidateQuality: candidateQuality,
            message: force ? "lyrics applied with force" : "lyrics applied"
        )
    }

    /// Applies Agent-supplied TTML directly after the same validation and
    /// repository-owned persistence boundary used by the manual lyric editor.
    /// Direct text is intentional: unlike a provider candidate it is not
    /// subject to the "only replace with a better search result" policy.
    func applyCustomTTMLForAutomation(
        trackID: UUID,
        ttml: String,
        expectedRevision: String? = nil
    ) async -> LibraryAutomationLyricsApplyOutcome {
        guard let normalizedTTML = LyricsFormatSupport.normalizedTTMLText(ttml) else {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: false,
                currentQuality: 0,
                candidateQuality: 0,
                message: "custom TTML is invalid"
            )
        }
        guard let track = libraryViewModel.allTracks.first(where: { $0.id == trackID }) else {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: false,
                currentQuality: 0,
                candidateQuality: 0,
                message: "Track not found"
            )
        }

        let currentQuality = automationLyricsQuality(track)
        if let expectedRevision,
           expectedRevision != libraryViewModel.automationTrackRevision(for: track) {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: true,
                currentQuality: currentQuality,
                candidateQuality: lyricsQuality(normalizedTTML),
                message: "Track metadata changed after the lyrics query"
            )
        }

        let candidateQuality = lyricsQuality(normalizedTTML)
        track.ttmlLyricText = normalizedTTML
        track.lyricsText = nil
        track.lyricsFileName = nil
        let persistence = await libraryViewModel.saveTrackEdits(
            track,
            mode: .metaAndLyrics,
            reason: "automationLyricsApplyCustomTTML"
        )
        guard persistence.persistedTrackIDs.contains(trackID) else {
            return LibraryAutomationLyricsApplyOutcome(
                applied: false,
                conflicted: false,
                currentQuality: currentQuality,
                candidateQuality: candidateQuality,
                message: "persistence failed"
            )
        }
        return LibraryAutomationLyricsApplyOutcome(
            applied: true,
            conflicted: false,
            currentQuality: currentQuality,
            candidateQuality: candidateQuality,
            message: "custom TTML applied"
        )
    }

    private func lyricsQuality(_ ttml: String) -> Int {
        LyricsFormatSupport.isWordSyncedTTML(ttml) ? 2 : 1
    }

    private func automationLyricsQuality(_ track: Track) -> Int {
        let ttml = track.ttmlLyricText
            ?? track.loadTTMLLyricsIfNeeded()
            ?? (track.ttmlLyricsFileName.flatMap { context.paths.trackAssetURL(for: track.id, fileName: $0) }).flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        if let ttml, !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lyricsQuality(ttml)
        }
        if track.ttmlLyricsFileName != nil { return 1 }
        let plain = track.lyricsText
            ?? track.loadLyricsIfNeeded()
            ?? (track.lyricsFileName.flatMap { context.paths.trackAssetURL(for: track.id, fileName: $0) }).flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LyricsFormatSupport.looksLikeLRC(plain) ? 1 : 0
        }
        return 0
    }

    /// Installs the session lifetime gate used by UI-owned imports. Keeping the
    /// closure on the view model avoids a second coordinator in the UI while
    /// preserving one owner for session quiescence.
    func bindLibraryViewModelOperationOwnership() {
        libraryViewModel.runOwnedImportOperation = { [weak self] work in
            guard let self else { return nil }
            do {
                return try await self.runLibraryOperation(as: .importFiles) {
                    await work()
                }
            } catch {
                Log.warning(
                    "[LibrarySession] import rejected by operation coordinator: \(error)",
                    category: .library
                )
                return nil
            }
        }
        libraryViewModel.runOwnedLibraryMutation = { [weak self] work in
            guard let self else {
                throw LibraryMutationCoordinatorError.sessionQuiescing
            }
            let _: Void = try await self.mutationCoordinator.run(
                kind: .userLibraryMutation
            ) {
                try await work()
            }
        }
    }

    /// Starts non-blocking session work, such as initial import after the
    /// setup panel closes. The returned flag lets callers release any retained
    /// security scope when a session is already quiescing.
    @discardableResult
    func startBackgroundLibraryOperation(
        _ work: @escaping @MainActor () async -> Void
    ) -> Bool {
        operationCoordinator.start(work, kind: .importFiles)
    }

    /// The same destination, duplicate, conversion and enrichment pipeline as
    /// manual import, retained by this session rather than the IPC request.
    @discardableResult
    func startAutomationImport(
        selection: LibraryInitialImportSelection,
        playlistID: UUID? = nil,
        retryEnrichment: Bool = false,
        enrichmentPolicy: LibraryImportEnrichmentPolicy = .standard
    ) -> LibraryOperationTaskDescriptor? {
        guard !isClosed else { return nil }
        let ownedSelection = selection.retainedCopy()
        let importContext = LibraryImportContext(
            libraryID: context.id,
            sessionGeneration: context.generation,
            destination: playlistID.map { .playlist($0) } ?? .libraryOnly,
            origin: .automation,
            enrichmentPolicy: enrichmentPolicy
        )
        let started = operationCoordinator.start({ [weak self] in
            defer { ownedSelection.release() }
            guard let self else { return }
            let previousTrackCount = playlistID.flatMap { id in
                self.libraryViewModel.playlists.first { $0.id == id }?.trackCount
            } ?? 0
            let outcome = await self.fileImportService.importSelectedURLs(
                ownedSelection.urls, context: importContext
            )
            await self.libraryViewModel.publishImportResult(
                outcome, playlistID: playlistID, previousTrackCount: previousTrackCount
            )
            var values: [String: AutomationJSONValue] = [
                "libraryID": .string(self.context.id.uuidString),
                "mode": .string(self.context.mode.rawValue),
                "trackIDs": .array(outcome.trackIDs.map { .string($0.uuidString) }),
                "importedTrackCount": .number(Double(outcome.importedTrackCount)),
                "reusedTrackCount": .number(Double(outcome.reusedTrackCount)),
                "playlistMembershipAdditions": .number(Double(outcome.playlistMembershipAdditions)),
                "alreadyInPlaylistCount": .number(Double(outcome.alreadyInPlaylistCount)),
                "pendingNCMCount": .number(Double(outcome.pendingNCMCount)),
                "fileTrackMappings": .array(outcome.fileTrackMappings.map { mapping in
                    .object([
                        "filePath": .string(mapping.filePath),
                        "trackID": .string(mapping.trackID.uuidString)
                    ])
                }),
                "failures": .array(outcome.failures.map { .object([
                    "path": .string($0.url.path), "message": .string($0.message)
                ]) }),
                "enrichmentPolicy": .string(enrichmentPolicy.rawValue),
                "enrichmentCompleted": .boolean(enrichmentPolicy == .migration)
            ]
            if let playlistID { values["targetPlaylistID"] = .string(playlistID.uuidString) }
            self.operationCoordinator.recordResult(.object(values))
            self.operationCoordinator.recordProgress(
                completedCount: outcome.affectedTrackCount,
                totalCount: outcome.affectedTrackCount + outcome.failures.count,
                phase: enrichmentPolicy == .migration ? "import complete" : "import enrichment"
            )
            for failure in outcome.failures.prefix(50) {
                self.operationCoordinator.recordPartialFailure("\(failure.url.path): \(failure.message)")
            }
            if outcome.wasRejectedAsStale {
                self.operationCoordinator.recordPartialFailure("Import rejected: library session changed")
            }
            guard enrichmentPolicy == .standard else {
                values["enrichmentWarnings"] = .array([])
                await self.libraryViewModel.syncVisibleStateFromRepositoryAfterImport()
                self.operationCoordinator.recordResult(.object(values))
                self.operationCoordinator.recordCheckpoint("Import complete without online enrichment")
                return
            }
            let newTrackIDs = Set(outcome.newTrackIDs)
            let affectedTrackIDs = Set(outcome.trackIDs)
            let enrichmentTrackIDs: Set<UUID>
            if retryEnrichment {
                let reusedTrackIDs = affectedTrackIDs.subtracting(newTrackIDs)
                let reusedTracks = self.libraryViewModel.allTracks.filter {
                    reusedTrackIDs.contains($0.id)
                }
                await self.importEnrichmentService.enqueueTracks(reusedTracks)
                enrichmentTrackIDs = affectedTrackIDs
            } else {
                enrichmentTrackIDs = newTrackIDs
            }
            do {
                let warnings = try await self.importEnrichmentService.waitForEnrichment(
                    for: enrichmentTrackIDs
                )
                await self.libraryViewModel.syncVisibleStateFromRepositoryAfterImport()
                values["enrichmentCompleted"] = .boolean(true)
                values["enrichmentWarnings"] = .array(warnings.map { .string($0) })
                self.operationCoordinator.recordResult(.object(values))
                self.operationCoordinator.recordCheckpoint("Import and enrichment complete")
            } catch is CancellationError {
                let cancelledEnrichmentIDs = retryEnrichment
                    ? affectedTrackIDs
                    : newTrackIDs
                await self.fileImportService.cancelEnrichment(for: cancelledEnrichmentIDs)
            } catch {
                self.operationCoordinator.recordPartialFailure("Enrichment failed: \(error)")
            }
        }, kind: .importFiles, retrySpec: .libraryImport(
            targetPlaylistID: playlistID,
            enrichmentPolicy: enrichmentPolicy.rawValue
        ))
        guard started else {
            ownedSelection.release()
            return nil
        }
        return operationCoordinator.taskDescriptors.last
    }

    /// Exports a portable, path-free Library snapshot while retaining the
    /// selected destination's security scope and this Library session until
    /// every media asset has been copied or reported unavailable.
    @discardableResult
    func startAutomationLibraryBundleExport(
        destinationDirectory: URL,
        destinationScopeStarted: Bool,
        revision: String,
        tracks: [LibraryBundleExportTrackInput],
        playlists: [LibraryBundleExportPlaylistInput]
    ) -> LibraryOperationTaskDescriptor? {
        guard !isClosed else {
            if destinationScopeStarted { destinationDirectory.stopAccessingSecurityScopedResource() }
            return nil
        }
        let started = operationCoordinator.start({ [weak self] in
            defer {
                if destinationScopeStarted {
                    destinationDirectory.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            do {
                let outcome = try await LibraryBundleExportService.export(
                    libraryID: self.context.id,
                    mode: self.context.mode.rawValue,
                    revision: revision,
                    destinationDirectory: destinationDirectory,
                    tracks: tracks,
                    playlists: playlists,
                    progress: { [weak self] completed, total, phase in
                        self?.operationCoordinator.recordProgress(
                            completedCount: completed,
                            totalCount: total,
                            phase: phase
                        )
                    }
                )
                self.operationCoordinator.recordResult(.object([
                    "libraryID": .string(self.context.id.uuidString),
                    "outputDirectory": .string(outcome.outputDirectory.path),
                    "trackCount": .number(Double(outcome.trackCount)),
                    "playlistCount": .number(Double(outcome.playlistCount)),
                    "copiedFileCount": .number(Double(outcome.copiedFileCount)),
                    "copiedBytes": .number(Double(outcome.copiedBytes)),
                    "failures": .array(outcome.failures.map(AutomationJSONValue.string))
                ]))
                for failure in outcome.failures.prefix(50) {
                    self.operationCoordinator.recordPartialFailure(failure)
                }
                self.operationCoordinator.recordCheckpoint("Library bundle export complete")
            } catch is CancellationError {
                self.operationCoordinator.recordCheckpoint("Library bundle export cancelled")
            } catch {
                self.operationCoordinator.recordPartialFailure("Library bundle export failed")
            }
        }, kind: .libraryBundleExport)
        guard started else {
            if destinationScopeStarted { destinationDirectory.stopAccessingSecurityScopedResource() }
            return nil
        }
        return operationCoordinator.taskDescriptors.last
    }

    /// Writes ID3 tags on staged MP3 copies, verifies each copy, then atomically
    /// replaces the matching file. The App Job serializes work with other
    /// Library operations and rechecks Track revisions immediately before each
    /// file mutation.
    @discardableResult
    func startAutomationEmbeddedTagWrite(
        requests: [MP3EmbeddedTagService.WriteRequest]
    ) -> LibraryOperationTaskDescriptor? {
        guard !isClosed else { return nil }
        let started = operationCoordinator.start({ [weak self] in
            guard let self else { return }
            var updatedTrackIDs: [UUID] = []
            var conflictedTrackIDs: [UUID] = []
            var failedTrackIDs: [UUID] = []
            for (index, request) in requests.enumerated() {
                guard !Task.isCancelled else { break }
                guard let track = self.libraryViewModel.allTracks.first(where: { $0.id == request.trackID }),
                      self.libraryViewModel.automationTrackRevision(for: track) == request.expectedTrackRevision else {
                    conflictedTrackIDs.append(request.trackID)
                    self.operationCoordinator.recordPartialFailure(
                        "\(request.trackID.uuidString): metadata changed before embedded-tag write",
                        itemID: request.trackID
                    )
                    self.operationCoordinator.recordProgress(
                        completedCount: index + 1,
                        totalCount: requests.count,
                        phase: "writing embedded tags"
                    )
                    continue
                }
                do {
                    let writeTask = Task.detached(priority: .utility) {
                        _ = try MP3EmbeddedTagService.patch(at: request.fileURL, fields: request.fields)
                    }
                    try await withTaskCancellationHandler {
                        try await writeTask.value
                    } onCancel: {
                        writeTask.cancel()
                    }
                    updatedTrackIDs.append(request.trackID)
                    self.operationCoordinator.recordCheckpoint("wrote embedded tags \(request.trackID.uuidString)")
                } catch {
                    failedTrackIDs.append(request.trackID)
                    self.operationCoordinator.recordPartialFailure(
                        "\(request.trackID.uuidString): \(MP3EmbeddedTagService.publicMessage(for: error))",
                        itemID: request.trackID
                    )
                }
                self.operationCoordinator.recordProgress(
                    completedCount: index + 1,
                    totalCount: requests.count,
                    phase: "writing embedded tags"
                )
            }
            let cancelled = Task.isCancelled
            self.operationCoordinator.recordResult(.object([
                "updatedTrackIDs": .array(updatedTrackIDs.map { .string($0.uuidString) }),
                "conflictedTrackIDs": .array(conflictedTrackIDs.map { .string($0.uuidString) }),
                "failedTrackIDs": .array(failedTrackIDs.map { .string($0.uuidString) }),
                "cancelled": .boolean(cancelled),
                "completedCount": .number(Double(updatedTrackIDs.count + conflictedTrackIDs.count + failedTrackIDs.count)),
                "totalCount": .number(Double(requests.count))
            ]))
            self.operationCoordinator.recordCheckpoint(
                cancelled ? "embedded-tag write cancelled" : "embedded-tag write complete"
            )
        }, kind: .embeddedTagWrite)
        guard started else { return nil }
        return operationCoordinator.taskDescriptors.last
    }

    /// Starts an automation-owned referenced Source import without keeping the
    /// IPC request blocked on file scanning, duplicate resolution, enrichment
    /// or index writes. The picker selection is retained until the operation
    /// reaches a terminal state, while the caller receives the Job descriptor
    /// immediately after authorization succeeds.
    @discardableResult
    func startAutomationInitialImport(
        selection: LibraryInitialImportSelection,
        playlistID: UUID? = nil
    ) -> LibraryOperationTaskDescriptor? {
        guard !isClosed, context.mode == .referenced else { return nil }
        let ownedSelection = selection.retainedCopy()
        let started = operationCoordinator.start({ [weak self] in
            defer { ownedSelection.release() }
            guard let self else { return }

            let result: LibraryInitialImportResult
            do {
                result = try await self.importInitialSelection(ownedSelection)
            } catch LibraryInitialImportError.initialImportFailed(let partialResult) {
                await self.finishAutomationInitialImport(
                    partialResult,
                    playlistID: playlistID
                )
                return
            } catch {
                self.operationCoordinator.recordPartialFailure(
                    "Source import failed: \(String(describing: error))"
                )
                return
            }

            await self.finishAutomationInitialImport(
                result,
                playlistID: playlistID
            )
        }, kind: .importFiles)
        guard started else {
            ownedSelection.release()
            return nil
        }
        return operationCoordinator.taskDescriptors.last
    }

    private func finishAutomationInitialImport(
        _ result: LibraryInitialImportResult,
        playlistID: UUID?
    ) async {
        operationCoordinator.recordProgress(
            completedCount: result.imported,
            totalCount: max(result.planned, result.requested),
            phase: "source import"
        )
        for failure in result.failures.prefix(50) {
            operationCoordinator.recordPartialFailure(
                "\(failure.url.path): \(failure.message)"
            )
        }
        if result.failures.count > 50 {
            operationCoordinator.recordPartialFailure(
                "\(result.failures.count - 50) additional Source import failures"
            )
        }

        guard let playlistID, !result.sourceIDs.isEmpty,
              let referencedSourceReconciler else { return }
        do {
            try await referencedSourceReconciler.bindSourcesToPlaylist(
                Set(result.sourceIDs),
                playlistID: playlistID,
                relativePath: nil
            )
            await libraryViewModel.reloadLibrary()
            operationCoordinator.recordCheckpoint("Source Playlist binding complete")
        } catch {
            operationCoordinator.recordPartialFailure(
                "Source Playlist binding failed: \(String(describing: error))"
            )
        }
    }

    /// Starts an automation-owned Source scan as a Job. Source scans can
    /// touch every file in a referenced directory, so they must not inherit
    /// the request lifetime of CLI/MCP callers.
    @discardableResult
    func startAutomationSourceRefresh(
        sourceID: UUID
    ) -> LibraryOperationTaskDescriptor? {
        guard !isClosed, context.mode == .referenced else { return nil }
        let started = operationCoordinator.start({ [weak self] in
            guard let self else { return }
            do {
                let issues = try await self.refreshReferencedSource(sourceID)
                self.operationCoordinator.recordProgress(
                    completedCount: 1,
                    totalCount: 1,
                    phase: "source scan"
                )
                for issue in issues {
                    self.operationCoordinator.recordPartialFailure(
                        "\(sourceID.uuidString): \(String(describing: issue))"
                    )
                }
                self.operationCoordinator.recordCheckpoint("Source scan complete")
            } catch is CancellationError {
                return
            } catch {
                self.operationCoordinator.recordPartialFailure(
                    "\(sourceID.uuidString): \(String(describing: error))"
                )
            }
        }, kind: .sourceScan, retrySpec: .sourceRefresh(sourceID: sourceID))
        guard started else { return nil }
        return operationCoordinator.taskDescriptors.last
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
                        _ = try await createPlaylistAndAddTracks(
                            name: entry.displayName,
                            tracks: tracks
                        )
                    }
                }

            case .individualFiles:
                let tracks = await importedTracks(for: entry, result: result)
                guard !tracks.isEmpty else { continue }
                let playlist = try await createPlaylistAndAddTracks(
                    name: automaticPlaylistName(for: entry, tracks: tracks),
                    tracks: tracks
                )
                if context.mode == .referenced {
                    let sourceIDs = Set(tracks.flatMap { track -> [UUID] in
                        guard case let .referenced(locator) = track.mediaLocator else { return [] }
                        return locator.allSourceMemberships.map(\.sourceID)
                    })
                    do {
                        try await referencedSourceReconciler?.bindSourcesToPlaylist(
                            sourceIDs,
                            playlistID: playlist.id
                        )
                    } catch {
                        do {
                            try await mutationCoordinator.run(
                                kind: .userLibraryMutation,
                                targetIDs: [playlist.id.uuidString]
                            ) {
                                try await self.repository.deletePlaylist(playlist)
                            }
                        } catch {
                            Log.error(
                                "[LibrarySession] failed to roll back automatic playlist \(playlist.id) after source binding failure: \(error.localizedDescription)",
                                category: .library
                            )
                        }
                        throw error
                    }
                }
            }
        }

        if context.mode == .referenced, !boundDirectorySourceIDs.isEmpty {
            try await referencedSourceReconciler?.createPlaylistsForSources(boundDirectorySourceIDs)
        }
    }

    /// Creates and populates an automatic playlist as one short durable
    /// mutation. If the item write fails, remove the newly-created empty
    /// playlist before returning the original error so setup cannot leave a
    /// half-created collection behind.
    private func createPlaylistAndAddTracks(
        name: String,
        tracks: [Track]
    ) async throws -> Playlist {
        var createdPlaylist: Playlist?
        try await mutationCoordinator.run(
            kind: .userLibraryMutation,
            targetIDs: tracks.map(\.id.uuidString)
        ) { [self] in
            let playlist = try await self.repository.createPlaylist(name: name)
            createdPlaylist = playlist
            do {
                try await self.repository.addTracks(tracks, to: playlist)
            } catch {
                do {
                    try await self.repository.deletePlaylist(playlist)
                } catch {
                    Log.error(
                        "[LibrarySession] failed to roll back automatic playlist \(playlist.id): \(error.localizedDescription)",
                        category: .library
                    )
                }
                throw error
            }
        }
        guard let createdPlaylist else {
            throw LibraryPlaylistPersistenceError.writeFailed(
                playlistID: UUID(),
                reason: "自动播放列表未返回稳定 ID"
            )
        }
        return createdPlaylist
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
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
            return issues
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
            throw error
        }
    }

    func refreshReferencedSource(_ sourceID: UUID) async throws -> [ReferencedSourceScopeIssue] {
        guard !isClosed,
              let referencedSourceReconciler,
              let libraryChangeMonitor else { return [] }
        let originalRoots = try await referencedSourceReconciler.monitoredSourceRoots()
        await libraryChangeMonitor.stopAndWait()
        do {
            let issues = try await referencedSourceReconciler.refreshSource(sourceID)
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
            await libraryViewModel.reloadLibrary()
            return issues
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: originalRoots
            )
            throw error
        }
    }

    func setReferencedSourceExcludedPath(
        sourceID: UUID,
        relativePath: String,
        excluded: Bool
    ) async throws {
        guard !isClosed,
              let referencedSourceReconciler,
              let libraryChangeMonitor else { return }
        let originalRoots = try await referencedSourceReconciler.monitoredSourceRoots()
        await libraryChangeMonitor.stopAndWait()
        do {
            try await referencedSourceReconciler.setExcludedRelativePath(
                sourceID: sourceID,
                relativePath: relativePath,
                excluded: excluded
            )
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
            await libraryViewModel.reloadLibrary()
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: originalRoots
            )
            throw error
        }
    }

    /// Changes whether filesystem events automatically reconcile one Source.
    /// Manual refresh remains available for `.off`; changing this policy only
    /// restarts the monitor and does not remove Track authority.
    func setReferencedSourceMonitorPolicy(
        sourceID: UUID,
        policy: ReferencedSourceMonitorPolicy
    ) async throws {
        guard !isClosed,
              let referencedSourceReconciler,
              let libraryChangeMonitor,
              let referencedSourceStore else { return }
        let originalRoots = try await referencedSourceReconciler.monitoredSourceRoots()
        let originalPolicy = try await referencedSourceStore.load(id: sourceID).monitorPolicy
        await libraryChangeMonitor.stopAndWait()
        do {
            _ = try await referencedSourceStore.updateMonitorPolicy(
                sourceID: sourceID,
                policy: policy
            )
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
        } catch {
            _ = try? await referencedSourceStore.updateMonitorPolicy(
                sourceID: sourceID,
                policy: originalPolicy
            )
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: originalRoots
            )
            throw error
        }
    }

    func removeReferencedSource(_ sourceID: UUID) async throws {
        guard !isClosed,
              let referencedSourceReconciler,
              let libraryChangeMonitor else { return }
        let originalRoots = try await referencedSourceReconciler.monitoredSourceRoots()
        await libraryChangeMonitor.stopAndWait()
        do {
            try await referencedSourceReconciler.removeSource(sourceID)
            try await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
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
        let originalRoots = try await referencedSourceReconciler.monitoredSourceRoots()
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
                roots: try await referencedSourceReconciler.monitoredSourceRoots()
            )
        } catch {
            try? await startReferencedSourceMonitor(
                libraryChangeMonitor,
                reconciler: referencedSourceReconciler,
                roots: try await sourceReconnectServiceRoots(
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
        var watchPathsBySource = roots.mapValues { [$0] }
        watchPathsBySource[libraryID] = libraryMonitorWatchPaths()

        try await monitor.start(
            sourceRoots: monitoredRoots,
            watchPathsBySource: watchPathsBySource,
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
            // The monitor is itself a session-owned lifecycle boundary:
            // `stopAndWait()` cancels and awaits this callback before a source
            // reconnect, library switch, or shutdown proceeds. Keeping the
            // callback out of the serial mutation coordinator also avoids a
            // stop/reconcile deadlock when a scan is already queued behind a
            // user-initiated source operation.
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
            watchPathsBySource: [libraryID: libraryMonitorWatchPaths()],
            eventFilter: { filter.shouldProcess($0) },
            initiallyDirty: false
        ) { [weak libraryViewModel] libraryIDs, _ in
            guard libraryIDs.contains(libraryID), let libraryViewModel else { return }
            await libraryViewModel.reloadLibrary()
        }
    }

    private func libraryMonitorWatchPaths() -> [URL] {
        let paths = [
            context.paths.tracksRootURL,
            context.paths.playlistsRootURL,
            context.paths.artistsRootURL,
            context.paths.albumsRootURL,
        ]
        let fileManager = FileManager.default
        guard paths.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            return [context.rootURL]
        }
        return paths
    }

    private func sourceReconnectServiceRoots(
        fallback: [UUID: URL],
        reconciler: ReferencedSourceReconciler
    ) async throws -> [UUID: URL] {
        let current = try await reconciler.monitoredSourceRoots()
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
        operationCoordinator.stopAcceptingNewOperations()
        await libraryChangeMonitor?.stopAndWait()
        await operationCoordinator.cancelAndWait()
        await fileImportService.quiesce()
        playerViewModel.stop()
        playerViewModel.stopLevelMeter()
        await importEnrichmentService.quiesce()
        await libraryService.quiesceAndWaitForBackgroundWrites()
        mutationCoordinator.stopAcceptingNewMutations()
        await mutationCoordinator.waitForDrain()
        libraryViewModel.prepareForSessionClose()
    }

    func close() async {
        guard !isClosed else { return }
        operationCoordinator.stopAcceptingNewOperations()
        await libraryChangeMonitor?.stopAndWait()
        await operationCoordinator.cancelAndWait()
        await fileImportService.quiesce()
        playerViewModel.stop()
        playerViewModel.stopLevelMeter()
        referencedSourceReconciler?.close()
        await importEnrichmentService.close()
        await libraryService.quiesceAndWaitForBackgroundWrites()
        mutationCoordinator.stopAcceptingNewMutations()
        await mutationCoordinator.waitForDrain()
        isClosed = true
        libraryViewModel.prepareForSessionClose()
        playbackCoordinator.close()
        await searchIndex.close()
        await storageBackend.close()
        await cacheServices.close()
        preferenceStatsService.clearCache()
        writerLease.release()
        rootAccessLease.release()
        isLoaded = false
    }
}

extension LibrarySession {
    /// Result of the switch-time first reconcile over every known source.
    struct InitialReconcileOutcome: Sendable, Equatable {
        struct SourceFailure: Sendable, Equatable {
            let sourceID: UUID
            let reason: String
        }

        let attemptedSourceIDs: Set<UUID>
        let failedSources: [SourceFailure]
        let startedAt: Date
        let finishedAt: Date

        var failedSourceIDs: Set<UUID> {
            Set(failedSources.map(\.sourceID))
        }

        var hasFailures: Bool {
            !failedSources.isEmpty
        }
    }
}

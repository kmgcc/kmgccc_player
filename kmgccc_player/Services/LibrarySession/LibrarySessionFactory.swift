import AVFoundation
import Foundation
import SwiftData

nonisolated enum LibrarySessionFactoryError: Error, Equatable {
    case manifestIdentityMismatch
    case manifestModeMismatch
    case missingReferencedSourceServices
}

@MainActor
final class LibrarySessionFactory: LibrarySessionBuilding {
    private let libraryRootBookmarkResolver: any BookmarkResolving
    private let sourceBookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool
    private let fileEventSourceFactory: @MainActor () -> any LibraryFileEventSource
    var referencedSourceNoticePublisher: any ReferencedSourceNoticePublishing

    init(
        libraryRootBookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        sourceBookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false,
        fileEventSourceFactory: @escaping @MainActor () -> any LibraryFileEventSource = {
            FSEventsLibraryFileEventSource()
        },
        referencedSourceNoticePublisher: any ReferencedSourceNoticePublishing = LogReferencedSourceNoticePublisher()
    ) {
        self.libraryRootBookmarkResolver = libraryRootBookmarkResolver
        self.sourceBookmarkResolver = sourceBookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
        self.fileEventSourceFactory = fileEventSourceFactory
        self.referencedSourceNoticePublisher = referencedSourceNoticePublisher
    }

    func makeSession(for context: LibraryContext) async throws -> any LibrarySessionLifecycle {
        let rootAccessLease = try LibraryRootAccessLease(
            context: context,
            resolver: libraryRootBookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        guard manifest.libraryID == context.id else {
            throw LibrarySessionFactoryError.manifestIdentityMismatch
        }
        guard manifest.mode == context.mode else {
            throw LibrarySessionFactoryError.manifestModeMismatch
        }

        // Acquire the single-writer boundary before migrations, SQLite setup,
        // source repair, or any sidecar writer can touch this Library root.
        let writerLease = try LibraryWriterLease.acquire(paths: context.paths)

        try context.paths.createRequiredDirectories()
        let mutationJournal = LibraryMutationJournal(
            paths: context.paths,
            libraryID: context.id
        )
        let recoveredMutations = try await mutationJournal.recoverInterruptedMutations()
        if !recoveredMutations.isEmpty {
            Log.warning(
                "[LibrarySession] recovered \(recoveredMutations.count) interrupted mutation intent(s) before reload",
                category: .library
            )
        }
        let mutationCoordinator = LibraryMutationCoordinator(
            libraryID: context.id,
            sessionGeneration: context.generation,
            journal: mutationJournal
        )

        let cacheServices = LibraryCacheServices(paths: context.paths)
        let modelContainer = try makeModelContainer(paths: context.paths)
        let preferenceStatsService = PreferenceStatsService()
        let libraryService = LocalLibraryService(
            paths: context.paths,
            preferenceStatsService: preferenceStatsService,
            mutationCoordinator: mutationCoordinator
        )
        let sourceStore: ReferencedSourceStore?
        let sourceScope: ReferencedSourceScope?
        if context.mode == .referenced {
            let store = ReferencedSourceStore(paths: context.paths)
            let scope = ReferencedSourceScope()
            let descriptors = try await store.loadAll()
            let issues = await scope.start(
                descriptors: descriptors,
                store: store,
                bookmarkResolver: sourceBookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
            if !issues.isEmpty {
                Log.warning(
                    "[LibrarySession] referenced sources unavailable count=\(issues.count)",
                    category: .library
                )
            }
            let scopedSettingsStore = LibraryScopedSettingsStore(paths: context.paths)
            if let scopedSettings = try? await scopedSettingsStore.load(),
               let trustedBookmark = scopedSettings.trustedAudioRootBookmarkData {
                do {
                    let configuration = try scope.configureTrustedAutomationRoot(
                        bookmarkData: trustedBookmark,
                        bookmarkResolver: sourceBookmarkResolver,
                        requiresSecurityScope: requiresSecurityScope
                    )
                    if let refreshedBookmarkData = configuration.refreshedBookmarkData {
                        try? await scopedSettingsStore.setTrustedAudioRoot(
                            bookmarkData: refreshedBookmarkData,
                            path: configuration.url.path
                        )
                    }
                } catch {
                    Log.warning(
                        "[LibrarySession] trusted automation root unavailable: \(error)",
                        category: .library
                    )
                }
            }
            sourceStore = store
            sourceScope = scope
        } else {
            sourceStore = nil
            sourceScope = nil
        }
        let playlistMembershipStore: ReferencedPlaylistMembershipStore? = context.mode == .referenced
            ? ReferencedPlaylistMembershipStore(paths: context.paths)
            : nil
        let storageBackend = try LibraryStorageBackendFactory.make(
            context: context,
            sourceStore: sourceStore,
            sourceScope: sourceScope,
            playlistMembershipStore: playlistMembershipStore,
            requiresSecurityScope: requiresSecurityScope
        )
        let searchIndex = LibrarySearchIndex(paths: context.paths)
        let detailHeaderArtworkResolver = DetailHeaderArtworkResolver(
            libraryService: libraryService
        )
        let repository = SwiftDataLibraryRepository(
            modelContext: modelContainer.mainContext,
            libraryService: libraryService,
            preferenceStatsService: preferenceStatsService,
            searchIndex: searchIndex,
            artworkDerivativeStore: cacheServices.artworkDerivativeStore,
            playlistArtworkPipeline: cacheServices.playlistArtworkPipeline,
            mutationCoordinator: mutationCoordinator
        )
        if let sourceStore, let playlistMembershipStore {
            do {
                let descriptors = try await sourceStore.loadAll()
                let playlists = await repository.fetchPlaylists()
                for descriptor in descriptors {
                    for binding in descriptor.playlistBindings {
                        guard let playlist = playlists.first(where: { $0.id == binding.playlistID }) else {
                            continue
                        }
                        let sourceTrackIDs = playlist.tracks.compactMap { track -> UUID? in
                            guard case let .referenced(locator) = track.mediaLocator,
                                  locator.containsSource(descriptor.id) else { return nil }
                            return track.id
                        }
                        let trackIDs = playlist.tracks.map(\.id)
                        try await playlistMembershipStore.migrateLegacy(
                            playlistID: playlist.id,
                            bindingID: binding.id,
                            trackIDs: trackIDs,
                            sourceTrackIDs: sourceTrackIDs,
                            legacyManagedTrackIDs: binding.legacyManagedTrackIDs ?? []
                        )
                    }
                }
            } catch {
                Log.warning(
                    "[LibrarySession] playlist membership migration deferred: \(error.localizedDescription)",
                    category: .library
                )
            }
        }
        let playbackHistoryStore = PlaybackHistoryStore(context: context)
        let playbackHistoryViewModel = PlaybackHistoryViewModel(
            preferenceStatsService: preferenceStatsService
        )
        let preferenceResetService = PreferenceResetService(
            preferenceStatsService: preferenceStatsService,
            playbackHistoryStore: playbackHistoryStore,
            paths: context.paths
        )
        let homeViewModel = HomeViewModel(
            preferenceStatsService: preferenceStatsService,
            paths: context.paths
        )
        let importEnrichmentService = ImportEnrichmentService(
            repository: repository,
            mutationCoordinator: mutationCoordinator,
            qqMusicCoverService: cacheServices.qqMusicCoverService,
            artistArtworkProviderCoordinator: cacheServices.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let ignoredItemsStore = sourceScope.map { _ in
            IgnoredReferencedItemsStore(paths: context.paths)
        }
        let operationCoordinator = LibraryOperationCoordinator(
            libraryID: context.id,
            sessionGeneration: context.generation,
            persistenceURL: context.paths.automationJobsURL
        )
        let ncmRegistry = sourceScope.map { _ in
            NCMConversionRegistry(paths: context.paths)
        }
        let referencedNCMConversionService = sourceScope.map {
            ReferencedNCMConversionService(
                paths: context.paths,
                sourceScope: $0,
                registry: ncmRegistry,
                parentAuthorizer: NCMParentDirectoryPanelAuthorizer(
                    bookmarkResolver: sourceBookmarkResolver,
                    requiresSecurityScope: requiresSecurityScope
                ),
                bookmarkResolver: sourceBookmarkResolver
            )
        }
        let fileImportService = FileImportService(
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: importEnrichmentService,
            storageBackend: storageBackend,
            operationCoordinator: operationCoordinator,
            mutationCoordinator: mutationCoordinator,
            referencedNCMConversionService: referencedNCMConversionService,
            ignoredItemsStore: ignoredItemsStore,
            qqMusicCoverService: cacheServices.qqMusicCoverService,
            artistArtworkProviderCoordinator: cacheServices.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService,
            libraryID: context.id,
            sessionGeneration: context.generation
        )
        let referencedSourceReconciler: ReferencedSourceReconciler?
        let sourceReconnectService: SourceReconnectService?
        let libraryChangeMonitor = LibraryChangeMonitor(eventSource: fileEventSourceFactory())
        if let sourceStore, let sourceScope, let ignoredItemsStore, let ncmRegistry {
            let ncmReservationFilter = NCMScanReservationFilter(registry: ncmRegistry)
            let scanner = ReferencedSourceScanner(paths: context.paths, isReserved: { url, identity in
                await ncmReservationFilter.isReserved(url: url, identity: identity)
            }, isIgnored: { fingerprint in
                do {
                    return try await ignoredItemsStore.contains(fingerprint)
                } catch {
                    Log.warning(
                        "[ReferencedSource] ignore lookup failed; conservatively skipping item",
                        category: .library
                    )
                    return true
                }
            })
            let reconciler = ReferencedSourceReconciler(
                context: context,
                repository: repository,
                importer: fileImportService,
                mutationCoordinator: mutationCoordinator,
                sourceStore: sourceStore,
                sourceScope: sourceScope,
                scanner: scanner,
                ignoredItemsStore: ignoredItemsStore,
                ncmRegistry: ncmRegistry,
                playlistMembershipStore: playlistMembershipStore,
                bookmarkResolver: sourceBookmarkResolver,
                requiresSecurityScope: requiresSecurityScope,
                noticePublisher: referencedSourceNoticePublisher
            )
            referencedSourceReconciler = reconciler
            sourceReconnectService = SourceReconnectService(
                context: context,
                repository: repository,
                sourceStore: sourceStore,
                sourceScope: sourceScope,
                reconciler: reconciler,
                bookmarkResolver: sourceBookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
        } else {
            referencedSourceReconciler = nil
            sourceReconnectService = nil
        }

        let libraryViewModel = LibraryViewModel(
            repository: repository,
            libraryService: libraryService,
            preferenceStatsService: preferenceStatsService,
            preferenceResetService: preferenceResetService,
            searchIndex: searchIndex,
            detailHeaderArtworkResolver: detailHeaderArtworkResolver,
            artistArtworkProviderCoordinator: cacheServices.artistArtworkProviderCoordinator,
            libraryID: context.id,
            sessionGeneration: context.generation
        )
        libraryViewModel.setImportService(fileImportService)
        libraryViewModel.onPlaylistDeletionCommit = { playlistID, commitPlaylist in
            try await storageBackend.commitPlaylistDeletion(
                playlistID: playlistID,
                commitPlaylist: commitPlaylist
            )
        }
        libraryViewModel.onManualPlaylistAdditionCommit = { playlistID, trackIDs, commitPlaylist in
            try await storageBackend.commitManualPlaylistAddition(
                playlistID: playlistID,
                trackIDs: trackIDs,
                commitPlaylist: commitPlaylist
            )
        }
        libraryViewModel.onManualPlaylistRemovalCommit = { playlistID, trackIDs, commitPlaylist in
            try await storageBackend.commitManualPlaylistRemoval(
                playlistID: playlistID,
                trackIDs: trackIDs,
                commitPlaylist: commitPlaylist
            )
        }
        if let sourceScope, let ignoredItemsStore, let ncmRegistry {
            let deletionService = ReferencedTrackDeletionService(
                context: context,
                sourceScope: sourceScope,
                ignoredItemsStore: ignoredItemsStore,
                ncmRegistry: ncmRegistry,
                bookmarkResolver: sourceBookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
            libraryViewModel.prepareTracksForDeletion = { tracks in
                await deletionService.prepareForAuthorityDeletion(tracks)
            }
        }
        if let sourceReconnectService {
            libraryViewModel.prepareTrackRelocationAction = { trackID, selectedURL in
                try await sourceReconnectService.prepareTrackRelocation(
                    trackID: trackID,
                    selectedURL: selectedURL
                )
            }
            libraryViewModel.relocateTrackAction = { proposal, confirmed in
                try await sourceReconnectService.relocateTrack(
                    proposal,
                    confirmedReplacement: confirmed
                )
            }
        }

        let smartPlaybackController = SmartPlaybackController(
            playbackHistoryStore: playbackHistoryStore,
            preferenceStatsService: preferenceStatsService,
            libraryService: libraryService
        )
        let playbackService = AVAudioPlaybackService(
            smartController: smartPlaybackController,
            libraryPaths: context.paths,
            authorizedSourceRootsProvider: sourceScope?.rootsProvider ?? AuthorizedSourceRootsProvider()
        )
        playbackService.onAudioLocatorResolved = { [weak repository] trackID, locator, availability in
            repository?.persistResolvedAudioLocator(
                trackID: trackID,
                locator: locator,
                availability: availability
            )
        }
        let ledMeterProvider = LEDMeterServiceProvider(
            config: LEDMeterConfig(
                ledCount: AppSettings.shared.ledCount,
                levels: AppSettings.shared.ledBrightnessLevels,
                cutoffHz: Float(AppSettings.shared.ledCutoffHz),
                sensitivity: AppSettings.shared.ledSensitivity,
                speed: Float(AppSettings.shared.ledSpeed),
                targetHz: AppSettings.shared.ledTargetHz
            )
        )
        let playerViewModel = PlayerViewModel(
            playbackService: playbackService,
            levelMeter: ledMeterProvider
        )
        let appleMusicAdapter = AppleMusicPlaybackAdapter(
            libraryTracksProvider: { [weak libraryViewModel] in libraryViewModel?.allTracks ?? [] },
            metadataStore: cacheServices.externalPlaybackMetadataStore,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let systemNowPlayingProvider = SystemNowPlayingProvider(
            libraryTracksProvider: { [weak libraryViewModel] in libraryViewModel?.allTracks ?? [] },
            metadataStore: cacheServices.externalPlaybackMetadataStore,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let playbackCoordinator = PlaybackCoordinator(
            localPlayback: playerViewModel,
            appleMusicAdapter: appleMusicAdapter,
            systemNowPlayingProvider: systemNowPlayingProvider,
            preferenceStatsService: preferenceStatsService,
            artworkCache: cacheServices.trackArtworkCache,
            meterProvider: ledMeterProvider,
            libraryTracksProvider: { [weak libraryViewModel] in libraryViewModel?.allTracks ?? [] }
        )
        let lyricsViewModel = LyricsViewModel(settings: AppSettings.shared)
        lyricsViewModel.setPlaybackSourceProvider { [weak playbackCoordinator] in
            playbackCoordinator?.activeSource ?? .local
        }

        libraryViewModel.currentTrackIDProvider = { [weak playerViewModel] in
            playerViewModel?.currentTrack?.id
        }
        libraryViewModel.onTracksDeleted = { [weak playerViewModel] deletedTrackIDs in
            guard let playerViewModel, !deletedTrackIDs.isEmpty else { return }
            if let currentTrackID = playerViewModel.currentTrack?.id,
               deletedTrackIDs.contains(currentTrackID) {
                playerViewModel.stop()
                return
            }
            let remainingQueue = playerViewModel.currentQueueTracks.filter {
                !deletedTrackIDs.contains($0.id)
            }
            guard remainingQueue.count != playerViewModel.currentQueueTracks.count else { return }
            if remainingQueue.isEmpty {
                playerViewModel.stop()
            } else {
                playerViewModel.updateQueueTracks(remainingQueue)
            }
        }

        let session = LibrarySession(
            context: context,
            rootAccessLease: rootAccessLease,
            writerLease: writerLease,
            modelContainer: modelContainer,
            cacheServices: cacheServices,
            repository: repository,
            libraryService: libraryService,
            preferenceStatsService: preferenceStatsService,
            preferenceResetService: preferenceResetService,
            searchIndex: searchIndex,
            playbackHistoryStore: playbackHistoryStore,
            playbackHistoryViewModel: playbackHistoryViewModel,
            homeViewModel: homeViewModel,
            libraryViewModel: libraryViewModel,
            importEnrichmentService: importEnrichmentService,
            fileImportService: fileImportService,
            operationCoordinator: operationCoordinator,
            mutationCoordinator: mutationCoordinator,
            storageBackend: storageBackend,
            referencedSourceStore: sourceStore,
            referencedSourceScope: sourceScope,
            referencedSourceReconciler: referencedSourceReconciler,
            sourceReconnectService: sourceReconnectService,
            libraryChangeMonitor: libraryChangeMonitor,
            playbackService: playbackService,
            playerViewModel: playerViewModel,
            playbackCoordinator: playbackCoordinator,
            lyricsViewModel: lyricsViewModel,
            ledMeterProvider: ledMeterProvider
        )
        session.bindLibraryViewModelOperationOwnership()
        return session
    }

    private func makeModelContainer(paths: LibraryPaths) throws -> ModelContainer {
        let schema = Schema([TrackIndexEntry.self])
        let configuration = ModelConfiguration(
            schema: schema,
            url: try TrackIndexStorePaths.prepareStoreURL(in: paths)
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

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
    private let sourceBookmarkResolver: any BookmarkResolving
    private let requiresSecurityScope: Bool
    private let fileEventSourceFactory: @MainActor () -> any LibraryFileEventSource

    init(
        sourceBookmarkResolver: any BookmarkResolving = SystemBookmarkResolver(),
        requiresSecurityScope: Bool = false,
        fileEventSourceFactory: @escaping @MainActor () -> any LibraryFileEventSource = {
            FSEventsLibraryFileEventSource()
        }
    ) {
        self.sourceBookmarkResolver = sourceBookmarkResolver
        self.requiresSecurityScope = requiresSecurityScope
        self.fileEventSourceFactory = fileEventSourceFactory
    }

    func makeSession(for context: LibraryContext) async throws -> any LibrarySessionLifecycle {
        let rootAccessLease = try LibraryRootAccessLease(
            context: context,
            resolver: sourceBookmarkResolver,
            requiresSecurityScope: requiresSecurityScope
        )
        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        guard manifest.libraryID == context.id else {
            throw LibrarySessionFactoryError.manifestIdentityMismatch
        }
        guard manifest.mode == context.mode else {
            throw LibrarySessionFactoryError.manifestModeMismatch
        }

        try context.paths.createRequiredDirectories()
        let cacheServices = LibraryCacheServices(paths: context.paths)
        let modelContainer = try makeModelContainer(paths: context.paths)
        let preferenceStatsService = PreferenceStatsService()
        let libraryService = LocalLibraryService(
            paths: context.paths,
            preferenceStatsService: preferenceStatsService
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
            sourceStore = store
            sourceScope = scope
        } else {
            sourceStore = nil
            sourceScope = nil
        }
        let storageBackend = try LibraryStorageBackendFactory.make(
            context: context,
            sourceStore: sourceStore,
            sourceScope: sourceScope,
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
            playlistArtworkPipeline: cacheServices.playlistArtworkPipeline
        )
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
            qqMusicCoverService: cacheServices.qqMusicCoverService,
            artistArtworkProviderCoordinator: cacheServices.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let referencedNCMConversionService = sourceScope.map {
            ReferencedNCMConversionService(
                paths: context.paths,
                sourceScope: $0,
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
            referencedNCMConversionService: referencedNCMConversionService,
            qqMusicCoverService: cacheServices.qqMusicCoverService,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let referencedSourceReconciler: ReferencedSourceReconciler?
        let libraryChangeMonitor: LibraryChangeMonitor?
        if let sourceStore, let sourceScope {
            let ncmReservationFilter = NCMScanReservationFilter(
                registry: NCMConversionRegistry(paths: context.paths)
            )
            let scanner = ReferencedSourceScanner(paths: context.paths, isReserved: { url, identity in
                await ncmReservationFilter.isReserved(url: url, identity: identity)
            })
            referencedSourceReconciler = ReferencedSourceReconciler(
                context: context,
                repository: repository,
                importer: fileImportService,
                sourceStore: sourceStore,
                sourceScope: sourceScope,
                scanner: scanner,
                bookmarkResolver: sourceBookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
            libraryChangeMonitor = LibraryChangeMonitor(eventSource: fileEventSourceFactory())
        } else {
            referencedSourceReconciler = nil
            libraryChangeMonitor = nil
        }

        let libraryViewModel = LibraryViewModel(
            repository: repository,
            libraryService: libraryService,
            preferenceStatsService: preferenceStatsService,
            preferenceResetService: preferenceResetService,
            searchIndex: searchIndex,
            detailHeaderArtworkResolver: detailHeaderArtworkResolver,
            artistArtworkProviderCoordinator: cacheServices.artistArtworkProviderCoordinator
        )
        libraryViewModel.setImportService(fileImportService)
        if let sourceScope {
            let deletionService = ReferencedTrackDeletionService(
                context: context,
                sourceScope: sourceScope,
                bookmarkResolver: sourceBookmarkResolver,
                requiresSecurityScope: requiresSecurityScope
            )
            libraryViewModel.prepareTracksForDeletion = { tracks in
                await deletionService.prepareForAuthorityDeletion(tracks)
            }
        }

        let smartPlaybackController = SmartPlaybackController(
            playbackHistoryStore: playbackHistoryStore,
            preferenceStatsService: preferenceStatsService,
            libraryService: libraryService
        )
        let playbackService = AVAudioPlaybackService(
            smartController: smartPlaybackController,
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
            ),
            mixerProvider: { [weak playbackService] in
                playbackService?.analysisMixerNode ?? AVAudioEngine().mainMixerNode
            }
        )
        let playerViewModel = PlayerViewModel(
            playbackService: playbackService,
            levelMeter: ledMeterProvider
        )
        let appleMusicAdapter = AppleMusicPlaybackAdapter(
            libraryVM: libraryViewModel,
            metadataStore: cacheServices.externalPlaybackMetadataStore,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let systemNowPlayingProvider = SystemNowPlayingProvider(
            libraryVM: libraryViewModel,
            metadataStore: cacheServices.externalPlaybackMetadataStore,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService
        )
        let playbackCoordinator = PlaybackCoordinator(
            playerVM: playerViewModel,
            appleMusicAdapter: appleMusicAdapter,
            systemNowPlayingProvider: systemNowPlayingProvider,
            preferenceStatsService: preferenceStatsService,
            artworkCache: cacheServices.trackArtworkCache,
            lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
            amllDBService: cacheServices.amllDBService,
            meterProvider: ledMeterProvider
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

        return LibrarySession(
            context: context,
            rootAccessLease: rootAccessLease,
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
            storageBackend: storageBackend,
            referencedSourceStore: sourceStore,
            referencedSourceScope: sourceScope,
            referencedSourceReconciler: referencedSourceReconciler,
            libraryChangeMonitor: libraryChangeMonitor,
            playbackService: playbackService,
            playerViewModel: playerViewModel,
            playbackCoordinator: playbackCoordinator,
            lyricsViewModel: lyricsViewModel,
            ledMeterProvider: ledMeterProvider
        )
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

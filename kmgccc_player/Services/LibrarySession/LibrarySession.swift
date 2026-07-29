import Foundation
import SwiftData

@MainActor
final class LibrarySession: LibrarySessionLifecycle {
    let context: LibraryContext
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
    let playerViewModel: PlayerViewModel
    let playbackCoordinator: PlaybackCoordinator
    let lyricsViewModel: LyricsViewModel
    let ledMeterProvider: LEDMeterServiceProvider

    private let playbackService: AVAudioPlaybackService
    private var isLoaded = false
    private var isClosed = false

    init(
        context: LibraryContext,
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
        playbackService: AVAudioPlaybackService,
        playerViewModel: PlayerViewModel,
        playbackCoordinator: PlaybackCoordinator,
        lyricsViewModel: LyricsViewModel,
        ledMeterProvider: LEDMeterServiceProvider
    ) {
        self.context = context
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
        libraryService.startMonitoring(repository: repository)
        isLoaded = true
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
        playerViewModel.stop()
        playerViewModel.stopLevelMeter()
        libraryViewModel.prepareForSessionClose()
        libraryService.stopMonitoring()
        let trackIDs = Set(libraryViewModel.allTracks.map(\.id))
        await importEnrichmentService.cancelEnrichment(for: trackIDs)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        libraryViewModel.prepareForSessionClose()
        libraryService.stopMonitoring()
        playbackCoordinator.close()
        await searchIndex.close()
        await storageBackend.close()
        await cacheServices.close()
        preferenceStatsService.clearCache()
        isLoaded = false
    }
}

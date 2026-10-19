import Foundation
import Observation

@Observable
@MainActor
final class LibraryCacheServices {
    static let preview = LibraryCacheServices(
        paths: LibraryPaths(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("kmgccc-player-preview-library", isDirectory: true)
        )
    )

    nonisolated let storageLocations: LibraryStorageLocations
    let trackArtworkCache: TrackArtworkCache
    let headerColorExtractor: HeaderColorExtractor
    /// Shared provider services used by both the interactive cover editor and
    /// App-owned automation artwork search.
    let coverDownloadService: CoverDownloadService
    let netEaseCoverService: NetEaseCoverService
    let qqMusicCoverService: QQMusicCoverService
    let artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator
    let amllDBRawIndexCache: AMLLDBRawIndexCache
    let amllDBService: AMLLDBService
    let lyricsSearchCoordinator: LyricsSearchCoordinator
    let externalPlaybackMetadataStore: ExternalPlaybackMetadataStore
    let artworkDerivativeStore: ArtworkDerivativeCacheStore
    let playlistArtworkPipeline: PlaylistArtworkPipeline

    @ObservationIgnored
    private weak var backgroundScheduler: BackgroundWorkScheduler?
    @ObservationIgnored
    private var backgroundOwner: BackgroundWorkOwner = .app
    @ObservationIgnored
    private(set) var artworkColorSource: ArtworkColorWorkSource?
    @ObservationIgnored
    private(set) var missingPlaylistArtworkSource: MissingPlaylistArtworkWorkSource?
    @ObservationIgnored
    private(set) var pageThumbnailSource: PageThumbnailWorkSource?

    init(paths: LibraryPaths) {
        let storage = StorageLocations.scoped(to: paths)
        self.storageLocations = storage
        self.trackArtworkCache = TrackArtworkCache(storage: storage)
        self.headerColorExtractor = HeaderColorExtractor(storage: storage)
        self.coverDownloadService = CoverDownloadService()
        self.netEaseCoverService = NetEaseCoverService()
        self.qqMusicCoverService = QQMusicCoverService(cacheRootURL: storage.qqMusicCoverCacheURL)
        self.artistArtworkProviderCoordinator = ArtistArtworkProviderCoordinator(
            qqMusicCoverService: qqMusicCoverService
        )
        self.amllDBRawIndexCache = AMLLDBRawIndexCache(cacheDirectory: storage.amllDBCacheURL)
        self.amllDBService = AMLLDBService(cache: amllDBRawIndexCache)
        self.lyricsSearchCoordinator = LyricsSearchCoordinator(amlldbService: amllDBService)
        self.externalPlaybackMetadataStore = ExternalPlaybackMetadataStore(storage: storage)
        self.artworkDerivativeStore = ArtworkDerivativeCacheStore(diskRootURL: storage.playlistArtworkDerivativesURL)
        self.playlistArtworkPipeline = PlaylistArtworkPipeline(derivativeStore: artworkDerivativeStore)
    }

    func close() async {
        detachBackgroundSources()
        amllDBService.close()
        amllDBRawIndexCache.close()
        await trackArtworkCache.clearMemory()
        headerColorExtractor.clearMemory()
        await artworkDerivativeStore.clearMemory()
        await playlistArtworkPipeline.clearMemory()
    }

    /// Connects the library's caches to the App scheduler, so prefetches run as
    /// upcoming work owned by this library session.
    func bindBackgroundWork(scheduler: BackgroundWorkScheduler, owner: BackgroundWorkOwner) {
        backgroundScheduler = scheduler
        backgroundOwner = owner
        amllDBRawIndexCache.bindBackgroundWork(scheduler: scheduler, owner: owner)
    }

    /// Runs a cover prefetch as upcoming work. Nil when the library is not
    /// bound to a scheduler yet, in which case the cover loads when it is shown.
    @discardableResult
    func submitArtworkPrefetch(
        domain: BackgroundWorkDomain,
        resources: BackgroundWorkResources = [.compute],
        operation: @escaping @Sendable (BackgroundWorkContext) async -> Void
    ) -> BackgroundTaskHandle? {
        guard let scheduler = backgroundScheduler else { return nil }
        return scheduler.submitWork(
            owner: backgroundOwner,
            domain: domain,
            priority: .upcoming,
            resources: resources,
            operation: operation
        )
    }

    /// Registers the library's artwork accent colours as a backlog of the App
    /// scheduler. The scheduler pulls batches as idle work when the machine is
    /// quiet, whether or not the App is in front; the source follows the
    /// library, so added songs join the pass.
    func attachArtworkColorSource(
        scheduler: BackgroundWorkScheduler,
        owner: BackgroundWorkOwner,
        libraryID: UUID,
        trackIDs: @escaping @MainActor () -> [UUID],
        revision: @escaping @MainActor () -> Int,
        sources: @escaping @MainActor ([UUID]) -> [TrackArtworkSource],
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        if let existing = artworkColorSource {
            scheduler.unregister(sourceID: existing.sourceID)
        }
        let source = ArtworkColorWorkSource(
            libraryID: libraryID,
            owner: owner,
            artworkCache: trackArtworkCache,
            trackIDs: trackIDs,
            revision: revision,
            sources: sources,
            isEnabled: isEnabled
        )
        backgroundScheduler = scheduler
        artworkColorSource = source
        scheduler.register(source)
    }

    /// Registers the playlists that still lack a saved cover as a backlog of
    /// the App scheduler, so their covers are made in idle time.
    func attachMissingPlaylistArtworkSource(
        scheduler: BackgroundWorkScheduler,
        owner: BackgroundWorkOwner,
        libraryID: UUID,
        playlists: @escaping @MainActor () -> [Playlist],
        lacksCover: @escaping @MainActor (Playlist) -> Bool,
        generate: @escaping @MainActor (UUID, TaskPriority) async -> Bool,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        if let existing = missingPlaylistArtworkSource {
            scheduler.unregister(sourceID: existing.sourceID)
        }
        let source = MissingPlaylistArtworkWorkSource(
            libraryID: libraryID,
            owner: owner,
            playlists: playlists,
            lacksCover: lacksCover,
            generate: generate,
            isEnabled: isEnabled
        )
        backgroundScheduler = scheduler
        missingPlaylistArtworkSource = source
        scheduler.register(source)
    }

    /// Registers the Home page's album and artist thumbnails as a backlog of
    /// the App scheduler, made in idle time at the sizes the page asks for.
    func attachPageThumbnailSource(
        scheduler: BackgroundWorkScheduler,
        owner: BackgroundWorkOwner,
        libraryID: UUID,
        candidates: @escaping @MainActor () -> [PageThumbnailCandidate],
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        if let existing = pageThumbnailSource {
            scheduler.unregister(sourceID: existing.sourceID)
        }
        let source = PageThumbnailWorkSource(
            libraryID: libraryID,
            owner: owner,
            derivativeStore: artworkDerivativeStore,
            candidates: candidates,
            isEnabled: isEnabled
        )
        backgroundScheduler = scheduler
        pageThumbnailSource = source
        scheduler.register(source)
    }

    func detachBackgroundSources() {
        if let source = artworkColorSource {
            backgroundScheduler?.unregister(sourceID: source.sourceID)
        }
        artworkColorSource = nil
        if let source = pageThumbnailSource {
            backgroundScheduler?.unregister(sourceID: source.sourceID)
        }
        pageThumbnailSource = nil
        if let source = missingPlaylistArtworkSource {
            backgroundScheduler?.unregister(sourceID: source.sourceID)
        }
        missingPlaylistArtworkSource = nil
    }
}

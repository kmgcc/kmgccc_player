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
    private weak var artworkColorPrefetchScheduler: BackgroundWorkScheduler?
    @ObservationIgnored
    private var artworkColorPrefetchKey: String?

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
        cancelArtworkColorPrefetch()
        amllDBService.close()
        amllDBRawIndexCache.close()
        await trackArtworkCache.clearMemory()
        headerColorExtractor.clearMemory()
        await artworkDerivativeStore.clearMemory()
        await playlistArtworkPipeline.clearMemory()
    }

    /// Queues artwork accent-colour preparation as idle batch work. When it
    /// runs is decided by the App scheduler (power, load, interaction), not
    /// by whether the App is in front; it pauses at track boundaries.
    func prefetchArtworkColors(
        trackIDs: [UUID],
        libraryID: UUID,
        scheduler: BackgroundWorkScheduler,
        sources: @escaping @MainActor @Sendable ([UUID]) -> [TrackArtworkSource],
        shouldContinue: @escaping @MainActor @Sendable () -> Bool
    ) {
        guard !trackIDs.isEmpty else { return }
        let key = "artwork-colors:\(libraryID.uuidString)"
        artworkColorPrefetchScheduler = scheduler
        artworkColorPrefetchKey = key
        let artworkCache = trackArtworkCache
        scheduler.submit(
            key: key,
            group: "artwork:\(libraryID.uuidString)",
            priority: .idleBatch,
            resources: [.cpu, .diskRead]
        ) { context in
            for startIndex in stride(from: 0, to: trackIDs.count, by: 24) {
                guard (try? await context.checkpoint()) != nil else { return }
                let batchIDs = Array(trackIDs[startIndex..<min(startIndex + 24, trackIDs.count)])
                let batch = await MainActor.run { shouldContinue() ? sources(batchIDs) : nil }
                guard let batch else { return }
                for source in batch {
                    guard (try? await context.checkpoint()) != nil else { return }
                    _ = await artworkCache.artworkAccentColor(
                        for: source,
                        purpose: "idle-artwork-color",
                        priority: .background
                    )
                }
            }
        }
    }

    func cancelArtworkColorPrefetch() {
        if let key = artworkColorPrefetchKey { artworkColorPrefetchScheduler?.cancel(key: key) }
        artworkColorPrefetchKey = nil
    }
}

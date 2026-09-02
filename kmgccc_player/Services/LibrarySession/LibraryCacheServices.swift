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
    let qqMusicCoverService: QQMusicCoverService
    let artistArtworkProviderCoordinator: ArtistArtworkProviderCoordinator
    let amllDBRawIndexCache: AMLLDBRawIndexCache
    let amllDBService: AMLLDBService
    let lyricsSearchCoordinator: LyricsSearchCoordinator
    let externalPlaybackMetadataStore: ExternalPlaybackMetadataStore
    let artworkDerivativeStore: ArtworkDerivativeCacheStore
    let playlistArtworkPipeline: PlaylistArtworkPipeline

    init(paths: LibraryPaths) {
        let storage = StorageLocations.scoped(to: paths)
        self.storageLocations = storage
        self.trackArtworkCache = TrackArtworkCache(storage: storage)
        self.headerColorExtractor = HeaderColorExtractor(storage: storage)
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
        amllDBService.close()
        amllDBRawIndexCache.close()
        await trackArtworkCache.clearMemory()
        headerColorExtractor.clearMemory()
        await artworkDerivativeStore.clearMemory()
        await playlistArtworkPipeline.clearMemory()
    }
}

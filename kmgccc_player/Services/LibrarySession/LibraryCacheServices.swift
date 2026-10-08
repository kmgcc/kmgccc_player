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
    private var artworkColorPrefetchTask: Task<Void, Never>?
    @ObservationIgnored
    private var artworkColorPrefetchGeneration: UInt64 = 0

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

    func prefetchArtworkColorsWhenIdle(
        from tracks: [Track],
        shouldContinue: @escaping @MainActor () -> Bool
    ) {
        cancelArtworkColorPrefetch()
        guard !tracks.isEmpty else { return }

        artworkColorPrefetchGeneration &+= 1
        let generation = artworkColorPrefetchGeneration
        let artworkCache = trackArtworkCache
        artworkColorPrefetchTask = Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.artworkColorPrefetchGeneration == generation {
                    self.artworkColorPrefetchTask = nil
                }
            }

            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  self.artworkColorPrefetchGeneration == generation,
                  shouldContinue()
            else { return }

            for startIndex in stride(from: 0, to: tracks.count, by: 24) {
                guard !Task.isCancelled,
                      self.artworkColorPrefetchGeneration == generation,
                      shouldContinue()
                else { return }
                let endIndex = min(startIndex + 24, tracks.count)

                for track in tracks[startIndex..<endIndex] {
                    guard !Task.isCancelled,
                          self.artworkColorPrefetchGeneration == generation,
                          shouldContinue()
                    else { return }
                    guard let source = track.trackArtworkSource() else { continue }
                    _ = await artworkCache.artworkAccentColor(
                        for: source,
                        purpose: "idle-artwork-color",
                        priority: .background
                    )
                    await Task.yield()
                }

                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    func cancelArtworkColorPrefetch() {
        artworkColorPrefetchGeneration &+= 1
        artworkColorPrefetchTask = nil
    }
}

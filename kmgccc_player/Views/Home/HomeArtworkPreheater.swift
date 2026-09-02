//
//  HomeArtworkPreheater.swift
//  myPlayer2
//
//  Bounded artwork preheating for the Home page.
//

import AppKit
import Foundation

@MainActor
final class HomeArtworkMemoryStore {
    static let shared = HomeArtworkMemoryStore()

    private var cache = CostBoundedCache<String, NSImage>(
        countLimit: 256,
        totalCostLimit: 64 * 1024 * 1024
    )

    func cachedImage(for key: String) -> NSImage? {
        cache.value(forKey: key)
    }

    func store(_ image: NSImage, for key: String) {
        cache.insert(image, forKey: key, cost: Self.estimatedCost(for: image))
    }

    func clearMemory() {
        cache.removeAll()
    }

    static func heroCoverKey(for track: Track) -> String {
        trackKey(prefix: "hero-cover", track: track, pixelSide: 480)
    }

    static func albumKey(for album: AlbumEntry, pixelSide: Int) -> String {
        "album|\(album.id.uuidString)|\(album.updatedAt.timeIntervalSince1970)|\(album.artworkFileName ?? "fallback")|\(pixelSide)"
    }

    static func artistKey(for artist: ArtistEntry, pixelSide: Int) -> String {
        "artist|\(artist.id.uuidString)|\(artist.updatedAt.timeIntervalSince1970)|\(artist.artworkFileName ?? "generated")|\(pixelSide)"
    }

    static func rankKey(trackID: UUID, pixelSide: Int) -> String {
        "rank|\(trackID.uuidString)|\(pixelSide)"
    }

    static func rankPixelSide(for logicalSide: CGFloat) -> Int {
        max(68, Int(ceil(logicalSide * 2)))
    }

    static func playlistPreviewKey(trackID: UUID) -> String {
        "playlist-preview|\(trackID.uuidString)|\(HomeArtworkPreheatConstants.playlistPreviewPixelSide)"
    }

    static func playlistHeaderKey(identity: String) -> String {
        "playlist-header|\(identity)"
    }

    private static func trackKey(prefix: String, track: Track, pixelSide: Int) -> String {
        "\(prefix)|\(track.id.uuidString)|\(track.artworkFileName ?? "embedded")|\(ArtworkDataFingerprint.sampledString(for: track.artworkData))|\(pixelSide)"
    }

    private static func estimatedCost(for image: NSImage) -> Int {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        let width = max(1, Int(ceil(image.size.width)))
        let height = max(1, Int(ceil(image.size.height)))
        return width * height * 4
    }
}

@MainActor
final class HomeArtworkPreheater {
    static let shared = HomeArtworkPreheater()

    private var task: Task<Void, Never>?
    private var lastSignature: String?

    func schedule(
        heroTrack: Track?,
        albums: [AlbumEntry],
        artists: [ArtistEntry],
        playlists: [Playlist],
        preferenceRanking: [HomeViewModel.PreferenceRankItem],
        libraryVM: LibraryViewModel,
        playlistArtworkPipeline: PlaylistArtworkPipeline,
        artworkDerivativeStore: ArtworkDerivativeCacheStore,
        mode: HomeLayoutMode,
        sectionOrder: [HomeSection]
    ) {
        let snapshot = makeSnapshot(
            heroTrack: heroTrack,
            albums: albums,
            artists: artists,
            playlists: playlists,
            preferenceRanking: preferenceRanking,
            libraryVM: libraryVM,
            mode: mode,
            sectionOrder: sectionOrder
        )
        guard snapshot.signature != lastSignature else { return }
        lastSignature = snapshot.signature

        let playlistPlans = makePlaylistHeaderPlans(
            playlists: playlists,
            libraryVM: libraryVM
        )
        let artworkResolver = libraryVM.detailHeaderArtworkResolver
        task?.cancel()
        task = Task(priority: .utility) {
            let token = FirstUseHitchDiagnostics.begin(
                "HomeArtworkPreheat",
                detail: snapshot.diagnosticDetail
            )
            let workerTask = Task.detached(priority: .utility) {
                await HomeArtworkPreheatWorker.run(
                    snapshot,
                    derivativeStore: artworkDerivativeStore
                )
            }
            await preheatPlaylistHeaders(
                playlistPlans,
                artworkResolver: artworkResolver,
                pipeline: playlistArtworkPipeline
            )
            await workerTask.value
            FirstUseHitchDiagnostics.end(token)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func makeSnapshot(
        heroTrack: Track?,
        albums: [AlbumEntry],
        artists: [ArtistEntry],
        playlists: [Playlist],
        preferenceRanking: [HomeViewModel.PreferenceRankItem],
        libraryVM: LibraryViewModel,
        mode: HomeLayoutMode,
        sectionOrder: [HomeSection]
    ) -> HomeArtworkPreheatSnapshot {
        let albumLimit = mode == .wide || mode == .medium ? 10 : 8
        let artistLimit = mode == .wide || mode == .medium ? 10 : 8
        let playlistLimit = mode == .wide || mode == .medium ? 10 : 8
        let rankLimit = mode == .wide || mode == .medium ? 10 : 8

        let albumPixelSide = mode.homeAlbumRailPixelSide
        let artistPixelSide = mode.homeArtistRailPixelSide
        let rankPixelSide = HomeArtworkMemoryStore.rankPixelSide(for: 34)

        let hero = heroTrack.map {
            HomeTrackArtworkPreheatCandidate(
                id: $0.id,
                displayKey: HomeArtworkMemoryStore.heroCoverKey(for: $0),
                artworkData: $0.artworkData,
                artworkURL: $0.resolvedArtworkURL(),
                pixelSide: 480
            )
        }

        let albumCandidates = albums.prefix(albumLimit).map { album in
            HomeAlbumArtworkPreheatCandidate(
                id: album.id,
                displayKey: HomeArtworkMemoryStore.albumKey(for: album, pixelSide: albumPixelSide),
                artworkData: album.artworkData,
                fallbackTrack: libraryVM.firstTrack(forAlbumGroupKey: album.canonicalKey).map {
                    HomeRawArtworkCandidate(track: $0)
                },
                pixelSide: albumPixelSide
            )
        }

        let allTracks = libraryVM.allTracks
        let artistCandidates = artists.prefix(artistLimit).map { artist in
            let sources: [ArtistArtworkTrackSource]
            if artist.artworkData?.isEmpty == false {
                sources = []
            } else {
                sources = allTracks
                    .filter { LibraryNormalization.containsArtist(artist.canonicalName, in: $0) }
                    .prefix(24)
                    .map { $0.artistArtworkSource() }
            }
            return HomeArtistArtworkPreheatCandidate(
                id: artist.id,
                displayName: artist.displayName,
                displayKey: HomeArtworkMemoryStore.artistKey(for: artist, pixelSide: artistPixelSide),
                artworkData: artist.artworkData,
                trackSources: sources,
                pixelSide: artistPixelSide
            )
        }

        let playlistPreviewTracks = playlists
            .prefix(playlistLimit)
            .flatMap { playlist in
                HomePlaylistPreviewCache.shared.previewTracks(
                    for: playlist,
                    limit: Self.playlistPreviewLimit(for: mode),
                    preferenceStats: { libraryVM.preferenceStats(for: $0) }
                )
            }
        var seenPreviewTrackIDs = Set<UUID>()
        let playlistPreviewCandidates = playlistPreviewTracks.compactMap { track -> HomeTrackArtworkPreheatCandidate? in
            guard seenPreviewTrackIDs.insert(track.id).inserted else { return nil }
            return HomeTrackArtworkPreheatCandidate(
                id: track.id,
                displayKey: HomeArtworkMemoryStore.playlistPreviewKey(trackID: track.id),
                artworkData: track.artworkData,
                artworkURL: track.resolvedArtworkURL(),
                pixelSide: HomeArtworkPreheatConstants.playlistPreviewPixelSide
            )
        }

        let rankCandidates = preferenceRanking.prefix(rankLimit).map { item in
            HomeTrackArtworkPreheatCandidate(
                id: item.id,
                displayKey: HomeArtworkMemoryStore.rankKey(trackID: item.id, pixelSide: rankPixelSide),
                artworkData: item.track.artworkData,
                artworkURL: item.track.resolvedArtworkURL(),
                pixelSide: rankPixelSide
            )
        }

        var signatureParts: [String] = [
            "mode:\(mode)",
            "order:\(sectionOrder.map(\.rawValue).joined(separator: ","))",
        ]
        if let hero { signatureParts.append("hero:\(hero.id)") }
        signatureParts.append("albums:\(albumCandidates.map(\.id.uuidString).joined(separator: ","))")
        signatureParts.append("artists:\(artistCandidates.map(\.id.uuidString).joined(separator: ","))")
        signatureParts.append("playlists:\(playlists.prefix(playlistLimit).map { $0.id.uuidString }.joined(separator: ","))")
        signatureParts.append("rank:\(rankCandidates.map(\.id.uuidString).joined(separator: ","))")

        return HomeArtworkPreheatSnapshot(
            signature: signatureParts.joined(separator: "|"),
            hero: hero,
            albums: albumCandidates,
            artists: artistCandidates,
            playlistPreviews: playlistPreviewCandidates,
            rankItems: rankCandidates,
            diagnosticDetail: "albums=\(albumCandidates.count), artists=\(artistCandidates.count), playlistPreviews=\(playlistPreviewCandidates.count), rank=\(rankCandidates.count)"
        )
    }

    private func makePlaylistHeaderPlans(
        playlists: [Playlist],
        libraryVM: LibraryViewModel
    ) -> [HomePlaylistHeaderPreheatPlan] {
        playlists.prefix(8).map { playlist in
            let identity = Self.playlistHeaderIdentity(
                for: playlist,
                revision: libraryVM.playlistArtworkRevision(playlistID: playlist.id)
            )
            return HomePlaylistHeaderPreheatPlan(
                identity: identity,
                request: DetailHeaderArtworkRequest.playlist(
                    selectionIdentity: "playlist-\(playlist.id)",
                    playlistID: playlist.id,
                    tracks: playlist.tracks
                )
            )
        }
    }

    private func preheatPlaylistHeaders(
        _ plans: [HomePlaylistHeaderPreheatPlan],
        artworkResolver: DetailHeaderArtworkResolver,
        pipeline: PlaylistArtworkPipeline
    ) async {
        guard !plans.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(120))
        for plan in plans {
            guard !Task.isCancelled else { return }
            let key = HomeArtworkMemoryStore.playlistHeaderKey(identity: plan.identity)
            if HomeArtworkMemoryStore.shared.cachedImage(for: key) != nil { continue }

            let immediate = artworkResolver.resolveImmediately(for: plan.request)
            if let image = await loadPlaylistHeaderImage(
                from: immediate,
                identity: plan.identity,
                pipeline: pipeline
            ) {
                HomeArtworkMemoryStore.shared.store(image, for: key)
                HomePlaylistCardCoverStore.shared.store(image, for: plan.identity)
                continue
            }

            let resolved = await artworkResolver.resolveDeferredArtwork(for: plan.request)
            if let image = await loadPlaylistHeaderImage(
                from: resolved,
                identity: plan.identity,
                pipeline: pipeline
            ) {
                HomeArtworkMemoryStore.shared.store(image, for: key)
                HomePlaylistCardCoverStore.shared.store(image, for: plan.identity)
            }
        }
    }

    private func loadPlaylistHeaderImage(
        from resolved: ResolvedHeaderArtwork?,
        identity: String,
        pipeline: PlaylistArtworkPipeline
    ) async -> NSImage? {
        guard let resolved else { return nil }
        let request = PlaylistArtworkPipeline.headerRequest(
            artworkIdentity: identity,
            artworkData: resolved.image?.tiffRepresentation,
            fileURL: resolved.fileURL
        )
        return await pipeline.load(request) ?? resolved.image
    }

    static func playlistHeaderIdentity(for playlist: Playlist, revision: String?) -> String {
        let selectionIdentity = "playlist-\(playlist.id)"
        if let revision, !revision.isEmpty {
            return "\(selectionIdentity)-artwork-\(revision)"
        }
        let signature = PlaylistArtworkGenerator.contentSignature(tracks: playlist.tracks)
        return "\(selectionIdentity)-unresolved-\(signature)"
    }

    private static func playlistPreviewLimit(for mode: HomeLayoutMode) -> Int {
        switch mode {
        case .wide, .medium: return 5
        case .compact, .narrow: return 4
        }
    }
}

private enum HomeArtworkPreheatConstants {
    static let playlistPreviewPixelSide = 96
}

private struct HomePlaylistHeaderPreheatPlan {
    let identity: String
    let request: DetailHeaderArtworkRequest
}

private struct HomeArtworkPreheatSnapshot: Sendable {
    let signature: String
    let hero: HomeTrackArtworkPreheatCandidate?
    let albums: [HomeAlbumArtworkPreheatCandidate]
    let artists: [HomeArtistArtworkPreheatCandidate]
    let playlistPreviews: [HomeTrackArtworkPreheatCandidate]
    let rankItems: [HomeTrackArtworkPreheatCandidate]
    let diagnosticDetail: String
}

private struct HomeRawArtworkCandidate: Sendable {
    let id: UUID
    let artworkData: Data?
    let artworkURL: URL?

    @MainActor
    init(track: Track) {
        id = track.id
        artworkData = track.artworkData
        artworkURL = track.resolvedArtworkURL()
    }
}

private struct HomeTrackArtworkPreheatCandidate: Sendable {
    let id: UUID
    let displayKey: String
    let artworkData: Data?
    let artworkURL: URL?
    let pixelSide: Int
}

private struct HomeAlbumArtworkPreheatCandidate: Sendable {
    let id: UUID
    let displayKey: String
    let artworkData: Data?
    let fallbackTrack: HomeRawArtworkCandidate?
    let pixelSide: Int
}

private struct HomeArtistArtworkPreheatCandidate: Sendable {
    let id: UUID
    let displayName: String
    let displayKey: String
    let artworkData: Data?
    let trackSources: [ArtistArtworkTrackSource]
    let pixelSide: Int
}

private enum HomeArtworkPreheatWorker {
    static func run(
        _ snapshot: HomeArtworkPreheatSnapshot,
        derivativeStore: ArtworkDerivativeCacheStore
    ) async {
        if let hero = snapshot.hero {
            await preheatTrack(hero, derivativeStore: derivativeStore)
        }
        for album in snapshot.albums {
            guard !Task.isCancelled else { return }
            await preheatAlbum(album, derivativeStore: derivativeStore)
        }
        for artist in snapshot.artists {
            guard !Task.isCancelled else { return }
            await preheatArtist(artist, derivativeStore: derivativeStore)
        }
        for preview in snapshot.playlistPreviews {
            guard !Task.isCancelled else { return }
            await preheatTrack(preview, derivativeStore: derivativeStore)
        }
        for item in snapshot.rankItems {
            guard !Task.isCancelled else { return }
            await preheatTrack(item, derivativeStore: derivativeStore)
        }
    }

    private static func preheatAlbum(
        _ candidate: HomeAlbumArtworkPreheatCandidate,
        derivativeStore: ArtworkDerivativeCacheStore
    ) async {
        let data: Data?
        if let artworkData = candidate.artworkData, !artworkData.isEmpty {
            data = artworkData
        } else if let fallbackData = candidate.fallbackTrack?.artworkData, !fallbackData.isEmpty {
            data = fallbackData
        } else {
            data = await readData(from: candidate.fallbackTrack?.artworkURL)
        }
        await preheatImage(
            id: candidate.id,
            displayKey: candidate.displayKey,
            artworkData: data,
            pixelSide: candidate.pixelSide,
            derivativeStore: derivativeStore
        )
    }

    private static func preheatArtist(
        _ candidate: HomeArtistArtworkPreheatCandidate,
        derivativeStore: ArtworkDerivativeCacheStore
    ) async {
        if let data = candidate.artworkData, !data.isEmpty {
            await preheatImage(
                id: candidate.id,
                displayKey: candidate.displayKey,
                artworkData: data,
                pixelSide: candidate.pixelSide,
                derivativeStore: derivativeStore
            )
            return
        }

        guard let image = await ArtistArtworkGenerator.shared.generateArtwork(
            artistName: candidate.displayName,
            trackSources: candidate.trackSources,
            pixelSide: candidate.pixelSide
        ) else { return }

        await MainActor.run {
            HomeArtworkMemoryStore.shared.store(image, for: candidate.displayKey)
        }
    }

    private static func preheatTrack(
        _ candidate: HomeTrackArtworkPreheatCandidate,
        derivativeStore: ArtworkDerivativeCacheStore
    ) async {
        let data: Data?
        if let artworkData = candidate.artworkData, !artworkData.isEmpty {
            data = artworkData
        } else {
            data = await readData(from: candidate.artworkURL)
        }
        await preheatImage(
            id: candidate.id,
            displayKey: candidate.displayKey,
            artworkData: data,
            pixelSide: candidate.pixelSide,
            derivativeStore: derivativeStore
        )
    }

    private static func preheatImage(
        id: UUID,
        displayKey: String,
        artworkData: Data?,
        pixelSide: Int,
        derivativeStore: ArtworkDerivativeCacheStore
    ) async {
        guard let artworkData, !artworkData.isEmpty else { return }
        let targetSize = CGSize(width: pixelSide, height: pixelSide)
        let checksum = ArtworkLoader.checksum(for: artworkData)
        let cacheKey = ArtworkLoader.cacheKey(
            trackID: id,
            checksum: checksum,
            targetPixelSize: targetSize
        )
        guard let image = await ArtworkLoader.loadImage(
            artworkData: artworkData,
            cacheKey: cacheKey,
            targetPixelSize: targetSize,
            derivativeStore: derivativeStore
        ) else { return }

        await MainActor.run {
            HomeArtworkMemoryStore.shared.store(image, for: displayKey)
        }
    }

    private static func readData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }
}

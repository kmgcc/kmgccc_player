import XCTest
@testable import kmgccc_player

private actor AlbumMotionClient: MusicEnrichmentFetching {
    private(set) var downloads = 0
    func fetch(provider: String, query: MusicEnrichmentQuery) async throws -> MusicEnrichmentResult? { nil }
    func materialize(_ descriptor: MotionArtworkDescriptor, destination: URL) async throws -> MusicEnrichmentHelperClient.MaterializedMotion {
        downloads += 1
        try await Task.sleep(for: .milliseconds(10))
        try Data("movie".utf8).write(to: destination)
        return .init(path: destination.path, startTime: 0, duration: 8)
    }
}

@MainActor
final class MusicEnrichmentAlbumMotionTests: XCTestCase {
    private func query(_ title: String, artist: String = "Artist", catalog: String? = nil) -> MusicEnrichmentQuery {
        MusicEnrichmentQuery(key: "track:\(UUID())", title: title, artist: artist, album: "Album", duration: 100,
            appleAlbumID: catalog, albumArtist: "Album artist")
    }

    func testConcurrentAlbumSongsDownloadOneFileAndPersistSharedDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root.appendingPathComponent("Enrichment"))
        let client = AlbumMotionClient()
        let service = MusicEnrichmentService(store: store, client: client)
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "https://example.com/album.m3u8")
        let first = MusicEnrichmentRecord(query: query("First", catalog: "123"))
        let second = MusicEnrichmentRecord(query: query("Second", artist: "Guest"))
        async let a = service.automaticMotion(descriptor, for: first)
        async let b = service.automaticMotion(descriptor, for: second)
        let (firstAsset, secondAsset) = try await (a, b)
        XCTAssertEqual(firstAsset, secondAsset)
        let count = await client.downloads
        XCTAssertEqual(count, 1)
        let resolved = try await store.resolveMotion(in: second)
        XCTAssertEqual(resolved.assets, [try XCTUnwrap(firstAsset)])
        XCTAssertEqual(resolved.albumMotionIdentity, "apple:123")
        let reference = TrackMotionArtwork(snapshot: await store.snapshot(resolved))
        XCTAssertNotNil(reference.resource(kind: "square", libraryRootURL: root))
        let firstRead = try await service.loadSnapshot(for: second.query)
        let nextRead = try await service.loadSnapshot(for: second.query)
        XCTAssertEqual(firstRead?.record.updatedAt, nextRead?.record.updatedAt)
        await service.close()
    }

    func testLegacyAutomaticAssetMigratesButManualDisableWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root.appendingPathComponent("Enrichment"))
        let temporary = root.appendingPathComponent("original.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("legacy-video".utf8).write(to: temporary)
        var legacy = MusicEnrichmentRecord(query: query("Legacy"))
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "legacy-video")
        let legacyAsset = try await store.importMotion(from: temporary, descriptor: descriptor,
            startTime: 0, duration: 7, queryKey: legacy.query.key, fileExtension: "mov")
        legacy.assets = [try XCTUnwrap(legacyAsset)]
        let migrated = try await store.resolveMotion(in: legacy)
        XCTAssertTrue(migrated.assets[0].relativePath.hasPrefix("AlbumAssets/"))
        XCTAssertTrue(migrated.assets[0].relativePath.hasSuffix(".mov"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
        var disabled = MusicEnrichmentRecord(query: query("Disabled"))
        disabled.manualMotionSelection = .init(source: "manual", motion: [])
        let override = try await store.resolveMotion(in: disabled)
        XCTAssertTrue(override.assets.isEmpty)
        XCTAssertNil(override.albumMotionIdentity)
        await store.close()
    }

    func testSameTitleWithDifferentArtistsOrCatalogIDsDoesNotMerge() {
        var a = MusicEnrichmentRecord(query: query("One", catalog: "1"))
        var b = MusicEnrichmentRecord(query: query("Two", catalog: "2"))
        XCTAssertNotEqual(a.motionAlbumIdentity?.key, b.motionAlbumIdentity?.key)
        a.query.appleAlbumID = nil
        b.query.appleAlbumID = nil
        a.query.albumArtist = "First artist"
        b.query.albumArtist = "Second artist"
        XCTAssertNotEqual(a.motionAlbumIdentity?.key, b.motionAlbumIdentity?.key)
    }

    func testSongLevelMusicVideoDoesNotMigrateToAlbum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root.appendingPathComponent("Enrichment"))
        let temporary = root.appendingPathComponent("mv.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("mv-content".utf8).write(to: temporary)

        var songRecord = MusicEnrichmentRecord(query: query("SongWithMV", catalog: "album-1"))
        // song duration is 100s, video duration is 105s -> qualifies as MV
        let descriptor = MotionArtworkDescriptor(kind: "square", url: "song-mv")
        let mvAsset = try await store.importMotion(from: temporary, descriptor: descriptor,
            startTime: 0, duration: 105, queryKey: songRecord.query.key, fileExtension: "mov")
        songRecord.assets = [try XCTUnwrap(mvAsset)]

        let resolved = try await store.resolveMotion(in: songRecord)
        // Song keeps its own MV
        XCTAssertEqual(resolved.assets.count, 1)
        XCTAssertTrue(resolved.assets[0].relativePath.hasPrefix("Tracks/"))
        XCTAssertNil(resolved.albumMotionIdentity)

        // Album does NOT adopt the MV
        let albumState = try await store.albumMotionState(for: songRecord)
        XCTAssertEqual(albumState?.assets.isEmpty, true)

        // Sibling song in the same album does not receive the MV
        let sibling = MusicEnrichmentRecord(query: query("SiblingTrack", catalog: "album-1"))
        let resolvedSibling = try await store.resolveMotion(in: sibling)
        XCTAssertTrue(resolvedSibling.assets.isEmpty)
        XCTAssertNil(resolvedSibling.albumMotionIdentity)

        let client = AlbumMotionClient()
        let service = MusicEnrichmentService(store: store, client: client)
        let albumResource = try await service.albumMotionResource(for: songRecord.query)
        XCTAssertNil(albumResource)

        await service.close()
    }

    func testImportAlbumMotionRejectsMusicVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MusicEnrichmentStore(rootURL: root.appendingPathComponent("Enrichment"))
        let client = AlbumMotionClient()
        let service = MusicEnrichmentService(store: store, client: client)
        let songQuery = query("SongWithMV", catalog: "album-2")

        let candidate = MusicEnrichmentResult(source: "appleWeb", albumID: "album-2", motion: [
            MotionArtworkDescriptor(kind: "square", url: "https://example.com/square.m3u8")
        ])

        // AlbumMotionClient returns video with duration: 8. For song duration: 100, 8s is not an MV.
        // It succeeds.
        let success = try await service.setAlbumMotion(candidate, for: songQuery)
        XCTAssertTrue(success)

        await service.close()
    }
}

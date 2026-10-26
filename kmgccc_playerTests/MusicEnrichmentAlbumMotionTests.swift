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
}

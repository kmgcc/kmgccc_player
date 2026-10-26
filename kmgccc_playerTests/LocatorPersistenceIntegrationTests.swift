import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import kmgccc_player
import XCTest

@MainActor
final class LocatorPersistenceIntegrationTests: XCTestCase {
    func testReferencedMetaOnlyWritesCurrentSchemaAndPreservesLocator() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "testReferencedNarrowWrite"))

        let metaURL = fixture.paths.trackMetaURL(for: fixture.track.id)
        XCTAssertEqual(metaURL.deletingLastPathComponent().lastPathComponent, fixture.track.id.uuidString)
        let data = try Data(contentsOf: metaURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, kmgccc_player.TrackSidecar.currentSchemaVersion)
        let decoded = try fixture.decoder.decode(kmgccc_player.TrackSidecar.self, from: data)
        XCTAssertEqual(decoded.mediaLocator, fixture.locator)
        XCTAssertEqual(decoded.mediaLocator.referencedFile?.fileBookmarkData, Data([1, 2, 3]))
    }

    func testSchemaNineLayerFieldsRoundTripThroughWriter() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let digest = String(repeating: "c9d4", count: 16)
        let layeredLocator = kmgccc_player.TrackMediaLocator.referenced(
            kmgccc_player.ReferencedFileLocator(
                fileBookmarkData: Data([7, 8]),
                lastKnownPath: "/diagnostic-only/song.flac",
                primaryAudioProperties: kmgccc_player.TrackAudioProperties(format: "FLAC", sampleRateHz: 48_000),
                primaryContentDigest: digest,
                primaryAvailabilityRaw: kmgccc_player.TrackAvailability.available.rawValue
            )
        )
        fixture.track.mediaLocator = layeredLocator
        fixture.track.musicBrainzReleaseID = "mbid-9f2"
        fixture.track.embeddedMetadataSnapshot = kmgccc_player.EmbeddedMetadataSnapshot(
            title: "Embedded",
            releaseYear: 2026,
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "testSchemaNineLayers"))

        let decoded = try fixture.decoder.decode(
            kmgccc_player.TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: fixture.track.id))
        )
        XCTAssertEqual(decoded.schemaVersion, kmgccc_player.TrackSidecar.currentSchemaVersion)
        XCTAssertEqual(decoded.musicBrainzReleaseID, "mbid-9f2")
        XCTAssertEqual(decoded.embeddedMetadataSnapshot?.releaseYear, 2026)
        let persistedLocator = try XCTUnwrap(decoded.mediaLocator.referencedFile)
        XCTAssertEqual(persistedLocator.primaryContentDigest, digest)
        XCTAssertEqual(persistedLocator.locations[0].contentDigest, digest)
        XCTAssertTrue(fixture.track.contentDigestPresent)
    }

    func testMotionArtworkSurvivesMetadataEditsDiskManifestAndRepositoryReload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = makeMotionArtwork(track: fixture.track)
        fixture.track.motionArtwork = expected
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "seedMotionArtwork"))
        fixture.track.title = "Edited title"
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "editTitleKeepMotionArtwork"))

        let decoded = try fixture.decoder.decode(
            kmgccc_player.TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: fixture.track.id))
        )
        XCTAssertEqual(decoded.motionArtwork, expected)
        let scanner = kmgccc_player.LibraryDiskScanner(paths: fixture.paths)
        XCTAssertEqual(scanner.scanIncremental().trackMetas.first?.motionArtwork, expected)
        // The second pass restores CachedScannedTrackMeta from the manifest.
        XCTAssertEqual(scanner.scanIncremental().trackMetas.first?.motionArtwork, expected)

        let repository = kmgccc_player.SwiftDataLibraryRepository(
            libraryService: fixture.service,
            preferenceStatsService: fixture.preferenceStatsService
        )
        await repository.reloadFromLibrary()
        let restored = await repository.fetchTracks(ids: [fixture.track.id])
        XCTAssertEqual(restored.first?.motionArtwork, expected)
    }

    func testBackgroundSnapshotPersistsMotionAndResolvesFromCapturedLibraryRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = makeMotionArtwork(track: fixture.track)
        fixture.track.motionArtwork = expected
        let relativePath = try XCTUnwrap(expected.assets.first?.relativePath)
        let fileURL = fixture.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: fileURL)

        fixture.service.writeMetaOnlyInBackground(for: fixture.track, reason: "persistDownloadedMotion")
        await fixture.service.quiesceAndWaitForBackgroundWrites()

        let decoded = try fixture.decoder.decode(
            kmgccc_player.TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: fixture.track.id))
        )
        XCTAssertEqual(decoded.motionArtwork, expected)
        XCTAssertEqual(fixture.track.storedMotionArtworkResource?.url, fileURL)
        XCTAssertEqual(fixture.track.storedMotionArtworkResource?.startTime, 10)
        XCTAssertNil(fixture.track.tallStoredMotionArtworkResource)
        fixture.track.libraryRootSnapshot = fixture.root.appendingPathComponent("OtherLibrary").path
        XCTAssertNil(fixture.track.storedMotionArtworkResource)
    }

    func testSchemaNineWithoutMotionArtworkRemainsReadable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "legacyNoMotion"))
        let data = try Data(contentsOf: fixture.paths.trackMetaURL(for: fixture.track.id))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["motionArtwork"])
        let decoded = try fixture.decoder.decode(kmgccc_player.TrackSidecar.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 9)
        XCTAssertNil(decoded.motionArtwork)
        XCTAssertNil(decoded.artworkIsUserSelected)
    }

    func testArtworkChoiceSurvivesWritersManifestAndRepositoryReload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.track.artworkIsUserSelected = true
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "manualArtworkChoice"))
        fixture.service.writeMetaOnlyInBackground(for: fixture.track, reason: "keepManualArtworkChoice")
        await fixture.service.quiesceAndWaitForBackgroundWrites()
        let decoded = try fixture.decoder.decode(kmgccc_player.TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: fixture.track.id)))
        XCTAssertEqual(decoded.artworkIsUserSelected, true)
        let scanner = kmgccc_player.LibraryDiskScanner(paths: fixture.paths)
        XCTAssertEqual(scanner.scanIncremental().trackMetas.first?.artworkIsUserSelected, true)
        XCTAssertEqual(scanner.scanIncremental().trackMetas.first?.artworkIsUserSelected, true)
        let repository = kmgccc_player.SwiftDataLibraryRepository(libraryService: fixture.service,
            preferenceStatsService: fixture.preferenceStatsService)
        await repository.reloadFromLibrary()
        let restored = await repository.fetchTracks(ids: [fixture.track.id])
        XCTAssertEqual(restored.first?.artworkIsUserSelected, true)
    }

    func testPNGOriginalSurvivesBothArtworkWritersWithoutRewriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = encoded as Data
        fixture.track.artworkData = original
        fixture.track.artworkIsUserSelected = true
        XCTAssertTrue(fixture.service.writeTrackMetaAndArtwork(for: fixture.track, reason: "originalPNG"))
        let url = fixture.paths.trackFolderURL(for: fixture.track.id).appendingPathComponent("artwork.png")
        XCTAssertEqual(try Data(contentsOf: url), original)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        let snapshot = kmgccc_player.TrackPersistenceSnapshot(track: fixture.track, preferenceStats: kmgccc_player.TrackPreferenceStats())
        let result = kmgccc_player.LocalLibraryService.persistTrackSnapshotOnBackground(snapshot, paths: fixture.paths,
            mode: .metaAndArtwork, reason: "sameOriginalPNG")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.references?.artworkFileName, "artwork.png")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
    }

    func testRefreshedLocatorPersistsRuntimeAndSidecarTogether() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "seed"))
        let repository = kmgccc_player.SwiftDataLibraryRepository(
            libraryService: fixture.service,
            preferenceStatsService: fixture.preferenceStatsService
        )
        await repository.reloadFromLibrary()
        let refreshed = referencedLocator(bookmark: Data([9, 8, 7]))

        repository.persistResolvedAudioLocator(
            trackID: fixture.track.id,
            locator: refreshed,
            availability: .stale
        )

        let fetched = await repository.fetchTracks(ids: [fixture.track.id])
        let runtime = try XCTUnwrap(fetched.first)
        XCTAssertEqual(runtime.mediaLocator, refreshed)
        XCTAssertEqual(runtime.availability, .stale)
        let persisted = try fixture.decoder.decode(
            kmgccc_player.TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: fixture.track.id))
        )
        XCTAssertEqual(persisted.mediaLocator, refreshed)
        XCTAssertEqual(persisted.availability, .stale)
    }

    func testRefreshedLocatorFailureDoesNotMutateRuntime() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "seed"))
        let repository = kmgccc_player.SwiftDataLibraryRepository(
            libraryService: fixture.service,
            preferenceStatsService: fixture.preferenceStatsService
        )
        await repository.reloadFromLibrary()
        let fetchedBefore = await repository.fetchTracks(ids: [fixture.track.id])
        let runtimeBefore = try XCTUnwrap(fetchedBefore.first)
        let originalLocator = runtimeBefore.mediaLocator
        let originalAvailability = runtimeBefore.availability
        let metaURL = fixture.paths.trackMetaURL(for: fixture.track.id)
        let trackFolder = metaURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: trackFolder)
        try Data([0]).write(to: trackFolder)

        repository.persistResolvedAudioLocator(
            trackID: fixture.track.id,
            locator: referencedLocator(bookmark: Data([4, 5, 6])),
            availability: .stale
        )

        let fetchedAfter = await repository.fetchTracks(ids: [fixture.track.id])
        let runtimeAfter = try XCTUnwrap(fetchedAfter.first)
        XCTAssertEqual(runtimeAfter.mediaLocator, originalLocator)
        XCTAssertEqual(runtimeAfter.availability, originalAvailability)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))
        XCTAssertEqual(try Data(contentsOf: trackFolder), Data([0]))
    }

    /// An unreadable sidecar must not be treated as "no references": rewriting
    /// it from an empty reference set drops the artwork/lyrics/TTML pointers.
    func testMetaOnlyWriteRefusesToRewriteUndecodableSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "seed"))
        let metaURL = fixture.paths.trackMetaURL(for: fixture.track.id)
        let damaged = Data("not a sidecar".utf8)
        try damaged.write(to: metaURL, options: .atomic)

        XCTAssertFalse(fixture.service.writeMetaOnly(for: fixture.track, reason: "damagedSidecar"))
        XCTAssertEqual(try Data(contentsOf: metaURL), damaged)
    }

    /// A cover that exists on disk but cannot be read is not a cleared cover;
    /// the writer must keep it instead of deleting the user's file.
    func testArtworkWriteKeepsUnreadableCover() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try FileManager.default.createDirectory(
            at: fixture.paths.trackFolderURL(for: fixture.track.id),
            withIntermediateDirectories: true
        )
        let coverName = kmgccc_player.LibraryPaths.preferredTrackArtworkFileName
        let coverURL = try XCTUnwrap(
            fixture.paths.trackArtworkURL(for: fixture.track.id, fileName: coverName)
        )
        try Data([0xFF, 0xD8, 0xFF]).write(to: coverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: coverURL.path)
        fixture.track.artworkFileName = coverName
        fixture.track.artworkData = nil

        let writtenName = try fixture.service.writeArtworkIfChanged(
            for: fixture.track,
            reason: "unreadableCover",
            existingFileName: coverName
        )

        XCTAssertEqual(writtenName, coverName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))
    }

    func testMissingOrderingSidecarKeepsLegacyMigrationOpen() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sidecar = fixture.service.loadLibraryOrderingSidecar()

        XCTAssertFalse(sidecar.legacyUserDefaultsMigrationCompleted)
        XCTAssertNil(sidecar.allSongs)
    }

    func testCorruptOrderingSidecarDoesNotBorrowLegacyDefaults() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sidecarURL = fixture.paths.libraryOrderingURL
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: sidecarURL)

        let sidecar = fixture.service.loadLibraryOrderingSidecar()

        XCTAssertTrue(sidecar.legacyUserDefaultsMigrationCompleted)
        XCTAssertNil(sidecar.allSongs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    private func makeMotionArtwork(track: kmgccc_player.Track) -> kmgccc_player.TrackMotionArtwork {
        let query = kmgccc_player.MusicEnrichmentQuery(
            key: "local:\(track.id.uuidString)", title: track.title, artist: track.artist,
            album: track.album, duration: track.duration
        )
        var record = kmgccc_player.MusicEnrichmentRecord(query: query)
        record.assets = [kmgccc_player.StoredMotionArtwork(
            kind: "square", relativePath: "Tracks/\(track.id.uuidString)/motion-square.mp4",
            sourceURL: "https://mvod.itunes.apple.com/fixture.m3u8", startTime: 10,
            duration: 20, width: 768, height: 768
        )]
        record.manualMotionSelection = kmgccc_player.MusicEnrichmentResult(source: "appleWeb", albumID: "456")
        return kmgccc_player.TrackMotionArtwork(snapshot: kmgccc_player.MusicEnrichmentSnapshot(
            record: record, squareArtwork: nil, tallArtwork: nil
        ))
    }

    private func makeFixture() throws -> (
        root: URL,
        paths: kmgccc_player.LibraryPaths,
        service: kmgccc_player.LocalLibraryService,
        preferenceStatsService: kmgccc_player.PreferenceStatsService,
        track: kmgccc_player.Track,
        locator: kmgccc_player.TrackMediaLocator,
        decoder: JSONDecoder
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocatorPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        let preferenceStatsService = kmgccc_player.PreferenceStatsService()
        let service = kmgccc_player.LocalLibraryService(
            paths: paths,
            preferenceStatsService: preferenceStatsService
        )
        service.ensureLibraryFolders()
        let locator = referencedLocator(bookmark: Data([1, 2, 3]))
        let track = kmgccc_player.Track(
            title: "Referenced",
            artist: "Artist",
            album: "Album",
            duration: 42,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileBookmarkData: Data(),
            mediaLocator: locator,
            availability: .available,
            libraryRootSnapshot: root.path
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (root, paths, service, preferenceStatsService, track, locator, decoder)
    }

    private func referencedLocator(bookmark: Data) -> kmgccc_player.TrackMediaLocator {
        .referenced(kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: bookmark,
            lastKnownPath: "/diagnostic-only/song.flac"
        ))
    }
}

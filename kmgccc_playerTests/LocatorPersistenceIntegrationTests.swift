import Foundation
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

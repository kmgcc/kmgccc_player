import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class LocatorPersistenceIntegrationTests: XCTestCase {
    func testReferencedMetaOnlyWritesSchemaSevenAndPreservesLocator() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "testReferencedNarrowWrite"))

        let metaURL = fixture.paths.trackMetaURL(for: fixture.track.id)
        XCTAssertEqual(metaURL.deletingLastPathComponent().lastPathComponent, fixture.track.id.uuidString)
        let data = try Data(contentsOf: metaURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 7)
        let decoded = try fixture.decoder.decode(kmgccc_player.TrackSidecar.self, from: data)
        XCTAssertEqual(decoded.mediaLocator, fixture.locator)
        XCTAssertEqual(decoded.mediaLocator.referencedFile?.fileBookmarkData, Data([1, 2, 3]))
    }

    func testRefreshedLocatorPersistsRuntimeAndSidecarTogether() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(fixture.service.writeMetaOnly(for: fixture.track, reason: "seed"))
        let repository = kmgccc_player.SwiftDataLibraryRepository(libraryService: fixture.service)
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
        let repository = kmgccc_player.SwiftDataLibraryRepository(libraryService: fixture.service)
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
        track: kmgccc_player.Track,
        locator: kmgccc_player.TrackMediaLocator,
        decoder: JSONDecoder
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocatorPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        let service = kmgccc_player.LocalLibraryService(
            paths: paths,
            preferenceStatsService: .shared
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
        return (root, paths, service, track, locator, decoder)
    }

    private func referencedLocator(bookmark: Data) -> kmgccc_player.TrackMediaLocator {
        .referenced(kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: bookmark,
            lastKnownPath: "/diagnostic-only/song.flac"
        ))
    }
}

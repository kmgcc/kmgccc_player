import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class LibraryPathsTests: XCTestCase {
    func testAllLibraryOwnedPathsRemainUnderCapturedRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/A/kmgccc_player Library", isDirectory: true)
        let paths = LibraryPaths(rootURL: root)
        let trackID = UUID()
        let sourceID = UUID()
        let urls = paths.requiredDirectories + [
            paths.manifestURL,
            paths.librarySettingsURL,
            paths.upgradeJournalURL,
            paths.playbackHistoryStoreURL,
            paths.trackIndexStoreURL,
            paths.searchIndexStoreURL,
            paths.libraryScanManifestURL,
            paths.ignoredItemsURL,
            paths.ncmConversionsURL,
            paths.trackMetaURL(for: trackID),
            try XCTUnwrap(paths.trackArtworkURL(for: trackID, fileName: "artwork.jpg")),
            try XCTUnwrap(paths.trackLyricsURL(for: trackID, ext: "ttml")),
            paths.playlistURL(for: UUID()),
            paths.sourceDescriptorURL(for: sourceID),
            paths.sourceScanManifestURL(for: sourceID),
        ]

        XCTAssertTrue(urls.allSatisfy(paths.contains))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/tmp/B/Index/TrackIndex.sqlite")))
    }

    func testLibraryRelativePathRejectsTraversal() {
        let paths = LibraryPaths(
            rootURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        )

        XCTAssertEqual(
            paths.libraryURL(from: "Tracks/song/audio.flac")?.path,
            "/tmp/library/Tracks/song/audio.flac"
        )
        XCTAssertNil(paths.libraryURL(from: "../outside.flac"))
        XCTAssertNil(paths.libraryURL(from: "/tmp/outside.flac"))
    }

    func testTrackAssetNamesCannotEscapeTrackFolder() {
        let paths = LibraryPaths(
            rootURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        )
        let id = UUID()

        for unsafe in ["", ".", "..", "../outside", "folder/file", "folder\\file"] {
            XCTAssertNil(paths.trackArtworkURL(for: id, fileName: unsafe))
            XCTAssertNil(paths.trackLyricsURL(for: id, ext: unsafe))
        }
        XCTAssertNil(paths.trackArtworkURL(for: id, fileName: "/tmp/outside.jpg"))
    }

    func testContextsKeepIndependentImmutablePaths() {
        let first = LibraryContext(
            id: UUID(),
            mode: .managed,
            rootURL: URL(fileURLWithPath: "/tmp/one", isDirectory: true),
            rootBookmarkData: Data([1]),
            generation: 1
        )
        let second = LibraryContext(
            id: UUID(),
            mode: .referenced,
            rootURL: URL(fileURLWithPath: "/tmp/two", isDirectory: true),
            rootBookmarkData: Data([2]),
            generation: 2
        )

        XCTAssertEqual(first.paths.trackIndexStoreURL.path, "/tmp/one/Index/TrackIndex.sqlite")
        XCTAssertEqual(second.paths.trackIndexStoreURL.path, "/tmp/two/Index/TrackIndex.sqlite")
        XCTAssertNotEqual(first.paths.cacheRootURL, second.paths.cacheRootURL)
        XCTAssertTrue(first.isCurrent(generation: 1))
        XCTAssertFalse(first.isCurrent(generation: 2))
    }


    func testRequiredDirectoriesCanBeCreated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-path-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)

        try paths.createRequiredDirectories()

        for url in paths.requiredDirectories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testLibraryOrderingSidecarIsScopedAndRoundTrips() throws {
        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-ordering-first-\(UUID().uuidString)", isDirectory: true)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-ordering-second-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let firstPaths = kmgccc_player.LibraryPaths(rootURL: firstRoot)
        let firstService = kmgccc_player.LocalLibraryService(
            paths: firstPaths,
            preferenceStatsService: kmgccc_player.PreferenceStatsService()
        )
        let playlistID = UUID()
        let albumID = UUID()
        let artistID = UUID()
        let expected = kmgccc_player.LibraryOrderingSidecar(
            allSongs: kmgccc_player.LibraryTrackSortState(sortKey: "title", sortOrder: "ascending"),
            allPlaylists: kmgccc_player.LibraryCollectionSortState(
                sortKey: "custom",
                sortOrder: "descending",
                customItemOrder: [playlistID]
            ),
            allAlbums: kmgccc_player.LibraryCollectionSortState(
                sortKey: "updatedAt",
                sortOrder: "ascending",
                customItemOrder: [albumID]
            ),
            allArtists: kmgccc_player.LibraryCollectionSortState(
                sortKey: "name",
                sortOrder: "descending",
                customItemOrder: [artistID]
            ),
            legacyUserDefaultsMigrationCompleted: true
        )

        XCTAssertTrue(firstService.saveLibraryOrderingSidecar(expected))
        XCTAssertEqual(firstService.loadLibraryOrderingSidecar(), expected)
        XCTAssertEqual(
            firstPaths.libraryOrderingURL.path,
            firstRoot.appendingPathComponent("Settings/ordering.json").path
        )

        let secondService = kmgccc_player.LocalLibraryService(
            paths: kmgccc_player.LibraryPaths(rootURL: secondRoot),
            preferenceStatsService: kmgccc_player.PreferenceStatsService()
        )
        XCTAssertNotEqual(secondService.loadLibraryOrderingSidecar(), expected)
    }

    func testEntityMetadataWritesPreserveCustomTrackOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-entity-ordering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = kmgccc_player.LocalLibraryService(
            paths: kmgccc_player.LibraryPaths(rootURL: root),
            preferenceStatsService: kmgccc_player.PreferenceStatsService()
        )
        let trackIDs = [UUID(), UUID(), UUID()]
        let playlistID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try service.writePlaylistSidecar(
            playlistID: playlistID,
            name: "Playlist",
            description: "Before",
            createdAt: now,
            trackIDs: trackIDs,
            itemAddedAt: [:],
            customTrackOrder: [trackIDs[2], trackIDs[0], trackIDs[1]],
            trackSortKey: "custom",
            trackSortOrder: "ascending"
        )
        try service.writePlaylistSidecar(
            playlistID: playlistID,
            name: "Playlist edited",
            description: "After",
            createdAt: now,
            trackIDs: trackIDs,
            itemAddedAt: [:]
        )
        let playlist = try XCTUnwrap(service.loadPlaylistSidecar(playlistID: playlistID))
        XCTAssertEqual(playlist.trackSortKey, "custom")
        XCTAssertEqual(playlist.trackSortOrder, "ascending")
        XCTAssertEqual(playlist.customTrackOrder, [trackIDs[2], trackIDs[0], trackIDs[1]])

        let artistID = UUID()
        try service.writeArtistSidecar(
            kmgccc_player.ArtistSidecar(
                id: artistID,
                canonicalName: "artist",
                displayName: "Artist",
                description: "Artist description",
                createdAt: now,
                updatedAt: now,
                trackSortKey: "custom",
                trackSortOrder: "descending",
                customTrackOrder: [trackIDs[1], trackIDs[2], trackIDs[0]]
            ),
            artworkData: nil
        )
        try service.writeArtistSidecar(
            kmgccc_player.ArtistSidecar(
                id: artistID,
                canonicalName: "artist",
                displayName: "Artist edited",
                createdAt: now,
                updatedAt: now.addingTimeInterval(1)
            ),
            artworkData: nil
        )
        let artist = try XCTUnwrap(service.loadArtistSidecar(artistID: artistID))
        XCTAssertEqual(artist.trackSortKey, "custom")
        XCTAssertEqual(artist.trackSortOrder, "descending")
        XCTAssertEqual(artist.customTrackOrder, [trackIDs[1], trackIDs[2], trackIDs[0]])

        let albumID = UUID()
        try service.writeAlbumSidecar(
            kmgccc_player.AlbumSidecar(
                id: albumID,
                canonicalKey: "album|artist",
                displayTitle: "Album",
                primaryArtistCanonicalName: "artist",
                description: "Album description",
                createdAt: now,
                updatedAt: now,
                trackSortKey: "custom",
                trackSortOrder: "ascending",
                customTrackOrder: [trackIDs[0], trackIDs[2], trackIDs[1]]
            ),
            artworkData: nil
        )
        try service.writeAlbumSidecar(
            kmgccc_player.AlbumSidecar(
                id: albumID,
                canonicalKey: "album|artist",
                displayTitle: "Album edited",
                primaryArtistCanonicalName: "artist",
                createdAt: now,
                updatedAt: now.addingTimeInterval(1)
            ),
            artworkData: nil
        )
        let album = try XCTUnwrap(service.loadAlbumSidecar(albumID: albumID))
        XCTAssertEqual(album.trackSortKey, "custom")
        XCTAssertEqual(album.trackSortOrder, "ascending")
        XCTAssertEqual(album.customTrackOrder, [trackIDs[0], trackIDs[2], trackIDs[1]])
    }
}

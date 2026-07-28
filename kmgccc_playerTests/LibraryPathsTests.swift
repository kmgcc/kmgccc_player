import Foundation
import XCTest

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
}

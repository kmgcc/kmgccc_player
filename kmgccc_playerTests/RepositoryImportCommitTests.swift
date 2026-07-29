import Foundation
@testable import kmgccc_player
import XCTest

private final class SidecarWriteSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]
    var failingIDs: Set<UUID> = []

    func write(_ track: Track) -> Bool {
        lock.withLock { counts[track.id, default: 0] += 1 }
        return !failingIDs.contains(track.id)
    }

    func count(for id: UUID) -> Int { lock.withLock { counts[id, default: 0] } }
}

@MainActor
final class RepositoryImportCommitTests: XCTestCase {
    func testCommitWritesEachSidecarOnceAndAttachesOnlySuccessfulTracks() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let spy = SidecarWriteSpy()
        let success = makeTrack(title: "Success", root: fixture.paths.rootURL)
        let failure = makeTrack(title: "Failure", root: fixture.paths.rootURL)
        spy.failingIDs = [failure.id]
        let repository = fixture.makeRepository(importWriter: { track, _ in spy.write(track) })

        let result = await repository.commitImportedTracks([success, failure])

        XCTAssertEqual(result.persistedTrackIDs, [success.id])
        XCTAssertEqual(result.failedTrackIDs, [failure.id])
        XCTAssertEqual(spy.count(for: success.id), 1)
        XCTAssertEqual(spy.count(for: failure.id), 1)
        XCTAssertEqual(await repository.fetchTracks(in: nil).map(\.id), [success.id])
    }

    func testFailedMembershipMergeLeavesRuntimeLocatorAndPlaylistUntouched() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let sourceID = UUID()
        let original = ReferencedFileLocator(
            fileBookmarkData: Data("old".utf8),
            sourceMemberships: [],
            lastKnownPath: "/old",
            fingerprint: .init(fileSize: 1, modifiedAt: 1)
        )
        let track = makeTrack(title: "Existing", root: fixture.paths.rootURL, locator: original)
        let repository = fixture.makeRepository(
            importWriter: { _, _ in true },
            locatorWriter: { _, _, _ in false }
        )
        _ = await repository.commitImportedTracks([track])
        let playlist = await repository.createPlaylist(name: "Playlist")
        let incoming = ReferencedFileLocator(
            fileBookmarkData: Data("new".utf8),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: "song.mp3")],
            primarySourceID: sourceID,
            lastKnownPath: "/new",
            fingerprint: .init(fileSize: 1, modifiedAt: 1)
        )

        do {
            try await repository.mergeReferencedLocator(incoming, into: track)
            XCTFail("Expected sidecar failure")
        } catch {}

        XCTAssertEqual(track.mediaLocator, .referenced(original))
        XCTAssertTrue(playlist.tracks.isEmpty)
    }

    private func makeTrack(
        title: String,
        root: URL,
        locator: ReferencedFileLocator? = nil
    ) -> Track {
        let referenced = locator ?? ReferencedFileLocator(
            fileBookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/file",
            fingerprint: .init(fileSize: 1, modifiedAt: 1)
        )
        return Track(
            title: title,
            fileBookmarkData: referenced.fileBookmarkData,
            mediaLocator: .referenced(referenced),
            libraryRootSnapshot: root.path
        )
    }
}

@MainActor
private struct RepositoryFixture {
    let root: URL
    let paths: LibraryPaths
    let libraryService: LocalLibraryService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        libraryService = LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService())
    }

    func makeRepository(
        importWriter: @escaping (Track, String) -> Bool,
        locatorWriter: @escaping (Track, TrackMediaLocator, String) -> Bool = { _, _, _ in true }
    ) -> SwiftDataLibraryRepository {
        SwiftDataLibraryRepository(
            libraryService: libraryService,
            importSidecarWriter: importWriter,
            locatorSidecarWriter: locatorWriter
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

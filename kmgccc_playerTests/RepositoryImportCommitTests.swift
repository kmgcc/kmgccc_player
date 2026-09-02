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
        let tracks = await repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [success.id])
    }

    func testFailedMembershipMergeLeavesRuntimeLocatorAndPlaylistUntouched() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let sourceID = UUID()
        let original = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data("old".utf8),
            sourceMemberships: [],
            lastKnownPath: "/old",
            fingerprint: .init(fileSize: 1, modifiedAt: 1)
        )
        let track = makeTrack(title: "Existing", root: fixture.paths.rootURL, locator: original)
        let repository = fixture.makeRepository(
            importWriter: { _, _ in true },
            locatorWriter: { _, _, _, _ in false }
        )
        _ = await repository.commitImportedTracks([track])
        let playlist = try await repository.createPlaylist(name: "Playlist")
        let incoming = kmgccc_player.ReferencedFileLocator(
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

    func testSuccessfulMembershipMergeClearsStaleMissingAvailability() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let sourceID = UUID()
        let original = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data("old".utf8),
            sourceMemberships: [],
            lastKnownPath: "/old",
            fingerprint: .init(fileSize: 1, modifiedAt: 1)
        )
        let track = Track(
            title: "Existing",
            fileBookmarkData: original.fileBookmarkData,
            mediaLocator: .referenced(original),
            availability: .missing,
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        let repository = fixture.makeRepository(importWriter: { _, _ in true })
        _ = await repository.commitImportedTracks([track])

        let incoming = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data("new".utf8),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: "song.mp3")],
            primarySourceID: sourceID,
            lastKnownPath: "/new",
            fingerprint: .init(fileSize: 1, modifiedAt: 2)
        )

        try await repository.mergeReferencedLocator(incoming, into: track)

        XCTAssertEqual(track.availability, .available)
        XCTAssertTrue(track.isPlayable)
        XCTAssertEqual(track.mediaLocator.referencedFile?.lastKnownPath, "/new")
    }

    func testPlaylistCreationFailureDoesNotPublishRuntimePlaylist() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.paths.playlistsRootURL)
        try Data("not-a-directory".utf8).write(to: fixture.paths.playlistsRootURL)
        let repository = fixture.makeRepository(importWriter: { _, _ in true })

        do {
            _ = try await repository.createPlaylist(name: "Must Fail")
            XCTFail("expected typed playlist persistence failure")
        } catch let error as LibraryPlaylistPersistenceError {
            guard case .writeFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let playlists = await repository.fetchPlaylists()
        XCTAssertTrue(playlists.isEmpty)
    }

    func testPlaylistUpdateFailureKeepsRuntimeAndDiskSnapshotUnchanged() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository(importWriter: { _, _ in true })
        let playlist = try await repository.createPlaylist(name: "Original")
        let originalSidecar = try XCTUnwrap(
            fixture.libraryService.loadPlaylistSidecar(playlistID: playlist.id)
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.paths.playlistsRootURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.paths.playlistsRootURL.path
            )
        }

        do {
            try await repository.renamePlaylist(playlist, name: "Lost Rename")
            XCTFail("expected typed playlist persistence failure")
        } catch let error as LibraryPlaylistPersistenceError {
            guard case .writeFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(playlist.name, "Original")
        let persisted = try XCTUnwrap(
            fixture.libraryService.loadPlaylistSidecar(playlistID: playlist.id)
        )
        XCTAssertEqual(persisted.name, originalSidecar.name)
    }

    func testPlaylistMembershipWriteFailureKeepsRuntimeAndDiskSnapshotUnchanged() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository(importWriter: { _, _ in true })
        let playlist = try await repository.createPlaylist(name: "Membership")
        let track = makeTrack(title: "Must Not Appear", root: fixture.paths.rootURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.paths.playlistsRootURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.paths.playlistsRootURL.path
            )
        }

        do {
            try await repository.addTracks([track], to: playlist)
            XCTFail("expected typed playlist persistence failure")
        } catch let error as LibraryPlaylistPersistenceError {
            guard case .writeFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(playlist.tracks.isEmpty)
        let persisted = try XCTUnwrap(
            fixture.libraryService.loadPlaylistSidecar(playlistID: playlist.id)
        )
        XCTAssertTrue(persisted.items.isEmpty)
    }

    func testPlaylistSnapshotReplacementRestoresOrderAndOriginalDates() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository(importWriter: { _, _ in true })
        let playlist = try await repository.createPlaylist(name: "Rollback")
        let first = makeTrack(title: "First", root: fixture.paths.rootURL)
        let second = makeTrack(title: "Second", root: fixture.paths.rootURL)
        try await repository.addTracks([first, second], to: playlist)
        let originalDateMap = await repository.fetchPlaylistItemAddedAtMap()
        let originalDates = try XCTUnwrap(originalDateMap[playlist.id])

        try await repository.removeTracks([first], from: playlist)
        try await repository.replacePlaylistTracks(
            [first, second],
            in: playlist,
            itemAddedAt: originalDates
        )

        XCTAssertEqual(playlist.tracks.map(\.id), [first.id, second.id])
        let restoredDateMap = await repository.fetchPlaylistItemAddedAtMap()
        XCTAssertEqual(restoredDateMap[playlist.id], originalDates)
        let persisted = try XCTUnwrap(
            fixture.libraryService.loadPlaylistSidecar(playlistID: playlist.id)
        )
        XCTAssertEqual(persisted.items.map(\.trackID), [first.id, second.id])
        for item in persisted.items {
            XCTAssertEqual(
                item.addedAt.timeIntervalSince1970,
                try XCTUnwrap(originalDates[item.trackID]).timeIntervalSince1970,
                accuracy: 1
            )
        }
    }

    func testPlaylistDeleteFailureKeepsRuntimeAndDiskSnapshotUnchanged() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository(importWriter: { _, _ in true })
        let playlist = try await repository.createPlaylist(name: "Keep Me")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.paths.playlistsRootURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.paths.playlistsRootURL.path
            )
        }

        do {
            try await repository.deletePlaylist(playlist)
            XCTFail("expected typed playlist persistence failure")
        } catch let error as LibraryPlaylistPersistenceError {
            guard case .deleteFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let playlists = await repository.fetchPlaylists()
        XCTAssertEqual(playlists.map(\.id), [playlist.id])
        XCTAssertNotNil(fixture.libraryService.loadPlaylistSidecar(playlistID: playlist.id))
    }

    func testMembershipPersistenceFailureRestoresActorState() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let store = ReferencedPlaylistMembershipStore(paths: fixture.paths)
        let playlistID = UUID()
        let existingTrackID = UUID()
        let rejectedTrackID = UUID()
        try await store.recordSourceContribution(
            playlistID: playlistID,
            trackID: existingTrackID,
            bindingIDs: [UUID()]
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.paths.sourcesRootURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.paths.sourcesRootURL.path
            )
        }

        do {
            try await store.recordManualAddition(
                playlistID: playlistID,
                trackIDs: [rejectedTrackID]
            )
            XCTFail("expected membership persistence failure")
        } catch {}

        let inMemoryTrackIDs = Set(try await store.loadAll().map(\.trackID))
        XCTAssertEqual(inMemoryTrackIDs, [existingTrackID])
    }

    private func makeTrack(
        title: String,
        root: URL,
        locator: kmgccc_player.ReferencedFileLocator? = nil
    ) -> Track {
        let referenced = locator ?? kmgccc_player.ReferencedFileLocator(
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
    let paths: kmgccc_player.LibraryPaths
    let libraryService: LocalLibraryService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = kmgccc_player.LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        libraryService = LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService())
    }

    func makeRepository(
        importWriter: @escaping (Track, String) -> Bool,
        locatorWriter: @escaping (
            Track,
            kmgccc_player.TrackMediaLocator,
            kmgccc_player.TrackAvailability,
            String
        ) -> Bool = { _, _, _, _ in true }
    ) -> SwiftDataLibraryRepository {
        SwiftDataLibraryRepository(
            libraryService: libraryService,
            importSidecarWriter: importWriter,
            locatorSidecarWriter: locatorWriter
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

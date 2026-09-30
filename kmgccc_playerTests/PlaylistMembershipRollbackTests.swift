import XCTest
@testable import kmgccc_player

@MainActor
final class PlaylistMembershipRollbackTests: XCTestCase {
    func testManualAdditionFailureRestoresPlaylistAndReportsNotice() async throws {
        let repository = StubLibraryRepository()
        let viewModel = LibraryViewModel.preview(repository: repository)
        let playlist = try await repository.createPlaylist(name: "Addition rollback")
        let tracks = await repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        var notice: String?
        viewModel.onImportRejectedNotice = { notice = $0 }
        viewModel.onManualPlaylistAddition = { _, _ in throw TestFailure.expected }

        await viewModel.addTracksToPlaylist([track], playlist: playlist)

        XCTAssertTrue(playlist.tracks.isEmpty)
        XCTAssertNotNil(notice)
    }

    func testManualRemovalFailureRestoresPlaylistOrderAndReportsNotice() async throws {
        let repository = StubLibraryRepository()
        let tracks = await repository.fetchTracks(in: nil)
        let originalTracks = Array(tracks.prefix(2))
        XCTAssertEqual(originalTracks.count, 2)
        let playlist = try await repository.createPlaylist(name: "Removal rollback")
        try await repository.addTracks(originalTracks, to: playlist)
        let viewModel = LibraryViewModel.preview(repository: repository)
        var notice: String?
        viewModel.onImportRejectedNotice = { notice = $0 }
        viewModel.onManualPlaylistRemoval = { _, _ in throw TestFailure.expected }

        await viewModel.removeTracksFromPlaylist([originalTracks[0]], playlist: playlist)

        XCTAssertEqual(playlist.tracks.map(\.id), originalTracks.map(\.id))
        XCTAssertNotNil(notice)
    }

    func testAutomationAddsExistingTrackAndRejectsStaleRevision() async throws {
        let repository = StubLibraryRepository()
        let viewModel = LibraryViewModel.preview(repository: repository)
        let tracks = await repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        let playlist = try await viewModel.createPlaylistForAutomation(name: "Automation target")
        let revision = viewModel.automationPlaylistRevision(for: playlist)

        try await viewModel.addTracksToPlaylistForAutomation(
            [track],
            playlist: playlist,
            expectedRevision: revision
        )

        XCTAssertEqual(
            viewModel.playlists.first { $0.id == playlist.id }?.tracks.map(\.id),
            [track.id]
        )
        do {
            try await viewModel.removeTracksFromPlaylistForAutomation(
                [track],
                playlist: playlist,
                expectedRevision: revision
            )
            XCTFail("a stale playlist revision must not overwrite membership")
        } catch let error as LibraryAutomationMutationError {
            guard case .revisionConflict = error else {
                return XCTFail("unexpected automation error: \(error)")
            }
        }
    }
}

private enum TestFailure: Error {
    case expected
}

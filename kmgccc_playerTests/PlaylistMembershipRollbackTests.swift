import AppKit
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

final class ListMultiselectStateTests: XCTestCase {
    func testRemovingLastSelectionEndsAutomaticModeAndKeepsManualMode() {
        var state = ListMultiselectState()
        state.updateModifiers(held: true, hasSelection: false, isAllowed: true)
        state.updateModifiers(held: false, hasSelection: true, isAllowed: true)
        state.reconcileSelection(hasSelection: false)
        XCTAssertFalse(state.isActive)
        state.beginPersistentSelection()
        state.reconcileSelection(hasSelection: false)
        XCTAssertTrue(state.isActive)
    }

    func testModifierModeExitsOnlyWhenEmptyAndUnpinned() {
        var state = ListMultiselectState()
        state.updateModifiers(held: true, hasSelection: false, isAllowed: true)
        XCTAssertTrue(state.isActive)
        state.updateModifiers(held: false, hasSelection: false, isAllowed: true)
        XCTAssertFalse(state.isActive)

        state.updateModifiers(held: true, hasSelection: false, isAllowed: true)
        state.updateModifiers(held: false, hasSelection: true, isAllowed: true)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.isManual)
    }

    func testToolbarPinsTemporaryModeUntilExplicitExit() {
        var state = ListMultiselectState()
        state.updateModifiers(held: true, hasSelection: false, isAllowed: true)
        XCTAssertTrue(state.toggleManually())
        XCTAssertTrue(state.isManual)
        state.updateModifiers(held: false, hasSelection: false, isAllowed: true)
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.toggleManually())
        XCTAssertFalse(state.isManual)
    }

    func testClearResetsKeyboardAndManualOrigins() {
        var state = ListMultiselectState()
        state.beginPersistentSelection()
        state.updateModifiers(held: true, hasSelection: true, isAllowed: true)
        state.clear()
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.isManual)
        XCTAssertFalse(state.modifiersHeld)
        state.updateModifiers(held: true, hasSelection: false, isAllowed: false)
        XCTAssertFalse(state.isActive)
    }

    func testShiftRangeUsesVisibleOrderInBothDirections() {
        let ids = (0..<5).map { _ in UUID() }
        XCTAssertEqual(ListMultiselectState.range(from: ids[3], to: ids[1], in: ids), Set(ids[1...3]))
        XCTAssertEqual(ListMultiselectState.range(from: ids[1], to: ids[4], in: ids), Set(ids[1...4]))
        XCTAssertNil(ListMultiselectState.range(from: UUID(), to: ids[1], in: ids))
    }
}

@MainActor
final class LibraryTrackDragTests: XCTestCase {
    func testPlaylistDropAppendsInDragOrderAndSkipsExistingMembership() async throws {
        let repository = StubLibraryRepository()
        let viewModel = LibraryViewModel.preview(repository: repository)
        await viewModel.load()
        let tracks = Array((await repository.fetchTracks(in: nil)).prefix(3))
        XCTAssertEqual(tracks.count, 3)
        let playlist = try await viewModel.createPlaylistForAutomation(name: "Drop target")
        await viewModel.addTracksToPlaylist([tracks[0]], playlist: playlist)
        let payload = LibraryTrackDragPayload(
            sessionID: viewModel.trackDragSessionID, trackIDs: [tracks[2].id, tracks[0].id, tracks[1].id]
        )
        let first = await viewModel.applyTrackDrop(payload, to: .playlist(playlist.id))
        XCTAssertEqual(first?.changedCount, 2)
        XCTAssertEqual(first?.unchangedCount, 1)
        XCTAssertEqual(playlist.tracks.map(\.id), [tracks[0].id, tracks[2].id, tracks[1].id])
        let repeated = await viewModel.applyTrackDrop(payload, to: .playlist(playlist.id))
        XCTAssertEqual(repeated?.changedCount, 0)
        XCTAssertEqual(repeated?.unchangedCount, 3)
    }

    func testPlaylistDropFailureUsesMembershipRollback() async throws {
        let repository = StubLibraryRepository()
        let viewModel = LibraryViewModel.preview(repository: repository)
        await viewModel.load()
        let playlist = try await viewModel.createPlaylistForAutomation(name: "Drop rollback")
        let tracks = await repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        viewModel.onManualPlaylistAddition = { _, _ in throw TestFailure.expected }
        let payload = LibraryTrackDragPayload(sessionID: viewModel.trackDragSessionID, trackIDs: [track.id])
        let result = await viewModel.applyTrackDrop(payload, to: .playlist(playlist.id))
        XCTAssertNil(result)
        XCTAssertTrue(playlist.tracks.isEmpty)
    }

    func testDragUsesVisibleSelectionOrderAndUnselectedRowIsIndependent() {
        let ids = (0..<6).map { _ in UUID() }
        let selected = Set([ids[4], ids[1], ids[3]])
        XCTAssertEqual(
            LibraryTrackDragPayload.draggedIDs(startingAt: ids[3], selectedIDs: selected, orderedIDs: ids),
            [ids[1], ids[3], ids[4]]
        )
        XCTAssertEqual(
            LibraryTrackDragPayload.draggedIDs(startingAt: ids[0], selectedIDs: selected, orderedIDs: ids),
            [ids[0]]
        )
    }

    func testDragPayloadPreservesSourceAndDeduplicatesWithoutLosingOrder() {
        let ids = (0..<3).map { _ in UUID() }
        let payload = LibraryTrackDragPayload(
            sessionID: UUID(), sourceSelectionIdentity: "album/example", trackIDs: ids + [ids[0]]
        )
        XCTAssertEqual(payload.trackIDs, ids)
        XCTAssertEqual(payload.sourceSelectionIdentity, "album/example")
    }

    func testDropRoutingPrefersPlaylistRowAndExcludesHiddenOrDetachedTargets() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        let group = LibraryTrackDropAnchorView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        group.performDrop = { _ in false }
        container.addSubview(group)
        let playlist = LibraryTrackDropAnchorView(frame: NSRect(x: 8, y: 100, width: 200, height: 38))
        playlist.target = .playlist(UUID())
        playlist.performDrop = { _ in true }
        container.addSubview(playlist)
        let session = window.libraryTrackDragSession
        session.register(group)
        session.register(playlist)
        let point = container.convert(NSPoint(x: 50, y: 118), to: nil)
        XCTAssertTrue(session.destination(atWindowPoint: point) === playlist)
        playlist.isHidden = true
        XCTAssertTrue(session.destination(atWindowPoint: point) === group)
        playlist.isHidden = false
        playlist.removeFromSuperview()
        XCTAssertTrue(session.destination(atWindowPoint: point) === group)
        XCTAssertNil(session.destination(atWindowPoint: container.convert(NSPoint(x: 400, y: 118), to: nil)))
    }

    func testDropRoutingUsesVisiblePartOfClippedPlaylistRow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(clip)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        clip.documentView = document
        let playlist = LibraryTrackDropAnchorView(frame: NSRect(x: 0, y: 80, width: 200, height: 40))
        playlist.target = .playlist(UUID())
        playlist.performDrop = { _ in true }
        document.addSubview(playlist)
        let session = window.libraryTrackDragSession
        session.register(playlist)
        XCTAssertTrue(session.destination(atWindowPoint: document.convert(NSPoint(x: 20, y: 90), to: nil)) === playlist)
        XCTAssertNil(session.destination(atWindowPoint: document.convert(NSPoint(x: 20, y: 110), to: nil)))
    }

    func testPlayDropKeepsUpcomingQueueAndMakesSelectionSequential() {
        let tracks = (0..<6).map { Track(title: "Song \($0)") }
        let plan = LibraryTrackPlaybackDropPlan(
            tracks: [tracks[4], tracks[2], tracks[4], tracks[5]],
            currentTrackID: tracks[1].id,
            existingQueue: Array(tracks.prefix(5))
        )
        XCTAssertEqual(plan.initialQueue.map(\.id), [tracks[4].id, tracks[3].id])
        XCTAssertEqual(plan.playNext.map(\.id), [tracks[2].id, tracks[5].id])
    }

    func testPlayDropSkipsMissingTracksAndExternalPlaybackStartsFresh() {
        let missing = Track(title: "Missing", availability: .missing)
        let first = Track(title: "First")
        let second = Track(title: "Second")
        let plan = LibraryTrackPlaybackDropPlan(
            tracks: [missing, first, second], currentTrackID: nil,
            existingQueue: [Track(title: "Old local song")]
        )
        XCTAssertEqual(plan.initialQueue.map(\.id), [first.id])
        XCTAssertEqual(plan.playNext.map(\.id), [second.id])
        XCTAssertTrue(LibraryTrackPlaybackDropPlan(tracks: [missing], currentTrackID: nil, existingQueue: []).initialQueue.isEmpty)
    }

    func testArtistAssignmentReplacesContributorsAndPreservesOtherCredits() {
        let composer = TrackCredit(displayName: "Composer", role: .composer)
        let track = Track(title: "Song", artist: "A, B", artistCredits: [
            TrackCredit(displayName: "A"), TrackCredit(displayName: "B", role: .featured), composer
        ], album: "Original album")
        let edit = LibraryTrackDropMetadataEdit.artist(name: "Target", canonicalName: "target")
        edit.apply(to: track)
        XCTAssertEqual(track.artist, "Target")
        XCTAssertEqual(LibraryNormalization.artistCanonicalNames(for: track), ["target"])
        XCTAssertEqual(track.artistCredits.last, composer)
        XCTAssertEqual(track.album, "Original album")
        let snapshot = LibraryTrackDropMetadataSnapshot(track)
        edit.apply(to: track)
        XCTAssertTrue(snapshot.matches(track), "repeated assignment should be a no-op")
    }

    func testExplicitAlbumBindingPreservesSameTitleDestinationAndOtherArtists() throws {
        let albums = [
            Track(title: "A1", artist: "A", album: "Same title"),
            Track(title: "A2", artist: "A", album: "Same title"),
            Track(title: "B1", artist: "B", album: "Same title"),
            Track(title: "B2", artist: "B", album: "Same title")
        ]
        let before = LibraryNormalization.buildAlbumGrouping(tracks: albums)
        let targetKey = try XCTUnwrap(before.albumKeyByTrackID[albums[0].id])
        let otherKey = try XCTUnwrap(before.albumKeyByTrackID[albums[2].id])
        XCTAssertNotEqual(targetKey, otherKey)
        let track = Track(title: "Guest song", artist: "Guest", album: "Old album", musicBrainzReleaseID: "old-release")
        LibraryTrackDropMetadataEdit.album(title: "Same title", artist: "A", key: targetKey, musicBrainzReleaseID: nil).apply(to: track)
        let after = LibraryNormalization.buildAlbumGrouping(tracks: albums + [track])
        XCTAssertEqual(after.albumKeyByTrackID[track.id], targetKey)
        XCTAssertEqual(after.albumKeyByTrackID[albums[0].id], targetKey)
        XCTAssertEqual(after.albumKeyByTrackID[albums[2].id], otherKey)
        XCTAssertEqual(track.artist, "Guest")
        XCTAssertNil(track.musicBrainzReleaseID)
        track.album = "Later edit"
        XCTAssertNotEqual(LibraryNormalization.buildAlbumGrouping(tracks: [track]).albumKeyByTrackID[track.id], targetKey)
    }

    func testMetadataRollbackDoesNotUndoUnrelatedFields() {
        let track = Track(title: "Song", artist: "Original", album: "Album")
        let original = LibraryTrackDropMetadataSnapshot(track)
        LibraryTrackDropMetadataEdit.artist(name: "Target", canonicalName: "target").apply(to: track)
        track.userDescription = "Unrelated edit"
        original.restore(to: track)
        XCTAssertTrue(original.matches(track))
        XCTAssertEqual(track.userDescription, "Unrelated edit")
    }

    func testMetadataAssignmentSurvivesSidecarScanAndLegacyCorrectionsDecode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("track-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)
        let id = UUID()
        let track = Track(
            id: id, title: "Song", artist: "Guest", album: "Old",
            mediaLocator: .managed(libraryRelativePath: "Tracks/\(id.uuidString)/audio.flac"), audioFileName: "audio.flac"
        )
        let key = LibraryNormalization.normalizedAlbumKey(album: "Target album")
        LibraryTrackDropMetadataEdit.album(title: "Target album", artist: "Album artist", key: key, musicBrainzReleaseID: nil).apply(to: track)
        let result = LocalLibraryService.persistTrackSnapshotOnBackground(
            TrackPersistenceSnapshot(track: track, preferenceStats: TrackPreferenceStats()),
            paths: paths, mode: .metaOnly, reason: "trackDropTest"
        )
        XCTAssertTrue(result.succeeded)
        let scanned = try XCTUnwrap(MusicLibraryScanner(paths: paths).scanTrackFolder(paths.trackMetaURL(for: id).deletingLastPathComponent()))
        XCTAssertEqual(scanned.userMetadataOverride?.albumGroupKey, key)
        XCTAssertEqual(scanned.album, "Target album")
        XCTAssertEqual(scanned.artist, "Guest")
        let legacy = Data(#"{"artistDisplay":"Legacy","editedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(UserMetadataOverride.self, from: legacy).albumGroupKey)
    }

    func testClosedAndOtherLibrarySessionsRejectPayload() async throws {
        let repository = StubLibraryRepository()
        let viewModel = LibraryViewModel.preview(repository: repository)
        await viewModel.load()
        let tracks = await repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        let stale = LibraryTrackDragPayload(sessionID: UUID(), trackIDs: [track.id])
        XCTAssertTrue(viewModel.tracks(forDragPayload: stale).isEmpty)
        let valid = LibraryTrackDragPayload(sessionID: viewModel.trackDragSessionID, trackIDs: [track.id])
        XCTAssertEqual(viewModel.tracks(forDragPayload: valid).map(\.id), [track.id])
        viewModel.prepareForSessionClose()
        XCTAssertTrue(viewModel.tracks(forDragPayload: valid).isEmpty)
    }
}

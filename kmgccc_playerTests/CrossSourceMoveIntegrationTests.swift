import AVFoundation
import Foundation
@testable import kmgccc_player
import XCTest

/// Regression tests for §11 cross-source file identity: the same physical
/// song moving between overlapping referenced sources must keep its
/// TrackRecord identity, and similarity must never be what merges it.
@MainActor
final class CrossSourceMoveIntegrationTests: XCTestCase {
    func testMovedFileAcrossSourcesKeepsTrackIdentity() async throws {
        let fixture = try await CrossSourceMoveFixture()
        defer { fixture.cleanup() }
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let sourceA = try await fixture.addDirectorySource(named: "SourceA", at: fixture.sourceARoot)
        let songURL = fixture.sourceARoot.appendingPathComponent("song.wav")
        try writeWavAudio(at: songURL, frames: 4_410)
        let playlist = await fixture.repository.createPlaylist(name: "Shared")
        try await fixture.reconciler.bindSourcesToPlaylist([sourceA], playlistID: playlist.id)

        try await fixture.reconciler.reconcile(sourceIDs: [sourceA])

        var tracks = await fixture.repository.fetchTracks(in: nil)
        let original = try XCTUnwrap(tracks.first)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(original.availability, .available)
        XCTAssertEqual(
            original.mediaLocator.referencedFile?.sourceMemberships,
            [.init(sourceID: sourceA, relativePath: "song.wav")]
        )
        var playlists = await fixture.repository.fetchPlaylists()
        XCTAssertEqual(playlists.map(\.id), [playlist.id])
        XCTAssertEqual(playlists[0].tracks.map(\.id), [original.id])

        let sourceBRoot = fixture.root.appendingPathComponent("SourceB", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBRoot, withIntermediateDirectories: true)
        let sourceB = try await fixture.addDirectorySource(named: "SourceB", at: sourceBRoot)
        try await fixture.reconciler.bindSourcesToPlaylist([sourceB], playlistID: playlist.id)
        let movedURL = sourceBRoot.appendingPathComponent("song.wav")
        try FileManager.default.moveItem(at: songURL, to: movedURL)

        // §12.3: a full successful scan that confirms the file is gone from A
        // removes only that TrackLocation; the Track itself must survive.
        _ = try await fixture.reconciler.reconcile(sourceIDs: [sourceA])
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [original.id])
        XCTAssertEqual(tracks[0].availability, .missing)
        XCTAssertTrue(tracks[0].mediaLocator.referencedFile?.allSourceMemberships.isEmpty == true)

        // The B-side scan reconnects through the preserved physical identity
        // instead of importing an orphan duplicate.
        _ = try await fixture.reconciler.reconcile(sourceIDs: [sourceB])
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [original.id])
        let locator = try XCTUnwrap(tracks[0].mediaLocator.referencedFile)
        XCTAssertEqual(
            locator.sourceMemberships,
            [.init(sourceID: sourceB, relativePath: "song.wav")]
        )
        XCTAssertEqual(locator.primarySourceID, sourceB)
        XCTAssertEqual(locator.lastKnownPath, movedURL.path)
        XCTAssertEqual(tracks[0].availability, .available)

        playlists = await fixture.repository.fetchPlaylists()
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists[0].tracks.map(\.id), [original.id])

        // An all-source settle pass (the LibrarySession.load shape) must be
        // stable: no resurrection of the A membership and no duplicates.
        let outcome = await fixture.reconciler.reconcileBestEffort(sourceIDs: [sourceA, sourceB])
        XCTAssertTrue(outcome.failedSourceIDs.isEmpty)
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [original.id])
        XCTAssertEqual(
            tracks[0].mediaLocator.referencedFile?.sourceMemberships,
            [.init(sourceID: sourceB, relativePath: "song.wav")]
        )
        XCTAssertEqual(tracks[0].availability, .available)

        await fixture.shutdown()
    }

    func testOverlappingSourcesDoNotDuplicateTrack() async throws {
        for outerClaimsFirst in [true, false] {
            let fixture = try await CrossSourceMoveFixture()
            defer { fixture.cleanup() }
            let previousDeferred = AppSettings.shared.deferImportEnrichment
            AppSettings.shared.deferImportEnrichment = true
            defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

            let outerRoot = fixture.root.appendingPathComponent("Outer", isDirectory: true)
            let innerRoot = outerRoot.appendingPathComponent("Inner", isDirectory: true)
            try FileManager.default.createDirectory(at: innerRoot, withIntermediateDirectories: true)
            let songURL = innerRoot.appendingPathComponent("song.wav")
            try writeWavAudio(at: songURL, frames: 5_000)
            let outerID = try await fixture.addDirectorySource(named: "Outer", at: outerRoot)
            let innerID = try await fixture.addDirectorySource(named: "Inner", at: innerRoot)
            let playlist = await fixture.repository.createPlaylist(name: "Overlap")
            try await fixture.reconciler.bindSourcesToPlaylist([outerID, innerID], playlistID: playlist.id)

            let first = outerClaimsFirst ? outerID : innerID
            let second = outerClaimsFirst ? innerID : outerID
            _ = try await fixture.reconciler.reconcile(sourceIDs: [first])
            _ = try await fixture.reconciler.reconcile(sourceIDs: [second])

            let context = "outerClaimsFirst=\(outerClaimsFirst)"
            let tracks = await fixture.repository.fetchTracks(in: nil)
            XCTAssertEqual(tracks.count, 1, context)
            let track = try XCTUnwrap(tracks.first)
            XCTAssertEqual(track.availability, .available, context)
            let locator = try XCTUnwrap(track.mediaLocator.referencedFile, context)
            XCTAssertEqual(
                Set(locator.allSourceMemberships.map(\.sourceID)),
                Set([outerID, innerID]),
                context
            )
            // The shortest relative path wins the primary slot, so the nested
            // source owns playback regardless of which scan claimed first.
            XCTAssertEqual(locator.primarySourceID, innerID, context)
            XCTAssertEqual(locator.lastKnownPath, songURL.path, context)
            let playlists = await fixture.repository.fetchPlaylists()
            XCTAssertEqual(playlists.count, 1, context)
            XCTAssertEqual(playlists[0].tracks.map(\.id), [track.id], context)

            await fixture.shutdown()
        }
    }

    func testMoveThenRenameStillReconnectsOrDocumentsGap() async throws {
        let fixture = try await CrossSourceMoveFixture()
        defer { fixture.cleanup() }
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let sourceA = try await fixture.addDirectorySource(named: "SourceA", at: fixture.sourceARoot)
        let originalURL = fixture.sourceARoot.appendingPathComponent("original-name.wav")
        try writeWavAudio(at: originalURL, frames: 6_000)
        try await fixture.reconciler.reconcile(sourceIDs: [sourceA])
        var tracks = await fixture.repository.fetchTracks(in: nil)
        let original = try XCTUnwrap(tracks.first)
        XCTAssertEqual(tracks.count, 1)

        let sourceBRoot = fixture.root.appendingPathComponent("SourceB", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBRoot, withIntermediateDirectories: true)
        let sourceB = try await fixture.addDirectorySource(named: "SourceB", at: sourceBRoot)
        let renamedURL = sourceBRoot.appendingPathComponent("renamed.wav")
        try FileManager.default.moveItem(at: originalURL, to: renamedURL)

        _ = try await fixture.reconciler.reconcile(sourceIDs: [sourceA])
        _ = try await fixture.reconciler.reconcile(sourceIDs: [sourceB])

        // A same-volume move+rename preserves the APFS resource identifier, so
        // the stable-identity tier (§11 resolution order) reconnects without a
        // content digest. Digest-based matching remains the future upgrade for
        // cross-volume copies where that identity is lost.
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [original.id])
        XCTAssertEqual(tracks[0].title, original.title)
        let locator = try XCTUnwrap(tracks[0].mediaLocator.referencedFile)
        XCTAssertEqual(
            locator.sourceMemberships,
            [.init(sourceID: sourceB, relativePath: "renamed.wav")]
        )
        XCTAssertEqual(locator.primarySourceID, sourceB)
        XCTAssertEqual(locator.lastKnownPath, renamedURL.path)
        XCTAssertEqual(tracks[0].availability, .available)

        await fixture.shutdown()
    }
}

@MainActor
private final class CrossSourceMoveFixture {
    let root: URL
    let sourceARoot: URL
    let paths: kmgccc_player.LibraryPaths
    let context: kmgccc_player.LibraryContext
    let store: ReferencedSourceStore
    let scope: ReferencedSourceScope
    let repository: SwiftDataLibraryRepository
    let backend: ReferencedLocalBackend
    let cache: LibraryCacheServices
    let enrichment: ImportEnrichmentService
    let reconciler: ReferencedSourceReconciler

    private let importer: FileImportService

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceARoot = root.appendingPathComponent("SourceA", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceARoot, withIntermediateDirectories: true)
        context = try makeLibraryContext(root: root.appendingPathComponent("Library", isDirectory: true), mode: .referenced)
        paths = context.paths
        try paths.createRequiredDirectories()
        store = ReferencedSourceStore(paths: paths)
        scope = ReferencedSourceScope()
        repository = SwiftDataLibraryRepository(
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService())
        )
        backend = ReferencedLocalBackend(
            paths: paths,
            sourceStore: store,
            sourceScope: scope,
            bookmarkResolver: PathBookmarkResolver()
        )
        cache = LibraryCacheServices(paths: paths)
        enrichment = ImportEnrichmentService(
            repository: repository,
            qqMusicCoverService: cache.qqMusicCoverService,
            artistArtworkProviderCoordinator: cache.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService
        )
        importer = FileImportService(
            repository: repository,
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService()),
            importEnrichmentService: enrichment,
            storageBackend: backend,
            operationCoordinator: LibraryOperationCoordinator(),
            qqMusicCoverService: cache.qqMusicCoverService,
            artistArtworkProviderCoordinator: cache.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService,
            uiPresentationObserver: {}
        )
        let ignoredItemsStore = IgnoredReferencedItemsStore(paths: paths)
        reconciler = ReferencedSourceReconciler(
            context: context,
            repository: repository,
            importer: importer,
            sourceStore: store,
            sourceScope: scope,
            scanner: ReferencedSourceScanner(
                paths: paths,
                isIgnored: { [ignoredItemsStore] fingerprint in
                    (try? await ignoredItemsStore.contains(fingerprint)) ?? true
                }
            ),
            ignoredItemsStore: ignoredItemsStore,
            ncmRegistry: NCMConversionRegistry(paths: paths),
            bookmarkResolver: PathBookmarkResolver()
        )
    }

    func addDirectorySource(named displayName: String, at sourceRoot: URL) async throws -> UUID {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceID = UUID()
        try await store.save(ReferencedSourceDescriptor(
            id: sourceID,
            rootBookmarkData: Data(sourceRoot.path.utf8),
            lastKnownPath: sourceRoot.path,
            displayName: displayName
        ))
        scope.add(sourceID: sourceID, url: sourceRoot, lease: .none)
        return sourceID
    }

    func shutdown() async {
        let trackIDs = await repository.fetchTracks(in: nil).map(\.id)
        await enrichment.cancelEnrichment(for: Set(trackIDs))
        await backend.close()
        await cache.close()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class PathBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { true }
    func stopAccessing(_: URL) {}
}

@MainActor
private func makeLibraryContext(root: URL, mode: kmgccc_player.MusicLibraryMode) throws -> kmgccc_player.LibraryContext {
    let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Test", mode: mode)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(to: kmgccc_player.LibraryPaths(rootURL: root).manifestURL)
    return kmgccc_player.LibraryContext(
        manifest: manifest,
        rootURL: root,
        rootBookmarkData: Data(root.path.utf8),
        generation: 1
    )
}

@MainActor
private func writeWavAudio(at url: URL, frames: AVAudioFrameCount) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    try audioFile.write(from: buffer)
}

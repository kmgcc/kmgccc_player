//
//  ImportPlannerCommitterTests.swift
//  kmgccc_playerTests
//
//  Focused coverage for the §16 Planner/Committer seams: golden-style plan
//  assertions on a fixed input, and a state-based rollback assertion that the
//  committer still drives ImportRollbackService with the same arguments.
//

import AVFoundation
import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class ImportPlannerCommitterTests: XCTestCase {
    // MARK: - Planner golden plan

    func testPlannerProducesGoldenCandidatePlanAndPlacementsForFixedInput() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let existing = kmgccc_player.Track(
            title: "Golden Song",
            fileBookmarkData: Data(),
            mediaLocator: .managed(libraryRelativePath: "Tracks/existing/audio.m4a"),
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        existing.artist = "Golden Artist"
        existing.duration = 180
        _ = await fixture.repository.commitImportedTracks([existing])
        let libraryTracks = await fixture.repository.fetchTracks(in: nil)

        let uniqueURL = try writeWAV(named: "brand-new.wav", in: fixture.root)
        let duplicateURL = try writeWAV(named: "golden-dup.wav", in: fixture.root)
        let resolved = [
            ResolvedImportFile(
                progressID: uniqueURL.path,
                displayName: uniqueURL.lastPathComponent,
                fileURL: uniqueURL,
                ncmResult: makeNCMResult(
                    url: uniqueURL,
                    title: "Brand New Song",
                    artist: "New Artist",
                    durationSeconds: 200
                ),
                discoveredFile: ImportDiscoveredFile(
                    url: uniqueURL,
                    memberships: [],
                    primarySourceID: nil,
                    fingerprint: nil
                ),
                referencedNCMOutput: nil
            ),
            ResolvedImportFile(
                progressID: duplicateURL.path,
                displayName: duplicateURL.lastPathComponent,
                fileURL: duplicateURL,
                ncmResult: makeNCMResult(
                    url: duplicateURL,
                    title: "Golden Song",
                    artist: "Golden Artist",
                    durationSeconds: 180
                ),
                discoveredFile: ImportDiscoveredFile(
                    url: duplicateURL,
                    memberships: [],
                    primarySourceID: nil,
                    fingerprint: nil
                ),
                referencedNCMOutput: nil
            )
        ]

        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let token = ImportCancellationToken()

        let prepared = await fixture.planner.prepareCandidates(
            resolvedFiles: resolved,
            libraryTracks: libraryTracks,
            metadataOverride: nil,
            cancellationToken: token,
            progressController: controller
        )

        XCTAssertEqual(prepared.unique.count, 1, "exactly one non-duplicate candidate")
        XCTAssertEqual(prepared.duplicates.count, 1, "exactly one possible-duplicate row")
        XCTAssertEqual(prepared.duplicateCandidates.count, 1)

        let unique = try XCTUnwrap(prepared.unique.first)
        XCTAssertEqual(unique.progressID, uniqueURL.path)
        XCTAssertEqual(unique.metadata.title, "Brand New Song")
        XCTAssertEqual(unique.metadata.artist, "New Artist")
        XCTAssertNil(unique.existingDuplicateTrackID)

        let row = try XCTUnwrap(prepared.duplicates.first)
        XCTAssertEqual(row.id, duplicateURL.path)
        XCTAssertEqual(row.incoming.title, "Golden Song")
        XCTAssertEqual(row.incoming.artist, "Golden Artist")
        XCTAssertEqual(row.existingCount, 1)
        XCTAssertEqual(
            row.dedupKey,
            kmgccc_player.LibraryNormalization.normalizedDedupKey(title: "Golden Song", artist: "Golden Artist")
        )

        let duplicateCandidate = try XCTUnwrap(prepared.duplicateCandidates.first)
        XCTAssertEqual(duplicateCandidate.existingDuplicateTrackID, existing.id)

        let placements = await fixture.planner.resolvePlacements(
            uniqueCandidates: prepared.unique,
            selectedDuplicates: [],
            session: fixture.session,
            progressController: controller
        )
        XCTAssertTrue(placements.failures.isEmpty)
        XCTAssertEqual(placements.placements.count, 1)
        let placed = try XCTUnwrap(placements.placements.first)
        XCTAssertNotNil(placed.trackID)
        XCTAssertEqual(placed.placement?.storageKind, .managed)
    }

    // MARK: - Playlist-destination duplicate policy

    func testPlaylistDestinationResolvesSimilarityDuplicatesByReuse() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let existing = kmgccc_player.Track(
            title: "Golden Song",
            fileBookmarkData: Data(),
            mediaLocator: .managed(libraryRelativePath: "Tracks/existing/audio.m4a"),
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        existing.artist = "Golden Artist"
        existing.duration = 180
        _ = await fixture.repository.commitImportedTracks([existing])
        let libraryTracks = await fixture.repository.fetchTracks(in: nil)

        let uniqueURL = try writeWAV(named: "brand-new.wav", in: fixture.root)
        let duplicateURL = try writeWAV(named: "golden-dup.wav", in: fixture.root)
        let resolved = [
            ResolvedImportFile(
                progressID: uniqueURL.path,
                displayName: uniqueURL.lastPathComponent,
                fileURL: uniqueURL,
                ncmResult: makeNCMResult(
                    url: uniqueURL,
                    title: "Brand New Song",
                    artist: "New Artist",
                    durationSeconds: 200
                ),
                discoveredFile: ImportDiscoveredFile(
                    url: uniqueURL,
                    memberships: [],
                    primarySourceID: nil,
                    fingerprint: nil
                ),
                referencedNCMOutput: nil
            ),
            ResolvedImportFile(
                progressID: duplicateURL.path,
                displayName: duplicateURL.lastPathComponent,
                fileURL: duplicateURL,
                ncmResult: makeNCMResult(
                    url: duplicateURL,
                    title: "Golden Song",
                    artist: "Golden Artist",
                    durationSeconds: 180
                ),
                discoveredFile: ImportDiscoveredFile(
                    url: duplicateURL,
                    memberships: [],
                    primarySourceID: nil,
                    fingerprint: nil
                ),
                referencedNCMOutput: nil
            )
        ]

        let playlist = await fixture.repository.createPlaylist(name: "Drop Target")
        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let token = ImportCancellationToken()

        let prepared = await fixture.planner.prepareCandidates(
            resolvedFiles: resolved,
            libraryTracks: libraryTracks,
            metadataOverride: nil,
            cancellationToken: token,
            progressController: controller,
            playlist: playlist
        )

        XCTAssertEqual(prepared.unique.count, 1)
        XCTAssertTrue(prepared.duplicates.isEmpty, "playlist destinations must not produce dialog rows")
        XCTAssertTrue(prepared.duplicateCandidates.isEmpty)
        XCTAssertEqual(prepared.reusedDuplicates.count, 1)

        let match = try XCTUnwrap(prepared.reusedDuplicates.first)
        XCTAssertEqual(match.progressID, duplicateURL.path)
        XCTAssertEqual(match.track.id, existing.id)

        let playlistTracks = await fixture.repository.fetchTracks(in: playlist)
        XCTAssertEqual(playlistTracks.map(\.id), [existing.id])
        let allTracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 1, "similarity duplicates must not be re-imported")
    }

    // MARK: - Committer rollback

    func testCommitterCancelledFinishRollsBackCommittedTracksAndStaging() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let doomed = kmgccc_player.Track(
            title: "Doomed",
            fileBookmarkData: Data(),
            mediaLocator: .managed(libraryRelativePath: "Tracks/doomed/audio.m4a"),
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        doomed.artist = "Doomed Artist"
        _ = await fixture.repository.commitImportedTracks([doomed])

        let session = try ImportSession(paths: fixture.paths)
        session.markCommitted(trackIDs: [doomed.id])

        let record = ImportedTrackRecord(
            progressID: doomed.id.uuidString,
            displayName: "Doomed",
            track: doomed,
            needsLyricsEnrichment: false,
            needsCoverEnrichment: false,
            needsTrackMetadataEnrichment: false,
            needsArtistMetadataEnrichment: false,
            needsAlbumMetadataEnrichment: false,
            needsArtistArtworkEnrichment: false,
            needsAlbumArtworkEnrichment: false
        )
        let controller = BatchImportProgressDialogController(presentsWindow: false)

        let result = await fixture.committer.finishCancelledImport(
            session: session,
            importedRecords: [record],
            createdTrackIDs: [doomed.id],
            to: nil,
            progressController: controller,
            totalCount: 1
        )

        XCTAssertTrue(result.isEmpty, "cancelled imports return no tracks")
        let remainingIDs = Set(await fixture.repository.fetchTracks(in: nil).map(\.id))
        XCTAssertFalse(remainingIDs.contains(doomed.id), "rollback must delete committed tracks")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: session.stagingDirectoryURL.path),
            "rollback must clean the staging directory"
        )
    }

    // MARK: - Fixtures

    private func makeNCMResult(
        url: URL,
        title: String,
        artist: String,
        durationSeconds: Double
    ) -> NCMConversionResult {
        NCMConversionResult(
            audioFileURL: url,
            format: .mp3,
            metadata: NCMMetadata(
                musicName: title,
                artist: [[artist]],
                album: "",
                albumPic: "",
                format: "mp3",
                bitrate: 0,
                duration: Int(durationSeconds * 1000)
            ),
            coverData: nil
        )
    }

    private func writeWAV(named fileName: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try audioFile.write(from: buffer)
        return url
    }

    @MainActor
    private func makeFixture() throws -> PlannerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        let paths = kmgccc_player.LibraryPaths(rootURL: libraryRoot)
        try paths.createRequiredDirectories()
        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: PreferenceStatsService()
        )
        let repository = SwiftDataLibraryRepository(libraryService: libraryService)
        let cache = LibraryCacheServices(paths: paths)
        let enrichment = ImportEnrichmentService(
            repository: repository,
            qqMusicCoverService: cache.qqMusicCoverService,
            artistArtworkProviderCoordinator: cache.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService
        )
        let backend: any kmgccc_player.LibraryStorageBackend = ManagedLocalBackend(paths: paths)
        let coordinator = LibraryOperationCoordinator()
        let pipeline = ManagedNCMConversionPipeline(operationCoordinator: coordinator)
        let planner = ImportPlanner(
            repository: repository,
            storageBackend: backend,
            paths: paths,
            referencedNCMConversionService: nil,
            ignoredItemsStore: nil,
            operationCoordinator: coordinator,
            ncmConversionPipeline: pipeline
        )
        let committer = ImportCommitter(
            repository: repository,
            libraryService: libraryService,
            storageBackend: backend,
            paths: paths,
            importEnrichmentService: enrichment,
            referencedNCMConversionService: nil
        )
        let session = try ImportSession(paths: paths)
        return PlannerFixture(
            root: root,
            paths: paths,
            repository: repository,
            planner: planner,
            committer: committer,
            session: session,
            enrichment: enrichment,
            backend: backend,
            cache: cache
        )
    }
}

@MainActor
private struct PlannerFixture {
    let root: URL
    let paths: kmgccc_player.LibraryPaths
    let repository: SwiftDataLibraryRepository
    let planner: ImportPlanner
    let committer: ImportCommitter
    let session: ImportSession
    let enrichment: ImportEnrichmentService
    let backend: any kmgccc_player.LibraryStorageBackend
    let cache: LibraryCacheServices

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

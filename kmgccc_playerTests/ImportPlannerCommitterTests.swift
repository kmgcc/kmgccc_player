//
//  ImportPlannerCommitterTests.swift
//  kmgccc_playerTests
//
//  Focused coverage for the §16 Planner/Committer seams: golden-style plan
//  assertions on a fixed input, and a state-based rollback assertion that the
//  committer still drives ImportRollbackService with the same arguments.
//

import AVFoundation
import CoreVideo
import Darwin
import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class ImportPlannerCommitterTests: XCTestCase {
    func testAIFFTagPaddingIsRemovedBeforeMatchingAndSnapshots() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("tags.aiff")
        try autoreleasepool {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441))
            buffer.frameLength = 441
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 441)
            try file.write(from: buffer)
        }
        var data = try Data(contentsOf: url)
        for (chunk, value) in [("NAME", "Padded title\0"), ("AUTH", "Padded artist\0")] {
            let text = Data(value.utf8)
            data.append(Data(chunk.utf8))
            var length = UInt32(text.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(text)
            if text.count % 2 != 0 { data.append(0) }
        }
        var formLength = UInt32(data.count - 8).bigEndian
        withUnsafeBytes(of: &formLength) { data.replaceSubrange(4..<8, with: $0) }
        try data.write(to: url)
        let metadata = await ImportMetadataExtractor.extractMetadata(from: url)
        XCTAssertEqual(metadata.tagFields.title, "Padded title")
        XCTAssertEqual(metadata.tagFields.artist, "Padded artist")
    }

    func testProgramRescanPreservesSourceSnapshotAndUserEdits() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try MusicLibraryManifest(displayName: "Test", mode: .managed).write(to: fixture.paths.manifestURL)
        let audio = try writeWAV(named: "album.wav", in: fixture.root)
        let cue = fixture.root.appendingPathComponent("album.cue")
        let text = "TITLE \"合辑\"\nPERFORMER \"群星\"\nFILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nTITLE \"来源曲名\"\nPERFORMER \"演唱者\"\nINDEX 01 00:00:00\n"
        try Data(text.utf8).write(to: cue)
        let plan = await fixture.backend.prepareInputs([cue])
        let file = try XCTUnwrap(plan.files.first)
        let token = ImportCancellationToken()
        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let prepared = await fixture.planner.prepareCandidates(
            resolvedFiles: [ResolvedImportFile(progressID: file.progressID, displayName: audio.lastPathComponent,
                fileURL: audio, ncmResult: nil, discoveredFile: file, referencedNCMOutput: nil)],
            libraryTracks: [], metadataOverride: nil, cancellationToken: token, progressController: controller
        )
        let placements = await fixture.planner.resolvePlacements(
            uniqueCandidates: prepared.unique, selectedDuplicates: [], session: fixture.session,
            progressController: controller
        )
        let batch = await fixture.committer.executeBatch(
            placements.placements, progressController: controller, enrichmentMode: .skipped,
            session: fixture.session, cancellationToken: token
        )
        XCTAssertTrue(batch.failures.isEmpty, String(describing: batch.failures))
        let track = try XCTUnwrap(batch.records.first?.track)
        XCTAssertEqual(track.embeddedMetadataSnapshot?.title, "来源曲名")
        XCTAssertEqual(track.embeddedMetadataSnapshot?.albumArtist, "群星")
        let saved = await fixture.committer.saveImportedTracks([track], progressController: controller,
            session: fixture.session, cancellationToken: token)
        XCTAssertEqual(saved?.map(\.id), [track.id])
        let copy = fixture.root.appendingPathComponent("whole-copy.wav")
        try FileManager.default.copyItem(at: audio, to: copy)
        let copyPlan = await fixture.backend.prepareInputs([copy])
        let whole = await fixture.planner.interpretInputs(inputPlan: copyPlan, libraryTracks: [track],
            isManualSelection: true, session: fixture.session)
        XCTAssertTrue(whole.reusedTracks.isEmpty)
        XCTAssertEqual(whole.filesToImport.map(\.url), [copy])
        track.title = "用户曲名"
        let repeated = await fixture.planner.interpretInputs(inputPlan: plan, libraryTracks: [track],
            isManualSelection: false, session: fixture.session)
        XCTAssertTrue(repeated.pendingAudioExpansions.isEmpty)
        XCTAssertEqual(repeated.reusedTrackIDs, [track.id])

        // Older imports omitted the snapshot. An unchanged descriptor keeps
        // the saved range authoritative even when the user edited the title.
        track.embeddedMetadataSnapshot = nil
        let legacy = await fixture.planner.interpretInputs(inputPlan: plan, libraryTracks: [track],
            isManualSelection: false, session: fixture.session)
        XCTAssertTrue(legacy.pendingAudioExpansions.isEmpty)
        XCTAssertEqual(legacy.reusedTrackIDs, [track.id])

        try Data(text.replacingOccurrences(of: "来源曲名", with: "更新曲名").utf8).write(to: cue, options: .atomic)
        let updated = await fixture.backend.prepareInputs([cue])
        let changed = await fixture.planner.interpretInputs(inputPlan: updated, libraryTracks: [track],
            isManualSelection: false, session: fixture.session)
        XCTAssertEqual(changed.pendingAudioExpansions.count, 1)
        XCTAssertEqual(changed.pendingAudioExpansions.first?.oldTrackIDs, [track.id])
        XCTAssertTrue(changed.filesToImport.isEmpty)
    }

    func testVideoImportCommitsAudioPosterAndSilentMotionTogether() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try await writeVideo(in: fixture.root, withAudio: true)
        let original = try Data(contentsOf: source)
        let plan = await fixture.backend.prepareInputs([source])
        let file = try XCTUnwrap(plan.files.first)
        let token = ImportCancellationToken()
        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let prepared = await fixture.planner.prepareCandidates(
            resolvedFiles: [ResolvedImportFile(
                progressID: source.path, displayName: source.lastPathComponent,
                fileURL: source, ncmResult: nil, discoveredFile: file, referencedNCMOutput: nil
            )],
            libraryTracks: [], metadataOverride: nil,
            cancellationToken: token, progressController: controller
        )
        let placements = await fixture.planner.resolvePlacements(
            uniqueCandidates: prepared.unique, selectedDuplicates: [], session: fixture.session,
            progressController: controller
        )
        XCTAssertTrue(placements.failures.isEmpty)
        let batch = await fixture.committer.executeBatch(
            placements.placements, progressController: controller,
            enrichmentMode: .skipped, session: fixture.session, cancellationToken: token
        )
        XCTAssertTrue(batch.failures.isEmpty)
        let track = try XCTUnwrap(batch.records.first?.track)
        XCTAssertEqual(track.mediaLocator.managedLibraryRelativePath, "Tracks/\(track.id.uuidString)/audio.m4a")
        XCTAssertTrue(track.artworkIsUserSelected == true)
        XCTAssertFalse(track.artworkNeedsUpgrade)
        XCTAssertNotNil(track.artworkData)
        XCTAssertFalse(batch.records[0].needsCoverEnrichment)
        let saved = await fixture.committer.saveImportedTracks(
            [track], progressController: controller, session: fixture.session, cancellationToken: token
        )
        XCTAssertEqual(saved?.map(\.id), [track.id])
        let audioPath = try XCTUnwrap(track.mediaLocator.managedLibraryRelativePath)
        let audioURL = fixture.paths.rootURL.appendingPathComponent(audioPath)
        XCTAssertGreaterThan(try AVAudioFile(forReading: audioURL).length, 0)
        XCTAssertEqual(track.audioProperties?.format, "M4A")
        let motion = try XCTUnwrap(track.motionArtwork?.resource(kind: "square", libraryRootURL: fixture.paths.rootURL))
        let movie = AVURLAsset(url: motion.url)
        let videoTracks = try await movie.loadTracks(withMediaType: .video)
        let audioTracks = try await movie.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
        XCTAssertEqual(track.motionArtwork?.assets.count, 2)
        XCTAssertEqual(track.motionArtwork?.assets.first?.width, 16)
        XCTAssertEqual(track.motionArtwork?.assets.first?.height, 32)
        let sidecar = fixture.paths.trackMetaURL(for: track.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual(metadata["audioFileName"] as? String, "audio.m4a")
        XCTAssertNotNil(metadata["motionArtwork"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testVideoWithoutAudioFailsWithoutStagedProducts() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try await writeVideo(in: fixture.root, withAudio: false)
        do {
            _ = try await VideoMusicImporter.prepare(
                sourceURL: source, outputDirectory: fixture.session.stagingDirectoryURL,
                cancellationToken: ImportCancellationToken()
            )
            XCTFail("A silent movie must not become an unplayable song")
        } catch VideoMusicImportError.noAudio {}
        let staged = try FileManager.default.contentsOfDirectory(
            at: fixture.session.stagingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertTrue(staged.isEmpty)
    }

    func testImportDoesNotReplaceAnExistingDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try await writeVideo(in: fixture.root, withAudio: true)
        let plan = await fixture.backend.prepareInputs([source])
        let file = try XCTUnwrap(plan.files.first)
        let token = ImportCancellationToken()
        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let prepared = await fixture.planner.prepareCandidates(
            resolvedFiles: [ResolvedImportFile(
                progressID: source.path, displayName: source.lastPathComponent,
                fileURL: source, ncmResult: nil, discoveredFile: file, referencedNCMOutput: nil
            )],
            libraryTracks: [], metadataOverride: nil,
            cancellationToken: token, progressController: controller
        )
        let placements = await fixture.planner.resolvePlacements(
            uniqueCandidates: prepared.unique, selectedDuplicates: [], session: fixture.session,
            progressController: controller
        )
        let batch = await fixture.committer.executeBatch(
            placements.placements, progressController: controller,
            enrichmentMode: .skipped, session: fixture.session, cancellationToken: token
        )
        let track = try XCTUnwrap(batch.records.first?.track)
        let path = try XCTUnwrap(track.mediaLocator.managedLibraryRelativePath)
        let destination = fixture.paths.rootURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = Data("preserve existing content".utf8)
        try existing.write(to: destination)

        let saved = await fixture.committer.saveImportedTracks(
            [track], progressController: controller, session: fixture.session, cancellationToken: token
        )
        XCTAssertNil(saved)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        _ = await fixture.committer.finishCancelledImport(
            session: fixture.session,
            importedRecords: batch.records,
            createdTrackIDs: batch.createdTrackIDs,
            to: nil,
            progressController: controller,
            totalCount: 1
        )
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    func testReferencedVideoCommitsMotionInLibraryAndLeavesAudioBesideSource() async throws {
        let fixture = try makeFixture(mode: .referenced)
        defer { fixture.cleanup() }
        let source = try await writeVideo(in: fixture.root, withAudio: true, fileType: .mov)
        let fingerprint = try ReferencedFileIdentityProvider().fingerprint(for: source)
        let sourceID = UUID()
        let locator = ReferencedFileLocator(
            fileBookmarkData: try SystemBookmarkResolver().refreshBookmark(for: source),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: source.lastPathComponent)],
            primarySourceID: sourceID, lastKnownPath: source.path, fingerprint: fingerprint
        )
        let candidate = ImportCandidate(
            progressID: source.path, displayName: source.lastPathComponent, fileURL: source,
            metadata: ImportPreview(title: "Video song", artist: "Artist", album: "", albumArtist: nil, duration: 0.1, lyrics: nil, artworkData: nil),
            discoveredFile: ImportDiscoveredFile(url: source, memberships: locator.sourceMemberships, primarySourceID: sourceID, fingerprint: fingerprint),
            trackID: UUID(), placement: .referenced(locator), existingDuplicateTrackID: nil,
            ncmOperationID: nil, ncmAssociation: nil, ncmLocator: nil, recoveryTrackID: nil,
            videoOutputDirectoryURL: fixture.root
        )
        let token = ImportCancellationToken()
        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let batch = await fixture.committer.executeBatch(
            [candidate], progressController: controller, enrichmentMode: .skipped,
            session: fixture.session, cancellationToken: token
        )
        XCTAssertTrue(batch.failures.isEmpty)
        let track = try XCTUnwrap(batch.records.first?.track)
        let saved = await fixture.committer.saveImportedTracks(
            [track], progressController: controller, session: fixture.session, cancellationToken: token
        )
        XCTAssertEqual(saved?.map(\.id), [track.id])
        let stored = try XCTUnwrap(track.mediaLocator.referencedFile)
        let audio = URL(fileURLWithPath: stored.lastKnownPath)
        XCTAssertEqual(
            audio.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path,
            source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(audio.pathExtension, "m4a")
        XCTAssertEqual(stored.videoSource?.fingerprint, fingerprint)
        let resolved = try LocalAudioResourceResolver(
            paths: fixture.paths,
            authorizedSourceRoots: [sourceID: AuthorizedSourceRoot(url: source, scopeOwner: .none)]
        ).resolve(track.mediaLocator)
        XCTAssertEqual(
            resolved.url.resolvingSymlinksInPath().standardizedFileURL.path,
            audio.resolvingSymlinksInPath().standardizedFileURL.path
        )
        resolved.lease.release()
        XCTAssertGreaterThan(try AVAudioFile(forReading: audio).length, 0)
        XCTAssertNotNil(track.motionArtwork?.resource(kind: "square", libraryRootURL: fixture.paths.rootURL))
        fixture.session.cleanupStaging()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        _ = await fixture.committer.finishCancelledImport(
            session: fixture.session, importedRecords: batch.records, createdTrackIDs: batch.createdTrackIDs,
            to: nil, progressController: controller, totalCount: 1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.trackFolderURL(for: track.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAudioOnlyMP4BecomesM4AWithoutMotionArtwork() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let wav = try writeWAV(named: "source.wav", in: fixture.root)
        let source = fixture.root.appendingPathComponent("audio-only.mp4")
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
        try await export.export(to: source, as: .m4a)
        let product = try await VideoMusicImporter.prepare(
            sourceURL: source, outputDirectory: fixture.session.stagingDirectoryURL,
            cancellationToken: ImportCancellationToken()
        )
        XCTAssertGreaterThan(try AVAudioFile(forReading: product.audioURL).length, 0)
        XCTAssertNil(product.motionURL)
        XCTAssertNil(product.artworkData)
    }

    func testPositiveDurationDoesNotBypassPlaybackDecoderValidation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("broken.mp4")
        try Data("not audio".utf8).write(to: source)
        XCTAssertThrowsError(try PerAudioFileImportTask.ensureAudioIsDecodable(source, knownDuration: 180))
    }

    func testReferencedVideoAudioUsesUniqueNameAndIsHiddenOnlyFromDirectoryScans() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try await writeVideo(in: fixture.root, withAudio: true)
        let collision = source.deletingPathExtension().appendingPathExtension("m4a")
        let existingData = Data("user file".utf8)
        try existingData.write(to: collision)
        let product = try await VideoMusicImporter.prepare(
            sourceURL: source, outputDirectory: fixture.session.stagingDirectoryURL,
            cancellationToken: ImportCancellationToken()
        )
        let identity = try ReferencedFileIdentityProvider().fingerprint(for: source)
        let output = try VideoMusicImporter.publishReferencedAudio(
            from: product.audioURL, beside: source, in: fixture.root,
            source: ReferencedVideoSource(path: source.path, fingerprint: identity)
        )
        XCTAssertNotEqual(output, collision)
        XCTAssertEqual(try Data(contentsOf: collision), existingData)
        XCTAssertTrue(VideoMusicImporter.isGeneratedAudio(output))
        let folder = await ImportInputScanner.scan(selectedURLs: [fixture.root], directorySources: [:])
        XCTAssertFalse(folder.files.contains { $0.url == output })
        let explicit = await ImportInputScanner.scan(selectedURLs: [output], directorySources: [:])
        XCTAssertEqual(explicit.files.map(\.url), [output])
        fixture.session.registerStagedAssets([], for: UUID(), generatedAudioURL: output)
        fixture.session.cleanupStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testManagedNCMConversionFailureIsReportedInsteadOfDiscarded() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("broken.ncm")
        try Data("not an NCM file".utf8).write(to: source)
        let outcome = await fixture.planner.resolveConversions(
            filesToImport: [],
            eligibleNCMFiles: [ImportDiscoveredFile(
                url: source, memberships: [], primarySourceID: nil, fingerprint: nil
            )],
            reusedTracks: [], reusedTrackIDs: [],
            session: fixture.session, cancellationToken: ImportCancellationToken(),
            progressController: BatchImportProgressDialogController(presentsWindow: false)
        )
        XCTAssertTrue(outcome.resolvedFiles.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failures.first?.url, source)
        XCTAssertFalse(outcome.failures.first?.message.isEmpty ?? true)
        XCTAssertFalse(outcome.cancelledAfterManagedConversion)
    }

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

    func testPlaylistDestinationKeepsSimilarityAsSuggestionAndDoesNotMutatePlaylist() async throws {
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
        let secondExisting = kmgccc_player.Track(
            title: "Golden Song",
            fileBookmarkData: Data(),
            mediaLocator: .managed(libraryRelativePath: "Tracks/existing-2/audio.m4a"),
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        secondExisting.artist = "Golden Artist"
        secondExisting.duration = 180
        _ = await fixture.repository.commitImportedTracks([existing, secondExisting])
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

        let playlist = try await fixture.repository.createPlaylist(name: "Drop Target")
        let controller = BatchImportProgressDialogController(presentsWindow: false)
        let token = ImportCancellationToken()

        let prepared = await fixture.planner.prepareCandidates(
            resolvedFiles: resolved,
            libraryTracks: libraryTracks,
            metadataOverride: nil,
            cancellationToken: token,
            progressController: controller
        )

        XCTAssertEqual(prepared.unique.count, 1)
        XCTAssertEqual(prepared.duplicates.count, 1, "similarity remains a user-facing suggestion")
        XCTAssertEqual(prepared.duplicateCandidates.count, 1)
        XCTAssertEqual(prepared.duplicates.first?.existingCount, 2)

        let playlistTracks = await fixture.repository.fetchTracks(in: playlist)
        XCTAssertTrue(playlistTracks.isEmpty, "planning must not mutate the destination playlist")
        let allTracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 2, "planning must neither merge nor import a similarity match")
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

    /// MP4 exercises AAC extraction; PCM-in-MOV exercises the encoder fallback.
    /// Both carry a rotated H.264 picture without checked-in media files.
    private func writeVideo(in directory: URL, withAudio: Bool, fileType: AVFileType = .mp4) async throws -> URL {
        let frames = directory.appendingPathComponent("frames-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: frames, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 16
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var optionalPixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32ARGB, nil, &optionalPixel), kCVReturnSuccess)
        let pixel = try XCTUnwrap(optionalPixel)
        CVPixelBufferLockBaseAddress(pixel, [])
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        memset(pixels, 128, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 30))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed)
        guard withAudio else { return frames }
        let wav = try writeWAV(named: "sound-\(UUID().uuidString).wav", in: directory)
        let movie = AVURLAsset(url: frames)
        let audio = AVURLAsset(url: wav)
        let sourceVideoTracks = try await movie.loadTracks(withMediaType: .video)
        let sourceAudioTracks = try await audio.loadTracks(withMediaType: .audio)
        let sourceVideo = try XCTUnwrap(sourceVideoTracks.first)
        let sourceAudio = try XCTUnwrap(sourceAudioTracks.first)
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let sound = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try video.insertTimeRange(try await sourceVideo.load(.timeRange), of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        try sound.insertTimeRange(try await sourceAudio.load(.timeRange), of: sourceAudio, at: .zero)
        let ext = fileType == .mov ? "mov" : "mp4"
        let url = directory.appendingPathComponent("song-\(UUID().uuidString).\(ext)")
        let preset = fileType == .mov ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: preset))
        try await export.export(to: url, as: fileType)
        return url
    }

    @MainActor
    private func makeFixture(mode: MusicLibraryMode = .managed) throws -> PlannerFixture {
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
        let backend: any kmgccc_player.LibraryStorageBackend
        if mode == .managed {
            backend = ManagedLocalBackend(paths: paths)
        } else {
            backend = ReferencedLocalBackend(
                paths: paths, sourceStore: ReferencedSourceStore(paths: paths), sourceScope: ReferencedSourceScope()
            )
        }
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

@MainActor
final class ImportStagingCleanupTests: XCTestCase {
    func testCleanupRemovesOnlyItsOwnMarkedStagingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let session = try ImportSession(paths: fixture.paths)
        let staging = session.stagingDirectoryURL
        try Data("staged".utf8).write(to: staging.appendingPathComponent("audio.mp3"))

        session.cleanupStaging()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCleanupKeepsStagingDirectoryWhoseMarkerWasRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let session = try ImportSession(paths: fixture.paths)
        let staging = session.stagingDirectoryURL
        try FileManager.default.removeItem(
            at: staging.appendingPathComponent(ImportStagingMarker.fileName)
        )
        try Data("foreign".utf8).write(to: staging.appendingPathComponent("keep.txt"))

        session.cleanupStaging()

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("keep.txt").path))
    }

    private struct Fixture {
        let root: URL
        let paths: LibraryPaths
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-staging-\(UUID().uuidString)", isDirectory: true)
            paths = LibraryPaths(rootURL: root)
            try paths.createRequiredDirectories()
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

/// Files without tags name their song as `歌手 - 歌名`; only that shape is read
/// as identity, and nothing else is invented from a file name.
final class ImportFileNameHintsTests: XCTestCase {
    private typealias Hints = ImportMetadataExtractor.FileNameMetadataHints

    func testSplitsArtistAndTitle() {
        let hints = Hints.hints(from: "福梦 - 背叛")
        XCTAssertEqual(hints.artist, "福梦")
        XCTAssertEqual(hints.title, "背叛")
    }

    func testKeepsEverythingAfterTheFirstSeparator() {
        let hints = Hints.hints(from: "A - B - C")
        XCTAssertEqual(hints.artist, "A")
        XCTAssertEqual(hints.title, "B - C")
    }

    func testSplitsJoinedArtistCredits() {
        let hints = Hints.hints(from: "福梦, CVLTE - 3MPTY")
        XCTAssertEqual(hints.artist, "福梦, CVLTE")
        XCTAssertEqual(hints.title, "3MPTY")
    }

    func testSplitsEnDash() {
        let hints = Hints.hints(from: "司南 – 天空")
        XCTAssertEqual(hints.artist, "司南")
        XCTAssertEqual(hints.title, "天空")
    }

    func testDoesNotReadTrackNumbersAsArtists() {
        XCTAssertEqual(Hints.hints(from: "01 - Intro"), .none)
        XCTAssertEqual(Hints.hints(from: "2019 - Live"), .none)
    }

    func testDoesNotSplitNamesWithoutBothSides() {
        XCTAssertEqual(Hints.hints(from: "背叛"), .none)
        XCTAssertEqual(Hints.hints(from: " - orphan"), .none)
    }
}

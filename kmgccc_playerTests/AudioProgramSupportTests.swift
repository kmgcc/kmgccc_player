import AppKit
import AVFoundation
import XCTest
@testable import kmgccc_player

final class AudioProgramSupportTests: XCTestCase {
    func testCueCreatesSeventeenIndependentRangesAndCredits() throws {
        let fixture = try Fixture(seconds: 17)
        defer { fixture.remove() }
        let cue = "TITLE \"合辑\"\nPERFORMER \"群星\"\nFILE \"album.wav\" WAVE\n" + (1...17).map { number in
            "TRACK \(String(format: "%02d", number)) AUDIO\nTITLE \"歌曲\(number)\"\nPERFORMER \"歌手\(number)\"\nINDEX 01 00:\(String(format: "%02d", number - 1)):00\n"
        }.joined()
        try Data(cue.utf8).write(to: fixture.cueURL)
        let tracks = try AudioProgramResolver.cueTracks(at: fixture.cueURL)
        XCTAssertEqual(tracks.count, 17)
        XCTAssertEqual(Set(tracks.map { $0.selection.logicalKey }).count, 17)
        XCTAssertEqual(Set(tracks.map(\.url)), [fixture.audioURL])
        XCTAssertEqual(tracks.first?.artist, "歌手1")
        XCTAssertEqual(tracks.last?.artist, "歌手17")
        XCTAssertTrue(tracks.allSatisfy { $0.albumArtist == "群星" && $0.selection.duration == 1 })
        for track in tracks {
            let resource = try AudioDecoderFactory.open(track.url, selection: track.selection)
            XCTAssertEqual(resource.length, 44_100)
        }
    }

    func testIndexZeroStaysInPreviousTrackAndLastTrackKeepsExactFileEnd() throws {
        let fixture = try Fixture(seconds: 3, extraFrames: 123)
        defer { fixture.remove() }
        let text = "FILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 00 00:01:00\nINDEX 01 00:02:00\n"
        let tracks = try AudioProgramResolver.parseCue(text, descriptorURL: fixture.cueURL)
        XCTAssertEqual(tracks[0].selection.length, 88_200)
        XCTAssertEqual(tracks[1].selection.length, 44_223)
        let resource = try AudioDecoderFactory.open(fixture.audioURL, selection: tracks[1].selection)
        XCTAssertEqual(resource.length, 44_223)
        try resource.provider.seek(to: resource.length - 1)
        XCTAssertEqual(try resource.provider.nextChunk(maxFrames: 32)?.frames, 1)
        XCTAssertNil(try resource.provider.nextChunk(maxFrames: 32))
    }

    func testCueRejectsMissingAudioDuplicateTracksAndOutOfBoundsRanges() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        for text in [
            "FILE \"missing.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00",
            "FILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 01 AUDIO\nINDEX 01 00:00:30",
            "FILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:02:00",
            "FILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:50\nTRACK 02 AUDIO\nINDEX 01 00:00:20",
        ] {
            XCTAssertThrowsError(try AudioProgramResolver.parseCue(text, descriptorURL: fixture.cueURL))
        }
    }

    func testUtf16AndGB18030CueText() throws {
        let text = "TITLE \"黄金十年\"\nPERFORMER \"群星\""
        var utf16 = Data([0xff, 0xfe])
        utf16.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        XCTAssertEqual(try AudioProgramResolver.decodeCue(utf16), text)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        XCTAssertEqual(try AudioProgramResolver.decodeCue(XCTUnwrap(text.data(using: encoding))), text)
    }

    func testCueEditsPreserveSourceGroupIdentity() throws {
        let fixture = try Fixture(seconds: 2)
        defer { fixture.remove() }
        let text = "FILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nTITLE \"原名\"\nINDEX 01 00:00:00"
        try Data(text.utf8).write(to: fixture.cueURL)
        let first = try AudioProgramResolver.cueTracks(at: fixture.cueURL)[0]
        try Data(text.replacingOccurrences(of: "原名", with: "新名").utf8).write(to: fixture.cueURL, options: .atomic)
        let second = try AudioProgramResolver.cueTracks(at: fixture.cueURL)[0]
        XCTAssertEqual(first.selection.logicalKey, second.selection.logicalKey)
        XCTAssertNotEqual(first.selection.descriptorFingerprint, second.selection.descriptorFingerprint)
    }

    func testContiguousRangesKeepThePhysicalDecoderCursor() throws {
        let source = CountingPCMProvider()
        let cursor = AudioCursorPCMProvider(source: source)
        let first = AudioRegionPCMProvider(source: cursor, start: 0, length: 100)
        let second = AudioRegionPCMProvider(source: cursor, start: 100, length: 100)
        XCTAssertEqual(try first.nextChunk(maxFrames: 100)?.frames, 100)
        XCTAssertEqual(try second.nextChunk(maxFrames: 100)?.data.first, 100)
        XCTAssertEqual(source.seekCount, 0)
        try second.seek(to: 20)
        XCTAssertEqual(try second.nextChunk(maxFrames: 1)?.data.first, 120)
        XCTAssertEqual(source.seekCount, 1)
    }

    func testDecoderProcessingFormatSupportsMultichannelAnalysisBuffers() throws {
        for channels in [1, 2, 6, 8, 64] {
            let provider = CountingPCMProvider(channels: channels, sampleRate: 192_000)
            let info = AudioDecoderInfo(sampleRate: 192_000, sourceSampleRate: 192_000,
                channels: channels, bitDepth: 24, frames: 200, codec: "PCM")
            let resource = try AudioDecoderResource(info: info, provider: provider)
            XCTAssertEqual(resource.processingFormat.channelCount, AVAudioChannelCount(channels))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: resource.processingFormat, frameCapacity: 32))
            try resource.read(into: buffer, frameCount: 32)
            XCTAssertEqual(buffer.frameLength, 32)
            XCTAssertNotNil(buffer.floatChannelData)
        }
    }

    func testProgramDSPPeekPreservesSourceReadAheadAndRangeBoundaries() throws {
        let source = CountingPCMProvider()
        let region = AudioRegionPCMProvider(source: AudioCursorPCMProvider(source: source), start: 20, length: 100)
        XCTAssertEqual(try region.nextChunk(maxFrames: 10)?.frames, 10)
        let seeks = source.seekCount
        let peeked = try region.peekChunk(at: 8, maxFrames: 16, restoringTo: 10)
        XCTAssertEqual(peeked?.data.first, 28)
        XCTAssertEqual(peeked?.data.last, 43)
        XCTAssertEqual(source.peekCount, 1)
        XCTAssertEqual(source.seekCount, seeks)
        XCTAssertEqual(try region.nextChunk(maxFrames: 1)?.data.first, 30)
        XCTAssertEqual(try region.peekChunk(at: 99, maxFrames: 16, restoringTo: 11)?.frames, 1)
        XCTAssertEqual(try region.nextChunk(maxFrames: 1)?.data.first, 31)
    }

    func testInvalidSelectionCannotOverflowOrReadPastMedia() throws {
        let invalid: [(Int64, Int64, Int64)] = [(0, 1, 0), (-1, 1, 75), (Int64.max, 10, 75), (10, 100, 75)]
        for values in invalid {
            let selection = AudioMediaSelection(kind: .cue, groupID: UUID(), trackNumber: 1,
                start: values.0, length: values.1, timeScale: values.2)
            XCTAssertThrowsError(try selection.decodedRange(sampleRate: 44_100, totalFrames: 44_100))
        }
    }

    func testProgramCommitVisibilityAndLibraryVersionRemainMonotonic() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let legacy = MusicLibraryManifest(displayName: "Test", mode: .managed)
        try legacy.write(to: paths.manifestURL)
        try SharedMediaAssetStore.enableFormat(at: paths)
        var renamed = legacy
        renamed.displayName = "Renamed"
        try renamed.write(to: paths.manifestURL)
        XCTAssertEqual(try MusicLibraryManifest.read(from: paths.manifestURL).schemaVersion, 2)
        let ids: Set<UUID> = [UUID(), UUID()]
        let transaction = try AudioProgramImportTransaction.begin(groupID: UUID(), trackIDs: ids, paths: paths)
        XCTAssertEqual(try AudioProgramImportTransaction.pendingTrackIDs(paths: paths), ids)
        XCTAssertThrowsError(try AudioProgramImportTransaction.begin(groupID: transaction.groupID, trackIDs: ids, paths: paths))
        try transaction.complete(paths: paths)
        XCTAssertTrue(try AudioProgramImportTransaction.pendingTrackIDs(paths: paths).isEmpty)
    }

    func testIncompleteGroupRecoveryRetainsFilesAndAllowsRetry() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let id = UUID()
        let folder = paths.trackFolderURL(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: folder.appendingPathComponent("meta.json"))
        let transaction = try AudioProgramImportTransaction.begin(groupID: UUID(), trackIDs: [id], paths: paths)
        try transaction.recover(paths: paths)
        XCTAssertTrue(try AudioProgramImportTransaction.pendingTrackIDs(paths: paths).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let saved = paths.recoveryRootURL.appendingPathComponent("IncompleteAudioPrograms/\(transaction.id.uuidString)/\(id.uuidString)/meta.json")
        XCTAssertEqual(try Data(contentsOf: saved), Data("partial".utf8))
    }

    func testInvalidTransactionRecordIsQuarantinedAndSkipped() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let good = try AudioProgramImportTransaction.begin(groupID: UUID(), trackIDs: [UUID()], paths: paths)
        let root = AudioProgramImportTransaction.root(paths)
        let invalidURL = root.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not a transaction".utf8).write(to: invalidURL)

        let loaded = try AudioProgramImportTransaction.load(paths: paths)

        XCTAssertEqual(loaded.map(\.id), [good.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidURL.path))
        let invalidRoot = root.appendingPathComponent("Invalid", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: invalidRoot.appendingPathComponent(invalidURL.lastPathComponent).path
        ))
        // A later load neither reads nor re-quarantines the isolated record.
        XCTAssertEqual(try AudioProgramImportTransaction.load(paths: paths).map(\.id), [good.id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: invalidRoot.appendingPathComponent(invalidURL.lastPathComponent).path
        ))
    }

    func testMissingRecoverySnapshotIsQuarantinedAndOtherRecordsStillRecover() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()

        let snapshot = AudioProgramRecoverySnapshot(
            id: UUID(), createdAt: Date(), oldTracks: [], newTrackIDs: [], playlists: []
        )
        try snapshot.write(to: paths)
        let recoverable = try AudioProgramImportTransaction.begin(
            groupID: UUID(), trackIDs: [], paths: paths, recoverySnapshotID: snapshot.id
        )
        let missingSnapshot = try AudioProgramImportTransaction.begin(
            groupID: UUID(), trackIDs: [], paths: paths, recoverySnapshotID: UUID()
        )

        AudioProgramImportTransaction.recoverInterruptedUpdates(paths: paths)

        let root = AudioProgramImportTransaction.root(paths)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(recoverable.id.uuidString).json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(missingSnapshot.id.uuidString).json").path
        ))
        let invalidRoot = root.appendingPathComponent("Invalid", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: invalidRoot.appendingPathComponent("\(missingSnapshot.id.uuidString).json").path
        ))
        XCTAssertTrue(try AudioProgramImportTransaction.load(paths: paths).isEmpty)
        XCTAssertTrue(try AudioProgramImportTransaction.pendingTrackIDs(paths: paths).isEmpty)
    }

    func testCommittedTransactionRecordsAreRemovedOnLoad() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let transaction = try AudioProgramImportTransaction.begin(groupID: UUID(), trackIDs: [UUID()], paths: paths)
        try transaction.complete(paths: paths)
        let recordURL = AudioProgramImportTransaction.root(paths)
            .appendingPathComponent("\(transaction.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))

        XCTAssertTrue(try AudioProgramImportTransaction.load(paths: paths).isEmpty)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
        XCTAssertTrue(try AudioProgramImportTransaction.pendingTrackIDs(paths: paths).isEmpty)
    }

    func testRegistryIncludesNativeFormatsAndDescriptors() {
        XCTAssertTrue(AudioFormatSupport.codecLibraryExtensions.isSubset(of: AudioFormatSupport.playableExtensions))
        XCTAssertTrue(AudioFormatSupport.importableExtensions.isSuperset(of: ["cue", "iso", "w64", "wave", "aifc", "rf64"]))
    }

    func testMultiFileCueKeepsOneGroupWithIndependentFileRanges() throws {
        let fixture = try Fixture(seconds: 2)
        defer { fixture.remove() }
        let secondURL = fixture.folder.appendingPathComponent("第二张.wav")
        try FileManager.default.copyItem(at: fixture.audioURL, to: secondURL)
        let cue = "TITLE \"合辑\"\nFILE \"album.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nFILE \"第二张.wav\" WAVE\nTRACK 02 AUDIO\nINDEX 01 00:00:00\n"
        let tracks = try AudioProgramResolver.parseCue(cue, descriptorURL: fixture.cueURL)
        XCTAssertEqual(tracks.map(\.url), [fixture.audioURL, secondURL])
        XCTAssertEqual(Set(tracks.map { $0.selection.groupID }).count, 1)
        XCTAssertEqual(tracks.map { $0.selection.start }, [0, 0])
        XCTAssertEqual(tracks.map { $0.selection.duration }, [2, 2])
    }

    func testLogicalRemovalRollbackPreservesEarlierRemovals() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let group = UUID()
        let first = AudioMediaSelection(kind: .cue, groupID: group, trackNumber: 1, start: 0, length: 75, timeScale: 75)
        let second = AudioMediaSelection(kind: .cue, groupID: group, trackNumber: 2, start: 75, length: 75, timeScale: 75)
        try LogicalAudioTrackTombstones.add(first, paths: paths)
        let inserted = try LogicalAudioTrackTombstones.add([first, second], paths: paths)
        XCTAssertEqual(inserted, [second.logicalKey])
        try LogicalAudioTrackTombstones.remove(inserted, paths: paths)
        XCTAssertEqual(try LogicalAudioTrackTombstones.load(paths: paths), [first.logicalKey])
    }

    @MainActor
    func testProgramAlbumUsesItsSharedCompilationArtist() {
        let group = UUID()
        let tracks = ["歌手甲", "歌手乙"].enumerated().map { index, artist in
            let track = Track(title: "歌曲\(index)", artist: artist, album: "合辑", albumArtist: "群星")
            var properties = TrackAudioProperties()
            properties.mediaSelection = AudioMediaSelection(kind: .cue, groupID: group,
                trackNumber: index + 1, start: Int64(index * 75), length: 75, timeScale: 75,
                albumTitle: "合辑", albumArtist: "群星")
            track.audioProperties = properties
            return track
        }
        let sections = LibraryNormalization.buildAlbumGrouping(tracks: tracks).sections
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.artistName, "群星")
    }

    @MainActor
    func testProgramImportProgressSeparatesPhysicalFilesAndLogicalTracks() {
        var details: [String] = []
        let controller = BatchImportProgressDialogController(presentsWindow: false, onProgress: { details.append($0) })
        controller.setMediaCounts(physicalFiles: 1, logicalTracks: 17)
        controller.update(stage: .scanning, progress: 0.2, detail: "正在读取歌曲", completedCount: 3, totalCount: 17)
        XCTAssertEqual(details.last, "1 个音频文件，17 首歌曲\n正在读取歌曲")
        controller.closeNow()
    }

    @MainActor
    func testProgramNotificationsUpdatePendingGroupsAndResetWithTheLibrary() {
        let state = UIStateViewModel()
        defer { state.resetLibraryNotices() }
        let id = UUID()
        let original = AudioProgramExpansionProposal(id: id, sourceURL: URL(fileURLWithPath: "/album.cue"),
            oldTrackIDs: [UUID()], trackCount: 3)
        state.recordAudioProgramProposals([original])
        let updated = AudioProgramExpansionProposal(id: id, sourceURL: original.sourceURL,
            oldTrackIDs: original.oldTrackIDs, trackCount: 4)
        state.recordAudioProgramProposals([updated])
        XCTAssertEqual(state.pendingAudioExpansions, [updated])
        XCTAssertEqual(state.sidebarNotice?.destination, .audioProgramExpansion)
        XCTAssertEqual(state.sidebarNotice?.tag, .audioPrograms)
        state.dismissSidebarNotice(tag: .audioPrograms)
        XCTAssertNil(state.sidebarNotice)
        state.resetLibraryNotices()
        XCTAssertTrue(state.pendingAudioExpansions.isEmpty)
    }

    @MainActor
    func testAlbumOrderingFailuresUseOneActionableSidebarNotice() {
        let state = UIStateViewModel()
        defer { state.resetLibraryNotices() }
        let failures = ["first", "second"].map {
            AlbumOrderingFailure(albumKey: $0, albumTitle: $0, artist: "艺人",
                reason: .albumNotFound, detail: "专辑曲序待整理")
        }
        state.applyAlbumOrderingOutcome(AlbumOrderingOutcome(failures: failures))
        XCTAssertEqual(state.sidebarNotice?.tag, .albumOrdering)
        XCTAssertEqual(state.sidebarNotice?.destination, .albumOrderingFailures)
        XCTAssertEqual(state.sidebarNotice?.message, "2 张专辑的曲序待整理")
        XCTAssertEqual(state.sidebarNotice?.isSticky, true)
        state.applyAlbumOrderingOutcome(AlbumOrderingOutcome(failures: [failures[0]]))
        XCTAssertEqual(state.albumOrderingFailures.count, 2)
        state.removeAlbumOrderingFailure(albumKey: "first")
        XCTAssertEqual(state.sidebarNotice?.message, "1 张专辑的曲序待整理")
        state.applyAlbumOrderingOutcome(AlbumOrderingOutcome(updatedAlbumKeys: ["second"]))
        XCTAssertTrue(state.albumOrderingFailures.isEmpty)
        XCTAssertNil(state.sidebarNotice)
    }

    @MainActor
    func testAlbumOrderingNoticeKeepsConcurrentLibraryWarnings() {
        let state = UIStateViewModel()
        defer { state.resetLibraryNotices() }
        state.showSidebarNotice("发现可分轨的整轨音频", style: .warning,
            actionTitle: "查看分轨", destination: .audioProgramExpansion,
            isSticky: true, tag: .audioPrograms)
        let failure = AlbumOrderingFailure(albumKey: "album", albumTitle: "专辑", artist: "艺人",
            reason: .requestFailed, detail: "专辑查询失败")
        state.applyAlbumOrderingOutcome(AlbumOrderingOutcome(failures: [failure]))
        XCTAssertEqual(state.sidebarNotice?.tag, .audioPrograms)
        state.applyAlbumOrderingOutcome(AlbumOrderingOutcome(failures: [failure]))
        state.dismissSidebarNotice(tag: .audioPrograms)
        XCTAssertEqual(state.sidebarNotice?.tag, .albumOrdering)
        state.clearAlbumOrderingFailures()
        XCTAssertNil(state.sidebarNotice)
    }

    @MainActor
    func testProgramFolderArtworkUsesConventionalCoverNames() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128,
            pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let cover = fixture.folder.appendingPathComponent("Cover.PNG")
        try data.write(to: cover)
        XCTAssertNotNil(ImportMetadataExtractor.extractProgramFolderArtwork(beside: fixture.audioURL))
        try FileManager.default.moveItem(at: cover, to: fixture.folder.appendingPathComponent("unrelated.png"))
        XCTAssertNil(ImportMetadataExtractor.extractProgramFolderArtwork(beside: fixture.audioURL))
    }

    @MainActor
    func testDeletingOneLogicalTrackRetainsSharedAudioUntilTheLastReference() throws {
        let fixture = try Fixture(seconds: 2)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let media = try fixture.makeOwnedMedia(paths: paths)
        let service = LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService())
        let tracks = (1...2).map { number in
            Track(title: "歌曲\(number)", mediaLocator: .managed(libraryRelativePath: media.relativePath),
                libraryRootSnapshot: paths.rootURL.path)
        }
        for track in tracks { XCTAssertTrue(service.writeImportedTrackSidecar(for: track)) }
        XCTAssertTrue(service.deleteTrackFolder(trackID: tracks[0].id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.url.path))
        XCTAssertTrue(service.deleteTrackFolder(trackID: tracks[1].id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.url.path))
    }

    func testActiveImportRetainsItsSharedMediaDuringCollection() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let media = try fixture.makeOwnedMedia(paths: paths)
        let release = SharedMediaAssetStore.retainMedia(media.relativePath, paths: paths)
        try SharedMediaAssetStore.pruneUnreferenced(paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.url.path))
        release()
        try SharedMediaAssetStore.pruneUnreferenced(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.url.path))
    }

    @MainActor
    func testRecoverySnapshotRetainsSharedAudioAfterLogicalDeletion() throws {
        let fixture = try Fixture(seconds: 1)
        defer { fixture.remove() }
        let paths = LibraryPaths(rootURL: fixture.folder.appendingPathComponent("Library"))
        try paths.createRequiredDirectories()
        let media = try fixture.makeOwnedMedia(paths: paths)
        let service = LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService())
        let track = Track(title: "恢复记录", mediaLocator: .managed(libraryRelativePath: media.relativePath),
            libraryRootSnapshot: paths.rootURL.path)
        XCTAssertTrue(service.writeImportedTrackSidecar(for: track))
        let saved = AudioProgramRecoverySnapshot.WholeTrack(id: track.id,
            sidecar: try Data(contentsOf: paths.trackMetaURL(for: track.id)), replacementMediaPath: media.relativePath)
        let snapshot = AudioProgramRecoverySnapshot(id: UUID(), createdAt: Date(), oldTracks: [saved],
            newTrackIDs: [], playlists: [])
        try snapshot.write(to: paths)
        XCTAssertTrue(service.deleteTrackFolder(trackID: track.id))
        try SharedMediaAssetStore.pruneUnreferenced(paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.url.path))
        try snapshot.restoreTrackFiles(paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.trackMetaURL(for: track.id).path))
    }

    private struct Fixture {
        let folder: URL
        var audioURL: URL { folder.appendingPathComponent("album.wav") }
        var cueURL: URL { folder.appendingPathComponent("album.cue") }
        init(seconds: Int, extraFrames: Int = 0) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
            let frames = AVAudioFrameCount(seconds * 44_100 + extraFrames)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    channels[channel].initialize(repeating: 0, count: Int(frames))
                }
            }
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        func makeOwnedMedia(paths: LibraryPaths) throws -> (relativePath: String, url: URL) {
            let relativePath = "MediaAssets/\(UUID().uuidString)/version/audio.wav"
            let url = try XCTUnwrap(paths.libraryURL(from: relativePath))
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: audioURL, to: url)
            try SharedMediaAssetStore.markOwnership(folder: parent, audioFileName: url.lastPathComponent)
            return (relativePath, url)
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }
}

private nonisolated final class CountingPCMProvider: RendererPCMProvider, @unchecked Sendable {
    let sourceChannelCount: Int
    let sourceSampleRate: Double
    let totalFrames: Int64 = 200
    var position = 0
    var seekCount = 0
    var peekCount = 0
    init(channels: Int = 1, sampleRate: Double = 44_100) {
        sourceChannelCount = channels
        sourceSampleRate = sampleRate
    }
    func nextChunk(maxFrames: AVAudioFrameCount) throws -> CanonicalPCM? {
        let count = min(Int(maxFrames), 200 - position)
        guard count > 0 else { return nil }
        let samples = (position..<(position + count)).flatMap { frame in
            [Float](repeating: Float(frame), count: sourceChannelCount)
        }
        position += count
        return CanonicalPCM(frames: count, channelCount: sourceChannelCount, sampleRate: sourceSampleRate, data: samples)
    }
    func seek(to position: Int64) throws { self.position = Int(position); seekCount += 1 }
    func peekChunk(at position: AVAudioFramePosition, maxFrames: AVAudioFrameCount,
        restoringTo restorePosition: AVAudioFramePosition) throws -> CanonicalPCM? {
        peekCount += 1
        let count = min(Int(maxFrames), Int(totalFrames - position))
        guard count > 0 else { return nil }
        let samples = (Int(position)..<(Int(position) + count)).flatMap { frame in
            [Float](repeating: Float(frame), count: sourceChannelCount)
        }
        return CanonicalPCM(frames: count, channelCount: sourceChannelCount, sampleRate: sourceSampleRate, data: samples)
    }
}

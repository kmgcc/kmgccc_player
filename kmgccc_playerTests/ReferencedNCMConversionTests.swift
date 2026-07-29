import AVFoundation
import Foundation
@testable import kmgccc_player
import XCTest

private final class NCMTestBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { true }
    func stopAccessing(_: URL) {}
}

@MainActor
private final class NCMTestParentAuthorizer: NCMParentDirectoryAuthorizing {
    var error: Error?
    private(set) var calls = 0

    func authorizeParentDirectory(of sourceURL: URL) async throws -> NCMParentDirectoryAuthorization {
        calls += 1
        if let error { throw error }
        let parent = sourceURL.deletingLastPathComponent()
        return NCMParentDirectoryAuthorization(
            directoryURL: parent,
            bookmarkData: Data(parent.path.utf8),
            lease: .none,
            releasesLease: false
        )
    }
}

@MainActor
private final class CommitFailureGate {
    private(set) var calls = 0

    func failOnce(operationID _: UUID, trackID _: UUID) throws {
        calls += 1
        if calls == 1 { throw CocoaError(.fileWriteUnknown) }
    }
}

private actor ConversionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
final class ReferencedNCMConversionTests: XCTestCase {
    func testFolderSourceWritesBesideNCMAndPersistsReservationAssociation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sourceID = UUID()
        fixture.scope.add(sourceID: sourceID, url: fixture.sourceRoot, lease: .none)
        let input = try fixture.input(memberships: [
            kmgccc_player.ReferencedSourceMembership(sourceID: sourceID, relativePath: "song.ncm")
        ], primarySourceID: sourceID)

        let output = try await fixture.service.convert(input)

        XCTAssertEqual(output.result.audioFileURL.deletingLastPathComponent(), fixture.sourceRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.ncmURL.path))
        XCTAssertEqual(output.locator.primarySourceID, sourceID)
        XCTAssertEqual(output.locator.sourceMemberships.first?.relativePath, "Converted.mp3")
        XCTAssertEqual(output.locator.ncmSourceIdentity, input.fingerprint?.identity)
        let reservedBeforeCommit = try await fixture.service.isReserved(url: output.result.audioFileURL)
        XCTAssertTrue(reservedBeforeCommit)

        try await fixture.service.markCommitted(operationID: output.operationID, trackID: fixture.trackID)
        let reservedAfterCommit = try await fixture.service.isReserved(url: output.result.audioFileURL)
        XCTAssertFalse(reservedAfterCommit)

        let reloaded = NCMConversionRegistry(paths: fixture.paths)
        let record = try await reloaded.committedRecord(matching: try XCTUnwrap(input.fingerprint))
        XCTAssertEqual(record?.trackID, fixture.trackID)
        XCTAssertEqual(record?.expectedOutputPath, output.result.audioFileURL.path)
    }

    func testSingleFileRequiresParentAuthorizationAndFailureIsItemScoped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let input = try fixture.input()
        fixture.authorizer.error = ReferencedNCMConversionError.parentAuthorizationDenied

        do {
            _ = try await fixture.service.convert(input)
            XCTFail("Expected parent authorization failure")
        } catch {
            XCTAssertEqual(error as? ReferencedNCMConversionError, .parentAuthorizationDenied)
        }
        XCTAssertEqual(fixture.authorizer.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.ncmURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path), ["song.ncm"])
    }

    func testConflictDoesNotOverwriteOrCreateNumberedCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let existing = fixture.sourceRoot.appendingPathComponent("Converted.mp3")
        let original = Data("existing".utf8)
        try original.write(to: existing)

        do {
            _ = try await fixture.service.convert(try fixture.input())
            XCTFail("Expected output conflict")
        } catch {
            XCTAssertEqual(error as? ReferencedNCMConversionError, .outputConflict("Converted.mp3"))
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceRoot.appendingPathComponent("Converted (1).mp3").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path).contains { $0.hasPrefix(".kmgccc-ncm-") })
    }

    func testFailureAndCancellationCleanTemporaryOutputAndKeepNCM() async throws {
        let fixture = try Fixture(convert: { _, directory in
            let partial = directory.appendingPathComponent("song.mp3")
            try Data("partial".utf8).write(to: partial)
            throw CancellationError()
        })
        defer { fixture.cleanup() }

        do {
            _ = try await fixture.service.convert(try fixture.input())
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.ncmURL.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path).contains { $0.hasPrefix(".kmgccc-ncm-") })
    }

    func testConcurrentSameInputHasSingleOutputAndActiveReservationBlocksRetry() async throws {
        let fixture = try Fixture(convert: { source, directory in
            try await Task.sleep(for: .milliseconds(150))
            return try Fixture.makeResult(source: source, directory: directory)
        })
        defer { fixture.cleanup() }
        let input = try fixture.input()

        async let first = fixture.service.convert(input)
        try await Task.sleep(for: .milliseconds(30))
        do {
            _ = try await fixture.service.convert(input)
            XCTFail("Expected active reservation")
        } catch ReferencedNCMConversionError.activeReservation {
        } catch ReferencedNCMConversionError.recoveryOutputMissing {
        }
        let output = try await first
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.sourceRoot.path).filter { $0 == "Converted.mp3" }.count, 1)
        let isReserved = try await fixture.service.isReserved(url: output.result.audioFileURL)
        XCTAssertTrue(isReserved)
    }

    func testOutputReadyRecoveryReusesOperationOutputAndTrackAfterCommitFailure() async throws {
        let counter = ConversionCounter()
        let gate = CommitFailureGate()
        let fixture = try Fixture(
            convert: { source, directory in
                await counter.increment()
                return try Fixture.makeResult(source: source, directory: directory)
            },
            commitOverride: { operationID, trackID in
                try gate.failOnce(operationID: operationID, trackID: trackID)
            }
        )
        defer { fixture.cleanup() }
        let input = try fixture.input()

        let first = try await fixture.service.convert(input)
        try await fixture.service.associateTrack(operationID: first.operationID, trackID: fixture.trackID)
        do {
            try await fixture.service.markCommitted(operationID: first.operationID, trackID: fixture.trackID)
            XCTFail("Expected injected registry commit failure")
        } catch {}

        let recovered = try await fixture.service.convert(input)
        XCTAssertEqual(recovered.operationID, first.operationID)
        XCTAssertEqual(recovered.trackID, fixture.trackID)
        XCTAssertEqual(recovered.result.audioFileURL, first.result.audioFileURL)
        let conversionCount = await counter.count
        XCTAssertEqual(conversionCount, 1)
        try await fixture.service.associateTrack(operationID: recovered.operationID, trackID: fixture.trackID)
        try await fixture.service.markCommitted(operationID: recovered.operationID, trackID: fixture.trackID)

        let registry = NCMConversionRegistry(paths: fixture.paths)
        let committed = try await registry.committedRecord(matching: try XCTUnwrap(input.fingerprint))
        XCTAssertEqual(committed?.id, first.operationID)
        XCTAssertEqual(committed?.trackID, fixture.trackID)
        XCTAssertEqual(committed?.state, .committed)
    }

    func testFingerprintStableAndFallbackDomainsNeverCrossMatch() {
        let timestamp = 123.0
        let bytes = Data([1, 2, 3])
        let stableA = kmgccc_player.ReferencedFileFingerprint(
            identity: kmgccc_player.ReferencedFileIdentity(volumeUUID: "A", resourceIdentifierArchive: bytes),
            fileSize: 10,
            modifiedAt: timestamp
        )
        let stableB = kmgccc_player.ReferencedFileFingerprint(
            identity: kmgccc_player.ReferencedFileIdentity(volumeUUID: "B", resourceIdentifierArchive: bytes),
            fileSize: 10,
            modifiedAt: timestamp
        )
        let stableDifferentResource = kmgccc_player.ReferencedFileFingerprint(
            identity: kmgccc_player.ReferencedFileIdentity(volumeUUID: "A", resourceIdentifierArchive: Data([9])),
            fileSize: 10,
            modifiedAt: timestamp
        )
        let missingIdentity = kmgccc_player.ReferencedFileFingerprint(
            identity: nil,
            fileSize: 10,
            modifiedAt: timestamp
        )
        let incompleteIdentity = kmgccc_player.ReferencedFileFingerprint(
            identity: kmgccc_player.ReferencedFileIdentity(volumeUUID: "A", resourceIdentifierArchive: nil),
            fileSize: 10,
            modifiedAt: timestamp
        )

        XCTAssertFalse(NCMConversionRegistry.sameFingerprint(stableA, missingIdentity))
        XCTAssertFalse(NCMConversionRegistry.sameFingerprint(stableA, incompleteIdentity))
        XCTAssertFalse(NCMConversionRegistry.sameFingerprint(stableA, stableB))
        XCTAssertFalse(NCMConversionRegistry.sameFingerprint(stableA, stableDifferentResource))
        XCTAssertTrue(NCMConversionRegistry.sameFingerprint(missingIdentity, incompleteIdentity))
    }

    func testSchemaSevenRoundTripKeepsTransactionAssociation() throws {
        let association = NCMConversionAssociation(
            operationID: UUID(), sourceIdentity: ReferencedFileIdentity(volumeUUID: "v"),
            sourcePath: "/source/song.ncm", outputIdentity: ReferencedFileIdentity(volumeUUID: "v2"),
            outputPath: "/source/song.mp3"
        )
        let sidecar = TrackSidecar(
            id: UUID(), title: "Song", artist: "Artist", album: "Album", duration: 1,
            addedAt: Date(timeIntervalSince1970: 1), importedAt: nil, lyricsTimeOffsetMs: nil,
            originalFilePath: nil, audioFileName: nil, artworkFileName: nil,
            lyricsFileName: nil, lyricsType: nil, ttmlLyricsFileName: nil, ncmSourcePath: nil,
            ncmConversionAssociation: association,
            mediaLocator: .referenced(ReferencedFileLocator(fileBookmarkData: Data("b".utf8)))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TrackSidecar.self, from: encoder.encode(sidecar)).ncmConversionAssociation, association)
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let paths: kmgccc_player.LibraryPaths
    let sourceRoot: URL
    let ncmURL: URL
    let scope = ReferencedSourceScope()
    let authorizer = NCMTestParentAuthorizer()
    let resolver = NCMTestBookmarkResolver()
    let service: ReferencedNCMConversionService
    let trackID = UUID()

    init(
        convert: ReferencedNCMConversionService.Convert? = nil,
        commitOverride: ReferencedNCMConversionService.Commit? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = kmgccc_player.LibraryPaths(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        ncmURL = sourceRoot.appendingPathComponent("song.ncm")
        try paths.createRequiredDirectories()
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("ncm-source".utf8).write(to: ncmURL)
        service = ReferencedNCMConversionService(
            paths: paths, sourceScope: scope, parentAuthorizer: authorizer,
            bookmarkResolver: resolver,
            convert: convert ?? { source, directory in try Self.makeResult(source: source, directory: directory) },
            commitOverride: commitOverride,
            validate: { url in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size <= 0 { throw ReferencedNCMConversionError.invalidOutput }
            }
        )
    }

    func input(
        memberships: [kmgccc_player.ReferencedSourceMembership] = [],
        primarySourceID: UUID? = nil
    ) throws -> kmgccc_player.ImportDiscoveredFile {
        kmgccc_player.ImportDiscoveredFile(
            url: ncmURL, memberships: memberships, primarySourceID: primarySourceID,
            fingerprint: try kmgccc_player.ReferencedFileIdentityProvider().fingerprint(for: ncmURL)
        )
    }

    nonisolated static func makeResult(source _: URL, directory: URL) throws -> NCMConversionResult {
        let output = directory.appendingPathComponent("song.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
        buffer.frameLength = 441
        try file.write(from: buffer)
        return NCMConversionResult(
            audioFileURL: output, format: .mp3,
            metadata: NCMMetadata(
                musicName: "Converted", artist: [["Artist"]], album: "Album",
                albumPic: "", format: "mp3", bitrate: 320_000, duration: 10
            ),
            coverData: nil
        )
    }

    func cleanup() {
        scope.close()
        try? FileManager.default.removeItem(at: root)
    }
}

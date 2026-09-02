import Foundation
@testable import kmgccc_player
import XCTest

final class SourceReconnectMatcherTests: XCTestCase {
    private let matcher = SourceReconnectMatcher()

    func testRootRenameAndVolumeNameChangeKeepRelativePathMatch() {
        let trackID = UUID()
        let old = expected(
            trackID: trackID,
            path: "Album/song.flac",
            fingerprint: fingerprint(volume: "old-volume", resource: "old")
        )
        let candidate = candidate(
            root: "/Volumes/Renamed Music",
            path: "Album/song.flac",
            fingerprint: fingerprint(volume: "new-volume", resource: "new")
        )

        let plan = matcher.makePlan(
            rootURL: candidate.rootURL,
            expected: [old],
            candidates: [candidate]
        )

        XCTAssertEqual(plan.matches.map(\.trackID), [trackID])
        XCTAssertEqual(plan.matches.first?.basis, .relativePath)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertTrue(plan.unmatchedTrackIDs.isEmpty)
    }

    func testRelativeDirectoryMoveUsesStablePhysicalIdentity() {
        let trackID = UUID()
        let identity = kmgccc_player.ReferencedFileIdentity(
            volumeUUID: "volume",
            resourceIdentifierArchive: Data("resource".utf8)
        )
        let old = expected(
            trackID: trackID,
            path: "Old/song.flac",
            fingerprint: .init(identity: identity, fileSize: 1_000, modifiedAt: 1)
        )
        let moved = candidate(
            root: "/Music",
            path: "New/Deep/song.flac",
            fingerprint: .init(identity: identity, fileSize: 1_000, modifiedAt: 2)
        )

        let plan = matcher.makePlan(
            rootURL: moved.rootURL,
            expected: [old],
            candidates: [moved]
        )

        XCTAssertEqual(plan.matches.first?.candidate.relativePath, "New/Deep/song.flac")
        XCTAssertEqual(plan.matches.first?.basis, .physicalIdentity)
    }

    func testVolumeChangeFallsBackToUniqueSizeAndDuration() {
        let trackID = UUID()
        let old = expected(
            trackID: trackID,
            path: "Old/song.wav",
            fingerprint: fingerprint(volume: "volume-a", resource: "resource-a")
        )
        let copied = candidate(
            root: "/Volumes/New",
            path: "Moved/song.wav",
            fingerprint: fingerprint(volume: "volume-b", resource: "resource-b"),
            duration: 180.4
        )

        let plan = matcher.makePlan(
            rootURL: copied.rootURL,
            expected: [old],
            candidates: [copied]
        )

        XCTAssertEqual(plan.matches.first?.basis, .fingerprint)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testSameNameAndFingerprintCandidatesRequireExplicitConflictChoice() {
        let trackID = UUID()
        let old = expected(
            trackID: trackID,
            path: "Missing/song.wav",
            fingerprint: .init(fileSize: 4_096, modifiedAt: 10)
        )
        let first = candidate(
            root: "/Music",
            path: "A/song.wav",
            fingerprint: .init(fileSize: 4_096, modifiedAt: 20)
        )
        let second = candidate(
            root: "/Music",
            path: "B/song.wav",
            fingerprint: .init(fileSize: 4_096, modifiedAt: 30)
        )

        let plan = matcher.makePlan(
            rootURL: first.rootURL,
            expected: [old],
            candidates: [first, second]
        )

        XCTAssertTrue(plan.matches.isEmpty)
        XCTAssertEqual(plan.conflicts.map(\.expected.trackID), [trackID])
        XCTAssertEqual(
            plan.conflicts.first?.candidates.map(\.relativePath),
            ["A/song.wav", "B/song.wav"]
        )
    }

    func testPartialMatchKeepsUnresolvedTrackAndPreparationIsMutationFree() {
        let matchedID = UUID()
        let missingID = UUID()
        let input = [
            expected(trackID: matchedID, path: "Found.wav"),
            expected(trackID: missingID, path: "Missing.wav"),
        ]
        let candidates = [candidate(root: "/Music", path: "Found.wav")]

        let plan = matcher.makePlan(
            rootURL: URL(fileURLWithPath: "/Music", isDirectory: true),
            expected: input,
            candidates: candidates
        )

        XCTAssertEqual(plan.matches.map(\.trackID), [matchedID])
        XCTAssertEqual(plan.unmatchedTrackIDs, [missingID])
        XCTAssertEqual(input.map(\.relativePath), ["Found.wav", "Missing.wav"])
        XCTAssertEqual(candidates.map(\.relativePath), ["Found.wav"])
    }

    private func expected(
        trackID: UUID,
        path: String,
        fingerprint: kmgccc_player.ReferencedFileFingerprint? = .init(
            fileSize: 1_000,
            modifiedAt: 1
        ),
        duration: Double = 180
    ) -> SourceReconnectExpectedFile {
        SourceReconnectExpectedFile(
            trackID: trackID,
            relativePath: path,
            fingerprint: fingerprint,
            duration: duration
        )
    }

    private func candidate(
        root: String,
        path: String,
        fingerprint: kmgccc_player.ReferencedFileFingerprint = .init(
            fileSize: 1_000,
            modifiedAt: 1
        ),
        duration: Double = 180
    ) -> SourceReconnectCandidateFile {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        return SourceReconnectCandidateFile(
            rootURL: rootURL,
            url: rootURL.appendingPathComponent(path),
            relativePath: path,
            fingerprint: fingerprint,
            duration: duration
        )
    }

    private func fingerprint(
        volume: String,
        resource: String
    ) -> kmgccc_player.ReferencedFileFingerprint {
        .init(
            identity: .init(
                volumeUUID: volume,
                resourceIdentifierArchive: Data(resource.utf8)
            ),
            fileSize: 1_000,
            modifiedAt: 1
        )
    }
}

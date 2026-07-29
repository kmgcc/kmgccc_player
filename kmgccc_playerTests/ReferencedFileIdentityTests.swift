import Foundation
@testable import kmgccc_player
import XCTest

final class ReferencedFileIdentityTests: XCTestCase {
    func testVolumeOnlyIdentityFallsBackToFingerprint() {
        let volumeOnly = ReferencedFileIdentity(volumeUUID: "volume", resourceIdentifierArchive: nil)
        let first = ReferencedFileFingerprint(identity: volumeOnly, fileSize: 10, modifiedAt: 1)
        let second = ReferencedFileFingerprint(identity: volumeOnly, fileSize: 20, modifiedAt: 2)
        XCTAssertNotEqual(ReferencedPhysicalIdentityKey(first), ReferencedPhysicalIdentityKey(second))
    }

    func testSameArchiveOnDifferentVolumesIsNotEqual() {
        let archive = Data("resource".utf8)
        let first = ReferencedFileFingerprint(
            identity: .init(volumeUUID: "volume-a", resourceIdentifierArchive: archive),
            fileSize: 10,
            modifiedAt: 1
        )
        let second = ReferencedFileFingerprint(
            identity: .init(volumeUUID: "volume-b", resourceIdentifierArchive: archive),
            fileSize: 10,
            modifiedAt: 1
        )
        XCTAssertNotEqual(ReferencedPhysicalIdentityKey(first), ReferencedPhysicalIdentityKey(second))
    }

    func testArchiveWithoutVolumeFallsBackToEachFingerprint() {
        let archive = Data("resource".utf8)
        let first = ReferencedFileFingerprint(
            identity: .init(volumeUUID: nil, resourceIdentifierArchive: archive),
            fileSize: 10,
            modifiedAt: 1
        )
        let second = ReferencedFileFingerprint(
            identity: .init(volumeUUID: nil, resourceIdentifierArchive: archive),
            fileSize: 20,
            modifiedAt: 2
        )
        XCTAssertNotEqual(ReferencedPhysicalIdentityKey(first), ReferencedPhysicalIdentityKey(second))
        let completeIdentity = ReferencedFileFingerprint(
            identity: .init(volumeUUID: "volume", resourceIdentifierArchive: archive),
            fileSize: 30,
            modifiedAt: 3
        )
        XCTAssertNotEqual(ReferencedPhysicalIdentityKey(first), ReferencedPhysicalIdentityKey(completeIdentity))
    }

    func testSameVolumeAndArchiveIsEqualRegardlessOfFingerprint() {
        let identity = ReferencedFileIdentity(
            volumeUUID: "volume",
            resourceIdentifierArchive: Data("resource".utf8)
        )
        let first = ReferencedFileFingerprint(identity: identity, fileSize: 10, modifiedAt: 1)
        let second = ReferencedFileFingerprint(identity: identity, fileSize: 20, modifiedAt: 2)
        XCTAssertEqual(ReferencedPhysicalIdentityKey(first), ReferencedPhysicalIdentityKey(second))
    }

    func testHardLinkIdentityAndArchiveAreStableAcrossCalls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.mp3")
        let link = root.appendingPathComponent("link.mp3")
        try Data("audio".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)
        let provider = ReferencedFileIdentityProvider()

        let first = try provider.fingerprint(for: original)
        let second = try provider.fingerprint(for: original)
        let hardLink = try provider.fingerprint(for: link)
        XCTAssertEqual(first.identity?.resourceIdentifierArchive, second.identity?.resourceIdentifierArchive)
        XCTAssertEqual(ReferencedPhysicalIdentityKey(first), ReferencedPhysicalIdentityKey(hardLink))
    }
}

import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class MP3EmbeddedTagServiceTests: XCTestCase {
    func testWritesID3v24FieldsAndLeavesMPEGFrameBytesUntouched() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-tags-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let mpegAudio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x55, count: 256)
        try mpegAudio.write(to: url)

        let result = try MP3EmbeddedTagService.patch(
            at: url,
            fields: [
                "title": "标题",
                "artist": "Artist",
                "comment": "A comment",
                "lyrics": "First line\nSecond line"
            ]
        )

        XCTAssertEqual(result.title, "标题")
        XCTAssertEqual(result.artist, "Artist")
        XCTAssertEqual(result.comment, "A comment")
        XCTAssertEqual(result.lyrics, "First line\nSecond line")
        let written = try Data(contentsOf: url)
        let tagSize = Int(written[6]) << 21 | Int(written[7]) << 14 | Int(written[8]) << 7 | Int(written[9])
        XCTAssertEqual(written.subdata(in: (10 + tagSize)..<written.count), mpegAudio)
    }

    func testPatchCanClearAFieldAndPreservesOtherTags() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-tags-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try (Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0x33, count: 64)).write(to: url)

        _ = try MP3EmbeddedTagService.patch(at: url, fields: ["title": "Keep", "artist": "Clear"])
        let result = try MP3EmbeddedTagService.patch(
            at: url,
            fields: ["artist": Optional<String>.none, "album": "Album"]
        )

        XCTAssertEqual(result.title, "Keep")
        XCTAssertNil(result.artist)
        XCTAssertEqual(result.album, "Album")
    }

    func testRejectsOtherFormatsWithoutChangingTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-tags-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("RIFF-not-an-MP3".utf8)
        try original.write(to: url)

        XCTAssertThrowsError(try MP3EmbeddedTagService.patch(at: url, fields: ["title": "Nope"]))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

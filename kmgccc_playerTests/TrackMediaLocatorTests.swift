import Foundation
import XCTest

final class TrackMediaLocatorTests: XCTestCase {
    func testTaggedManagedEncodingIsStable() throws {
        let locator = TrackMediaLocator.managed(libraryRelativePath: "Tracks/id/audio.flac")
        let data = try JSONEncoder().encode(locator)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["kind"] as? String, "managed")
        XCTAssertNil(object["referenced"])
        XCTAssertEqual(
            (object["managed"] as? [String: Any])?["libraryRelativePath"] as? String,
            "Tracks/id/audio.flac"
        )
        XCTAssertEqual(try JSONDecoder().decode(TrackMediaLocator.self, from: data), locator)
    }

    func testTaggedReferencedEncodingHasNoSynthesizedAssociatedValueKeys() throws {
        let locator = TrackMediaLocator.referenced(ReferencedFileLocator(
            fileBookmarkData: Data([1, 2, 3]),
            lastKnownPath: "/Volumes/Music/song.flac"
        ))
        let data = try JSONEncoder().encode(locator)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"kind\":\"referenced\""))
        XCTAssertTrue(json.contains("\"referenced\""))
        XCTAssertFalse(json.contains("_0"))
        XCTAssertEqual(try JSONDecoder().decode(TrackMediaLocator.self, from: data), locator)
    }

    func testUnknownMalformedAndTraversalLocatorsAreRejected() {
        for json in [
            #"{"kind":"future","managed":{"libraryRelativePath":"Tracks/id/audio.flac"}}"#,
            #"{"kind":"managed","managed":{"libraryRelativePath":"../outside.flac"}}"#,
            #"{"kind":"referenced","referenced":{"fileBookmarkData":"","sourceMemberships":[],"lastKnownPath":"/tmp/song"}}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                TrackMediaLocator.self,
                from: Data(json.utf8)
            ))
        }
    }

    func testReferencedEncodingRejectsPrimaryOutsideMemberships() {
        let locator = TrackMediaLocator.referenced(ReferencedFileLocator(
            fileBookmarkData: Data([1]),
            sourceMemberships: [.init(sourceID: UUID(), relativePath: "song.flac")],
            primarySourceID: UUID()
        ))
        XCTAssertThrowsError(try JSONEncoder().encode(locator))
    }

    func testLegacySidecarSchemasOneThroughSixMapToManagedLocator() throws {
        let id = UUID()
        for schema in 1...6 {
            let versionFields: String
            switch schema {
            case 1:
                versionFields = "\"playCount\":4"
            case 2:
                versionFields = "\"genreTags\":\"Rock, Pop\",\"playCount\":2"
            case 3:
                versionFields = "\"preferenceStats\":{\"playCount\":3,\"completePlayCount\":1,\"skipCount\":0,\"quickSkipCount\":0,\"totalPlayedSeconds\":120,\"manualLikeState\":\"none\",\"preferenceScoreCache\":0,\"effectiveWeightCache\":1}"
            case 4:
                versionFields = "\"lyricsTimeOffsetMs\":125"
            case 5:
                versionFields = "\"albumArtist\":\"Album Artist\",\"language\":\"zh\""
            default:
                versionFields = "\"metadataSource\":\"qqmusic\",\"metadataConfidence\":0.9"
            }
            let json = """
            {"schemaVersion":\(schema),"id":"\(id.uuidString)","title":"Song","artist":"Artist","album":"Album","duration":1,"addedAt":"2026-01-01T00:00:00Z","audioFileName":"audio.flac",\(versionFields)}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sidecar = try decoder.decode(TrackSidecar.self, from: Data(json.utf8))
            XCTAssertEqual(
                sidecar.mediaLocator,
                .managed(libraryRelativePath: "Tracks/\(id.uuidString)/audio.flac")
            )
        }
    }

    func testLegacySidecarMissingRequiredFieldsFailsDeterministically() {
        let id = UUID()
        let invalidFixtures = [
            "{\"schemaVersion\":6,\"id\":\"\(id)\",\"title\":\"Song\",\"artist\":\"Artist\",\"album\":\"Album\",\"addedAt\":\"2026-01-01T00:00:00Z\",\"audioFileName\":\"audio.flac\"}",
            "{\"schemaVersion\":6,\"id\":\"\(id)\",\"title\":\"Song\",\"artist\":\"Artist\",\"album\":\"Album\",\"duration\":1,\"audioFileName\":\"audio.flac\"}",
            "{\"schemaVersion\":6,\"id\":\"\(id)\",\"title\":\"Song\",\"artist\":\"Artist\",\"album\":\"Album\",\"duration\":1,\"addedAt\":\"2026-01-01T00:00:00Z\"}",
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for fixture in invalidFixtures {
            XCTAssertThrowsError(try decoder.decode(TrackSidecar.self, from: Data(fixture.utf8)))
        }
    }
}

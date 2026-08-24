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

    func testLegacySidecarSchemasSevenAndEightDecodeWithNilSchemaNineFields() throws {
        let id = UUID()
        let creditID = UUID()
        for schema in 7...8 {
            let versionFields: String
            switch schema {
            case 7:
                versionFields = ""
            default:
                versionFields = """
                ,"artistCredits":[{"id":"\(creditID.uuidString)","displayName":"Artist","canonicalName":"artist","role":"primary"}]
                """
            }
            let json = """
            {"schemaVersion":\(schema),"id":"\(id.uuidString)","title":"Song","artist":"Artist","album":"Album","duration":1,"addedAt":"2026-01-01T00:00:00Z"\(versionFields),"mediaLocator":{"kind":"managed","managed":{"libraryRelativePath":"Tracks/\(id.uuidString)/audio.flac"}},"availability":"available"}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sidecar = try decoder.decode(TrackSidecar.self, from: Data(json.utf8))
            XCTAssertEqual(sidecar.schemaVersion, schema)
            XCTAssertNil(sidecar.musicBrainzReleaseID)
            XCTAssertNil(sidecar.embeddedMetadataSnapshot)
            XCTAssertNil(sidecar.userMetadataOverride)
            XCTAssertEqual(sidecar.enrichmentSuggestions, [])
        }
    }

    func testLegacyReferencedSidecarDecodesWithNilPerLocationFields() throws {
        let sidecar = try legacyReferencedSidecar(schemaVersion: 7)
        let locator = try XCTUnwrap(sidecar.mediaLocator.referencedFile)
        let primary = locator.locations[0]
        XCTAssertNil(primary.audioProperties)
        XCTAssertNil(primary.contentDigest)
        XCTAssertNil(primary.availabilityRaw)
        XCTAssertNil(locator.primaryAudioProperties)
        XCTAssertNil(locator.primaryContentDigest)
        XCTAssertNil(locator.primaryAvailabilityRaw)
    }

    func testSchemaNineRoundTripPreservesEveryNewField() throws {
        let primaryID = UUID()
        let alternateID = UUID()
        let suggestionID = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_760_000_000)
        let editedAt = Date(timeIntervalSince1970: 1_760_000_100)
        let suggestionCreatedAt = Date(timeIntervalSince1970: 1_760_000_200)
        let primaryDigest = String(repeating: "b4e2", count: 16)
        let alternateDigest = String(repeating: "a3f1", count: 16)

        let sidecar = TrackSidecar(
            id: UUID(),
            title: "Song",
            artist: "Artist",
            album: "Album",
            musicBrainzReleaseID: "4d1c8a54-9f61-4e0b-9d5f-3f7c2b1a0e99",
            duration: 180,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            importedAt: nil,
            lyricsTimeOffsetMs: nil,
            originalFilePath: nil,
            audioFileName: nil,
            artworkFileName: nil,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil,
            ncmSourcePath: nil,
            mediaLocator: .referenced(ReferencedFileLocator(
                fileBookmarkData: Data([1, 2, 3]),
                lastKnownPath: "/Volumes/Music/song.flac",
                alternateLocations: [
                    ReferencedTrackLocation(
                        id: alternateID,
                        fileBookmarkData: Data([4, 5]),
                        lastKnownPath: "/Volumes/Backup/song.flac",
                        audioProperties: TrackAudioProperties(
                            format: "FLAC",
                            bitrateKbps: 986,
                            sampleRateHz: 44_100,
                            bitDepth: 16,
                            channelCount: 2
                        ),
                        contentDigest: alternateDigest,
                        availabilityRaw: TrackAvailability.stale.rawValue
                    )
                ],
                primaryLocationID: primaryID,
                primaryAudioProperties: TrackAudioProperties(format: "MP3", bitrateKbps: 320),
                primaryContentDigest: primaryDigest,
                primaryAvailabilityRaw: TrackAvailability.available.rawValue
            )),
            embeddedMetadataSnapshot: EmbeddedMetadataSnapshot(
                title: "Embedded Title",
                artistDisplay: "Embedded Artist",
                album: "Embedded Album",
                albumArtist: "Embedded Album Artist",
                releaseYear: 2024,
                compilation: false,
                musicBrainzReleaseID: "embedded-mbid",
                durationSeconds: 179.5,
                capturedAt: capturedAt
            ),
            userMetadataOverride: UserMetadataOverride(
                title: "User Title",
                artistDisplay: "User Artist",
                album: "User Album",
                albumArtist: "User Album Artist",
                releaseYear: 1999,
                editedAt: editedAt
            ),
            enrichmentSuggestions: [
                EnrichmentSuggestion(
                    id: suggestionID,
                    source: "qq-music",
                    title: "Suggested Title",
                    artistDisplay: "Suggested Artist",
                    album: "Suggested Album",
                    albumArtist: "Suggested Album Artist",
                    releaseYear: 2020,
                    compilation: true,
                    musicBrainzReleaseID: "suggested-mbid",
                    confidence: 0.87,
                    createdAt: suggestionCreatedAt
                )
            ],
            audioProperties: TrackAudioProperties(
                format: "MP3",
                bitrateKbps: 320,
                sampleRateHz: 44_100,
                channelCount: 2
            )
        )

        XCTAssertEqual(sidecar.schemaVersion, TrackSidecar.currentSchemaVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TrackSidecar.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, TrackSidecar.currentSchemaVersion)
        XCTAssertEqual(decoded.musicBrainzReleaseID, sidecar.musicBrainzReleaseID)
        XCTAssertEqual(decoded.embeddedMetadataSnapshot, sidecar.embeddedMetadataSnapshot)
        XCTAssertEqual(decoded.userMetadataOverride, sidecar.userMetadataOverride)
        XCTAssertEqual(decoded.enrichmentSuggestions, sidecar.enrichmentSuggestions)
        XCTAssertEqual(
            decoded.audioProperties,
            TrackAudioProperties(format: "MP3", bitrateKbps: 320, sampleRateHz: 44_100, channelCount: 2),
            "Managed root-level audio properties round-trip at schema 9"
        )

        let locator = try XCTUnwrap(decoded.mediaLocator.referencedFile)
        XCTAssertEqual(locator.primaryLocationID, primaryID)
        XCTAssertEqual(locator.primaryAudioProperties, TrackAudioProperties(format: "MP3", bitrateKbps: 320))
        XCTAssertEqual(locator.primaryContentDigest, primaryDigest)
        XCTAssertEqual(locator.primaryAvailabilityRaw, TrackAvailability.available.rawValue)

        let primary = locator.locations[0]
        XCTAssertEqual(primary.id, primaryID)
        XCTAssertEqual(primary.audioProperties?.format, "MP3")
        XCTAssertEqual(primary.contentDigest, primaryDigest)

        let alternate = try XCTUnwrap(locator.alternateLocations.first)
        XCTAssertEqual(alternate.id, alternateID)
        XCTAssertEqual(alternate.audioProperties, TrackAudioProperties(
            format: "FLAC",
            bitrateKbps: 986,
            sampleRateHz: 44_100,
            bitDepth: 16,
            channelCount: 2
        ))
        XCTAssertEqual(alternate.contentDigest, alternateDigest)
        XCTAssertEqual(alternate.availabilityRaw, TrackAvailability.stale.rawValue)
    }

    func testLegacyPrimaryLocationIDBecomesStableAcrossRedecodeAndSaveCycle() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let firstDecode = try legacyReferencedSidecar(schemaVersion: 7)
        let firstLocator = try XCTUnwrap(firstDecode.mediaLocator.referencedFile)
        let stableID = firstLocator.primaryLocationID
        XCTAssertEqual(firstLocator.locations[0].id, stableID)
        XCTAssertEqual(firstLocator.locations[0].id, stableID)

        let reencoded = try encoder.encode(firstDecode)
        let secondDecode = try decoder.decode(TrackSidecar.self, from: reencoded)
        let secondLocator = try XCTUnwrap(secondDecode.mediaLocator.referencedFile)
        XCTAssertEqual(secondLocator.primaryLocationID, stableID)

        let thirdDecode = try decoder.decode(TrackSidecar.self, from: reencoded)
        let thirdLocator = try XCTUnwrap(thirdDecode.mediaLocator.referencedFile)
        XCTAssertEqual(thirdLocator.primaryLocationID, stableID)

        // The generated id is bookkeeping only: two decodes of the same
        // pre-schema-9 payload stay logically equal despite different ids.
        let otherDecode = try legacyReferencedSidecar(schemaVersion: 7)
        let otherLocator = try XCTUnwrap(otherDecode.mediaLocator.referencedFile)
        XCTAssertNotEqual(otherLocator.primaryLocationID, stableID)
        XCTAssertEqual(otherLocator, firstLocator)
    }

    // MARK: - EffectiveMetadata projection (spec §10.1)

    func testEffectiveMetadataWithEmptyLayersFallsBackToFileNameForTitleOnly() {
        let projected = EffectiveMetadata.project(
            sidecar: makeLayeredSidecar(),
            fileNameFallback: "  01 - Opening.flac "
        )
        XCTAssertEqual(projected.title, "01 - Opening.flac")
        XCTAssertNil(projected.artistDisplay)
        XCTAssertNil(projected.album)
        XCTAssertNil(projected.albumArtist)
        XCTAssertNil(projected.releaseYear)
        XCTAssertNil(projected.compilation)
        XCTAssertNil(projected.musicBrainzReleaseID)

        let withoutFallback = EffectiveMetadata.project(sidecar: makeLayeredSidecar())
        XCTAssertEqual(withoutFallback.title, "")
    }

    func testEffectiveMetadataPriorityOverrideBeatsEmbeddedBeatsSuggestion() {
        let sidecar = makeLayeredSidecar(
            embedded: EmbeddedMetadataSnapshot(
                title: "Embedded Title",
                artistDisplay: "Embedded Artist",
                album: nil,
                albumArtist: "Embedded Album Artist",
                releaseYear: nil,
                compilation: false,
                musicBrainzReleaseID: nil,
                durationSeconds: nil,
                capturedAt: Date(timeIntervalSince1970: 10)
            ),
            override: UserMetadataOverride(
                title: "User Title",
                artistDisplay: nil,
                album: "User Album",
                albumArtist: nil,
                releaseYear: 2001,
                editedAt: Date(timeIntervalSince1970: 20)
            ),
            suggestions: [
                EnrichmentSuggestion(
                    source: "qq-music",
                    title: "Suggested Title",
                    artistDisplay: "Suggested Artist",
                    album: "Suggested Album",
                    albumArtist: "Suggested Album Artist",
                    releaseYear: 2020,
                    compilation: true,
                    musicBrainzReleaseID: "suggested-mbid",
                    confidence: 0.9,
                    createdAt: Date(timeIntervalSince1970: 5)
                )
            ]
        )

        let projected = EffectiveMetadata.project(sidecar: sidecar, fileNameFallback: "fallback.flac")
        XCTAssertEqual(projected.title, "User Title")
        XCTAssertEqual(projected.artistDisplay, "Embedded Artist")
        XCTAssertEqual(projected.album, "User Album")
        XCTAssertEqual(projected.albumArtist, "Embedded Album Artist")
        XCTAssertEqual(projected.releaseYear, 2001)
        XCTAssertEqual(projected.compilation, false)
        XCTAssertEqual(projected.musicBrainzReleaseID, "suggested-mbid")
    }

    func testEffectiveMetadataPrefersRootMusicBrainzIDOverLayers() {
        let sidecar = makeLayeredSidecar(
            musicBrainzReleaseID: "root-mbid",
            embedded: EmbeddedMetadataSnapshot(
                musicBrainzReleaseID: "embedded-mbid",
                capturedAt: Date(timeIntervalSince1970: 10)
            ),
            suggestions: [
                EnrichmentSuggestion(
                    source: "folder-inference",
                    musicBrainzReleaseID: "suggested-mbid",
                    confidence: 1,
                    createdAt: Date(timeIntervalSince1970: 5)
                )
            ]
        )

        XCTAssertEqual(
            EffectiveMetadata.project(sidecar: sidecar).musicBrainzReleaseID,
            "root-mbid"
        )
    }

    func testEffectiveMetadataPicksHighestConfidenceSuggestionWithDeterministicTies() {
        let olderID = UUID()
        let newerID = UUID()
        let tiedLowerID = UUID()
        let tiedHigherID = UUID()

        let byConfidence = makeLayeredSidecar(suggestions: [
            EnrichmentSuggestion(
                id: olderID,
                source: "qq-music",
                title: "Weak",
                confidence: 0.4,
                createdAt: Date(timeInterval: 99, since: .distantPast)
            ),
            EnrichmentSuggestion(
                id: newerID,
                source: "folder-inference",
                title: "Strong",
                confidence: 0.8,
                createdAt: Date(timeInterval: 1, since: .distantPast)
            ),
        ])
        XCTAssertEqual(EffectiveMetadata.project(sidecar: byConfidence).title, "Strong")

        let byRecency = makeLayeredSidecar(suggestions: [
            EnrichmentSuggestion(
                id: olderID,
                source: "qq-music",
                title: "Older",
                confidence: 0.8,
                createdAt: Date(timeInterval: 1, since: .distantPast)
            ),
            EnrichmentSuggestion(
                id: newerID,
                source: "folder-inference",
                title: "Newer",
                confidence: 0.8,
                createdAt: Date(timeInterval: 99, since: .distantPast)
            ),
        ])
        XCTAssertEqual(EffectiveMetadata.project(sidecar: byRecency).title, "Newer")

        let fullTie = makeLayeredSidecar(suggestions: [
            EnrichmentSuggestion(
                id: tiedHigherID,
                source: "qq-music",
                title: "Higher ID",
                confidence: 0.8,
                createdAt: Date(timeInterval: 50, since: .distantPast)
            ),
            EnrichmentSuggestion(
                id: tiedLowerID,
                source: "folder-inference",
                title: "Lower ID",
                confidence: 0.8,
                createdAt: Date(timeInterval: 50, since: .distantPast)
            ),
        ])
        let expectedWinner = tiedHigherID.uuidString > tiedLowerID.uuidString ? "Higher ID" : "Lower ID"
        XCTAssertEqual(EffectiveMetadata.project(sidecar: fullTie).title, expectedWinner)
    }

    func testEffectiveMetadataIgnoresBlankLayerValues() {
        let sidecar = makeLayeredSidecar(
            embedded: EmbeddedMetadataSnapshot(
                title: "   ",
                artistDisplay: "",
                album: "Embedded Album",
                capturedAt: Date(timeIntervalSince1970: 10)
            ),
            suggestions: [
                EnrichmentSuggestion(
                    source: "qq-music",
                    title: "Suggested Title",
                    confidence: 0.5,
                    createdAt: Date(timeIntervalSince1970: 5)
                )
            ]
        )

        let projected = EffectiveMetadata.project(sidecar: sidecar)
        XCTAssertEqual(projected.title, "Suggested Title")
        XCTAssertEqual(projected.album, "Embedded Album")
        XCTAssertNil(projected.artistDisplay)
    }

    // MARK: - Fixtures

    private func legacyReferencedSidecar(schemaVersion: Int) throws -> TrackSidecar {
        let id = UUID()
        let json = """
        {"schemaVersion":\(schemaVersion),"id":"\(id.uuidString)","title":"Song","artist":"Artist","album":"Album","duration":1,"addedAt":"2026-01-01T00:00:00Z","mediaLocator":{"kind":"referenced","referenced":{"fileBookmarkData":"AQID","sourceMemberships":[],"lastKnownPath":"/Volumes/Music/song.flac"}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TrackSidecar.self, from: Data(json.utf8))
    }

    private func makeLayeredSidecar(
        musicBrainzReleaseID: String? = nil,
        embedded: EmbeddedMetadataSnapshot? = nil,
        override: UserMetadataOverride? = nil,
        suggestions: [EnrichmentSuggestion]? = nil
    ) -> TrackSidecar {
        TrackSidecar(
            id: UUID(),
            title: "Base",
            artist: "Base Artist",
            album: "Base Album",
            musicBrainzReleaseID: musicBrainzReleaseID,
            duration: 1,
            addedAt: Date(timeIntervalSince1970: 0),
            importedAt: nil,
            lyricsTimeOffsetMs: nil,
            originalFilePath: nil,
            audioFileName: nil,
            artworkFileName: nil,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil,
            ncmSourcePath: nil,
            embeddedMetadataSnapshot: embedded,
            userMetadataOverride: override,
            enrichmentSuggestions: suggestions
        )
    }
}

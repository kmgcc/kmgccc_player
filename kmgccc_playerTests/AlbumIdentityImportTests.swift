//
//  AlbumIdentityImportTests.swift
//  kmgccc_playerTests
//
//  §10.3/§10.4 wave: synthetic tag-frame parsing, folder-inference
//  suggestion lifecycle, NCM audio-property mapping and per-location /
//  managed audio-properties round-trips.
//

import AVFoundation
import Foundation
@testable import kmgccc_player
import XCTest

@MainActor
final class AlbumIdentityImportTests: XCTestCase {
    // MARK: - Synthetic tag frames

    private func id3Item(
        key: String,
        value: String? = nil,
        number: NSNumber? = nil,
        keySpace: String = AVMetadataKeySpace("id3").rawValue
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier("\(keySpace)/\(key)")
        item.keySpace = AVMetadataKeySpace(keySpace)
        item.key = key as NSString
        if let value { item.value = value as NSString }
        if let number { item.value = number }
        return item
    }

    private func txxxItem(description: String, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = AVMetadataKeySpace("id3")
        item.key = "TXXX:\(description)" as NSString
        item.value = value as NSString
        return item
    }

    // MARK: MusicBrainz release id

    func testMusicBrainzReleaseIDParsesAlbumAndReleaseDescriptions() async {
        let mbid = "4d1c8a54-9f61-4e0b-9d5f-3f7c2b1a0e99"
        let inlineAlbum = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            id3Item(key: "TXXX", value: "MusicBrainz Album Id \(mbid)"),
        ])
        XCTAssertEqual(inlineAlbum, mbid, "inline album-id variant")
        let inlineLowercase = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            id3Item(key: "TXXX", value: "musicbrainz release id \(mbid) extra"),
        ])
        XCTAssertEqual(inlineLowercase, mbid, "lowercase release-id variant")
        let keyedFrame = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            txxxItem(description: "MusicBrainz Release Id", value: mbid),
        ])
        XCTAssertEqual(keyedFrame, mbid, "keyed TXXX frame variant")
        let iTunesFreeform = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            id3Item(
                key: "----:com.apple.iTunes:MusicBrainz Album Id",
                value: mbid,
                keySpace: AVMetadataKeySpace("its").rawValue
            ),
        ])
        XCTAssertEqual(iTunesFreeform, mbid, "iTunes freeform variant")
    }

    func testMusicBrainzReleaseIDIgnoresNoiseAndNonUUIDValues() async {
        let empty = await ImportMetadataExtractor.musicBrainzReleaseID(in: [])
        XCTAssertNil(empty)
        let noise = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            id3Item(key: "TXXX", value: "hello world"),
        ])
        XCTAssertNil(noise)
        let markerWithoutUUID = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            id3Item(key: "TXXX", value: "MusicBrainz but not an identifier"),
        ])
        XCTAssertNil(markerWithoutUUID)
        let wrongFrame = await ImportMetadataExtractor.musicBrainzReleaseID(in: [
            id3Item(key: "TIT2", value: "MusicBrainz 4d1c8a54-9f61-4e0b-9d5f-3f7c2b1a0e99"),
        ])
        XCTAssertNil(wrongFrame)
    }

    // MARK: Compilation flag

    func testCompilationFlagReadsTCMPAndCPIL() async {
        let tcmpOne = await ImportMetadataExtractor.compilationFlag(in: [id3Item(key: "TCMP", value: "1")])
        XCTAssertEqual(tcmpOne, true)
        let tcmpZero = await ImportMetadataExtractor.compilationFlag(in: [id3Item(key: "TCMP", value: "0")])
        XCTAssertEqual(tcmpZero, false)
        let cpilTrue = await ImportMetadataExtractor.compilationFlag(in: [
            id3Item(key: "CPIL", number: 1, keySpace: AVMetadataKeySpace("its").rawValue),
        ])
        XCTAssertEqual(cpilTrue, true)
        let absent = await ImportMetadataExtractor.compilationFlag(in: [])
        XCTAssertNil(absent)
        let blank = await ImportMetadataExtractor.compilationFlag(in: [id3Item(key: "TCMP", value: "")])
        XCTAssertNil(blank)
    }

    // MARK: Release year

    func testReleaseYearParsesTYERAndTDRCAndDayKeys() async {
        let tyer = await ImportMetadataExtractor.releaseYear(in: [id3Item(key: "TYER", value: "1998")])
        XCTAssertEqual(tyer, 1998)
        let tdrc = await ImportMetadataExtractor.releaseYear(in: [id3Item(key: "TDRC", value: "2024-03-01")])
        XCTAssertEqual(tdrc, 2024)
        let dayBare = await ImportMetadataExtractor.releaseYear(in: [
            id3Item(key: "©day", value: "2024", keySpace: AVMetadataKeySpace("its").rawValue),
        ])
        XCTAssertEqual(dayBare, 2024)
        let dayISO = await ImportMetadataExtractor.releaseYear(in: [
            id3Item(key: "day", value: "2019-11-08T00:00:00Z", keySpace: AVMetadataKeySpace("its").rawValue),
        ])
        XCTAssertEqual(dayISO, 2019)
        let absent = await ImportMetadataExtractor.releaseYear(in: [])
        XCTAssertNil(absent)
        let garbage = await ImportMetadataExtractor.releaseYear(in: [id3Item(key: "TYER", value: "garbage")])
        XCTAssertNil(garbage)
    }

    // MARK: - §10.4 folder inference

    private func makeCandidate(
        progressID: String,
        directory: URL,
        album: String,
        artist: String,
        compilation: Bool? = nil
    ) -> ImportCandidate {
        ImportCandidate(
            progressID: progressID,
            displayName: "\(progressID).flac",
            fileURL: directory.appendingPathComponent("\(progressID).flac"),
            metadata: ImportPreview(
                title: progressID,
                artist: artist,
                album: album,
                albumArtist: nil,
                duration: 180,
                lyrics: nil,
                artworkData: nil
            ),
            discoveredFile: ImportDiscoveredFile(
                url: directory.appendingPathComponent("\(progressID).flac"),
                memberships: [],
                primarySourceID: nil,
                fingerprint: nil
            ),
            trackID: nil,
            placement: nil,
            existingDuplicateTrackID: nil,
            ncmOperationID: nil,
            ncmAssociation: nil,
            ncmLocator: nil,
            recoveryTrackID: nil,
            embeddedSnapshot: kmgccc_player.EmbeddedMetadataSnapshot(
                title: progressID,
                artistDisplay: artist,
                album: album,
                albumArtist: nil,
                compilation: compilation,
                capturedAt: Date()
            )
        )
    }

    func testFolderInferenceEmitsOneSuggestionPerTrackForMixedArtistBatch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VA Mix", isDirectory: true)
        let candidates = [
            makeCandidate(progressID: "a", directory: directory, album: "Greatest Hits", artist: "Alpha"),
            makeCandidate(progressID: "b", directory: directory, album: "Greatest Hits", artist: "Beta"),
        ]

        let suggestions = ImportPlanner.folderInferenceSuggestions(from: candidates)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(Set(suggestions.keys), ["a", "b"])
        for suggestion in suggestions.values.flatMap({ $0 }) {
            XCTAssertEqual(suggestion.compilation, true)
            XCTAssertEqual(suggestion.source, "folder-inference")
            XCTAssertEqual(suggestion.confidence, 0.6)
            XCTAssertEqual(suggestion.album, "Greatest Hits")
        }
        XCTAssertNotEqual(suggestions["a"]?.first?.id, suggestions["b"]?.first?.id)
    }

    func testFolderInferenceIsDeterministicAcrossRunsForDeduplication() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VA Mix", isDirectory: true)
        let candidates = [
            makeCandidate(progressID: "a", directory: directory, album: "Greatest Hits", artist: "Alpha"),
            makeCandidate(progressID: "b", directory: directory, album: "Greatest Hits", artist: "Beta"),
        ]

        let firstPass = ImportPlanner.folderInferenceSuggestions(from: candidates, now: Date(timeIntervalSince1970: 100))
        let secondPass = ImportPlanner.folderInferenceSuggestions(from: candidates, now: Date(timeIntervalSince1970: 200))

        var merged: [kmgccc_player.EnrichmentSuggestion] = []
        merged.appendDeduplicatingByIDs(Array(firstPass.values.flatMap { $0 }))
        merged.appendDeduplicatingByIDs(Array(secondPass.values.flatMap { $0 }))
        XCTAssertEqual(merged.count, 2, "Re-running the pass must not duplicate stored suggestions")
    }

    func testFolderInferenceSkipsExplicitMarkerAndUniformArtists() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tagged", isDirectory: true)
        let explicitlyTagged = [
            makeCandidate(progressID: "a", directory: directory, album: "Hits", artist: "Alpha", compilation: true),
            makeCandidate(progressID: "b", directory: directory, album: "Hits", artist: "Beta", compilation: true),
        ]
        XCTAssertTrue(ImportPlanner.folderInferenceSuggestions(from: explicitlyTagged).isEmpty)

        let uniformArtists = [
            makeCandidate(progressID: "c", directory: directory, album: "Hits", artist: "Alpha"),
            makeCandidate(progressID: "d", directory: directory, album: "Hits", artist: "Alpha"),
        ]
        XCTAssertTrue(ImportPlanner.folderInferenceSuggestions(from: uniformArtists).isEmpty)

        let singleTrack = [
            makeCandidate(progressID: "e", directory: directory, album: "Hits", artist: "Alpha"),
        ]
        XCTAssertTrue(ImportPlanner.folderInferenceSuggestions(from: singleTrack).isEmpty)
    }

    // MARK: - NCM audio properties

    func testNCMMetadataMapsToAudioProperties() {
        let properties = ImportPlanner.audioProperties(fromNCM: NCMMetadata(
            musicName: "Song",
            artist: [["Artist"]],
            album: "Album",
            albumPic: "",
            format: "flac",
            bitrate: 986_000,
            duration: 181_000
        ))
        XCTAssertEqual(properties.format, "FLAC")
        XCTAssertEqual(properties.bitrateKbps, 986)
        XCTAssertNil(properties.sampleRateHz)
        XCTAssertNil(properties.bitDepth)
        XCTAssertNil(properties.channelCount)

        let silentBitrate = ImportPlanner.audioProperties(fromNCM: NCMMetadata(
            musicName: "Song",
            artist: [["Artist"]],
            album: "Album",
            albumPic: "",
            format: "mp3",
            bitrate: 0,
            duration: 1000
        ))
        XCTAssertNil(silentBitrate.bitrateKbps)
        XCTAssertEqual(silentBitrate.format, "MP3")
    }

    // MARK: - Audio properties round-trip (referenced locator + managed root)

    func testReferencedLocatorPrimaryAudioPropertiesSurviveSidecarRoundTrip() throws {
        let properties = kmgccc_player.TrackAudioProperties(
            format: "FLAC",
            bitrateKbps: 986,
            sampleRateHz: 44_100,
            bitDepth: 16,
            channelCount: 2
        )
        let sidecar = kmgccc_player.TrackSidecar(
            id: UUID(),
            title: "Song",
            artist: "Artist",
            album: "Album",
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
            mediaLocator: .referenced(kmgccc_player.ReferencedFileLocator(
                fileBookmarkData: Data([1, 2, 3]),
                lastKnownPath: "/Volumes/Music/song.flac",
                primaryAudioProperties: properties
            ))
        )

        let data = try JSONEncoder().encode(sidecar)
        let decoded = try JSONDecoder().decode(kmgccc_player.TrackSidecar.self, from: data)
        let locator = try XCTUnwrap(decoded.mediaLocator.referencedFile)
        XCTAssertEqual(locator.primaryAudioProperties, properties)
        XCTAssertEqual(locator.locations.first?.audioProperties, properties)
    }

    func testManagedAudioPropertiesRootFieldRoundTripsAtSchemaNine() throws {
        let properties = kmgccc_player.TrackAudioProperties(format: "MP3", bitrateKbps: 320, sampleRateHz: 44_100)
        let sidecar = kmgccc_player.TrackSidecar(
            id: UUID(),
            title: "Song",
            artist: "Artist",
            album: "Album",
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
            mediaLocator: .managed(libraryRelativePath: "Tracks/\(UUID().uuidString)/audio.mp3"),
            audioProperties: properties
        )

        XCTAssertEqual(sidecar.schemaVersion, kmgccc_player.TrackSidecar.currentSchemaVersion)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(kmgccc_player.TrackSidecar.self, from: try encoder.encode(sidecar))
        XCTAssertEqual(decoded.schemaVersion, kmgccc_player.TrackSidecar.currentSchemaVersion, "No schema bump for the additive field")
        XCTAssertEqual(decoded.audioProperties, properties)
    }

    func testScannedMetaCarriesAudioPropertiesAndSuggestionsThroughReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.tracksRootURL, withIntermediateDirectories: true)

        let trackID = UUID()
        let folder = paths.trackFolderURL(for: trackID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suggestionID = UUID()
        let sidecar = kmgccc_player.TrackSidecar(
            id: trackID,
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            importedAt: nil,
            lyricsTimeOffsetMs: nil,
            originalFilePath: nil,
            audioFileName: "audio.flac",
            artworkFileName: nil,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil,
            ncmSourcePath: nil,
            mediaLocator: .managed(libraryRelativePath: "Tracks/\(trackID.uuidString)/audio.flac"),
            enrichmentSuggestions: [
                kmgccc_player.EnrichmentSuggestion(
                    id: suggestionID,
                    source: "folder-inference",
                    album: "Album",
                    compilation: true,
                    confidence: 0.6,
                    createdAt: Date(timeIntervalSince1970: 1_760_000_000)
                )
            ],
            audioProperties: kmgccc_player.TrackAudioProperties(format: "FLAC", bitrateKbps: 900, channelCount: 2)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: folder.appendingPathComponent("meta.json"))

        let scanned = MusicLibraryScanner(paths: paths).scanTracks()
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first?.audioProperties?.format, "FLAC")
        XCTAssertEqual(scanned.first?.audioProperties?.channelCount, 2)
        XCTAssertEqual(scanned.first?.enrichmentSuggestions.first?.source, "folder-inference")
        XCTAssertEqual(scanned.first?.enrichmentSuggestions.first?.compilation, true)
    }
}

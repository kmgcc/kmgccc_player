import CryptoKit
import Foundation
import PlayerAutomationProtocol
@testable import kmgccc_player
import XCTest

@MainActor
final class LibraryBundleExportServiceTests: XCTestCase {
    func testExportsPathFreeMetadataPlaylistAndMediaWithChecksums() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryBundleExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Private Source/song.mp3")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let audio = Data("sample audio payload".utf8)
        try audio.write(to: source)

        let trackID = UUID()
        let libraryID = UUID()
        let input = LibraryBundleExportTrackInput(
            metadata: AutomationMetadataDocumentTrack(
                id: trackID,
                revision: "track-revision",
                title: "A Song",
                artist: "An Artist",
                album: "An Album",
                duration: 180,
                fields: ["title": .string("A Song"), "artist": .string("An Artist")]
            ),
            audioURL: source,
            artworkURL: nil,
            lyricsURL: nil,
            ttmlURL: nil,
            failures: []
        )
        let playlist = LibraryBundleExportPlaylistInput(
            id: UUID(),
            name: "Favorites",
            description: "Kept in order",
            trackIDs: [trackID]
        )

        let outcome = try await LibraryBundleExportService.export(
            libraryID: libraryID,
            mode: "managed",
            revision: "library-revision",
            destinationDirectory: destination,
            tracks: [input],
            playlists: [playlist],
            progress: { _, _, _ in }
        )

        let manifestURL = outcome.outputDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let serializedManifest = String(decoding: manifestData, as: UTF8.self)
        XCTAssertFalse(serializedManifest.contains(source.path))
        XCTAssertEqual(manifestObject["schemaVersion"] as? Int, 1)
        XCTAssertEqual(manifestObject["trackCount"] as? Int, 1)

        let mediaURL = outcome.outputDirectory
            .appendingPathComponent("Media/\(trackID.uuidString)/audio.mp3")
        XCTAssertEqual(try Data(contentsOf: mediaURL), audio)
        let metadataURL = outcome.outputDirectory.appendingPathComponent("Metadata/tracks-00000.json")
        let document = try AutomationWireCoding.decoder().decode(
            AutomationMetadataDocument.self,
            from: Data(contentsOf: metadataURL)
        )
        XCTAssertEqual(document.tracks.map(\.id), [trackID])
        let exportedPlaylists = try AutomationWireCoding.decoder().decode(
            [LibraryBundleExportPlaylistInput].self,
            from: Data(contentsOf: outcome.outputDirectory.appendingPathComponent("Metadata/playlists.json"))
        )
        XCTAssertEqual(exportedPlaylists, [playlist])
        XCTAssertGreaterThan(outcome.copiedFileCount, 3)
        XCTAssertGreaterThan(outcome.copiedBytes, Int64(audio.count))
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testMotionExportKeepsTimingSelectionAndOnlySuccessfullyCopiedReferences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryBundleMotionExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trackID = UUID()
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let relativePath = "Tracks/\(trackID.uuidString)/motion-square-012345.mp4"
        let source = sourceRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let video = Data("motion video fixture".utf8)
        try video.write(to: source)
        var record = MusicEnrichmentRecord(query: MusicEnrichmentQuery(
            key: "local:\(trackID.uuidString)", title: "Song", artist: "Artist", album: "Album", duration: 180
        ))
        record.assets = [
            StoredMotionArtwork(kind: "square", relativePath: relativePath, sourceURL: "https://mvod.itunes.apple.com/square.m3u8", startTime: 10, duration: 20, width: 768, height: 768),
            StoredMotionArtwork(kind: "tall", relativePath: "Tracks/\(trackID.uuidString)/missing-tall.mp4", sourceURL: "https://mvod.itunes.apple.com/tall.m3u8", startTime: 10, duration: 20, width: 664, height: 886)
        ]
        record.manualMotionSelection = MusicEnrichmentResult(source: "appleWeb", albumID: "456")
        let input = LibraryBundleExportTrackInput(
            metadata: AutomationMetadataDocumentTrack(
                id: trackID, revision: "revision", title: "Song", artist: "Artist", album: "Album",
                duration: 180, fields: ["title": .string("Song")]
            ),
            audioURL: nil, artworkURL: nil, lyricsURL: nil, ttmlURL: nil, failures: [],
            motionArtwork: TrackMotionArtwork(snapshot: MusicEnrichmentSnapshot(record: record, squareArtwork: nil, tallArtwork: nil)),
            libraryRootURL: sourceRoot
        )
        XCTAssertEqual(LibraryBundleExportService.estimatedBytes(for: [input]), Int64(video.count))
        let outcome = try await LibraryBundleExportService.export(
            libraryID: UUID(), mode: "managed", revision: "revision", destinationDirectory: destination,
            tracks: [input], playlists: [], progress: { _, _, _ in }
        )
        XCTAssertEqual(try Data(contentsOf: outcome.outputDirectory.appendingPathComponent(relativePath)), video)
        let manifestData = try Data(contentsOf: outcome.outputDirectory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let tracks = try XCTUnwrap(manifest["tracks"] as? [[String: Any]])
        let motionJSON = try XCTUnwrap(tracks.first?["motionArtwork"] as? [String: Any])
        let motion = try AutomationWireCoding.decoder().decode(
            TrackMotionArtwork.self, from: JSONSerialization.data(withJSONObject: motionJSON)
        )
        XCTAssertEqual(motion.assets.count, 1)
        XCTAssertEqual(motion.assets[0].relativePath, relativePath)
        XCTAssertEqual(motion.assets[0].startTime, 10)
        XCTAssertEqual(motion.assets[0].duration, 20)
        XCTAssertTrue(motion.isUserSelected)
        XCTAssertEqual(motion.catalogAlbumID, "456")
        XCTAssertEqual(outcome.failures.count, 1)
        let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        let copiedVideo = try XCTUnwrap(files.first { $0["relativePath"] as? String == relativePath })
        let digest = SHA256.hash(data: video).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(copiedVideo["sha256"] as? String, digest)
        XCTAssertFalse(String(decoding: manifestData, as: UTF8.self).contains(sourceRoot.path))

        // Existing schema-one readers can ignore the additive motion field.
        let legacy = try AutomationWireCoding.decoder().decode(LegacyManifest.self, from: manifestData)
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertEqual(legacy.tracks.map(\.id), [trackID])
    }

    func testSharedAlbumVideoIsExportedOnceWithEveryTrackReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumMotionExport-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let relative = "AlbumAssets/album/square-video.mov"
        let source = sourceRoot.appendingPathComponent("Enrichment/\(relative)")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let video = Data("shared video fixture".utf8)
        try video.write(to: source)
        let inputs = [UUID(), UUID()].map { id in
            var record = MusicEnrichmentRecord(query: MusicEnrichmentQuery(
                key: "track:\(id)", title: "Song", artist: "Artist", album: "Album", duration: 180
            ))
            record.albumMotionIdentity = "apple:123"
            record.assets = ["square", "tall"].map { kind in
                StoredMotionArtwork(kind: kind, relativePath: relative, sourceURL: "importedVideo:fixture", startTime: 0, duration: 1200)
            }
            return LibraryBundleExportTrackInput(
                metadata: AutomationMetadataDocumentTrack(id: id, revision: "r", title: "Song", artist: "Artist", album: "Album", duration: 180, fields: [:]),
                audioURL: nil, artworkURL: nil, lyricsURL: nil, ttmlURL: nil, failures: [],
                motionArtwork: TrackMotionArtwork(snapshot: MusicEnrichmentSnapshot(record: record, squareArtwork: nil, tallArtwork: nil)),
                libraryRootURL: sourceRoot
            )
        }
        XCTAssertEqual(LibraryBundleExportService.estimatedBytes(for: inputs), Int64(video.count))
        let outcome = try await LibraryBundleExportService.export(
            libraryID: UUID(), mode: "managed", revision: "r", destinationDirectory: destination,
            tracks: inputs, playlists: [], progress: { _, _, _ in }
        )
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outcome.outputDirectory.appendingPathComponent("Enrichment/\(relative)")), video)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outcome.outputDirectory.appendingPathComponent("manifest.json"))) as? [String: Any])
        let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(files.filter { ($0["kind"] as? String)?.hasPrefix("motion.") == true }.count, 1)
        let tracks = try XCTUnwrap(manifest["tracks"] as? [[String: Any]])
        for track in tracks {
            let motion = try XCTUnwrap(track["motionArtwork"] as? [String: Any])
            let assets = try XCTUnwrap(motion["assets"] as? [[String: Any]])
            XCTAssertEqual(assets.count, 2)
            XCTAssertTrue(assets.allSatisfy { $0["relativePath"] as? String == "Enrichment/\(relative)" })
        }
    }

    private struct LegacyManifest: Decodable {
        let schemaVersion: Int
        let tracks: [LegacyTrack]
    }

    private struct LegacyTrack: Decodable {
        let id: UUID
        let audioPath: String?
        let artworkPath: String?
        let lyricsPath: String?
        let ttmlPath: String?
    }
}

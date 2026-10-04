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
}

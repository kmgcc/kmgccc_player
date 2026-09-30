import Foundation
@testable import kmgccc_player
import UniformTypeIdentifiers
import XCTest

@MainActor
final class LibraryPathsTests: XCTestCase {
    func testAllLibraryOwnedPathsRemainUnderCapturedRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/A/kmgccc_player Library", isDirectory: true)
        let paths = LibraryPaths(rootURL: root)
        let trackID = UUID()
        let sourceID = UUID()
        let urls = paths.requiredDirectories + [
            paths.manifestURL,
            paths.librarySettingsURL,
            paths.upgradeJournalURL,
            paths.playbackHistoryStoreURL,
            paths.trackIndexStoreURL,
            paths.searchIndexStoreURL,
            paths.libraryScanManifestURL,
            paths.ignoredItemsURL,
            paths.ncmConversionsURL,
            paths.trackMetaURL(for: trackID),
            try XCTUnwrap(paths.trackArtworkURL(for: trackID, fileName: "artwork.jpg")),
            try XCTUnwrap(paths.trackLyricsURL(for: trackID, ext: "ttml")),
            paths.playlistURL(for: UUID()),
            paths.sourceDescriptorURL(for: sourceID),
            paths.sourceScanManifestURL(for: sourceID),
        ]

        XCTAssertTrue(urls.allSatisfy(paths.contains))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/tmp/B/Index/TrackIndex.sqlite")))
    }

    func testLibraryRelativePathRejectsTraversal() {
        let paths = LibraryPaths(
            rootURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        )

        XCTAssertEqual(
            paths.libraryURL(from: "Tracks/song/audio.flac")?.path,
            "/tmp/library/Tracks/song/audio.flac"
        )
        XCTAssertNil(paths.libraryURL(from: "../outside.flac"))
        XCTAssertNil(paths.libraryURL(from: "/tmp/outside.flac"))
    }

    func testTrackAssetNamesCannotEscapeTrackFolder() {
        let paths = LibraryPaths(
            rootURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true)
        )
        let id = UUID()

        for unsafe in ["", ".", "..", "../outside", "folder/file", "folder\\file"] {
            XCTAssertNil(paths.trackArtworkURL(for: id, fileName: unsafe))
            XCTAssertNil(paths.trackLyricsURL(for: id, ext: unsafe))
        }
        XCTAssertNil(paths.trackArtworkURL(for: id, fileName: "/tmp/outside.jpg"))
    }

    func testContextsKeepIndependentImmutablePaths() {
        let first = LibraryContext(
            id: UUID(),
            mode: .managed,
            rootURL: URL(fileURLWithPath: "/tmp/one", isDirectory: true),
            rootBookmarkData: Data([1]),
            generation: 1
        )
        let second = LibraryContext(
            id: UUID(),
            mode: .referenced,
            rootURL: URL(fileURLWithPath: "/tmp/two", isDirectory: true),
            rootBookmarkData: Data([2]),
            generation: 2
        )

        XCTAssertEqual(first.paths.trackIndexStoreURL.path, "/tmp/one/Index/TrackIndex.sqlite")
        XCTAssertEqual(second.paths.trackIndexStoreURL.path, "/tmp/two/Index/TrackIndex.sqlite")
        XCTAssertNotEqual(first.paths.cacheRootURL, second.paths.cacheRootURL)
        XCTAssertTrue(first.isCurrent(generation: 1))
        XCTAssertFalse(first.isCurrent(generation: 2))
    }


    func testRequiredDirectoriesCanBeCreated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-path-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LibraryPaths(rootURL: root)

        try paths.createRequiredDirectories()

        for url in paths.requiredDirectories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testLibraryOrderingSidecarIsScopedAndRoundTrips() throws {
        let firstRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-ordering-first-\(UUID().uuidString)", isDirectory: true)
        let secondRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-ordering-second-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let firstPaths = kmgccc_player.LibraryPaths(rootURL: firstRoot)
        let firstService = kmgccc_player.LocalLibraryService(
            paths: firstPaths,
            preferenceStatsService: kmgccc_player.PreferenceStatsService()
        )
        let playlistID = UUID()
        let albumID = UUID()
        let artistID = UUID()
        let expected = kmgccc_player.LibraryOrderingSidecar(
            allSongs: kmgccc_player.LibraryTrackSortState(sortKey: "title", sortOrder: "ascending"),
            allPlaylists: kmgccc_player.LibraryCollectionSortState(
                sortKey: "custom",
                sortOrder: "descending",
                customItemOrder: [playlistID]
            ),
            allAlbums: kmgccc_player.LibraryCollectionSortState(
                sortKey: "updatedAt",
                sortOrder: "ascending",
                customItemOrder: [albumID]
            ),
            allArtists: kmgccc_player.LibraryCollectionSortState(
                sortKey: "name",
                sortOrder: "descending",
                customItemOrder: [artistID]
            ),
            legacyUserDefaultsMigrationCompleted: true
        )

        XCTAssertTrue(firstService.saveLibraryOrderingSidecar(expected))
        XCTAssertEqual(firstService.loadLibraryOrderingSidecar(), expected)
        XCTAssertEqual(
            firstPaths.libraryOrderingURL.path,
            firstRoot.appendingPathComponent("Settings/ordering.json").path
        )

        let secondService = kmgccc_player.LocalLibraryService(
            paths: kmgccc_player.LibraryPaths(rootURL: secondRoot),
            preferenceStatsService: kmgccc_player.PreferenceStatsService()
        )
        XCTAssertNotEqual(secondService.loadLibraryOrderingSidecar(), expected)
    }

    func testEntityMetadataWritesPreserveCustomTrackOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-entity-ordering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = kmgccc_player.LocalLibraryService(
            paths: kmgccc_player.LibraryPaths(rootURL: root),
            preferenceStatsService: kmgccc_player.PreferenceStatsService()
        )
        let trackIDs = [UUID(), UUID(), UUID()]
        let playlistID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try service.writePlaylistSidecar(
            playlistID: playlistID,
            name: "Playlist",
            description: "Before",
            createdAt: now,
            trackIDs: trackIDs,
            itemAddedAt: [:],
            customTrackOrder: [trackIDs[2], trackIDs[0], trackIDs[1]],
            trackSortKey: "custom",
            trackSortOrder: "ascending"
        )
        try service.writePlaylistSidecar(
            playlistID: playlistID,
            name: "Playlist edited",
            description: "After",
            createdAt: now,
            trackIDs: trackIDs,
            itemAddedAt: [:]
        )
        let playlist = try XCTUnwrap(service.loadPlaylistSidecar(playlistID: playlistID))
        XCTAssertEqual(playlist.trackSortKey, "custom")
        XCTAssertEqual(playlist.trackSortOrder, "ascending")
        XCTAssertEqual(playlist.customTrackOrder, [trackIDs[2], trackIDs[0], trackIDs[1]])

        let artistID = UUID()
        try service.writeArtistSidecar(
            kmgccc_player.ArtistSidecar(
                id: artistID,
                canonicalName: "artist",
                displayName: "Artist",
                description: "Artist description",
                createdAt: now,
                updatedAt: now,
                trackSortKey: "custom",
                trackSortOrder: "descending",
                customTrackOrder: [trackIDs[1], trackIDs[2], trackIDs[0]]
            ),
            artworkData: nil
        )
        try service.writeArtistSidecar(
            kmgccc_player.ArtistSidecar(
                id: artistID,
                canonicalName: "artist",
                displayName: "Artist edited",
                createdAt: now,
                updatedAt: now.addingTimeInterval(1)
            ),
            artworkData: nil
        )
        let artist = try XCTUnwrap(service.loadArtistSidecar(artistID: artistID))
        XCTAssertEqual(artist.trackSortKey, "custom")
        XCTAssertEqual(artist.trackSortOrder, "descending")
        XCTAssertEqual(artist.customTrackOrder, [trackIDs[1], trackIDs[2], trackIDs[0]])

        let albumID = UUID()
        try service.writeAlbumSidecar(
            kmgccc_player.AlbumSidecar(
                id: albumID,
                canonicalKey: "album|artist",
                displayTitle: "Album",
                primaryArtistCanonicalName: "artist",
                description: "Album description",
                createdAt: now,
                updatedAt: now,
                trackSortKey: "custom",
                trackSortOrder: "ascending",
                customTrackOrder: [trackIDs[0], trackIDs[2], trackIDs[1]]
            ),
            artworkData: nil
        )
        try service.writeAlbumSidecar(
            kmgccc_player.AlbumSidecar(
                id: albumID,
                canonicalKey: "album|artist",
                displayTitle: "Album edited",
                primaryArtistCanonicalName: "artist",
                createdAt: now,
                updatedAt: now.addingTimeInterval(1)
            ),
            artworkData: nil
        )
        let album = try XCTUnwrap(service.loadAlbumSidecar(albumID: albumID))
        XCTAssertEqual(album.trackSortKey, "custom")
        XCTAssertEqual(album.trackSortOrder, "ascending")
        XCTAssertEqual(album.customTrackOrder, [trackIDs[0], trackIDs[2], trackIDs[1]])
    }
}

final class DiskCacheOptimizationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCacheOptimizationTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testDiskCacheBudgetInvariants() {
        XCTAssertEqual(DiskCacheBudget.trackOriginals.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(DiskCacheBudget.trackDerivatives.maxBytes, 160 * 1024 * 1024)
        XCTAssertEqual(DiskCacheBudget.playlistDerivatives.maxBytes, 96 * 1024 * 1024)
        XCTAssertEqual(DiskCacheBudget.qqMusicImages.maxBytes, 64 * 1024 * 1024)
        XCTAssertEqual(DiskCacheBudget.qqMusicMetadata.maxBytes, 8 * 1024 * 1024)
        XCTAssertEqual(DiskCacheBudget.externalPlaybackArtwork.maxBytes, 48 * 1024 * 1024)
        XCTAssertEqual(DiskCacheBudget.headerColors.maxBytes, 4 * 1024 * 1024)

        let expectedCeiling: Int64 =
            64 * 1024 * 1024 +
            160 * 1024 * 1024 +
            96 * 1024 * 1024 +
            64 * 1024 * 1024 +
            8 * 1024 * 1024 +
            48 * 1024 * 1024 +
            4 * 1024 * 1024

        XCTAssertEqual(DiskCacheBudget.totalCeilingBytes, expectedCeiling)
        XCTAssertGreaterThan(DiskCacheBudget.trackOriginals.targetFraction, 0.5)
        XCTAssertLessThanOrEqual(DiskCacheBudget.trackOriginals.targetFraction, 1.0)
    }

    func testDiskCacheRetentionDirectorySize() throws {
        let root = tempDirectory.appendingPathComponent("SizeTest", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let emptyResult = DiskCacheRetention.directorySize(at: root, recursive: false)
        XCTAssertEqual(emptyResult.bytes, 0)
        XCTAssertEqual(emptyResult.fileCount, 0)

        // Write 3 files in root
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("f1.bin"))
        try Data(repeating: 2, count: 200).write(to: root.appendingPathComponent("f2.bin"))
        try Data(repeating: 3, count: 300).write(to: root.appendingPathComponent("f3.bin"))

        // Create sub-directory with 2 files
        let sub = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 400).write(to: sub.appendingPathComponent("f4.bin"))
        try Data(repeating: 5, count: 500).write(to: sub.appendingPathComponent("f5.bin"))

        let nonRecursive = DiskCacheRetention.directorySize(at: root, recursive: false)
        XCTAssertEqual(nonRecursive.bytes, 600)
        XCTAssertEqual(nonRecursive.fileCount, 3)

        let recursive = DiskCacheRetention.directorySize(at: root, recursive: true)
        XCTAssertEqual(recursive.bytes, 1500)
        XCTAssertEqual(recursive.fileCount, 5)

        let nonExistent = DiskCacheRetention.directorySize(at: root.appendingPathComponent("DoesntExist"))
        XCTAssertEqual(nonExistent.bytes, 0)
        XCTAssertEqual(nonExistent.fileCount, 0)
    }

    func testDiskCacheRetentionLRUTrim() throws {
        let root = tempDirectory.appendingPathComponent("LRUTest", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileManager = FileManager.default
        let now = Date()

        // Create 5 files, 1000 bytes each
        var urls: [URL] = []
        for i in 1...5 {
            let fileURL = root.appendingPathComponent("file_\(i).dat")
            try Data(repeating: UInt8(i), count: 1000).write(to: fileURL)
            // Stagger modification dates: file_1 is oldest, file_5 is newest
            let modDate = now.addingTimeInterval(TimeInterval(i * 10 - 100))
            try fileManager.setAttributes([.modificationDate: modDate], ofItemAtPath: fileURL.path)
            urls.append(fileURL)
        }

        // Total bytes = 5000. Set maxBytes = 3500, targetFraction = 0.60.
        // Target bytes = 3500 * 0.60 = 2100 bytes.
        // Trimming oldest should remove file_1 (1000), file_2 (1000), file_3 (1000), leaving 2000 bytes.
        let result = DiskCacheRetention.trim(
            at: root,
            maxBytes: 3500,
            targetFraction: 0.60,
            fileManager: fileManager
        )

        XCTAssertEqual(result.removedFileCount, 3)
        XCTAssertEqual(result.removedBytes, 3000)

        // file_1, file_2, file_3 must have been removed
        XCTAssertFalse(fileManager.fileExists(atPath: urls[0].path))
        XCTAssertFalse(fileManager.fileExists(atPath: urls[1].path))
        XCTAssertFalse(fileManager.fileExists(atPath: urls[2].path))

        // file_4, file_5 must still exist
        XCTAssertTrue(fileManager.fileExists(atPath: urls[3].path))
        XCTAssertTrue(fileManager.fileExists(atPath: urls[4].path))
    }

    func testDiskCacheRetentionMaxAgePruning() throws {
        let root = tempDirectory.appendingPathComponent("TTLTest", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileManager = FileManager.default
        let now = Date()

        let expiredURL1 = root.appendingPathComponent("expired1.dat")
        let expiredURL2 = root.appendingPathComponent("expired2.dat")
        let recentURL = root.appendingPathComponent("recent.dat")

        try Data(repeating: 1, count: 500).write(to: expiredURL1)
        try Data(repeating: 2, count: 500).write(to: expiredURL2)
        try Data(repeating: 3, count: 500).write(to: recentURL)

        // 10 days old, 8 days old, 1 day old
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: expiredURL1.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: expiredURL2.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-1 * 86400)], ofItemAtPath: recentURL.path)

        // Trim with TTL of 7 days (7 * 86400). Quota is very high, so only TTL triggers.
        let result = DiskCacheRetention.trim(
            at: root,
            maxBytes: 100_000_000,
            maxAge: 7 * 86400,
            fileManager: fileManager
        )

        XCTAssertEqual(result.removedFileCount, 2)
        XCTAssertEqual(result.removedBytes, 1000)
        XCTAssertFalse(fileManager.fileExists(atPath: expiredURL1.path))
        XCTAssertFalse(fileManager.fileExists(atPath: expiredURL2.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recentURL.path))
    }

    func testDiskCacheRetentionEdgeCases() {
        let nonExistent = tempDirectory.appendingPathComponent("NotExist_\(UUID().uuidString)")
        let r1 = DiskCacheRetention.trim(at: nonExistent, maxBytes: 1000)
        XCTAssertEqual(r1, .empty)

        let r2 = DiskCacheRetention.trim(at: tempDirectory, maxBytes: 0)
        XCTAssertEqual(r2, .empty)

        let r3 = DiskCacheRetention.trim(at: tempDirectory, maxBytes: -50)
        XCTAssertEqual(r3, .empty)
    }

    func testCalculateLibraryDiskCacheUsage() async throws {
        let libraryRoot = tempDirectory.appendingPathComponent("LibRoot", isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: libraryRoot)
        let storage = LibraryStorageLocations(paths: paths)

        try FileManager.default.createDirectory(at: storage.trackArtworkOriginalsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.trackArtworkDerivativesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.qqMusicCoverCacheURL, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 1024).write(to: storage.trackArtworkOriginalsURL.appendingPathComponent("track1.img"))
        try Data(repeating: 2, count: 2048).write(to: storage.trackArtworkDerivativesURL.appendingPathComponent("deriv1.img"))
        try Data(repeating: 3, count: 4096).write(to: storage.qqMusicCoverCacheURL.appendingPathComponent("cover.img"))

        let usage = await CacheManager.calculateLibraryDiskCacheUsage(storage: storage)
        XCTAssertEqual(usage.trackOriginalsBytes, 1024)
        XCTAssertEqual(usage.trackDerivativesBytes, 2048)
        XCTAssertEqual(usage.qqMusicCoverBytes, 4096)
        XCTAssertEqual(usage.totalBytes, 1024 + 2048 + 4096)
        XCTAssertEqual(usage.totalFileCount, 3)
    }

    func testArtworkDerivativeJPEGCompressionRatio() throws {
        // Create a 512x512 gradient/noise bitmap to simulate an album cover photo
        let width = 512
        let height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        var seed: UInt32 = 12345
        for i in 0..<(width * height) {
            seed = seed &* 1103515245 &+ 12345
            let r = UInt8((seed >> 16) & 0xFF)
            seed = seed &* 1103515245 &+ 12345
            let g = UInt8((seed >> 16) & 0xFF)
            seed = seed &* 1103515245 &+ 12345
            let b = UInt8((seed >> 16) & 0xFF)
            pixelData[i * 4] = r
            pixelData[i * 4 + 1] = g
            pixelData[i * 4 + 2] = b
            pixelData[i * 4 + 3] = 255 // Opaque
        }

        guard let ctx = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            XCTFail("Failed to create test image")
            return
        }

        // Test JPEG 0.85 encoding
        let jpegData = NSMutableData()
        guard let jpegDest = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create JPEG destination")
            return
        }
        CGImageDestinationAddImage(jpegDest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(jpegDest))

        // Test PNG encoding
        let pngData = NSMutableData()
        guard let pngDest = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create PNG destination")
            return
        }
        CGImageDestinationAddImage(pngDest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(pngDest))

        // Verify JPEG is at least 60% smaller than PNG
        XCTAssertLessThan(jpegData.count, pngData.count / 2, "JPEG (0.85) should be well under half the size of PNG for photos")

        // Verify JPEG magic bytes: 0xFF, 0xD8, 0xFF
        let header = [UInt8](jpegData as Data)[0..<3]
        XCTAssertEqual(header, [0xFF, 0xD8, 0xFF])

        // Verify ImageIO can read and decode the JPEG data back cleanly
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            XCTFail("Failed to read back encoded JPEG image source")
            return
        }
        guard let decodedCG = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("Failed to decode image from JPEG data")
            return
        }
        XCTAssertEqual(decodedCG.width, width)
        XCTAssertEqual(decodedCG.height, height)
    }

    func testDiskCacheRetentionPreservedFileNames() throws {
        let root = tempDirectory.appendingPathComponent("PreserveTest", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fileManager = FileManager.default
        let now = Date()

        let protectedURL = root.appendingPathComponent("manual_override.img")
        let expiredURL = root.appendingPathComponent("expired_auto.img")

        try Data(repeating: 1, count: 1000).write(to: protectedURL)
        try Data(repeating: 2, count: 1000).write(to: expiredURL)

        // Make both files 30 days old (expired)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86400)], ofItemAtPath: protectedURL.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86400)], ofItemAtPath: expiredURL.path)

        // Trim with TTL of 7 days, but protect manual_override.img
        let result = DiskCacheRetention.trim(
            at: root,
            maxBytes: 500, // Budget is tight, would require evicting both
            targetFraction: 0.5,
            maxAge: 7 * 86400,
            preservedFileNames: ["manual_override.img"],
            fileManager: fileManager
        )

        // Only expired_auto.img should be removed
        XCTAssertEqual(result.removedFileCount, 1)
        XCTAssertEqual(result.removedBytes, 1000)
        XCTAssertFalse(fileManager.fileExists(atPath: expiredURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: protectedURL.path))
    }

    func testArtworkDataNormalizerEncodedDerivativeData() {
        let width = 256
        let height = 256
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. Opaque test image
        var opaquePixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in 0..<(width * height) {
            opaquePixels[i * 4 + 3] = 255 // Opaque
        }
        guard let opaqueCtx = CGContext(
            data: &opaquePixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let opaqueCG = opaqueCtx.makeImage() else {
            XCTFail("Failed to create opaque CGImage")
            return
        }
        let opaqueImage = NSImage(cgImage: opaqueCG, size: CGSize(width: width, height: height))
        let opaqueData = ArtworkDataNormalizer.encodedDerivativeData(for: opaqueImage, lossyCompressionQuality: 0.85)
        XCTAssertNotNil(opaqueData)
        if let opaqueData {
            // Check JPEG magic bytes
            let header = [UInt8](opaqueData)[0..<3]
            XCTAssertEqual(header, [0xFF, 0xD8, 0xFF])
        }

        // 2. Image with alpha channel
        var alphaPixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in 0..<(width * height) {
            alphaPixels[i * 4 + 3] = 120 // Transparent
        }
        guard let alphaCtx = CGContext(
            data: &alphaPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let alphaCG = alphaCtx.makeImage() else {
            XCTFail("Failed to create transparent CGImage")
            return
        }
        let alphaImage = NSImage(cgImage: alphaCG, size: CGSize(width: width, height: height))
        let alphaData = ArtworkDataNormalizer.encodedDerivativeData(for: alphaImage, lossyCompressionQuality: 0.85)
        XCTAssertNotNil(alphaData)
        if let alphaData {
            // Check PNG magic bytes: 0x89, 0x50, 0x4E, 0x47
            let header = [UInt8](alphaData)[0..<4]
            XCTAssertEqual(header, [0x89, 0x50, 0x4E, 0x47])
        }
    }

    func testCalculateLibraryDiskCacheUsageIncludesScanAndOtherCaches() async throws {
        let libraryRoot = tempDirectory.appendingPathComponent("LibRootScanTest", isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: libraryRoot)
        let storage = LibraryStorageLocations(paths: paths)

        try FileManager.default.createDirectory(at: storage.trackArtworkOriginalsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.libraryScanCacheRootURL, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 1024).write(to: storage.trackArtworkOriginalsURL.appendingPathComponent("track1.img"))
        try Data(repeating: 2, count: 2048).write(to: storage.libraryScanCacheRootURL.appendingPathComponent("manifest.json"))

        let usage = await CacheManager.calculateLibraryDiskCacheUsage(storage: storage)
        XCTAssertEqual(usage.trackOriginalsBytes, 1024)
        XCTAssertEqual(usage.otherBytes, 2048)
        XCTAssertEqual(usage.totalBytes, 1024 + 2048)
        XCTAssertEqual(usage.totalFileCount, 2)
    }
}


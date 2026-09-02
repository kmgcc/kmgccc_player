import Foundation
import AVFoundation
import XCTest
@testable import kmgccc_player

private final class BookmarkResolverSpy: BookmarkResolving, @unchecked Sendable {
    var url: URL
    var stale: Bool
    var startResult: Bool
    var refreshedData: Data
    private(set) var starts = 0
    private(set) var stops = 0

    init(url: URL, stale: Bool = false, startResult: Bool = true, refreshedData: Data = Data([9])) {
        self.url = url
        self.stale = stale
        self.startResult = startResult
        self.refreshedData = refreshedData
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (url, stale) }
    func refreshBookmark(for url: URL) throws -> Data { refreshedData }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return startResult }
    func stopAccessing(_ url: URL) { stops += 1 }
}

final class AudioLocatorResolutionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSystemBookmarkResolverAcceptsRegularBookmarkData() throws {
        let root = try temporaryDirectory()
        let resolver = SystemBookmarkResolver()
        let bookmark = try root.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let resolved = try resolver.resolve(bookmark)
        XCTAssertEqual(resolved.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(resolved.isStale)
    }

    func testSystemBookmarkResolverStillAcceptsSecurityScopedBookmarkData() throws {
        let root = try temporaryDirectory()
        let resolver = SystemBookmarkResolver()
        let bookmark = try root.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let resolved = try resolver.resolve(bookmark)
        XCTAssertEqual(resolved.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(resolved.isStale)
    }

    func testStartupResolverActivatesLibraryWithRegularBookmark() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Regular startup", mode: .managed)
        try manifest.write(to: LibraryPaths(rootURL: root).manifestURL)
        let descriptor = kmgccc_player.MusicLibraryBookmark(
            id: manifest.libraryID,
            displayName: manifest.displayName,
            rootBookmarkData: try root.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
            lastKnownPath: root.path,
            modeProjection: manifest.mode
        )
        let store = try kmgccc_player.MusicLibraryRegistryStore(
            fileURL: root.appendingPathComponent("LibraryRegistry.json")
        )
        try await store.register(descriptor)
        try await store.setActiveLibrary(id: descriptor.id, manifestMode: descriptor.modeProjection)

        let resolution = await LibraryStartupContextResolver(registryStore: store).resolve()
        guard case let .context(context) = resolution else {
            return XCTFail("Expected a regular bookmark library to be reachable at startup")
        }
        XCTAssertEqual(context.id, manifest.libraryID)
        XCTAssertEqual(context.rootURL.standardizedFileURL, root.standardizedFileURL)
    }

    func testManagedAndReferencedMembershipResolve() throws {
        let root = try temporaryDirectory()
        let managed = root.appendingPathComponent("Tracks/id/audio.flac")
        try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: managed)
        let sourceID = UUID()
        let sourceRoot = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let referenced = sourceRoot.appendingPathComponent("Album/song.flac")
        try FileManager.default.createDirectory(at: referenced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: referenced)

        let resolver = LocalAudioResourceResolver(
            paths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: [
                sourceID: AuthorizedSourceRoot(url: sourceRoot, scopeOwner: .none)
            ]
        )
        XCTAssertEqual(
            try resolver.resolve(.managed(libraryRelativePath: "Tracks/id/audio.flac")).url,
            managed
        )
        XCTAssertEqual(
            try resolver.resolve(.referenced(ReferencedFileLocator(
                fileBookmarkData: Data(),
                sourceMemberships: [.init(sourceID: sourceID, relativePath: "Album/song.flac")],
                primarySourceID: sourceID
            ))).url,
            referenced
        )
    }

    func testSingleFileSourceRootResolvesItsMembershipWithoutAppendingToFile() throws {
        let root = try temporaryDirectory()
        let song = root.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: song)
        let sourceID = UUID()
        let resolver = LocalAudioResourceResolver(
            paths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: [
                sourceID: AuthorizedSourceRoot(url: song, scopeOwner: .none)
            ]
        )

        let resolution = try resolver.resolve(.referenced(ReferencedFileLocator(
            fileBookmarkData: Data(),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: "song.mp3")],
            primarySourceID: sourceID,
            lastKnownPath: song.path
        )))

        XCTAssertEqual(resolution.url, song)
    }

    func testTraversalIsRejectedBeforeFilesystemAccess() throws {
        let root = try temporaryDirectory()
        let sourceID = UUID()
        let resolver = LocalAudioResourceResolver(
            paths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: [
                sourceID: AuthorizedSourceRoot(url: root, scopeOwner: .none)
            ]
        )
        XCTAssertThrowsError(try resolver.resolve(.referenced(ReferencedFileLocator(
            fileBookmarkData: Data(),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: "../outside.flac")]
        )))) { error in
            XCTAssertEqual(error as? LocalAudioResolutionError, .pathTraversal)
        }
    }

    func testInsideSymlinkResolvesAndOutsideSymlinkIsRejected() throws {
        let root = try temporaryDirectory()
        let inside = root.appendingPathComponent("inside.flac")
        try Data([1]).write(to: inside)
        let insideLink = root.appendingPathComponent("inside-link.flac")
        try FileManager.default.createSymbolicLink(at: insideLink, withDestinationURL: inside)
        let outsideRoot = try temporaryDirectory()
        let outside = outsideRoot.appendingPathComponent("outside.flac")
        try Data([2]).write(to: outside)
        let outsideLink = root.appendingPathComponent("outside-link.flac")
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outside)
        let sourceID = UUID()
        let resolver = LocalAudioResourceResolver(
            paths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: [sourceID: AuthorizedSourceRoot(url: root, scopeOwner: .none)]
        )

        XCTAssertEqual(try resolver.resolve(.referenced(ReferencedFileLocator(
            fileBookmarkData: Data(),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: "inside-link.flac")]
        ))).url, inside)
        XCTAssertThrowsError(try resolver.resolve(.referenced(ReferencedFileLocator(
            fileBookmarkData: Data(),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: "outside-link.flac")]
        )))) { error in
            XCTAssertEqual(error as? LocalAudioResolutionError, .permissionDenied)
        }
    }

    func testStaleBookmarkReturnsRefreshedLocatorAndPairsScopeOnce() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("song.flac")
        try Data([1]).write(to: file)
        let spy = BookmarkResolverSpy(url: file, stale: true)
        let resolver = LocalAudioResourceResolver(
            paths: LibraryPaths(rootURL: root),
            bookmarkResolver: spy,
            requiresSecurityScope: true
        )
        let result = try resolver.resolve(.referenced(ReferencedFileLocator(
            fileBookmarkData: Data([1]),
            lastKnownPath: "/old/song.flac"
        )))

        XCTAssertEqual(result.refreshedLocator?.referencedFile?.fileBookmarkData, Data([9]))
        XCTAssertEqual(result.refreshedLocator?.referencedFile?.lastKnownPath, file.path)
        XCTAssertEqual(spy.starts, 1)
        result.lease.release()
        result.lease.release()
        XCTAssertEqual(spy.stops, 1)
    }

    func testInvalidSourceMembershipDoesNotHideValidBookmarkFallback() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("song.wav")
        try Data("audio".utf8).write(to: file)
        let spy = BookmarkResolverSpy(url: file)
        let resolver = LocalAudioResourceResolver(
            paths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: [
                UUID(): AuthorizedSourceRoot(url: root, scopeOwner: .none)
            ],
            bookmarkResolver: spy
        )

        // Old sidecars can contain one stale source edge alongside a still
        // usable bookmark. The unsafe edge must be skipped, not turn the
        // entire track into a missing file.
        let result = try resolver.resolve(.referenced(ReferencedFileLocator(
            fileBookmarkData: Data([1]),
            sourceMemberships: [
                .init(sourceID: UUID(), relativePath: "../outside/song.wav")
            ],
            lastKnownPath: file.path
        )))
        XCTAssertEqual(result.url.standardizedFileURL, file.standardizedFileURL)
        result.lease.release()
    }

    @MainActor
    func testPreparationFallsBackWhenPreferredReferencedCopyCannotOpen() async throws {
        let root = try temporaryDirectory()
        let broken = root.appendingPathComponent("broken.wav")
        try Data("metadata can still be read from this placeholder".utf8).write(to: broken)

        let playable = root.appendingPathComponent("playable.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        )
        do {
            let audioFile = try AVAudioFile(forWriting: playable, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            buffer.frameLength = 4_410
            try audioFile.write(from: buffer)
        }

        let brokenSourceID = UUID()
        let playableSourceID = UUID()
        let locator = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data(),
            sourceMemberships: [
                .init(sourceID: brokenSourceID, relativePath: broken.lastPathComponent)
            ],
            primarySourceID: brokenSourceID,
            lastKnownPath: broken.path,
            alternateLocations: [
                kmgccc_player.ReferencedTrackLocation(
                    fileBookmarkData: Data(),
                    sourceMemberships: [
                        .init(sourceID: playableSourceID, relativePath: playable.lastPathComponent)
                    ],
                    lastKnownPath: playable.path
                )
            ]
        )
        let request = AudioPrepRequest(
            trackID: UUID(),
            locator: .referenced(locator),
            libraryPaths: kmgccc_player.LibraryPaths(rootURL: root),
            authorizedSourceRoots: [
                brokenSourceID: kmgccc_player.AuthorizedSourceRoot(url: broken, scopeOwner: .none),
                playableSourceID: kmgccc_player.AuthorizedSourceRoot(url: playable, scopeOwner: .none)
            ],
            titleForLog: "fallback"
        )

        let resource = try await AudioFilePreparationActor().prepare(request)
        XCTAssertEqual(resource.resolvedURL.standardizedFileURL, playable.standardizedFileURL)
        resource.lease.release()
    }

    // Narrow sidecar writes are covered through LocalLibraryService in the app target.
}

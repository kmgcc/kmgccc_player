import Foundation
import XCTest

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

    // Narrow sidecar writes are covered through LocalLibraryService in the app target.
}

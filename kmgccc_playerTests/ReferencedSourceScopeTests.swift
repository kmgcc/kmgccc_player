import Foundation
@testable import kmgccc_player
import XCTest

private final class SourceBookmarkResolverSpy: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    let url: URL
    var stale = false
    var startResult = true
    private(set) var starts = 0
    private(set) var stops = 0

    init(url: URL) { self.url = url }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if String(decoding: data, as: UTF8.self) == "offline" { throw CocoaError(.fileNoSuchFile) }
        return (url, stale)
    }
    func refreshBookmark(for _: URL) throws -> Data { Data("refreshed".utf8) }
    func startAccessing(_: URL) -> Bool { starts += 1; return startResult }
    func stopAccessing(_: URL) { stops += 1 }
}

@MainActor
final class ReferencedSourceScopeTests: XCTestCase {
    func testStaleBookmarkPersistsAndCloseStopsExactlyOnce() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makePaths(root)
        let source = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("old".utf8), lastKnownPath: "/old",
            displayName: "Source", status: .stale
        )
        let store = kmgccc_player.ReferencedSourceStore(paths: paths)
        try await store.save(source)
        let resolver = SourceBookmarkResolverSpy(url: root)
        resolver.stale = true
        let scope = kmgccc_player.ReferencedSourceScope()

        let issues = await scope.start(descriptors: [source], store: store, bookmarkResolver: resolver)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(resolver.starts, 1)
        XCTAssertEqual(resolver.stops, 0)
        XCTAssertNotNil(scope.authorizedRoots[source.id])
        let refreshed = try await store.load(id: source.id)
        XCTAssertEqual(refreshed.rootBookmarkData, Data("refreshed".utf8))
        XCTAssertEqual(refreshed.lastKnownPath, root.path)

        scope.close()
        scope.close()
        XCTAssertEqual(resolver.stops, 1)
        XCTAssertTrue(scope.authorizedRoots.isEmpty)
    }

    func testOneOfflineSourceDoesNotPreventOtherSourceOrScope() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makePaths(root)
        let good = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("good".utf8), lastKnownPath: root.path, displayName: "Good"
        )
        let offline = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("offline".utf8), lastKnownPath: "/Volumes/Missing", displayName: "Offline"
        )
        let store = kmgccc_player.ReferencedSourceStore(paths: paths)
        try await store.save(good)
        try await store.save(offline)
        let resolver = SourceBookmarkResolverSpy(url: root)
        let scope = kmgccc_player.ReferencedSourceScope()

        let issues = await scope.start(descriptors: [good, offline], store: store, bookmarkResolver: resolver)
        XCTAssertTrue(issues.contains(kmgccc_player.ReferencedSourceScopeIssue.offline(offline.id)))
        XCTAssertNotNil(scope.authorizedRoots[good.id])
        XCTAssertNil(scope.authorizedRoots[offline.id])
        let offlineStatus = try await store.load(id: offline.id).status
        let goodStatus = try await store.load(id: good.id).status
        XCTAssertEqual(offlineStatus, kmgccc_player.ReferencedSourceStatus.offline)
        XCTAssertEqual(goodStatus, kmgccc_player.ReferencedSourceStatus.available)
        scope.close()
        XCTAssertEqual(resolver.stops, 1)
    }

    func testSessionFactoryStillBuildsWithOneOfflineSource() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Referenced", mode: .referenced)
        try manifest.write(to: kmgccc_player.LibraryPaths(rootURL: root).manifestURL)
        let actualPaths = kmgccc_player.LibraryPaths(rootURL: root)
        try actualPaths.createRequiredDirectories()
        let store = kmgccc_player.ReferencedSourceStore(paths: actualPaths)
        let good = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("good".utf8), lastKnownPath: root.path, displayName: "Good"
        )
        let offline = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("offline".utf8), lastKnownPath: "/Volumes/Missing", displayName: "Offline"
        )
        try await store.save(good)
        try await store.save(offline)
        let context = kmgccc_player.LibraryContext(
            manifest: manifest, rootURL: root, rootBookmarkData: Data("root".utf8), generation: 1
        )
        let session = try await kmgccc_player.LibrarySessionFactory(
            sourceBookmarkResolver: SourceBookmarkResolverSpy(url: root)
        ).makeSession(for: context)
        let concrete = try XCTUnwrap(session as? kmgccc_player.LibrarySession)
        XCTAssertNotNil(concrete.referencedSourceScope?.authorizedRoots[good.id])
        XCTAssertNil(concrete.referencedSourceScope?.authorizedRoots[offline.id])
        let offlineStatus = try await store.load(id: offline.id).status
        XCTAssertEqual(offlineStatus, kmgccc_player.ReferencedSourceStatus.offline)
        await concrete.close()
    }

    func testFalseStartReadableAllowedOnlyOutsideSandboxPolicy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makePaths(root)
        let source = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8), lastKnownPath: root.path, displayName: "Source"
        )
        let store = kmgccc_player.ReferencedSourceStore(paths: paths)
        try await store.save(source)
        let resolver = SourceBookmarkResolverSpy(url: root)
        resolver.startResult = false

        let nonSandboxScope = kmgccc_player.ReferencedSourceScope()
        let nonSandboxIssues = await nonSandboxScope.start(
            descriptors: [source], store: store, bookmarkResolver: resolver,
            requiresSecurityScope: false
        )
        XCTAssertTrue(nonSandboxIssues.isEmpty)
        nonSandboxScope.close()
        XCTAssertEqual(resolver.stops, 0)

        let sandboxScope = kmgccc_player.ReferencedSourceScope()
        let sandboxIssues = await sandboxScope.start(
            descriptors: [source], store: store, bookmarkResolver: resolver,
            requiresSecurityScope: true
        )
        XCTAssertTrue(sandboxIssues.contains(kmgccc_player.ReferencedSourceScopeIssue.permissionDenied(source.id)))
        XCTAssertTrue(sandboxScope.authorizedRoots.isEmpty)
    }

    func testRegularBookmarkSourceIsAvailableOutsideSandboxPolicy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makePaths(root)
        let bookmark = try root.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let source = kmgccc_player.ReferencedSourceDescriptor(
            rootBookmarkData: bookmark,
            lastKnownPath: root.path,
            displayName: "Regular bookmark",
            status: .offline
        )
        let store = kmgccc_player.ReferencedSourceStore(paths: paths)
        try await store.save(source)
        let scope = kmgccc_player.ReferencedSourceScope()

        let issues = await scope.start(
            descriptors: [source],
            store: store,
            bookmarkResolver: kmgccc_player.SystemBookmarkResolver(),
            requiresSecurityScope: false
        )

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(scope.authorizedRoots[source.id]?.url.standardizedFileURL, root.standardizedFileURL)
        let sourceStatus = try await store.load(id: source.id).status
        XCTAssertEqual(sourceStatus, kmgccc_player.ReferencedSourceStatus.available)
        scope.close()
    }

    func testTrustedAutomationRootCoversDescendantsAndReleasesOnce() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Albums", isDirectory: true)
        let file = child.appendingPathComponent("track.m4a")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: file)
        let sibling = root.deletingLastPathComponent().appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let resolver = SourceBookmarkResolverSpy(url: root)
        let scope = kmgccc_player.ReferencedSourceScope()
        let configuration = try scope.configureTrustedAutomationRoot(
            bookmarkData: Data("trusted".utf8),
            bookmarkResolver: resolver,
            requiresSecurityScope: true
        )

        XCTAssertEqual(configuration.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(scope.isTrustedAutomationPath(root))
        XCTAssertTrue(scope.isTrustedAutomationPath(child))
        XCTAssertTrue(scope.isTrustedAutomationPath(file))
        XCTAssertFalse(scope.isTrustedAutomationPath(sibling))

        scope.close()
        scope.close()
        XCTAssertEqual(resolver.starts, 1)
        XCTAssertEqual(resolver.stops, 1)
        XCTAssertFalse(scope.isTrustedAutomationPath(child))
    }

    func testAuthorizedDirectorySourceCoversDescendantsButNotRootOrSibling() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("Albums", isDirectory: true)
        let file = child.appendingPathComponent("track.m4a")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: file)
        let sibling = root.deletingLastPathComponent().appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let sourceID = UUID()
        let scope = ReferencedSourceScope()
        scope.rootsProvider.set(
            kmgccc_player.AuthorizedSourceRoot(url: root, scopeOwner: kmgccc_player.SecurityScopedResourceLease.none),
            for: sourceID
        )

        XCTAssertNil(scope.authorizedDirectorySourceID(containing: root))
        XCTAssertEqual(scope.authorizedDirectorySourceID(containing: child), sourceID)
        XCTAssertEqual(scope.authorizedDirectorySourceID(containing: file), sourceID)
        XCTAssertNil(scope.authorizedDirectorySourceID(containing: sibling))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePaths(_ root: URL) throws -> kmgccc_player.LibraryPaths {
        let paths = kmgccc_player.LibraryPaths(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        try paths.createRequiredDirectories()
        return paths
    }
}

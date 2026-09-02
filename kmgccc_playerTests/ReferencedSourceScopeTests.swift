import Foundation
@testable import kmgccc_player
import XCTest

private final class SourceBookmarkResolverSpy: BookmarkResolving, @unchecked Sendable {
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
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("old".utf8), lastKnownPath: "/old",
            displayName: "Source", status: .stale
        )
        let store = ReferencedSourceStore(paths: paths)
        try await store.save(source)
        let resolver = SourceBookmarkResolverSpy(url: root)
        resolver.stale = true
        let scope = ReferencedSourceScope()

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
        let good = ReferencedSourceDescriptor(
            rootBookmarkData: Data("good".utf8), lastKnownPath: root.path, displayName: "Good"
        )
        let offline = ReferencedSourceDescriptor(
            rootBookmarkData: Data("offline".utf8), lastKnownPath: "/Volumes/Missing", displayName: "Offline"
        )
        let store = ReferencedSourceStore(paths: paths)
        try await store.save(good)
        try await store.save(offline)
        let resolver = SourceBookmarkResolverSpy(url: root)
        let scope = ReferencedSourceScope()

        let issues = await scope.start(descriptors: [good, offline], store: store, bookmarkResolver: resolver)
        XCTAssertTrue(issues.contains(.offline(offline.id)))
        XCTAssertNotNil(scope.authorizedRoots[good.id])
        XCTAssertNil(scope.authorizedRoots[offline.id])
        XCTAssertEqual(try await store.load(id: offline.id).status, .offline)
        XCTAssertEqual(try await store.load(id: good.id).status, .available)
        scope.close()
        XCTAssertEqual(resolver.stops, 1)
    }

    func testSessionFactoryStillBuildsWithOneOfflineSource() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = MusicLibraryManifest(displayName: "Referenced", mode: .referenced)
        try manifest.write(to: LibraryPaths(rootURL: root).manifestURL)
        let actualPaths = LibraryPaths(rootURL: root)
        try actualPaths.createRequiredDirectories()
        let store = ReferencedSourceStore(paths: actualPaths)
        let good = ReferencedSourceDescriptor(
            rootBookmarkData: Data("good".utf8), lastKnownPath: root.path, displayName: "Good"
        )
        let offline = ReferencedSourceDescriptor(
            rootBookmarkData: Data("offline".utf8), lastKnownPath: "/Volumes/Missing", displayName: "Offline"
        )
        try await store.save(good)
        try await store.save(offline)
        let context = LibraryContext(
            manifest: manifest, rootURL: root, rootBookmarkData: Data("root".utf8), generation: 1
        )
        let session = try await LibrarySessionFactory(
            sourceBookmarkResolver: SourceBookmarkResolverSpy(url: root)
        ).makeSession(for: context)
        let concrete = try XCTUnwrap(session as? LibrarySession)
        XCTAssertNotNil(concrete.referencedSourceScope?.authorizedRoots[good.id])
        XCTAssertNil(concrete.referencedSourceScope?.authorizedRoots[offline.id])
        XCTAssertEqual(try await store.load(id: offline.id).status, .offline)
        await concrete.close()
    }

    func testFalseStartReadableAllowedOnlyOutsideSandboxPolicy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try makePaths(root)
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: Data("bookmark".utf8), lastKnownPath: root.path, displayName: "Source"
        )
        let store = ReferencedSourceStore(paths: paths)
        try await store.save(source)
        let resolver = SourceBookmarkResolverSpy(url: root)
        resolver.startResult = false

        let nonSandboxScope = ReferencedSourceScope()
        let nonSandboxIssues = await nonSandboxScope.start(
            descriptors: [source], store: store, bookmarkResolver: resolver,
            requiresSecurityScope: false
        )
        XCTAssertTrue(nonSandboxIssues.isEmpty)
        nonSandboxScope.close()
        XCTAssertEqual(resolver.stops, 0)

        let sandboxScope = ReferencedSourceScope()
        let sandboxIssues = await sandboxScope.start(
            descriptors: [source], store: store, bookmarkResolver: resolver,
            requiresSecurityScope: true
        )
        XCTAssertTrue(sandboxIssues.contains(.permissionDenied(source.id)))
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
        let source = ReferencedSourceDescriptor(
            rootBookmarkData: bookmark,
            lastKnownPath: root.path,
            displayName: "Regular bookmark",
            status: .offline
        )
        let store = ReferencedSourceStore(paths: paths)
        try await store.save(source)
        let scope = ReferencedSourceScope()

        let issues = await scope.start(
            descriptors: [source],
            store: store,
            bookmarkResolver: SystemBookmarkResolver(),
            requiresSecurityScope: false
        )

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(scope.authorizedRoots[source.id]?.url.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(try await store.load(id: source.id).status, .available)
        scope.close()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePaths(_ root: URL) throws -> LibraryPaths {
        let paths = LibraryPaths(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        try paths.createRequiredDirectories()
        return paths
    }
}

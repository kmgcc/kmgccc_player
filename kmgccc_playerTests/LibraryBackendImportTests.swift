import Foundation
@testable import kmgccc_player
import XCTest

private final class BackendBookmarkResolver: BookmarkResolving, @unchecked Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { false }
    func stopAccessing(_: URL) {}
}

@MainActor
final class LibraryBackendImportTests: XCTestCase {
    func testPhysicalIdentityDedupsHardLinkAndMergesOverlappingMemberships() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let outer = fixture.external.appendingPathComponent("Outer", isDirectory: true)
        let inner = outer.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let original = inner.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: original)
        let hardLink = inner.appendingPathComponent("hard.mp3")
        try FileManager.default.linkItem(at: original, to: hardLink)
        let outerID = UUID(), innerID = UUID()

        let plan = await ImportInputScanner.scan(
            selectedURLs: [outer, inner],
            directorySources: [outer: outerID, inner: innerID]
        )

        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(Set(plan.files[0].memberships.map(\.sourceID)), Set([outerID, innerID]))
        XCTAssertEqual(plan.files[0].primarySourceID, innerID)
        XCTAssertNotNil(plan.files[0].fingerprint?.identity?.volumeUUID)
        XCTAssertNotNil(plan.files[0].fingerprint?.identity?.resourceIdentifierArchive)
    }

    func testRecursiveScanSkipsHiddenPackageAndOutsideSymlinkAndBreaksLoop() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let root = fixture.external.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("visible.flac"))
        try Data().write(to: root.appendingPathComponent(".hidden.mp3"))
        let package = root.appendingPathComponent("Archive.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("inside.mp3"))
        let outside = fixture.external.appendingPathComponent("outside.mp3")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link.mp3"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop", isDirectory: true),
            withDestinationURL: root
        )

        let plan = await ImportInputScanner.scan(selectedURLs: [root], directorySources: [root: UUID()])
        XCTAssertEqual(plan.files.map(\.url.lastPathComponent), ["visible.flac"])
    }

    func testDirectorySourceIDIsReusedWithinBatchAcrossBatchAndRestart() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let outer = fixture.external.appendingPathComponent("Outer", isDirectory: true)
        let inner = outer.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data().write(to: inner.appendingPathComponent("song.mp3"))
        let store = ReferencedSourceStore(paths: fixture.paths)
        let firstScope = ReferencedSourceScope()
        let firstBackend = ReferencedLocalBackend(
            paths: fixture.paths, sourceStore: store, sourceScope: firstScope,
            bookmarkResolver: BackendBookmarkResolver()
        )

        let repeated = await firstBackend.prepareInputs([outer, outer])
        XCTAssertEqual(Set(repeated.directorySources.map(\.source.id)).count, 1)
        let firstID = try XCTUnwrap(repeated.directorySources.first?.source.id)
        firstBackend.finishImportBatch()
        let second = await firstBackend.prepareInputs([outer])
        XCTAssertEqual(second.directorySources.first?.source.id, firstID)
        firstBackend.finishImportBatch()

        let restarted = ReferencedLocalBackend(
            paths: fixture.paths, sourceStore: store, sourceScope: ReferencedSourceScope(),
            bookmarkResolver: BackendBookmarkResolver()
        )
        let afterRestart = await restarted.prepareInputs([outer, inner])
        XCTAssertEqual(afterRestart.directorySources.first { $0.rootURL == outer }?.source.id, firstID)
        XCTAssertEqual(Set(afterRestart.directorySources.map(\.source.id)).count, 2)
        XCTAssertEqual(try await store.loadAll().count, 2)
    }

    func testInsideDirectoryAndFileSymlinksAreFollowedAndOutsideIsRejected() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let root = fixture.external.appendingPathComponent("Root", isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let song = target.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: song)
        let directoryLink = root.appendingPathComponent("DirectoryLink", isDirectory: true)
        let fileLink = root.appendingPathComponent("file-link.mp3")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: song)
        let outside = fixture.external.appendingPathComponent("outside.mp3")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside-link.mp3"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop", isDirectory: true), withDestinationURL: root
        )

        let plan = await ImportInputScanner.scan(selectedURLs: [root], directorySources: [root: UUID()])
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(plan.files.first?.url, song)
    }

    func testManagedCopiesAndReferencedCreatesLocatorWithoutAudioCopyOrFakeSource() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let file = fixture.external.appendingPathComponent("single.mp3")
        try Data("audio".utf8).write(to: file)
        let discovered = ImportDiscoveredFile(
            url: file,
            memberships: [],
            primarySourceID: nil,
            fingerprint: try ReferencedFileIdentityProvider().fingerprint(for: file)
        )
        let staging = fixture.paths.importStagingRootURL.appendingPathComponent("test", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let managed = ManagedLocalBackend(paths: fixture.paths)
        let managedPlacement = try await managed.makePlacement(for: discovered, trackID: UUID(), stagingDirectoryURL: staging)
        guard case let .managed(stagedURL, _) = managedPlacement else { return XCTFail("Expected managed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        let store = ReferencedSourceStore(paths: fixture.paths)
        let scope = ReferencedSourceScope()
        let referenced = ReferencedLocalBackend(
            paths: fixture.paths,
            sourceStore: store,
            sourceScope: scope,
            bookmarkResolver: BackendBookmarkResolver()
        )
        let plan = await referenced.prepareInputs([file])
        XCTAssertEqual(plan.directorySources.count, 0)
        XCTAssertTrue(try await store.loadAll().isEmpty)
        let placement = try await referenced.makePlacement(
            for: try XCTUnwrap(plan.files.first), trackID: UUID(), stagingDirectoryURL: staging
        )
        guard case let .referenced(locator) = placement else { return XCTFail("Expected referenced") }
        XCTAssertTrue(locator.sourceMemberships.isEmpty)
        XCTAssertNil(locator.primarySourceID)
        XCTAssertEqual(locator.lastKnownPath, file.path)
        XCTAssertEqual(try Data(contentsOf: file), Data("audio".utf8))
    }
}

private struct BackendFixture {
    let root: URL
    let external: URL
    let paths: LibraryPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        external = root.appendingPathComponent("External", isDirectory: true)
        paths = LibraryPaths(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try paths.createRequiredDirectories()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

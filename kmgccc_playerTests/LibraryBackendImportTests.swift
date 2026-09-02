import Foundation
@testable import kmgccc_player
import XCTest

private final class BackendBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { false }
    func stopAccessing(_: URL) {}
}

private final class CountingScopeBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    private(set) var startedPaths: [String] = []
    private(set) var stoppedPaths: [String] = []
    var startResult = true

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }

    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func startAccessing(_ url: URL) -> Bool {
        startedPaths.append(url.standardizedFileURL.path)
        return startResult
    }

    func stopAccessing(_ url: URL) {
        stoppedPaths.append(url.standardizedFileURL.path)
    }
}

@MainActor
final class LibraryBackendImportTests: XCTestCase {
    func testSecurityScopesGroupSiblingAndNestedFilesAndRetainResolver() throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let music = fixture.external.appendingPathComponent("Music", isDirectory: true)
        let albums = music.appendingPathComponent("Albums", isDirectory: true)
        let other = fixture.external.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: albums, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let first = music.appendingPathComponent("first.mp3")
        let second = music.appendingPathComponent("second.mp3")
        let nested = albums.appendingPathComponent("nested.mp3")
        let separate = other.appendingPathComponent("separate.mp3")
        for file in [first, second, nested, separate] {
            try Data("audio".utf8).write(to: file)
        }

        let roots = kmgccc_player.SecurityScopeAuthorization.groupedRoots(for: [first, second, nested, separate])
        XCTAssertEqual(
            roots.map(kmgccc_player.SecurityScopeAuthorization.canonicalPath),
            [music, other].map(kmgccc_player.SecurityScopeAuthorization.canonicalPath)
        )

        let resolver = CountingScopeBookmarkResolver()
        let selection = kmgccc_player.LibraryInitialImportSelection(
            urls: [first, second, nested],
            bookmarkResolver: resolver
        )
        XCTAssertEqual(resolver.startedPaths, [music.path])

        let retained = selection.retainedCopy()
        XCTAssertEqual(resolver.startedPaths, [music.path, music.path])
        selection.release()
        retained.release()
        XCTAssertEqual(resolver.stoppedPaths, [music.path, music.path])
    }

    func testInitialSelectionDoesNotRetryDeniedParentOncePerFile() throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let music = fixture.external.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let first = music.appendingPathComponent("first.mp3")
        let second = music.appendingPathComponent("second.mp3")
        try Data("audio-one".utf8).write(to: first)
        try Data("audio-two".utf8).write(to: second)

        let resolver = CountingScopeBookmarkResolver()
        resolver.startResult = false
        let selection = kmgccc_player.LibraryInitialImportSelection(
            urls: [first, second],
            bookmarkResolver: resolver
        )

        XCTAssertEqual(resolver.startedPaths, [music.path])
        selection.release()
        XCTAssertTrue(resolver.stoppedPaths.isEmpty)
    }

    func testReferencedBackendSharesOneParentScopeForMultipleFiles() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let music = fixture.external.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let first = music.appendingPathComponent("first.mp3")
        let second = music.appendingPathComponent("second.mp3")
        try Data("audio-one".utf8).write(to: first)
        try Data("audio-two".utf8).write(to: second)

        let resolver = CountingScopeBookmarkResolver()
        let backend = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths,
            sourceStore: kmgccc_player.ReferencedSourceStore(paths: fixture.paths),
            sourceScope: kmgccc_player.ReferencedSourceScope(),
            bookmarkResolver: resolver,
            requiresSecurityScope: true
        )
        let plan = await backend.prepareInputs([first, second])

        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(resolver.startedPaths, [music.path])

        await backend.close()
        XCTAssertEqual(resolver.stoppedPaths, [music.path])
    }

    func testReferencedBackendUsesOneScopePerDistinctParent() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let firstParent = fixture.external.appendingPathComponent("First", isDirectory: true)
        let secondParent = fixture.external.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
        let first = firstParent.appendingPathComponent("first.mp3")
        let second = secondParent.appendingPathComponent("second.mp3")
        try Data("audio-one".utf8).write(to: first)
        try Data("audio-two".utf8).write(to: second)

        let resolver = CountingScopeBookmarkResolver()
        let backend = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths,
            sourceStore: kmgccc_player.ReferencedSourceStore(paths: fixture.paths),
            sourceScope: kmgccc_player.ReferencedSourceScope(),
            bookmarkResolver: resolver,
            requiresSecurityScope: true
        )
        let plan = await backend.prepareInputs([first, second])

        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(Set(resolver.startedPaths), Set([firstParent.path, secondParent.path]))
        XCTAssertEqual(resolver.startedPaths.count, 2)

        await backend.close()
        XCTAssertEqual(Set(resolver.stoppedPaths), Set([firstParent.path, secondParent.path]))
        XCTAssertEqual(resolver.stoppedPaths.count, 2)
    }

    func testReferencedBackendDoesNotFallBackToPerFileAuthorizationAfterBatchDenial() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let music = fixture.external.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let first = music.appendingPathComponent("first.mp3")
        let second = music.appendingPathComponent("second.mp3")
        try Data("audio-one".utf8).write(to: first)
        try Data("audio-two".utf8).write(to: second)

        let resolver = CountingScopeBookmarkResolver()
        resolver.startResult = false
        let backend = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths,
            sourceStore: kmgccc_player.ReferencedSourceStore(paths: fixture.paths),
            sourceScope: kmgccc_player.ReferencedSourceScope(),
            bookmarkResolver: resolver,
            requiresSecurityScope: true
        )
        let plan = await backend.prepareInputs([first, second])

        XCTAssertEqual(resolver.startedPaths, [music.path])
        XCTAssertEqual(plan.files.count, 0)
        XCTAssertEqual(plan.failures.count, 2)

        await backend.close()
    }

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

        let plan = await kmgccc_player.ImportInputScanner.scan(
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

        let plan = await kmgccc_player.ImportInputScanner.scan(selectedURLs: [root], directorySources: [root: UUID()])
        XCTAssertEqual(plan.files.map(\.url.lastPathComponent), ["visible.flac"])
    }

    func testDirectorySourceIDIsReusedWithinBatchAcrossBatchAndRestart() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let outer = fixture.external.appendingPathComponent("Outer", isDirectory: true)
        let inner = outer.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data().write(to: inner.appendingPathComponent("song.mp3"))
        let store = kmgccc_player.ReferencedSourceStore(paths: fixture.paths)
        let firstScope = kmgccc_player.ReferencedSourceScope()
        let firstBackend = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths, sourceStore: store, sourceScope: firstScope,
            bookmarkResolver: BackendBookmarkResolver()
        )

        let repeated = await firstBackend.prepareInputs([outer, outer])
        XCTAssertEqual(Set(repeated.directorySources.map(\.source.id)).count, 1)
        let firstID = try XCTUnwrap(repeated.directorySources.first?.source.id)
        try await firstBackend.commitPreparedSources()
        firstBackend.finishImportBatch()
        let second = await firstBackend.prepareInputs([outer])
        XCTAssertEqual(second.directorySources.first?.source.id, firstID)
        firstBackend.finishImportBatch()

        let restarted = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths, sourceStore: store, sourceScope: kmgccc_player.ReferencedSourceScope(),
            bookmarkResolver: BackendBookmarkResolver()
        )
        let afterRestart = await restarted.prepareInputs([outer, inner])
        XCTAssertEqual(afterRestart.directorySources.first { $0.rootURL == outer }?.source.id, firstID)
        XCTAssertEqual(Set(afterRestart.directorySources.map(\.source.id)).count, 2)
        try await restarted.commitPreparedSources()
        let storedAfterRestart = try await store.loadAll()
        XCTAssertEqual(storedAfterRestart.count, 2)
    }

    func testSingleFileSelectionCreatesPrunableFileSource() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let file = fixture.external.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: file)
        XCTAssertFalse(file.hasDirectoryPath)
        XCTAssertTrue(kmgccc_player.AudioFormatSupport.isImportable(file))
        let store = kmgccc_player.ReferencedSourceStore(paths: fixture.paths)
        let backend = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths, sourceStore: store, sourceScope: kmgccc_player.ReferencedSourceScope(),
            bookmarkResolver: BackendBookmarkResolver()
        )

        let plan = await backend.prepareInputs([file])
        XCTAssertEqual(
            plan.directorySources.count,
            1,
            "file=\(file.path) ext=\(file.pathExtension) failures=\(plan.failures)"
        )
        XCTAssertEqual(plan.directorySources.first?.source.mode, .file)
        try await backend.commitPreparedSources()
        let storedAfterPrepare = try await store.loadAll()
        XCTAssertEqual(storedAfterPrepare.count, 1)

        // File sources whose file never produced a track are pruned …
        await backend.pruneUnimportedFileSources(importedURLs: [], importedSourceIDs: [])
        let storedAfterPrune = try await store.loadAll()
        XCTAssertEqual(storedAfterPrune.count, 0)
        XCTAssertEqual(backend.lastPreparedInputPlan?.directorySources.count, 0)

        // … while successfully imported ones survive (by path …
        let second = await backend.prepareInputs([file])
        XCTAssertEqual(second.directorySources.first?.source.mode, .file)
        try await backend.commitPreparedSources()
        let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
        await backend.pruneUnimportedFileSources(importedURLs: [canonical], importedSourceIDs: [])
        let surviving = try await store.loadAll()
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving.first?.mode, .file)

        // … or by membership sourceID, the NCM-conversion shape where the
        // imported path is the converted product, not the source file).
        let third = await backend.prepareInputs([file])
        let thirdID = try XCTUnwrap(third.directorySources.first?.source.id)
        await backend.pruneUnimportedFileSources(importedURLs: [], importedSourceIDs: [thirdID])
        let storedAfterSecondPrune = try await store.loadAll()
        XCTAssertEqual(storedAfterSecondPrune.count, 1)
        backend.finishImportBatch()
    }

    func testFileCoveredByDirectorySourceDoesNotCreateFileSource() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let root = fixture.external.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("song.mp3")
        try Data("audio".utf8).write(to: file)
        let store = kmgccc_player.ReferencedSourceStore(paths: fixture.paths)
        let backend = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths, sourceStore: store, sourceScope: kmgccc_player.ReferencedSourceScope(),
            bookmarkResolver: BackendBookmarkResolver()
        )

        _ = await backend.prepareInputs([root])
        try await backend.commitPreparedSources()
        backend.finishImportBatch()
        let plan = await backend.prepareInputs([file])
        XCTAssertTrue(plan.directorySources.isEmpty)
        let descriptors = try await store.loadAll()
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.mode, .directory)
        let discovered = try XCTUnwrap(plan.files.first)
        XCTAssertEqual(discovered.memberships.map(\.sourceID), [try XCTUnwrap(descriptors.first?.id)])
        backend.finishImportBatch()
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

        let plan = await kmgccc_player.ImportInputScanner.scan(selectedURLs: [root], directorySources: [root: UUID()])
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(plan.files.first?.url, song)
    }

    func testManagedCopiesAndReferencedCreatesLocatorWithoutAudioCopyOrFakeSource() async throws {
        let fixture = try BackendFixture()
        defer { fixture.cleanup() }
        let file = fixture.external.appendingPathComponent("single.mp3")
        try Data("audio".utf8).write(to: file)
        let discovered = kmgccc_player.ImportDiscoveredFile(
            url: file,
            memberships: [],
            primarySourceID: nil,
            fingerprint: try kmgccc_player.ReferencedFileIdentityProvider().fingerprint(for: file)
        )
        let staging = fixture.paths.importStagingRootURL.appendingPathComponent("test", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let managed = kmgccc_player.ManagedLocalBackend(paths: fixture.paths)
        let managedPlacement = try await managed.makePlacement(for: discovered, trackID: UUID(), stagingDirectoryURL: staging)
        guard case let .managed(stagedURL, _) = managedPlacement else { return XCTFail("Expected managed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))

        let store = kmgccc_player.ReferencedSourceStore(paths: fixture.paths)
        let scope = kmgccc_player.ReferencedSourceScope()
        let referenced = kmgccc_player.ReferencedLocalBackend(
            paths: fixture.paths,
            sourceStore: store,
            sourceScope: scope,
            bookmarkResolver: BackendBookmarkResolver()
        )
        let plan = await referenced.prepareInputs([file])
        XCTAssertEqual(plan.directorySources.count, 1)
        try await referenced.commitPreparedSources()
        let storedSources = try await store.loadAll()
        XCTAssertEqual(storedSources.count, 1)
        let placement = try await referenced.makePlacement(
            for: try XCTUnwrap(plan.files.first), trackID: UUID(), stagingDirectoryURL: staging
        )
        guard case let .referenced(locator) = placement else { return XCTFail("Expected referenced") }
        let sourceID = try XCTUnwrap(plan.directorySources.first?.source.id)
        XCTAssertEqual(locator.sourceMemberships.map(\.sourceID), [sourceID])
        XCTAssertEqual(locator.primarySourceID, sourceID)
        XCTAssertEqual(locator.lastKnownPath, file.path)
        XCTAssertEqual(try Data(contentsOf: file), Data("audio".utf8))
    }
}

private struct BackendFixture {
    let root: URL
    let external: URL
    let paths: kmgccc_player.LibraryPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        external = root.appendingPathComponent("External", isDirectory: true)
        paths = kmgccc_player.LibraryPaths(rootURL: root.appendingPathComponent("Library", isDirectory: true))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try paths.createRequiredDirectories()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

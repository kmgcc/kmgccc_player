import Foundation
import XCTest

final class LegacyLibraryBootstrapTests: XCTestCase {
    func testRegistersExistingLibraryInPlaceAsManaged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)

        let result = try bootstrap.run(
            legacyRootURL: fixture.root,
            generation: 42,
            now: Date(timeIntervalSince1970: 100)
        )

        let context = try XCTUnwrap(result.context)
        XCTAssertTrue(result.didCreateManifest)
        XCTAssertTrue(result.didRegisterLibrary)
        XCTAssertEqual(context.mode, .managed)
        XCTAssertEqual(context.generation, 42)
        XCTAssertEqual(context.rootURL, fixture.root.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Tracks").path))

        let manifest = try MusicLibraryManifest.read(from: context.paths.manifestURL)
        XCTAssertEqual(manifest.libraryID, context.id)
        XCTAssertEqual(manifest.mode, .managed)
        let registry = try MusicLibraryRegistryFile.load(from: fixture.registry)
        XCTAssertEqual(registry.activeLibraryID, context.id)
        XCTAssertEqual(registry.recentManagedLibraryID, context.id)
        XCTAssertEqual(registry.libraries.count, 1)
        let journal = try XCTUnwrap(LibraryUpgradeJournal.read(from: context.paths.upgradeJournalURL))
        XCTAssertEqual(journal.stage, .committed)
    }

    func testBootstrapIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Playlists", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bootstrap = makeBootstrap(registryURL: fixture.registry)

        let first = try bootstrap.run(legacyRootURL: fixture.root)
        let second = try bootstrap.run(legacyRootURL: fixture.root)

        XCTAssertEqual(first.context?.id, second.context?.id)
        XCTAssertFalse(second.didCreateManifest)
        XCTAssertFalse(second.didRegisterLibrary)
        XCTAssertEqual(try MusicLibraryRegistryFile.load(from: fixture.registry).libraries.count, 1)
    }

    func testResumesUsingIdentityPersistedInJournal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let paths = LibraryPaths(rootURL: fixture.root)
        try FileManager.default.createDirectory(at: paths.tracksRootURL, withIntermediateDirectories: true)
        let expectedID = UUID()
        try LibraryUpgradeJournal(
            libraryID: expectedID,
            rootURL: fixture.root,
            stage: .discovered
        ).write(to: paths.upgradeJournalURL)

        let result = try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)

        XCTAssertEqual(result.context?.id, expectedID)
        XCTAssertEqual(try MusicLibraryManifest.read(from: paths.manifestURL).libraryID, expectedID)
    }

    func testDoesNotCreateLibraryForEmptyOrMissingRoot() throws {
        let fixture = try makeFixture(createRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        let result = try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)

        XCTAssertEqual(result, .noLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.registry.path))
    }

    func testCorruptedRegistryIsPreservedForRecovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )
        let original = Data("corrupted-registry".utf8)
        try FileManager.default.createDirectory(
            at: fixture.registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: fixture.registry)

        XCTAssertThrowsError(
            try makeBootstrap(registryURL: fixture.registry).run(legacyRootURL: fixture.root)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.registry), original)
        let journal = try XCTUnwrap(
            LibraryUpgradeJournal.read(from: LibraryPaths(rootURL: fixture.root).upgradeJournalURL)
        )
        XCTAssertEqual(journal.stage, .manifestWritten)
    }

    private func makeBootstrap(registryURL: URL) -> LegacyLibraryBootstrap {
        LegacyLibraryBootstrap(
            registryURL: registryURL,
            bookmarkDataProvider: { Data("bookmark:\($0.path)".utf8) }
        )
    }

    private func makeFixture(createRoot: Bool = true) throws -> (
        container: URL,
        root: URL,
        registry: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let parent = container.appendingPathComponent("Music", isDirectory: true)
        let root = parent.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return (
            container,
            root,
            container.appendingPathComponent("AppSupport/LibraryRegistry.json")
        )
    }
}

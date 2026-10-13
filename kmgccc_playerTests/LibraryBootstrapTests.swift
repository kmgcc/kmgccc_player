import Foundation
import XCTest
@testable import kmgccc_player

final class LibraryBootstrapTests: XCTestCase {
    func testDefaultBookmarkResolverRestoresRegularBookmark() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let manifest = MusicLibraryManifest(displayName: "Regular bookmark", mode: .managed)
        try manifest.write(to: LibraryPaths(rootURL: fixture.root).manifestURL)
        let descriptor = MusicLibraryBookmark(
            id: manifest.libraryID,
            displayName: manifest.displayName,
            rootBookmarkData: try fixture.root.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
            lastKnownPath: fixture.root.path,
            modeProjection: manifest.mode
        )
        try MusicLibraryRegistryFile.save(
            MusicLibraryRegistry(
                libraries: [descriptor],
                activeLibraryID: descriptor.id,
                recentManagedLibraryID: descriptor.id
            ),
            to: fixture.registry
        )

        let result = try LibraryBootstrap(registryURL: fixture.registry).run(generation: 42)

        XCTAssertEqual(result.context?.id, manifest.libraryID)
        XCTAssertEqual(result.context?.generation, 42)
        XCTAssertEqual(result.context?.rootURL.standardizedFileURL, fixture.root.standardizedFileURL)
    }

    func testReturnsNoLibraryWithoutRegistry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Tracks", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = try makeBootstrap(registryURL: fixture.registry).run()

        XCTAssertEqual(result, .noLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.registry.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LibraryPaths(rootURL: fixture.root).manifestURL.path
        ))
    }

    func testReturnsNoLibraryWithoutActiveLibrary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try registerLibrary(at: fixture)
        var registry = try MusicLibraryRegistryFile.load(from: fixture.registry)
        registry.activeLibraryID = nil
        try MusicLibraryRegistryFile.save(registry, to: fixture.registry)

        let result = try makeBootstrap(registryURL: fixture.registry).run()

        XCTAssertEqual(result, .noLibrary)
    }

    func testCorruptedRegistryIsPreservedForRecovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let original = Data("corrupted-registry".utf8)
        try FileManager.default.createDirectory(
            at: fixture.registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: fixture.registry)

        XCTAssertThrowsError(try makeBootstrap(registryURL: fixture.registry).run())
        XCTAssertEqual(try Data(contentsOf: fixture.registry), original)
    }

    func testStaleBookmarkRefreshesRegistryAfterValidatedLastKnownFallback() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let libraryID = try registerLibrary(at: fixture)
        let missingBookmarkRoot = fixture.container.appendingPathComponent("Missing", isDirectory: true)
        let refreshedData = Data("refreshed-bookmark".utf8)
        let bootstrap = LibraryBootstrap(
            registryURL: fixture.registry,
            bookmarkDataProvider: { _ in refreshedData },
            bookmarkURLResolver: { _ in (missingBookmarkRoot, true) }
        )

        let restored = try bootstrap.run()

        XCTAssertEqual(restored.context?.id, libraryID)
        XCTAssertEqual(restored.context?.rootURL.standardizedFileURL, fixture.root.standardizedFileURL)
        XCTAssertEqual(restored.context?.rootBookmarkData, refreshedData)
        let registry = try MusicLibraryRegistryFile.load(from: fixture.registry)
        XCTAssertEqual(registry.library(id: libraryID)?.rootBookmarkData, refreshedData)
        XCTAssertEqual(registry.library(id: libraryID)?.lastKnownPath, fixture.root.standardizedFileURL.path)
    }

    func testLastKnownFallbackRejectsManifestIdentityMismatch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try registerLibrary(at: fixture)
        let manifestURL = LibraryPaths(rootURL: fixture.root).manifestURL
        let manifest = try MusicLibraryManifest.read(from: manifestURL)
        try MusicLibraryManifest(
            libraryID: UUID(),
            displayName: manifest.displayName,
            mode: manifest.mode,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt
        ).write(to: manifestURL)
        let missingBookmarkRoot = fixture.container.appendingPathComponent("Missing", isDirectory: true)
        let bootstrap = LibraryBootstrap(
            registryURL: fixture.registry,
            bookmarkDataProvider: { _ in Data("unused".utf8) },
            bookmarkURLResolver: { _ in (missingBookmarkRoot, true) }
        )

        XCTAssertThrowsError(try bootstrap.run())
    }

    func testStrictDiskInspectionRejectsCorruptTrackSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let context = try registeredContext(at: fixture)
        let package = context.paths.trackFolderURL(for: UUID())
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: package.appendingPathComponent("meta.json"))

        XCTAssertThrowsError(
            try LibraryStorageValidator.inspectDisk(context: context)
        ) {
            XCTAssertEqual(
                $0 as? LibraryStorageValidationError,
                LibraryStorageValidationError.damagedTrackSidecar
            )
        }
    }

    func testStrictDiskInspectionRejectsUnreadablePlaylistDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let context = try registeredContext(at: fixture)
        try FileManager.default.createDirectory(
            at: context.paths.tracksRootURL,
            withIntermediateDirectories: true
        )
        try Data("not-a-directory".utf8).write(to: context.paths.playlistsRootURL)

        XCTAssertThrowsError(
            try LibraryStorageValidator.inspectDisk(context: context)
        ) {
            XCTAssertEqual(
                $0 as? LibraryStorageValidationError,
                .damagedPlaylistSidecar
            )
        }
    }

    @MainActor
    func testExternalPlaybackManualOverridesAreGlobalAndAutomaticRecordsAreLibraryScoped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let firstRoot = fixture.container.appendingPathComponent("First Library", isDirectory: true)
        let secondRoot = fixture.container.appendingPathComponent("Second Library", isDirectory: true)
        let firstStorage = StorageLocations.scoped(to: LibraryPaths(rootURL: firstRoot))
        let secondStorage = StorageLocations.scoped(to: LibraryPaths(rootURL: secondRoot))
        let defaultsName = "LibraryBootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let raw = ExternalPlaybackRawMetadata(
            source: .appleMusic,
            title: "Original",
            artist: "Artist",
            duration: 180
        )
        let firstStore = ExternalPlaybackMetadataStore(storage: firstStorage, defaults: defaults)
        firstStore.saveOverride(
            ExternalPlaybackMatchOverride(
                title: "Edited",
                artist: nil,
                album: nil,
                manuallySelectedLyrics: nil,
                manuallySelectedLyricsSource: nil,
                lyricsTimeOffsetMs: nil,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            for: raw.stableKey
        )
        firstStore.saveManualLyrics("manual lyrics", source: "manual", for: raw.stableKey)
        _ = await firstStore.resolve(raw: raw, libraryTracks: [])

        let secondStore = ExternalPlaybackMetadataStore(storage: secondStorage, defaults: defaults)

        XCTAssertEqual(secondStore.effectiveMetadata(for: raw).title, "Edited")
        XCTAssertEqual(secondStore.manualLyrics(for: raw.stableKey), "manual lyrics")
        XCTAssertEqual(
            firstStorage.externalPlaybackMetadataURL,
            firstRoot.appendingPathComponent("Cache/ExternalPlayback", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: firstStorage.externalPlaybackMetadataURL
                .appendingPathComponent("records.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: secondStorage.externalPlaybackMetadataURL
                .appendingPathComponent("records.json").path
        ))
    }

    // MARK: - Fixtures

    private func makeBootstrap(registryURL: URL) -> LibraryBootstrap {
        LibraryBootstrap(
            registryURL: registryURL,
            bookmarkDataProvider: { Data("bookmark:\($0.path)".utf8) },
            bookmarkURLResolver: { data in
                let raw = String(decoding: data, as: UTF8.self)
                guard raw.hasPrefix("bookmark:") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (
                    URL(
                        fileURLWithPath: String(raw.dropFirst("bookmark:".count)),
                        isDirectory: true
                    ),
                    false
                )
            }
        )
    }

    /// Writes a managed manifest at the fixture root and registers it as the
    /// active library with the fake bookmark format `makeBootstrap` resolves.
    @discardableResult
    private func registerLibrary(
        at fixture: (container: URL, root: URL, registry: URL)
    ) throws -> UUID {
        let manifest = MusicLibraryManifest(displayName: "Fixture", mode: .managed)
        try manifest.write(to: LibraryPaths(rootURL: fixture.root).manifestURL)
        let descriptor = MusicLibraryBookmark(
            id: manifest.libraryID,
            displayName: manifest.displayName,
            rootBookmarkData: Data("bookmark:\(fixture.root.path)".utf8),
            lastKnownPath: fixture.root.standardizedFileURL.path,
            modeProjection: manifest.mode
        )
        try FileManager.default.createDirectory(
            at: fixture.registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try MusicLibraryRegistryFile.save(
            MusicLibraryRegistry(
                libraries: [descriptor],
                activeLibraryID: descriptor.id,
                recentManagedLibraryID: descriptor.id
            ),
            to: fixture.registry
        )
        return manifest.libraryID
    }

    private func registeredContext(
        at fixture: (container: URL, root: URL, registry: URL)
    ) throws -> LibraryContext {
        try registerLibrary(at: fixture)
        return try XCTUnwrap(makeBootstrap(registryURL: fixture.registry).run().context)
    }

    private func makeFixture() throws -> (
        container: URL,
        root: URL,
        registry: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgccc-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        let root = container
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            container,
            root,
            container.appendingPathComponent("AppSupport/LibraryRegistry.json")
        )
    }
}

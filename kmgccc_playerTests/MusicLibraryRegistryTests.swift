import Foundation
import XCTest

final class MusicLibraryManifestTests: XCTestCase {
    func testManifestRoundTripsBothModes() throws {
        for mode in MusicLibraryMode.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent(MusicLibraryManifest.fileName)
            let manifest = MusicLibraryManifest(
                libraryID: UUID(),
                displayName: "Test Library",
                mode: mode,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200)
            )

            try manifest.write(to: url)

            XCTAssertEqual(try MusicLibraryManifest.read(from: url), manifest)
        }
    }

    func testManifestRejectsUnknownModeAndSchema() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let id = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "libraryID": "\(id.uuidString)",
          "displayName": "Broken",
          "mode": "remote",
          "createdAt": "1970-01-01T00:00:00Z",
          "updatedAt": "1970-01-01T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: url)

        XCTAssertThrowsError(try MusicLibraryManifest.read(from: url)) { error in
            XCTAssertEqual(error as? MusicLibraryManifestError, .invalidMode("remote"))
        }

        let unsupported = MusicLibraryManifest(
            schemaVersion: 999,
            displayName: "Future",
            mode: .managed
        )
        XCTAssertThrowsError(try unsupported.validated()) { error in
            XCTAssertEqual(error as? MusicLibraryManifestError, .unsupportedSchema(999))
        }
    }
}

final class MusicLibraryRegistryTests: XCTestCase {
    func testRegistryRoundTripTracksActiveAndPerModeRecents() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("LibraryRegistry.json")
        let managed = descriptor(mode: .managed, path: root.appendingPathComponent("managed"))
        let referenced = descriptor(mode: .referenced, path: root.appendingPathComponent("referenced"))
        let store = try MusicLibraryRegistryStore(fileURL: registryURL)

        try await store.register(managed)
        try await store.register(referenced)
        try await store.setActiveLibrary(id: managed.id, manifestMode: .managed)
        try await store.setActiveLibrary(id: referenced.id, manifestMode: .referenced)

        let reloaded = try MusicLibraryRegistryFile.load(from: registryURL)
        XCTAssertEqual(reloaded.libraries.count, 2)
        XCTAssertEqual(reloaded.activeLibraryID, referenced.id)
        XCTAssertEqual(reloaded.recentManagedLibraryID, managed.id)
        XCTAssertEqual(reloaded.recentReferencedLibraryID, referenced.id)
    }

    func testDuplicateIDsAndPathsAreRejected() throws {
        let id = UUID()
        let first = MusicLibraryBookmark(
            id: id,
            displayName: "First",
            rootBookmarkData: Data([1]),
            lastKnownPath: "/tmp/first",
            modeProjection: .managed
        )
        let duplicateID = MusicLibraryBookmark(
            id: id,
            displayName: "Second",
            rootBookmarkData: Data([2]),
            lastKnownPath: "/tmp/second",
            modeProjection: .managed
        )
        XCTAssertThrowsError(
            try MusicLibraryRegistry(libraries: [first, duplicateID]).validated()
        ) { error in
            XCTAssertEqual(error as? MusicLibraryRegistryError, .duplicateLibraryID)
        }

        var duplicatePath = duplicateID
        duplicatePath = MusicLibraryBookmark(
            id: UUID(),
            displayName: duplicatePath.displayName,
            rootBookmarkData: duplicatePath.rootBookmarkData,
            lastKnownPath: first.lastKnownPath,
            modeProjection: duplicatePath.modeProjection
        )
        XCTAssertThrowsError(
            try MusicLibraryRegistry(libraries: [first, duplicatePath]).validated()
        ) { error in
            XCTAssertEqual(error as? MusicLibraryRegistryError, .duplicateLibraryPath)
        }
    }

    func testCorruptedRegistryIsNotOverwritten() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("LibraryRegistry.json")
        let original = Data("not-json".utf8)
        try original.write(to: registryURL)

        XCTAssertThrowsError(try MusicLibraryRegistryStore(fileURL: registryURL))
        XCTAssertEqual(try Data(contentsOf: registryURL), original)
    }

    func testRemovingActiveLibraryRepairsAllPointers() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MusicLibraryRegistryStore(
            fileURL: root.appendingPathComponent("LibraryRegistry.json")
        )
        let first = descriptor(mode: .managed, path: root.appendingPathComponent("first"))
        let second = descriptor(mode: .managed, path: root.appendingPathComponent("second"))
        try await store.register(first)
        try await store.register(second)
        try await store.setActiveLibrary(id: first.id, manifestMode: .managed)

        try await store.remove(libraryID: first.id)

        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.activeLibraryID)
        XCTAssertEqual(snapshot.recentManagedLibraryID, second.id)
    }

    private func descriptor(mode: MusicLibraryMode, path: URL) -> MusicLibraryBookmark {
        MusicLibraryBookmark(
            id: UUID(),
            displayName: path.lastPathComponent,
            rootBookmarkData: Data(path.path.utf8),
            lastKnownPath: path.path,
            modeProjection: mode
        )
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgccc-registry-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

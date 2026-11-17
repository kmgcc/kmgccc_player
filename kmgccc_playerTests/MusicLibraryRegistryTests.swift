import Foundation
import Darwin
@testable import kmgccc_player
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

    func testApplicationStorePreservesUnreadableRegistryAndRejectsWrites() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appendingPathComponent("LibraryRegistry.json")
        let original = Data("not-json".utf8)
        try original.write(to: registryURL)
        let store = MusicLibraryRegistryStore.makeApplicationStore(fileURL: registryURL)
        do {
            try await store.register(descriptor(mode: .managed, path: root.appendingPathComponent("library")))
            XCTFail("A recovery store must not replace the original registry")
        } catch {
            guard case .some(.unavailable(_)) = error as? MusicLibraryRegistryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: registryURL), original)
        let restored = descriptor(mode: .managed, path: root.appendingPathComponent("restored"))
        try MusicLibraryRegistryFile.save(MusicLibraryRegistry(libraries: [restored]), to: registryURL)
        _ = try await store.reload()
        let next = descriptor(mode: .referenced, path: root.appendingPathComponent("next"))
        try await store.register(next)
        let saved = try MusicLibraryRegistryFile.load(from: registryURL)
        XCTAssertNotNil(saved.library(id: restored.id))
        XCTAssertNotNil(saved.library(id: next.id))
    }

    func testConcurrentStoresMergeRegistrationsFromASharedSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("LibraryRegistry.json")
        let firstStore = try MusicLibraryRegistryStore(fileURL: url)
        let secondStore = try MusicLibraryRegistryStore(fileURL: url)
        let first = descriptor(mode: .managed, path: root.appendingPathComponent("first"))
        let second = descriptor(mode: .referenced, path: root.appendingPathComponent("second"))
        // Both stores loaded the same empty file. A row-scoped commit applies
        // to the newest disk snapshot instead of replacing it wholesale.
        try await firstStore.register(first)
        try await secondStore.register(second)
        let saved = try MusicLibraryRegistryFile.load(from: url)
        XCTAssertNotNil(saved.library(id: first.id))
        XCTAssertNotNil(saved.library(id: second.id))
        XCTAssertEqual(Set(saved.libraries.map(\.id)), Set([first.id, second.id]))
    }

    func testConcurrentStoresPreserveUnrelatedRows() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("LibraryRegistry.json")
        let firstStore = try MusicLibraryRegistryStore(fileURL: url)
        let staleStore = try MusicLibraryRegistryStore(fileURL: url)
        let first = descriptor(mode: .managed, path: root.appendingPathComponent("first"))
        let second = descriptor(mode: .referenced, path: root.appendingPathComponent("second"))
        try await firstStore.register(first)
        try await staleStore.register(second)
        try await firstStore.updateDisplayName(libraryID: first.id, displayName: "Renamed")
        try await staleStore.updateBookmark(
            libraryID: second.id,
            bookmarkData: Data("bookmark".utf8),
            lastKnownPath: root.appendingPathComponent("second").path,
            modeProjection: .referenced
        )
        let saved = try MusicLibraryRegistryFile.load(from: url)
        XCTAssertEqual(saved.library(id: first.id)?.displayName, "Renamed")
        XCTAssertEqual(saved.library(id: second.id)?.rootBookmarkData, Data("bookmark".utf8))
    }

    func testRegistryRejectsSymlinkAndFIFOLockPaths() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Registry.json")
        let lock = url.appendingPathExtension("lock")
        let target = root.appendingPathComponent("user-file")
        let original = Data("keep".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        let store = try MusicLibraryRegistryStore(fileURL: url)
        let library = descriptor(mode: .managed, path: root.appendingPathComponent("library"))
        do {
            try await store.register(library)
            XCTFail("A symlink must not be accepted as the registry lock")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(Darwin.mkfifo(lock.path, 0o600), 0)
        do {
            try await store.register(library)
            XCTFail("A FIFO must not be accepted as the registry lock")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRegistryCommitRefusesWhileAnotherOpenDescriptionHoldsTheLock() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Registry.json")
        let lock = url.appendingPathExtension("lock")
        let store = try MusicLibraryRegistryStore(fileURL: url)
        let library = descriptor(mode: .managed, path: root.appendingPathComponent("library"))
        // BSD locks belong to the open file description, so a raw open models
        // a second App process inside its commit critical section.
        let descriptorFD = Darwin.open(
            lock.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertGreaterThanOrEqual(descriptorFD, 0)
        defer { _ = Darwin.close(descriptorFD) }
        XCTAssertEqual(kmgccc_flock(descriptorFD, LOCK_EX | LOCK_NB), 0)
        do {
            try await store.register(library)
            XCTFail("A held cross-process lock must refuse the commit")
        } catch {
            XCTAssertEqual(error as? MusicLibraryRegistryError, .registryLocked)
        }
        XCTAssertEqual(kmgccc_flock(descriptorFD, LOCK_UN), 0)
        try await store.register(library)
        XCTAssertNotNil(try MusicLibraryRegistryFile.load(from: url).library(id: library.id))
    }

    func testConditionalDescriptorReplacementPreservesUnrelatedRegistryChanges() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MusicLibraryRegistryStore(fileURL: root.appendingPathComponent("Registry.json"))
        let first = descriptor(mode: .managed, path: root.appendingPathComponent("first"))
        let second = descriptor(mode: .referenced, path: root.appendingPathComponent("second"))
        try await store.register(first)
        try await store.register(second)
        try await store.setActiveLibrary(id: second.id, manifestMode: .referenced)
        var moved = first
        moved.lastKnownPath = root.appendingPathComponent("moved").path
        try await store.replaceDescriptor(expected: first, with: moved)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.library(id: first.id), moved)
        XCTAssertEqual(snapshot.library(id: second.id), second)
        XCTAssertEqual(snapshot.activeLibraryID, second.id)
        do {
            try await store.replaceDescriptor(expected: first, with: moved)
            XCTFail("A changed transaction row must not be overwritten")
        } catch {
            XCTAssertEqual(error as? MusicLibraryRegistryError, .externalModification)
        }
    }

    func testActivationRollbackRetainsUnrelatedRegistrationAndSelection() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MusicLibraryRegistryStore(fileURL: root.appendingPathComponent("Registry.json"))
        let original = descriptor(mode: .managed, path: root.appendingPathComponent("original"))
        let target = descriptor(mode: .managed, path: root.appendingPathComponent("target"))
        let unrelated = descriptor(mode: .referenced, path: root.appendingPathComponent("unrelated"))
        try await store.register(original)
        try await store.setActiveLibrary(id: original.id, manifestMode: .managed)
        let before = await store.snapshot()
        try await store.register(target)
        try await store.register(unrelated)
        try await store.setActiveLibrary(id: unrelated.id, manifestMode: .referenced)
        try await store.rollbackActivation(before: before, target: target, staleID: nil)
        let after = await store.snapshot()
        XCTAssertNil(after.library(id: target.id))
        XCTAssertEqual(after.library(id: unrelated.id), unrelated)
        XCTAssertEqual(after.activeLibraryID, unrelated.id)
    }

    func testStaleConditionalReplacementStillFailsClosed() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Registry.json")
        let writer = try MusicLibraryRegistryStore(fileURL: url)
        let staleStore = try MusicLibraryRegistryStore(fileURL: url)
        let original = descriptor(mode: .managed, path: root.appendingPathComponent("original"))
        try await writer.register(original)
        var renamed = original
        renamed.displayName = "Renamed"
        try await writer.updateDisplayName(libraryID: original.id, displayName: "Renamed")
        do {
            try await staleStore.replaceDescriptor(expected: original, with: renamed)
            XCTFail("A stale transaction row must not overwrite a newer rename")
        } catch {
            XCTAssertEqual(error as? MusicLibraryRegistryError, .externalModification)
        }
        XCTAssertEqual(try MusicLibraryRegistryFile.load(from: url).library(id: original.id)?.displayName, "Renamed")
    }

    func testStaleStoreWritesSelectionAgainstNewestSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Registry.json")
        let firstStore = try MusicLibraryRegistryStore(fileURL: url)
        let first = descriptor(mode: .managed, path: root.appendingPathComponent("first"))
        let second = descriptor(mode: .referenced, path: root.appendingPathComponent("second"))
        try await firstStore.register(first)
        try await firstStore.register(second)
        try await firstStore.setActiveLibrary(id: first.id, manifestMode: .managed)
        let staleStore = try MusicLibraryRegistryStore(fileURL: url)
        try await firstStore.setActiveLibrary(id: second.id, manifestMode: .referenced)
        // An explicit selection is a real write. It applies to the newest
        // snapshot and must not drop either registration.
        try await staleStore.setActiveLibrary(id: first.id, manifestMode: .managed)
        let saved = try MusicLibraryRegistryFile.load(from: url)
        XCTAssertEqual(saved.activeLibraryID, first.id)
        XCTAssertEqual(Set(saved.libraries.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(saved.recentReferencedLibraryID, second.id)
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

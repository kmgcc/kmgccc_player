import XCTest
@testable import kmgccc_player

@MainActor
final class MusicSettingsStateTests: XCTestCase {
    func testModeRoutingUsesReachableRecentWithoutChangingPresentation() {
        let managed = bookmark(mode: .managed, path: "/managed")
        let referenced = bookmark(mode: .referenced, path: "/referenced")
        let registry = kmgccc_player.MusicLibraryRegistry(
            libraries: [managed, referenced],
            activeLibraryID: managed.id,
            recentManagedLibraryID: managed.id,
            recentReferencedLibraryID: referenced.id
        )
        let viewModel = LibrarySetupViewModel(mode: .managed)

        let target = viewModel.routeModeSelection(
            .referenced,
            activeMode: .managed,
            registry: registry
        )

        XCTAssertEqual(target, referenced.id)
        XCTAssertEqual(viewModel.presentation, .none)
        XCTAssertEqual(viewModel.mode, .managed)
    }

    func testModeRoutingUsesSetupWhenModeHasNoLibrary() {
        let managed = bookmark(mode: .managed, path: "/managed")
        let registry = kmgccc_player.MusicLibraryRegistry(libraries: [managed], activeLibraryID: managed.id, recentManagedLibraryID: managed.id)
        let viewModel = LibrarySetupViewModel(mode: .managed)

        XCTAssertNil(viewModel.routeModeSelection(.referenced, activeMode: .managed, registry: registry))
        XCTAssertEqual(viewModel.presentation, .setup(.referenced))
    }

    func testModeRoutingReturnsRecentForBookmarkActivation() {
        let referenced = bookmark(mode: .referenced, path: "/offline")
        let registry = kmgccc_player.MusicLibraryRegistry(libraries: [referenced], recentReferencedLibraryID: referenced.id)
        let viewModel = LibrarySetupViewModel()

        XCTAssertEqual(
            viewModel.routeModeSelection(.referenced, activeMode: .managed, registry: registry),
            referenced.id
        )
        XCTAssertEqual(viewModel.presentation, .none)
    }

    func testPresentationsAreMutuallyExclusive() {
        let id = UUID()
        let viewModel = LibrarySetupViewModel()
        viewModel.present(.setup(.managed))
        viewModel.present(.chooser(.referenced))
        viewModel.present(.reconnectRequired(libraryID: id, mode: .referenced))

        XCTAssertEqual(viewModel.presentation, .reconnectRequired(libraryID: id, mode: .referenced))
    }

    func testStorageLocationIsImplicitUntilPickerSelection() {
        let viewModel = LibrarySetupViewModel(mode: .managed)
        XCTAssertFalse(viewModel.isStorageLocationExplicitlyChosen)

        viewModel.storageParentURL = temporaryLibraryRoot()

        XCTAssertTrue(viewModel.isStorageLocationExplicitlyChosen)
    }

    func testDeletePolicyIsStoredInsideEachLibrary() async throws {
        let first = temporaryLibraryRoot()
        let second = temporaryLibraryRoot()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let firstStore = LibraryScopedSettingsStore(paths: kmgccc_player.LibraryPaths(rootURL: first))
        let secondStore = LibraryScopedSettingsStore(paths: kmgccc_player.LibraryPaths(rootURL: second))

        try await firstStore.setReferencedTrackDeletePolicy(.recycleSource)

        let firstSettings = try await firstStore.load()
        let secondSettings = try await secondStore.load()
        XCTAssertEqual(firstSettings.referencedTrackDeletePolicy, ReferencedTrackDeletePolicy.recycleSource)
        XCTAssertEqual(secondSettings.referencedTrackDeletePolicy, ReferencedTrackDeletePolicy.onlyLibrary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kmgccc_player.LibraryPaths(rootURL: first).librarySettingsURL.path))
    }

    func testInvalidSettingsPayloadDoesNotFallBackToGlobalState() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.settingsRootURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: paths.librarySettingsURL)
        let store = LibraryScopedSettingsStore(paths: paths)

        do {
            _ = try await store.load()
            XCTFail("Expected invalid payload")
        } catch {
            XCTAssertEqual(error as? LibraryScopedSettingsError, .invalidPayload)
        }
    }

    func testOnlyExactlyEmptyObjectUsesDevelopmentMigration() async throws {
        let payloads: [(String, LibraryScopedSettingsError)] = [
            ("{\"unknown\":1}", .invalidPayload),
            ("[]", .invalidPayload),
            ("null", .invalidPayload),
            ("{\"schemaVersion\":999,\"referencedTrackDeletePolicy\":\"onlyLibrary\"}", .unsupportedSchema(999)),
        ]

        for (payload, expected) in payloads {
            let root = temporaryLibraryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = kmgccc_player.LibraryPaths(rootURL: root)
            try FileManager.default.createDirectory(at: paths.settingsRootURL, withIntermediateDirectories: true)
            try Data(payload.utf8).write(to: paths.librarySettingsURL)

            do {
                _ = try await LibraryScopedSettingsStore(paths: paths).load()
                XCTFail("Expected settings error for \(payload)")
            } catch {
                XCTAssertEqual(error as? LibraryScopedSettingsError, expected)
            }
        }
    }

    private func bookmark(mode: kmgccc_player.MusicLibraryMode, path: String) -> kmgccc_player.MusicLibraryBookmark {
        kmgccc_player.MusicLibraryBookmark(id: UUID(), displayName: path, rootBookmarkData: Data([1]), lastKnownPath: path, modeProjection: mode)
    }

    private func temporaryLibraryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

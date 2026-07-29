import AVFoundation
import SwiftData
import XCTest
@testable import kmgccc_player

nonisolated private final class TrackingRootBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    var url: URL
    var startResult = true
    private(set) var starts = 0
    private(set) var stops = 0

    init(url: URL) {
        self.url = url
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (url, false)
    }

    func refreshBookmark(for url: URL) throws -> Data {
        Data([1])
    }

    func startAccessing(_ url: URL) -> Bool {
        starts += 1
        return startResult
    }

    func stopAccessing(_ url: URL) {
        stops += 1
    }
}

@MainActor
final class LibraryInitialImportIntegrationTests: XCTestCase {
    func testReferencedCreationInitialFolderImportPersistsSourceAndRestarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        let selection = LibraryInitialImportSelection(urls: [fixture.sourceRoot])

        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Referenced",
            initialImportSelection: selection
        )

        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let context = session.context
        let descriptors = try await XCTUnwrap(session.referencedSourceStore).loadAll()
        XCTAssertEqual(descriptors.count, 1)
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.paths.sourceDescriptorURL(for: descriptor.id).path))

        let tracks = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.count, 1)
        let track = try XCTUnwrap(tracks.first)
        let locator = try XCTUnwrap(track.mediaLocator.referencedFile)
        XCTAssertEqual(locator.primarySourceID, descriptor.id)
        XCTAssertEqual(locator.sourceMemberships.map(\.sourceID), [descriptor.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.paths.trackMetaURL(for: track.id).path))
        XCTAssertFalse(try trackPackageContainsAudio(context.paths.trackFolderURL(for: track.id)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))

        await session.quiesce()
        await session.close()
        let restarted = try await LibrarySessionFactory().makeSession(for: context)
        let restartedSession = try XCTUnwrap(restarted as? LibrarySession)
        try await restartedSession.load()
        let restartedSources = try await XCTUnwrap(restartedSession.referencedSourceStore).loadAll()
        let restartedTracks = await restartedSession.repository.fetchTracks(in: nil)
        XCTAssertEqual(restartedSources.map(\.id), [descriptor.id])
        XCTAssertEqual(restartedTracks.map(\.id), [track.id])
        XCTAssertEqual(restartedTracks.first?.mediaLocator.referencedFile?.primarySourceID, descriptor.id)
        await restartedSession.quiesce()
        await restartedSession.close()
    }

    func testEmptyAndUnsupportedFoldersRegisterSourceAndReturnWarningResult() async throws {
        for unsupportedOnly in [false, true] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.removeItem(at: fixture.wavURL)
            if unsupportedOnly {
                try Data("text".utf8).write(to: fixture.sourceRoot.appendingPathComponent("Unsupported.txt"))
            }
            let host = try makeHost(registryURL: fixture.registryURL)
            let result = try await host.createMusicLibrary(
                mode: .referenced,
                parentURL: fixture.libraryParent,
                displayName: "Empty",
                initialImportSelection: LibraryInitialImportSelection(urls: [fixture.sourceRoot])
            )
            guard case .created(_, let initial?) = result else { return XCTFail("Expected created result") }
            XCTAssertEqual(initial.imported, 0)
            XCTAssertEqual(initial.sourceIDs.count, 1)
            XCTAssertTrue(initial.isPartial)
            XCTAssertFalse(initial.failures.isEmpty)
            if let session = host.activeLibraryBinding.activeSession {
                await session.quiesce()
                await session.close()
            }
        }
    }

    func testStandaloneCorruptAudioThrowsTypedFailureAndKeepsCreatedLibrary() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = fixture.root.appendingPathComponent("Corrupt.wav")
        try Data("not audio".utf8).write(to: corrupt)
        let host = try makeHost(registryURL: fixture.registryURL)

        do {
            _ = try await host.createMusicLibrary(
                mode: .referenced,
                parentURL: fixture.libraryParent,
                displayName: "Corrupt",
                initialImportSelection: LibraryInitialImportSelection(urls: [corrupt])
            )
            XCTFail("Expected typed initial import failure")
        } catch LibraryInitialImportError.initialImportFailed(let result) {
            XCTAssertEqual(result.imported, 0)
            XCTAssertTrue(result.sourceIDs.isEmpty)
            XCTAssertFalse(result.failures.isEmpty)
            XCTAssertNotNil(host.activeLibraryBinding.context)
        }
        if let session = host.activeLibraryBinding.activeSession {
            await session.quiesce()
            await session.close()
        }
    }

    func testFailedInitialImportCanRetryInsideCreatedLibrary() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = fixture.root.appendingPathComponent("Retry.wav")
        try Data("not audio".utf8).write(to: corrupt)
        let host = try makeHost(registryURL: fixture.registryURL)
        let selection = LibraryInitialImportSelection(urls: [corrupt])

        do {
            _ = try await host.createMusicLibrary(
                mode: .referenced,
                parentURL: fixture.libraryParent,
                displayName: "Retry",
                initialImportSelection: selection
            )
            XCTFail("Expected typed initial import failure")
        } catch LibraryInitialImportError.initialImportFailed {
            try writeWAV(to: corrupt)
            let result = try await host.importMusicSelection(selection)
            XCTAssertEqual(result.imported, 1)
            XCTAssertTrue(result.failures.isEmpty)
            let tracks = await host.activeLibraryBinding.activeSession?.repository.fetchTracks(in: nil)
            XCTAssertEqual(tracks?.count, 1)
        }

        selection.release()
        if let session = host.activeLibraryBinding.activeSession {
            await session.quiesce()
            await session.close()
        }
    }

    func testPartialInitialImportReturnsWarningAndPreservesSuccessfulTrack() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("not audio".utf8).write(to: fixture.sourceRoot.appendingPathComponent("Corrupt.wav"))
        let host = try makeHost(registryURL: fixture.registryURL)
        let result = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Partial",
            initialImportSelection: LibraryInitialImportSelection(urls: [fixture.sourceRoot])
        )
        guard case .created(_, let initial?) = result else { return XCTFail("Expected created result") }
        XCTAssertEqual(initial.imported, 1)
        XCTAssertTrue(initial.isPartial)
        XCTAssertFalse(initial.failures.isEmpty)
        let importedTrackCount = await host.activeLibraryBinding.activeSession?.repository.fetchTracks(in: nil).count
        XCTAssertEqual(importedTrackCount, 1)
        if let session = host.activeLibraryBinding.activeSession {
            await session.quiesce()
            await session.close()
        }
    }

    func testExistingLibraryResultDoesNotImportSelectionOrActivateSilently() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "First",
            initialImportSelection: nil
        )
        let result = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Second",
            initialImportSelection: LibraryInitialImportSelection(urls: [fixture.sourceRoot])
        )
        guard case .existingLibraryModeMismatch(let context, requestedMode: .managed) = result else {
            return XCTFail("Expected mode mismatch")
        }
        XCTAssertEqual(context.mode, .referenced)
        let existingTracks = await host.activeLibraryBinding.activeSession?.repository.fetchTracks(in: nil)
        XCTAssertTrue(existingTracks?.isEmpty ?? false)
        if let session = host.activeLibraryBinding.activeSession {
            await session.quiesce()
            await session.close()
        }
    }

    func testManagedCreationInitialFolderImportStillCopiesAudio() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        let selection = LibraryInitialImportSelection(urls: [fixture.sourceRoot])

        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Managed",
            initialImportSelection: selection
        )

        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let tracks = await session.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.mediaLocator.storageKind, .managed)
        XCTAssertTrue(try trackPackageContainsAudio(session.context.paths.trackFolderURL(for: track.id)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertNil(session.referencedSourceStore)
        await session.quiesce()
        await session.close()
    }

    func testOnlyLibraryDeletionKeepsReferencedAudio() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Delete",
            initialImportSelection: LibraryInitialImportSelection(urls: [fixture.sourceRoot])
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        try await LibraryScopedSettingsStore(paths: session.context.paths).setReferencedTrackDeletePolicy(.onlyLibrary)
        let beforeDeletion = await session.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(beforeDeletion.first)

        await session.libraryViewModel.deleteTrack(track)

        let remaining = await session.repository.fetchTracks(in: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertTrue(remaining.isEmpty)
        await session.quiesce()
        await session.close()
    }

    func testRecycleFailureKeepsReferencedTrackAuthority() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Delete Failure",
            initialImportSelection: LibraryInitialImportSelection(urls: [fixture.sourceRoot])
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        try await LibraryScopedSettingsStore(paths: session.context.paths).setReferencedTrackDeletePolicy(.recycleSource)
        let deletion = ReferencedTrackDeletionService(
            context: session.context,
            sourceScope: try XCTUnwrap(session.referencedSourceScope),
            recycler: FailingTrackRecycler()
        )
        session.libraryViewModel.prepareTracksForDeletion = { tracks in
            await deletion.prepareForAuthorityDeletion(tracks)
        }
        let beforeDeletion = await session.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(beforeDeletion.first)

        await session.libraryViewModel.deleteTrack(track)

        let retained = await session.repository.fetchTracks(in: nil).first { $0.id == track.id }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.wavURL.path))
        XCTAssertNotNil(retained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.context.paths.trackMetaURL(for: track.id).path))
        await session.quiesce()
        await session.close()
    }

    func testBatchRecycleFailureDeletesOnlySuccessfullyRecycledAuthority() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retainedURL = fixture.sourceRoot.appendingPathComponent("Retained.wav")
        try writeWAV(to: retainedURL)
        let host = try makeHost(registryURL: fixture.registryURL)
        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Batch Delete",
            initialImportSelection: LibraryInitialImportSelection(urls: [fixture.sourceRoot])
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        try await LibraryScopedSettingsStore(paths: session.context.paths).setReferencedTrackDeletePolicy(.recycleSource)
        let deletion = ReferencedTrackDeletionService(
            context: session.context,
            sourceScope: try XCTUnwrap(session.referencedSourceScope),
            recycler: SelectiveTrackRecycler(failingName: retainedURL.lastPathComponent)
        )
        session.libraryViewModel.prepareTracksForDeletion = { tracks in
            await deletion.prepareForAuthorityDeletion(tracks)
        }
        var reportedFailures: [TrackAuthorityDeletionFailure] = []
        session.libraryViewModel.onTrackDeletionPreparationFailures = {
            reportedFailures = $0
        }
        let tracks = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.count, 2)
        let retainedTrack = try XCTUnwrap(tracks.first {
            $0.mediaLocator.referencedFile?.sourceMemberships.contains {
                $0.relativePath == retainedURL.lastPathComponent
            } == true
        })
        let recycledTrack = try XCTUnwrap(tracks.first { $0.id != retainedTrack.id })
        let recycledRelativePath = try XCTUnwrap(
            recycledTrack.mediaLocator.referencedFile?.sourceMemberships.first?.relativePath
        )
        let recycledURL = fixture.sourceRoot.appendingPathComponent(recycledRelativePath)

        await session.libraryViewModel.deleteTracks(tracks)

        let remaining = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(remaining.map(\.id), [retainedTrack.id])
        XCTAssertEqual(reportedFailures.map(\.trackID), [retainedTrack.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recycledURL.path))
        await session.quiesce()
        await session.close()
    }

    func testSessionRetainsRootScopeUntilClose() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Root Scope",
            initialImportSelection: nil
        )
        let original = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let context = original.context
        await original.quiesce()
        await original.close()
        _ = host.activeLibraryBinding.releaseActiveSession()

        let resolver = TrackingRootBookmarkResolver(url: context.rootURL)
        let rebuilt = try await LibrarySessionFactory(
            sourceBookmarkResolver: resolver,
            requiresSecurityScope: true
        ).makeSession(for: context)
        XCTAssertEqual(resolver.starts, 1)
        XCTAssertEqual(resolver.stops, 0)

        await rebuilt.close()
        XCTAssertEqual(resolver.stops, 1)
    }

    func testEmptyDevelopmentSettingsMigratesToDefaultsAndRewritesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        try FileManager.default.createDirectory(at: paths.settingsRootURL, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: paths.librarySettingsURL)

        let loaded = try await LibraryScopedSettingsStore(paths: paths).load()
        XCTAssertEqual(loaded, LibraryScopedSettings())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.librarySettingsURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, LibraryScopedSettings.schemaVersion)
        XCTAssertEqual(object["referencedTrackDeletePolicy"] as? String, ReferencedTrackDeletePolicy.onlyLibrary.rawValue)
    }

    func testFreshProductionCreationWritesCompleteSettingsJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Fresh", mode: .referenced)
        let fileOperator = ProductionLibraryLifecycleFileOperator()

        try await fileOperator.createStagedLibrary(at: staging, manifest: manifest)

        let paths = kmgccc_player.LibraryPaths(rootURL: staging)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.librarySettingsURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, LibraryScopedSettings.schemaVersion)
        XCTAssertEqual(object["referencedTrackDeletePolicy"] as? String, ReferencedTrackDeletePolicy.onlyLibrary.rawValue)
        let loaded = try await LibraryScopedSettingsStore(paths: paths).load()
        XCTAssertEqual(loaded, LibraryScopedSettings())
    }

    private struct Fixture {
        let root: URL
        let sourceRoot: URL
        let libraryParent: URL
        let registryURL: URL
        let wavURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let libraryParent = root.appendingPathComponent("Library Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryParent, withIntermediateDirectories: true)
        let wavURL = sourceRoot.appendingPathComponent("Initial.wav")
        try writeWAV(to: wavURL)
        return Fixture(
            root: root,
            sourceRoot: sourceRoot,
            libraryParent: libraryParent,
            registryURL: root.appendingPathComponent("Registry.json"),
            wavURL: wavURL
        )
    }

    private func makeHost(registryURL: URL) throws -> AppSessionHost {
        let schema = Schema([TrackIndexEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return AppSessionHost(
            modelContainer: container,
            initialLibraryContext: nil,
            registryStore: try kmgccc_player.MusicLibraryRegistryStore(fileURL: registryURL),
            sessionFactory: LibrarySessionFactory()
        )
    }

    private func trackPackageContainsAudio(_ packageURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: packageURL.path) else { return false }
        return try FileManager.default.contentsOfDirectory(at: packageURL, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("audio.") }
    }

    private func writeWAV(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        )
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)
        )
        buffer.frameLength = 4_410
        try audioFile.write(from: buffer)
    }

    private struct FailingTrackRecycler: LibraryRecycling {
        struct Failure: Error {}
        func recycle(_ url: URL) async throws { throw Failure() }
    }

    private struct SelectiveTrackRecycler: LibraryRecycling {
        struct Failure: Error {}
        let failingName: String

        func recycle(_ url: URL) async throws {
            guard url.lastPathComponent != failingName else { throw Failure() }
            try FileManager.default.removeItem(at: url)
        }
    }
}

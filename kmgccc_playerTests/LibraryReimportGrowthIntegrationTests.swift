import AVFoundation
import SwiftData
import XCTest
@testable import kmgccc_player

/// Plan §7.5 acceptance: when a directory grows from 1–10 to 1–15 files and is
/// re-imported into its bound playlist, both storage modes must add 5 tracks,
/// reuse 10, end at 15 playlist entries and 15 library tracks, and never
/// produce duplicate Track records or duplicate managed copies.
@MainActor
final class LibraryReimportGrowthIntegrationTests: XCTestCase {
    func testReferencedDirectoryGrowthReimportAddsFiveAndReusesTen() async throws {
        let fixture = try makeFixture(initialFileCount: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Growth Referenced",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        var playlists = await session.repository.fetchPlaylists()
        XCTAssertEqual(playlists.count, 1)
        let playlist = try XCTUnwrap(playlists.first)
        XCTAssertEqual(playlist.tracks.count, 10)

        for index in 11...15 {
            try writeWAV(to: fixture.sourceRoot.appendingPathComponent("\(index).wav"))
        }
        let result = await session.fileImportService.importSelectedURLs(
            [fixture.sourceRoot],
            context: LibraryImportContext(
                libraryID: session.context.id,
                sessionGeneration: session.context.generation,
                destination: .playlist(playlist.id),
                origin: .windowDrop
            )
        )

        XCTAssertEqual(result.importedTrackCount, 5)
        XCTAssertEqual(result.reusedTrackCount, 10)
        XCTAssertEqual(result.playlistMembershipAdditions, 5)
        XCTAssertEqual(result.alreadyInPlaylistCount, 10)
        XCTAssertEqual(result.possibleDuplicatesCount, 0)
        XCTAssertTrue(result.failures.isEmpty)

        let allTracks = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 15)
        XCTAssertEqual(Set(allTracks.map(\.id)).count, 15, "duplicate Track records were created")
        playlists = await session.repository.fetchPlaylists()
        XCTAssertEqual(playlists.first { $0.id == playlist.id }?.tracks.count, 15)
        let locatorPaths = allTracks.compactMap { $0.mediaLocator.referencedFile?.lastKnownPath }
        XCTAssertEqual(locatorPaths.count, 15)
        XCTAssertEqual(Set(locatorPaths).count, 15, "duplicate referenced copies were created")

        await session.fileImportService.cancelEnrichment(for: Set(allTracks.map(\.id)))
        await session.quiesce()
        await session.close()
    }

    func testManagedDirectoryGrowthReimportAddsFiveAndReusesTen() async throws {
        let fixture = try makeFixture(initialFileCount: 10)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Growth Managed",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        var playlists = await session.repository.fetchPlaylists()
        XCTAssertEqual(playlists.count, 1)
        let playlist = try XCTUnwrap(playlists.first)
        XCTAssertEqual(playlist.tracks.count, 10)

        for index in 11...15 {
            try writeWAV(to: fixture.sourceRoot.appendingPathComponent("\(index).wav"))
        }
        let result = await session.fileImportService.importSelectedURLs(
            [fixture.sourceRoot],
            context: LibraryImportContext(
                libraryID: session.context.id,
                sessionGeneration: session.context.generation,
                destination: .playlist(playlist.id),
                origin: .windowDrop
            )
        )

        XCTAssertEqual(result.importedTrackCount, 5)
        XCTAssertEqual(result.reusedTrackCount, 10)
        XCTAssertEqual(result.playlistMembershipAdditions, 5)
        XCTAssertEqual(result.alreadyInPlaylistCount, 10)
        XCTAssertEqual(result.possibleDuplicatesCount, 0)
        XCTAssertTrue(result.failures.isEmpty)

        let allTracks = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 15)
        XCTAssertEqual(Set(allTracks.map(\.id)).count, 15, "duplicate Track records were created")
        playlists = await session.repository.fetchPlaylists()
        XCTAssertEqual(playlists.first { $0.id == playlist.id }?.tracks.count, 15)
        let managedCopies = allTracks.compactMap { track -> String? in
            guard case let .managed(libraryRelativePath) = track.mediaLocator else { return nil }
            return libraryRelativePath
        }
        XCTAssertEqual(managedCopies.count, 15)
        XCTAssertEqual(Set(managedCopies).count, 15, "duplicate managed audio copies were created")

        await session.fileImportService.cancelEnrichment(for: Set(allTracks.map(\.id)))
        await session.quiesce()
        await session.close()
    }

    func testReferencedInteractiveMetadataDuplicateLinksExistingTrackAndAddsPlaylistMembership() async throws {
        let fixture = try makeFixture(initialFileCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let duplicateRoot = fixture.root.appendingPathComponent("Duplicate Source", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateRoot, withIntermediateDirectories: true)
        let duplicateURL = duplicateRoot.appendingPathComponent("1.wav")
        try writeWAV(to: duplicateURL, sampleValue: 0.25)

        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .referenced,
            parentURL: fixture.libraryParent,
            displayName: "Duplicate Referenced",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let initialTracks = await session.repository.fetchTracks(in: nil)
        let existing = try XCTUnwrap(initialTracks.first)
        // Reproduce a track that was previously marked unavailable by a
        // background resolution. Importing a readable duplicate must recover
        // that state before the track is offered for playback.
        existing.availability = .missing
        await session.repository.persistTrackMetaOnly(existing, reason: "testStaleDuplicateAvailability")
        let destination = try await session.repository.createPlaylist(name: "Duplicate Target")
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let result = await session.fileImportService.importSelectedURLs(
            [duplicateURL],
            context: LibraryImportContext(
                libraryID: session.context.id,
                sessionGeneration: session.context.generation,
                destination: .playlist(destination.id),
                origin: .windowDrop
            )
        )

        XCTAssertEqual(result.importedTrackCount, 0)
        XCTAssertEqual(result.reusedTrackCount, 1)
        XCTAssertEqual(result.playlistMembershipAdditions, 1)
        XCTAssertEqual(result.alreadyInPlaylistCount, 0)
        XCTAssertEqual(result.possibleDuplicatesCount, 1)
        XCTAssertTrue(result.failures.isEmpty)

        let allTracks = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.map(\.id), [existing.id], "referenced duplicate must not create a Track")
        let locator = try XCTUnwrap(existing.mediaLocator.referencedFile)
        XCTAssertEqual(locator.locations.count, 2, "the selected duplicate should be retained as a second location")
        XCTAssertTrue(locator.locations.contains { $0.lastKnownPath == duplicateURL.path })
        XCTAssertEqual(locator.lastKnownPath, duplicateURL.path, "the newly imported readable location should be preferred")
        XCTAssertEqual(existing.availability, .available)
        XCTAssertTrue(existing.isPlayable)
        let savedPlaylists = await session.repository.fetchPlaylists()
        let savedPlaylist = try XCTUnwrap(savedPlaylists.first { $0.id == destination.id })
        XCTAssertEqual(savedPlaylist.tracks.map(\.id), [existing.id])

        // The imported copy is the preferred locator. If that copy later
        // becomes unreadable (a partial/corrupt file is a real-world failure
        // mode), playback must fall back to the original source location
        // retained by the referenced locator rather than failing the track.
        try Data("not an audio file".utf8).write(to: duplicateURL)
        let roots = session.referencedSourceScope?.authorizedRoots ?? [:]
        let prepared = try await AudioFilePreparationActor().prepare(
            AudioPrepRequest(
                trackID: existing.id,
                locator: existing.mediaLocator,
                libraryPaths: session.context.paths,
                authorizedSourceRoots: roots,
                titleForLog: existing.title
            )
        )
        XCTAssertEqual(
            prepared.resolvedURL.resolvingSymlinksInPath().standardizedFileURL,
            fixture.sourceRoot.appendingPathComponent("1.wav")
                .resolvingSymlinksInPath().standardizedFileURL
        )
        prepared.lease.release()

        await session.fileImportService.cancelEnrichment(for: Set(allTracks.map(\.id)))
        await session.quiesce()
        await session.close()
    }

    func testManagedInteractiveMetadataDuplicateCopiesTrackIntoPlaylist() async throws {
        let fixture = try makeFixture(initialFileCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let duplicateRoot = fixture.root.appendingPathComponent("Duplicate Source", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateRoot, withIntermediateDirectories: true)
        let duplicateURL = duplicateRoot.appendingPathComponent("1.wav")
        try writeWAV(to: duplicateURL, sampleValue: 0.25)

        let host = try makeHost(registryURL: fixture.registryURL)
        let entries = LibraryImportSourceEntry.makeEntries(from: [fixture.sourceRoot])
        _ = try await host.createMusicLibrary(
            mode: .managed,
            parentURL: fixture.libraryParent,
            displayName: "Duplicate Managed",
            initialImportSelection: LibraryInitialImportSelection(
                urls: [fixture.sourceRoot],
                playlistSourceEntries: entries
            )
        )
        let session = try XCTUnwrap(host.activeLibraryBinding.activeSession)
        let initialTracks = await session.repository.fetchTracks(in: nil)
        let existing = try XCTUnwrap(initialTracks.first)
        let destination = try await session.repository.createPlaylist(name: "Duplicate Target")
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let result = await session.fileImportService.importSelectedURLs(
            [duplicateURL],
            context: LibraryImportContext(
                libraryID: session.context.id,
                sessionGeneration: session.context.generation,
                destination: .playlist(destination.id),
                origin: .windowDrop
            )
        )

        XCTAssertEqual(result.importedTrackCount, 1)
        XCTAssertEqual(result.reusedTrackCount, 0)
        XCTAssertEqual(result.playlistMembershipAdditions, 1)
        XCTAssertEqual(result.alreadyInPlaylistCount, 0)
        XCTAssertEqual(result.possibleDuplicatesCount, 1)
        XCTAssertTrue(result.failures.isEmpty)

        let allTracks = await session.repository.fetchTracks(in: nil)
        XCTAssertEqual(allTracks.count, 2, "managed duplicate should be a copied Track")
        let copied = try XCTUnwrap(allTracks.first { $0.id != existing.id })
        guard case let .managed(relativePath) = copied.mediaLocator else {
            return XCTFail("managed duplicate must have a managed placement")
        }
        XCTAssertNotEqual(relativePath, existing.mediaLocator.managedLibraryRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.resolvedAudioURL()?.path ?? ""))
        let savedPlaylists = await session.repository.fetchPlaylists()
        let savedPlaylist = try XCTUnwrap(savedPlaylists.first { $0.id == destination.id })
        XCTAssertEqual(savedPlaylist.tracks.map(\.id), [copied.id])

        await session.fileImportService.cancelEnrichment(for: Set(allTracks.map(\.id)))
        await session.quiesce()
        await session.close()
    }

    private struct Fixture {
        let root: URL
        let sourceRoot: URL
        let libraryParent: URL
        let registryURL: URL
    }

    private func makeFixture(initialFileCount: Int) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let libraryParent = root.appendingPathComponent("Library Parent", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraryParent, withIntermediateDirectories: true)
        for index in 1...initialFileCount {
            try writeWAV(to: sourceRoot.appendingPathComponent("\(index).wav"))
        }
        return Fixture(
            root: root,
            sourceRoot: sourceRoot,
            libraryParent: libraryParent,
            registryURL: root.appendingPathComponent("Registry.json")
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

    private func writeWAV(to url: URL, sampleValue: Float = 0) throws {
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
        if let channelData = buffer.floatChannelData?[0] {
            for frame in 0..<Int(buffer.frameLength) {
                channelData[frame] = sampleValue
            }
        }
        try audioFile.write(from: buffer)
    }
}

import AVFoundation
import Foundation
@testable import kmgccc_player
import XCTest

private final class ReconcileBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { true }
    func stopAccessing(_: URL) {}
}

private final class StartupBookmarkResolver: kmgccc_player.BookmarkResolving, @unchecked Sendable {
    enum Mode { case available, offline, permissionDenied }

    private let lock = NSLock()
    private let url: URL
    private var mode: Mode

    init(url: URL, mode: Mode) {
        self.url = url
        self.mode = mode
    }

    func setMode(_ mode: Mode) { lock.withLock { self.mode = mode } }

    func resolve(_: Data) throws -> (url: URL, isStale: Bool) {
        if lock.withLock({ mode == .offline }) { throw CocoaError(.fileNoSuchFile) }
        return (url, false)
    }

    func refreshBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func startAccessing(_: URL) -> Bool { lock.withLock { mode == .available } }
    func stopAccessing(_: URL) {}
}

@MainActor
private final class ReconcileImporter: AutomaticReferencedFileImporting {
    let repository: SwiftDataLibraryRepository
    private let fingerprintProvider: @Sendable (URL) throws -> kmgccc_player.ReferencedFileFingerprint
    var beforeImport: (() async -> Void)?
    var rejectNextImport = false

    init(
        repository: SwiftDataLibraryRepository,
        fingerprintProvider: @escaping @Sendable (URL) throws -> kmgccc_player.ReferencedFileFingerprint
    ) {
        self.repository = repository
        self.fingerprintProvider = fingerprintProvider
    }

    func importAutomatically(_ urls: [URL]) async -> [Track] {
        await beforeImport?()
        if rejectNextImport {
            rejectNextImport = false
            return []
        }
        var result: [Track] = []
        for url in urls {
            guard let fingerprint = try? fingerprintProvider(url) else { continue }
            if let existing = await repository.track(matching: fingerprint) {
                result.append(existing)
                continue
            }
            let locator = kmgccc_player.ReferencedFileLocator(
                fileBookmarkData: Data(url.path.utf8),
                lastKnownPath: url.path,
                fingerprint: fingerprint
            )
            let track = Track(
                title: url.deletingPathExtension().lastPathComponent,
                userDescription: "application metadata",
                fileBookmarkData: locator.fileBookmarkData,
                originalFilePath: url.path,
                mediaLocator: .referenced(locator),
                libraryRootSnapshot: "test"
            )
            let committed = await repository.commitImportedTracks([track])
            if committed.persistedTrackIDs.contains(track.id) { result.append(track) }
        }
        return result
    }
}

private final class PartialLocatorWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failNextIDs = Set<UUID>()
    private var counts: [UUID: Int] = [:]

    var failOnceID: UUID? {
        get { nil }
        set {
            guard let newValue else { return }
            lock.withLock { _ = failNextIDs.insert(newValue) }
        }
    }

    func write(_ track: Track) -> Bool {
        lock.withLock {
            counts[track.id, default: 0] += 1
            if failNextIDs.remove(track.id) != nil { return false }
            return true
        }
    }

    func count(_ id: UUID) -> Int { lock.withLock { counts[id, default: 0] } }
}

private final class TestFileEventSource: LibraryFileEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([LibraryFileEvent]) -> Void)?
    private(set) var stopCount = 0
    private(set) var startCount = 0
    var onStart: (() -> Void)?

    func start(paths _: [String], handler: @escaping @Sendable ([LibraryFileEvent]) -> Void) throws {
        lock.withLock {
            startCount += 1
            self.handler = handler
            onStart?()
        }
    }
    func stop() { lock.withLock { stopCount += 1; handler = nil } }
    func send(_ events: [LibraryFileEvent]) { lock.withLock { handler }?(events) }
}

private actor MonitorRecorder {
    var batches: [(Set<UUID>, Bool)] = []
    var suspended = false
    func record(_ ids: Set<UUID>, _ full: Bool) async {
        batches.append((ids, full))
        while suspended && !Task.isCancelled { await Task.yield() }
    }
    func setSuspended(_ value: Bool) { suspended = value }
    func snapshot() -> [(Set<UUID>, Bool)] { batches }
}

@MainActor
final class ReferencedSourceReconcilerTests: XCTestCase {
    func testNewImportIntentPrecedesImporterAndReplayClosesRejectedImportWindow() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        try Data("audio".utf8).write(to: fixture.sourceRoot.appendingPathComponent("new.mp3"))
        let store = LibraryReconcileIntentStore(paths: fixture.paths)
        var observedPreparedIntent = false
        fixture.importer.rejectNextImport = true
        fixture.importer.beforeImport = {
            let pending = try? await store.pending(libraryID: fixture.context.id)
            observedPreparedIntent = pending?.count == 1 && pending?.first?.state == .prepared
        }

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])

        let tracksBeforeReplay = await fixture.repository.fetchTracks(in: nil)
        let intentsBeforeReplay = try await store.pending(libraryID: fixture.context.id)
        XCTAssertTrue(observedPreparedIntent)
        XCTAssertTrue(tracksBeforeReplay.isEmpty)
        XCTAssertEqual(intentsBeforeReplay.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.sourceScanManifestURL(for: fixture.sourceID).path))

        fixture.importer.beforeImport = nil
        fixture.importer.rejectNextImport = true
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let stillPending = try await store.pending(
            libraryID: fixture.context.id,
            sourceID: fixture.sourceID
        )
        XCTAssertEqual(stillPending.map(\.id), intentsBeforeReplay.map(\.id))

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let tracksAfterReplay = await fixture.repository.fetchTracks(in: nil)
        let intentsAfterReplay = try await store.pending(libraryID: fixture.context.id)
        XCTAssertEqual(tracksAfterReplay.count, 1)
        XCTAssertTrue(intentsAfterReplay.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.sourceScanManifestURL(for: fixture.sourceID).path))
    }

    func testUniqueFallbackIdentityRenamePreservesUUIDMembershipAndAvailability() async throws {
        let fallbackFingerprint: @Sendable (URL) throws -> kmgccc_player.ReferencedFileFingerprint = { url in
            let actual = try ReferencedFileIdentityProvider().fingerprint(for: url)
            return .init(identity: nil, fileSize: actual.fileSize, modifiedAt: actual.modifiedAt)
        }
        let fixture = try await ReconcileFixture(fingerprintProvider: fallbackFingerprint)
        defer { fixture.cleanup() }
        let original = fixture.sourceRoot.appendingPathComponent("fallback.mp3")
        try Data("fallback-audio".utf8).write(to: original)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let originalTracks = await fixture.repository.fetchTracks(in: nil)
        let originalTrack = try XCTUnwrap(originalTracks.first)

        let renamed = fixture.sourceRoot.appendingPathComponent("renamed-fallback.mp3")
        try FileManager.default.moveItem(at: original, to: renamed)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])

        let tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [originalTrack.id])
        XCTAssertEqual(tracks[0].availability, .available)
        XCTAssertEqual(tracks[0].mediaLocator.referencedFile?.sourceMemberships, [
            .init(sourceID: fixture.sourceID, relativePath: "renamed-fallback.mp3")
        ])
        XCTAssertEqual(tracks[0].mediaLocator.referencedFile?.lastKnownPath, renamed.path)
    }

    func testProductionReconcileNewRenameReplacementOfflineRestartAndSourceRemoval() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let song = fixture.sourceRoot.appendingPathComponent("song.mp3")
        try Data("first".utf8).write(to: song)

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        var tracks = await fixture.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.userDescription, "application metadata")
        XCTAssertEqual(track.availability, .available)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.first?.relativePath, "song.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.sourceScanManifestURL(for: fixture.sourceID).path))

        let renamed = fixture.sourceRoot.appendingPathComponent("renamed.mp3")
        try FileManager.default.moveItem(at: song, to: renamed)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [track.id])
        XCTAssertEqual(tracks[0].mediaLocator.referencedFile?.lastKnownPath, renamed.path)

        try FileManager.default.removeItem(at: renamed)
        try Data("replacement-has-a-different-identity".utf8).write(to: renamed)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [track.id])
        XCTAssertEqual(tracks[0].userDescription, "application metadata")

        try FileManager.default.moveItem(at: fixture.sourceRoot, to: fixture.offlineRoot)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let offlineTracks = await fixture.repository.fetchTracks(in: nil)
        let offlineDescriptor = try await fixture.store.load(id: fixture.sourceID)
        XCTAssertEqual(offlineTracks[0].availability, .volumeUnavailable)
        XCTAssertEqual(offlineTracks[0].mediaLocator.referencedFile?.sourceMemberships.count, 1)
        XCTAssertEqual(offlineDescriptor.status, .offline)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let offlineSidecar = try decoder.decode(
            TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: track.id))
        )
        XCTAssertEqual(offlineSidecar.availability, .volumeUnavailable)
        try FileManager.default.moveItem(at: fixture.offlineRoot, to: fixture.sourceRoot)

        try FileManager.default.removeItem(at: fixture.paths.sourceScanManifestURL(for: fixture.sourceID))
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let rebuiltTracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(rebuiltTracks.map(\.id), [track.id])
        XCTAssertEqual(rebuiltTracks[0].availability, .available)
        XCTAssertEqual(rebuiltTracks[0].mediaLocator.referencedFile?.sourceMemberships.count, 1)
        let recoveredSidecar = try decoder.decode(
            TrackSidecar.self,
            from: Data(contentsOf: fixture.paths.trackMetaURL(for: track.id))
        )
        XCTAssertEqual(recoveredSidecar.availability, .available)

        let externalBytes = try Data(contentsOf: renamed)
        try await fixture.reconciler.removeSource(fixture.sourceID)
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.id), [track.id])
        XCTAssertEqual(tracks[0].availability, .missing)
        XCTAssertEqual(tracks[0].mediaLocator.referencedFile?.sourceMemberships, [])
        XCTAssertEqual(try Data(contentsOf: renamed), externalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.sourceDescriptorURL(for: fixture.sourceID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.sourceScanManifestURL(for: fixture.sourceID).path))
    }

    func testOfflineAvailabilityIsSidecarFirstAndRecoveryPreservesMembership() async throws {
        let writer = PartialLocatorWriter()
        let fixture = try await ReconcileFixture(locatorWriter: { track, _, _, _ in writer.write(track) })
        defer { fixture.cleanup() }
        let song = fixture.sourceRoot.appendingPathComponent("offline.mp3")
        try Data("audio".utf8).write(to: song)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let importedTracks = await fixture.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(importedTracks.first)
        writer.failOnceID = track.id
        try FileManager.default.moveItem(at: fixture.sourceRoot, to: fixture.offlineRoot)

        do {
            try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
            XCTFail("Expected offline authority sidecar failure")
        } catch let error as ReferencedSourceReconcileError {
            XCTAssertEqual(error, .authorityCommitFailed([track.id]))
        }
        let descriptorBeforeRetry = try await fixture.store.load(id: fixture.sourceID)
        XCTAssertEqual(track.availability, .available)
        XCTAssertEqual(descriptorBeforeRetry.status, .available)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.count, 1)

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let descriptorOffline = try await fixture.store.load(id: fixture.sourceID)
        XCTAssertEqual(track.availability, .volumeUnavailable)
        XCTAssertEqual(descriptorOffline.status, .offline)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.count, 1)

        try FileManager.default.moveItem(at: fixture.offlineRoot, to: fixture.sourceRoot)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        XCTAssertEqual(track.availability, .available)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.count, 1)
    }

    func testPermissionDeniedAvailabilityAndRecoveryPreserveMembership() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        try Data("audio".utf8).write(to: fixture.sourceRoot.appendingPathComponent("permission.mp3"))
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let tracks = await fixture.repository.fetchTracks(in: nil)
        let track = try XCTUnwrap(tracks.first)
        fixture.scope.remove(sourceID: fixture.sourceID)
        _ = try await fixture.store.updateStatus(
            sourceID: fixture.sourceID,
            status: .permissionDenied
        )

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        XCTAssertEqual(track.availability, .permissionDenied)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.count, 1)

        fixture.scope.add(sourceID: fixture.sourceID, url: fixture.sourceRoot, lease: .none)
        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        XCTAssertEqual(track.availability, .available)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.count, 1)
    }

    func testSourceReconnectCommitsTrackAuthorityBeforeSourceDescriptorAndReplays() async throws {
        let writer = PartialLocatorWriter()
        let fixture = try await ReconcileFixture(locatorWriter: { track, _, _, _ in
            writer.write(track)
        })
        defer { fixture.cleanup() }
        let oldURL = fixture.sourceRoot.appendingPathComponent("old.wav")
        try Data("old-audio".utf8).write(to: oldURL)
        let track = fixture.makeTrack(title: "Keeps Metadata", path: oldURL.path)
        let imported = await fixture.repository.commitImportedTracks([track])
        XCTAssertEqual(imported.persistedTrackIDs, [track.id])

        let newRoot = fixture.root.appendingPathComponent("Reconnected", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let newURL = newRoot.appendingPathComponent("moved.wav")
        try Data("old-audio".utf8).write(to: newURL)
        let fingerprint = try ReferencedFileIdentityProvider().fingerprint(for: newURL)
        var locator = try XCTUnwrap(track.mediaLocator.referencedFile)
        locator.fileBookmarkData = Data(newURL.path.utf8)
        locator.lastKnownPath = newURL.path
        locator.fingerprint = fingerprint
        locator.sourceMemberships = [
            .init(sourceID: fixture.sourceID, relativePath: newURL.lastPathComponent)
        ]
        locator.primarySourceID = fixture.sourceID
        let mutation = ReferencedSourceLocatorMutation(
            trackID: track.id,
            locator: locator,
            availability: .available
        )
        let proposedDescriptor = ReferencedSourceDescriptor(
            id: fixture.sourceID,
            rootBookmarkData: Data(newRoot.path.utf8),
            lastKnownPath: newRoot.path,
            displayName: newRoot.lastPathComponent
        )
        let proposedManifest = ReferencedSourceScanManifest(
            libraryID: fixture.context.id,
            sourceID: fixture.sourceID,
            generation: 1,
            lastSuccessfulScan: Date(),
            entries: [
                .init(
                    relativePath: newURL.lastPathComponent,
                    identity: fingerprint.identity,
                    fingerprint: fingerprint,
                    trackID: track.id,
                    availability: .available,
                    lastSeenGeneration: 1
                )
            ]
        )
        writer.failOnceID = track.id

        do {
            try await fixture.reconciler.reconnectSource(
                descriptor: proposedDescriptor,
                rootURL: newRoot,
                lease: .none,
                mutations: [mutation],
                proposedManifest: proposedManifest
            )
            XCTFail("Expected authority commit failure")
        } catch {
            XCTAssertEqual(
                error as? ReferencedSourceReconcileError,
                .authorityCommitFailed([track.id])
            )
        }
        let descriptorBeforeReplay = try await fixture.store.load(id: fixture.sourceID)
        XCTAssertEqual(descriptorBeforeReplay.lastKnownPath, fixture.sourceRoot.path)
        XCTAssertEqual(track.mediaLocator.referencedFile?.lastKnownPath, oldURL.path)
        let intentStore = LibraryReconcileIntentStore(paths: fixture.paths)
        let pending = try await intentStore.pending(
            libraryID: fixture.context.id,
            sourceID: fixture.sourceID
        )
        XCTAssertEqual(pending.first?.operation, .sourceReconnect)
        XCTAssertEqual(
            pending.first?.proposedSourceDescriptor?.lastKnownPath,
            proposedDescriptor.lastKnownPath
        )
        XCTAssertEqual(
            pending.first?.proposedSourceDescriptor?.rootBookmarkData,
            proposedDescriptor.rootBookmarkData
        )

        try await fixture.reconciler.replayPending(sourceID: fixture.sourceID)

        let descriptorAfterReplay = try await fixture.store.load(id: fixture.sourceID)
        XCTAssertEqual(descriptorAfterReplay.id, proposedDescriptor.id)
        XCTAssertEqual(descriptorAfterReplay.lastKnownPath, proposedDescriptor.lastKnownPath)
        XCTAssertEqual(descriptorAfterReplay.rootBookmarkData, proposedDescriptor.rootBookmarkData)
        XCTAssertEqual(track.id, mutation.trackID)
        XCTAssertEqual(track.title, "Keeps Metadata")
        XCTAssertEqual(track.mediaLocator.referencedFile?.lastKnownPath, newURL.path)
        let pendingAfterReplay = try await intentStore.pending(
            libraryID: fixture.context.id,
            sourceID: fixture.sourceID
        )
        XCTAssertTrue(pendingAfterReplay.isEmpty)
    }

    func testStandaloneTrackRelocationRequiresConfirmationAndPreservesAppMetadata() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let oldURL = fixture.root.appendingPathComponent("missing.wav")
        let oldLocator = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data(oldURL.path.utf8),
            lastKnownPath: oldURL.path,
            fingerprint: .init(fileSize: 10, modifiedAt: 1)
        )
        let track = Track(
            title: "Edited Title",
            artist: "Edited Artist",
            userDescription: "Keeps App Metadata",
            fileBookmarkData: oldLocator.fileBookmarkData,
            originalFilePath: oldURL.path,
            mediaLocator: .referenced(oldLocator),
            availability: .missing,
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        let imported = await fixture.repository.commitImportedTracks([track])
        XCTAssertEqual(imported.persistedTrackIDs, [track.id])
        let selectedURL = fixture.root.appendingPathComponent("replacement.wav")
        try Data("replacement-audio".utf8).write(to: selectedURL)
        let service = SourceReconnectService(
            context: fixture.context,
            repository: fixture.repository,
            sourceStore: fixture.store,
            sourceScope: fixture.scope,
            reconciler: fixture.reconciler,
            bookmarkResolver: ReconcileBookmarkResolver()
        )

        let proposal = try await service.prepareTrackRelocation(
            trackID: track.id,
            selectedURL: selectedURL
        )
        XCTAssertTrue(proposal.requiresReplacementConfirmation)
        do {
            try await service.relocateTrack(proposal, confirmedReplacement: false)
            XCTFail("Expected replacement confirmation")
        } catch {
            XCTAssertEqual(
                error as? SourceReconnectServiceError,
                .replacementConfirmationRequired
            )
        }
        XCTAssertEqual(track.mediaLocator.referencedFile?.lastKnownPath, oldURL.path)

        try await service.relocateTrack(proposal, confirmedReplacement: true)

        XCTAssertEqual(track.id, proposal.trackID)
        XCTAssertEqual(track.title, "Edited Title")
        XCTAssertEqual(track.artist, "Edited Artist")
        XCTAssertEqual(track.userDescription, "Keeps App Metadata")
        XCTAssertEqual(track.availability, .available)
        XCTAssertEqual(track.mediaLocator.referencedFile?.lastKnownPath, selectedURL.path)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships, [])
        let sidecar = try decodeTrackSidecar(paths: fixture.paths, trackID: track.id)
        XCTAssertEqual(sidecar.id, track.id)
        XCTAssertEqual(sidecar.mediaLocator.referencedFile?.lastKnownPath, selectedURL.path)
        do {
            _ = try await service.prepareTrackRelocation(
                trackID: track.id,
                selectedURL: selectedURL
            )
            XCTFail("Expected an available track to reject standalone relocation")
        } catch {
            XCTAssertEqual(
                error as? SourceReconnectServiceError,
                .trackIsNotStandaloneMissing(track.id)
            )
        }
    }

    func testSourceReconnectRetainsMatchedTrackAndFullReconcileImportsNewFiles() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let candidateRoot = fixture.root.appendingPathComponent("Reconnected", isDirectory: true)
        let albumRoot = candidateRoot.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumRoot, withIntermediateDirectories: true)
        let matchedURL = albumRoot.appendingPathComponent("existing.mp3")
        let newURL = candidateRoot.appendingPathComponent("fresh.mp3")
        try Data("existing-audio".utf8).write(to: matchedURL)
        try Data("fresh-audio".utf8).write(to: newURL)
        let fingerprint = try ReferencedFileIdentityProvider().fingerprint(for: matchedURL)
        let oldURL = fixture.sourceRoot.appendingPathComponent("Album/existing.mp3")
        let locator = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data(oldURL.path.utf8),
            sourceMemberships: [.init(
                sourceID: fixture.sourceID,
                relativePath: "Album/existing.mp3"
            )],
            primarySourceID: fixture.sourceID,
            lastKnownPath: oldURL.path,
            fingerprint: fingerprint
        )
        let existingTrack = Track(
            title: "Existing",
            fileBookmarkData: locator.fileBookmarkData,
            originalFilePath: oldURL.path,
            mediaLocator: .referenced(locator),
            availability: .missing,
            libraryRootSnapshot: fixture.paths.rootURL.path
        )
        let imported = await fixture.repository.commitImportedTracks([existingTrack])
        XCTAssertEqual(imported.persistedTrackIDs, [existingTrack.id])
        let service = SourceReconnectService(
            context: fixture.context,
            repository: fixture.repository,
            sourceStore: fixture.store,
            sourceScope: fixture.scope,
            reconciler: fixture.reconciler,
            bookmarkResolver: ReconcileBookmarkResolver()
        )

        let preparation = try await service.prepareSourceReconnect(
            sourceID: fixture.sourceID,
            candidateRoots: [candidateRoot]
        )
        let plan = try XCTUnwrap(preparation.plans.first)
        XCTAssertEqual(plan.matches.map(\.trackID), [existingTrack.id])

        try await service.reconnectSource(
            preparation: preparation,
            planID: plan.id,
            conflictSelections: [:]
        )

        let tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(Set(tracks.map(\.id)).contains(existingTrack.id), true)
        XCTAssertEqual(tracks.first(where: { $0.id == existingTrack.id })?.availability, .available)
        XCTAssertEqual(tracks.first(where: { $0.id == existingTrack.id })?
            .mediaLocator.referencedFile?.lastKnownPath, matchedURL.path)
        XCTAssertEqual(tracks.first(where: { $0.title == "fresh" })?
            .mediaLocator.referencedFile?.primarySourceID, fixture.sourceID)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(
            fixture.scope.authorizedRoots[fixture.sourceID]?.url.standardizedFileURL,
            candidateRoot.standardizedFileURL
        )
    }

    func testOverlappingSourcesMergeAndRemovingOnePreservesTrack() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let inner = fixture.sourceRoot.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let song = inner.appendingPathComponent("song.flac")
        try Data("audio".utf8).write(to: song)
        let innerID = UUID()
        let innerDescriptor = ReferencedSourceDescriptor(
            id: innerID,
            rootBookmarkData: Data(inner.path.utf8),
            lastKnownPath: inner.path,
            displayName: "Inner"
        )
        try await fixture.store.save(innerDescriptor)
        fixture.scope.add(sourceID: innerID, url: inner, lease: .none)

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID, innerID])
        var tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(Set(tracks[0].mediaLocator.referencedFile?.sourceMemberships.map(\.sourceID) ?? []), Set([fixture.sourceID, innerID]))
        XCTAssertEqual(tracks[0].mediaLocator.referencedFile?.primarySourceID, innerID)

        try await fixture.reconciler.removeSource(innerID)
        tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].availability, .available)
        XCTAssertEqual(tracks[0].mediaLocator.referencedFile?.sourceMemberships.map(\.sourceID), [fixture.sourceID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.path))
    }

    func testNCMReservationSkipsSourceAndOutputAndRegistryFailureIsConservative() async throws {
        let fixture = try await ReconcileFixture(scannerFactory: { paths in
            let filter = NCMScanReservationFilter(registry: NCMConversionRegistry(paths: paths))
            return ReferencedSourceScanner(paths: paths, isReserved: { url, identity in
                await filter.isReserved(url: url, identity: identity)
            })
        })
        defer { fixture.cleanup() }
        let source = fixture.sourceRoot.appendingPathComponent("song.ncm")
        let output = fixture.sourceRoot.appendingPathComponent("song.mp3")
        let ordinary = fixture.sourceRoot.appendingPathComponent("ordinary.flac")
        try Data("ncm".utf8).write(to: source)
        try Data("output".utf8).write(to: output)
        try Data("ordinary".utf8).write(to: ordinary)
        let sourceFingerprint = try ReferencedFileIdentityProvider().fingerprint(for: source)
        let registry = NCMConversionRegistry(paths: fixture.paths)
        try await registry.reserve(NCMConversionRecord(
            id: UUID(),
            sourceIdentity: sourceFingerprint.identity,
            sourceFingerprint: sourceFingerprint,
            sourceBookmarkData: Data(source.path.utf8),
            parentDirectoryBookmarkData: nil,
            sourcePath: source.path,
            sourceMemberships: [],
            sourcePrimaryID: nil,
            expectedOutputPath: output.path,
            outputIdentity: nil,
            outputFingerprint: nil,
            outputLocator: nil,
            outputFormat: nil,
            outputMetadata: nil,
            outputCoverData: nil,
            trackID: nil,
            state: .pending,
            errorSummary: nil,
            createdAt: Date(),
            updatedAt: Date()
        ))

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let tracks = await fixture.repository.fetchTracks(in: nil)
        XCTAssertEqual(tracks.map(\.title), ["ordinary"])

        let failureFixture = try await ReconcileFixture(scannerFactory: { paths in
            let filter = NCMScanReservationFilter(registry: NCMConversionRegistry(paths: paths))
            return ReferencedSourceScanner(paths: paths, isReserved: { url, identity in
                await filter.isReserved(url: url, identity: identity)
            })
        })
        defer { failureFixture.cleanup() }
        try Data("broken".utf8).write(to: failureFixture.paths.ncmConversionsURL)
        try Data("audio".utf8).write(to: failureFixture.sourceRoot.appendingPathComponent("should-skip.mp3"))
        try await failureFixture.reconciler.reconcile(sourceIDs: [failureFixture.sourceID])
        let failureTracks = await failureFixture.repository.fetchTracks(in: nil)
        XCTAssertTrue(failureTracks.isEmpty)
    }

    func testDebounceCoalescesAndStopAwaitsInFlightScanWithoutLateWrite() async throws {
        let eventSource = TestFileEventSource()
        let monitor = LibraryChangeMonitor(eventSource: eventSource, debounceNanoseconds: 20_000_000)
        let recorder = MonitorRecorder()
        let first = UUID(), second = UUID()
        let firstURL = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let secondURL = URL(fileURLWithPath: "/tmp/second", isDirectory: true)
        try await monitor.start(sourceRoots: [first: firstURL, second: secondURL]) { ids, full in
            await recorder.record(ids, full)
        }
        eventSource.send([.init(path: firstURL.appendingPathComponent("a").path, requiresFullScan: false)])
        eventSource.send([.init(path: secondURL.appendingPathComponent("b").path, requiresFullScan: true)])
        try await Task.sleep(nanoseconds: 80_000_000)
        let initialBatches = await recorder.snapshot()
        XCTAssertEqual(initialBatches.count, 1)
        XCTAssertEqual(initialBatches[0].0, Set([first, second]))
        XCTAssertTrue(initialBatches[0].1)

        await recorder.setSuspended(true)
        await monitor.markDirty(sourceIDs: [first])
        try await Task.sleep(nanoseconds: 40_000_000)
        let stop = Task { await monitor.stopAndWait() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(stop.isCancelled)
        await recorder.setSuspended(false)
        await stop.value
        let countAtClose = await recorder.snapshot().count
        eventSource.send([.init(path: firstURL.path, requiresFullScan: false)])
        try await Task.sleep(nanoseconds: 40_000_000)
        let batchesAfterClose = await recorder.snapshot()
        XCTAssertEqual(batchesAfterClose.count, countAtClose)
    }

    func testPartialAuthorityFailureStaysPreparedAndRetriesOnlyFailedTrack() async throws {
        let writer = PartialLocatorWriter()
        let fixture = try await ReconcileFixture(locatorWriter: { track, _, _, _ in writer.write(track) })
        defer { fixture.cleanup() }
        let first = fixture.makeTrack(title: "First", path: "/first-old")
        let second = fixture.makeTrack(title: "Second", path: "/second-old")
        _ = await fixture.repository.commitImportedTracks([first, second])
        writer.failOnceID = second.id
        let mutations = [first, second].map { track -> ReferencedSourceLocatorMutation in
            var locator = track.mediaLocator.referencedFile!
            locator.lastKnownPath += "-new"
            return .init(trackID: track.id, locator: locator, availability: .available)
        }
        let diff = ReferencedSourceDiff(
            libraryID: fixture.context.id,
            libraryGeneration: fixture.context.generation,
            sourceID: fixture.sourceID,
            scanGeneration: 9,
            sourceStatus: .available
        )
        let store = LibraryReconcileIntentStore(paths: fixture.paths)
        _ = try await store.prepare(diff, mutations: mutations)

        do {
            try await fixture.reconciler.replayPending()
            XCTFail("Expected item-scoped authority failure")
        } catch let error as ReferencedSourceReconcileError {
            XCTAssertEqual(error, .authorityCommitFailed([second.id]))
        }

        let pendingAfterFailure = try await store.pending(libraryID: fixture.context.id)
        let afterFailure = try XCTUnwrap(pendingAfterFailure.first)
        XCTAssertEqual(afterFailure.state, .prepared)
        XCTAssertEqual(afterFailure.committedTrackIDs, [first.id])
        XCTAssertEqual(first.mediaLocator.referencedFile?.lastKnownPath, "/first-old")
        XCTAssertEqual(second.mediaLocator.referencedFile?.lastKnownPath, "/second-old")
        XCTAssertEqual(writer.count(first.id), 1)
        XCTAssertEqual(writer.count(second.id), 1)

        try await fixture.reconciler.replayPending()

        let pendingAfterRetry = try await store.pending(libraryID: fixture.context.id)
        XCTAssertTrue(pendingAfterRetry.isEmpty)
        XCTAssertEqual(first.mediaLocator.referencedFile?.lastKnownPath, "/first-old-new")
        XCTAssertEqual(second.mediaLocator.referencedFile?.lastKnownPath, "/second-old-new")
        XCTAssertEqual(writer.count(first.id), 1)
        XCTAssertEqual(writer.count(second.id), 2)
    }

    func testIntentReplayIsIdempotentAtAllThreeCommitBoundaries() async throws {
        for boundary in [
            LibraryReconcileIntentState.prepared,
            .sidecarsCommitted,
            .runtimeApplied,
        ] {
            let fixture = try await ReconcileFixture()
            defer { fixture.cleanup() }
            let oldLocator = kmgccc_player.ReferencedFileLocator(
                fileBookmarkData: Data("old".utf8),
                sourceMemberships: [.init(sourceID: fixture.sourceID, relativePath: "old.mp3")],
                primarySourceID: fixture.sourceID,
                lastKnownPath: "/old.mp3",
                fingerprint: .init(fileSize: 1, modifiedAt: 1)
            )
            let track = Track(
                title: "Replay",
                fileBookmarkData: oldLocator.fileBookmarkData,
                mediaLocator: .referenced(oldLocator),
                libraryRootSnapshot: fixture.paths.rootURL.path
            )
            _ = await fixture.repository.commitImportedTracks([track])
            var newLocator = oldLocator
            newLocator.lastKnownPath = "/new.mp3"
            newLocator.sourceMemberships[0].relativePath = "new.mp3"
            let mutation = ReferencedSourceLocatorMutation(
                trackID: track.id,
                locator: newLocator,
                availability: .available
            )
            let diff = ReferencedSourceDiff(
                libraryID: fixture.context.id,
                libraryGeneration: fixture.context.generation,
                sourceID: fixture.sourceID,
                scanGeneration: 7,
                sourceStatus: .available
            )
            let store = LibraryReconcileIntentStore(paths: fixture.paths)
            var intent = try await store.prepare(diff, mutations: [mutation])
            if boundary == .sidecarsCommitted || boundary == .runtimeApplied {
                _ = await fixture.repository.commitReferencedSourceMutations([mutation])
                intent = try await store.advance(intent, to: .sidecarsCommitted)
            }
            if boundary == .runtimeApplied {
                await fixture.repository.attachReferencedSourceMutations([mutation])
                intent = try await store.advance(intent, to: .runtimeApplied)
            }

            try await fixture.reconciler.replayPending()

            let replayedTracks = await fixture.repository.fetchTracks(ids: [track.id])
            let pendingAfterReplay = try await store.pending(libraryID: fixture.context.id)
            let replayed = try XCTUnwrap(replayedTracks.first)
            XCTAssertEqual(replayed.mediaLocator.referencedFile?.lastKnownPath, "/new.mp3", "boundary=\(boundary)")
            XCTAssertTrue(pendingAfterReplay.isEmpty)
        }
    }

    func testReferencedSessionStartupOfflinePersistsAvailabilityAndExplicitRefreshRecovers() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = container.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = container.appendingPathComponent("Source", isDirectory: true)
        let parkedRoot = container.appendingPathComponent("Parked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let fileURL = sourceRoot.appendingPathComponent("offline.mp3")
        try Data("offline-audio".utf8).write(to: fileURL)
        let context = try makeLibraryContext(root: libraryRoot, mode: .referenced)
        let sourceID = UUID()
        let fingerprint = try ReferencedFileIdentityProvider().fingerprint(for: fileURL)
        let trackID = try await seedReferencedTrack(
            context: context,
            sourceID: sourceID,
            fileURL: fileURL,
            fingerprint: fingerprint
        )
        let store = ReferencedSourceStore(paths: context.paths)
        try await store.save(ReferencedSourceDescriptor(
            id: sourceID,
            rootBookmarkData: Data(sourceRoot.path.utf8),
            lastKnownPath: sourceRoot.path,
            displayName: "Offline"
        ))
        try FileManager.default.moveItem(at: sourceRoot, to: parkedRoot)
        let resolver = StartupBookmarkResolver(url: sourceRoot, mode: .offline)
        let session = try await LibrarySessionFactory(
            libraryRootBookmarkResolver: ReconcileBookmarkResolver(),
            sourceBookmarkResolver: resolver,
            requiresSecurityScope: true,
            fileEventSourceFactory: { TestFileEventSource() }
        ).makeSession(for: context)
        let concrete = try XCTUnwrap(session as? LibrarySession)

        try await concrete.load()

        let offlineTracks = await concrete.repository.fetchTracks(ids: [trackID])
        let offlineTrack = try XCTUnwrap(offlineTracks.first)
        let offlineSidecar = try decodeTrackSidecar(paths: context.paths, trackID: trackID)
        XCTAssertEqual(offlineTrack.availability, .volumeUnavailable)
        XCTAssertEqual(offlineSidecar.availability, .volumeUnavailable)
        XCTAssertEqual(offlineTrack.mediaLocator.referencedFile?.sourceMemberships.count, 1)
        XCTAssertTrue(concrete.libraryChangeMonitor != nil)

        try FileManager.default.moveItem(at: parkedRoot, to: sourceRoot)
        resolver.setMode(.available)
        _ = try await concrete.refreshReferencedSources()

        let recoveredSidecar = try decodeTrackSidecar(paths: context.paths, trackID: trackID)
        XCTAssertEqual(offlineTrack.availability, .available)
        XCTAssertEqual(recoveredSidecar.availability, .available)
        XCTAssertEqual(offlineTrack.mediaLocator.referencedFile?.sourceMemberships.count, 1)
        await concrete.close()
    }

    func testReferencedSessionStartupPermissionDeniedPersistsAvailabilityAndStillLoads() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = container.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = container.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let fileURL = sourceRoot.appendingPathComponent("permission.mp3")
        try Data("permission-audio".utf8).write(to: fileURL)
        let context = try makeLibraryContext(root: libraryRoot, mode: .referenced)
        let sourceID = UUID()
        let trackID = try await seedReferencedTrack(
            context: context,
            sourceID: sourceID,
            fileURL: fileURL,
            fingerprint: try ReferencedFileIdentityProvider().fingerprint(for: fileURL)
        )
        let store = ReferencedSourceStore(paths: context.paths)
        try await store.save(ReferencedSourceDescriptor(
            id: sourceID,
            rootBookmarkData: Data(sourceRoot.path.utf8),
            lastKnownPath: sourceRoot.path,
            displayName: "Permission"
        ))
        let resolver = StartupBookmarkResolver(url: sourceRoot, mode: .permissionDenied)
        let session = try await LibrarySessionFactory(
            libraryRootBookmarkResolver: ReconcileBookmarkResolver(),
            sourceBookmarkResolver: resolver,
            requiresSecurityScope: true,
            fileEventSourceFactory: { TestFileEventSource() }
        ).makeSession(for: context)
        let concrete = try XCTUnwrap(session as? LibrarySession)

        try await concrete.load()

        let permissionTracks = await concrete.repository.fetchTracks(ids: [trackID])
        let track = try XCTUnwrap(permissionTracks.first)
        let sidecar = try decodeTrackSidecar(paths: context.paths, trackID: trackID)
        XCTAssertEqual(track.availability, .permissionDenied)
        XCTAssertEqual(sidecar.availability, .permissionDenied)
        XCTAssertEqual(track.mediaLocator.referencedFile?.sourceMemberships.count, 1)
        await concrete.close()
    }

    func testCorruptDescriptorAuthorityPropagatesFromReconcile() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let descriptorURL = fixture.paths.sourceDescriptorURL(for: fixture.sourceID)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL)) as? [String: Any]
        )
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: descriptorURL, options: .atomic)

        do {
            try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
            XCTFail("Expected descriptor schema failure")
        } catch let error as ReferencedSourceStoreError {
            XCTAssertEqual(error, .unsupportedSchema(99))
        }
    }

    func testReferencedSessionReplaysBeforeMonitorStartAndCloseStopsLateEvents() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = container.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = container.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let context = try makeLibraryContext(root: libraryRoot, mode: .referenced)
        let sourceID = UUID()
        let sourceStore = ReferencedSourceStore(paths: context.paths)
        try await sourceStore.save(ReferencedSourceDescriptor(
            id: sourceID,
            rootBookmarkData: Data(sourceRoot.path.utf8),
            lastKnownPath: sourceRoot.path,
            displayName: "Source"
        ))
        let manifest = ReferencedSourceScanManifest(
            libraryID: context.id,
            sourceID: sourceID,
            generation: 1,
            lastSuccessfulScan: Date(),
            entries: []
        )
        let diff = ReferencedSourceDiff(
            libraryID: context.id,
            libraryGeneration: context.generation,
            sourceID: sourceID,
            scanGeneration: 1,
            sourceStatus: .available
        )
        let intentStore = LibraryReconcileIntentStore(paths: context.paths)
        let prepared = try await intentStore.prepare(diff, proposedManifest: manifest)
        let sidecars = try await intentStore.advance(prepared, to: .sidecarsCommitted)
        _ = try await intentStore.advance(sidecars, to: .runtimeApplied)
        let eventSource = TestFileEventSource()
        var replayWasFinalizedBeforeStart = false
        eventSource.onStart = {
            replayWasFinalizedBeforeStart = FileManager.default.fileExists(
                atPath: context.paths.sourceScanManifestURL(for: sourceID).path
            )
        }
        let session = try await LibrarySessionFactory(
            sourceBookmarkResolver: ReconcileBookmarkResolver(),
            fileEventSourceFactory: { eventSource }
        ).makeSession(for: context)
        let concrete = try XCTUnwrap(session as? LibrarySession)

        try await concrete.load()

        XCTAssertTrue(replayWasFinalizedBeforeStart)
        XCTAssertEqual(eventSource.startCount, 1)
        let generationBeforeClose = try await ReferencedSourceScanManifestStore(paths: context.paths)
            .load(sourceID: sourceID, libraryID: context.id)?.generation
        await concrete.quiesce()
        await concrete.close()
        eventSource.send([.init(path: sourceRoot.path, requiresFullScan: true)])
        try await Task.sleep(nanoseconds: 50_000_000)
        let generationAfterClose = try await ReferencedSourceScanManifestStore(paths: context.paths)
            .load(sourceID: sourceID, libraryID: context.id)?.generation
        XCTAssertGreaterThanOrEqual(eventSource.stopCount, 1)
        XCTAssertEqual(generationAfterClose, generationBeforeClose)
    }

    func testIntentStoreRejectsCorruptUnknownSchemaDuplicateSourceAndInvalidTransition() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let intentStore = LibraryReconcileIntentStore(paths: fixture.paths)
        let reconcileDirectory = fixture.paths.sourceScanCacheRootURL
            .appendingPathComponent("Reconcile", isDirectory: true)
        try FileManager.default.createDirectory(at: reconcileDirectory, withIntermediateDirectories: true)
        let corruptURL = reconcileDirectory.appendingPathComponent("corrupt.json")
        try Data("{".utf8).write(to: corruptURL)
        do {
            _ = try await intentStore.pending(libraryID: fixture.context.id)
            XCTFail("Expected corrupt intent failure")
        } catch let error as LibraryReconcileIntentStoreError {
            guard case let .corruptIntent(path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "corrupt.json")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
        try FileManager.default.removeItem(at: corruptURL)

        let diff = ReferencedSourceDiff(
            libraryID: fixture.context.id,
            libraryGeneration: fixture.context.generation,
            sourceID: fixture.sourceID,
            scanGeneration: 1,
            sourceStatus: .available
        )
        let prepared = try await intentStore.prepare(diff)
        do {
            _ = try await intentStore.prepare(diff)
            XCTFail("Expected one active intent per source")
        } catch let error as LibraryReconcileIntentStoreError {
            XCTAssertEqual(error, .activeIntentExists(sourceID: fixture.sourceID, intentID: prepared.id))
        }
        do {
            _ = try await intentStore.advance(prepared, to: .runtimeApplied)
            XCTFail("Expected strict transition failure")
        } catch let error as LibraryReconcileIntentStoreError {
            XCTAssertEqual(error, .invalidTransition(from: .prepared, to: .runtimeApplied))
        }

        let intentURL = reconcileDirectory.appendingPathComponent("\(prepared.id.uuidString).json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as? [String: Any]
        )
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: intentURL, options: .atomic)
        do {
            _ = try await intentStore.pending(libraryID: fixture.context.id)
            XCTFail("Expected unknown schema failure")
        } catch let error as LibraryReconcileIntentStoreError {
            XCTAssertEqual(error, .unsupportedSchema(99))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: intentURL.path))
    }

    func testManifestInvalidValuesAreQuarantinedAndTriggerRebuild() async throws {
        let fixture = try await ReconcileFixture()
        defer { fixture.cleanup() }
        let store = ReferencedSourceScanManifestStore(paths: fixture.paths)
        let manifestURL = fixture.paths.sourceScanManifestURL(for: fixture.sourceID)
        let valid = ReferencedSourceScanManifest(
            libraryID: fixture.context.id,
            sourceID: fixture.sourceID,
            generation: 1,
            lastSuccessfulScan: Date(),
            entries: []
        )
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schemaVersion"] = 99 }),
            ("library", { $0["libraryID"] = UUID().uuidString }),
            ("source", { $0["sourceID"] = UUID().uuidString }),
        ]
        for (reason, mutate) in cases {
            try await store.save(valid)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
            )
            mutate(&object)
            try JSONSerialization.data(withJSONObject: object).write(to: manifestURL, options: .atomic)
            let loaded = try await store.load(sourceID: fixture.sourceID, libraryID: fixture.context.id)
            XCTAssertNil(loaded, "reason=\(reason)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        }
        try Data("{".utf8).write(to: manifestURL, options: .atomic)
        let corruptLoad = try await store.load(
            sourceID: fixture.sourceID,
            libraryID: fixture.context.id
        )
        let quarantined = try await store.quarantinedURLs()
        XCTAssertNil(corruptLoad)
        XCTAssertEqual(quarantined.count, 4)

        try await fixture.reconciler.reconcile(sourceIDs: [fixture.sourceID])
        let rebuilt = try await store.load(
            sourceID: fixture.sourceID,
            libraryID: fixture.context.id
        )
        XCTAssertNotNil(rebuilt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testRealFileImportServiceAutomaticUsesReferencedPipelineWithoutUI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryRoot = root.appendingPathComponent("Library", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: libraryRoot)
        try paths.createRequiredDirectories()
        let wavURL = sourceRoot.appendingPathComponent("Production Automatic.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let audioFile = try AVAudioFile(forWriting: wavURL, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try audioFile.write(from: buffer)

        let libraryService = LocalLibraryService(
            paths: paths,
            preferenceStatsService: PreferenceStatsService()
        )
        let repository = SwiftDataLibraryRepository(libraryService: libraryService)
        let sourceStore = ReferencedSourceStore(paths: paths)
        let sourceScope = ReferencedSourceScope()
        let backend = ReferencedLocalBackend(
            paths: paths,
            sourceStore: sourceStore,
            sourceScope: sourceScope,
            bookmarkResolver: ReconcileBookmarkResolver()
        )
        let cache = LibraryCacheServices(paths: paths)
        let enrichment = ImportEnrichmentService(
            repository: repository,
            qqMusicCoverService: cache.qqMusicCoverService,
            artistArtworkProviderCoordinator: cache.artistArtworkProviderCoordinator,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService
        )
        var uiWasPresented = false
        let service = FileImportService(
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: enrichment,
            storageBackend: backend,
            qqMusicCoverService: cache.qqMusicCoverService,
            lyricsSearchCoordinator: cache.lyricsSearchCoordinator,
            amllDBService: cache.amllDBService,
            uiPresentationObserver: { uiWasPresented = true }
        )
        let previousDeferred = AppSettings.shared.deferImportEnrichment
        AppSettings.shared.deferImportEnrichment = true
        defer { AppSettings.shared.deferImportEnrichment = previousDeferred }

        let imported = await service.importAutomatically([sourceRoot])

        XCTAssertFalse(uiWasPresented)
        XCTAssertEqual(imported.count, 1)
        let track = try XCTUnwrap(imported.first)
        XCTAssertEqual(track.title, "Production Automatic.wav")
        XCTAssertEqual(track.availability, .available)
        XCTAssertEqual(track.mediaLocator.referencedFile?.lastKnownPath, wavURL.path)
        let membership = try XCTUnwrap(track.mediaLocator.referencedFile?.sourceMemberships.first)
        XCTAssertEqual(membership.relativePath, wavURL.lastPathComponent)
        XCTAssertEqual(track.mediaLocator.referencedFile?.primarySourceID, membership.sourceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.trackMetaURL(for: track.id).path))
        XCTAssertEqual(try Data(contentsOf: wavURL).isEmpty, false)
        let sourceIDs = try await sourceStore.loadAll().map(\.id)
        XCTAssertEqual(sourceIDs, [membership.sourceID])
        await enrichment.cancelEnrichment(for: [track.id])
        await backend.close()
        await cache.close()
    }

    func testManagedFactoryDoesNotCreateSourceMonitor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeLibraryContext(root: root, mode: .managed)
        let session = try await LibrarySessionFactory(
            sourceBookmarkResolver: ReconcileBookmarkResolver()
        ).makeSession(for: context)
        let concrete = try XCTUnwrap(session as? LibrarySession)
        XCTAssertNil(concrete.referencedSourceReconciler)
        XCTAssertNil(concrete.libraryChangeMonitor)
        await concrete.close()
    }
}

@MainActor
private final class ReconcileFixture {
    let root: URL
    let sourceRoot: URL
    let offlineRoot: URL
    let paths: kmgccc_player.LibraryPaths
    let context: kmgccc_player.LibraryContext
    let sourceID: UUID
    let store: ReferencedSourceStore
    let scope: ReferencedSourceScope
    let repository: SwiftDataLibraryRepository
    let importer: ReconcileImporter
    let reconciler: ReferencedSourceReconciler

    init(
        scannerFactory: ((kmgccc_player.LibraryPaths) -> ReferencedSourceScanner)? = nil,
        fingerprintProvider: @escaping @Sendable (URL) throws -> kmgccc_player.ReferencedFileFingerprint = {
            try ReferencedFileIdentityProvider().fingerprint(for: $0)
        },
        locatorWriter: ((Track, kmgccc_player.TrackMediaLocator, kmgccc_player.TrackAvailability, String) -> Bool)? = nil
    ) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceRoot = root.appendingPathComponent("External", isDirectory: true)
        offlineRoot = root.appendingPathComponent("External-offline", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        context = try makeLibraryContext(root: root.appendingPathComponent("Library", isDirectory: true), mode: .referenced)
        paths = context.paths
        try paths.createRequiredDirectories()
        sourceID = UUID()
        store = ReferencedSourceStore(paths: paths)
        scope = ReferencedSourceScope()
        repository = SwiftDataLibraryRepository(
            libraryService: LocalLibraryService(paths: paths, preferenceStatsService: PreferenceStatsService()),
            locatorSidecarWriter: locatorWriter
        )
        let descriptor = ReferencedSourceDescriptor(
            id: sourceID,
            rootBookmarkData: Data(sourceRoot.path.utf8),
            lastKnownPath: sourceRoot.path,
            displayName: "External"
        )
        try await store.save(descriptor)
        scope.add(sourceID: sourceID, url: sourceRoot, lease: .none)
        importer = ReconcileImporter(
            repository: repository,
            fingerprintProvider: fingerprintProvider
        )
        let scanner = scannerFactory?(paths) ?? ReferencedSourceScanner(
            paths: paths,
            fingerprintProvider: fingerprintProvider
        )
        reconciler = ReferencedSourceReconciler(
            context: context,
            repository: repository,
            importer: importer,
            sourceStore: store,
            sourceScope: scope,
            scanner: scanner,
            bookmarkResolver: ReconcileBookmarkResolver()
        )
    }

    func makeTrack(title: String, path: String) -> Track {
        let locator = kmgccc_player.ReferencedFileLocator(
            fileBookmarkData: Data(path.utf8),
            sourceMemberships: [.init(sourceID: sourceID, relativePath: URL(fileURLWithPath: path).lastPathComponent)],
            primarySourceID: sourceID,
            lastKnownPath: path,
            fingerprint: .init(fileSize: Int64(path.utf8.count), modifiedAt: 1)
        )
        return Track(
            title: title,
            fileBookmarkData: locator.fileBookmarkData,
            mediaLocator: .referenced(locator),
            libraryRootSnapshot: paths.rootURL.path
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private func seedReferencedTrack(
    context: kmgccc_player.LibraryContext,
    sourceID: UUID,
    fileURL: URL,
    fingerprint: kmgccc_player.ReferencedFileFingerprint
) async throws -> UUID {
    let locator = kmgccc_player.ReferencedFileLocator(
        fileBookmarkData: Data(fileURL.path.utf8),
        sourceMemberships: [.init(sourceID: sourceID, relativePath: fileURL.lastPathComponent)],
        primarySourceID: sourceID,
        lastKnownPath: fileURL.path,
        fingerprint: fingerprint
    )
    let track = Track(
        title: fileURL.deletingPathExtension().lastPathComponent,
        fileBookmarkData: locator.fileBookmarkData,
        originalFilePath: fileURL.path,
        mediaLocator: .referenced(locator),
        libraryRootSnapshot: context.paths.rootURL.path
    )
    let service = LocalLibraryService(
        paths: context.paths,
        preferenceStatsService: PreferenceStatsService()
    )
    let repository = SwiftDataLibraryRepository(libraryService: service)
    let result = await repository.commitImportedTracks([track])
    XCTAssertEqual(result.persistedTrackIDs, [track.id])
    return track.id
}

private func decodeTrackSidecar(
    paths: kmgccc_player.LibraryPaths,
    trackID: UUID
) throws -> kmgccc_player.TrackSidecar {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        kmgccc_player.TrackSidecar.self,
        from: Data(contentsOf: paths.trackMetaURL(for: trackID))
    )
}

private func makeLibraryContext(root: URL, mode: kmgccc_player.MusicLibraryMode) throws -> kmgccc_player.LibraryContext {
    let manifest = kmgccc_player.MusicLibraryManifest(displayName: "Test", mode: mode)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(to: kmgccc_player.LibraryPaths(rootURL: root).manifestURL)
    return kmgccc_player.LibraryContext(
        manifest: manifest,
        rootURL: root,
        rootBookmarkData: Data(root.path.utf8),
        generation: 1
    )
}

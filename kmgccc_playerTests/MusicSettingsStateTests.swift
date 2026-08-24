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

    func testNewSetupDefaultsToReferencedAndDismissInvalidatesWork() {
        let viewModel = LibrarySetupViewModel()
        XCTAssertEqual(viewModel.mode, .referenced)

        viewModel.present(.setup(.referenced))
        viewModel.storageParentURL = temporaryLibraryRoot()
        viewModel.selectedMusicURLs = [URL(fileURLWithPath: "/tmp/song.mp3")]
        let operation = viewModel.beginOperation()

        viewModel.dismiss()

        XCTAssertFalse(viewModel.isCurrentOperation(operation))
        XCTAssertEqual(viewModel.presentation, .none)
        XCTAssertEqual(viewModel.operation, .idle)
        XCTAssertTrue(viewModel.selectedMusicURLs.isEmpty)
        XCTAssertNil(viewModel.initialImportSelection)
        XCTAssertFalse(viewModel.isStorageLocationExplicitlyChosen)
    }

    func testLibraryOperationCoordinatorCancelsAndWaitsForBackgroundWork() async {
        let coordinator = LibraryOperationCoordinator()
        let started = expectation(description: "background work started")
        let cancelled = expectation(description: "background work cancelled")

        coordinator.start {
            started.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            cancelled.fulfill()
        }

        await fulfillment(of: [started], timeout: 1)
        await coordinator.quiesceAndWait()
        await fulfillment(of: [cancelled], timeout: 1)
    }

    // MARK: - §14 Observable Task State

    @MainActor
    private final class LibraryTaskSnapshotLog {
        private(set) var snapshots: [[LibraryOperationTaskDescriptor]] = []

        func record(_ descriptors: [LibraryOperationTaskDescriptor]) {
            snapshots.append(descriptors)
        }

        func states(ofID id: UUID) -> [LibraryTaskState] {
            snapshots.compactMap { snapshot in
                snapshot.first { $0.id == id }?.state
            }
        }

        /// Same as `states(ofID:)` but collapses consecutive repeats caused by
        /// sibling tasks mutating the shared snapshot list.
        func distinctStates(ofID id: UUID) -> [LibraryTaskState] {
            var result: [LibraryTaskState] = []
            for snapshot in snapshots {
                guard let state = snapshot.first(where: { $0.id == id })?.state else { continue }
                if result.last != state {
                    result.append(state)
                }
            }
            return result
        }

        func lastDescriptor(withID id: UUID) -> LibraryOperationTaskDescriptor? {
            snapshots.reversed().compactMap { $0.first { $0.id == id } }.first
        }

        var maxLiveCount: Int {
            snapshots.map(\.count).max() ?? 0
        }
    }

    @MainActor
    private final class FlagBox {
        var value = false
    }

    func testLibraryTaskLifecycleOrdersQueuedRunningCompleted() async throws {
        let libraryID = UUID()
        let coordinator = LibraryOperationCoordinator(libraryID: libraryID, sessionGeneration: 42)
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        let started = expectation(description: "operation started")
        let runner = Task {
            try await coordinator.run {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(100))
                return true
            }
        }

        await fulfillment(of: [started], timeout: 2)
        let operationID = try XCTUnwrap(log.snapshots.first?.first?.id)
        XCTAssertEqual(log.distinctStates(ofID: operationID), [.queued, .running])

        let value = try await runner.value
        XCTAssertTrue(value)

        XCTAssertEqual(log.distinctStates(ofID: operationID), [.queued, .running, .completed])
        let final = try XCTUnwrap(log.lastDescriptor(withID: operationID))
        XCTAssertEqual(final.kind, .other)
        XCTAssertEqual(final.libraryID, libraryID)
        XCTAssertEqual(final.sessionGeneration, 42)
        XCTAssertNotNil(final.startedAt)
        XCTAssertNotNil(final.finishedAt)
        XCTAssertNil(final.lastCheckpointLabel)
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testLibraryTaskFailsOnThrownError() async throws {
        struct ImportExplosion: Error {}
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        do {
            _ = try await coordinator.run { throw ImportExplosion() }
            XCTFail("expected the operation error to propagate")
        } catch {}

        XCTAssertEqual(
            log.snapshots.compactMap(\.first?.state),
            [.queued, .running, .failed]
        )
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testLibraryTaskRecordsPartialFailureBeforeCompleting() async throws {
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        let result = try await coordinator.run { () -> Int in
            coordinator.recordPartialFailure("封面下载失败")
            coordinator.recordPartialFailure("歌词匹配失败")
            return 2
        }
        XCTAssertEqual(result, 2)

        let operationID = try XCTUnwrap(log.snapshots.first?.first?.id)
        XCTAssertEqual(
            log.states(ofID: operationID),
            [.queued, .running, .running, .running, .partialFailure]
        )
        let final = try XCTUnwrap(log.lastDescriptor(withID: operationID))
        XCTAssertEqual(final.partialFailureSummaries, ["封面下载失败", "歌词匹配失败"])
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testLibraryTaskCheckpointTransitionsWithLabelAndKind() async throws {
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        _ = try await coordinator.run(as: .sourceScan) {
            coordinator.recordCheckpoint("来源扫描中")
        }

        let operationID = try XCTUnwrap(log.snapshots.first?.first?.id)
        XCTAssertEqual(
            log.distinctStates(ofID: operationID),
            [.queued, .running, .checkpointed, .completed]
        )
        let checkpointed = try XCTUnwrap(
            log.snapshots.lazy.compactMap { $0.first { $0.state == .checkpointed } }.first
        )
        XCTAssertEqual(checkpointed.lastCheckpointLabel, "来源扫描中")
        XCTAssertNotNil(checkpointed.lastCheckpointAt)
        let final = try XCTUnwrap(log.lastDescriptor(withID: operationID))
        XCTAssertEqual(final.kind, .sourceScan)
        XCTAssertEqual(final.lastCheckpointLabel, "来源扫描中")
    }

    func testQuiesceCancelsMidRunTaskAfterThrowPropagates() async throws {
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        let started = expectation(description: "mid-run operation started")
        let runner = Task {
            try await coordinator.run {
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
        }
        await fulfillment(of: [started], timeout: 2)

        await coordinator.quiesceAndWait()
        _ = try? await runner.value

        XCTAssertEqual(
            log.snapshots.compactMap(\.first?.state),
            [.queued, .running, .cancelled]
        )
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testQuiesceCancelsQueuedTaskWithoutStartingIt() async throws {
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        let registered = FlagBox()
        let queuedRegistered = expectation(description: "queued operation registered")
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
            if coordinator.taskDescriptors.count == 2, !registered.value {
                registered.value = true
                queuedRegistered.fulfill()
            }
        }

        let headStarted = expectation(description: "head operation started")
        let head = Task {
            try await coordinator.run {
                headStarted.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
        }
        await fulfillment(of: [headStarted], timeout: 2)

        let flag = FlagBox()
        let queued = Task {
            try await coordinator.run {
                flag.value = true
            }
        }
        await fulfillment(of: [queuedRegistered], timeout: 2)

        let headID = try XCTUnwrap(log.snapshots.first?.first?.id)
        let queuedID = try XCTUnwrap(coordinator.taskDescriptors.last?.id)

        await coordinator.quiesceAndWait()
        _ = try? await head.value
        _ = try? await queued.value

        XCTAssertEqual(log.distinctStates(ofID: headID), [.queued, .running, .cancelled])
        XCTAssertEqual(log.distinctStates(ofID: queuedID), [.queued, .cancelled])
        XCTAssertFalse(flag.value)
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testReEntrantInlineCallRecordsOntoEnclosingOperation() async throws {
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        let innerResult = try await coordinator.run { () -> Bool in
            try await coordinator.run {
                coordinator.recordCheckpoint("inner-checkpoint")
                return true
            }
        }
        XCTAssertTrue(innerResult)

        XCTAssertEqual(log.maxLiveCount, 1)
        let operationID = try XCTUnwrap(log.snapshots.first?.first?.id)
        XCTAssertEqual(
            log.distinctStates(ofID: operationID),
            [.queued, .running, .checkpointed, .completed]
        )
        let final = try XCTUnwrap(log.lastDescriptor(withID: operationID))
        XCTAssertEqual(final.lastCheckpointLabel, "inner-checkpoint")
    }

    func testSessionQuiescingRejectsOperationsWithoutCreatingDescriptors() async throws {
        let coordinator = LibraryOperationCoordinator()
        let log = LibraryTaskSnapshotLog()
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
        }

        await coordinator.quiesceAndWait()

        do {
            _ = try await coordinator.run { true }
            XCTFail("expected sessionQuiescing rejection")
        } catch let error as LibraryOperationError {
            XCTAssertEqual(error, .sessionQuiescing)
        }
        XCTAssertFalse(coordinator.start {})
        XCTAssertTrue(log.snapshots.isEmpty)
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testStartCapturesKindLibraryIDAndGeneration() async throws {
        let libraryID = UUID()
        let coordinator = LibraryOperationCoordinator(libraryID: libraryID, sessionGeneration: 9)
        let log = LibraryTaskSnapshotLog()
        let terminal = expectation(description: "terminal state observed")
        coordinator.onTasksDidChange = { [weak log] in
            log?.record(coordinator.taskDescriptors)
            if log?.snapshots.last?.first?.state.isTerminal == true {
                terminal.fulfill()
            }
        }

        let finished = expectation(description: "started work finished")
        coordinator.start({
            finished.fulfill()
        }, kind: .indexUpdate)

        await fulfillment(of: [finished], timeout: 2)
        await fulfillment(of: [terminal], timeout: 2)

        let descriptor = try XCTUnwrap(log.snapshots.last?.first)
        XCTAssertEqual(descriptor.kind, .indexUpdate)
        XCTAssertEqual(descriptor.libraryID, libraryID)
        XCTAssertEqual(descriptor.sessionGeneration, 9)
        XCTAssertEqual(descriptor.state, .completed)
        XCTAssertNotNil(descriptor.startedAt)
        XCTAssertNotNil(descriptor.finishedAt)
        XCTAssertTrue(coordinator.taskDescriptors.isEmpty)
    }

    func testLibraryDiagnosticsSeparateHealthStatesAndFindDuplicates() {
        let first = LibraryTrackDiagnosticInput(
            id: UUID(),
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            availability: .available,
            format: "mp3",
            fileSize: 10,
            physicalKey: "identity:volume:one",
            metadataKey: "song|artist|album|180",
            path: "/Music/song.mp3",
            storageKind: .referenced
        )
        let samePhysical = LibraryTrackDiagnosticInput(
            id: UUID(),
            title: "Song copy",
            artist: "Artist",
            album: "Album",
            duration: 180,
            availability: .missing,
            format: "flac",
            fileSize: 20,
            physicalKey: "identity:volume:one",
            metadataKey: "song|artist|album|180",
            path: "/Music/song.flac",
            storageKind: .referenced
        )
        let permissionDenied = LibraryTrackDiagnosticInput(
            id: UUID(),
            title: "Other",
            artist: "Other Artist",
            album: "Album",
            duration: 0,
            availability: .permissionDenied,
            format: "mp3",
            fileSize: nil,
            physicalKey: nil,
            metadataKey: nil,
            path: "/Music/other.mp3",
            storageKind: .managed
        )
        let snapshot = LibraryDiagnosticsAnalyzer.analyze([first, samePhysical, permissionDenied])
        XCTAssertEqual(snapshot.summary.totalTracks, 3)
        XCTAssertEqual(snapshot.summary.playableTracks, 1)
        XCTAssertEqual(snapshot.summary.missingTracks, 1)
        XCTAssertEqual(snapshot.summary.permissionDeniedTracks, 1)
        XCTAssertEqual(snapshot.summary.formatCounts["mp3"], 2)
        XCTAssertEqual(snapshot.duplicateGroups.count, 2)
        XCTAssertEqual(
            snapshot.duplicateGroups.first?.reason,
            .samePhysicalFile
        )
    }

    func testSearchIndexIndexesExtendedFieldsAndHonorsSort() async throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        try paths.createRequiredDirectories()
        let index = LibrarySearchIndex(paths: paths)
        let firstID = UUID()
        let secondID = UUID()
        let sources = [
            SearchDocumentSource(
                trackID: firstID,
                titleRaw: "First Song",
                artistRaw: "Artist A",
                albumRaw: "Album Z",
                albumArtistRaw: "Various Artists",
                ttmlLyricsFileURL: nil,
                plainLyricsFileURL: nil,
                inlineTTMLText: nil,
                inlinePlainLyricsText: nil,
                playCount: 0,
                preferenceScore: 0,
                lastPlayedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 100),
                artistCreditsRaw: "Guest A",
                filePathRaw: "/Music/First Song.flac",
                formatRaw: "flac"
            ),
            SearchDocumentSource(
                trackID: secondID,
                titleRaw: "Second Song",
                artistRaw: "Artist B",
                albumRaw: "Album A",
                albumArtistRaw: "Artist B",
                ttmlLyricsFileURL: nil,
                plainLyricsFileURL: nil,
                inlineTTMLText: nil,
                inlinePlainLyricsText: nil,
                playCount: 0,
                preferenceScore: 0,
                lastPlayedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 200),
                artistCreditsRaw: nil,
                filePathRaw: "/Music/Second Song.mp3",
                formatRaw: "mp3"
            )
        ]

        await index.replaceAllDocuments(sources, reason: "stage8-test")
        try await index.validateIntegrity(expectedTrackIDs: Set([firstID, secondID]))

        let formatHits = await index.search(
            query: "flac",
            fields: [.format],
            sort: .title
        )
        XCTAssertEqual(formatHits.map(\.trackID), [firstID])

        let pathHits = await index.search(
            query: "Second Song.mp3",
            fields: [.path],
            sort: .title
        )
        XCTAssertEqual(pathHits.map(\.trackID), [secondID])

        let defaultFieldHits = await index.search(
            query: "First Song",
            sort: .relevance
        )
        XCTAssertEqual(defaultFieldHits.first?.trackID, firstID)

        let newestHits = await index.search(
            query: "Song",
            fields: [.title],
            sort: .newest
        )
        XCTAssertEqual(newestHits.map(\.trackID), [secondID, firstID])
        await index.close()
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

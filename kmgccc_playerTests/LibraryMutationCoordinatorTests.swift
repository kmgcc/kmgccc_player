import XCTest
@testable import kmgccc_player

@MainActor
final class LibraryMutationCoordinatorTests: XCTestCase {
    func testJournalPreservesUnresolvedInterruptedIntent() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var intent = try await fixture.journal.prepare(
            kind: .importCommit,
            sessionGeneration: 7,
            targetIDs: ["track-b", "track-a", "track-a"]
        )
        intent = try await fixture.journal.markCommitting(intent)
        _ = try await fixture.journal.markFailed(intent, error: TestError.expected)

        let recovered = try await fixture.journal.recoverInterruptedMutations()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].id, intent.id)
        XCTAssertEqual(recovered[0].state, .failed)
        XCTAssertEqual(recovered[0].targetIDs, ["track-a", "track-b"])
        let pending = try await fixture.journal.pendingIntents()
        let completed = try await fixture.journal.completedIntents()
        XCTAssertEqual(pending.map(\.id), [intent.id])
        XCTAssertTrue(completed.isEmpty)
    }

    func testPreparedIntentCanBeArchivedWithoutClaimingPartialWrites() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let intent = try await fixture.journal.prepare(kind: .importCommit, sessionGeneration: 1)
        let recovered = try await fixture.journal.recoverInterruptedMutations()
        XCTAssertEqual(recovered.first?.id, intent.id)
        XCTAssertEqual(recovered.first?.state, .recovered)
        let pending = try await fixture.journal.pendingIntents()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCorruptPendingRecordsAreReportedBeforeAnyRecordIsMoved() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let intent = try await fixture.journal.prepare(kind: .importCommit, sessionGeneration: 1)
        let pendingDirectory = fixture.journal.paths.pendingTransactionsRootURL
        let valid = pendingDirectory.appendingPathComponent("\(intent.id.uuidString).json")
        let first = pendingDirectory.appendingPathComponent("bad-a.json")
        let second = pendingDirectory.appendingPathComponent("bad-b.json")
        try Data("invalid".utf8).write(to: first)
        try Data("invalid".utf8).write(to: second)
        do {
            _ = try await fixture.journal.recoverInterruptedMutations()
            XCTFail("Expected corrupt pending records to stop recovery")
        } catch let error as LibraryMetadataReadError {
            let actual = Set(([error.fileURL] + error.additionalFiles).map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            })
            let expected = Set([first, second].map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            })
            XCTAssertEqual(actual, expected)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
        let completed = try await fixture.journal.completedIntents()
        XCTAssertTrue(completed.isEmpty)
    }

    func testFailedMutationNotifiesImmediatelyAndKeepsPendingEvidence() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var noticeCount = 0
        fixture.coordinator.onUnresolvedMutation = { _ in noticeCount += 1 }
        do {
            let _: Void = try await fixture.coordinator.run(kind: .importCommit, targetIDs: ["track-a"]) {
                throw TestError.expected
            }
            XCTFail("Expected mutation failure")
        } catch {}
        XCTAssertEqual(noticeCount, 1)
        let pending = try await fixture.journal.pendingIntents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.state, .failed)
    }

    func testPartialMutationReturnsValueAndRetainsUnresolvedIntent() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var noticeCount = 0
        fixture.coordinator.onUnresolvedMutation = { _ in noticeCount += 1 }
        let result = try await fixture.coordinator.run(kind: .importCommit, targetIDs: ["a", "b"]) {
            try await fixture.coordinator.run(kind: .importCommit) {
                fixture.coordinator.recordUnresolved("saved one of two")
                fixture.coordinator.recordUnresolved("association incomplete")
                return ["a"]
            }
        }
        XCTAssertEqual(result, ["a"])
        XCTAssertEqual(noticeCount, 1)
        let pending = try await fixture.journal.pendingIntents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.state, .failed)
        XCTAssertEqual(pending.first?.failureSummary, "saved one of two\nassociation incomplete")
        let completed = try await fixture.journal.completedIntents()
        XCTAssertTrue(completed.isEmpty)
    }

    func testCompletedStepRemainsRecordedWhenLaterWorkFails() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let _: Void = try await fixture.coordinator.run(
                kind: .importCommit,
                targetIDs: ["track-a"],
                stepIDs: ["audio", "track_metadata"]
            ) {
                try await fixture.coordinator.recordCompletedStep("audio")
                throw TestError.expected
            }
            XCTFail("Expected later work to fail")
        } catch {}
        let pending = try await fixture.journal.pendingIntents()
        let intent = try XCTUnwrap(pending.first)
        XCTAssertEqual(intent.steps.first { $0.id == "audio" }?.state, .completed)
        XCTAssertEqual(intent.steps.first { $0.id == "track_metadata" }?.state, .pending)
        XCTAssertEqual(intent.state, .failed)
    }

    func testCoordinatorSerializesShortCommitsAndArchivesEachIntent() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ContinuationGate()
        var events: [String] = []

        let first = Task { @MainActor in
            try await fixture.coordinator.run(kind: .maintenance) {
                events.append("first-start")
                await gate.wait()
                events.append("first-end")
                return 1
            }
        }
        await waitUntil { events.contains("first-start") }

        let second = Task { @MainActor in
            try await fixture.coordinator.run(kind: .settingsUpdate) {
                events.append("second")
                return 2
            }
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(events, ["first-start"])

        gate.open()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
        let pending = try await fixture.journal.pendingIntents()
        let completed = try await fixture.journal.completedIntents()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(completed.count, 2)
    }

    func testNestedMutationMergesIntoOneDurableIntent() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let value = try await fixture.coordinator.run(kind: .userLibraryMutation) {
            try await fixture.coordinator.run(kind: .settingsUpdate) {
                42
            }
        }

        XCTAssertEqual(value, 42)
        let completed = try await fixture.journal.completedIntents()
        XCTAssertEqual(completed.count, 1)
    }

    func testQuiesceRejectsNewMutationButDrainsCurrentCommit() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = ContinuationGate()
        var didFinish = false

        let current = Task { @MainActor in
            try await fixture.coordinator.run(kind: .maintenance) {
                await gate.wait()
                didFinish = true
            }
        }
        await waitUntil { gate.isWaiting }
        let quiesce = Task { @MainActor in
            await fixture.coordinator.quiesceAndWait()
        }
        await waitUntil { !fixture.coordinator.isAcceptingMutations }

        do {
            _ = try await fixture.coordinator.run(kind: .maintenance) { 1 }
            XCTFail("quiescing coordinator accepted a new mutation")
        } catch let error as LibraryMutationCoordinatorError {
            XCTAssertEqual(error, .sessionQuiescing)
        }

        gate.open()
        try await current.value
        await quiesce.value
        XCTAssertTrue(didFinish)
        let pending = try await fixture.journal.pendingIntents()
        XCTAssertTrue(pending.isEmpty)
    }

    func testIsolatedTargetRejectsOnlyMutationsTouchingIt() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.coordinator.isolateTargets(["track-a"])
        do {
            _ = try await fixture.coordinator.run(kind: .userLibraryMutation, targetIDs: ["track-a"]) { 1 }
            XCTFail("An isolated target must reject a new mutation")
        } catch let error as LibraryMutationCoordinatorError {
            XCTAssertEqual(error, .targetIsolated("track-a"))
        }
        let value = try await fixture.coordinator.run(
            kind: .userLibraryMutation,
            targetIDs: ["track-b"]
        ) { 2 }
        XCTAssertEqual(value, 2)
        fixture.coordinator.replaceIsolatedTargets([])
        let released = try await fixture.coordinator.run(
            kind: .userLibraryMutation,
            targetIDs: ["track-a"]
        ) { 3 }
        XCTAssertEqual(released, 3)
    }

    func testPendingInspectionIsReadOnly() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var intent = try await fixture.journal.prepare(
            kind: .importCommit,
            sessionGeneration: 1,
            targetIDs: ["track-a"]
        )
        intent = try await fixture.journal.markCommitting(intent)
        _ = try await fixture.journal.markFailed(intent, error: TestError.expected)
        let pendingURL = fixture.journal.paths.pendingTransactionsRootURL
            .appendingPathComponent("\(intent.id.uuidString).json")
        let before = try Data(contentsOf: pendingURL)

        let inspection = try await fixture.journal.inspectPending()

        XCTAssertEqual(inspection.intents.map(\.id), [intent.id])
        XCTAssertTrue(inspection.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: pendingURL), before)
        let completed = try await fixture.journal.completedIntents()
        XCTAssertTrue(completed.isEmpty)
    }

    func testVerifiedIntentCanBeArchivedWithoutReplay() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var intent = try await fixture.journal.prepare(
            kind: .importCommit,
            sessionGeneration: 1,
            targetIDs: ["track-a"],
            stepIDs: ["audio", "track_metadata", "ncm_associations"]
        )
        intent = try await fixture.journal.markCommitting(intent)
        _ = try await fixture.journal.markStepFailed(intent, stepID: "track_metadata", error: TestError.expected)
        _ = try await fixture.journal.markFailed(intent, error: TestError.expected)

        _ = try await fixture.journal.markResolved(
            intentID: intent.id,
            summary: "verified target projection"
        )

        let pending = try await fixture.journal.pendingIntents()
        XCTAssertTrue(pending.isEmpty)
        let completed = try await fixture.journal.completedIntents()
        XCTAssertEqual(completed.map(\.id), [intent.id])
        XCTAssertEqual(completed.first?.state, .recovered)
        XCTAssertEqual(completed.first?.recoverySummary, "verified target projection")
    }

    func testReviewedIntentCanBeArchivedWithoutClaimingRecovery() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var intent = try await fixture.journal.prepare(
            kind: .userLibraryMutation,
            sessionGeneration: 1,
            targetIDs: ["track-a"]
        )
        intent = try await fixture.journal.markCommitting(intent)
        _ = try await fixture.journal.markFailed(intent, error: TestError.expected)

        _ = try await fixture.journal.archiveUnresolved(
            intentID: intent.id,
            summary: "reviewed by the user"
        )

        let pending = try await fixture.journal.pendingIntents()
        XCTAssertTrue(pending.isEmpty)
        let completed = try await fixture.journal.completedIntents()
        XCTAssertEqual(completed.map(\.state), [.archived])
        XCTAssertEqual(completed.first?.recoverySummary, "reviewed by the user")
    }

    func testImportVerifierAcceptsOnlyCompleteTargets() {
        let trackID = UUID()
        let intent = LibraryMutationIntent(
            libraryID: UUID(),
            sessionGeneration: 1,
            kind: .importCommit,
            targetIDs: [trackID.uuidString]
        )
        var snapshot = LibraryMutationProjectionSnapshot()
        snapshot.trackIDs = [trackID]
        snapshot.trackFolderIDs = [trackID]
        snapshot.managedAudioExists = [trackID: true]
        snapshot.isComplete = true
        let complete = LibraryMutationVerifier.verify(intent, snapshot: snapshot)
        XCTAssertTrue(complete.isResolved)
        XCTAssertEqual(complete.intentID, intent.id)

        snapshot.managedAudioExists = [trackID: false]
        let incomplete = LibraryMutationVerifier.verify(intent, snapshot: snapshot)
        XCTAssertFalse(incomplete.isResolved)

        snapshot.trackIDs = []
        snapshot.trackFolderIDs = []
        snapshot.managedAudioExists = [:]
        let neverPublished = LibraryMutationVerifier.verify(intent, snapshot: snapshot)
        XCTAssertTrue(neverPublished.isResolved)
    }

    private func makeFixture() -> (
        root: URL,
        journal: LibraryMutationJournal,
        coordinator: LibraryMutationCoordinator
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutation-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = kmgccc_player.LibraryPaths(rootURL: root)
        let libraryID = UUID()
        let journal = LibraryMutationJournal(paths: paths, libraryID: libraryID)
        let coordinator = LibraryMutationCoordinator(
            libraryID: libraryID,
            sessionGeneration: 1,
            journal: journal
        )
        return (root, journal, coordinator)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate(), "condition did not become true")
    }

    private enum TestError: Error {
        case expected
    }
}

@MainActor
private final class ContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

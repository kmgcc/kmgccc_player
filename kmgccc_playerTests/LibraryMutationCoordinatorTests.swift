import XCTest
@testable import kmgccc_player

@MainActor
final class LibraryMutationCoordinatorTests: XCTestCase {
    func testJournalRecoversInterruptedIntentBeforeNextWritableSession() async throws {
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
        XCTAssertEqual(recovered[0].state, .recovered)
        XCTAssertEqual(recovered[0].targetIDs, ["track-a", "track-b"])
        let pending = try await fixture.journal.pendingIntents()
        let completed = try await fixture.journal.completedIntents()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(completed.last?.state, .recovered)
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

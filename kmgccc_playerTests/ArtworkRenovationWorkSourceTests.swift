import XCTest
@testable import kmgccc_player

@MainActor
final class ArtworkRenovationWorkSourceTests: XCTestCase {
    func testLegacyCohortSkipsManualChoicesAndPersistsAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryID = UUID()
        let legacy = Track(title: "Legacy", artworkData: Data([1]))
        let manual = Track(title: "Manual", artworkData: Data([2]))
        manual.artworkIsUserSelected = true
        var tracks = [legacy, manual]
        func source() -> ArtworkRenovationWorkSource {
            ArtworkRenovationWorkSource(libraryID: libraryID, owner: .app,
                ledgerURL: root.appendingPathComponent("repair.json"), tracks: { tracks },
                lookup: { _ in nil }, apply: { _, _, _, _ in XCTFail("No match must preserve the cover"); return false }, wake: {})
        }
        let first = source()
        await first.prepare()
        XCTAssertEqual(first.total, 1)
        let unit = try XCTUnwrap(first.nextUnit(priority: .idleBatch, excluding: []))
        let outcome = await unit.run(BackgroundWorkContext())
        first.unitDidEnd(unitID: unit.id, outcome: outcome)
        XCTAssertEqual(first.completed, 1)
        first.close()
        await first.flush()
        tracks.append(Track(title: "New import", artworkData: Data([3])))
        let reopened = source()
        await reopened.prepare()
        XCTAssertEqual(reopened.total, 1, "Only the upgrade's frozen cohort is renovated")
        XCTAssertFalse(reopened.hasWork(priority: .idleBatch, excluding: []))
        reopened.close()
    }

    func testPauseSurvivesLibraryReopenOnlyInMemoryAndDeclineIsDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryID = UUID()
        let track = Track(title: "Legacy", artworkData: Data([1]))
        func source() -> ArtworkRenovationWorkSource {
            ArtworkRenovationWorkSource(libraryID: libraryID, owner: .app,
                ledgerURL: root.appendingPathComponent("repair.json"), tracks: { [track] },
                lookup: { _ in nil }, apply: { _, _, _, _ in false }, wake: {})
        }
        let first = source()
        await first.prepare()
        first.setPaused(true)
        XCTAssertFalse(first.hasWork(priority: .idleBatch, excluding: []))
        first.close()
        let reopened = source()
        await reopened.prepare()
        XCTAssertTrue(reopened.isPaused)
        let stored = try JSONDecoder().decode(ArtworkRenovationState.self, from: Data(contentsOf: root.appendingPathComponent("repair.json")))
        XCTAssertFalse(stored.declined)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        XCTAssertNil(json["paused"], "A new process must resume the pass")
        reopened.setPaused(false)
        XCTAssertTrue(reopened.hasWork(priority: .idleBatch, excluding: []))
        reopened.decline()
        await reopened.flush()
        reopened.close()
        let declined = source()
        await declined.prepare()
        XCTAssertTrue(declined.isDeclined)
        XCTAssertFalse(declined.hasWork(priority: .idleBatch, excluding: []))
        declined.close()
    }

    func testManualChoiceMadeAfterEnqueueIsCheckedBeforeLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(title: "Legacy", artworkData: Data([1]))
        let calls = RenovationLookupCounter()
        let source = ArtworkRenovationWorkSource(libraryID: UUID(), owner: .app,
            ledgerURL: root.appendingPathComponent("repair.json"), tracks: { [track] },
            lookup: { _ in await calls.increment(); return nil }, apply: { _, _, _, _ in false }, wake: {})
        await source.prepare()
        track.artworkIsUserSelected = true
        let unit = try XCTUnwrap(source.nextUnit(priority: .idleBatch, excluding: []))
        let outcome = await unit.run(BackgroundWorkContext())
        source.unitDidEnd(unitID: unit.id, outcome: outcome)
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(source.completed, 1)
        source.close()
    }

    func testClosedQueuedUnitCannotStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(title: "Legacy", artworkData: Data([1]))
        let source = ArtworkRenovationWorkSource(libraryID: UUID(), owner: .app,
            ledgerURL: root.appendingPathComponent("repair.json"), tracks: { [track] },
            lookup: { _ in nil }, apply: { _, _, _, _ in XCTFail("Closed source applied artwork"); return true }, wake: {})
        await source.prepare()
        let unit = try XCTUnwrap(source.nextUnit(priority: .idleBatch, excluding: []))
        source.close()
        let outcome = await unit.run(BackgroundWorkContext())
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(source.completed, 0)
    }

    func testManualSelectionWhileLookupIsRunningPreservesCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(title: "Legacy", artworkData: Data([1]))
        let gate = RenovationLookupGate()
        let source = ArtworkRenovationWorkSource(libraryID: UUID(), owner: .app,
            ledgerURL: root.appendingPathComponent("repair.json"), tracks: { [track] },
            lookup: { _ in
                await gate.wait()
                return CoverCandidate(imageData: Data([3]), source: .appleMusic, sourceItemId: "new", width: 1200, height: 1200)
            }, apply: { _, _, _, _ in XCTFail("Manual choice was overwritten"); return true }, wake: {})
        await source.prepare()
        let unit = try XCTUnwrap(source.nextUnit(priority: .idleBatch, excluding: []))
        let run = Task { await unit.run(BackgroundWorkContext()) }
        await gate.started()
        track.artworkData = Data([2])
        track.artworkIsUserSelected = true
        await gate.release()
        let outcome = await run.value
        source.unitDidEnd(unitID: unit.id, outcome: outcome)
        XCTAssertEqual(track.artworkData, Data([2]))
        XCTAssertEqual(source.updated, 0)
        source.close()
    }

    func testPauseWhileWaitingForWriterDoesNotMarkCoverAsFinished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = Track(title: "Legacy", artworkData: Data([1]))
        let gate = RenovationLookupGate()
        let source = ArtworkRenovationWorkSource(libraryID: UUID(), owner: .app,
            ledgerURL: root.appendingPathComponent("repair.json"), tracks: { [track] },
            lookup: { _ in CoverCandidate(imageData: Data([3]), source: .appleMusic, sourceItemId: "new", width: 1200, height: 1200) },
            apply: { _, _, _, _ in await gate.wait(); return false }, wake: {})
        await source.prepare()
        let unit = try XCTUnwrap(source.nextUnit(priority: .idleBatch, excluding: []))
        let run = Task { await unit.run(BackgroundWorkContext()) }
        await gate.started()
        source.setPaused(true)
        await gate.release()
        let outcome = await run.value
        source.unitDidEnd(unitID: unit.id, outcome: outcome)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(source.completed, 0)
        source.setPaused(false)
        XCTAssertTrue(source.hasWork(priority: .idleBatch, excluding: []))
        source.close()
    }
}

private actor RenovationLookupCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor RenovationLookupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

import XCTest
@testable import kmgccc_player

nonisolated private struct EmptyCompletionClient: MusicEnrichmentFetching {
    func fetch(provider: String, query: MusicEnrichmentQuery) async throws -> MusicEnrichmentResult? { nil }
    func materialize(_ descriptor: MotionArtworkDescriptor, destination: URL) async throws -> MusicEnrichmentHelperClient.MaterializedMotion {
        throw MusicEnrichmentHelperError.invalidResponse
    }
}

@MainActor
final class MusicEnrichmentWorkSourceTests: XCTestCase {
    func testNegativePassPersistsAndNewImportsJoinWithoutRepeatingOldSongs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: EmptyCompletionClient())
        let preferred = Track(title: "Preferred")
        let other = Track(title: "Other")
        var tracks = [other, preferred]
        var revision = 0
        func source() -> MusicEnrichmentWorkSource {
            MusicEnrichmentWorkSource(libraryID: UUID(), owner: .app, rootURL: root,
                service: service, tracks: { tracks }, revision: { revision },
                score: { $0 == preferred.id ? 10 : 0 }, wake: {})
        }
        let first = source()
        await first.prepare()
        let unit = try XCTUnwrap(first.nextUnit(priority: .idleBatch, excluding: []))
        XCTAssertEqual(unit.id, preferred.id.uuidString)
        XCTAssertNil(first.nextUnit(priority: .idleBatch, excluding: []), "Only one song may run")
        let outcome = await unit.run(BackgroundWorkContext())
        XCTAssertEqual(outcome, .completed)
        first.unitDidEnd(unitID: unit.id, outcome: outcome)
        first.close()
        await first.flush()

        let reopened = source()
        await reopened.prepare()
        XCTAssertEqual(reopened.status.completed, 1)
        XCTAssertEqual(reopened.status.remaining, 1)
        tracks.append(Track(title: "New import"))
        revision += 1
        XCTAssertEqual(reopened.status.remaining, 2)
        XCTAssertNotEqual(reopened.nextUnit(priority: .idleBatch, excluding: [])?.id, preferred.id.uuidString)
        reopened.close()
        await reopened.flush()
        await service.close()
    }

    func testPausedAndClosedSourcesNeverAdmitWork() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MusicEnrichmentService(store: MusicEnrichmentStore(rootURL: root), client: EmptyCompletionClient())
        let track = Track(title: "Song")
        let source = MusicEnrichmentWorkSource(libraryID: UUID(), owner: .app, rootURL: root,
            service: service, tracks: { [track] }, revision: { 0 }, score: { _ in 0 }, wake: {})
        await source.prepare()
        source.setPaused(true)
        XCTAssertFalse(source.hasWork(priority: .idleBatch, excluding: []))
        source.setPaused(false)
        XCTAssertTrue(source.hasWork(priority: .idleBatch, excluding: []))
        source.close()
        await source.flush()
        XCTAssertFalse(source.hasWork(priority: .idleBatch, excluding: []))
        await service.close()
    }
}

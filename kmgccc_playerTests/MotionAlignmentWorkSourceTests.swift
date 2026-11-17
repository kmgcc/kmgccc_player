import XCTest
@testable import kmgccc_player

@MainActor
final class MotionAlignmentWorkSourceTests: XCTestCase {
    func testExistingVideoIsScannedOnceAndReplacementIsQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let enrichment = root.appendingPathComponent("Enrichment")
        try FileManager.default.createDirectory(at: enrichment, withIntermediateDirectories: true)
        try Data([1]).write(to: enrichment.appendingPathComponent("first.mp4"))
        try Data([2]).write(to: enrichment.appendingPathComponent("second.mp4"))
        func artwork(_ path: String) -> TrackMotionArtwork {
            TrackMotionArtwork(importedAssets: [StoredMotionArtwork(
                kind: "square", relativePath: path, sourceURL: "importedVideo:\(path)",
                startTime: 0, duration: 250, width: nil, height: nil
            )])
        }
        let track = Track(title: "Song", motionArtwork: artwork("first.mp4"), duration: 240,
                          libraryRootSnapshot: root.path)
        var checks = 0
        func source() -> MotionAlignmentWorkSource {
            MotionAlignmentWorkSource(libraryID: UUID(), owner: .app, rootURL: enrichment,
                alignment: MotionAudioAlignmentCoordinator(), tracks: { [track] }, revision: { 0 }, wake: {},
                analyze: { _, _, _ in checks += 1; return .unmatched })
        }
        let first = source()
        await first.prepare()
        let unit = try XCTUnwrap(first.nextUnit(priority: .idleBatch, excluding: []))
        XCTAssertNil(first.nextUnit(priority: .idleBatch, excluding: []))
        let outcome = await unit.run(BackgroundWorkContext())
        XCTAssertEqual(outcome, .completed)
        first.unitDidEnd(unitID: unit.id, outcome: outcome)
        await first.close()

        let reopened = source()
        await reopened.prepare()
        XCTAssertEqual(reopened.progress.completed, 1)
        XCTAssertEqual(reopened.progress.remaining, 0)
        XCTAssertEqual(checks, 1)
        track.motionArtwork = artwork("second.mp4")
        reopened.invalidate(trackIDs: [track.id])
        XCTAssertEqual(reopened.progress.remaining, 1)
        XCTAssertNotNil(reopened.nextUnit(priority: .idleBatch, excluding: []))
        await reopened.close()
    }

    func testNonMVIsNotQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let enrichment = root.appendingPathComponent("Enrichment")
        try FileManager.default.createDirectory(at: enrichment, withIntermediateDirectories: true)
        try Data([1]).write(to: enrichment.appendingPathComponent("loop.mp4"))
        let asset = StoredMotionArtwork(kind: "square", relativePath: "loop.mp4", sourceURL: "loop",
                                       startTime: 0, duration: 10, width: nil, height: nil)
        let track = Track(title: "Song", motionArtwork: TrackMotionArtwork(importedAssets: [asset]),
                          duration: 240, libraryRootSnapshot: root.path)
        let source = MotionAlignmentWorkSource(libraryID: UUID(), owner: .app, rootURL: enrichment,
            alignment: MotionAudioAlignmentCoordinator(), tracks: { [track] }, revision: { 0 }, wake: {})
        await source.prepare()
        XCTAssertFalse(source.hasWork(priority: .idleBatch, excluding: []))
        await source.close()
    }
}

import XCTest
@testable import NativeLyrics

final class TimelineTests: XCTestCase {
    func testHalfOpenAndBufferedParallelRetention() {
        var t = LyricsTimeline(bounds:[.init(1,4),.init(2,7),.init(8,10)],profile:.currentPlayer)
        XCTAssertEqual(t.update(1).playing,[0]); XCTAssertEqual(t.update(2).highlighted,[0,1])
        let partial = t.update(4); XCTAssertEqual(partial.playing,[1]); XCTAssertEqual(partial.highlighted,[0,1])
        XCTAssertEqual(t.update(7).highlighted,[])
        XCTAssertEqual(t.update(8).highlighted,[2])
    }
    func testCompletedMiddleParallelRowRemainsHighlighted() {
        var t = LyricsTimeline(bounds:[.init(0,10),.init(5,6),.init(6,7)],profile:.currentPlayer)
        XCTAssertEqual(t.update(5.5).highlighted,[0,1])
        // B ends at the same instant C starts.  A keeps the foreground span
        // alive, so B is retained rather than blinking out between voices.
        XCTAssertEqual(t.update(6).playing,[0,2])
        XCTAssertEqual(t.update(6).highlighted,[0,1,2])
        XCTAssertEqual(t.update(7).highlighted,[0,1,2])
        XCTAssertEqual(t.update(10).highlighted,[])
    }
    func testParallelRetentionCanBeDisabledForSingleLayerHosts() {
        var t = LyricsTimeline(bounds:[.init(1,4),.init(2,7)],profile:.currentPlayer,preserveParallelHighlight:false)
        XCTAssertEqual(t.update(2).highlighted,[0,1])
        XCTAssertEqual(t.update(3).highlighted,[0,1])
        XCTAssertEqual(t.update(4).highlighted,[1])
    }
    func testNewParallelEndpointDropsRowsFromPreviousForegroundSpan() {
        var t = LyricsTimeline(bounds:[.init(0,4),.init(2,6),.init(4.5,7.5)],profile:.currentPlayer)
        XCTAssertEqual(t.update(2.1).highlighted,[0,1])
        // A has ended before C starts. Once C opens the next foreground span,
        // A must not remain sharp while B/C continue.
        XCTAssertEqual(t.update(4.5).highlighted,[1,2])
        XCTAssertEqual(t.update(5.8).highlighted,[1,2])
    }
    func testSeekClearsExpiredParallelAndSelectsNextInGap() {
        var t = LyricsTimeline(bounds:[.init(1,4),.init(2,7),.init(8,10)],profile:.currentPlayer)
        _ = t.update(2)
        XCTAssertEqual(t.update(4,seek:true).highlighted,[1])
        XCTAssertEqual(t.update(7.5,seek:true).focus,2)
    }
    func testUpstreamShortGapLingersAndSeekReconstructs() {
        var t = LyricsTimeline(bounds:[.init(1,4),.init(2,7),.init(8,10)],profile:.upstream)
        _ = t.update(2)
        XCTAssertEqual(t.update(7.5).highlighted,[0,1])
        XCTAssertEqual(t.update(7.5,seek:true).highlighted,[0,1])
        XCTAssertEqual(t.update(10).highlighted,[])
    }
    func testInterludeDoesNotAppearWithinOverlapUnion() {
        let t = LyricsTimeline(bounds:[.init(1,15),.init(2,3),.init(10,18),.init(24,26)],profile:.upstream)
        XCTAssertEqual(t.interludes,[.init(range:.init(18,24),anchor:2)])
    }
    func testForkInterludeThresholdDeductsQuarterSecond() {
        let f = LyricsTimeline(bounds:[.init(1,3),.init(7.1,10)],profile:.currentPlayer)
        let u = LyricsTimeline(bounds:[.init(1,3),.init(7.1,10)],profile:.upstream)
        XCTAssertTrue(f.interludes.isEmpty); XCTAssertEqual(u.interludes.count,1)
    }
    func testPauseFreezesPredictedTimeAndResumeDoesNotJumpBack() {
        var clock = LyricsClock()
        clock.synchronize(time: 0, playing: true, host: 0, force: true)

        XCTAssertEqual(clock.time(at: 1), 1, accuracy: 0.0001)

        // The playback sample is stale, but the pause transition must use the
        // predicted audio/presentation time at the transition boundary.
        clock.synchronize(time: 0.8, playing: false, host: 1)
        XCTAssertEqual(clock.time(at: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(clock.time(at: 2), 1, accuracy: 0.0001)

        // Resume from the frozen point even though the first resume sample is
        // still the old low-frequency value.
        clock.synchronize(time: 0.8, playing: true, host: 2)
        XCTAssertEqual(clock.time(at: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(clock.time(at: 3), 2, accuracy: 0.0001)
    }

    func testPausedExplicitTimeUpdateStillMovesTheClock() {
        var clock = LyricsClock()
        clock.synchronize(time: 4, playing: false, host: 0, force: true)
        clock.synchronize(time: 7, playing: false, host: 1)

        XCTAssertEqual(clock.time(at: 10), 7, accuracy: 0.0001)
    }
    func testUserScrollReturnsAtProfileDeadline() {
        var interaction = LyricsInteraction(); var snapshot = LyricsTimelineSnapshot(); snapshot.focus = 4
        interaction.scroll(100,now:1,timeline:snapshot)
        XCTAssertEqual(interaction.frozenFocus,4); XCTAssertFalse(interaction.update(now:6.14,profile:.upstream))
        XCTAssertTrue(interaction.update(now:6.15,profile:.upstream)); XCTAssertEqual(interaction.offset,0)
    }
    func testUserScrollTimeoutWaitsForPointerExit() {
        var interaction = LyricsInteraction(); var snapshot = LyricsTimelineSnapshot(); snapshot.focus = 2
        interaction.scroll(100,now:1,timeline:snapshot)
        XCTAssertFalse(interaction.update(now:20,profile:.currentPlayer,allowAutoResume:false))
        XCTAssertTrue(interaction.suspended)
        interaction.pointerExited(now:20)
        XCTAssertFalse(interaction.update(now:24.99,profile:.currentPlayer))
        XCTAssertTrue(interaction.update(now:25,profile:.currentPlayer))
    }
}

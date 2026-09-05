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
    func testParallelRetentionCanBeDisabledForSingleLayerHosts() {
        var t = LyricsTimeline(bounds:[.init(1,4),.init(2,7)],profile:.currentPlayer,preserveParallelHighlight:false)
        XCTAssertEqual(t.update(2).highlighted,[0,1])
        XCTAssertEqual(t.update(3).highlighted,[0,1])
        XCTAssertEqual(t.update(4).highlighted,[1])
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
    func testUserScrollReturnsAtProfileDeadline() {
        var interaction = LyricsInteraction(); var snapshot = LyricsTimelineSnapshot(); snapshot.focus = 4
        interaction.scroll(100,now:1,timeline:snapshot)
        XCTAssertEqual(interaction.frozenFocus,4); XCTAssertFalse(interaction.update(now:6.14,profile:.upstream))
        XCTAssertTrue(interaction.update(now:6.15,profile:.upstream)); XCTAssertEqual(interaction.offset,0)
    }
}

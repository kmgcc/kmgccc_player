import AppKit
import XCTest
@testable import NativeLyrics

final class BehaviorRegressionTests: XCTestCase {
    private let fixture = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='3s'><span begin='0s' end='3s'>First</span></p><p begin='3s' end='6s'><span begin='0s' end='3s'>Second</span></p><p begin='6s' end='9s'><span begin='0s' end='3s'>Third</span></p><p begin='9s' end='12s'><span begin='0s' end='3s'>Fourth</span></p></div></body></tt>".utf8)

    @MainActor func testBlurTransitionsAndPointerExitDeadline() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:fixture,playing:true,hostTime:0)
        let before = view.render(at:2.9)
        XCTAssertGreaterThan(before.groups[1].blur,2)
        let transition = view.render(at:3.01)
        XCTAssertGreaterThan(transition.groups[1].blur,2)
        let settled = view.render(at:3.6)
        XCTAssertEqual(settled.groups[1].blur,0,accuracy:0.001)
        XCTAssertGreaterThan(settled.groups[0].blur,2)
        view.synchronize(time:3.6,playing:false,hostTime:3.6)
        view.setPointerInside(true,hostTime:3.6); view.render(at:3.6)
        XCTAssertTrue(view.render(at:4.2).groups.allSatisfy { $0.blur < 0.001 })
        view.setPointerInside(false,hostTime:4.2)
        XCTAssertTrue(view.render(at:7.19).groups.allSatisfy { $0.blur < 0.001 })
        view.render(at:7.21)
        XCTAssertGreaterThan(view.render(at:7.8).groups[0].blur,2)
    }

    @MainActor func testScrubCancelsCascadeAndMovesStackImmediately() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:fixture,hostTime:0)
        view.synchronize(time:9.1,playing:false,seek:true,motion:.cascade,hostTime:1)
        let start = view.render(at:1)
        let moving = view.render(at:1.02)
        XCTAssertLessThan(moving.groups[0].y,start.groups[0].y)
        XCTAssertEqual(moving.groups[3].y,start.groups[3].y,accuracy:0.001)
        view.synchronize(time:3.1,playing:false,seek:true,hostTime:1.03)
        let scrub = view.render(at:1.03), later = view.render(at:2)
        for i in scrub.groups.indices { XCTAssertEqual(scrub.groups[i].y,later.groups[i].y,accuracy:0.001) }
    }

    func testWhitespaceAndBackwardsWordDoNotScrambleSweep() {
        let specs: [(String,Double,Double)] = [("I",1.703,1.831),(" ",0,3),("got",0.831,2.282),(" ",0,3),("three",2.282,2.573)]
        let placements = specs.enumerated().map { i,s in WordPlacement(atom:TextAtom(word:LyricWord(id:"\(i)",text:s.0,range:.init(s.1,s.2))),rect:.zero,pieces:[],width:s.0 == " " ? 10 : 100,fontSize:40,fadeHeight:48) }
        let path = MaskPath(placements,fadeWidth:20)
        var previous = -Double.infinity
        for i in 1700...2600 { let p = path.position(at:Double(i)/1000); XCTAssertGreaterThanOrEqual(p,previous); previous = p }
        XCTAssertGreaterThan(path.position(at:2.1),path.position(at:1.9))
        XCTAssertEqual(path.position(at:2.6),320,accuracy:0.001)
    }

    func testAnticipationMovesForwardThroughGapWithoutLag() {
        let words = [LyricWord(id:"a",text:"A",range:.init(1,2)),LyricWord(id:"b",text:"B",range:.init(4,5))]
        let path = MaskPath(words.map { WordPlacement(atom:TextAtom(word:$0),rect:.zero,pieces:[],width:100,fontSize:40,fadeHeight:48) },fadeWidth:20)
        XCTAssertGreaterThan(path.anticipatedPosition(at:3.5,amount:0.12),path.anticipatedPosition(at:2.5,amount:0.12))
        for i in 100...500 { let t = Double(i)/100; XCTAssertGreaterThanOrEqual(path.anticipatedPosition(at:t,amount:0.12),path.position(at:t)) }
    }

    func testExitResetsEmphasisAndIndependentBlendChannels() {
        let word = LyricWord(id:"a",text:"Glow",range:.init(0,4))
        let line = LyricLine(id:"line",range:.init(0,4),words:[word],isWordTimed:true)
        var config = LyricsConfiguration()
        config.channelBlend = .init(inactive:.normal,current:.normal,highlight:.plusLighter)
        let layout = TextLayoutEngine().group(PreparedGroup(source:.init(main:line),main:line,background:nil),width:760,config:config,dynamic:true,hasDuet:false).main
        let layers = LineLayers(layout,cache:GlyphCache(),scale:2,config:config,previous:nil,now:0)
        layers.update(now:0,media:1,floatTime:1,active:true,alpha:1,background:false,config:config)
        layers.update(now:1,media:2,floatTime:2,active:true,alpha:1,background:false,config:config)
        let glyph = layers.words[0].glyphs[0]
        XCTAssertGreaterThan(glyph.glow.opacity,0)
        XCTAssertNil(glyph.dark.compositingFilter)
        XCTAssertNotNil(glyph.bright.compositingFilter)
        layers.update(now:1.1,media:2,floatTime:2,active:false,alpha:0,background:false,config:config)
        layers.update(now:2,media:2,floatTime:2,active:false,alpha:0,background:false,config:config)
        XCTAssertEqual(glyph.glow.opacity,0)
        XCTAssertEqual(glyph.root.transform.m11,1,accuracy:0.001)
    }

    @MainActor func testExitCatchUpUsesWordEndBeyondTruncatedLine() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        try view.load(ttml:fixture,playing:true,hostTime:0)
        view.render(at:2.3)
        let exit = view.render(at:2.41)
        XCTAssertFalse(exit.groups[0].active)
        let half = view.render(at:2.55), complete = view.render(at:2.71)
        XCTAssertGreaterThan(half.groups[0].maskPosition,exit.groups[0].maskPosition)
        XCTAssertGreaterThan(complete.groups[0].maskPosition,half.groups[0].maskPosition)
    }

    @MainActor func testBackgroundRevealIsContinuousAndDoesNotOvershoot() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata'><body><div><p begin='1s' end='4s'><span begin='0s' end='3s'>Main</span><span ttm:role='x-bg' begin='0s' end='3s'>Background</span></p></div></body></tt>".utf8)
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:data,playing:true,hostTime:0)
        let collapsed = view.render(at:0.9).groups[0].height
        let initial = view.render(at:1).groups[0].height
        XCTAssertEqual(initial,collapsed,accuracy:0.001)
        var previous = initial
        for i in 121...180 {
            let frame = view.render(at:Double(i)/120).groups[0]
            XCTAssertGreaterThanOrEqual(frame.height,previous)
            XCTAssertTrue((0.9...1).contains(frame.backgroundScale))
            XCTAssertEqual(frame.backgroundSlide,0)
            previous = frame.height
        }
        XCTAssertGreaterThan(previous,collapsed)
        view.render(at:3.99); view.render(at:4)
        for i in 481...540 {
            let height = view.render(at:Double(i)/120).groups[0].height
            XCTAssertLessThanOrEqual(height,previous); previous = height
        }
        XCTAssertEqual(previous,collapsed,accuracy:0.001)
    }
}

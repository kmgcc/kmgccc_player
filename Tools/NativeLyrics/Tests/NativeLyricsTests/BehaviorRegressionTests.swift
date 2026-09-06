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
        view.render(at:4.2)
        XCTAssertGreaterThan(view.render(at:4.3).groups[0].blur,0)
        XCTAssertGreaterThan(view.render(at:4.8).groups[0].blur,2)
    }

    @MainActor func testOnlyFocusedRowStaysSharpWhenTTMLRangesOverlap() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='4s'><span begin='0s' end='4s'>Main</span></p><p begin='2s' end='6s'><span begin='0s' end='4s'>Background</span></p><p begin='4.5s' end='7.5s'><span begin='0s' end='3s'>Next</span></p></div></body></tt>".utf8)
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:data,playing:true,hostTime:0)
        let frame = view.render(at:3)
        XCTAssertEqual(frame.timeline.focus,0)
        XCTAssertEqual(frame.groups[0].blur,0,accuracy:0.001)
        XCTAssertGreaterThan(frame.groups[1].blur,2)
        view.render(at:4)
        view.render(at:5.8)
        let next = view.render(at:6.4)
        XCTAssertEqual(next.timeline.focus,1)
        XCTAssertGreaterThan(next.groups[0].blur,0)
        XCTAssertEqual(next.groups[1].blur,0,accuracy:0.001)
    }

    @MainActor func testExpiredFocusBlursDuringAnInterlude() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='2s'><span begin='0s' end='2s'>First</span></p><p begin='4s' end='6s'><span begin='0s' end='2s'>Second</span></p></div></body></tt>".utf8)
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:data,playing:true,hostTime:0)
        view.render(at:1)
        view.render(at:2.5)
        let gap = view.render(at:3.1)
        XCTAssertTrue(gap.timeline.playing.isEmpty)
        XCTAssertGreaterThan(gap.groups[0].blur,2)
        XCTAssertGreaterThan(gap.groups[1].blur,2)
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
        XCTAssertNil(glyph.root.compositingFilter)
        XCTAssertEqual(glyph.gradient.colors?.count,9)
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
    func testExitAccelerationStartsAtPlaybackRateAndFinishesOnDeadline() {
        let start = 2.0, end = 3.0, duration = 0.28
        let first = exitCatchUpTime(start:start,end:end,elapsed:0.00001,duration:duration)
        XCTAssertEqual((first-start)/0.00001,1,accuracy:0.001)
        let a = exitCatchUpTime(start:start,end:end,elapsed:0.05,duration:duration)
        let b = exitCatchUpTime(start:start,end:end,elapsed:0.1,duration:duration)
        XCTAssertGreaterThan(b-a,a-start)
        XCTAssertEqual(exitCatchUpTime(start:start,end:end,elapsed:duration,duration:duration),end)
    }

    func testInternalAdditiveInkDoesNotNeedBackdropAndKeepsColor() {
        let base = LyricsColor(0.2,0.4,0.3), high = LyricsColor(0.4,0.2,0.3)
        let normal = compositeInk(base:base,highlight:high,baseAlpha:1,highlightAlpha:0.5,mode:.normal)
        let plus = compositeInk(base:base,highlight:high,baseAlpha:1,highlightAlpha:0.5,mode:.plusLighter)
        XCTAssertEqual(plus.red,0.4,accuracy:0.0001)
        XCTAssertEqual(plus.green,0.5,accuracy:0.0001)
        XCTAssertGreaterThan(plus.red,normal.red)
        XCTAssertEqual(compositeInk(base:base,highlight:high,baseAlpha:1,highlightAlpha:0,mode:.plusLighter),base)
    }

    @MainActor func testManualScrollReturnsAtNextLineWithOrderedCascade() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:fixture,playing:true,hostTime:0)
        view.render(at:2)
        view.scroll(by:140,hostTime:2); view.render(at:2)
        let before = view.render(at:2.999)
        XCTAssertFalse(before.following)
        let start = view.render(at:3)
        XCTAssertTrue(start.following)
        for i in start.groups.indices { XCTAssertEqual(start.groups[i].y,before.groups[i].y,accuracy:0.02) }
        let moving = view.render(at:3.03)
        XCTAssertNotEqual(moving.groups[0].y,start.groups[0].y)
        XCTAssertEqual(moving.groups[3].y,start.groups[3].y,accuracy:0.02)
    }

    func testTimedSpacesHaveVisibleContinuousForwardLead() {
        let specs: [(String,Double,Double)] = [("night",0,1),(" ",0,5),("like",2,3)]
        let words = specs.enumerated().map { i,s in WordPlacement(atom:TextAtom(word:LyricWord(id:"\(i)",text:s.0,range:.init(s.1,s.2))),rect:.zero,pieces:[],width:s.0 == " " ? 8 : 100,fontSize:40,fadeHeight:48) }
        let path = MaskPath(words,fadeWidth:20)
        XCTAssertGreaterThan(path.anticipatedPosition(at:1.9,amount:0.12)-path.position(at:1.9),5)
        var last = path.anticipatedPosition(at:0,amount:0.12)
        for i in 1...359 {
            let t = Double(i)/120, p = path.anticipatedPosition(at:t,amount:0.12)
            XCTAssertGreaterThan(p,last); XCTAssertGreaterThanOrEqual(p,path.position(at:t)); last = p
        }
    }

    func testHighlightSmootherTracksPromptlyAndGlidesOnlyDuringAStall() {
        var smoother = HighlightSmoother()
        XCTAssertEqual(smoother.sample(target:0,now:0,playing:false,reset:true,fadeWidth:48),0)
        XCTAssertEqual(smoother.sample(target:100,now:0.1,playing:true,reset:false,fadeWidth:48),100,accuracy:0.001)
        let before = smoother.value
        let duringStall = smoother.sample(target:100,now:0.2,playing:true,reset:false,fadeWidth:48)
        XCTAssertGreaterThan(duringStall,before)
        XCTAssertLessThanOrEqual(duringStall,101.44)
        XCTAssertEqual(smoother.sample(target:80,now:0.3,playing:false,reset:false,fadeWidth:48),80,accuracy:0.001)
        let resumed = smoother.sample(target:80,now:1,playing:true,reset:false,fadeWidth:48)
        XCTAssertGreaterThanOrEqual(resumed,80)
        XCTAssertLessThanOrEqual(resumed,80.1)
    }

    @MainActor func testPausedMaskIsExactAndDoesNotDrift() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:fixture,time:1,hostTime:0)
        let a = view.render(at:0), b = view.render(at:100)
        XCTAssertEqual(a.groups[0].maskPosition,b.groups[0].maskPosition)
        view.synchronize(time:0,playing:false,seek:true,hostTime:100)
        XCTAssertLessThan(view.render(at:100).groups[0].maskPosition,0)
    }

    @MainActor func testColorAndMotionChangesDoNotRebuildText() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        try view.load(ttml:fixture,hostTime:0)
        let layouts = view.render(at:0).layoutCount
        view.configuration.glowRadiusScale = 2
        view.configuration.blur = false
        view.configuration.channelBlend.highlight = .plusLighter
        view.configuration.palette.mainActive = LyricsColor(0.3,0.7,0.5)
        XCTAssertEqual(view.render(at:1).layoutCount,layouts)
    }

    func testExitHighlightFadesImmediatelyAndHasNoTailAfterDeadline() {
        let word = LyricWord(id:"w",text:"Glow",range:.init(0,4))
        let line = LyricLine(id:"l",range:.init(0,4),words:[word],isWordTimed:true)
        let config = LyricsConfiguration()
        let layout = TextLayoutEngine().group(PreparedGroup(source:.init(main:line),main:line,background:nil),width:760,config:config,dynamic:true,hasDuet:false).main
        let layers = LineLayers(layout,cache:GlyphCache(),scale:2,config:config,previous:nil,now:0)
        layers.update(now:0,media:2,floatTime:2,active:true,alpha:1,background:false,config:config,seek:true)
        layers.update(now:1,media:2,floatTime:2,active:false,alpha:1,background:false,config:config)
        let glyph = layers.words[0].glyphs[0], start = layers.words[0].glyphs[0].highlightOpacity
        layers.update(now:1.01,media:2.01,floatTime:2.01,active:false,alpha:1,background:false,config:config)
        XCTAssertLessThan(glyph.highlightOpacity,start)
        layers.update(now:1.29,media:4,floatTime:4,active:false,alpha:0.5,background:false,config:config)
        XCTAssertEqual(glyph.highlightOpacity,0,accuracy:0.00001)
    }

    func testEmphasisGlowUsesTintedGlyphSourceAndBlurFilter() {
        let word = LyricWord(id:"w",text:"Soooo",range:.init(0,5))
        let line = LyricLine(id:"l",range:.init(0,5),words:[word],isWordTimed:true)
        var config = LyricsConfiguration()
        config.palette.emphasisGlow = LyricsColor(0.2,0.8,0.6)
        let layout = TextLayoutEngine().group(PreparedGroup(source:.init(main:line),main:line,background:nil),width:760,config:config,dynamic:true,hasDuet:false).main
        let layers = LineLayers(layout,cache:GlyphCache(),scale:2,config:config,previous:nil,now:0)
        layers.update(now:1,media:1,floatTime:1,active:true,alpha:1,background:false,config:config,seek:true)
        let glyph = try! XCTUnwrap(layers.words.first?.glyphs.first)
        let names = glyph.glow.filters?.compactMap { ($0 as? CIFilter)?.name } ?? []
        XCTAssertTrue(names.contains("CIColorMonochrome"))
        XCTAssertTrue(names.contains("CIGaussianBlur"))
        XCTAssertNil(glyph.glow.mask)
    }

}

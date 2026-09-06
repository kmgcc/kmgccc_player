import AppKit
import XCTest
@testable import NativeLyrics

final class LayoutTests: XCTestCase {
    func testMaskDwellsBetweenWordsAndReachesEnd() {
        let a = LyricWord(id:"a",text:"Alpha",range:.init(1,2)), b = LyricWord(id:"b",text:"Beta",range:.init(4,5))
        let placements = [a,b].map { WordPlacement(atom:TextAtom(word:$0),rect:.zero,pieces:[],width:100,fontSize:40,fadeHeight:48) }
        let path = MaskPath(placements,fadeWidth:20)
        XCTAssertEqual(path.position(at:0),-40)
        XCTAssertEqual(path.position(at:2),90)
        XCTAssertEqual(path.position(at:3),90)
        XCTAssertEqual(path.position(at:5),200)
        XCTAssertEqual(path.position(at:4.5),145)
    }
    func testTimedRubyControlsBaseSweep() {
        let word = LyricWord(id:"a",text:"星空",range:.init(1,5),ruby:[.init(text:"ほし",range:.init(1,2)),.init(text:"ぞら",range:.init(4,5))])
        let path = MaskPath([WordPlacement(atom:TextAtom(word:word),rect:.zero,pieces:[],width:100,fontSize:40,fadeHeight:48)],fadeWidth:10)
        XCTAssertEqual(path.position(at:2),45); XCTAssertEqual(path.position(at:3),45); XCTAssertEqual(path.position(at:5),100)
    }
    @MainActor func testResizeDoesNotResetTimelineOrJumpGroupPosition() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        try view.load(ttml:Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='1s' end='12s'><span begin='0s' end='4s'>Watch </span><span begin='4s' end='11s'>the stars moving across the sky</span></p></div></body></tt>".utf8),playing:true,hostTime:0)
        for i in 0...600 { view.render(at:Double(i)/120) }
        let before = view.render(at:5)
        view.setFrameSize(NSSize(width:390,height:600))
        let after = view.render(at:5)
        XCTAssertEqual(after.timeline,before.timeline)
        XCTAssertEqual(after.groups[0].y,before.groups[0].y,accuracy:0.001)
        XCTAssertGreaterThan(after.layoutCount,before.layoutCount)
        let steady = view.render(at:5.1); XCTAssertEqual(steady.layoutCount,after.layoutCount)
    }
    @MainActor func testResizeUsesGentleReflowForWrappedLine() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        try view.load(ttml:Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='1s' end='12s'><span begin='0s' end='11s'>Watch the stars moving across the sky tonight</span></p><p begin='12s' end='20s'>Next line</p></div></body></tt>".utf8),playing:true,hostTime:0)
        for i in 0...600 { _ = view.render(at:Double(i)/120) }
        let before = view.render(at:5)
        view.setFrameSize(NSSize(width:390,height:600))
        let atResize = view.render(at:5)
        let first = view.render(at:5.08)
        let second = view.render(at:5.18)
        let target = view.render(at:7).groups[0].y
        XCTAssertEqual(atResize.groups[0].y,before.groups[0].y,accuracy:0.001)
        if target < atResize.groups[0].y {
            XCTAssertLessThan(first.groups[0].y,atResize.groups[0].y)
            XCTAssertLessThan(second.groups[0].y,first.groups[0].y)
            XCTAssertGreaterThanOrEqual(second.groups[0].y,target-0.01)
        } else {
            XCTAssertGreaterThan(first.groups[0].y,atResize.groups[0].y)
            XCTAssertGreaterThan(second.groups[0].y,first.groups[0].y)
            XCTAssertLessThanOrEqual(second.groups[0].y,target+0.01)
        }
    }
    @MainActor func testInvalidReloadPreservesSurface() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        let valid = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='1s' end='3s'>Keep me</p></div></body></tt>".utf8)
        try view.load(ttml:valid,hostTime:0)
        let before = view.document
        XCTAssertThrowsError(try view.load(ttml:Data("bad xml".utf8)))
        XCTAssertEqual(view.document,before)
    }
    @MainActor func testClickUsesSourceNotVisualAdvance() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.trackOffset = 0.5
        view.configuration.timing.seekOffset = 0.5
        view.configuration.timing.globalAdvance = 0.2
        try view.load(ttml:Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='5s' end='8s'>Seek here</p></div></body></tt>".utf8),hostTime:0)
        XCTAssertEqual(view.seekTime(forGroup:0),5.5)
    }

    func testCoverBlurRenderLayersSelectChannels() {
        let word = LyricWord(id:"word",text:"Highlight",range:.init(0,2))
        let line = LyricLine(id:"line",range:.init(0,2),words:[word],isWordTimed:true)
        let group = PreparedGroup(source:.init(main:line),main:line,background:nil)
        let configBase = LyricsConfiguration()
        let layout = TextLayoutEngine().group(group,width:760,config:configBase,dynamic:true,hasDuet:false).main
        let cache = GlyphCache(); cache.budget = 8*1024*1024
        let now = 1.5

        func opacities(_ layer: LyricsRenderLayer, hideActive: Bool = false) -> (Float,Float) {
            var config = configBase
            config.surface = .coverBlurLight; config.coverBlurRenderLayer = layer; config.coverBlurHideActiveMainLine = hideActive
            let lines = LineLayers(layout,cache:cache,scale:2,config:config,previous:nil,now:0)
            lines.update(now:0,media:0,floatTime:0,active:true,alpha:1,background:false,config:config)
            lines.update(now:now,media:1.5,floatTime:1.5,active:true,alpha:1,background:false,config:config)
            let glyph = lines.words.first!.glyphs.first!
            return (Float(glyph.baseOpacity),Float(glyph.highlightOpacity))
        }

        let full = opacities(.full)
        XCTAssertGreaterThan(full.0,0); XCTAssertGreaterThan(full.1,0)
        let base = opacities(.base)
        XCTAssertGreaterThan(base.0,0); XCTAssertEqual(base.1,0)
        let highlight = opacities(.highlight)
        XCTAssertEqual(highlight.0,0); XCTAssertGreaterThan(highlight.1,0)
        let hidden = opacities(.full,hideActive:true)
        XCTAssertEqual(hidden.0,0); XCTAssertEqual(hidden.1,0)
    }

    func testGenericCoverDoesNotLeakIntoWindowSurface() {
        var config = LyricsConfiguration()
        config.coverBlurGenericMode = true
        config.coverBlurRenderLayer = .highlight
        config.surface = .window
        XCTAssertFalse(config.usesCoverBlurCompositing)
        XCTAssertEqual(config.effectiveRenderLayer,.full)
        config.surface = .appleStyle
        XCTAssertTrue(config.usesCoverBlurCompositing)
        XCTAssertEqual(config.effectiveRenderLayer,.highlight)
    }

    @MainActor func testNoPerFrameTextLayoutAndBoundedGlyphCache() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.cacheBudgetBytes = 1024*1024
        try view.load(ttml:Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='1s' end='8s'><span begin='0s' end='7s'>天空 👩🏽‍🚀 é ffi</span></p></div></body></tt>".utf8),playing:true,hostTime:0)
        let count = view.lastFrame!.layoutCount
        for i in 0...600 { let frame = view.render(at:Double(i)/120); XCTAssertEqual(frame.layoutCount,count); XCTAssertLessThanOrEqual(frame.glyphCacheBytes,1024*1024) }
    }
}

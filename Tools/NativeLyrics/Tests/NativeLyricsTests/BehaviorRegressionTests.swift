import AppKit
import XCTest
@testable import NativeLyrics

final class BehaviorRegressionTests: XCTestCase {
    private let fixture = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='3s'><span begin='0s' end='3s'>First</span></p><p begin='3s' end='6s'><span begin='3s' end='6s'>Second</span></p><p begin='6s' end='9s'><span begin='6s' end='9s'>Third</span></p><p begin='9s' end='12s'><span begin='9s' end='12s'>Fourth</span></p></div></body></tt>".utf8)

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

    @MainActor func testAllParallelRowsStaySharpWhenTTMLRangesOverlap() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='4s'><span begin='0s' end='4s'>Main</span></p><p begin='2s' end='6s'><span begin='2s' end='6s'>Background</span></p><p begin='4.5s' end='7.5s'><span begin='4.5s' end='7.5s'>Next</span></p></div></body></tt>".utf8)
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:data,playing:true,hostTime:0)
        let frame = view.render(at:3)
        XCTAssertEqual(frame.timeline.focus,0)
        XCTAssertEqual(frame.groups[0].blur,0,accuracy:0.001)
        // Blur transitions are intentionally eased; once the overlap has
        // settled, every concurrently highlighted row is sharp.
        let settled = view.render(at:3.6)
        XCTAssertEqual(settled.groups[0].blur,0,accuracy:0.001)
        XCTAssertEqual(settled.groups[1].blur,0,accuracy:0.001)
        view.render(at:4)
        view.render(at:5.8)
        let next = view.render(at:6.4)
        XCTAssertEqual(next.timeline.focus,1)
        XCTAssertEqual(next.timeline.highlighted,[1,2])
        XCTAssertGreaterThan(next.groups[0].blur,2)
        XCTAssertEqual(next.groups[1].blur,0,accuracy:0.001)
        XCTAssertEqual(next.groups[2].blur,0,accuracy:0.001)
        // A completed middle row is still AMLL-buffered while the long main
        // row and the next duet row overlap. It must retain the active scale
        // instead of shrinking as soon as its own range ends.
        XCTAssertEqual(next.groups[1].scale,1,accuracy:0.001)
    }

    @MainActor func testExpiredFocusBlursDuringAnInterlude() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='2s'><span begin='0s' end='2s'>First</span></p><p begin='4s' end='6s'><span begin='4s' end='6s'>Second</span></p></div></body></tt>".utf8)
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

    @MainActor func testInterludeKeepsPreviousRowInPlaceAndCentersDots() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='2s'>阖上眼我就是自由灵魂</p><p begin='8s' end='10s'>就闭上眼 当我</p></div></body></tt>".utf8)
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.spring = false
        view.configuration.blur = false
        try view.load(ttml:data,playing:true,hostTime:0)

        let beforeGap = view.render(at:1.9)
        let inGap = view.render(at:3.0)
        guard let dots = inGap.interlude else {
            return XCTFail("Expected a visible interlude frame")
        }
        XCTAssertEqual(inGap.timeline.interlude?.anchor,0)
        // Inserting the marker must not apply the old AMLL global-origin
        // subtraction, which lifted the completed line at gap entrance.
        XCTAssertEqual(inGap.groups[0].y,beforeGap.groups[0].y,accuracy:0.001)
        let previousBottom = inGap.groups[0].y + inGap.groups[0].height
        let markerMargin = view.configuration.fontSize * 0.4
        let markerHeight = view.configuration.fontSize
        XCTAssertEqual(
            dots.y,
            previousBottom + markerMargin + markerHeight / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            inGap.groups[1].y,
            dots.y + markerHeight / 2 + markerMargin,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(dots.opacity,0)
        XCTAssertEqual(dots.walk.count,3)
        XCTAssertGreaterThanOrEqual(dots.walk[0],dots.walk[1])
        XCTAssertGreaterThanOrEqual(dots.walk[1],dots.walk[2])
    }

    @MainActor func testInterludeEntranceDoesNotRestartAfterBackwardPlaybackSample() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='8s' end='10s'>First</p><p begin='15s' end='17s'>Second</p></div></body></tt>".utf8)
        let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.spring = false
        view.configuration.blur = false
        try view.load(ttml: data, time: 0, playing: true, hostTime: 0)

        let progressed = view.render(at: 2.0)
        let progressedDots = try XCTUnwrap(progressed.interlude)

        // A stale presentation callback can rebase the lyric clock backwards
        // while the same authored gap is still active. The marker must keep
        // its AMLL-style monotonic progress instead of running scale-in again.
        view.synchronize(time: 0.5, playing: true, seek: false, hostTime: 2.1)
        let afterBacktrack = try XCTUnwrap(view.render(at: 2.2).interlude)
        XCTAssertGreaterThanOrEqual(afterBacktrack.opacity, progressedDots.opacity - 0.001)
        XCTAssertGreaterThanOrEqual(afterBacktrack.walk[0], progressedDots.walk[0] - 0.001)
        XCTAssertGreaterThanOrEqual(afterBacktrack.walk[1], progressedDots.walk[1] - 0.001)
        XCTAssertGreaterThanOrEqual(afterBacktrack.walk[2], progressedDots.walk[2] - 0.001)
    }

    @MainActor func testIntroInterludeUsesFixedMarkerGapAndPushesFirstRowDown() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='8s' end='10s'>First</p><p begin='15s' end='17s'>Second</p></div></body></tt>".utf8)
        let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.spring = false
        view.configuration.blur = false
        try view.load(ttml: data, time: 0, playing: true, hostTime: 0)

        let intro = view.render(at: 2)
        let dots = try XCTUnwrap(intro.interlude)
        let activeAnchor = view.bounds.height * view.configuration.alignPosition
            - view.configuration.alignOffset
        XCTAssertEqual(dots.anchor, -1)
        XCTAssertEqual(dots.y, activeAnchor, accuracy: 0.001)

        let markerHeight = view.configuration.fontSize
        let markerMargin = markerHeight * 0.4
        XCTAssertEqual(
            intro.groups[0].y,
            dots.y + markerHeight / 2 + markerMargin,
            accuracy: 0.001
        )

        let playing = view.render(at: 8.1)
        XCTAssertNil(playing.interlude)
        let playingCenter = playing.groups[0].y + playing.groups[0].height / 2
        XCTAssertEqual(playingCenter, activeAnchor, accuracy: 0.001)
        XCTAssertLessThan(playing.groups[0].y, intro.groups[0].y)
    }

    @MainActor func testIntroInterludeMarkerUsesTheFocusedRowCenterForEveryAnchor() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='8s' end='10s'>First</p><p begin='15s' end='17s'>Second</p></div></body></tt>".utf8)
        for anchor in [LyricAlignment.top, .center, .bottom] {
            let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
            view.automaticDisplayUpdates = false
            view.configuration.timing.enabled = false
            view.configuration.spring = false
            view.configuration.blur = false
            view.configuration.alignAnchor = anchor
            try view.load(ttml: data, time: 0, playing: true, hostTime: 0)

            let frame = view.render(at: 2)
            let dots = try XCTUnwrap(frame.interlude)
            let activeAnchor = view.bounds.height * view.configuration.alignPosition
                - view.configuration.alignOffset
            let first = frame.groups[0]
            let expectedMarker = switch anchor {
            case .top: activeAnchor + first.height / 2
            case .center: activeAnchor
            case .bottom: activeAnchor - first.height / 2
            }
            XCTAssertEqual(dots.y, expectedMarker, accuracy: 0.001)
            XCTAssertEqual(
                first.y,
                dots.y + view.configuration.fontSize / 2
                    + view.configuration.fontSize * 0.4,
                accuracy: 0.001
            )
        }
    }

    @MainActor func testLoadEntryContinuesIndependentlyWhenIntroInterludeIsVisible() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='8s' end='10s'>First</p><p begin='15s' end='17s'>Second</p></div></body></tt>".utf8)
        let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.blur = false
        try view.load(ttml: data, time: 0, playing: true, hostTime: 0)

        let start = view.render(at: 0)
        let moving = view.render(at: 0.15)
        let later = view.render(at: 0.6)
        XCTAssertNotNil(start.interlude)
        XCTAssertNotNil(later.interlude)
        XCTAssertLessThan(moving.groups[0].y, start.groups[0].y)
        XCTAssertLessThan(later.groups[0].y, moving.groups[0].y)
        XCTAssertGreaterThan(later.interlude?.opacity ?? 0, start.interlude?.opacity ?? 0)
    }

    @MainActor func testLoadAndWakeEntryAnimationsUseSeparateStates() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='20s'>First</p><p begin='20s' end='40s'>Second</p><p begin='40s' end='60s'>Third</p></div></body></tt>".utf8)
        let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.blur = false
        try view.load(ttml: data, time: 0, playing: true, hostTime: 0)

        let loadStart = view.render(at: 0)
        let loadMoving = view.render(at: 0.15)
        XCTAssertLessThan(loadMoving.groups[0].y, loadStart.groups[0].y)
        XCTAssertGreaterThan(loadMoving.groups[0].scale, loadStart.groups[0].scale)

        let settled = view.render(at: 5)
        view.prepareWakeEntryAnimation()
        let gathered = view.render(at: 5.01)
        XCTAssertEqual(gathered.groups[0].y, settled.groups[0].y, accuracy: 0.001)
        XCTAssertGreaterThan(gathered.groups[1].y, settled.groups[1].y)
        XCTAssertGreaterThan(gathered.groups[2].y, settled.groups[2].y)

        let closing = view.render(at: 5.35)
        XCTAssertLessThan(closing.groups[1].y, gathered.groups[1].y)
        XCTAssertLessThan(closing.groups[2].y, gathered.groups[2].y)
    }

    @MainActor func testLoadEntryUsesUnderdampedPositionAndSurvivesInitialRebase() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='20s'>First</p><p begin='20s' end='40s'>Second</p></div></body></tt>".utf8)

        let animated = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        animated.automaticDisplayUpdates = false
        animated.configuration.timing.enabled = false
        animated.configuration.blur = false
        try animated.load(ttml: data, time: 0, playing: true, hostTime: 0)

        _ = animated.render(at: 0)
        let entrySamples = stride(from: 0.15, through: 1.5, by: 0.05).map {
            animated.render(at: $0).groups[0].y
        }

        let reference = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        reference.automaticDisplayUpdates = false
        reference.configuration.timing.enabled = false
        reference.configuration.blur = false
        try reference.load(ttml: data, time: 0, playing: true, hostTime: 0)
        let targetY = reference.render(at: 5).groups[0].y
        XCTAssertLessThan(entrySamples.min() ?? .infinity, targetY - 0.01)

        animated.synchronize(time: 0, playing: true, seek: true, motion: .immediate, hostTime: 0)
        let afterInitialRebase = animated.render(at: 0.15).groups[0].y
        XCTAssertGreaterThan(afterInitialRebase, targetY + 0.01)
    }

    @MainActor func testLoadEntrySurvivesPausedTrackHandoff() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='20s'>First</p><p begin='20s' end='40s'>Second</p></div></body></tt>".utf8)
        let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.blur = false
        // A real track switch can deliver the new document while transport is
        // briefly paused. The entrance must remain armed until playback state
        // settles instead of snapping to its final position.
        try view.load(ttml: data, time: 0, playing: false, hostTime: 0)
        let start = view.render(at: 0)
        let moving = view.render(at: 0.15)
        XCTAssertLessThan(moving.groups[0].y, start.groups[0].y)
        XCTAssertGreaterThan(moving.groups[0].scale, start.groups[0].scale)
    }

    @MainActor func testLoadEntrySurvivesDiscontinuousTransportReconciliation() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='0s' end='20s'>First</p><p begin='20s' end='40s'>Second</p></div></body></tt>".utf8)
        let view = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.blur = false
        view.configuration.positionSpring = .positionOverride(duration: 0.55, bounce: 0.75)
        try view.load(ttml: data, time: 0, playing: false, hostTime: 0)

        let start = view.render(at: 0)
        // A real track handoff can publish a new media position that is far
        // from the load-time clock before the first display frames arrive.
        // That transport rebase must not cancel the independent entry spring.
        view.synchronize(time: 5, playing: true, seek: true, hostTime: 0.05)
        let moving = view.render(at: 0.15)
        XCTAssertLessThan(moving.groups[0].y, start.groups[0].y)

        let reference = LyricsView(frame: NSRect(x: 0, y: 0, width: 760, height: 720))
        reference.automaticDisplayUpdates = false
        reference.configuration.timing.enabled = false
        reference.configuration.spring = false
        reference.configuration.blur = false
        try reference.load(ttml: data, time: 5, playing: false, hostTime: 5)
        let targetY = reference.render(at: 5).groups[0].y
        XCTAssertGreaterThan(moving.groups[0].y, targetY + 0.01)
    }

    func testLineTimedWindowDoesNotDoubleApplyInactiveOpacity() throws {
        // A line-timed LRC/TTML document keeps an opaque glyph channel in the
        // window surface. Applying the normal karaoke inactive alpha as well
        // would make the whole track appear abnormally pale.
        let word = LyricWord(id:"line-0",text:"Blessing",range:.init(0,4))
        let line = LyricLine(id:"line",range:.init(0,4),words:[word],isWordTimed:false)
        var config = LyricsConfiguration()
        config.surface = .window
        let prepared = PreparedGroup(source:.init(main:line),main:line,background:nil)
        let layout = TextLayoutEngine().group(prepared,width:760,config:config,dynamic:false,hasDuet:false).main
        let layers = LineLayers(layout,cache:GlyphCache(),scale:2,config:config,previous:nil,now:0)

        layers.update(now:0,media:1,floatTime:1,active:false,alpha:0,background:false,config:config,seek:true)
        let glyph = try XCTUnwrap(layers.words.first?.glyphs.first)
        XCTAssertEqual(glyph.baseOpacity,1,accuracy:0.0001)
        XCTAssertEqual(glyph.highlightOpacity,0,accuracy:0.0001)
    }

    func testDiscreteHighlightPinsEachWordToAUniformMask() throws {
        let words = [
            LyricWord(id: "first", text: "First", range: .init(0, 1)),
            LyricWord(id: "second", text: "Second", range: .init(1, 2))
        ]
        let line = LyricLine(id: "line", range: .init(0, 2), words: words, isWordTimed: true)
        var config = LyricsConfiguration()
        config.highlightMode = .discrete
        config.fullscreenLyricDodgeMode = true
        let prepared = PreparedGroup(source: .init(main: line), main: line, background: nil)
        let layout = TextLayoutEngine().group(prepared, width: 760, config: config, dynamic: true, hasDuet: false).main
        let layers = LineLayers(layout, cache: GlyphCache(), scale: 2, config: config, previous: nil, now: 0)

        layers.update(now: 0.35, media: 0.35, floatTime: 0.35, active: true, alpha: 1, background: false, config: config)

        // A discrete word is composed with one opacity value. Its gradient
        // boundary is pushed beyond the glyph instead of sweeping through it.
        for word in layers.words {
            let glyph = try XCTUnwrap(word.glyphs.first)
            XCTAssertGreaterThan(glyph.gradient.endPoint.x, 0.99)
        }
    }

    func testDiscreteHighlightUsesPerWordOpacityOnWindowAndFullscreenSurfaces() throws {
        let words = [
            LyricWord(id: "first", text: "First", range: .init(0, 1)),
            LyricWord(id: "second", text: "Second", range: .init(1, 2))
        ]
        let line = LyricLine(id: "line", range: .init(0, 2), words: words, isWordTimed: true)
        let prepared = PreparedGroup(source: .init(main: line), main: line, background: nil)

        for fullscreen in [false, true] {
            var config = LyricsConfiguration()
            config.highlightMode = .discrete
            config.fullscreenLyricDodgeMode = fullscreen
            let layout = TextLayoutEngine().group(
                prepared,
                width: 760,
                config: config,
                dynamic: true,
                hasDuet: false
            ).main
            let layers = LineLayers(layout, cache: GlyphCache(), scale: 2, config: config, previous: nil, now: 0)

            // Establish the line highlight, then sample after its short line
            // transition has settled so the assertion isolates word timing.
            layers.update(now: 0, media: 0, floatTime: 0, active: true, alpha: 1, background: false, config: config)
            layers.update(now: 0.5, media: 0.5, floatTime: 0.5, active: true, alpha: 1, background: false, config: config)

            let opacities = try layers.words.map { word in
                let glyph = try XCTUnwrap(word.glyphs.first)
                return glyph.baseOpacity + glyph.highlightOpacity
            }
            XCTAssertGreaterThan(opacities[0], opacities[1] + 0.05)
            if fullscreen {
                XCTAssertEqual(opacities[1], 0.28, accuracy: 0.0001)
            } else {
                XCTAssertEqual(opacities[1], 0.28, accuracy: 0.0001)
            }
        }
    }

    func testDiscreteHighlightAlsoAppliesToLineTimedRows() throws {
        let word = LyricWord(id: "line", text: "Line timed", range: .init(0, 2))
        let line = LyricLine(id: "line", range: .init(0, 2), words: [word], isWordTimed: false)
        var config = LyricsConfiguration()
        config.highlightMode = .discrete
        config.fullscreenLyricDodgeMode = true
        let layout = TextLayoutEngine().group(
            PreparedGroup(source: .init(main: line), main: line, background: nil),
            width: 760,
            config: config,
            dynamic: false,
            hasDuet: false
        ).main
        let layers = LineLayers(layout, cache: GlyphCache(), scale: 2, config: config, previous: nil, now: 0)

        layers.update(now: 0, media: 0, floatTime: 0, active: true, alpha: 1, background: false, config: config)
        layers.update(now: 0.5, media: 0.5, floatTime: 0.5, active: true, alpha: 1, background: false, config: config)
        let glyph = try XCTUnwrap(layers.words.first?.glyphs.first)
        XCTAssertGreaterThan(glyph.gradient.endPoint.x, 0.99)
        XCTAssertGreaterThan(glyph.baseOpacity + glyph.highlightOpacity, 0.28)
    }

    func testLineTimedRowsKeepTheirWordFloatWhenHighlightIsSmooth() throws {
        let word = LyricWord(id: "line", text: "Line timed", range: .init(0, 2))
        let line = LyricLine(id: "line", range: .init(0, 2), words: [word], isWordTimed: false)
        let config = LyricsConfiguration()
        let layout = TextLayoutEngine().group(
            PreparedGroup(source: .init(main: line), main: line, background: nil),
            width: 760,
            config: config,
            dynamic: false,
            hasDuet: false
        ).main
        let layers = LineLayers(layout, cache: GlyphCache(), scale: 2, config: config, previous: nil, now: 0)

        layers.update(now: 0, media: 0, floatTime: 0, active: true, alpha: 1, background: false, config: config, seek: true)
        let start = try XCTUnwrap(layers.words.first?.glyphs.first).root.position.y
        layers.update(now: 0.5, media: 0.5, floatTime: 0.5, active: true, alpha: 1, background: false, config: config)
        let moving = try XCTUnwrap(layers.words.first?.glyphs.first).root.position.y
        XCTAssertLessThan(moving, start)

        // The ordinary, non-emphasis float must use the same line fall and
        // return to the exact baseline after the slow descent completes.
        layers.update(now: 4.5, media: 4.5, floatTime: 4.5, active: true, alpha: 1, background: false, config: config)
        let settled = try XCTUnwrap(layers.words.first?.glyphs.first).root.position.y
        XCTAssertEqual(settled, start, accuracy: 0.0001)
    }

    func testDiscreteHighlightKeepsEmphasisFloatAndGlow() throws {
        let word = LyricWord(id: "word", text: "Soooo", range: .init(0, 4))
        let line = LyricLine(id: "line", range: .init(0, 4), words: [word], isWordTimed: true)
        let prepared = PreparedGroup(source: .init(main: line), main: line, background: nil)

        func sample(_ mode: HighlightMode) throws -> (CGPoint, Float) {
            var config = LyricsConfiguration()
            config.highlightMode = mode
            let layout = TextLayoutEngine().group(
                prepared,
                width: 760,
                config: config,
                dynamic: true,
                hasDuet: false
            ).main
            let layers = LineLayers(
                layout,
                cache: GlyphCache(),
                scale: 2,
                config: config,
                previous: nil,
                now: 0
            )
            layers.update(
                now: 0,
                media: 1,
                floatTime: 1,
                active: true,
                alpha: 1,
                background: false,
                config: config
            )
            layers.update(
                now: 1,
                media: 2,
                floatTime: 2,
                active: true,
                alpha: 1,
                background: false,
                config: config
            )
            let glyph = try XCTUnwrap(layers.words.first?.glyphs.first)
            return (glyph.root.position, glyph.glow.opacity)
        }

        let smooth = try sample(.smooth)
        let discrete = try sample(.discrete)
        XCTAssertEqual(discrete.0.y, smooth.0.y, accuracy: 0.001)
        XCTAssertEqual(discrete.1, smooth.1, accuracy: 0.001)
        XCTAssertGreaterThan(discrete.1, 0)
    }

    @MainActor func testFullscreenLineTimedRowsStayOpaqueAndCanBlur() throws {
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml'><body><div><p begin='2s' end='4s'>First</p><p begin='6s' end='8s'>Second</p></div></body></tt>".utf8)
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        view.configuration.fullscreenLyricDodgeMode = true
        try view.load(ttml:data,playing:true,hostTime:0)

        _ = view.render(at:0)
        let frame = view.render(at:0.3)
        XCTAssertTrue(view.configuration.usesOpaqueCompositing)
        XCTAssertTrue(frame.groups.allSatisfy { $0.opacity >= 0.999 })
        XCTAssertGreaterThan(frame.groups[0].blur,0)
        XCTAssertGreaterThan(frame.groups[1].blur,0)
    }

    @MainActor func testScrubPreviewScrollsTheWholeStackWithoutBlur() throws {
        let view = LyricsView(frame:NSRect(x:0,y:0,width:760,height:720)); view.automaticDisplayUpdates = false
        view.configuration.timing.enabled = false
        try view.load(ttml:fixture,hostTime:0)
        view.synchronize(time:9.1,playing:false,seek:true,motion:.preview,hostTime:1)
        let start = view.render(at:1)
        let moving = view.render(at:1.02)
        XCTAssertLessThan(moving.groups[0].y,start.groups[0].y)
        XCTAssertNotEqual(moving.groups[3].y,start.groups[3].y,accuracy:0.001)
        XCTAssertTrue(moving.groups.allSatisfy { $0.blur < 0.001 })
        view.synchronize(time:3.1,playing:false,seek:true,motion:.preview,hostTime:1.03)
        let scrub = view.render(at:1.03), later = view.render(at:1.08)
        for i in scrub.groups.indices {
            XCTAssertNotEqual(scrub.groups[i].y,later.groups[i].y,accuracy:0.001)
            XCTAssertLessThan(scrub.groups[i].blur,0.001)
        }
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
        let data = Data("<tt xmlns='http://www.w3.org/ns/ttml' xmlns:ttm='http://www.w3.org/ns/ttml#metadata'><body><div><p begin='1s' end='4s'><span begin='1s' end='4s'>Main</span><span ttm:role='x-bg' begin='1s' end='4s'>Background</span></p></div></body></tt>".utf8)
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
        let stillBrowsing = view.render(at:3)
        XCTAssertFalse(stillBrowsing.following)
        for i in stillBrowsing.groups.indices { XCTAssertEqual(stillBrowsing.groups[i].y,before.groups[i].y,accuracy:0.02) }
        view.setPointerInside(false,hostTime:3)
        XCTAssertFalse(view.render(at:7.99).following)
        let start = view.render(at:8)
        XCTAssertTrue(start.following)
        for i in start.groups.indices { XCTAssertEqual(start.groups[i].y,before.groups[i].y,accuracy:0.02) }
        let moving = view.render(at:8.03)
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

    func testHighlightSmootherNeverAddsSyntheticLeadOrLag() {
        var smoother = HighlightSmoother()
        XCTAssertEqual(smoother.sample(target:0,now:0,playing:false,reset:true,fadeWidth:48),0)
        XCTAssertEqual(smoother.sample(target:100,now:0.1,playing:true,reset:false,fadeWidth:48),100,accuracy:0.001)
        let before = smoother.value
        let duringStall = smoother.sample(target:100,now:0.2,playing:true,reset:false,fadeWidth:48)
        XCTAssertEqual(duringStall,before,accuracy:0.001)
        XCTAssertEqual(smoother.sample(target:80,now:0.3,playing:false,reset:false,fadeWidth:48),80,accuracy:0.001)
        let resumed = smoother.sample(target:80,now:1,playing:true,reset:false,fadeWidth:48)
        XCTAssertEqual(resumed,80,accuracy:0.001)
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

    func testLineExitLetsEmphasisFloatDescendIndependentlyFromHighlightFade() throws {
        let word = LyricWord(id:"w",text:"Soooo",range:.init(0,2))
        let line = LyricLine(id:"l",range:.init(0,8),words:[word],isWordTimed:true)
        let config = LyricsConfiguration()
        let layout = TextLayoutEngine().group(
            PreparedGroup(source:.init(main:line),main:line,background:nil),
            width:760,
            config:config,
            dynamic:true,
            hasDuet:false
        ).main
        let layers = LineLayers(layout,cache:GlyphCache(),scale:2,config:config,previous:nil,now:0)

        // Establish the word's upward float before the line leaves.
        layers.update(now:0,media:1,floatTime:1,active:true,alpha:1,background:false,config:config,seek:true)

        // The exit sample keeps the emphasized word at its apex while the
        // line fade begins. Later host-time samples must move it down slowly;
        // they must not use the accelerated mask media time as the float
        // clock.
        layers.update(now:1,media:1.5,floatTime:1.5,active:false,alpha:1,background:false,config:config)
        let exitY = try XCTUnwrap(layers.words.first?.glyphs.first).root.position.y
        layers.update(now:1.25,media:1.75,floatTime:1.25,active:false,alpha:1,background:false,config:config)
        let duringFadeY = try XCTUnwrap(layers.words.first?.glyphs.first).root.position.y
        layers.update(now:3.5,media:3.5,floatTime:-0.5,active:false,alpha:1,background:false,config:config)
        let lateY = try XCTUnwrap(layers.words.first?.glyphs.first).root.position.y

        XCTAssertGreaterThan(duringFadeY,exitY)
        XCTAssertGreaterThan(lateY,duringFadeY)
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
        XCTAssertEqual((glyph.glow.compositingFilter as? CIFilter)?.name, "CIAdditionCompositing")
    }

}

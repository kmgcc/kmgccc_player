import AppKit
import QuartzCore
import CoreImage

public struct LyricsGroupFrame: Codable, Sendable {
    public var index: Int
    public var y: Double
    public var height: Double
    public var scale: Double
    public var backgroundScale: Double
    public var backgroundSlide: Double
    public var opacity: Double
    public var blur: Double
    public var active: Bool
    public var maskPosition: Double
}

/// Deterministic presentation state for the three-dot interlude marker.
/// Keeping the geometry in the frame lets the native surface be verified
/// without reaching into its private CALayer tree.
public struct LyricsInterludeFrame: Codable, Sendable, Equatable {
    public var anchor: Int
    public var range: LyricRange
    /// Unscaled layer leading edge. The renderer compensates for the centered
    /// transform so this edge meets the lyric leading edge at peak breathing.
    public var x: Double
    /// Unscaled layer center y, halfway between adjacent lyric rows.
    public var y: Double
    public var width: Double
    public var height: Double
    public var scale: Double
    public var opacity: Double
    public var walk: [Double]
}

public struct LyricsFrame: Codable, Sendable {
    public var timeline: LyricsTimelineSnapshot
    public var groups: [LyricsGroupFrame]
    public var interlude: LyricsInterludeFrame?
    public var following: Bool
    public var glyphCacheBytes: Int
    public var glyphCacheMisses: Int
    public var layoutCount: Int
    public var renderMilliseconds: Double
}

@MainActor private final class DisplayTarget: NSObject {
    weak var view: LyricsView?
    @objc func tick(_ link: CADisplayLink) { view?.displayTick() }
}

/// A reusable TTML-only, layer-backed native surface. The host owns playback and seek.
@MainActor public final class LyricsView: NSView {
    public var configuration = LyricsConfiguration() {
        didSet {
            guard configuration != oldValue else { return }
            if configuration.timing != oldValue.timing || configuration.profile != oldValue.profile || configuration.preserveCompletedHighlight != oldValue.preserveCompletedHighlight { rebuildTimeline() }
            let c = configuration, o = oldValue
            if c.fontName != o.fontName || c.fontNameCJK != o.fontNameCJK || c.fontSize != o.fontSize || c.fontWeight != o.fontWeight
                || c.translationFontName != o.translationFontName || c.translationFontSize != o.translationFontSize
                || c.translationFontWeight != o.translationFontWeight || c.showTranslation != o.showTranslation
                || c.showRuby != o.showRuby || c.showRomanization != o.showRomanization
                || c.translationLanguage != o.translationLanguage || c.romanizationLanguage != o.romanizationLanguage
                || c.surface != o.surface || c.emphasis != o.emphasis || c.obscenity != o.obscenity
                || c.maskCharacter != o.maskCharacter || c.wordFadeWidth != o.wordFadeWidth { layoutDirty = true }
            wake()
        }
    }
    public var onSeek: ((Double)->Void)?
    public var onFrame: ((LyricsFrame)->Void)?
    public private(set) var document: LyricsDocument?
    public private(set) var lastFrame: LyricsFrame?
    public var automaticDisplayUpdates = true { didSet { wake() } }
    /// Whether a window-backed display loop is currently installed.
    /// Hosts can use this to verify that a visible surface actually advances
    /// between sparse playback snapshots without exposing the display link.
    public var isDisplayUpdateRunning: Bool { displayLink != nil }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public var isFollowing: Bool { !interaction.suspended }
    public var diagnosticTimings: [LyricGroup] { prepared.map { LyricGroup(main:$0.main,background:$0.background) } }

    private var prepared: [PreparedGroup] = []
    private var timeline = LyricsTimeline(bounds:[],profile:.currentPlayer)
    private var clock = LyricsClock()
    private var interaction = LyricsInteraction()
    private let layoutEngine = TextLayoutEngine(), cache = GlyphCache()
    private let imageContext = CIContext(options:[.cacheIntermediates:false])
    private var groups: [GroupLayers] = []
    private let content = CALayer(), dots = CALayer(), bottom = CATextLayer()
    private var dotLayers: [CALayer] = []
    private var displayLink: CADisplayLink?
    private let displayTarget = DisplayTarget()
    private var observations: [NSObjectProtocol] = []
    private var layoutDirty = true
    private var lastSize = CGSize.zero
    private var lastScale = 0.0
    private var previousHost: Double?
    private var seekPending = true
    private var pendingSeekMotion: LyricsSeekMotion = .immediate
    private var cascadeUntil = 0.0
    private var followPending = false
    private var hoverInside = false
    private var clearUntil = -Double.infinity
    private var hoveredIndex: Int?
    private var gapIdentity: LyricInterlude?
    private var gapEntrance = 0.0
    private var lastFocus = -1
    private var lastFocusTime: Double?
    private var focusInterval: Double?
    private var currentPositionSpring = SpringParameters.position
    private var rendering = false
    private var scrollBoundary = (min: 0.0, max: 0.0)

    public override init(frame frameRect: NSRect) { super.init(frame:frameRect); setUp() }
    public required init?(coder: NSCoder) { super.init(coder:coder); setUp() }
    private func setUp() {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true; layer?.addSublayer(content)
        content.anchorPoint = .zero; content.addSublayer(dots); content.addSublayer(bottom)
        // Keep the interlude indicator's transform centered so its entrance,
        // breathing and exit scaling never pull it toward the leading edge.
        dots.anchorPoint = CGPoint(x:0.5,y:0.5)
        for _ in 0..<3 { let dot = CALayer(); dot.backgroundColor = NSColor.white.cgColor; dots.addSublayer(dot); dotLayers.append(dot) }
        bottom.alignmentMode = .center; bottom.foregroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        displayTarget.view = self
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Lyrics")
    }
    deinit { displayLink?.invalidate(); observations.forEach(NotificationCenter.default.removeObserver) }

    /// Parsing succeeds before the previous document/surface is changed.
    public func load(ttml data: Data, time: Double = 0, playing: Bool = false, hostTime: Double = CACurrentMediaTime()) throws {
        let decoded = try TTMLDecoder().decode(data)
        document = decoded
        groups.forEach { $0.root.removeFromSuperlayer() }; groups.removeAll()
        rebuildTimeline(); interaction.resume(); gapIdentity = nil; lastFocus = -1
        clock.synchronize(time:time,playing:playing,host:hostTime,force:true)
        previousHost = nil; layoutDirty = true; seekPending = true
        // A view can be loaded before Auto Layout has assigned its final
        // bounds. Do not commit a zero-sized presentation; the first valid
        // window layout below will perform the initial render.
        if bounds.width > 0 && bounds.height > 0 { render(at:hostTime) }
        wake()
    }
    /// Clear the current document without treating the absence of lyrics as a
    /// parser failure. Playback state is retained so a later valid document can
    /// be installed atomically at the current media position.
    public func clear(time: Double = 0, playing: Bool = false, hostTime: Double = CACurrentMediaTime()) {
        document = nil
        prepared.removeAll()
        timeline = LyricsTimeline(bounds:[],profile:configuration.profile,preserveParallelHighlight:configuration.preserveCompletedHighlight)
        groups.forEach { $0.root.removeFromSuperlayer() }; groups.removeAll()
        dotLayers.forEach { $0.isHidden = true }
        bottom.string = nil
        clock.synchronize(time:time,playing:playing,host:hostTime,force:true)
        interaction.resume(); gapIdentity = nil; lastFocus = -1
        previousHost = nil; layoutDirty = true; seekPending = true; lastFrame = nil
        stopDisplayLink()
    }
    public func synchronize(time: Double, playing: Bool, seek: Bool = false, motion: LyricsSeekMotion = .immediate, hostTime: Double = CACurrentMediaTime()) {
        guard time.isFinite else { return }
        let predicted = clock.time(at: hostTime)
        let discontinuity = abs(time-predicted)>0.5
            || (clock.isPlaying && playing && time < predicted - LyricsClock.backwardsJitterTolerance)
        clock.synchronize(
            time: time,
            playing: playing,
            host: hostTime,
            force: seek || discontinuity
        )
        if seek || discontinuity { seekPending = true; pendingSeekMotion = motion; interaction.resume() }
        wake()
    }
    public func followCurrentLyrics() { followPending = interaction.suspended; interaction.resume(); wake() }
    public func releaseRenderingResources() {
        displayLink?.invalidate(); displayLink = nil
        groups.forEach { $0.root.removeFromSuperlayer() }; groups.removeAll(); cache.removeAll(); layoutDirty = true
    }
    private func rebuildTimeline() {
        guard let document else { return }
        prepared = TimingPolicy.prepare(document,configuration)
        timeline = LyricsTimeline(bounds:prepared.map(\.range),profile:configuration.profile,preserveParallelHighlight:configuration.preserveCompletedHighlight)
        seekPending = true; layoutDirty = true
    }
    public override func layout() { super.layout(); if bounds.size != lastSize { layoutDirty = true; wake() } }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        if let window {
            window.acceptsMouseMovedEvents = true
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didChangeBackingPropertiesNotification] {
                observations.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.wake() }
                })
            }
            // `load` may have happened before constraints were resolved. Force
            // one valid-size commit when the view enters a window so the Demo
            // cannot open with only the pre-layout blurred layer state.
            layoutSubtreeIfNeeded()
            if bounds.width > 0 && bounds.height > 0 && document != nil {
                render(at:CACurrentMediaTime())
            }
            wake()
        }
    }
    public override func viewDidHide() { super.viewDidHide(); stopDisplayLink() }
    public override func viewDidUnhide() { super.viewDidUnhide(); wake() }
    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }
    private func wake() {
        guard automaticDisplayUpdates, document != nil, let window, !isHiddenOrHasHiddenAncestor, !window.isMiniaturized, window.occlusionState.contains(.visible) else { stopDisplayLink(); return }
        if let link = displayLink {
            configureDisplayLink(link)
            return
        }
        let link = displayLink(target:displayTarget,selector:#selector(DisplayTarget.tick(_:)))
        configureDisplayLink(link)
        link.add(to:.main,forMode:.common); displayLink = link
    }
    private func configureDisplayLink(_ link: CADisplayLink) {
        let cap = configuration.fpsCap
        if cap > 0 {
            let rate = Float(min(120,max(1,cap)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum:1,maximum:rate,preferred:rate)
        } else {
            let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum:min(60,rate),maximum:rate,preferred:rate)
        }
    }
    fileprivate func displayTick() {
        let now = CACurrentMediaTime()
        render(at:now)
        if !clock.isPlaying && !interaction.suspended && now >= clearUntil && groups.allSatisfy({$0.settled(now)}) { stopDisplayLink() }
    }

    /// Deterministic host-time entry point for a replay, trace, or offscreen comparison.
    @discardableResult public func render(at now: Double) -> LyricsFrame {
        let started = CACurrentMediaTime()
        if rendering, let lastFrame { return lastFrame }
        rendering = true; defer { rendering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previousHost = now
        let media = clock.time(at:now), seek = seekPending; seekPending = false
        if seek { gapIdentity = nil }
        if interaction.update(now:now,profile:configuration.profile,allowAutoResume:!hoverInside) { followPending = true }
        let snapshot = timeline.update(media,seek:seek,hasBottom:!configuration.bottomText.isEmpty)
        // Manual browsing remains anchored while the pointer is over the lyric
        // surface, even when playback advances into another line.  The
        // interaction timeout is armed on pointer exit and is the only
        // implicit return path; an explicit follow request still returns now.
        let returning = followPending
        followPending = false
        if returning { interaction.resume() }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let requestedRenderScale = configuration.renderScale.isFinite ? configuration.renderScale : 1
        let renderScale = min(1,max(0.35,requestedRenderScale))
        let scale = backingScale * renderScale
        let reflowed = layoutDirty || lastSize != bounds.size || scale != lastScale
        if reflowed {
            reflow(now:now,scale:scale); lastSize = bounds.size; lastScale = scale; layoutDirty = false
        }
        content.frame = bounds
        content.backgroundColor = configuration.backdropColor?.cgColor
        let blendOpacity = configuration.blendOpacity.isFinite ? Curves.clamp(configuration.blendOpacity) : 1
        content.opacity = Float(blendOpacity)
        var focus = snapshot.focus
        if interaction.suspended { focus = interaction.frozenFocus }
        let focusChanged = focus != lastFocus
        if focusChanged || seek || snapshot.interlude != gapIdentity {
            focusInterval = focus>0 && focus<prepared.count ? prepared[focus].range.start-prepared[focus-1].range.start : nil
            if focusInterval != nil || seek || snapshot.interlude != nil {
                currentPositionSpring = .position(interval:focusInterval,slow:seek || snapshot.interlude != nil,end:snapshot.endOfSong,profile:configuration.profile)
            }
            lastFocusTime = now; lastFocus = focus
        }
        var heights: [Double] = []
        for (i,group) in groups.enumerated() {
            let active = snapshot.playing.contains(i)
            // AMLL's buffered foreground rows are presentation-active even
            // after their own authored range ends.  Treating only `active`
            // as active made a completed duet row shrink/collapse while the
            // long main row and the next duet row were still highlighted.
            let presentationActive = active || snapshot.highlighted.contains(i)
            if seek {
                group.exitTime = nil; group.lastMedia = media; group.exitMedia = media
                group.isReflowing = false
            } else if group.active && !active { group.exitTime = now; group.exitMedia = media }
            else if !group.active && active { group.exitTime = nil }
            group.active = active
            group.scale.retarget(configuration.scale && clock.isPlaying && !presentationActive ? 0.97 : 1,at:now)
            let expanded = presentationActive || !clock.isPlaying
            group.reveal.set(expanded ? 1 : 0,at:now,duration:configuration.motion.backgroundTransition)
            if seek { group.reveal.snap(expanded ? 1 : 0) }
            group.scale.resolve(now)
            let reveal = group.reveal.value(now)
            heights.append(group.layout.collapsedHeight+(group.layout.expandedHeight-group.layout.collapsedHeight)*reveal)
        }
        var offsets = [0.0]; for height in heights { offsets.append(offsets.last!+height) }
        let gap = snapshot.interlude
        let gapHeight = gap == nil ? 0 : configuration.fontSize*1.1
        if let gap {
            for i in offsets.indices where i>=gap.anchor+1 { offsets[i] += gapHeight }
        }
        let focusIndex = min(max(0,focus),groups.count)
        let baseOrigin = bounds.height*configuration.alignPosition-offsets[focusIndex]
        // The interlude is an inserted slot between two rows. Subtracting its
        // height from the entire stack origin moves the completed row upward
        // exactly when the gap starts, which is the visible jump seen after
        // “阖上眼我就是自由灵魂”. When the next row becomes the focus its
        // offset already includes the slot, so no special origin shift is
        // needed here.
        // Keep the same boundary model as AMLL's LayoutCalculator: the
        // minimum reaches the first group before focus, while the maximum
        // places the end of the lyric stack around the viewport midpoint.
        scrollBoundary.min = -offsets[focusIndex]
        scrollBoundary.max = max(scrollBoundary.min,baseOrigin+(offsets.last ?? 0)-bounds.height/2)
        interaction.offset = max(scrollBoundary.min,min(scrollBoundary.max,interaction.offset))
        var origin = baseOrigin
        let anchorHeight = focusIndex<heights.count ? heights[focusIndex] : configuration.fontSize*2
        if configuration.alignAnchor == .center { origin -= anchorHeight/2 }
        if configuration.alignAnchor == .bottom { origin -= anchorHeight }
        let alignOffset = configuration.alignOffset.isFinite ? configuration.alignOffset : 0
        origin -= interaction.offset + alignOffset
        let position = configuration.positionSpring ?? currentPositionSpring
        // Clicks cascade in visual reading order. Scrubbing moves the stack
        // directly, and cannot leave delayed springs from a previous click.
        let seekCascade = ((seek && pendingSeekMotion == .cascade) || returning) && !reflowed && configuration.spring
        let immediateSeek = seek && !seekCascade
        if seekCascade { cascadeUntil = now+0.7 }
        if immediateSeek { cascadeUntil = 0 }
        let firstVisible = groups.firstIndex { $0.y.value(now)+$0.layout.expandedHeight >= 0 } ?? 0
        var stagger = 0.0, baseDelay = reflowed ? 0 : 0.05
        var frames: [LyricsGroupFrame] = []
        var leadingXs: [Double] = []
        for (i,group) in groups.enumerated() {
            let target = origin+offsets[i]
            if group.isReflowing && !seek && configuration.spring {
                group.y.retarget(target,at:now,parameters:configuration.motion.resizeSpring,preserveVelocity:!reflowed)
                if group.y.settled(now) { group.isReflowing = false }
            } else if configuration.spring && !immediateSeek && !interaction.suspended {
                let delay = seekCascade
                    ? min(0.6,Double(max(0,i-firstVisible))*configuration.motion.clickStagger)
                    : (focusChanged ? stagger : 0)
                if seekCascade { group.cascadeStart = now+delay }
                let remainingDelay = now < cascadeUntil ? max(0,group.cascadeStart-now) : delay
                group.y.retarget(target,at:now,delay:remainingDelay,parameters:position)
            } else if interaction.suspended && configuration.spring && !immediateSeek {
                group.y.retarget(target,at:now,parameters:position)
            } else {
                group.isReflowing = false
                group.y.snap(target,at:now)
            }
            group.y.resolve(now)
            let y = group.y.value(now)
            let distance = abs(Double(i-focus))
            let clear = hoverInside || now < clearUntil
            // AMLL keeps every row in the current foreground span crisp.  The
            // highlighted set includes rows retained across a parallel voice,
            // so a completed middle row does not suddenly blur while its
            // neighbouring duet/main rows continue singing.
            let isFocus = snapshot.playing.contains(i) || snapshot.highlighted.contains(i)
            group.blur.set(configuration.blur && !clear && !isFocus ? min(configuration.motion.maximumBlurRadius,configuration.motion.blurRadius+distance*0.6) : 0,at:now,duration:configuration.motion.blurTransition)
            let passed = configuration.hidePassedLines && i<(gap.map { $0.anchor+1 } ?? snapshot.focus) && clock.isPlaying
            // The timeline's highlighted set is AMLL's buffered foreground
            // span, not only the currently hot rows. Retained parallel rows
            // therefore keep the same buffered opacity until the next
            // foreground transition rebuilds that span.
            // The upstream fullscreen stylesheet forces the line wrapper to
            // opaque (`lyricLineWrapper { opacity: 1 !important; }`).  The
            // window renderer intentionally keeps AMLL's non-dynamic .2
            // wrapper dimming, but carrying that factor into fullscreen made
            // every LDDC line-timed track look washed out and also hid the
            // inactive-row blur behind a near-transparent layer.
            let groupAlpha: Double
            if configuration.usesOpaqueCompositing {
                groupAlpha = 1
            } else if snapshot.highlighted.contains(i) {
                groupAlpha = 0.85
            } else {
                groupAlpha = document?.isWordTimed == false ? 0.2 : 1
            }
            group.opacity.set(passed ? 0 : groupAlpha,at:now)
            group.root.position = CGPoint(x:0,y:y); group.root.opacity = Float(group.opacity.value(now))
            group.root.bounds = CGRect(x:0,y:0,width:bounds.width,height:heights[i])
            group.hover.frame = group.root.bounds.insetBy(dx:8,dy:1); group.hover.isHidden = hoveredIndex != i || !configuration.hoverBackground
            group.updateCompositor(configuration)
            let blur = group.blur.value(now)
            if blur>0.01 && abs(blur-group.appliedBlur)>0.001 {
                if group.blurFilter == nil { group.blurFilter = CIFilter(name:"CIGaussianBlur") }
                group.blurFilter?.setValue(blur,forKey:kCIInputRadiusKey)
                // CA copies filter state at assignment. Mutating the same filter
                // instance can leave the compositor with its first radius.
                group.root.filters = group.blurFilter.map { [$0.copy() as! CIFilter] }
                group.appliedBlur = blur
            } else if blur<=0.01 && group.appliedBlur != 0 { group.root.filters = nil; group.appliedBlur = 0 }
            let pad = bounds.width<=500 ? 20.0 : configuration.fontSize
            let duet = prepared[i].main.isDuet
            let x = duet ? bounds.width-pad-group.layout.main.width : pad
            leadingXs.append(x)
            let bgFirst = prepared[i].backgroundFirst && !configuration.alwaysPostpositionBackground
            let reveal = group.reveal.value(now)
            let bgHeight = group.layout.background?.height ?? 0
            let bgFlowHeight = bgHeight+group.layout.gap
            let bs = configuration.scale ? 0.9+0.1*reveal : 1
            let mainY = group.layout.padding+(bgFirst ? bgFlowHeight*reveal : 0)
            let ms = group.scale.value(now)
            group.main.root.anchorPoint = CGPoint(x:duet ? 1 : 0,y:0)
            group.main.root.position = CGPoint(x:x+(duet ? group.layout.main.width : 0),y:mainY)
            group.main.root.transform = CATransform3DMakeScale(ms,ms,1)
            let alphaTarget = Curves.clamp((ms-0.97)/0.03)
            group.alpha = alphaTarget
            let parallelHighlight = snapshot.highlighted.contains(i) && !group.active && configuration.preserveCompletedHighlight
            var animationTime = media, floatTime = media, highlightHold = false
            if !group.active, let exit = group.exitTime {
                let wordEnd = max(group.main.mask.points.last?.time ?? 0,group.background?.mask.points.last?.time ?? 0)
                let remaining = max(0,wordEnd-group.exitMedia)
                let duration = max(configuration.motion.catchUpMinimum,min(configuration.motion.catchUpMaximum,remaining))
                highlightHold = parallelHighlight || (remaining > 0.016 && now-exit < duration)
                if !parallelHighlight {
                    animationTime = configuration.profile == .currentPlayer && clock.isPlaying && !seek ? exitCatchUpTime(start:group.exitMedia,end:wordEnd,elapsed:now-exit,duration:duration) : group.exitMedia
                    floatTime = group.exitMedia-(now-exit)
                }
            }
            group.lastMedia = media
            group.isVisible = y+heights[i] >= -configuration.overscan && y<=bounds.height+configuration.overscan
            group.root.isHidden = !group.isVisible
            if group.isVisible {
                group.main.ensureContent(cache:cache,scale:scale,config:configuration,now:now)
                group.background?.ensureContent(cache:cache,scale:scale,config:configuration,now:now)
                group.main.update(now:now,media:animationTime,floatTime:floatTime,active:group.active,alpha:group.alpha,background:false,config:configuration,playing:clock.isPlaying,seek:seek,highlightHold:highlightHold,preserveHighlight:parallelHighlight)
                if let background = group.background {
                    // For a background-first group, AMLL's negative margin
                    // keeps the visual bottom of the chorus attached to the
                    // main line while it is scaled and revealed.  Recreate
                    // that relation in points instead of letting the two
                    // layers drift independently.
                    let by = bgFirst
                        ? mainY-group.layout.gap-background.layout.height*bs
                        : mainY+group.layout.main.height*ms+group.layout.gap
                    group.backgroundWrapper.position = CGPoint(x:x,y:by)
                    group.backgroundWrapper.opacity = Float(reveal)
                    background.root.anchorPoint = CGPoint(x:duet ? 1 : 0,y:0)
                    background.root.position = CGPoint(x:duet ? background.layout.width : 0,y:0)
                    background.root.transform = CATransform3DMakeScale(bs,bs,1)
                    background.root.opacity = configuration.usesOpaqueCompositing ? 1 : 0.4
                    background.update(now:now,media:animationTime,floatTime:floatTime,active:group.active,alpha:group.alpha,background:true,config:configuration,playing:clock.isPlaying,seek:seek,highlightHold:highlightHold,preserveHighlight:parallelHighlight)
                }
            } else { group.main.discardContent(); group.background?.discardContent() }
            frames.append(.init(index:i,y:y,height:heights[i],scale:ms,backgroundScale:bs,backgroundSlide:0,opacity:group.opacity.value(now),blur:blur,active:group.active,maskPosition:group.main.renderedCursor))
            if target+heights[i]>=0 && !seekCascade { stagger += baseDelay; if i>=focus { baseDelay /= 1.05 } }
        }
        let interludeFrame = updateDots(snapshot,media:media,now:now,frames:frames,leadingXs:leadingXs)
        bottom.string = configuration.bottomText; bottom.fontSize = max(10,configuration.fontSize*0.5); bottom.contentsScale = scale
        bottom.frame = CGRect(x:20,y:origin+(offsets.last ?? 0)+configuration.fontSize,width:max(0,bounds.width-40),height:configuration.fontSize*2)
        CATransaction.commit()
        let result = LyricsFrame(timeline:snapshot,groups:frames,interlude:interludeFrame,following:!interaction.suspended,glyphCacheBytes:cache.bytes,glyphCacheMisses:cache.misses,layoutCount:layoutEngine.layoutCount,renderMilliseconds:(CACurrentMediaTime()-started)*1000)
        lastFrame = result; onFrame?(result); return result
    }
    private func reflow(now: Double, scale: Double) {
        cache.budget = configuration.cacheBudgetBytes
        guard let document else { return }
        for i in prepared.indices {
            let dynamic = prepared[i].main.hasEffectiveWordTiming
                || prepared[i].background?.hasEffectiveWordTiming == true
            let layout = layoutEngine.group(prepared[i],width:max(1,bounds.width),config:configuration,dynamic:dynamic,hasDuet:document.hasDuet)
            if i<groups.count { groups[i].reflow(layout,cache:cache,scale:scale,config:configuration,now:now) }
            else {
                let group = GroupLayers(index:i,layout:layout,initialY:bounds.height*2,cache:cache,scale:scale,config:configuration,now:now)
                groups.append(group); content.insertSublayer(group.root,below:dots)
            }
        }
    }
    private func updateDots(
        _ snapshot: LyricsTimelineSnapshot,
        media: Double,
        now: Double,
        frames: [LyricsGroupFrame],
        leadingXs: [Double]
    ) -> LyricsInterludeFrame? {
        guard let gap = snapshot.interlude,
              configuration.effectiveRenderLayer != .highlight,
              !interaction.dotsHidden(now),
              !frames.isEmpty
        else {
            dots.isHidden = true
            return nil
        }
        if gap != gapIdentity {
            gapIdentity = gap
            // The entrance clock is the authored gap start for both profiles.
            // Using the first observed media sample (the old upstream path)
            // restarts the fade when playback updates arrive late.
            gapEntrance = gap.range.start
        }
        let sample = interludeSample(
            elapsed: media-gapEntrance,
            duration: gap.range.end-gapEntrance,
            profile: configuration.profile
        )
        let dotScale = configuration.interludeDotScale.isFinite
            ? min(4,max(0.25,configuration.interludeDotScale))
            : 1
        let size = max(1,configuration.fontSize*0.3*dotScale)
        let step = size*1.7
        dots.isHidden = false
        // Entrance and exit are a single global fade. Per-dot progress is
        // represented by the inactive-to-active color below, so all surfaces
        // retain an actual inactive state instead of forcing three bright dots.
        dots.opacity = Float(Curves.clamp(sample.opacity))

        let nextIndex = min(frames.count-1,max(0,gap.anchor+1))
        let leadingX = leadingXs.indices.contains(nextIndex)
            ? leadingXs[nextIndex]
            : (bounds.width <= 500 ? 20.0 : configuration.fontSize)
        // The transform is centered. Compensate for the known maximum
        // breathing scale so the physical left tangent of the first dot meets
        // the lyric leading edge at the peak.
        let maximumBreathingScale = 0.7 * 1.05
        let dotWidth = size + step*2
        let dotHeight = configuration.fontSize
        let dotX = leadingX + dotWidth*(maximumBreathingScale-1)/2

        let nextTop = frames[nextIndex].y
        let previousBottom: Double
        if gap.anchor >= 0, frames.indices.contains(gap.anchor) {
            previousBottom = frames[gap.anchor].y + frames[gap.anchor].height
        } else {
            previousBottom = nextTop - configuration.fontSize*1.1
        }
        // Place the marker at the exact midpoint of the two row boundaries.
        // This remains correct while line-level springs settle because the
        // current frame geometry, rather than a stale target offset, is used.
        let centerY = previousBottom + (nextTop-previousBottom)/2
        dots.bounds = CGRect(x:0,y:0,width:dotWidth,height:dotHeight)
        dots.position = CGPoint(x:dotX+dotWidth/2,y:centerY)
        dots.transform = CATransform3DMakeScale(sample.scale,sample.scale,1)
        for i in 0..<3 {
            dotLayers[i].frame = CGRect(
                x: Double(i)*step,
                y: (dotHeight-size)/2,
                width: size,
                height: size
            )
            dotLayers[i].cornerRadius = size/2
            dotLayers[i].opacity = 1
            // AMLL's walk starts at 0.25. Normalize that baseline to the
            // configured inactive color, then blend toward the exact active
            // main-lyric color as each dot walks in.
            let walk = sample.walk.indices.contains(i) ? sample.walk[i] : 0
            let progress = Curves.clamp((walk-0.25)/0.75)
            dotLayers[i].backgroundColor = interpolateLyricsColor(
                configuration.palette.mainInactive,
                configuration.palette.mainActive,
                progress
            ).cgColor
        }
        return LyricsInterludeFrame(
            anchor: gap.anchor,
            range: gap.range,
            x: dotX,
            y: centerY,
            width: dotWidth,
            height: dotHeight,
            scale: sample.scale,
            opacity: sample.opacity,
            walk: sample.walk
        )
    }

    public func groupIndex(at point: CGPoint) -> Int? {
        lastFrame?.groups.first { $0.opacity>0.01 && point.y >= $0.y && point.y < $0.y+$0.height }?.index
    }
    public func seekTime(forGroup index: Int) -> Double? {
        guard prepared.indices.contains(index) else { return nil }
        return max(0,prepared[index].source.main.range.start+configuration.timing.seekOffset)
    }
    public override func mouseDown(with event: NSEvent) {
        setPointerInside(true)
        guard let i = groupIndex(at:convert(event.locationInWindow,from:nil)), let time = seekTime(forGroup:i) else { return }
        interaction.resume(); onSeek?(time); wake()
    }
    public override func scrollWheel(with event: NSEvent) {
        scroll(by:-event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? 1 : 50),hostTime:CACurrentMediaTime())
    }
    public func scroll(by delta: Double, hostTime: Double = CACurrentMediaTime()) {
        guard delta.isFinite else { return }
        setPointerInside(true,hostTime:hostTime)
        let oldOffset = interaction.offset
        interaction.scroll(delta,now:hostTime,timeline:timeline.snapshot)
        clearUntil = hostTime+configuration.motion.pointerExitDelay
        interaction.offset = max(scrollBoundary.min,min(scrollBoundary.max,interaction.offset))
        let translation = oldOffset-interaction.offset
        for group in groups { group.y.translate(translation) }
        wake()
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.mouseEnteredAndExited,.mouseMoved],owner:self))
    }
    public func setPointerInside(_ inside: Bool, hostTime: Double = CACurrentMediaTime()) {
        hoverInside = inside
        if !inside {
            clearUntil = hostTime+configuration.motion.pointerExitDelay
            hoveredIndex = nil
            interaction.pointerExited(now: hostTime)
        }
        wake()
    }
    public override func mouseEntered(with event: NSEvent) { setPointerInside(true); mouseMoved(with:event) }
    public override func mouseExited(with event: NSEvent) { setPointerInside(false) }
    public override func mouseMoved(with event: NSEvent) { setPointerInside(true); hoveredIndex = groupIndex(at:convert(event.locationInWindow,from:nil)) }
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = groupIndex(at:convert(event.locationInWindow,from:nil)) else { return nil }
        let menu = NSMenu(); let item = menu.addItem(withTitle:"Copy lyrics",action:#selector(copyLyric(_:)),keyEquivalent:""); item.target = self; item.tag = i
        return menu
    }
    @objc private func copyLyric(_ sender: NSMenuItem) {
        guard prepared.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prepared[sender.tag].source.main.text,forType:.string)
    }
    public func snapshotImage(scale: Double = 2) -> CGImage? {
        layoutSubtreeIfNeeded(); CATransaction.flush()
        let w = max(1,Int(bounds.width*scale)), h = max(1,Int(bounds.height*scale))
        guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let pixelBounds = CGRect(x:0,y:0,width:w,height:h)
        let backdrop = configuration.backdropColor ?? LyricsColor(0.055,0.075,0.12)
        context.setFillColor(backdrop.cgColor); context.fill(pixelBounds)
        // CALayer.render(in:) deliberately omits compositor filters. Apply the same public
        // Gaussian filter in Core Image for exports, rather than claiming a sharp export is parity.
        let visible = groups.filter { !$0.root.isHidden }
        let dotsHidden = dots.isHidden, bottomHidden = bottom.isHidden
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer {
            visible.forEach { $0.root.isHidden = false }; dots.isHidden = dotsHidden; bottom.isHidden = bottomHidden
            CATransaction.commit()
        }
        groups.forEach { $0.root.isHidden = true }; dots.isHidden = true; bottom.isHidden = true
        func capture() -> CGImage? {
            guard let bitmap = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            bitmap.scaleBy(x:scale,y:scale); bitmap.translateBy(x:0,y:bounds.height); bitmap.scaleBy(x:1,y:-1)
            layer?.render(in:bitmap); return bitmap.makeImage()
        }
        for group in visible {
            group.root.isHidden = false
            if let image = capture() {
                let radius = group.blur.value(previousHost ?? 0)*scale
                let filtered = radius>0.01 ? imageContext.createCGImage(CIImage(cgImage:image).applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]),from:pixelBounds) : image
                if let filtered { context.draw(filtered,in:pixelBounds) }
            }
            group.root.isHidden = true
        }
        dots.isHidden = dotsHidden; bottom.isHidden = bottomHidden
        if let image = capture() { context.draw(image,in:pixelBounds) }
        return context.makeImage()
    }
}

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

private enum LyricsEntryAnimation: Equatable {
    case load
    case wake
}

/// Some Apple/AMLL exports declare word timing but wrap an entire lyric line
/// in one timed span. There is no authored word boundary to render, but
/// keeping the line in the line-timed layout makes its vertical float move as
/// one block. In that narrow case the layout engine may distribute the single
/// span across its visible tokens for presentation only. The document's source
/// ranges and seek semantics remain untouched.
func usesVisualWordTiming(_ line: LyricLine, document: LyricsDocument) -> Bool {
    if line.hasEffectiveWordTiming { return true }
    guard document.timingMode == .word,
          line.isWordTimed,
          line.words.count == 1,
          let text = line.words.first?.text else { return false }
    return text.lazy.filter { !$0.isWhitespace }.count > 1
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
    /// True while an overlay (for example the fullscreen mini-player) owns
    /// the pointer. The gate is persistent; clearing hover once is not enough
    /// because the next mouse-moved event can otherwise re-enable it.
    public private(set) var isPointerInteractionSuppressed = false
    /// Whether a window-backed display loop is currently installed.
    /// Hosts can use this to verify that a visible surface actually advances
    /// between sparse playback snapshots without exposing the display link.
    public var isDisplayUpdateRunning: Bool { displayLink != nil }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public var isFollowing: Bool { !interaction.suspended }
    public var diagnosticTimings: [LyricGroup] { prepared.map { LyricGroup(main:$0.main,background:$0.background) } }
    /// Internal rendering probe used by regression tests. The public frame
    /// intentionally exposes only timing/geometry, while this verifies that
    /// a cleared interlude marker is actually made visible after a reload.
    var areInterludeDotLayersVisible: Bool {
        !dots.isHidden && dotLayers.count == 3 && dotLayers.allSatisfy { !$0.isHidden }
    }

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
    /// Drain expensive text shaping in small display-frame batches during a
    /// live resize. Existing group layouts remain valid until their queued
    /// replacement is ready, so the main actor never stalls on a whole song.
    private var pendingReflowIndices: [Int] = []
    private var pendingReflowCursor = 0
    private var reflowInProgress = false
    private let reflowBatchLimit = 4
    private let reflowFrameBudget: Double = 0.004
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
    /// Highest media position rendered for the current interlude.  Playback
    /// snapshots can arrive out of order (especially while switching tracks
    /// or completing a seek); keeping the marker's own clock monotonic mirrors
    /// AMLL's delta-driven InterludeDots and prevents a second scale-in.
    private var gapLastMedia = -Double.infinity
    private var lastFocus = -1
    private var lastFocusTime: Double?
    private var focusInterval: Double?
    private var currentPositionSpring = SpringParameters.position
    /// A document load starts rows below the viewport. A surface that was
    /// hidden and becomes visible again uses the separate gather animation so
    /// the current row stays anchored while its neighbours close in around it.
    private var pendingEntryAnimation: LyricsEntryAnimation?
    private var runningEntryAnimation: LyricsEntryAnimation?
    /// Keep the entry solver as the owner for a short handoff after it
    /// settles. Replacing it immediately with the normal focus solver can
    /// expose a one-frame jump when the entry spring returns from overshoot.
    private var entryAnimationHandoffUntil = 0.0
    private var rendering = false
    private var scrollBoundary = (min: 0.0, max: 0.0)

    private var entryPositionSpring: SpringParameters {
        // Entry motion must retain a real under-damped position solver. A
        // critically damped fallback makes the load animation look like a
        // linear translation and removes the requested settle-back motion.
        configuration.positionSpring ?? .position
    }

    /// The interlude marker occupies a real layout slot, rather than being
    /// placed at the midpoint between two already-laid-out rows. Keeping the
    /// marker's box and its edge margin in one place prevents the dot layer
    /// from overlapping the first lyric when font metrics or alignment change.
    private var interludeMarkerHeight: Double {
        let size = configuration.fontSize.isFinite ? configuration.fontSize : 38
        return max(10, size)
    }

    private var interludeMarkerMargin: Double {
        interludeMarkerHeight * 0.4
    }

    private var interludeSlotHeight: Double {
        interludeMarkerHeight + interludeMarkerMargin * 2
    }

    private var entryScaleSpring: SpringParameters {
        SpringParameters(mass: 1, damping: 24, stiffness: 150, soft: true)
    }

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
        setDotsHidden(true)
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
        rebuildTimeline(); interaction.resume(); gapIdentity = nil; gapLastMedia = -Double.infinity; lastFocus = -1
        pendingEntryAnimation = .load
        runningEntryAnimation = nil
        entryAnimationHandoffUntil = 0
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
        setDotsHidden(true)
        bottom.string = nil
        clock.synchronize(time:time,playing:playing,host:hostTime,force:true)
        interaction.resume(); gapIdentity = nil; gapLastMedia = -Double.infinity; lastFocus = -1
        pendingEntryAnimation = nil
        runningEntryAnimation = nil
        entryAnimationHandoffUntil = 0
        previousHost = nil; layoutDirty = true; seekPending = true; lastFrame = nil
        pendingReflowIndices.removeAll(); pendingReflowCursor = 0; reflowInProgress = false
        stopDisplayLink()
    }
    @discardableResult
    public func synchronize(time: Double, playing: Bool, seek: Bool = false, motion: LyricsSeekMotion = .immediate, hostTime: Double = CACurrentMediaTime()) -> Double {
        guard time.isFinite else { return clock.time(at: hostTime) }
        let predicted = clock.time(at: hostTime)
        let playbackTransition = clock.isPlaying != playing
        let discontinuity = !playbackTransition && (
            abs(time-predicted)>0.5
                || (clock.isPlaying && playing && time < predicted - LyricsClock.backwardsJitterTolerance)
        )
        clock.synchronize(
            time: time,
            playing: playing,
            host: hostTime,
            force: seek || discontinuity
        )
        if seek || discontinuity {
            seekPending = true; pendingSeekMotion = motion; interaction.resume()
            // A real seek supersedes a wake animation. A loaded document owns
            // its entrance until the position spring settles: transport
            // reconciliation can arrive out of order during a track handoff,
            // and cancelling the load spring here turns the whole entrance
            // into the hard jump seen after a reload. An explicit seek still
            // retargets the active entry spring through the normal render
            // path; it does not need to replace it with a snap.
            let isLoadEntryActive = pendingEntryAnimation == .load
                || runningEntryAnimation == .load
            if !isLoadEntryActive {
                if pendingEntryAnimation == .wake { pendingEntryAnimation = nil }
                runningEntryAnimation = nil
                entryAnimationHandoffUntil = 0
            }
        }
        wake()
        return clock.time(at: hostTime)
    }
    public func followCurrentLyrics() { followPending = interaction.suspended; interaction.resume(); wake() }

    /// Request the reappearance animation used when a lyric surface is shown
    /// again after being hidden or moved between the window and fullscreen
    /// hosts. The request is ignored while a newly loaded document is still
    /// performing its one-time entrance, so that lifecycle transitions cannot
    /// restart that animation halfway through.
    public func prepareWakeEntryAnimation() {
        guard document != nil, !groups.isEmpty, lastFrame != nil,
              pendingEntryAnimation == nil, runningEntryAnimation == nil,
              CACurrentMediaTime() >= entryAnimationHandoffUntil
        else { return }
        interaction.resume()
        pendingEntryAnimation = .wake
        wake()
    }
    public func releaseRenderingResources() {
        displayLink?.invalidate(); displayLink = nil
        groups.forEach { $0.root.removeFromSuperlayer() }; groups.removeAll(); cache.removeAll(); layoutDirty = true
        pendingEntryAnimation = nil
        runningEntryAnimation = nil
        entryAnimationHandoffUntil = 0
        pendingReflowIndices.removeAll(); pendingReflowCursor = 0; reflowInProgress = false
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
        // AppKit may retain the old tracking-area state while a lyric surface
        // moves between the windowed and fullscreen hosts. Clear that
        // transient hover state so inactive rows regain blur after re-entry.
        setPointerInside(false, hostTime: CACurrentMediaTime())
        displayLink?.invalidate(); displayLink = nil
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        if let window {
            window.acceptsMouseMovedEvents = true
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didChangeBackingPropertiesNotification] {
                observations.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.wake() }
                })
            }
            // Reparenting a surface (most notably the fullscreen host) is a
            // real visual reappearance. If the document was already rendered,
            // gather the rows around the current line once the new host is
            // ready. A pending load entrance takes precedence.
            prepareWakeEntryAnimation()
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
    public override func viewDidHide() {
        super.viewDidHide()
        setPointerInside(false, hostTime: CACurrentMediaTime())
        stopDisplayLink()
    }
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        prepareWakeEntryAnimation()
        wake()
    }
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
        if !clock.isPlaying
            && !interaction.suspended
            && !layoutDirty
            && !reflowInProgress
            && runningEntryAnimation == nil
            && now >= entryAnimationHandoffUntil
            && now >= clearUntil
            && groups.allSatisfy({ $0.settled(now) })
        {
            stopDisplayLink()
        }
    }

    /// Deterministic host-time entry point for a replay, trace, or offscreen comparison.
    @discardableResult public func render(at now: Double) -> LyricsFrame {
        let started = CACurrentMediaTime()
        if rendering, let lastFrame { return lastFrame }
        rendering = true; defer { rendering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previousHost = now
        // Fullscreen/AppKit transitions can swallow a matching mouse-exit
        // event. Reconcile only an already-entered pointer here so a stale
        // hover gate cannot suppress inactive-row blur forever, while a real
        // pointer still receives ownership from tracking-area events.
        reconcilePointerTracking(hostTime: now)
        let seek = seekPending
        let seekMotion = seek ? pendingSeekMotion : .immediate
        seekPending = false
        pendingSeekMotion = .immediate
        let media = clock.time(at:now)
        let seekPreview = seek && seekMotion == .preview
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
        let needsReflow = layoutDirty || lastSize != bounds.size || scale != lastScale
        // AppKit sends a layout pass for every live-resize tick. Keep the
        // existing text shaping while the pointer is still resizing the
        // window; reflow once at the latest size after the resize ends. This
        // avoids repeatedly throwing away an in-progress batch before the
        // text width has even settled, which otherwise makes the windowed
        // lyric surface the dominant main-thread cost during a drag.
        let deferLiveResizeReflow = window?.inLiveResize == true
        // `reflowed` means a new generation started in this frame. A
        // continuation frame keeps the resize spring's current velocity.
        var reflowed = false
        if needsReflow && !deferLiveResizeReflow {
            if groups.count != prepared.count {
                // Initial document installation has no usable old geometry;
                // create all group shells atomically so frame consumers still
                // receive one complete group array on the first render.
                reflowAll(now: now, scale: scale)
                pendingReflowIndices.removeAll(keepingCapacity: true)
                pendingReflowCursor = 0
                reflowInProgress = false
                lastSize = bounds.size
                lastScale = scale
                layoutDirty = false
                reflowed = true
            } else {
                beginIncrementalReflow(focus: snapshot.focus)
                lastSize = bounds.size
                lastScale = scale
                layoutDirty = false
                reflowed = true
                _ = processIncrementalReflow(now: now, scale: scale)
            }
        } else if reflowInProgress {
            _ = processIncrementalReflow(now: now, scale: scale)
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
                currentPositionSpring = seekPreview
                    ? .nonBouncyPosition()
                    : .position(interval:focusInterval,slow:seek || snapshot.interlude != nil,end:snapshot.endOfSong,profile:configuration.profile)
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
                group.isReflowing = false; group.reflowTarget = nil
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
        let introInterlude = gap?.anchor == -1
        let focusIndex = min(max(0,focus),groups.count)
        // An interlude is a real slot in the vertical stack. For a normal
        // gap the marker sits between two real row boundaries. At the start
        // of a song, however, the marker is centred on the virtual active
        // row, so the inserted distance must also include half of that
        // row's measured height. This is the part the old font-size-only
        // offset missed: a tall first row could consume the entire gap.
        let gapHeight: Double = {
            guard gap != nil else { return 0 }
            guard introInterlude, focusIndex < heights.count else {
                return interludeSlotHeight
            }
            return heights[focusIndex] / 2
                + interludeMarkerHeight / 2
                + interludeMarkerMargin
        }()
        if let gap {
            for i in offsets.indices where i>=gap.anchor+1 { offsets[i] += gapHeight }
        }
        let alignOffset = configuration.alignOffset.isFinite ? configuration.alignOffset : 0
        // For an intro gap the marker owns the active height. Keep the stack
        // origin at the normal active anchor instead of subtracting the
        // inserted spacing; the first lyric then lands directly below it.
        let baseOrigin = bounds.height*configuration.alignPosition
            - offsets[focusIndex]
            + (introInterlude ? gapHeight : 0)
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
        origin -= interaction.offset + alignOffset
        startPendingEntryAnimation(
            focus: focus,
            origin: origin,
            offsets: offsets,
            snapshot: snapshot,
            now: now
        )
        let position = seekPreview
            ? .nonBouncyPosition(from: configuration.positionSpring ?? currentPositionSpring)
            : (configuration.positionSpring ?? currentPositionSpring)
        // Clicks cascade in visual reading order. Scrubbing moves the stack
        // directly, and cannot leave delayed springs from a previous click.
        let seekCascade = ((seek && seekMotion == .cascade) || returning) && !reflowed && configuration.spring
        let immediateSeek = seek && seekMotion == .immediate
        if seekCascade { cascadeUntil = now+0.7 }
        if immediateSeek { cascadeUntil = 0 }
        let firstVisible = groups.firstIndex { $0.y.value(now)+$0.layout.expandedHeight >= 0 } ?? 0
        var stagger = 0.0, baseDelay = reflowed ? 0 : 0.05
        var frames: [LyricsGroupFrame] = []
        var leadingXs: [Double] = []
        for (i,group) in groups.enumerated() {
            let target = origin+offsets[i]
            let resizeTargetChanged = group.reflowTarget.map { abs($0-target) > 0.5 } ?? false
            let entryMotionActive = runningEntryAnimation != nil || now < entryAnimationHandoffUntil
            if entryMotionActive {
                group.isReflowing = false; group.reflowTarget = nil
                let presentationActive = snapshot.playing.contains(i)
                    || snapshot.highlighted.contains(i)
                // Delay is part of the entry event, not a per-frame layout
                // decision. Re-arming it while the focus/height target moves
                // can strand a row in the pending state and then make it snap
                // to the target after the visible spring has already played.
                let remainingEntryDelay = max(0, group.entryDelayUntil-now)
                let normalScale = configuration.scale && clock.isPlaying
                    && !presentationActive ? 0.97 : 1
                if configuration.spring {
                    group.y.retarget(
                        target,
                        at: now,
                        delay: remainingEntryDelay,
                        parameters: entryPositionSpring,
                        preserveVelocity: true
                    )
                    group.scale.retarget(
                        normalScale,
                        at: now,
                        delay: remainingEntryDelay,
                        parameters: entryScaleSpring,
                        preserveVelocity: true
                    )
                } else {
                    group.y.snap(target,at:now)
                    group.scale.snap(normalScale,at:now)
                }
            } else if group.isReflowing && !seek && !seekCascade && configuration.spring && !focusChanged && !resizeTargetChanged {
                if group.reflowTarget == nil { group.reflowTarget = target }
                group.y.retarget(target,at:now,parameters:configuration.motion.resizeSpring,preserveVelocity:!reflowed)
                if group.y.settled(now) { group.isReflowing = false; group.reflowTarget = nil }
            } else if configuration.spring && !immediateSeek && !interaction.suspended {
                // A playback focus/height transition supersedes a resize
                // reflow. Clearing the marker here prevents the next frame
                // from applying the critically damped resize spring to the
                // authored lyric movement, which otherwise reads as a hitch.
                group.isReflowing = false; group.reflowTarget = nil
                let delay = seekCascade
                    ? min(0.6,Double(max(0,i-firstVisible))*configuration.motion.clickStagger)
                    : (focusChanged && !seekPreview ? stagger : 0)
                if seekCascade { group.cascadeStart = now+delay }
                let remainingDelay = now < cascadeUntil ? max(0,group.cascadeStart-now) : delay
                group.y.retarget(target,at:now,delay:remainingDelay,parameters:position)
            } else if interaction.suspended && configuration.spring && !immediateSeek {
                group.isReflowing = false; group.reflowTarget = nil
                group.y.retarget(target,at:now,parameters:position)
            } else {
                group.isReflowing = false; group.reflowTarget = nil
                group.y.snap(target,at:now)
            }
            group.y.resolve(now)
            let y = group.y.value(now)
            let distance = abs(Double(i-focus))
            let clear = hoverInside || now < clearUntil || seekPreview
            // AMLL keeps every row in the current foreground span crisp.  The
            // highlighted set includes rows retained across a parallel voice,
            // so a completed middle row does not suddenly blur while its
            // neighbouring duet/main rows continue singing.
            let isFocus = snapshot.playing.contains(i) || snapshot.highlighted.contains(i)
            let blurTarget = configuration.blur && !clear && !isFocus
                ? min(configuration.motion.maximumBlurRadius,configuration.motion.blurRadius+distance*0.45)
                : 0
            if seekPreview {
                // A scrub preview is a temporary inspection state. Do not
                // spend the first few frames fading old blur away; every row
                // must be readable while the pointer is moving.
                group.blur.snap(0)
            } else {
                group.blur.set(blurTarget,at:now,duration:configuration.motion.blurTransition)
            }
            let passed = configuration.hidePassedLines && i<(gap.map { $0.anchor+1 } ?? snapshot.focus) && clock.isPlaying
            // The timeline's highlighted set is AMLL's buffered foreground
            // span, not only the currently hot rows. Retained parallel rows
            // therefore keep the same buffered opacity until the next
            // foreground transition rebuilds that span.
            // The upstream fullscreen stylesheet forces the line wrapper to
            // opaque (`lyricLineWrapper { opacity: 1 !important; }`). Keep
            // that same readable baseline on the window surface as well; a
            // blanket .2 wrapper made converted line-timed LRC tracks look
            // washed out and hid their inactive-row contrast.
            let groupAlpha: Double
            if configuration.usesOpaqueCompositing || snapshot.playing.contains(i) {
                groupAlpha = 1
            } else if snapshot.highlighted.contains(i) {
                // Retained parallel rows stay just under the currently hot
                // line, but must not inherit the old blanket 0.2 opacity that
                // made every inactive line-timed LRC row look washed out.
                groupAlpha = 0.85
            } else {
                groupAlpha = 1
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
            // AMLL scales a lyric line around its leading edge and vertical
            // centre. Anchoring at the top made the inactive shrink also move
            // the visible baseline, which reads as a small positional jitter
            // while the row is moving to its next stack slot.
            group.main.root.anchorPoint = CGPoint(x:duet ? 1 : 0,y:0.5)
            group.main.root.position = CGPoint(x:x+(duet ? group.layout.main.width : 0),y:mainY+group.layout.main.height/2)
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
            // Warm the focused line while a load entrance is still below the
            // viewport. Without this one-line prewarm the first paused frame
            // reports an uninitialized mask (0), then the mask jumps to its
            // authored position as the spring reaches the viewport.
            let entryFocus = min(max(0, focus), max(0, groups.count-1))
            let prewarmEntryFocus = runningEntryAnimation != nil && i == entryFocus
            group.isVisible = prewarmEntryFocus
                || (y+heights[i] >= -configuration.overscan && y<=bounds.height+configuration.overscan)
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
                    //
                    // `main.root` is vertically centered.  The old formula
                    // treated `mainY` as the top edge and therefore applied
                    // the scale a second time to the background offset.  As
                    // the focused row changed scale this made the background
                    // snap by a fraction of a point, which is visible as
                    // granular line-to-line jitter.  Resolve the scaled main
                    // bounds first, then attach the background to those
                    // bounds with the fixed group gap.
                    let mainHeight = group.layout.main.height
                    let mainTop = mainY + (mainHeight-mainHeight*ms)/2
                    let mainBottom = mainTop + mainHeight*ms
                    let by = bgFirst
                        ? mainTop-group.layout.gap-background.layout.height*bs
                        : mainBottom+group.layout.gap
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
        if runningEntryAnimation != nil,
           groups.allSatisfy({ $0.y.settled(now) && $0.scale.settled(now) }) {
            runningEntryAnimation = nil
            entryAnimationHandoffUntil = now + 0.18
            for group in groups { group.entryDelayUntil = 0 }
        }
        if runningEntryAnimation == nil, now >= entryAnimationHandoffUntil {
            entryAnimationHandoffUntil = 0
        }
        let introMarkerY: Double? = {
            guard introInterlude else { return nil }
            // `LyricsInterludeFrame.y` is a center coordinate. Resolve the
            // normal focused row first, then remove the intro virtual slot
            // from its offset. This keeps .top/.center/.bottom semantics
            // identical for the marker and the real active line.
            let focusOffsetWithoutIntro = offsets[focusIndex] - gapHeight
            var normalOrigin = bounds.height*configuration.alignPosition - focusOffsetWithoutIntro
            if configuration.alignAnchor == .center { normalOrigin -= anchorHeight/2 }
            if configuration.alignAnchor == .bottom { normalOrigin -= anchorHeight }
            // The dots are centred on the same active-row anchor that the
            // first lyric will use after the intro slot is removed.
            return normalOrigin + anchorHeight/2 - interaction.offset - alignOffset
        }()
        let interludeFrame = updateDots(
            snapshot,
            media: media,
            now: now,
            frames: frames,
            leadingXs: leadingXs,
            introMarkerY: introMarkerY
        )
        bottom.string = configuration.bottomText; bottom.fontSize = max(10,configuration.fontSize*0.5); bottom.contentsScale = scale
        bottom.frame = CGRect(x:20,y:origin+(offsets.last ?? 0)+configuration.fontSize,width:max(0,bounds.width-40),height:configuration.fontSize*2)
        CATransaction.commit()
        let result = LyricsFrame(timeline:snapshot,groups:frames,interlude:interludeFrame,following:!interaction.suspended,glyphCacheBytes:cache.bytes,glyphCacheMisses:cache.misses,layoutCount:layoutEngine.layoutCount,renderMilliseconds:(CACurrentMediaTime()-started)*1000)
        lastFrame = result; onFrame?(result); return result
    }

    private func startPendingEntryAnimation(
        focus: Int,
        origin: Double,
        offsets: [Double],
        snapshot: LyricsTimelineSnapshot,
        now: Double
    ) {
        guard let pending = pendingEntryAnimation else { return }
        guard !groups.isEmpty else {
            pendingEntryAnimation = nil
            return
        }

        pendingEntryAnimation = nil
        runningEntryAnimation = pending
        let entryFocus = min(max(0, focus), max(0, groups.count-1))

        switch pending {
        case .load:
            // Groups are created below the viewport. A small initial scale
            // gives the spring rise a little depth without affecting the
            // authored text layout. Do not gate this on clock.isPlaying: a
            // real track change can install its lyric document during the
            // transport's short paused/loading handoff. Cancelling here turns
            // the whole entrance into the hard seek snap seen on true track
            // changes, while same-track replay happens to keep playing=true.
            let initialScale = configuration.scale ? 0.94 : 1
            // Re-arm the position track explicitly. A document can be
            // reloaded while the previous frame is still visible, so relying
            // only on GroupLayers' construction-time value can leave the new
            // entry starting at (or already settled on) its final target.
            let entryStartY = max(1, bounds.height * 2)
            for (i, group) in groups.enumerated() {
                group.y.snap(entryStartY, at: now)
                group.entryDelayUntil = now + min(0.28, Double(max(0, i-entryFocus))*0.04)
                group.scale.snap(initialScale,at:now)
            }
        case .wake:
            // The focused row starts exactly at its normal target. Rows above
            // begin farther above and rows below farther below, then both sides
            // move inward so the initial state has expanded line spacing.
            let spacing = min(180, max(20, configuration.fontSize*0.9))
            for i in groups.indices {
                let target = origin + (offsets.indices.contains(i) ? offsets[i] : 0)
                let distance = Double(abs(i-entryFocus))
                let direction: Double
                if i < entryFocus { direction = -1 }
                else if i > entryFocus { direction = 1 }
                else { direction = 0 }
                groups[i].y.snap(target + direction*distance*spacing,at:now)
                groups[i].entryDelayUntil = now + min(0.24, distance*0.04)

                let presentationActive = snapshot.playing.contains(i)
                    || snapshot.highlighted.contains(i)
                let normalScale = configuration.scale && clock.isPlaying
                    && !presentationActive ? 0.97 : 1
                groups[i].scale.snap(configuration.scale ? min(normalScale,0.97) : normalScale,at:now)
            }
        }
    }

    private func reflowAll(now: Double, scale: Double) {
        cache.budget = configuration.cacheBudgetBytes
        guard let document else { return }
        for i in prepared.indices {
            reflowGroup(at: i, now: now, scale: scale, document: document)
        }
    }

    private func beginIncrementalReflow(focus: Int) {
        pendingReflowIndices = prepared.indices.sorted {
            let lhs = abs($0 - focus), rhs = abs($1 - focus)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        pendingReflowCursor = 0
        reflowInProgress = !pendingReflowIndices.isEmpty
    }

    @discardableResult
    private func processIncrementalReflow(now: Double, scale: Double) -> Bool {
        guard reflowInProgress, let document else { return false }
        cache.budget = configuration.cacheBudgetBytes
        let started = CACurrentMediaTime()
        var processed = 0
        while pendingReflowCursor < pendingReflowIndices.count {
            if processed >= reflowBatchLimit { break }
            if processed > 0 && CACurrentMediaTime() - started >= reflowFrameBudget { break }
            let index = pendingReflowIndices[pendingReflowCursor]
            pendingReflowCursor += 1
            reflowGroup(at: index, now: now, scale: scale, document: document)
            processed += 1
        }
        if pendingReflowCursor >= pendingReflowIndices.count {
            pendingReflowIndices.removeAll(keepingCapacity: true)
            pendingReflowCursor = 0
            reflowInProgress = false
        }
        return processed > 0
    }

    private func reflowGroup(at index: Int, now: Double, scale: Double, document: LyricsDocument) {
        guard prepared.indices.contains(index) else { return }
        let dynamic = usesVisualWordTiming(prepared[index].main, document: document)
            || prepared[index].background.map { usesVisualWordTiming($0, document: document) } == true
        let layout = layoutEngine.group(
            prepared[index],
            width: max(1, bounds.width),
            config: configuration,
            dynamic: dynamic,
            hasDuet: document.hasDuet
        )
        if index < groups.count {
            groups[index].reflow(layout, cache: cache, scale: scale, config: configuration, now: now)
        } else {
            let group = GroupLayers(
                index: index,
                layout: layout,
                initialY: bounds.height * 2,
                cache: cache,
                scale: scale,
                config: configuration,
                now: now
            )
            groups.append(group)
            content.insertSublayer(group.root, below: dots)
        }
    }

    private func setDotsHidden(_ hidden: Bool) {
        dots.isHidden = hidden
        dotLayers.forEach { $0.isHidden = hidden }
    }
    private func updateDots(
        _ snapshot: LyricsTimelineSnapshot,
        media: Double,
        now: Double,
        frames: [LyricsGroupFrame],
        leadingXs: [Double],
        introMarkerY: Double?
    ) -> LyricsInterludeFrame? {
        guard !frames.isEmpty else {
            setDotsHidden(true)
            return nil
        }
        guard let gap = snapshot.interlude else {
            // Once playback has actually left the previous gap, forget its
            // progress so seeking back into that gap gets a correct entrance.
            // A hidden marker caused by scrolling or a cover-blur layer keeps
            // the identity intact and therefore cannot trigger a duplicate
            // entrance on the next visible frame.
            if let identity = gapIdentity, !identity.range.contains(media) {
                gapIdentity = nil
                gapLastMedia = -Double.infinity
            }
            setDotsHidden(true)
            return nil
        }
        guard configuration.effectiveRenderLayer != .highlight,
              !interaction.dotsHidden(now)
        else {
            setDotsHidden(true)
            return nil
        }
        if gap != gapIdentity {
            gapIdentity = gap
            // The entrance clock is the authored gap start for both profiles.
            // Using the first observed media sample (the old upstream path)
            // restarts the fade when playback updates arrive late.
            gapEntrance = gap.range.start
            gapLastMedia = max(gap.range.start, media)
        }
        // The host media clock may briefly move backwards when a presentation
        // callback races the display link. Do not rewind the marker's own
        // elapsed time; AMLL advances InterludeDots by positive deltas and
        // therefore keeps an in-flight entrance from replaying.
        let dotsMedia = max(media, gapLastMedia)
        gapLastMedia = dotsMedia
        let sample = interludeSample(
            elapsed: dotsMedia-gapEntrance,
            duration: gap.range.end-gapEntrance,
            profile: configuration.profile
        )
        let dotScale = configuration.interludeDotScale.isFinite
            ? min(4,max(0.25,configuration.interludeDotScale))
            : 1
        let size = max(1,configuration.fontSize*0.3*dotScale)
        let step = size*1.7
        setDotsHidden(false)
        // Entrance and exit are a single global fade. Per-dot progress is
        // represented by the inactive-to-active color below, so all surfaces
        // retain an actual inactive state instead of forcing three bright dots.
        dots.opacity = Float(Curves.clamp(sample.opacity))

        let nextIndex = min(frames.count-1,max(0,gap.anchor+1))
        let leadingX = leadingXs.indices.contains(nextIndex)
            ? leadingXs[nextIndex]
            : (bounds.width <= 500 ? 20.0 : configuration.fontSize)
        // The transform is centered. Keep the physical left tangent pinned to
        // the lyric leading edge while the marker breathes. This is equivalent
        // to aligning the largest state (the important boundary) and avoids
        // Core Animation rounding/anchor differences making the expanded dots
        // spill past the lyric edge.
        let dotWidth = size + step*2
        let dotHeight = interludeMarkerHeight
        // Pin the fully expanded marker to the lyric leading edge. At smaller
        // breathing states it remains slightly inset instead of protruding
        // past the text column.
        let peakScale = 0.7*1.05
        let dotX = leadingX + dotWidth*(peakScale-1)/2

        let nextTop = frames[nextIndex].y
        let previousBottom: Double
        if gap.anchor >= 0, frames.indices.contains(gap.anchor) {
            previousBottom = frames[gap.anchor].y + frames[gap.anchor].height
        } else {
            previousBottom = nextTop - interludeSlotHeight
        }
        // The marker is attached to the preceding row's bottom edge with a
        // fixed margin. Intro gaps use the virtual active anchor calculated
        // above; normal gaps use the same slot contract between real rows.
        let centerY = gap.anchor == -1 && introMarkerY != nil
            ? introMarkerY!
            : previousBottom + interludeMarkerMargin + dotHeight/2
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
            dotLayers[i].isHidden = false
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
        let now = previousHost ?? CACurrentMediaTime()
        if let group = groups.first(where: { group in
            guard group.opacity.value(now) > 0.01 else { return false }
            let reveal = group.reveal.value(now)
            let height = group.layout.collapsedHeight
                + (group.layout.expandedHeight - group.layout.collapsedHeight) * reveal
            let y = group.y.value(now)
            return point.y >= y && point.y < y + height
        }) {
            return group.index
        }
        return lastFrame?.groups.first {
            $0.opacity > 0.01 && point.y >= $0.y && point.y < $0.y + $0.height
        }?.index
    }
    private func lyricViewportContains(_ point: CGPoint) -> Bool {
        guard !isPointerInteractionSuppressed,
              bounds.contains(point)
        else { return false }
        // SwiftUI's fullscreen mask/offset can make AppKit's `visibleRect`
        // describe only a lower slice of this layer-backed view. The visual
        // effect is row-gated by `pointerRegionContains`; using `bounds` here
        // keeps the complete lyric column hittable while still rejecting
        // points outside the hosted window and covered mini-player.
        return true
    }
    private func pointerRegionContains(_ point: CGPoint) -> Bool {
        guard lyricViewportContains(point) else { return false }
        // The NSView is intentionally taller than the masked fullscreen
        // viewport. Only a rendered lyric row is a hover surface; whitespace,
        // overbleed and the area below the embedded window must stay inert.
        return groupIndex(at: point) != nil
    }
    private func pointerIsInsideWindow(_ window: NSWindow) -> Bool {
        window.isVisible
            && !window.isMiniaturized
            && window.frame.contains(NSEvent.mouseLocation)
    }
    public func seekTime(forGroup index: Int) -> Double? {
        guard prepared.indices.contains(index) else { return nil }
        return max(0,prepared[index].source.main.range.start+configuration.timing.seekOffset)
    }
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let window, event.window === window,
              pointerIsInsideWindow(window),
              pointerRegionContains(point),
              let i = groupIndex(at: point),
              let time = seekTime(forGroup:i)
        else {
            setPointerInside(false)
            return
        }
        setPointerInside(true)
        interaction.resume(); onSeek?(time); wake()
        // A click can move focus to the lyric view without delivering the
        // matching tracking-area exit when fullscreen changes its host. Read
        // the window's authoritative pointer location after the seek so a
        // pointer that is already outside cannot leave blur suppressed.
        DispatchQueue.main.async { [weak self] in self?.reconcilePointerTracking() }
    }
    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        reconcilePointerTracking()
    }
    public override func scrollWheel(with event: NSEvent) {
        guard lyricViewportContains(convert(event.locationInWindow, from: nil)) else {
            setPointerInside(false)
            return
        }
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
        // Do not use `.inVisibleRect`: SwiftUI's fullscreen mask/offset can
        // make AppKit's visibleRect cover only a lower slice of this host.
        // Row/window checks below still keep the visual hover effect strict.
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.activeInActiveApp,.mouseEnteredAndExited,.mouseMoved],owner:self))
    }
    public func setPointerInside(_ inside: Bool, hostTime: Double = CACurrentMediaTime()) {
        let nextInside = inside && !isPointerInteractionSuppressed
        hoverInside = nextInside
        if !nextInside {
            clearUntil = hostTime+configuration.motion.pointerExitDelay
            hoveredIndex = nil
            interaction.pointerExited(now: hostTime)
        }
        wake()
    }
    public func setPointerInteractionSuppressed(_ suppressed: Bool, hostTime: Double = CACurrentMediaTime()) {
        guard isPointerInteractionSuppressed != suppressed else {
            if suppressed { setPointerInside(false, hostTime: hostTime) }
            return
        }
        isPointerInteractionSuppressed = suppressed
        if suppressed {
            setPointerInside(false, hostTime: hostTime)
        } else {
            // The overlay may disappear while the mouse is already over a
            // lyric. Reconcile from the authoritative screen position instead
            // of waiting for a new mouse-moved event.
            reconcilePointerTracking(hostTime: hostTime)
        }
    }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Scrolling must remain possible in the whitespace around the last
        // visible row. Hover/click highlighting remains row-gated above, but
        // using that gate for hit testing strands the surface at the scroll
        // boundary when the pointer is no longer over a stale frame row.
        guard lyricViewportContains(point) else { return nil }
        // LyricsView renders into CALayers and has no interactive NSView
        // descendants. Returning self avoids another AppKit visibleRect
        // intersection after the explicit bounds gate above.
        return self
    }
    public override func mouseEntered(with event: NSEvent) { mouseMoved(with:event) }
    public override func mouseExited(with event: NSEvent) { setPointerInside(false) }
    public override func mouseMoved(with event: NSEvent) {
        guard let window, event.window === window, pointerIsInsideWindow(window) else {
            setPointerInside(false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard pointerRegionContains(point) else {
            setPointerInside(false)
            return
        }
        setPointerInside(true)
        hoveredIndex = groupIndex(at: point)
    }
    private func reconcilePointerTracking(hostTime: Double = CACurrentMediaTime()) {
        // Offscreen/unit-test surfaces have no window-backed pointer to query;
        // leave their explicitly supplied interaction state untouched.
        guard let window else { return }
        guard !isPointerInteractionSuppressed,
              pointerIsInsideWindow(window)
        else {
            if hoverInside { setPointerInside(false, hostTime: hostTime) }
            return
        }
        // `NSEvent.mouseLocation` is the current screen position, whereas
        // `mouseLocationOutsideOfEventStream` may remain at the last event
        // while a fullscreen host is being reparented.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        if pointerRegionContains(point) {
            if !hoverInside { setPointerInside(true, hostTime: hostTime) }
            hoveredIndex = groupIndex(at: point)
        } else if hoverInside {
            setPointerInside(false, hostTime: hostTime)
        }
    }
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard pointerRegionContains(point), let i = groupIndex(at: point) else { return nil }
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

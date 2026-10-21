import AppKit
import ObjectiveC
import Observation
import SwiftUI

/// Motion values resolved by the view that starts a drag, so the window layer
/// follows the same MotionKit policy as the list it came from.
struct LibraryTrackDragMotion {
    var control: Animation?
    var settle: Animation?
    var settleDuration: TimeInterval
}

/// Everything a row hands to the window when it starts a drag on its own.
struct LibraryTrackDragStart {
    let payload: LibraryTrackDragPayload
    /// Row cards, top card first. Each card already carries its environment.
    let cards: [AnyView]
    let count: Int
    let cardHeight: CGFloat
    let accentColor: Color
    let backgroundColor: Color
    let colorScheme: ColorScheme
    let motion: LibraryTrackDragMotion
    var onSessionChanged: ((Bool) -> Void)?
    var onSinkDropCompleted: ((LibraryTrackDropTarget) -> Void)?
}

/// Where accepted cards shrink to inside a drop target.
enum LibraryTrackDropSinkAnchor {
    case center
    case leading(inset: CGFloat)

    func point(in frame: CGRect) -> CGPoint {
        switch self {
        case .center:
            return CGPoint(x: frame.midX, y: frame.midY)
        case let .leading(inset):
            return CGPoint(x: frame.minX + min(inset, frame.width / 2), y: frame.midY)
        }
    }
}

/// Geometry shared by the AppKit event boundary and the SwiftUI overlay.
enum LibraryTrackDragGeometry {
    static func topLeftRect(_ rect: CGRect, in bounds: CGRect, isFlipped: Bool) -> CGRect {
        CGRect(
            x: rect.minX - bounds.minX,
            y: isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func topLeftPoint(_ point: CGPoint, in bounds: CGRect, isFlipped: Bool) -> CGPoint {
        CGPoint(
            x: point.x - bounds.minX,
            y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        )
    }

    static func containsDropPoint(
        _ point: CGPoint, bounds: CGRect, visibleRect: CGRect, cornerRadius: CGFloat
    ) -> Bool {
        guard bounds.intersection(visibleRect).contains(point) else { return false }
        guard cornerRadius > 0 else { return true }
        return CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ).contains(point)
    }

    static func sinkAnchor(at point: CGPoint, in frame: CGRect) -> UnitPoint {
        guard frame.width > 0, frame.height > 0 else { return .center }
        return UnitPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }
}

/// The sidebar, the track list and the Mini Player live in separate hosting
/// views. One window-level layer carries the cards across those boundaries.
///
/// Two kinds of drags share it:
/// - Rows that register a source anchor are tracked here with AppKit mouse
///   events, so table-hosted cells do not depend on SwiftUI gesture arbitration.
///   The window owns their cards from pickup to landing.
/// - The multiselect list keeps its own gesture, gathering, reordering and
///   settling. It only publishes its cards here; the window decides whether a
///   release lands in a target or goes back to the list.
@MainActor
final class LibraryTrackDragWindowSession {
    struct SourceHandlers {
        /// Escape, window deactivation or a rejected drop: the list animates
        /// its cards home and then calls `endSourceDrag`.
        var returnHome: () -> Void
        /// The cards were accepted and are sinking into the target. The list
        /// restores its rows at once; the window finishes the animation.
        var detach: (LibraryTrackDropTarget) -> Void
    }

    private enum Owner { case window, source }
    private enum Phase { case dragging, dropping, settling }

    private struct Press {
        weak var source: LibraryTrackDragSourceView?
        let windowPoint: NSPoint
    }

    private weak var window: NSWindow?
    private var destinations: [ObjectIdentifier: WeakDestination] = [:]
    private var sources: [ObjectIdentifier: WeakSource] = [:]
    private weak var hoveredDestination: LibraryTrackDropAnchorView?
    private var overlay: LibraryTrackDragOverlayHost?
    private let presentation = LibraryTrackDragPresentation()

    private var activeID: UUID?
    private var owner: Owner = .window
    private var phase: Phase = .dragging
    private var payload: LibraryTrackDragPayload?
    private var motion = LibraryTrackDragMotion(control: nil, settle: nil, settleDuration: 0)

    // Window-owned drag state.
    private var windowStart: LibraryTrackDragStart?
    private weak var windowSource: LibraryTrackDragSourceView?
    private var windowOrigin: CGRect = .zero
    private var grabOffset: CGPoint = .zero
    private var pendingPress: Press?

    // Source-owned drag state.
    private var sourceHandlers: SourceHandlers?

    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var dropTask: Task<Void, Never>?

    private let dragThreshold: CGFloat = 4

    init(window: NSWindow) { self.window = window }

    var hasActiveDrag: Bool { activeID != nil }

    /// True while the window, not the list, owns a drag the list started.
    func isFinishingDrop(_ id: UUID) -> Bool { activeID == id && owner == .window }

    // MARK: - Registration

    func register(_ view: LibraryTrackDropAnchorView) {
        destinations[ObjectIdentifier(view)] = WeakDestination(view)
        // Disclosure can create rows during a SwiftUI update. Deliver hover
        // state after that pass rather than mutating its bindings in AppKit's
        // viewDidMoveToWindow callback.
        if activeID != nil, phase == .dragging {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeID != nil, self.phase == .dragging else { return }
                self.updateHover()
            }
        }
    }

    func unregister(_ view: LibraryTrackDropAnchorView) {
        destinations.removeValue(forKey: ObjectIdentifier(view))
        if hoveredDestination === view {
            hoveredDestination = nil
            let clearHighlight = view.setTargeted
            DispatchQueue.main.async { [weak view] in
                if let view, view.window?.libraryTrackDragSession.hoveredDestination === view { return }
                clearHighlight?(false)
            }
        }
    }

    func register(_ view: LibraryTrackDragSourceView) {
        sources[ObjectIdentifier(view)] = WeakSource(view)
        installMouseMonitorIfNeeded()
    }

    func unregister(_ view: LibraryTrackDragSourceView) {
        sources.removeValue(forKey: ObjectIdentifier(view))
        if pendingPress?.source === view { pendingPress = nil }
    }

    // MARK: - Source-owned drags (multiselect list)

    func beginSourceDrag(
        from view: NSView,
        payload: LibraryTrackDragPayload,
        content: AnyView,
        frame: CGRect,
        motion: LibraryTrackDragMotion,
        handlers: SourceHandlers
    ) -> UUID? {
        guard activeID == nil, let overlay = makeOverlay(from: view) else { return nil }
        let id = UUID()
        activeID = id
        owner = .source
        phase = .dragging
        self.payload = payload
        self.motion = motion
        sourceHandlers = handlers
        pendingPress = nil

        presentation.content = .custom(content)
        presentation.frame = overlayRect(frame, from: view, in: overlay)
        presentation.scale = 1
        presentation.scaleAnchor = .center
        presentation.opacity = 1
        presentation.isOverTarget = false
        overlay.layoutSubtreeIfNeeded()
        installDragMonitors()
        updateHover()
        return id
    }

    /// Returns true while the pointer is over a drop target, so the list can
    /// pause reordering and auto-scroll.
    @discardableResult
    func updateSourceDrag(
        _ id: UUID,
        from view: NSView,
        frame: CGRect,
        animation: Animation? = nil
    ) -> Bool {
        guard activeID == id, owner == .source, phase != .dropping, let overlay else { return false }
        withAnimation(animation) {
            presentation.frame = overlayRect(frame, from: view, in: overlay)
        }
        guard phase == .dragging else { return false }
        updateHover()
        return hoveredDestination != nil
    }

    /// Returns false when the release belongs to the list itself.
    @discardableResult
    func releaseSourceDrag(_ id: UUID) -> Bool {
        guard activeID == id, owner == .source, phase == .dragging else { return false }
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.window === window {
            setHoveredDestination(destination(atWindowPoint: event.locationInWindow))
        } else {
            updateHover()
        }
        guard let destination = hoveredDestination, destination.performDrop != nil else { return false }
        drop(on: destination)
        return true
    }

    /// The list's own settle or return animation has started; hover state no
    /// longer applies.
    func settleSourceDrag(_ id: UUID) {
        guard activeID == id, owner == .source else { return }
        phase = .settling
        setHoveredDestination(nil)
        setOverTarget(false)
    }

    func endSourceDrag(_ id: UUID) {
        guard activeID == id, owner == .source else { return }
        end()
    }

    // MARK: - Window-owned drags (single rows and other sources)

    private func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }

    private func handleMouse(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        switch event.type {
        case .leftMouseDown:
            pendingPress = nil
            guard activeID == nil,
                  !event.modifierFlags.contains(.control),
                  window.attachedSheet == nil,
                  let source = source(atWindowPoint: event.locationInWindow) else { return }
            pendingPress = Press(source: source, windowPoint: event.locationInWindow)
        case .leftMouseDragged:
            if activeID == nil, let press = pendingPress {
                let dx = event.locationInWindow.x - press.windowPoint.x
                let dy = event.locationInWindow.y - press.windowPoint.y
                guard hypot(dx, dy) >= dragThreshold else { return }
                pendingPress = nil
                beginWindowDrag(press)
            } else if activeID != nil, owner == .window, phase == .dragging {
                moveWindowDrag(at: event.locationInWindow)
            }
        case .leftMouseUp:
            pendingPress = nil
            if activeID != nil, owner == .window, phase == .dragging {
                releaseWindowDrag(at: event.locationInWindow)
            }
        default:
            break
        }
    }

    private func source(atWindowPoint point: NSPoint) -> LibraryTrackDragSourceView? {
        guard let window, let contentView = window.contentView else { return nil }
        sources = sources.filter { $0.value.view != nil }
        let hitPoint = contentView.superview?.convert(point, from: nil) ?? point
        guard let hit = contentView.hitTest(hitPoint), !Self.isInteractiveControl(hit) else { return nil }
        let candidates = sources.values.compactMap(\.view).filter { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor, view.makeStart != nil else { return false }
            guard view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil)) else { return false }
            // Chrome above a scrolled list (toolbar, scroller) owns its own clicks.
            return hit.enclosingScrollView === view.enclosingScrollView
        }
        return candidates.min { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    private static func isInteractiveControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSScroller || candidate is NSTextView { return true }
            if let field = candidate as? NSTextField, field.isEditable { return true }
            current = candidate.superview
        }
        return false
    }

    private func beginWindowDrag(_ press: Press) {
        guard let source = press.source, let start = source.makeStart?(), !start.cards.isEmpty,
              let overlay = makeOverlay(from: source) else { return }
        let id = UUID()
        activeID = id
        owner = .window
        phase = .dragging
        payload = start.payload
        motion = start.motion
        windowStart = start
        windowSource = source

        let visibleCards = min(start.cards.count, LibraryTrackDragPileView.maxVisibleCards)
        let rowFrame = overlayRect(source.bounds, from: source, in: overlay)
        windowOrigin = CGRect(
            x: rowFrame.minX,
            y: rowFrame.minY,
            width: rowFrame.width,
            height: start.cardHeight + CGFloat(visibleCards - 1) * LibraryTrackDragPileView.cardOverlap
        )
        let pressPoint = overlayPoint(fromWindow: press.windowPoint, in: overlay)
        // Horizontal pickup stays where the user grabbed the row. Vertically
        // the front card is centred on the pointer, independent of pile depth.
        grabOffset = CGPoint(x: pressPoint.x - windowOrigin.minX, y: start.cardHeight / 2)

        presentation.content = .pile(
            cards: start.cards, count: start.count, cardHeight: start.cardHeight,
            accentColor: start.accentColor, backgroundColor: start.backgroundColor,
            colorScheme: start.colorScheme
        )
        presentation.glassOpacity = 0
        presentation.isSettled = true
        presentation.scale = 1
        presentation.scaleAnchor = .center
        presentation.opacity = 1
        presentation.isOverTarget = false
        presentation.frame = windowOrigin
        moveWindowDrag()
        overlay.layoutSubtreeIfNeeded()
        installDragMonitors()
        start.onSessionChanged?(true)

        // Lift on the next pass so the card first renders flush with its row.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeID == id, self.phase == .dragging else { return }
            withAnimation(self.motion.control) {
                self.presentation.glassOpacity = 1
                self.presentation.isSettled = false
            }
        }
    }

    private func moveWindowDrag(at windowPoint: NSPoint? = nil) {
        guard let overlay, let window else { return }
        let point = windowPoint ?? window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointer = overlayPoint(fromWindow: point, in: overlay)
        presentation.frame.origin = CGPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
        setHoveredDestination(destination(atWindowPoint: point))
    }

    private func releaseWindowDrag(at windowPoint: NSPoint) {
        // Resolve the drop from this mouse-up event, never from cached hover.
        moveWindowDrag(at: windowPoint)
        if let destination = hoveredDestination, destination.performDrop != nil {
            drop(on: destination)
        } else {
            returnWindowDragHome()
        }
    }

    private func returnWindowDragHome() {
        guard let id = activeID, owner == .window else { return }
        phase = .settling
        setHoveredDestination(nil)
        if let overlay, let source = windowSource, source.window === window {
            windowOrigin.origin = overlayRect(source.bounds, from: source, in: overlay).origin
        }
        withAnimation(motion.settle) {
            presentation.frame = windowOrigin
            presentation.scale = 1
            presentation.opacity = 1
            presentation.isOverTarget = false
            presentation.glassOpacity = 0
            presentation.isSettled = true
        }
        finishAfterAnimation(id, target: nil)
    }

    // MARK: - Dropping

    private func drop(on destination: LibraryTrackDropAnchorView) {
        guard let id = activeID, let payload, let perform = destination.performDrop else { return }
        phase = .dropping
        let target = destination.target
        let sinkAnchor = destination.sinkAnchor
        dropTask = Task { @MainActor [weak self, weak destination] in
            let succeeded = await perform(payload)
            guard let self, self.activeID == id, !Task.isCancelled else { return }
            let frame = destination.flatMap { self.destinationFrame($0) }
            self.setHoveredDestination(nil)
            if succeeded, let target, Self.sinksIntoTarget(target), let frame {
                self.sink(id, into: target, at: sinkAnchor.point(in: frame))
            } else {
                // Rejected drops and metadata edits leave the cards at full
                // size and send them back to where they came from.
                self.returnHome(id)
            }
        }
    }

    private func returnHome(_ id: UUID) {
        guard activeID == id else { return }
        switch owner {
        case .window:
            returnWindowDragHome()
        case .source:
            phase = .settling
            setOverTarget(false)
            sourceHandlers?.returnHome()
        }
    }

    private func sink(_ id: UUID, into target: LibraryTrackDropTarget, at anchor: CGPoint) {
        if owner == .source {
            let handlers = sourceHandlers
            owner = .window
            sourceHandlers = nil
            handlers?.detach(target)
        }
        phase = .settling
        // Changing the pivot at scale 1 leaves the cards in place. Every point
        // then contracts towards the actual target, in this same overlay space.
        presentation.scaleAnchor = LibraryTrackDragGeometry.sinkAnchor(
            at: anchor, in: presentation.frame
        )
        withAnimation(motion.settle) {
            presentation.scale = 0
            presentation.isOverTarget = false
        }
        // Keep the cards opaque through landing. They disappear only after
        // reaching the target, using the same MotionKit settle as the list.
        finishAfterAnimation(id, target: target)
    }

    private func finishAfterAnimation(_ id: UUID, target: LibraryTrackDropTarget?) {
        dropTask?.cancel()
        let delay = motion.settleDuration
        dropTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, self.activeID == id, !Task.isCancelled else { return }
            let start = self.windowStart
            self.end()
            if let target { start?.onSinkDropCompleted?(target) }
        }
    }

    private static func sinksIntoTarget(_ target: LibraryTrackDropTarget) -> Bool {
        switch target {
        case .playlist, .playNow:
            return true
        case .artist, .album:
            return false
        }
    }

    // MARK: - Teardown

    private func end() {
        guard activeID != nil else { return }
        let start = windowStart
        activeID = nil
        dropTask?.cancel()
        dropTask = nil
        setHoveredDestination(nil)
        removeDragMonitors()
        overlay?.removeFromSuperview()
        overlay = nil
        presentation.content = .custom(AnyView(EmptyView()))
        payload = nil
        windowStart = nil
        windowSource = nil
        sourceHandlers = nil
        owner = .window
        phase = .dragging
        start?.onSessionChanged?(false)
    }

    private func cancelActiveDrag() {
        guard let id = activeID, phase == .dragging else { return }
        setHoveredDestination(nil)
        returnHome(id)
    }

    private func installDragMonitors() {
        guard let window else { return }
        removeDragMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53, self.activeID != nil else { return event }
            self.cancelActiveDrag()
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelActiveDrag() }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    private func removeDragMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    // MARK: - Geometry

    private func makeOverlay(from source: NSView) -> LibraryTrackDragOverlayHost? {
        guard let window, source.window === window, let container = window.contentView else { return nil }
        let host = LibraryTrackDragOverlayHost(rootView: LibraryTrackDragOverlay(presentation: presentation))
        // All geometry below is relative to contentView.bounds. A titlebar
        // safe-area inset here would move both the cards and their sink point.
        host.safeAreaRegions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        container.addSubview(host, positioned: .above, relativeTo: nil)
        overlay = host
        return host
    }

    /// SwiftUI positions the overlay content from its top-left corner,
    /// whatever the host's AppKit orientation is.
    private func overlayRect(_ rect: CGRect, from view: NSView, in overlay: NSView) -> CGRect {
        LibraryTrackDragGeometry.topLeftRect(
            overlay.convert(rect, from: view), in: overlay.bounds, isFlipped: overlay.isFlipped
        )
    }

    private func overlayPoint(fromWindow point: NSPoint, in overlay: NSView) -> CGPoint {
        LibraryTrackDragGeometry.topLeftPoint(
            overlay.convert(point, from: nil), in: overlay.bounds, isFlipped: overlay.isFlipped
        )
    }

    private func destinationFrame(_ view: NSView) -> CGRect? {
        let visibleBounds = view.bounds.intersection(view.visibleRect)
        guard let overlay, view.window === window, !visibleBounds.isEmpty else { return nil }
        return overlayRect(visibleBounds, from: view, in: overlay)
    }

    // MARK: - Hover

    private func updateHover() {
        guard let window else { return }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setHoveredDestination(destination(atWindowPoint: point))
    }

    func destination(atWindowPoint point: NSPoint) -> LibraryTrackDropAnchorView? {
        guard let window else { return nil }
        destinations = destinations.filter { $0.value.view != nil }
        let hits = destinations.values.compactMap(\.view).filter { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.alphaValue > 0, view.performDrop != nil else { return false }
            // NSView does not clip to bounds by default on macOS 14+. Its
            // visibleRect can extend across the containing pane, so it alone
            // cannot define a Mini Player or sidebar row's drop region.
            return LibraryTrackDragGeometry.containsDropPoint(
                view.convert(point, from: nil), bounds: view.bounds,
                visibleRect: view.visibleRect, cornerRadius: view.cornerRadius
            )
        }
        // Prefer a concrete row over a containing disclosure/group target.
        return hits.min { lhs, rhs in
            if (lhs.target != nil) != (rhs.target != nil) { return lhs.target != nil }
            return lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    private func setHoveredDestination(_ view: LibraryTrackDropAnchorView?) {
        guard hoveredDestination !== view else { return }
        hoveredDestination?.setTargeted?(false)
        hoveredDestination = view
        view?.setTargeted?(true)
        setOverTarget(view?.target != nil)
    }

    private func setOverTarget(_ isOver: Bool) {
        guard presentation.isOverTarget != isOver else { return }
        withAnimation(motion.control) { presentation.isOverTarget = isOver }
    }

    private struct WeakDestination {
        weak var view: LibraryTrackDropAnchorView?
        init(_ view: LibraryTrackDropAnchorView) { self.view = view }
    }

    private struct WeakSource {
        weak var view: LibraryTrackDragSourceView?
        init(_ view: LibraryTrackDragSourceView) { self.view = view }
    }
}

@MainActor
private var libraryTrackDragWindowKey: UInt8 = 0

extension NSWindow {
    @MainActor var libraryTrackDragSession: LibraryTrackDragWindowSession {
        if let existing = objc_getAssociatedObject(self, &libraryTrackDragWindowKey) as? LibraryTrackDragWindowSession {
            return existing
        }
        let session = LibraryTrackDragWindowSession(window: self)
        objc_setAssociatedObject(self, &libraryTrackDragWindowKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }
}

// MARK: - Overlay

@MainActor @Observable
private final class LibraryTrackDragPresentation {
    enum Content {
        case pile(
            cards: [AnyView], count: Int, cardHeight: CGFloat,
            accentColor: Color, backgroundColor: Color, colorScheme: ColorScheme
        )
        case custom(AnyView)
    }

    var content: Content = .custom(AnyView(EmptyView()))
    var frame: CGRect = .zero
    var scale: CGFloat = 1
    var scaleAnchor: UnitPoint = .center
    var opacity: Double = 1
    var glassOpacity: Double = 1
    var isSettled = false
    var isOverTarget = false
}

private struct LibraryTrackDragOverlay: View {
    let presentation: LibraryTrackDragPresentation

    var body: some View {
        content
            .frame(width: presentation.frame.width, height: presentation.frame.height, alignment: .topLeading)
            .scaleEffect(presentation.scale, anchor: presentation.scaleAnchor)
            .opacity(presentation.opacity)
            .position(x: presentation.frame.midX, y: presentation.frame.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.content {
        case let .pile(cards, count, cardHeight, accentColor, backgroundColor, colorScheme):
            LibraryTrackDragPileView(
                cards: cards,
                count: count,
                cardHeight: cardHeight,
                accentColor: accentColor,
                backgroundColor: backgroundColor,
                glassOpacity: presentation.glassOpacity,
                isSettled: presentation.isSettled
            )
            .environment(\.colorScheme, colorScheme)
        case let .custom(view):
            view
        }
    }
}

/// The reorder list's floating pile, for drags the window owns.
struct LibraryTrackDragPileView: View {
    static let maxVisibleCards = 5
    static let cardOverlap: CGFloat = 12

    let cards: [AnyView]
    let count: Int
    let cardHeight: CGFloat
    let accentColor: Color
    let backgroundColor: Color
    let glassOpacity: Double
    let isSettled: Bool

    var body: some View {
        let visible = Array(cards.prefix(Self.maxVisibleCards).enumerated())
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .topLeading) {
                ForEach(visible, id: \.offset) { depth, card in
                    card
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: cardHeight, alignment: .topLeading)
                        .modifier(LibraryTrackDragCardSurface(
                            cornerRadius: Constants.Layout.TrackRow.cornerRadius,
                            backgroundColor: backgroundColor,
                            glassOpacity: glassOpacity
                        ))
                        .offset(
                            x: isSettled ? 0 : Self.pileXOffset(depth),
                            y: isSettled ? 0 : CGFloat(depth) * Self.cardOverlap
                        )
                        .rotationEffect(.degrees(isSettled ? 0 : Self.pileRotation(depth)), anchor: .center)
                        .zIndex(Double(visible.count - depth))
                }
            }
            // UI exception: the lifted pile keeps the original reorder card's
            // shadow so it reads as floating above the rows it leaves.
            .shadow(
                color: GlassStyleTokens.subtleShadowColor.opacity(glassOpacity),
                radius: GlassStyleTokens.subtleShadowRadius + 5,
                x: 0,
                y: 5
            )

            if count > 1 && !isSettled {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accentColor))
                    .offset(x: 5, y: -6)
                    .transition(.identity)
            }
        }
    }

    private static func pileXOffset(_ depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        return depth.isMultiple(of: 2) ? 4 : -4
    }

    private static func pileRotation(_ depth: Int) -> Double {
        guard depth > 0 else { return 0 }
        return depth.isMultiple(of: 2) ? 1.6 : -1.6
    }
}

/// Keep the original reorder card's row layout on an opaque theme surface.
/// UI exception: its hairline edge is carried over unchanged from that card;
/// it separates the floating card from rows of the same tint underneath.
struct LibraryTrackDragCardSurface: ViewModifier {
    let cornerRadius: CGFloat
    let backgroundColor: Color
    var glassOpacity: Double = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .background(
                shape
                    .fill(backgroundColor)
                    // Theme surfaces may carry alpha; an opaque backing keeps
                    // the lifted card solid in every app colour mode.
                    .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            )
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(0.16 * glassOpacity), lineWidth: 0.8)
            )
            .clipShape(shape)
    }
}

private final class LibraryTrackDragOverlayHost: NSHostingView<LibraryTrackDragOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Source anchor

struct LibraryTrackDragSourceAnchor: NSViewRepresentable {
    let makeStart: () -> LibraryTrackDragStart?

    func makeNSView(context: Context) -> LibraryTrackDragSourceView {
        let view = LibraryTrackDragSourceView()
        view.makeStart = makeStart
        return view
    }

    func updateNSView(_ view: LibraryTrackDragSourceView, context: Context) {
        view.makeStart = makeStart
    }

    static func dismantleNSView(_ view: LibraryTrackDragSourceView, coordinator: ()) {
        view.window?.libraryTrackDragSession.unregister(view)
        view.makeStart = nil
    }
}

final class LibraryTrackDragSourceView: NSView {
    var makeStart: (() -> LibraryTrackDragStart?)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        window?.libraryTrackDragSession.unregister(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.libraryTrackDragSession.register(self)
    }
}

// MARK: - Drop anchor

struct LibraryTrackDropAnchor: NSViewRepresentable {
    let target: LibraryTrackDropTarget?
    var sinkAnchor: LibraryTrackDropSinkAnchor = .center
    var cornerRadius: CGFloat = 0
    let setTargeted: (Bool) -> Void
    let performDrop: (LibraryTrackDragPayload) async -> Bool

    func makeNSView(context: Context) -> LibraryTrackDropAnchorView {
        let view = LibraryTrackDropAnchorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LibraryTrackDropAnchorView, context: Context) {
        view.target = target
        view.sinkAnchor = sinkAnchor
        view.cornerRadius = cornerRadius
        view.setTargeted = setTargeted
        view.performDrop = performDrop
    }

    static func dismantleNSView(_ view: LibraryTrackDropAnchorView, coordinator: ()) {
        view.window?.libraryTrackDragSession.unregister(view)
        view.setTargeted = nil
        view.performDrop = nil
    }
}

final class LibraryTrackDropAnchorView: NSView {
    var target: LibraryTrackDropTarget?
    var sinkAnchor: LibraryTrackDropSinkAnchor = .center
    var cornerRadius: CGFloat = 0
    var setTargeted: ((Bool) -> Void)?
    var performDrop: ((LibraryTrackDragPayload) async -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        window?.libraryTrackDragSession.unregister(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.libraryTrackDragSession.register(self)
    }
}

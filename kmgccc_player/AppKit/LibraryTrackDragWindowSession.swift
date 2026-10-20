import AppKit
import ObjectiveC
import Observation
import SwiftUI

/// The sidebar and track table have separate hosting views. A window-local
/// overlay carries the existing SwiftUI cards across that boundary; the list
/// continues to own selection, insertion positions and reorder persistence.
@MainActor
final class LibraryTrackDragWindowSession {
    private weak var window: NSWindow?
    private var destinations: [ObjectIdentifier: WeakDestination] = [:]
    private weak var hoveredDestination: LibraryTrackDropAnchorView?
    private var overlay: LibraryTrackDragOverlayHost?
    private let presentation = LibraryTrackDragPresentation()
    private var sessionID: UUID?
    private var payload: LibraryTrackDragPayload?
    private var origin: CGRect = .zero
    private var animation: Animation?
    private var completionDelay: TimeInterval = 0
    private var onCancel: (() -> Void)?
    private var onComplete: ((LibraryTrackDropTarget?) -> Void)?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var dropTask: Task<Void, Never>?
    private var isCompleting = false

    init(window: NSWindow) { self.window = window }

    var hasActiveDrag: Bool { sessionID != nil }
    func isFinishingDrop(_ id: UUID) -> Bool { sessionID == id && isCompleting }

    func settleInSource(_ id: UUID) {
        guard sessionID == id else { return }
        isCompleting = true
        setHoveredDestination(nil)
    }

    func register(_ view: LibraryTrackDropAnchorView) {
        destinations[ObjectIdentifier(view)] = WeakDestination(view)
        // Disclosure can create rows during a SwiftUI update. Deliver hover
        // state after that pass rather than mutating its bindings in AppKit's
        // viewDidMoveToWindow callback.
        if sessionID != nil, !isCompleting {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID != nil, !self.isCompleting else { return }
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

    func begin(
        from source: NSView,
        payload: LibraryTrackDragPayload,
        content: AnyView,
        frame: CGRect,
        animation: Animation?,
        completionDelay: TimeInterval,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (LibraryTrackDropTarget?) -> Void
    ) -> UUID? {
        guard let window, source.window === window, let container = window.contentView else { return nil }
        guard sessionID == nil else { return nil }
        let id = UUID()
        sessionID = id
        self.payload = payload
        self.animation = animation
        self.completionDelay = completionDelay
        self.onCancel = onCancel
        self.onComplete = onComplete
        isCompleting = false

        let host = LibraryTrackDragOverlayHost(rootView: LibraryTrackDragOverlay(presentation: presentation))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        container.addSubview(host, positioned: .above, relativeTo: nil)
        overlay = host
        origin = host.convert(frame, from: source)
        presentation.frame = origin
        presentation.content = content
        presentation.scale = 1
        presentation.opacity = 1
        host.rootView = LibraryTrackDragOverlay(presentation: presentation)
        host.layoutSubtreeIfNeeded()
        installMonitors(in: window)
        updateHover()
        return id
    }

    @discardableResult
    func update(_ id: UUID, from source: NSView, content: AnyView, frame: CGRect, animation: Animation? = nil) -> Bool {
        guard sessionID == id, !isCompleting, let overlay, source.window === window else { return false }
        withAnimation(animation) {
            presentation.content = content
            presentation.frame = overlay.convert(frame, from: source)
        }
        updateHover()
        return hoveredDestination != nil
    }

    /// Returns false when the release belongs to the source list's reorder
    /// gesture. Membership changes finish before the cards enter the target.
    @discardableResult
    func finish(_ id: UUID) -> Bool {
        guard sessionID == id, !isCompleting, let payload else { return false }
        updateHover()
        guard let destination = hoveredDestination, let perform = destination.performDrop else { return false }
        isCompleting = true
        let target = destination.target
        let targetFrame = destinationFrame(destination)
        dropTask = Task { @MainActor [weak self, weak destination] in
            let succeeded = await perform(payload)
            guard let self, self.sessionID == id, !Task.isCancelled else { return }
            guard succeeded else {
                self.isCompleting = false
                self.setHoveredDestination(nil)
                self.onCancel?()
                return
            }
            let frame = destination.flatMap { self.destinationFrame($0) } ?? targetFrame
            withAnimation(self.animation) {
                if let frame {
                    // A row's leading artwork is the visual receptacle.
                    self.presentation.frame.origin = CGPoint(
                        x: frame.minX + min(22, frame.width / 2) - self.presentation.frame.width / 2,
                        y: frame.midY - self.presentation.frame.height / 2
                    )
                }
                self.presentation.scale = 0.035
                self.presentation.opacity = 0
            }
            await self.waitForAnimation()
            guard self.sessionID == id, !Task.isCancelled else { return }
            let complete = self.onComplete
            self.end(id)
            complete?(target)
        }
        return true
    }

    func returnToSource(_ id: UUID) {
        guard sessionID == id, !isCompleting else { return }
        isCompleting = true
        setHoveredDestination(nil)
        withAnimation(animation) {
            presentation.frame = origin
            presentation.scale = 1
            presentation.opacity = 0
        }
        dropTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForAnimation()
            guard self.sessionID == id, !Task.isCancelled else { return }
            let complete = self.onComplete
            self.end(id)
            complete?(nil)
        }
    }

    func end(_ id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil
        dropTask?.cancel()
        dropTask = nil
        setHoveredDestination(nil)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        overlay?.removeFromSuperview()
        overlay = nil
        presentation.content = AnyView(EmptyView())
        payload = nil
        onCancel = nil
        onComplete = nil
        isCompleting = false
    }

    private func waitForAnimation() async {
        guard completionDelay > 0 else { return }
        try? await Task.sleep(for: .seconds(completionDelay))
    }

    private func destinationFrame(_ view: NSView) -> CGRect? {
        guard let overlay, view.window === window, !view.visibleRect.isEmpty else { return nil }
        return overlay.convert(view.visibleRect, from: view)
    }

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
            return view.visibleRect.contains(view.convert(point, from: nil))
        }
        // Prefer a concrete row over a containing disclosure/group target.
        return hits.min { lhs, rhs in
            if (lhs.target != nil) != (rhs.target != nil) { return lhs.target != nil }
            return lhs.visibleRect.width * lhs.visibleRect.height < rhs.visibleRect.width * rhs.visibleRect.height
        }
    }

    private func setHoveredDestination(_ view: LibraryTrackDropAnchorView?) {
        guard hoveredDestination !== view else { return }
        hoveredDestination?.setTargeted?(false)
        hoveredDestination = view
        view?.setTargeted?(true)
    }

    private func installMonitors(in window: NSWindow) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else { return event }
            if !self.isCompleting {
                self.setHoveredDestination(nil)
                self.onCancel?()
            }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCompleting else { return }
                self.setHoveredDestination(nil)
                self.onCancel?()
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.sessionID else { return }
                let complete = self.onComplete
                self.end(id)
                complete?(nil)
            }
        }
    }

    private struct WeakDestination {
        weak var view: LibraryTrackDropAnchorView?
        init(_ view: LibraryTrackDropAnchorView) { self.view = view }
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

@MainActor @Observable
private final class LibraryTrackDragPresentation {
    var content = AnyView(EmptyView())
    var frame: CGRect = .zero
    var scale: CGFloat = 1
    var opacity: Double = 1
}

private struct LibraryTrackDragOverlay: View {
    let presentation: LibraryTrackDragPresentation

    var body: some View {
        presentation.content
            .frame(width: presentation.frame.width, height: presentation.frame.height, alignment: .topLeading)
            .scaleEffect(presentation.scale)
            .opacity(presentation.opacity)
            .position(x: presentation.frame.midX, y: presentation.frame.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private final class LibraryTrackDragOverlayHost: NSHostingView<LibraryTrackDragOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class LibraryTrackDragSourceReference {
    weak var view: NSView?
}

struct LibraryTrackDragSourceAnchor: NSViewRepresentable {
    let reference: LibraryTrackDragSourceReference

    func makeNSView(context: Context) -> NSView {
        let view = LibraryTrackDragSourceView()
        reference.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { reference.view = view }
}

private final class LibraryTrackDragSourceView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct LibraryTrackDropAnchor: NSViewRepresentable {
    let target: LibraryTrackDropTarget?
    let setTargeted: (Bool) -> Void
    let performDrop: (LibraryTrackDragPayload) async -> Bool

    func makeNSView(context: Context) -> LibraryTrackDropAnchorView {
        let view = LibraryTrackDropAnchorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LibraryTrackDropAnchorView, context: Context) {
        view.target = target
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

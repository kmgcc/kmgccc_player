import AppKit
import SwiftUI

/// Fullscreen artwork and controls share the complete window coordinate space.
/// AppKit must not reserve an invisible titlebar for window dragging over them.
@MainActor
final class FullscreenPlayerHostingView: NSHostingView<AnyView> {
    private enum WindowInteractionMetrics {
        static let resizeHitTarget: CGFloat = 10
    }

    var controlRects: [CGRect] = []
    private var checkingAccessibility = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isResizableHostWindow else { return }

        let edge = min(
            WindowInteractionMetrics.resizeHitTarget,
            min(bounds.width, bounds.height) / 2
        )
        let left = NSRect(x: bounds.minX, y: bounds.minY, width: edge, height: bounds.height)
        let right = NSRect(x: bounds.maxX - edge, y: bounds.minY, width: edge, height: bounds.height)
        let topY = isFlipped ? bounds.minY : bounds.maxY - edge
        let bottomY = isFlipped ? bounds.maxY - edge : bounds.minY
        let top = NSRect(
            x: bounds.minX + edge,
            y: topY,
            width: bounds.width - edge * 2,
            height: edge
        )
        let bottom = NSRect(
            x: bounds.minX + edge,
            y: bottomY,
            width: bounds.width - edge * 2,
            height: edge
        )

        addCursorRect(left, cursor: resizeCursor(at: .left))
        addCursorRect(right, cursor: resizeCursor(at: .right))
        addCursorRect(top, cursor: resizeCursor(at: .top))
        addCursorRect(bottom, cursor: resizeCursor(at: .bottom))
        addCursorRect(
            NSRect(x: bounds.minX, y: topY, width: edge, height: edge),
            cursor: resizeCursor(at: .topLeft)
        )
        addCursorRect(
            NSRect(x: bounds.maxX - edge, y: topY, width: edge, height: edge),
            cursor: resizeCursor(at: .topRight)
        )
        addCursorRect(
            NSRect(x: bounds.minX, y: bottomY, width: edge, height: edge),
            cursor: resizeCursor(at: .bottomLeft)
        )
        addCursorRect(
            NSRect(x: bounds.maxX - edge, y: bottomY, width: edge, height: edge),
            cursor: resizeCursor(at: .bottomRight)
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !checkingAccessibility, NSApp.currentEvent?.type == .leftMouseDown {
            // This view covers the window's content while embedded fullscreen is
            // active. Give the window perimeter its own resize hit target before
            // the titlebar-height drag region gets a chance to claim the event.
            if resizeEdges(at: local) != nil || isWindowDragPoint(local) {
                return self
            }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let window, let edges = resizeEdges(at: local) {
            resizeWindow(window, edges: edges, from: event)
        } else if isWindowDragPoint(local), let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private var isResizableHostWindow: Bool {
        guard let window else { return false }
        return window.styleMask.contains(.titled)
            && window.styleMask.contains(.resizable)
            && !window.styleMask.contains(.fullScreen)
    }

    private func resizeEdges(at point: NSPoint) -> FullscreenWindowResizeEdges? {
        guard isResizableHostWindow, bounds.contains(point) else { return nil }

        let edge = WindowInteractionMetrics.resizeHitTarget
        var edges: FullscreenWindowResizeEdges = []
        if point.x - bounds.minX <= edge { edges.insert(.left) }
        if bounds.maxX - point.x <= edge { edges.insert(.right) }
        if topDistance(for: point) <= edge { edges.insert(.top) }
        if bottomDistance(for: point) <= edge { edges.insert(.bottom) }
        return edges.isEmpty ? nil : edges
    }

    private func resizeWindow(
        _ window: NSWindow,
        edges: FullscreenWindowResizeEdges,
        from initialEvent: NSEvent
    ) {
        let initialFrame = window.frame
        let startPoint = window.convertPoint(toScreen: initialEvent.locationInWindow)
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        while let event = NSApp.nextEvent(
            matching: eventMask,
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            guard event.type == .leftMouseDragged else { break }

            let currentPoint = window.convertPoint(toScreen: event.locationInWindow)
            let deltaX = currentPoint.x - startPoint.x
            let deltaY = currentPoint.y - startPoint.y
            let minimumWidth = max(window.minSize.width, window.contentMinSize.width)
            let minimumHeight = max(window.minSize.height, window.contentMinSize.height)
            let maximumWidth = max(minimumWidth, window.maxSize.width)
            let maximumHeight = max(minimumHeight, window.maxSize.height)

            var width = initialFrame.width
            if edges.contains(.left) {
                width = min(max(initialFrame.width - deltaX, minimumWidth), maximumWidth)
            } else if edges.contains(.right) {
                width = min(max(initialFrame.width + deltaX, minimumWidth), maximumWidth)
            }

            var height = initialFrame.height
            if edges.contains(.bottom) {
                height = min(max(initialFrame.height - deltaY, minimumHeight), maximumHeight)
            } else if edges.contains(.top) {
                height = min(max(initialFrame.height + deltaY, minimumHeight), maximumHeight)
            }

            let x = edges.contains(.left) ? initialFrame.maxX - width : initialFrame.minX
            let y = edges.contains(.bottom) ? initialFrame.maxY - height : initialFrame.minY
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }

    private func topDistance(for point: NSPoint) -> CGFloat {
        isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
    }

    private func bottomDistance(for point: NSPoint) -> CGFloat {
        isFlipped ? bounds.maxY - point.y : point.y - bounds.minY
    }

    private func resizeCursor(at position: NSCursor.FrameResizePosition) -> NSCursor {
        NSCursor.frameResize(position: position, directions: .all)
    }

    private func isWindowDragPoint(_ point: NSPoint) -> Bool {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              bounds.contains(point)
        else { return false }
        let titlebarHeight = (window.contentView?.bounds.height ?? bounds.height) - window.contentLayoutRect.height
        guard topDistance(for: point) <= max(44, titlebarHeight) else { return false }
        let windowPoint = convert(point, to: nil)
        guard !controlRects.contains(where: { $0.contains(windowPoint) }) else { return false }
        return !hasAccessibleControl(at: window.convertPoint(toScreen: windowPoint))
    }

    /// Standard SwiftUI/AppKit/Web controls work without skin-specific annotations.
    /// Custom drawings use the same .skinControlRegion() marker as native lyric occlusion.
    private func hasAccessibleControl(at screenPoint: NSPoint) -> Bool {
        checkingAccessibility = true
        defer { checkingAccessibility = false }
        guard let element = accessibilityHitTest(screenPoint) as? any NSAccessibilityProtocol,
              let role = element.accessibilityRole() else { return false }
        let roles: Set<NSAccessibility.Role> = [
            .button, .menuButton, .popUpButton, .checkBox, .radioButton,
            .slider, .textField, .textArea, .comboBox, .link, .incrementor,
        ]
        return roles.contains(role)
    }
}

private struct FullscreenWindowResizeEdges: OptionSet {
    let rawValue: Int

    static let top = Self(rawValue: 1 << 0)
    static let left = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let right = Self(rawValue: 1 << 3)
}

/// Publishes actual layout rectangles to the local native host; there is no global
/// window state and no titlebar-size assumption in a skin or in its components.
struct FullscreenHostControlRegions: NSViewRepresentable {
    let rectangles: [CGRect]
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) {
        view.rectangles = rectangles
        view.publish()
    }

    final class RegionView: NSView {
        override var isFlipped: Bool { true }
        var rectangles: [CGRect] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); publish() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); publish() }
        func publish() {
            var ancestor = superview
            while let view = ancestor {
                if let host = view as? FullscreenPlayerHostingView {
                    host.controlRects = rectangles.map { convert($0, to: nil) }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

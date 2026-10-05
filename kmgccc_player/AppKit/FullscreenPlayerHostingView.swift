import AppKit
import SwiftUI

/// Fullscreen artwork and controls share the complete window coordinate space.
/// AppKit must not reserve an invisible titlebar for window dragging over them.
@MainActor
final class FullscreenPlayerHostingView: NSHostingView<AnyView> {
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !checkingAccessibility, NSApp.currentEvent?.type == .leftMouseDown,
           isWindowDragPoint(local) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isWindowDragPoint(convert(event.locationInWindow, from: nil)), let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func isWindowDragPoint(_ point: NSPoint) -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen), bounds.contains(point) else { return false }
        let topDistance = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        let titlebarHeight = (window.contentView?.bounds.height ?? bounds.height) - window.contentLayoutRect.height
        guard topDistance <= max(44, titlebarHeight) else { return false }
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

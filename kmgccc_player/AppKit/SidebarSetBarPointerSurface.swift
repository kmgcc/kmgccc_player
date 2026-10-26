import AppKit
import SwiftUI

/// Owns one pointer session above the whole editor. Source views may move or disappear
/// without cancelling the drag. Only actual button regions claim mouse-down events;
/// the rest of the carousel retains its normal scrolling and hover controls.
struct SidebarSetBarPointerSurface: NSViewRepresentable {
    var regions: [SidebarSetBarEditorRegion: CGRect]
    var isEnabled: Bool
    var onClick: (SidebarSetBarEditorRegion) -> Void
    var onBegin: (SidebarSetBarEditorRegion, CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onRelease: (CGPoint, CGSize) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        view.regions = regions
        view.isEnabled = isEnabled
        view.onClick = onClick
        view.onBegin = onBegin
        view.onMove = onMove
        view.onRelease = onRelease
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: PointerView, coordinator: ()) {
        view.stopTracking()
    }

    final class PointerView: NSView {
        var regions: [SidebarSetBarEditorRegion: CGRect] = [:]
        var isEnabled = true
        var onClick: ((SidebarSetBarEditorRegion) -> Void)?
        var onBegin: ((SidebarSetBarEditorRegion, CGPoint) -> Void)?
        var onMove: ((CGPoint) -> Void)?
        var onRelease: ((CGPoint, CGSize) -> Void)?
        var onCancel: (() -> Void)?

        private var monitor: Any?
        private var pressedRegion: SidebarSetBarEditorRegion?
        private var pressPoint = CGPoint.zero
        private var previousPoint = CGPoint.zero
        private var previousTime: TimeInterval = 0
        private var velocity = CGSize.zero
        private var isDragging = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard isEnabled, bounds.contains(local), region(at: local) != nil else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let region = region(at: point) else { return }
            stopTracking()
            pressedRegion = region
            pressPoint = point
            previousPoint = point
            previousTime = event.timestamp
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.track(event)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                let wasDragging = isDragging
                stopTracking()
                if wasDragging { onCancel?() }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func region(at point: CGPoint) -> SidebarSetBarEditorRegion? {
            regions.first(where: { $0.value.contains(point) })?.key
        }

        private func track(_ event: NSEvent) -> NSEvent? {
            guard let pressedRegion else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                stopTracking()
                onCancel?()
                return nil
            }
            let point = convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseDragged {
                let elapsed = event.timestamp - previousTime
                if elapsed > 0 {
                    velocity = CGSize(width: (point.x - previousPoint.x) / elapsed, height: (point.y - previousPoint.y) / elapsed)
                }
                previousPoint = point
                previousTime = event.timestamp
                if !isDragging && hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= 3 {
                    isDragging = true
                    onBegin?(pressedRegion, pressPoint)
                }
                if isDragging { onMove?(point) }
            } else if event.type == .leftMouseUp {
                let didDrag = isDragging
                let releaseVelocity = event.timestamp - previousTime < 0.1 ? velocity : .zero
                stopTracking()
                if didDrag {
                    onRelease?(point, releaseVelocity)
                } else {
                    onClick?(pressedRegion)
                }
            }
            // Consuming drag/up here prevents the carousel's SwiftUI recognizer from
            // claiming the same pointer stream after an icon has been picked up.
            return nil
        }

        func stopTracking() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressedRegion = nil
            isDragging = false
            velocity = .zero
        }
    }
}

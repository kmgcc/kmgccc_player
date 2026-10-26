import AppKit
import SwiftUI

/// Observes only scrolls inside this scene node; ordinary control clicks pass through.
struct SkinSceneScrollRegion: NSViewRepresentable {
    let onScroll: (Double, Double) -> Void
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.stop() }
    final class RegionView: NSView {
        var onScroll: ((Double, Double) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.window === event.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY)
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

struct SkinSceneCursorRegion: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) { view.name = name; view.window?.invalidateCursorRects(for: view) }
    final class CursorView: NSView {
        var name = "arrow"
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            let cursor: NSCursor
            switch name {
            case "pointingHand": cursor = .pointingHand
            case "openHand": cursor = .openHand
            case "closedHand": cursor = .closedHand
            case "crosshair": cursor = .crosshair
            case "resizeLeftRight": cursor = .resizeLeftRight
            case "resizeUpDown": cursor = .resizeUpDown
            case "ibeam": cursor = .iBeam
            default: cursor = .arrow
            }
            addCursorRect(bounds, cursor: cursor)
        }
    }
}

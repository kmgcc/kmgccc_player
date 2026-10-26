import AppKit
import SwiftUI

/// Reads the actual hosting window instead of guessing from the frontmost display.
struct SkinSceneHostProbe: NSViewRepresentable {
    let data: SkinSceneData
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.data = data; view.publish() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }
    final class Probe: NSView {
        weak var data: SkinSceneData?
        private var tracking: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
            updateTrackingAreas(); publish()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { data?.updateHostFacts(["host.pointerInside": .boolean(true)]); moved() }
        override func mouseExited(with event: NSEvent) { data?.updateHostFacts(["host.pointerInside": .boolean(false)]); moved() }
        override func mouseMoved(with event: NSEvent) { moved() }
        private func moved() { data?.pointerMoved() }
        @objc private func changed() { publish() }
        func publish() {
            guard let window, let data else { return }
            data.updateHostFacts(["host.isKeyWindow": .boolean(window.isKeyWindow)])
            let inset = safeAreaInsets
            data.updateViewportFacts([
                "viewport.maximumRefreshRate": .number(Double(window.screen?.maximumFramesPerSecond ?? 60)),
                "viewport.safeArea": .record(["top": .number(inset.top), "leading": .number(inset.left), "bottom": .number(inset.bottom), "trailing": .number(inset.right)])
            ])
        }
        func stop() {
            NotificationCenter.default.removeObserver(self)
            if let tracking { removeTrackingArea(tracking) }; tracking = nil
        }
    }
}

import AppKit
import Foundation

struct FullscreenMiniPlayerOcclusionRegion: Equatable {
    static let inactive = FullscreenMiniPlayerOcclusionRegion(
        rect: .zero,
        cornerRadius: 0,
        isEnabled: false
    )

    let rect: CGRect
    let cornerRadius: CGFloat
    let isEnabled: Bool

    func contains(_ point: CGPoint) -> Bool {
        guard isEnabled, rect.contains(point) else { return false }

        let radius = min(cornerRadius, rect.width * 0.5, rect.height * 0.5)
        guard radius > 0 else { return true }

        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ).contains(point)
    }
}

@MainActor
final class FullscreenPointerOcclusionMonitor {
    private weak var window: NSWindow?
    private var region: FullscreenMiniPlayerOcclusionRegion = .inactive
    private var eventMonitor: Any?
    private var onOcclusionChanged: ((Bool) -> Void)?
    private var isOccluded = false

    func setWindow(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.acceptsMouseMovedEvents = true
        refreshFromCurrentMouseLocation()
    }

    func start(onOcclusionChanged: @escaping (Bool) -> Void) {
        self.onOcclusionChanged = onOcclusionChanged
        if window == nil, let keyWindow = NSApp.keyWindow {
            setWindow(keyWindow)
        }
        guard eventMonitor == nil else {
            refreshFromCurrentMouseLocation()
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseEntered,
                .mouseExited,
                .mouseMoved,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged
            ]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }

        refreshFromCurrentMouseLocation()
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        updateOcclusion(false)
        onOcclusionChanged = nil
        window = nil
        region = .inactive
    }

    func updateRegion(_ region: FullscreenMiniPlayerOcclusionRegion) {
        self.region = region
        refreshFromCurrentMouseLocation()
    }

    private func handle(_ event: NSEvent) {
        if window == nil, let eventWindow = event.window {
            setWindow(eventWindow)
        }
        guard let window, event.window === window else {
            updateOcclusion(false)
            return
        }
        updateOcclusion(region.contains(event.locationInWindow))
    }

    private func refreshFromCurrentMouseLocation() {
        guard let window else {
            updateOcclusion(false)
            return
        }
        updateOcclusion(region.contains(window.mouseLocationOutsideOfEventStream))
    }

    private func updateOcclusion(_ nextValue: Bool) {
        guard nextValue != isOccluded else { return }
        isOccluded = nextValue
        onOcclusionChanged?(nextValue)
    }
}

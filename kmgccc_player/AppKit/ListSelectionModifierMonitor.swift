import AppKit

/// One window-scoped monitor; hosted rows never install their own keyboard
/// monitors. Text editors and sheets keep their normal modifier behavior.
@MainActor
final class ListSelectionModifierMonitor {
    private weak var window: NSWindow?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onChange: ((Bool) -> Void)?

    init(window: NSWindow, onChange: @escaping (Bool) -> Void) {
        self.window = window
        self.onChange = onChange
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.refresh(flags: event.modifierFlags)
            return event
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?(false) }
        })
        refresh()
    }

    func refresh(flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let window, window.isKeyWindow, NSApp.isActive,
              window.attachedSheet == nil,
              !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSTextField) else {
            onChange?(false)
            return
        }
        onChange?(!flags.intersection([.command, .shift]).isEmpty)
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        onChange?(false)
        onChange = nil
    }
}

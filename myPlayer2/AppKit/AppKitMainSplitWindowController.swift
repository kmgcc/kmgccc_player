//
//  AppKitMainSplitWindowController.swift
//  myPlayer2
//
//  AppKit-driven main window template (three-column split).
//  Step 1: Root split only (no NSToolbar wiring yet).
//

import AppKit

@MainActor
final class AppKitMainSplitWindowController: NSWindowController, NSWindowDelegate {
    private static weak var sharedController: AppKitMainSplitWindowController?

    private let splitViewController: AppKitMainSplitViewController
#if DEBUG
    private var hitTestMonitor: Any?
#endif

    static func show(appSession: AppSessionHost) {
        let controller: AppKitMainSplitWindowController
        if let existing = sharedController {
            controller = existing
        } else {
            controller = AppKitMainSplitWindowController(appSession: appSession)
            sharedController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.printVerificationSnapshot()
    }

    init(appSession: AppSessionHost) {
        self.splitViewController = AppKitMainSplitViewController(appSession: appSession)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "kmgccc_player (AppKit Split Template)"
        window.center()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Important: avoid allowing the split content area (including dividers) to move the window.
        // Window dragging remains available via the titlebar/toolbar region.
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = splitViewController
        window.delegate = self
        window.isReleasedWhenClosed = false

#if DEBUG
        installHitTestMonitor()
#endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.sharedController = nil
#if DEBUG
        if let hitTestMonitor {
            NSEvent.removeMonitor(hitTestMonitor)
            self.hitTestMonitor = nil
        }
#endif
    }

    private func printVerificationSnapshot() {
        let usesFullSizeContent = window?.styleMask.contains(.fullSizeContentView) == true
        let transparentTitlebar = window?.titlebarAppearsTransparent == true
        let movableByBackground = window?.isMovableByWindowBackground == true
        print("[AppKitMainWindow] \(splitViewController.runtimeVerificationSnapshot()) fullSizeContent=\(usesFullSizeContent) titlebarTransparent=\(transparentTitlebar) movableByBackground=\(movableByBackground) toolbarStyle=\(window?.toolbarStyle.rawValue ?? -1)")
    }

#if DEBUG
    private func installHitTestMonitor() {
        guard hitTestMonitor == nil else { return }
        hitTestMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = event.locationInWindow
            if let view = window.contentView?.hitTest(location) {
                print("[AppKitMainWindow] hitTest view=\(type(of: view)) mouseDownCanMoveWindow=\(view.mouseDownCanMoveWindow)")
            } else {
                print("[AppKitMainWindow] hitTest view=nil")
            }
            return event
        }
    }
#endif
}

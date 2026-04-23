import AppKit
import SwiftData
import SwiftUI

@MainActor
final class LegacyMainWindowController: NSWindowController, NSWindowDelegate {
    private static var sharedController: LegacyMainWindowController?

    private let appSession: AppSessionHost

    static func show(appSession: AppSessionHost) {
        let controller: LegacyMainWindowController
        if let existing = sharedController {
            controller = existing
        } else {
            controller = LegacyMainWindowController(appSession: appSession)
            sharedController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(appSession: AppSessionHost) {
        self.appSession = appSession

        let rootView = AppRootView(appSession: appSession)
            .frame(minWidth: 1100, minHeight: 600)
            .modelContainer(appSession.sharedModelContainer)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "kmgccc_player (Legacy SwiftUI Main Window)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = hostingController
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.sharedController = nil
    }
}

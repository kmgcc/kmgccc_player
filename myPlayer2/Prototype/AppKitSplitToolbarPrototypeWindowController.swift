//
//  AppKitSplitToolbarPrototypeWindowController.swift
//  myPlayer2
//
//  Standalone prototype window for validating AppKit split + toolbar behavior.
//

import AppKit

@MainActor
final class AppKitSplitToolbarPrototypeWindowController: NSWindowController, NSWindowDelegate {
    private static weak var sharedController: AppKitSplitToolbarPrototypeWindowController?

    private let splitViewController = AppKitSplitToolbarPrototypeViewController()
    private lazy var toolbarController = AppKitSplitToolbarPrototypeToolbarController(
        splitViewController: splitViewController
    )

    static func showPrototypeWindow() {
        let controller: AppKitSplitToolbarPrototypeWindowController
        if let existing = sharedController {
            controller = existing
        } else {
            controller = AppKitSplitToolbarPrototypeWindowController()
            sharedController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        controller.printVerificationSnapshot()
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "AppKit Split Toolbar Prototype"
        window.center()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = splitViewController
        window.toolbar = toolbarController.toolbar
        window.delegate = self
        window.isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.sharedController = nil
    }

    private func printVerificationSnapshot() {
        let usesFullSizeContent = window?.styleMask.contains(.fullSizeContentView) == true
        let transparentTitlebar = window?.titlebarAppearsTransparent == true
        print("[PrototypeWindow] \(splitViewController.runtimeVerificationSnapshot()) fullSizeContent=\(usesFullSizeContent) titlebarTransparent=\(transparentTitlebar) toolbarStyle=\(window?.toolbarStyle.rawValue ?? -1)")
        print("[PrototypeToolbar] \(toolbarController.runtimeVerificationSnapshot())")
    }
}

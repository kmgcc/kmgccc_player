//
//  AppDelegate.swift
//  myPlayer2
//
//  kmgccc_player - App Delegate for Menu Configuration
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    static var launchMainWindowHandler: (@MainActor () -> Void)?
    static var applicationShouldTerminateHandler:
        ((@escaping @MainActor @Sendable () -> Void) -> Void)?
    static var shouldCancelTerminationForPendingUpdateHandler: (@MainActor () -> Bool)?
    static var applicationWillTerminateHandler: (@MainActor () -> Void)?

    static func showMainWindow() {
        Task { @MainActor in
            launchMainWindowHandler?()
        }
    }

    private let dockController = DockController()
    private weak var playbackCoordinator: PlaybackCoordinator?
    private var spacebarMonitor: Any?
    private var terminationReplyPending = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.debug("[AppDelegate] didFinishLaunching", category: .ui)
        disableWindowTabbing()
        configureMainMenu()
        installSpacebarPlayPauseMonitor()
        dockController.installDockTile()
        DispatchQueue.main.async {
            Log.debug("[AppDelegate] launchMainWindowHandler.invoke", category: .ui)
            Self.showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PaneLayoutTrace.log("AppDelegate.applicationWillTerminate")
        Self.applicationWillTerminateHandler?()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldCancelTerminationForPendingUpdateHandler?() == true {
            Log.info("[Lifecycle] Cancelled ordinary quit while Sparkle install reply is pending", category: .ui)
            return .terminateCancel
        }
        guard let handler = Self.applicationShouldTerminateHandler else {
            return .terminateNow
        }
        guard !terminationReplyPending else {
            return .terminateLater
        }

        terminationReplyPending = true
        handler { [weak self, weak sender] in
            Task { @MainActor in
                self?.terminationReplyPending = false
                sender?.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func configureDockPlayback(playbackCoordinator: PlaybackCoordinator) {
        self.playbackCoordinator = playbackCoordinator
        dockController.configure(playbackCoordinator: playbackCoordinator)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockController.makeDockMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dockController.applicationShouldHandleReopen(hasVisibleWindows: flag)
    }

    private func disableWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // MARK: - Spacebar play/pause monitor

    /// Intercepts bare-spacebar keyDown events app-wide so that play/pause
    /// works even when an `NSTableView` (backing SwiftUI `List`) has keyboard
    /// focus. Without this, `NSTableView.keyDown` consumes the space key
    /// for page-scroll before the menu bar shortcut can fire.
    private func installSpacebarPlayPauseMonitor() {
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only intercept bare spacebar (keyCode 49, no significant modifiers).
            guard event.keyCode == 49 else { return event }
            let dominated = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard dominated.isEmpty else { return event }

            // Don't intercept when a text input is the first responder — the
            // user is typing a space character.
            if let responder = event.window?.firstResponder {
                if responder is NSTextView || responder is NSTextField {
                    return event
                }
                if String(describing: type(of: responder)).contains("FieldEditor") {
                    return event
                }
            }

            // Forward to playback coordinator.
            self?.playbackCoordinator?.playPause()
            return nil // consume the event
        }
    }

    private func configureMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for menuItem in mainMenu.items {
            if menuItem.title == "View" || menuItem.title == "视图" {
                configureViewMenu(menuItem.submenu)
            }
            if menuItem.title == "Window" || menuItem.title == "窗口" {
                configureWindowMenu(menuItem.submenu)
            }
        }
    }

    private func configureViewMenu(_ viewMenu: NSMenu?) {
        // View menu now managed by SwiftUI CommandGroup(replacing: .sidebar)
        // This avoids duplication with the system-provided View menu items
    }

    private func configureWindowMenu(_ windowMenu: NSMenu?) {
        guard let windowMenu else { return }

        let itemsToRemove = windowMenu.items.filter { item in
            let title = item.title
            return title.contains("Tab Bar")
                || title.contains("标签页栏")
                || title.contains("Show All Tabs")
                || title.contains("显示所有标签页")
        }

        for item in itemsToRemove {
            windowMenu.removeItem(item)
        }
    }

    @objc private func showToolbarCustomization() {
        if let window = NSApp.mainWindow, let toolbar = window.toolbar {
            toolbar.runCustomizationPalette(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

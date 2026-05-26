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
    static var applicationWillTerminateHandler: (@MainActor () -> Void)?

    static func showMainWindow() {
        Task { @MainActor in
            launchMainWindowHandler?()
        }
    }

    private let dockController = DockController()

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] didFinishLaunching")
        disableWindowTabbing()
        configureMainMenu()
        dockController.installDockTile()
        DispatchQueue.main.async {
            print("[AppDelegate] launchMainWindowHandler.invoke")
            Self.showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PaneLayoutTrace.log("AppDelegate.applicationWillTerminate")
        Self.applicationWillTerminateHandler?()
    }

    func configureDockPlayback(playbackCoordinator: PlaybackCoordinator) {
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
}

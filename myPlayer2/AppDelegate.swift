//
//  AppDelegate.swift
//  myPlayer2
//
//  kmgccc_player - App Delegate for Menu Configuration
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        disableWindowTabbing()
        configureMainMenu()
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
        guard let viewMenu else { return }

        let customizeToolbarItem = NSMenuItem(
            title: NSLocalizedString("menu.customize_toolbar", comment: ""),
            action: #selector(showToolbarCustomization),
            keyEquivalent: ""
        )
        customizeToolbarItem.target = self

        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(customizeToolbarItem)
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
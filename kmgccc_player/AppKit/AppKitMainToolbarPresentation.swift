//
//  AppKitMainToolbarPresentation.swift
//  myPlayer2
//
//  Stateless presentation updates for the main AppKit toolbar items.
//

import AppKit

@MainActor
enum AppKitMainToolbarPresentation {
    static func syncMultiselect(
        item: NSToolbarItem?,
        isOn: Bool,
        isEnabled: Bool
    ) {
        let symbol = isOn ? "checkmark.circle.fill" : "checkmark.circle"
        item?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item?.label)
        item?.isEnabled = isEnabled
    }

    static func syncHistoryDelete(item: NSToolbarItem?, isEnabled: Bool) {
        item?.isEnabled = isEnabled
    }

    static func syncRevealNowPlaying(item: NSToolbarItem?, isEnabled: Bool) {
        item?.isEnabled = isEnabled
    }

    static func syncSidebarToggle(
        item: NSToolbarItem?,
        isSidebarVisible: Bool
    ) {
        guard let item else { return }
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
        item.toolTip = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        item.isEnabled = true
    }

    static func syncLyricsToggle(
        item: NSToolbarItem?,
        isLyricsVisible: Bool,
        isFlashFilled: Bool
    ) {
        guard let item else { return }
        let symbol = isFlashFilled ? "quote.bubble.fill" : "quote.bubble"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.toolTip = isLyricsVisible ? "Hide Lyrics" : "Show Lyrics"
        item.isEnabled = true
    }

    static func syncHomeNavigation(
        group: NSToolbarItemGroup?,
        isPlaybackHistoryMode: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        guard let group else { return }
        if isPlaybackHistoryMode {
            if group.subitems.indices.contains(0) {
                group.subitems[0].isEnabled = true
            }
            if group.subitems.indices.contains(1) {
                group.subitems[1].isEnabled = false
            }
            group.isEnabled = true
            return
        }
        if group.subitems.indices.contains(0) {
            group.subitems[0].isEnabled = canGoBack
        }
        if group.subitems.indices.contains(1) {
            group.subitems[1].isEnabled = canGoForward
        }
        group.isEnabled = canGoBack || canGoForward
    }
}

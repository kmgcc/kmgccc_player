//
//  AppKitMainToolbarItemFactory.swift
//  myPlayer2
//
//  Stateless construction of the main window's toolbar items.
//

import AppKit

@MainActor
struct AppKitMainToolbarItemFactory {
    struct Actions {
        let target: AnyObject
        let sidebarToggle: Selector
        let homeNavigation: Selector
        let pillGroup: Selector
        let homePillGroup: Selector
        let lyricsToggle: Selector
    }

    struct Context {
        let isSidebarVisible: Bool
        let isLyricsVisible: Bool
        let isPlaybackHistoryMode: Bool
        let isMultiselectMode: Bool
        let generation: Int
        let splitView: NSSplitView?
    }

    func makeItem(
        identifier: NSToolbarItem.Identifier,
        context: Context,
        actions: Actions,
        sortMenu: NSMenu,
        searchBridge: AppKitMainToolbarSearchBridge
    ) -> NSToolbarItem? {
        switch identifier {
        case AppKitMainToolbarController.Identifier.sidebarToggle:
            return makeSidebarToggleItem(
                identifier: identifier,
                isSidebarVisible: context.isSidebarVisible,
                actions: actions
            )

        case AppKitMainToolbarController.Identifier.homeNavPill:
            return makeHomeNavigationItem(identifier: identifier, actions: actions)

        case AppKitMainToolbarController.Identifier.sort:
            return makeSortItem(identifier: identifier, menu: sortMenu)

        case AppKitMainToolbarController.Identifier.pillGroup:
            return makePillGroupItem(
                identifier: identifier,
                isHistoryMode: context.isPlaybackHistoryMode,
                isMultiselectMode: context.isMultiselectMode,
                actions: actions
            )

        case AppKitMainToolbarController.Identifier.homePillGroup:
            return makeHomePillGroupItem(identifier: identifier, actions: actions)

        case AppKitMainToolbarController.Identifier.search:
            return searchBridge.makeToolbarItem(
                isHistoryMode: context.isPlaybackHistoryMode,
                generation: context.generation
            )

        case AppKitMainToolbarController.Identifier.lyricsToggle:
            return makeLyricsToggleItem(
                identifier: identifier,
                isLyricsVisible: context.isLyricsVisible,
                actions: actions
            )

        case .sidebarTrackingSeparator:
            guard let splitView = context.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier,
                splitView: splitView,
                dividerIndex: 0
            )

        case .inspectorTrackingSeparator:
            guard let splitView = context.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier,
                splitView: splitView,
                dividerIndex: AppKitMainSplitViewController.mainLyricsDividerIndex
            )

        default:
            // System-provided items (.toggleSidebar, spacers) return nil.
            return nil
        }
    }

    private func makeSidebarToggleItem(
        identifier: NSToolbarItem.Identifier,
        isSidebarVisible: Bool,
        actions: Actions
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = NSLocalizedString("toolbar.sidebar", comment: "Sidebar")
        item.paletteLabel = item.label
        item.toolTip = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
        item.target = actions.target
        item.action = actions.sidebarToggle
        item.autovalidates = false
        item.isEnabled = true
        return item
    }

    private func makeHomeNavigationItem(
        identifier: NSToolbarItem.Identifier,
        actions: Actions
    ) -> NSToolbarItemGroup {
        let backLabel = "后退"
        let forwardLabel = "前进"
        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: backLabel)
                    ?? NSImage(),
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forwardLabel)
                    ?? NSImage()
            ],
            selectionMode: .momentary,
            labels: [backLabel, forwardLabel],
            target: actions.target,
            action: actions.homeNavigation
        )
        group.label = "Home Navigation"
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        group.isNavigational = true
        group.autovalidates = false
        group.isEnabled = true
        if group.subitems.indices.contains(0) {
            group.subitems[0].toolTip = backLabel
            group.subitems[0].isNavigational = true
        }
        if group.subitems.indices.contains(1) {
            group.subitems[1].toolTip = forwardLabel
            group.subitems[1].isNavigational = true
        }
        return group
    }

    private func makeSortItem(
        identifier: NSToolbarItem.Identifier,
        menu: NSMenu
    ) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = NSLocalizedString("sort.menu_title", comment: "Sort")
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.image = NSImage(
            systemSymbolName: "arrow.up.arrow.down",
            accessibilityDescription: item.label
        )
        item.menu = menu
        item.showsIndicator = true
        item.autovalidates = true
        return item
    }

    private func makePillGroupItem(
        identifier: NSToolbarItem.Identifier,
        isHistoryMode: Bool,
        isMultiselectMode: Bool,
        actions: Actions
    ) -> NSToolbarItemGroup {
        let multiselectLabel = NSLocalizedString("context.multiselect", comment: "Select")
        let playLabel = NSLocalizedString("context.play_all", comment: "Play All")
        let revealLabel = "定位正在播放"
        let deleteHistoryLabel = "删除播放历史"
        let importLabel = NSLocalizedString("context.import", comment: "Import")
        let multiselectSymbol = isMultiselectMode ? "checkmark.circle.fill" : "checkmark.circle"

        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            images: [
                NSImage(systemSymbolName: multiselectSymbol, accessibilityDescription: multiselectLabel)
                    ?? NSImage(),
                NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
                    ?? NSImage(),
                NSImage(
                    systemSymbolName: isHistoryMode ? "trash" : "list.bullet.below.rectangle",
                    accessibilityDescription: isHistoryMode ? deleteHistoryLabel : revealLabel
                )
                    ?? NSImage(),
                NSImage(systemSymbolName: "plus", accessibilityDescription: importLabel)
                    ?? NSImage()
            ],
            selectionMode: .momentary,
            labels: [
                multiselectLabel,
                playLabel,
                isHistoryMode ? deleteHistoryLabel : revealLabel,
                importLabel
            ],
            target: actions.target,
            action: actions.pillGroup
        )
        group.label = "Actions"
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        group.autovalidates = false
        group.isEnabled = true
        if group.subitems.indices.contains(0) {
            group.subitems[0].toolTip = multiselectLabel
        }
        if group.subitems.indices.contains(1) {
            group.subitems[1].toolTip = playLabel
        }
        if group.subitems.indices.contains(2) {
            group.subitems[2].toolTip = isHistoryMode ? deleteHistoryLabel : revealLabel
        }
        if group.subitems.indices.contains(3) {
            group.subitems[3].toolTip = importLabel
        }
        return group
    }

    private func makeHomePillGroupItem(
        identifier: NSToolbarItem.Identifier,
        actions: Actions
    ) -> NSToolbarItemGroup {
        let playLabel = NSLocalizedString("context.play_all", comment: "Play All")
        let revealLabel = "定位正在播放"
        let importLabel = NSLocalizedString("context.import", comment: "Import")

        let group = NSToolbarItemGroup(
            itemIdentifier: identifier,
            images: [
                NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
                    ?? NSImage(),
                NSImage(systemSymbolName: "list.bullet.below.rectangle", accessibilityDescription: revealLabel)
                    ?? NSImage(),
                NSImage(systemSymbolName: "plus", accessibilityDescription: importLabel)
                    ?? NSImage()
            ],
            selectionMode: .momentary,
            labels: [playLabel, revealLabel, importLabel],
            target: actions.target,
            action: actions.homePillGroup
        )
        group.label = "Home Actions"
        group.paletteLabel = group.label
        group.controlRepresentation = .expanded
        group.autovalidates = false
        group.isEnabled = true
        if group.subitems.indices.contains(0) {
            group.subitems[0].toolTip = playLabel
        }
        if group.subitems.indices.contains(1) {
            group.subitems[1].toolTip = revealLabel
        }
        if group.subitems.indices.contains(2) {
            group.subitems[2].toolTip = importLabel
        }
        return group
    }

    private func makeLyricsToggleItem(
        identifier: NSToolbarItem.Identifier,
        isLyricsVisible: Bool,
        actions: Actions
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = NSLocalizedString("lyrics", comment: "Lyrics")
        item.paletteLabel = item.label
        item.toolTip = isLyricsVisible ? "Hide Lyrics" : "Show Lyrics"
        item.target = actions.target
        item.action = actions.lyricsToggle
        item.autovalidates = false
        item.isEnabled = true
        return item
    }
}

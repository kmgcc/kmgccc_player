//
//  AppKitMainToolbarItemFactory.swift
//  myPlayer2
//
//  Stateless construction of the main window's toolbar items.
//

import AppKit
import MotionKit
import SwiftUI

@MainActor
struct AppKitMainToolbarItemFactory {
    struct Actions {
        let target: AnyObject
        let sidebarToggle: Selector
        let homeNavigation: Selector
        let pillGroup: Selector
        let homePillGroup: Selector
        let pillItem: Selector
        let lyricsToggle: Selector
    }

    struct Context {
        let isSidebarVisible: Bool
        let isLyricsVisible: Bool
        let isPlaybackHistoryMode: Bool
        let isHomeLandingSelection: Bool
        let isMultiselectMode: Bool
        let generation: Int
        let splitView: NSSplitView?
        let historyViewModel: PlaybackHistoryViewModel?
    }

    func makeItem(
        identifier: NSToolbarItem.Identifier,
        context: Context,
        actions: Actions,
        sortMenu: NSMenu,
        searchBridge: AppKitMainToolbarSearchBridge
    ) -> NSToolbarItem? {
        switch identifier {
        case AppKitMainToolbarController.Identifier.historySectionTitle:
            guard let historyVM = context.historyViewModel else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "播放历史日期"
            item.paletteLabel = item.label
            let view = NSHostingView(rootView: PlaybackHistoryToolbarTitleView(historyVM: historyVM))
            view.frame = NSRect(x: 0, y: 0, width: 144, height: 28)
            item.view = view
            item.isBordered = false
            item.visibilityPriority = .low
            return item

        case AppKitMainToolbarController.Identifier.sidebarToggle:
            return makeSidebarToggleItem(
                identifier: identifier,
                isSidebarVisible: context.isSidebarVisible,
                actions: actions
            )

        case AppKitMainToolbarController.Identifier.homeNavPill:
            return makeHomeNavigationItem(identifier: identifier, actions: actions)

        case AppKitMainToolbarController.Identifier.homeBack:
            return makeHomeNavigationActionItem(
                identifier: identifier,
                isForward: false,
                target: actions.target,
                action: actions.homeNavigation
            )

        case AppKitMainToolbarController.Identifier.homeForward:
            return makeHomeNavigationActionItem(
                identifier: identifier,
                isForward: true,
                target: actions.target,
                action: actions.homeNavigation
            )

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

        case AppKitMainToolbarController.Identifier.multiselect,
             AppKitMainToolbarController.Identifier.play,
             AppKitMainToolbarController.Identifier.revealNowPlaying,
             AppKitMainToolbarController.Identifier.import:
            return makePillActionItem(
                identifier: identifier,
                context: context,
                target: actions.target,
                action: actions.pillItem
            )

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
        item.label = "侧边栏"
        item.paletteLabel = item.label
        item.toolTip = isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏"
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
        item.target = actions.target
        item.action = actions.sidebarToggle
        item.autovalidates = false
        item.isEnabled = true
        return item
    }

    private func makeHomeNavigationActionItem(
        identifier: NSToolbarItem.Identifier,
        isForward: Bool,
        target: AnyObject,
        action: Selector
    ) -> NSToolbarItem {
        let label = isForward ? "前进" : "后退"
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(
            systemSymbolName: isForward ? "chevron.right" : "chevron.left",
            accessibilityDescription: label
        )
        item.target = target
        item.action = action
        item.isNavigational = true
        item.autovalidates = false
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
        group.label = "页面导航"
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
        item.label = "排序"
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

    private func makePillActionItem(
        identifier: NSToolbarItem.Identifier,
        context: Context,
        target: AnyObject,
        action: Selector
    ) -> NSToolbarItem {
        let label: String
        let symbol: String
        switch identifier {
        case AppKitMainToolbarController.Identifier.multiselect:
            label = "多选"
            symbol = context.isMultiselectMode ? "checkmark.circle.fill" : "checkmark.circle"
        case AppKitMainToolbarController.Identifier.play:
            label = context.isHomeLandingSelection ? "全部播放" : "播放"
            symbol = "play.fill"
        case AppKitMainToolbarController.Identifier.revealNowPlaying:
            label = context.isPlaybackHistoryMode ? "删除所选历史" : "定位正在播放"
            symbol = context.isPlaybackHistoryMode ? "trash" : "list.bullet.below.rectangle"
        case AppKitMainToolbarController.Identifier.import:
            label = "导入音乐"
            symbol = "plus"
        default:
            return NSToolbarItem(itemIdentifier: identifier)
        }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = target
        item.action = action
        item.autovalidates = false
        return item
    }

    private func makePillGroupItem(
        identifier: NSToolbarItem.Identifier,
        isHistoryMode: Bool,
        isMultiselectMode: Bool,
        actions: Actions
    ) -> NSToolbarItemGroup {
        let multiselectLabel = "多选"
        let playLabel = "播放"
        let revealLabel = "定位正在播放"
        let deleteHistoryLabel = "删除所选历史"
        let importLabel = "导入音乐"
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
        group.label = "列表操作"
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
        let playLabel = "全部播放"
        let revealLabel = "定位正在播放"
        let importLabel = "导入音乐"

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
        group.label = "主页操作"
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
        item.label = "歌词"
        item.paletteLabel = item.label
        item.toolTip = isLyricsVisible ? "隐藏歌词" : "显示歌词"
        item.target = actions.target
        item.action = actions.lyricsToggle
        item.autovalidates = false
        item.isEnabled = true
        return item
    }
}

private struct PlaybackHistoryToolbarTitleView: View {
    let historyVM: PlaybackHistoryViewModel
    @ObservedObject private var themeStore = ThemeStore.shared
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let title = historyVM.toolbarSectionTitle {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .lineLimit(1)
                    .id(title)
                    .transition(.asymmetric(
                        insertion: .offset(y: rollDistance).combined(with: .opacity),
                        removal: .offset(y: -rollDistance).combined(with: .opacity)
                    ))
            }
        }
        .frame(width: 144, height: 28, alignment: .leading)
        .clipped()
        .motionAnimation(.contentReplacement, value: historyVM.toolbarSectionTitle)
        .allowsHitTesting(false)
        .accessibilityHidden(historyVM.toolbarSectionTitle == nil)
    }

    private var rollDistance: CGFloat {
        motionPolicy.resolving(accessibilityReduceMotion: accessibilityReduceMotion) == .full ? 8 : 0
    }
}

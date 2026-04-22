//
//  AppKitSplitToolbarPrototypeToolbarController.swift
//  myPlayer2
//
//  Minimal NSToolbar delegate used to validate search + tracking separator behavior.
//

import AppKit

@MainActor
final class AppKitSplitToolbarPrototypeToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSUserInterfaceValidations {
    private enum Identifier {
        static let toolbar = NSToolbar.Identifier("AppKitSplitToolbarPrototypeToolbar")
        static let pillGroup = NSToolbarItem.Identifier("AppKitSplitToolbarPrototype.pillGroup")
        static let search = NSToolbarItem.Identifier("AppKitSplitToolbarPrototype.search")
    }

    private weak var splitViewController: AppKitSplitToolbarPrototypeViewController?
    private(set) lazy var toolbar: NSToolbar = makeToolbar()
    private(set) var lastSearchQuery = ""

    init(splitViewController: AppKitSplitToolbarPrototypeViewController) {
        self.splitViewController = splitViewController
        super.init()
    }

    func runtimeVerificationSnapshot() -> String {
        let identifiers = toolbar.items.map(\.itemIdentifier.rawValue).joined(separator: ",")
        let groupClass = toolbar.items.first { $0.itemIdentifier == Identifier.pillGroup }
            .map { String(describing: type(of: $0)) } ?? "missing"
        let searchClass = toolbar.items.first { $0.itemIdentifier == Identifier.search }
            .map { String(describing: type(of: $0)) } ?? "missing"
        let toggleInspectorClass = toolbar.items.first { $0.itemIdentifier == .toggleInspector }
            .map { String(describing: type(of: $0)) } ?? "missing"
        let sidebarTrackingDescription: String
        if let trackingItem = toolbar.items.first(where: { $0.itemIdentifier == .sidebarTrackingSeparator }) as? NSTrackingSeparatorToolbarItem {
            sidebarTrackingDescription = "class=\(type(of: trackingItem)) dividerIndex=\(trackingItem.dividerIndex)"
        } else {
            sidebarTrackingDescription = "missing"
        }
        let inspectorTrackingDescription: String
        if let trackingItem = toolbar.items.first(where: { $0.itemIdentifier == .inspectorTrackingSeparator }) as? NSTrackingSeparatorToolbarItem {
            inspectorTrackingDescription = "class=\(type(of: trackingItem)) dividerIndex=\(trackingItem.dividerIndex) splitViewSameWindow=\(trackingItem.splitView.window === splitViewController?.view.window)"
        } else {
            inspectorTrackingDescription = "missing"
        }

        return [
            "items=\(identifiers)",
            "groupClass=\(groupClass)",
            "searchClass=\(searchClass)",
            "toggleInspectorClass=\(toggleInspectorClass)",
            "sidebarTracking=\(sidebarTrackingDescription)",
            "inspectorTracking=\(inspectorTrackingDescription)"
        ].joined(separator: " ")
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        true
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Identifier.pillGroup, .flexibleSpace, Identifier.search, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Identifier.pillGroup, .flexibleSpace, Identifier.search, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Identifier.pillGroup:
            let selectItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("AppKitSplitToolbarPrototype.select"))
            selectItem.label = "Select"
            selectItem.image = NSImage(
                systemSymbolName: "checkmark.circle",
                accessibilityDescription: "Select"
            )
            selectItem.target = self
            selectItem.action = #selector(handlePillAction(_:))
            selectItem.autovalidates = false
            selectItem.isEnabled = true

            let playItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("AppKitSplitToolbarPrototype.play"))
            playItem.label = "Play"
            playItem.image = NSImage(
                systemSymbolName: "play.fill",
                accessibilityDescription: "Play"
            )
            playItem.target = self
            playItem.action = #selector(handlePillAction(_:))
            playItem.autovalidates = false
            playItem.isEnabled = true

            let addItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("AppKitSplitToolbarPrototype.add"))
            addItem.label = "Add"
            addItem.image = NSImage(
                systemSymbolName: "plus",
                accessibilityDescription: "Add"
            )
            addItem.target = self
            addItem.action = #selector(handlePillAction(_:))
            addItem.autovalidates = false
            addItem.isEnabled = true

            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.label = "Actions"
            group.paletteLabel = "Actions"
            group.subitems = [selectItem, playItem, addItem]
            group.selectionMode = .momentary
            group.controlRepresentation = .expanded
            group.autovalidates = false
            group.isEnabled = true
            return group

        case Identifier.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.searchField.placeholderString = "Search"
            item.preferredWidthForSearchField = 160
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(handleSearchChange(_:))
            return item

        case .sidebarTrackingSeparator:
            guard let splitViewController else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )

        case .inspectorTrackingSeparator:
            guard let splitViewController else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: AppKitSplitToolbarPrototypeViewController.mainLyricsDividerIndex
            )

        default:
            return nil
        }
    }

    @objc
    private func handlePillAction(_ sender: NSToolbarItem) {
        print("[PrototypeToolbar] pillAction=\(sender.itemIdentifier.rawValue)")
    }

    @objc
    private func handleSearchChange(_ sender: NSSearchField) {
        lastSearchQuery = sender.stringValue
        print("[PrototypeToolbar] searchQuery=\(lastSearchQuery)")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Identifier.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .default
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }
}

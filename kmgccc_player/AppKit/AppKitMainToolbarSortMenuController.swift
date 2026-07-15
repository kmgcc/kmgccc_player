//
//  AppKitMainToolbarSortMenuController.swift
//  myPlayer2
//
//  Lazy sort-menu construction and target-action forwarding for the main toolbar.
//

import AppKit

@MainActor
protocol AppKitMainToolbarSortMenuControllerDelegate: AnyObject {
    func toolbarSortMenuContext(
        _ controller: AppKitMainToolbarSortMenuController
    ) -> (libraryVM: LibraryViewModel, generation: Int)?

    func toolbarSortMenuController(
        _ controller: AppKitMainToolbarSortMenuController,
        didSelectKeyRawValue rawValue: String,
        generation: Int
    )

    func toolbarSortMenuController(
        _ controller: AppKitMainToolbarSortMenuController,
        didSelectOrderRawValue rawValue: String,
        generation: Int
    )
}

@MainActor
final class AppKitMainToolbarSortMenuController: NSObject, NSMenuDelegate {
    private final class ActionPayload: NSObject {
        let rawValue: String
        let generation: Int

        init(rawValue: String, generation: Int) {
            self.rawValue = rawValue
            self.generation = generation
        }
    }

    // The main toolbar controller owns this helper for its full lifetime.
    // The delegate is weak, while the helper exclusively owns the menu/delegate pair.
    weak var delegate: AppKitMainToolbarSortMenuControllerDelegate?

    let menu: NSMenu

    override init() {
        let menu = NSMenu(title: "Sort")
        self.menu = menu
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenu()
    }

    func detachMenuItemActions() {
        menu.items.forEach { item in
            if item.target === self {
                item.target = nil
                item.action = nil
            }
        }
        menu.removeAllItems()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        guard let context = delegate?.toolbarSortMenuContext(self) else { return }
        let libraryVM = context.libraryVM
        let generation = context.generation

        let keyHeader = NSMenuItem(
            title: NSLocalizedString("sort.by", comment: "Sort by"),
            action: nil,
            keyEquivalent: ""
        )
        keyHeader.isEnabled = false
        menu.addItem(keyHeader)

        switch libraryVM.currentSelection {
        case .allPlaylists:
            for key in PlaylistSortKey.allCases {
                addSortKeyItem(
                    title: key.title,
                    rawValue: key.rawValue,
                    isSelected: libraryVM.playlistSortKey == key,
                    generation: generation
                )
            }
        case .allAlbums:
            for key in AlbumSortKey.allCases {
                addSortKeyItem(
                    title: key.title,
                    rawValue: key.rawValue,
                    isSelected: libraryVM.albumSortKey == key,
                    generation: generation
                )
            }
        case .allArtists:
            for key in ArtistSortKey.allCases {
                addSortKeyItem(
                    title: key.title,
                    rawValue: key.rawValue,
                    isSelected: libraryVM.artistSortKey == key,
                    generation: generation
                )
            }
        default:
            for key in TrackSortKey.allCases
                where key != .custom || libraryVM.supportsCustomTrackOrder()
            {
                addSortKeyItem(
                    title: key.title,
                    rawValue: key.rawValue,
                    isSelected: libraryVM.trackSortKey == key,
                    generation: generation
                )
            }
        }

        menu.addItem(.separator())

        let isCustomCollectionSort: Bool = {
            switch libraryVM.currentSelection {
            case .allPlaylists, .allAlbums, .allArtists:
                return libraryVM.isCustomCollectionSortActive()
            default:
                return false
            }
        }()
        for order in TrackSortOrder.allCases {
            let item = NSMenuItem(
                title: order.title,
                action: #selector(handleSortOrder(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ActionPayload(rawValue: order.rawValue, generation: generation)
            item.state = libraryVM.sortOrderForCurrentSelection == order ? .on : .off
            item.isEnabled = !isCustomCollectionSort
            item.target = self
            menu.addItem(item)
        }
    }

    private func addSortKeyItem(
        title: String,
        rawValue: String,
        isSelected: Bool,
        generation: Int
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(handleSortKey(_:)),
            keyEquivalent: ""
        )
        item.representedObject = ActionPayload(rawValue: rawValue, generation: generation)
        item.state = isSelected ? .on : .off
        item.target = self
        menu.addItem(item)
    }

    @objc
    private func handleSortKey(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ActionPayload else { return }
        delegate?.toolbarSortMenuController(
            self,
            didSelectKeyRawValue: payload.rawValue,
            generation: payload.generation
        )
    }

    @objc
    private func handleSortOrder(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ActionPayload else { return }
        delegate?.toolbarSortMenuController(
            self,
            didSelectOrderRawValue: payload.rawValue,
            generation: payload.generation
        )
    }
}

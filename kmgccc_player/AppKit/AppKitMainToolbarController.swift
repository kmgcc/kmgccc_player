 //
//  AppKitMainToolbarController.swift
//  myPlayer2
//
//  NSToolbar for the AppKit main split template window.
//  Owns toolbar items and bridges actions to AppSession / hosted controllers.
//

import AppKit
import Combine
import Observation
import SwiftUI

@MainActor
final class AppKitMainToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate, NSSearchFieldDelegate {
    private enum FeatureTips {
        static let shiftRangeSelectionKey = "playlist.shiftRangeSelection"
        static let shiftRangeSelectionIntroducedBuild = AppBuild(7)
        static let shiftRangeSelectionMaxDisplayCount = 2
    }

    enum Identifier {
        static let toolbar = NSToolbar.Identifier("AppKitMainToolbar")
        static let sidebarToggle = NSToolbarItem.Identifier("AppKitMainToolbar.sidebarToggle")
        static let homeNavPill = NSToolbarItem.Identifier("AppKitMainToolbar.homeNavPill")
        static let sort = NSToolbarItem.Identifier("AppKitMainToolbar.sort")
        static let pillGroup = NSToolbarItem.Identifier("AppKitMainToolbar.pillGroup")
        static let search = NSToolbarItem.Identifier("AppKitMainToolbar.search")
        static let lyricsToggle = NSToolbarItem.Identifier("AppKitMainToolbar.lyricsToggle")

        static let multiselect = NSToolbarItem.Identifier("AppKitMainToolbar.multiselect")
        static let play = NSToolbarItem.Identifier("AppKitMainToolbar.play")
        static let revealNowPlaying = NSToolbarItem.Identifier("AppKitMainToolbar.revealNowPlaying")
        static let `import` = NSToolbarItem.Identifier("AppKitMainToolbar.import")
        static let homePillGroup = NSToolbarItem.Identifier("AppKitMainToolbar.homePillGroup")
    }

    private weak var splitViewController: AppKitMainSplitViewController?
    private weak var appSession: AppSessionHost?
    private weak var window: NSWindow?
    private var isAttachedToWindow = false
    private var isDetachingFromWindow = false
    private var attachmentGeneration = 0

    private weak var multiselectItem: NSToolbarItem?
    private weak var playItem: NSToolbarItem?
    private weak var revealNowPlayingItem: NSToolbarItem?
    private weak var importItem: NSToolbarItem?
    private weak var searchItem: NSToolbarItem?
    private weak var searchField: NSSearchField?
    private weak var historySearchRangeButton: NSPopUpButton?
    private weak var pillGroupItem: NSToolbarItemGroup?
    private weak var homePillGroupItem: NSToolbarItemGroup?
    private weak var historyDeleteItem: NSToolbarItem?
    private weak var sidebarToggleItem: NSToolbarItem?
    private weak var lyricsToggleItem: NSToolbarItem?
    private weak var homeNavPillItem: NSToolbarItemGroup?

    private var fullscreenModeCancellable: AnyCancellable?
    private var featureTipPopover: NSPopover?
    private var lyricsFlashTicket = 0
    private var lyricsFlashFilled = false

    private var currentPageController: PlaylistPageController? {
        splitViewController?.playlistPageController
    }

    private var currentLibraryVM: LibraryViewModel? {
        appSession?.libraryVM
    }

    private var currentPlaybackCoordinator: PlaybackCoordinator? {
        appSession?.playbackCoordinator
    }

    private var currentPlayerVM: PlayerViewModel? {
        appSession?.playerVM
    }

    private var currentHistoryVM: PlaybackHistoryViewModel? {
        appSession?.playbackHistoryViewModel
    }

    private var isPlaybackHistoryMode: Bool {
        appSession?.uiState.contentMode == .playbackHistory
    }

    private lazy var sortMenu: NSMenu = {
        let menu = NSMenu(title: "Sort")
        menu.delegate = self
        return menu
    }()

    private var toolbar: NSToolbar?

    init(splitViewController: AppKitMainSplitViewController, appSession: AppSessionHost) {
        self.splitViewController = splitViewController
        self.appSession = appSession
        super.init()
    }

    func attachToWindow(_ window: NSWindow) {
        attachToWindow(window, rebuildLayout: true)
    }

    func makeFreshToolbarForWindowAttach() -> NSToolbar {
        closeFeatureTipPopover()
        if let oldToolbar = toolbar {
            clearToolbarItemTargets(oldToolbar)
            oldToolbar.delegate = nil
            if window?.toolbar === oldToolbar {
                window?.toolbar = nil
            }
        }
        let freshToolbar = makeToolbar()
        toolbar = freshToolbar
        resetToolbarItemReferences()
        return freshToolbar
    }

    func attachToFreshToolbarWindow(_ window: NSWindow) {
        attachToWindow(window, rebuildLayout: false)
    }

    private func attachToWindow(_ window: NSWindow, rebuildLayout: Bool) {
        if self.window !== window {
            closeFeatureTipPopover()
            resetToolbarItemReferences()
        }
        self.window = window
        isDetachingFromWindow = false
        isAttachedToWindow = true
        attachmentGeneration += 1
        // Start one-shot observation loops after the toolbar is installed in a live window.
        observeSearchText()
        observeMultiselectState()
        observeContentMode()
        observeLyricsVisibility()
        observeEmbeddedFullscreenMode()
        observeLibrarySearchResetTrigger()
        observeToolbarState()
        observeNowPlayingRevealState()
        observeHomeNavigationState()
        if rebuildLayout {
            applyToolbarLayoutForCurrentState()
        } else {
            reattachVisibleToolbarItemReferences()
            validateCurrentToolbarVisibleItems()
            syncVisibleToolbarItemPresentation()
        }
    }

    func detachFromWindow(_ window: NSWindow) {
        guard self.window === window else { return }
        isDetachingFromWindow = true
        isAttachedToWindow = false
        attachmentGeneration += 1
        closeFeatureTipPopover()
        fullscreenModeCancellable?.cancel()
        fullscreenModeCancellable = nil
        if let toolbar {
            clearToolbarItemTargets(toolbar)
            toolbar.delegate = nil
            if window.toolbar === toolbar {
                window.toolbar = nil
            }
        }
        resetToolbarItemReferences()
        toolbar = nil
        self.window = nil
        isDetachingFromWindow = false
    }

    func toggleMultiselectFromCommand() {
        let commandItem = multiselectItem ?? NSToolbarItem(itemIdentifier: Identifier.multiselect)
        handleToggleMultiselect(commandItem)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let appSession else { return true }

        let isLibraryMode = (appSession.uiState.contentMode == .library)
        let isHistoryMode = (appSession.uiState.contentMode == .playbackHistory)
        let hasLibrary = (appSession.libraryVM != nil)
        let hasPlayback = (appSession.playbackCoordinator != nil)
        let isHomeSelection = currentLibraryVM?.currentSelection == .home

        let queueTracks = currentPageController?.page?.queueTracks ?? []
        let hasSelection = (currentPageController?.selectedTrackIDs.isEmpty == false)
        let isSearching = currentPageController?.isSearchFilteringCurrentList == true
        let isCollectionSelection = currentLibraryVM.map {
            $0.supportsCustomCollectionOrder(for: $0.currentSelection)
        } ?? false
        let canPlayHistory = currentHistoryVM?.visibleItems.contains { item in
            currentLibraryVM?.allTracks.contains {
                $0.id == item.trackID && $0.availability != .missing
            } == true
        } == true

        switch item.itemIdentifier {
        case Identifier.sort:
            return isLibraryMode && hasLibrary && !isHomeSelection
        case Identifier.search:
            return (isLibraryMode || isHistoryMode) && hasLibrary
        case Identifier.multiselect:
            if isHistoryMode {
                return hasLibrary && currentHistoryVM?.hasVisibleItems == true
            }
            return isLibraryMode
                && hasLibrary
                && !isHomeSelection
                && currentPageController?.hasMultiselectRowsForCurrentSelection == true
                && !isSearching
        case Identifier.play:
            if isHistoryMode {
                return hasLibrary && hasPlayback && canPlayHistory
            }
            if !(isLibraryMode && hasLibrary && hasPlayback) { return false }
            if isHomeSelection {
                return !(currentLibraryVM?.allTracks.filter { $0.availability != .missing }.isEmpty ?? true)
            }
            return !queueTracks.isEmpty || (hasSelection && !isCollectionSelection)
        case Identifier.revealNowPlaying:
            return isLibraryMode
                && hasLibrary
                && currentPlayerVM?.currentTrack != nil
        case Identifier.import:
            return (isLibraryMode || isHistoryMode) && hasLibrary
        case Identifier.pillGroup:
            if isHistoryMode {
                return hasLibrary
            }
            return isLibraryMode && hasLibrary && !isHomeSelection
        case Identifier.homePillGroup:
            return isLibraryMode && hasLibrary && isHomeSelection
        case Identifier.sidebarToggle, Identifier.lyricsToggle:
            return true
        case Identifier.homeNavPill:
            return shouldShowHomeNavPill()
        default:
            return true
        }
    }

    private func shouldShowHomeNavPill() -> Bool {
        guard let appSession else { return false }
        if appSession.uiState.contentMode == .playbackHistory {
            return true
        }
        guard appSession.uiState.contentMode == .library else { return false }
        guard let libraryVM = appSession.libraryVM else { return false }
        return appSession.uiState.shouldShowHomeNavigationPill(libraryVM: libraryVM)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Identifier.sidebarToggle,
            .sidebarTrackingSeparator,
            Identifier.homeNavPill,
            Identifier.sort,
            Identifier.pillGroup,
            Identifier.homePillGroup,
            .flexibleSpace,
            Identifier.search,
            Identifier.lyricsToggle,
            .inspectorTrackingSeparator,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        desiredToolbarIdentifiersForCurrentState()
    }

    private func baseLibraryToolbarIdentifiers() -> [NSToolbarItem.Identifier] {
        [
            Identifier.sidebarToggle,
            .sidebarTrackingSeparator,
            Identifier.homeNavPill,
            Identifier.sort,
            Identifier.pillGroup,
            .flexibleSpace,
            Identifier.search,
            Identifier.lyricsToggle,
            .inspectorTrackingSeparator,
        ]
    }

    private func playbackHistoryToolbarIdentifiers() -> [NSToolbarItem.Identifier] {
        [
            Identifier.sidebarToggle,
            .sidebarTrackingSeparator,
            Identifier.homeNavPill,
            Identifier.pillGroup,
            .flexibleSpace,
            Identifier.search,
            Identifier.lyricsToggle,
            .inspectorTrackingSeparator,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Identifier.sidebarToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("toolbar.sidebar", comment: "Sidebar")
            item.paletteLabel = item.label
            item.toolTip = appSession?.uiState.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(handleSidebarToggle(_:))
            item.autovalidates = false
            item.isEnabled = true
            self.sidebarToggleItem = item
            return item

        case Identifier.homeNavPill:
            let backLabel = "后退"
            let forwardLabel = "前进"
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: backLabel)
                        ?? NSImage(),
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forwardLabel)
                        ?? NSImage()
                ],
                selectionMode: .momentary,
                labels: [backLabel, forwardLabel],
                target: self,
                action: #selector(handleHomeNavPillAction(_:))
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
            self.homeNavPillItem = group
            syncHomeNavPillPresentation()
            return group

        case Identifier.sort:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("sort.menu_title", comment: "Sort")
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(
                systemSymbolName: "arrow.up.arrow.down",
                accessibilityDescription: item.label
            )
            item.menu = sortMenu
            item.showsIndicator = true
            item.autovalidates = true
            return item

        case Identifier.pillGroup:
            let isHistoryMode = isPlaybackHistoryMode
            let multiselectLabel = NSLocalizedString("context.multiselect", comment: "Select")
            let playLabel = NSLocalizedString("context.play_all", comment: "Play All")
            let revealLabel = "定位正在播放"
            let deleteHistoryLabel = "删除播放历史"
            let importLabel = NSLocalizedString("context.import", comment: "Import")
            let multiselectSymbol = (isHistoryMode
                ? currentHistoryVM?.isMultiselectMode
                : currentPageController?.isMultiselectMode) == true
                ? "checkmark.circle.fill"
                : "checkmark.circle"

            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
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
                target: self,
                action: #selector(handlePillGroupAction(_:))
            )
            group.label = "Actions"
            group.paletteLabel = group.label
            group.controlRepresentation = .expanded
            group.autovalidates = false
            group.isEnabled = true
            self.pillGroupItem = group
            if group.subitems.indices.contains(0) {
                self.multiselectItem = group.subitems[0]
                group.subitems[0].toolTip = multiselectLabel
            }
            if group.subitems.indices.contains(1) {
                self.playItem = group.subitems[1]
                group.subitems[1].toolTip = playLabel
            }
            if group.subitems.indices.contains(2) {
                if isHistoryMode {
                    self.historyDeleteItem = group.subitems[2]
                    group.subitems[2].toolTip = deleteHistoryLabel
                } else {
                    self.revealNowPlayingItem = group.subitems[2]
                    group.subitems[2].toolTip = revealLabel
                }
            }
            if group.subitems.indices.contains(3) {
                self.importItem = group.subitems[3]
                group.subitems[3].toolTip = importLabel
            }

            syncMultiselectItemPresentation()
            syncHistoryDeleteItemPresentation()
            syncRevealNowPlayingItemPresentation()
            return group

        case Identifier.homePillGroup:
            let playLabel = NSLocalizedString("context.play_all", comment: "Play All")
            let revealLabel = "定位正在播放"
            let importLabel = NSLocalizedString("context.import", comment: "Import")

            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
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
                target: self,
                action: #selector(handleHomePillGroupAction(_:))
            )
            group.label = "Home Actions"
            group.paletteLabel = group.label
            group.controlRepresentation = .expanded
            group.autovalidates = false
            group.isEnabled = true
            self.homePillGroupItem = group
            if group.subitems.indices.contains(0) {
                self.playItem = group.subitems[0]
                group.subitems[0].toolTip = playLabel
            }
            if group.subitems.indices.contains(1) {
                self.revealNowPlayingItem = group.subitems[1]
                group.subitems[1].toolTip = revealLabel
            }
            if group.subitems.indices.contains(2) {
                self.importItem = group.subitems[2]
                group.subitems[2].toolTip = importLabel
            }
            syncRevealNowPlayingItemPresentation()
            return group

        case Identifier.search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("library.search", comment: "Search")
            item.paletteLabel = item.label
            item.toolTip = item.label

            let isHistoryMode = isPlaybackHistoryMode
            let width: CGFloat = isHistoryMode ? 216 : 176
            let height: CGFloat = 28
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            container.translatesAutoresizingMaskIntoConstraints = false
            container.setContentHuggingPriority(.required, for: .horizontal)
            container.setContentCompressionResistancePriority(.required, for: .horizontal)

            let field = NSSearchField(frame: .zero)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.placeholderString = "在播放列表中搜索"
            field.sendsSearchStringImmediately = true
            field.target = self
            field.action = #selector(handleSearchChange(_:))
            field.delegate = self
            container.addSubview(field)

            var constraints = [
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                field.topAnchor.constraint(equalTo: container.topAnchor),
                field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                container.widthAnchor.constraint(equalToConstant: width),
                container.heightAnchor.constraint(equalToConstant: height)
            ]

            if isHistoryMode {
                let rangeButton = makeHistorySearchRangeButton()
                container.addSubview(rangeButton)
                NSLayoutConstraint.activate([
                    rangeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    rangeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    rangeButton.widthAnchor.constraint(equalToConstant: 30),
                    rangeButton.heightAnchor.constraint(equalToConstant: height)
                ])
                historySearchRangeButton = rangeButton
                constraints.append(field.leadingAnchor.constraint(equalTo: rangeButton.trailingAnchor, constant: 2))
            } else {
                constraints.append(field.leadingAnchor.constraint(equalTo: container.leadingAnchor))
            }
            NSLayoutConstraint.activate(constraints)

            item.view = container
            self.searchItem = item
            self.searchField = field
            syncSearchFieldFromModel()
            syncSearchPlaceholder()
            return item

        case Identifier.lyricsToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("lyrics", comment: "Lyrics")
            item.paletteLabel = item.label
            item.toolTip = appSession?.uiState.lyricsVisible == true ? "Hide Lyrics" : "Show Lyrics"
            item.target = self
            item.action = #selector(handleLyricsToggle(_:))
            item.autovalidates = false
            item.isEnabled = true
            self.lyricsToggleItem = item
            syncLyricsToggleItemPresentation()
            return item

        case .sidebarTrackingSeparator:
            guard let splitView = splitViewController?.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: 0
            )

        case .inspectorTrackingSeparator:
            guard let splitView = splitViewController?.splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitView,
                dividerIndex: AppKitMainSplitViewController.mainLyricsDividerIndex
            )

        default:
            // System-provided items (.toggleSidebar, spacers) return nil.
            return nil
        }
    }

    private func makeHistorySearchRangeButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .small
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: "搜索范围"
        )
        button.toolTip = "搜索范围"
        button.target = self
        button.action = #selector(handleHistorySearchRange(_:))

        let menu = NSMenu(title: "搜索范围")
        for range in PlaybackHistorySearchRange.allCases {
            let item = NSMenuItem(
                title: range.title,
                action: #selector(handleHistorySearchRangeMenuItem(_:)),
                keyEquivalent: ""
            )
            item.representedObject = range.rawValue
            item.target = self
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    // MARK: - Sort Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sortMenu else { return }
        rebuildSortMenu()
    }

    private func rebuildSortMenu() {
        sortMenu.removeAllItems()
        guard let libraryVM = appSession?.libraryVM else { return }

        let keyHeader = NSMenuItem(title: NSLocalizedString("sort.by", comment: "Sort by"), action: nil, keyEquivalent: "")
        keyHeader.isEnabled = false
        sortMenu.addItem(keyHeader)

        // Context-aware sort keys: collection pages
        // expose their own sort dimensions (track count, album count, etc.),
        // while track-list selections continue to use TrackSortKey.
        switch libraryVM.currentSelection {
        case .allPlaylists:
            for key in PlaylistSortKey.allCases {
                let item = NSMenuItem(
                    title: key.title,
                    action: #selector(handleSortKey(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = key.rawValue
                item.state = (libraryVM.playlistSortKey == key) ? .on : .off
                item.target = self
                sortMenu.addItem(item)
            }
        case .allAlbums:
            for key in AlbumSortKey.allCases {
                let item = NSMenuItem(
                    title: key.title,
                    action: #selector(handleSortKey(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = key.rawValue
                item.state = (libraryVM.albumSortKey == key) ? .on : .off
                item.target = self
                sortMenu.addItem(item)
            }
        case .allArtists:
            for key in ArtistSortKey.allCases {
                let item = NSMenuItem(
                    title: key.title,
                    action: #selector(handleSortKey(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = key.rawValue
                item.state = (libraryVM.artistSortKey == key) ? .on : .off
                item.target = self
                sortMenu.addItem(item)
            }
        default:
            for key in TrackSortKey.allCases
                where key != .custom || libraryVM.supportsCustomTrackOrder()
            {
                let item = NSMenuItem(
                    title: key.title,
                    action: #selector(handleSortKey(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = key.rawValue
                item.state = (libraryVM.trackSortKey == key) ? .on : .off
                item.target = self
                sortMenu.addItem(item)
            }
        }

        sortMenu.addItem(.separator())

        let isCustomTrackSort: Bool = {
            switch libraryVM.currentSelection {
            case .allPlaylists, .allAlbums, .allArtists:
                return libraryVM.isCustomCollectionSortActive()
            default:
                return libraryVM.trackSortKey == .custom
            }
        }()
        for order in TrackSortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(handleSortOrder(_:)), keyEquivalent: "")
            item.representedObject = order.rawValue
            item.state = (libraryVM.trackSortOrder == order) ? .on : .off
            item.isEnabled = !isCustomTrackSort
            item.target = self
            sortMenu.addItem(item)
        }
    }

    @objc
    private func handleSortKey(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let libraryVM = currentLibraryVM
        else { return }

        // Dispatch the selected raw value into the right model property based
        // on the current selection. This lets the same toolbar menu item
        // action serve TrackSortKey and collection sort keys.
        switch libraryVM.currentSelection {
        case .allPlaylists:
            guard let key = PlaylistSortKey(rawValue: raw) else { return }
            if key == .custom {
                currentPageController?.activateCustomSortFromCurrentDisplay(reason: "toolbar.customPlaylistSort")
                validateCurrentToolbarVisibleItems()
                return
            }
            libraryVM.playlistSortKey = key
        case .allAlbums:
            guard let key = AlbumSortKey(rawValue: raw) else { return }
            if key == .custom {
                currentPageController?.activateCustomSortFromCurrentDisplay(reason: "toolbar.customAlbumSort")
                validateCurrentToolbarVisibleItems()
                return
            }
            libraryVM.albumSortKey = key
        case .allArtists:
            guard let key = ArtistSortKey(rawValue: raw) else { return }
            if key == .custom {
                currentPageController?.activateCustomSortFromCurrentDisplay(reason: "toolbar.customArtistSort")
                validateCurrentToolbarVisibleItems()
                return
            }
            libraryVM.artistSortKey = key
        default:
            guard let key = TrackSortKey(rawValue: raw) else { return }
            if key == .custom {
                currentPageController?.activateCustomSortFromCurrentDisplay(reason: "toolbar.customSort")
                validateCurrentToolbarVisibleItems()
                return
            }
            libraryVM.trackSortKey = key
            currentPageController?.handleSortChange(reason: "toolbar.sortKey")
        }
        validateCurrentToolbarVisibleItems()
    }

    @objc
    private func handleSortOrder(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let order = TrackSortOrder(rawValue: raw),
            let libraryVM = currentLibraryVM
        else { return }
        libraryVM.trackSortOrder = order
        currentPageController?.handleSortChange(reason: "toolbar.sortOrder")
        validateCurrentToolbarVisibleItems()
    }

    // MARK: - Actions

    @objc
    private func handleSearchChange(_ sender: NSSearchField) {
        if isPlaybackHistoryMode {
            currentHistoryVM?.searchText = sender.stringValue
            syncMultiselectItemPresentation()
            validateCurrentToolbarVisibleItems()
            return
        }
        currentPageController?.prepareForSearchInteraction()
        currentPageController?.searchText = sender.stringValue
        currentPageController?.handleSearchChange()
        syncMultiselectItemPresentation()
        validateCurrentToolbarVisibleItems()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        if isPlaybackHistoryMode {
            validateCurrentToolbarVisibleItems()
            return
        }
        currentPageController?.prepareForSearchInteraction()
        syncMultiselectItemPresentation()
        validateCurrentToolbarVisibleItems()
    }

    @objc
    private func handleSidebarToggle(_ sender: NSToolbarItem) {
        guard isCurrentToolbarAttached else { return }
        guard let splitViewController else { return }
        splitViewController.setSidebarVisible(!splitViewController.isSidebarVisible)
        syncSidebarToggleItemPresentation()
    }

    @objc
    private func handleLyricsToggle(_ sender: NSToolbarItem) {
        guard isCurrentToolbarAttached else { return }
        guard let splitViewController else { return }
        lyricsFlashTicket += 1
        let ticket = lyricsFlashTicket
        let generation = attachmentGeneration
        lyricsFlashFilled = true
        syncLyricsToggleItemPresentation()
        splitViewController.setLyricsVisible(!splitViewController.isLyricsVisible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self else { return }
            if self.lyricsFlashTicket == ticket, self.isCurrentAttachment(generation) {
                self.lyricsFlashFilled = false
                self.syncLyricsToggleItemPresentation()
            }
        }
    }

    @objc
    private func handleToggleMultiselect(_ sender: NSToolbarItem) {
        if isPlaybackHistoryMode {
            guard let historyVM = currentHistoryVM, historyVM.hasVisibleItems else { return }
            historyVM.toggleMultiselectMode()
            syncMultiselectItemPresentation()
            syncHistoryDeleteItemPresentation()
            validateCurrentToolbarVisibleItems()
            return
        }
        guard let pageController = currentPageController else { return }
        guard pageController.hasMultiselectRowsForCurrentSelection else { return }
        let didEnable = pageController.toggleMultiselectModeIfAllowed()
        if !didEnable {
            closeFeatureTipPopover()
        }
        syncMultiselectItemPresentation()
        validateCurrentToolbarVisibleItems()
        if didEnable {
            let generation = attachmentGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.showShiftRangeSelectionTipIfNeeded()
            }
        }
    }

    private func showShiftRangeSelectionTipIfNeeded() {
        guard featureTipPopover?.isShown != true else { return }
        guard AppVersionGate.shared.shouldShowFeatureTip(
            featureKey: FeatureTips.shiftRangeSelectionKey,
            introducedBuild: FeatureTips.shiftRangeSelectionIntroducedBuild,
            maxDisplayCount: FeatureTips.shiftRangeSelectionMaxDisplayCount
        ) else { return }
        guard let anchor = multiselectTipAnchor() else { return }

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentSize = NSSize(width: 288, height: 118)
        popover.contentViewController = NSHostingController(
            rootView: ShiftRangeSelectionTipView { [weak self] in
                AppVersionGate.shared.markFeatureTipDismissed(
                    featureKey: FeatureTips.shiftRangeSelectionKey
                )
                self?.featureTipPopover?.performClose(nil)
                self?.featureTipPopover = nil
            }
        )

        featureTipPopover = popover
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minY)
        AppVersionGate.shared.recordFeatureTipDisplayed(
            featureKey: FeatureTips.shiftRangeSelectionKey
        )
    }

    private func closeFeatureTipPopover() {
        featureTipPopover?.close()
        featureTipPopover = nil
    }

    private func multiselectAnchorRect(in view: NSView) -> NSRect {
        if let segmentedControl = view as? NSSegmentedControl {
            let segmentCount = max(segmentedControl.segmentCount, 1)
            return NSRect(
                x: segmentedControl.bounds.minX,
                y: segmentedControl.bounds.minY,
                width: segmentedControl.bounds.width / CGFloat(segmentCount),
                height: segmentedControl.bounds.height
            )
        }

        let segmentWidth = max(view.bounds.width / 4, 28)
        return NSRect(
            x: view.bounds.minX,
            y: view.bounds.minY,
            width: segmentWidth,
            height: view.bounds.height
        )
    }

    private func multiselectTipAnchor() -> (view: NSView, rect: NSRect)? {
        if let itemView = multiselectItem?.view {
            return (itemView, itemView.bounds)
        }

        if let groupView = pillGroupItem?.view {
            return (groupView, multiselectAnchorRect(in: groupView))
        }

        guard let rootView = window?.contentView?.superview ?? window?.contentView else { return nil }
        if let segmentedControl = firstSubview(
            in: rootView,
            matching: { view in
                guard let control = view as? NSSegmentedControl else { return false }
                return control.segmentCount == 4
            }
        ) as? NSSegmentedControl {
            return (segmentedControl, multiselectAnchorRect(in: segmentedControl))
        }

        if let toolbarView = firstSubview(
            in: rootView,
            matching: { view in
                let className = String(describing: type(of: view))
                return className.localizedCaseInsensitiveContains("toolbar")
                    && view.bounds.width > 80
                    && view.bounds.height > 20
            }
        ) {
            let width = min(toolbarView.bounds.width, 360)
            let rect = NSRect(
                x: toolbarView.bounds.midX - width / 2,
                y: toolbarView.bounds.minY,
                width: width,
                height: toolbarView.bounds.height
            )
            return (toolbarView, rect)
        }

        guard let contentView = window?.contentView else { return nil }
        let width = min(contentView.bounds.width - 32, 320)
        let rect = NSRect(
            x: contentView.bounds.minX + 16,
            y: contentView.bounds.maxY - 1,
            width: max(width, 80),
            height: 1
        )
        return (contentView, rect)
    }

    private func firstSubview(
        in view: NSView,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        if predicate(view) { return view }
        for subview in view.subviews {
            if let match = firstSubview(in: subview, matching: predicate) {
                return match
            }
        }
        return nil
    }

    @objc
    private func handlePlayFromToolbar(_ sender: NSToolbarItem) {
        if isPlaybackHistoryMode {
            guard let historyVM = currentHistoryVM,
                  let playbackCoordinator = currentPlaybackCoordinator,
                  let libraryVM = currentLibraryVM
            else { return }
            historyVM.playRandom(
                using: playbackCoordinator,
                libraryVM: libraryVM
            )
            syncRevealNowPlayingItemPresentation()
            validateCurrentToolbarVisibleItems()
            return
        }
        guard
            let pageController = currentPageController,
            let playbackCoordinator = currentPlaybackCoordinator,
            let libraryVM = currentLibraryVM
        else { return }

        let toolbarSelectionIdentity: String = {
            if let identity = pageController.page?.selectionIdentity {
                return identity
            }
            switch libraryVM.currentSelection {
            case .home:
                return "home"
            case .allSongs:
                return "allSongs"
            case .allPlaylists:
                return "allPlaylists"
            case .allAlbums:
                return "allAlbums"
            case .allArtists:
                return "allArtists"
            case .playlist(let id):
                return "playlist-\(id.uuidString)"
            case .artist(let key):
                return "artist-\(key)"
            case .album(let key):
                return "album-\(key)"
            }
        }()

        if libraryVM.currentSelection == .home {
            let tracks = libraryVM.allTracks.filter { $0.availability != .missing }
            guard !tracks.isEmpty else { return }
            playbackCoordinator.playRandomTracks(
                tracks,
                libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
            )
            return
        }

        let isCollectionSelection = libraryVM.supportsCustomCollectionOrder(
            for: libraryVM.currentSelection
        )

        if !isCollectionSelection,
           pageController.isMultiselectMode,
           !pageController.selectedTrackIDs.isEmpty {
            let selectedTracks = selectedTracksForToolbar(pageController: pageController)
            guard !selectedTracks.isEmpty else { return }
            if case .album = libraryVM.currentSelection {
                playbackCoordinator.playTracks(
                    selectedTracks,
                    libraryQueueSource: .librarySelection(toolbarSelectionIdentity),
                    startPolicy: .forceSequentialTemporary
                )
                return
            }
            playbackCoordinator.playRandomTracks(
                selectedTracks,
                libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
            )
            return
        }

        let queueTracks = pageController.page?.queueTracks ?? []
        guard !queueTracks.isEmpty else { return }
        if case .album = libraryVM.currentSelection {
            playbackCoordinator.playTracks(
                queueTracks,
                libraryQueueSource: .librarySelection(toolbarSelectionIdentity),
                startPolicy: .forceSequentialTemporary
            )
            return
        }
        playbackCoordinator.playRandomTracks(
            queueTracks,
            libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
        )
    }

    @objc
    private func handleDeleteHistoryFromToolbar(_ sender: NSToolbarItem) {
        guard isPlaybackHistoryMode,
              let historyVM = currentHistoryVM,
              historyVM.hasSelectedEvents,
              let historyStore = appSession?.playbackHistoryStore
        else { return }

        historyVM.deleteSelected(using: historyStore)
        syncMultiselectItemPresentation()
        syncHistoryDeleteItemPresentation()
        validateCurrentToolbarVisibleItems()
    }

    @objc
    private func handleHistorySearchRange(_ sender: NSPopUpButton) {
        guard isPlaybackHistoryMode,
              let rawValue = sender.selectedItem?.representedObject as? String,
              let range = PlaybackHistorySearchRange(rawValue: rawValue)
        else { return }
        currentHistoryVM?.searchRange = range
        syncHistorySearchRangePresentation()
        validateCurrentToolbarVisibleItems()
    }

    @objc
    private func handleHistorySearchRangeMenuItem(_ sender: NSMenuItem) {
        guard isPlaybackHistoryMode,
              let rawValue = sender.representedObject as? String,
              let range = PlaybackHistorySearchRange(rawValue: rawValue)
        else { return }
        currentHistoryVM?.searchRange = range
        syncHistorySearchRangePresentation()
        validateCurrentToolbarVisibleItems()
    }

    @objc
    private func handleRevealNowPlaying(_ sender: NSToolbarItem) {
        guard
            let libraryVM = currentLibraryVM,
            let pageController = currentPageController,
            let playerVM = currentPlayerVM,
            let track = playerVM.currentTrack
        else { return }

        let targetSelection = librarySelectionForNowPlayingTrack(
            track,
            libraryVM: libraryVM,
            playerVM: playerVM
        )

        // If the target lives in a different selection (e.g. the user is on
        // Home, whose rows contain every track), defer the reveal until the
        // selection switch triggers a rebuild for the target page. Otherwise
        // the reveal would be consumed by the current page's rows and the
        // target playlist would never scroll.
        let needsSelectionSwitch = libraryVM.currentSelection != targetSelection
        pageController.requestRevealTrack(
            track.id,
            animated: true,
            deferUntilRebuild: needsSelectionSwitch
        )
        appSession?.uiState.showLibrary()
        libraryVM.selectOrResetCurrentSelection(targetSelection)
        syncSearchPlaceholder()
        validateCurrentToolbarVisibleItems()
    }

    @objc
    private func handleImportToPlaylist(_ sender: NSToolbarItem) {
        guard let libraryVM = currentLibraryVM else { return }
        let contentMode = appSession?.uiState.contentMode ?? .library
        Task { @MainActor in
            await libraryVM.importToCurrentContext(contentMode: contentMode)
        }
    }

    @objc
    private func handlePillItemAction(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Identifier.multiselect:
            handleToggleMultiselect(sender)
        case Identifier.play:
            handlePlayFromToolbar(sender)
        case Identifier.revealNowPlaying:
            if isPlaybackHistoryMode {
                handleDeleteHistoryFromToolbar(sender)
            } else {
                handleRevealNowPlaying(sender)
            }
        case Identifier.import:
            handleImportToPlaylist(sender)
        default:
            break
        }
    }

    @objc
    private func handleHomeNavPillAction(_ sender: Any) {
        let selectedIndex: Int
        if let group = sender as? NSToolbarItemGroup {
            selectedIndex = group.selectedIndex
        } else if let segmentedControl = sender as? NSSegmentedControl {
            selectedIndex = segmentedControl.selectedSegment
        } else {
            selectedIndex = homeNavPillItem?.selectedIndex ?? -1
        }
        guard let appSession, let libraryVM = appSession.libraryVM else { return }

        if isPlaybackHistoryMode {
            switch selectedIndex {
            case 0:
                if appSession.uiState.playbackHistoryDate != nil {
                    appSession.uiState.showPlaybackHistory()
                } else {
                    appSession.uiState.showLibrary()
                }
            default:
                break
            }
            syncHomeNavPillPresentation()
            validateCurrentToolbarVisibleItems()
            return
        }

        switch selectedIndex {
        case 0:
            appSession.uiState.goBackInHomeContext(libraryVM: libraryVM)
        case 1:
            appSession.uiState.goForwardInHomeContext(libraryVM: libraryVM)
        default:
            break
        }
        syncHomeNavPillPresentation()
        validateCurrentToolbarVisibleItems()
    }

    private func syncHomeNavPillPresentation() {
        guard let group = homeNavPillItem else { return }
        guard let appSession = appSession else {
            group.subitems.forEach { $0.isEnabled = false }
            return
        }
        if appSession.uiState.contentMode == .playbackHistory {
            if group.subitems.indices.contains(0) {
                group.subitems[0].isEnabled = true
            }
            if group.subitems.indices.contains(1) {
                group.subitems[1].isEnabled = false
            }
            group.isEnabled = true
            return
        }
        let canBack = !appSession.uiState.homeBackStack.isEmpty
        let canForward = !appSession.uiState.homeForwardStack.isEmpty
        if group.subitems.indices.contains(0) {
            group.subitems[0].isEnabled = canBack
        }
        if group.subitems.indices.contains(1) {
            group.subitems[1].isEnabled = canForward
        }
        group.isEnabled = canBack || canForward
    }

    @objc
    private func handlePillGroupAction(_ sender: Any) {
        let selectedIndex: Int
        if let group = sender as? NSToolbarItemGroup {
            selectedIndex = group.selectedIndex
        } else if let segmentedControl = sender as? NSSegmentedControl {
            selectedIndex = segmentedControl.selectedSegment
        } else {
            selectedIndex = pillGroupItem?.selectedIndex ?? -1
        }

        switch selectedIndex {
        case 0:
            handleToggleMultiselect(multiselectItem ?? NSToolbarItem(itemIdentifier: Identifier.multiselect))
        case 1:
            handlePlayFromToolbar(playItem ?? NSToolbarItem(itemIdentifier: Identifier.play))
        case 2:
            if isPlaybackHistoryMode {
                handleDeleteHistoryFromToolbar(
                    historyDeleteItem ?? NSToolbarItem(itemIdentifier: Identifier.revealNowPlaying)
                )
            } else {
                handleRevealNowPlaying(
                    revealNowPlayingItem ?? NSToolbarItem(itemIdentifier: Identifier.revealNowPlaying)
                )
            }
        case 3:
            handleImportToPlaylist(importItem ?? NSToolbarItem(itemIdentifier: Identifier.import))
        default:
            break
        }
    }

    @objc
    private func handleHomePillGroupAction(_ sender: Any) {
        let selectedIndex: Int
        if let group = sender as? NSToolbarItemGroup {
            selectedIndex = group.selectedIndex
        } else if let segmentedControl = sender as? NSSegmentedControl {
            selectedIndex = segmentedControl.selectedSegment
        } else {
            selectedIndex = homePillGroupItem?.selectedIndex ?? -1
        }

        switch selectedIndex {
        case 0:
            handlePlayFromToolbar(playItem ?? NSToolbarItem(itemIdentifier: Identifier.play))
        case 1:
            handleRevealNowPlaying(
                revealNowPlayingItem ?? NSToolbarItem(itemIdentifier: Identifier.revealNowPlaying)
            )
        case 2:
            handleImportToPlaylist(importItem ?? NSToolbarItem(itemIdentifier: Identifier.import))
        default:
            break
        }
    }

    private func selectedTracksForToolbar(pageController: PlaylistPageController) -> [Track] {
        guard let rows = pageController.page?.rows else { return [] }
        return rows.compactMap { row in
            guard pageController.selectedTrackIDs.contains(row.id) else { return nil }
            return pageController.latestTrackFromLibrary(trackID: row.id)
        }
    }

    private func librarySelectionForNowPlayingTrack(
        _ track: Track,
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel
    ) -> LibrarySelection {
        if case .librarySelection(let identity) = playerVM.activeLibraryQueueSource,
           let sourceSelection = librarySelection(fromQueueIdentity: identity, libraryVM: libraryVM),
           selection(sourceSelection, contains: track, libraryVM: libraryVM) {
            return sourceSelection
        }

        if let playlist = libraryVM.playlists.first(where: { playlist in
            playlist.tracks.contains { $0.id == track.id }
        }) {
            return .playlist(playlist.id)
        }

        return .allSongs
    }

    private func librarySelection(
        fromQueueIdentity identity: String,
        libraryVM: LibraryViewModel
    ) -> LibrarySelection? {
        if let playlistID = uuidSuffix(identity, prefixes: [
            "playlist-",
            "home-playlist-",
            "all-playlists-"
        ]) {
            return .playlist(playlistID)
        }

        if identity == "allSongs" {
            return .allSongs
        }

        if identity.hasPrefix("home-album-") {
            return .album(String(identity.dropFirst("home-album-".count)))
        }
        if let albumSelection = librarySelection(
            identity: identity,
            prefix: "album-",
            entries: libraryVM.albumEntries,
            id: \.id,
            key: \.canonicalKey,
            makeSelection: { .album($0) }
        ) {
            return albumSelection
        }

        if identity.hasPrefix("home-artist-") {
            return .artist(String(identity.dropFirst("home-artist-".count)))
        }
        if let artistSelection = librarySelection(
            identity: identity,
            prefix: "artist-",
            entries: libraryVM.artistEntries,
            id: \.id,
            key: \.canonicalName,
            makeSelection: { .artist($0) }
        ) {
            return artistSelection
        }

        return nil
    }

    private func uuidSuffix(_ identity: String, prefixes: [String]) -> UUID? {
        for prefix in prefixes where identity.hasPrefix(prefix) {
            let raw = String(identity.dropFirst(prefix.count))
            if let uuid = UUID(uuidString: raw) {
                return uuid
            }
        }
        return nil
    }

    private func librarySelection<Entry>(
        identity: String,
        prefix: String,
        entries: [Entry],
        id: KeyPath<Entry, UUID>,
        key: KeyPath<Entry, String>,
        makeSelection: (String) -> LibrarySelection
    ) -> LibrarySelection? {
        guard identity.hasPrefix(prefix) else { return nil }
        let raw = String(identity.dropFirst(prefix.count))
        if let entry = entries.first(where: { $0[keyPath: id].uuidString == raw }) {
            return makeSelection(entry[keyPath: key])
        }
        if entries.contains(where: { $0[keyPath: key] == raw }) {
            return makeSelection(raw)
        }
        return nil
    }

    private func selection(
        _ selection: LibrarySelection,
        contains track: Track,
        libraryVM: LibraryViewModel
    ) -> Bool {
        switch selection {
        case .home, .allSongs:
            return libraryVM.allTracks.contains { $0.id == track.id }
        case .playlist(let id):
            return libraryVM.playlists
                .first(where: { $0.id == id })?
                .tracks
                .contains { $0.id == track.id } == true
        case .artist(let key):
            return LibraryNormalization.containsArtist(key, in: track.artist)
        case .album(let key):
            return track.albumGroupKey == key
        case .allPlaylists, .allAlbums, .allArtists:
            return false
        }
    }

    private func syncMultiselectItemPresentation() {
        if isPlaybackHistoryMode {
            let isOn = currentHistoryVM?.isMultiselectMode == true
            let symbol = isOn ? "checkmark.circle.fill" : "checkmark.circle"
            multiselectItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: multiselectItem?.label)
            multiselectItem?.isEnabled = currentHistoryVM?.hasVisibleItems == true
            return
        }
        let pageController = currentPageController
        let isOn = pageController?.isMultiselectMode == true
        let symbol = isOn ? "checkmark.circle.fill" : "checkmark.circle"
        multiselectItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: multiselectItem?.label)
        multiselectItem?.isEnabled = currentLibraryVM?.currentSelection != .home
            && pageController?.hasMultiselectRowsForCurrentSelection == true
            && pageController?.isSearchFilteringCurrentList != true
    }

    private func syncHistoryDeleteItemPresentation() {
        guard isPlaybackHistoryMode else {
            historyDeleteItem?.isEnabled = false
            return
        }
        historyDeleteItem?.isEnabled = currentHistoryVM?.hasSelectedEvents == true
    }

    private func syncRevealNowPlayingItemPresentation() {
        revealNowPlayingItem?.isEnabled = currentPlayerVM?.currentTrack != nil
    }

    private func syncSearchFieldFromModel() {
        guard searchItem != nil, let searchField else { return }
        if isPlaybackHistoryMode {
            let modelValue = currentHistoryVM?.searchText ?? ""
            if searchField.stringValue != modelValue {
                searchField.stringValue = modelValue
            }
            syncSearchPlaceholder()
            syncHistorySearchRangePresentation()
            return
        }
        guard let pageController = currentPageController else { return }
        let modelValue = pageController.searchText
        if searchField.stringValue != modelValue {
            searchField.stringValue = modelValue
        }
        syncSearchPlaceholder()
    }

    private func syncSearchPlaceholder() {
        guard let searchField else { return }
        if isPlaybackHistoryMode {
            searchField.placeholderString = "在最近播放记录中搜索"
            return
        }
        switch currentLibraryVM?.currentSelection {
        case .home, .allSongs:
            searchField.placeholderString = "在所有歌曲中搜索"
        case .allPlaylists:
            searchField.placeholderString = "在所有播放列表中搜索"
        case .playlist:
            searchField.placeholderString = "在播放列表中搜索"
        case .album:
            searchField.placeholderString = "在专辑中搜索"
        case .artist:
            searchField.placeholderString = "在歌手中搜索"
        case .allAlbums:
            searchField.placeholderString = "在所有专辑中搜索"
        case .allArtists:
            searchField.placeholderString = "在所有歌手中搜索"
        case nil:
            searchField.placeholderString = "在播放列表中搜索"
        }
    }

    private func syncHistorySearchRangePresentation() {
        guard let button = historySearchRangeButton,
              let historyVM = currentHistoryVM
        else { return }
        let range = historyVM.searchRange
        button.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle",
            accessibilityDescription: "搜索范围：\(range.title)"
        )
        button.toolTip = "搜索范围：\(range.title)"
        button.selectItem(withTitle: range.title)
        button.menu?.items.forEach { item in
            item.state = (item.representedObject as? String) == range.rawValue ? .on : .off
        }
    }

    private func resignSearchFocusIfNeeded() {
        guard let searchField else { return }
        guard let window = searchField.window ?? window else { return }
        let firstResponder = window.firstResponder
        if firstResponder === searchField || firstResponder === searchField.currentEditor() {
            window.makeFirstResponder(nil)
        }
    }

    private func syncSidebarToggleItemPresentation() {
        guard let item = sidebarToggleItem else { return }
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
        item.toolTip = appSession?.uiState.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar"
        item.isEnabled = true
    }

    private func syncLyricsToggleItemPresentation() {
        guard let item = lyricsToggleItem else { return }
        let symbol = lyricsFlashFilled ? "quote.bubble.fill" : "quote.bubble"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.toolTip = appSession?.uiState.lyricsVisible == true ? "Hide Lyrics" : "Show Lyrics"
        item.isEnabled = true
    }

    private func observeSearchText() {
        guard isCurrentToolbarAttached else { return }
        if isPlaybackHistoryMode, let historyVM = currentHistoryVM {
            let generation = attachmentGeneration
            withObservationTracking {
                _ = historyVM.searchText
            } onChange: {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentAttachment(generation) else { return }
                    self.syncSearchFieldFromModel()
                    self.validateCurrentToolbarVisibleItems()
                    self.observeSearchText()
                }
            }
            return
        }
        guard let pageController = currentPageController else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = pageController.searchText
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.syncSearchFieldFromModel()
                self.validateCurrentToolbarVisibleItems()
                self.observeSearchText()
            }
        }
    }

    private func observeMultiselectState() {
        guard isCurrentToolbarAttached else { return }
        if isPlaybackHistoryMode, let historyVM = currentHistoryVM {
            let generation = attachmentGeneration
            withObservationTracking {
                _ = historyVM.isMultiselectMode
                _ = historyVM.selectedEventIDs.count
            } onChange: {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentAttachment(generation) else { return }
                    self.syncMultiselectItemPresentation()
                    self.syncHistoryDeleteItemPresentation()
                    self.validateCurrentToolbarVisibleItems()
                    self.observeMultiselectState()
                }
            }
            return
        }
        guard let pageController = currentPageController else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = pageController.isMultiselectMode
            _ = pageController.selectedTrackIDs.count
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                if self.currentPageController?.isMultiselectMode != true {
                    self.closeFeatureTipPopover()
                }
                self.syncMultiselectItemPresentation()
                self.validateCurrentToolbarVisibleItems()
                self.observeMultiselectState()
            }
        }
    }

    private func observeContentMode() {
        guard isCurrentToolbarAttached else { return }
        guard let uiState = appSession?.uiState else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = uiState.contentMode
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.applyToolbarLayoutForCurrentState()
                self.syncSidebarToggleItemPresentation()
                self.syncSearchPlaceholder()
                self.validateCurrentToolbarVisibleItems()
                self.observeContentMode()
            }
        }
    }

    private func observeLyricsVisibility() {
        guard isCurrentToolbarAttached else { return }
        guard let uiState = appSession?.uiState else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = uiState.lyricsVisible
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.syncLyricsToggleItemPresentation()
                self.validateCurrentToolbarVisibleItems()
                self.observeLyricsVisibility()
            }
        }
    }

    private func observeEmbeddedFullscreenMode() {
        guard isCurrentToolbarAttached else { return }
        let generation = attachmentGeneration
        fullscreenModeCancellable = FullscreenWindowManager.shared.$presentationMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.applyToolbarLayoutForCurrentState()
            }
    }

    private var isCurrentToolbarAttached: Bool {
        guard isAttachedToWindow, !isDetachingFromWindow else { return false }
        guard let window, let toolbar else { return false }
        return window.toolbar === toolbar
    }

    private func isCurrentAttachment(_ generation: Int) -> Bool {
        generation == attachmentGeneration && isCurrentToolbarAttached
    }

    private func validateCurrentToolbarVisibleItems() {
        guard isCurrentToolbarAttached, let toolbar else { return }
        toolbar.validateVisibleItems()
    }

    private func applyToolbarLayoutForCurrentState() {
        guard isCurrentToolbarAttached, let window, let currentToolbar = toolbar else { return }
        let desiredIdentifiers = desiredToolbarIdentifiersForCurrentState()
        let currentIdentifiers = currentToolbar.items.map(\.itemIdentifier)
        guard currentIdentifiers != desiredIdentifiers else {
            reattachVisibleToolbarItemReferences()
            validateCurrentToolbarVisibleItems()
            syncVisibleToolbarItemPresentation()
            return
        }

        closeFeatureTipPopover()
        clearToolbarItemTargets(currentToolbar)
        currentToolbar.delegate = nil
        resetToolbarItemReferences()

        let freshToolbar = makeToolbar()
        toolbar = freshToolbar
        window.toolbar = freshToolbar

        reattachVisibleToolbarItemReferences()
        validateCurrentToolbarVisibleItems()
        syncVisibleToolbarItemPresentation()
    }

    private func resetToolbarItemReferences() {
        searchItem = nil
        searchField = nil
        historySearchRangeButton = nil
        multiselectItem = nil
        playItem = nil
        revealNowPlayingItem = nil
        importItem = nil
        pillGroupItem = nil
        homePillGroupItem = nil
        historyDeleteItem = nil
        sidebarToggleItem = nil
        lyricsToggleItem = nil
        homeNavPillItem = nil
    }

    private func reattachVisibleToolbarItemReferences() {
        guard isCurrentToolbarAttached, let toolbar else {
            resetToolbarItemReferences()
            return
        }
        resetToolbarItemReferences()

        for item in toolbar.items {
            switch item.itemIdentifier {
            case Identifier.sidebarToggle:
                item.target = self
                item.action = #selector(handleSidebarToggle(_:))
                item.autovalidates = false
                item.isEnabled = true
                sidebarToggleItem = item

            case Identifier.lyricsToggle:
                item.target = self
                item.action = #selector(handleLyricsToggle(_:))
                item.autovalidates = false
                item.isEnabled = true
                lyricsToggleItem = item

            case Identifier.search:
                searchItem = item
                if let itemView = item.view,
                   let field = firstSubview(in: itemView, matching: { $0 is NSSearchField }) as? NSSearchField {
                    field.target = self
                    field.action = #selector(handleSearchChange(_:))
                    field.delegate = self
                    searchField = field
                }
                if let itemView = item.view,
                   let rangeButton = firstSubview(in: itemView, matching: { $0 is NSPopUpButton }) as? NSPopUpButton {
                    rangeButton.target = self
                    rangeButton.action = #selector(handleHistorySearchRange(_:))
                    historySearchRangeButton = rangeButton
                }

            case Identifier.pillGroup:
                guard let group = item as? NSToolbarItemGroup else { continue }
                group.target = self
                group.action = #selector(handlePillGroupAction(_:))
                group.autovalidates = false
                group.isEnabled = true
                pillGroupItem = group
                if group.subitems.indices.contains(0) {
                    multiselectItem = group.subitems[0]
                }
                if group.subitems.indices.contains(1) {
                    playItem = group.subitems[1]
                }
                if group.subitems.indices.contains(2) {
                    if isPlaybackHistoryMode {
                        historyDeleteItem = group.subitems[2]
                    } else {
                        revealNowPlayingItem = group.subitems[2]
                    }
                }
                if group.subitems.indices.contains(3) {
                    importItem = group.subitems[3]
                }

            case Identifier.homePillGroup:
                guard let group = item as? NSToolbarItemGroup else { continue }
                group.target = self
                group.action = #selector(handleHomePillGroupAction(_:))
                group.autovalidates = false
                group.isEnabled = true
                homePillGroupItem = group
                if group.subitems.indices.contains(0) {
                    playItem = group.subitems[0]
                }
                if group.subitems.indices.contains(1) {
                    revealNowPlayingItem = group.subitems[1]
                }
                if group.subitems.indices.contains(2) {
                    importItem = group.subitems[2]
                }

            case Identifier.homeNavPill:
                guard let group = item as? NSToolbarItemGroup else { continue }
                group.target = self
                group.action = #selector(handleHomeNavPillAction(_:))
                group.autovalidates = false
                group.isEnabled = true
                homeNavPillItem = group

            default:
                continue
            }
        }
    }

    private func clearToolbarItemTargets(_ toolbar: NSToolbar) {
        for item in toolbar.items {
            clearToolbarItemTarget(item)
            if let group = item as? NSToolbarItemGroup {
                group.subitems.forEach { clearToolbarItemTarget($0) }
            }
        }
    }

    private func clearToolbarItemTarget(_ item: NSToolbarItem) {
        item.target = nil
        item.action = nil
        if let searchField = item.view.flatMap({ firstSubview(in: $0, matching: { $0 is NSSearchField }) }) as? NSSearchField {
            searchField.target = nil
            searchField.action = nil
            searchField.delegate = nil
        }
        if let rangeButton = item.view.flatMap({ firstSubview(in: $0, matching: { $0 is NSPopUpButton }) }) as? NSPopUpButton {
            rangeButton.target = nil
            rangeButton.action = nil
        }
    }

    private func syncVisibleToolbarItemPresentation() {
        syncSearchFieldFromModel()
        syncSidebarToggleItemPresentation()
        syncMultiselectItemPresentation()
        syncHistoryDeleteItemPresentation()
        syncRevealNowPlayingItemPresentation()
        syncLyricsToggleItemPresentation()
        syncHomeNavPillPresentation()
    }

    private func desiredToolbarIdentifiersForCurrentState() -> [NSToolbarItem.Identifier] {
        if FullscreenWindowManager.shared.isWindowedFullscreenActive {
            return []
        }

        if appSession?.uiState.contentMode == .playbackHistory {
            return playbackHistoryToolbarIdentifiers()
        }

        guard appSession?.uiState.contentMode == .library else {
            return [
                Identifier.sidebarToggle,
                .sidebarTrackingSeparator,
                .flexibleSpace,
                .inspectorTrackingSeparator,
                .flexibleSpace,
                Identifier.lyricsToggle
            ]
        }

        var ids = baseLibraryToolbarIdentifiers()
        if !shouldShowHomeNavPill() {
            ids.removeAll { $0 == Identifier.homeNavPill }
        }
        if currentLibraryVM?.currentSelection == .home {
            ids.removeAll { $0 == Identifier.sort || $0 == Identifier.pillGroup }
            if let flexibleIndex = ids.firstIndex(of: .flexibleSpace) {
                ids.insert(Identifier.homePillGroup, at: flexibleIndex)
            } else {
                ids.append(Identifier.homePillGroup)
            }
        }
        return ids
    }

    private func observeLibrarySearchResetTrigger() {
        guard isCurrentToolbarAttached else { return }
        guard let libraryVM = currentLibraryVM else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = libraryVM.searchResetTrigger
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                if self.isPlaybackHistoryMode {
                    self.currentHistoryVM?.searchText = ""
                    self.resignSearchFocusIfNeeded()
                    self.syncSearchFieldFromModel()
                    self.syncSearchPlaceholder()
                    self.observeLibrarySearchResetTrigger()
                    return
                }
                let hadSearch = !(self.currentPageController?.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(self.searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                self.currentPageController?.clearSearchAndRebuildIfNeeded(reason: "search-reset")
                if hadSearch {
                    self.resignSearchFocusIfNeeded()
                }
                self.syncSearchFieldFromModel()
                self.syncSearchPlaceholder()
                self.observeLibrarySearchResetTrigger()
            }
        }
    }

    private func observeHomeNavigationState() {
        guard isCurrentToolbarAttached else { return }
        guard let appSession else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = appSession.uiState.isHomeDrilldown
            _ = appSession.uiState.homeBackStack.count
            _ = appSession.uiState.homeForwardStack.count
            _ = appSession.libraryVM?.currentSelection
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.applyToolbarLayoutForCurrentState()
                self.syncSearchPlaceholder()
                self.syncHomeNavPillPresentation()
                self.validateCurrentToolbarVisibleItems()
                self.observeHomeNavigationState()
            }
        }
    }

    private func observeToolbarState() {
        guard isCurrentToolbarAttached else { return }
        if isPlaybackHistoryMode, let historyVM = currentHistoryVM {
            let generation = attachmentGeneration
            withObservationTracking {
                _ = historyVM.items.count
                _ = historyVM.visibleItems.count
                _ = historyVM.olderItemCount
                _ = historyVM.searchRange
                _ = historyVM.isMultiselectMode
                _ = historyVM.selectedEventIDs.count
            } onChange: {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentAttachment(generation) else { return }
                    self.syncMultiselectItemPresentation()
                    self.syncHistoryDeleteItemPresentation()
                    self.syncHistorySearchRangePresentation()
                    self.validateCurrentToolbarVisibleItems()
                    self.observeToolbarState()
                }
            }
            return
        }
        guard let pageController = currentPageController else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = pageController.page?.rows.count
            _ = pageController.page?.queueTracks.count
            _ = pageController.page?.selectionIdentity
            _ = pageController.phase
            _ = pageController.hasMultiselectRowsForCurrentSelection
            _ = pageController.isSearchFilteringCurrentList
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.syncMultiselectItemPresentation()
                self.syncHistoryDeleteItemPresentation()
                self.validateCurrentToolbarVisibleItems()
                self.observeToolbarState()
            }
        }
    }

    private func observeNowPlayingRevealState() {
        guard isCurrentToolbarAttached else { return }
        guard let playerVM = currentPlayerVM else { return }
        let generation = attachmentGeneration
        withObservationTracking {
            _ = playerVM.currentTrack?.id
            _ = playerVM.activeLibraryQueueSource
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentAttachment(generation) else { return }
                self.syncRevealNowPlayingItemPresentation()
                self.validateCurrentToolbarVisibleItems()
                self.observeNowPlayingRevealState()
            }
        }
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

private struct ShiftRangeSelectionTipView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("多选排序")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            Text("多选歌曲后，按住歌曲条目并拖动，可以对歌曲进行排序。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 288, alignment: .leading)
    }
}

//
//  AppKitMainToolbarController.swift
//  myPlayer2
//
//  Step 2: Real NSToolbar for the AppKit main split template window.
//  Owns toolbar items and bridges minimal actions to AppSession / hosted controllers.
//

import AppKit
import Combine
import Observation

@MainActor
final class AppKitMainToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate {
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
        static let `import` = NSToolbarItem.Identifier("AppKitMainToolbar.import")
        static let homePillGroup = NSToolbarItem.Identifier("AppKitMainToolbar.homePillGroup")
    }

    private weak var splitViewController: AppKitMainSplitViewController?
    private weak var appSession: AppSessionHost?
    private weak var window: NSWindow?

    private weak var multiselectItem: NSToolbarItem?
    private weak var playItem: NSToolbarItem?
    private weak var importItem: NSToolbarItem?
    private weak var searchItem: NSToolbarItem?
    private weak var searchField: NSSearchField?
    private weak var pillGroupItem: NSToolbarItemGroup?
    private weak var homePillGroupItem: NSToolbarItemGroup?
    private weak var sidebarToggleItem: NSToolbarItem?
    private weak var lyricsToggleItem: NSToolbarItem?
    private weak var homeNavPillItem: NSToolbarItemGroup?

    private var fullscreenModeCancellable: AnyCancellable?
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

    private lazy var sortMenu: NSMenu = {
        let menu = NSMenu(title: "Sort")
        menu.delegate = self
        return menu
    }()

    private(set) lazy var toolbar: NSToolbar = makeToolbar()

    init(splitViewController: AppKitMainSplitViewController, appSession: AppSessionHost) {
        self.splitViewController = splitViewController
        self.appSession = appSession
        super.init()
    }

    func attachToWindow(_ window: NSWindow) {
        self.window = window
        // Start one-shot observation loops after the toolbar is installed in a live window.
        observeSearchText()
        observeMultiselectState()
        observeContentMode()
        observeLyricsVisibility()
        observeEmbeddedFullscreenMode()
        observeLibrarySearchResetTrigger()
        observeToolbarState()
        observeHomeNavigationState()
        applyToolbarLayoutForCurrentState()
    }

    func toggleMultiselectFromCommand() {
        let commandItem = multiselectItem ?? NSToolbarItem(itemIdentifier: Identifier.multiselect)
        handleToggleMultiselect(commandItem)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let appSession else { return true }

        let isLibraryMode = (appSession.uiState.contentMode == .library)
        let hasLibrary = (appSession.libraryVM != nil)
        let hasPlayback = (appSession.playbackCoordinator != nil)
        let isHomeSelection = currentLibraryVM?.currentSelection == .home

        let queueTracks = currentPageController?.page?.queueTracks ?? []
        let hasRows = (currentPageController?.page?.rows.isEmpty == false)
        let hasSelection = (currentPageController?.selectedTrackIDs.isEmpty == false)

        switch item.itemIdentifier {
        case Identifier.sort:
            return isLibraryMode && hasLibrary && !isHomeSelection
        case Identifier.search:
            return isLibraryMode && hasLibrary
        case Identifier.multiselect:
            return isLibraryMode && hasLibrary && !isHomeSelection && hasRows
        case Identifier.play:
            if !(isLibraryMode && hasLibrary && hasPlayback) { return false }
            if isHomeSelection {
                return !(currentLibraryVM?.allTracks.filter { $0.availability != .missing }.isEmpty ?? true)
            }
            return !queueTracks.isEmpty || hasSelection
        case Identifier.import:
            return isLibraryMode && hasLibrary
        case Identifier.pillGroup:
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
            let multiselectLabel = NSLocalizedString("context.multiselect", comment: "Select")
            let playLabel = NSLocalizedString("context.play_all", comment: "Play All")
            let importLabel = NSLocalizedString("context.import", comment: "Import")
            let multiselectSymbol = currentPageController?.isMultiselectMode == true
                ? "checkmark.circle.fill"
                : "checkmark.circle"

            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: multiselectSymbol, accessibilityDescription: multiselectLabel)
                        ?? NSImage(),
                    NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
                        ?? NSImage(),
                    NSImage(systemSymbolName: "plus", accessibilityDescription: importLabel)
                        ?? NSImage()
                ],
                selectionMode: .momentary,
                labels: [multiselectLabel, playLabel, importLabel],
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
                self.importItem = group.subitems[2]
                group.subitems[2].toolTip = importLabel
            }

            syncMultiselectItemPresentation()
            return group

        case Identifier.homePillGroup:
            let playLabel = NSLocalizedString("context.play_all", comment: "Play All")
            let importLabel = NSLocalizedString("context.import", comment: "Import")

            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
                        ?? NSImage(),
                    NSImage(systemSymbolName: "plus", accessibilityDescription: importLabel)
                        ?? NSImage()
                ],
                selectionMode: .momentary,
                labels: [playLabel, importLabel],
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
                self.importItem = group.subitems[1]
                group.subitems[1].toolTip = importLabel
            }
            return group

        case Identifier.search:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = NSLocalizedString("library.search", comment: "Search")
            item.paletteLabel = item.label
            item.toolTip = item.label

            let width: CGFloat = 176
            let height: CGFloat = 28
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            container.translatesAutoresizingMaskIntoConstraints = false
            container.setContentHuggingPriority(.required, for: .horizontal)
            container.setContentCompressionResistancePriority(.required, for: .horizontal)

            let field = NSSearchField(frame: container.bounds)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.placeholderString = "在播放列表中搜索"
            field.sendsSearchStringImmediately = true
            field.target = self
            field.action = #selector(handleSearchChange(_:))
            container.addSubview(field)

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                field.topAnchor.constraint(equalTo: container.topAnchor),
                field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                container.widthAnchor.constraint(equalToConstant: width),
                container.heightAnchor.constraint(equalToConstant: height)
            ])

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

        // Context-aware sort keys: All Albums and All Artists pages
        // expose their own sort dimensions (track count, album count, etc.),
        // while track-list selections continue to use TrackSortKey.
        switch libraryVM.currentSelection {
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
            for key in TrackSortKey.allCases {
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

        for order in TrackSortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(handleSortOrder(_:)), keyEquivalent: "")
            item.representedObject = order.rawValue
            item.state = (libraryVM.trackSortOrder == order) ? .on : .off
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
        // action serve TrackSortKey, AlbumSortKey, and ArtistSortKey.
        switch libraryVM.currentSelection {
        case .allAlbums:
            guard let key = AlbumSortKey(rawValue: raw) else { return }
            libraryVM.albumSortKey = key
        case .allArtists:
            guard let key = ArtistSortKey(rawValue: raw) else { return }
            libraryVM.artistSortKey = key
        default:
            guard let key = TrackSortKey(rawValue: raw) else { return }
            libraryVM.trackSortKey = key
            currentPageController?.handleSortChange(reason: "toolbar.sortKey")
        }
        window?.toolbar?.validateVisibleItems()
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
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Actions

    @objc
    private func handleSearchChange(_ sender: NSSearchField) {
        currentPageController?.searchText = sender.stringValue
        currentPageController?.handleSearchChange()
        window?.toolbar?.validateVisibleItems()
    }

    @objc
    private func handleSidebarToggle(_ sender: NSToolbarItem) {
        guard let splitViewController else { return }
        splitViewController.setSidebarVisible(!splitViewController.isSidebarVisible)
        syncSidebarToggleItemPresentation()
    }

    @objc
    private func handleLyricsToggle(_ sender: NSToolbarItem) {
        guard let splitViewController else { return }
        lyricsFlashTicket += 1
        let ticket = lyricsFlashTicket
        lyricsFlashFilled = true
        syncLyricsToggleItemPresentation()
        splitViewController.setLyricsVisible(!splitViewController.isLyricsVisible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self else { return }
            if self.lyricsFlashTicket == ticket {
                self.lyricsFlashFilled = false
                self.syncLyricsToggleItemPresentation()
            }
        }
    }

    @objc
    private func handleToggleMultiselect(_ sender: NSToolbarItem) {
        guard let pageController = currentPageController else { return }
        guard let page = pageController.page, !page.rows.isEmpty else { return }
        pageController.isMultiselectMode.toggle()
        if !pageController.isMultiselectMode {
            pageController.selectedTrackIDs.removeAll()
        }
        syncMultiselectItemPresentation()
        window?.toolbar?.validateVisibleItems()
    }

    @objc
    private func handlePlayFromToolbar(_ sender: NSToolbarItem) {
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

        if pageController.isMultiselectMode, !pageController.selectedTrackIDs.isEmpty {
            let selectedTracks = selectedTracksForToolbar(pageController: pageController)
            guard !selectedTracks.isEmpty else { return }
            if case .album = libraryVM.currentSelection {
                playbackCoordinator.playTracks(
                    selectedTracks,
                    libraryQueueSource: .librarySelection(toolbarSelectionIdentity),
                    playbackOrderMode: .sequence
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
                playbackOrderMode: .sequence
            )
            return
        }
        playbackCoordinator.playRandomTracks(
            queueTracks,
            libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
        )
    }

    @objc
    private func handleImportToPlaylist(_ sender: NSToolbarItem) {
        guard let libraryVM = currentLibraryVM else { return }
        Task { @MainActor in
            await libraryVM.importToCurrentPlaylist()
        }
    }

    @objc
    private func handlePillItemAction(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Identifier.multiselect:
            handleToggleMultiselect(sender)
        case Identifier.play:
            handlePlayFromToolbar(sender)
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

        switch selectedIndex {
        case 0:
            appSession.uiState.goBackInHomeContext(libraryVM: libraryVM)
        case 1:
            appSession.uiState.goForwardInHomeContext(libraryVM: libraryVM)
        default:
            break
        }
        syncHomeNavPillPresentation()
        window?.toolbar?.validateVisibleItems()
    }

    private func syncHomeNavPillPresentation() {
        guard let group = homeNavPillItem else { return }
        guard let appSession = appSession else {
            group.subitems.forEach { $0.isEnabled = false }
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

    private func syncMultiselectItemPresentation() {
        guard let item = multiselectItem else { return }
        let isOn = currentPageController?.isMultiselectMode == true
        let symbol = isOn ? "checkmark.circle.fill" : "checkmark.circle"
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
    }

    private func syncSearchFieldFromModel() {
        guard searchItem != nil, let searchField else { return }
        guard let pageController = currentPageController else { return }
        let modelValue = pageController.searchText
        if searchField.stringValue != modelValue {
            searchField.stringValue = modelValue
        }
        syncSearchPlaceholder()
    }

    private func syncSearchPlaceholder() {
        guard let searchField else { return }
        switch currentLibraryVM?.currentSelection {
        case .home, .allSongs:
            searchField.placeholderString = "在所有歌曲中搜索"
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
        guard let pageController = currentPageController else { return }
        withObservationTracking {
            _ = pageController.searchText
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.syncSearchFieldFromModel()
                self?.window?.toolbar?.validateVisibleItems()
                self?.observeSearchText()
            }
        }
    }

    private func observeMultiselectState() {
        guard let pageController = currentPageController else { return }
        withObservationTracking {
            _ = pageController.isMultiselectMode
            _ = pageController.selectedTrackIDs.count
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.syncMultiselectItemPresentation()
                self?.window?.toolbar?.validateVisibleItems()
                self?.observeMultiselectState()
            }
        }
    }

    private func observeContentMode() {
        guard let uiState = appSession?.uiState else { return }
        withObservationTracking {
            _ = uiState.contentMode
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.applyToolbarLayoutForCurrentState()
                self?.syncSidebarToggleItemPresentation()
                self?.syncSearchPlaceholder()
                self?.window?.toolbar?.validateVisibleItems()
                self?.observeContentMode()
            }
        }
    }

    private func observeLyricsVisibility() {
        guard let uiState = appSession?.uiState else { return }
        withObservationTracking {
            _ = uiState.lyricsVisible
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.syncLyricsToggleItemPresentation()
                self?.window?.toolbar?.validateVisibleItems()
                self?.observeLyricsVisibility()
            }
        }
    }

    private func observeEmbeddedFullscreenMode() {
        fullscreenModeCancellable = FullscreenWindowManager.shared.$presentationMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyToolbarLayoutForCurrentState()
            }
    }

    private func applyToolbarLayoutForCurrentState() {
        let desiredIdentifiers = desiredToolbarIdentifiersForCurrentState()
        let currentIdentifiers = toolbar.items.map(\.itemIdentifier)
        guard currentIdentifiers != desiredIdentifiers else {
            toolbar.validateVisibleItems()
            return
        }

        searchItem = nil
        searchField = nil
        multiselectItem = nil
        playItem = nil
        importItem = nil
        pillGroupItem = nil
        homePillGroupItem = nil
        sidebarToggleItem = nil
        lyricsToggleItem = nil
        homeNavPillItem = nil

        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: toolbar.items.count - 1)
        }

        for (index, identifier) in desiredIdentifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }

        toolbar.validateVisibleItems()
        syncSearchFieldFromModel()
        syncSidebarToggleItemPresentation()
        syncMultiselectItemPresentation()
        syncLyricsToggleItemPresentation()
        syncHomeNavPillPresentation()
    }

    private func desiredToolbarIdentifiersForCurrentState() -> [NSToolbarItem.Identifier] {
        if FullscreenWindowManager.shared.isWindowedFullscreenActive {
            return []
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

        var ids = toolbarDefaultItemIdentifiers(toolbar)
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
        guard let libraryVM = currentLibraryVM else { return }
        withObservationTracking {
            _ = libraryVM.searchResetTrigger
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
        guard let appSession else { return }
        withObservationTracking {
            _ = appSession.uiState.isHomeDrilldown
            _ = appSession.uiState.homeBackStack.count
            _ = appSession.uiState.homeForwardStack.count
            _ = appSession.libraryVM?.currentSelection
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.applyToolbarLayoutForCurrentState()
                self?.syncSearchPlaceholder()
                self?.syncHomeNavPillPresentation()
                self?.window?.toolbar?.validateVisibleItems()
                self?.observeHomeNavigationState()
            }
        }
    }

    private func observeToolbarState() {
        guard let pageController = currentPageController else { return }
        withObservationTracking {
            _ = pageController.page?.rows.count
            _ = pageController.page?.queueTracks.count
            _ = pageController.page?.selectionIdentity
            _ = pageController.phase
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.window?.toolbar?.validateVisibleItems()
                self?.observeToolbarState()
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

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
        static let sort = NSToolbarItem.Identifier("AppKitMainToolbar.sort")
        static let pillGroup = NSToolbarItem.Identifier("AppKitMainToolbar.pillGroup")
        static let search = NSToolbarItem.Identifier("AppKitMainToolbar.search")
        static let lyricsToggle = NSToolbarItem.Identifier("AppKitMainToolbar.lyricsToggle")

        static let multiselect = NSToolbarItem.Identifier("AppKitMainToolbar.multiselect")
        static let play = NSToolbarItem.Identifier("AppKitMainToolbar.play")
        static let `import` = NSToolbarItem.Identifier("AppKitMainToolbar.import")
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
    private weak var sidebarToggleItem: NSToolbarItem?
    private weak var lyricsToggleItem: NSToolbarItem?

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

        let queueTracks = currentPageController?.page?.queueTracks ?? []
        let hasRows = (currentPageController?.page?.rows.isEmpty == false)
        let hasSelection = (currentPageController?.selectedTrackIDs.isEmpty == false)

        switch item.itemIdentifier {
        case Identifier.sort:
            return isLibraryMode && hasLibrary
        case Identifier.search:
            return isLibraryMode && hasLibrary
        case Identifier.multiselect:
            return isLibraryMode && hasLibrary && hasRows
        case Identifier.play:
            if !(isLibraryMode && hasLibrary && hasPlayback) { return false }
            return !queueTracks.isEmpty || hasSelection
        case Identifier.import:
            return isLibraryMode && hasLibrary
        case Identifier.pillGroup:
            return isLibraryMode && hasLibrary
        case Identifier.sidebarToggle, Identifier.lyricsToggle:
            return true
        default:
            return true
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Identifier.sidebarToggle,
            .sidebarTrackingSeparator,
            Identifier.sort,
            Identifier.pillGroup,
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

        for key in TrackSortKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(handleSortKey(_:)), keyEquivalent: "")
            item.representedObject = key.rawValue
            item.state = (libraryVM.trackSortKey == key) ? .on : .off
            item.target = self
            sortMenu.addItem(item)
        }

        sortMenu.addItem(.separator())

        let orderHeader = NSMenuItem(title: NSLocalizedString("sort.order", comment: "Order"), action: nil, keyEquivalent: "")
        orderHeader.isEnabled = false
        sortMenu.addItem(orderHeader)

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
            let key = TrackSortKey(rawValue: raw),
            let libraryVM = currentLibraryVM
        else { return }
        libraryVM.trackSortKey = key
        currentPageController?.handleSortChange(reason: "toolbar.sortKey")
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
            case .playlist(let id):
                return "playlist-\(id.uuidString)"
            case .artist(let key):
                return "artist-\(key)"
            case .album(let key):
                return "album-\(key)"
            }
        }()

        if pageController.isMultiselectMode, !pageController.selectedTrackIDs.isEmpty {
            let selectedTracks = selectedTracksForToolbar(pageController: pageController)
            guard !selectedTracks.isEmpty else { return }
            playbackCoordinator.playTracks(
                selectedTracks,
                libraryQueueSource: .librarySelection(toolbarSelectionIdentity)
            )
            return
        }

        let queueTracks = pageController.page?.queueTracks ?? []
        guard !queueTracks.isEmpty else { return }
        playbackCoordinator.playTracks(
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
        sidebarToggleItem = nil
        lyricsToggleItem = nil

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

        return toolbarDefaultItemIdentifiers(toolbar)
    }

    private func observeLibrarySearchResetTrigger() {
        guard let libraryVM = currentLibraryVM else { return }
        withObservationTracking {
            _ = libraryVM.searchResetTrigger
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                self?.syncSearchFieldFromModel()
                self?.observeLibrarySearchResetTrigger()
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

//
//  PlaylistTrackRowsSection.swift
//  myPlayer2
//
//  Track-specific adapter for the shared multiselect/reorder row shell.
//

import AppKit
import SwiftUI
import MotionKit

struct PlaylistTrackRowsSection: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy

    let rows: [PlaylistPageRowModel]
    let queueTracks: [Track]
    let selection: LibrarySelection
    let selectionIdentity: String
    let currentTrackID: UUID?
    let pageController: PlaylistPageController
    let menuBuilder: (UUID) -> AnyView
    var rowPrimaryColor: Color = ColorTokens.textPrimary
    var rowSecondaryColor: Color = ColorTokens.textSecondary
    var rowTertiaryColor: Color = ColorTokens.textTertiary

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("PlaylistTrackRowsSection.body")
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.hostBodyUpdate",
            detail: "surface=PlaylistTrackRowsSection, rows=\(rows.count), current=\(FirstUseHitchDiagnostics.trackIDPrefix(currentTrackID))"
        )

        reorderableRows
    }

    private var reorderableRows: some View {
        Group {
            if pageController.isMultiselectMode {
                swiftUIRows
            } else {
                appKitRows
            }
        }
    }

    private var swiftUIRows: some View {
        ReorderableMultiselectRowsSection(
            rows: rows,
            isMultiselectMode: pageController.isMultiselectMode,
            selectedIDs: pageController.selectedTrackIDs,
            canReorder: pageController.canManuallyReorderCurrentTracks,
            trackDragPayload: { ids in
                LibraryTrackDragPayload(
                    sessionID: libraryVM.trackDragSessionID,
                    sourceSelectionIdentity: selectionIdentity,
                    trackIDs: ids
                )
            },
            isSearchFiltering: pageController.isSearchFilteringTracks,
            coordinateSpaceName: "playlistTrackReorderSpace",
            rowCornerRadius: Constants.Layout.TrackRow.cornerRadius,
            bottomSpacerHeight: 160,
            badgeText: { "\($0)" },
            rowHeight: rowHeight(for:),
            onClearSelection: {
                guard libraryVM.currentSelection == selection,
                      pageController.toolbarSelectionIdentity == selectionIdentity else { return }
                pageController.clearMultiselectState()
            },
            onBeginReorder: {
                pageController.setNativeTrackDragActive(true)
            },
            onEndReorder: {
                pageController.setNativeTrackDragActive(false)
            },
            onCommitOrder: { orderedIDs in
                pageController.commitManualTrackOrder(
                    orderedTrackIDs: orderedIDs,
                    reason: "manual-track-reorder"
                )
            },
            rowContent: { row, isSelected, continuity in
                trackRow(row, isSelected: isSelected, selectionContinuity: continuity)
            },
            floatingContent: { row in
                floatingTrackCard(row)
            }
        )
    }

    private var appKitRows: some View {
        var rowIDsHasher = Hasher()
        rowIDsHasher.combine(rows.count)
        for row in rows {
            rowIDsHasher.combine(row.id)
        }

        let rowHeightSum = rows.reduce(CGFloat.zero) { $0 + rowHeight(for: $1) }
        let bottomSpacerHeight: CGFloat = 160
        let contentHeight = rowHeightSum + bottomSpacerHeight
        let dataRevision = AppKitPlaylistRowsDataRevision(
            selectionIdentity: selectionIdentity,
            searchText: pageController.searchText,
            sourceFingerprint: pageController.page?.sourceFingerprint ?? "",
            rowIDsHash: rowIDsHasher.finalize()
        )
        let presentation = AppKitPlaylistRowsPresentation(
            currentTrackID: currentTrackID,
            revealHighlightTrackID: pageController.revealHighlightTrackID,
            interactionsEnabled: pageController.areRowSecondaryInteractionsEnabled,
            artworkLoadingEnabled: pageController.areRowArtworkLoadsEnabled,
            trackDragActive: pageController.isNativeTrackDragActive,
            colorScheme: colorScheme,
            primaryColor: rowPrimaryColor,
            secondaryColor: rowSecondaryColor,
            tertiaryColor: rowTertiaryColor,
            artworkTintMode: settings.artworkTintMode
        )

        return ZStack(alignment: .topLeading) {
            // Keep lightweight, eagerly measured anchors so scroll targets
            // retain exact cumulative row positions as the AppKit table reuses
            // cells. AppKit draws the rows over these transparent anchors.
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: rowHeight(for: row))
                        .id(row.id)
                }
                Color.clear.frame(height: bottomSpacerHeight)
            }
            .frame(height: contentHeight, alignment: .top)
            .scrollTargetLayout()
            .accessibilityHidden(true)
            .allowsHitTesting(false)

            AppKitPlaylistTrackRowsTable(
                rows: rows,
                dataRevision: dataRevision,
                presentation: presentation,
                rowHeight: rowHeight(for:),
                rowContent: { row in
                    trackRow(row, isSelected: false, selectionContinuity: .isolated)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: rowHeight(for: row), alignment: .leading)
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)
        }
    }

    private func trackRow(
        _ row: PlaylistPageRowModel,
        isSelected: Bool,
        selectionContinuity: TrackRowSelectionContinuity
    ) -> some View {
        TrackRowView(
            model: row.trackRowModel,
            isPlaying: currentTrackID == row.id,
            isSelected: isSelected,
            selectionContinuity: selectionContinuity,
            showsSelectionBackground: false,
            enableSecondaryInteractions: pageController.areRowSecondaryInteractionsEnabled,
            enableArtworkLoading: pageController.areRowArtworkLoadsEnabled,
            revealHighlight: pageController.revealHighlightTrackID == row.id,
            onTap: { isShiftPressed in
                if LibraryRowInput.selectionModifiersHeld { pageController.updateSelectionModifiers(held: true) }
                if pageController.isMultiselectMode {
                    pageController.handleMultiselectRowTap(
                        trackID: row.id,
                        extendingRange: isShiftPressed
                    )
                } else {
                    guard let track = pageController.latestTrackFromLibrary(trackID: row.id) else { return }
                    if case .album = selection {
                        let startIndex = pageController.queueStartIndex(for: row.id)
                        playbackCoordinator.playTracks(
                            queueTracks,
                            startingAt: startIndex,
                            libraryQueueSource: .librarySelection(selectionIdentity),
                            startPolicy: .forceSequentialTemporary
                        )
                        return
                    }
                    playbackCoordinator.playTrack(
                        track,
                        inQueueFrom: queueTracks,
                        libraryQueueSource: .librarySelection(selectionIdentity)
                    )
                }
            },
            onLyricSnippetTap: {
                guard let startTime = row.lyricSnippetStartTime,
                      let track = pageController.latestTrackFromLibrary(trackID: row.id)
                else { return }
                if case .album = selection {
                    let startIndex = pageController.queueStartIndex(for: row.id)
                    playbackCoordinator.playTracks(
                        queueTracks,
                        startingAt: startIndex,
                        seekTo: startTime,
                        libraryQueueSource: .librarySelection(selectionIdentity),
                        startPolicy: .forceSequentialTemporary
                    )
                    return
                }
                playbackCoordinator.playTrack(
                    track,
                    inQueueFrom: queueTracks,
                    seekTo: startTime,
                    libraryQueueSource: .librarySelection(selectionIdentity)
                )
            },
            onRowAppear: {
                pageController.prefetchAroundTrackID(row.id)
            },
            onRevealHighlightFinished: {
                pageController.clearRevealHighlight(for: row.id)
            },
            rowPrimaryColor: rowPrimaryColor,
            rowSecondaryColor: rowSecondaryColor,
            rowTertiaryColor: rowTertiaryColor,
            artworkTintMode: settings.artworkTintMode
        ) {
            menuBuilder(row.id)
        }
        .equatable()
        .libraryTrackDrag(
            isEnabled: !pageController.isMultiselectMode,
            title: row.trackRowModel.title,
            onSessionChanged: { pageController.setNativeTrackDragActive($0) },
            onSinkDropCompleted: {
                guard libraryVM.currentSelection == selection,
                      pageController.toolbarSelectionIdentity == selectionIdentity else { return }
                pageController.clearMultiselectState()
            },
            previewContent: AnyView(floatingTrackCard(row)),
            previewHeight: rowHeight(for: row)
        ) {
            LibraryTrackDragPayload(
                sessionID: libraryVM.trackDragSessionID,
                sourceSelectionIdentity: selectionIdentity,
                trackIDs: LibraryTrackDragPayload.draggedIDs(
                    startingAt: row.id,
                    selectedIDs: pageController.selectedTrackIDs,
                    orderedIDs: rows.map(\.id)
                )
            )
        }
        // NSHostingView does not inherit SwiftUI environment values from the
        // view that created its rootView. Keep the hosted AppKit table cells
        // in the same presentation and service environment as native rows.
        .environment(playbackCoordinator)
        .environment(libraryVM)
        .environment(settings)
        .environment(cacheServices)
        .environmentObject(themeStore)
        .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .environment(\.colorScheme, colorScheme)
        .environment(\.motionTokens, motionTokens)
        .environment(\.motionPolicy, motionPolicy)
    }

    private func floatingTrackCard(_ row: PlaylistPageRowModel) -> some View {
        TrackRowView(
            model: row.trackRowModel,
            isPlaying: currentTrackID == row.id,
            isSelected: true,
            enableSecondaryInteractions: false,
            enableArtworkLoading: pageController.areRowArtworkLoadsEnabled,
            onTap: { _ in },
            rowPrimaryColor: rowPrimaryColor,
            rowSecondaryColor: rowSecondaryColor,
            rowTertiaryColor: rowTertiaryColor,
            artworkTintMode: settings.artworkTintMode
        ) {
            EmptyView()
        }
        .equatable()
        .environment(cacheServices)
        .environmentObject(themeStore)
        .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .environment(\.colorScheme, colorScheme)
        .environment(\.motionTokens, motionTokens)
        .environment(\.motionPolicy, motionPolicy)
    }

    private func rowHeight(for row: PlaylistPageRowModel) -> CGFloat {
        let snippet = row.lyricSnippetLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return snippet.isEmpty
            ? Constants.Layout.TrackRow.height
            : Constants.Layout.TrackRow.lyricSnippetHeight
    }
}

private struct AppKitPlaylistRowsDataRevision: Equatable {
    let selectionIdentity: String
    let searchText: String
    let sourceFingerprint: String
    let rowIDsHash: Int
}

private struct AppKitPlaylistRowsPresentation: Equatable {
    let currentTrackID: UUID?
    let revealHighlightTrackID: UUID?
    let interactionsEnabled: Bool
    let artworkLoadingEnabled: Bool
    let trackDragActive: Bool
    let colorScheme: ColorScheme
    let primaryColor: Color
    let secondaryColor: Color
    let tertiaryColor: Color
    let artworkTintMode: AppSettings.ArtworkTintMode
}

private struct AppKitPlaylistTrackRowsTable<RowContent: View>: NSViewRepresentable {
    let rows: [PlaylistPageRowModel]
    let dataRevision: AppKitPlaylistRowsDataRevision
    let presentation: AppKitPlaylistRowsPresentation
    let rowHeight: (PlaylistPageRowModel) -> CGFloat
    let rowContent: (PlaylistPageRowModel) -> RowContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AppKitPlaylistRowsContainerView {
        let container = AppKitPlaylistRowsContainerView()
        let tableView = container.tableView
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.attach(tableView: tableView)
        return container
    }

    func updateNSView(_ nsView: AppKitPlaylistRowsContainerView, context: Context) {
        context.coordinator.update(
            rows: rows,
            dataRevision: dataRevision,
            presentation: presentation,
            rowHeight: rowHeight,
            rowContent: rowContent
        )
    }

    static func dismantleNSView(_ nsView: AppKitPlaylistRowsContainerView, coordinator: Coordinator) {
        nsView.tableView.delegate = nil
        nsView.tableView.dataSource = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var tableView: NSTableView?
        private var rows: [PlaylistPageRowModel] = []
        private var rowHeight: ((PlaylistPageRowModel) -> CGFloat)?
        private var rowContent: ((PlaylistPageRowModel) -> RowContent)?
        private var dataRevision: AppKitPlaylistRowsDataRevision?
        private var presentation: AppKitPlaylistRowsPresentation?

        private let cellIdentifier = NSUserInterfaceItemIdentifier("PlaylistTrackHostingCell")
        private let cells = NSHashTable<AppKitPlaylistTrackCellView<RowContent>>.weakObjects()

        func attach(tableView: NSTableView) {
            self.tableView = tableView
        }

        func detach() {
            // Include cells already held by AppKit's reuse queue.
            for cell in cells.allObjects { cell.releaseHostedContent() }
            cells.removeAllObjects()
            tableView = nil
            rows = []
            rowHeight = nil
            rowContent = nil
            dataRevision = nil
            presentation = nil
        }

        func update(
            rows: [PlaylistPageRowModel],
            dataRevision: AppKitPlaylistRowsDataRevision,
            presentation: AppKitPlaylistRowsPresentation,
            rowHeight: @escaping (PlaylistPageRowModel) -> CGFloat,
            rowContent: @escaping (PlaylistPageRowModel) -> RowContent
        ) {
            // Reloading a hosting cell destroys its active SwiftUI gesture.
            // Apply playback/library presentation changes after mouse-up and
            // the drop animation, using the latest inputs from SwiftUI.
            if presentation.trackDragActive, self.dataRevision != nil { return }
            let dataChanged = self.dataRevision != dataRevision
            let presentationChanged = self.presentation != presentation

            self.rows = rows
            self.rowHeight = rowHeight
            self.rowContent = rowContent
            self.dataRevision = dataRevision
            self.presentation = presentation

            guard let tableView else { return }
            if dataChanged {
                tableView.reloadData()
            } else if presentationChanged {
                reloadVisibleRows(in: tableView)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row), let rowHeight else { return Constants.Layout.TrackRow.height }
            return rowHeight(rows[row])
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let rowContent else { return nil }
            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? AppKitPlaylistTrackCellView<RowContent>)
                ?? AppKitPlaylistTrackCellView<RowContent>(identifier: cellIdentifier)
            cells.add(cell)
            cell.setRootView(PlaylistTrackCellContent(trackID: rows[row].id, content: rowContent(rows[row])))
            return cell
        }

        func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
            // NSTableView may retain the cell in its reuse queue. Keep the shell,
            // but release its SwiftUI graph and captured page state offscreen.
            (rowView.view(atColumn: 0) as? AppKitPlaylistTrackCellView<RowContent>)?.releaseHostedContent()
        }

        func selectionShouldChange(in tableView: NSTableView) -> Bool {
            false
        }

        private func reloadVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
            let rowIndexes = IndexSet(integersIn: visibleRows.location..<NSMaxRange(visibleRows))
            let columnIndexes = IndexSet(integersIn: 0..<tableView.numberOfColumns)
            guard !columnIndexes.isEmpty else { return }
            tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        }
    }
}

@MainActor
private final class AppKitPlaylistRowsContainerView: NSView {
    let tableView = NSTableView(frame: .zero)
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PlaylistTrackColumn"))

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        tableView.style = .plain
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = Constants.Layout.TrackRow.height
        tableView.focusRingType = .none
        tableView.autoresizingMask = [.width, .height]
        addSubview(tableView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        tableView.frame = bounds
        column.width = bounds.width
    }
}

private struct PlaylistTrackCellContent<Content: View>: View {
    let trackID: UUID
    let content: Content

    var body: some View { content.id(trackID) }
}

@MainActor
private final class AppKitPlaylistTrackCellView<Content: View>: NSTableCellView {
    private var hostingView: NSHostingView<PlaylistTrackCellContent<Content>>?
    private var hostingConstraints: [NSLayoutConstraint] = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setRootView(_ rootView: PlaylistTrackCellContent<Content>) {
        if let hostingView {
            hostingView.rootView = rootView
            return
        }

        let hostingView = NSHostingView(rootView: rootView)
        // NSTableView and the cell constraints own this row's dimensions.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        hostingConstraints = [
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(hostingConstraints)
        self.hostingView = hostingView
    }

    func releaseHostedContent() {
        guard let hostingView else { return }
        if let responder = window?.firstResponder as? NSView,
           responder === hostingView || responder.isDescendant(of: hostingView) {
            window?.makeFirstResponder(nil)
        }
        NSLayoutConstraint.deactivate(hostingConstraints)
        hostingConstraints.removeAll()
        hostingView.removeFromSuperview()
        self.hostingView = nil
    }
}

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
    @Environment(LibraryCacheServices.self) private var cacheServices
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
            isSearchFiltering: pageController.isSearchFilteringTracks,
            coordinateSpaceName: "playlistTrackReorderSpace",
            rowCornerRadius: Constants.Layout.TrackRow.cornerRadius,
            bottomSpacerHeight: 160,
            badgeText: { "\($0)" },
            rowHeight: rowHeight(for:),
            onClearSelection: {
                pageController.clearMultiselectState()
            },
            onBeginReorder: {
                pageController.beginManualTrackReorderInteraction()
            },
            onEndReorder: {
                pageController.endManualTrackReorderInteraction()
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
            colorScheme: colorScheme,
            primaryColor: rowPrimaryColor,
            secondaryColor: rowSecondaryColor,
            tertiaryColor: rowTertiaryColor
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
                    AnyView(
                        trackRow(row, isSelected: false, selectionContinuity: .isolated)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: rowHeight(for: row), alignment: .leading)
                    )
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
            rowTertiaryColor: rowTertiaryColor
        ) {
            menuBuilder(row.id)
        }
        .equatable()
        // NSHostingView does not inherit SwiftUI environment values from the
        // view that created its rootView. Keep the hosted AppKit table cells
        // in the same presentation and service environment as native rows.
        .environment(playbackCoordinator)
        .environment(cacheServices)
        .environmentObject(themeStore)
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
            rowTertiaryColor: rowTertiaryColor
        ) {
            EmptyView()
        }
        .equatable()
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
    let colorScheme: ColorScheme
    let primaryColor: Color
    let secondaryColor: Color
    let tertiaryColor: Color
}

private struct AppKitPlaylistTrackRowsTable: NSViewRepresentable {
    let rows: [PlaylistPageRowModel]
    let dataRevision: AppKitPlaylistRowsDataRevision
    let presentation: AppKitPlaylistRowsPresentation
    let rowHeight: (PlaylistPageRowModel) -> CGFloat
    let rowContent: (PlaylistPageRowModel) -> AnyView

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

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var tableView: NSTableView?
        private var rows: [PlaylistPageRowModel] = []
        private var rowHeight: ((PlaylistPageRowModel) -> CGFloat)?
        private var rowContent: ((PlaylistPageRowModel) -> AnyView)?
        private var dataRevision: AppKitPlaylistRowsDataRevision?
        private var presentation: AppKitPlaylistRowsPresentation?

        private let cellIdentifier = NSUserInterfaceItemIdentifier("PlaylistTrackHostingCell")

        func attach(tableView: NSTableView) {
            self.tableView = tableView
        }

        func update(
            rows: [PlaylistPageRowModel],
            dataRevision: AppKitPlaylistRowsDataRevision,
            presentation: AppKitPlaylistRowsPresentation,
            rowHeight: @escaping (PlaylistPageRowModel) -> CGFloat,
            rowContent: @escaping (PlaylistPageRowModel) -> AnyView
        ) {
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
            let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? AppKitPlaylistTrackCellView)
                ?? AppKitPlaylistTrackCellView(identifier: cellIdentifier)
            cell.setRootView(AnyView(rowContent(rows[row]).id(rows[row].id)))
            return cell
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

@MainActor
private final class AppKitPlaylistTrackCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setRootView(_ rootView: AnyView) {
        if let hostingView {
            hostingView.rootView = rootView
            return
        }

        let hostingView = NSHostingView(rootView: rootView)
        // NSTableView and the cell constraints own this row's dimensions.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.hostingView = hostingView
    }
}

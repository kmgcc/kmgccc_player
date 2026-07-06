//
//  PlaylistTrackRowsSection.swift
//  myPlayer2
//
//  Track-specific adapter for the shared multiselect/reorder row shell.
//

import SwiftUI

struct PlaylistTrackRowsSection: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

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
            rowPrimaryColor: rowPrimaryColor,
            rowSecondaryColor: rowSecondaryColor,
            rowTertiaryColor: rowTertiaryColor
        ) {
            menuBuilder(row.id)
        }
        .equatable()
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

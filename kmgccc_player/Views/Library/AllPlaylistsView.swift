//
//  AllPlaylistsView.swift
//  myPlayer2
//
//  Full Playlists page reached from Home -> Playlists -> "查看全部".
//

import AppKit
import SwiftUI

private struct PlaylistDeletionRequest: Identifiable {
    let playlist: Playlist
    var id: UUID { playlist.id }
}

struct AllPlaylistsView: View {
    let pageController: PlaylistPageController

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var deletionRequest: PlaylistDeletionRequest?

    var body: some View {
        let palette = themeStore.appForegroundPalette
        let primary = palette.primaryColor
        let secondary = palette.secondaryColor
        let tertiary = palette.tertiaryColor
        let playlists = filteredPlaylists
        let visibleIDs = playlists.map(\.id)
        let customSourceIDs = customOrderSourcePlaylists.map(\.id)

        return list(
            playlists,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            let token = FirstUseHitchDiagnostics.begin(
                "AllPlaylistsView.onAppear",
                detail: "playlists=\(libraryVM.playlists.count)"
            )
            FirstUseHitchDiagnostics.end(token)
            pageController.bindCollectionList(libraryVM: libraryVM, uiState: uiState)
            registerCollectionList(
                visibleIDs: visibleIDs,
                customSourceIDs: customSourceIDs,
                isFiltering: isFiltering
            )
        }
        .onChange(of: visibleIDs) { _, newIDs in
            registerCollectionList(
                visibleIDs: newIDs,
                customSourceIDs: customSourceIDs,
                isFiltering: isFiltering
            )
        }
        .onChange(of: customSourceIDs) { _, newIDs in
            registerCollectionList(
                visibleIDs: visibleIDs,
                customSourceIDs: newIDs,
                isFiltering: isFiltering
            )
        }
        .onChange(of: isFiltering) { _, newValue in
            registerCollectionList(
                visibleIDs: visibleIDs,
                customSourceIDs: customSourceIDs,
                isFiltering: newValue
            )
        }
        .onDisappear {
            pageController.unregisterCollectionList(selection: .allPlaylists)
        }
        .alert(
            NSLocalizedString("edit.playlist.delete_confirm_title", comment: ""),
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button(
                NSLocalizedString("edit.playlist.delete_confirm", comment: ""),
                role: .destructive
            ) {
                let playlist = request.playlist
                deletionRequest = nil
                Task { await libraryVM.deletePlaylist(playlist) }
            }
            Button(
                NSLocalizedString("edit.track.cancel", comment: ""),
                role: .cancel
            ) { deletionRequest = nil }
        } message: { _ in
            Text(NSLocalizedString("edit.playlist.delete_desc", comment: ""))
        }
    }

    private func list(
        _ playlists: [Playlist],
        primary: Color,
        secondary: Color,
        tertiary: Color
    ) -> some View {
        ScrollView(.vertical) {
            ReorderableMultiselectRowsSection(
                rows: playlists,
                isMultiselectMode: pageController.isMultiselectMode,
                selectedIDs: pageController.selectedTrackIDs,
                canReorder: pageController.canManuallyReorderCurrentCollection,
                isSearchFiltering: isFiltering,
                coordinateSpaceName: "playlistCollectionReorderSpace",
                rowCornerRadius: 12,
                bottomSpacerHeight: 120,
                badgeText: { "\($0)" },
                rowHeight: { _ in 76 },
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
                    pageController.commitManualCollectionOrder(
                        orderedItemIDs: orderedIDs,
                        reason: "manual-playlist-reorder"
                    )
                },
                rowContent: { playlist, _, _ in
                    PlaylistListRow(
                        playlist: playlist,
                        titleColor: primary,
                        subtitleColor: secondary,
                        metaColor: tertiary,
                        onOpen: { handleRowTap(playlist) },
                        onPlay: { play(playlist) },
                        onDelete: { deletionRequest = PlaylistDeletionRequest(playlist: playlist) }
                    )
                },
                floatingContent: { playlist in
                    PlaylistListRow(
                        playlist: playlist,
                        titleColor: primary,
                        subtitleColor: secondary,
                        metaColor: tertiary,
                        enableSecondaryInteractions: false,
                        onOpen: {},
                        onPlay: {},
                        onDelete: {}
                    )
                }
            )
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
    }

    private var filteredPlaylists: [Playlist] {
        let trimmed = normalizedSearchText
        let base: [Playlist]
        if trimmed.isEmpty {
            base = libraryVM.playlists
        } else {
            base = libraryVM.playlists.filter {
                $0.name.lowercased().contains(trimmed)
                    || $0.userDescription.lowercased().contains(trimmed)
            }
        }
        return libraryVM.sortedPlaylistsForDisplay(base)
    }

    private var customOrderSourcePlaylists: [Playlist] {
        libraryVM.sortedPlaylistsForDisplay(libraryVM.playlists)
    }

    private var normalizedSearchText: String {
        pageController.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var isFiltering: Bool {
        !normalizedSearchText.isEmpty
    }

    private func registerCollectionList(
        visibleIDs: [UUID],
        customSourceIDs: [UUID],
        isFiltering: Bool
    ) {
        pageController.registerCollectionList(
            selection: .allPlaylists,
            visibleItemIDs: visibleIDs,
            customOrderSourceItemIDs: customSourceIDs,
            isFiltering: isFiltering
        )
    }

    private func handleRowTap(_ playlist: Playlist) {
        if pageController.isMultiselectMode {
            pageController.handleMultiselectItemTap(
                itemID: playlist.id,
                extendingRange: LibraryRowInput.isShiftPressed
            )
        } else {
            open(playlist)
        }
    }

    private func open(_ playlist: Playlist) {
        uiState.pushSelectionInHomeContext(
            .playlist(playlist.id),
            libraryVM: libraryVM
        )
    }

    private func play(_ playlist: Playlist) {
        playbackCoordinator.playRandomTracks(
            playlist.tracks,
            libraryQueueSource: .librarySelection("all-playlists-\(playlist.id.uuidString)")
        )
    }
}

private struct PlaylistListRow: View {
    let playlist: Playlist
    var titleColor: Color = .primary
    var subtitleColor: Color = .secondary
    var metaColor: Color = Color.secondary.opacity(0.7)
    var enableSecondaryInteractions = true
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var isHovering = false

    private let artworkSize: CGFloat = 60
    private let cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 14) {
            artworkView
            textBlock
            Spacer(minLength: 8)
            trailingActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering
                      ? Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard enableSecondaryInteractions else { return }
            onOpen()
        }
        .onHover { isHovering = enableSecondaryInteractions && $0 }
        .contextMenu {
            if enableSecondaryInteractions {
                Button(action: onOpen) {
                    Label("打开播放列表", systemImage: "music.note.list")
                }
                Button(action: onPlay) {
                    Label("播放该播放列表", systemImage: "play.fill")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label(NSLocalizedString("edit.playlist.delete", comment: ""), systemImage: "trash")
                }
            }
        }
        .task(id: artworkIdentity) {
            await loadArtwork()
        }
    }

    private var artworkView: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkPlaceholderView(
                    size: artworkSize,
                    cornerRadius: cornerRadius,
                    clipShape: .continuous,
                    iconSize: 22,
                    iconOpacity: 0.4
                )
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1),
            radius: 4, y: 2
        )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
            if !playlist.userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(playlist.userDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(playlist.trackCount) 首歌曲")
                if playlist.totalDuration > 0 {
                    Text("·")
                    Text(formattedDuration(playlist.totalDuration))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(metaColor)
            .lineLimit(1)
        }
    }

    private var trailingActions: some View {
        Menu {
            Button(action: onOpen) {
                Label("打开播放列表", systemImage: "music.note.list")
            }
            Button(action: onPlay) {
                Label("播放该播放列表", systemImage: "play.fill")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(NSLocalizedString("edit.playlist.delete", comment: ""), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(subtitleColor)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .opacity(isHovering ? 1 : 0.4)
        .disabled(!enableSecondaryInteractions)
        .allowsHitTesting(enableSecondaryInteractions)
    }

    private var artworkIdentity: String {
        let selectionIdentity = "playlist-\(playlist.id.uuidString)"
        if let revision = LocalLibraryService.shared.playlistArtworkRevision(playlistID: playlist.id),
           !revision.isEmpty
        {
            return "\(selectionIdentity)-artwork-\(revision)"
        }
        let signature = PlaylistArtworkGenerator.contentSignature(tracks: playlist.tracks)
        return "\(selectionIdentity)-unresolved-\(signature)"
    }

    private func loadArtwork() async {
        let request = DetailHeaderArtworkRequest.playlist(
            selectionIdentity: "playlist-\(playlist.id.uuidString)",
            playlistID: playlist.id,
            tracks: playlist.tracks
        )
        let immediate = DetailHeaderArtworkResolver.shared.resolveImmediately(for: request)
        if let image = await loadHeaderImage(from: immediate) {
            self.image = image
        }

        let resolved = await DetailHeaderArtworkResolver.shared.resolveDeferredArtwork(for: request)
        if let image = await loadHeaderImage(from: resolved ?? immediate) {
            self.image = image
        }
    }

    private func loadHeaderImage(from resolved: ResolvedHeaderArtwork?) async -> NSImage? {
        guard let resolved else { return nil }
        let request = PlaylistArtworkPipeline.headerRequest(
            artworkIdentity: artworkIdentity,
            artworkData: resolved.image?.tiffRepresentation,
            fileURL: resolved.fileURL
        )
        return await PlaylistArtworkPipeline.shared.load(request) ?? resolved.image
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }
}

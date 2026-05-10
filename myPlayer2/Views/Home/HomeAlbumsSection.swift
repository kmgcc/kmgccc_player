//
//  HomeAlbumsSection.swift
//  myPlayer2
//
//  Horizontal scrolling album cards for the Home page.
//
//  The section title aligns inside the center column (matching Hero /
//  Playlists / Insights), while the carousel viewport itself spans the
//  full window width — first card aligned with the center column's
//  left edge, items free to scroll past sidebar / right inspector glass.
//  Hits and scroll wheel events route normally because Home now lives
//  in a real full-window layer; there is no mirrored side-strip copy.
//

import AppKit
import SwiftUI

struct HomeAlbumsSection: View {
    let albums: [AlbumEntry]
    var mode: HomeLayoutMode = .wide
    /// Distance from the window's left edge to where the first card should
    /// sit (sidebar width + horizontal padding inside the center column).
    let centerLeftPad: CGFloat
    /// Distance from the right window edge inwards (right lyrics inspector
    /// width + horizontal padding inside the center column).
    let centerRightPad: CGFloat

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @State private var deletionRequest: HomeAlbumDeletionRequest?
    @State private var editingAlbum: AlbumEntry?

    private let cardCornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)
            carousel
        }
        .alert(
            NSLocalizedString("sidebar.delete_album_confirm_title", comment: ""),
            isPresented: Binding(
                get: { deletionRequest != nil },
                set: { if !$0 { deletionRequest = nil } }
            ),
            presenting: deletionRequest
        ) { request in
            Button(
                NSLocalizedString("sidebar.delete_album", comment: ""),
                role: .destructive
            ) {
                let entry = request.entry
                deletionRequest = nil
                Task { await libraryVM.deleteAlbum(entry) }
            }
            Button(
                NSLocalizedString("edit.track.cancel", comment: ""),
                role: .cancel
            ) { deletionRequest = nil }
        } message: { request in
            Text(
                String(
                    format: NSLocalizedString("sidebar.delete_album_confirm_message", comment: ""),
                    request.entry.displayTitle,
                    request.trackCount
                )
            )
        }
        .sheet(item: $editingAlbum) { entry in
            AlbumInfoEditSheet(entry: entry) {}
                .presentationSizing(.page)
        }
    }

    @ViewBuilder
    private var carousel: some View {
        HorizontalFadeScrollContainer(
            spacing: rowSpacing,
            fadeWidth: 0,
            verticalPadding: 22,
            // First card's leading edge starts at the center column's
            // visual left edge (sidebar width + center horizontal padding).
            leadingScrollPadding: centerLeftPad + 4,
            trailingScrollPadding: max(4, centerRightPad - 8),
            showsEdgeFade: false,
            showsScrollButtons: true,
            scrollButtonLeadingInset: centerLeftPad + 8,
            scrollButtonTrailingInset: max(12, centerRightPad + 8)
        ) {
            ForEach(albums) { album in
                HomeAlbumCard(
                    album: album,
                    mode: mode,
                    onOpen: { open(album) },
                    onPlay: { play(album) },
                    onEdit: { editingAlbum = album },
                    onDelete: { requestDelete(album) }
                )
            }
        }
    }

    private var cardSize: CGFloat {
        switch mode {
        case .wide:    return 164
        case .medium:  return 146
        case .compact: return 124
        case .narrow:  return 110
        }
    }

    private var rowSpacing: CGFloat {
        switch mode {
        case .wide:    return 18
        case .medium:  return 14
        case .compact: return 12
        case .narrow:  return 10
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("专辑")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
            Spacer()
            viewAllButton
        }
    }

    private var viewAllButton: some View {
        Button {
            uiState.pushSelectionInHomeContext(
                .allAlbums,
                libraryVM: libraryVM
            )
        } label: {
            HStack(spacing: 2) {
                Text("查看全部")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func open(_ album: AlbumEntry) {
        libraryVM.selectedAlbumName = album.displayTitle
        uiState.navigateFromHome(
            to: .album(album.canonicalKey),
            libraryVM: libraryVM
        )
    }

    private func play(_ album: AlbumEntry) {
        let tracks = libraryVM.allTracks.filter { $0.albumGroupKey == album.canonicalKey }
        playbackCoordinator.playTracks(
            tracks,
            startingAt: 0,
            libraryQueueSource: .librarySelection("home-album-\(album.canonicalKey)"),
            playbackOrderMode: .sequence
        )
    }

    private func requestDelete(_ album: AlbumEntry) {
        deletionRequest = HomeAlbumDeletionRequest(
            entry: album,
            trackCount: album.trackCount
        )
    }
}

private struct HomeAlbumDeletionRequest: Identifiable {
    let entry: AlbumEntry
    let trackCount: Int
    var id: UUID { entry.id }
}

// MARK: - Album card

private struct HomeAlbumCard: View {
    let album: AlbumEntry
    let mode: HomeLayoutMode
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(LibraryViewModel.self) private var libraryVM
    @State private var image: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    // Outer card geometry. Cover radius is derived so the cover and card
    // form concentric rounded rectangles: innerR = outerR − inset.
    private let outerCornerRadius: CGFloat = 18
    private let cardInset: CGFloat = 10
    private var coverCornerRadius: CGFloat {
        max(0, outerCornerRadius - cardInset)
    }

    private var cardSize: CGFloat {
        switch mode {
        case .wide:    return 164
        case .medium:  return 146
        case .compact: return 124
        case .narrow:  return 110
        }
    }

    private var titleFontSize: CGFloat {
        switch mode {
        case .wide, .medium: return 14
        case .compact:       return 13
        case .narrow:        return 12
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: mode == .narrow ? 8 : 10) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ArtworkPlaceholderView(
                        size: cardSize,
                        cornerRadius: coverCornerRadius,
                        clipShape: .continuous,
                        iconSize: 32,
                        iconOpacity: 0.4
                    )
                }
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayTitle)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(album.primaryArtistDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(cardInset)
        .frame(width: cardSize + cardInset * 2)
        .homeUnifiedGlassCard(
            cornerRadius: outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: true
        )
        .overlay(
            // Cheap hover indicator (see HomeArtistCircle for rationale).
            RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(isHovering ? 0.18 : 0),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onPlay) {
                Label("播放该专辑", systemImage: "play.fill")
            }

            Button(action: onOpen) {
                Label("打开专辑", systemImage: "square.stack")
            }
            Button(action: onEdit) {
                Label("编辑专辑", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("删除专辑", systemImage: "trash")
            }
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        var artworkData = album.artworkData
        if artworkData == nil || artworkData!.isEmpty {
            let albumKey = album.canonicalKey
            if let firstTrack = libraryVM.allTracks.first(where: { $0.albumGroupKey == albumKey }) {
                artworkData = await firstTrack.loadArtworkDataOffMainIfNeeded()
            }
        }
        guard let data = artworkData, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: album.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 336, height: 336)
        )
        let loaded = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 336, height: 336)
        )
        image = loaded
    }
}

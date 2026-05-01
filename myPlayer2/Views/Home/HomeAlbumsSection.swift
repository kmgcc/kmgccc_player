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

    private let cardCornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
                .padding(.leading, centerLeftPad)
                .padding(.trailing, centerRightPad)
            carousel
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
            showsEdgeFade: false
        ) {
            ForEach(albums) { album in
                HomeAlbumCard(album: album, mode: mode)
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
}

// MARK: - Album card

private struct HomeAlbumCard: View {
    let album: AlbumEntry
    let mode: HomeLayoutMode

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
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

                Text("\(album.trackCount) 首歌曲")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(cardInset)
        .frame(width: cardSize + cardInset * 2)
        .homeUnifiedGlassCard(
            cornerRadius: outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: true
        )
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            libraryVM.selectedAlbumName = album.displayTitle
            uiState.navigateFromHome(
                to: .album(album.canonicalKey),
                libraryVM: libraryVM
            )
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
                artworkData = await Task.detached { firstTrack.loadArtworkDataIfNeeded() }.value
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

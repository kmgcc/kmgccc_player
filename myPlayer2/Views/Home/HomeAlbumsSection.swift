//
//  HomeAlbumsSection.swift
//  myPlayer2
//
//  Horizontal scrolling album cards for the Home page.
//
//  Renders an interactive horizontal carousel inside the center content pane.
//  The carousel is bounded by the pane (it does NOT extend behind the Sidebar
//  or right Inspector) — that earlier full-window overlay approach was
//  reverted because it covered Sidebar / Inspector / Mini Player and broke
//  vertical scrolling. A subtle edge fade is provided by
//  `HorizontalFadeScrollContainer` so the row's edges blend with the page
//  background when more cards exist beyond the viewport.
//

import AppKit
import SwiftUI

struct HomeAlbumsSection: View {
    let albums: [AlbumEntry]
    var mode: HomeLayoutMode = .wide

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    private let underlayState = HomeCarouselUnderlayState.shared
    private let cardCornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            carousel
        }
        .onAppear {
            pushSnapshot()
            underlayState.setAlbumsActive(true)
        }
        .onDisappear {
            underlayState.setAlbumsActive(false)
        }
        .onChange(of: snapshotItems) { _, _ in
            pushSnapshot()
        }
        .onChange(of: mode) { _, _ in
            pushSnapshot()
        }
    }

    @ViewBuilder
    private var carousel: some View {
        let hPad = mode.horizontalPadding
        HorizontalFadeScrollContainer(
            spacing: rowSpacing,
            fadeWidth: 0,
            verticalPadding: 12,
            leadingScrollPadding: hPad + 4,
            trailingScrollPadding: 4,
            showsEdgeFade: false,
            onHorizontalScrollOffsetChange: { offset in
                underlayState.updateAlbumsHorizontalOffset(offset)
            }
        ) {
            ForEach(albums) { album in
                HomeAlbumCard(album: album, mode: mode)
            }
        }
        // Negate the parent VStack's horizontal padding so the row's
        // viewport reaches the center pane's left and right edges. The
        // section title above keeps the parent padding (so it stays aligned
        // with Hero / Playlists / Insights), only the carousel extends.
        .padding(.horizontal, -hPad)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newFrame in
            underlayState.updateAlbumsRowOrigin(
                minX: newFrame.minX,
                minY: newFrame.minY
            )
            // The carousel's horizontal extent IS the center mask. Beyond
            // its left/right edges (under sidebar / inspector glass) the
            // underlay continues drawing.
            HomeCarouselUnderlayState.shared.setCenterRange(
                minX: newFrame.minX,
                maxX: newFrame.maxX
            )
        }
    }

    // MARK: - Snapshot push

    private var snapshotItems: [HomeCarouselUnderlayState.Item] {
        albums.map { album in
            HomeCarouselUnderlayState.Item.album(id: album.id, artwork: album.artworkData)
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

    private func pushSnapshot() {
        var snapshot = HomeCarouselUnderlayState.RowSnapshot.empty
        snapshot.isActive = true
        snapshot.items = snapshotItems
        snapshot.rowMinXInWindow = underlayState.albums.rowMinXInWindow
        snapshot.rowMinYInWindow = underlayState.albums.rowMinYInWindow
        snapshot.rowHeight = cardSize + 24
        snapshot.cardWidth = cardSize
        snapshot.cardHeight = cardSize
        snapshot.spacing = rowSpacing
        // Mirror the real carousel's leading padding so the underlay's
        // first card is co-located with the real first card at offset 0.
        snapshot.leadingScrollPadding = mode.horizontalPadding + 4
        snapshot.verticalPadding = 12
        snapshot.horizontalScrollOffset = underlayState.albums.horizontalScrollOffset
        snapshot.clipShape = .roundedRect(radius: cardCornerRadius)
        underlayState.updateAlbums(snapshot)
    }

    private var rowSpacing: CGFloat {
        switch mode {
        case .wide:    return 18
        case .medium:  return 14
        case .compact: return 12
        case .narrow:  return 10
        }
    }

    private var fadeWidth: CGFloat {
        switch mode {
        case .wide:    return 22
        case .medium:  return 18
        case .compact: return 16
        case .narrow:  return 14
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

    private let radius: CGFloat = 16

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
                        cornerRadius: radius,
                        clipShape: .continuous,
                        iconSize: 32,
                        iconOpacity: 0.4
                    )
                }
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12),
                radius: isHovering ? 12 : 8, y: isHovering ? 6 : 4
            )

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
        .frame(width: cardSize)
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
        // Mirror the same NSImage into the underlay's shared cache so the
        // off-screen continuation under sidebar / inspector glass renders
        // the SAME pixels as the real card. Without this, most underlay
        // cards would fall back to a placeholder (because `album.artworkData`
        // is frequently empty, with the real cover living on a track) and
        // the user would see "blurry gray blobs" through the glass.
        if let loaded {
            HomeCarouselUnderlayState.shared.setLoadedImage(loaded, for: album.id)
        }
    }
}

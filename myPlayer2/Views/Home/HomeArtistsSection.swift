//
//  HomeArtistsSection.swift
//  myPlayer2
//
//  Horizontal scrolling artist circles for the Home page.
//
//  Renders an interactive horizontal carousel inside the center content pane,
//  bounded by the pane (no full-window overlay). Edge fades come from
//  `HorizontalFadeScrollContainer` and only appear when the row actually
//  overflows.
//

import AppKit
import SwiftUI

struct HomeArtistsSection: View {
    let artists: [ArtistEntry]
    var mode: HomeLayoutMode = .wide

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    private let underlayState = HomeCarouselUnderlayState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            carousel
        }
        .onAppear {
            pushSnapshot()
            underlayState.setArtistsActive(true)
        }
        .onDisappear {
            underlayState.setArtistsActive(false)
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
                underlayState.updateArtistsHorizontalOffset(offset)
            }
        ) {
            ForEach(artists) { artist in
                HomeArtistCircle(artist: artist, mode: mode)
            }
        }
        // Negate the parent VStack's horizontal padding so the row's
        // viewport reaches the center pane's left and right edges. The
        // section title above keeps the parent padding (so it stays aligned
        // with Hero / Playlists / Insights).
        .padding(.horizontal, -hPad)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newFrame in
            underlayState.updateArtistsRowOrigin(
                minX: newFrame.minX,
                minY: newFrame.minY
            )
            HomeCarouselUnderlayState.shared.setCenterRange(
                minX: newFrame.minX,
                maxX: newFrame.maxX
            )
        }
    }

    // MARK: - Snapshot push

    private var snapshotItems: [HomeCarouselUnderlayState.Item] {
        artists.map { artist in
            HomeCarouselUnderlayState.Item.artist(id: artist.id, artwork: artist.artworkData)
        }
    }

    private var circleSize: CGFloat {
        switch mode {
        case .wide:    return 136
        case .medium:  return 120
        case .compact: return 104
        case .narrow:  return 90
        }
    }

    private func pushSnapshot() {
        var snapshot = HomeCarouselUnderlayState.RowSnapshot.empty
        snapshot.isActive = true
        snapshot.items = snapshotItems
        snapshot.rowMinXInWindow = underlayState.artists.rowMinXInWindow
        snapshot.rowMinYInWindow = underlayState.artists.rowMinYInWindow
        snapshot.rowHeight = circleSize + 24
        snapshot.cardWidth = circleSize
        snapshot.cardHeight = circleSize
        snapshot.spacing = rowSpacing + extraSpacingForCircleContainer
        // Mirror the real carousel's leading padding (hPad + 4) and add the
        // half-container slack so the underlay's first circle is co-located
        // with the real first circle at offset 0.
        snapshot.leadingScrollPadding = mode.horizontalPadding + 4 + halfExtraContainerSlack
        snapshot.verticalPadding = 12
        snapshot.horizontalScrollOffset = underlayState.artists.horizontalScrollOffset
        snapshot.clipShape = .circle
        underlayState.updateArtists(snapshot)
    }

    /// `HomeArtistCircle` wraps each circle in a frame of width
    /// `circleSize + (mode == .narrow ? 10 : 16)`. The underlay places cards
    /// at `circleSize` and steps by `cardWidth + spacing`, so we add the
    /// container's extra horizontal slack to the spacing instead.
    private var extraSpacingForCircleContainer: CGFloat {
        mode == .narrow ? 10 : 16
    }

    private var halfExtraContainerSlack: CGFloat {
        extraSpacingForCircleContainer / 2
    }

    private var rowSpacing: CGFloat {
        switch mode {
        case .wide:    return 16
        case .medium:  return 12
        case .compact: return 10
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
            Text("歌手")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
            Spacer()
            viewAllButton
        }
    }

    private var viewAllButton: some View {
        Button {
            uiState.pushSelectionInHomeContext(
                .allArtists,
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

// MARK: - Artist circle

private struct HomeArtistCircle: View {
    let artist: ArtistEntry
    let mode: HomeLayoutMode

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @State private var image: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var circleSize: CGFloat {
        switch mode {
        case .wide:    return 136
        case .medium:  return 120
        case .compact: return 104
        case .narrow:  return 90
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
        VStack(spacing: mode == .narrow ? 8 : 12) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ArtworkPlaceholderView(
                        size: circleSize,
                        clipShape: .circle,
                        iconSize: 28,
                        iconOpacity: 0.4
                    )
                }
            }
            .frame(width: circleSize, height: circleSize)
            .clipShape(Circle())
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.35 : 0.15),
                radius: isHovering ? 14 : 10, y: isHovering ? 6 : 4
            )

            VStack(spacing: 3) {
                Text(artist.displayName)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .lineLimit(1)

                Text("\(artist.albumCount) 张专辑 \u{00B7} \(artist.trackCount) 首歌曲")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: circleSize + (mode == .narrow ? 10 : 16))
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            uiState.navigateFromHome(
                to: .artist(artist.canonicalName),
                libraryVM: libraryVM
            )
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        if let data = artist.artworkData, !data.isEmpty {
            let checksum = ArtworkLoader.checksum(for: data)
            let key = ArtworkLoader.cacheKey(
                trackID: artist.id,
                checksum: checksum,
                targetPixelSize: CGSize(width: 256, height: 256)
            )
            let loaded = await ArtworkLoader.loadImage(
                artworkData: data,
                cacheKey: key,
                targetPixelSize: CGSize(width: 256, height: 256)
            )
            image = loaded
            if let loaded {
                HomeCarouselUnderlayState.shared.setLoadedImage(loaded, for: artist.id)
            }
            return
        }

        let canonicalName = artist.canonicalName
        let tracks = libraryVM.allTracks.filter {
            LibraryNormalization.normalizeArtist($0.artist) == canonicalName
        }
        let generated = await ArtistArtworkGenerator.shared.generateArtwork(
            artistName: artist.displayName,
            tracks: tracks
        )
        image = generated
        if let generated {
            HomeCarouselUnderlayState.shared.setLoadedImage(generated, for: artist.id)
        }
    }
}

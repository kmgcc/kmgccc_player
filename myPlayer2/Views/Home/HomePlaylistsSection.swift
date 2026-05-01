//
//  HomePlaylistsSection.swift
//  myPlayer2
//
//  Playlist cards for the Home page.
//

import AppKit
import SwiftUI

struct HomePlaylistsSection: View {
    let playlists: [Playlist]
    var mode: HomeLayoutMode = .wide

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    private var columnCount: Int {
        switch mode {
        case .wide:    return 3
        case .medium:  return 2
        case .compact: return 2
        case .narrow:  return 1
        }
    }

    private var gridSpacing: CGFloat {
        switch mode {
        case .wide, .medium: return 14
        case .compact:       return 12
        case .narrow:        return 10
        }
    }

    /// Cluster requires at least two grid columns and three playlists
    /// (one featured + two side). Narrow mode and tiny libraries fall back
    /// to a plain grid of normal cards.
    private var shouldUseCluster: Bool {
        columnCount >= 2 && playlists.count >= 3
    }

    /// `featured` = highest track count. `sideA`, `sideB` = two lowest track
    /// counts excluding the featured one. Ties always resolve to the
    /// playlist that appears first — the user's order is preserved.
    private var selection: ClusterSelection? {
        guard shouldUseCluster, let featuredIdx = highestTrackCountIndex(in: playlists) else {
            return nil
        }

        let featured = playlists[featuredIdx]
        let nonFeaturedIndexed = playlists.enumerated()
            .filter { $0.offset != featuredIdx }
            .map { $0 }

        // Two smallest by trackCount; ties resolved by original index.
        let sortedSmall = nonFeaturedIndexed.sorted { lhs, rhs in
            if lhs.element.trackCount != rhs.element.trackCount {
                return lhs.element.trackCount < rhs.element.trackCount
            }
            return lhs.offset < rhs.offset
        }
        guard sortedSmall.count >= 2 else { return nil }

        let sideA = sortedSmall[0]
        let sideB = sortedSmall[1]
        let sideOriginalIndices: Set<Int> = [sideA.offset, sideB.offset]

        // Remaining preserves original order.
        let remaining = nonFeaturedIndexed
            .filter { !sideOriginalIndices.contains($0.offset) }
            .map { $0.element }

        return ClusterSelection(
            featured: featured,
            sideA: sideA.element,
            sideB: sideB.element,
            remaining: remaining
        )
    }

    private func highestTrackCountIndex(in list: [Playlist]) -> Int? {
        guard !list.isEmpty else { return nil }
        var best = 0
        for index in 1..<list.count where list[index].trackCount > list[best].trackCount {
            best = index
        }
        return best
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            contentBlock
        }
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var contentBlock: some View {
        if let selection {
            // Inner spacing equals gridSpacing so the featured cluster sits
            // exactly one row-gap above the remaining grid — i.e. it reads
            // as the first row group of the same playlist grid, not a
            // separately blocked-off chunk.
            VStack(alignment: .leading, spacing: gridSpacing) {
                clusterRow(
                    featured: selection.featured,
                    sideA: selection.sideA,
                    sideB: selection.sideB
                )
                if !selection.remaining.isEmpty {
                    grid(of: selection.remaining)
                }
            }
        } else {
            // Narrow mode or too few playlists for a cluster: plain grid.
            grid(of: playlists)
        }
    }

    // MARK: - Cluster

    /// Cluster width ratio (1.25 : 0.75 → 0.625 : 0.375 of the cluster width
    /// minus the gap between the two columns).
    private var clusterFeaturedRatio: CGFloat { 1.25 / 2.0 }   // = 0.625
    private var clusterSideRatio: CGFloat { 0.75 / 2.0 }       // = 0.375

    @ViewBuilder
    private func clusterRow(
        featured: Playlist,
        sideA: Playlist,
        sideB: Playlist
    ) -> some View {
        let normalH = HomePlaylistCard.normalHeight(for: mode)
        // Featured taller than normal; the two stacked side cards plus the
        // spacing between them equal the featured height exactly.
        let featuredH = normalH * 1.65
        let smallH = (featuredH - gridSpacing) / 2

        // Cluster as a fixed-width HStack: featured (wider) + stacked side
        // cards (narrower). Inter-column spacing equals the normal grid
        // spacing so the cluster reads as part of the same playlist grid.
        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width - gridSpacing)
            let featuredW = floor(availableWidth * clusterFeaturedRatio)
            let sideW = availableWidth - featuredW

            HStack(alignment: .top, spacing: gridSpacing) {
                HomePlaylistCard(
                    playlist: featured,
                    mode: mode,
                    kind: .featured(height: featuredH)
                )
                .frame(width: featuredW)
                .onTapGesture { navigate(to: featured) }

                VStack(spacing: gridSpacing) {
                    HomePlaylistCard(
                        playlist: sideA,
                        mode: mode,
                        kind: .compact(height: smallH)
                    )
                    .onTapGesture { navigate(to: sideA) }
                    HomePlaylistCard(
                        playlist: sideB,
                        mode: mode,
                        kind: .compact(height: smallH)
                    )
                    .onTapGesture { navigate(to: sideB) }
                }
                .frame(width: sideW, height: featuredH)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: featuredH)
    }

    // MARK: - Remaining grid
    //
    // Two-column staggered layout: left column slightly narrower, right
    // column slightly wider — for visual rhythm, not masonry. Row heights
    // stay constant. Narrow mode falls back to a single equal-width column.

    private var staggeredLeftRatio: CGFloat { 0.84 / 2.0 }   // = 0.42
    private var staggeredRightRatio: CGFloat { 1.16 / 2.0 }  // = 0.58

    @ViewBuilder
    private func grid(of items: [Playlist]) -> some View {
        if columnCount >= 2 {
            staggeredGrid(of: items)
        } else {
            plainSingleColumnGrid(of: items)
        }
    }

    @ViewBuilder
    private func plainSingleColumnGrid(of items: [Playlist]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: gridSpacing, alignment: .top)],
            alignment: .leading,
            spacing: gridSpacing
        ) {
            ForEach(items) { playlist in
                HomePlaylistCard(playlist: playlist, mode: mode, kind: .normal)
                    .onTapGesture { navigate(to: playlist) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func staggeredGrid(of items: [Playlist]) -> some View {
        let normalH = HomePlaylistCard.normalHeight(for: mode)
        let rowCount = (items.count + 1) / 2
        let totalHeight =
            CGFloat(rowCount) * normalH
            + CGFloat(max(0, rowCount - 1)) * gridSpacing

        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width - gridSpacing)
            let leftWidth = floor(availableWidth * staggeredLeftRatio)
            let rightWidth = availableWidth - leftWidth

            VStack(alignment: .leading, spacing: gridSpacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    staggeredRow(
                        items: items,
                        rowIndex: row,
                        leftWidth: leftWidth,
                        rightWidth: rightWidth
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: totalHeight)
    }

    @ViewBuilder
    private func staggeredRow(
        items: [Playlist],
        rowIndex: Int,
        leftWidth: CGFloat,
        rightWidth: CGFloat
    ) -> some View {
        let leftIndex = rowIndex * 2
        let rightIndex = leftIndex + 1

        HStack(alignment: .top, spacing: gridSpacing) {
            HomePlaylistCard(playlist: items[leftIndex], mode: mode, kind: .normal)
                .frame(width: leftWidth)
                .onTapGesture { navigate(to: items[leftIndex]) }

            if rightIndex < items.count {
                HomePlaylistCard(playlist: items[rightIndex], mode: mode, kind: .normal)
                    .frame(width: rightWidth)
                    .onTapGesture { navigate(to: items[rightIndex]) }
            } else {
                // Single trailing item on the last row keeps the wide-side
                // slot empty rather than stretching the lone card across.
                Color.clear.frame(width: rightWidth)
            }
        }
    }

    private func navigate(to playlist: Playlist) {
        uiState.navigateFromHome(
            to: .playlist(playlist.id),
            libraryVM: libraryVM
        )
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("播放列表")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
            Spacer()
        }
    }
}

private struct ClusterSelection {
    let featured: Playlist
    let sideA: Playlist
    let sideB: Playlist
    let remaining: [Playlist]
}

// MARK: - Card

private enum HomePlaylistCardKind {
    case normal
    case featured(height: CGFloat)
    case compact(height: CGFloat)
}

private struct HomePlaylistCard: View {
    let playlist: Playlist
    let mode: HomeLayoutMode
    let kind: HomePlaylistCardKind

    @State private var coverImage: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    fileprivate static let cardInset: CGFloat = 12
    fileprivate static let outerCornerRadius: CGFloat = 18
    private var coverCornerRadius: CGFloat {
        // Concentric rounded rectangles: innerR = outerR − inset.
        max(0, Self.outerCornerRadius - Self.cardInset)
    }

    static func baseCoverSize(for mode: HomeLayoutMode) -> CGFloat {
        switch mode {
        case .wide:    return 68
        case .medium:  return 60
        case .compact: return 56
        case .narrow:  return 52
        }
    }

    /// Normal card height: cover + 2 × inset, so the cover sits with a
    /// uniform inset on top, bottom, and leading.
    static func normalHeight(for mode: HomeLayoutMode) -> CGFloat {
        baseCoverSize(for: mode) + cardInset * 2
    }

    private var cardHeight: CGFloat {
        switch kind {
        case .normal:
            return Self.normalHeight(for: mode)
        case .featured(let h), .compact(let h):
            return h
        }
    }

    private var isFeatured: Bool {
        if case .featured = kind { return true }
        return false
    }

    var body: some View {
        Group {
            switch kind {
            case .normal:
                normalBody
            case .featured:
                featuredBody
            case .compact:
                compactBody
            }
        }
        .scaleEffect(isHovering ? (isFeatured ? 1.01 : 1.015) : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .task {
            await loadCover()
        }
    }

    // MARK: - Normal body
    //
    // HStack: cover left, text right. Cover fills the card vertically
    // minus the inset on top/bottom — uniform inset on top, bottom, and
    // leading. innerR = outerR − inset (= 6).
    @ViewBuilder
    private var normalBody: some View {
        let coverSide = cardHeight - Self.cardInset * 2
        HStack(spacing: 14) {
            artwork(side: coverSide, iconSize: 20)
                .frame(width: coverSide, height: coverSide)
                .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: mode == .narrow ? 14 : 15, weight: .semibold))
                    .lineLimit(1)

                metaLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !playlist.userDescription.isEmpty {
                    Text(playlist.userDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Self.cardInset)
        .frame(height: cardHeight)
        .homeUnifiedGlassCard(
            cornerRadius: Self.outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: true
        )
    }

    // MARK: - Featured body
    //
    // HStack: square artwork on the LEFT filling the card vertically, then
    // text/info on the right. With .padding(cardInset) the artwork sits
    // with a uniform 12 pt inset on leading, top, and bottom edges of the
    // card. innerR = outerR − inset.
    @ViewBuilder
    private var featuredBody: some View {
        let artworkSide = max(0, cardHeight - Self.cardInset * 2)
        HStack(alignment: .center, spacing: 14) {
            artwork(side: artworkSide, iconSize: 32)
                .frame(width: artworkSide, height: artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.name)
                    .font(.system(size: mode == .narrow ? 16 : 18, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                metaLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !playlist.userDescription.isEmpty {
                    Text(playlist.userDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Self.cardInset)
        .frame(height: cardHeight)
        .homeUnifiedGlassCard(
            cornerRadius: Self.outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: true
        )
    }

    // MARK: - Compact body
    //
    // Used for the two side cards in the featured cluster. Smaller than
    // a normal card; content reduced to cover + title + track count to
    // avoid crowding inside the reduced height.
    @ViewBuilder
    private var compactBody: some View {
        let coverSide = max(0, cardHeight - Self.cardInset * 2)
        HStack(spacing: 10) {
            artwork(side: coverSide, iconSize: 14)
                .frame(width: coverSide, height: coverSide)
                .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text("\(playlist.trackCount) 首歌曲")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(Self.cardInset)
        .frame(height: cardHeight)
        .homeUnifiedGlassCard(
            cornerRadius: Self.outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: true
        )
    }

    // MARK: - Shared subviews

    @ViewBuilder
    private func artwork(side: CGFloat, iconSize: CGFloat) -> some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ArtworkPlaceholderView(
                size: side,
                cornerRadius: coverCornerRadius,
                clipShape: .continuous,
                iconSize: iconSize,
                iconOpacity: 0.4
            )
        }
    }

    private var metaLine: some View {
        HStack(spacing: 0) {
            Text("\(playlist.trackCount) 首歌曲")
            Text(" \u{00B7} ")
                .foregroundStyle(.tertiary)
            Text(formattedDuration)
        }
    }

    private var formattedDuration: String {
        let totalSeconds = Int(playlist.totalDuration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分"
    }

    private func loadCover() async {
        let request = DetailHeaderArtworkRequest.playlist(
            selectionIdentity: "playlist-\(playlist.id)",
            playlistID: playlist.id,
            tracks: playlist.tracks
        )

        let immediate = DetailHeaderArtworkResolver.shared.resolveImmediately(for: request)
        if let image = await loadHeaderImage(from: immediate) {
            coverImage = image
        }

        let resolved = await DetailHeaderArtworkResolver.shared.resolveDeferredArtwork(for: request)
        if let image = await loadHeaderImage(from: resolved ?? immediate) {
            coverImage = image
        }
    }

    private func loadHeaderImage(from resolved: ResolvedHeaderArtwork?) async -> NSImage? {
        guard let resolved else { return nil }
        let request = PlaylistArtworkPipeline.headerRequest(
            artworkIdentity: headerArtworkIdentity,
            artworkData: resolved.image?.tiffRepresentation,
            fileURL: resolved.fileURL
        )
        return await PlaylistArtworkPipeline.shared.load(request) ?? resolved.image
    }

    private var headerArtworkIdentity: String {
        let selectionIdentity = "playlist-\(playlist.id)"
        if let revision = LocalLibraryService.shared.playlistArtworkRevision(playlistID: playlist.id),
           !revision.isEmpty
        {
            return "\(selectionIdentity)-artwork-\(revision)"
        }
        let signature = PlaylistArtworkGenerator.contentSignature(tracks: playlist.tracks)
        return "\(selectionIdentity)-unresolved-\(signature)"
    }
}

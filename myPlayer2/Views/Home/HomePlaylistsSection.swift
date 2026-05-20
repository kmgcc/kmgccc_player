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
    var titleColor: Color = Color.primary

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @State private var deletionRequest: HomePlaylistDeletionRequest?

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
                    grid(
                        of: selection.remaining,
                        expandsSingleTrailingItem: playlists.count > 3
                    )
                }
            }
        } else {
            // Narrow mode or too few playlists for a cluster: plain grid.
            grid(
                of: playlists,
                expandsSingleTrailingItem: playlists.count > 3
            )
        }
    }

    // MARK: - Cluster

    /// Cluster width ratio (1.30 : 0.70 → 0.65 : 0.35 of the cluster width
    /// minus the gap between the two columns). Slightly tighter than the
    /// previous 1.25 : 0.75 so the featured card has more visual weight
    /// and gains room for additional preview-cover slots.
    private var clusterFeaturedRatio: CGFloat { 1.30 / 2.0 }   // = 0.65
    private var clusterSideRatio: CGFloat { 0.70 / 2.0 }       // = 0.35

    /// How many preview-cover slots fit on the right side of the featured
    /// card. Computed from the featured card's actual width minus the
    /// artwork column and surrounding insets; the available width is
    /// bucketed to 16 pt so the count doesn't jitter pixel-by-pixel as
    /// the window resizes.
    private func featuredPreviewLimit(
        featuredCardWidth: CGFloat,
        featuredHeight: CGFloat
    ) -> Int {
        let modeBaseline: Int = (mode == .wide || mode == .medium) ? 5 : 4
        let artworkSide = max(0, featuredHeight - HomePlaylistCard.cardInset * 2)
        // Featured body layout reserves, in order:
        //   .padding(cardInset) on the card edges (cardInset * 2 total)
        //   HStack(spacing: 14) between artwork and right column
        //   .padding(.trailing, 6) on the right VStack
        let reservedWidth = HomePlaylistCard.cardInset * 2 + 14 + 6
        let available = max(0, featuredCardWidth - artworkSide - reservedWidth)
        let bucketed = (available / 16).rounded(.down) * 16
        let side = HomePlaylistCard.featuredPreviewSide(for: mode)
        let spacing: CGFloat = 7
        guard side > 0 else { return modeBaseline }
        let fit = Int(floor((bucketed + spacing) / (side + spacing)))
        return max(3, min(8, max(fit, modeBaseline)))
    }

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
            let previewLimit = featuredPreviewLimit(
                featuredCardWidth: featuredW,
                featuredHeight: featuredH
            )

            HStack(alignment: .top, spacing: gridSpacing) {
                HomePlaylistCard(
                    playlist: featured,
                    mode: mode,
                    kind: .featured(height: featuredH),
                    featuredPreviewLimit: previewLimit,
                    onFeaturedTrackPlay: { track in
                        play(track, in: featured)
                    }
                )
                .frame(width: featuredW)
                .onTapGesture { navigate(to: featured) }
                .contextMenu { playlistContextMenu(for: featured) }

                VStack(spacing: gridSpacing) {
                    HomePlaylistCard(
                        playlist: sideA,
                        mode: mode,
                        kind: .compact(height: smallH)
                    )
                    .onTapGesture { navigate(to: sideA) }
                    .contextMenu { playlistContextMenu(for: sideA) }
                    HomePlaylistCard(
                        playlist: sideB,
                        mode: mode,
                        kind: .compact(height: smallH)
                    )
                    .onTapGesture { navigate(to: sideB) }
                    .contextMenu { playlistContextMenu(for: sideB) }
                }
                .frame(width: sideW, height: featuredH)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: featuredH)
    }

    // MARK: - Remaining grid
    //
    // Two-column staggered layout with row-alternating proportions:
    //   even rows (0, 2, 4 …): left narrow, right wide
    //   odd rows (1, 3, 5 …):  left wide,   right narrow
    // The widths themselves are unchanged — the narrow/wide pair is just
    // swapped between left and right columns per row, so the row rhythm
    // reads as zig-zagged rather than a fixed lean. Row heights stay
    // constant; narrow mode falls back to a single equal-width column.

    private var staggeredLeftRatio: CGFloat { 0.84 / 2.0 }   // = 0.42
    private var staggeredRightRatio: CGFloat { 1.16 / 2.0 }  // = 0.58

    @ViewBuilder
    private func grid(
        of items: [Playlist],
        expandsSingleTrailingItem: Bool = false
    ) -> some View {
        if columnCount >= 2 {
            staggeredGrid(
                of: items,
                expandsSingleTrailingItem: expandsSingleTrailingItem
            )
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
                    .contextMenu { playlistContextMenu(for: playlist) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func staggeredGrid(
        of items: [Playlist],
        expandsSingleTrailingItem: Bool
    ) -> some View {
        let normalH = HomePlaylistCard.normalHeight(for: mode)
        let expandedTrailingH = HomePlaylistCard.expandedTrailingHeight(for: mode)
        let rowCount = (items.count + 1) / 2
        let hasExpandedTrailingRow = expandsSingleTrailingItem && items.count % 2 == 1
        let totalHeight =
            CGFloat(rowCount) * normalH
            + CGFloat(max(0, rowCount - 1)) * gridSpacing
            - (hasExpandedTrailingRow ? normalH - expandedTrailingH : 0)

        GeometryReader { geo in
            let availableWidth = max(0, geo.size.width - gridSpacing)
            let leftWidth = floor(availableWidth * staggeredLeftRatio)
            let rightWidth = availableWidth - leftWidth
            let rowWidth = geo.size.width

            VStack(alignment: .leading, spacing: gridSpacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    staggeredRow(
                        items: items,
                        rowIndex: row,
                        leftWidth: leftWidth,
                        rightWidth: rightWidth,
                        rowWidth: rowWidth,
                        expandedTrailingHeight: expandedTrailingH,
                        expandsSingleTrailingItem: expandsSingleTrailingItem
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
        rightWidth: CGFloat,
        rowWidth: CGFloat,
        expandedTrailingHeight: CGFloat,
        expandsSingleTrailingItem: Bool
    ) -> some View {
        let leftIndex = rowIndex * 2
        let rightIndex = leftIndex + 1
        let isSingleTrailingItem = rightIndex >= items.count
        let shouldExpandTrailingItem = isSingleTrailingItem && expandsSingleTrailingItem
        // Odd rows swap which column gets the wide width. The expansion
        // override below replaces the leading width with the full row,
        // so alternation doesn't affect single-trailing-item rows.
        let swapColumns = rowIndex.isMultiple(of: 2) == false
        let leftColumnWidth = swapColumns ? rightWidth : leftWidth
        let rightColumnWidth = swapColumns ? leftWidth : rightWidth
        let leftCardWidth = shouldExpandTrailingItem ? rowWidth : leftColumnWidth

        HStack(alignment: .top, spacing: gridSpacing) {
            HomePlaylistCard(
                playlist: items[leftIndex],
                mode: mode,
                kind: shouldExpandTrailingItem ? .expandedTrailing(height: expandedTrailingHeight) : .normal
            )
                .frame(width: leftCardWidth)
                .onTapGesture { navigate(to: items[leftIndex]) }
                .contextMenu { playlistContextMenu(for: items[leftIndex]) }

            if rightIndex < items.count {
                HomePlaylistCard(playlist: items[rightIndex], mode: mode, kind: .normal)
                    .frame(width: rightColumnWidth)
                    .onTapGesture { navigate(to: items[rightIndex]) }
                    .contextMenu { playlistContextMenu(for: items[rightIndex]) }
            } else if shouldExpandTrailingItem {
                EmptyView()
            } else {
                // Single trailing item on the last row keeps the opposite
                // slot empty rather than stretching the lone card across.
                Color.clear.frame(width: rightColumnWidth)
            }
        }
    }

    private func navigate(to playlist: Playlist) {
        uiState.navigateFromHome(
            to: .playlist(playlist.id),
            libraryVM: libraryVM
        )
    }

    private func play(_ playlist: Playlist) {
        playbackCoordinator.playRandomTracks(
            playlist.tracks,
            libraryQueueSource: .librarySelection("home-playlist-\(playlist.id.uuidString)")
        )
    }

    private func play(_ track: Track, in playlist: Playlist) {
        playbackCoordinator.playTrack(
            track,
            inRandomQueueFrom: playlist.tracks,
            libraryQueueSource: .librarySelection("home-playlist-\(playlist.id.uuidString)")
        )
    }

    @ViewBuilder
    private func playlistContextMenu(for playlist: Playlist) -> some View {
        Button {
            play(playlist)
        } label: {
            Label("播放该播放列表", systemImage: "play.fill")
        }

        Button {
            navigate(to: playlist)
        } label: {
            Label("打开播放列表", systemImage: "music.note.list")
        }

        Divider()

        Button(role: .destructive) {
            deletionRequest = HomePlaylistDeletionRequest(playlist: playlist)
        } label: {
            Label(NSLocalizedString("edit.playlist.delete", comment: ""), systemImage: "trash")
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("播放列表")
                .font(.system(size: mode.sectionTitleFontSize, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(titleColor)
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

private struct HomePlaylistDeletionRequest: Identifiable {
    let playlist: Playlist
    var id: UUID { playlist.id }
}

// MARK: - Card

private enum HomePlaylistCardKind {
    case normal
    case expandedTrailing(height: CGFloat)
    case featured(height: CGFloat)
    case compact(height: CGFloat)
}

private struct HomePlaylistCard: View {
    let playlist: Playlist
    let mode: HomeLayoutMode
    let kind: HomePlaylistCardKind
    /// Parent-computed preview-cover slot count for the featured card.
    /// Ignored by non-featured kinds. Defaults to the per-mode baseline
    /// so callers that don't need dynamic sizing can omit it.
    var featuredPreviewLimit: Int?
    var onFeaturedTrackPlay: ((Track) -> Void)?

    @State private var coverImage: NSImage?

    init(
        playlist: Playlist,
        mode: HomeLayoutMode,
        kind: HomePlaylistCardKind,
        featuredPreviewLimit: Int? = nil,
        onFeaturedTrackPlay: ((Track) -> Void)? = nil
    ) {
        self.playlist = playlist
        self.mode = mode
        self.kind = kind
        self.featuredPreviewLimit = featuredPreviewLimit
        self.onFeaturedTrackPlay = onFeaturedTrackPlay
        // Seed @State synchronously from the main-actor cover store so
        // LazyVStack rematerialization doesn't flash the placeholder and
        // doesn't kick off the async resolveImmediately/pipeline hop for
        // covers we've already decoded once this session. The .task body
        // short-circuits when the seed is populated (mirrors the
        // HomePlaylistPreviewArtworkStore pattern already used for the
        // featured-card preview thumbs).
        _coverImage = State(
            initialValue: HomePlaylistCardCoverStore.shared.cachedImage(
                for: Self.headerArtworkIdentity(for: playlist)
            )
        )
    }
    // Hover state intentionally removed — playlist cards used to apply a
    // 1.01–1.015 scaleEffect on hover, which forced the card's glass material
    // to recomposite at a new scale every time the cursor crossed a card
    // during outer vertical scroll. The visual change was barely perceptible
    // while costing significant per-frame compositing work; we drop it
    // entirely rather than replacing with an overlay.
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

    static func expandedTrailingHeight(for mode: HomeLayoutMode) -> CGFloat {
        max(normalHeight(for: mode) - 8, cardInset * 2 + 44)
    }

    private var cardHeight: CGFloat {
        switch kind {
        case .normal:
            return Self.normalHeight(for: mode)
        case .expandedTrailing(let h):
            return h
        case .featured(let h), .compact(let h):
            return h
        }
    }

    private var isFeatured: Bool {
        if case .featured = kind { return true }
        return false
    }

    private var featuredTrackPreviewLimit: Int {
        featuredPreviewLimit ?? Self.modeBaselinePreviewLimit(for: mode)
    }

    private var featuredTrackPreviewSide: CGFloat {
        Self.featuredPreviewSide(for: mode)
    }

    fileprivate static func featuredPreviewSide(for mode: HomeLayoutMode) -> CGFloat {
        switch mode {
        case .wide: return 42
        case .medium: return 38
        case .compact, .narrow: return 34
        }
    }

    fileprivate static func modeBaselinePreviewLimit(for mode: HomeLayoutMode) -> Int {
        switch mode {
        case .wide, .medium: return 5
        case .compact, .narrow: return 4
        }
    }

    private var featuredDescriptionLineLimit: Int {
        2
    }

    private var featuredTrackPreviews: [Track] {
        HomePlaylistPreviewCache.shared.previewTracks(
            for: playlist,
            limit: featuredTrackPreviewLimit
        )
    }

    var body: some View {
        Group {
            switch kind {
            case .normal, .expandedTrailing:
                normalBody
            case .featured:
                featuredBody
            case .compact:
                compactBody
            }
        }
        .task(id: headerArtworkIdentity) {
            // Init seeded @State from HomePlaylistCardCoverStore. If the
            // image is already populated we skip resolveImmediately (which
            // does main-thread sidecar JSON + PNG reads) and the pipeline
            // actor hop entirely — rematerialization of the playlist
            // section now reuses cached covers instead of round-tripping.
            if coverImage != nil { return }
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

                trackCountLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(Self.cardInset)
        .frame(height: cardHeight)
        // `isFloating: false` matches HomeAlbumCard / HomeArtistCircle. The
        // playlist grid stacks many isFloating cards side-by-side, and the
        // overlapping drop shadows both burn compositing work per frame and
        // dim each card's top-edge highlight gradient at the seams (light
        // mode). Same shell otherwise — material and edge overlays unchanged.
        .homeUnifiedGlassCard(
            cornerRadius: Self.outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: false
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
        let previewTracks = featuredTrackPreviews
        HStack(alignment: .top, spacing: 14) {
            artwork(side: artworkSide, iconSize: 32)
                .frame(width: artworkSide, height: artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: coverCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(playlist.name)
                            .font(.system(size: mode == .narrow ? 16 : 18, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        trackCountLine
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(alignment: .trailing)
                    }

                    if !playlist.userDescription.isEmpty {
                        Text(playlist.userDescription)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(featuredDescriptionLineLimit)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)

                if !previewTracks.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(previewTracks) { track in
                            HomeFeaturedPlaylistTrackArtwork(
                                track: track,
                                side: featuredTrackPreviewSide,
                                cornerRadius: 7
                            ) {
                                onFeaturedTrackPlay?(track)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: artworkSide, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
        .padding(Self.cardInset)
        .frame(height: cardHeight)
        // See normalBody — playlist cards run without per-card shadow so
        // the featured card stays visually unified with the grid neighbours.
        .homeUnifiedGlassCard(
            cornerRadius: Self.outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: false
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

                trackCountLine
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(Self.cardInset)
        .frame(height: cardHeight)
        // See normalBody — playlist cards run without per-card shadow.
        .homeUnifiedGlassCard(
            cornerRadius: Self.outerCornerRadius,
            colorScheme: colorScheme,
            isFloating: false
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

    private var trackCountLine: some View {
        Text("\(playlist.trackCount) 首")
    }

    private func loadCover() async {
        let identity = headerArtworkIdentity
        let request = DetailHeaderArtworkRequest.playlist(
            selectionIdentity: "playlist-\(playlist.id)",
            playlistID: playlist.id,
            tracks: playlist.tracks
        )

        let immediate = DetailHeaderArtworkResolver.shared.resolveImmediately(for: request)
        if let image = await loadHeaderImage(from: immediate) {
            coverImage = image
            HomePlaylistCardCoverStore.shared.store(image, for: identity)
        }

        let resolved = await DetailHeaderArtworkResolver.shared.resolveDeferredArtwork(for: request)
        if let image = await loadHeaderImage(from: resolved ?? immediate) {
            coverImage = image
            HomePlaylistCardCoverStore.shared.store(image, for: identity)
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
        Self.headerArtworkIdentity(for: playlist)
    }

    fileprivate static func headerArtworkIdentity(for playlist: Playlist) -> String {
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

/// Main-actor synchronously-readable cache for Home playlist card cover
/// images. Mirrors `HomePlaylistPreviewArtworkStore` but keyed by the
/// playlist's full `headerArtworkIdentity` (selection + revision/signature)
/// so a custom-artwork edit or generated-artwork refresh invalidates the
/// entry automatically — the next render computes a new identity and
/// misses the cache.
@MainActor
private final class HomePlaylistCardCoverStore {
    static let shared = HomePlaylistCardCoverStore()

    private var images: [String: NSImage] = [:]
    private var insertionOrder: [String] = []
    private let capacity = 128

    func cachedImage(for identity: String) -> NSImage? {
        images[identity]
    }

    func store(_ image: NSImage, for identity: String) {
        if images[identity] == nil {
            insertionOrder.append(identity)
        }
        images[identity] = image
        if insertionOrder.count > capacity {
            let oldest = insertionOrder.removeFirst()
            if oldest != identity {
                images.removeValue(forKey: oldest)
            }
        }
    }
}

@MainActor
private final class HomePlaylistPreviewCache {
    static let shared = HomePlaylistPreviewCache()

    private struct Key: Hashable {
        let playlistID: UUID
        let trackSignature: Int
        let limit: Int
    }

    private var cached: [Key: [Track]] = [:]

    func previewTracks(for playlist: Playlist, limit: Int) -> [Track] {
        let key = Key(
            playlistID: playlist.id,
            trackSignature: trackSignature(for: playlist),
            limit: limit
        )
        if let tracks = cached[key] {
            return tracks
        }

        let tracks = Array(
            playlist.tracks
                .enumerated()
                .filter { $0.element.isPlayable && $0.element.hasArtworkSource }
                .sorted { lhs, rhs in
                    let lhsScore = preferenceScore(for: lhs.element)
                    let rhsScore = preferenceScore(for: rhs.element)
                    if lhsScore != rhsScore {
                        return lhsScore > rhsScore
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
                .prefix(limit)
        )

        if cached.count > 80 {
            cached.removeAll(keepingCapacity: true)
        }
        cached[key] = tracks
        return tracks
    }

    private func trackSignature(for playlist: Playlist) -> Int {
        var hasher = Hasher()
        hasher.combine(playlist.tracks.count)
        for track in playlist.tracks {
            hasher.combine(track.id)
            hasher.combine(track.artworkFileName)
        }
        return hasher.finalize()
    }

    private func preferenceScore(for track: Track) -> Double {
        let stats = PreferenceStatsService.shared.getStats(for: track.id)
        let result = PreferenceScorerV2.calculateScore(
            stats: stats,
            duration: track.duration,
            manualLikeState: stats.manualLikeState
        )
        return result.finalPreference
    }
}

private struct HomeFeaturedPlaylistTrackArtwork: View {
    let track: Track
    let side: CGFloat
    let cornerRadius: CGFloat
    let onPlay: () -> Void

    @State private var image: NSImage?

    init(
        track: Track,
        side: CGFloat,
        cornerRadius: CGFloat,
        onPlay: @escaping () -> Void
    ) {
        self.track = track
        self.side = side
        self.cornerRadius = cornerRadius
        self.onPlay = onPlay
        // Seed @State synchronously from the main-actor preview store so
        // LazyVStack rematerialization doesn't flash the placeholder.
        // Falling back to nil for first appearance is fine — the .task
        // below populates and memoizes the image.
        _image = State(
            initialValue: HomePlaylistPreviewArtworkStore.shared.cachedImage(forTrackID: track.id)
        )
    }

    var body: some View {
        Button(action: onPlay) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.36, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(track.title)
        .task(id: track.id) {
            // If the State seed already pulled the image from the main-actor
            // store, skip the actor-cache hop + checksum work. Up to 8 thumbs
            // per featured card × LazyVStack rematerialization adds up.
            if image != nil { return }
            await loadImage()
        }
    }

    private func loadImage() async {
        // Single bucketed thumbnail tier for Home featured-card previews.
        // 96 covers the 34–42 pt display range at 2× Retina without
        // re-decoding per mode, so we keep one derivative key per track
        // across the whole Home view.
        let pixelSide = HomePlaylistPreviewArtworkStore.previewPixelSide
        let displayedSize = CGSize(width: pixelSide, height: pixelSide)

        // Track helper handles in-memory + disk read off the main thread
        // and caches the bytes on the model — don't reimplement here.
        guard let data = await track.loadArtworkDataOffMainIfNeeded(),
              !data.isEmpty
        else {
            image = nil
            return
        }

        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: track.id,
            checksum: checksum,
            targetPixelSize: displayedSize
        )

        // ArtworkLoader's actor cache is async — read once asynchronously,
        // then promote to the main-actor store so subsequent rematerializations
        // hit synchronously via the State seed in init.
        let loaded = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: displayedSize
        )

        guard let loaded else { return }
        HomePlaylistPreviewArtworkStore.shared.store(loaded, forTrackID: track.id)
        if image !== loaded {
            image = loaded
        }
    }
}

/// Main-actor synchronously-readable cache for Home featured-card preview
/// thumbnails. Holds the decoded `NSImage` keyed by track ID so the small
/// 4–8 covers can survive LazyVStack rematerialization without flashing
/// the placeholder while the actor cache is hopped to.
@MainActor
private final class HomePlaylistPreviewArtworkStore {
    static let shared = HomePlaylistPreviewArtworkStore()

    /// Single bucketed thumbnail pixel size used across all Home layout
    /// modes. Covers the 34–42 pt display range at 2× Retina with one
    /// derivative key per track.
    static let previewPixelSide: CGFloat = 96

    private var images: [UUID: NSImage] = [:]
    private var insertionOrder: [UUID] = []
    private let capacity = 256

    func cachedImage(forTrackID trackID: UUID) -> NSImage? {
        images[trackID]
    }

    func store(_ image: NSImage, forTrackID trackID: UUID) {
        if images[trackID] == nil {
            insertionOrder.append(trackID)
        }
        images[trackID] = image
        if insertionOrder.count > capacity {
            let oldest = insertionOrder.removeFirst()
            if oldest != trackID {
                images.removeValue(forKey: oldest)
            }
        }
    }
}

private extension Track {
    var hasArtworkSource: Bool {
        if let artworkData, !artworkData.isEmpty { return true }
        return artworkFileName?.isEmpty == false
    }
}

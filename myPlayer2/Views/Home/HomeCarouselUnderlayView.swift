//
//  HomeCarouselUnderlayView.swift
//  myPlayer2
//
//  Non-interactive visual continuation of the Home page Albums / Artists
//  carousels.
//
//  This view is hosted in the AppKit main window's root view BELOW the
//  split view (z-order: art background → this underlay → split view).
//  It must NEVER receive pointer events — the AppKit hosting view
//  (`AppKitMainSplitWindowController`) returns nil from `hitTest(_:)` so
//  clicks always reach the split view's sidebar / main / inspector / mini
//  player.
//
//  The view reads `HomeCarouselUnderlayState.shared` and:
//    1. Computes the row's content base x using the snapshot's
//       `rowMinXInWindow + leadingScrollPadding − horizontalScrollOffset`.
//    2. Lays each card at an absolute position via `.position(x:y:)`.
//    3. Masks the entire ZStack to the LEFT and RIGHT side strips only
//       (windows where x ∈ [0, centerMinX] ∪ [centerMaxX, windowWidth]).
//       The center strip is always transparent so we never draw duplicates
//       on top of the real in-pane carousel.
//
//  Artwork source: each underlay card pulls its `NSImage` from the shared
//  `HomeCarouselUnderlayState.imageCache`. The real `HomeAlbumCard` /
//  `HomeArtistCircle` populate this cache from their existing loading
//  pipeline (track-fallback for albums, generated artwork for artists),
//  so the underlay always renders the SAME pixels as the real card. If
//  the real card hasn't finished loading yet, the underlay simply skips
//  that item — never a gray placeholder under glass.
//
//  Vertical sync: the row's `.global` frame minY is captured by the section
//  and pushed into state, so the underlay rows track Home page vertical
//  scrolling automatically.
//

import AppKit
import SwiftUI

struct HomeCarouselUnderlayView: View {
    @State private var state = HomeCarouselUnderlayState.shared

    var body: some View {
        let g = state.geometry
        let albums = state.albums
        let artists = state.artists
        let hasGeometry = g.hasValidLayout
        let albumsVisible = hasGeometry && albums.isActive && !albums.items.isEmpty
        let artistsVisible = hasGeometry && artists.isActive && !artists.items.isEmpty

        return ZStack(alignment: .topLeading) {
            if albumsVisible {
                rowLayer(snapshot: albums, geometry: g)
            }
            if artistsVisible {
                rowLayer(snapshot: artists, geometry: g)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask {
            sideStripMask(geometry: g)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea(.container, edges: .all)
    }

    // MARK: - Row layer

    @ViewBuilder
    private func rowLayer(
        snapshot: HomeCarouselUnderlayState.RowSnapshot,
        geometry g: HomeCarouselUnderlayState.Geometry
    ) -> some View {
        let baseX = snapshot.rowMinXInWindow
            + snapshot.leadingScrollPadding
            - snapshot.horizontalScrollOffset
        let centerY = snapshot.rowMinYInWindow
            + snapshot.verticalPadding
            + snapshot.cardHeight / 2

        ForEach(Array(snapshot.items.enumerated()), id: \.element.id) { (index, item) in
            let itemMinX = baseX + CGFloat(index) * (snapshot.cardWidth + snapshot.spacing)
            let itemMaxX = itemMinX + snapshot.cardWidth
            let centerX = itemMinX + snapshot.cardWidth / 2

            // Cull items that are entirely inside the center column (where
            // the side mask would hide them anyway). This keeps the
            // underlay layer count proportional to what's actually visible
            // in the side strips.
            let touchesLeftStrip = itemMinX < g.centerMinXInWindow
            let touchesRightStrip = itemMaxX > g.centerMaxXInWindow
            if touchesLeftStrip || touchesRightStrip {
                UnderlayCardView(
                    item: item,
                    cardWidth: snapshot.cardWidth,
                    cardHeight: snapshot.cardHeight,
                    clipShape: snapshot.clipShape
                )
                .frame(width: snapshot.cardWidth, height: snapshot.cardHeight)
                .position(x: centerX, y: centerY)
            }
        }
    }

    // MARK: - Side strip mask

    /// Mask that keeps only the left and right side strips visible. The
    /// center column (where the real in-pane carousel lives) is fully
    /// transparent so the underlay never paints over it.
    @ViewBuilder
    private func sideStripMask(geometry g: HomeCarouselUnderlayState.Geometry) -> some View {
        let leftWidth = max(0, g.centerMinXInWindow)
        let centerWidth = max(0, g.centerMaxXInWindow - g.centerMinXInWindow)
        let rightWidth = max(0, g.windowWidth - g.centerMaxXInWindow)

        HStack(spacing: 0) {
            Rectangle()
                .fill(.white)
                .frame(width: leftWidth)
            Color.clear
                .frame(width: centerWidth)
            Rectangle()
                .fill(.white)
                .frame(width: rightWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Underlay card

/// Lightweight visual mirror of a real Albums/Artists card.
///
/// Pulls its image from the shared `HomeCarouselUnderlayState.imageCache`
/// (populated by the real cards) and draws ONLY the artwork — no labels,
/// no hover, no shadow. Without an image (real card hasn't loaded yet, or
/// no artwork at all), it draws nothing rather than a gray placeholder.
/// The pane glass above (`NSVisualEffectView` with `.withinWindow`) is the
/// only blur applied; we deliberately avoid stacking a second blur or
/// scrim on top of the artwork.
private struct UnderlayCardView: View {
    let item: HomeCarouselUnderlayState.Item
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let clipShape: HomeCarouselUnderlayState.ClipShape

    @State private var state = HomeCarouselUnderlayState.shared

    var body: some View {
        let image = state.loadedImage(for: item.id)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.9)
            } else {
                Color.clear
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(shapeForClip)
    }

    private var shapeForClip: AnyShape {
        switch clipShape {
        case .roundedRect(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .circle:
            return AnyShape(Circle())
        }
    }
}

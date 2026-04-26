//
//  HomeAlbumsSection.swift
//  myPlayer2
//
//  Section header + invisible row placeholder for the Home Albums carousel.
//  The actual horizontally-scrolling cards are rendered by the wide overlay
//  hosted at the AppKit root level (see `HomeWideCarouselOverlay.swift`),
//  because NSSplitView clips every split item to its column and would
//  prevent the cards from passing under the Sidebar / right pane.
//

import AppKit
import SwiftUI

struct HomeAlbumsSection: View {
    let albums: [AlbumEntry]
    var mode: HomeLayoutMode = .wide
    /// Total outer container width (= HomeView's geo.size.width). Forwarded
    /// to the overlay state so the wide carousel can size itself to the
    /// window. (Kept for API compatibility with HomeView; the placeholder
    /// itself doesn't need it.)
    var outerContainerWidth: CGFloat = 0
    /// The Home page's normal horizontal content inset (= HomeView's hPad).
    /// Forwarded to the overlay state so the first card lines up with the
    /// Home content left edge at scroll offset zero.
    var contentHorizontalPadding: CGFloat = 0

    @ObservedObject private var overlayState = HomeCarouselOverlayState.shared
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            carouselPlaceholder
        }
    }

    /// Reserves the same vertical band that the overlay carousel will paint
    /// into and reports its frame in window coordinates to the shared state.
    /// The placeholder itself is fully transparent and never intercepts
    /// pointer events.
    @ViewBuilder
    private var carouselPlaceholder: some View {
        Color.clear
            .frame(height: HomeWideCarouselMetrics.albumsRowHeight(for: mode))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                HomeCarouselFrameProbe { frame in
                    let windowNumber = NSApp.keyWindow?.windowNumber
                        ?? NSApp.mainWindow?.windowNumber
                        ?? 0
                    overlayState.setAlbumsAnchor(
                        HomeCarouselRowAnchor(
                            frameInWindow: frame,
                            windowNumber: windowNumber
                        )
                    )
                }
                .allowsHitTesting(false)
            )
            .allowsHitTesting(false)
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

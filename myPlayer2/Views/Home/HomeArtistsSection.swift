//
//  HomeArtistsSection.swift
//  myPlayer2
//
//  Section header + invisible row placeholder for the Home Artists carousel.
//  The actual horizontally-scrolling circles are rendered by the wide overlay
//  hosted at the AppKit root level (see `HomeWideCarouselOverlay.swift`),
//  because NSSplitView clips every split item to its column and would
//  prevent the circles from passing under the Sidebar / right pane.
//

import AppKit
import SwiftUI

struct HomeArtistsSection: View {
    let artists: [ArtistEntry]
    var mode: HomeLayoutMode = .wide
    /// Total outer container width (= HomeView's geo.size.width). Forwarded
    /// to the overlay state so the wide carousel can size itself to the
    /// window. (Kept for API compatibility with HomeView.)
    var outerContainerWidth: CGFloat = 0
    /// The Home page's normal horizontal content inset (= HomeView's hPad).
    /// Forwarded to the overlay state so the first circle lines up with the
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
            .frame(height: HomeWideCarouselMetrics.artistsRowHeight(for: mode))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                HomeCarouselFrameProbe { frame in
                    let windowNumber = NSApp.keyWindow?.windowNumber
                        ?? NSApp.mainWindow?.windowNumber
                        ?? 0
                    overlayState.setArtistsAnchor(
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

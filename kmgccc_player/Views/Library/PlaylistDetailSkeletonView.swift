//
//  PlaylistDetailSkeletonView.swift
//  myPlayer2
//
//  Skeleton loading placeholder for playlist and library detail pages.
//  Provides graceful visual continuity during page transitions instead of
//  abruptly flashing a raw progress indicator.
//

import AppKit
import SwiftUI

struct PlaylistDetailSkeletonView: View {
    let showHeader: Bool
    @Environment(LibraryViewModel.self) private var libraryVM
    @EnvironmentObject private var themeStore: ThemeStore

    private enum Layout {
        static let artistColumnWidth: CGFloat = 164
        static let playingIndicatorColumnWidth: CGFloat = 20
        static let durationColumnWidth: CGFloat = 42
        static let trailingMenuHitSize: CGFloat = 30
    }

    init(showHeader: Bool = true) {
        self.showHeader = showHeader
    }

    private var placeholderColor: Color {
        themeStore.appForegroundPalette.primaryColor.opacity(0.06)
    }

    private var placeholderHighlightColor: Color {
        themeStore.appForegroundPalette.primaryColor.opacity(0.10)
    }

    private var isCircularArtwork: Bool {
        if case .artist = libraryVM.currentSelection { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if showHeader {
                        headerSkeleton(contentWidth: max(0, geometry.size.width - 80))
                    }

                    rowsSkeleton(contentWidth: max(0, geometry.size.width - (showHeader ? 80 : 64)))
                        // Match the native table's inset style inside the scroll gutter.
                        .padding(.horizontal, 16)
                        .padding(.trailing, showHeader ? 16 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .padding(.bottom, 64)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func headerSkeleton(contentWidth: CGFloat) -> some View {
        let textColumnWidth = max(0, contentWidth - LibraryDetailHeaderView.artworkSide - 20)

        HStack(alignment: .bottom, spacing: 20) {
            ArtworkPlaceholderView.header(
                size: LibraryDetailHeaderView.artworkSide,
                isCircle: isCircularArtwork,
                themeColor: placeholderHighlightColor
            )
                .frame(
                    width: LibraryDetailHeaderView.artworkSide,
                    height: LibraryDetailHeaderView.artworkSide
                )

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(placeholderHighlightColor)
                    .frame(width: min(220, textColumnWidth), height: 26)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(placeholderColor)
                    .frame(width: min(140, textColumnWidth), height: 15)

                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(placeholderColor)
                        .frame(width: min(90, textColumnWidth), height: 13)
                }

                Spacer(minLength: 14)

                HStack(spacing: 12) {
                    Capsule(style: .continuous)
                        .fill(placeholderHighlightColor)
                        .frame(width: 78, height: 36)

                    Circle()
                        .fill(placeholderColor)
                        .frame(width: 36, height: 36)
                }
            }
            .frame(maxWidth: .infinity, minHeight: LibraryDetailHeaderView.artworkSide, maxHeight: LibraryDetailHeaderView.artworkSide, alignment: .topLeading)
        }
        .frame(height: LibraryDetailHeaderView.artworkSide, alignment: .bottom)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowsSkeleton(contentWidth: CGFloat) -> some View {
        let titleColumnWidth = max(0, contentWidth - 382)

        return VStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { index in
                HStack(spacing: Constants.Layout.TrackRow.horizontalSpacing) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(placeholderHighlightColor)
                        .frame(
                            width: Constants.Layout.artworkSmallSize,
                            height: Constants.Layout.artworkSmallSize
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius)
                        )

                    HStack(spacing: Constants.Layout.TrackRow.textColumnSpacing) {
                        VStack(alignment: .leading, spacing: Constants.Layout.TrackRow.textVerticalSpacing) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(placeholderHighlightColor)
                                .frame(
                                    width: min(titleWidth(for: index), titleColumnWidth),
                                    height: Constants.Layout.TrackRow.titleFontSize
                                )

                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(placeholderColor)
                            .frame(width: min(artistWidth(for: index), Layout.artistColumnWidth), height: 12)
                            .frame(width: Layout.artistColumnWidth, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(width: Layout.playingIndicatorColumnWidth)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(placeholderColor)
                        .frame(width: 32, height: 11)
                        .frame(width: Layout.durationColumnWidth, alignment: .trailing)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(placeholderColor)
                        .frame(width: 14, height: 3)
                        .frame(width: Layout.trailingMenuHitSize, height: Layout.trailingMenuHitSize)
                }
                .padding(.vertical, Constants.Layout.TrackRow.verticalPadding)
                .padding(.horizontal, Constants.Layout.TrackRow.horizontalPadding)
                .frame(height: Constants.Layout.TrackRow.height)
            }
        }
    }

    private func titleWidth(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [180, 140, 220, 160, 190, 130, 210, 170, 150, 200]
        return pattern[index % pattern.count]
    }

    private func artistWidth(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [100, 80, 120, 90, 110, 85, 130, 95, 80, 115]
        return pattern[index % pattern.count]
    }
}

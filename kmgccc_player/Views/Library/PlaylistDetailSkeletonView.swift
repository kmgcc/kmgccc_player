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
        Color.primary.opacity(0.08)
    }

    private var placeholderHighlightColor: Color {
        Color.primary.opacity(0.14)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if showHeader {
                        headerSkeleton(contentWidth: max(0, geometry.size.width - 48))
                    }

                    rowsSkeleton(contentWidth: max(0, geometry.size.width - 48))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, showHeader ? 20 : 12)
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
            .opacity(0.68)
        }
    }

    @ViewBuilder
    private func headerSkeleton(contentWidth: CGFloat) -> some View {
        let textColumnWidth = max(0, contentWidth - LibraryDetailHeaderView.artworkSide - 24)

        HStack(alignment: .bottom, spacing: 24) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(placeholderHighlightColor)
                .frame(
                    width: LibraryDetailHeaderView.artworkSide,
                    height: LibraryDetailHeaderView.artworkSide
                )

            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(placeholderColor)
                    .frame(width: min(56, textColumnWidth), height: 13)

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

                Spacer().frame(height: 4)

                HStack(spacing: 12) {
                    Capsule(style: .continuous)
                        .fill(placeholderHighlightColor)
                        .frame(width: 92, height: 32)

                    Circle()
                        .fill(placeholderColor)
                        .frame(width: 32, height: 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 8)
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

                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(placeholderColor)
                                .frame(
                                    width: min(artistWidth(for: index), titleColumnWidth * 0.65),
                                    height: Constants.Layout.TrackRow.subtitleFontSize
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

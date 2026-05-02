//
//  HomeArtistsSection.swift
//  myPlayer2
//
//  Horizontal scrolling artist circles for the Home page.
//
//  Section title aligns inside the center column; the carousel viewport
//  spans the full window width with the first circle anchored at the
//  center column's left edge.
//

import AppKit
import SwiftUI

struct HomeArtistsSection: View {
    let artists: [ArtistEntry]
    var mode: HomeLayoutMode = .wide
    let centerLeftPad: CGFloat
    let centerRightPad: CGFloat

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

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
            leadingScrollPadding: centerLeftPad + 4,
            trailingScrollPadding: max(4, centerRightPad - 8),
            showsEdgeFade: false
        ) {
            ForEach(artists) { artist in
                HomeArtistCircle(artist: artist, mode: mode)
            }
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

    private var rowSpacing: CGFloat {
        switch mode {
        case .wide:    return 16
        case .medium:  return 12
        case .compact: return 10
        case .narrow:  return 10
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
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: circleSize + (mode == .narrow ? 26 : 32))
        .homeUnifiedGlassCard(
            cornerRadius: 18,
            colorScheme: colorScheme,
            isFloating: true
        )
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
            return
        }

        let canonicalName = artist.canonicalName
        let tracks = libraryVM.allTracks.filter {
            LibraryNormalization.containsArtist(canonicalName, in: $0.artist)
        }
        let generated = await ArtistArtworkGenerator.shared.generateArtwork(
            artistName: artist.displayName,
            tracks: tracks
        )
        image = generated
    }
}

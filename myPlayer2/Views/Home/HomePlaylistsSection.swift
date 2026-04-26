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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader

            let count = max(1, min(columnCount, max(playlists.count, 1)))
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top),
                count: count
            )

            LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
                ForEach(playlists) { playlist in
                    HomePlaylistCard(playlist: playlist, mode: mode)
                        .onTapGesture {
                            uiState.navigateFromHome(
                                to: .playlist(playlist.id),
                                libraryVM: libraryVM
                            )
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Vertical padding so hover lift / shadow has headroom and isn't
            // clipped by neighbouring sections.
            .padding(.vertical, 4)
        }
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

private struct HomePlaylistCard: View {
    let playlist: Playlist
    let mode: HomeLayoutMode

    @State private var coverImage: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private let radius: CGFloat = 18

    private var coverSize: CGFloat {
        switch mode {
        case .wide:    return 68
        case .medium:  return 60
        case .compact: return 56
        case .narrow:  return 52
        }
    }

    private var cardHeight: CGFloat {
        coverSize + 28
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let coverImage {
                    Image(nsImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ArtworkPlaceholderView(
                        size: coverSize,
                        cornerRadius: 12,
                        clipShape: .continuous,
                        iconSize: 20,
                        iconOpacity: 0.4
                    )
                }
            }
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: mode == .narrow ? 14 : 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 0) {
                    Text("\(playlist.trackCount) 首歌曲")
                    Text(" \u{00B7} ")
                        .foregroundStyle(.tertiary)
                    Text(formattedDuration)
                }
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
        .padding(12)
        .frame(height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.04)
                      : Color.black.opacity(0.03))
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.2 : 0.06),
            radius: isHovering ? 10 : 6, y: isHovering ? 4 : 2
        )
        .scaleEffect(isHovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .task {
            await loadCover()
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
        guard let firstTrack = playlist.tracks.first else { return }
        guard let data = firstTrack.loadArtworkDataIfNeeded(), !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: firstTrack.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 136, height: 136)
        )
        coverImage = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 136, height: 136)
        )
    }
}

//
//  HomePlaylistsSection.swift
//  myPlayer2
//
//  Playlist cards for the Home page.
//  Phase 1: basic layout. Phase 3 will add blurred backdrop.
//

import AppKit
import SwiftUI

struct HomePlaylistsSection: View {
    let playlists: [Playlist]

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader

            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 14),
                count: min(3, max(1, playlists.count))
            )

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(playlists) { playlist in
                    HomePlaylistCard(playlist: playlist)
                        .onTapGesture {
                            libraryVM.currentSelection = .playlist(playlist.id)
                            uiState.showLibrary()
                        }
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("home.section.curated", comment: "Curated"))
                    .font(.caption)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("home.section.playlists", comment: "Playlists"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
            }
            Spacer()
        }
    }
}

private struct HomePlaylistCard: View {
    let playlist: Playlist

    @State private var coverImage: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private let cardHeight: CGFloat = 96
    private let coverSize: CGFloat = 68
    private let radius: CGFloat = 18

    var body: some View {
        HStack(spacing: 14) {
            // Playlist cover
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
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 0) {
                    Text("\(playlist.trackCount) \(NSLocalizedString("home.songs", comment: "songs"))")
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
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    private func loadCover() async {
        // Use first track's artwork as playlist cover
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

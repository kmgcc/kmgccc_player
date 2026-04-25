//
//  HomeAlbumsSection.swift
//  myPlayer2
//
//  Horizontal scrolling album cards for the Home page.
//

import AppKit
import SwiftUI

struct HomeAlbumsSection: View {
    let albums: [AlbumEntry]

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(albums) { album in
                        HomeAlbumCard(album: album)
                            .onTapGesture {
                                libraryVM.currentSelection = .album(album.canonicalKey)
                                libraryVM.selectedAlbumName = album.displayTitle
                                uiState.showLibrary()
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("home.section.from_library", comment: "From your library"))
                    .font(.caption)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("home.section.albums", comment: "Albums"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
            }
            Spacer()
        }
    }
}

private struct HomeAlbumCard: View {
    let album: AlbumEntry

    @State private var image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    private let cardSize: CGFloat = 168
    private let radius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ArtworkPlaceholderView(
                        size: cardSize,
                        cornerRadius: radius,
                        clipShape: .continuous,
                        iconSize: 32,
                        iconOpacity: 0.4
                    )
                }
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12),
                radius: 8, y: 4
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(album.primaryArtistDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(album.trackCount) \(NSLocalizedString("home.songs", comment: "songs"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .frame(width: cardSize)
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let data = album.artworkData, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: album.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 336, height: 336)
        )
        image = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 336, height: 336)
        )
    }
}

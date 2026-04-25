//
//  HomeArtistsSection.swift
//  myPlayer2
//
//  Horizontal scrolling artist circles for the Home page.
//

import AppKit
import SwiftUI

struct HomeArtistsSection: View {
    let artists: [ArtistEntry]

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(artists) { artist in
                        HomeArtistCircle(artist: artist)
                            .onTapGesture {
                                libraryVM.currentSelection = .artist(artist.canonicalName)
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
                Text(NSLocalizedString("home.section.people", comment: "People"))
                    .font(.caption)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("home.section.artists", comment: "Artists"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
            }
            Spacer()
        }
    }
}

private struct HomeArtistCircle: View {
    let artist: ArtistEntry

    @State private var image: NSImage?
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private let circleSize: CGFloat = 128

    var body: some View {
        VStack(spacing: 12) {
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
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.35 : 0.15),
                radius: isHovering ? 14 : 10, y: isHovering ? 6 : 4
            )

            VStack(spacing: 3) {
                Text(artist.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text("\(artist.albumCount) \(NSLocalizedString("home.albums", comment: "albums")) \u{00B7} \(artist.trackCount) \(NSLocalizedString("home.songs", comment: "songs"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: circleSize + 20)
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let data = artist.artworkData, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: artist.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 256, height: 256)
        )
        image = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 256, height: 256)
        )
    }
}

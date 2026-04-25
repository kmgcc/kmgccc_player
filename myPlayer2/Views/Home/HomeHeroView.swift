//
//  HomeHeroView.swift
//  myPlayer2
//
//  Hero card for the Home page.
//  Phase 1: basic structure with artwork and track info.
//  Phase 3 will add blurred backdrop effect.
//

import AppKit
import SwiftUI

struct HomeHeroView: View {
    let track: Track

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.colorScheme) private var colorScheme

    @State private var coverImage: NSImage?

    private let heroHeight: CGFloat = 300
    private let coverSize: CGFloat = 244
    private let coverRadius: CGFloat = 18

    var body: some View {
        ZStack {
            // Background — Phase 3 will add blurred artwork
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.04)
                      : Color.black.opacity(0.03))

            HStack(spacing: 28) {
                artworkView
                    .frame(width: coverSize, height: coverSize)

                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("home.hero.eyebrow", comment: "From your library"))
                        .font(.caption)
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    Text(track.title)
                        .font(.system(size: 36, weight: .semibold))
                        .tracking(-0.5)
                        .lineLimit(2)

                    HStack(spacing: 0) {
                        Text(track.artist)
                            .foregroundStyle(.primary)
                        if !track.album.isEmpty {
                            Text(" \u{00B7} ")
                                .foregroundStyle(.tertiary)
                            Text(track.album)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                    HStack(spacing: 0) {
                        Text(formattedDuration)
                        let stats = PreferenceStatsService.shared.getStats(for: track.id)
                        if stats.playCount > 0 {
                            Text(" \u{00B7} ")
                            Text("\(stats.playCount) \(NSLocalizedString("home.hero.plays", comment: "plays"))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    Spacer(minLength: 8)

                    Button {
                        playerVM.play(track: track)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text(NSLocalizedString("home.hero.play", comment: "Play"))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 20, y: 6)
        .task {
            await loadCoverImage()
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        } else {
            ArtworkPlaceholderView(
                size: coverSize,
                cornerRadius: coverRadius,
                clipShape: .continuous,
                iconSize: 48,
                iconOpacity: 0.4
            )
        }
    }

    private var formattedDuration: String {
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadCoverImage() async {
        // Load hero artwork — single image, larger size is OK
        let data = track.loadArtworkDataIfNeeded()
        guard let data, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        let key = ArtworkLoader.cacheKey(
            trackID: track.id,
            checksum: checksum,
            targetPixelSize: CGSize(width: 480, height: 480)
        )
        coverImage = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: key,
            targetPixelSize: CGSize(width: 480, height: 480)
        )
    }
}

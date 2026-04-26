//
//  HomeHeroView.swift
//  myPlayer2
//
//  Hero card for the Home page.
//  Blurred artwork backdrop with track info and play button.
//

import AppKit
import SwiftUI

struct HomeHeroView: View {
    let track: Track
    var containerWidth: CGFloat = 700
    var mode: HomeLayoutMode = .wide

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var coverImage: NSImage?
    @State private var isHovering = false

    private var heroHeight: CGFloat {
        switch mode {
        case .wide:    return 230
        case .medium:  return 210
        case .compact: return 196
        case .narrow:  return 176
        }
    }

    private var coverSize: CGFloat {
        switch mode {
        case .wide:    return 170
        case .medium:  return 154
        case .compact: return 130
        case .narrow:  return 108
        }
    }

    private var titleFontSize: CGFloat {
        switch mode {
        case .wide:    return 26
        case .medium:  return 22
        case .compact: return 19
        case .narrow:  return 17
        }
    }

    private var heroPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 20
        case .compact:       return 16
        case .narrow:        return 14
        }
    }

    private let coverRadius: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdropView
            heroContent
                .zIndex(1)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(coverImage != nil ? 0.12 : 0.0), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 18, y: 6)
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: track.id) {
            await loadCoverImage()
        }
    }

    @ViewBuilder
    private var backdropView: some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 50, opaque: true)
                .saturation(colorScheme == .dark ? 1.2 : 1.1)
                .brightness(colorScheme == .dark ? -0.15 : 0.05)
                .overlay(
                    Color.black.opacity(colorScheme == .dark ? 0.35 : 0.15)
                )
                .clipped()
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.04)
                      : Color.black.opacity(0.03))
        }
    }

    private var heroContent: some View {
        HStack(alignment: .center, spacing: heroPadding) {
            artworkView
                .frame(width: coverSize, height: coverSize)

            trackInfoView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(heroPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Make sure we never let the foreground content collapse — without
        // this guard, a stack-layout race could give trackInfoView zero
        // height and hide the title/play button under the artwork.
        .layoutPriority(1)
    }

    @ViewBuilder
    private var trackInfoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track.title)
                .font(.system(size: titleFontSize, weight: .semibold))
                .tracking(-0.5)
                .lineLimit(2)
                .foregroundStyle(coverImage != nil ? .white : .primary)

            artistAlbumLine
            statsLine

            Spacer(minLength: 6)

            playButton
        }
    }

    @ViewBuilder
    private var artistAlbumLine: some View {
        HStack(spacing: 0) {
            Text(track.artist)
                .foregroundStyle(coverImage != nil ? .white.opacity(0.9) : .primary)
            if !track.album.isEmpty {
                Text(" \u{00B7} ")
                    .foregroundStyle(coverImage != nil ? .white.opacity(0.4) : Color(nsColor: .tertiaryLabelColor))
                Text(track.album)
                    .foregroundStyle(coverImage != nil ? .white.opacity(0.7) : .secondary)
            }
        }
        .font(.system(size: mode == .narrow ? 12 : 14, weight: .medium))
        .lineLimit(1)
    }

    @ViewBuilder
    private var statsLine: some View {
        HStack(spacing: 0) {
            Text(formattedDuration)
            let stats = PreferenceStatsService.shared.getStats(for: track.id)
            if stats.playCount > 0 {
                Text(" \u{00B7} ")
                Text("\(stats.playCount) 次播放")
            }
        }
        .font(.caption)
        .foregroundStyle(coverImage != nil ? .white.opacity(0.55) : Color(nsColor: .tertiaryLabelColor))
    }

    private var playButton: some View {
        let bgColor: Color = coverImage != nil
            ? Color.white
            : (colorScheme == .dark ? Color.white : Color.black)
        let fgColor: Color = coverImage != nil
            ? Color.black
            : (colorScheme == .dark ? Color.black : Color.white)

        return Button {
            playerVM.play(track: track)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("播放")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(fgColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(bgColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        } else {
            ArtworkPlaceholderView(
                size: coverSize,
                cornerRadius: coverRadius,
                clipShape: .continuous,
                iconSize: 40,
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
        coverImage = nil
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

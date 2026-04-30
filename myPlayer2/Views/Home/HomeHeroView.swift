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
    @State private var artworkData: Data?
    @State private var heroArtworkChecksum: UInt64 = 0
    @State private var artworkDominantColor: NSColor?
    @State private var isHovering = false

    private var heroHeight: CGFloat {
        switch mode {
        case .wide:    return 320
        case .medium:  return 295
        case .compact: return 270
        case .narrow:  return 250
        }
    }

    private var heroTopPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 36
        case .compact:       return 28
        case .narrow:        return 24
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

    private var heroBlurConfig: CoverGradientBlurConfig {
        CoverGradientBlurConfig(
            blurRadius: 80,
            colorOverlayOpacity: 0.40,
            transitionDuration: 0.35,
            edgeStripWidth: 3.0,
            blurStartRatio: 0.1,
            blurEndRatio: 0.9,
            overlayOffsetRatio: 0.0,
            blurCurveGamma: 5.0,
            overlayCurveGamma: 3.0,
            edgeFillMode: .pixelStretch,
            // Start blur slightly inside the artwork's right half
            blurStartRatioFromEdge: 0.35,
            // More linear ramp: reaches large blur values earlier than the default cubic
            blurAlphaCoefficients: (0, 0.50, 0.30, 0.20)
        )
    }

    /// Width the background renderer draws the artwork at (scale-to-height).
    /// Used to push the text content past the visible cover art.
    private var artworkLeadingWidth: CGFloat {
        guard artworkData != nil else { return 0 }
        if let img = coverImage {
            return heroHeight * (img.size.width / max(1, img.size.height))
        }
        return heroHeight  // assume square while image is loading
    }

    @ViewBuilder
    private var backdropView: some View {
        if let artworkData {
            CoverGradientBlurBackgroundView(
                artworkData: artworkData,
                artworkImage: coverImage,
                artworkChecksum: heroArtworkChecksum,
                dominantColor: artworkDominantColor,
                config: heroBlurConfig
            )
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color.white.opacity(0.04)
                      : Color.black.opacity(0.03))
        }
    }

    private var heroContent: some View {
        trackInfoView
            .padding(.top, heroTopPadding)
            .padding(.leading, heroPadding + artworkLeadingWidth)
            .padding(.trailing, heroPadding)
            .padding(.bottom, heroPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        Button {
            playerVM.play(track: track)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("播放")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.95 : 0.90))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            Capsule()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.15))
        }
        .glassEffect(.clear, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .clipShape(Capsule())
    }

    private var formattedDuration: String {
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadCoverImage() async {
        coverImage = nil
        artworkData = nil
        heroArtworkChecksum = 0
        artworkDominantColor = nil
        let data = track.loadArtworkDataIfNeeded()
        guard let data, !data.isEmpty else { return }
        let checksum = ArtworkLoader.checksum(for: data)
        artworkData = data
        heroArtworkChecksum = checksum
        artworkDominantColor = ArtworkColorExtractor.averageColor(from: data)
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

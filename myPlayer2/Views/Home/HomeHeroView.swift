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

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var coverImage: NSImage?
    @State private var artworkData: Data?
    @State private var heroArtworkChecksum: UInt64 = 0
    @State private var artworkDominantColor: NSColor?
    @State private var isHovering = false
    @State private var trackToEdit: Track?

    private var baseHeroHeight: CGFloat {
        switch mode {
        case .wide:    return 320
        case .medium:  return 295
        case .compact: return 270
        case .narrow:  return 250
        }
    }

    private var heroHeight: CGFloat {
        baseHeroHeight + wideExpansion * 56
    }

    private var heroTopPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 36
        case .compact:       return 28
        case .narrow:        return 24
        }
    }

    private var titleFontSize: CGFloat {
        let extra = wideExpansion * 5
        switch mode {
        case .wide:    return 31 + extra
        case .medium:  return 27
        case .compact: return 23
        case .narrow:  return 20
        }
    }

    private var wideExpansion: CGFloat {
        guard mode == .wide else { return 0 }
        return min(max((containerWidth - 920) / 520, 0), 1)
    }

    private var heroButtonHeight: CGFloat {
        switch mode {
        case .wide:    return 36 + wideExpansion * 8
        case .medium:  return 36
        case .compact: return 34
        case .narrow:  return 32
        }
    }

    private var heroButtonHorizontalPadding: CGFloat {
        switch mode {
        case .wide:    return 16 + wideExpansion * 4
        case .medium:  return 16
        case .compact: return 14
        case .narrow:  return 13
        }
    }

    private var heroButtonIconSize: CGFloat {
        switch mode {
        case .wide:    return 12 + wideExpansion * 2
        case .medium:  return 12
        case .compact: return 11
        case .narrow:  return 10.5
        }
    }

    private var heroButtonTextSize: CGFloat {
        switch mode {
        case .wide:    return 13 + wideExpansion * 1.5
        case .medium:  return 13
        case .compact: return 12
        case .narrow:  return 12
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
                .contentShape(Rectangle())
                .onTapGesture {
                    playHeroTrackInHomeQueue()
                }
            heroContent
                .zIndex(1)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
                .environmentObject(themeStore)
        }
        .task(id: track.id) {
            await loadCoverImage()
        }
    }

    private var heroBlurConfig: CoverGradientBlurConfig {
        CoverGradientBlurConfig(
            blurRadius: 90,
            colorOverlayOpacity: 0.40,
            transitionDuration: 0.35,
            edgeStripWidth: 3.0,
            blurStartRatio: 0.08,
            blurEndRatio: 0.9,
            overlayOffsetRatio: 0.0,
            blurCurveGamma: 5.0,
            overlayCurveGamma: 3.0,
            edgeFillMode: .pixelStretch,
            // Start blur slightly inside the artwork's right half
            blurStartRatioFromEdge: 0.42,
            // More linear ramp: reaches large blur values earlier than the default cubic
            blurAlphaCoefficients: (0, 0.54, 0.30, 0.24)
        )
    }

    /// Width the background renderer draws the artwork at (scale-to-height).
    /// Used to push the text content past the visible cover art.
    private var artworkLeadingWidth: CGFloat {
        guard artworkData != nil else { return 0 }
        if let img = coverImage {
            return baseHeroHeight * (img.size.width / max(1, img.size.height))
        }
        return baseHeroHeight  // assume square while image is loading
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
                .fill(Color.clear)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .tracking(0)
                    .lineLimit(2)
                    .foregroundStyle(coverImage != nil ? .white : .primary)

                artistAlbumLine
                statsLine
            }
            .contentShape(Rectangle())
            .onTapGesture {
                playHeroTrackInHomeQueue()
            }

            Spacer(minLength: 6)

            actionButtons
                .padding(.bottom, actionBottomPadding)
        }
    }

    private var actionBottomPadding: CGFloat {
        switch mode {
        case .wide, .medium: return 8
        case .compact:       return 6
        case .narrow:        return 4
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            playButton
            moreButton
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
            playHeroTrackInHomeQueue()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: heroButtonIconSize, weight: .semibold))
                Text("播放")
                    .font(.system(size: heroButtonTextSize, weight: .medium))
            }
            .foregroundStyle(heroButtonForeground)
            .padding(.horizontal, heroButtonHorizontalPadding)
            .frame(height: heroButtonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .homeHeroHeaderGlassCapsule(colorScheme: colorScheme)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var moreButton: some View {
        Menu {
            TrackActionMenuContent(
                track: track,
                selectedPlaylistID: nil,
                onPlay: {
                    playHeroTrackInHomeQueue()
                },
                onEditTrack: { trackToEdit = $0 }
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: heroButtonIconSize + 3, weight: .semibold))
                .foregroundStyle(heroButtonForeground)
                .frame(width: heroButtonHeight, height: heroButtonHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: heroButtonHeight, height: heroButtonHeight)
        .fixedSize()
        .homeHeroHeaderGlassCircle(colorScheme: colorScheme)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var heroButtonForeground: Color {
        if heroButtonNeedsDarkForeground {
            return Color.black.opacity(colorScheme == .dark ? 0.80 : 0.74)
        }

        if coverImage != nil {
            return Color.white.opacity(colorScheme == .dark ? 0.95 : 0.90)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.92 : 0.82)
    }

    private var heroButtonNeedsDarkForeground: Bool {
        guard let color = heroButtonContrastSourceColor else { return false }
        return Self.perceivedBrightness(of: color) > 0.68
    }

    private var heroButtonContrastSourceColor: NSColor? {
        if themeStore.hasArtworkThemeColor {
            return themeStore.artworkBaseNSColor
        }
        return coverImage == nil ? nil : artworkDominantColor
    }

    private var formattedDuration: String {
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var homePlayableTracks: [Track] {
        libraryVM.allTracks.filter { $0.availability != .missing }
    }

    private func playHeroTrackInHomeQueue() {
        let tracks = homePlayableTracks
        guard !tracks.isEmpty else { return }
        playbackCoordinator.playTrack(
            track,
            inRandomQueueFrom: tracks,
            libraryQueueSource: .librarySelection("home")
        )
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

    private static func perceivedBrightness(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
    }
}

private extension View {
    func homeHeroHeaderGlassCapsule(colorScheme: ColorScheme) -> some View {
        let shape = Capsule()
        return self
            .glassEffect(.clear, in: shape)
            .overlay {
                shape
                    .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }

    func homeHeroHeaderGlassCircle(colorScheme: ColorScheme) -> some View {
        let shape = Circle()
        return self
            .glassEffect(.clear, in: shape)
            .overlay {
                shape
                    .strokeBorder(GlassStyleTokens.highlightGradient, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }
}

//
//  FullscreenMiniPlayerView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Mini Player View
//  Enlarged miniplayer controls for fullscreen mode.
//

import AppKit
import SwiftUI

struct FullscreenControlsGlassStyle {
    let colorScheme: ColorScheme
    let accentColor: Color?
    let materialStyle: LiquidGlassPillMaterialStyle
}

/// Enlarged mini player bar for fullscreen mode.
/// Layout: Cover+Title | Controls | Playback Mode | Progress | Volume
struct FullscreenMiniPlayerView: View {
    // Scale factor for responsive sizing at different resolutions
    var scale: CGFloat = 1.0
    let glassStyle: FullscreenControlsGlassStyle
    let playbackMode: PlaybackOrderMode
    let onPlaybackModeChange: (PlaybackOrderMode) -> Void
    let onCurrentPlaybackModeRetap: (PlaybackOrderMode) -> Void
    var onInteraction: () -> Void = {}
    var onHoverStateChanged: (Bool) -> Void = { _ in }
    var onProgressDraggingChanged: (Bool) -> Void = { _ in }
    
    private let fixedBarHeight: CGFloat = 60
    private static let fullscreenThemeMinLightness: CGFloat = 0.90
    private static let fullscreenThemeMaxLightness: CGFloat = 0.98
    private static let fullscreenThemeMinSaturation: CGFloat = 0.88

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var previousSymbolEffectTrigger = 0
    @State private var playPauseSymbolEffectTrigger = 0
    @State private var nextSymbolEffectTrigger = 0
    @State private var artworkImage: NSImage?
    @State private var isPlaybackModeExpanded = false

    // Computed properties based on settings and scale
    private var barHeight: CGFloat { fixedBarHeight * scale }
    private var artworkSize: CGFloat { barHeight * 0.73 }
    private var controlSize: CGFloat { barHeight * 0.6 }
    private var iconSize: CGFloat { barHeight * 0.27 }
    private var primaryIconSize: CGFloat { barHeight * 0.33 }
    
    // Layout constants scaled
    private var trackInfoWidth: CGFloat { 196 * scale }
    private var controlsWidth: CGFloat { 174 * scale }
    private var playbackModeExpandedWidth: CGFloat { 178 * scale }
    private var playbackModeCollapsedWidth: CGFloat { 56 * scale }
    private var playbackModeOccupancyWidth: CGFloat {
        isPlaybackModeExpanded ? playbackModeExpandedWidth : playbackModeCollapsedWidth
    }
    private var minProgressWidth: CGFloat { 320 * scale }
    private var hStackSpacing: CGFloat { 18 * scale }
    private var hPadding: CGFloat { 20 * scale }
    private var vPadding: CGFloat { 8 * scale }
    private var trackInfoHSpacing: CGFloat { 16 * scale }
    private var trackInfoVSpacing: CGFloat { 6 * scale }
    private var titleFontSize: CGFloat { 15 * scale }
    private var artistFontSize: CGFloat { 12.5 * scale }
    private var artworkCornerRadius: CGFloat { 12 * scale }
    private var musicNoteIconSize: CGFloat { 22 * scale }
    private var controlsHSpacing: CGFloat { 20 * scale }
    private var timeFontSize: CGFloat { 10.5 * scale }
    private var progressAreaHPadding: CGFloat { 8 * scale }
    private var progressTimeSpacing: CGFloat { 10 * scale }
    private var progressYOffset: CGFloat { 13 * scale }
    private var layoutAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }

    var body: some View {
        HStack(spacing: hStackSpacing) {
            // Left: Cover + Title/Artist
            trackInfoView
                .frame(width: trackInfoWidth, alignment: .leading)

            // Center: Playback Controls
            controlsView
                .frame(width: controlsWidth)

            // Playback Mode
            playbackModeView
                .frame(width: playbackModeOccupancyWidth, alignment: .leading)

            // Progress bar
            progressArea
                .frame(minWidth: minProgressWidth, maxWidth: .infinity)

            // Volume removed - now external component
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .frame(height: barHeight)
        .liquidGlassPill(
            colorScheme: glassStyle.colorScheme,
            accentColor: glassStyle.accentColor,
            prominence: .prominent,
            materialStyle: glassStyle.materialStyle,
            isFloating: true
        )
        .onHover { hovering in
            onHoverStateChanged(hovering)
            if hovering {
                onInteraction()
            }
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkThumbnail()
        }
    }

    // MARK: - Subviews

    private var trackInfoView: some View {
        HStack(spacing: trackInfoHSpacing) {
            artworkView

            VStack(alignment: .leading, spacing: trackInfoVSpacing) {
                if let track = playerVM.currentTrack {
                    MarqueeText(
                        text: track.title,
                        fontSize: titleFontSize,
                        fontWeight: .semibold,
                        color: lyricsDynamicPrimaryColor,
                        enablesContentTransition: true
                    )

                    MarqueeText(
                        text: track.artist.isEmpty
                            ? NSLocalizedString("library.unknown_artist", comment: "")
                            : track.artist,
                        fontSize: artistFontSize,
                        fontWeight: .medium,
                        color: lyricsDynamicSecondaryColor,
                        enablesContentTransition: true
                    )
                } else {
                    Text("mini.not_playing")
                        .font(.system(size: titleFontSize, weight: .semibold))
                        .foregroundStyle(lyricsDynamicSecondaryColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        } else {
            ArtworkPlaceholderView.fullscreenMiniPlayer(artworkSize: 44, scale: scale)
        }
    }

    private var controlsView: some View {
        let isEnabled = playerVM.currentTrack != nil
        return HStack(spacing: controlsHSpacing) {
            // Previous
            Button {
                onInteraction()
                previousSymbolEffectTrigger += 1
                playerVM.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                    .compositingGroup()
                    .blendMode(isEnabled ? .screen : .normal)
                    .symbolEffect(.wiggle, value: previousSymbolEffectTrigger)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            // Play/Pause
            Button {
                onInteraction()
                playPauseSymbolEffectTrigger += 1
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: primaryIconSize, weight: .semibold))
                    .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                    .compositingGroup()
                    .blendMode(isEnabled ? .screen : .normal)
                    .symbolEffect(.bounce, value: playPauseSymbolEffectTrigger)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            // Next
            Button {
                onInteraction()
                nextSymbolEffectTrigger += 1
                playerVM.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                    .compositingGroup()
                    .blendMode(isEnabled ? .screen : .normal)
                    .symbolEffect(.wiggle, value: nextSymbolEffectTrigger)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }

    private var playbackModeView: some View {
        let isEnabled = playerVM.currentTrack != nil
        return PlaybackModeSlider(
            mode: playbackMode,
            isEnabled: isEnabled,
            isExpanded: isPlaybackModeExpanded,
            iconSize: 16 * scale,
            selectedColor: controlPrimaryColor,
            unselectedColor: controlPrimaryColor.opacity(0.62),
            useScreenBlend: true,
            pillTintColor: themeStore.accentColor,
            pillTintBlendMode: .normal,
            onInteraction: onInteraction,
            scale: scale,
            onModeChange: onPlaybackModeChange,
            onCurrentModeRetap: onCurrentPlaybackModeRetap
        )
        .frame(width: playbackModeOccupancyWidth, height: 36 * scale, alignment: .leading)
        .contentShape(Capsule())
        .animation(layoutAnimation, value: isPlaybackModeExpanded)
        .onHover { hovering in
            guard isEnabled else {
                if isPlaybackModeExpanded {
                    isPlaybackModeExpanded = false
                }
                return
            }
            if hovering {
                onInteraction()
            }
            withAnimation(layoutAnimation) {
                isPlaybackModeExpanded = hovering
            }
        }
    }

    private var progressArea: some View {
        MiniPlayerProgressSpectrumRow(
            scale: scale,
            isSpectrumEnabled: settings.fullscreen.isMiniPlayerSpectrumEnabled,
            isPlaying: playerVM.isPlaying,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            progress: progressDisplayTime,
            duration: playerVM.duration,
            onSeek: { seekTime in
                onInteraction()
                dragProgress = seekTime
            },
            onDragStart: {
                onInteraction()
                isDragging = true
                onProgressDraggingChanged(true)
            },
            onDragEnd: {
                onInteraction()
                playerVM.seek(to: dragProgress)
                isDragging = false
                onProgressDraggingChanged(false)
            },
            onInteraction: onInteraction,
            onDragStateChanged: onProgressDraggingChanged
        )
    }

    // MARK: - Legacy Progress Views (kept for reference, no longer used)
    
    @available(*, deprecated, message: "Replaced by MiniPlayerProgressSpectrumRow")
    private var progressBarWithSpectrum: some View {
        EmptyView()
    }
    
    @available(*, deprecated, message: "Replaced by MiniPlayerProgressSpectrumRow")
    private var progressBar: some View {
        EmptyView()
    }
    
    private var currentArtworkTaskKey: String {
        guard let track = playerVM.currentTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: track.artworkData)
        return "\(track.id.uuidString)-\(checksum)"
    }
    
    private func loadArtworkThumbnail() async {
        guard let track = playerVM.currentTrack, let artworkData = track.artworkData, !artworkData.isEmpty
        else {
            artworkImage = nil
            return
        }
        
        let snapshot = await ArtworkAssetStore.shared.snapshotMetadata(
            trackID: track.id,
            artworkData: artworkData
        )
        guard !Task.isCancelled else { return }
        artworkImage = snapshot?.thumbnailImage ?? snapshot?.fullImage
    }

    private var progressDisplayTime: Double {
        isDragging ? dragProgress : playerVM.currentTime
    }

    private var progressFillColor: Color {
        controlPrimaryColor.opacity(0.9)
    }

    private var progressTrackColor: Color {
        lyricsDynamicSecondaryColor.opacity(0.32)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard playerVM.duration > 0 else { return 0 }
        let time = isDragging ? dragProgress : playerVM.currentTime
        let progress = time / playerVM.duration
        return totalWidth * CGFloat(max(0, min(1, progress)))
    }

    private var volumeView: some View {
        HStack(spacing: 10) {
            Image(systemName: volumeIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(controlPrimaryColor)
                .compositingGroup()
                .blendMode(.screen)
                .frame(width: 24)

            Slider(
                value: Binding(
                    get: { playerVM.volume },
                    set: { playerVM.setVolume($0) }
                ),
                in: 0...1
            )
            .controlSize(.regular)
            .tint(controlPrimaryColor)
            .compositingGroup()
            .blendMode(.screen)
        }
    }

    private var volumeIcon: String {
        if playerVM.volume == 0 {
            return "speaker.slash.fill"
        } else if playerVM.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if playerVM.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var lyricsDynamicPrimaryColor: Color {
        Color(nsColor: fullscreenThemeAccentColor).opacity(0.94)
    }

    private var lyricsDynamicSecondaryColor: Color {
        Color(nsColor: fullscreenThemeAccentColor).opacity(0.78)
    }

    private var controlPrimaryColor: Color {
        Self.resolveControlPrimaryColor(from: themeStore.accentNSColor)
    }

    private var controlDisabledColor: Color {
        Color.secondary.opacity(0.5)
    }

    private var fullscreenThemeAccentColor: NSColor {
        Self.resolveControlAccentColor(from: themeStore.accentNSColor)
    }

    // MARK: - HSL Color Helpers

    static func resolveControlAccentColor(from color: NSColor) -> NSColor {
        let saturated = enforceMinimumHslSaturation(
            color,
            minimumSaturation: fullscreenThemeMinSaturation
        )
        let lifted = enforceMinimumHslLightness(
            saturated,
            minimumLightness: fullscreenThemeMinLightness
        )
        return enforceMaximumHslLightness(
            lifted,
            maximumLightness: fullscreenThemeMaxLightness
        )
    }

    static func resolveControlPrimaryColor(from color: NSColor) -> Color {
        Color(nsColor: resolveControlAccentColor(from: color)).opacity(0.96)
    }

    private static func enforceMinimumHslLightness(_ color: NSColor, minimumLightness: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = max(hsl.l, minimumLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func enforceMaximumHslLightness(_ color: NSColor, maximumLightness: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = min(hsl.l, maximumLightness)
        if targetL >= hsl.l - 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func enforceMinimumHslSaturation(_ color: NSColor, minimumSaturation: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetS = max(hsl.s, minimumSaturation)
        if targetS <= hsl.s + 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: targetS, l: hsl.l)
    }

    private static func hslComponents(from color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }

        let r = clamp01(rgb.redComponent)
        let g = clamp01(rgb.greenComponent)
        let b = clamp01(rgb.blueComponent)

        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        let l = (maxV + minV) * 0.5

        var h: CGFloat = 0
        if delta > 0.000_001 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }

        var s: CGFloat = 0
        if delta > 0.000_001 {
            s = delta / (1 - abs(2 * l - 1))
        }

        return (h: h, s: s, l: l)
    }

    private static func rgbColorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))

        var rp: CGFloat = 0
        var gp: CGFloat = 0
        var bp: CGFloat = 0

        switch hPrime {
        case 0..<1:
            rp = c; gp = x; bp = 0
        case 1..<2:
            rp = x; gp = c; bp = 0
        case 2..<3:
            rp = 0; gp = c; bp = x
        case 3..<4:
            rp = 0; gp = x; bp = c
        case 4..<5:
            rp = x; gp = 0; bp = c
        default:
            rp = c; gp = 0; bp = x
        }

        let m = l - c * 0.5
        return NSColor(
            calibratedRed: clamp01(rp + m),
            green: clamp01(gp + m),
            blue: clamp01(bp + m),
            alpha: 1.0
        )
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, 0), 1)
    }
}

// MARK: - Preview

#Preview("Fullscreen Mini Player") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)

    let track = Track(
        title: "Blinding Lights",
        artist: "The Weeknd",
        album: "After Hours",
        duration: 203,
        fileBookmarkData: Data()
    )

    VStack {
        Spacer()
        FullscreenMiniPlayerView(
            glassStyle: FullscreenControlsGlassStyle(
                colorScheme: .dark,
                accentColor: ThemeStore.shared.accentColor,
                materialStyle: .clear
            ),
            playbackMode: .sequence,
            onPlaybackModeChange: { _ in },
            onCurrentPlaybackModeRetap: { _ in }
        )
            .environment(playerVM)
            .environmentObject(ThemeStore.shared)
            .padding(40)
    }
    .frame(width: 1400, height: 200)
    .background(Color.black.opacity(0.8))
    .onAppear {
        playerVM.playTracks([track])
    }
}

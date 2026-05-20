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
    private static let appleMusicArtworkCacheTrackID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000A2"
    )!

    // Scale factor for responsive sizing at different resolutions
    var scale: CGFloat = 1.0
    let glassStyle: FullscreenControlsGlassStyle
    let playbackMode: PlaybackOrderMode
    let onPlaybackModeChange: (PlaybackOrderMode) -> Void
    let onCurrentPlaybackModeRetap: (PlaybackOrderMode) -> Void
    var onInteraction: () -> Void = {}
    var onHoverStateChanged: (Bool) -> Void = { _ in }
    var onProgressDraggingChanged: (Bool) -> Void = { _ in }
    var onEditTrackRequested: (Track) -> Void = { _ in }
    var onEditExternalInfoRequested: () -> Void = {}
    
    private let fixedBarHeight: CGFloat = 60

    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
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
        let expandedWidth = playbackCoordinator.presentation.source.isExternal
            ? 160 * scale
            : playbackModeExpandedWidth
        return isPlaybackModeExpanded ? expandedWidth : playbackModeCollapsedWidth
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
            FullscreenMiniPlayerLeftSection(
                hasTrack: playbackCoordinator.presentation.hasTrack,
                isArtworkLoading: playbackCoordinator.presentation.isArtworkLoading,
                displayTitle: playbackCoordinator.presentation.title,
                displayArtist: playbackCoordinator.presentation.artist,
                emptyTitleKey: playbackCoordinator.presentation.emptyTitleKey,
                artworkImage: artworkImage,
                scale: scale,
                primaryColor: lyricsDynamicPrimaryColor,
                secondaryColor: lyricsDynamicSecondaryColor,
                onEditTrack: { track in
                    onInteraction()
                    onEditTrackRequested(track)
                },
                onEditExternalInfo: {
                    onInteraction()
                    onEditExternalInfoRequested()
                },
                onInteraction: onInteraction
            )
            .equatable()
            .frame(width: trackInfoWidth, alignment: .leading)
            .contentShape(Rectangle())

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

    private var controlsView: some View {
        let presentation = playbackCoordinator.presentation
        let isEnabled = presentation.isControlEnabled
        let isTrackControlEnabled = isEnabled && presentation.hasTrack
        return HStack(spacing: controlsHSpacing) {
            // Previous
            Button {
                onInteraction()
                previousSymbolEffectTrigger += 1
                playbackCoordinator.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(isTrackControlEnabled ? controlPrimaryColor : controlDisabledColor)
                    .compositingGroup()
                    .blendMode(isTrackControlEnabled ? controlBlendMode : .normal)
                    .symbolEffect(.wiggle, value: previousSymbolEffectTrigger)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.plain)
            .disabled(!isTrackControlEnabled)

            // Play/Pause
            Button {
                onInteraction()
                playPauseSymbolEffectTrigger += 1
                playbackCoordinator.playPause()
            } label: {
                Image(systemName: presentation.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: primaryIconSize, weight: .semibold))
                    .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                    .compositingGroup()
                    .blendMode(isEnabled ? controlBlendMode : .normal)
                    .symbolEffect(.bounce, value: playPauseSymbolEffectTrigger)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            // Next
            Button {
                onInteraction()
                nextSymbolEffectTrigger += 1
                playbackCoordinator.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(isTrackControlEnabled ? controlPrimaryColor : controlDisabledColor)
                    .compositingGroup()
                    .blendMode(isTrackControlEnabled ? controlBlendMode : .normal)
                    .symbolEffect(.wiggle, value: nextSymbolEffectTrigger)
                    .frame(width: controlSize, height: controlSize)
            }
            .buttonStyle(.plain)
            .disabled(!isTrackControlEnabled)
        }
    }

    private var playbackModeView: some View {
        let presentation = playbackCoordinator.presentation
        let isEnabled = presentation.isPlaybackModeControlEnabled && presentation.hasTrack
        return Group {
            switch presentation.source {
            case .local:
                PlaybackModeSlider(
                    mode: playbackMode,
                    isEnabled: isEnabled,
                    isExpanded: isPlaybackModeExpanded,
                    iconSize: 16 * scale,
                    selectedColor: controlPrimaryColor,
                    unselectedColor: controlPrimaryColor.opacity(0.62),
                    useScreenBlend: usesScreenBlendForControls,
                    pillTintColor: themeStore.accentColor,
                    pillTintBlendMode: .normal,
                    onInteraction: onInteraction,
                    scale: scale,
                    onModeChange: { mode in
                        playbackCoordinator.setPlaybackOrderMode(mode)
                        onPlaybackModeChange(mode)
                    },
                    onCurrentModeRetap: onCurrentPlaybackModeRetap
                )
            case .appleMusic, .systemNowPlaying:
                AppleMusicPlaybackModeSlider(
                    mode: presentation.appleMusicPlaybackMode ?? .sequence,
                    isEnabled: isEnabled,
                    isExpanded: isPlaybackModeExpanded,
                    iconSize: 16 * scale,
                    selectedColor: controlPrimaryColor,
                    unselectedColor: controlPrimaryColor.opacity(0.62),
                    useScreenBlend: usesScreenBlendForControls,
                    pillTintColor: themeStore.accentColor,
                    pillTintBlendMode: .normal,
                    onInteraction: onInteraction,
                    scale: scale,
                    onModeChange: { mode in
                        playbackCoordinator.setAppleMusicPlaybackMode(mode)
                    }
                )
            }
        }
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
            isPlaying: playbackCoordinator.presentation.isPlaying,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            foregroundColor: controlPrimaryColor,
            enforceBrightForeground: !usesAdaptiveClearForeground,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: usesDarkArtworkForegroundForClear,
            progress: progressDisplayTime,
            duration: playbackCoordinator.presentation.duration,
            isSeekEnabled: playbackCoordinator.presentation.isSeekEnabled,
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
                playbackCoordinator.seek(to: dragProgress)
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
        let presentation = playbackCoordinator.presentation
        let checksum = ArtworkAssetStore.checksum(for: presentation.artworkData)
        let identity = presentation.artworkIdentity
            ?? presentation.lyricsIdentity
            ?? presentation.localTrack?.id.uuidString
            ?? "none"
        return "\(identity)-\(checksum)"
    }
    
    private func loadArtworkThumbnail() async {
        let presentation = playbackCoordinator.presentation
        guard
            let artworkData = presentation.artworkData,
            !artworkData.isEmpty
        else {
            artworkImage = nil
            return
        }
        
        let snapshot = await ArtworkAssetStore.shared.snapshotMetadata(
            trackID: presentation.artworkDisplayTrackID
                ?? presentation.displayTrackID
                ?? presentation.localTrack?.id
                ?? Self.appleMusicArtworkCacheTrackID,
            artworkData: artworkData
        )
        guard !Task.isCancelled else { return }
        artworkImage = snapshot?.thumbnailImage ?? snapshot?.fullImage
    }

    private var progressDisplayTime: Double {
        isDragging ? dragProgress : playbackCoordinator.presentation.currentTime
    }

    private var progressFillColor: Color {
        controlPrimaryColor.opacity(0.9)
    }

    private var progressTrackColor: Color {
        lyricsDynamicSecondaryColor.opacity(0.32)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        let presentation = playbackCoordinator.presentation
        guard presentation.duration > 0 else { return 0 }
        let time = isDragging ? dragProgress : presentation.currentTime
        let progress = time / presentation.duration
        return totalWidth * CGFloat(max(0, min(1, progress)))
    }

    private var volumeView: some View {
        let isEnabled = playbackCoordinator.presentation.isVolumeControlEnabled
        return HStack(spacing: 10) {
            Image(systemName: volumeIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                .compositingGroup()
                .blendMode(isEnabled ? controlBlendMode : .normal)
                .frame(width: 24)

            Slider(
                value: Binding(
                    get: { playbackCoordinator.presentation.volume },
                    set: { playbackCoordinator.setVolume($0) }
                ),
                in: 0...1
            )
            .controlSize(.regular)
            .tint(controlPrimaryColor)
            .compositingGroup()
            .blendMode(isEnabled ? controlBlendMode : .normal)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
        }
    }

    private var volumeIcon: String {
        let volume = playbackCoordinator.presentation.volume
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var lyricsDynamicPrimaryColor: Color {
        controlPrimaryColor.opacity(0.94)
    }

    private var lyricsDynamicSecondaryColor: Color {
        controlPrimaryColor.opacity(0.78)
    }

    private var controlPrimaryColor: Color {
        Color(nsColor: controlPrimaryNSColor).opacity(0.96)
    }

    private var controlDisabledColor: Color {
        controlPrimaryColor.opacity(0.45)
    }

    private var controlPrimaryNSColor: NSColor {
        let palette = themeStore.semanticPalette
        if usesDarkArtworkForegroundForClear {
            // Surface is the artwork itself (Cover Gradient Blur "clear"
            // material AND the cover is bright enough that the stricter
            // dark-foreground gate fires). Use the readability profile so
            // we share the near-mono neutralisation with HomeHero and
            // other future on-artwork surfaces.
            return palette.readabilityProfile.foregroundPrimary
        }
        // Surface is the chrome material (darkened liquid-glass pill).
        // The Phase 4 MiniPlayerControl palette collapses to OKLCH
        // neutral white on near-mono covers, so the legacy "lift HSL
        // saturation to ≥0.88" path can no longer leak a pastel tint.
        return palette.miniPlayerControl.primary
    }

    private var usesAdaptiveClearForeground: Bool {
        settings.fullscreen.skinID == FullscreenSkinID.coverGradientBlur.rawValue
            && glassStyle.materialStyle == .clear
            && themeStore.hasArtworkThemeColor
    }

    private var usesDarkArtworkForegroundForClear: Bool {
        usesAdaptiveClearForeground
            && Self.shouldUseDarkArtworkForeground(for: themeStore.semanticPalette.analysis)
    }

    private var controlBlendMode: BlendMode {
        usesScreenBlendForControls ? .screen : .normal
    }

    private var usesScreenBlendForControls: Bool {
        !usesDarkArtworkForegroundForClear || ColorMath.relativeLuminance(of: controlPrimaryNSColor) >= 0.58
    }

    private var spectrumArtworkColors: [NSColor] {
        guard usesAdaptiveClearForeground else { return [] }
        let analysis = themeStore.semanticPalette.analysis
        // Phase 3: switch the spectrum source from raw topPalette to the
        // Phase-2 displayPalette. displayPalette is ordered
        // `top.first → salient → top.tail → rich`, so when an artwork has
        // a small-area but visually striking accent (5% bright yellow over
        // a 95% black canvas), that salient highlight naturally lands as
        // the second colour — which is exactly the "peak / high-band"
        // endpoint of the L→R gradient drawn across 9 capsules.
        let primary: [NSColor]
        if !analysis.displayPalette.isEmpty {
            primary = analysis.displayPalette
        } else if !analysis.topPalette.isEmpty {
            primary = analysis.topPalette
        } else {
            primary = [
                themeStore.semanticPalette.artBackgroundPrimary,
                themeStore.semanticPalette.artBackgroundSecondary,
            ]
        }
        let chosen = Array(primary.prefix(2))
        // Phase 3 hotfix: when the artwork is near-monochrome, the
        // displayPalette ordering still surfaces the salient highlight as
        // the second colour. That salient slot legitimately carries a
        // small-area but visibly hued micro-spot (e.g. a 3% pink reflection
        // on a black-and-white photograph). Letting it through unchanged
        // makes the spectrum read as "pink" even when the cover is
        // perceptually grey. Project to neutral via OKLCH chroma clamp so
        // the spectrum stays faithful to the grey impression. Low-but-not-
        // near-mono covers are preserved with a soft chroma shoulder so we
        // don't over-saturate; honest colour artworks pass through.
        let prepared = Self.prepareSpectrumColors(chosen, analysis: analysis)
        Self.logSpectrumColors(prepared, analysis: analysis)
        return prepared
    }

    nonisolated private static func prepareSpectrumColors(
        _ colors: [NSColor],
        analysis: ArtworkColorAnalysis
    ) -> [NSColor] {
        guard !colors.isEmpty else { return colors }
        if analysis.isNearMonochrome {
            return colors.map { neutralizeForNearMono($0) ?? $0 }
        }
        if analysis.colorfulness < 0.18 {
            return colors.map { dampenLowSaturation($0) ?? $0 }
        }
        return colors
    }

    /// Force a near-monochrome source to perceptual grey: preserve L,
    /// crush chroma to ~0 in OKLCH. Guarantees no visible hue tint
    /// regardless of which salient highlight the displayPalette surfaced.
    nonisolated private static func neutralizeForNearMono(_ color: NSColor) -> NSColor? {
        guard let lch = OKColor.nsColorToOKLCH(color) else { return nil }
        let neutral = OKColor.OKLCH(l: lch.l, c: min(lch.c, 0.008), h: lch.h)
        return OKColor.okLCHToNSColor(neutral, alpha: 1)
    }

    /// Soft-clamp chroma on low-saturation (but not near-mono) covers so
    /// downstream visibility tuning doesn't lift them above their natural
    /// muted impression.
    nonisolated private static func dampenLowSaturation(_ color: NSColor) -> NSColor? {
        guard let lch = OKColor.nsColorToOKLCH(color) else { return nil }
        let shouldered = OKColor.chromaSoftShoulder(lch, ceiling: 0.05, softness: 0.04)
        return OKColor.okLCHToNSColor(shouldered, alpha: 1)
    }

    private static func logSpectrumColors(
        _ colors: [NSColor],
        analysis: ArtworkColorAnalysis
    ) {
        guard LogConfig.isCategoryEnabled(.ui) else { return }
        let hexes = colors.compactMap { color -> String? in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
            return String(
                format: "#%02X%02X%02X",
                UInt8(min(max(rgb.redComponent, 0), 1) * 255),
                UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
                UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
            )
        }.joined(separator: " ")
        let salientHashes = Set(analysis.salientHighlightPalette.compactMap { color -> String? in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
            return String(
                format: "#%02X%02X%02X",
                UInt8(min(max(rgb.redComponent, 0), 1) * 255),
                UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
                UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
            )
        })
        let hasSalient = colors.contains { color in
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
            let hex = String(
                format: "#%02X%02X%02X",
                UInt8(min(max(rgb.redComponent, 0), 1) * 255),
                UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
                UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
            )
            return salientHashes.contains(hex)
        }
        Log.debug(
            "[Spectrum/palette] ultraDark=\(analysis.isUltraDark) nearMono=\(analysis.isNearMonochrome) hasSalient=\(hasSalient) colors=[\(hexes)]",
            category: .ui
        )
    }

    // MARK: - Stricter readability gate

    /// Stricter dark-foreground gate used by surfaces sitting on a blurred
    /// artwork (Cover Gradient Blur clear material). `analysis.usesDarkForeground`
    /// flips at HSL L≥0.58; over a blur we want a more conservative
    /// threshold so a moderately bright cover still keeps light text.
    /// Phase 4 keeps this in the view layer because the gate is specific
    /// to the over-blur surface — the rest of the readability semantic
    /// lives on `ArtworkReadabilityProfile`.
    static func shouldUseDarkArtworkForeground(for analysis: ArtworkColorAnalysis) -> Bool {
        guard analysis.usesDarkForeground else { return false }
        let averageLuma = ColorMath.relativeLuminance(of: analysis.averageColor)
        return analysis.avgHslLightness >= 0.68
            || averageLuma >= 0.58
            || (analysis.avgBrightness >= 0.82 && analysis.avgSaturation < 0.30)
    }
}

// MARK: - Left section (isolated from high-frequency presentation ticks)

private struct FullscreenMiniPlayerLeftSection: View, Equatable {

    let hasTrack: Bool
    let isArtworkLoading: Bool
    let displayTitle: String
    let displayArtist: String
    let emptyTitleKey: String
    let artworkImage: NSImage?
    let scale: CGFloat
    let primaryColor: Color
    let secondaryColor: Color

    let onEditTrack: (Track) -> Void
    let onEditExternalInfo: () -> Void
    let onInteraction: () -> Void

    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    // Layout derived from scale (mirrors FullscreenMiniPlayerView formulas)
    private var artworkSize: CGFloat { 60 * 0.73 * scale }
    private var artworkCornerRadius: CGFloat { 12 * scale }
    private var trackInfoHSpacing: CGFloat { 16 * scale }
    private var trackInfoVSpacing: CGFloat { 6 * scale }
    private var titleFontSize: CGFloat { 15 * scale }
    private var artistFontSize: CGFloat { 12.5 * scale }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasTrack == rhs.hasTrack
            && lhs.isArtworkLoading == rhs.isArtworkLoading
            && lhs.displayTitle == rhs.displayTitle
            && lhs.displayArtist == rhs.displayArtist
            && lhs.emptyTitleKey == rhs.emptyTitleKey
            && lhs.artworkImage === rhs.artworkImage
            && lhs.scale == rhs.scale
            && lhs.primaryColor == rhs.primaryColor
            && lhs.secondaryColor == rhs.secondaryColor
    }

    var body: some View {
        HStack(spacing: trackInfoHSpacing) {
            artworkView

            VStack(alignment: .leading, spacing: trackInfoVSpacing) {
                if hasTrack {
                    SeamlessMarqueeText(
                        text: displayTitle,
                        fontSize: titleFontSize,
                        fontWeight: .semibold,
                        color: primaryColor,
                        enablesContentTransition: true
                    )

                    SeamlessMarqueeText(
                        text: displayArtist.isEmpty
                            ? NSLocalizedString("library.unknown_artist", comment: "")
                            : displayArtist,
                        fontSize: artistFontSize,
                        fontWeight: .medium,
                        color: secondaryColor,
                        enablesContentTransition: true
                    )
                } else {
                    Text(LocalizedStringKey(emptyTitleKey))
                        .font(.system(size: titleFontSize, weight: .semibold))
                        .foregroundStyle(secondaryColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            // Closure is lazy — evaluated only when NSMenu appears, not during body computation.
            nowPlayingInfoContextMenu
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
        } else if isArtworkLoading {
            ZStack {
                ArtworkPlaceholderView.fullscreenMiniPlayer(artworkSize: 44, scale: scale)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.78 * scale)
            }
            .frame(width: artworkSize, height: artworkSize)
        } else {
            ArtworkPlaceholderView.fullscreenMiniPlayer(artworkSize: 44, scale: scale)
        }
    }

    @ViewBuilder
    private var nowPlayingInfoContextMenu: some View {
        let presentation = playbackCoordinator.presentation
        if let track = presentation.localTrack {
            TrackActionMenuContent(
                track: track,
                onPlay: {
                    onInteraction()
                    playbackCoordinator.play(track: track)
                },
                onEditTrack: { t in
                    onInteraction()
                    onEditTrack(t)
                },
                showsPlay: false,
                showsNavigation: false
            )
            if presentation.source.isExternal, presentation.externalStableKey != nil {
                Button {
                    onInteraction()
                    onEditExternalInfo()
                } label: {
                    Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
                }
            }
        } else if presentation.source.isExternal, presentation.externalStableKey != nil {
            Button {
                onInteraction()
                onEditExternalInfo()
            } label: {
                Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
            }
        }
    }
}

// MARK: - Preview

#Preview("Fullscreen Mini Player") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let libraryVM = LibraryViewModel(repository: StubLibraryRepository())
    let appleMusicAdapter = AppleMusicPlaybackAdapter(libraryVM: libraryVM)
    let playbackCoordinator = PlaybackCoordinator(
        playerVM: playerVM,
        appleMusicAdapter: appleMusicAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider(libraryVM: libraryVM)
    )

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
            .environment(playbackCoordinator)
            .environment(libraryVM)
            .environmentObject(ThemeStore.shared)
            .padding(40)
    }
    .frame(width: 1400, height: 200)
    .background(Color.black.opacity(0.8))
    .onAppear {
        playerVM.playTracks([track])
    }
}

#if DEBUG
/// Debug-only bridge exposing the Spectrum colour preparation step to
/// `ColorSystemSelfCheck`. Verifies the Phase 3 hotfix invariant that
/// near-monochrome cover inputs leave the spectrum source with effectively
/// zero chroma, and that low-saturation covers don't get amplified.
nonisolated enum SpectrumPaletteSelfCheck {
    nonisolated static func prepare(
        _ colors: [NSColor],
        analysis: ArtworkColorAnalysis
    ) -> [NSColor] {
        FullscreenMiniPlayerView._selfCheckPrepareSpectrum(colors, analysis: analysis)
    }
}

extension FullscreenMiniPlayerView {
    fileprivate nonisolated static func _selfCheckPrepareSpectrum(
        _ colors: [NSColor],
        analysis: ArtworkColorAnalysis
    ) -> [NSColor] {
        prepareSpectrumColors(colors, analysis: analysis)
    }
}
#endif

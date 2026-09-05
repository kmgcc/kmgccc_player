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

/// Shared content metrics for the fullscreen Mini Player. The outer pill owns
/// the animated container width; every section except progress has a stable
/// footprint, so progress is the single continuous compression/expansion zone.
/// Keeping these values in one type lets geometry self-checks detect future
/// changes that would make the content wider than an expanded pill.
nonisolated struct FullscreenMiniPlayerLayoutMetrics: Equatable, Sendable {
    let scale: CGFloat

    var trackInfoWidth: CGFloat { 196 * scale }
    var controlsWidth: CGFloat { 174 * scale }
    var playbackModeExpandedWidth: CGFloat { 178 * scale }
    var externalPlaybackModeExpandedWidth: CGFloat { 160 * scale }
    var playbackModeCollapsedWidth: CGFloat { 56 * scale }
    var preferredProgressAreaWidth: CGFloat { 320 * scale }
    var minimumProgressAreaWidth: CGFloat { 104 * scale }
    var sectionSpacing: CGFloat { 18 * scale }
    var horizontalPadding: CGFloat { 20 * scale }

    var maximumPlaybackModeWidth: CGFloat {
        max(playbackModeExpandedWidth, externalPlaybackModeExpandedWidth)
    }

    func availableProgressAreaWidth(
        containerWidth: CGFloat,
        playbackModeWidth: CGFloat
    ) -> CGFloat {
        max(
            0,
            containerWidth
                - horizontalPadding * 2
                - sectionSpacing * 3
                - trackInfoWidth
                - controlsWidth
                - playbackModeWidth
        )
    }
}

/// Enlarged mini player bar for fullscreen mode.
/// Layout: Cover+Title | Controls | Playback Mode | Progress | Volume
struct FullscreenMiniPlayerView: View {
    private static let appleMusicArtworkCacheTrackID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000A2"
    )!

    // Scale factor for responsive sizing at different resolutions
    var scale: CGFloat = 1.0
    var isSpectrumActive: Bool = true
    let glassStyle: FullscreenControlsGlassStyle
    let playbackMode: PlaybackOrderMode
    let onPlaybackModeChange: (PlaybackOrderMode) -> Void
    let onCurrentPlaybackModeRetap: (PlaybackOrderMode) -> Void
    var onInteraction: () -> Void = {}
    var onHoverStateChanged: (Bool) -> Void = { _ in }
    var onProgressDraggingChanged: (Bool) -> Void = { _ in }
    var onEditTrackRequested: (Track) -> Void = { _ in }
    var onEditExternalInfoRequested: () -> Void = {}
    var onShowDetailRequested: ((Track) -> Void)? = nil
    var foregroundProfile: FullscreenMiniPlayerForegroundProfile? = nil
    
    private let fixedBarHeight: CGFloat = 60

    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var artworkImage: NSImage?
    @State private var isPlaybackModeExpanded = false
    @State private var isMiniPlayerHovering = false
    @State private var trackDeletionRequest: TrackDeletionConfirmationRequest?

    // Computed properties based on settings and scale
    private var barHeight: CGFloat { fixedBarHeight * scale }
    private var layoutMetrics: FullscreenMiniPlayerLayoutMetrics {
        FullscreenMiniPlayerLayoutMetrics(scale: scale)
    }

    // Layout constants scaled
    private var trackInfoWidth: CGFloat { layoutMetrics.trackInfoWidth }
    private var controlsWidth: CGFloat { layoutMetrics.controlsWidth }
    private var playbackModeExpandedWidth: CGFloat { layoutMetrics.playbackModeExpandedWidth }
    private var playbackModeCollapsedWidth: CGFloat { layoutMetrics.playbackModeCollapsedWidth }
    private var playbackModeOccupancyWidth: CGFloat {
        let expandedWidth = playbackCoordinator.stablePresentation.source.isExternal
            ? layoutMetrics.externalPlaybackModeExpandedWidth
            : playbackModeExpandedWidth
        return isPlaybackModeExpanded ? expandedWidth : playbackModeCollapsedWidth
    }
    private var minimumProgressAreaWidth: CGFloat { layoutMetrics.minimumProgressAreaWidth }
    private var preferredProgressAreaWidth: CGFloat { layoutMetrics.preferredProgressAreaWidth }
    private var hStackSpacing: CGFloat { layoutMetrics.sectionSpacing }
    private var hPadding: CGFloat { layoutMetrics.horizontalPadding }
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
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.miniPlayerBodyUpdate",
            detail: "surface=FullscreenMiniPlayerView, track=\(FirstUseHitchDiagnostics.trackIDPrefix(playbackCoordinator.stablePresentation.localTrack?.id)), isPlaying=\(playbackCoordinator.stablePresentation.isPlaying)"
        )
#if DEBUG
        let _ = MiniPlayerFGDiagnostics.logIfChanged(
            trackID: playbackCoordinator.stablePresentation.localTrack?.id,
            skinID: settings.fullscreen.skinID,
            materialStyle: glassStyle.materialStyle,
            colorScheme: colorScheme,
            isPlaying: playbackCoordinator.stablePresentation.isPlaying,
            isHovering: isMiniPlayerHovering,
            isExpanded: isPlaybackModeExpanded,
            hasArtworkThemeColor: themeStore.hasArtworkThemeColor,
            artworkUsesDarkForeground: themeStore.semanticPalette.analysis.usesDarkForeground,
            profile: resolvedForegroundProfile
        )
#endif
        HStack(spacing: hStackSpacing) {
            // Left: Cover + Title/Artist
            FullscreenMiniPlayerLeftSection(
                hasTrack: playbackCoordinator.stablePresentation.hasTrack,
                isArtworkLoading: playbackCoordinator.stablePresentation.isArtworkLoading,
                displayTitle: playbackCoordinator.stablePresentation.title,
                displayArtist: playbackCoordinator.stablePresentation.artist,
                emptyTitleKey: playbackCoordinator.stablePresentation.emptyTitleKey,
                artworkImage: artworkImage,
                isPlaying: playbackCoordinator.stablePresentation.isPlaying,
                isRefetchingLyrics: playbackCoordinator.stablePresentation.isRefetchingLyrics,
                scale: scale,
                textForegroundProfile: miniPlayerTextForegroundProfile,
                placeholderColor: lyricsDynamicSecondaryColor,
                activityIndicatorColor: controlPrimaryColor,
                contextMenuRefreshTrigger: libraryVM.refreshTrigger,
                onEditTrack: { track in
                    onInteraction()
                    onEditTrackRequested(track)
                },
                onDeleteTrack: { track in
                    onInteraction()
                    trackDeletionRequest = TrackDeletionConfirmationRequest(tracks: [track])
                },
                onEditExternalInfo: {
                    onInteraction()
                    onEditExternalInfoRequested()
                },
                onShowDetails: onShowDetailRequested != nil ? { track in
                    onInteraction()
                    onShowDetailRequested?(track)
                } : nil,
                onInteraction: onInteraction
            )
            .equatable()
            .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
            .frame(width: trackInfoWidth, alignment: .leading)
            .contentShape(Rectangle())

            // Center: Playback Controls
            controlsView
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .frame(width: controlsWidth)

            // Playback Mode
            playbackModeView
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
                .frame(width: playbackModeOccupancyWidth, alignment: .leading)

            // The progress/spectrum row is the only flexible section. Its
            // proposal follows the outer pill's animated width on every frame,
            // while the fixed controls keep their positions and dimensions.
            FullscreenMiniPlayerLivePresentationReader { presentation in
                progressArea(presentation: presentation)
            }
                .frame(
                    minWidth: minimumProgressAreaWidth,
                    idealWidth: preferredProgressAreaWidth,
                    maxWidth: .infinity
                )
                .layoutPriority(-1)
                .frame(height: barHeight - vPadding * 2, alignment: .center)

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
        .animation(nil, value: resolvedForegroundProfile)
        .onHover { hovering in
            isMiniPlayerHovering = hovering
            onHoverStateChanged(hovering)
            if hovering {
                onInteraction()
            }
        }
        .trackDeletionConfirmation(item: $trackDeletionRequest) { tracks in
            Task {
                await libraryVM.deleteTracks(tracks)
            }
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkThumbnail()
        }
    }

    // MARK: - Subviews

    private var controlsView: some View {
        let presentation = playbackCoordinator.stablePresentation
        let isEnabled = presentation.isControlEnabled
        let isTrackControlEnabled = isEnabled && presentation.hasTrack
        let metrics = AnimatedMediaControlMetrics.fullscreenMiniPlayer(scale: scale)
        return HStack(spacing: controlsHSpacing) {
            // Previous
            AnimatedSkipButton(
                direction: .previous,
                enabled: isTrackControlEnabled,
                metrics: metrics,
                color: controlPrimaryColor,
                disabledColor: controlDisabledColor,
                blendMode: controlBlendMode,
                action: {
                    onInteraction()
                    playbackCoordinator.previous()
                }
            )

            // Play/Pause
            AnimatedPlayPauseButton(
                isPlaying: presentation.isPlaying,
                enabled: isEnabled,
                metrics: metrics,
                color: controlPrimaryColor,
                disabledColor: controlDisabledColor,
                blendMode: controlBlendMode,
                action: {
                    onInteraction()
                    playbackCoordinator.playPause()
                }
            )

            // Next
            AnimatedSkipButton(
                direction: .next,
                enabled: isTrackControlEnabled,
                metrics: metrics,
                color: controlPrimaryColor,
                disabledColor: controlDisabledColor,
                blendMode: controlBlendMode,
                action: {
                    onInteraction()
                    playbackCoordinator.next()
                }
            )
        }
    }

    private var playbackModeView: some View {
        let presentation = playbackCoordinator.stablePresentation
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
                    unselectedColor: controlSecondaryColor,
                    useScreenBlend: usesScreenBlendForControls,
                    pillTintColor: fullscreenControlPillTintColor,
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
                    unselectedColor: controlSecondaryColor,
                    useScreenBlend: usesScreenBlendForControls,
                    pillTintColor: fullscreenControlPillTintColor,
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
        .anchorPreference(
            key: PlaybackModeRetapTipAnchorPreferenceKey.self,
            value: .bounds
        ) { $0 }
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

    private func progressArea(presentation: NowPlayingPresentation) -> some View {
        MiniPlayerProgressSpectrumRow(
            scale: scale,
            visualization: settings.fullscreen.miniPlayerVisualization,
            isPlaying: presentation.isPlaying,
            isSpectrumActive: isSpectrumActive,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            foregroundColor: controlPrimaryColor,
            foregroundProfile: resolvedForegroundProfile,
            enforceBrightForeground: resolvedForegroundProfile.enforceBrightProgressForeground,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: resolvedForegroundProfile.spectrumUsesDarkForeground,
            ledToneVariant: settings.fullscreen.skinID == AppleStyleSkin.skinID
                ? .appleStyleBright
                : .miniPlayer,
            progress: progressDisplayTime(for: presentation),
            duration: presentation.duration,
            isSeekEnabled: presentation.isSeekEnabled,
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

    private var currentArtworkTaskKey: String {
        let presentation = playbackCoordinator.stablePresentation
        if let source = presentation.localTrack?.trackArtworkSource(fallbackData: presentation.artworkData) {
            return "local-\(source.sourceKey)-thumb"
        }
        let identity = presentation.artworkIdentity
            ?? presentation.lyricsIdentity
            ?? presentation.localTrack?.id.uuidString
            ?? "none"
        return "\(identity)-\(ArtworkDataFingerprint.sampledString(for: presentation.artworkData))"
    }
    
    private func loadArtworkThumbnail() async {
        let presentation = playbackCoordinator.stablePresentation
        if let source = presentation.localTrack?.trackArtworkSource(fallbackData: presentation.artworkData) {
            let image = await cacheServices.trackArtworkCache.thumbnail(for: source)
            guard !Task.isCancelled else { return }
            if let image {
                artworkImage = image
            } else if !presentation.isArtworkLoading {
                artworkImage = nil
            }
            return
        }

        guard
            let artworkData = presentation.artworkData,
            !artworkData.isEmpty
        else {
            if !presentation.hasTrack || !presentation.isArtworkLoading {
                artworkImage = nil
            }
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
        if let image = snapshot?.thumbnailImage ?? snapshot?.fullImage {
            artworkImage = image
        } else if !presentation.isArtworkLoading {
            artworkImage = nil
        }
    }

    private func progressDisplayTime(for presentation: NowPlayingPresentation) -> Double {
        isDragging ? dragProgress : presentation.currentTime
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
        let presentation = playbackCoordinator.stablePresentation
        let isEnabled = presentation.isVolumeControlEnabled
        return HStack(spacing: 10) {
            Image(systemName: volumeIcon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                .compositingGroup()
                .blendMode(isEnabled ? controlBlendMode : .normal)
                .frame(width: 24)

            Slider(
                value: Binding(
                    get: { presentation.volume },
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
        let volume = playbackCoordinator.stablePresentation.volume
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

    private var miniPlayerTextForegroundProfile: PlusBlendTextForegroundProfile {
        themeStore.plusBlendTextPalette.profile(
            for: resolvedForegroundProfile.isDarkForeground
                ? .darkOnLightBackground
                : .lightOnDarkBackground
        )
    }

    private var controlSecondaryColor: Color {
        resolvedForegroundProfile.secondaryColor.opacity(0.96)
    }

    private var controlPrimaryColor: Color {
        resolvedForegroundProfile.primaryColor.opacity(0.96)
    }

    private var controlDisabledColor: Color {
        controlPrimaryColor.opacity(0.45)
    }

    private var fullscreenControlPillTintColor: Color? {
        resolvedForegroundProfile.pillTintColor.opacity(0.96)
    }

    private var controlPrimaryNSColor: NSColor {
        resolvedForegroundProfile.primary
    }

    private var controlBlendMode: BlendMode {
        resolvedForegroundProfile.iconBlendMode
    }

    private var usesScreenBlendForControls: Bool {
        resolvedForegroundProfile.useScreenBlend
    }

    private var resolvedForegroundProfile: FullscreenMiniPlayerForegroundProfile {
        if let foregroundProfile {
            return foregroundProfile
        }
        return FullscreenMiniPlayerForegroundStrategy.resolve(
            palette: themeStore.semanticPalette,
            localArtworkPolarity: nil,
            hasArtworkThemeColor: themeStore.hasArtworkThemeColor,
            skinID: settings.fullscreen.skinID,
            colorScheme: colorScheme,
            materialStyle: glassStyle.materialStyle,
            fullscreenArtBackgroundEnabled: settings.fullscreenArtBackgroundEnabled
        )
    }

    private var spectrumArtworkColors: [NSColor] {
        guard resolvedForegroundProfile.role == .coverBlurDarkForeground
            || resolvedForegroundProfile.role == .coverBlurLightForeground
        else { return [] }
        let analysis = themeStore.semanticPalette.analysis
        // Use displayPalette rather than raw topPalette. displayPalette is
        // ordered `top.first → salient → top.tail → rich`, so when an artwork
        // has a small-area but visually striking accent (5% bright yellow over
        // a 95% black canvas), that salient highlight naturally lands as the
        // second colour: the "peak / high-band" endpoint of the L→R gradient.
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
        // When the artwork is near-monochrome, displayPalette ordering can
        // still surface a small-area hued micro-spot as the second colour.
        // Letting it through unchanged makes the spectrum read as "pink" even
        // when the cover is perceptually grey. Project to neutral via OKLCH
        // chroma clamp so the spectrum stays faithful to the grey impression.
        // Low-but-not-near-mono covers are preserved with a soft chroma shoulder so we
        // don't over-saturate; honest colour artworks pass through.
        let prepared = SpectrumColorResolver.prepareSpectrumColors(chosen, analysis: analysis)
        Self.logSpectrumColors(prepared, analysis: analysis)
        return prepared
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

    // The old `shouldUseDarkArtworkForeground` wrapper was removed: Cover Blur
    // foreground polarity is now resolved centrally by
    // `FullscreenMiniPlayerForegroundStrategy.resolve(localArtworkPolarity:)`
    // and passed down as a `foregroundProfile`. The volume control and other
    // surfaces consume that profile instead of re-reading `analysis` here.
}

// MARK: - Left section (isolated from high-frequency presentation ticks)

private struct FullscreenMiniPlayerLeftSection: View, Equatable {

    let hasTrack: Bool
    let isArtworkLoading: Bool
    let displayTitle: String
    let displayArtist: String
    let emptyTitleKey: String
    let artworkImage: NSImage?
    let isPlaying: Bool
    let isRefetchingLyrics: Bool
    let scale: CGFloat
    let textForegroundProfile: PlusBlendTextForegroundProfile
    let placeholderColor: Color
    let activityIndicatorColor: Color
    let contextMenuRefreshTrigger: Int

    let onEditTrack: (Track) -> Void
    let onDeleteTrack: (Track) -> Void
    let onEditExternalInfo: () -> Void
    let onShowDetails: ((Track) -> Void)?
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
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isRefetchingLyrics == rhs.isRefetchingLyrics
            && lhs.scale == rhs.scale
            && lhs.textForegroundProfile == rhs.textForegroundProfile
            && lhs.placeholderColor == rhs.placeholderColor
            && lhs.activityIndicatorColor == rhs.activityIndicatorColor
            && lhs.contextMenuRefreshTrigger == rhs.contextMenuRefreshTrigger
    }

    var body: some View {
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.miniPlayerBodyUpdate",
            detail: "surface=FullscreenMiniPlayerLeftSection"
        )
        HStack(spacing: trackInfoHSpacing) {
            artworkView

            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: trackInfoVSpacing) {
                    if hasTrack {
                        SeamlessMarqueeText(
                            text: displayTitle,
                            fontSize: titleFontSize,
                            fontWeight: .semibold,
                            color: textForegroundProfile.primaryColor,
                            shouldAnimate: isPlaying,
                            enablesContentTransition: true
                        )
                        .compositingGroup()
                        .blendMode(textForegroundProfile.blendMode)

                        SeamlessMarqueeText(
                            text: displayArtist.isEmpty
                                ? NSLocalizedString("library.unknown_artist", comment: "")
                                : displayArtist,
                            fontSize: artistFontSize,
                            fontWeight: .medium,
                            color: textForegroundProfile.secondaryColor,
                            shouldAnimate: isPlaying,
                            enablesContentTransition: true
                        )
                        .compositingGroup()
                        .blendMode(textForegroundProfile.blendMode)
                    } else {
                        Text(LocalizedStringKey(emptyTitleKey))
                            .font(.system(size: titleFontSize, weight: .semibold))
                            .foregroundStyle(placeholderColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, isRefetchingLyrics ? 20 * scale : 0)

                ProgressView()
                    .controlSize(.small)
                    .tint(activityIndicatorColor)
                    .foregroundStyle(activityIndicatorColor)
                    .frame(width: 12, height: 12)
                    .scaleEffect(scale)
                    .opacity(isRefetchingLyrics ? 1 : 0)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isRefetchingLyrics)
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
                    .tint(activityIndicatorColor)
                    .foregroundStyle(activityIndicatorColor)
                    .scaleEffect(0.78 * scale)
            }
            .frame(width: artworkSize, height: artworkSize)
        } else {
            ArtworkPlaceholderView.fullscreenMiniPlayer(artworkSize: 44, scale: scale)
        }
    }

    @ViewBuilder
    private var nowPlayingInfoContextMenu: some View {
        let token = ContextMenuDiagnostics.beginBuild(
            surface: "MiniPlayerContextMenu",
            detail: "surface=fullscreen, track=\(FirstUseHitchDiagnostics.trackIDPrefix(playbackCoordinator.stablePresentation.localTrack?.id))"
        )
        let _ = ContextMenuDiagnostics.end(token)
        let presentation = playbackCoordinator.stablePresentation
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
                onDeleteFromLibraryRequest: onDeleteTrack,
                onShowDetails: onShowDetails,
                showsPlay: false,
                showsNavigation: false,
                diagnosticSurface: "MiniPlayerContextMenu"
            )
            Divider()
            MiniPlayerRefetchLyricsButton(onAction: onInteraction)
            if presentation.source.isExternal, presentation.externalStableKey != nil {
                Button {
                    let actionToken = ContextMenuDiagnostics.beginActionInvoke(
                        surface: "MiniPlayerContextMenu",
                        detail: "action=editExternalInfo, surface=fullscreen"
                    )
                    onInteraction()
                    onEditExternalInfo()
                    ContextMenuDiagnostics.end(actionToken)
                } label: {
                    Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
                }
            }
        } else if presentation.source.isExternal, presentation.externalStableKey != nil {
            MiniPlayerRefetchLyricsButton(onAction: onInteraction)
            Divider()
            Button {
                let actionToken = ContextMenuDiagnostics.beginActionInvoke(
                    surface: "MiniPlayerContextMenu",
                    detail: "action=editExternalInfo, surface=fullscreen"
                )
                onInteraction()
                onEditExternalInfo()
                ContextMenuDiagnostics.end(actionToken)
            } label: {
                Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct FullscreenMiniPlayerLivePresentationReader<Content: View>: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    private let content: (NowPlayingPresentation) -> Content

    init(@ViewBuilder content: @escaping (NowPlayingPresentation) -> Content) {
        self.content = content
    }

    var body: some View {
        content(playbackCoordinator.presentation)
    }
}

// MARK: - MiniPlayer Foreground Diagnostics

#if DEBUG
private nonisolated enum MiniPlayerFGDiagnostics {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastSnapshotKey: String = ""

    static func logIfChanged(
        trackID: UUID?,
        skinID: String,
        materialStyle: LiquidGlassPillMaterialStyle,
        colorScheme: ColorScheme,
        isPlaying: Bool,
        isHovering: Bool,
        isExpanded: Bool,
        hasArtworkThemeColor: Bool,
        artworkUsesDarkForeground: Bool,
        profile: FullscreenMiniPlayerForegroundProfile
    ) {
        guard LogConfig.miniPlayerFGDebugEnabled else { return }

        let trackIDString = trackID?.uuidString ?? "none"
        let primaryHex = hexString(for: profile.primary)
        let secondaryHex = hexString(for: profile.secondary)
        let disabledHex = hexString(for: profile.disabled)
        let snapshotKey = [
            trackIDString,
            skinID,
            "\(materialStyle)",
            "\(colorScheme)",
            "\(isPlaying)",
            "\(isHovering)",
            "\(isExpanded)",
            "\(hasArtworkThemeColor)",
            "\(artworkUsesDarkForeground)",
            profile.role.rawValue,
            primaryHex,
            secondaryHex,
            disabledHex,
            "\(profile.iconBlendMode)",
            "\(profile.useScreenBlend)",
            "\(profile.enforceBrightProgressForeground)",
            "\(profile.spectrumUsesDarkForeground)",
        ].joined(separator: "|")

        lock.lock()
        defer { lock.unlock() }
        guard snapshotKey != lastSnapshotKey else { return }
        lastSnapshotKey = snapshotKey

        Log.miniPlayerFG(
            "[MiniPlayerFG] trackID=\(trackIDString) skin=\(skinID) material=\(materialStyle) colorScheme=\(colorScheme) isPlaying=\(isPlaying) isHovering=\(isHovering) orderExpanded=\(isExpanded) artworkTheme=\(hasArtworkThemeColor) artworkUsesDarkFG=\(artworkUsesDarkForeground) role=\(profile.role.rawValue) primary=\(primaryHex) secondary=\(secondaryHex) disabled=\(disabledHex) blend=\(profile.iconBlendMode) screenBlend=\(profile.useScreenBlend) progressEnforceBright=\(profile.enforceBrightProgressForeground) spectrumDarkFG=\(profile.spectrumUsesDarkForeground) sources=title:profile.primary artist:profile.primary.opacity controls:profile.primary order:profile.primary/profile.secondary progress:profile.primary spectrum:profile.primary+artwork volume:profile.primary leftButtons:profile.primary"
        )
    }

    private static func hexString(for color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "unknown" }
        return String(
            format: "#%02X%02X%02X",
            UInt8(min(max(rgb.redComponent, 0), 1) * 255),
            UInt8(min(max(rgb.greenComponent, 0), 1) * 255),
            UInt8(min(max(rgb.blueComponent, 0), 1) * 255)
        )
    }
}
#endif

// MARK: - Preview

#Preview("Fullscreen Mini Player") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let libraryVM = LibraryViewModel.preview(repository: StubLibraryRepository())
    let cacheServices = LibraryCacheServices.preview
    let appleMusicAdapter = AppleMusicPlaybackAdapter(previewLibraryTracksProvider: { [weak libraryVM] in libraryVM?.allTracks ?? [] })
    let playbackCoordinator = PlaybackCoordinator(
        localPlayback: playerVM,
        appleMusicAdapter: appleMusicAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider(previewLibraryTracksProvider: { [weak libraryVM] in libraryVM?.allTracks ?? [] }),
        artworkCache: cacheServices.trackArtworkCache,
        lyricsSearchCoordinator: cacheServices.lyricsSearchCoordinator,
        amllDBService: cacheServices.amllDBService
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
            .environment(cacheServices)
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
/// `ColorSystemSelfCheck`. Verifies the invariant that near-monochrome cover
/// inputs leave the spectrum source with effectively
/// zero chroma, and that low-saturation covers don't get amplified.
nonisolated enum SpectrumPaletteSelfCheck {
    nonisolated static func prepare(
        _ colors: [NSColor],
        analysis: ArtworkColorAnalysis
    ) -> [NSColor] {
        SpectrumColorResolver.prepareSpectrumColors(colors, analysis: analysis)
    }
}
#endif

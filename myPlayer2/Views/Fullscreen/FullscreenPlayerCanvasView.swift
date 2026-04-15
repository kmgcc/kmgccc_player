//
//  FullscreenPlayerCanvasView.swift
//  myPlayer2
//

import SwiftUI

struct FullscreenPlayerCanvasView: View {
    let proxySize: CGSize
    let selectedSkin: any FullscreenSkin
    let skinUsesCustomBackground: Bool
    let effectiveDimmingIntensity: Double
    let isFullscreenArtBackgroundActive: Bool
    let currentTrack: Track?
    let isPlaying: Bool
    let currentTrackID: UUID?
    let currentQueueTracks: [Track]
    let playbackMode: PlaybackOrderMode
    let glassStyle: FullscreenControlsGlassStyle
    let usesBrightTextPalette: Bool
    let fullscreenStore: LyricsWebViewStore
    let coverBlurHighlightStore: LyricsWebViewStore
    let bkController: BKArtBackgroundController
    let bottomControlsController: FullscreenBottomControlsController
    let baseCanvasSize: CGSize
    let topContentHorizontalPadding: CGFloat
    let topContentLeftShift: CGFloat
    let artworkLyricsColumnSpacing: CGFloat
    let lyricsColumnLeftNudge: CGFloat
    let lyricsRightMarginReserve: CGFloat
    let lyricsViewportTopLift: CGFloat
    let coverSkinLyricsRightShift: CGFloat
    let bottomControlsAnimation: Animation
    let coverDropAnimation: Animation
    let isCoverBlurFullscreenSkin: Bool
    let shouldRenderCoverBlurHighlightOverlay: Bool
    let coverBlurBaseBlendMode: BlendMode
    let coverBlurHighlightBlendMode: BlendMode
    let keepLyricsHostMounted: Bool
    let isShowingLyricsPanel: Bool
    let isShowingQueuePanel: Bool
    let hostOpacity: Double
    let isHostVisible: Bool
    let viewportOpacity: Double
    let volume: Binding<Double>
    let primaryColor: Color
    let controlsColorScheme: ColorScheme
    let effectiveAppearance: AppSettings.ManualAppearance
    let artworkScale: CGFloat
    let canToggleLyrics: Bool
    let autoHideSeconds: Double
    let shouldKeepControlsVisible: Bool
    let makeSkinContext: (_ artworkColumnWidth: CGFloat, _ fullscreenScale: CGFloat) -> SkinContext
    let onScaleChange: (CGFloat) -> Void
    let onExitFullscreen: () -> Void
    let onToggleLyrics: () -> Void
    let onCycleAppearance: () -> Void
    let onPlaybackModeChange: (PlaybackOrderMode) -> Void
    let onCurrentPlaybackModeRetap: (PlaybackOrderMode) -> Void
    let onQueueTrackTap: (Track) -> Void
    let onDismissQueue: () -> Void

    private var isShowingRightPanel: Bool {
        isShowingLyricsPanel || isShowingQueuePanel
    }

    var body: some View {
        let scaleX = proxySize.width / baseCanvasSize.width
        let scaleY = proxySize.height / baseCanvasSize.height
        let scale = min(scaleX, scaleY)

        ZStack {
            backgroundLayer

            FullscreenLyricsLayerView(
                scale: scale,
                screenWidth: proxySize.width,
                baseCanvasSize: baseCanvasSize,
                artworkColumnWidth: layoutMetrics(showLyricsColumn: true).artworkWidth,
                topContentLeftShift: topContentLeftShift,
                artworkLyricsColumnSpacing: artworkLyricsColumnSpacing,
                lyricsColumnLeftNudge: lyricsColumnLeftNudge,
                coverSkinLyricsRightShift: coverSkinLyricsRightShift,
                lyricsViewportTopLift: lyricsViewportTopLift,
                bottomControlsBottomPadding: FullscreenBottomControlsMetrics.bottomPadding,
                bottomControlsVisible: bottomControlsController.isVisible,
                bottomControlsAnimation: bottomControlsAnimation,
                isCoverBlurFullscreenSkin: isCoverBlurFullscreenSkin,
                shouldRenderCoverBlurHighlightOverlay: shouldRenderCoverBlurHighlightOverlay,
                coverBlurBaseBlendMode: coverBlurBaseBlendMode,
                coverBlurHighlightBlendMode: coverBlurHighlightBlendMode,
                keepLyricsHostMounted: keepLyricsHostMounted,
                isShowingLyricsPanel: isShowingLyricsPanel,
                isShowingQueuePanel: isShowingQueuePanel,
                hostOpacity: hostOpacity,
                isHostVisible: isHostVisible,
                viewportOpacity: viewportOpacity,
                currentQueueTracks: currentQueueTracks,
                currentTrackID: currentTrackID,
                playbackMode: playbackMode,
                glassStyle: glassStyle,
                usesBrightTextPalette: usesBrightTextPalette,
                fullscreenStore: fullscreenStore,
                coverBlurHighlightStore: coverBlurHighlightStore,
                onQueueTrackTap: onQueueTrackTap,
                onDismissQueue: onDismissQueue
            )
            .frame(width: proxySize.width, height: proxySize.height)

            scaledArtworkContainer(scale: scale, screenWidth: proxySize.width)
                .frame(width: baseCanvasSize.width, height: baseCanvasSize.height)
                .scaleEffect(scale, anchor: .center)

            FullscreenBottomControlsView(
                controller: bottomControlsController,
                scale: scale,
                screenHeight: proxySize.height,
                glassStyle: glassStyle,
                playbackMode: playbackMode,
                volume: volume,
                primaryColor: primaryColor,
                controlsColorScheme: controlsColorScheme,
                effectiveAppearance: effectiveAppearance,
                isLyricsVisible: isShowingLyricsPanel,
                canToggleLyrics: canToggleLyrics,
                autoHideSeconds: autoHideSeconds,
                shouldKeepVisible: shouldKeepControlsVisible,
                animation: bottomControlsAnimation,
                onExitFullscreen: onExitFullscreen,
                onToggleLyrics: onToggleLyrics,
                onCycleAppearance: onCycleAppearance,
                onPlaybackModeChange: onPlaybackModeChange,
                onCurrentPlaybackModeRetap: onCurrentPlaybackModeRetap
            )
            .frame(width: proxySize.width, height: proxySize.height)
        }
        .frame(width: proxySize.width, height: proxySize.height)
        .onAppear {
            onScaleChange(scale)
        }
        .onChange(of: scale) { _, newScale in
            onScaleChange(newScale)
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if skinUsesCustomBackground {
            selectedSkin.makeBackground(
                context: makeSkinContext(layoutMetrics(showLyricsColumn: isShowingRightPanel).artworkWidth, 1.0)
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            Color.black.opacity(effectiveDimmingIntensity * 0.7)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else if isFullscreenArtBackgroundActive {
            BKArtBackgroundView(
                controller: bkController,
                trackID: currentTrackID,
                artworkData: currentTrack?.artworkData,
                isPlaying: isPlaying,
                avoidanceRect: nil,
                resourceProfile: selectedSkin.artBackgroundResourceProfile,
                dotRenderStyle: .solidCircles
            )
            .ignoresSafeArea()

            Color.black.opacity(effectiveDimmingIntensity)
                .ignoresSafeArea()
        } else {
            selectedSkin.makeBackground(
                context: makeSkinContext(layoutMetrics(showLyricsColumn: isShowingRightPanel).artworkWidth, 1.0)
            )
            .ignoresSafeArea()

            Color.black.opacity(effectiveDimmingIntensity * 0.7)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func scaledArtworkContainer(scale: CGFloat, screenWidth: CGFloat) -> some View {
        let coverDropY: CGFloat =
            selectedSkin.hasMiniPlayerMotion && !bottomControlsController.isVisible ? 20 : 0

        ZStack {
            VStack(spacing: 0) {
                artworkArea(scale: scale, screenWidth: screenWidth)
                    .padding(.horizontal, topContentHorizontalPadding)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .offset(y: coverDropY)
                    .animation(coverDropAnimation, value: bottomControlsController.isVisible)

                Spacer(
                    minLength:
                        FullscreenBottomControlsMetrics.bottomPadding
                        + FullscreenBottomControlsMetrics.buttonSize
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func artworkArea(scale: CGFloat, screenWidth: CGFloat) -> some View {
        let metrics = layoutMetrics(showLyricsColumn: isShowingRightPanel)
        let rightPanelVisible = isShowingRightPanel
        let artworkToCenterOffset = max(0, (baseCanvasSize.width - metrics.artworkWidth) * 0.5)
        let contentOffsetX: CGFloat = rightPanelVisible ? -topContentLeftShift : artworkToCenterOffset

        let scaleX = screenWidth / baseCanvasSize.width
        let artworkColumnCenterX = contentOffsetX + metrics.artworkWidth / 2
        let artworkHorizCorrection: CGFloat = rightPanelVisible
            ? (artworkColumnCenterX - baseCanvasSize.width / 2) * (scaleX - scale) / scale
            : 0
        let adjustedContentOffsetX = contentOffsetX + artworkHorizCorrection

        skinArtworkArea(artworkColumnWidth: metrics.artworkWidth, scale: scale)
            .frame(width: metrics.artworkWidth)
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .offset(x: adjustedContentOffsetX)
    }

    @ViewBuilder
    private func skinArtworkArea(artworkColumnWidth: CGFloat, scale: CGFloat) -> some View {
        let context = makeSkinContext(artworkColumnWidth, scale)

        ZStack {
            selectedSkin.makeArtwork(context: context)
                .scaleEffect(artworkScale)

            if let overlay = selectedSkin.makeOverlay(context: context) {
                overlay
                    .scaleEffect(artworkScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func layoutMetrics(showLyricsColumn: Bool) -> (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        let availableWidth = max(0, baseCanvasSize.width - topContentHorizontalPadding * 2)

        if showLyricsColumn {
            let constrainedWidth = max(0, availableWidth - lyricsRightMarginReserve)
            let lyricsWidth = min(max(constrainedWidth * 0.30, 320), 560)
            let artworkWidth = max(constrainedWidth - lyricsWidth - artworkLyricsColumnSpacing, 360)
            return (artworkWidth, lyricsWidth)
        }

        let lyricsWidth = min(max(availableWidth * 0.35, 340), 580)
        let centeredArtworkWidth = min(max(availableWidth * 0.78, 420), availableWidth)
        return (centeredArtworkWidth, lyricsWidth)
    }
}

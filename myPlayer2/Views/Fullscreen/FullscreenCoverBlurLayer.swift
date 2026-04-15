//
//  FullscreenCoverBlurLayer.swift
//  myPlayer2
//

import SwiftUI

struct FullscreenLyricsLayerView: View {
    let scale: CGFloat
    let screenWidth: CGFloat
    let baseCanvasSize: CGSize
    let artworkColumnWidth: CGFloat
    let topContentLeftShift: CGFloat
    let artworkLyricsColumnSpacing: CGFloat
    let lyricsColumnLeftNudge: CGFloat
    let coverSkinLyricsRightShift: CGFloat
    let lyricsViewportTopLift: CGFloat
    let bottomControlsBottomPadding: CGFloat
    let bottomControlsVisible: Bool
    let bottomControlsAnimation: Animation
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
    let currentQueueTracks: [Track]
    let currentTrackID: UUID?
    let playbackMode: PlaybackOrderMode
    let glassStyle: FullscreenControlsGlassStyle
    let usesBrightTextPalette: Bool
    let fullscreenStore: LyricsWebViewStore
    let coverBlurHighlightStore: LyricsWebViewStore
    let onQueueTrackTap: (Track) -> Void
    let onDismissQueue: () -> Void

    var body: some View {
        let scaleX = screenWidth / baseCanvasSize.width
        let hostBaseContentOffsetX: CGFloat = -topContentLeftShift
        let hostArtworkColumnCenterX = hostBaseContentOffsetX + artworkColumnWidth / 2
        let hostArtworkHorizCorrection =
            (hostArtworkColumnCenterX - baseCanvasSize.width / 2) * (scaleX - scale) / scale
        let hostArtworkX = hostBaseContentOffsetX + hostArtworkHorizCorrection
        let baseLyricsX =
            hostArtworkX + artworkColumnWidth + artworkLyricsColumnSpacing - lyricsColumnLeftNudge

        let leftExpansion: CGFloat = 80
        let coverSkinOffset: CGFloat = isCoverBlurFullscreenSkin ? coverSkinLyricsRightShift : 0
        let finalLyricsX = baseLyricsX - leftExpansion + coverSkinOffset

        let canvasCenteringX = max(0, (screenWidth - baseCanvasSize.width * scale) / 2)
        let visibleLyricsX = finalLyricsX * scale + canvasCenteringX
        let hiddenLyricsX = visibleLyricsX + 92 * scale
        let actualLyricsX = isShowingLyricsPanel ? visibleLyricsX : hiddenLyricsX

        let lyricsRightScreenPad: CGFloat = 44 * scale
        let actualLyricsWidth = max(100, screenWidth - visibleLyricsX - lyricsRightScreenPad)
        let actualLyricsHeight = baseCanvasSize.height * scale
        let visibleBottomReserve: CGFloat = bottomControlsVisible ? bottomControlsBottomPadding : 0
        let visibleClipHeight = (baseCanvasSize.height - visibleBottomReserve) * scale

        ZStack(alignment: .topLeading) {
            if keepLyricsHostMounted {
                fullscreenLyricsCrispView(visibleClipHeight: visibleClipHeight)
                    .frame(width: actualLyricsWidth, height: actualLyricsHeight, alignment: .topLeading)
                    .offset(x: actualLyricsX)
                    .opacity(hostOpacity)
                    .allowsHitTesting(isHostVisible)
                    .accessibilityHidden(!isHostVisible)
            }

            if isShowingQueuePanel {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onDismissQueue()
                        }

                    FullscreenQueueView(
                        tracks: currentQueueTracks,
                        currentTrackID: currentTrackID,
                        playbackMode: playbackMode,
                        glassStyle: glassStyle,
                        usesBrightTextPalette: usesBrightTextPalette,
                        scale: scale,
                        visibleHeight: visibleClipHeight,
                        onTrackTap: { track in
                            onQueueTrackTap(track)
                        }
                    )
                    .padding(.trailing, 118 * scale)
                    .padding(.top, 72 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
                .accessibilityHidden(false)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 92 * scale)),
                        removal: .opacity.combined(with: .offset(x: 92 * scale))
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(bottomControlsAnimation, value: bottomControlsVisible)
    }

    @ViewBuilder
    private func fullscreenLyricsCrispView(visibleClipHeight: CGFloat) -> some View {
        GeometryReader { proxy in
            let topFade: CGFloat = 58 * scale
            let baseBottomFadeVisible: CGFloat = 60
            let baseBottomFadeHidden: CGFloat = 380
            let bottomFade = (bottomControlsVisible ? baseBottomFadeVisible : baseBottomFadeHidden) * scale
            let horizontalInset: CGFloat = 10 * scale
            let expandedHeight = proxy.size.height + topFade + 420 * scale + 6 * scale

            ZStack {
                let webViewWidth = max(0, proxy.size.width - horizontalInset * 2)

                if shouldRenderCoverBlurHighlightOverlay {
                    fullscreenMaskedLyricsSurface(
                        width: webViewWidth,
                        height: expandedHeight,
                        visibleHeight: visibleClipHeight,
                        topFade: topFade,
                        bottomFade: bottomFade,
                        blendMode: coverBlurBaseBlendMode,
                        useCompositingGroup: false
                    ) {
                        AMLLWebView(
                            store: fullscreenStore,
                            forcedAppearanceMode: .dark
                        )
                    }

                    fullscreenMaskedLyricsSurface(
                        width: webViewWidth,
                        height: expandedHeight,
                        visibleHeight: visibleClipHeight,
                        topFade: topFade,
                        bottomFade: bottomFade,
                        blendMode: coverBlurHighlightBlendMode,
                        useCompositingGroup: false
                    ) {
                        AMLLWebView(
                            store: coverBlurHighlightStore,
                            forcedAppearanceMode: .dark
                        )
                    }
                    .allowsHitTesting(false)
                } else {
                    fullscreenMaskedLyricsSurface(
                        width: webViewWidth,
                        height: expandedHeight,
                        visibleHeight: visibleClipHeight,
                        topFade: topFade,
                        bottomFade: bottomFade,
                        blendMode: isCoverBlurFullscreenSkin ? coverBlurBaseBlendMode : .normal,
                        useCompositingGroup: !isCoverBlurFullscreenSkin
                    ) {
                        AMLLWebView(store: fullscreenStore, forcedAppearanceMode: .dark)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scaleEffect(y: bottomControlsVisible ? 0.97 : 1.0, anchor: .top)
            .animation(bottomControlsAnimation, value: bottomControlsVisible)
        }
    }

    @ViewBuilder
    private func fullscreenMaskedLyricsSurface<Content: View>(
        width: CGFloat,
        height: CGFloat,
        visibleHeight: CGFloat,
        topFade: CGFloat,
        bottomFade: CGFloat,
        blendMode: BlendMode,
        useCompositingGroup: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let maskedContent = content()
            .frame(width: width, height: height)
            .offset(y: -lyricsViewportTopLift * scale)
            .opacity(viewportOpacity)
            .environment(\.colorScheme, .dark)
            .mask(
                ZStack(alignment: .top) {
                    fullscreenLyricsMask(
                        visibleHeight: visibleHeight,
                        topFade: topFade,
                        bottomFade: bottomFade
                    )
                }
                .frame(height: height, alignment: .top)
                .offset(y: (bottomControlsVisible ? 42 : 58) * scale)
            )

        if useCompositingGroup {
            maskedContent
                .compositingGroup()
                .blendMode(blendMode)
        } else {
            maskedContent
                .blendMode(blendMode)
        }
    }

    private func fullscreenLyricsMask(
        visibleHeight: CGFloat,
        topFade: CGFloat,
        bottomFade: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: topFade)

            Rectangle()
                .fill(.black)
                .frame(height: max(0, visibleHeight - topFade - bottomFade))

            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottomFade)
        }
    }
}

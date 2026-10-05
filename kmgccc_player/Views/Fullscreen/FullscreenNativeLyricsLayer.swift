import MotionKit
import SwiftUI

struct FullscreenNativeLyricsLayoutSnapshot {
    let scale: CGFloat
    let screenWidth: CGFloat
    let hostLayout: FullscreenHorizontalSplitLayout
    let coverBlurLegacyArtworkWidth: CGFloat
    let coverBlurLegacyLyricsWidth: CGFloat
}

struct FullscreenNativeLyricsPresentationSnapshot {
    let usesCoverBlurBackdrop: Bool
    let isShowingLyricsPanel: Bool
    let isShowingRightPanel: Bool
    let isShowingQueuePanel: Bool
    let shouldKeepFullscreenLyricsHostMounted: Bool
    let fullscreenLyricsHostOpacity: Double
    let isFullscreenLyricsHostVisible: Bool
    let fullscreenLyricsViewportOpacity: Double
    let isFullscreenBottomControlsVisible: Bool
    let fullscreenControlsBottomPadding: CGFloat
    let lyricsViewportTopLift: CGFloat
    let lyricsViewportTopCropDown: CGFloat
    let usesCoverBlurLyricsRenderingPath: Bool
    let coverBlurBaseBlendMode: BlendMode
}

struct FullscreenNativeLyricsQueueSnapshot {
    let tracks: [Track]
    let currentTrackID: UUID?
    let playbackMode: PlaybackOrderMode
    let glassStyle: FullscreenControlsGlassStyle
    let foregroundProfile: FullscreenOverlayForegroundProfile
}

struct FullscreenNativeLyricsActions {
    let showLyrics: () -> Void
    let queueTrackTap: (Track) -> Void
}

@MainActor
struct FullscreenNativeLyricsLayer: View {
    static let baseCanvasWidth: CGFloat = 1470
    static let baseCanvasHeight: CGFloat = 923
    private let coverBlurLegacyTopContentLeftShift: CGFloat = 44
    private let coverBlurLegacyArtworkLyricsColumnSpacing: CGFloat = -58
    private let coverBlurLegacyLyricsColumnLeftNudge: CGFloat = 80
    private let coverBlurLegacyLyricsRightShift: CGFloat = 30
    private let coverBlurLegacyLeftExpansion: CGFloat = 80

    let layout: FullscreenNativeLyricsLayoutSnapshot
    let presentation: FullscreenNativeLyricsPresentationSnapshot
    let queue: FullscreenNativeLyricsQueueSnapshot
    let actions: FullscreenNativeLyricsActions

    // The snapshots keep the view's construction contract small while these
    // names keep the established mask and queue geometry easy to compare.
    private var scale: CGFloat { layout.scale }
    private var screenWidth: CGFloat { layout.screenWidth }
    private var hostLayout: FullscreenHorizontalSplitLayout { layout.hostLayout }
    private var coverBlurLegacyArtworkWidth: CGFloat { layout.coverBlurLegacyArtworkWidth }
    private var coverBlurLegacyLyricsWidth: CGFloat { layout.coverBlurLegacyLyricsWidth }
    private var usesCoverBlurBackdrop: Bool { presentation.usesCoverBlurBackdrop }
    private var isShowingLyricsPanel: Bool { presentation.isShowingLyricsPanel }
    private var isShowingRightPanel: Bool { presentation.isShowingRightPanel }
    private var isShowingQueuePanel: Bool { presentation.isShowingQueuePanel }
    private var shouldKeepFullscreenLyricsHostMounted: Bool { presentation.shouldKeepFullscreenLyricsHostMounted }
    private var fullscreenLyricsHostOpacity: Double { presentation.fullscreenLyricsHostOpacity }
    private var isFullscreenLyricsHostVisible: Bool { presentation.isFullscreenLyricsHostVisible }
    private var fullscreenLyricsViewportOpacity: Double { presentation.fullscreenLyricsViewportOpacity }
    private var isFullscreenBottomControlsVisible: Bool { presentation.isFullscreenBottomControlsVisible }
    private var fullscreenControlsBottomPadding: CGFloat { presentation.fullscreenControlsBottomPadding }
    private var lyricsViewportTopLift: CGFloat { presentation.lyricsViewportTopLift }
    private var lyricsViewportTopCropDown: CGFloat { presentation.lyricsViewportTopCropDown }
    private var usesCoverBlurLyricsRenderingPath: Bool { presentation.usesCoverBlurLyricsRenderingPath }
    private var coverBlurBaseBlendMode: BlendMode { presentation.coverBlurBaseBlendMode }
    private var queueTracks: [Track] { queue.tracks }
    private var currentQueueTrackID: UUID? { queue.currentTrackID }
    private var currentPlaybackMode: PlaybackOrderMode { queue.playbackMode }
    private var fullscreenQueueGlassStyle: FullscreenControlsGlassStyle { queue.glassStyle }
    private var fullscreenQueueForegroundProfile: FullscreenOverlayForegroundProfile { queue.foregroundProfile }
    private var onShowLyrics: () -> Void { actions.showLyrics }
    private var onQueueTrackTap: (Track) -> Void { actions.queueTrackTap }

    var body: some View {
        fullscreenLyricsLayer(scale: scale, screenWidth: screenWidth)
    }

    private func fullscreenLyricsLayer(scale: CGFloat, screenWidth: CGFloat) -> some View {
        let hostLayout = self.hostLayout
        let lyricsPanelVisible = isShowingLyricsPanel
        let keepLyricsHostMounted = shouldKeepFullscreenLyricsHostMounted

        let baseLyricsLeadingX: CGFloat
        let minReadableLyricsWidth: CGFloat
        if usesCoverBlurBackdrop {
            let legacyLayout = (artworkWidth: coverBlurLegacyArtworkWidth, lyricsWidth: coverBlurLegacyLyricsWidth)
            let scaleX = screenWidth / Self.baseCanvasWidth
            let hostBaseContentOffsetX = -coverBlurLegacyTopContentLeftShift
            let hostArtworkColumnCenterX = hostBaseContentOffsetX + legacyLayout.artworkWidth / 2
            let hostArtworkHorizCorrection: CGFloat
            if scale.isFinite, scale > .leastNonzeroMagnitude, scaleX.isFinite {
                hostArtworkHorizCorrection =
                    (hostArtworkColumnCenterX - Self.baseCanvasWidth / 2) * (scaleX - scale) / scale
            } else {
                hostArtworkHorizCorrection = 0
            }
            let hostArtworkX = hostBaseContentOffsetX + hostArtworkHorizCorrection
            let legacyBaseLyricsX =
                hostArtworkX
                + legacyLayout.artworkWidth
                + coverBlurLegacyArtworkLyricsColumnSpacing
                - coverBlurLegacyLyricsColumnLeftNudge
            baseLyricsLeadingX =
                legacyBaseLyricsX
                - coverBlurLegacyLeftExpansion
                + coverBlurLegacyLyricsRightShift
            minReadableLyricsWidth = legacyLayout.lyricsWidth
        } else {
            // Mirror the cover group left-bias (Classic / Rotating Cover /
            // Cassette / AppleStyle) so cover + visualizer + lyrics translate
            // together without altering their relative spacing. This branch
            // already excludes the cover-blur skin (which uses the legacy
            // layout above). `groupLeftBias` is subtracted here to match the
            // artwork area's `-groupLeftShift` offset.
            let groupLeftShift: CGFloat = isShowingRightPanel
                ? FullscreenCoverHorizontalOffset.groupLeftBias
                : 0
            baseLyricsLeadingX = hostLayout.lyricsLeadingX - groupLeftShift
            minReadableLyricsWidth = hostLayout.lyricsWidth
        }

        // Canvas horizontal centering margin: on 16:9 screens the canvas is narrower than
        // the screen; add the side margin so the lyrics block stays aligned to the
        // shared artwork+lyrics split, not to the left screen edge.
        let canvasCenteringX = max(0, (screenWidth - Self.baseCanvasWidth * scale) / 2)
        let visibleLyricsX = baseLyricsLeadingX * scale + canvasCenteringX
        let hiddenLyricsX = visibleLyricsX + 92 * scale
        let actualLyricsX = lyricsPanelVisible ? visibleLyricsX : hiddenLyricsX

        // Keep a readable minimum (layout split width), while still letting the right
        // column breathe on wide windows.
        let lyricsRightScreenPad = max(44 * scale, minReadableLyricsWidth * scale * 0.08)
        let layoutWidth = minReadableLyricsWidth * scale
        let fillWidth = screenWidth - visibleLyricsX - lyricsRightScreenPad
        let actualLyricsWidth = max(100, max(layoutWidth, fillWidth))

        // Fixed native lyrics frame — always the full base canvas height. The
        // surface does not resize during miniplayer hide/show, so its alignment
        // never chases a moving target.
        let actualLyricsHeight = Self.baseCanvasHeight * scale  // 923*scale, constant

        // Visible clip boundary — Swift-only. Animates 851↔923*scale via bottomControlsAnimation.
        // Only the mask window changes; the lyrics content space stays stable.
        let visibleBottomReserve: CGFloat = isFullscreenBottomControlsVisible ? fullscreenControlsBottomPadding : 0
        let visibleClipHeight = (Self.baseCanvasHeight - visibleBottomReserve) * scale

        // Debug logging for first layout
        let _ = {
            if keepLyricsHostMounted {
                Log.debug("fullscreenLyricsLayer: scale=\(scale), width=\(actualLyricsWidth), height=\(actualLyricsHeight), visible=\(lyricsPanelVisible)", category: .lyrics)
            }
        }()

        return ZStack(alignment: .topLeading) {
            if keepLyricsHostMounted {
                fullscreenLyricsCrispView(scale: scale, visibleClipHeight: visibleClipHeight)
                    .frame(width: actualLyricsWidth, height: actualLyricsHeight, alignment: .topLeading)
                    .offset(x: actualLyricsX)
                    .opacity(fullscreenLyricsHostOpacity)
                    .allowsHitTesting(isFullscreenLyricsHostVisible)
                    .accessibilityHidden(!isFullscreenLyricsHostVisible)
            }

            if isShowingQueuePanel {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onShowLyrics()
                        }

                    fullscreenQueuePanel(
                        scale: scale,
                        visibleHeight: visibleClipHeight
                    )
                    .padding(.trailing, 118 * scale)
                    .padding(.top, 72 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
                .accessibilityHidden(false)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 92 * scale)),
                    removal: .opacity.combined(with: .offset(x: 92 * scale))
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // REMOVED: .animation(lyricsLayoutAnimation, value: lyricsVisible)
        // The container animation was causing the entire lyrics block to animate
        // in from above, making it look like a falling block. The native surface
        // handles line motion internally, keeping the current line fixed while
        // other lines converge.
        .motionAnimation(.layout, value: isFullscreenBottomControlsVisible)  // mask only
    }

    @ViewBuilder
    private func fullscreenLyricsCrispView(scale: CGFloat, visibleClipHeight: CGFloat) -> some View {
        GeometryReader { proxy in
            let topFade: CGFloat = 58 * scale
            // Bottom feather shape: controls where the fade-out starts within the visible clip region.
            // Does NOT affect expandedHeight — the lyrics surface is pinned to
            // 420pt overbleed always.
            // visible: larger fade → bottom fade starts higher, giving lyrics breathing room
            //          above the miniplayer bar.
            // hidden:  smaller fade → bottom fade starts lower, revealing more solid content
            //          in the expanded view before the edge softens.
            let baseBottomFadeVisible: CGFloat = 60
            let baseBottomFadeHidden: CGFloat = 380
            let bottomFade = (isFullscreenBottomControlsVisible ? baseBottomFadeVisible : baseBottomFadeHidden) * scale
            let horizontalInset: CGFloat = 10 * scale
            // Fixed expanded height: always allocate the maximum bottom overbleed
            // (420pt) so the native surface height never changes during
            // miniplayer hide/show. Previously this used the variable
            // `bottomFade`, which caused expandedHeight to jump from ~947 to
            // ~1407 and recompute the entire line layout on every state change.
            let expandedHeight = proxy.size.height + topFade + 420 * scale + 6 * scale
            ZStack {
                let lyricsSurfaceWidth = max(0, proxy.size.width - horizontalInset * 2)

                fullscreenMaskedLyricsSurface(
                    scale: scale,
                    width: lyricsSurfaceWidth,
                    height: expandedHeight,
                    visibleHeight: visibleClipHeight,
                    topFade: topFade,
                    bottomFade: bottomFade,
                    blendMode: usesCoverBlurLyricsRenderingPath ? coverBlurBaseBlendMode : .normal,
                    useCompositingGroup: !usesCoverBlurLyricsRenderingPath
                ) {
                    NativeLyricsViewRepresentable(
                        surface: NativeLyricsSurfaceManager.shared.surface(for: .fullscreen)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Motion feel: subtle y-scale anchored at top creates "pushing down" feel during expansion.
            .scaleEffect(
                y: isFullscreenBottomControlsVisible ? 0.97 : 1.0,
                anchor: .top
            )
            .motionAnimation(.layout, value: isFullscreenBottomControlsVisible)
        }
    }

    private func fullscreenQueuePanel(
        scale: CGFloat,
        visibleHeight: CGFloat
    ) -> some View {
        FullscreenQueueView(
            tracks: queueTracks,
            currentTrackID: currentQueueTrackID,
            playbackMode: currentPlaybackMode,
            glassStyle: fullscreenQueueGlassStyle,
            foregroundProfile: fullscreenQueueForegroundProfile,
            scale: scale,
            visibleHeight: visibleHeight,
            onTrackTap: onQueueTrackTap
        )
    }

    @ViewBuilder
    private func fullscreenMaskedLyricsSurface<Content: View>(
        scale: CGFloat,
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
            .opacity(fullscreenLyricsViewportOpacity)
            .environment(\.colorScheme, .dark)
            .mask(
                ZStack(alignment: .top) {
                    fullscreenLyricsMask(
                        visibleHeight: visibleHeight - lyricsViewportTopCropDown * scale,
                        topFade: topFade,
                        bottomFade: bottomFade
                    )
                }
                .frame(height: height, alignment: .top)
                .offset(
                    y: (isFullscreenBottomControlsVisible
                        ? 42 + lyricsViewportTopCropDown
                        : 58 + lyricsViewportTopCropDown) * scale
                )
            )

        if blendMode == .normal {
            maskedContent
        } else if useCompositingGroup {
            maskedContent
                .compositingGroup()
                .blendMode(blendMode)
        } else {
            maskedContent
                .blendMode(blendMode)
        }
    }
    private func layoutMetrics(showLyricsColumn: Bool) -> FullscreenHorizontalSplitLayout {
        showLyricsColumn ? hostLayout : FullscreenHorizontalSplitLayout.resolve(showLyricsColumn: false)
    }

    private func coverBlurLegacyLayoutMetrics(
        showLyricsColumn: Bool
    ) -> (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        (coverBlurLegacyArtworkWidth, coverBlurLegacyLyricsWidth)
    }

}

func fullscreenLyricsMask(
    visibleHeight: CGFloat,
    topFade: CGFloat,
    bottomFade: CGFloat
) -> some View {
    let height = max(0, visibleHeight)
    let top = min(height, max(0, topFade))
    let bottom = min(height, max(top, height - max(0, bottomFade)))
    let denominator = max(height, 1)

    // Keep the two fade transitions in one rasterized mask.  Building this
    // from adjacent gradient/rectangle/gradient views leaves a fractional
    // boundary after fullscreen scaling; the mask then removes one row of
    // lyric pixels while the opaque background underneath remains intact.
    return LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: top / denominator),
            .init(color: .black, location: bottom / denominator),
            .init(color: .clear, location: height / denominator),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    .frame(height: height)
}

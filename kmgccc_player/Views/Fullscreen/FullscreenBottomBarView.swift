import MotionKit
import SwiftUI

struct FullscreenBottomBarMetrics {
    let scale: CGFloat
    let screenSize: CGSize
    let canvasSize: CGSize
    let buttonSize: CGFloat
    let bottomPadding: CGFloat
    let geometryConfiguration: FullscreenBottomControlsGeometry.Configuration
    let controlsGeometry: FullscreenBottomControlsGeometry
    let quickAppearancePanelFrame: CGRect
}

struct FullscreenBottomBarPresentation {
    let glassStyle: FullscreenControlsGlassStyle
    let miniPlayerForegroundProfile: FullscreenMiniPlayerForegroundProfile
    let quickPanelForegroundProfile: FullscreenOverlayForegroundProfile
    let primaryColor: Color
    let iconBlendMode: BlendMode
    let playbackMode: PlaybackOrderMode
    let hasTrack: Bool
    let isShowingLyrics: Bool
    let isVolumeControlEnabled: Bool
    let usesAdaptiveVolumeForeground: Bool
    let showsPlaybackModeRetapTip: Bool
}

struct FullscreenBottomBarActions {
    let exitFullscreen: () -> Void
    let toggleLyrics: () -> Void
    let setQuickAppearancePanelPresented: (Bool) -> Void
    let hotZoneHoverChanged: (Bool) -> Void
    let centerHoverChanged: (Bool) -> Void
    let leadingHoverChanged: (Bool) -> Void
    let trailingHoverChanged: (Bool) -> Void
    let appearancePanelHoverChanged: (Bool) -> Void
    let progressDraggingChanged: (Bool) -> Void
    let volumeAdjustingChanged: (Bool) -> Void
    let interaction: () -> Void
    let playbackModeChanged: (PlaybackOrderMode) -> Void
    let currentPlaybackModeRetapped: (PlaybackOrderMode) -> Void
    let editTrackRequested: (Track) -> Void
    let editExternalInfoRequested: () -> Void
    let showDetailRequested: (Track) -> Void
    let dismissPlaybackModeRetapTip: () -> Void
}

nonisolated private enum BottomControlGlassID: Hashable, Sendable {
    case leading
    case miniPlayer
    case volume
}

@MainActor
struct FullscreenBottomBarView: View {
    let metrics: FullscreenBottomBarMetrics
    let presentation: FullscreenBottomBarPresentation
    let actions: FullscreenBottomBarActions

    @Bindable var controls: FullscreenBottomControlsCoordinator
    @Binding var volume: Double
    @Namespace private var glassNamespace

    var body: some View {
        let scale = metrics.scale
        let buttonSize = metrics.buttonSize * scale
        let geometry = metrics.controlsGeometry
        let scaledLeadingOriginX = geometry.leadingControlsRect.minX * scale
        let scaledLeadingWidth = geometry.leadingControlsRect.width * scale
        let scaledMiniPlayerOriginX = geometry.miniPlayerRect.minX * scale
        let scaledMiniPlayerWidth = geometry.miniPlayerRect.width * scale
        let scaledVolumeOriginX = geometry.volumeRect.minX * scale
        let scaledVolumeWidth = geometry.volumeRect.width * scale
        let scaledCanvasWidth = metrics.canvasSize.width * scale
        let canvasBottomMargin = max(0, (metrics.screenSize.height - metrics.canvasSize.height * scale) / 2)
        let scaledBottomPadding = metrics.bottomPadding * scale + canvasBottomMargin
        let scaledGroupWidth = geometry.fullGroupRect.width * scale
        let hotZoneWidth = min(scaledCanvasWidth, scaledGroupWidth + 120 * scale)
        let hotZoneHeight = buttonSize + 34 * scale
        let controlsRowHeight = max(buttonSize, hotZoneHeight)
        let controlsCenterY = controlsRowHeight * 0.5
        let adjustedBottomPadding = max(
            0,
            scaledBottomPadding - (controlsRowHeight - buttonSize) * 0.5
        )
        let quickPanelFrame = metrics.quickAppearancePanelFrame

        return ZStack(alignment: .topLeading) {
            if controls.isQuickAppearancePanelPresented {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        actions.setQuickAppearancePanelPresented(false)
                    }
                    .transition(.opacity)
                    .zIndex(0)
            }

            VStack {
                Spacer()
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.001)
                        .frame(width: hotZoneWidth, height: hotZoneHeight)
                        .contentShape(
                            RoundedRectangle(
                                cornerRadius: hotZoneHeight * 0.5,
                                style: .continuous
                            )
                        )
                        .position(x: scaledCanvasWidth * 0.5, y: controlsCenterY)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                actions.hotZoneHoverChanged(true)
                            case .ended:
                                actions.hotZoneHoverChanged(false)
                            }
                        }

                    GlassEffectContainer(spacing: 0) {
                        ZStack(alignment: .leading) {
                            leadingControlsPill(size: buttonSize)
                                .glassEffectID(BottomControlGlassID.leading, in: glassNamespace)
                                .frame(width: scaledLeadingWidth, height: buttonSize)
                                .position(
                                    x: scaledLeadingOriginX + scaledLeadingWidth / 2,
                                    y: controlsCenterY
                                )

                            FullscreenMiniPlayerView(
                                scale: scale,
                                isSpectrumActive: controls.isVisible,
                                glassStyle: presentation.glassStyle,
                                playbackMode: presentation.playbackMode,
                                onPlaybackModeChange: actions.playbackModeChanged,
                                onCurrentPlaybackModeRetap: actions.currentPlaybackModeRetapped,
                                onInteraction: actions.interaction,
                                onHoverStateChanged: { hovering in
                                    actions.centerHoverChanged(hovering)
                                    if hovering { actions.interaction() }
                                },
                                onProgressDraggingChanged: actions.progressDraggingChanged,
                                onEditTrackRequested: actions.editTrackRequested,
                                onEditExternalInfoRequested: actions.editExternalInfoRequested,
                                onShowDetailRequested: actions.showDetailRequested,
                                foregroundProfile: presentation.miniPlayerForegroundProfile
                            )
                            .glassEffectID(BottomControlGlassID.miniPlayer, in: glassNamespace)
                            .frame(width: scaledMiniPlayerWidth, height: buttonSize)
                            .environment(\.colorScheme, presentation.glassStyle.colorScheme)
                            .position(
                                x: scaledMiniPlayerOriginX + scaledMiniPlayerWidth / 2,
                                y: controlsCenterY
                            )

                            ExpandableVolumeControl(
                                volume: $volume,
                                isExpanded: $controls.isVolumeExpanded,
                                scale: scale,
                                onInteraction: actions.interaction,
                                onHoverStateChanged: actions.trailingHoverChanged,
                                onAdjustingChanged: actions.volumeAdjustingChanged,
                                materialStyle: presentation.glassStyle.materialStyle,
                                isEnabled: presentation.isVolumeControlEnabled,
                                usesAdaptiveForeground: presentation.usesAdaptiveVolumeForeground,
                                forceDarkForegroundProfile: false,
                                usesInternalHoverExpansion: false,
                                foregroundProfile: presentation.miniPlayerForegroundProfile
                            )
                            .glassEffectID(BottomControlGlassID.volume, in: glassNamespace)
                            .frame(width: scaledVolumeWidth, height: buttonSize)
                            .environment(\.colorScheme, presentation.glassStyle.colorScheme)
                            .position(
                                x: scaledVolumeOriginX + scaledVolumeWidth / 2,
                                y: controlsCenterY
                            )
                        }
                    }
                    .opacity(controls.isVisible ? 1 : 0)
                    .allowsHitTesting(controls.isVisible)
                    .accessibilityHidden(!controls.isVisible)
                    // Glass resolves its polarity at the container, so keep the
                    // complementary scheme on this scope as well as the pills.
                    .environment(\.colorScheme, presentation.glassStyle.colorScheme)
                }
                .overlayPreferenceValue(PlaybackModeRetapTipAnchorPreferenceKey.self) { anchor in
                    GeometryReader { proxy in
                        if controls.isVisible,
                           presentation.showsPlaybackModeRetapTip,
                           let anchor
                        {
                            let sliderRect = proxy[anchor]
                            PlaybackModeRetapTipView(onClose: actions.dismissPlaybackModeRetapTip)
                                .offset(
                                    x: sliderRect.midX - 144,
                                    y: sliderRect.minY - 12 * scale
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                                .zIndex(3)
                        }
                    }
                }
                .frame(width: scaledCanvasWidth, height: controlsRowHeight, alignment: .leading)
                .padding(.bottom, adjustedBottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)

            if controls.isQuickAppearancePanelPresented {
                FullscreenQuickAppearancePanel(
                    scale: scale,
                    foregroundProfile: presentation.quickPanelForegroundProfile,
                    onDismiss: { actions.setQuickAppearancePanelPresented(false) }
                )
                .frame(width: quickPanelFrame.width, height: quickPanelFrame.height)
                .skinControlRegion()
                .position(x: quickPanelFrame.midX, y: quickPanelFrame.midY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        actions.appearancePanelHoverChanged(true)
                    case .ended:
                        actions.appearancePanelHoverChanged(false)
                    }
                }
                // Offset keeps AppKit-backed panel controls at a stable size
                // during insertion and removal.
                .transition(.opacity.combined(with: .offset(x: -8, y: 8)))
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motionAnimation(.control, value: controls.isQuickAppearancePanelPresented)
    }

    private func leadingControlsPill(size: CGFloat) -> some View {
        FullscreenLeadingControlsPill(size: size, presentation: presentation, actions: actions, controls: controls)
    }
}

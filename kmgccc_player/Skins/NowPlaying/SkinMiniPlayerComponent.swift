import MotionKit
import SwiftUI

struct SkinNativeControlsContext {
    let presentation: FullscreenBottomBarPresentation
    let actions: FullscreenBottomBarActions
    let controls: FullscreenBottomControlsCoordinator
}

extension EnvironmentValues {
    @Entry var skinNativeControls: SkinNativeControlsContext?
}

/// The centre capsule is deliberately not registered separately. This component always
/// includes both side capsules and measures fonts/controls at the actual drawing size.
struct SkinMiniPlayerComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.skinNativeControls) private var native
    @Environment(\.skinSceneIsActive) private var isActive
    @State private var capsuleControls = FullscreenBottomControlsCoordinator()

    var body: some View {
        GeometryReader { proxy in
            if let native {
                let metrics = FullscreenBottomControlsGeometry.Configuration()
                let minimumWidth = FullscreenMiniPlayerLayoutMetrics(scale: 1).minimumExpandedContainerWidth
                    + metrics.leadingExpandedWidth + metrics.volumeExpandedWidth + metrics.spacing * 2
                let scale = max(0.1, min(configuration.number("scale", fallback: 1), proxy.size.width / minimumWidth,
                                         proxy.size.height / metrics.buttonSize))
                let leadingWidth = (capsuleControls.isLeftActionsExpanded ? metrics.leadingExpandedWidth : metrics.leadingCollapsedWidth) * scale
                let volumeWidth = (capsuleControls.isVolumeExpanded ? metrics.volumeExpandedWidth : metrics.volumeCollapsedWidth) * scale
                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: metrics.spacing * scale) {
                        SkinLeadingCapsule(configuration: .init(values: ["scale": .number(scale)]), controls: capsuleControls)
                            .frame(width: leadingWidth, height: metrics.buttonSize * scale)
                        FullscreenMiniPlayerView(
                            scale: scale, isSpectrumActive: isActive,
                            glassStyle: native.presentation.glassStyle,
                            playbackMode: native.presentation.playbackMode,
                            onPlaybackModeChange: native.actions.playbackModeChanged,
                            onCurrentPlaybackModeRetap: native.actions.currentPlaybackModeRetapped,
                            onInteraction: native.actions.interaction,
                            onProgressDraggingChanged: native.actions.progressDraggingChanged,
                            onEditTrackRequested: native.actions.editTrackRequested,
                            onEditExternalInfoRequested: native.actions.editExternalInfoRequested,
                            onShowDetailRequested: native.actions.showDetailRequested,
                            foregroundProfile: native.presentation.miniPlayerForegroundProfile
                        )
                        .frame(width: max(0, proxy.size.width - leadingWidth - volumeWidth - metrics.spacing * 2 * scale),
                               height: metrics.buttonSize * scale)
                        SkinVolumeCapsule(configuration: .init(values: ["scale": .number(scale)]), controls: capsuleControls)
                            .frame(width: volumeWidth, height: metrics.buttonSize * scale)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .environment(\.colorScheme, native.presentation.glassStyle.colorScheme)
            }
        }
    }
}

struct SkinLeadingCapsule: View {
    let configuration: SkinComponentConfiguration
    var controls: FullscreenBottomControlsCoordinator? = nil
    @Environment(\.skinNativeControls) private var native
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localControls = FullscreenBottomControlsCoordinator()
    private var model: FullscreenBottomControlsCoordinator { controls ?? localControls }

    var body: some View {
        if let native {
            FullscreenLeadingControlsPill(
                size: 60 * configuration.number("scale", fallback: 1),
                presentation: native.presentation, actions: native.actions, controls: model,
                isFullscreen: surface == .fullscreen,
                showsLyricsButton: configuration.boolean("showsLyricsButton", fallback: true),
                onHoverStateChanged: hoverChanged
            )
            .skinProvidesControls(configuration.boolean("showsLyricsButton", fallback: true)
                ? [.fullscreen, .lyricsToggle, .quickPanel] : [.fullscreen, .quickPanel])
            .onDisappear { model.cancelLeftCollapse() }
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        model.isLeadingHovered = hovering
        if hovering {
            model.cancelLeftCollapse()
            setExpanded(true, reason: "skin-hover-enter")
        } else {
            model.scheduleLeftCollapse(
                reason: "skin-hover-exit", setLeftActionsExpanded: { expanded, reason in setExpanded(expanded, reason: reason) },
                scheduleAutoHide: {}
            )
        }
    }

    private func setExpanded(_ expanded: Bool, reason: String) {
        model.setLeftActionsExpanded(expanded, reason: reason) { updates in
            FullscreenBottomControlsAnimationPolicy.animateGeometry(
                with: configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion).animation(for: motionTokens[.layout]), updates
            )
        }
    }

}

struct SkinVolumeCapsule: View {
    let configuration: SkinComponentConfiguration
    var controls: FullscreenBottomControlsCoordinator? = nil
    @Environment(\.skinNativeControls) private var native
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localControls = FullscreenBottomControlsCoordinator()
    private var model: FullscreenBottomControlsCoordinator { controls ?? localControls }

    var body: some View {
        if let native {
            ExpandableVolumeControl(
                volume: Binding(get: { playback.stablePresentation.volume }, set: { playback.setVolume($0) }),
                isExpanded: Binding(get: { model.isVolumeExpanded }, set: { setExpanded($0, reason: "skin-volume") }),
                scale: configuration.number("scale", fallback: 1),
                onInteraction: native.actions.interaction, onHoverStateChanged: hoverChanged,
                onAdjustingChanged: { adjusting in
                    model.isVolumeAdjusting = adjusting
                    if adjusting { model.cancelVolumeCollapse(); setExpanded(true, reason: "skin-volume-adjust") }
                    else { scheduleCollapse() }
                },
                materialStyle: native.presentation.glassStyle.materialStyle,
                isEnabled: native.presentation.isVolumeControlEnabled,
                usesAdaptiveForeground: native.presentation.usesAdaptiveVolumeForeground,
                forceDarkForegroundProfile: false, usesInternalHoverExpansion: false,
                foregroundProfile: native.presentation.miniPlayerForegroundProfile
            )
            .environment(\.colorScheme, native.presentation.glassStyle.colorScheme)
            .onDisappear { model.cancelVolumeCollapse() }
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        model.isTrailingHovered = hovering
        if hovering && playback.stablePresentation.isVolumeControlEnabled {
            model.cancelVolumeCollapse()
            setExpanded(true, reason: "skin-hover-enter")
        } else { scheduleCollapse() }
    }
    private func scheduleCollapse() {
        model.scheduleVolumeCollapse(
            reason: "skin-hover-exit", setVolumeExpanded: { expanded, reason in setExpanded(expanded, reason: reason) },
            scheduleAutoHide: {}
        )
    }

    private func setExpanded(_ expanded: Bool, reason: String) {
        model.setVolumeExpanded(
            expanded, reason: reason, volumeControlEnabled: playback.stablePresentation.isVolumeControlEnabled
        ) { updates in
            FullscreenBottomControlsAnimationPolicy.animateGeometry(
                with: configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion).animation(for: motionTokens[.layout]), updates
            )
        }
    }

}

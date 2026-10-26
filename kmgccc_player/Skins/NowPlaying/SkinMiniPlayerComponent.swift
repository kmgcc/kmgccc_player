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

/// The centre capsule is deliberately not registered separately. The component measures
/// fonts and controls at the actual drawing size. `width` is the whole row's length at 1×
/// (the fullscreen host's length by default), and each part can be hidden.
struct SkinMiniPlayerComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.skinNativeControls) private var native
    @Environment(\.skinSceneIsActive) private var isActive
    @State private var capsuleControls = FullscreenBottomControlsCoordinator()

    private var sections: FullscreenMiniPlayerSections {
        var result = FullscreenMiniPlayerSections()
        if configuration.boolean("showsTrackInfo", fallback: true) { result.insert(.trackInfo) }
        if configuration.boolean("showsTransport", fallback: true) { result.insert(.transport) }
        if configuration.boolean("showsPlaybackMode", fallback: true) { result.insert(.playbackMode) }
        if configuration.boolean("showsProgress", fallback: true) { result.insert(.progress) }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            if let native {
                let metrics = FullscreenBottomControlsGeometry.Configuration()
                let showsLeading = configuration.boolean("showsLeading", fallback: true)
                let showsVolume = configuration.boolean("showsVolume", fallback: true)
                let sections = self.sections
                let sides = (showsLeading ? metrics.leadingExpandedWidth + metrics.spacing : 0)
                    + (showsVolume ? metrics.volumeExpandedWidth + metrics.spacing : 0)
                let pillWidth = FullscreenMiniPlayerLayoutMetrics(scale: 1).containerWidth(for: sections)
                let hostWidth = FullscreenBottomControlsGeometry.make(isLeftActionsExpanded: false, isVolumeExpanded: false).fullGroupRect.width
                let stretches = sections.contains(.progress)
                // The widest the row gets: progress absorbs the side capsules' expansion,
                // otherwise the row hugs its content and grows with the capsules.
                let maximumLength = stretches ? max(pillWidth + sides, configuration.number("width", fallback: hostWidth)) : pillWidth + sides
                let scale = max(0.1, min(configuration.number("scale", fallback: 1), proxy.size.width / maximumLength,
                                         proxy.size.height / metrics.buttonSize))
                let leadingWidth = (capsuleControls.isLeftActionsExpanded ? metrics.leadingExpandedWidth : metrics.leadingCollapsedWidth) * scale
                let volumeWidth = (capsuleControls.isVolumeExpanded ? metrics.volumeExpandedWidth : metrics.volumeCollapsedWidth) * scale
                let rowWidth = stretches ? maximumLength * scale
                    : pillWidth * scale + (showsLeading ? leadingWidth + metrics.spacing * scale : 0)
                        + (showsVolume ? volumeWidth + metrics.spacing * scale : 0)
                GlassEffectContainer(spacing: 0) {
                    MiniPlayerCapsuleRowLayout(
                        leadingWidth: leadingWidth, volumeWidth: volumeWidth,
                        spacing: metrics.spacing * scale, height: metrics.buttonSize * scale,
                        showsLeading: showsLeading, showsVolume: showsVolume
                    ) {
                        if showsLeading {
                            SkinLeadingCapsule(
                                configuration: .init(values: ["scale": .number(scale),
                                    "showsLyricsButton": .boolean(configuration.boolean("showsLyricsButton", fallback: true))]),
                                controls: capsuleControls, usesContainerWidth: true
                            )
                        } else {
                            Color.clear
                        }
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
                            foregroundProfile: native.presentation.miniPlayerForegroundProfile,
                            sections: sections
                        )
                        if showsVolume {
                            SkinVolumeCapsule(
                                configuration: .init(values: ["scale": .number(scale)]),
                                controls: capsuleControls, usesContainerWidth: true
                            )
                        } else {
                            Color.clear
                        }
                    }
                }
                .frame(width: rowWidth, height: metrics.buttonSize * scale)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: rowAlignment)
                .environment(\.colorScheme, native.presentation.glassStyle.colorScheme)
            }
        }
    }

    private var rowAlignment: Alignment {
        switch configuration.text("align") {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

struct SkinLeadingCapsule: View {
    let configuration: SkinComponentConfiguration
    var controls: FullscreenBottomControlsCoordinator? = nil
    var usesContainerWidth = false
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
                onHoverStateChanged: hoverChanged, usesContainerWidth: usesContainerWidth
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
                with: configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion).animation(for: motionTokens.miniPlayerLayout), updates
            )
        }
    }

}

struct SkinVolumeCapsule: View {
    let configuration: SkinComponentConfiguration
    var controls: FullscreenBottomControlsCoordinator? = nil
    var usesContainerWidth = false
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
                foregroundProfile: native.presentation.miniPlayerForegroundProfile,
                usesContainerWidth: usesContainerWidth
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
                with: configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion).animation(for: motionTokens.miniPlayerLayout), updates
            )
        }
    }

}

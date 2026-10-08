import SwiftUI

struct SkinVolumeComponent: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let presentation = playback.stablePresentation
        VolumeSlider(
            volume: Binding(get: { playback.stablePresentation.volume }, set: actions.setVolume),
            markerColor: theme.accentColor.opacity(0.85), hidesMarkerAtDefault: true
        )
        .controlSize(.small)
        .tint(theme.accentColor)
        .disabled(!presentation.isVolumeControlEnabled)
    }
}

struct SkinLikeComponent: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryViewModel.self) private var library
    @Environment(\.skinSceneActions) private var actions

    var body: some View {
        let track = playback.stablePresentation.localTrack
        let liked = track.map { library.preferenceStats(for: $0.id).manualLikeState == .liked } ?? false
        Button(action: actions.like) { Image(systemName: liked ? "heart.fill" : "heart") }
            .buttonStyle(.plain)
            .disabled(track == nil)
            .help(liked ? "取消喜欢" : "喜欢")
    }
}

struct SkinQueueComponent: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions

    var body: some View {
        Button(action: actions.toggleQueue) { Image(systemName: "list.bullet") }
            .buttonStyle(.plain)
            .disabled(playback.stablePresentation.source != .local)
            .help("播放队列")
    }
}

struct SkinPlaybackModeComponent: View {
    var configuration = SkinComponentConfiguration()
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(\.skinSceneActions) private var actions

    var body: some View {
        let presentation = playback.stablePresentation
        let scale = configuration.number("scale", fallback: 1)
        let color = configuration.color(fallback: .primary)
        let expanded = configuration.boolean("expanded", fallback: true)
        let metrics = FullscreenMiniPlayerLayoutMetrics(scale: scale)
        let width = expanded ? (presentation.source == .local ? metrics.playbackModeExpandedWidth : metrics.externalPlaybackModeExpandedWidth) : metrics.playbackModeCollapsedWidth
        Group {
            if presentation.source == .local {
                PlaybackModeSlider(
                    mode: presentation.localPlaybackOrderMode ?? settings.playbackOrderMode,
                    isEnabled: presentation.isPlaybackModeControlEnabled,
                    isExpanded: expanded,
                    iconSize: 16 * scale, selectedColor: color, scale: scale,
                    onModeChange: actions.setPlaybackOrder, onCurrentModeRetap: { _ in actions.toggleQueue() }
                )
            } else {
                AppleMusicPlaybackModeSlider(
                    mode: presentation.appleMusicPlaybackMode ?? .sequence,
                    isEnabled: presentation.isPlaybackModeControlEnabled,
                    isExpanded: expanded,
                    iconSize: 16 * scale, selectedColor: color, scale: scale,
                    onModeChange: actions.setExternalPlaybackOrder
                )
            }
        }
        .frame(width: configuration.number("width", fallback: width),
               height: configuration.number("height", fallback: 36 * scale))
        .fixedSize()
    }
}

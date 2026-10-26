import AppKit
import SwiftUI

struct SkinVolumeComponent: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let presentation = playback.stablePresentation
        let setVolume = actions.setVolume
        VolumeSlider(
            volume: Binding(
                get: { playback.stablePresentation.volume },
                set: setVolume
            ),
            markerColor: theme.accentColor.opacity(0.85), hidesMarkerAtDefault: true
        )
        .controlSize(.small)
        .tint(theme.accentColor)
        .disabled(!presentation.isVolumeControlEnabled)
    }
}

/// `symbol` names the outline glyph; the active state uses its `.fill` variant.
/// `fontSize` and `color` size and tint it; `activeColor` tints the active state.
struct SkinLikeComponent: View {
    var configuration = SkinComponentConfiguration()
    var dislike = false
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryViewModel.self) private var library
    @Environment(\.skinSceneActions) private var actions

    var body: some View {
        let _ = library.refreshTrigger
        let track = playback.stablePresentation.localTrack
        let state = track.map { library.preferenceStats(for: $0.id).manualLikeState } ?? ManualLikeState.none
        let active = state == (dislike ? .disliked : .liked)
        let symbol = configuration.text("symbol", fallback: dislike ? "hand.thumbsdown" : "heart")
        // Without `color` the glyph keeps the surrounding foreground.
        let base = OKLCHColor(named: configuration.text("color"))
        let tint = active ? OKLCHColor(named: configuration.text("activeColor")) ?? base : base
        Button(action: dislike ? actions.toggleDislike : actions.like) {
            let image = Image(systemName: active ? symbol + ".fill" : symbol)
                .font(.system(size: configuration.number("fontSize", fallback: 13)))
                .contentShape(Rectangle())
            if let tint { image.foregroundStyle(tint.swiftUIColor) } else { image }
        }
            .buttonStyle(.plain)
            .disabled(track == nil)
            .help(dislike ? (active ? "取消不喜欢" : "不喜欢") : (active ? "取消喜欢" : "喜欢"))
    }
}

/// The playback route as a symbol and name; a click lists the outputs.
struct SkinOutputDeviceComponent: View {
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneActions) private var actions
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let current = AudioDSPDeviceController.current?.currentDevice
        let fontSize = configuration.number("fontSize", fallback: 13)
        HStack(spacing: configuration.number("spacing", fallback: 6)) {
            Image(systemName: current?.symbolName ?? "hifispeaker").font(.system(size: fontSize * 1.15))
            if configuration.boolean("showsName", fallback: true) {
                Text(current?.name ?? "").font(.system(size: fontSize, weight: .medium)).lineLimit(1)
            }
        }
        .foregroundStyle(configuration.color(fallback: .primary))
        .contentShape(Rectangle())
        // An AppKit snapshot menu, so per-tick scene redraws never close it.
        .overlay { SkinMenuAnchor(opensOnClick: true) { NSHostingMenu(rootView: SkinOutputDeviceItems(actions: actions).environment(settings)) } }
        .skinControlRegion()
        .help("输出设备")
    }
}

private struct SkinOutputDeviceItems: View {
    let actions: SkinSceneActions
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker(selection: Binding(get: { settings.audioOutputDeviceUID ?? "" }, set: { actions.selectOutput($0.isEmpty ? nil : $0) })) {
            Text("跟随系统").tag("")
            ForEach(AudioDSPDeviceController.current?.devices ?? []) { device in Label(device.name, systemImage: device.symbolName).tag(device.uid) }
        } label: { EmptyView() }
            .pickerStyle(.inline)
            .labelStyle(.titleAndIcon)
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
                    iconSize: configuration.number("iconSize", fallback: 16) * scale, selectedColor: color, scale: scale,
                    onModeChange: actions.setPlaybackOrder, onCurrentModeRetap: { _ in actions.toggleQueue() }
                )
            } else {
                AppleMusicPlaybackModeSlider(
                    mode: presentation.appleMusicPlaybackMode ?? .sequence,
                    isEnabled: presentation.isPlaybackModeControlEnabled,
                    isExpanded: expanded,
                    iconSize: configuration.number("iconSize", fallback: 16) * scale, selectedColor: color, scale: scale,
                    onModeChange: actions.setExternalPlaybackOrder
                )
            }
        }
        .frame(width: configuration.number("width", fallback: width),
               height: configuration.number("height", fallback: 36 * scale))
        .fixedSize()
    }
}

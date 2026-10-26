import AppKit
import MotionKit
import SwiftUI

/// The App's animated play/pause and skip buttons. `size`, `symbolSize`, `color`, `disabledColor`
/// and `blendMode` shape them; the node's `motion` retunes their MotionKit springs.
struct SkinAnimatedButtonPart: View {
    let configuration: SkinComponentConfiguration
    let skip: Bool
    var previous: Bool?
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    var body: some View {
        let p = playback.stablePresentation
        let color = configuration.color(fallback: .primary)
        let disabled = configuration.color("disabledColor", fallback: .secondary)
        let blend = SkinNodeStyle.blendMode(configuration.text("blendMode", fallback: "normal"))
        let previous = previous ?? (configuration.text("direction") == "previous")
        Group {
            if skip {
                AnimatedSkipButton(direction: previous ? .previous : .next, enabled: p.isControlEnabled && p.hasTrack,
                    metrics: configuration.mediaControlMetrics(navigation: true), color: color, disabledColor: disabled,
                    blendMode: blend, action: previous ? actions.previous : actions.next)
            } else {
                AnimatedPlayPauseButton(isPlaying: p.isPlaying, enabled: p.isControlEnabled, metrics: configuration.mediaControlMetrics(navigation: false),
                                        color: color, disabledColor: disabled, blendMode: blend, action: actions.playPause)
            }
        }
        .help(skip ? (previous ? "上一首" : "下一首") : (p.isPlaying ? "暂停" : "播放"))
        .skinControlRegion().skinProvidesControls(skip ? [previous ? .previous : .next] : [.playPause])
    }
}

struct SkinLyricsPanelPart: View {
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneSurface) private var surface
    var body: some View {
        Group {
            if surface == .window { LyricsPanelView() }
            else { SkinLyricsSlot(configuration: configuration) }
        }.preference(key: SkinLyricsSlotKey.self, value: configuration)
    }
}

struct SkinProgressSpectrumPart: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneIsActive) private var active
    @State private var dragging = false
    @State private var position: Double = 0
    var body: some View {
        let p = playback.presentation
        MiniPlayerProgressSpectrumRow(scale: configuration.number("scale", fallback: 1),
            visualization: configuration.text("mode", fallback: "spectrum") == "led" ? .led : .spectrum,
            isPlaying: p.isPlaying, isSpectrumActive: active, accentColor: snapshot.theme.accentColor,
            foregroundColor: configuration.color(fallback: snapshot.theme.accentColor),
            spectrumArtworkColors: snapshot.theme.spectrumArtworkColors,
            spectrumUsesDarkForeground: snapshot.theme.spectrumUsesDarkForeground,
            progress: dragging ? position : p.currentTime, duration: p.duration, isSeekEnabled: p.isSeekEnabled,
            onSeek: { position = $0 }, onDragStart: { position = p.currentTime; dragging = true },
            onDragEnd: { actions.seek(position); dragging = false }, onInteraction: {}, onDragStateChanged: { _ in })
    }
}

struct SkinExpandableVolumePart: View {
    let configuration: SkinComponentConfiguration
    @State private var expanded = false
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinSceneActions) private var actions
    var body: some View {
        ExpandableVolumeControl(volume: Binding(get: { playback.stablePresentation.volume }, set: { actions.setVolume($0) }), isExpanded: $expanded,
            scale: configuration.number("scale", fallback: 0.65), isEnabled: playback.stablePresentation.isVolumeControlEnabled)
            .skinControlRegion()
    }
}

struct SkinGlassButtonPart: View {
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneActions) private var actions
    var body: some View {
        GlassIconButton(systemImage: configuration.text("symbol", fallback: "play.fill"), size: configuration.number("size", fallback: 36),
            iconSize: configuration.number("fontSize", fallback: 16), isPrimary: false,
            iconColorOverride: configuration.color(fallback: .primary)) {
                switch configuration.text("action", fallback: "playPause") {
                case "previous": actions.previous()
                case "next": actions.next()
                case "lyricsToggle": actions.toggleLyrics()
                case "settings": actions.openSettings()
                case "quickPanel": actions.openQuickPanel()
                default: actions.playPause()
                }
            }.skinControlRegion()
    }
}

struct SkinGlassTriplePart: View {
    let configuration: SkinComponentConfiguration
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 0) {
            ForEach([SkinActionButton.Kind.previous, .playPause, .next], id: \.rawValue) { kind in
                SkinActionButton(kind: kind, configuration: configuration).frame(width: 44, height: 36)
            }
        }.liquidGlassPill(colorScheme: scheme, accentColor: nil as Color?, prominence: .standard, materialStyle: .regular)
    }
}

struct SkinBokehPart: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.displayScale) private var displayScale
    @Environment(\.skinSceneIsActive) private var active
    @State private var sources: BokehTransitionSourceSet?
    var body: some View {
        GeometryReader { proxy in
            let context = snapshot.context
            let value = BokehTransitionSnapshot(transitionPosition: configuration.number("position", fallback: 0),
                bokehRadius: active ? configuration.number("radius", fallback: 0) : 0,
                surfaceOpacity: active ? configuration.number("opacity", fallback: 1) : 0,
                handoffOpacity: 1, keepsSurfaceOpaque: false, configuration: .init(), tier: .balanced,
                motionPolicy: context.motionPolicy, motionTokens: context.motionTokens)
            BokehTransitionSurface(snapshot: value, sourceSet: sources, liveFeed: nil)
                .task(id: "\(snapshot.track?.id.uuidString ?? "")|\(snapshot.track?.artworkChecksum ?? 0)|\(proxy.size)|\(displayScale)") {
                    let request = BokehTransitionSourceRequest(artworkData: snapshot.track?.artworkData, artworkImage: snapshot.track?.artworkImage,
                        viewport: proxy.size, displayScale: displayScale, checksum: snapshot.track?.artworkChecksum ?? 0,
                        sourceKey: snapshot.track?.id.uuidString ?? "", tier: .balanced,
                        style: .init(leading: .leading, centered: .centered, edgeFill: .stretch, overlay: nil))
                    let prepared = await Task.detached(priority: .userInitiated) { request.prepare() }.value
                    if !Task.isCancelled { sources = prepared }
                }
                .onDisappear { sources = nil }
        }.allowsHitTesting(false)
    }
}

/// `artwork` with `track`: a queue row's thumbnail, from the window queue panel's cache.
struct SkinQueueTrackArtwork: View {
    let trackID: UUID
    var fills = true
    @Environment(PlayerViewModel.self) private var player
    @Environment(LibraryCacheServices.self) private var caches
    @State private var image: NSImage?

    var body: some View {
        let source = player.currentQueueTracks.first { $0.id == trackID }?.trackArtworkSource()
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: fills ? .fill : .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                ArtworkPlaceholderView.queueRow(artworkSize: min(proxy.size.width, proxy.size.height))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .task(id: source?.sourceKey ?? trackID.uuidString) {
            guard let source else { image = nil; return }
            let loaded = await caches.trackArtworkCache.thumbnail(for: source)
            if !Task.isCancelled { image = loaded }
        }
    }
}

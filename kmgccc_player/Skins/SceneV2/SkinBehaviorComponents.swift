import AppKit
import MotionKit
import SwiftUI

struct SkinBehaviorComponent: View {
    let kind: String
    let configuration: SkinComponentConfiguration
    let content: AnyView
    @State private var coordinator = FullscreenBottomControlsCoordinator()
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneData) private var data
    @Environment(\.skinSceneIsActive) private var active
    @Environment(\.skinSceneLyricsVisible) private var lyricsVisible
    @Environment(\.motionTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch kind {
        case "autoHide":
            content.opacity(coordinator.isVisible ? 1 : 0)
                .allowsHitTesting(coordinator.isVisible)
                .background { Color.clear.contentShape(Rectangle()).onHover { hovering in coordinator.isHovered = hovering; reveal() } }
                .onContinuousHover { phase in if case .active = phase { reveal() } }
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in coordinator.isProgressDragging = true; reveal() }.onEnded { _ in coordinator.isProgressDragging = false; schedule() })
                .motionAnimation(tokens[.control], value: coordinator.isVisible)
                .transformPreference(SkinSceneControlsKey.self) { if !coordinator.isVisible { $0 = [] } }
                .onAppear { schedule() }.onDisappear { coordinator.cancelAllScheduledWork() }
        case "scrollVolume":
            content.background { SkinSceneScrollRegion { _, y in
                guard data?.playback["playback.canSetVolume"]?.isTruthy == true else { return }
                let current = data?.playback["playback.volume"]?.number() ?? 0
                actions.setVolume((current + y * configuration.number("step", fallback: 0.0025)).clamped01)
            } }
        case "windowDrag": content.gesture(WindowDragGesture())
        case "pointerOcclusion": content.skinControlRegion()
        case "lyricsEndAutoHide":
            // Sleep until the last line ends instead of sampling every frame; seeks and
            // play state changes reschedule the wait.
            content.task(id: lyricsEndKey) {
                guard active, lyricsVisible, let data, data.clock.isPlaying,
                      let last = data.lyricsTimeline.lines.last?[member: "end"].numberValue else { return }
                let remaining = last + configuration.number("delay", fallback: 3) - data.clock.lyricsTime(at: Date.timeIntervalSinceReferenceDate)
                guard remaining > 0 else { return }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                if lyricsVisible, data.clock.isPlaying { actions.toggleLyrics() }
            }
        default: content
        }
    }
    private var lyricsEndKey: String {
        guard let data else { return "" }
        return "\(active)|\(lyricsVisible)|\(data.clock.isPlaying)|\(data.seekRevision)|\(data.lyrics["lyrics.revision"]?.number() ?? 0)"
    }

    private func reveal() { coordinator.isVisible = true; data?.pointerMoved(); schedule() }
    private func schedule() {
        // A zero delay matches the host's "never" auto-hide setting.
        let delay = configuration.number("delay", fallback: 3)
        guard delay > 0 else { coordinator.isVisible = true; return }
        coordinator.scheduleAutoHide(after: delay,
            shouldBlock: { coordinator.isHovered || coordinator.isProgressDragging },
            setVisible: { coordinator.isVisible = $0 }, setLeftActionsExpanded: { _, _ in }, setVolumeExpanded: { _, _ in }, scheduleAgain: schedule)
    }
}

/// The mini player's menu, by section: `info` (music info), `track` (like, playlists, details,
/// edit, library navigation, delete), `external`, `order`, `view` (queue, lyrics, fullscreen,
/// quick panel) and `output`. `include` picks sections; `trigger: click` opens it as a button menu.
struct SkinTrackMenuComponent: View {
    static let trackSections = ["info", "track", "external"]
    static let allSections = ["info", "track", "external", "order", "view", "output"]

    let content: AnyView
    var configuration = SkinComponentConfiguration()
    var defaultSections = SkinTrackMenuComponent.trackSections
    @Environment(\.skinSceneActions) private var actions
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinSceneLyricsVisible) private var lyricsVisible
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(LibraryViewModel.self) private var library

    var body: some View {
        let items = SkinPlayerMenuItems(
            sections: Set(configuration.values["include"]?.arrayValue?.compactMap(\.stringValue) ?? defaultSections),
            showsDislike: configuration.boolean("showsDislike", fallback: true),
            surface: surface, lyricsVisible: lyricsVisible, actions: actions
        )
        .labelStyle(.titleAndIcon)
        .environment(playback).environment(settings).environment(uiState).environment(library)
        content.overlay {
            SkinMenuAnchor(opensOnClick: configuration.text("trigger", fallback: "secondaryClick") == "click") {
                NSHostingMenu(rootView: items)
            }
        }
    }
}

/// Opens a host menu from AppKit. The scene redraws on every playback tick; a SwiftUI `Menu`
/// or `contextMenu` is rebuilt with its view, and AppKit then replaces the submenu under the
/// pointer. This menu is made when it opens and nothing in the scene reaches it afterwards.
/// Only the clicks that open it stop here; the rest pass through to the content beneath.
struct SkinMenuAnchor: NSViewRepresentable {
    let opensOnClick: Bool
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.opensOnClick = opensOnClick
        view.makeMenu = makeMenu
    }

    final class AnchorView: NSView {
        var opensOnClick = false
        var makeMenu: (() -> NSMenu)?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp: return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                return opensOnClick || event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default: return nil
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) { popUpContextMenu(event) }

        override func mouseDown(with event: NSEvent) {
            guard opensOnClick, !event.modifierFlags.contains(.control) else { popUpContextMenu(event); return }
            makeMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        }

        private func popUpContextMenu(_ event: NSEvent) {
            guard let menu = makeMenu?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

private struct SkinPlayerMenuItems: View {
    let sections: Set<String>
    let showsDislike: Bool
    let surface: SkinSurface
    let lyricsVisible: Bool
    let actions: SkinSceneActions
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AppSettings.self) private var settings
    @Environment(UIStateViewModel.self) private var uiState

    var body: some View {
        let presentation = playback.stablePresentation
        if sections.contains("info"), presentation.musicEnrichment != nil {
            Button(action: actions.openMusicInfo) { Label("音乐资料", systemImage: "text.book.closed") }
        }
        if sections.contains("track"), let track = presentation.localTrack {
            TrackActionMenuContent(
                track: track, onPlay: {}, onEditTrack: { _ in actions.openTrackEdit() },
                onDeleteFromLibraryRequest: { _ in actions.deleteTrack() }, onShowDetails: { _ in actions.openTrackDetail() },
                showsPlay: false, showsNavigation: surface == .window,
                showsDislike: showsDislike, diagnosticSurface: "SkinTrackMenu"
            )
        }
        if sections.contains("external"), presentation.source.isExternal, presentation.externalStableKey != nil {
            Button(action: actions.openExternalInfo) { Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3") }
        }
        if sections.contains("order"), presentation.isPlaybackModeControlEnabled {
            Divider()
            orderPicker(presentation)
        }
        if sections.contains("view") {
            Divider()
            if presentation.source == .local {
                Button(action: actions.toggleQueue) {
                    Label(uiState.isWindowPlaybackQueueVisible ? "隐藏播放队列" : "显示播放队列", systemImage: "list.bullet")
                }
            }
            Button(action: actions.toggleLyrics) {
                Label(lyricsVisible ? "隐藏歌词" : "显示歌词", systemImage: "quote.bubble")
            }
            if surface == .fullscreen {
                Button(action: actions.openQuickPanel) { Label("快速外观", systemImage: "slider.horizontal.3") }
                Button(action: actions.exit) { Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left") }
            } else {
                Button(action: actions.enterFullscreen) { Label("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
        }
        if sections.contains("output"), let route = AudioDSPDeviceController.current, !route.devices.isEmpty {
            Divider()
            Picker(selection: Binding(get: { settings.audioOutputDeviceUID ?? "" }, set: { actions.selectOutput($0.isEmpty ? nil : $0) })) {
                Text("跟随系统").tag("")
                ForEach(route.devices) { device in Label(device.name, systemImage: device.symbolName).tag(device.uid) }
            } label: { Label("输出设备", systemImage: route.currentDevice?.symbolName ?? "hifispeaker") }
        }
    }

    @ViewBuilder private func orderPicker(_ presentation: NowPlayingPresentation) -> some View {
        if presentation.source == .local {
            Picker(selection: Binding(get: { presentation.localPlaybackOrderMode ?? settings.playbackOrderMode }, set: { actions.setPlaybackOrder($0) })) {
                ForEach([PlaybackOrderMode.shuffle, .sequence, .repeatOne, .stopAfterTrack], id: \.self) { mode in
                    Label(Self.title(mode), systemImage: Self.symbol(mode)).tag(mode)
                }
            } label: { Label("播放顺序", systemImage: Self.symbol(presentation.localPlaybackOrderMode ?? settings.playbackOrderMode)) }
        } else {
            Picker(selection: Binding(get: { presentation.appleMusicPlaybackMode ?? .sequence }, set: { actions.setExternalPlaybackOrder($0) })) {
                ForEach(AppleMusicPlaybackMode.allCases) { mode in Text(Self.title(mode)).tag(mode) }
            } label: { Label("播放顺序", systemImage: "list.bullet") }
        }
    }

    private static func title(_ mode: PlaybackOrderMode) -> String {
        switch mode {
        case .shuffle: "随机播放"
        case .sequence: "顺序播放"
        case .repeatOne: "单曲循环"
        case .stopAfterTrack: "播完停止"
        }
    }

    private static func symbol(_ mode: PlaybackOrderMode) -> String {
        switch mode {
        case .shuffle: "shuffle"
        case .sequence: "list.bullet"
        case .repeatOne: "repeat.1"
        case .stopAfterTrack: "pause.circle"
        }
    }

    private static func title(_ mode: AppleMusicPlaybackMode) -> String {
        switch mode {
        case .sequence: "顺序播放"
        case .shuffle: "随机播放"
        case .repeatAll: "列表循环"
        case .repeatOne: "单曲循环"
        }
    }
}

extension EnvironmentValues {
    @Entry var skinSceneData: SkinSceneData?
}

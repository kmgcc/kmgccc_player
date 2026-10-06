import SwiftUI

struct SkinLyricsSlotKey: PreferenceKey {
    static var defaultValue: SkinComponentConfiguration?
    static func reduce(value: inout SkinComponentConfiguration?, nextValue: () -> SkinComponentConfiguration?) {
        value = value ?? nextValue()
    }
}

struct SkinLyricsSlot: View {
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinSceneLyricsRenderingEnabled) private var isVisible
    @Environment(\.skinSceneIsActive) private var isActive

    var body: some View {
        Group {
            if isActive { SkinNativeLyricsMount(role: surface == .window ? .main : .fullscreen) }
            else { Color.clear }
        }
            .clipped()
            .modifier(SkinLyricsEdgeFade(configuration: configuration))
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .preference(key: SkinLyricsSlotKey.self, value: configuration)
    }
}

/// Authors own content; the host owns the single native surface and recovery affordances.
struct SkinSceneHost: View {
    let skin: any NowPlayingSkin
    let scene: SkinScene
    let context: SkinContext
    let session: SkinSession
    let viewport: SkinViewport
    var lyricsVisible = true
    var onExit: (() -> Void)?
    var onToggleLyrics: (() -> Void)?
    let onRestore: () -> Void

    @Environment(SkinManager.self) private var skinManager
    @Environment(UIStateViewModel.self) private var uiState
    @ObservedObject private var fullscreen = FullscreenWindowManager.shared
    @State private var lyricsConfiguration: SkinComponentConfiguration?
    @State private var reloadError: String?

    private var role: LyricsSurfaceRole { viewport.surface == .window ? .main : .fullscreen }
    private var isActive: Bool {
        viewport.surface == .fullscreen || fullscreen.presentationMode == .none
    }
    private var nativeLyricsVisible: Bool {
        lyricsConfiguration != nil && lyricsVisible && isActive && !uiState.isWindowPlaybackQueueVisible
            && (viewport.surface != .window || uiState.skinSceneLyricsVisible)
    }

    var body: some View {
        let snapshot = SkinSceneSnapshot(context: context)
        let parameters = skinManager.catalog.parameters.values(
            skinID: skin.id, surface: viewport.surface, definitions: skin.parameterDefinitions
        )
        let components = SkinComponents(catalog: skinManager.catalog.components, snapshot: snapshot, parameters: parameters)
        SkinSceneControlHost(
            surface: viewport.surface, lyricsVisible: viewport.surface == .fullscreen ? lyricsVisible : uiState.skinSceneLyricsVisible,
            onExit: exit, onRestore: onRestore, onReload: reload,
            onToggleLyrics: toggleLyrics
        ) {
          ZStack(alignment: .topLeading) {
            if isActive {
                scene.makeContent(snapshot: snapshot, viewport: viewport, components: components)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .id(skin.id)
            } else {
                Color.clear
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }

            SkinSceneNativeLyricsLifecycle(
                role: role, configuration: lyricsConfiguration,
                isVisible: nativeLyricsVisible
            )

            if uiState.isWindowPlaybackQueueVisible && isActive {
                WindowPlaybackQueuePanelView()
                    .frame(width: min(viewport.size.width, 620), height: viewport.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .skinControlRegion()
            }
          }
        }
        .environment(\.skinSceneSurface, viewport.surface)
        .environment(\.skinSceneFullscreenHost, viewport.fullscreenHost)
        .environment(\.skinSceneLyricsRenderingEnabled, nativeLyricsVisible)
        .environment(\.skinSceneLyricsVisible, lyricsVisible && (viewport.surface == .fullscreen || uiState.skinSceneLyricsVisible))
        .environment(\.skinSceneIsActive, isActive)
        .environment(\.skinSceneSession, session)
        .environment(\.skinPackageResources, resourceDirectory)
        .onPreferenceChange(SkinLyricsSlotKey.self) { configuration in
            lyricsConfiguration = configuration
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("刷新皮肤", action: reload)
            Button("恢复外观", action: onRestore)
        }
        .alert("皮肤包", isPresented: Binding(get: { reloadError != nil }, set: { if !$0 { reloadError = nil } })) {
            Button("好", role: .cancel) { reloadError = nil }
        } message: { Text(reloadError ?? "") }

    }

    private var resourceDirectory: URL? {
        guard let skin = skin as? PackagedSkin else { return nil }
        switch skin.origin {
        case .bundled: return Bundle.main.resourceURL
        case .installed(let url): return url
        }
    }

    private func reload() {
        do { try skinManager.catalog.reload(skin.id) }
        catch { reloadError = error.localizedDescription }
    }

    private func toggleLyrics() {
        if let onToggleLyrics { onToggleLyrics() }
        else { uiState.skinSceneLyricsVisible.toggle() }
    }

    private func exit() {
        if let onExit { onExit(); return }
        switch fullscreen.presentationMode {
        case .systemFullscreenSpace: fullscreen.closeFullscreenWindow()
        case .embeddedInWindow: fullscreen.closeFullscreenPlayerInWindow()
        case .none: break
        }
    }
}

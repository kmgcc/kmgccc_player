import MotionKit
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

/// A switched-in scene cross-fades over the outgoing one on MotionKit's `backgroundTransition`.
/// The animation rides on the transition, so nothing else in the host animates with it; a scene's
/// root `enter` adds its own entrance on top.
struct SkinSceneSwitchTransition: ViewModifier {
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let policy = motionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
        content.transition(policy.animation(for: motionTokens[.backgroundTransition]).map { AnyTransition.opacity.animation($0) } ?? .identity)
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
    @State private var sceneDrawsQueue = false

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
            onToggleLyrics: toggleLyrics, controlForeground: skin.descriptor.presentation.controlForeground
        ) {
          ZStack(alignment: .topLeading) {
            if isActive {
                scene.makeContent(snapshot: snapshot, viewport: viewport, components: components)
                    .transformEnvironment(\.skinSceneActions) { actions in
                        actions.setParameter = { id, value in
                            guard let definition = skin.parameterDefinitions.first(where: { $0.id == id }) else { return }
                            skinManager.catalog.parameters.set(skinID: skin.id, surface: viewport.surface, definition: definition, value: value)
                        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .id(skin.id)
                    .onPreferenceChange(SkinSceneControlsKey.self) { sceneDrawsQueue = $0.contains(.queue) }
            } else {
                Color.clear
                    .frame(width: viewport.size.width, height: viewport.size.height)
            }

            SkinSceneNativeLyricsLifecycle(
                role: role, configuration: lyricsConfiguration,
                isVisible: nativeLyricsVisible
            )

            if uiState.isWindowPlaybackQueueVisible && isActive && !sceneDrawsQueue {
                WindowPlaybackQueuePanelView()
                    .frame(width: min(viewport.size.width, 620), height: viewport.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .skinControlRegion()
            }
          }
        }
        .environment(\.skinSceneSurface, viewport.surface)
        .environment(\.skinScenePresentation, skin.descriptor.presentation)
        .environment(\.skinSceneFullscreenHost, viewport.fullscreenHost)
        .environment(\.skinSceneLyricsRenderingEnabled, nativeLyricsVisible)
        .environment(\.skinSceneLyricsVisible, lyricsVisible && (viewport.surface == .fullscreen || uiState.skinSceneLyricsVisible))
        .environment(\.skinSceneIsActive, isActive)
        .environment(\.skinSceneSession, session)
        .environment(\.skinPackageResources, resourceDirectory)
        .environment(\.skinPackageFonts, (skin as? PackagedSkin)?.manifest.fonts ?? [])
        .onPreferenceChange(SkinLyricsSlotKey.self) { configuration in
            lyricsConfiguration = configuration
        }
        .contentShape(Rectangle())
        .contextMenuWithVisibleIcons {
            if SkinRegistry.customizationEnabled {
                Button("刷新皮肤", action: reload)
                Button("恢复外观", action: onRestore)
            }
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
        case .development(let url): return url
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

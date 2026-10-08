import MotionKit
import SwiftUI

/// Ephemeral UI belongs to the host, not to each component. Commands still use the
/// existing coordinator; sheets, mandatory chrome and Quick Panel stay above the scene.
struct SkinSceneControlHost<Content: View>: View {
    let surface: SkinSurface
    let lyricsVisible: Bool
    let onExit: () -> Void
    let onRestore: () -> Void
    let onReload: () -> Void
    let onToggleLyrics: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(LibraryViewModel.self) private var library
    @Environment(LibraryCacheServices.self) private var caches
    @Environment(AppSettings.self) private var settings
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var theme: ThemeStore
    @State private var controls = FullscreenBottomControlsCoordinator()
    @State private var providedControls: Set<SkinSceneControl> = []
    @State private var hitRegions = SkinSceneHitRegions()
    @State private var editingTrack: Track?
    @State private var editingExternalInfo = false
    @State private var showingSettings = false
    @State private var detailTrack: Track?

    private var nativeContext: SkinNativeControlsContext {
        let material: LiquidGlassPillMaterialStyle = settings.fullscreenMiniPlayerGlassMaterial == .normal ? .normal : .clear
        let profile = FullscreenMiniPlayerForegroundStrategy.resolve(
            palette: theme.semanticPalette, localArtworkPolarity: nil,
            hasArtworkThemeColor: theme.palette != nil, controlForeground: .chrome,
            colorScheme: theme.colorScheme, materialStyle: material, fullscreenArtBackgroundEnabled: false
        )
        return .init(
            presentation: .init(
                glassStyle: .init(colorScheme: theme.colorScheme, accentColor: theme.accentColor, materialStyle: material),
                miniPlayerForegroundProfile: profile,
                quickPanelForegroundProfile: .init(primary: profile.primary, isDarkForeground: theme.colorScheme == .light),
                primaryColor: Color(nsColor: profile.primary), iconBlendMode: profile.iconBlendMode,
                playbackMode: playback.stablePresentation.localPlaybackOrderMode ?? settings.playbackOrderMode,
                hasTrack: playback.stablePresentation.hasTrack, isShowingLyrics: lyricsVisible,
                isVolumeControlEnabled: playback.stablePresentation.isVolumeControlEnabled,
                usesAdaptiveVolumeForeground: false, showsPlaybackModeRetapTip: false
            ),
            actions: .init(
                exitFullscreen: surface == .fullscreen ? onExit : enterFullscreen,
                toggleLyrics: onToggleLyrics,
                setQuickAppearancePanelPresented: { presented in
                    if surface == .fullscreen { controls.isQuickAppearancePanelPresented = presented }
                    else { presentSettings() }
                },
                hotZoneHoverChanged: { _ in }, centerHoverChanged: { _ in },
                leadingHoverChanged: { _ in }, trailingHoverChanged: { _ in },
                appearancePanelHoverChanged: { _ in }, progressDraggingChanged: { _ in },
                volumeAdjustingChanged: { _ in }, interaction: {},
                playbackModeChanged: { playback.setPlaybackOrderMode($0) },
                currentPlaybackModeRetapped: { _ in uiState.toggleWindowPlaybackQueue() },
                editTrackRequested: { editingTrack = $0 }, editExternalInfoRequested: { editingExternalInfo = true },
                showDetailRequested: { detailTrack = $0 }, dismissPlaybackModeRetapTip: {}
            ), controls: controls
        )
    }

    var body: some View {
        let native = nativeContext
        content()
            .environment(\.skinNativeControls, native)
            .environment(\.skinSceneHitRegions, hitRegions)
            .environment(\.skinSceneActions, actions)
            .onPreferenceChange(SkinSceneControlsKey.self) { providedControls = $0 }
            .overlay(alignment: .topTrailing) {
                if surface == .fullscreen {
                    HStack(spacing: 12) {
                        if !providedControls.contains(.fullscreen) { SkinActionButton(reportsControls: false, kind: .fullscreen, configuration: .init()) }
                        if !providedControls.contains(.lyricsToggle) { SkinActionButton(reportsControls: false, kind: .lyricsToggle, configuration: .init()) }
                        if !providedControls.contains(.quickPanel) { SkinActionButton(reportsControls: false, kind: .quickPanel, configuration: .init()) }
                    }
                    .environment(\.skinNativeControls, native)
                    .environment(\.skinSceneSurface, surface)
                    .environment(\.skinSceneActions, actions)
                    .padding(12)
                }
            }
            .overlay {
                GeometryReader { proxy in
                    if controls.isQuickAppearancePanelPresented {
                        let scale = max(0.1, min(1, (proxy.size.width - 32) / 560, (proxy.size.height - 32) / 690))
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { controls.isQuickAppearancePanelPresented = false }
                            .skinControlRegion()
                        FullscreenQuickAppearancePanel(
                            scale: scale, foregroundProfile: native.presentation.quickPanelForegroundProfile,
                            onDismiss: { controls.isQuickAppearancePanelPresented = false }
                        )
                        .frame(width: 560 * scale, height: 690 * scale)
                        .skinControlRegion()
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                }
            }
            .overlayPreferenceValue(SkinControlRegionKey.self) { anchors in
                GeometryReader { proxy in
                    SkinSceneHitRegionBridge(regions: hitRegions, rectangles: anchors.map { proxy[$0] })
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: $editingTrack) { TrackEditSheet(track: $0).environmentObject(theme) }
            .sheet(isPresented: $editingExternalInfo) {
                ExternalPlaybackInfoEditorView(
                    presentation: playback.presentation, metadataStore: caches.externalPlaybackMetadataStore,
                    onSaved: { playback.invalidateExternalPlaybackResolution(onlyOffsetChanged: $0) }
                ).environmentObject(theme)
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                FeatureTipPresentationCoordinator.shared.setSuspended(false, reason: .settingsSheet)
            }) {
                SettingsView(hasActiveLibrarySession: true).environmentObject(theme)
            }
            .sheet(item: $detailTrack) { track in
                let detail = TrackDetailResolver.resolve(for: track, libraryVM: library)
                FullscreenDetailReaderPanel(
                    title: detail.subtitle, attributionNote: detail.attributionNote, text: detail.text,
                    scale: 0.8, foregroundProfile: native.presentation.quickPanelForegroundProfile,
                    onDismiss: { detailTrack = nil }
                )
            }
    }

    private func presentSettings() {
        FeatureTipPresentationCoordinator.shared.setSuspended(true, reason: .settingsSheet)
        showingSettings = true
    }

    private func enterFullscreen() { FullscreenWindowManager.shared.showFullscreenPlayerInWindow() }

    private var actions: SkinSceneActions {
        .init(
            playPause: { playback.playPause() }, previous: { playback.previous() }, next: { playback.next() },
            seek: { playback.seek(to: $0) }, setVolume: { playback.setVolume($0) },
            setPlaybackOrder: { playback.setPlaybackOrderMode($0) },
            setExternalPlaybackOrder: { playback.setAppleMusicPlaybackMode($0) },
            like: {
                guard let track = playback.stablePresentation.localTrack else { return }
                let liked = library.preferenceStats(for: track.id).manualLikeState == .liked
                Task { await library.setManualLikeState(liked ? .none : .liked, for: track) }
            },
            toggleQueue: { uiState.toggleWindowPlaybackQueue() }, toggleLyrics: onToggleLyrics,
            enterFullscreen: enterFullscreen, exit: onExit,
            openSettings: { presentSettings() }, openQuickPanel: { if surface == .fullscreen { controls.isQuickAppearancePanelPresented = true } else { presentSettings() } },
            reload: onReload, restore: onRestore
        )
    }
}

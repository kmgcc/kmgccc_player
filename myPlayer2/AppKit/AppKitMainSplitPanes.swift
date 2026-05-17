//
//  AppKitMainSplitPanes.swift
//  myPlayer2
//
//  SwiftUI roots hosted inside AppKitMainSplitViewController panes.
//  These views intentionally avoid SwiftUI .toolbar/.searchable and custom glass backgrounds.
//

import SwiftData
import SwiftUI

struct AppKitMainSidebarPaneRoot: View {
    @ObservedObject var appSession: AppSessionHost

    var body: some View {
        if let libraryVM = appSession.libraryVM,
           let playerVM = appSession.playerVM,
           let playbackCoordinator = appSession.playbackCoordinator,
           let lyricsVM = appSession.lyricsVM,
           let ledMeterProvider = appSession.ledMeterProvider,
           let importEnrichmentService = appSession.importEnrichmentService,
            let skinManager = appSession.skinManager {
            SidebarView()
                .environment(AppSettings.shared)
                .environment(appSession.uiState)
                .environment(libraryVM)
                .environment(playerVM)
               .environment(playbackCoordinator)
               .environment(lyricsVM)
               .environment(ledMeterProvider)
               .environment(importEnrichmentService)
               .environment(skinManager)
               .environmentObject(ThemeStore.shared)
                .environment(\.libraryPresentedAccentColor, ThemeStore.shared.accentColor)
                .modelContainer(appSession.sharedModelContainer)
                .tint(ThemeStore.shared.accentColor)
                .accentColor(ThemeStore.shared.accentColor)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppKitMainContentPaneRoot: View {
    @ObservedObject var appSession: AppSessionHost
    @ObservedObject private var fullscreenWindowManager = FullscreenWindowManager.shared
    @StateObject private var themeStore = ThemeStore.shared
    @ObservedObject var artBackgroundController: BKArtBackgroundController
    @State private var settings = AppSettings.shared
    @State private var coverDownloadService = CoverDownloadService()
    @State private var netEaseCoverService = NetEaseCoverService()
    @State private var hasPresentedNowPlayingArtBackground = false
    @Environment(\.colorScheme) private var swiftUIColorScheme

    let pageController: PlaylistPageController

    var body: some View {
        let uiState = appSession.uiState
        if let libraryVM = appSession.libraryVM,
           let playerVM = appSession.playerVM,
           let playbackCoordinator = appSession.playbackCoordinator,
           let lyricsVM = appSession.lyricsVM,
           let ledMeterProvider = appSession.ledMeterProvider,
           let importEnrichmentService = appSession.importEnrichmentService,
           let skinManager = appSession.skinManager {
            contentView(
                uiState: uiState,
                libraryVM: libraryVM,
                playerVM: playerVM,
                playbackCoordinator: playbackCoordinator,
                lyricsVM: lyricsVM,
                ledMeterProvider: ledMeterProvider,
                importEnrichmentService: importEnrichmentService,
                skinManager: skinManager
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// True when the active library selection is `.home` and content mode is
    /// `.library`. The center pane renders a transparent placeholder in that
    /// case (the real `HomeView` lives in the full-window Home host) and the
    /// passthrough hosting view forwards clicks to the host below.
    private func isHomeMode(uiState: UIStateViewModel, libraryVM: LibraryViewModel) -> Bool {
        uiState.contentMode == .library && libraryVM.currentSelection == .home
    }

    private func contentView(
        uiState: UIStateViewModel,
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        playbackCoordinator: PlaybackCoordinator,
        lyricsVM: LyricsViewModel,
        ledMeterProvider: LEDMeterServiceProvider,
        importEnrichmentService: ImportEnrichmentService,
        skinManager: SkinManager
    ) -> some View {
        let homeMode = isHomeMode(uiState: uiState, libraryVM: libraryVM)
        let homeSearchActive = homeMode
            && !pageController.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let base = ZStack(alignment: .bottomLeading) {
            // Transparent center-rect probe. Reports the center pane's
            // presence so the center pane keeps its normal layout footprint.
            // AppKitMainSplitViewController publishes the center rect
            // synchronously from the split view frames; doing it here with a
            // SwiftUI geometry callback lags during live window resize.
            Color.clear
                .allowsHitTesting(false)

            Group {
                switch uiState.contentMode {
                case .library:
                    switch libraryVM.currentSelection {
                    case .home:
                        if homeSearchActive {
                            PlaylistDetailView(pageController: pageController)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .id("appkit-main-home-search")
                        } else {
                            // The real HomeView is rendered by
                            // HomeFullWindowRoot in the AppKit window's
                            // full-window Home host. The center pane only
                            // contributes a transparent passthrough here so
                            // hits/scrolls fall through to that host below.
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .allowsHitTesting(false)
                                .id("appkit-main-home")
                        }
                    case .allAlbums:
                        AllAlbumsView(pageController: pageController)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .id("appkit-main-all-albums")
                    case .allArtists:
                        AllArtistsView(pageController: pageController)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .id("appkit-main-all-artists")
                    case .allSongs, .playlist, .artist, .album:
                        PlaylistDetailView(pageController: pageController)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .id("appkit-main-library")
                    }
                case .nowPlaying:
                    GeometryReader { proxy in
                        NowPlayingHostView(
                            mainContentWidth: proxy.size.width,
                            artBackgroundIsUltraDark: settings.nowPlayingArtBackgroundEnabled
                                && artBackgroundController.isUltraDarkActive
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .id("appkit-main-nowplaying")
                }
            }

            if !FullscreenWindowManager.shared.isWindowedFullscreenActive {
                GeometryReader { proxy in
                    MiniPlayerView()
                        .onGeometryChange(for: CGRect.self) { geometry in
                            geometry.frame(in: .global)
                        } action: { newRect in
                            HomeWindowLayoutState.shared.setMiniPlayerFrame(newRect)
                        }
                        .frame(maxWidth: proxy.size.width, alignment: .leading)
                        .padding(.leading, GlassStyleTokens.miniPlayerHorizontalPadding)
                        .padding(.trailing, GlassStyleTokens.miniPlayerHorizontalPadding)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .allowsHitTesting(true)
            }

            if fullscreenWindowManager.isWindowedFullscreenActive {
                FullscreenPlayerView(hostContext: .embeddedWindow) {
                    fullscreenWindowManager.closeFullscreenPlayerInWindow()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(1)
            }
        }

        let withAppear: some View = base
            .onAppear {
                applyAppearanceToWindows()
                syncThemeStoreWithSwiftUIColorScheme(swiftUIColorScheme)
                syncFullscreenWindowEditorDependencies()
                HomeWindowLayoutState.shared.setEmbeddedFullscreenActive(
                    fullscreenWindowManager.isWindowedFullscreenActive
                )
                HomeWindowLayoutState.shared.setHomeMode(homeMode)
                HomeWindowLayoutState.shared.setHomeSearchActive(homeSearchActive)
                if shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    _ = markNowPlayingArtBackgroundPresentationIfNeeded()
                }
            }
            .onChange(of: homeMode) { _, newValue in
                HomeWindowLayoutState.shared.setHomeMode(newValue)
            }
            .onChange(of: homeSearchActive) { _, newValue in
                HomeWindowLayoutState.shared.setHomeSearchActive(newValue)
            }
            .onChange(of: libraryVM.searchResetTrigger) { _, _ in
                pageController.clearSearchAndRebuildIfNeeded(reason: "search-reset")
            }

        let withSettingsChanges: some View = withAppear
            .onChange(of: settings.followSystemAppearance) { (_: Bool, _: Bool) in
                applyAppearanceToWindows()
            }
            .onChange(of: settings.manualAppearance) { (_: AppSettings.ManualAppearance, _: AppSettings.ManualAppearance) in
                applyAppearanceToWindows()
            }
            .onChange(of: settings.globalArtworkTintEnabled) { (_: Bool, _: Bool) in
                Task { @MainActor in
                    await themeStore.refreshPalette(reason: "global_artwork_tint_toggle")
                }
            }

        let withTasks: some View = withSettingsChanges
            .task(id: libraryVM.state) {
                guard libraryVM.state == .loading else { return }
                // Avoid double-reload when reloadLibrary() is already in progress.
                guard libraryVM.loadingPhase.isIdle || libraryVM.loadingPhase.isFailed else { return }
                await libraryVM.load()
            }
            .onChange(of: swiftUIColorScheme) { (_: ColorScheme, newScheme: ColorScheme) in
                syncThemeStoreWithSwiftUIColorScheme(newScheme)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
                Task { @MainActor in
                    await themeStore.updateTheme(for: playbackCoordinator.presentation)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
                guard let trackID = notification.userInfo?["trackID"] as? UUID else { return }
                guard let refreshedTrack = libraryVM.allTracks.first(where: { $0.id == trackID }) else {
                    return
                }
                playerVM.refreshTracks([refreshedTrack])
            }
            // Theme/artwork updates depend on playbackCoordinator.presentation, which the
            // 0.25s presentationTimer reassigns during playback. Subscribing to it here
            // would invalidate this body every 0.25s, reinstantiating PlaylistDetailView
            // and tearing down the open contextMenu's hover state. Isolate it in a tiny
            // child view so only that child re-renders on presentation ticks.
            .background(PlaybackThemeArtworkWatcher())

        let withEvents: some View = withTasks
            .onChange(of: uiState.contentMode) { (_: ContentMode, newValue: ContentMode) in
                handleContentModeChange(newValue, playbackCoordinator: playbackCoordinator, uiState: uiState)
            }
            .onChange(of: playerVM.currentTrack?.id) { (_: UUID?, _: UUID?) in
                if shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    artBackgroundController.triggerTransition()
                }
            }
            .onChange(of: settings.nowPlayingArtBackgroundEnabled) { (_: Bool, enabled: Bool) in
                if enabled && shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    artBackgroundController.triggerTransition()
                }
            }
            .onChange(of: fullscreenWindowManager.presentationMode) { (_: FullscreenWindowManager.PresentationMode, mode: FullscreenWindowManager.PresentationMode) in
                HomeWindowLayoutState.shared.setEmbeddedFullscreenActive(mode == .embeddedInWindow)
                if mode == .none && shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    artBackgroundController.triggerTransition()
                }
            }

        return withEvents
            .environment(AppSettings.shared)
            .environment(appSession.uiState)
            .environment(appSession.homeVM)
            .environment(libraryVM)
            .environment(playerVM)
            .environment(playbackCoordinator)
            .environment(lyricsVM)
            .environment(ledMeterProvider)
            .environment(importEnrichmentService)
            .environment(skinManager)
            .environment(coverDownloadService)
            .environment(netEaseCoverService)
            .environmentObject(themeStore)
            .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
            .modelContainer(appSession.sharedModelContainer)
            .tint(themeStore.accentColor)
            .accentColor(themeStore.accentColor)
    }

    private func handleContentModeChange(
        _ newValue: ContentMode,
        playbackCoordinator: PlaybackCoordinator,
        uiState: UIStateViewModel
    ) {
        guard newValue == .nowPlaying else { return }
        guard shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) else {
            return
        }
        if markNowPlayingArtBackgroundPresentationIfNeeded() {
            return
        }
        artBackgroundController.triggerTransition()
    }

    private func shouldShowArtBackground(
        playbackCoordinator: PlaybackCoordinator,
        uiState: UIStateViewModel
    ) -> Bool {
        uiState.contentMode == .nowPlaying
            && settings.nowPlayingArtBackgroundEnabled
            && settings.selectedNowPlayingSkinID != AppleStyleSkin.skinID
            && playbackCoordinator.presentation.hasTrack
            && !fullscreenWindowManager.usesFullscreenPlayerUI
    }

    private func shouldTriggerArtBackgroundTransition(
        playbackCoordinator: PlaybackCoordinator,
        uiState: UIStateViewModel
    ) -> Bool {
        shouldShowArtBackground(playbackCoordinator: playbackCoordinator, uiState: uiState)
    }

    private func artworkBackgroundTrackID(playbackCoordinator: PlaybackCoordinator) -> UUID? {
        let presentation = playbackCoordinator.presentation
        if let artworkTrackID = presentation.artworkDisplayTrackID {
            return artworkTrackID
        }
        if let localID = presentation.localTrack?.id {
            return localID
        }
        return presentation.source.isExternal && presentation.hasTrack
            ? UUID(uuidString: "3C7BB22E-1A57-4B8B-8461-A48B9646AA7C")
            : nil
    }

    @discardableResult
    private func markNowPlayingArtBackgroundPresentationIfNeeded() -> Bool {
        let isFirstPresentation = !hasPresentedNowPlayingArtBackground
        if isFirstPresentation {
            hasPresentedNowPlayingArtBackground = true
        }
        return isFirstPresentation
    }

    private func applyAppearanceToWindows() {
        if settings.followSystemAppearance {
            NSApp.appearance = nil
            for window in NSApp.windows {
                window.appearance = nil
            }
            return
        }

        let appearanceName: NSAppearance.Name = settings.manualAppearance == .dark ? .darkAqua : .aqua
        let appearance = NSAppearance(named: appearanceName)
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    private func syncThemeStoreWithSwiftUIColorScheme(_ newScheme: ColorScheme) {
        themeStore.colorScheme = newScheme
        Task { @MainActor in
            await themeStore.refreshPalette(reason: "swiftui_colorScheme_changed")
        }
    }

    private func syncFullscreenWindowEditorDependencies() {
        FullscreenWindowManager.shared.configureEditorServices(
            coverDownloadService: coverDownloadService,
            netEaseCoverService: netEaseCoverService
        )
    }
}

/// Subscribes to `playbackCoordinator.presentation` in isolation so the parent
/// content pane's body does not re-evaluate every 0.25 s when the presentation
/// timer reassigns the value. Renders an invisible zero-size layer.
private struct PlaybackThemeArtworkWatcher: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: artworkIdentity) {
                await themeStore.updateTheme(for: playbackCoordinator.presentation)
            }
    }

    private var artworkIdentity: String {
        let presentation = playbackCoordinator.presentation
        let identity =
            presentation.artworkIdentity
            ?? presentation.externalStableKey
            ?? presentation.lyricsIdentity
            ?? presentation.localTrack?.id.uuidString
            ?? "none"
        return "\(presentation.source.rawValue)|track:\(presentation.hasTrack)|art:\(identity)"
    }
}

struct AppKitMainLyricsPaneRoot: View {
    @ObservedObject var appSession: AppSessionHost

    var body: some View {
        if let libraryVM = appSession.libraryVM,
           let playerVM = appSession.playerVM,
           let playbackCoordinator = appSession.playbackCoordinator,
           let lyricsVM = appSession.lyricsVM,
           let ledMeterProvider = appSession.ledMeterProvider,
           let importEnrichmentService = appSession.importEnrichmentService,
           let skinManager = appSession.skinManager {
            LyricsPanelView(hostContainer: .appKitInspector)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Let the inspector pane content visually extend under the unified titlebar/toolbar glass,
                // matching the system split+inspector pattern (avoids a “fake” blank strip at the top).
                .ignoresSafeArea(.container, edges: .top)
            .environment(AppSettings.shared)
            .environment(appSession.uiState)
            .environment(libraryVM)
            .environment(playerVM)
            .environment(playbackCoordinator)
            .environment(lyricsVM)
            .environment(ledMeterProvider)
            .environment(importEnrichmentService)
            .environment(skinManager)
            .environmentObject(ThemeStore.shared)
            .environment(\.libraryPresentedAccentColor, ThemeStore.shared.accentColor)
            .modelContainer(appSession.sharedModelContainer)
            .tint(ThemeStore.shared.accentColor)
            .accentColor(ThemeStore.shared.accentColor)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppKitMainWindowArtBackgroundLayer: View {
    @ObservedObject var appSession: AppSessionHost
    let playlistPageController: PlaylistPageController
    @ObservedObject var artBackgroundController: BKArtBackgroundController
    @ObservedObject private var fullscreenWindowManager = FullscreenWindowManager.shared
    @StateObject private var themeStore = ThemeStore.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            if shouldShowPlaylistHeaderBackground {
                HeaderFullWindowBackgroundView(
                    state: playlistPageController.haloState,
                    currentSource: playlistPageController.haloCurrentImage,
                    incomingSource: playlistPageController.haloIncomingImage,
                    sourceBlendOpacity: playlistPageController.haloSourceBlendOpacity,
                    presentationOpacity: playlistPageController.haloPresentationOpacity,
                    xOffset: playlistHeaderBackgroundXOffset,
                    yOffset: 32
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .all)
            }

            if let playbackCoordinator = appSession.playbackCoordinator,
               shouldShowArtBackground(playbackCoordinator: playbackCoordinator) {
                BKArtBackgroundView(
                    controller: artBackgroundController,
                    trackID: artworkBackgroundTrackID(playbackCoordinator: playbackCoordinator),
                    artworkData: playbackCoordinator.presentation.artworkData,
                    isPlaying: playbackCoordinator.presentation.isPlaying,
                    resourceProfile: settings.selectedNowPlayingSkinID == "kmgccc.cassette"
                        ? .cassetteForeground
                        : .standard,
                    initialPalette: [themeStore.accentNSColor]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.container, edges: .all)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .all)
    }

    private var shouldShowPlaylistHeaderBackground: Bool {
        let selection = appSession.libraryVM?.currentSelection ?? .allSongs
        let isPlaylistContext: Bool
        switch selection {
        case .home, .allAlbums, .allArtists:
            isPlaylistContext = false
        case .allSongs, .playlist, .artist, .album:
            isPlaylistContext = true
        }
        return appSession.uiState.contentMode == .library
            && isPlaylistContext
            && playlistPageController.rendersHeaderBackgroundInWindowLayer
            && playlistPageController.isHeaderEffectsEnabled
            && (playlistPageController.haloCurrentImage != nil || playlistPageController.haloIncomingImage != nil)
            && !fullscreenWindowManager.usesFullscreenPlayerUI
    }

    private var playlistHeaderBackgroundXOffset: CGFloat {
        guard appSession.uiState.sidebarVisible else { return 0 }
        return max(appSession.uiState.sidebarLastWidth, Constants.Layout.sidebarMinWidth)
    }

    private func shouldShowArtBackground(playbackCoordinator: PlaybackCoordinator) -> Bool {
        appSession.uiState.contentMode == .nowPlaying
            && settings.nowPlayingArtBackgroundEnabled
            && settings.selectedNowPlayingSkinID != AppleStyleSkin.skinID
            && playbackCoordinator.presentation.hasTrack
            && !fullscreenWindowManager.usesFullscreenPlayerUI
    }

    private func artworkBackgroundTrackID(playbackCoordinator: PlaybackCoordinator) -> UUID? {
        let presentation = playbackCoordinator.presentation
        if let artworkTrackID = presentation.artworkDisplayTrackID {
            return artworkTrackID
        }
        if let localID = presentation.localTrack?.id {
            return localID
        }
        return presentation.source.isExternal && presentation.hasTrack
            ? UUID(uuidString: "3C7BB22E-1A57-4B8B-8461-A48B9646AA7C")
            : nil
    }
}

// MARK: - Flat AppKit lyrics driver view

/// Zero-sized SwiftUI driver for the `lyrics.debug.windowUseFlatAppKitHost` diagnostic.
/// Provides the same LyricsViewModel observation/lifecycle as LyricsPanelView
/// with no visual content. Embedded as a zero-sized child NSHostingController
/// inside LyricsFlatAppKitHostViewController.
struct LyricsFlatDriverView: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    // Key matches AMLLKeys.lyricsRenderQuality in AppSettings. Default "medium" matches AppSettings default.
    @AppStorage("amllLyricsRenderQuality") private var amllLyricsRenderQuality: String = "medium"

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                setupSeekCallback()
                reloadLyrics(reason: "flat driver appear")
            }
            .onDisappear {
                LyricsSurfaceManager.shared.reportMainVisible(false)
            }
            .onChange(of: playbackCoordinator.presentation.lyricsIdentity) { oldId, newId in
                guard oldId != newId else { return }
                reloadLyrics(reason: "track changed", forceLyricsReload: true)
            }
            .onChange(of: uiState.lyricsVisible) { _, isVisible in
                guard isVisible else { return }
                LyricsSurfaceManager.shared.reportMainVisible(true)
                reloadLyrics(reason: "lyrics expanded")
            }
            .onChange(of: playbackCoordinator.presentation.lyricsText) { _, _ in
                guard playbackCoordinator.presentation.source.isExternal else { return }
                reloadLyrics(reason: "external lyrics updated", forceLyricsReload: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
                reloadLyrics(reason: "playback track notification", forceLyricsReload: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
                guard
                    let trackID = notification.userInfo?["trackID"] as? UUID,
                    trackID == playbackCoordinator.presentation.localTrack?.id
                else { return }
                reloadLyrics(reason: "library track update", forceLyricsReload: true)
            }
            .onChange(of: themeStore.colorScheme) { _, _ in
                lyricsVM.refreshConfigFromSettings()
            }
            // Real-time sync — inlined from LyricsRealtimeSyncObserver (which is private).
            .onChange(of: playbackCoordinator.presentation.currentTime) { oldTime, newTime in
                lyricsVM.syncTime(newTime)
                if oldTime > 1.0, newTime < 0.2 {
                    reloadLyrics(reason: "playback restarted", forceLyricsReload: true)
                }
            }
            .onChange(of: playbackCoordinator.presentation.isPlaying) { _, newValue in
                if !newValue {
                    lyricsVM.syncTime(playbackCoordinator.presentation.currentTime)
                }
                lyricsVM.setPlaying(newValue)
            }
            .modifier(LyricsSettingsObserver(lyricsVM: lyricsVM))
            .onChange(of: amllLyricsRenderQuality) { _, newValue in
                let scale = AppSettings.AMLLLyricsRenderQuality(rawValue: newValue)?.webViewScale ?? 0.75
                LyricsSurfaceManager.shared.mainStore.setRenderQualityScale(
                    scale,
                    reason: "flatDriver.qualityChanged"
                )
            }
    }

    private func setupSeekCallback() {
        let coordinator = playbackCoordinator
        lyricsVM.onSeekRequest = { seconds in
            coordinator.seek(to: seconds)
        }
    }

    private func reloadLyrics(reason: String, forceWebReload: Bool = false, forceLyricsReload: Bool = false) {
        let presentation = playbackCoordinator.presentation
        switch presentation.source {
        case .local:
            lyricsVM.ensureAMLLLoaded(
                track: presentation.localTrack,
                currentTime: presentation.currentTime,
                isPlaying: presentation.isPlaying,
                reason: reason,
                forceWebReload: forceWebReload,
                forceLyricsReload: forceLyricsReload
            )
        case .appleMusic, .systemNowPlaying:
            lyricsVM.ensureExternalAMLLLoaded(
                presentation: presentation,
                reason: reason,
                forceWebReload: forceWebReload,
                forceLyricsReload: forceLyricsReload
            )
        }
    }
}

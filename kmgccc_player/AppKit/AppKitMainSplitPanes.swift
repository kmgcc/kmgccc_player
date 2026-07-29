//
//  AppKitMainSplitPanes.swift
//  myPlayer2
//
//  SwiftUI roots hosted inside AppKitMainSplitViewController panes.
//  These views intentionally avoid SwiftUI .toolbar/.searchable and custom glass backgrounds.
//

import AppKit
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
           let cacheServices = appSession.cacheServices,
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

               .environment(cacheServices)
               .environment(skinManager)
               .environmentObject(appSession)
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

private struct NoLibrarySetupPlaceholder: View {
    @ObservedObject var appSession: AppSessionHost
    @State private var registry = MusicLibraryRegistry()

    var body: some View {
        ScrollView {
            LibrarySetupFlow(
                flow: appSession.librarySetupFlow,
                registry: registry,
                onChange: {}
            )
            .environmentObject(appSession)
            .environmentObject(ThemeStore.shared)
            .frame(maxWidth: 500)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBaseBackgroundColorView())
        .task {
            registry = await appSession.musicLibraryRegistrySnapshot()
            if appSession.librarySetupFlow.presentation == .none {
                appSession.librarySetupFlow.present(.setup(.managed))
            }
        }
    }
}

struct AppKitMainContentPaneRoot: View {
    @ObservedObject var appSession: AppSessionHost
    @ObservedObject private var fullscreenWindowManager = FullscreenWindowManager.shared
    @ObservedObject private var crashReportService = CrashReportService.shared
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
           let cacheServices = appSession.cacheServices,
           let skinManager = appSession.skinManager {
            contentView(
                uiState: uiState,
                libraryVM: libraryVM,
                playerVM: playerVM,
                playbackCoordinator: playbackCoordinator,
                lyricsVM: lyricsVM,
                ledMeterProvider: ledMeterProvider,
                importEnrichmentService: importEnrichmentService,
                cacheServices: cacheServices,
                skinManager: skinManager
            )
        } else {
            NoLibrarySetupPlaceholder(appSession: appSession)
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
        cacheServices: LibraryCacheServices,
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
              if fullscreenWindowManager.isWindowedFullscreenActive {
                // Embedded fullscreen presents an opaque, full-pane overlay
                // (see `FullscreenPlayerView` zIndex(1) below). The heavy detail
                // content beneath it is fully occluded, so tear it down while
                // embedded fullscreen is active: it saves the cost of keeping
                // `PlaylistDetailView` / `NowPlayingHostView` live, and removes
                // the layer that showed through during cover-switch transients.
                // It is re-rendered automatically when embedded fullscreen exits.
                Color.clear
              } else {
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
                    case .allPlaylists:
                        AllPlaylistsView(pageController: pageController)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .id("appkit-main-all-playlists")
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
                case .playbackHistory:
                    PlaybackHistoryView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id("appkit-main-playback-history")
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
                .environment(AppSettings.shared)
                .environment(appSession.uiState)
                .environment(libraryVM)
                .environment(playerVM)
                .environment(playbackCoordinator)
                .environment(lyricsVM)
                .environment(ledMeterProvider)
                .environment(importEnrichmentService)

                .environment(cacheServices)
                .environment(skinManager)
                .environment(coverDownloadService)
                .environment(netEaseCoverService)
                .environmentObject(themeStore)
                .modelContainer(appSession.sharedModelContainer)
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
            .environment(appSession.playbackHistoryStore)
            .environment(appSession.playbackHistoryViewModel)
            .environment(libraryVM)
            .environment(playerVM)
            .environment(playbackCoordinator)
            .environment(lyricsVM)
            .environment(ledMeterProvider)
            .environment(importEnrichmentService)

            .environment(cacheServices)
            .environment(skinManager)
            .environment(coverDownloadService)
            .environment(netEaseCoverService)
            .environmentObject(themeStore)
            .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
            .modelContainer(appSession.sharedModelContainer)
            .tint(themeStore.accentColor)
            .accentColor(themeStore.accentColor)
            .sheet(item: crashPromptBinding) { _ in
                CrashReportPromptSheet(
                    onCancel: {
                        crashReportService.cancelCurrentPrompt()
                    },
                    onExport: { description in
                        try await crashReportService.exportCurrentPrompt(description: description)
                    },
                    onSend: { description in
                        crashReportService.sendCurrentPrompt(description: description)
                    }
                )
            }
    }

    private var crashPromptBinding: Binding<CrashReportPromptPresentation?> {
        Binding(
            get: { crashReportService.currentPrompt },
            set: { _ in }
        )
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
        return "\(presentation.source.rawValue)|track:\(presentation.hasTrack)|art:\(identity)|loading:\(presentation.isArtworkLoading)|sig:\(ArtworkDataFingerprint.sampledString(for: presentation.artworkData))"
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
           let cacheServices = appSession.cacheServices,
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

            .environment(cacheServices)
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
        GeometryReader { proxy in
            ZStack {
                ThemedBaseBackgroundColorView()

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
                   isRenderableWindowBackgroundSize(proxy.size),
                   shouldShowAppleStyleWindowBackground(playbackCoordinator: playbackCoordinator) {
                    SkinRegistry.skin(for: AppleStyleSkin.skinID)
                        .makeBackground(context: makeAppleStyleWindowContext(
                            windowSize: proxy.size,
                            playbackCoordinator: playbackCoordinator
                        ))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .ignoresSafeArea(.container, edges: .all)
                        .allowsHitTesting(false)
                }

                if let playbackCoordinator = appSession.playbackCoordinator,
                   shouldShowArtBackground(playbackCoordinator: playbackCoordinator) {
                    BKArtBackgroundView(
                        controller: artBackgroundController,
                        trackID: artworkBackgroundTrackID(playbackCoordinator: playbackCoordinator),
                        artworkData: renderingArtworkData(playbackCoordinator: playbackCoordinator),
                        isPlaying: playbackCoordinator.presentation.isPlaying,
                        animationEnabled: appSession.uiState.contentMode == .nowPlaying
                            && !fullscreenWindowManager.usesFullscreenPlayerUI,
                        resourceProfile: settings.selectedNowPlayingSkinID == "kmgccc.cassette"
                            ? .cassetteForeground
                            : .standard,
                        initialPalette: [themeStore.accentNSColor],
                        holdPaletteWhenArtworkMissing: playbackCoordinator.presentation.isArtworkLoading
                            && renderingArtworkData(playbackCoordinator: playbackCoordinator) == nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(.container, edges: .all)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .all)
    }

    private var shouldShowPlaylistHeaderBackground: Bool {
        let selection = appSession.libraryVM?.currentSelection ?? .allSongs
        let isPlaylistContext: Bool
        switch selection {
        case .home, .allPlaylists, .allAlbums, .allArtists:
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

    private func shouldShowAppleStyleWindowBackground(playbackCoordinator: PlaybackCoordinator) -> Bool {
        appSession.uiState.contentMode == .nowPlaying
            && settings.selectedNowPlayingSkinID == AppleStyleSkin.skinID
            && !fullscreenWindowManager.usesFullscreenPlayerUI
    }

    private func isRenderableWindowBackgroundSize(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 1
            && size.height > 1
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

    private func renderingArtworkData(playbackCoordinator: PlaybackCoordinator) -> Data? {
        let presentation = playbackCoordinator.presentation
        if let artworkData = presentation.artworkData, !artworkData.isEmpty {
            return artworkData
        }
        guard ArtworkRenderingFallback.shouldUse(
            for: presentation.artworkData,
            isArtworkLoading: presentation.isArtworkLoading
        ) else {
            return nil
        }
        return ArtworkRenderingFallback.data(for: artworkBackgroundTrackID(playbackCoordinator: playbackCoordinator))
    }

    private func makeAppleStyleWindowContext(
        windowSize: CGSize,
        playbackCoordinator: PlaybackCoordinator
    ) -> SkinContext {
        let presentation = playbackCoordinator.presentation
        let effectiveArtworkData = renderingArtworkData(playbackCoordinator: playbackCoordinator)
        let artworkChecksum = ArtworkDataFingerprint.sampledHash(for: effectiveArtworkData)

        let trackMeta: SkinContext.TrackMetadata? = presentation.hasTrack
            ? SkinContext.TrackMetadata(
                id: presentation.artworkDisplayTrackID
                    ?? presentation.displayTrackID
                    ?? presentation.localTrack?.id
                    ?? UUID(uuidString: "9D7D2E53-8CC0-4E65-8B19-7D9E772E6D43")!,
                title: presentation.title,
                artist: presentation.artist,
                album: presentation.album ?? "",
                duration: presentation.duration,
                artworkChecksum: artworkChecksum,
                artworkData: effectiveArtworkData,
                artworkImage: nil,
                displayedArtworkID: nil
            )
            : nil

        let playback = SkinContext.PlaybackState(
            isPlaying: presentation.isPlaying,
            currentTime: presentation.currentTime,
            duration: presentation.duration,
            progress: presentation.progress
        )

        let analysis = themeStore.semanticPalette.analysis
        let primary: [NSColor]
        if !analysis.displayPalette.isEmpty {
            primary = analysis.displayPalette
        } else if !analysis.topPalette.isEmpty {
            primary = analysis.topPalette
        } else {
            primary = [
                themeStore.semanticPalette.artBackgroundPrimary,
                themeStore.semanticPalette.artBackgroundSecondary,
            ]
        }
        let chosen = Array(primary.prefix(2))
        let spectrumArtworkColors = SpectrumColorResolver.prepareSpectrumColors(chosen, analysis: analysis)

        let audioMetrics = appSession.ledMeterProvider?.audioMetrics ?? .zero
        let ledMetrics = appSession.ledMeterProvider?.metrics
            ?? LEDMeterMetrics.zero(count: LEDDefaults.ledCount)

        let theme = SkinContext.ThemeTokens(
            accentColor: themeStore.accentColor,
            colorScheme: themeStore.colorScheme,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            glassIntensity: settings.liquidGlassIntensity,
            backgroundBlur: settings.nowPlayingBackgroundBlur,
            backgroundBrightness: settings.nowPlayingBackgroundBrightness,
            backgroundSaturation: settings.nowPlayingBackgroundSaturation,
            meshAmplitude: settings.nowPlayingMeshAmplitude,
            meshFlowSpeed: settings.nowPlayingMeshFlowSpeed,
            meshSharpness: settings.nowPlayingMeshSharpness,
            meshSoftness: settings.nowPlayingMeshSoftness,
            meshColorBoost: settings.nowPlayingMeshColorBoost,
            meshContrast: settings.nowPlayingMeshContrast,
            meshBassImpact: settings.nowPlayingMeshBassImpact,
            artworkAccentColor: themeStore.hasArtworkThemeColor ? themeStore.accentColor : nil,
            artworkPalette: primary,
            artworkRichPalette: analysis.displayPalette,
            artworkAverageColor: nil,
            artBackgroundIsUltraDark: false,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: analysis.usesDarkForeground,
            cassetteTint: themeStore.semanticPalette.cassetteTint,
            kickToBrightnessMix: settings.bgKickToBrightnessMix,
            kickDisplaceAmount: settings.bgKickDisplaceAmount,
            kickScaleAmount: settings.bgKickScaleAmount
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            audio: audioMetrics,
            led: ledMetrics,
            theme: theme,
            windowSize: windowSize,
            contentBounds: CGRect(origin: .zero, size: windowSize),
            fullscreenScale: 1.0,
            lyricsVisible: appSession.uiState.lyricsVisible,
            presentationMode: .nowPlaying,
            fullscreenHostMode: .none
        )
    }
}

// MARK: - Flat AppKit lyrics background view

/// Background layer for `LyricsFlatAppKitHostViewController`.
/// Mirrors `LyricsPanelView.appKitInspectorBackgroundLayer` so the lyrics panel
/// material setting is respected in the flat host diagnostic path.
/// Observes `AppSettings.lyricsBackgroundMode` and updates live when changed.
struct FlatLyricsBackgroundView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch settings.lyricsBackgroundMode {
        case .sidebar:
            // System inspector pane provides the Liquid Glass background automatically.
            Color.clear
                .allowsHitTesting(false)
        case .clear:
            Rectangle()
                .fill(.ultraThinMaterial)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Flat AppKit lyrics driver view

/// Zero-sized SwiftUI driver for the flat AppKit lyrics host.
/// Provides the non-visual LyricsViewModel observation/lifecycle with no
/// SwiftUI view wrapping the WKWebView itself.
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
                syncMainLyricsVisibility(
                    isVisible: isLyricsSurfaceActive,
                    reason: "flat driver appear"
                )
            }
            .onDisappear {
                LyricsSurfaceManager.shared.reportMainVisible(false)
            }
            .onChange(of: playbackCoordinator.presentation.lyricsIdentity) { oldId, newId in
                guard oldId != newId else { return }
                LyricsRuntimeProfile.increment("LyricsFlatDriverView.trackIDChange")
            }
            .onChange(of: playbackCoordinator.presentation.hasTrack) { _, hasTrack in
                syncMainLyricsVisibility(
                    isVisible: isLyricsSurfaceActive,
                    reason: "flat driver hasTrack changed",
                    hasTrackOverride: hasTrack
                )
            }
            .onChange(of: uiState.lyricsVisible) { _, isVisible in
                syncMainLyricsVisibility(
                    isVisible: isVisible && !uiState.isWindowPlaybackQueueVisible,
                    reason: isVisible ? "flat lyrics expanded" : "flat lyrics collapsed"
                )
            }
            .onChange(of: uiState.isWindowPlaybackQueueVisible) { _, isQueueVisible in
                syncMainLyricsVisibility(
                    isVisible: uiState.lyricsVisible && !isQueueVisible,
                    reason: isQueueVisible ? "flat window queue opened" : "flat window queue closed"
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
                guard isLyricsSurfaceActive else { return }
                guard
                    let trackID = notification.userInfo?["trackID"] as? UUID,
                    trackID == playbackCoordinator.presentation.localTrack?.id
                else { return }
                reloadLyrics(reason: "library track update", forceLyricsReload: true)
            }
            .onChange(of: themeStore.colorScheme) { _, _ in
                guard isLyricsSurfaceActive else { return }
                lyricsVM.refreshConfigFromSettings()
            }
            // Real-time sync — inlined from LyricsRealtimeSyncObserver (which is private).
            .onChange(of: playbackCoordinator.presentation.currentTime) { oldTime, newTime in
                guard isLyricsSurfaceActive else { return }
                lyricsVM.syncTime(playbackCoordinator.presentation.lyricsCurrentTime)
                if oldTime > 1.0, newTime < 0.2 {
                    reloadLyrics(reason: "playback restarted", forceLyricsReload: true)
                }
            }
            .onChange(of: playbackCoordinator.presentation.isPlaying) { _, newValue in
                guard isLyricsSurfaceActive else { return }
                if !newValue {
                    lyricsVM.syncTime(playbackCoordinator.presentation.lyricsCurrentTime)
                }
                lyricsVM.setPlaying(newValue)
            }
            .modifier(LyricsSettingsObserver(lyricsVM: lyricsVM, isActive: isLyricsSurfaceActive))
            .onChange(of: amllLyricsRenderQuality) { _, newValue in
                guard isLyricsSurfaceActive else { return }
                let scale = AppSettings.AMLLLyricsRenderQuality(rawValue: newValue)?.webViewScale ?? 0.75
                LyricsSurfaceManager.shared.mainStore.setRenderQualityScale(
                    scale,
                    reason: "flatDriver.qualityChanged"
                )
            }
    }

    private var isLyricsSurfaceActive: Bool {
        // uiState stays true across fullscreen only as a restoration marker.
        // Do not let the hidden flat-host driver keep syncing the window store.
        LyricsSurfaceManager.shared.targetMode == .main
            && uiState.lyricsVisible
            && !uiState.isWindowPlaybackQueueVisible
    }

    private func setupSeekCallback() {
        let coordinator = playbackCoordinator
        lyricsVM.onSeekRequest = { seconds in
            coordinator.seek(to: seconds)
        }
    }

    private func syncMainLyricsVisibility(
        isVisible: Bool,
        reason: String,
        hasTrackOverride: Bool? = nil
    ) {
        setupSeekCallback()
        guard LyricsSurfaceManager.shared.targetMode == .main else {
            LyricsSurfaceManager.shared.reportMainVisible(false)
            return
        }
        let hasTrack = hasTrackOverride ?? playbackCoordinator.presentation.hasTrack
        guard isVisible, hasTrack else {
            LyricsSurfaceManager.shared.reportMainVisible(false)
            return
        }

        let shouldRevealExistingLyrics =
            LyricsSurfaceManager.shared.currentMode == .main
            && LyricsSurfaceManager.shared.switchState == .idle
            && LyricsSurfaceManager.shared.existingStore(for: .main)?.isReady == true

        LyricsSurfaceManager.shared.reportMainVisible(true)
        reloadLyrics(reason: reason)
        // A mode switch/new WebView already receives the full AMLL
        // setLyricLines entrance from snapshot replay. Only a ready, already
        // active main surface uses the lightweight existing-line relayout.
        if shouldRevealExistingLyrics {
            lyricsVM.revealExistingLyrics(reason: reason)
        }
    }

    private func reloadLyrics(reason: String, forceWebReload: Bool = false, forceLyricsReload: Bool = false) {
        let presentation = playbackCoordinator.presentation
        switch presentation.source {
        case .local:
            lyricsVM.ensureAMLLLoaded(
                track: presentation.localTrack,
                currentTime: presentation.lyricsCurrentTime,
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

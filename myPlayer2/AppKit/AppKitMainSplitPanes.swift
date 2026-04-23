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
            ZStack(alignment: .bottomLeading) {
                Group {
                    switch uiState.contentMode {
                    case .library:
                        PlaylistDetailView(pageController: pageController)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .id("appkit-main-library")
                    case .nowPlaying:
                        GeometryReader { proxy in
                            NowPlayingHostView(mainContentWidth: proxy.size.width)
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
            .onAppear {
                let session = String(ObjectIdentifier(appSession).hashValue)
                let library = appSession.libraryVM.map { String(ObjectIdentifier($0).hashValue) } ?? "nil"
                let playback = appSession.playbackCoordinator.map { String(ObjectIdentifier($0).hashValue) } ?? "nil"
                print("[AppKitMainContentPane] appear appSession=\(session) pageController=\(ObjectIdentifier(pageController).hashValue) libraryVM=\(library) playbackCoord=\(playback) contentMode=\(uiState.contentMode)")
                applyAppearanceToWindows()
                syncThemeStoreWithSwiftUIColorScheme(swiftUIColorScheme)
                syncFullscreenWindowEditorDependencies()
                if shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    _ = markNowPlayingArtBackgroundPresentationIfNeeded()
                }
            }
            .onChange(of: settings.followSystemAppearance) { _, _ in
                applyAppearanceToWindows()
            }
            .onChange(of: settings.manualAppearance) { _, _ in
                applyAppearanceToWindows()
            }
            .onChange(of: settings.globalArtworkTintEnabled) { _, _ in
                Task { @MainActor in
                    await themeStore.refreshPalette(reason: "global_artwork_tint_toggle")
                }
            }
            .task(id: libraryVM.state) {
                guard libraryVM.state == .loading else { return }
                print("[AppKitMainContentPane] library.load.begin state=\(libraryVM.state)")
                await libraryVM.load()
                print(
                    "[AppKitMainContentPane] library.load.end state=\(libraryVM.state) "
                        + "playlists=\(libraryVM.playlists.count) tracks=\(libraryVM.totalTrackCount)"
                )
            }
            .onChange(of: swiftUIColorScheme) { _, newScheme in
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
            .task(id: playbackThemeArtworkIdentity(playbackCoordinator: playbackCoordinator)) {
                await themeStore.updateTheme(for: playbackCoordinator.presentation)
            }
            .onChange(of: uiState.contentMode) { _, newValue in
                guard newValue == .nowPlaying else { return }
                guard shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) else {
                    return
                }
                if markNowPlayingArtBackgroundPresentationIfNeeded() {
                    return
                }
                artBackgroundController.triggerTransition()
            }
            .onChange(of: playerVM.currentTrack?.id) { _, _ in
                if shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    artBackgroundController.triggerTransition()
                }
            }
            .onChange(of: settings.nowPlayingArtBackgroundEnabled) { _, enabled in
                if enabled && shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    artBackgroundController.triggerTransition()
                }
            }
            .onChange(of: fullscreenWindowManager.presentationMode) { _, mode in
                if mode == .none && shouldTriggerArtBackgroundTransition(playbackCoordinator: playbackCoordinator, uiState: uiState) {
                    artBackgroundController.triggerTransition()
                }
            }
            .environment(AppSettings.shared)
            .environment(appSession.uiState)
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
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func playbackThemeArtworkIdentity(playbackCoordinator: PlaybackCoordinator) -> String {
        let presentation = playbackCoordinator.presentation
        let identity =
            presentation.artworkIdentity
            ?? presentation.externalStableKey
            ?? presentation.lyricsIdentity
            ?? presentation.localTrack?.id.uuidString
            ?? "none"
        return "\(presentation.source.rawValue)|track:\(presentation.hasTrack)|art:\(identity)"
    }

    private func shouldShowArtBackground(
        playbackCoordinator: PlaybackCoordinator,
        uiState: UIStateViewModel
    ) -> Bool {
        uiState.contentMode == .nowPlaying
            && settings.nowPlayingArtBackgroundEnabled
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
        return presentation.source == .appleMusic && presentation.hasTrack
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
        appSession.uiState.contentMode == .library
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
        return presentation.source == .appleMusic && presentation.hasTrack
            ? UUID(uuidString: "3C7BB22E-1A57-4B8B-8461-A48B9646AA7C")
            : nil
    }
}

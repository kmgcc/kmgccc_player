//
//  AppKitMainSplitPanes.swift
//  myPlayer2
//
//  SwiftUI roots hosted inside AppKitMainSplitViewController panes.
//  These views intentionally avoid SwiftUI .toolbar/.searchable and custom glass backgrounds.
//

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
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppKitMainContentPaneRoot: View {
    @ObservedObject var appSession: AppSessionHost
    @State private var playlistPageController = PlaylistPageController()

    var body: some View {
        let uiState = appSession.uiState
        if let libraryVM = appSession.libraryVM,
           let playerVM = appSession.playerVM,
           let playbackCoordinator = appSession.playbackCoordinator,
           let lyricsVM = appSession.lyricsVM,
           let ledMeterProvider = appSession.ledMeterProvider,
           let importEnrichmentService = appSession.importEnrichmentService,
           let skinManager = appSession.skinManager {
            Group {
                switch uiState.contentMode {
                case .library:
                    PlaylistDetailView(pageController: playlistPageController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id("appkit-main-library")
                case .nowPlaying:
                    GeometryReader { proxy in
                        NowPlayingHostView(mainContentWidth: proxy.size.width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .id("appkit-main-nowplaying")
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
            .environmentObject(ThemeStore.shared)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

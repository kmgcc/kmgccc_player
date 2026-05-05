//
//  HomeFullWindowRoot.swift
//  myPlayer2
//
//  SwiftUI root mounted in the AppKit window's full-window Home host (a
//  sibling layer between the art background and the split view). It only
//  renders the real `HomeView` when the active library selection is
//  `.home` and content mode is `.library`; otherwise it returns an empty
//  `Color.clear` that yields hit-testing entirely so clicks/scrolls fall
//  through to whatever lies beneath the host (the art background layer).
//
//  Environments injected here mirror the set provided by
//  `AppKitMainContentPaneRoot.contentView(...)` so `HomeView` and its
//  sections behave identically to when they were rendered inside the
//  center pane.
//

import SwiftData
import SwiftUI

struct HomeFullWindowRoot: View {
    @ObservedObject var appSession: AppSessionHost
    @StateObject private var themeStore = ThemeStore.shared
    @State private var settings = AppSettings.shared
    @State private var coverDownloadService = CoverDownloadService()
    @State private var netEaseCoverService = NetEaseCoverService()
    @State private var layout = HomeWindowLayoutState.shared

    var body: some View {
        Group {
            if shouldRenderHome {
                if let libraryVM = appSession.libraryVM,
                   let playerVM = appSession.playerVM,
                   let playbackCoordinator = appSession.playbackCoordinator,
                   let lyricsVM = appSession.lyricsVM,
                   let ledMeterProvider = appSession.ledMeterProvider,
                   let importEnrichmentService = appSession.importEnrichmentService,
                   let skinManager = appSession.skinManager {
                    HomeView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        .environment(\.homeLiveResizeRendering, layout.isLiveResizing)
                        .environment(\.libraryPresentedAccentColor, themeStore.accentColor)
                        .modelContainer(appSession.sharedModelContainer)
                        .tint(themeStore.accentColor)
                        .accentColor(themeStore.accentColor)
                }
            } else {
                Color.clear
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .all)
    }

    private var shouldRenderHome: Bool {
        guard layout.allowsHomeInteraction else { return false }
        guard let libraryVM = appSession.libraryVM else { return false }
        return appSession.uiState.contentMode == .library
            && libraryVM.currentSelection == .home
    }
}

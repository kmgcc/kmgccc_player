//
//  NowPlayingSettingsContainerView.swift
//  myPlayer2
//
//  kmgccc_player - Window Playback Settings with Tab Navigation
//

import SwiftUI

/// Container view for Now Playing settings with "常规" and "歌词" tabs.
struct NowPlayingSettingsContainerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerViewModel.self) private var playerVM
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var selectedTab = 0
    private let tabs = ["常规", "歌词"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("settings.section.now_playing", systemImage: "sparkles")

            // Tab selector
            SettingsTabSelector(tabs: tabs, selectedTab: $selectedTab)
                .environmentObject(themeStore)

            // Tab content
            switch selectedTab {
            case 0:
                NowPlayingGeneralTabView()
            case 1:
                NowPlayingLyricsTabView()
            default:
                NowPlayingGeneralTabView()
            }
        }
    }
}
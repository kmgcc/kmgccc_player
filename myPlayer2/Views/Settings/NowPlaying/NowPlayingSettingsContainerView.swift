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
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @State private var selectedTab = 0
    private let tabs = ["常规", "歌词", "LED"]

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.containerSpacing) {
            SettingsHeaderLabel("settings.section.now_playing", systemImage: "sparkles")

            SettingsTabSelector(tabs: tabs, selectedTab: $selectedTab, fillsWidth: true)
                .environmentObject(themeStore)

            switch selectedTab {
            case 0:
                NowPlayingGeneralTabView()
            case 1:
                NowPlayingLyricsTabView()
            case 2:
                LEDMeterSettingsView(showTitle: false)
            default:
                NowPlayingGeneralTabView()
            }
        }
    }
}

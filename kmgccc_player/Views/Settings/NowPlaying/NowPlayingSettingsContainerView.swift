//
//  NowPlayingSettingsContainerView.swift
//  myPlayer2
//
//  kmgccc_player - Window Playback Settings with Tab Navigation
//

import SwiftUI

/// Container view for Now Playing settings with "皮肤" and "歌词" tabs.
struct NowPlayingSettingsContainerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerViewModel.self) private var playerVM
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @State private var selectedTab = 0
    private let tabs = ["皮肤", "歌词"]

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.containerSpacing) {
            SettingsHeaderLabel("settings.section.now_playing", systemImage: "macwindow")

            SettingsTabSelector(tabs: tabs, selectedTab: $selectedTab, fillsWidth: true)
                .environmentObject(themeStore)

            switch selectedTab {
            case 1:
                NowPlayingLyricsTabView()
            default:
                NowPlayingGeneralTabView()
            }
        }
    }
}

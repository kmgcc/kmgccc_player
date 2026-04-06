//
//  FullscreenSettingsContainerView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Playback Settings with Tab Navigation
//

import SwiftUI

/// Container view for Fullscreen settings with "皮肤" and "歌词" tabs.
struct FullscreenSettingsContainerView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var selectedTab = 0
    private let tabs = ["皮肤", "歌词"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right")

            // Tab selector
            SettingsTabSelector(tabs: tabs, selectedTab: $selectedTab)
                .environmentObject(themeStore)

            // Tab content
            switch selectedTab {
            case 0:
                FullscreenSkinTabView()
            case 1:
                FullscreenLyricsTabView()
            default:
                FullscreenSkinTabView()
            }
        }
    }
}
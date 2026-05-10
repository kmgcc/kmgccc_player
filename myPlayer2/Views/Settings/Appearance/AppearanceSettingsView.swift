//
//  AppearanceSettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Appearance Settings View
//

import SwiftUI

/// Appearance settings: global tint, system appearance, lyrics background mode.
struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var globalArtworkTintEnabled: Bool = AppSettings.shared.globalArtworkTintEnabled
    @State private var dockProgressVisible: Bool = AppSettings.shared.dockProgressVisible
    @State private var followSystemAppearance: Bool = AppSettings.shared.followSystemAppearance
    @State private var lyricsBackgroundMode: AppSettings.LyricsBackgroundMode = AppSettings.shared.lyricsBackgroundMode
    @State private var homeCardMaterialMode: AppSettings.HomeCardMaterialMode = AppSettings.shared.homeCardMaterialMode

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外观", systemImage: "paintpalette")

            SettingsSection {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSwitchRow(
                        title: "全局取色",
                        isOn: $globalArtworkTintEnabled,
                        detail: "开启后重点色跟随当前歌曲封面，关闭后使用默认主题色。"
                    )

                    SettingsSwitchRow(
                        title: "Dock 播放进度",
                        isOn: $dockProgressVisible,
                        detail: "开启后 Dock 图标底部显示当前歌曲进度"
                    )

                    SettingsSwitchRow(
                        title: "跟随系统",
                        isOn: $followSystemAppearance,
                        detail: "开启后跟随系统深浅色，关闭后可用侧边栏按钮手动切换深/浅。"
                    )

                    Divider()

                    lyricsBackgroundModePicker

                    homeCardMaterialModePicker
                }
            }
        }
        .onAppear {
            globalArtworkTintEnabled = settings.globalArtworkTintEnabled
            dockProgressVisible = settings.dockProgressVisible
            followSystemAppearance = settings.followSystemAppearance
            lyricsBackgroundMode = settings.lyricsBackgroundMode
            homeCardMaterialMode = settings.homeCardMaterialMode
        }
        .onChange(of: globalArtworkTintEnabled) { _, newValue in
            settings.globalArtworkTintEnabled = newValue
            Task { @MainActor in
                await themeStore.refreshPalette(reason: "settings_global_tint_change")
            }
        }
        .onChange(of: dockProgressVisible) { _, newValue in
            settings.dockProgressVisible = newValue
        }
        .onChange(of: followSystemAppearance) { _, newValue in
            settings.followSystemAppearance = newValue
        }
        .onChange(of: lyricsBackgroundMode) { _, newValue in
            settings.lyricsBackgroundMode = newValue
        }
        .onChange(of: homeCardMaterialMode) { _, newValue in
            settings.homeCardMaterialMode = newValue
        }
    }

    private var lyricsBackgroundModePicker: some View {
        HStack(spacing: 8) {
            Text("歌词卡片背景")
                .settingsRowLabelStyle()

            Spacer()

            SlidingSelector(
                segments: AppSettings.LyricsBackgroundMode.allCases,
                selection: $lyricsBackgroundMode,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { mode, isSelected in
                    Text(mode.title)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var homeCardMaterialModePicker: some View {
        HStack(spacing: 8) {
            Text("主页卡片材质")
                .settingsRowLabelStyle()

            Spacer()

            SlidingSelector(
                segments: AppSettings.HomeCardMaterialMode.allCases,
                selection: $homeCardMaterialMode,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(themeStore.accentColor.opacity(0.18))
                },
                content: { mode, isSelected in
                    Text(mode.title)
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

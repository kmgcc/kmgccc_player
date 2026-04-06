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
    @State private var followSystemAppearance: Bool = AppSettings.shared.followSystemAppearance
    @State private var lyricsBackgroundMode: AppSettings.LyricsBackgroundMode = AppSettings.shared.lyricsBackgroundMode

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外观", systemImage: "paintpalette")

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("全局取色", isOn: $globalArtworkTintEnabled)
                        .toggleStyle(.switch)
                    Text("开启后重点色跟随当前歌曲封面；关闭后使用默认主题色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("跟随系统", isOn: $followSystemAppearance)
                        .toggleStyle(.switch)
                    Text("开启后跟随系统深浅色；关闭后可用侧边栏按钮手动切换深/浅。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    lyricsBackgroundModePicker
                }
                .padding(12)
            }
        }
        .onAppear {
            globalArtworkTintEnabled = settings.globalArtworkTintEnabled
            followSystemAppearance = settings.followSystemAppearance
            lyricsBackgroundMode = settings.lyricsBackgroundMode
        }
        .onChange(of: globalArtworkTintEnabled) { _, newValue in
            settings.globalArtworkTintEnabled = newValue
            Task { @MainActor in
                await themeStore.refreshPalette(reason: "settings_global_tint_change")
            }
        }
        .onChange(of: followSystemAppearance) { _, newValue in
            settings.followSystemAppearance = newValue
        }
        .onChange(of: lyricsBackgroundMode) { _, newValue in
            settings.lyricsBackgroundMode = newValue
        }
    }

    private var lyricsBackgroundModePicker: some View {
        HStack(spacing: 8) {
            Text("歌词背景")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                ForEach(AppSettings.LyricsBackgroundMode.allCases) { mode in
                    Button {
                        lyricsBackgroundMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 11, weight: lyricsBackgroundMode == mode ? .medium : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule()
                            .fill(lyricsBackgroundMode == mode ? themeStore.accentColor.opacity(0.18) : Color.clear)
                    )
                    .foregroundStyle(lyricsBackgroundMode == mode ? themeStore.accentColor : .secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }
}
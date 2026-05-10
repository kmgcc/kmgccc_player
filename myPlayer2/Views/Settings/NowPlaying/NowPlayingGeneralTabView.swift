//
//  NowPlayingGeneralTabView.swift
//  myPlayer2
//
//  kmgccc_player - Window Playback General Settings Tab
//

import SwiftUI

/// General settings tab for window playback: art background and skin selection.
struct NowPlayingGeneralTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerViewModel.self) private var playerVM
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @State private var nowPlayingSkin: String = AppSettings.shared.selectedNowPlayingSkinID
    @State private var nowPlayingArtBackgroundEnabled: Bool = AppSettings.shared.nowPlayingArtBackgroundEnabled

    @AppStorage("skin.classicLED.visualizerMode") private var classicVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.visualizerMode") private var cassetteVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var cassetteShowKmgLook: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
            SettingsSection("视觉效果") {
                VStack(alignment: .leading, spacing: presentationStyle.rowSpacing) {
                    SettingsSwitchRow(
                        title: "启用艺术背景",
                        isOn: $nowPlayingArtBackgroundEnabled,
                        detail: "遇到性能问题时，可以关闭此选项",
                        detailFont: presentationStyle.captionFont
                    )
                }
            }

            SettingsSection("settings.now_playing.select_skin") {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    SkinSelectorRow(
                        skins: SkinRegistry.nowPlayingOptions,
                        selectedSkinID: $nowPlayingSkin
                    )
                }
            }

            if let selected = SkinRegistry.options.first(where: { $0.id == nowPlayingSkin }),
               let optionsView = SkinRegistry.skin(for: nowPlayingSkin).settingsView {
                SettingsSection(
                    String(
                        format: NSLocalizedString(
                            "settings.now_playing.skin_options", comment: ""), selected.name)
                ) {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        optionsView
                    }
                }
            }
        }
        .onAppear {
            nowPlayingSkin = settings.selectedNowPlayingSkinID
            nowPlayingArtBackgroundEnabled = settings.nowPlayingArtBackgroundEnabled
        }
        .onChange(of: nowPlayingSkin) { _, newValue in
            settings.selectedNowPlayingSkinID = newValue
            playerVM.refreshLedMeterStateFromSettings()
        }
        .onChange(of: nowPlayingArtBackgroundEnabled) { _, newValue in
            settings.nowPlayingArtBackgroundEnabled = newValue
        }
    }
}

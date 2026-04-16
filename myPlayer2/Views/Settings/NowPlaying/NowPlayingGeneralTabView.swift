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

    @State private var nowPlayingSkin: String = AppSettings.shared.selectedNowPlayingSkinID
    @State private var nowPlayingArtBackgroundEnabled: Bool = AppSettings.shared.nowPlayingArtBackgroundEnabled

    @AppStorage("skin.classicLED.visualizerMode") private var classicVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.visualizerMode") private var cassetteVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var cassetteShowKmgLook: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Art background toggle
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用艺术背景 (Beta)", isOn: $nowPlayingArtBackgroundEnabled)
                        .toggleStyle(.switch)
                    Text("遇到性能问题时，可以关闭此选项。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            // Skin selection
            Text("settings.now_playing.select_skin")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("", selection: $nowPlayingSkin) {
                        ForEach(SkinRegistry.nowPlayingOptions) { skin in
                            Label(skin.name, systemImage: skin.systemImage)
                                .tag(skin.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let selected = SkinRegistry.nowPlayingOptions.first(where: {
                        $0.id == nowPlayingSkin
                    }) {
                        Text(LocalizedStringKey(selected.detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Skin-specific options
            if let selected = SkinRegistry.options.first(where: { $0.id == nowPlayingSkin }),
               let optionsView = SkinRegistry.skin(for: nowPlayingSkin).settingsView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "settings.now_playing.skin_options", comment: ""), selected.name)
                    )
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                    GroupBox {
                        optionsView
                            .padding(12)
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
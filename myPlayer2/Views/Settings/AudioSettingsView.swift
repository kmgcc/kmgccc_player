//
//  AudioSettingsView.swift
//  myPlayer2
//
//  Audio output settings, including the optional visualization-sync delay.
//

import SwiftUI

@MainActor
struct AudioSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var lookaheadEnabled: Bool = AppSettings.shared.audioLookaheadEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("音频", systemImage: "waveform")

            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSwitchRow(title: "音频延迟补偿", isOn: $lookaheadEnabled)

                    Text("开启后会略微延迟真实声音，用来改善 LED、频谱和歌词等可视化与听感的同步。关闭后音频输出更直接、延迟更低，适合追求最低延迟或排查卡顿。\n\n更改会在下一首歌曲或重新播放时生效。")
                        .settingsDescriptionStyle()
                }
            }
        }
        .onAppear {
            lookaheadEnabled = settings.audioLookaheadEnabled
        }
        .onChange(of: lookaheadEnabled) { _, newValue in
            settings.audioLookaheadEnabled = newValue
        }
    }
}

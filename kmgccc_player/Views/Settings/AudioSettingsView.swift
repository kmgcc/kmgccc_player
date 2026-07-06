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

                    Text("开启后声音输出将延迟以改善LED、频谱等音频可视化效果的同步。")
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

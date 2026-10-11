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
    @EnvironmentObject private var appSession: AppSessionHost

    @State private var volumeControlTarget: AppSettings.VolumeControlTarget = AppSettings.shared.volumeControlTarget
    @State private var lookaheadEnabled: Bool = AppSettings.shared.audioLookaheadEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("音频", systemImage: "waveform")

            SettingsSection("通用") {
                VStack(alignment: .leading, spacing: 14) {
                    CapsulePicker(
                        label: "音量调节目标",
                        options: AppSettings.VolumeControlTarget.allCases,
                        selection: $volumeControlTarget,
                        displayName: { $0.title }
                    )

                    Divider()

                    SettingsSwitchRow(title: "音频延迟补偿", isOn: $lookaheadEnabled)

                    Text("延迟音频输出以对齐频谱与可视化动效。")
                        .settingsDescriptionStyle()
                }
            }

            AudioProcessingGlobalsSettingsView(
                controller: appSession.audioProcessingGlobalsController
            )

            SettingsSection {
                SettingsSubpageLink(
                    title: "音效处理",
                    subtitle: "均衡器、效果链与预设",
                    page: .audioDSP
                )
            }
        }
        .onAppear {
            volumeControlTarget = settings.volumeControlTarget
            lookaheadEnabled = settings.audioLookaheadEnabled
        }
        .onChange(of: volumeControlTarget) { _, newValue in
            settings.volumeControlTarget = newValue
        }
        .onChange(of: lookaheadEnabled) { _, newValue in
            settings.audioLookaheadEnabled = newValue
        }
    }
}

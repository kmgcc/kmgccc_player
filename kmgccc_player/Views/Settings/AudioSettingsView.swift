//
//  AudioSettingsView.swift
//  myPlayer2
//
//  Audio output settings, including general playback options and DSP devices.
//

import SwiftUI

@MainActor
struct AudioSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @State private var selectedTab = 0
    private let tabs = ["常规", "音效与设备"]

    @State private var volumeControlTarget: AppSettings.VolumeControlTarget = AppSettings.shared.volumeControlTarget
    @State private var lookaheadEnabled: Bool = AppSettings.shared.audioLookaheadEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.containerSpacing) {
            SettingsHeaderLabel("音频", systemImage: "waveform")

            SettingsTabSelector(tabs: tabs, selectedTab: $selectedTab, fillsWidth: true)
                .environmentObject(themeStore)

            switch selectedTab {
            case 0:
                generalTab
            case 1:
                AudioDSPSettingsView(embedsInTab: true)
            default:
                generalTab
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

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
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
        }
    }
}

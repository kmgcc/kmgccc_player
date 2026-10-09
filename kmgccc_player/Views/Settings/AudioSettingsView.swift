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

    @Environment(\.navigateSettingsSubpage) private var navigateSettingsSubpage

    @State private var lookaheadEnabled: Bool = AppSettings.shared.audioLookaheadEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("音频", systemImage: "waveform")

            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsSwitchRow(title: "音频延迟补偿", isOn: $lookaheadEnabled)

                    Text("延迟音频输出以对齐频谱与可视化动效。")
                        .settingsDescriptionStyle()
                }
            }

            AudioProcessingGlobalsSettingsView(
                controller: appSession.audioProcessingGlobalsController
            )

            SettingsSection("音效处理") {
                Button {
                    navigateSettingsSubpage(.audioDSP)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DSP 音效")
                                .settingsRowLabelStyle()
                            Text("九段均衡器、增益与预设")
                                .settingsDescriptionStyle()
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Capsule())
                }
                .audioDSPCapsuleButtonStyle()
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

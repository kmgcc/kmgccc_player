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

            AudioProcessingGlobalsSettingsView(
                controller: appSession.audioProcessingGlobalsController
            )

            SettingsSection("音效处理") {
                NavigationLink {
                    AudioDSPSettingsView()
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

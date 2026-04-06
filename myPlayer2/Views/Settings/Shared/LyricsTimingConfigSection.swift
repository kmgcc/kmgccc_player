//
//  LyricsTimingConfigSection.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Lyrics Timing Configuration Section
//

import SwiftUI

/// Lyrics timing parameters configuration section.
/// These parameters are shared between window and fullscreen lyrics.
struct LyricsTimingConfigSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsViewModel.self) private var lyricsVM
    @EnvironmentObject private var themeStore: ThemeStore

    // Local state for slider binding (fixes UI update issue with @ObservationIgnored properties)
    @State private var leadInMs: Double = 600
    @State private var nearSwitchGapMs: Double = 160
    @State private var globalAdvanceMs: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("settings.lyrics.timing")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认值") {
                    leadInMs = 600
                    nearSwitchGapMs = 160
                    globalAdvanceMs = 0
                    syncToSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Text("参数仅供调试，正常使用无需调整")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("同时作用于窗口与全屏歌词")
                .font(.caption2)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    leadInSection
                    Divider()
                    nearSwitchGapSection
                    Divider()
                    globalAdvanceSection
                }
                .padding(12)
            }
        }
        .onAppear {
            leadInMs = settings.lyricsLeadInMs
            nearSwitchGapMs = settings.lyricsNearSwitchGapMs
            globalAdvanceMs = settings.lyricsGlobalAdvanceMs
        }
        .onChange(of: leadInMs) { _, _ in syncToSettings() }
        .onChange(of: nearSwitchGapMs) { _, _ in syncToSettings() }
        .onChange(of: globalAdvanceMs) { _, _ in syncToSettings() }
    }

    private var leadInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.lyrics.leadin")
                Spacer()
                Text("\(Int(leadInMs)) ms")
                    .foregroundStyle(themeStore.accentColor)
                    .font(.system(.subheadline, design: .monospaced))
            }
            Slider(value: $leadInMs, in: 0...1200, step: 20)
            Text("settings.lyrics.leadin_desc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var nearSwitchGapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("settings.lyrics.near_switch_gap")
                Spacer()
                Text("\(Int(nearSwitchGapMs)) ms")
                    .foregroundStyle(themeStore.accentColor)
                    .font(.system(.subheadline, design: .monospaced))
            }
            Slider(value: $nearSwitchGapMs, in: 0...500, step: 5)
            Text("settings.lyrics.near_switch_gap_desc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var globalAdvanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("歌词整体提前量")
                Spacer()
                Text("\(Int(globalAdvanceMs)) ms")
                    .foregroundStyle(themeStore.accentColor)
                    .font(.system(.subheadline, design: .monospaced))
            }
            Slider(value: $globalAdvanceMs, in: -1000...1000, step: 10)
            Text("全曲统一提前（正值=更早显示，负值=更晚显示）。会与单曲时间偏移共同作用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func syncToSettings() {
        settings.lyricsLeadInMs = leadInMs
        settings.lyricsNearSwitchGapMs = nearSwitchGapMs
        settings.lyricsGlobalAdvanceMs = globalAdvanceMs
        lyricsVM.refreshConfigFromSettings()
    }
}
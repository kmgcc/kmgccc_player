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
    private enum Defaults {
        static let leadInMs: Double = 600
        static let nearSwitchGapMs: Double = 160
        static let globalAdvanceMs: Double = 0
    }

    @Environment(AppSettings.self) private var settings
    @Environment(LyricsViewModel.self) private var lyricsVM
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    // Local state for slider binding (fixes UI update issue with @ObservationIgnored properties)
    @State private var leadInMs: Double = Defaults.leadInMs
    @State private var nearSwitchGapMs: Double = Defaults.nearSwitchGapMs
    @State private var globalAdvanceMs: Double = Defaults.globalAdvanceMs

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                leadInSection
                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)
                nearSwitchGapSection
                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)
                globalAdvanceSection
            }
            .padding(
                presentationStyle.usesCustomSectionCards
                    ? 0
                    : presentationStyle.groupPadding
            )
        } label: {
            HStack(spacing: presentationStyle.compactInlineSpacing) {
                Text("settings.lyrics.timing")
                    .font(presentationStyle.sectionTitleFont)
                    .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                    .settingsInfoHint("参数仅供调试，日常聆听保持默认即可。")
                Spacer()
                Button("恢复默认值") {
                    resetToDefaults()
                }
                .buttonStyle(.borderless)
                .font(.system(size: presentationStyle.captionFontSize))
                .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
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
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                    Text("settings.lyrics.leadin")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                        .settingsInfoHint(String(localized: "settings.lyrics.leadin_desc"))
                Spacer()
                Text("\(Int(leadInMs)) ms")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(value: $leadInMs, in: 0...1200, step: 20)
                .frame(height: presentationStyle.tabHeight)
        }
    }

    private func resetToDefaults() {
        leadInMs = Defaults.leadInMs
        nearSwitchGapMs = Defaults.nearSwitchGapMs
        globalAdvanceMs = Defaults.globalAdvanceMs
        syncToSettings()
    }

    private var nearSwitchGapSection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                    Text("settings.lyrics.near_switch_gap")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                        .settingsInfoHint(String(localized: "settings.lyrics.near_switch_gap_desc"))
                Spacer()
                Text("\(Int(nearSwitchGapMs)) ms")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(value: $nearSwitchGapMs, in: 0...500, step: 5)
                .frame(height: presentationStyle.tabHeight)
        }
    }

    private var globalAdvanceSection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                    Text("歌词整体提前量")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                        .settingsInfoHint("全曲歌词统一提前显示：正值更早，负值更晚，与单曲时间偏移叠加生效。")
                Spacer()
                Text("\(Int(globalAdvanceMs)) ms")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(value: $globalAdvanceMs, in: -1000...1000, step: 10)
                .frame(height: presentationStyle.tabHeight)
        }
    }

    private func syncToSettings() {
        settings.lyricsLeadInMs = leadInMs
        settings.lyricsNearSwitchGapMs = nearSwitchGapMs
        settings.lyricsGlobalAdvanceMs = globalAdvanceMs
        lyricsVM.refreshConfigFromSettings()
    }
}

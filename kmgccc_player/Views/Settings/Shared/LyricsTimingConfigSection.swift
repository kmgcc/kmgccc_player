//
//  LyricsTimingConfigSection.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Lyrics Timing Configuration Section
//

import MotionKit
import SwiftUI

/// Lyrics timing parameters configuration section, folded by default.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    // Local state for slider binding (fixes UI update issue with @ObservationIgnored properties)
    @State private var leadInMs: Double = Defaults.leadInMs
    @State private var nearSwitchGapMs: Double = Defaults.nearSwitchGapMs
    @State private var globalAdvanceMs: Double = Defaults.globalAdvanceMs
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                Text("参数仅供调试，日常聆听保持默认即可。")
                    .settingsDescriptionStyle()

                if isExpanded {
                    leadInSection
                    Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)
                    nearSwitchGapSection
                    Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)
                    globalAdvanceSection
                }
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
                Spacer()
                if isExpanded {
                    Button("恢复默认值") {
                        resetToDefaults()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: presentationStyle.captionFontSize))
                    .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                }
                expandButton
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

    private var expandButton: some View {
        Button {
            let policy = configuredMotionPolicy.resolving(
                accessibilityReduceMotion: reduceMotion
            )
            withAnimation(policy.animation(for: motionTokens[.microInteraction])) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(presentationStyle.settingsSecondaryTextColor(appColors: appColors))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起" : "展开")
        .accessibilityLabel(isExpanded ? "收起时间轴" : "展开时间轴")
    }

    private var leadInSection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                    Text("settings.lyrics.leadin")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                Spacer()
                Text("\(Int(leadInMs)) ms")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(value: $leadInMs, in: 0...1200, step: 20)
                .frame(height: presentationStyle.tabHeight)
            Text("settings.lyrics.leadin_desc")
                .settingsDescriptionStyle()
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
                Spacer()
                Text("\(Int(nearSwitchGapMs)) ms")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(value: $nearSwitchGapMs, in: 0...500, step: 5)
                .frame(height: presentationStyle.tabHeight)
            Text("settings.lyrics.near_switch_gap_desc")
                .settingsDescriptionStyle()
        }
    }

    private var globalAdvanceSection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                    Text("歌词整体提前量")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                Spacer()
                Text("\(Int(globalAdvanceMs)) ms")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(value: $globalAdvanceMs, in: -1000...1000, step: 10)
                .frame(height: presentationStyle.tabHeight)
            Text("全曲歌词统一提前显示：正值更早，负值更晚，与单曲时间偏移叠加生效。")
                .settingsDescriptionStyle()
        }
    }

    private func syncToSettings() {
        settings.lyricsLeadInMs = leadInMs
        settings.lyricsNearSwitchGapMs = nearSwitchGapMs
        settings.lyricsGlobalAdvanceMs = globalAdvanceMs
        lyricsVM.refreshConfigFromSettings()
    }
}

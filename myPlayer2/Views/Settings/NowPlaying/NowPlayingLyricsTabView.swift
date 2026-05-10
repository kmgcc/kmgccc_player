//
//  NowPlayingLyricsTabView.swift
//  myPlayer2
//
//  kmgccc_player - Window Playback Lyrics Settings Tab
//

import SwiftUI

/// Lyrics settings tab for window playback: timing, fonts, and preview.
struct NowPlayingLyricsTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsViewModel.self) private var lyricsVM
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    // Font settings state
    @State private var lyricsFontNameZh: String = AppSettings.shared.lyricsFontNameZh
    @State private var lyricsFontNameEn: String = AppSettings.shared.lyricsFontNameEn
    @State private var lyricsTranslationFontName: String = AppSettings.shared.lyricsTranslationFontName
    @State private var lyricsFontWeightLight: Int = AppSettings.shared.lyricsFontWeightLight
    @State private var lyricsFontWeightDark: Int = AppSettings.shared.lyricsFontWeightDark
    @State private var lyricsFontSize: Double = AppSettings.shared.lyricsFontSize
    @State private var lyricsTranslationFontSize: Double = AppSettings.shared.lyricsTranslationFontSize
    @State private var lyricsTranslationFontWeightLight: Int = AppSettings.shared.lyricsTranslationFontWeightLight
    @State private var lyricsTranslationFontWeightDark: Int = AppSettings.shared.lyricsTranslationFontWeightDark
    @State private var amllHighResolutionLyricsEnabled: Bool = AppSettings.shared.amllHighResolutionLyricsEnabled
    @State private var amllDiscreteWordHighlightEnabled: Bool = AppSettings.shared.amllDiscreteWordHighlightEnabled

    private var fontFamilies: [String] {
        Self.cachedFontFamilies
    }

    private static let cachedFontFamilies: [String] =
        NSFontManager.shared.availableFontFamilies.sorted()

    private let fontWeights: [(label: LocalizedStringKey, value: Int)] = [
        ("settings.lyrics.weight_thin", 100),
        ("settings.lyrics.weight_light", 300),
        ("settings.lyrics.weight_regular", 400),
        ("settings.lyrics.weight_medium", 500),
        ("settings.lyrics.weight_semibold", 600),
        ("settings.lyrics.weight_bold", 700),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
            renderingSection

            fontsSection

            previewSection

            LyricsTimingConfigSection()
                .environment(settings)
                .environment(lyricsVM)
        }
    }

    private var renderingSection: some View {
        SettingsSection("外观") {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                SettingsSwitchRow(
                    title: "高分辨率",
                    isOn: $amllHighResolutionLyricsEnabled,
                    detail: "开启后歌词观感和 GPU 占用会提高",
                    titleFont: presentationStyle.rowLabelFont,
                    detailFont: presentationStyle.captionFont
                )

                SettingsSwitchRow(
                    title: "减弱高亮(beta)",
                    isOn: $amllDiscreteWordHighlightEnabled,
                    detail: "开启后可能减少高亮移动干扰",
                    titleFont: presentationStyle.rowLabelFont,
                    detailFont: presentationStyle.captionFont
                )
            }
        }
        .onAppear {
            amllHighResolutionLyricsEnabled = settings.amllHighResolutionLyricsEnabled
            amllDiscreteWordHighlightEnabled = settings.amllDiscreteWordHighlightEnabled
        }
        .onChange(of: amllHighResolutionLyricsEnabled) { _, _ in syncToSettings() }
        .onChange(of: amllDiscreteWordHighlightEnabled) { _, _ in syncToSettings() }
    }

    private var fontsSection: some View {
        SettingsSection("settings.lyrics.fonts") {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                HStack {
                    Text("settings.lyrics.font_size")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Text("\(Int(lyricsFontSize)) px")
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                        .font(presentationStyle.rowValueFont)
                }
                Slider(value: $lyricsFontSize, in: 16...48, step: 1)
                    .frame(height: presentationStyle.tabHeight)

                HStack {
                    Text("浅色模式字重")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsFontWeightLight) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.compactPickerWidth)
                }

                HStack {
                    Text("深色模式字重")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsFontWeightDark) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.compactPickerWidth)
                }

                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)

                HStack {
                    Text("settings.lyrics.translation_size")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Text("\(Int(lyricsTranslationFontSize)) px")
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                        .font(presentationStyle.rowValueFont)
                }
                Slider(value: $lyricsTranslationFontSize, in: 12...36, step: 1)
                    .frame(height: presentationStyle.tabHeight)

                HStack {
                    Text("翻译浅色字重")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsTranslationFontWeightLight) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.compactPickerWidth)
                }

                HStack {
                    Text("翻译深色字重")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsTranslationFontWeightDark) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.compactPickerWidth)
                }

                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)

                HStack {
                    Text("settings.lyrics.chinese_font")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsFontNameZh) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family)
                                .font(.custom(family, size: 12))
                                .tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.pickerWidth)
                }

                HStack {
                    Text("settings.lyrics.english_font")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsFontNameEn) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family)
                                .font(.custom(family, size: 12))
                                .tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.pickerWidth)
                }

                HStack {
                    Text("settings.lyrics.translation_font")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Picker("", selection: $lyricsTranslationFontName) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family)
                                .font(.custom(family, size: 12))
                                .tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(presentationStyle.rowLabelFont)
                    .frame(width: presentationStyle.pickerWidth)
                }
            }
        }
        .onAppear {
            syncStateFromSettings()
        }
        .onChange(of: lyricsFontNameZh) { _, newValue in syncToSettings() }
        .onChange(of: lyricsFontNameEn) { _, newValue in syncToSettings() }
        .onChange(of: lyricsTranslationFontName) { _, newValue in syncToSettings() }
        .onChange(of: lyricsFontWeightLight) { _, newValue in syncToSettings() }
        .onChange(of: lyricsFontWeightDark) { _, newValue in syncToSettings() }
        .onChange(of: lyricsFontSize) { _, newValue in syncToSettings() }
        .onChange(of: lyricsTranslationFontSize) { _, newValue in syncToSettings() }
        .onChange(of: lyricsTranslationFontWeightLight) { _, newValue in syncToSettings() }
        .onChange(of: lyricsTranslationFontWeightDark) { _, newValue in syncToSettings() }
    }

    private var previewSection: some View {
        SettingsSection("settings.lyrics.preview") {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                LyricsPreviewCard(
                    title: "浅色模式预览",
                    isDarkCard: false,
                    mainWeight: lyricsFontWeightLight,
                    translationWeight: lyricsTranslationFontWeightLight,
                    mainFontNameZh: lyricsFontNameZh,
                    mainFontNameEn: lyricsFontNameEn,
                    translationFontName: lyricsTranslationFontName,
                    mainFontSize: lyricsFontSize,
                    translationFontSize: lyricsTranslationFontSize
                )
                LyricsPreviewCard(
                    title: "深色模式预览",
                    isDarkCard: true,
                    mainWeight: lyricsFontWeightDark,
                    translationWeight: lyricsTranslationFontWeightDark,
                    mainFontNameZh: lyricsFontNameZh,
                    mainFontNameEn: lyricsFontNameEn,
                    translationFontName: lyricsTranslationFontName,
                    mainFontSize: lyricsFontSize,
                    translationFontSize: lyricsTranslationFontSize
                )
            }
        }
    }

    private func syncStateFromSettings() {
        lyricsFontNameZh = settings.lyricsFontNameZh
        lyricsFontNameEn = settings.lyricsFontNameEn
        lyricsTranslationFontName = settings.lyricsTranslationFontName
        lyricsFontWeightLight = settings.lyricsFontWeightLight
        lyricsFontWeightDark = settings.lyricsFontWeightDark
        lyricsFontSize = settings.lyricsFontSize
        lyricsTranslationFontSize = settings.lyricsTranslationFontSize
        lyricsTranslationFontWeightLight = settings.lyricsTranslationFontWeightLight
        lyricsTranslationFontWeightDark = settings.lyricsTranslationFontWeightDark
        amllHighResolutionLyricsEnabled = settings.amllHighResolutionLyricsEnabled
        amllDiscreteWordHighlightEnabled = settings.amllDiscreteWordHighlightEnabled
    }

    private func syncToSettings() {
        settings.lyricsFontNameZh = lyricsFontNameZh
        settings.lyricsFontNameEn = lyricsFontNameEn
        settings.lyricsTranslationFontName = lyricsTranslationFontName
        settings.lyricsFontWeightLight = lyricsFontWeightLight
        settings.lyricsFontWeightDark = lyricsFontWeightDark
        settings.lyricsFontSize = lyricsFontSize
        settings.lyricsTranslationFontSize = lyricsTranslationFontSize
        settings.lyricsTranslationFontWeightLight = lyricsTranslationFontWeightLight
        settings.lyricsTranslationFontWeightDark = lyricsTranslationFontWeightDark
        settings.amllHighResolutionLyricsEnabled = amllHighResolutionLyricsEnabled
        settings.amllDiscreteWordHighlightEnabled = amllDiscreteWordHighlightEnabled
        lyricsVM.refreshConfigFromSettings()
    }
}

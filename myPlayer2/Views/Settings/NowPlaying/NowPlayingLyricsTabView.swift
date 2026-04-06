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
        VStack(alignment: .leading, spacing: 20) {
            // Shared timing config
            LyricsTimingConfigSection()
                .environment(settings)
                .environment(lyricsVM)

            // Font configuration
            fontsSection

            // Preview
            previewSection
        }
    }

    private var fontsSection: some View {
        GroupBox(LocalizedStringKey("settings.lyrics.fonts")) {
            VStack(alignment: .leading, spacing: 12) {
                // Main font size
                HStack {
                    Text("settings.lyrics.font_size")
                    Spacer()
                    Text("\(Int(lyricsFontSize)) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lyricsFontSize, in: 16...48, step: 1)

                // Light mode weight
                HStack {
                    Text("浅色模式字重")
                    Spacer()
                    Picker("", selection: $lyricsFontWeightLight) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                // Dark mode weight
                HStack {
                    Text("深色模式字重")
                    Spacer()
                    Picker("", selection: $lyricsFontWeightDark) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Divider()

                // Translation font size
                HStack {
                    Text("settings.lyrics.translation_size")
                    Spacer()
                    Text("\(Int(lyricsTranslationFontSize)) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lyricsTranslationFontSize, in: 12...36, step: 1)

                // Translation weights
                HStack {
                    Text("翻译浅色字重")
                    Spacer()
                    Picker("", selection: $lyricsTranslationFontWeightLight) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                HStack {
                    Text("翻译深色字重")
                    Spacer()
                    Picker("", selection: $lyricsTranslationFontWeightDark) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Divider()

                // Font family pickers
                HStack {
                    Text("settings.lyrics.chinese_font")
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
                    .frame(width: 220)
                }

                HStack {
                    Text("settings.lyrics.english_font")
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
                    .frame(width: 220)
                }

                HStack {
                    Text("settings.lyrics.translation_font")
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
                    .frame(width: 220)
                }
            }
            .padding(.horizontal, 10)
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
        GroupBox(LocalizedStringKey("settings.lyrics.preview")) {
            VStack(alignment: .leading, spacing: 12) {
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
        lyricsVM.refreshConfigFromSettings()
    }
}
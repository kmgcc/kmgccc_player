//
//  FullscreenLyricsTabView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Lyrics Settings Tab
//

import SwiftUI

/// Lyrics settings tab for fullscreen playback: shared timing, fullscreen fonts, and preview.
struct FullscreenLyricsTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsViewModel.self) private var lyricsVM
    @EnvironmentObject private var themeStore: ThemeStore

    // Fullscreen-specific font settings
    @State private var fullscreenLyricsFontNameZh: String = AppSettings.shared.fullscreenLyricsFontNameZh
    @State private var fullscreenLyricsFontNameEn: String = AppSettings.shared.fullscreenLyricsFontNameEn
    @State private var fullscreenLyricsTranslationFontName: String = AppSettings.shared.fullscreenLyricsTranslationFontName
    @State private var fullscreenLyricsFontWeight: Int = AppSettings.shared.fullscreenLyricsFontWeight
    @State private var fullscreenLyricsTranslationFontWeight: Int = AppSettings.shared.fullscreenLyricsTranslationFontWeight
    @State private var fullscreenLyricsFontSize: Double = AppSettings.shared.fullscreenLyricsFontSize
    @State private var fullscreenLyricsTranslationFontSize: Double = AppSettings.shared.fullscreenLyricsTranslationFontSize

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

            // Fullscreen-specific font configuration
            typographySection

            // Preview
            previewSection
        }
        .onAppear {
            syncStateFromSettings()
        }
        .onChange(of: fullscreenLyricsFontNameZh) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsFontNameEn) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsTranslationFontName) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsFontWeight) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsTranslationFontWeight) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsFontSize) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsTranslationFontSize) { _, _ in syncToSettings() }
    }

    private var typographySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("全屏歌词样式")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("仅影响全屏 AMLL")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Main font size
                HStack {
                    Text("主歌词字号")
                    Spacer()
                    Text("\(Int(fullscreenLyricsFontSize)) px")
                        .foregroundStyle(themeStore.accentColor)
                        .monospacedDigit()
                }
                Slider(
                    value: $fullscreenLyricsFontSize,
                    in: 24...72,
                    step: 1
                )

                // Main font weight
                HStack {
                    Text("主歌词字重")
                    Spacer()
                    Picker("", selection: $fullscreenLyricsFontWeight) {
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
                    Text("翻译字号")
                    Spacer()
                    Text("\(Int(fullscreenLyricsTranslationFontSize)) px")
                        .foregroundStyle(themeStore.accentColor)
                        .monospacedDigit()
                }
                Slider(
                    value: $fullscreenLyricsTranslationFontSize,
                    in: 14...40,
                    step: 1
                )

                // Translation font weight
                HStack {
                    Text("翻译字重")
                    Spacer()
                    Picker("", selection: $fullscreenLyricsTranslationFontWeight) {
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
                    Text("中文字体")
                    Spacer()
                    Picker("", selection: $fullscreenLyricsFontNameZh) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                HStack {
                    Text("英文字体")
                    Spacer()
                    Picker("", selection: $fullscreenLyricsFontNameEn) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                HStack {
                    Text("翻译字体")
                    Spacer()
                    Picker("", selection: $fullscreenLyricsTranslationFontName) {
                        ForEach(fontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
            }
            .padding(12)
        }
    }

    private var previewSection: some View {
        GroupBox("全屏歌词预览") {
            LyricsPreviewCard(
                title: "",
                isDarkCard: true,
                mainWeight: fullscreenLyricsFontWeight,
                translationWeight: fullscreenLyricsTranslationFontWeight,
                mainFontNameZh: fullscreenLyricsFontNameZh,
                mainFontNameEn: fullscreenLyricsFontNameEn,
                translationFontName: fullscreenLyricsTranslationFontName,
                mainFontSize: fullscreenLyricsFontSize,
                translationFontSize: fullscreenLyricsTranslationFontSize
            )
        }
    }

    private func syncStateFromSettings() {
        fullscreenLyricsFontNameZh = settings.fullscreenLyricsFontNameZh
        fullscreenLyricsFontNameEn = settings.fullscreenLyricsFontNameEn
        fullscreenLyricsTranslationFontName = settings.fullscreenLyricsTranslationFontName
        fullscreenLyricsFontWeight = settings.fullscreenLyricsFontWeight
        fullscreenLyricsTranslationFontWeight = settings.fullscreenLyricsTranslationFontWeight
        fullscreenLyricsFontSize = settings.fullscreenLyricsFontSize
        fullscreenLyricsTranslationFontSize = settings.fullscreenLyricsTranslationFontSize
    }

    private func syncToSettings() {
        settings.fullscreenLyricsFontNameZh = fullscreenLyricsFontNameZh
        settings.fullscreenLyricsFontNameEn = fullscreenLyricsFontNameEn
        settings.fullscreenLyricsTranslationFontName = fullscreenLyricsTranslationFontName
        settings.fullscreenLyricsFontWeight = fullscreenLyricsFontWeight
        settings.fullscreenLyricsTranslationFontWeight = fullscreenLyricsTranslationFontWeight
        settings.fullscreenLyricsFontSize = fullscreenLyricsFontSize
        settings.fullscreenLyricsTranslationFontSize = fullscreenLyricsTranslationFontSize
    }
}
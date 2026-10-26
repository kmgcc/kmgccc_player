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
    @State private var amllLyricsSpringDuration: Double = AppSettings.shared.amllLyricsSpringDuration
    @State private var amllLyricsSpringBounce: Double = AppSettings.shared.amllLyricsSpringBounce
    @State private var amllDiscreteWordHighlightEnabled: Bool = AppSettings.shared.amllDiscreteWordHighlightEnabled
    @State private var amllLyricsRenderQuality: AppSettings.AMLLLyricsRenderQuality = AppSettings.shared.amllLyricsRenderQuality
    @State private var pendingSpringSettingsRefreshTask: Task<Void, Never>?
    @State private var pendingTypographyRefreshTask: Task<Void, Never>?

    private let fontWeights: [(label: LocalizedStringKey, value: Int)] = [
        ("settings.lyrics.weight_thin", 100),
        ("settings.lyrics.weight_light", 300),
        ("settings.lyrics.weight_regular", 400),
        ("settings.lyrics.weight_medium", 500),
        ("settings.lyrics.weight_semibold", 600),
        ("settings.lyrics.weight_bold", 700),
        ("settings.lyrics.weight_black", 900),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
            renderingSection

            springSection

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
                AMLLLyricsRenderQualitySlider(quality: $amllLyricsRenderQuality)

                SettingsSwitchRow(
                    title: "减弱高亮",
                    isOn: $amllDiscreteWordHighlightEnabled,
                    titleFont: presentationStyle.rowLabelFont,
                    info: "开启后歌词逐字亮起而不是扫光。" + (skinOwnedNote("highlight", "高亮") ?? "")
                )
            }
        }
        .onAppear {
            amllLyricsSpringDuration = settings.amllLyricsSpringDuration
            amllLyricsSpringBounce = settings.amllLyricsSpringBounce
            amllDiscreteWordHighlightEnabled = settings.amllDiscreteWordHighlightEnabled
            amllLyricsRenderQuality = settings.amllLyricsRenderQuality
        }
        .onChange(of: amllLyricsSpringDuration) { _, _ in syncSpringSettingsDebounced() }
        .onChange(of: amllLyricsSpringBounce) { _, _ in syncSpringSettingsDebounced() }
        .onChange(of: amllDiscreteWordHighlightEnabled) { _, _ in
            syncToSettings()
            NotificationCenter.default.post(name: .lyricHighlightModeDidChange, object: nil)
        }
        .onChange(of: amllLyricsRenderQuality) { _, newValue in
            settings.amllLyricsRenderQuality = newValue
        }
    }

    /// Names the selected skins that keep this group of lyrics settings for themselves.
    private func skinOwnedNote(_ group: String, _ subject: String) -> String? {
        let skins = [SkinRegistry.skin(for: settings.selectedNowPlayingSkinID), SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID)]
        let names = skins.filter { $0.lyricsSkinOwnedSettings.contains(group) }
            .reduce(into: [String]()) { if !$0.contains($1.name) { $0.append($1.name) } }
        guard !names.isEmpty else { return nil }
        return "「" + names.joined(separator: "」「") + "」皮肤使用自己的\(subject)。"
    }

    private var springSection: some View {
        SettingsSection("滚动弹性", info: skinOwnedNote("spring", "滚动弹性")) {
            AMLLLyricSpringSettingsControls(
                duration: $amllLyricsSpringDuration,
                bounce: $amllLyricsSpringBounce
            )
        }
    }

    private var fontsSection: some View {
        SettingsSection("settings.lyrics.fonts", info: skinOwnedNote("font", "字体")) {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                HStack {
                    Text("settings.lyrics.font_size")
                        .font(presentationStyle.rowLabelFont)
                    Spacer()
                    Text("\(Int(lyricsFontSize)) px")
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                        .font(presentationStyle.rowValueFont)
                }
                Slider(value: $lyricsFontSize, in: 16...44, step: 1)
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
                Slider(value: $lyricsTranslationFontSize, in: 10...26, step: 1)
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

                DeferredLyricsFontPickerRows(
                    mainFontNameZh: $lyricsFontNameZh,
                    mainFontNameEn: $lyricsFontNameEn,
                    translationFontName: $lyricsTranslationFontName,
                    zhTitle: "settings.lyrics.chinese_font",
                    enTitle: "settings.lyrics.english_font",
                    translationTitle: "settings.lyrics.translation_font"
                )
            }
        }
        .onAppear {
            syncStateFromSettings()
        }
        .onChange(of: lyricsFontNameZh) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsFontNameEn) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsTranslationFontName) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsFontWeightLight) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsFontWeightDark) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsFontSize) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsTranslationFontSize) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsTranslationFontWeightLight) { _, _ in syncToSettings(debounceLyrics: true) }
        .onChange(of: lyricsTranslationFontWeightDark) { _, _ in syncToSettings(debounceLyrics: true) }
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
        amllLyricsSpringDuration = settings.amllLyricsSpringDuration
        amllLyricsSpringBounce = settings.amllLyricsSpringBounce
        amllDiscreteWordHighlightEnabled = settings.amllDiscreteWordHighlightEnabled
    }

    private func syncToSettings(debounceLyrics: Bool = false) {
        settings.lyricsFontNameZh = lyricsFontNameZh
        settings.lyricsFontNameEn = lyricsFontNameEn
        settings.lyricsTranslationFontName = lyricsTranslationFontName
        settings.lyricsFontWeightLight = lyricsFontWeightLight
        settings.lyricsFontWeightDark = lyricsFontWeightDark
        settings.lyricsFontSize = lyricsFontSize
        settings.lyricsTranslationFontSize = lyricsTranslationFontSize
        settings.lyricsTranslationFontWeightLight = lyricsTranslationFontWeightLight
        settings.lyricsTranslationFontWeightDark = lyricsTranslationFontWeightDark
        settings.amllLyricsSpringEnabled = true
        settings.amllLyricsSpringDuration = amllLyricsSpringDuration
        settings.amllLyricsSpringBounce = amllLyricsSpringBounce
        settings.amllDiscreteWordHighlightEnabled = amllDiscreteWordHighlightEnabled
        if debounceLyrics {
            scheduleTypographyRefresh()
        } else {
            lyricsVM.refreshConfigFromSettings()
        }
    }

    private func scheduleTypographyRefresh() {
        pendingTypographyRefreshTask?.cancel()
        pendingTypographyRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            lyricsVM.refreshConfigFromSettings()
            pendingTypographyRefreshTask = nil
        }
    }

    private func syncSpringSettingsDebounced() {
        settings.amllLyricsSpringEnabled = true
        settings.amllLyricsSpringDuration = amllLyricsSpringDuration
        settings.amllLyricsSpringBounce = amllLyricsSpringBounce

        pendingSpringSettingsRefreshTask?.cancel()
        pendingSpringSettingsRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            lyricsVM.refreshConfigFromSettings()
            NotificationCenter.default.post(name: .lyricSpringSettingsDidSettle, object: nil)
        }
    }
}

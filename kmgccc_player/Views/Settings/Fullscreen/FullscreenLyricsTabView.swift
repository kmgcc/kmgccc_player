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
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    @State private var fullscreenLyricsUsesPerSkinTypography: Bool =
        AppSettings.shared.fullscreenLyricsUsesPerSkinTypography
    // Fullscreen-specific font settings
    @State private var fullscreenLyricsFontNameZh: String = AppSettings.shared.fullscreenLyricsFontNameZh
    @State private var fullscreenLyricsFontNameEn: String = AppSettings.shared.fullscreenLyricsFontNameEn
    @State private var fullscreenLyricsTranslationFontName: String = AppSettings.shared.fullscreenLyricsTranslationFontName
    @State private var fullscreenLyricsFontWeight: Int = AppSettings.shared.fullscreenLyricsFontWeight
    @State private var fullscreenLyricsTranslationFontWeight: Int = AppSettings.shared.fullscreenLyricsTranslationFontWeight
    @State private var fullscreenLyricsFontSize: Double = AppSettings.shared.fullscreenLyricsFontSize
    @State private var fullscreenLyricsTranslationFontSize: Double = AppSettings.shared.fullscreenLyricsTranslationFontSize
    @State private var amllLyricsRenderQuality: AppSettings.AMLLLyricsRenderQuality = AppSettings.shared.amllLyricsRenderQuality
    @State private var amllLyricsSpringDuration: Double = AppSettings.shared.amllLyricsSpringDuration
    @State private var amllLyricsSpringBounce: Double = AppSettings.shared.amllLyricsSpringBounce
    @State private var amllDiscreteWordHighlightEnabled: Bool = AppSettings.shared.amllDiscreteWordHighlightEnabled
    @State private var pendingSpringSettingsRefreshTask: Task<Void, Never>?

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
            appearanceSection
            fontsSection

            if !presentationStyle.usesMaterialSectionCards {
                previewSection
            }

            LyricsTimingConfigSection()
                .environment(settings)
                .environment(lyricsVM)
        }
        .onAppear {
            syncStateFromSettings()
        }
        .onChange(of: fullscreenLyricsUsesPerSkinTypography) { _, newValue in
            settings.fullscreenLyricsUsesPerSkinTypography = newValue
            syncStateFromSettings()
        }
        .onChange(of: settings.fullscreen.skinID) { _, _ in
            syncStateFromSettings()
        }
        .onChange(of: fullscreenLyricsFontNameZh) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsFontNameEn) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsTranslationFontName) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsFontWeight) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsTranslationFontWeight) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsFontSize) { _, _ in syncToSettings() }
        .onChange(of: fullscreenLyricsTranslationFontSize) { _, _ in syncToSettings() }
        .onChange(of: amllLyricsRenderQuality) { _, _ in syncToSettings() }
        .onChange(of: amllLyricsSpringDuration) { _, _ in syncSpringSettingsDebounced() }
        .onChange(of: amllLyricsSpringBounce) { _, _ in syncSpringSettingsDebounced() }
        .onChange(of: amllDiscreteWordHighlightEnabled) { _, _ in syncToSettings() }
    }

    private var appearanceSection: some View {
        SettingsSection("外观") {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                AMLLLyricsRenderQualitySlider(quality: $amllLyricsRenderQuality)

                AMLLLyricSpringSettingsControls(
                    duration: $amllLyricsSpringDuration,
                    bounce: $amllLyricsSpringBounce
                )

                SettingsSwitchRow(
                    title: "减弱高亮(beta)",
                    isOn: $amllDiscreteWordHighlightEnabled,
                    detail: "开启后可能减少高亮移动干扰",
                    titleFont: presentationStyle.rowLabelFont,
                    detailFont: presentationStyle.captionFont,
                    titleColor: presentationStyle.settingsPrimaryTextColor(appColors: appColors),
                    detailColor: presentationStyle.settingsTertiaryTextColor(appColors: appColors)
                )
            }
        }
    }

    private var fontsSection: some View {
        SettingsSection("字体") {
            VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                SettingsSwitchRow(
                    title: "按皮肤单独设置字体",
                    isOn: $fullscreenLyricsUsesPerSkinTypography,
                    titleFont: presentationStyle.rowLabelFont,
                    detailFont: presentationStyle.captionFont,
                    titleColor: presentationStyle.settingsPrimaryTextColor(appColors: appColors),
                    detailColor: presentationStyle.settingsTertiaryTextColor(appColors: appColors)
                )

                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)

                HStack {
                    Text("主歌词字号")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                    Spacer()
                    Text("\(Int(fullscreenLyricsFontSize)) px")
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                        .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
                }
                Slider(value: $fullscreenLyricsFontSize, in: 24...72, step: 1)
                    .frame(height: presentationStyle.tabHeight)

                HStack {
                    Text("主歌词字重")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                    Spacer()
                    Picker("", selection: $fullscreenLyricsFontWeight) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: presentationStyle.compactPickerWidth)
                }

                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)

                HStack {
                    Text("翻译字号")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                    Spacer()
                    Text("\(Int(fullscreenLyricsTranslationFontSize)) px")
                        .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                        .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
                }
                Slider(value: $fullscreenLyricsTranslationFontSize, in: 12...36, step: 1)
                    .frame(height: presentationStyle.tabHeight)

                HStack {
                    Text("翻译字重")
                        .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                        .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                    Spacer()
                    Picker("", selection: $fullscreenLyricsTranslationFontWeight) {
                        ForEach(fontWeights, id: \.value) { weight in
                            Text(weight.label).tag(weight.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: presentationStyle.compactPickerWidth)
                }

                Divider().padding(.vertical, presentationStyle.dividerVerticalPadding)

                DeferredLyricsFontPickerRows(
                    mainFontNameZh: $fullscreenLyricsFontNameZh,
                    mainFontNameEn: $fullscreenLyricsFontNameEn,
                    translationFontName: $fullscreenLyricsTranslationFontName,
                    zhTitle: "中文字体",
                    enTitle: "英文字体",
                    translationTitle: "翻译字体"
                )
            }
        }
    }

    private var previewSection: some View {
        SettingsSection("预览") {
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
        fullscreenLyricsUsesPerSkinTypography = settings.fullscreenLyricsUsesPerSkinTypography
        let typography = settings.effectiveFullscreenLyricsTypography
        fullscreenLyricsFontNameZh = typography.mainFontNameZh
        fullscreenLyricsFontNameEn = typography.mainFontNameEn
        fullscreenLyricsTranslationFontName = typography.translationFontName
        fullscreenLyricsFontWeight = typography.mainFontWeight
        fullscreenLyricsTranslationFontWeight = typography.translationFontWeight
        fullscreenLyricsFontSize = typography.mainFontSize
        fullscreenLyricsTranslationFontSize = typography.translationFontSize
        amllLyricsRenderQuality = settings.amllLyricsRenderQuality
        amllLyricsSpringDuration = settings.amllLyricsSpringDuration
        amllLyricsSpringBounce = settings.amllLyricsSpringBounce
        amllDiscreteWordHighlightEnabled = settings.amllDiscreteWordHighlightEnabled
    }

    private func syncToSettings() {
        let typography = FullscreenLyricsTypography(
            mainFontNameZh: fullscreenLyricsFontNameZh,
            mainFontNameEn: fullscreenLyricsFontNameEn,
            translationFontName: fullscreenLyricsTranslationFontName,
            mainFontWeight: fullscreenLyricsFontWeight,
            translationFontWeight: fullscreenLyricsTranslationFontWeight,
            mainFontSize: fullscreenLyricsFontSize,
            translationFontSize: fullscreenLyricsTranslationFontSize
        )
        if settings.fullscreenLyricsUsesPerSkinTypography {
            settings.setFullscreenLyricsTypography(
                typography,
                for: settings.fullscreen.skinID
            )
        } else {
            settings.fullscreenLyricsFontNameZh = typography.mainFontNameZh
            settings.fullscreenLyricsFontNameEn = typography.mainFontNameEn
            settings.fullscreenLyricsTranslationFontName = typography.translationFontName
            settings.fullscreenLyricsFontWeight = typography.mainFontWeight
            settings.fullscreenLyricsTranslationFontWeight = typography.translationFontWeight
            settings.fullscreenLyricsFontSize = typography.mainFontSize
            settings.fullscreenLyricsTranslationFontSize = typography.translationFontSize
        }
        settings.amllLyricsRenderQuality = amllLyricsRenderQuality
        settings.amllLyricsSpringEnabled = true
        settings.amllLyricsSpringDuration = amllLyricsSpringDuration
        settings.amllLyricsSpringBounce = amllLyricsSpringBounce
        settings.amllDiscreteWordHighlightEnabled = amllDiscreteWordHighlightEnabled
        lyricsVM.refreshConfigFromSettings()
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

    private var selectedFullscreenSkinName: String {
        SkinRegistry.fullscreenOptions.first(where: { $0.id == settings.fullscreen.skinID })?.name
            ?? settings.fullscreen.skinID
    }
}

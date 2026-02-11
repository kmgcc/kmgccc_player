//
//  SettingsView.swift
//  myPlayer2
//
//  TrueMusic - Settings View
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import AppKit
import SwiftUI

/// Settings view with sidebar categories.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(LEDMeterService.self) private var ledMeter
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    // MARK: - Navigation

    @State private var selection: SettingsCategory = .nowPlaying
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // MARK: - App Settings

    // MARK: - AMLL Settings

    @State private var lyricsLeadInMs: Double = AppSettings.shared.lyricsLeadInMs
    @State private var lyricsFontNameZh: String = AppSettings.shared.lyricsFontNameZh
    @State private var lyricsFontNameEn: String = AppSettings.shared.lyricsFontNameEn
    @State private var lyricsTranslationFontName: String = AppSettings.shared
        .lyricsTranslationFontName
    @State private var lyricsFontWeightLight: Int = AppSettings.shared.lyricsFontWeightLight
    @State private var lyricsFontWeightDark: Int = AppSettings.shared.lyricsFontWeightDark
    @State private var lyricsFontSize: Double = AppSettings.shared.lyricsFontSize
    @State private var lyricsTranslationFontSize: Double = AppSettings.shared
        .lyricsTranslationFontSize
    @State private var lyricsTranslationFontWeightLight: Int = AppSettings.shared
        .lyricsTranslationFontWeightLight
    @State private var lyricsTranslationFontWeightDark: Int = AppSettings.shared
        .lyricsTranslationFontWeightDark
    @State private var nowPlayingSkin: String = AppSettings.shared.selectedNowPlayingSkinID

    // MARK: - LED Settings State

    @State private var sensitivity: Float = AppSettings.shared.ledSensitivity
    @State private var cutoffHz: Double = AppSettings.shared.ledCutoffHz
    @State private var preGain: Double = AppSettings.shared.ledPreGain
    @State private var speed: Double = AppSettings.shared.ledSpeed
    @State private var targetHz: Int = AppSettings.shared.ledTargetHz
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var lookaheadMs: Double = AppSettings.shared.lookaheadMs
    @State private var aboutEasterEggTracker = AboutEasterEggTapTracker()

    private var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    private let fontWeights: [(label: LocalizedStringKey, value: Int)] = [
        ("settings.lyrics.weight_thin", 100),
        ("settings.lyrics.weight_light", 300),
        ("settings.lyrics.weight_regular", 400),
        ("settings.lyrics.weight_medium", 500),
        ("settings.lyrics.weight_semibold", 600),
        ("settings.lyrics.weight_bold", 700),
    ]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 24)
                            .foregroundStyle(selection == category ? .primary : .secondary)

                        Text(category.title)
                            .font(.body)

                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)  // Reduced from 12 to bring content closer to pill edge
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))  // Much tighter to sidebar edges
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selection == category ? themeStore.selectionFill : Color.clear)
                        .padding(.horizontal, 14)  // Narrower, centered pill look
                )
            }
            .listStyle(.sidebar)
            .padding(.top, 16)  // Add top breathing room
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .overlay(
                GlassStyleTokens.highlightGradient
                    .mask(RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 680)
        .onAppear {
            nowPlayingSkin = settings.selectedNowPlayingSkinID
            if SkinRegistry.options.contains(where: { $0.id == nowPlayingSkin }) == false {
                nowPlayingSkin = SkinRegistry.defaultSkinID
            }
        }
        .background(settingsSyncLogic)  // Apply sync logic here
        .background(
            WindowToolbarAccessor { window in
                // Fixes sidebar top-corner clipping/radius issues by ensuring "Liquid Glass"
                // extends to the window edge (Full Size Content view behavior).
                window.titlebarAppearsTransparent = true
            }
        )
    }

    // Extracted Sync Logic to reduce body complexity
    private var settingsSyncLogic: some View {
        Group {
            skinSyncLogic
            lyricsSyncLogic
            ledSyncLogic
        }
    }

    private var skinSyncLogic: some View {
        Color.clear
            .onChange(of: nowPlayingSkin) { _, val in settings.selectedNowPlayingSkinID = val }
    }

    private var lyricsSyncLogic: some View {
        Color.clear
            .onChange(of: lyricsLeadInMs) { _, val in AppSettings.shared.lyricsLeadInMs = val }
            .onChange(of: lyricsFontNameZh) { _, val in AppSettings.shared.lyricsFontNameZh = val }
            .onChange(of: lyricsFontNameEn) { _, val in AppSettings.shared.lyricsFontNameEn = val }
            .onChange(of: lyricsTranslationFontName) { _, val in
                AppSettings.shared.lyricsTranslationFontName = val
            }
            .onChange(of: lyricsFontWeightLight) { _, val in
                AppSettings.shared.lyricsFontWeightLight = val
            }
            .onChange(of: lyricsFontWeightDark) { _, val in
                AppSettings.shared.lyricsFontWeightDark = val
            }
            .onChange(of: lyricsFontSize) { _, val in AppSettings.shared.lyricsFontSize = val }
            .onChange(of: lyricsTranslationFontSize) { _, val in
                AppSettings.shared.lyricsTranslationFontSize = val
            }
            .onChange(of: lyricsTranslationFontWeightLight) { _, val in
                AppSettings.shared.lyricsTranslationFontWeightLight = val
            }
            .onChange(of: lyricsTranslationFontWeightDark) { _, val in
                AppSettings.shared.lyricsTranslationFontWeightDark = val
            }
    }

    private var ledSyncLogic: some View {
        Group {
            Color.clear
                .onChange(of: sensitivity) { _, val in
                    AppSettings.shared.ledSensitivity = val
                    applyLedConfig()
                }
                .onChange(of: cutoffHz) { _, val in
                    AppSettings.shared.ledCutoffHz = val
                    applyLedConfig()
                }
                .onChange(of: preGain) { _, val in
                    AppSettings.shared.ledPreGain = val
                    applyLedConfig()
                }
                .onChange(of: speed) { _, val in
                    AppSettings.shared.ledSpeed = val
                    applyLedConfig()
                }

            Color.clear
                .onChange(of: targetHz) { _, val in
                    AppSettings.shared.ledTargetHz = val
                    applyLedConfig()
                }
                .onChange(of: ledCount) { _, val in
                    AppSettings.shared.ledCount = val
                    applyLedConfig()
                }
                .onChange(of: brightnessLevels) { _, val in
                    AppSettings.shared.ledBrightnessLevels = val
                    applyLedConfig()
                }
                .onChange(of: lookaheadMs) { _, val in
                    AppSettings.shared.lookaheadMs = val
                }

            Color.clear
                .onChange(of: transientThreshold) { _, _ in
                    applyLedConfig()
                }
                .onChange(of: transientIntensity) { _, _ in
                    applyLedConfig()
                }
        }
    }

    // MARK: - Appearance Section

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selection {
                case .nowPlaying:
                    nowPlayingSection
                case .lyrics:
                    amllSection
                case .led:
                    ledSettingsSection
                case .about:
                    aboutSection
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Now Playing Section

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerLabel(
                "settings.section.now_playing",
                systemImage: "sparkles")

            VStack(alignment: .leading, spacing: 12) {
                Text("settings.now_playing.select_skin")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("", selection: $nowPlayingSkin) {
                            ForEach(SkinRegistry.options) { skin in
                                Label(skin.name, systemImage: skin.systemImage)
                                    .tag(skin.id)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let selected = SkinRegistry.options.first(where: {
                            $0.id == nowPlayingSkin
                        }) {
                            Text(LocalizedStringKey(selected.detail))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let selected = SkinRegistry.options.first(where: { $0.id == nowPlayingSkin }),
                let optionsView = SkinRegistry.skin(for: nowPlayingSkin).settingsView
            {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "settings.now_playing.skin_options", comment: ""), selected.name)
                    )
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                    GroupBox {
                        optionsView
                            .padding(12)
                    }
                }
            }
        }
    }

    // MARK: - AMLL Section

    private var amllSection: some View {
        VStack(alignment: .leading, spacing: 20) {  // Reduced from 32
            headerLabel(
                "settings.section.lyrics", systemImage: "text.quote"
            )

            amllTimingConfig
            amllFontsConfig
            amllPreviewConfig
        }
    }

    private var amllTimingConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.lyrics.timing")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("settings.lyrics.leadin")
                            Spacer()
                            Text("\(Int(lyricsLeadInMs)) ms")
                                .foregroundStyle(themeStore.accentColor)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Slider(value: $lyricsLeadInMs, in: 0...800, step: 20)
                    }

                    Text("settings.lyrics.leadin_desc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    private var amllFontsConfig: some View {
        GroupBox(LocalizedStringKey("settings.lyrics.fonts")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("settings.lyrics.font_size")
                    Spacer()
                    Text("\(Int(lyricsFontSize)) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lyricsFontSize, in: 16...48, step: 1)

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

                HStack {
                    Text("settings.lyrics.translation_size")
                    Spacer()
                    Text("\(Int(lyricsTranslationFontSize)) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lyricsTranslationFontSize, in: 12...36, step: 1)

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
    }

    private var amllPreviewConfig: some View {
        GroupBox(LocalizedStringKey("settings.lyrics.preview")) {
            VStack(alignment: .leading, spacing: 12) {
                lyricsPreviewCard(
                    title: "浅色模式预览",
                    isDarkCard: false,
                    mainWeight: lyricsFontWeightLight,
                    translationWeight: lyricsTranslationFontWeightLight
                )
                lyricsPreviewCard(
                    title: "深色模式预览",
                    isDarkCard: true,
                    mainWeight: lyricsFontWeightDark,
                    translationWeight: lyricsTranslationFontWeightDark
                )
            }
        }
    }

    private func lyricsPreviewCard(
        title: String,
        isDarkCard: Bool,
        mainWeight: Int,
        translationWeight: Int
    ) -> some View {
        let backgroundColor = isDarkCard ? Color(red: 0.18, green: 0.18, blue: 0.20) : .white
        let titleColor = isDarkCard ? Color.white.opacity(0.78) : Color.black.opacity(0.65)
        let mainTextColor = isDarkCard ? Color.white : Color.black
        let translationColor = isDarkCard ? Color.white.opacity(0.72) : Color.black.opacity(0.62)

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(titleColor)

            HStack(spacing: 12) {
                Text("settings.lyrics.preview_zh")
                    .font(.custom(lyricsFontNameZh, size: CGFloat(lyricsFontSize)))
                    .fontWeight(fontWeight(mainWeight))
                    .foregroundStyle(mainTextColor)
                Text("settings.lyrics.preview_en")
                    .font(.custom(lyricsFontNameEn, size: CGFloat(lyricsFontSize)))
                    .fontWeight(fontWeight(mainWeight))
                    .foregroundStyle(mainTextColor)
            }

            Text("settings.lyrics.preview_translation")
                .font(.custom(lyricsTranslationFontName, size: CGFloat(lyricsTranslationFontSize)))
                .fontWeight(fontWeight(translationWeight))
                .foregroundStyle(translationColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDarkCard ? Color.white.opacity(0.08) : Color.black.opacity(0.10),
                    lineWidth: 1
                )
        )
    }

    // MARK: - LED Settings Section

    @AppStorage("ledTransientThreshold") private var transientThreshold: Double = 3.0
    @AppStorage("ledTransientIntensity") private var transientIntensity: Double = 1.5
    private var ledSettingsSection: some View {
        VStack(alignment: .leading, spacing: 20) {  // Reduced from 32
            headerLabel(
                "settings.section.led",
                systemImage: "waveform.path.ecg")

            // Live Preview
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.led.live_preview")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    LedMeterView(
                        level: Double(ledMeter.normalizedLevel),
                        ledValues: ledMeter.metrics.leds,
                        dotSize: 14,
                        spacing: 7
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.primary.opacity(0.05))
                    )
                }
            }

            // Visual Config
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.led.config")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(spacing: 16) {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                            GridRow {
                                Text("settings.led.count")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $ledCount) {
                                    Text("9").tag(9)
                                    Text("11").tag(11)
                                    Text("13").tag(13)
                                    Text("15").tag(15)
                                }
                                .labelsHidden()
                            }
                            GridRow {
                                Text("settings.led.brightness")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $brightnessLevels) {
                                    Text("3").tag(3)
                                    Text("5").tag(5)
                                    Text("7").tag(7)
                                }
                                .labelsHidden()
                            }
                        }

                        Divider()

                        ledSensitivitySlider

                        Divider()

                        ledTuningSliders
                    }
                    .padding(16)
                }
            }
        }
    }

    private var ledSensitivitySlider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("settings.led.sensitivity")
                Spacer()
                Text(String(format: "%.1fx", sensitivity))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $sensitivity, in: 0.5...3.0)
            Text("settings.led.sensitivity_desc")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
    }

    private var ledTuningSliders: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.frequency")
                    Spacer()
                    Text(String(format: "%.0f Hz", cutoffHz))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $cutoffHz, in: 200...6000, step: 100)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.pregain")
                    Spacer()
                    Text(String(format: "%.2fx", preGain))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $preGain, in: 0.0...2.0, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.transient_threshold")
                    Spacer()
                    Text(String(format: "%.1f dB", transientThreshold))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $transientThreshold, in: 1.0...12.0, step: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.transient_intensity")
                    Spacer()
                    Text(String(format: "%.1fx", transientIntensity))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $transientIntensity, in: 0.0...4.0, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.speed")
                    Spacer()
                    Text(String(format: "%.2fx", speed))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speed, in: 0.5...2.0, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.publish_rate")
                    Spacer()
                    Text("\(targetHz) Hz")
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: $targetHz) {
                    Text("30 Hz").tag(30)
                    Text("60 Hz").tag(60)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.led.lookahead")
                    Spacer()
                    Text(String(format: "%.0f ms", lookaheadMs))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lookaheadMs, in: 0...500, step: 10)
                Text("settings.led.lookahead_desc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 40)

            Image("EmptyLyric")
                .resizable()
                .scaledToFit()
                .frame(width: 230, height: 230)
                .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)

            VStack(spacing: 8) {
                Text(Constants.appName)
                    .font(.title.bold())
                Text(
                    String(
                        format: NSLocalizedString("settings.about.version", comment: ""),
                        Constants.appVersion)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Text(NSLocalizedString("settings.about.quote", comment: ""))
                .font(.body)
                .fontWeight(.ultraLight)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
                .padding(.top, 12)

            Spacer()

            Divider()
                .padding(.vertical, 32)

            HStack(spacing: 10) {
                socialIconLink(
                    title: "b",
                    hexColor: "fb7299",
                    destination: "https://space.bilibili.com/1605472940"
                )
                socialIconLink(
                    title: "g",
                    hexColor: "020408",
                    destination: "https://github.com/kmgcc"
                )
                socialIconLink(
                    title: "书",
                    hexColor: "f72241",
                    destination: "https://xhslink.com/m/7o53GE3YNQy"
                )

                Link("查看更新", destination: URL(string: "https://github.com/kmgcc/kmgccc_player/releases")!)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 34)

            VStack(alignment: .leading, spacing: 20) {
                Text(NSLocalizedString("settings.about.compliance", comment: ""))
                    .font(.headline)

                Text("settings.about.compliance_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 16) {
                    complianceItem(
                        name: "applemusic-like-lyrics",
                        url: "https://github.com/amll-dev/applemusic-like-lyrics"
                    )
                    complianceItem(
                        name: "apple-audio-visualization",
                        url: "https://github.com/taterboom/apple-audio-visualization"
                    )
                    complianceItem(
                        name: "LDDC",
                        url: "https://github.com/chenmozhijin/LDDC"
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.about.source_code")
                        .font(.subheadline.bold())
                    Text("settings.about.source_code_desc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(
                        "https://github.com/kmgccc/TrueMusic",
                        destination: URL(string: "https://github.com/kmgcc/kmgccc_player")!
                    )
                    .font(.caption)
                }
                .padding(.top, 10)

                Text("settings.about.license")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("版权与素材声明")
                        .font(.headline)
                    Text(
                        "本项目中所使用的所有美术素材，包括但不限于界面插画、UI 装饰、皮肤、贴图、角色设计、视觉元素，均为作者原创作品。"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Text(
                        "上述美术素材 不属于开源代码的一部分，亦 不适用 AGPL-3.0 许可证。\n未经明确许可，不得对这些素材进行复制、修改、再分发或用于 AI 训练等其他项目。"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                Spacer()

                Text("settings.about.copyright")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .overlay {
            GeometryReader { proxy in
                let minimumSideWidth: CGFloat = 72
                let centerWidth = min(
                    560,
                    max(280, proxy.size.width - minimumSideWidth * 2)
                )
                let sideWidth = max(0, (proxy.size.width - centerWidth) / 2)

                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: sideWidth, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { handleAboutTap(on: .left) }

                    Color.clear
                        .frame(width: centerWidth, height: proxy.size.height)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: sideWidth, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { handleAboutTap(on: .right) }
                }
                .onAppear {
                    print(
                        "[AboutEasterEgg] overlay widths - total: \(Int(proxy.size.width)), center: \(Int(centerWidth)), side: \(Int(sideWidth))"
                    )
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    let adjustedCenter = min(560, max(280, newWidth - minimumSideWidth * 2))
                    let adjustedSide = max(0, (newWidth - adjustedCenter) / 2)
                    print(
                        "[AboutEasterEgg] overlay widths changed - total: \(Int(newWidth)), center: \(Int(adjustedCenter)), side: \(Int(adjustedSide))"
                    )
                }
            }
            .allowsHitTesting(true)
        }
    }

    private func handleAboutTap(on side: AboutTapSide) {
        print("[AboutEasterEgg] side tap: \(side == .left ? "left" : "right")")
        if aboutEasterEggTracker.registerTap(on: side) {
            print("[AboutEasterEgg] sequence matched -> trigger")
            NotificationCenter.default.post(name: .aboutEasterEggTriggered, object: nil)
        }
    }

    private func complianceItem(name: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline.bold())
            Link(url, destination: URL(string: url)!)
                .font(.caption)
            //            Text("Modified source code is used in this application.")
            //                .font(.caption2)
            //                .foregroundStyle(.secondary)
        }
    }

    private func socialIconLink(title: String, hexColor: String, destination: String) -> some View {
        Link(destination: URL(string: destination)!) {
            Circle()
                .fill(Color(hex: hexColor) ?? .secondary)
                .frame(width: 30, height: 30)
                .overlay {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .buttonStyle(.plain)
    }

    private func headerLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {  // Reduced spacing
            Image(systemName: systemImage)
                .foregroundStyle(themeStore.accentColor)
                .font(.title3.bold())
            Text(LocalizedStringKey(title))
                .font(.title2.bold())
        }
        .padding(.bottom, 4)  // Reduced padding (let VStack spacing handle the gap)
    }

    private func fontWeight(_ weight: Int) -> Font.Weight {
        switch weight {
        case 100: return .ultraLight
        case 200: return .thin
        case 300: return .light
        case 400: return .regular
        case 500: return .medium
        case 600: return .semibold
        case 700: return .bold
        case 800: return .heavy
        case 900: return .black
        default: return .regular
        }
    }

    private func applyLedConfig() {
        ledMeter.updateConfig(
            LEDMeterConfig(
                ledCount: ledCount,
                levels: brightnessLevels,
                cutoffHz: Float(cutoffHz),
                preGain: Float(preGain),
                sensitivity: sensitivity,
                speed: Float(speed),
                targetHz: targetHz,
                transientThreshold: Float(transientThreshold),
                transientIntensity: Float(transientIntensity)
            )
        )
    }

}

private enum AboutTapSide {
    case left
    case right
}

private struct AboutEasterEggTapTracker {
    private static let requiredTapCount = 4
    private static let minInterval: TimeInterval = 0.14
    private static let maxInterval: TimeInterval = 1.05

    private var lastSide: AboutTapSide?
    private var lastTapTime: TimeInterval?
    private var tapCount: Int = 0

    mutating func registerTap(on side: AboutTapSide, now: TimeInterval = Date.timeIntervalSinceReferenceDate)
        -> Bool
    {
        guard let previousSide = lastSide, let previousTime = lastTapTime else {
            lastSide = side
            lastTapTime = now
            tapCount = 1
            return false
        }

        let interval = now - previousTime
        let isAlternating = previousSide != side
        let isTimingValid = interval >= Self.minInterval && interval <= Self.maxInterval

        if isAlternating && isTimingValid {
            tapCount += 1
            lastSide = side
            lastTapTime = now

            if tapCount >= Self.requiredTapCount {
                reset()
                return true
            }
            return false
        }

        lastSide = side
        lastTapTime = now
        tapCount = 1
        return false
    }

    private mutating func reset() {
        lastSide = nil
        lastTapTime = nil
        tapCount = 0
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case nowPlaying
    case lyrics
    case led
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .nowPlaying: return "settings.section.now_playing"
        case .lyrics: return "settings.section.lyrics"
        case .led: return "settings.section.led"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: return "sparkles"
        case .lyrics: return "text.quote"
        case .led: return "waveform.path.ecg"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Preview

#Preview("Settings") {
    SettingsView()
        .environment(LEDMeterService())
        .environmentObject(ThemeStore.shared)
}

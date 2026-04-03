//
//  SettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Settings View
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import AppKit
import SwiftUI

/// Settings view with sidebar categories.
@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LEDMeterService.self) private var ledMeter
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    // MARK: - Navigation

    @State private var selection: SettingsCategory = .appearance
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // MARK: - App Settings

    // MARK: - AMLL Settings

    @State private var lyricsLeadInMs: Double = AppSettings.shared.lyricsLeadInMs
    @State private var lyricsNearSwitchGapMs: Double = AppSettings.shared.lyricsNearSwitchGapMs
    @State private var lyricsGlobalAdvanceMs: Double = AppSettings.shared.lyricsGlobalAdvanceMs
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
    @State private var nowPlayingArtBackgroundEnabled: Bool = AppSettings.shared
        .nowPlayingArtBackgroundEnabled
    @State private var globalArtworkTintEnabled: Bool = AppSettings.shared.globalArtworkTintEnabled
    @State private var followSystemAppearance: Bool = AppSettings.shared.followSystemAppearance
    @State private var lyricsBackgroundMode: AppSettings.LyricsBackgroundMode = AppSettings.shared
        .lyricsBackgroundMode
    @AppStorage("skin.classicLED.visualizerMode") private var classicVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.visualizerMode") private var cassetteVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var cassetteShowKmgLook: Bool = false

    // MARK: - LED Settings State

    @State private var sensitivity: Float = AppSettings.shared.ledSensitivity
    @State private var cutoffHz: Double = AppSettings.shared.ledCutoffHz
    @State private var preGain: Double = AppSettings.shared.ledPreGain
    @State private var speed: Double = AppSettings.shared.ledSpeed
    @State private var targetHz: Int = AppSettings.shared.ledTargetHz
    @State private var ledCount: Int = AppSettings.shared.ledCount
    @State private var brightnessLevels: Int = AppSettings.shared.ledBrightnessLevels
    @State private var lookaheadMs: Double = AppSettings.shared.lookaheadMs

    // MARK: - Fullscreen Settings State

    @State private var fullscreenArtworkScale: Double = AppSettings.shared.fullscreenArtworkScale
    @State private var fullscreenLyricsFontScale: Double = AppSettings.shared.fullscreenLyricsFontScale
    @State private var fullscreenDimmingIntensity: Double = AppSettings.shared.fullscreenDimmingIntensity
    @State private var fullscreenLyricsFontNameZh: String = AppSettings.shared
        .fullscreenLyricsFontNameZh
    @State private var fullscreenLyricsFontNameEn: String = AppSettings.shared
        .fullscreenLyricsFontNameEn
    @State private var fullscreenLyricsTranslationFontName: String = AppSettings.shared
        .fullscreenLyricsTranslationFontName
    @State private var fullscreenLyricsFontWeight: Int = AppSettings.shared
        .fullscreenLyricsFontWeight
    @State private var fullscreenLyricsTranslationFontWeight: Int = AppSettings.shared
        .fullscreenLyricsTranslationFontWeight
    @State private var fullscreenLyricsFontSize: Double = AppSettings.shared.fullscreenLyricsFontSize
    @State private var fullscreenLyricsTranslationFontSize: Double = AppSettings.shared
        .fullscreenLyricsTranslationFontSize
    @State private var aboutEasterEggTracker = AboutEasterEggTapTracker()
    @State private var showEasterEggImage: Bool = false
    @State private var showResetDataAlert: Bool = false
    @State private var showClearIndexCacheAlert: Bool = false
    @State private var showClearArtworkColorCacheAlert: Bool = false

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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                // Sidebar Header
                Text("设置")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                List(SettingsCategory.allCases) { category in
                    Button {
                        selection = category
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.systemImage)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 20)
                                .foregroundStyle(
                                    selection == category ? themeStore.accentColor : .primary)

                            Text(category.title)
                                .font(.body)
                                .fontWeight(selection == category ? .medium : .regular)
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                    .listRowBackground(
                        Capsule()
                            .fill(selection == category ? themeStore.selectionFill : Color.clear)
                            .padding(.horizontal, 14)
                    )
                }
                .listStyle(.sidebar)
            }
            .background(Material.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .navigationSplitViewColumnWidth(
                min: GlassStyleTokens.sidebarMinWidth, ideal: GlassStyleTokens.sidebarWidth,
                max: 300)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .overlay(alignment: .topTrailing) {
            GlassIconButton(
                systemImage: "xmark",
                size: GlassStyleTokens.headerControlHeight,
                iconSize: GlassStyleTokens.headerStandardIconSize,
                isPrimary: false,
                help: "关闭",
                surfaceVariant: .defaultToolbar
            ) {
                dismiss()
            }
            .padding(GlassStyleTokens.headerHorizontalPadding)
        }
        .frame(minWidth: 760, minHeight: 680)
        .onAppear {
            showEasterEggImage = false
            nowPlayingSkin = settings.selectedNowPlayingSkinID
            nowPlayingArtBackgroundEnabled = settings.nowPlayingArtBackgroundEnabled
            globalArtworkTintEnabled = settings.globalArtworkTintEnabled
            followSystemAppearance = settings.followSystemAppearance
            lyricsBackgroundMode = settings.lyricsBackgroundMode
            // Coordinator handles skin state - no manual sync needed
            settings.fullscreen.normalizeConfiguration()
            syncFullscreenLyricsStateFromSettings()
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
        .alert("初始化应用数据？", isPresented: $showResetDataAlert) {
            Button("取消", role: .cancel) {}
            Button("初始化", role: .destructive) {
                resetAppDataExceptMusicLibrary()
            }
        } message: {
            Text("会重置应用设置与界面状态，不会修改音乐资料库内容。")
        }
        .alert("清除索引缓存？", isPresented: $showClearIndexCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await libraryVM.clearIndexCacheAndRebuild()
                }
            }
        } message: {
            Text("将清空索引缓存并立即重新扫描音乐资料库，不会删除音频、meta.json 或播放列表。")
        }
        .alert("清除取色缓存？", isPresented: $showClearArtworkColorCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task {
                    await ArtworkAssetStore.shared.clearCache()
                }
            }
        } message: {
            Text("将清空歌曲封面取色缓存，下次播放时会重新提取颜色。")
        }
    }

    // Extracted Sync Logic to reduce body complexity
    private var settingsSyncLogic: some View {
        Group {
            appearanceSyncLogic
            skinSyncLogic
            lyricsSyncLogic
            fullscreenSyncLogic
            ledSyncLogic
        }
    }

    private var appearanceSyncLogic: some View {
        Color.clear
            .onChange(of: globalArtworkTintEnabled) { _, val in
                settings.globalArtworkTintEnabled = val
                Task { @MainActor in
                    await themeStore.refreshPalette(reason: "settings_global_tint_change")
                }
            }
            .onChange(of: followSystemAppearance) { _, val in
                settings.followSystemAppearance = val
            }
            .onChange(of: lyricsBackgroundMode) { _, val in
                settings.lyricsBackgroundMode = val
            }
    }

    private var skinSyncLogic: some View {
        Color.clear
            .onChange(of: nowPlayingSkin) { _, val in
                settings.selectedNowPlayingSkinID = val
                playerVM.refreshLedMeterStateFromSettings()
            }
            .onChange(of: nowPlayingArtBackgroundEnabled) { _, val in
                settings.nowPlayingArtBackgroundEnabled = val
            }
    }

    private var lyricsSyncLogic: some View {
        Color.clear
            .onChange(of: lyricsLeadInMs) { _, val in
                AppSettings.shared.lyricsLeadInMs = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsNearSwitchGapMs) { _, val in
                AppSettings.shared.lyricsNearSwitchGapMs = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsGlobalAdvanceMs) { _, val in
                AppSettings.shared.lyricsGlobalAdvanceMs = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontNameZh) { _, val in
                AppSettings.shared.lyricsFontNameZh = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontNameEn) { _, val in
                AppSettings.shared.lyricsFontNameEn = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontName) { _, val in
                AppSettings.shared.lyricsTranslationFontName = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontWeightLight) { _, val in
                AppSettings.shared.lyricsFontWeightLight = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontWeightDark) { _, val in
                AppSettings.shared.lyricsFontWeightDark = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontSize) { _, val in
                AppSettings.shared.lyricsFontSize = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontSize) { _, val in
                AppSettings.shared.lyricsTranslationFontSize = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontWeightLight) { _, val in
                AppSettings.shared.lyricsTranslationFontWeightLight = val
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontWeightDark) { _, val in
                AppSettings.shared.lyricsTranslationFontWeightDark = val
                lyricsVM.refreshConfigFromSettings()
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

    private var fullscreenSyncLogic: some View {
        Color.clear
            .onChange(of: fullscreenLyricsFontScale) { _, val in
                AppSettings.shared.fullscreenLyricsFontScale = val
            }
            .onChange(of: fullscreenLyricsFontNameZh) { _, val in
                AppSettings.shared.fullscreenLyricsFontNameZh = val
            }
            .onChange(of: fullscreenLyricsFontNameEn) { _, val in
                AppSettings.shared.fullscreenLyricsFontNameEn = val
            }
            .onChange(of: fullscreenLyricsTranslationFontName) { _, val in
                AppSettings.shared.fullscreenLyricsTranslationFontName = val
            }
            .onChange(of: fullscreenLyricsFontWeight) { _, val in
                AppSettings.shared.fullscreenLyricsFontWeight = val
            }
            .onChange(of: fullscreenLyricsTranslationFontWeight) { _, val in
                AppSettings.shared.fullscreenLyricsTranslationFontWeight = val
            }
    }

    private func handleSkinLEDToggleChange(for skinID: String, isOn: Bool) {
        guard nowPlayingSkin == skinID else { return }
        playerVM.refreshLedMeterStateFromSettings()
    }

    // MARK: - Appearance Section

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selection {
                case .appearance:
                    appearanceSection
                case .nowPlaying:
                    nowPlayingSection
                case .fullscreen:
                    fullscreenSection
                case .lyrics:
                    amllSection
                case .led:
                    ledSettingsSection
                case .data:
                    dataSection
                case .about:
                    aboutSection
                }
            }
            .padding(.horizontal, 32)
            // Manual Adjustment: Main detail content top padding
            .padding(.vertical, 40)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Now Playing Section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerLabel("外观", systemImage: "paintpalette")

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("全局取色", isOn: $globalArtworkTintEnabled)
                    Text("开启后重点色跟随当前歌曲封面；关闭后使用默认主题色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("跟随系统", isOn: $followSystemAppearance)
                    Text("开启后跟随系统深浅色；关闭后可用侧边栏按钮手动切换深/浅。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // Lyrics Background Mode - Capsule Picker Style
                    HStack(spacing: 8) {
                        Text("歌词背景")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Spacer()

                        HStack(spacing: 4) {
                            ForEach(AppSettings.LyricsBackgroundMode.allCases) { mode in
                                Button {
                                    lyricsBackgroundMode = mode
                                } label: {
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: lyricsBackgroundMode == mode ? .medium : .regular))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    Capsule()
                                        .fill(lyricsBackgroundMode == mode ? themeStore.accentColor.opacity(0.18) : Color.clear)
                                )
                                .foregroundStyle(lyricsBackgroundMode == mode ? themeStore.accentColor : .secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.08))
                        )
                    }
                }
                .toggleStyle(.switch)
                .padding(12)
            }
        }
    }

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerLabel(
                "settings.section.now_playing",
                systemImage: "sparkles")

            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("启用艺术背景 (Beta)", isOn: $nowPlayingArtBackgroundEnabled)
                            .toggleStyle(.switch)
                        Text(" 遇到性能问题时，可以关闭此选项。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                Text("settings.now_playing.select_skin")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("", selection: $nowPlayingSkin) {
                            ForEach(SkinRegistry.nowPlayingOptions) { skin in
                                Label(skin.name, systemImage: skin.systemImage)
                                    .tag(skin.id)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let selected = SkinRegistry.nowPlayingOptions.first(where: {
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

    // MARK: - Fullscreen Section

    private var fullscreenSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerLabel("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right")

            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("全屏皮肤")
                        .font(.headline)

                    Picker("", selection: Binding(
                        get: { settings.fullscreen.skinID },
                        set: { settings.fullscreen.setSkinID($0) }
                    )) {
                        ForEach(SkinRegistry.fullscreenOptions) { skin in
                            Label(skin.name, systemImage: skin.systemImage)
                                .tag(skin.id)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Divider()

                    Toggle("底栏频谱动画", isOn: Binding(
                        get: { settings.fullscreen.isMiniPlayerSpectrumEnabled },
                        set: { _ in settings.fullscreen.toggleMiniPlayerSpectrum() }
                    ))
                    .toggleStyle(.switch)

//                    Text("开启后，全屏 MiniPlayer 右侧会显示频谱可视化。与皮肤自带的频谱/LED电平表互斥。")
//                        .font(.caption)
//                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            if let _ = SkinRegistry.fullscreenOptions.first(where: { $0.id == settings.fullscreen.skinID }),
               let optionsView = SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID).fullscreenSettingsView {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("皮肤选项")
                            .font(.headline)
                        optionsView
                    }
                    .padding(12)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("封面缩放")
                            Spacer()
                            Text(String(format: "%.2f", fullscreenArtworkScale))
                                .foregroundStyle(themeStore.accentColor)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Slider(
                            value: $fullscreenArtworkScale,
                            in: 0.8...1.5,
                            step: 0.05
                        ) { editing in
                            if editing == false {
                                AppSettings.shared.fullscreenArtworkScale = fullscreenArtworkScale
                            }
                        }
                        Text("调整全屏模式下歌曲封面的显示大小")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    fullscreenLyricsTypographyConfig

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("背景压暗强度")
                            Spacer()
                            Text(String(format: "%.0f%%", fullscreenDimmingIntensity * 100))
                                .foregroundStyle(themeStore.accentColor)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Slider(
                            value: $fullscreenDimmingIntensity,
                            in: 0.0...0.5,
                            step: 0.05
                        ) { editing in
                            if editing == false {
                                AppSettings.shared.fullscreenDimmingIntensity =
                                    fullscreenDimmingIntensity
                            }
                        }
                        Text("调整全屏模式下背景压暗程度，提高可读性")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                }
                .padding(12)
            }

            fullscreenLyricsPreviewConfig
        }
    }

    private var fullscreenLyricsTypographyConfig: some View {
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
            ) { editing in
                if editing == false {
                    AppSettings.shared.fullscreenLyricsFontSize = fullscreenLyricsFontSize
                }
            }

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
            ) { editing in
                if editing == false {
                    AppSettings.shared.fullscreenLyricsTranslationFontSize =
                        fullscreenLyricsTranslationFontSize
                }
            }

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
    }

    private var fullscreenLyricsPreviewConfig: some View {
        GroupBox("全屏歌词预览") {
            lyricsPreviewCard(
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
            HStack {
                Text("settings.lyrics.timing")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认值") {
                    lyricsLeadInMs = 300
                    lyricsNearSwitchGapMs = 85
                    lyricsGlobalAdvanceMs = 0
                    AppSettings.shared.lyricsLeadInMs = 300
                    AppSettings.shared.lyricsNearSwitchGapMs = 85
                    AppSettings.shared.lyricsGlobalAdvanceMs = 0
                    lyricsVM.refreshConfigFromSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Text("参数仅供调试，正常使用无需调整")
                .font(.caption2)
                .foregroundStyle(.tertiary)

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
                        Slider(value: $lyricsLeadInMs, in: 0...1200, step: 20)
                    }

                    Text("settings.lyrics.leadin_desc")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("settings.lyrics.near_switch_gap")
                            Spacer()
                            Text("\(Int(lyricsNearSwitchGapMs)) ms")
                                .foregroundStyle(themeStore.accentColor)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Slider(value: $lyricsNearSwitchGapMs, in: 0...500, step: 5)
                    }

                    Text("settings.lyrics.near_switch_gap_desc")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("歌词整体提前量")
                            Spacer()
                            Text("\(Int(lyricsGlobalAdvanceMs)) ms")
                                .foregroundStyle(themeStore.accentColor)
                                .font(.system(.subheadline, design: .monospaced))
                        }
                        Slider(value: $lyricsGlobalAdvanceMs, in: -1000...1000, step: 10)
                    }

                    Text("全曲统一提前（正值=更早显示，负值=更晚显示）。会与单曲时间偏移共同作用。")
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
        translationWeight: Int,
        mainFontNameZh: String? = nil,
        mainFontNameEn: String? = nil,
        translationFontName: String? = nil,
        mainFontSize: Double? = nil,
        translationFontSize: Double? = nil
    ) -> some View {
        let backgroundColor = isDarkCard ? Color(red: 0.18, green: 0.18, blue: 0.20) : .white
        let titleColor = isDarkCard ? Color.white.opacity(0.78) : Color.black.opacity(0.65)
        let mainTextColor = isDarkCard ? Color.white : Color.black
        let translationColor = isDarkCard ? Color.white.opacity(0.72) : Color.black.opacity(0.62)
        let resolvedZhFont = mainFontNameZh ?? lyricsFontNameZh
        let resolvedEnFont = mainFontNameEn ?? lyricsFontNameEn
        let resolvedTranslationFont = translationFontName ?? lyricsTranslationFontName
        let resolvedMainFontSize = CGFloat(mainFontSize ?? lyricsFontSize)
        let resolvedTranslationFontSize = CGFloat(translationFontSize ?? lyricsTranslationFontSize)

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(titleColor)

            HStack(spacing: 12) {
                Text("settings.lyrics.preview_zh")
                    .font(.custom(resolvedZhFont, size: resolvedMainFontSize))
                    .fontWeight(fontWeight(mainWeight))
                    .foregroundStyle(mainTextColor)
                Text("settings.lyrics.preview_en")
                    .font(.custom(resolvedEnFont, size: resolvedMainFontSize))
                    .fontWeight(fontWeight(mainWeight))
                    .foregroundStyle(mainTextColor)
            }

            Text("settings.lyrics.preview_translation")
                .font(.custom(resolvedTranslationFont, size: resolvedTranslationFontSize))
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

    @AppStorage("ledTransientThreshold") private var transientThreshold: Double = 12.0
    @AppStorage("ledTransientIntensity") private var transientIntensity: Double = 4.0
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
                        // LED Count - Capsule Picker Style
                        HStack(spacing: 8) {
                            Text("settings.led.count")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Spacer()

                            HStack(spacing: 4) {
                                ForEach([9, 11, 13, 15], id: \.self) { count in
                                    Button {
                                        ledCount = count
                                    } label: {
                                        Text("\(count)")
                                            .font(.system(size: 11, weight: ledCount == count ? .medium : .regular))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                    .background(
                                        Capsule()
                                            .fill(ledCount == count ? themeStore.accentColor.opacity(0.18) : Color.clear)
                                    )
                                    .foregroundStyle(ledCount == count ? themeStore.accentColor : .secondary)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }

                        // Brightness Levels - Capsule Picker Style
                        HStack(spacing: 8) {
                            Text("settings.led.brightness")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Spacer()

                            HStack(spacing: 4) {
                                ForEach([3, 5, 7], id: \.self) { level in
                                    Button {
                                        brightnessLevels = level
                                    } label: {
                                        Text("\(level)")
                                            .font(.system(size: 11, weight: brightnessLevels == level ? .medium : .regular))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                    .background(
                                        Capsule()
                                            .fill(brightnessLevels == level ? themeStore.accentColor.opacity(0.18) : Color.clear)
                                    )
                                    .foregroundStyle(brightnessLevels == level ? themeStore.accentColor : .secondary)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.08))
                            )
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

            // Refresh Rate - Capsule Picker Style
            HStack(spacing: 8) {
                Text("settings.led.publish_rate")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    ForEach([30, 60], id: \.self) { hz in
                        Button {
                            targetHz = hz
                        } label: {
                            Text("\(hz) Hz")
                                .font(.system(size: 11, weight: targetHz == hz ? .medium : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .background(
                            Capsule()
                                .fill(targetHz == hz ? themeStore.accentColor.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(targetHz == hz ? themeStore.accentColor : .secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.08))
                )
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

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerLabel("数据", systemImage: "arrow.counterclockwise.circle")

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("将应用配置恢复为初始默认值，不会修改音乐资料库。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("初始化应用设置", role: .destructive) {
                            showResetDataAlert = true
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())

                        Button("清除索引缓存") {
                            showClearIndexCacheAlert = true
                        }
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                    }
                }
                .padding(12)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("清除歌曲封面取色缓存。若遇到取色异常、颜色显示不正确，可尝试清除缓存。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("清除取色缓存") {
                        showClearArtworkColorCacheAlert = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                }
                .padding(12)
            }
        }
    }

    private func resetAppDataExceptMusicLibrary() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        // Only clear app defaults. Local music library under ~/Music is untouched.
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()

        reloadStateFromDefaults()
    }

    private func reloadStateFromDefaults() {
        nowPlayingSkin = AppSettings.shared.selectedNowPlayingSkinID
        nowPlayingArtBackgroundEnabled = AppSettings.shared.nowPlayingArtBackgroundEnabled
        globalArtworkTintEnabled = AppSettings.shared.globalArtworkTintEnabled
        followSystemAppearance = AppSettings.shared.followSystemAppearance
        lyricsBackgroundMode = AppSettings.shared.lyricsBackgroundMode

        classicVisualizerMode = "off"
        cassetteVisualizerMode = "off"
        cassetteShowKmgLook = false

        sensitivity = AppSettings.shared.ledSensitivity
        cutoffHz = AppSettings.shared.ledCutoffHz
        preGain = AppSettings.shared.ledPreGain
        speed = AppSettings.shared.ledSpeed
        targetHz = AppSettings.shared.ledTargetHz
        ledCount = AppSettings.shared.ledCount
        brightnessLevels = AppSettings.shared.ledBrightnessLevels
        lookaheadMs = AppSettings.shared.lookaheadMs
        transientThreshold = AppSettings.shared.ledTransientThreshold
        transientIntensity = AppSettings.shared.ledTransientIntensity

        lyricsLeadInMs = AppSettings.shared.lyricsLeadInMs
        lyricsNearSwitchGapMs = AppSettings.shared.lyricsNearSwitchGapMs
        lyricsGlobalAdvanceMs = AppSettings.shared.lyricsGlobalAdvanceMs
        lyricsFontNameZh = AppSettings.shared.lyricsFontNameZh
        lyricsFontNameEn = AppSettings.shared.lyricsFontNameEn
        lyricsTranslationFontName = AppSettings.shared.lyricsTranslationFontName
        lyricsFontWeightLight = AppSettings.shared.lyricsFontWeightLight
        lyricsFontWeightDark = AppSettings.shared.lyricsFontWeightDark
        lyricsFontSize = AppSettings.shared.lyricsFontSize
        lyricsTranslationFontSize = AppSettings.shared.lyricsTranslationFontSize
        lyricsTranslationFontWeightLight = AppSettings.shared.lyricsTranslationFontWeightLight
        lyricsTranslationFontWeightDark = AppSettings.shared.lyricsTranslationFontWeightDark
        fullscreenArtworkScale = AppSettings.shared.fullscreenArtworkScale
        fullscreenLyricsFontScale = AppSettings.shared.fullscreenLyricsFontScale
        fullscreenDimmingIntensity = AppSettings.shared.fullscreenDimmingIntensity
        syncFullscreenLyricsStateFromSettings()

        applyLedConfig()
        lyricsVM.refreshConfigFromSettings()
        playerVM.refreshLedMeterStateFromSettings()
        Task { @MainActor in
            await themeStore.refreshPalette(reason: "settings_reset_defaults")
        }
    }

    private func syncFullscreenLyricsStateFromSettings() {
        fullscreenLyricsFontNameZh = AppSettings.shared.fullscreenLyricsFontNameZh
        fullscreenLyricsFontNameEn = AppSettings.shared.fullscreenLyricsFontNameEn
        fullscreenLyricsTranslationFontName = AppSettings.shared.fullscreenLyricsTranslationFontName
        fullscreenLyricsFontWeight = AppSettings.shared.fullscreenLyricsFontWeight
        fullscreenLyricsTranslationFontWeight = AppSettings.shared.fullscreenLyricsTranslationFontWeight
        fullscreenLyricsFontSize = AppSettings.shared.fullscreenLyricsFontSize
        fullscreenLyricsTranslationFontSize = AppSettings.shared.fullscreenLyricsTranslationFontSize
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 40)

            Image(showEasterEggImage ? "jntm" : "EmptyLyric")
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
                    title: "哔",
                    hexColor: "fb7299",
                    destination: "https://space.bilibili.com/1605472940"
                )
                socialIconLink(
                    title: "码",
                    hexColor: "020408",
                    destination: "https://github.com/kmgcc"
                )
                socialIconLink(
                    title: "书",
                    hexColor: "f72241",
                    destination: "https://xhslink.com/m/7o53GE3YNQy"
                )

                Link(
                    "查看更新",
                    destination: URL(string: "https://github.com/kmgcc/kmgccc_player/releases")!
                )
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .clipShape(Capsule())
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
                        url: "https://github.com/amll-dev/applemusic-like-lyrics",
                        license: "AGPL-3.0"
                    )
                    complianceItem(
                        name: "apple-audio-visualization",
                        url: "https://github.com/taterboom/apple-audio-visualization",
                        license: nil
                    )
                    complianceItem(
                        name: "LDDC",
                        url: "https://github.com/chenmozhijin/LDDC",
                        license: "GPL-3.0"
                    )
                    complianceItem(
                        name: "sacad",
                        url: "https://github.com/desbma/sacad",
                        license: "MPL-2.0"
                    )
                    complianceItem(
                        name: "ncmdump",
                        url: "https://github.com/taurusxin/ncmdump",
                        license: "MIT"
                    )
                    complianceItem(
                        name: "WhatsNewKit",
                        url: "https://github.com/SvenTiigi/WhatsNewKit",
                        license: "MIT"
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.about.source_code")
                        .font(.subheadline.bold())
                    Text("settings.about.source_code_desc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(
                        "https://github.com/kmgccc/kmgccc_player",
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
            showEasterEggImage = true
            NotificationCenter.default.post(name: .aboutEasterEggTriggered, object: nil)
        }
    }

    private func complianceItem(name: String, url: String, license: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.bold())
                Link(url, destination: URL(string: url)!)
                    .font(.caption)
            }
            
            Spacer()
            
            if let license = license {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(license)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(licenseColor(for: license).opacity(0.15))
                )
                .foregroundStyle(licenseColor(for: license))
            } else {
                
            }
        }
    }
    
    private func licenseColor(for license: String) -> Color {
        switch license {
        case "MIT": return .green
        case "GPL-3.0", "AGPL-3.0": return .blue
        case "MPL-2.0": return .purple
        case "Apache-2.0": return .teal
        case "BSD": return .cyan
        default: return .secondary
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

    mutating func registerTap(
        on side: AboutTapSide, now: TimeInterval = Date.timeIntervalSinceReferenceDate
    )
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

// MARK: - Capsule Picker Component

/// A reusable capsule-style picker with buttons inside a capsule container.
/// Matches the Liquid Glass aesthetic used throughout the app.
struct CapsulePicker<T: Hashable & Identifiable>: View where T.ID: Hashable {
    let label: String
    let options: [T]
    let displayName: (T) -> String
    @Binding var selection: T.ID
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 4) {
                ForEach(options) { option in
                    CapsulePickerButton(
                        title: displayName(option),
                        isSelected: selection == option.id,
                        accentColor: accentColor
                    ) {
                        selection = option.id
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }
}

/// Individual button inside CapsulePicker.
struct CapsulePickerButton: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(isSelected ? accentColor.opacity(0.18) : Color.clear)
        )
        .foregroundStyle(isSelected ? accentColor : .secondary)
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance
    case nowPlaying
    case fullscreen
    case lyrics
    case led
    case data
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: return "外观"
        case .nowPlaying: return "settings.section.now_playing"
        case .fullscreen: return "全屏播放"
        case .lyrics: return "settings.section.lyrics"
        case .led: return "settings.section.led"
        case .data: return "数据"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .nowPlaying: return "sparkles"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .lyrics: return "text.quote"
        case .led: return "waveform.path.ecg"
        case .data: return "arrow.counterclockwise.circle"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Preview

#Preview("Settings") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let lyricsVM = LyricsViewModel()

    SettingsView()
        .environment(LEDMeterService())
        .environment(playerVM)
        .environment(lyricsVM)
        .environment(AppSettings.shared)
        .environmentObject(ThemeStore.shared)
}

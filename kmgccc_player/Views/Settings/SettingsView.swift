//
//  SettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Settings View (Refactored)
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import AppKit
import MotionKit
import PopupKit
import SwiftUI

/// Settings view with sidebar categories.
@MainActor
struct SettingsView: View {
    var hasActiveLibrarySession = false
    var initialCategory: SettingsCategory?
    var initialAnchor: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    // MARK: - Navigation State

    @State private var selection: SettingsCategory
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var subpagePath: [SettingsSubpage] = []
    @State private var searchText = ""
    @State private var selectedSearchResultID: String?
    @State private var searchRequest: SettingsSearchRequest?
    /// Applied only after the sheet closes: switching the app appearance while
    /// SwiftUI is still drawing this sheet leaves it in a mixed state.
    @State private var pendingAppearanceMode: AppSettings.AppearanceMode?

    init(
        hasActiveLibrarySession: Bool = false,
        initialCategory: SettingsCategory? = nil,
        initialAnchor: String? = nil
    ) {
        self.hasActiveLibrarySession = hasActiveLibrarySession
        self.initialCategory = initialCategory
        self.initialAnchor = initialAnchor
        _selection = State(initialValue: initialCategory ?? .general)
    }

    private var currentSubpage: SettingsSubpage? { subpagePath.last }

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var navigationSpec: MotionSpec {
        motionTokens.phaseSpec(
            for: .navigation,
            duration: 0.32,
            bounce: 0,
            blendDuration: 0.1
        )
    }

    private var navigationAnimation: Animation? {
        motionPolicy.animation(for: navigationSpec)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(
                selection: $selection,
                searchText: $searchText,
                results: searchResults,
                selectedResultID: selectedSearchResultID,
                selectResult: selectSearchResult
            )
                .navigationSplitViewColumnWidth(
                    min: GlassStyleTokens.sidebarMinWidth,
                    ideal: GlassStyleTokens.sidebarWidth,
                    max: 300
                )
        } detail: {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    // Keep earlier pages alive outside the clip without fading
                    // the entire text and control hierarchy into a composited layer.
                    detailView
                        .id(selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .offset(x: currentSubpage == nil ? 0 : -proxy.size.width)
                        .allowsHitTesting(currentSubpage == nil)
                        .disabled(currentSubpage != nil)
                        .accessibilityHidden(currentSubpage != nil)

                    ForEach(subpagePath, id: \.self) { subpage in
                        subpageView(for: subpage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background {
                                ThemedBaseBackgroundColorView()
                                    .padding(.horizontal, -40)
                            }
                            .offset(x: currentSubpage == subpage ? 0 : -proxy.size.width)
                            .allowsHitTesting(currentSubpage == subpage)
                            .disabled(currentSubpage != subpage)
                            .accessibilityHidden(currentSubpage != subpage)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing),
                                removal: .move(edge: .trailing)
                            ))
                    }

                    if currentSubpage != nil {
                        settingsBackButton
                            .padding(.top, 18)
                            .padding(.leading, 24)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .leading)),
                                removal: .opacity
                            ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .motionAnimation(navigationSpec, value: subpagePath)
                .environment(\.navigateSettingsSubpage) { page in
                    navigateToSubpage(page)
                }
                .environment(\.settingsSearchRequest, searchRequest)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .appPopupAppearance()
        .presentationCornerRadius(AppPopupStyle().cornerRadius)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .overlay(alignment: .topTrailing) {
            settingsCloseButton
                .padding(.top, AppPopupStyle().closeMarginTop)
                .padding(.trailing, AppPopupStyle().closeMarginTrailing)
        }
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else if currentSubpage != nil {
                navigateToSubpage(nil)
            } else {
                dismiss()
            }
        }
        .onChange(of: selection) { _, _ in
            if currentSubpage != nil {
                subpagePath = []
            }
        }
        .onChange(of: searchText) { _, value in
            selectedSearchResultID = nil
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchRequest = nil
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        .scrollContentBackground(.hidden)
        .background(ThemedBaseBackgroundColorView())
        .background(SettingsWindowMarkerView())
        .dismissTextEditingOnOutsideClick()
        .environment(\.fullscreenSettingsPresentationStyle, .settingsWindow)
        .environment(\.settingsAppForegroundColors, appForegroundColors)
        .foregroundStyle(appForegroundColors.primary)
        .onAppear {
            settings.fullscreen.normalizeConfiguration()
            if let initialAnchor {
                // Deep link from a sidebar notice: select the requested tab
                // and reuse the search-anchor scroll path.
                subpagePath = []
                searchRequest = SettingsSearchRequest(
                    category: selection,
                    tab: nil,
                    anchor: initialAnchor
                )
            }
        }
        .onDisappear {
            guard let mode = pendingAppearanceMode else { return }
            pendingAppearanceMode = nil
            let settings = settings
            Task { @MainActor in
                guard settings.appearanceMode != mode else { return }
                settings.appearanceMode = mode
            }
        }
    }

    // MARK: - Detail View

    private var detailView: some View {
        // Phase 4.5: resolve the tinted-neutral foreground palette once at the
        // top of the detail pane. The shared SettingsHeaderLabel /
        // SettingsSwitchRow / settingsRowLabelStyle / settingsSectionTitleStyle
        // / settingsDescriptionStyle modifiers all read this environment and
        // override their built-in `.primary`/`.secondary` defaults — except
        // surfaces whose presentation style supplies its own unified foreground (fullscreen
        // overlay panel), which keep the high-contrast white hierarchy.
        let appColors = appForegroundColors
        let detailCategory = selection
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selection {
                    case .general:
                        GeneralSettingsView()
                    case .appearance:
                        AppearanceSettingsView(pendingAppearanceMode: $pendingAppearanceMode)
                    case .nowPlaying:
                        NowPlayingSettingsContainerView()
                    case .fullscreen:
                        FullscreenSettingsContainerView()
                    case .audio:
                        AudioSettingsView()
                    case .externalPlayback:
                        if hasActiveLibrarySession {
                            ExternalPlaybackSettingsView()
                        } else {
                            unavailableLibrarySettings
                        }
                    case .library:
                        if hasActiveLibrarySession {
                            LibrarySettingsView()
                        } else {
                            unavailableLibrarySettings
                        }
                    case .data:
                        if hasActiveLibrarySession {
                            DataManagementSettingsView()
                        } else {
                            unavailableLibrarySettings
                        }
                    case .automation:
                        AutomationSettingsView()
                    case .about:
                        AboutSettingsView()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsSearchAnchor("settings.top")
            }
            .onPreferenceChange(SettingsSearchAnchorPreferenceKey.self) { request in
                guard let request, request.category == detailCategory else { return }
                // The target reports itself after its tab enters the hierarchy.
                DispatchQueue.main.async {
                    guard searchRequest?.id == request.id, selection == request.category else { return }
                    proxy.scrollTo(request.anchor ?? "settings.top", anchor: .top)
                    searchRequest = nil
                }
            }
        }
        .groupBoxStyle(SettingsWindowGroupBoxStyle())
        .environment(\.settingsAppForegroundColors, appColors)
        .foregroundStyle(appColors.primary)
        .scrollContentBackground(.hidden)
        .dismissTextEditingOnOutsideClick()
    }

    private var unavailableLibrarySettings: some View {
        ContentUnavailableView(
            "找不到资料库",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("请先打开资料库。")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var searchResults: [SettingsSearchEntry] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let windowSkin = SkinRegistry.skin(for: settings.selectedNowPlayingSkinID)
        let fullscreenSkin = SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID)
        let hasFullscreenMiniPlayer = fullscreenSkin.scene == nil
            || fullscreenSkin.sceneComponents.contains("control.miniPlayer")
        let usesReferencedLibrary = hasActiveLibrarySession
            && appSession.activeLibraryBinding.context?.mode == .referenced
        let hasDuplicates = hasActiveLibrarySession
            && !(appSession.libraryVM?.diagnostics.duplicateGroups.isEmpty ?? true)

        let availableEntries = SettingsSearchIndex.entries.filter { entry in
            switch entry.anchor {
            case "skin.miniplayer" where entry.category == .fullscreen:
                return hasFullscreenMiniPlayer
            case "skin.visual":
                return FullscreenSkinTabView.supportsArtworkScaleControl(for: settings.fullscreen.skinID)
            case "library.sources", "library.deletion", "library.missing":
                return usesReferencedLibrary
            case "library.duplicates":
                return hasDuplicates
            default:
                return true
            }
        }
        var liveEntries = skinSearchEntries(for: windowSkin, surface: .window, category: .nowPlaying)
            + skinSearchEntries(for: fullscreenSkin, surface: .fullscreen, category: .fullscreen)
        if usesReferencedLibrary {
            liveEntries.append(SettingsSearchEntry(
                "来源同步", category: .data, tab: 0, tabTitle: "后台任务",
                anchor: "background.task.source-sync", keywords: "文件夹 扫描 来源"
            ))
        }
        return SettingsSearchIndex.results(for: searchText, entries: availableEntries + liveEntries)
    }

    private func skinSearchEntries(
        for skin: any NowPlayingSkin,
        surface: SkinSurface,
        category: SettingsCategory
    ) -> [SettingsSearchEntry] {
        func entry(_ title: String, anchor: String = "skin.options", keywords: String = "", identity: String? = nil) -> SettingsSearchEntry {
            SettingsSearchEntry(title, category: category, tab: 0, tabTitle: "皮肤",
                                anchor: anchor, keywords: "\(skin.name) \(keywords)", identity: identity)
        }

        var result: [SettingsSearchEntry] = []
        let hasHostBackground = surface == .window
            ? skin.scene == nil || skin.sceneComponents.contains("background.host")
            : skin.fullscreenSettingsView == nil && skin.sceneComponents.contains("background.host")
        if hasHostBackground || (surface == .fullscreen && [ClassicLEDSkin.id, RotatingCoverSkin.id, "kmgccc.cassette"].contains(skin.id)) {
            result.append(entry("启用艺术背景", keywords: "封面 背景"))
        }

        switch skin.id {
        case ClassicLEDSkin.id:
            result += [entry("风格化封面边缘"), entry("边缘模糊"), entry("皮肤音频可视化", keywords: "频谱 LED 电平")]
        case RotatingCoverSkin.id:
            result += [entry("CD 模式", keywords: "唱片"), entry("皮肤音频可视化", keywords: "频谱 LED 电平")]
        case AppleStyleSkin.skinID:
            result += [entry("动态背景"), entry("流体速度", keywords: "背景 动画"), entry("皮肤音频可视化", keywords: "频谱 LED 电平")]
        case "kmgccc.cassette":
            result += [entry("LED 电平表", keywords: "频谱"), entry(NSLocalizedString("skin.kmgccc_cassette.show_kmg", comment: ""))]
        case "fullscreen.coverGradientBlur" where surface == .fullscreen:
            result += [entry("右侧填充"), entry("背景压暗强度", keywords: "亮度")]
        default:
            break
        }

        let hasMiniPlayer = surface == .window
            ? skin.scene == nil
            : skin.scene == nil || skin.sceneComponents.contains("control.miniPlayer")
        if hasMiniPlayer {
            result.append(entry("Mini Player 音频可视化", anchor: "skin.miniplayer", keywords: "频谱 LED 电平"))
        }

        if SkinRegistry.customizationEnabled {
            let definitions = SkinParameterSettingsView.visibleDefinitions(
                skinID: skin.id, surface: surface, definitions: skin.parameterDefinitions,
                store: SkinRegistry.catalog.parameters
            )
            result += definitions.map {
                entry($0.title, anchor: "skin.parameter.\($0.id)",
                      keywords: $0.section ?? "", identity: "parameter:\($0.id)")
            }
        }
        return result
    }

    private func selectSearchResult(_ result: SettingsSearchEntry) {
        subpagePath = []
        selection = result.category
        selectedSearchResultID = result.id
        let needsLibrary = [.externalPlayback, .library, .data].contains(result.category)
        searchRequest = SettingsSearchRequest(
            category: result.category,
            tab: result.tab,
            anchor: needsLibrary && !hasActiveLibrarySession ? nil : result.anchor
        )
    }

    private var appForegroundColors: SettingsAppForegroundColors {
        let palette = themeStore.appForegroundPalette
        return SettingsAppForegroundColors(
            primary: palette.primaryColor,
            secondary: palette.secondaryColor,
            tertiary: palette.tertiaryColor,
            quaternary: palette.quaternaryColor,
            disabled: palette.disabledColor
        )
    }



    private var settingsCloseButton: some View {
        AppPopupCloseButton { dismiss() }
    }

    private var settingsBackButton: some View {
        Button {
            navigateToSubpage(nil)
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: GlassStyleTokens.headerStandardIconSize, weight: .semibold))
                .foregroundStyle(themeStore.accentColor.opacity(colorScheme == .dark ? 0.94 : 0.84))
                .frame(
                    width: GlassStyleTokens.headerControlHeight,
                    height: GlassStyleTokens.headerControlHeight
                )
                .contentShape(Circle())
                .liquidGlassCircle(
                    colorScheme: colorScheme,
                    accentColor: nil as Color?,
                    isFloating: true
                )
        }
        .buttonStyle(.plain)
        .help("返回")
        .accessibilityLabel(Text("返回"))
    }

    private func navigateToSubpage(_ subpage: SettingsSubpage?) {
        withAnimation(navigationAnimation) {
            if let subpage {
                guard !subpagePath.contains(subpage) else { return }
                subpagePath.append(subpage)
            } else if !subpagePath.isEmpty {
                subpagePath.removeLast()
            }
        }
    }

    @ViewBuilder
    private func subpageView(for subpage: SettingsSubpage) -> some View {
        switch subpage {
        case .audioDSP:
            AudioDSPSettingsView()
                .groupBoxStyle(SettingsWindowGroupBoxStyle())
        }
    }
}

/// Presents the existing About content as a standalone app window.
@MainActor
struct AboutWindowRoot: View {
    @EnvironmentObject private var themeStore: ThemeStore

    private var appColors: SettingsAppForegroundColors {
        let palette = themeStore.appForegroundPalette
        return SettingsAppForegroundColors(
            primary: palette.primaryColor,
            secondary: palette.secondaryColor,
            tertiary: palette.tertiaryColor,
            quaternary: palette.quaternaryColor,
            disabled: palette.disabledColor
        )
    }

    var body: some View {
        ScrollView {
            AboutSettingsView()
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(SettingsWindowGroupBoxStyle())
        .scrollContentBackground(.hidden)
        .background(ThemedBaseBackgroundColorView())
        .environment(\.fullscreenSettingsPresentationStyle, .settingsWindow)
        .environment(\.settingsAppForegroundColors, appColors)
        .foregroundStyle(appColors.primary)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .preferredColorScheme(AppSettings.shared.colorScheme)
        .motionEnvironment()
    }
}

// MARK: - Settings Subpage Navigation

enum SettingsSubpage: Hashable, Sendable {
    case audioDSP
}

private struct SettingsSubpageActionKey: EnvironmentKey {
    static let defaultValue: (SettingsSubpage?) -> Void = { _ in }
}

extension EnvironmentValues {
    var navigateSettingsSubpage: (SettingsSubpage?) -> Void {
        get { self[SettingsSubpageActionKey.self] }
        set { self[SettingsSubpageActionKey.self] = newValue }
    }
}

// MARK: - Settings Window GroupBox Style

/// Ensures every GroupBox in the settings detail pane fills the available column width.
/// Fullscreen/NowPlaying containers override this with their own glass or material style.
/// Popups that edit settings-like forms (track info editor) reuse it for their section cards.
struct SettingsWindowGroupBoxStyle: GroupBoxStyle {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionLabelSpacing) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)

            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(
                        cornerRadius: presentationStyle.sectionCornerRadius,
                        style: .continuous
                    )
                    .fill(settingsCardBackground)
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: presentationStyle.sectionCornerRadius,
                        style: .continuous
                    )
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsCardBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.045)
            : Color.black.opacity(0.035)
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

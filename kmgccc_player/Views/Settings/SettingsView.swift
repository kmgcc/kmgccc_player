//
//  SettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Settings View (Refactored)
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import AppKit
import MotionKit
import SwiftUI

/// Settings view with sidebar categories.
@MainActor
struct SettingsView: View {
    var hasActiveLibrarySession = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    // MARK: - Navigation State

    @State private var selection: SettingsCategory = .appearance
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var currentSubpage: SettingsSubpage? = nil

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
            SettingsSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: GlassStyleTokens.sidebarMinWidth,
                    ideal: GlassStyleTokens.sidebarWidth,
                    max: 300
                )
        } detail: {
            ZStack(alignment: .topLeading) {
                detailView
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: currentSubpage == nil ? 0 : -60)
                    .opacity(currentSubpage == nil ? 1 : 0)
                    .allowsHitTesting(currentSubpage == nil)

                if let subpage = currentSubpage {
                    subpageView(for: subpage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background {
                            ThemedBaseBackgroundColorView()
                                .padding(.horizontal, -40)
                        }
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
            .motionAnimation(navigationSpec, value: currentSubpage)
            .environment(\.navigateSettingsSubpage) { page in
                navigateToSubpage(page)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .overlay(alignment: .topTrailing) {
            settingsCloseButton
                .padding(.top, 18)
                .padding(.trailing, 20)
        }
        .onExitCommand {
            if currentSubpage != nil {
                navigateToSubpage(nil)
            } else {
                dismiss()
            }
        }
        .onChange(of: selection) { _, _ in
            if currentSubpage != nil {
                currentSubpage = nil
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        .scrollContentBackground(.hidden)
        .background(ThemedBaseBackgroundColorView())
        .environment(\.settingsAppForegroundColors, appForegroundColors)
        .foregroundStyle(appForegroundColors.primary)
        .onAppear {
            settings.fullscreen.normalizeConfiguration()
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
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selection {
                case .appearance:
                    AppearanceSettingsView()
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
        }
        .groupBoxStyle(SettingsWindowGroupBoxStyle())
        .environment(\.settingsAppForegroundColors, appColors)
        .foregroundStyle(appColors.primary)
        .scrollContentBackground(.hidden)
    }

    private var unavailableLibrarySettings: some View {
        ContentUnavailableView(
            "找不到资料库",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("请先打开资料库。")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
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
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
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
        .help("关闭")
        .accessibilityLabel(Text("关闭"))
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
            currentSubpage = subpage
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
private struct SettingsWindowGroupBoxStyle: GroupBoxStyle {
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

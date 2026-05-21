//
//  SettingsView.swift
//  myPlayer2
//
//  kmgccc_player - Settings View (Refactored)
//  Provides user-configurable settings including LED meter, Appearance, and AMLL.
//

import AppKit
import SwiftUI

/// Settings view with sidebar categories.
@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    // MARK: - Navigation State

    @State private var selection: SettingsCategory = .appearance
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // MARK: - Feature Tip State

    @State private var showV2FeatureTip = false

    private enum FeatureTips {
        static let v2FeatureKey = "settings.v2DataManagement"
        static let v2FeatureIntroducedVersion = AppVersion(major: 2, minor: 0, patch: 0)
        static let v2FeatureMaxDisplayCount = 2
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: GlassStyleTokens.sidebarMinWidth,
                    ideal: GlassStyleTokens.sidebarWidth,
                    max: 300
                )
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .overlay(alignment: .topTrailing) {
            settingsCloseButton
                .padding(.top, 18)
                .padding(.trailing, 20)
        }
        .overlay(alignment: .leading) {
            if showV2FeatureTip {
                V2FeatureTipView(onClose: dismissV2FeatureTip)
                    .padding(.leading, 20)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        .onAppear {
            settings.fullscreen.normalizeConfiguration()
            showV2FeatureTipIfNeeded()
        }
    }

    // MARK: - Detail View

    private var detailView: some View {
        // Phase 4.5: resolve the tinted-neutral foreground palette once at the
        // top of the detail pane. The shared SettingsHeaderLabel /
        // SettingsSwitchRow / settingsRowLabelStyle / settingsSectionTitleStyle
        // / settingsDescriptionStyle modifiers all read this environment and
        // override their built-in `.primary`/`.secondary` defaults — except
        // surfaces whose presentation style sets `forcesWhiteText` (fullscreen
        // overlay panel), which keep the high-contrast white hierarchy.
        let palette = themeStore.appForegroundPalette
        let appColors = SettingsAppForegroundColors(
            primary: Color(nsColor: palette.primary),
            secondary: Color(nsColor: palette.secondary),
            tertiary: Color(nsColor: palette.tertiary)
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selection {
                case .appearance:
                    AppearanceSettingsView()
                case .nowPlaying:
                    NowPlayingSettingsContainerView()
                case .fullscreen:
                    FullscreenSettingsContainerView()
                case .externalPlayback:
                    ExternalPlaybackSettingsView()
                case .data:
                    DataManagementSettingsView()
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
    }

    // MARK: - Feature Tip

    private func showV2FeatureTipIfNeeded() {
        guard !showV2FeatureTip else { return }
        guard AppVersionGate.shared.shouldShowFeatureTip(
            featureKey: FeatureTips.v2FeatureKey,
            introducedVersion: FeatureTips.v2FeatureIntroducedVersion,
            maxDisplayCount: FeatureTips.v2FeatureMaxDisplayCount
        ) else { return }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showV2FeatureTip = true
        }
        AppVersionGate.shared.recordFeatureTipDisplayed(
            featureKey: FeatureTips.v2FeatureKey
        )
    }

    private func dismissV2FeatureTip() {
        withAnimation(.easeOut(duration: 0.2)) {
            showV2FeatureTip = false
        }
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

// MARK: - V2 Feature Tip View

private struct V2FeatureTipView: View {
    let onClose: () -> Void
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("资料库管理升级")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                    Text("支持自定义音乐资料库储存位置")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                    Text("可为所有歌曲主动补全信息与封面")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: themeStore.appForegroundPalette.secondary))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 298, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
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

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
        .frame(minWidth: 760, minHeight: 680)
        .onAppear {
            settings.fullscreen.normalizeConfiguration()
        }
    }

    // MARK: - Detail View

    private var detailView: some View {
        ScrollView {
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
                    .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: presentationStyle.sectionCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    .allowsHitTesting(false)
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

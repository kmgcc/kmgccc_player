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
            closeButton
        }
        .frame(minWidth: 760, minHeight: 680)
        .onAppear {
            settings.fullscreen.normalizeConfiguration()
        }
        .background(
            WindowToolbarAccessor { window in
                window.titlebarAppearsTransparent = true
            }
        )
    }

    // MARK: - Close Button

    private var closeButton: some View {
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
                case .led:
                    LEDMeterSettingsView()
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
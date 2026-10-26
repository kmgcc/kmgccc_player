//
//  NowPlayingGeneralTabView.swift
//  myPlayer2
//
//  kmgccc_player - Window Playback General Settings Tab
//

import SwiftUI

/// General settings tab for window playback: art background and skin selection.
struct NowPlayingGeneralTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerViewModel.self) private var playerVM
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @State private var nowPlayingSkin: String = AppSettings.shared.selectedNowPlayingSkinID
    @State private var nowPlayingArtBackgroundEnabled: Bool = AppSettings.shared.nowPlayingArtBackgroundEnabled
    @State private var visualizationPreferences = AudioVisualizationPreferences.shared

    @AppStorage("skin.classicLED.visualizerMode") private var classicVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.visualizerMode") private var cassetteVisualizerMode: String = "off"
    @AppStorage("skin.kmgcccCassette.showKmgLook") private var cassetteShowKmgLook: Bool = false

    var body: some View {
        let selectedSkin = SkinRegistry.skin(for: nowPlayingSkin)
        let hasSkinOptions = selectedSkin.settingsView != nil
            || (SkinRegistry.customizationEnabled && selectedSkin.parameterDefinitions.contains(where: { $0.isUserVisible && $0.surfaces.contains(.window) }))
        let showsArtBackgroundOption = selectedSkin.scene == nil || selectedSkin.sceneComponents.contains("background.host")
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
            SettingsSection("settings.now_playing.select_skin") {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    if SkinRegistry.customizationEnabled {
                        SkinPackageSettingsActions(skin: SkinRegistry.skin(for: nowPlayingSkin))
                    }
                    SkinSelectorRow(
                        skins: SkinRegistry.nowPlayingOptions,
                        selectedSkinID: $nowPlayingSkin,
                        showsScrollButtons: true
                    )
                }
            }

            if showsArtBackgroundOption || hasSkinOptions {
                SettingsSection(String(format: NSLocalizedString("settings.now_playing.skin_options", comment: ""), selectedSkin.name)) {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        if showsArtBackgroundOption {
                            SettingsSwitchRow(
                                title: "启用艺术背景",
                                isOn: $nowPlayingArtBackgroundEnabled
                            )
                        }
                        if let optionsView = selectedSkin.settingsView { optionsView }
                        if SkinRegistry.customizationEnabled {
                            SkinParameterSettingsView(skinID: selectedSkin.id, surface: .window,
                                                      definitions: selectedSkin.parameterDefinitions, store: SkinRegistry.catalog.parameters)
                        }
                    }
                }
            }

            if selectedSkin.scene == nil {
                SettingsSection("Mini Player") {
                    AudioVisualizationSelectorRow(
                        title: "音频可视化",
                        selection: Binding(
                            get: {
                                visualizationPreferences.selection(
                                    for: nowPlayingSkin,
                                    scope: .window
                                ).miniPlayerKind
                            },
                            set: { kind in
                                visualizationPreferences.setMiniPlayerKind(
                                    kind,
                                    for: nowPlayingSkin,
                                    scope: .window
                                )
                                playerVM.refreshLedMeterStateFromSettings()
                            }
                        )
                    )
                }
            }
        }
        .onAppear {
            nowPlayingSkin = settings.selectedNowPlayingSkinID
            nowPlayingArtBackgroundEnabled = settings.nowPlayingArtBackgroundEnabled
            visualizationPreferences.synchronizeLegacyState(for: nowPlayingSkin, scope: .window)
        }
        .onChange(of: nowPlayingSkin) { _, newValue in
            settings.selectedNowPlayingSkinID = newValue
            visualizationPreferences.synchronizeLegacyState(for: newValue, scope: .window)
            playerVM.refreshLedMeterStateFromSettings()
        }
        .onChange(of: settings.selectedNowPlayingSkinID) { _, value in
            nowPlayingSkin = value
        }
        .onChange(of: nowPlayingArtBackgroundEnabled) { _, newValue in
            settings.nowPlayingArtBackgroundEnabled = newValue
        }
    }
}

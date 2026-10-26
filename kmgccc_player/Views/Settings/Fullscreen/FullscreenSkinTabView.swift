//
//  FullscreenSkinTabView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Skin Settings Tab
//

import SwiftUI

/// Skin settings tab for fullscreen playback: skin selection, MiniPlayer, and visual settings.
struct FullscreenSkinTabView: View {
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    @AppStorage("fullscreenArtBackgroundEnabled") private var fullscreenArtBackgroundEnabled: Bool = true
    @State private var fullscreenArtworkScale: Double = AppSettings.shared.fullscreenArtworkScale
    @State private var fullscreenMiniPlayerAutoHideSeconds: Double = AppSettings.shared.fullscreenMiniPlayerAutoHideSeconds
    @State private var fullscreenMiniPlayerGlassMaterial: AppSettings.FullscreenMiniPlayerGlassMaterial = AppSettings.shared.fullscreenMiniPlayerGlassMaterial

    private var slidingKnobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return presentationStyle.settingsPrimaryTextColor(appColors: appColors)
        }
        return themeStore.accentColor
    }

    private let fullscreenMiniPlayerAutoHideOptions: [(title: String, seconds: Double)] = [
        ("关闭自动隐藏", 0),
        ("2 秒", 2),
        ("4 秒", 4),
        ("6 秒", 6),
    ]

    private let fullscreenMiniPlayerGlassMaterialOptions:
        [(title: String, material: AppSettings.FullscreenMiniPlayerGlassMaterial)] = [
            ("透明", .clear),
            ("常规", .normal),
        ] 

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
            SettingsSection("选择外观") {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    if SkinRegistry.customizationEnabled {
                        SkinPackageSettingsActions(skin: SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID))
                    }
                    SkinSelectorRow(
                        skins: SkinRegistry.fullscreenOptions,
                        selectedSkinID: Binding(
                            get: { settings.fullscreen.skinID },
                            set: { settings.fullscreen.setSkinID($0) }
                        ),
                        cardSize: presentationStyle.skinCardSize,
                        previewSize: presentationStyle.skinPreviewSize,
                        cornerRadius: presentationStyle.skinCornerRadius,
                        titleFontSize: presentationStyle.skinTitleFontSize,
                        itemSpacing: presentationStyle.skinItemSpacing,
                        edgePadding: presentationStyle.skinEdgePadding,
                        verticalPadding: presentationStyle.skinVerticalPadding,
                        showsScrollButtons: true
                    )
                }
            }

            let selectedSkin = SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID)
            // A package scene that draws the host backdrop gets the toggle built-in skins carry in their own options.
            let showsArtBackgroundOption = selectedSkin.fullscreenSettingsView == nil
                && selectedSkin.sceneComponents.contains("background.host")
            if showsArtBackgroundOption || selectedSkin.fullscreenSettingsView != nil || (SkinRegistry.customizationEnabled && selectedSkin.parameterDefinitions.contains(where: { $0.isUserVisible && $0.surfaces.contains(.fullscreen) })) {
                SettingsSection("\(selectedSkin.name) 选项") {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        if showsArtBackgroundOption {
                            SettingsSwitchRow(
                                title: "启用艺术背景",
                                isOn: $fullscreenArtBackgroundEnabled,
                                titleFont: presentationStyle.rowLabelFont,
                                titleColor: presentationStyle.settingsPrimaryTextColor(appColors: appColors)
                            )
                        }
                        if let optionsView = selectedSkin.fullscreenSettingsView { optionsView }
                        if SkinRegistry.customizationEnabled {
                            SkinParameterSettingsView(skinID: selectedSkin.id, surface: .fullscreen,
                                                      definitions: selectedSkin.parameterDefinitions, store: SkinRegistry.catalog.parameters)
                        }
                    }
                }
            }

            if selectedSkin.scene == nil || selectedSkin.sceneComponents.contains("control.miniPlayer") {
                SettingsSection("Mini Player") {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        AudioVisualizationSelectorRow(
                            title: "音频可视化",
                            selection: Binding(
                                get: { settings.fullscreen.miniPlayerVisualization },
                                set: { settings.fullscreen.setMiniPlayerVisualization($0) }
                            )
                        )

                        miniPlayerAutoHidePicker

                        miniPlayerMaterialPicker
                    }
                }
            }

            if supportsArtworkScaleControl(for: settings.fullscreen.skinID) {
                SettingsSection("视觉效果") {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        artworkScaleSection
                    }
                }
            }
        }
        .onAppear {
            let skinID = settings.fullscreen.skinID
            let scale = settings.fullscreenArtworkScale
            let range = artworkScaleRange(for: skinID)
            fullscreenArtworkScale = min(max(scale, range.lowerBound), range.upperBound)

            fullscreenMiniPlayerAutoHideSeconds = settings.fullscreenMiniPlayerAutoHideSeconds
            fullscreenMiniPlayerGlassMaterial = settings.fullscreenMiniPlayerGlassMaterial
        }
        .onChange(of: settings.fullscreen.skinID) { _, newSkinID in
            let scale = settings.artworkScale(for: newSkinID)
            let range = artworkScaleRange(for: newSkinID)
            fullscreenArtworkScale = min(max(scale, range.lowerBound), range.upperBound)
        }
        .onChange(of: fullscreenArtworkScale) { _, newValue in
            settings.fullscreenArtworkScale = newValue
        }
        .onChange(of: fullscreenMiniPlayerAutoHideSeconds) { _, newValue in
            settings.fullscreenMiniPlayerAutoHideSeconds = newValue
        }
        .onChange(of: fullscreenMiniPlayerGlassMaterial) { _, newValue in
            settings.fullscreenMiniPlayerGlassMaterial = newValue
        }
    }

    private var miniPlayerAutoHidePicker: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text("自动隐藏")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
            Spacer()
            SlidingSelector(
                segments: fullscreenMiniPlayerAutoHideOptions.map(\.seconds),
                selection: $fullscreenMiniPlayerAutoHideSeconds,
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(slidingKnobColor.opacity(0.18))
                },
                content: { seconds, isSelected in
                    let title = fullscreenMiniPlayerAutoHideOptions.first(where: { $0.seconds == seconds })?.title ?? ""
                    Text(title)
                        .font(.system(size: presentationStyle.segmentedFontSize, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, presentationStyle.segmentedHorizontalPadding)
                        .padding(.vertical, presentationStyle.segmentedVerticalPadding)
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.settingsSelectedTextColor(
                                    accentColor: themeStore.accentColor,
                                    appColors: appColors
                                )
                                : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        )
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(segmentedTrackBackground)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var miniPlayerMaterialPicker: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text("材质")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
            Spacer()
            SlidingSelector(
                segments: fullscreenMiniPlayerGlassMaterialOptions.map(\.material),
                selection: $fullscreenMiniPlayerGlassMaterial,
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(slidingKnobColor.opacity(0.18))
                },
                content: { material, isSelected in
                    let title = fullscreenMiniPlayerGlassMaterialOptions.first(where: { $0.material == material })?.title ?? ""
                    Text(title)
                        .font(.system(size: presentationStyle.segmentedFontSize, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, presentationStyle.segmentedHorizontalPadding)
                        .padding(.vertical, presentationStyle.segmentedVerticalPadding)
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.settingsSelectedTextColor(
                                    accentColor: themeStore.accentColor,
                                    appColors: appColors
                                )
                                : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        )
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(segmentedTrackBackground)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func artworkScaleRange(for skinID: String) -> ClosedRange<Double> {
        let maxVal = AppSettings.maxArtworkScale(for: skinID)
        return 0.9...maxVal
    }

    private func supportsArtworkScaleControl(for skinID: String) -> Bool {
        let skin = SkinRegistry.fullscreenSkin(for: skinID)
        // Preset artwork in host layout follows the same scale setting.
        let usesPresetArtwork = skin.sceneComponents.contains { $0.hasPrefix("builtin.") && $0.hasSuffix(".artwork") }
        return (skin.scene == nil || usesPresetArtwork) && skin.descriptor.presentation.artworkLayout == .foreground
    }

    private var currentArtworkScaleRange: ClosedRange<Double> {
        artworkScaleRange(for: settings.fullscreen.skinID)
    }

    private var artworkScaleSection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text("封面缩放")
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                Spacer()
                Text(String(format: "%.2f", fullscreenArtworkScale))
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(presentationStyle.rowValueFont)
            }
            Slider(
                value: $fullscreenArtworkScale,
                in: currentArtworkScaleRange,
                step: 0.05
            )
            .frame(height: presentationStyle.tabHeight)
        }
    }



    @ViewBuilder
    private var segmentedTrackBackground: some View {
        if presentationStyle.usesGlassSectionCards {
            Capsule()
                .fill(Color.clear)
                .liquidGlassPill(
                    colorScheme: .dark,
                    accentColor: nil,
                    prominence: .standard,
                    materialStyle: presentationStyle.glassMaterialStyle,
                    isFloating: false
                )
                .overlay(
                    Capsule()
                        .fill(Color.white.opacity(0.018))
                )
        } else {
            Capsule()
                .fill(presentationStyle.settingsSegmentedTrackColor(appColors: appColors))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            presentationStyle.segmentedTrackStrokeColor,
                            lineWidth: presentationStyle.segmentedTrackStrokeColor == .clear
                                ? 0
                                : presentationStyle.scaledHairlineWidth
                        )
                        .allowsHitTesting(false)
                )
        }
    }
}

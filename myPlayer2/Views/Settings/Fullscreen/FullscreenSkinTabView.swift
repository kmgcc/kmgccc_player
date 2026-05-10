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

    @State private var fullscreenArtworkScale: Double = AppSettings.shared.fullscreenArtworkScale
    @State private var fullscreenDimmingIntensity: Double = AppSettings.shared.fullscreenDimmingIntensity
    @State private var fullscreenArtBackgroundEnabled: Bool = AppSettings.shared.fullscreenArtBackgroundEnabled
    @State private var fullscreenMiniPlayerAutoHideSeconds: Double = AppSettings.shared.fullscreenMiniPlayerAutoHideSeconds
    @State private var fullscreenMiniPlayerGlassMaterial: AppSettings.FullscreenMiniPlayerGlassMaterial = AppSettings.shared.fullscreenMiniPlayerGlassMaterial

    private var slidingKnobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return FullscreenSelectionAccentStyle.dimmedAccentColor(
                from: themeStore.accentNSColor,
                lightnessDelta: 0.30
            )
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
            ("clear", .clear),
            ("dark glass", .darkGlass),
        ]

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sectionSpacing) {
            SettingsSection("选择外观") {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
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

            if let selected = SkinRegistry.fullscreenOptions.first(where: { $0.id == settings.fullscreen.skinID }),
               let optionsView = SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID).fullscreenSettingsView {
                SettingsSection("\(selected.name) 选项") {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        optionsView
                    }
                }
            }

            SettingsSection("Mini Player") {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    SettingsSwitchRow(
                        title: "频谱动画",
                        isOn: Binding(
                            get: { settings.fullscreen.isMiniPlayerSpectrumEnabled },
                            set: { _ in settings.fullscreen.toggleMiniPlayerSpectrum() }
                        ),
                        titleFont: presentationStyle.rowLabelFont,
                        titleColor: presentationStyle.primaryTextColor
                    )

                    miniPlayerAutoHidePicker

                    miniPlayerMaterialPicker
                }
            }

            SettingsSection("视觉效果") {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    SettingsSwitchRow(
                        title: "启用艺术背景",
                        isOn: $fullscreenArtBackgroundEnabled,
                        detail: "遇到性能问题时，可以关闭此选项",
                        titleFont: presentationStyle.rowLabelFont,
                        detailFont: presentationStyle.captionFont,
                        titleColor: presentationStyle.primaryTextColor,
                        detailColor: presentationStyle.secondaryTextColor
                    )

                    artworkScaleSection

                    dimmingIntensitySection
                }
            }
        }
        .onAppear {
            fullscreenArtworkScale = settings.fullscreenArtworkScale
            fullscreenDimmingIntensity = settings.fullscreenDimmingIntensity
            fullscreenArtBackgroundEnabled = settings.fullscreenArtBackgroundEnabled
            fullscreenMiniPlayerAutoHideSeconds = settings.fullscreenMiniPlayerAutoHideSeconds
            fullscreenMiniPlayerGlassMaterial = settings.fullscreenMiniPlayerGlassMaterial
        }
        .onChange(of: fullscreenArtworkScale) { _, newValue in
            settings.fullscreenArtworkScale = newValue
        }
        .onChange(of: fullscreenDimmingIntensity) { _, newValue in
            settings.fullscreenDimmingIntensity = newValue
        }
        .onChange(of: fullscreenArtBackgroundEnabled) { _, newValue in
            settings.fullscreenArtBackgroundEnabled = newValue
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
                .foregroundStyle(presentationStyle.primaryTextColor)
            Spacer()
            SlidingSelector(
                segments: fullscreenMiniPlayerAutoHideOptions.map(\.seconds),
                selection: $fullscreenMiniPlayerAutoHideSeconds,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
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
                                ? presentationStyle.selectedTextColor(accentColor: themeStore.accentColor)
                                : presentationStyle.secondaryTextColor
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
                .foregroundStyle(presentationStyle.primaryTextColor)
            Spacer()
            SlidingSelector(
                segments: fullscreenMiniPlayerGlassMaterialOptions.map(\.material),
                selection: $fullscreenMiniPlayerGlassMaterial,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
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
                                ? presentationStyle.selectedTextColor(accentColor: themeStore.accentColor)
                                : presentationStyle.secondaryTextColor
                        )
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(segmentedTrackBackground)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var artworkScaleSection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text("封面缩放")
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.primaryTextColor)
                Spacer()
                let displayValue = fullscreenArtworkScale - 0.1
                Text(String(format: "%.2f", displayValue))
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(presentationStyle.rowValueFont)
            }
            Slider(
                value: $fullscreenArtworkScale,
                in: 0.9...1.6,
                step: 0.05
            )
            .frame(height: presentationStyle.tabHeight)
            Text("调整全屏模式下歌曲封面的显示大小")
                .settingsDescriptionStyle()
        }
    }

    private var dimmingIntensitySection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text("背景压暗强度")
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.primaryTextColor)
                Spacer()
                Text(String(format: "%.0f%%", fullscreenDimmingIntensity * 100))
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(presentationStyle.rowValueFont)
            }
            Slider(
                value: $fullscreenDimmingIntensity,
                in: 0.0...0.5,
                step: 0.05
            )
            .frame(height: presentationStyle.tabHeight)
            Text("调整全屏模式下背景压暗程度，提高可读性")
                .settingsDescriptionStyle()
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
                .fill(presentationStyle.segmentedTrackColor)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            presentationStyle.segmentedTrackStrokeColor,
                            lineWidth: presentationStyle.segmentedTrackStrokeColor == .clear ? 0 : 0.5
                        )
                        .allowsHitTesting(false)
                )
        }
    }
}

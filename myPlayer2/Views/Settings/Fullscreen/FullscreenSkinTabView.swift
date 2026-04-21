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
    @State private var fullscreenMiniPlayerAutoHideSeconds: Double = AppSettings.shared.fullscreenMiniPlayerAutoHideSeconds
    @State private var fullscreenMiniPlayerGlassMaterial: AppSettings.FullscreenMiniPlayerGlassMaterial = AppSettings.shared.fullscreenMiniPlayerGlassMaterial

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
            GroupBox {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    Text("全屏皮肤")
                        .font(.system(size: presentationStyle.sectionTitleFontSize, weight: .semibold))
                        .foregroundStyle(presentationStyle.secondaryTextColor)

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
                        verticalPadding: presentationStyle.skinVerticalPadding
                    )
                }
                .padding(presentationStyle.groupPadding)
            }

            if let selected = SkinRegistry.fullscreenOptions.first(where: { $0.id == settings.fullscreen.skinID }),
               let optionsView = SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID).fullscreenSettingsView {
                GroupBox {
                    VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                        Text("\(selected.name) 选项")
                            .font(.system(size: presentationStyle.sectionTitleFontSize, weight: .semibold))
                            .foregroundStyle(presentationStyle.secondaryTextColor)

                        optionsView
                    }
                    .padding(presentationStyle.groupPadding)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    Text("Mini Player")
                        .font(.system(size: presentationStyle.sectionTitleFontSize, weight: .semibold))
                        .foregroundStyle(presentationStyle.secondaryTextColor)

                    HStack(spacing: presentationStyle.compactInlineSpacing) {
                        Text("频谱动画")
                            .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                            .foregroundStyle(presentationStyle.primaryTextColor)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.fullscreen.isMiniPlayerSpectrumEnabled },
                            set: { _ in settings.fullscreen.toggleMiniPlayerSpectrum() }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    miniPlayerAutoHidePicker

                    miniPlayerMaterialPicker
                }
                .padding(presentationStyle.groupPadding)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    Text("视觉效果")
                        .font(.system(size: presentationStyle.sectionTitleFontSize, weight: .semibold))
                        .foregroundStyle(presentationStyle.secondaryTextColor)

                    artworkScaleSection

                    dimmingIntensitySection
                }
                .padding(presentationStyle.groupPadding)
            }
        }
        .onAppear {
            fullscreenArtworkScale = settings.fullscreenArtworkScale
            fullscreenDimmingIntensity = settings.fullscreenDimmingIntensity
            fullscreenMiniPlayerAutoHideSeconds = settings.fullscreenMiniPlayerAutoHideSeconds
            fullscreenMiniPlayerGlassMaterial = settings.fullscreenMiniPlayerGlassMaterial
        }
        .onChange(of: fullscreenArtworkScale) { _, newValue in
            settings.fullscreenArtworkScale = newValue
        }
        .onChange(of: fullscreenDimmingIntensity) { _, newValue in
            settings.fullscreenDimmingIntensity = newValue
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
                .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
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
                        .fill(themeStore.accentColor.opacity(0.18))
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
                .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
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
                        .fill(themeStore.accentColor.opacity(0.18))
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
                    .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                    .foregroundStyle(presentationStyle.primaryTextColor)
                Spacer()
                let displayValue = fullscreenArtworkScale - 0.1
                Text(String(format: "%.2f", displayValue))
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(
                value: $fullscreenArtworkScale,
                in: 0.9...1.6,
                step: 0.05
            )
            .frame(height: presentationStyle.tabHeight)
            Text("调整全屏模式下歌曲封面的显示大小")
                .font(.system(size: presentationStyle.captionFontSize))
                .foregroundStyle(presentationStyle.secondaryTextColor)
        }
    }

    private var dimmingIntensitySection: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text("背景压暗强度")
                    .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
                    .foregroundStyle(presentationStyle.primaryTextColor)
                Spacer()
                Text(String(format: "%.0f%%", fullscreenDimmingIntensity * 100))
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(.system(size: presentationStyle.rowValueFontSize, weight: .medium, design: .monospaced))
            }
            Slider(
                value: $fullscreenDimmingIntensity,
                in: 0.0...0.5,
                step: 0.05
            )
            .frame(height: presentationStyle.tabHeight)
            Text("调整全屏模式下背景压暗程度，提高可读性")
                .font(.system(size: presentationStyle.captionFontSize))
                .foregroundStyle(presentationStyle.secondaryTextColor)
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
        }
    }
}

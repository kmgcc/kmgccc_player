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
        VStack(alignment: .leading, spacing: 20) {
            // Skin selection
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
                }
                .padding(12)
            }

            // Skin-specific options
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

            // MiniPlayer settings
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Mini Player")
                        .font(.headline)

                    Toggle("底栏频谱动画", isOn: Binding(
                        get: { settings.fullscreen.isMiniPlayerSpectrumEnabled },
                        set: { _ in settings.fullscreen.toggleMiniPlayerSpectrum() }
                    ))
                    .toggleStyle(.switch)

                    Divider()

                    miniPlayerAutoHidePicker

                    Divider()

                    miniPlayerMaterialPicker
                }
                .padding(12)
            }

            // Visual settings
            GroupBox {
                VStack(alignment: .leading, spacing: 20) {
                    artworkScaleSection

                    Divider()

                    dimmingIntensitySection
                }
                .padding(12)
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
        HStack(spacing: 8) {
            Text("Mini Player 自动隐藏")
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
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var miniPlayerMaterialPicker: some View {
        HStack(spacing: 8) {
            Text("Mini Player 材质")
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
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                }
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.08))
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var artworkScaleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("封面缩放")
                Spacer()
                let displayValue = fullscreenArtworkScale - 0.1
                Text(String(format: "%.2f", displayValue))
                    .foregroundStyle(themeStore.accentColor)
                    .font(.system(.subheadline, design: .monospaced))
            }
            Slider(
                value: $fullscreenArtworkScale,
                in: 0.9...1.6,
                step: 0.05
            )
            Text("调整全屏模式下歌曲封面的显示大小")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dimmingIntensitySection: some View {
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
            )
            Text("调整全屏模式下背景压暗程度，提高可读性")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

//
//  AppleStyleSkin.swift
//  myPlayer2
//
//  Apple Music-style AMLL mesh background with classic foreground content.
//

import SwiftUI

struct AppleStyleSkin: NowPlayingSkin {
    static let skinID = "appleStyle"

    let id = AppleStyleSkin.skinID
    let name = NSLocalizedString("skin.apple_style.name", comment: "")
    let detail = NSLocalizedString("skin.apple_style.detail", comment: "")
    let systemImage = "sparkles"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { true }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(AppleMeshBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(AppleStyleArtwork(context: context))
    }

    var settingsView: AnyView? {
        AnyView(AppleStyleSettingsView(mode: .nowPlaying))
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(AppleStyleSettingsView(mode: .fullscreen))
    }
}

private struct AppleMeshBackground: View {
    let context: SkinContext

    @AppStorage("skin.appleStyle.dynamicBackgroundEnabled") private var dynamicBackgroundEnabled: Bool = true
    @AppStorage("skin.appleStyle.flowSpeed") private var flowSpeed: String = AppleMeshBackgroundSpeed.standard.rawValue

    var body: some View {
        ZStack {
            AppleMeshFallbackBackground(context: context)
            AMLLMeshGradientBackgroundView(configuration: .init(
                artworkData: context.track?.artworkData,
                artworkChecksum: context.track?.artworkChecksum ?? 0,
                isPlaying: context.playback.isPlaying,
                dynamicBackgroundEnabled: dynamicBackgroundEnabled && !context.theme.reduceMotion,
                speed: AppleMeshBackgroundSpeed(rawValue: flowSpeed) ?? .standard
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AppleMeshFallbackBackground: View {
    let context: SkinContext

    var body: some View {
        let base = context.theme.colorScheme == .dark
            ? Color(red: 0.06, green: 0.065, blue: 0.08)
            : Color(red: 0.86, green: 0.88, blue: 0.92)
        let primary = context.theme.artworkAccentColor ?? context.theme.accentColor
        let secondary = context.theme.accentColor

        ZStack {
            base
            RadialGradient(
                colors: [primary.opacity(0.24), .clear],
                center: .topLeading,
                startRadius: 18,
                endRadius: 420
            )
            RadialGradient(
                colors: [secondary.opacity(0.18), .clear],
                center: .bottomTrailing,
                startRadius: 12,
                endRadius: 460
            )
        }
    }
}

private struct AppleStyleArtwork: View {
    let context: SkinContext

    @AppStorage("skin.appleStyle.visualizerMode") private var normalVisualizerMode: String = "led"
    @AppStorage("skin.appleStyle.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    var body: some View {
        let visualizerMode = context.usesFullscreenPlayerLayout
            ? fullscreenVisualizerMode
            : normalVisualizerMode
        ClassicCoverArtworkView(context: context, visualizerMode: visualizerMode)
    }
}

private struct AppleStyleSettingsView: View {
    enum Mode {
        case nowPlaying
        case fullscreen
    }

    let mode: Mode

    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @AppStorage("skin.appleStyle.dynamicBackgroundEnabled") private var dynamicBackgroundEnabled: Bool = true
    @AppStorage("skin.appleStyle.flowSpeed") private var flowSpeed: String = AppleMeshBackgroundSpeed.standard.rawValue
    @AppStorage("skin.appleStyle.visualizerMode") private var normalVisualizerMode: String = "led"
    @AppStorage("skin.appleStyle.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    private var speedSelection: Binding<AppleMeshBackgroundSpeed> {
        Binding(
            get: { AppleMeshBackgroundSpeed(rawValue: flowSpeed) ?? .standard },
            set: { flowSpeed = $0.rawValue }
        )
    }

    private var slidingKnobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return FullscreenSelectionAccentStyle.dimmedAccentColor(
                from: themeStore.accentNSColor,
                lightnessDelta: 0.30
            )
        }
        return themeStore.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "动态背景",
                isOn: $dynamicBackgroundEnabled,
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.primaryTextColor
            )

            speedPicker

            SettingsSwitchRow(
                title: "LED 电平表",
                isOn: Binding(
                    get: { visualizerMode == "led" },
                    set: { isOn in
                        if isOn {
                            visualizerMode = "led"
                            if mode == .fullscreen {
                                FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                            } else {
                                ledMeterProvider.getOrCreate().start()
                            }
                        } else if visualizerMode == "led" {
                            visualizerMode = "off"
                            if mode == .fullscreen {
                                FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                            } else {
                                ledMeterProvider.releaseNowPlayingResources()
                            }
                        }
                    }
                ),
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.primaryTextColor
            )

            SettingsSwitchRow(
                title: "频谱动画",
                isOn: Binding(
                    get: { visualizerMode == "spectrum" },
                    set: { isOn in
                        if isOn {
                            visualizerMode = "spectrum"
                            if mode == .fullscreen {
                                FullscreenPresentationCoordinator.shared.setVisualizerMode(.skinVisualizer)
                            } else {
                                ledMeterProvider.releaseNowPlayingResources()
                            }
                        } else if visualizerMode == "spectrum" {
                            visualizerMode = "off"
                            if mode == .fullscreen {
                                FullscreenPresentationCoordinator.shared.setVisualizerMode(.off)
                            }
                        }
                    }
                ),
                titleFont: presentationStyle.rowLabelFont,
                titleColor: presentationStyle.primaryTextColor
            )
        }
    }

    private var visualizerMode: String {
        get {
            switch mode {
            case .nowPlaying: return normalVisualizerMode
            case .fullscreen:
                guard FullscreenPresentationCoordinator.shared.isSkinVisualizerEnabled else {
                    return "off"
                }
                return fullscreenVisualizerMode
            }
        }
        nonmutating set {
            switch mode {
            case .nowPlaying:
                normalVisualizerMode = newValue
            case .fullscreen:
                fullscreenVisualizerMode = newValue
            }
        }
    }

    private var speedPicker: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text("流体速度")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)

            Spacer()

            SlidingSelector(
                segments: AppleMeshBackgroundSpeed.allCases,
                selection: speedSelection,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(slidingKnobColor.opacity(0.18))
                },
                content: { speed, isSelected in
                    Text(speed.title)
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
            .background(
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
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

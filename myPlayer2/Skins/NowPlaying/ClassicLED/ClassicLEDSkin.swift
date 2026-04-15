//
//  ClassicLEDSkin.swift
//  myPlayer2
//
//  kmgccc_player - Classic LED theme
//

import SwiftUI

struct ClassicLEDTheme: SkinTheme {
    let id = "coverLed"
    let name = NSLocalizedString("skin.classic_led.name", comment: "")
    let detail = NSLocalizedString("skin.classic_led.detail", comment: "")
    let systemImage = "dot.radiowaves.left.and.right"
    let normal: (any NormalSkin)? = ClassicLEDNormalSkin()
    let fullscreen: (any FullscreenSkin)? = ClassicLEDFullscreenSkin()
}

struct ClassicLEDNormalSkin: NormalSkin {
    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(ClassicLEDNormalArtwork(context: context))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(ClassicLEDNormalSettingsView())
    }
}

struct ClassicLEDFullscreenSkin: FullscreenSkin {
    var hasMiniPlayerMotion: Bool { true }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(UnifiedNowPlayingBackground(context: context))
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(ClassicLEDFullscreenArtwork(context: context))
    }

    func makeSettingsView(actions: SkinHostActions) -> AnyView? {
        AnyView(ClassicLEDFullscreenSettingsView(actions: actions))
    }
}

private struct ClassicLEDNormalArtwork: View {
    let context: SkinContext

    @AppStorage("skin.classicLED.visualizerMode") private var visualizerMode: String = "off"

    var body: some View {
        let contentSize = context.contentSize
        let maxArtwork = min(contentSize.width * 0.5, contentSize.height * 0.5, 360)
        let artworkSize = max(180, maxArtwork)

        VStack(spacing: 24) {
            artworkView(size: artworkSize)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)

            if visualizerMode == "led" {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: 10,
                    spacing: 6,
                    pillTint: context.theme.artworkAccentColor
                )
            } else if visualizerMode == "spectrum" {
                NowPlayingPillSpectrumView(
                    context: context,
                    isFullscreen: false,
                    pillTint: context.theme.artworkAccentColor
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: 18)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ArtworkPlaceholderView.nowPlaying(
                size: size,
                cornerRadius: 12
            )
        }
    }
}

private struct ClassicLEDFullscreenArtwork: View {
    let context: SkinContext

    @AppStorage("skin.classicLED.fullscreen.visualizerMode") private var fullscreenVisualizerMode: String = "led"

    var body: some View {
        let contentSize = context.contentSize
        let artworkBoost: CGFloat = 1.22
        let maxArtwork = min(contentSize.width * 0.6, contentSize.height * 0.6, 480 * artworkBoost)
        let artworkSize = max(180 * artworkBoost, maxArtwork)
        let leftShift = context.lyricsVisible ? -40.0 : 0.0
        let shouldRenderVisualizer = context.visualizerMode == .skinVisualizer

        VStack(spacing: 32) {
            artworkView(size: artworkSize)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)

            if shouldRenderVisualizer && fullscreenVisualizerMode == "led" {
                LedMeterView(
                    level: Double(context.audio.smoothedLevel),
                    ledValues: context.led.leds,
                    dotSize: 12,
                    spacing: 8,
                    pillTint: context.theme.artworkAccentColor
                )
            } else if shouldRenderVisualizer && fullscreenVisualizerMode == "spectrum" {
                NowPlayingPillSpectrumView(
                    context: context,
                    isFullscreen: true,
                    pillTint: context.theme.artworkAccentColor
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(1.2)
        .offset(x: leftShift, y: 32)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ArtworkPlaceholderView.nowPlaying(
                size: size,
                cornerRadius: 12
            )
        }
    }
}

private struct ClassicLEDNormalSettingsView: View {
    @AppStorage("skin.classicLED.visualizerMode") private var visualizerMode: String = "off"
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("LED 电平表", isOn: Binding(
                get: { visualizerMode == "led" },
                set: { isOn in
                    if isOn {
                        visualizerMode = "led"
                        ledMeterProvider.getOrCreate().start()
                    } else if visualizerMode == "led" {
                        visualizerMode = "off"
                        ledMeterProvider.releaseNowPlayingResources()
                    }
                }
            ))
            .toggleStyle(.switch)

            Toggle("频谱动画", isOn: Binding(
                get: { visualizerMode == "spectrum" },
                set: { isOn in
                    if isOn {
                        visualizerMode = "spectrum"
                        ledMeterProvider.releaseNowPlayingResources()
                    } else if visualizerMode == "spectrum" {
                        visualizerMode = "off"
                    }
                }
            ))
            .toggleStyle(.switch)
        }
    }
}

private struct ClassicLEDFullscreenSettingsView: View {
    let actions: SkinHostActions

    @Environment(FullscreenPresentationCoordinator.self) private var fullscreenPresentation

    private let visualizerKey = "skin.classicLED.fullscreen.visualizerMode"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("LED 电平表", isOn: Binding(
                get: {
                    fullscreenPresentation.visualizerMode == .skinVisualizer
                        && UserDefaults.standard.string(forKey: visualizerKey) == "led"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("led", forKey: visualizerKey)
                        actions.setVisualizerMode(.skinVisualizer)
                    } else {
                        actions.setVisualizerMode(.off)
                    }
                }
            ))
            .toggleStyle(.switch)

            Toggle("频谱动画", isOn: Binding(
                get: {
                    fullscreenPresentation.visualizerMode == .skinVisualizer
                        && UserDefaults.standard.string(forKey: visualizerKey) == "spectrum"
                },
                set: { isOn in
                    if isOn {
                        UserDefaults.standard.set("spectrum", forKey: visualizerKey)
                        actions.setVisualizerMode(.skinVisualizer)
                    } else {
                        actions.setVisualizerMode(.off)
                    }
                }
            ))
            .toggleStyle(.switch)
        }
    }
}

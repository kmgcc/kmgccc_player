import AppKit
import MotionKit
import SwiftUI

enum NativeSkinComponents {
    static func register(in catalog: SkinComponentCatalog) {
        catalog.register("native.artwork") { snapshot, config in SkinArtworkComponent(snapshot: snapshot, configuration: config) }
        catalog.register("native.background") { snapshot, config in SkinBackgroundComponent(snapshot: snapshot, configuration: config) }
        catalog.register("native.trackInfo") { snapshot, config in SkinTrackInfoComponent(snapshot: snapshot, configuration: config) }
        catalog.register("native.text") { snapshot, config in
            Text(config.text("text", fallback: snapshot.track?.title ?? ""))
                .font(.system(size: config.number("fontSize", fallback: 24)))
                .foregroundStyle(config.color(fallback: snapshot.theme.accentColor))
                .fixedSize(horizontal: false, vertical: true)
        }
        catalog.register("native.image") { _, config in SkinImageComponent(configuration: config) }
        catalog.register("native.lyrics") { _, config in SkinLyricsSlot(configuration: config) }
        catalog.register("native.transport", isInteractive: true) { _, config in SkinTransportComponent(configuration: config) }
        catalog.register("native.progress", isInteractive: true) { _, _ in SkinProgressComponent() }
        catalog.register("native.volume", isInteractive: true) { _, _ in SkinVolumeComponent() }
        catalog.register("native.like", isInteractive: true) { _, _ in SkinLikeComponent() }
        catalog.register("native.queue", isInteractive: true) { _, _ in SkinQueueComponent() }
        catalog.register("native.playbackMode", isInteractive: true) { _, config in SkinPlaybackModeComponent(configuration: config) }
        catalog.register("native.spectrum") { snapshot, config in SkinSpectrumComponent(snapshot: snapshot, configuration: config) }
        catalog.register("native.waveform") { _, config in SkinWaveformComponent(configuration: config) }
        catalog.register("native.led") { snapshot, config in SkinLEDComponent(snapshot: snapshot, configuration: config) }
        catalog.register("native.actionsCapsule", isInteractive: true) { _, config in SkinLeadingCapsule(configuration: config) }
        catalog.register("native.volumeCapsule", isInteractive: true) { _, config in SkinVolumeCapsule(configuration: config) }
        for control in SkinActionButton.Kind.allCases {
            catalog.register("native." + control.rawValue) { _, config in SkinActionButton(kind: control, configuration: config) }
        }
        catalog.register("native.miniPlayer", isInteractive: true) { snapshot, config in
            SkinMiniPlayerComponent(snapshot: snapshot, configuration: config)
        }
    }
}

extension SkinComponentConfiguration {
    func boolean(_ key: String, fallback: Bool) -> Bool {
        if case .boolean(let value) = values[key] { return value }
        return fallback
    }

    func number(_ key: String, fallback: Double) -> Double {
        if case .number(let value) = values[key] { return value }
        return fallback
    }

    func text(_ key: String, fallback: String = "") -> String {
        if case .text(let value) = values[key] { return value }
        return fallback
    }

    func color(fallback: Color) -> Color {
        guard case .number(let red) = values["red"],
              case .number(let green) = values["green"],
              case .number(let blue) = values["blue"] else { return fallback }
        return Color(.displayP3, red: red, green: green, blue: blue, opacity: number("opacity", fallback: 1))
    }
}

private struct SkinTrackInfoComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration

    var body: some View {
        let centered = configuration.text("alignment", fallback: "leading") == "center"
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(snapshot.track?.title ?? "")
                .font(.system(size: configuration.number("fontSize", fallback: 24), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(snapshot.track?.artist ?? "").foregroundStyle(.secondary)
                .font(.system(size: configuration.number("artistFontSize", fallback: 14)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .foregroundStyle(configuration.color(fallback: .primary))
    }
}

private struct SkinImageComponent: View {
    let configuration: SkinComponentConfiguration
    @Environment(\.skinPackageResources) private var resources

    var body: some View {
        if let resources, let image = NSImage(contentsOf: resources.appendingPathComponent(configuration.text("path"))) {
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

private struct SkinSpectrumComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneIsActive) private var isActive

    var body: some View {
        GeometryReader { proxy in
            MiniPlayerSpectrumView(
                isPlaying: snapshot.playback.isPlaying,
                isActive: isActive,
                accentColor: configuration.color(fallback: snapshot.theme.accentColor),
                artworkColors: snapshot.theme.spectrumArtworkColors,
                usesDarkForeground: snapshot.theme.spectrumUsesDarkForeground,
                scale: 1, isHovered: false, pausedBehavior: .default,
                capsuleCount: Int(configuration.number("count", fallback: 9)),
                preferredWidth: proxy.size.width, preferredHeight: proxy.size.height
            )
        }
    }
}

private struct SkinLEDComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(LEDMeterServiceProvider.self) private var provider
    @Environment(\.skinSceneIsActive) private var isActive

    var body: some View {
        LedMeterView(
            level: Double(provider.metrics.level), ledValues: provider.metrics.leds,
            dotSize: configuration.number("dotSize", fallback: 12),
            spacing: configuration.number("spacing", fallback: 7),
            isPlaying: snapshot.playback.isPlaying
        )
        .ledMeterLifecycle(isActive: isActive, isPlaying: snapshot.playback.isPlaying)
    }
}

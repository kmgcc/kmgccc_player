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
        catalog.register("native.like", isInteractive: true) { _, config in SkinLikeComponent(configuration: config) }
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
        SkinComponentContract.register(in: catalog)
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

    func color(_ key: String, fallback: Color) -> Color {
        if case .text(let color) = values[key], let value = OKLCHColor(named: color) { return value.swiftUIColor }
        return fallback
    }

    /// The App's animated media controls, sized by `size` (hit target) and `symbolSize`.
    func mediaControlMetrics(navigation: Bool) -> AnimatedMediaControlMetrics {
        let size = number("size", fallback: AnimatedMediaControlMetrics.windowMiniPlayer.hitSize)
        let scale = size / AnimatedMediaControlMetrics.windowMiniPlayer.hitSize
        return AnimatedMediaControlMetrics(
            hitSize: size,
            playSymbolSize: number("symbolSize", fallback: AnimatedMediaControlMetrics.windowMiniPlayer.playSymbolSize * scale),
            navSymbolSize: number(navigation ? "symbolSize" : "navSymbolSize", fallback: AnimatedMediaControlMetrics.windowMiniPlayer.navSymbolSize * scale)
        )
    }

    func color(fallback: Color) -> Color {
        if case .text(let color) = values["color"], let value = OKLCHColor(named: color) { return value.swiftUIColor }
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
        // `count` capsules; `artworkColors` false keeps them in `color`; `paused` "dots" shrinks them while paused.
        GeometryReader { proxy in
            MiniPlayerSpectrumView(
                isPlaying: snapshot.playback.isPlaying,
                isActive: isActive,
                accentColor: configuration.color(fallback: snapshot.theme.accentColor),
                artworkColors: configuration.boolean("artworkColors", fallback: true) ? snapshot.theme.spectrumArtworkColors : [],
                usesDarkForeground: configuration.boolean("darkForeground", fallback: snapshot.theme.spectrumUsesDarkForeground),
                scale: configuration.number("scale", fallback: 1), isHovered: false,
                pausedBehavior: configuration.text("paused") == "dots" ? .minimalDots : .default,
                capsuleCount: max(1, min(64, Int(configuration.number("count", fallback: 9)))),
                preferredWidth: proxy.size.width, preferredHeight: proxy.size.height
            )
        }
    }
}

/// The layer-backed LED meter of the bundled skins. `count` segments, `levels` brightness steps,
/// `color` for the accent, `tint` for the pill, `direction` centerOut or leftToRight, `tone`
/// standard, light, bright or miniPlayer; `pill`, `statusLight` and `paddingX/Y` shape the shell.
private struct SkinLEDComponent: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneIsActive) private var isActive

    var body: some View {
        let isPlaying = snapshot.playback.isPlaying
        let tone: PerceptualToneLadder.LEDToneVariant = switch configuration.text("tone", fallback: "light") {
        case "standard": .retuned
        case "bright": .appleStyleBright
        case "miniPlayer": .miniPlayer
        default: .skinLight
        }
        let scheme: ColorScheme? = switch configuration.text("scheme") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
        LiveLedMeterView(
            dotSize: configuration.number("dotSize", fallback: 12),
            spacing: configuration.number("spacing", fallback: 7),
            pillTint: configuration.values["tint"] == nil ? nil : configuration.color("tint", fallback: .clear),
            isPlaying: isPlaying,
            forceBrightLEDColors: configuration.boolean("bright", fallback: snapshot.theme.artBackgroundIsUltraDark),
            colorSchemeOverride: scheme,
            levelToneVariant: tone,
            ledCountOverride: configuration.values["count"] == nil ? nil : max(1, min(64, Int(configuration.number("count", fallback: 11)))),
            accentColorOverride: configuration.values["color"] == nil ? nil : configuration.color(fallback: snapshot.theme.accentColor),
            brightnessLevelsOverride: configuration.values["levels"] == nil ? nil : max(2, min(16, Int(configuration.number("levels", fallback: 4)))),
            showsStatusLight: configuration.boolean("statusLight", fallback: true),
            fillDirection: configuration.text("direction") == "leftToRight" ? .leftToRight : .centerOut,
            drawsPill: configuration.boolean("pill", fallback: true),
            horizontalPadding: configuration.number("paddingX", fallback: 14),
            verticalPadding: configuration.number("paddingY", fallback: 10)
        )
        .ledMeterLifecycle(isActive: isActive, isPlaying: isPlaying)
    }
}

import AppKit
import ImageIO
import SwiftUI

/// What lies under a scene, reduced to a luminance map so a node can choose legible ink for
/// the region it occupies. The artwork, aspect-filled over the viewport, stands in for the
/// backdrop; background parts report their dimming so the estimate follows what is drawn.
@MainActor @Observable
final class SkinBackdropReadability {
    nonisolated static let space = "skinScene"

    private(set) var revision = 0
    @ObservationIgnored private var source: RenderedBackdropReadabilityMap?
    @ObservationIgnored private var map: RenderedBackdropReadabilityMap?
    @ObservationIgnored private var imageSize: CGSize = .zero
    @ObservationIgnored private var viewport: CGSize = .zero
    @ObservationIgnored private var dimming: Double = 0
    @ObservationIgnored private var artworkKey: String?

    func setViewport(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        revision += 1
    }

    func setDimming(_ value: Double) {
        let value = max(0, min(1, value))
        guard value != dimming else { return }
        dimming = value
        rebuild()
    }

    func load(key: String, artwork: Data?) async {
        guard key != artworkKey else { return }
        artworkKey = key
        let result = await Task.detached(priority: .utility) { artwork.flatMap(Self.makeMap) }.value
        guard key == artworkKey else { return }
        source = result?.map
        imageSize = result?.size ?? .zero
        rebuild()
    }

    /// Nil when the region covers too little of the map to decide.
    func polarity(for rect: CGRect, dark: NSColor, light: NSColor) -> ArtworkForegroundPolarity? {
        guard let map, let region = AspectFillReadabilityMapping.map(
            viewRect: rect, viewSize: viewport, imageSize: imageSize,
            horizontalAlignment: .center, verticalAlignment: .center
        ) else { return nil }
        let decision = RenderedBackdropReadability.decide(darkForeground: dark, lightForeground: light, samples: [(map, [region])])
        return decision.reason == .noValidSamples ? nil : decision.polarity
    }

    /// A black veil of opacity d scales linear luminance by (1 − d).
    private func rebuild() {
        let factor = Float(1 - dimming)
        map = source.map { factor == 1 ? $0 : .init(pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, luma: $0.luma.map { $0 * factor }) }
        revision += 1
    }

    nonisolated private static func makeMap(_ data: Data) -> (map: RenderedBackdropReadabilityMap, size: CGSize)? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: ColorSystemTokens.ReadabilityForeground.mapMaximumDimension] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let map = RenderedBackdropReadabilityMap.make(from: image) else { return nil }
        return (map, CGSize(width: image.width, height: image.height))
    }
}

/// The ink an adaptive node chose for what lies beneath it.
struct SkinBackdropReading: Equatable {
    let profile: FullscreenMiniPlayerForegroundProfile
    var usesDarkForeground: Bool { profile.isDarkForeground }
    var primary: Color { Color(nsColor: profile.primary) }
    var secondary: Color { Color(nsColor: profile.secondary) }

    var value: SkinValue {
        .record(["backdrop": .text(usesDarkForeground ? "light" : "dark"),
                 "foreground": .color(OKLCHColor(profile.primary)), "secondaryForeground": .color(OKLCHColor(profile.secondary))])
    }
}

extension EnvironmentValues {
    @Entry var skinBackdropReadability: SkinBackdropReadability?
    @Entry var skinBackdropReading: SkinBackdropReading?
}

/// `adaptive: true` on a node: measure where it sits, read the backdrop there and hand the
/// subtree matching ink, colour scheme and native control colours. Recomputed only when the
/// node moves, the artwork or dimming changes, or the theme does.
struct SkinAdaptiveBackdropProbe: ViewModifier {
    @Binding var reading: SkinBackdropReading?
    @Environment(\.skinBackdropReadability) private var backdrop
    @Environment(\.skinNativeControls) private var native
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var theme: ThemeStore
    @State private var frame: CGRect = .zero

    private struct Key: Equatable {
        let frame: CGRect
        let revision: Int
        let dark: Int
        let light: Int
        let scheme: ColorScheme
    }

    func body(content: Content) -> some View {
        let candidates = FullscreenMiniPlayerForegroundStrategy.artworkCandidateProfiles(palette: theme.semanticPalette)
        let key = Key(frame: frame, revision: backdrop?.revision ?? 0, dark: candidates.dark.primary.hash,
                      light: candidates.light.primary.hash, scheme: theme.colorScheme)
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                // Quantised, so small motion does not re-score the backdrop.
                let rect = proxy.frame(in: .named(SkinBackdropReadability.space))
                func step(_ value: CGFloat) -> CGFloat { (value / 8).rounded() * 8 }
                return CGRect(x: step(rect.minX), y: step(rect.minY), width: step(rect.width), height: step(rect.height))
            } action: { frame = $0 }
            .onChange(of: key, initial: true) { resolve(candidates) }
            .environment(\.skinBackdropReading, reading)
            .environment(\.skinNativeControls, adaptedControls)
            .environment(\.colorScheme, reading?.profile.complementaryGlassColorScheme ?? theme.colorScheme)
    }

    private func resolve(_ candidates: (dark: FullscreenMiniPlayerForegroundProfile, light: FullscreenMiniPlayerForegroundProfile)) {
        let palette = theme.semanticPalette
        // Small controls sample a slightly larger patch so the map has enough pixels to judge.
        let rect = frame.insetBy(dx: min(0, (frame.width - 72) / 2), dy: min(0, (frame.height - 72) / 2))
        let polarity = backdrop?.polarity(for: rect, dark: candidates.dark.primary, light: candidates.light.primary)
            ?? (palette.analysis.usesDarkForeground ? .darkOnLightBackground : .lightOnDarkBackground)
        let material = native?.presentation.glassStyle.materialStyle
            ?? (settings.fullscreenMiniPlayerGlassMaterial == .normal ? .normal : .clear)
        let profile = FullscreenMiniPlayerForegroundStrategy.resolve(
            palette: palette, localArtworkPolarity: polarity, hasArtworkThemeColor: theme.palette != nil,
            controlForeground: .artworkAdaptive, colorScheme: theme.colorScheme, materialStyle: material,
            fullscreenArtBackgroundEnabled: false
        )
        let next = SkinBackdropReading(profile: profile)
        if reading != next { reading = next }
    }

    private var adaptedControls: SkinNativeControlsContext? {
        guard let native, let reading else { return native }
        let p = native.presentation
        return .init(
            presentation: .init(
                glassStyle: .init(colorScheme: reading.profile.complementaryGlassColorScheme,
                                  accentColor: p.glassStyle.accentColor, materialStyle: p.glassStyle.materialStyle),
                miniPlayerForegroundProfile: reading.profile, primaryColor: reading.primary,
                iconBlendMode: reading.profile.iconBlendMode, playbackMode: p.playbackMode, hasTrack: p.hasTrack,
                isShowingLyrics: p.isShowingLyrics, isVolumeControlEnabled: p.isVolumeControlEnabled,
                usesAdaptiveVolumeForeground: p.usesAdaptiveVolumeForeground, showsPlaybackModeRetapTip: p.showsPlaybackModeRetapTip
            ),
            actions: native.actions, controls: native.controls
        )
    }
}

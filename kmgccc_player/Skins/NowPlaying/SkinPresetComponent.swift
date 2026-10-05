import MotionKit
import SwiftUI

/// Existing renderers are reusable parts, registered in exactly the same component catalog.
struct SkinPresetComponent: View {
    enum Part: String, CaseIterable { case artwork, background, overlay }
    let renderer: any NowPlayingSkin
    let part: Part
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var motionPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinSceneFullscreenHost) private var fullscreenHost

    var body: some View {
        GeometryReader { proxy in
            if surface == .fullscreen && part != .background {
                // Keep the preset's design canvas and raster scale, scoped to this component.
                let canvas = CGSize(
                    width: configuration.number("canvasWidth", fallback: 882),
                    height: configuration.number("canvasHeight", fallback: 572)
                )
                let scale = min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
                content(context: context(size: canvas, scale: scale))
                    .frame(width: canvas.width, height: canvas.height)
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                content(context: context(size: proxy.size, scale: 1))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func context(size: CGSize, scale: CGFloat) -> SkinContext {
        SkinContext(
            track: snapshot.track, playback: snapshot.playback, theme: snapshot.theme,
            motionTokens: motionTokens,
            motionPolicy: motionPolicy.resolving(accessibilityReduceMotion: reduceMotion),
            windowSize: size, contentBounds: CGRect(origin: .zero, size: size),
            fullscreenScale: scale, lyricsVisible: false,
            presentationMode: surface == .window ? .nowPlaying : .fullscreenPlayer,
            fullscreenHostMode: fullscreenHost
        )
    }

    @ViewBuilder
    private func content(context: SkinContext) -> some View {
        switch part {
        case .artwork: renderer.makeArtwork(context: context)
        case .background: renderer.makeBackground(context: context)
        case .overlay: renderer.makeOverlay(context: context)
        }
    }
}

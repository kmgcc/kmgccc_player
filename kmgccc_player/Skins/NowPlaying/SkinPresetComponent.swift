import MotionKit
import SwiftUI

/// Existing renderers are reusable parts, registered in exactly the same component catalog.
/// With `layout: "host"` the part fills the viewport and is laid out the way the built-in host
/// lays the skin out; otherwise it draws inside the frame the scene gives it.
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
    @Environment(\.skinSceneIsActive) private var isActive
    @Environment(\.skinSceneLyricsVisible) private var lyricsVisible
    @Environment(AppSettings.self) private var settings

    var body: some View {
        GeometryReader { proxy in
            if isActive {
                if configuration.text("layout") == "host" {
                    hostLayout(size: proxy.size)
                } else if surface == .fullscreen && part != .background {
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
            } else {
                Color.clear
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
    private func hostLayout(size: CGSize) -> some View {
        let policy = motionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
        if surface == .fullscreen {
            // FullscreenPlayerView: a 1470×923 canvas, the split's artwork column, then one scale.
            let canvas = SkinHostLayout.canvas
            let scale = SkinHostLayout.fullscreenScale(for: size)
            let split = FullscreenHorizontalSplitLayout.resolve(showLyricsColumn: lyricsVisible)
            let hostContext = snapshot.context.relaid(
                windowSize: canvas, contentSize: CGSize(width: split.artworkWidth, height: canvas.height * 0.62),
                fullscreenScale: scale, lyricsVisible: lyricsVisible, presentationMode: .fullscreenPlayer,
                motionTokens: motionTokens, motionPolicy: policy
            )
            if part == .background {
                content(context: hostContext)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                let presentation = renderer.descriptor.presentation
                let backdrop = presentation.artworkLayout == .backdrop
                let artworkScale = backdrop ? 1 : settings.fullscreenArtworkScale
                let groupShift = !backdrop && lyricsVisible ? FullscreenCoverHorizontalOffset.groupLeftBias : 0
                FullscreenScaledArtworkContainer(
                    movesArtworkWithControls: presentation.movesArtworkWithControls, areControlsVisible: true,
                    horizontalPadding: 0, controlsBottomPadding: SkinHostLayout.controlsBottomPadding,
                    controlButtonSize: SkinHostLayout.buttonSize
                ) {
                    content(context: hostContext)
                        .scaleEffect(artworkScale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .offset(x: -groupShift)
                        .frame(width: split.artworkWidth)
                        .frame(maxHeight: .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .offset(x: split.artworkLeadingX + split.artworkWidth * 0.5 - canvas.width * 0.5)
                }
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale, anchor: .center)
                .frame(width: size.width, height: size.height)
            }
        } else {
            // NowPlayingHostView: the artwork column above the mini player, the window as the backdrop.
            let frames = SkinHostLayout.frames(size: size, surface: .window, lyricsVisible: lyricsVisible,
                                               presentation: renderer.descriptor.presentation)
            let hostContext = snapshot.context.relaid(
                windowSize: size, contentSize: frames.artwork.size, fullscreenScale: 1, lyricsVisible: false,
                presentationMode: .nowPlaying, motionTokens: motionTokens, motionPolicy: policy
            )
            ZStack(alignment: .topLeading) {
                if part == .background {
                    content(context: hostContext).frame(width: size.width, height: size.height)
                } else {
                    content(context: hostContext).frame(width: frames.artwork.width, height: frames.artwork.height)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
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

/// The backdrop a built-in host draws behind a preset: the skin's own background, or the
/// art background when the user turned it on and the skin leaves the backdrop to the host.
struct SkinHostBackgroundPart: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    @Environment(\.skinSceneSurface) private var surface
    @Environment(\.skinSceneIsActive) private var isActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.skinBackdropReadability) private var backdrop
    // Read the stored switches directly, as the skins' own settings rows write them.
    @AppStorage("fullscreenArtBackgroundEnabled") private var fullscreenArtBackgroundEnabled = true
    @AppStorage("nowPlayingArtBackgroundEnabled") private var nowPlayingArtBackgroundEnabled = true

    var body: some View {
        let presetID = configuration.text("preset", fallback: ClassicLEDSkin.id)
        let renderer = SkinRegistry.catalog.nativePreset(for: presetID)
        let presentation = renderer?.descriptor.presentation ?? SkinPresentationPolicy()
        let usesArt = usesArtBackground(presentation)
        let veil = surface == .fullscreen && presentation.backgroundDimming == .host
            ? (usesArt ? (colorScheme == .light ? 0 : dimming(presetID)) : dimming(presetID) * 0.7) : 0
        ZStack {
            if usesArt {
                SkinArtBackgroundPart(snapshot: snapshot, surface: surface,
                                      resourceProfile: presentation.artBackgroundResourceProfile,
                                      isArtworkLoading: playback.stablePresentation.isArtworkLoading)
            } else if let renderer {
                SkinPresetComponent(renderer: renderer, part: .background, snapshot: snapshot,
                                    configuration: .init(values: ["layout": .text("host")]))
            } else {
                UnifiedNowPlayingBackground(context: snapshot.context)
            }
            if veil > 0 { Color.black.opacity(veil) }
        }
        .allowsHitTesting(false)
        .onChange(of: veil, initial: true) { _, value in backdrop?.setDimming(value) }
    }

    private func usesArtBackground(_ presentation: SkinPresentationPolicy) -> Bool {
        guard isActive, snapshot.track != nil, configuration.boolean("allowsArtBackground", fallback: true) else { return false }
        if surface == .fullscreen {
            return presentation.backgroundOwner != .skin && fullscreenArtBackgroundEnabled
        }
        return presentation.windowBackgroundPlacement != .parent && nowPlayingArtBackgroundEnabled
    }

    /// FullscreenPlayerView.effectiveDimmingIntensity.
    private func dimming(_ presetID: String) -> Double {
        let base = UserDefaults.standard.object(forKey: "fullscreenDimmingIntensity") == nil
            ? AppSettings.defaultFullscreenDimmingIntensity(for: presetID)
            : settings.fullscreenDimmingIntensity
        return colorScheme == .light ? min(0.55, base * 1.40) : base
    }
}

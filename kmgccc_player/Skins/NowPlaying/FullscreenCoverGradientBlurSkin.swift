//
//  FullscreenCoverGradientBlurSkin.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Cover Gradient Blur Skin
//

import AppKit
import SwiftUI

struct FullscreenCoverGradientBlurSkin: NowPlayingSkin {
    let id = "fullscreen.coverGradientBlur"
    let name = NSLocalizedString("skin.cover_gradient_blur.name", comment: "")
    let detail = NSLocalizedString("skin.cover_gradient_blur.detail", comment: "")
    let systemImage = "photo.fill"
    var isFullscreenCompatible: Bool { true }
    var isNowPlayingCompatible: Bool { false }

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(
            CoverGradientBlurSkinBackgroundBridge(context: context, config: makeConfigFromSettings())
        )
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        // This skin uses the background AS the artwork (full cover with blur)
        // No separate foreground artwork card needed
        AnyView(EmptyView())
    }

    var fullscreenSettingsView: AnyView? {
        AnyView(CoverGradientBlurSettingsView())
    }

    private func makeConfigFromSettings() -> CoverGradientBlurConfig {
        Self.configFromSettings()
    }

    static func configFromSettings() -> CoverGradientBlurConfig {
        let storedBlurRadius = UserDefaults.standard.double(forKey: "skin.coverGradientBlur.maxBlurRadius")
        let storedEdgeFillMode = UserDefaults.standard.string(forKey: "skin.coverGradientBlur.edgeFillMode")

        // Fall back to the slider's own default (1600) — not 200 — when the
        // slider was never touched, so the rendered blur matches the value the
        // settings UI shows and the far edge actually reaches several hundred px.
        let blurRadius: CGFloat = storedBlurRadius > 0 ? storedBlurRadius : 1600.0
        // Fixed values
        let transitionWidth: CGFloat = 0.8
        let colorIntensity: CGFloat = 0.5
        let edgeFillMode: CoverEdgeFillMode = CoverEdgeFillMode(rawValue: storedEdgeFillMode ?? "") ?? .pixelStretch

        // Convert transitionWidth to blur ratios
        // transitionWidth 0.8 means blur starts at 0.1 and ends at 0.9 of canvas
        let blurStartRatio = max(0, min(1, 0.5 - transitionWidth * 0.5))
        let blurEndRatio = max(0, min(1, 0.5 + transitionWidth * 0.5))

        return CoverGradientBlurConfig(
            blurRadius: blurRadius,
            colorOverlayOpacity: colorIntensity,
            transitionDuration: 0.4,
            edgeStripWidth: 3.0,
            blurStartRatio: blurStartRatio,
            blurEndRatio: blurEndRatio,
            overlayOffsetRatio: 0.15,
            blurCurveGamma: 5.0,
            edgeFillMode: edgeFillMode,
            // Confine the in-cover blur to a narrow strip hugging the right edge
            // (30% of the cover width, not the 0.48 default's ~half): the cover's
            // left ~78% stays crisp and only a thin near-edge band ramps up.
            // Smaller = narrower blurred strip (clearer cover) but the curve must
            // be steeper to keep the edge value up; larger = wider soft band.
            blurStartRatioFromEdge: 0.30,
            // In-cover ramp across the narrow strip: ~0 at the start so the strip's
            // inner side blends into the crisp cover, accelerating to a stronger
            // edge value (~0.19 of the radius ≈ 28px) so the cover↔stretch junction
            // is well masked and the fill has a high base for the linear floor to
            // grow from. Raised from ~22px, which left the junction too sharp.
            // Bigger quadratic term = bigger edge; the negative cubic keeps the
            // curve ≤ 1 at the far right.
            blurAlphaCoefficients: (0, 0, 1.8, -0.8),
            // Adds a continuous blur ramp across the fill (pixel-stretch) region:
            // 0 at the cover's right edge, easing up smoothly toward the right.
            // The mask is 0 inside the cover, so the cover interior is untouched.
            // This makes the fill connect to the cover at a low blur and increase
            // continuously, with no hard seam at the cover→fill boundary.
            extensionFloorStrength: 0.2
        )
    }
}

// MARK: - Background View Wrapper (SemanticPalette bridge)

/// Thin wrapper that reads `themeStore.semanticPalette.coverGradientDominant` from the
/// SwiftUI environment and forwards it as the dominant color, replacing the old
/// `context.theme.artworkAverageColor` source.
private struct CoverGradientBlurSkinBackgroundBridge: View {
    let context: SkinContext
    let config: CoverGradientBlurConfig

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenBackdropReadabilityState) private var readabilityState
    @Environment(\.displayScale) private var displayScale
    @State private var transitionPosition: CGFloat
    @State private var centeredLayerOpacity: CGFloat
    @State private var transitionLayerOpacity: CGFloat = 0
    @State private var transitionBlurRadius: CGFloat = 0
    @State private var bokehRadius: CGFloat = 0
    @State private var bokehSurfaceOpacity: CGFloat = 0
    @State private var bokehOpticalOpacity: CGFloat = 0
    @State private var activeTransitionMode: BokehTransitionMode = .unmaskedFallback(reason: "idle")
    @State private var activeBokehConfiguration = BokehTransitionConfig()
    @State private var isTransitionActive = false
    @State private var transitionTask: Task<Void, Never>?
    @State private var leadingRenderedFrame: CoverGradientBlurRenderedFrame?
    @State private var centeredRenderedFrame: CoverGradientBlurRenderedFrame?
    @State private var transitionRenderedFrame: CoverGradientBlurRenderedFrame?
    @State private var bokehPreparedSourceSet: BokehTransitionPreparedSourceSet?
    @State private var activeBokehSourceSet: BokehTransitionPreparedSourceSet?
    @State private var bokehViewportSize: CGSize = .zero
    @State private var bokehSourcePreparer = BokehTransitionSourcePreparer()

    init(context: SkinContext, config: CoverGradientBlurConfig) {
        self.context = context
        self.config = config

        let startsCentered = context.usesFullscreenPlayerLayout && !context.lyricsVisible
        self._transitionPosition = State(initialValue: startsCentered ? 1 : 0)
        self._centeredLayerOpacity = State(initialValue: startsCentered ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let targetCentered = context.usesFullscreenPlayerLayout && !context.lyricsVisible

            ZStack {
                staticBackground(size: geometry.size, placement: .leading)
                    .zIndex(0)

                staticBackground(size: geometry.size, placement: .centeredSymmetric)
                    .opacity(Double(centeredLayerOpacity))
                    .zIndex(1)

                transitionBackground(size: geometry.size)
                    .frame(
                        width: transitionCanvasWidth(for: geometry.size),
                        height: geometry.size.height
                    )
                    .offset(x: transitionCanvasOffset(for: geometry.size))
                    .opacity(Double(transitionLayerOpacity))
                    .zIndex(2)

                BokehTransitionSurface(
                    snapshot: bokehSnapshot(for: geometry.size),
                    sourceSet: activeBokehSourceSet
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                .zIndex(3)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .compositingGroup()
            .blur(radius: transitionBlurRadius, opaque: true)
            .onChange(of: targetCentered) { _, newValue in
                runLayoutTransition(to: newValue)
            }
            .onAppear {
                updateBokehViewport(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateBokehViewport(newSize)
            }
        }
        .onAppear { beginReadabilityArtwork() }
        .onChange(of: context.track?.artworkChecksum ?? 0) { _, _ in
            beginReadabilityArtwork()
            handleArtworkChange()
        }
        .onChange(of: displayScale) { _, _ in
            prepareBokehSourcesIfPossible()
        }
        .onDisappear {
            transitionTask?.cancel()
            bokehSourcePreparer.invalidate()
        }
    }

    /// Tell the readability state when a new artwork begins so stale maps from
    /// the previous track cannot drive the new track's control polarity.
    private func beginReadabilityArtwork() {
        readabilityState?.beginArtwork(checksum: context.track?.artworkChecksum ?? 0)
    }

    /// Forward a rendered readability map to the fullscreen state.
    @MainActor
    private func acceptReadability(_ snapshot: CoverGradientBlurReadabilitySnapshot) {
        readabilityState?.accept(snapshot)
    }

    /// The transition layer is wider than the viewport and slides horizontally.
    /// Attach representative start/middle/end frames so the consumer samples
    /// the pixels that are actually under the controls, not the same normalized
    /// coordinates in the oversized render at every animation position.
    @MainActor
    private func acceptTransitionReadability(
        _ snapshot: CoverGradientBlurReadabilitySnapshot,
        viewportSize: CGSize
    ) {
        readabilityState?.accept(
            snapshot.withTransitionFrames(
                transitionReadabilityFrames(for: viewportSize)
            )
        )
    }

    @MainActor
    private func acceptRenderedFrame(_ frame: CoverGradientBlurRenderedFrame) {
        guard frame.artworkChecksum == (context.track?.artworkChecksum ?? 0) else { return }
        switch frame.placement {
        case .leading:
            leadingRenderedFrame = frame
        case .centeredSymmetric:
            centeredRenderedFrame = frame
        case .transition:
            transitionRenderedFrame = frame
        }
        prepareBokehSourcesIfPossible()
    }

    private func handleArtworkChange() {
        bokehSourcePreparer.invalidate()
        leadingRenderedFrame = nil
        centeredRenderedFrame = nil
        transitionRenderedFrame = nil
        bokehPreparedSourceSet = nil

        // A running Bokeh surface may only ever show a complete, one-artwork
        // source set. On a track change retire it rather than combining frames
        // from the outgoing and incoming tracks; the high-resolution Gaussian
        // path remains underneath for this exceptional interruption.
        retireBokehWithoutOpticalFallback(reason: "artwork changed during transition")
        activeBokehSourceSet = nil
    }

    private func updateBokehViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        bokehViewportSize = size
        // Keep the active source set stable until the transition completes.
        // A resize prepares the next set but never replaces Bokeh with a sudden
        // full-surface Gaussian blur.
        prepareBokehSourcesIfPossible()
    }

    private func retireBokehWithoutOpticalFallback(reason: String) {
        guard activeTransitionMode.usesBokeh else { return }
        activeTransitionMode = .unmaskedFallback(reason: reason)
        BokehTransitionPerformancePolicy.shared.finish()
        withoutSwiftUIAnimation {
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehOpticalOpacity = 0
            transitionBlurRadius = 0
        }
    }

    private func preferredBokehTier(for configuration: BokehTransitionConfig) -> BokehTransitionRenderTier {
        switch configuration.quality {
        case .low:
            return .low
        case .balanced:
            return .balanced
        case .automatic:
            let thermal = ProcessInfo.processInfo.thermalState
            if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical {
                return .low
            }
            return BokehTransitionPerformancePolicy.shared.nextAutomaticDecision().tier
        }
    }

    private func prepareBokehSourcesIfPossible() {
        let configuration = BokehTransitionConfig.load()
        let tier = preferredBokehTier(for: configuration)
        guard configuration.effect == .bokeh,
              BokehTransitionMetalContext.shared.availability.isReady,
              let frames = BokehTransitionSourceFrames(
                leading: leadingRenderedFrame,
                centered: centeredRenderedFrame,
                transition: transitionRenderedFrame
              ),
              bokehViewportSize.width > 1,
              bokehViewportSize.height > 1,
              abs(frames.leading.logicalCanvasSize.width - bokehViewportSize.width) <= 12,
              abs(frames.leading.logicalCanvasSize.height - bokehViewportSize.height) <= 12,
              let renderSize = BokehTransitionRenderSize.make(
                backingPixelSize: CGSize(
                    width: bokehViewportSize.width * displayScale,
                    height: bokehViewportSize.height * displayScale
                ),
                tier: tier
              ) else {
            return
        }

        bokehSourcePreparer.prepare(
            frames: frames,
            renderSize: renderSize,
            tier: tier
        ) { sourceSet in
            bokehPreparedSourceSet = sourceSet
            // A source prepared during a transition is intentionally held for
            // the next one; no mid-animation resolution/identity swap.
            if !isTransitionActive {
                activeBokehSourceSet = sourceSet
            }
        }
    }

    private func bokehSnapshot(for size: CGSize) -> BokehTransitionSnapshot {
        let sourceSet = activeBokehSourceSet
        let canvasRatio = sourceSet?.transitionCanvasSizeRatio ?? CGSize(width: 1, height: 1)
        return BokehTransitionSnapshot(
            transitionPosition: transitionPosition,
            centeredOpacity: centeredLayerOpacity,
            transitionOpacity: transitionLayerOpacity,
            bokehRadius: bokehRadius,
            surfaceOpacity: bokehSurfaceOpacity,
            opticalOpacity: bokehOpticalOpacity,
            transitionCanvasSizeRatio: canvasRatio,
            // A constant travel distance; Metal combines it with the animated
            // transitionPosition every frame. Sending the already-evaluated
            // offset here bypassed AnimatableData and caused a hard position cut.
            transitionCanvasOffsetRatio: size.width > 1 ? coverCenterShift(for: size) / size.width : 0,
            configuration: activeTransitionMode.usesBokeh ? activeBokehConfiguration : BokehTransitionConfig.load(),
            tier: sourceSet?.identity.tier ?? .balanced,
            reduceMotion: context.theme.reduceMotion
        )
    }

    private func selectTransitionMode(configuration: BokehTransitionConfig) -> BokehTransitionMode {
        guard configuration.effect == .bokeh else {
            return .gaussianFallback(reason: "selected in settings")
        }

        let metalAvailability = BokehTransitionMetalContext.shared.availability
        guard metalAvailability.isReady else {
            return .gaussianFallback(
                reason: metalAvailability.reason ?? "Bokeh enhancement unavailable"
            )
        }

        let tier = preferredBokehTier(for: configuration)
        guard let sourceSet = bokehPreparedSourceSet,
              sourceSet.identity.tier == tier else {
            prepareBokehSourcesIfPossible()
            return .unmaskedFallback(reason: "Bokeh source set not ready")
        }
        activeBokehSourceSet = sourceSet
        return .bokeh
    }

    private var blurRiseAnimation: Animation {
        if context.theme.reduceMotion {
            return .easeInOut(duration: 0.16)
        }
        return .timingCurve(0.22, 0.0, 0.24, 1.0, duration: 0.34)
    }

    private var coverSpringAnimation: Animation {
        if context.theme.reduceMotion {
            return .easeInOut(duration: 0.36)
        }
        return .spring(response: 0.74, dampingFraction: 0.78, blendDuration: 0.14)
    }

    private var backgroundCrossfadeAnimation: Animation {
        context.theme.reduceMotion
            ? .easeInOut(duration: 0.28)
            : .timingCurve(0.24, 0.62, 0.22, 1.0, duration: 0.58)
    }

    private var transitionLayerFadeInAnimation: Animation {
        context.theme.reduceMotion
            ? .easeInOut(duration: 0.12)
            : .easeInOut(duration: 0.22)
    }

    private var transitionLayerFadeOutAnimation: Animation {
        context.theme.reduceMotion
            ? .easeInOut(duration: 0.18)
            : .timingCurve(0.24, 0.72, 0.22, 1.0, duration: 0.32)
    }

    private var blurFallAnimation: Animation {
        context.theme.reduceMotion
            ? .easeInOut(duration: 0.28)
            : .timingCurve(0.20, 0.78, 0.22, 1.0, duration: 0.78)
    }

    @ViewBuilder
    private func staticBackground(
        size: CGSize,
        placement: CoverGradientBlurArtworkPlacement
    ) -> some View {
        let readabilityPlacement: CoverGradientBlurReadabilityPlacement = placement == .leading ? .leading : .centeredSymmetric
        CoverGradientBlurBackgroundView(
            artworkData: context.track?.artworkData,
            artworkImage: context.track?.artworkImage,
            artworkChecksum: context.track?.artworkChecksum ?? 0,
            dominantColor: themeStore.semanticPalette.coverGradientDominant,
            config: config(for: placement),
            readabilityPlacement: readabilityPlacement,
            onReadabilitySnapshot: acceptReadability,
            onRenderedFrame: acceptRenderedFrame
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func transitionBackground(size: CGSize) -> some View {
        CoverGradientBlurBackgroundView(
            artworkData: context.track?.artworkData,
            artworkImage: context.track?.artworkImage,
            artworkChecksum: context.track?.artworkChecksum ?? 0,
            dominantColor: themeStore.semanticPalette.coverGradientDominant,
            config: config(for: .centeredSymmetric),
            readabilityPlacement: .transition,
            onReadabilitySnapshot: { snapshot in
                acceptTransitionReadability(snapshot, viewportSize: size)
            },
            onRenderedFrame: acceptRenderedFrame
        )
        .allowsHitTesting(false)
    }

    private func runLayoutTransition(to targetCentered: Bool) {
        transitionTask?.cancel()

        let targetPosition: CGFloat = targetCentered ? 1 : 0
        let shouldRetargetImmediately = isTransitionActive
        let bokehConfiguration = BokehTransitionConfig.load()

        guard transitionPosition != targetPosition || isTransitionActive else {
            retireTransitionEffect()
            return
        }

        isTransitionActive = true

        if !shouldRetargetImmediately {
            // The mode is deliberately locked for this whole transition. A
            // source set that becomes ready later is reserved for the next
            // toggle, avoiding an in-flight Gaussian/Bokeh quality jump.
            activeBokehConfiguration = bokehConfiguration
            activeTransitionMode = selectTransitionMode(configuration: activeBokehConfiguration)
            if activeTransitionMode.usesBokeh {
                BokehTransitionPerformancePolicy.shared.begin(
                    tier: activeBokehSourceSet?.identity.tier ?? .balanced
                )
            }
        }

        startTransitionEffect(configuration: activeBokehConfiguration)
        setTransitionLayerOpacity(1, rising: true)

        if shouldRetargetImmediately {
            retargetTransition(to: targetPosition)
        }

        transitionTask = Task { @MainActor in
            if !shouldRetargetImmediately {
                // Start moving once the masking blur is roughly halfway up.
                guard await waitForTransitionStage(nanoseconds: 105_000_000) else { return }
                retargetTransition(to: targetPosition)
            }

            guard await waitForTransitionStage(nanoseconds: movementSettleDelay) else { return }

            setTransitionLayerOpacity(0, rising: false)

            guard await waitForTransitionStage(nanoseconds: 120_000_000) else { return }

            retireTransitionEffect()

            if activeTransitionMode.usesBokeh {
                guard await waitForTransitionStage(nanoseconds: bokehTailFadeDelay) else { return }
                withoutSwiftUIAnimation {
                    bokehOpticalOpacity = 0
                }
                guard await waitForTransitionStage(nanoseconds: bokehTailRetirementDelay) else { return }
            } else {
                guard await waitForTransitionStage(nanoseconds: transitionCompletionDelay) else { return }
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                bokehSurfaceOpacity = 0
            }
            isTransitionActive = false
            BokehTransitionPerformancePolicy.shared.finish()
            activeBokehSourceSet = bokehPreparedSourceSet
        }
    }

    private func startTransitionEffect(configuration: BokehTransitionConfig) {
        switch activeTransitionMode {
        case .bokeh:
            transitionBlurRadius = 0
            withoutSwiftUIAnimation {
                bokehSurfaceOpacity = 1
                bokehOpticalOpacity = 1
                bokehRadius = configuration.radiusAt1080
            }
        case .gaussianFallback:
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehOpticalOpacity = 0
            withAnimation(blurRiseAnimation) {
                transitionBlurRadius = 44
            }
        case .unmaskedFallback:
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehOpticalOpacity = 0
            transitionBlurRadius = 0
        }
    }

    private func retireTransitionEffect() {
        switch activeTransitionMode {
        case .bokeh:
            withoutSwiftUIAnimation {
                bokehRadius = 0
            }
        case .gaussianFallback:
            withAnimation(blurFallAnimation) {
                transitionBlurRadius = 0
            }
        case .unmaskedFallback:
            transitionBlurRadius = 0
        }
    }

    private var movementSettleDelay: UInt64 {
        context.theme.reduceMotion ? 380_000_000 : 720_000_000
    }

    private var transitionCompletionDelay: UInt64 {
        context.theme.reduceMotion ? 320_000_000 : 820_000_000
    }

    private var bokehTailFadeDelay: UInt64 {
        context.theme.reduceMotion ? 180_000_000 : 520_000_000
    }

    private var bokehTailRetirementDelay: UInt64 {
        context.theme.reduceMotion ? 140_000_000 : 300_000_000
    }

    private func retargetTransition(to targetPosition: CGFloat) {
        if activeTransitionMode.usesBokeh {
            // Metal is the sole animation authority in Bokeh mode. SwiftUI only
            // publishes new targets; the renderer preserves spring velocity and
            // generates every presentation frame, including interruptions.
            withoutSwiftUIAnimation {
                transitionPosition = targetPosition
                centeredLayerOpacity = targetPosition
            }
        } else {
            withAnimation(coverSpringAnimation) {
                transitionPosition = targetPosition
            }
            withAnimation(backgroundCrossfadeAnimation) {
                centeredLayerOpacity = targetPosition
            }
        }
    }

    private func setTransitionLayerOpacity(_ value: CGFloat, rising: Bool) {
        if activeTransitionMode.usesBokeh {
            withoutSwiftUIAnimation {
                transitionLayerOpacity = value
            }
        } else {
            withAnimation(rising ? transitionLayerFadeInAnimation : transitionLayerFadeOutAnimation) {
                transitionLayerOpacity = value
            }
        }
    }

    private func withoutSwiftUIAnimation(_ updates: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    private func waitForTransitionStage(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func transitionCanvasWidth(for size: CGSize) -> CGFloat {
        size.width + coverCenterShift(for: size) * 2 + transitionOverscan(for: size) * 2
    }

    private func transitionCanvasOffset(for size: CGSize) -> CGFloat {
        let shift = coverCenterShift(for: size)
        return shift * (transitionPosition - 1)
    }

    private func transitionReadabilityFrames(for size: CGSize) -> [CGRect] {
        let canvasWidth = transitionCanvasWidth(for: size)
        let centeredOriginX = (size.width - canvasWidth) * 0.5
        let shift = coverCenterShift(for: size)
        return [CGFloat(0), 0.5, 1].map { position in
            CGRect(
                x: centeredOriginX + shift * (position - 1),
                y: 0,
                width: canvasWidth,
                height: size.height
            )
        }
    }

    private func coverCenterShift(for size: CGSize) -> CGFloat {
        max(0, (size.width - renderedArtworkWidth(for: size)) * 0.5)
    }

    private func renderedArtworkWidth(for size: CGSize) -> CGFloat {
        guard
            let imageSize = context.track?.artworkImage?.size,
            imageSize.width > 0,
            imageSize.height > 0
        else {
            return min(size.width, size.height)
        }

        return min(size.width, size.height * imageSize.width / imageSize.height)
    }

    private func transitionOverscan(for size: CGSize) -> CGFloat {
        max(48, min(120, size.width * 0.045))
    }

    private func config(
        for placement: CoverGradientBlurArtworkPlacement
    ) -> CoverGradientBlurConfig {
        var copy = config
        copy.artworkPlacement = placement
        if placement == .centeredSymmetric {
            copy.blurStartRatioFromEdge = 0.22
            copy.blurAlphaCoefficients = (0, 0, 1.35, -0.55)
            copy.extensionFloorStrength = min(copy.extensionFloorStrength, 0.16)
        }
        return copy
    }
}

// MARK: - Background View Wrapper

private struct CoverGradientBlurSkinBackground: View {
    let context: SkinContext

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600

    private var config: CoverGradientBlurConfig {
        // Fixed values
        let transitionW: CGFloat = 0.8
        let colorOverlayIntensity: CGFloat = 0.5
        let blurStartRatio = max(0, min(1, 0.5 - transitionW * 0.5))
        let blurEndRatio = max(0, min(1, 0.5 + transitionW * 0.5))

        return CoverGradientBlurConfig(
            blurRadius: CGFloat(maxBlurRadius),
            colorOverlayOpacity: colorOverlayIntensity,
            transitionDuration: 0.35,
            edgeStripWidth: 3.0,
            blurStartRatio: blurStartRatio,
            blurEndRatio: blurEndRatio,
            overlayOffsetRatio: 0.15,
            blurCurveGamma: 5.0
        )
    }

    var body: some View {
        CoverGradientBlurBackgroundView(
            artworkData: context.track?.artworkData,
            artworkImage: context.track?.artworkImage,
            artworkChecksum: context.track?.artworkChecksum ?? 0,
            dominantColor: themeStore.semanticPalette.coverGradientDominant,
            config: config
        )
        .ignoresSafeArea()
    }

    @EnvironmentObject private var themeStore: ThemeStore
}

// MARK: - Artwork View

private struct CoverGradientBlurArtwork: View {
    let context: SkinContext
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Fullscreen Fine-tuning Constants
    private let fullscreenArtworkBoost: CGFloat = 1.15
    private let fullscreenLeftShift: CGFloat = -36

    var body: some View {
        let contentSize = context.contentSize
        let usesFullscreenLayout = context.usesFullscreenPlayerLayout

        let artworkBoost = usesFullscreenLayout ? fullscreenArtworkBoost : 1.0
        let leftShift = (usesFullscreenLayout && context.lyricsVisible) ? fullscreenLeftShift : 0

        let scaleFactor: CGFloat = usesFullscreenLayout ? 0.55 : 0.5
        let maxSizeBase: CGFloat = usesFullscreenLayout ? 420 : 320
        let maxSize = maxSizeBase * artworkBoost
        let maxArtwork = min(contentSize.width * scaleFactor, contentSize.height * scaleFactor, maxSize)
        let artworkSize = max(180 * artworkBoost, maxArtwork)
        let yOffset: CGFloat = usesFullscreenLayout ? 24 : 16

        artworkView
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: leftShift, y: yOffset)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let image = context.track?.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            ColorRenderingAdapter.makeSwiftUIColor(accentNSColor).opacity(0.6),
                            ColorRenderingAdapter.makeSwiftUIColor(accentNSColor).opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(placeholderIconColor)
                }
        }
    }

    private var accentNSColor: NSColor {
        if let accent = context.theme.artworkAccentColor {
            return NSColor(accent)
        }
        return NSColor.controlAccentColor
    }

    /// Placeholder icon colour follows the current colour scheme. Reusing the
    /// SwiftUI semantic `.primary` keeps it in sync with system foreground
    /// without introducing a second readability judgement just for this icon.
    private var placeholderIconColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.5)
            : Color.primary.opacity(0.45)
    }
}

// MARK: - Settings View

private struct CoverGradientBlurSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600
    @AppStorage("skin.coverGradientBlur.edgeFillMode") private var edgeFillMode: String = CoverEdgeFillMode.pixelStretch.rawValue
    @AppStorage("fullscreenDimmingIntensity") private var fullscreenDimmingIntensity: Double = 0.15
    @AppStorage(BokehTransitionConfig.Keys.effect) private var transitionEffect: String = CoverBlurTransitionEffect.bokeh.rawValue
    @AppStorage(BokehTransitionConfig.Keys.quality) private var transitionQuality: String = BokehTransitionQuality.automatic.rawValue
    @AppStorage(BokehTransitionConfig.Keys.radiusAt1080) private var bokehRadiusAt1080: Double = BokehTransitionConfig.defaultRadiusAt1080
    @AppStorage(BokehTransitionConfig.Keys.highlightPower) private var bokehHighlightPower: Double = BokehTransitionConfig.defaultHighlightPower
    @AppStorage(BokehTransitionConfig.Keys.highlightThreshold) private var bokehHighlightThreshold: Double = BokehTransitionConfig.defaultHighlightThreshold
    @AppStorage(BokehTransitionConfig.Keys.aperture) private var bokehAperture: String = BokehApertureShape.circle.rawValue
    @AppStorage(BokehTransitionConfig.Keys.apertureRotationDegrees) private var bokehApertureRotationDegrees: Double = 0
    @AppStorage(BokehTransitionConfig.Keys.apertureRoundness) private var bokehApertureRoundness: Double = 0

    private var currentEdgeFillMode: CoverEdgeFillMode {
        CoverEdgeFillMode(rawValue: edgeFillMode) ?? .pixelStretch
    }

    private var currentTransitionEffect: CoverBlurTransitionEffect {
        CoverBlurTransitionEffect(rawValue: transitionEffect) ?? .bokeh
    }

    private var currentTransitionQuality: BokehTransitionQuality {
        BokehTransitionQuality(rawValue: transitionQuality) ?? .automatic
    }

    private var currentAperture: BokehApertureShape {
        BokehApertureShape(rawValue: bokehAperture) ?? .circle
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
            edgeFillModePicker

            blurRadiusSlider

            transitionEffectPicker

            bokehControls

            dimmingIntensitySlider
        }
        .padding(.vertical, 6)
    }

    private var edgeFillModePicker: some View {
        HStack(spacing: 8) {
            Text("右侧填充")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)

            Spacer()

            SlidingSelector(
                segments: CoverEdgeFillMode.allCases,
                selection: Binding(
                    get: { currentEdgeFillMode },
                    set: { edgeFillMode = $0.rawValue }
                ),
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(slidingKnobColor.opacity(0.18))
                },
                content: { mode, isSelected in
                    Text(mode.displayName)
                        .font(presentationStyle.segmentedLabelFont.weight(isSelected ? .medium : .regular))
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

    private var blurRadiusSlider: some View {
        HStack(spacing: 12) {
            Text("模糊半径")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: 84, alignment: .leading)

            Slider(value: $maxBlurRadius, in: 100...2500, step: 100)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity)

            Text("\(Int(maxBlurRadius))")
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                // Don't let the value collapse into an ellipsis on narrower settings windows.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var transitionEffectPicker: some View {
        HStack(spacing: 8) {
            Text("切换效果")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)

            Spacer()

            SlidingSelector(
                segments: CoverBlurTransitionEffect.allCases,
                selection: Binding(
                    get: { currentTransitionEffect },
                    set: { transitionEffect = $0.rawValue }
                ),
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: { Color.clear },
                knob: {
                    Capsule()
                        .fill(slidingKnobColor.opacity(0.18))
                },
                content: { effect, isSelected in
                    Text(effect.displayName)
                        .font(presentationStyle.segmentedLabelFont.weight(isSelected ? .medium : .regular))
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

    private var bokehControls: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            menuRow(
                title: "散景质量",
                selection: Binding(
                    get: { currentTransitionQuality },
                    set: { transitionQuality = $0.rawValue }
                )
            )

            sliderRow(
                title: "散景半径",
                value: $bokehRadiusAt1080,
                range: 16...72,
                step: 1,
                valueText: "\(Int(bokehRadiusAt1080))"
            )

            sliderRow(
                title: "高光力度",
                value: $bokehHighlightPower,
                range: 1...5,
                step: 0.1,
                valueText: String(format: "%.1f", bokehHighlightPower)
            )

            sliderRow(
                title: "高光阈值",
                value: $bokehHighlightThreshold,
                range: 0.40...0.95,
                step: 0.01,
                valueText: String(format: "%.2f", bokehHighlightThreshold)
            )

            menuRow(
                title: "光圈形状",
                selection: Binding(
                    get: { currentAperture },
                    set: { bokehAperture = $0.rawValue }
                )
            )

            sliderRow(
                title: "光圈旋转",
                value: $bokehApertureRotationDegrees,
                range: 0...180,
                step: 1,
                valueText: "\(Int(bokehApertureRotationDegrees))°"
            )
            .disabled(!currentAperture.supportsPolygonControls)

            sliderRow(
                title: "光圈圆度",
                value: $bokehApertureRoundness,
                range: -1...1,
                step: 0.05,
                valueText: String(format: "%.2f", bokehApertureRoundness)
            )
            .disabled(!currentAperture.supportsPolygonControls)
        }
        .disabled(currentTransitionEffect != .bokeh)
        .opacity(currentTransitionEffect == .bokeh ? 1 : 0.55)
    }

    private func menuRow<Option: CaseIterable & Hashable>(
        title: String,
        selection: Binding<Option>
    ) -> some View where Option.AllCases: RandomAccessCollection, Option: BokehTransitionMenuOption {
        HStack(spacing: 12) {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: 84, alignment: .leading)

            Spacer()

            Picker(title, selection: selection) {
                ForEach(Array(Option.allCases), id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 120, alignment: .trailing)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: 84, alignment: .leading)

            Slider(value: value, in: range, step: step)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity)

            Text(valueText)
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var dimmingIntensitySlider: some View {
        HStack(spacing: 12) {
            Text("背景压暗强度")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: 84, alignment: .leading)

            Slider(value: $fullscreenDimmingIntensity, in: 0.0...0.5, step: 0.05)
                .tint(themeStore.accentColor)
                .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", fullscreenDimmingIntensity * 100))
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

private protocol BokehTransitionMenuOption {
    var displayName: String { get }
}

extension BokehTransitionQuality: BokehTransitionMenuOption {}
extension BokehApertureShape: BokehTransitionMenuOption {}

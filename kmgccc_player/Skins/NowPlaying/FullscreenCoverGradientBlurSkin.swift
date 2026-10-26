//
//  FullscreenCoverGradientBlurSkin.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Cover Gradient Blur Skin
//

import AppKit
import MotionKit
import SwiftUI

struct FullscreenCoverGradientBlurSkin: NowPlayingSkin {
    let descriptor = SkinDescriptor(
        id: "fullscreen.coverGradientBlur",
        name: NSLocalizedString("skin.cover_gradient_blur.name", comment: ""),
        detail: NSLocalizedString("skin.cover_gradient_blur.detail", comment: ""),
        systemImage: "photo.fill",
        surfaces: [.fullscreen],
        presentation: SkinPresentationPolicy(
            backgroundOwner: .skin,
            artworkLayout: .backdrop,
            lyricsBackdrop: .coverBlur,
            controlForeground: .artworkAdaptive,
            movesArtworkWithControls: false
        ),
        audio: SkinAudioDefaults(
            fullscreen: .miniPlayerSpectrum,
            supportsEmbeddedVisualizer: false,
            hasLedMeter: false
        ),
        artwork: SkinArtworkDefaults(scale: 1.0, maximumScale: 1.0),
        fullscreenTypography: SkinDescriptor.backdropTypography,
        fullscreenDimming: 0,
        fullscreenOrder: 0,
        legacy: SkinLegacySettings(
            visualizerNamespace: "skin.fullscreen.coverGradientBlur",
            previousFullscreenVisualization: .miniPlayerSpectrum
        )
    )

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(
            CoverGradientBlurSkinBackgroundBridge(context: context, config: makeConfigFromSettings())
                // Stabilize identity across track switches so @State survives
                // and the targetCentered onChange can animate position/opacity.
                // Artwork changes are still observed via artworkChecksum and
                // handled by handleArtworkChange.
                .id("fullscreen.coverGradientBlur.backgroundBridge")
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

    func releaseCachedResources() async {
        await CoverGradientBlurMemory.clear()
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
            extensionFloorStrength: 0.2,
            // The GPU progressive blur replaces the pass chain above; those
            // values remain only for the Core Image fallback.
            progressiveProfile: .leading
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
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    /// Placement the displayed motion frame was rendered for; nil while it
    /// shows the plain video under an opaque lens.
    @State private var readyMotionPlacement: Bool?
    /// The video keeps playing under the lens and feeds the moving surface.
    @State private var bokehLiveFeed = BokehLiveCoverFeed()
    @State private var installedBokehIdentity: BokehTransitionSourceIdentity?
    @State private var bokehSurfaceState = BokehTransitionSurfaceState()
    /// From the blur-fall start the motion frame renders for the target
    /// placement again, so it is ready when the lens dissolves.
    @State private var bokehFallStarted = false
    @State private var transitionPosition: CGFloat
    @State private var centeredLayerOpacity: CGFloat
    @State private var settledCenteredLayerOpacity: CGFloat
    @State private var transitionLayerOpacity: CGFloat = 0
    @State private var transitionBlurRadius: CGFloat = 0
    @State private var bokehRadius: CGFloat = 0
    @State private var bokehSurfaceOpacity: CGFloat = 0
    /// Holds the surface opaque while the radius falls; the renderer then
    /// dissolves it into the settled layer once the radius is small.
    @State private var bokehSurfaceHoldsOpaque = false
    /// Dissolves the surface early when an artwork change has no source.
    @State private var bokehHandoffOpacity: CGFloat = 0
    /// The surface's cover. A different artwork installed while it draws
    /// dissolves in inside the same panorama.
    @State private var bokehSourceSet: BokehTransitionSourceSet?
    @State private var activeTransitionMode: BokehTransitionMode = .unmaskedFallback(reason: "idle")
    @State private var isTransitionActive = false
    /// Builds the next transition's source outside the track-switch path.
    @State private var bokehPrewarmTask: Task<Void, Never>?
    @State private var transitionGeneration: UInt64 = 0
    @State private var transitionTask: Task<Void, Never>?
    /// Live track artwork checksum, updated in onChange. The transitionTask
    /// captures `self` at creation time, so `context.track` inside the task
    /// can be stale if the track changes during the transition. This @State
    /// variable always holds the latest checksum (SwiftUI @State storage is
    /// identity-based, so the task reads the current value).
    @State private var latestTrackArtworkChecksum: UInt64 = 0
    /// When the artwork last changed; a layout change soon after it belongs
    /// to the same track switch.
    @State private var artworkChangeUptime: TimeInterval?
    /// The newest source for the current artwork. Mid-movement it waits for
    /// the fall before it replaces the surface's cover.
    @State private var bokehPreparedSourceSet: BokehTransitionSourceSet?
    @State private var bokehViewportSize: CGSize = .zero
    @State private var bokehSourceTask: Task<Void, Never>?
    @State private var bokehSourceKey: String?

    /// A source for the current artwork and viewport, if one exists.
    private var reusableBokehSourceSet: BokehTransitionSourceSet? {
        let checksum = latestTrackArtworkChecksum
        guard checksum != 0 else { return nil }
        for candidate in [bokehPreparedSourceSet, bokehSourceSet] {
            if let candidate,
               candidate.identity.artworkChecksum == checksum,
               candidate.identity.matchesViewport(bokehViewportSize, displayScale: displayScale) {
                return candidate
            }
        }
        return nil
    }

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(
            accessibilityReduceMotion: accessibilityReduceMotion
        )
    }

    /// Host-specific viewport fitting belongs to `FullscreenPlayerView`.
    /// Both fullscreen hosts must keep this target change so hiding lyrics
    /// continues to drive the existing movement and Bokeh transition state.
    private static func shouldCenterArtwork(for context: SkinContext) -> Bool {
        context.usesFullscreenPlayerLayout
            && !context.lyricsVisible
    }

    init(context: SkinContext, config: CoverGradientBlurConfig) {
        self.context = context
        self.config = config

        let startsCentered = Self.shouldCenterArtwork(for: context)
        self._transitionPosition = State(initialValue: startsCentered ? 1 : 0)
        self._centeredLayerOpacity = State(initialValue: startsCentered ? 1 : 0)
        self._settledCenteredLayerOpacity = State(initialValue: startsCentered ? 1 : 0)
        self._latestTrackArtworkChecksum = State(
            initialValue: context.track?.artworkChecksum ?? 0
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let targetCentered = Self.shouldCenterArtwork(for: context)
            let shouldMountCenteredBackground = targetCentered
                || isTransitionActive
                || centeredLayerOpacity > 0.001
                || settledCenteredLayerOpacity > 0.001
            let shouldMountTransitionBackground = isTransitionActive && !activeTransitionMode.usesBokeh

            ZStack {
                motionArtwork(size: geometry.size, centered: settledCenteredLayerOpacity > 0.5,
                              mountsCenteredBackground: shouldMountCenteredBackground)
                    .zIndex(1.5)

                if shouldMountTransitionBackground {
                    transitionBackground(size: geometry.size)
                        .frame(
                            width: transitionCanvasWidth(for: geometry.size),
                            height: geometry.size.height
                        )
                        .offset(x: transitionCanvasOffset(for: geometry.size))
                        .opacity(Double(transitionLayerOpacity))
                        .zIndex(2)
                }

                // One persistent Bokeh surface. It is never removed from the
                // hierarchy (only paused and hidden when dormant), so a
                // mid-flight MTKView is never dismantled. An artwork change
                // dissolves inside its panorama, so no second surface has to
                // present in step with it.
                BokehTransitionSurface(
                    snapshot: bokehSnapshot,
                    sourceSet: bokehSourceSet,
                    liveFeed: bokehLiveFeed,
                    onSourceReady: { installedBokehIdentity = $0 },
                    onSurfaceStateChange: { bokehSurfaceState = $0 }
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
                DebugUIHooks.record("cover-blur targetCentered changed to \(newValue), current pos=\(transitionPosition) isActive=\(isTransitionActive)")
                runLayoutTransition(to: newValue)
            }
            .onAppear {
                updateBokehViewport(geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                updateBokehViewport(newSize)
            }
        }
        .onAppear {
            beginReadabilityArtwork()
            scheduleBokehPrewarm()
        }
        .onChange(of: context.track?.artworkChecksum ?? 0) { _, newValue in
            latestTrackArtworkChecksum = newValue
            beginReadabilityArtwork()
            handleArtworkChange()
        }
        .onChange(of: displayScale) { _, _ in
            scheduleBokehPrewarm(full: 250_000_000, reduced: 250_000_000)
        }
        .onChange(of: bokehStyleKey) { _, _ in
            scheduleBokehPrewarm(full: 250_000_000, reduced: 250_000_000)
        }
        .onDisappear {
            transitionTask?.cancel()
            bokehPrewarmTask?.cancel()
            bokehSourceTask?.cancel()
            bokehSourceTask = nil
            bokehSourceKey = nil
            bokehLiveFeed.clear()
            bokehSourceSet = nil
            installedBokehIdentity = nil
            bokehPreparedSourceSet = nil
        }
    }

    /// The video plays on through the whole transition. Clear artwork and
    /// its progressive extension are rendered from each decoded frame,
    /// except while the opaque lens covers the movement: the lens then
    /// draws the video itself, and the panorama render would only compete.
    private func motionArtwork(size: CGSize, centered: Bool, mountsCenteredBackground: Bool) -> some View {
        let resource = context.track?.preferredMotionArtwork
        let checksum = context.track?.artworkChecksum ?? 0
        let feed = bokehLiveFeed
        let processor = suspendsMotionPanorama
            ? nil
            : motionPanoramaProcessor(size: size, centered: centered)
        let placement: Bool? = processor == nil ? nil : centered
        return MotionArtworkView(
            resource: resource,
            isPlaying: context.playback.isPlaying,
            frameProcessor: processor,
            onFrame: { image in
                feed.publish(image, artworkChecksum: checksum)
                if readyMotionPlacement != placement { readyMotionPlacement = placement }
            },
            frameOpacity: motionArtworkOpacity
        ) {
            ZStack {
                staticBackground(size: size, placement: .leading)
                if mountsCenteredBackground {
                    staticBackground(size: size, placement: .centeredSymmetric)
                        // Keep the floor at the last completed placement
                        // while a Bokeh surface owns the transition.
                        .opacity(Double(activeTransitionMode.usesBokeh
                            ? settledCenteredLayerOpacity : centeredLayerOpacity))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func motionPanoramaProcessor(size: CGSize, centered: Bool) -> MotionArtworkFrameProcessor {
        let style = MotionPanoramaFrameStyle(
            size: size, displayScale: displayScale,
            dominantColor: themeStore.semanticPalette.coverGradientDominant,
            config: config(for: centered ? .centeredSymmetric : .leading)
        )
        return MotionArtworkFrameProcessor(
            identity: "\(size.width)x\(size.height):\(displayScale):\(String(reflecting: style.config)):\(String(describing: style.dominantColor))",
            process: { style.render($0) }
        )
    }

    private var suspendsMotionPanorama: Bool {
        isTransitionActive && activeTransitionMode.usesBokeh
            && bokehSurfaceState.isOpaque && !bokehFallStarted
    }

    /// Visible through the lens's rise, hidden while the opaque lens covers
    /// it, and back once a frame for the settled placement has rendered.
    private var motionArtworkOpacity: Double {
        if isTransitionActive, activeTransitionMode.usesBokeh, bokehSurfaceState.isOpaque {
            return 0
        }
        return readyMotionPlacement == (settledCenteredLayerOpacity > 0.5) ? 1 : 0
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

    private func handleArtworkChange() {
        // A static artwork checksum may arrive after the video, or change
        // between two songs sharing one album video. Its retained frame is
        // still ready for the current placement throughout that handoff.
        if context.track?.preferredMotionArtwork == nil { readyMotionPlacement = nil }
        bokehLiveFeed.clear()
        artworkChangeUptime = ProcessInfo.processInfo.systemUptime

        bokehPrewarmTask?.cancel()
        bokehSourceTask?.cancel()
        bokehSourceTask = nil
        bokehSourceKey = nil
        bokehPreparedSourceSet = nil

        if isTransitionActive {
            // Never interrupt a running movement: it continues on the old
            // cover. The new artwork's source is only a decode and a crop, so
            // it is built now and replaces the cover at the fall, where the
            // renderer dissolves between the two inside one panorama.
            prepareBokehSourceIfNeeded()
            DebugUIHooks.record("cover-blur artwork changed during transition: mode=\(transitionModeLabel(activeTransitionMode)) pos=\(transitionPosition)")
        } else {
            let targetCentered = Self.shouldCenterArtwork(for: context)
            let targetPosition: CGFloat = targetCentered ? 1 : 0
            if abs(transitionPosition - targetPosition) > 0.001 {
                DebugUIHooks.record("cover-blur artwork changed: no transition, starting one pos=\(transitionPosition)->\(targetPosition)")
                runLayoutTransition(to: targetCentered)
            } else {
                DebugUIHooks.record("cover-blur artwork changed: already at target pos=\(targetPosition)")
            }
        }

        if !isTransitionActive {
            scheduleBokehPrewarm()
        }
    }

    private func updateBokehViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        bokehViewportSize = size
        // A resize prepares the next source once it settles; the running
        // transition keeps its own, drawn to the view's live bounds.
        scheduleBokehPrewarm(full: 250_000_000, reduced: 250_000_000)
    }

    private func preferredBokehTier() -> BokehTransitionRenderTier {
        // A system fullscreen space can be several times larger in backing
        // pixels than the embedded host. Use the smaller drawable from the
        // first transition instead of waiting for a dropped-frame sample to
        // downgrade the next one.
        if context.fullscreenHostMode == .systemFullscreen {
            return .low
        }

        if SystemConditionMonitor.shared.prefersReducedVisualEffort {
            return .low
        }
        return BokehTransitionPerformancePolicy.shared.nextAutomaticDecision().tier
    }

    /// The settled layers' profiles, fill and tint; the transition panorama
    /// draws with exactly these, so its ends match them.
    private var bokehSourceStyle: BokehTransitionSourceStyle {
        let leading = config(for: .leading)
        let centered = config(for: .centeredSymmetric)
        return BokehTransitionSourceStyle(
            leading: leading.progressiveProfile ?? .leading,
            centered: centered.progressiveProfile ?? .centered,
            edgeFill: config.edgeFillMode == .pixelStretch ? .stretch : .mirror,
            overlay: CoverGradientBlurRenderer.progressiveOverlay(
                dominantColor: themeStore.semanticPalette.coverGradientDominant,
                config: leading
            )
        )
    }

    private var bokehStyleKey: String {
        let style = bokehSourceStyle
        let overlay = style.overlay.map { "\($0.linearColor):\($0.maxAlpha):\($0.startRatioFromEdge)" } ?? "none"
        return "\(style.leading.cacheToken)|\(style.centered.cacheToken)|\(style.edgeFill)|\(overlay)"
    }

    /// Builds the next transition's cover off the main actor: a decode and a
    /// square crop of the stored artwork. A video track starts from its
    /// poster; the live feed replaces it from the first frame on.
    private func prepareBokehSourceIfNeeded() {
        guard BokehTransitionMetalContext.shared.availability.isReady,
              bokehViewportSize.width > 1, bokehViewportSize.height > 1,
              latestTrackArtworkChecksum != 0 else { return }
        let tier = preferredBokehTier()
        let viewport = bokehViewportSize
        let checksum = latestTrackArtworkChecksum
        let key = "\(checksum):\(Int(viewport.width))x\(Int(viewport.height)):"
            + "\(Int((displayScale * 100).rounded())):\(tier.rawValue):\(bokehStyleKey)"
        guard bokehSourceKey != key else { return }
        if let reusable = reusableBokehSourceSet, reusable.identity.sourceKey == key {
            publishBokehSource(reusable)
            return
        }
        bokehSourceKey = key
        bokehSourceTask?.cancel()

        let request = BokehTransitionSourceRequest(
            artworkData: context.track?.artworkData,
            artworkImage: context.track?.artworkImage,
            viewport: viewport,
            displayScale: displayScale,
            checksum: checksum,
            sourceKey: key,
            tier: tier,
            style: bokehSourceStyle
        )
        bokehSourceTask = Task { @MainActor in
            let operation = Task.detached(priority: .userInitiated) { request.prepare() }
            let prepared = await withTaskCancellationHandler {
                await operation.value
            } onCancel: { operation.cancel() }
            guard !Task.isCancelled, bokehSourceKey == key else { return }
            bokehSourceTask = nil
            guard let prepared else {
                // Allow a later attempt for the same artwork.
                bokehSourceKey = nil
                return
            }
            guard prepared.identity.artworkChecksum == latestTrackArtworkChecksum else { return }
            publishBokehSource(prepared)
            DebugUIHooks.record(
                "bokeh-source ready cs=\(checksum) "
                + "\(prepared.identity.renderSize.width)x\(prepared.identity.renderSize.height)"
            )
        }
    }

    private func publishBokehSource(_ sourceSet: BokehTransitionSourceSet) {
        bokehPreparedSourceSet = sourceSet
        // A running movement keeps its cover until the fall.
        if !isTransitionActive, bokehSourceSet?.identity != sourceSet.identity {
            bokehSourceSet = sourceSet
        }
    }

    private var bokehSnapshot: BokehTransitionSnapshot {
        BokehTransitionSnapshot(
            transitionPosition: transitionPosition,
            bokehRadius: bokehRadius,
            surfaceOpacity: bokehSurfaceOpacity,
            handoffOpacity: bokehHandoffOpacity,
            keepsSurfaceOpaque: bokehSurfaceHoldsOpaque,
            configuration: BokehTransitionConfig(),
            tier: bokehSourceSet?.identity.tier ?? .balanced,
            motionPolicy: motionPolicy,
            motionTokens: motionTokens
        )
    }

    private func transitionModeLabel(_ mode: BokehTransitionMode) -> String {
        switch mode {
        case .bokeh: return "bokeh"
        case .gaussianFallback: return "gaussian"
        case .unmaskedFallback: return "unmasked"
        }
    }

    private func selectTransitionMode() -> BokehTransitionMode {
        let metalAvailability = BokehTransitionMetalContext.shared.availability
        guard metalAvailability.isReady else {
            Log.info("CoverBlur transition: Gaussian (Metal unavailable: \(metalAvailability.reason ?? "unknown"))", category: .fullscreen)
            return .gaussianFallback(
                reason: metalAvailability.reason ?? "Bokeh enhancement unavailable"
            )
        }

        let tier = preferredBokehTier()
        if let sourceSet = reusableBokehSourceSet,
           bokehSourceSet?.identity == sourceSet.identity,
           installedBokehIdentity == sourceSet.identity {
            // A prepared source is usable even if the performance policy has
            // since decided on a different tier; the next one follows it.
            if sourceSet.identity.tier != tier {
                Log.debug("CoverBlur transition: tier mismatch, using prepared \(sourceSet.identity.tier.rawValue) source set while decision is \(tier.rawValue)", category: .fullscreen)
            }
            return .bokeh
        }

        // Do not hold the layout animation behind source preparation beyond
        // the short wait before this. Preparation keeps running for the next
        // transition while this one starts on the complete Gaussian path.
        prepareBokehSourceIfNeeded()
        Log.info("CoverBlur transition: Gaussian (Bokeh source not ready, tier=\(tier.rawValue))", category: .fullscreen)
        return .gaussianFallback(reason: "Bokeh source not ready")
    }

    private func transitionAnimation(
        duration: Double,
        token: MotionToken
    ) -> Animation? {
        let spec = motionTokens.phaseSpec(for: token, duration: duration, bounce: 0)
        return motionPolicy.animation(for: spec)
    }

    private var blurRiseAnimation: Animation? {
        transitionAnimation(duration: 0.34, token: .contentReplacement)
    }

    private var coverSpringAnimation: Animation? {
        return motionPolicy.animation(for: motionTokens[.backgroundTransition])
    }

    private var backgroundCrossfadeAnimation: Animation? {
        transitionAnimation(duration: 0.72, token: .backgroundTransition)
    }

    private var transitionLayerFadeInAnimation: Animation? {
        transitionAnimation(duration: 0.22, token: .contentReplacement)
    }

    private var transitionLayerFadeOutAnimation: Animation? {
        transitionAnimation(duration: 0.32, token: .contentReplacement)
    }

    private var blurFallAnimation: Animation? {
        transitionAnimation(duration: 0.78, token: .backgroundTransition)
    }

    private func motionDelay(full: UInt64, reduced: UInt64) -> UInt64 {
        switch motionPolicy {
        case .full:
            full
        case .reduced:
            reduced
        case .disabled:
            0
        }
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
            extendsIntoSafeArea: false,
            readabilityPlacement: readabilityPlacement,
            onReadabilitySnapshot: acceptReadability
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// The moving canvas of the Gaussian fallback.
    @ViewBuilder
    private func transitionBackground(size: CGSize) -> some View {
        CoverGradientBlurBackgroundView(
            artworkData: context.track?.artworkData,
            artworkImage: context.track?.artworkImage,
            artworkChecksum: context.track?.artworkChecksum ?? 0,
            dominantColor: themeStore.semanticPalette.coverGradientDominant,
            config: config(for: .centeredSymmetric),
            extendsIntoSafeArea: false,
            readabilityPlacement: .transition,
            onReadabilitySnapshot: { snapshot in
                acceptTransitionReadability(snapshot, viewportSize: size)
            }
        )
        // This overscan render is only a moving/blurred transition source;
        // settled leading and centered surfaces supply the Retina detail.
        .environment(\.displayScale, 1)
        .allowsHitTesting(false)
    }

    private func runLayoutTransition(to targetCentered: Bool) {
        transitionTask?.cancel()
        bokehPrewarmTask?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration

        let targetPosition: CGFloat = targetCentered ? 1 : 0
        let shouldRetargetImmediately = isTransitionActive

        DebugUIHooks.record("cover-blur runLayoutTransition: target=\(targetPosition) pos=\(transitionPosition) isActive=\(isTransitionActive)")

        guard transitionPosition != targetPosition || isTransitionActive else {
            DebugUIHooks.record("cover-blur runLayoutTransition: guard returned, already at target")
            retireTransitionEffect()
            return
        }

        transitionTask = Task { @MainActor in
            if !shouldRetargetImmediately {
                await waitForBokehSource()
                guard !Task.isCancelled, transitionGeneration == generation else { return }
                let selectedMode = selectTransitionMode()
                guard !Task.isCancelled, transitionGeneration == generation else { return }

                activeTransitionMode = selectedMode
                if activeTransitionMode.usesBokeh {
                    BokehTransitionPerformancePolicy.shared.begin(
                        tier: bokehSourceSet?.identity.tier ?? .balanced
                    )
                }
                var modeDescription = transitionModeLabel(activeTransitionMode)
                if case let .gaussianFallback(reason) = activeTransitionMode {
                    modeDescription += " reason=\(reason)"
                }
                Log.info("CoverBlur transition starting: mode=\(modeDescription) target=\(targetPosition)", category: .fullscreen)
                DebugUIHooks.record("cover-blur-transition mode=\(modeDescription) target=\(targetPosition)")
            }

            guard !Task.isCancelled, transitionGeneration == generation else { return }
            isTransitionActive = true
            startTransitionEffect()
            setTransitionLayerOpacity(1, rising: true)
            recordTransitionState("start")

            // Publish the target at once. In Bokeh mode the renderer holds
            // the cover until the lens is opaque, then springs it from its
            // current presentation.
            retargetTransition(to: targetPosition)

            guard await waitForTransitionStage(nanoseconds: movementSettleDelay) else { return }

            setTransitionLayerOpacity(0, rising: false)

            guard await waitForTransitionStage(nanoseconds: 120_000_000) else { return }

            if activeTransitionMode.usesBokeh {
                // Use the live checksum (latestTrackArtworkChecksum) instead
                // of context.track, which is captured at task creation time
                // and can be stale if the track changed during the transition.
                let targetChecksum = latestTrackArtworkChecksum
                let activeChecksum = bokehSourceSet?.identity.artworkChecksum
                let artworkChanged = activeChecksum != nil
                    && activeChecksum != targetChecksum

                // The radius falls with the surface held opaque; the settled
                // layers switch to the target beneath it, and the renderer
                // dissolves into them once the radius is small. An artwork
                // that changed mid-movement leaves during the same fall.
                withoutSwiftUIAnimation {
                    bokehRadius = 0
                    bokehSurfaceHoldsOpaque = true
                    bokehFallStarted = true
                    settledCenteredLayerOpacity = targetPosition
                    if artworkChanged {
                        if let prepared = bokehPreparedSourceSet,
                           prepared.identity.artworkChecksum == targetChecksum {
                            // The renderer dissolves to the new cover inside
                            // the same panorama.
                            bokehSourceSet = prepared
                        } else {
                            // The settled layers beneath already show the new
                            // artwork at the target layout.
                            bokehHandoffOpacity = 0
                        }
                    }
                }
                recordTransitionState("fall")
                if artworkChanged {
                    Log.debug("CoverBlur fall with artwork change: \(activeChecksum ?? 0) -> \(targetChecksum) swap=\(bokehSourceSet?.identity.artworkChecksum == targetChecksum)", category: .fullscreen)
                }
                guard await waitForBokehHandoff() else { return }
            } else {
                retireTransitionEffect()
                guard await waitForTransitionStage(nanoseconds: transitionCompletionDelay) else { return }
            }
            // A newer transition may have started while this task ran its last
            // stage. Its retirement must not overwrite the new transition's
            // optical opacity / active flag; that race left the surface at
            // alpha 0 (static layers hard-cutting underneath a half-faded
            // ghost) on quick repeated toggles.
            guard !Task.isCancelled, transitionGeneration == generation else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Gaussian/unmasked paths have no optical fade, so the settled
                // floor is synced here at retirement. For Bokeh this is a
                // no-op: the floor was already synced above.
                settledCenteredLayerOpacity = targetPosition
                bokehSurfaceOpacity = 0
                bokehHandoffOpacity = 0
                bokehSurfaceHoldsOpaque = false
                bokehFallStarted = false
                isTransitionActive = false
            }
            recordTransitionState("retire")
            BokehTransitionPerformancePolicy.shared.finish()
            // A source prepared mid-movement (resize, artwork change without
            // a swap) becomes the surface's cover for the next transition.
            if let reusable = reusableBokehSourceSet, bokehSourceSet?.identity != reusable.identity {
                bokehSourceSet = reusable
            }
            scheduleBokehPrewarm()
        }
    }

    /// Builds and installs the source before the movement starts instead of
    /// accepting a Gaussian fallback. A track switch gets the larger budget
    /// because the new artwork needs decoding. The movement itself still
    /// starts as soon as the source is on the surface.
    private func waitForBokehSource() async {
        guard BokehTransitionMetalContext.shared.availability.isReady else { return }
        let recentlyChangedArtwork = artworkChangeUptime.map {
            ProcessInfo.processInfo.systemUptime - $0 < 2
        } ?? false
        let limit = recentlyChangedArtwork
            ? motionDelay(full: 360_000_000, reduced: 200_000_000)
            : motionDelay(full: 200_000_000, reduced: 120_000_000)
        prepareBokehSourceIfNeeded()
        let pollInterval: UInt64 = 16_000_000
        var elapsed: UInt64 = 0
        while true {
            if let reusable = reusableBokehSourceSet {
                if bokehSourceSet?.identity != reusable.identity { bokehSourceSet = reusable }
                if installedBokehIdentity == reusable.identity { return }
            }
            guard elapsed < limit,
                  await waitForTransitionStage(nanoseconds: pollInterval) else { return }
            elapsed += pollInterval
        }
    }

    /// The renderer dissolves the surface itself once the falling radius is
    /// small. Bounded in case the surface stopped drawing.
    private func waitForBokehHandoff() async -> Bool {
        let limit = motionDelay(full: 1_400_000_000, reduced: 600_000_000)
        let pollInterval: UInt64 = 16_000_000
        var elapsed: UInt64 = 0
        while !bokehSurfaceState.handoffComplete, elapsed < limit {
            guard await waitForTransitionStage(nanoseconds: pollInterval) else { return false }
            elapsed += pollInterval
        }
        return !Task.isCancelled
    }

    private func startTransitionEffect() {
        switch activeTransitionMode {
        case .bokeh:
            transitionBlurRadius = 0
            withoutSwiftUIAnimation {
                bokehSurfaceOpacity = 1
                bokehHandoffOpacity = 1
                // The surface fades in with the rising radius; only the fall
                // holds it opaque. A retarget during the fall resumes here.
                bokehSurfaceHoldsOpaque = false
                bokehFallStarted = false
                bokehRadius = BokehTransitionConfig.defaultRadiusAt1080
            }
        case .gaussianFallback:
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehHandoffOpacity = 0
            withAnimation(blurRiseAnimation) {
                transitionBlurRadius = 44
            }
        case .unmaskedFallback:
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehHandoffOpacity = 0
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
        motionDelay(full: 720_000_000, reduced: 380_000_000)
    }

    private var transitionCompletionDelay: UInt64 {
        motionDelay(full: 820_000_000, reduced: 320_000_000)
    }

    private func retargetTransition(to targetPosition: CGFloat) {
        if activeTransitionMode.usesBokeh {
            // Targets are published atomically; the renderer retargets from
            // its current presentation frame and preserves spring velocity.
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
        recordTransitionState("retarget")
    }

    private func recordTransitionState(_ label: String) {
        let viewport = bokehViewportSize
        let shift = viewport.width > 1 ? coverCenterShift(for: viewport) : 0
        let artWidth = viewport.width > 1 ? renderedArtworkWidth(for: viewport) : 0
        DebugUIHooks.record(
            "cover-blur state \(label) pos=\(String(format: "%.2f", transitionPosition)) "
            + "settled=\(String(format: "%.2f", settledCenteredLayerOpacity)) "
            + "centered=\(String(format: "%.2f", centeredLayerOpacity)) "
            + "active=\(isTransitionActive) surface=\(String(format: "%.2f", bokehSurfaceOpacity)) "
            + "radius=\(String(format: "%.1f", bokehRadius)) "
            + "handoff=\(String(format: "%.2f", bokehHandoffOpacity)) "
            + "holds=\(bokehSurfaceHoldsOpaque) mode=\(transitionModeLabel(activeTransitionMode)) "
            + "viewport=\(Int(viewport.width))x\(Int(viewport.height)) "
            + "shift=\(String(format: "%.1f", shift)) artW=\(String(format: "%.1f", artWidth)) "
            + "fall=\(bokehFallStarted) opaque=\(bokehSurfaceState.isOpaque) "
            + "motion=\(readyMotionPlacement.map { $0 ? "centered" : "leading" } ?? "none")"
        )
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

    /// The source is a decode and a crop off the main actor, so it is built
    /// shortly after a change settles; a transition before then builds it
    /// itself.
    private func scheduleBokehPrewarm(
        full: UInt64 = 900_000_000,
        reduced: UInt64 = 500_000_000
    ) {
        bokehPrewarmTask?.cancel()
        bokehPrewarmTask = Task { @MainActor in
            guard await waitForTransitionStage(nanoseconds: motionDelay(full: full, reduced: reduced)) else { return }
            guard !isTransitionActive else { return }
            prepareBokehSourceIfNeeded()
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

    /// Every cover is shown square and fills the canvas height; off-square
    /// artwork is center-cropped by the renderers.
    private func renderedArtworkWidth(for size: CGSize) -> CGFloat {
        min(size.width, size.height)
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
            copy.progressiveProfile = .centered
        }
        return copy
    }
}

// MARK: - Background View Wrapper

struct SkinCoverBlurPart: View {
    let snapshot: SkinSceneSnapshot
    let configuration: SkinComponentConfiguration
    var body: some View {
        CoverGradientBlurSkinBackground(context: snapshot.context).environment(\.skinComponentConfiguration, configuration)
    }
}

private struct CoverGradientBlurSkinBackground: View {
    let context: SkinContext

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600
    @Environment(\.skinComponentConfiguration) private var componentConfiguration

    private var config: CoverGradientBlurConfig {
        // Fixed values
        let transitionW: CGFloat = 0.8
        let colorOverlayIntensity: CGFloat = 0.5
        let blurStartRatio = max(0, min(1, 0.5 - transitionW * 0.5))
        let blurEndRatio = max(0, min(1, 0.5 + transitionW * 0.5))

        return CoverGradientBlurConfig(
            blurRadius: componentConfiguration.number("blurRadius", fallback: maxBlurRadius),
            colorOverlayOpacity: componentConfiguration.number("colorOverlayOpacity", fallback: colorOverlayIntensity),
            transitionDuration: componentConfiguration.number("transitionDuration", fallback: 0.35),
            edgeStripWidth: componentConfiguration.number("edgeStripWidth", fallback: 3),
            blurStartRatio: componentConfiguration.number("blurStartRatio", fallback: blurStartRatio),
            blurEndRatio: componentConfiguration.number("blurEndRatio", fallback: blurEndRatio),
            overlayOffsetRatio: componentConfiguration.number("overlayOffsetRatio", fallback: 0.15),
            blurCurveGamma: componentConfiguration.number("blurCurveGamma", fallback: 5)
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

/// The cover-blur skin's artwork card, sized by the scene frame.
struct SkinCoverGradientBlurArtworkPart: View {
    let snapshot: SkinSceneSnapshot
    var body: some View {
        GeometryReader { proxy in
            CoverGradientBlurArtwork(
                context: snapshot.context.withComponentBounds(proxy.size),
                fixedSize: min(proxy.size.width, proxy.size.height)
            )
        }
    }
}

private struct CoverGradientBlurArtwork: View {
    let context: SkinContext
    var fixedSize: CGFloat? = nil
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
        let artworkSize = fixedSize ?? max(180 * artworkBoost, maxArtwork)
        let yOffset: CGFloat = fixedSize != nil ? 0 : usesFullscreenLayout ? 24 : 16

        artworkView
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: fixedSize != nil ? 0 : leftShift, y: yOffset)
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
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    @AppStorage("skin.coverGradientBlur.edgeFillMode") private var edgeFillMode: String = CoverEdgeFillMode.pixelStretch.rawValue
    @AppStorage("fullscreenDimmingIntensity") private var fullscreenDimmingIntensity: Double =
        AppSettings.defaultFullscreenDimmingIntensity(for: "fullscreen.coverGradientBlur")

    private var currentEdgeFillMode: CoverEdgeFillMode {
        CoverEdgeFillMode(rawValue: edgeFillMode) ?? .pixelStretch
    }

    private var slidingKnobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return presentationStyle.settingsPrimaryTextColor(appColors: appColors)
        }
        return themeStore.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            edgeFillModePicker

            dimmingIntensitySlider
        }
        .padding(.vertical, presentationStyle.scaled(6))
    }

    private var edgeFillModePicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
            Text("右侧填充")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))

            Spacer()

            SlidingSelector(
                segments: CoverEdgeFillMode.allCases,
                selection: Binding(
                    get: { currentEdgeFillMode },
                    set: { edgeFillMode = $0.rawValue }
                ),
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
                                ? presentationStyle.settingsSelectedTextColor(
                                    accentColor: themeStore.accentColor,
                                    appColors: appColors
                                )
                                : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        )
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(
                Capsule()
                    .fill(presentationStyle.settingsSegmentedTrackColor(appColors: appColors))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                presentationStyle.segmentedTrackStrokeColor,
                                lineWidth: presentationStyle.segmentedTrackStrokeColor == .clear
                                    ? 0
                                    : presentationStyle.scaledHairlineWidth
                            )
                            .allowsHitTesting(false)
                    )
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var dimmingIntensitySlider: some View {
        HStack(spacing: presentationStyle.scaled(12)) {
            Text("背景压暗强度")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
                .frame(width: presentationStyle.scaled(84), alignment: .leading)

            Slider(value: $fullscreenDimmingIntensity, in: 0.0...0.5, step: 0.05)
                .tint(presentationStyle.settingsSelectedTextColor(
                    accentColor: themeStore.accentColor,
                    appColors: appColors
                ))
                .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", fullscreenDimmingIntensity * 100))
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: presentationStyle.scaled(52), alignment: .trailing)
        }
    }
}

/// Captured values cross to the render executor; AppKit color is read only.
private nonisolated struct MotionPanoramaFrameStyle: @unchecked Sendable {
    let size: CGSize
    let displayScale: CGFloat
    let dominantColor: NSColor?
    let config: CoverGradientBlurConfig

    nonisolated func render(_ image: CGImage) -> CGImage? {
        // Match the settled and frozen panorama pipeline exactly; changing
        // blur resolution at the live-video handoff changes the side fills.
        CoverGradientBlurRenderer.render(
            artworkCGImage: image,
            targetSize: size,
            dominantColor: dominantColor,
            config: config,
            displayScale: displayScale,
            materializeIntermediateBlurPasses: true
        )
    }
}

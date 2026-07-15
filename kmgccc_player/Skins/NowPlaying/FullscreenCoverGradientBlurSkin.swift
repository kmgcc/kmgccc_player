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
    @State private var settledCenteredLayerOpacity: CGFloat
    @State private var transitionLayerOpacity: CGFloat = 0
    @State private var transitionBlurRadius: CGFloat = 0
    @State private var bokehRadius: CGFloat = 0
    @State private var bokehSurfaceOpacity: CGFloat = 0
    /// Per-surface optical opacity for the two persistent Bokeh surfaces.
    /// Surface 0 is the "base" (current artwork, always full opacity while
    /// active). Surface 1 is the "overlay" (previous artwork that fades out
    /// on top of the base to reveal the new artwork underneath). Only the
    /// old artwork fades out; the new artwork is never faded in, so no
    /// semi-transparent surface pair can expose transparent canvas edges.
    @State private var bokehOpticalOpacities: [CGFloat] = [0, 0]
    @State private var bokehSourceSets: [BokehTransitionPreparedSourceSet?] = [nil, nil]
    @State private var activeTransitionMode: BokehTransitionMode = .unmaskedFallback(reason: "idle")
    @State private var isTransitionActive = false
    @State private var transitionGeneration: UInt64 = 0
    @State private var transitionTask: Task<Void, Never>?
    /// Live track artwork checksum, updated in onChange. The transitionTask
    /// captures `self` at creation time, so `context.track` inside the task
    /// can be stale if the track changes during the transition. This @State
    /// variable always holds the latest checksum (SwiftUI @State storage is
    /// identity-based, so the task reads the current value).
    @State private var latestTrackArtworkChecksum: UInt64 = 0
    @State private var leadingRenderedFrame: CoverGradientBlurRenderedFrame?
    @State private var centeredRenderedFrame: CoverGradientBlurRenderedFrame?
    @State private var transitionRenderedFrame: CoverGradientBlurRenderedFrame?
    @State private var bokehPreparedSourceSet: BokehTransitionPreparedSourceSet?
    @State private var bokehViewportSize: CGSize = .zero
    @State private var bokehSourcePreparer = BokehTransitionSourcePreparer()

    /// Read-only accessor for the base surface's source set.
    private var activeBokehSourceSet: BokehTransitionPreparedSourceSet? {
        bokehSourceSets[0]
    }

    init(context: SkinContext, config: CoverGradientBlurConfig) {
        self.context = context
        self.config = config

        let startsCentered = context.usesFullscreenPlayerLayout && !context.lyricsVisible
        self._transitionPosition = State(initialValue: startsCentered ? 1 : 0)
        self._centeredLayerOpacity = State(initialValue: startsCentered ? 1 : 0)
        self._settledCenteredLayerOpacity = State(initialValue: startsCentered ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let targetCentered = context.usesFullscreenPlayerLayout && !context.lyricsVisible

            ZStack {
                staticBackground(size: geometry.size, placement: .leading)
                    .zIndex(0)

                staticBackground(size: geometry.size, placement: .centeredSymmetric)
                    // Bokeh transition targets move ahead of their rendered
                    // presentation values. Keep the high-resolution floor at
                    // the last completed layout until the surface retires.
                    .opacity(Double(
                        activeTransitionMode.usesBokeh
                            ? settledCenteredLayerOpacity
                            : centeredLayerOpacity
                    ))
                    .zIndex(1)

                transitionBackground(size: geometry.size)
                    .frame(
                        width: transitionCanvasWidth(for: geometry.size),
                        height: geometry.size.height
                    )
                    .offset(x: transitionCanvasOffset(for: geometry.size))
                    // Metal already contains this moving source. Showing the
                    // SwiftUI copy too leaves a stationary translucent ghost
                    // when an opacity fade is interrupted.
                    .opacity(activeTransitionMode.usesBokeh ? 0 : Double(transitionLayerOpacity))
                    .zIndex(2)

                // Two persistent Bokeh surfaces. They are never removed from
                // the hierarchy (only paused / alpha-zeroed when dormant) so
                // dismantling a mid-flight MTKView can never crash the app.
                // During a track change the incoming artwork is installed on
                // the dormant surface and the two crossfade optical opacity;
                // both carry the same blur so the swap reads as a smooth
                // dissolved crossfade, not a hard texture cut.
                BokehTransitionSurface(
                    snapshot: bokehSnapshot(for: geometry.size, surfaceIndex: 0),
                    sourceSet: bokehSourceSets[0]
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                .zIndex(3)

                BokehTransitionSurface(
                    snapshot: bokehSnapshot(for: geometry.size, surfaceIndex: 1),
                    sourceSet: bokehSourceSets[1]
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                .zIndex(4)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .compositingGroup()
            .blur(radius: transitionBlurRadius, opaque: true)
            .onChange(of: targetCentered) { _, newValue in
                print("[CoverBlur] targetCentered changed to \(newValue), current pos=\(transitionPosition) isActive=\(isTransitionActive)")
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
        .onChange(of: context.track?.artworkChecksum ?? 0) { _, newValue in
            latestTrackArtworkChecksum = newValue
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
        print("[CoverBlur] frame arrived: \(frame.placement) cs=\(frame.artworkChecksum) leading=\(leadingRenderedFrame != nil) centered=\(centeredRenderedFrame != nil) transition=\(transitionRenderedFrame != nil) isActive=\(isTransitionActive)")
        prepareBokehSourcesIfPossible()
    }

    private func handleArtworkChange() {
        let wasBokeh = activeTransitionMode.usesBokeh

        // Invalidate the preparer and clear stale rendered frames / prepared
        // source sets. The new artwork's frames will arrive via
        // acceptRenderedFrame and trigger prepareBokehSourcesIfPossible for
        // the next transition.
        bokehSourcePreparer.invalidate()
        leadingRenderedFrame = nil
        centeredRenderedFrame = nil
        transitionRenderedFrame = nil
        bokehPreparedSourceSet = nil

        if isTransitionActive {
            // A transition is in progress. Do NOT disrupt it - killing the
            // Bokeh and switching to Gaussian here was the root cause of the
            // "Bokeh shows briefly -> Gaussian fallback" jank and choppiness
            // during auto track switching. The position/blur animation must
            // run to completion.
            if wasBokeh {
                // The base surface holds textures from the previous artwork,
                // but the Metal renderer is still animating position/opacity
                // and its blur is visually acceptable for the remainder of
                // this transition. Keep it running; do NOT clear the base
                // source set or switch to Gaussian. New sources for the new
                // artwork are prepared in the background
                // (acceptRenderedFrame -> prepareBokehSourcesIfPossible) and
                // stored in bokehPreparedSourceSet. The actual swap is
                // deferred to retirement (after the position settles) so the
                // texture upload does not cause frame drops during the
                // position animation and the blur decrease + overlay fade-out
                // start simultaneously.
                print("[CoverBlur] artwork changed during Bokeh transition: keeping Bokeh, pos=\(transitionPosition)")
            } else {
                print("[CoverBlur] artwork changed during non-Bokeh transition: letting it continue pos=\(transitionPosition)")
            }
        } else {
            // No transition active. Clear the source sets (old artwork
            // textures) so the next transition prepares fresh sources.
            if wasBokeh {
                bokehSourceSets = [nil, nil]
                bokehOpticalOpacities = [0, 0]
            }
            let targetCentered = context.usesFullscreenPlayerLayout && !context.lyricsVisible
            let targetPosition: CGFloat = targetCentered ? 1 : 0
            if abs(transitionPosition - targetPosition) > 0.001 {
                print("[CoverBlur] artwork changed: no transition, starting one pos=\(transitionPosition)->\(targetPosition)")
                runLayoutTransition(to: targetCentered)
            } else {
                print("[CoverBlur] artwork changed: already at target pos=\(targetPosition)")
            }
        }
    }

    private func updateBokehViewport(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        bokehViewportSize = size
        // Keep the active source set stable until the transition completes.
        // A resize prepares the next set but never replaces Bokeh with a sudden
        // full-surface Gaussian blur.
        prepareBokehSourcesIfPossible()
    }

    private func preferredBokehTier() -> BokehTransitionRenderTier {
        let thermal = ProcessInfo.processInfo.thermalState
        if ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical {
            return .low
        }
        return BokehTransitionPerformancePolicy.shared.nextAutomaticDecision().tier
    }

    private func prepareBokehSourcesIfPossible() {
        let tier = preferredBokehTier()
        let hasAllFrames = leadingRenderedFrame != nil
            && centeredRenderedFrame != nil
            && transitionRenderedFrame != nil
        guard BokehTransitionMetalContext.shared.availability.isReady,
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
            if hasAllFrames {
                let leadingW = leadingRenderedFrame?.logicalCanvasSize.width ?? 0
                let leadingH = leadingRenderedFrame?.logicalCanvasSize.height ?? 0
                print("[CoverBlur] prepare skipped despite all frames: metal=\(BokehTransitionMetalContext.shared.availability.isReady) viewport=\(bokehViewportSize) leadingSize=\(leadingW)x\(leadingH) tier=\(tier.rawValue)")
            }
            return
        }

        print("[CoverBlur] preparing Bokeh source set: cs=\(frames.leading.artworkChecksum) tier=\(tier.rawValue) isActive=\(isTransitionActive)")
        bokehSourcePreparer.prepare(
            frames: frames,
            renderSize: renderSize,
            tier: tier
        ) { sourceSet in
            bokehPreparedSourceSet = sourceSet
            if !isTransitionActive {
                bokehSourceSets[0] = sourceSet
            }
            // Do NOT swap mid-transition. The artwork swap is deferred to
            // retirement so it runs in the transitionTask (no separate
            // overlayFadeTask that can race a subsequent swap and cause the
            // disappear->flashback->fade flicker on rapid track switching) and
            // so the texture upload does not cause frame drops during the
            // position animation. At retirement the swap, blur decrease, and
            // overlay fade-out all start together.
        }
    }

    private func bokehSnapshot(for size: CGSize, surfaceIndex: Int) -> BokehTransitionSnapshot {
        let sourceSet = bokehSourceSets[surfaceIndex]
        let canvasRatio = sourceSet?.transitionCanvasSizeRatio ?? CGSize(width: 1, height: 1)
        return BokehTransitionSnapshot(
            transitionPosition: transitionPosition,
            centeredOpacity: centeredLayerOpacity,
            transitionOpacity: transitionLayerOpacity,
            bokehRadius: bokehRadius,
            surfaceOpacity: bokehSurfaceOpacity,
            opticalOpacity: bokehOpticalOpacities[surfaceIndex],
            transitionCanvasSizeRatio: canvasRatio,
            // A constant travel distance; Metal combines it with the animated
            // transitionPosition every frame. Sending the already-evaluated
            // offset here bypassed AnimatableData and caused a hard position cut.
            transitionCanvasOffsetRatio: size.width > 1 ? coverCenterShift(for: size) / size.width : 0,
            configuration: BokehTransitionConfig(),
            tier: sourceSet?.identity.tier ?? .balanced,
            reduceMotion: context.theme.reduceMotion
        )
    }

    private func transitionModeLabel(_ mode: BokehTransitionMode) -> String {
        switch mode {
        case .bokeh: return "bokeh"
        case .gaussianFallback: return "gaussian"
        case .unmaskedFallback: return "unmasked"
        }
    }

    private func selectTransitionMode() async -> BokehTransitionMode? {
        let metalAvailability = BokehTransitionMetalContext.shared.availability
        guard metalAvailability.isReady else {
            Log.info("CoverBlur transition: Gaussian (Metal unavailable: \(metalAvailability.reason ?? "unknown"))", category: .fullscreen)
            return .gaussianFallback(
                reason: metalAvailability.reason ?? "Bokeh enhancement unavailable"
            )
        }

        let tier = preferredBokehTier()
        if let sourceSet = bokehPreparedSourceSet {
            // A prepared source set is usable even if the performance policy
            // has since decided on a different tier; tier only affects sample
            // budget, and the shader reads the actual tier from the snapshot.
            // Rejecting here caused frequent Bokeh->Gaussian fallback when the
            // automatic quality policy oscillated between .low and .balanced.
            if sourceSet.identity.tier != tier {
                Log.debug("CoverBlur transition: tier mismatch, using prepared \(sourceSet.identity.tier.rawValue) source set while decision is \(tier.rawValue)", category: .fullscreen)
            }
            bokehSourceSets[0] = bokehPreparedSourceSet
            return .bokeh
        }

        prepareBokehSourcesIfPossible()
        let pollInterval: UInt64 = 16_000_000
        let preparationTimeout: UInt64 = 750_000_000
        var elapsed: UInt64 = 0

        while elapsed < preparationTimeout {
            guard await waitForTransitionStage(nanoseconds: pollInterval) else { return nil }
            elapsed += pollInterval

            if let sourceSet = bokehPreparedSourceSet {
                if sourceSet.identity.tier != tier {
                    Log.debug("CoverBlur transition: tier mismatch, using prepared \(sourceSet.identity.tier.rawValue) source set while decision is \(tier.rawValue)", category: .fullscreen)
                }
                bokehSourceSets[0] = sourceSet
                Log.debug("CoverBlur transition: Bokeh source became ready after \(elapsed / 1_000_000)ms", category: .fullscreen)
                return .bokeh
            }
        }

        Log.info("CoverBlur transition: Gaussian (source preparation timed out, tier=\(tier.rawValue))", category: .fullscreen)
        return .gaussianFallback(reason: "Bokeh source preparation timed out")
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
            ? .easeInOut(duration: 0.34)
            : .timingCurve(0.36, 0.0, 0.64, 1.0, duration: 0.72)
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
        transitionGeneration &+= 1
        let generation = transitionGeneration

        let targetPosition: CGFloat = targetCentered ? 1 : 0
        let shouldRetargetImmediately = isTransitionActive

        print("[CoverBlur] runLayoutTransition: target=\(targetPosition) pos=\(transitionPosition) isActive=\(isTransitionActive)")

        guard transitionPosition != targetPosition || isTransitionActive else {
            print("[CoverBlur] runLayoutTransition: guard returned, already at target")
            retireTransitionEffect()
            return
        }

        transitionTask = Task { @MainActor in
            if !shouldRetargetImmediately {
                guard let selectedMode = await selectTransitionMode() else { return }
                guard !Task.isCancelled, transitionGeneration == generation else { return }

                activeTransitionMode = selectedMode
                if activeTransitionMode.usesBokeh {
                    BokehTransitionPerformancePolicy.shared.begin(
                        tier: activeBokehSourceSet?.identity.tier ?? .balanced
                    )
                }
                Log.info("CoverBlur transition starting: mode=\(transitionModeLabel(activeTransitionMode)) target=\(targetPosition)", category: .fullscreen)
            }

            guard !Task.isCancelled, transitionGeneration == generation else { return }
            isTransitionActive = true
            startTransitionEffect()
            setTransitionLayerOpacity(1, rising: true)

            if shouldRetargetImmediately {
                retargetTransition(to: targetPosition)
            }

            if !shouldRetargetImmediately {
                // Start moving once the masking blur is roughly halfway up.
                guard await waitForTransitionStage(nanoseconds: 105_000_000) else { return }
                retargetTransition(to: targetPosition)
            }

            guard await waitForTransitionStage(nanoseconds: movementSettleDelay) else { return }

            setTransitionLayerOpacity(0, rising: false)

            guard await waitForTransitionStage(nanoseconds: 120_000_000) else { return }

            if activeTransitionMode.usesBokeh {
                // Use the live checksum (latestTrackArtworkChecksum) instead
                // of context.track, which is captured at task creation time
                // and can be stale if the track changed during the transition.
                let targetChecksum = latestTrackArtworkChecksum
                let activeChecksum = activeBokehSourceSet?.identity.artworkChecksum
                let artworkChanged = activeChecksum != nil
                    && activeChecksum != targetChecksum

                // Start the blur decrease IMMEDIATELY (user-requested timing:
                // position settles -> blur starts decreasing). The artwork
                // swap + overlay fade-out happen as soon as the new source set
                // is ready, which may be slightly after the blur starts
                // decreasing (source preparation is async). This is better
                // than skipping the swap entirely (which caused the hard-cut
                // "old artwork disappears, new artwork appears" the user saw
                // when the source set wasn't ready at a fixed check point).
                //
                // When the swap lands mid-blur-fall, the overlay snaps to
                // full opacity showing the OLD artwork - which is exactly
                // what was already visible on the base - so the snap is
                // invisible. The overlay then fades out, revealing the new
                // artwork underneath while the blur continues decreasing.
                withoutSwiftUIAnimation {
                    bokehRadius = 0
                    settledCenteredLayerOpacity = targetPosition
                }

                if artworkChanged {
                    print("[CoverBlur] retirement: polling for source set, active=\(activeChecksum ?? 0) target=\(targetChecksum) prepared=\(bokehPreparedSourceSet?.identity.artworkChecksum ?? 0)")
                    // Poll for the source set during the blur fall. When
                    // ready, swap + start the overlay fade-out.
                    let pollInterval: UInt64 = 16_000_000
                    var elapsed: UInt64 = 0
                    var swapped = false
                    while elapsed < bokehBlurFallDuration {
                        guard await waitForTransitionStage(nanoseconds: pollInterval) else { return }
                        elapsed += pollInterval
                        if let prepared = bokehPreparedSourceSet,
                           prepared.identity.artworkChecksum == targetChecksum {
                            print("[CoverBlur] retirement swap+fade at +\(elapsed / 1_000_000)ms: \(activeChecksum ?? 0) -> \(targetChecksum)")
                            let oldSourceSet = bokehSourceSets[0]
                            withoutSwiftUIAnimation {
                                bokehSourceSets[1] = oldSourceSet
                                bokehSourceSets[0] = prepared
                                bokehOpticalOpacities[0] = 1
                                bokehOpticalOpacities[1] = 0
                            }
                            swapped = true
                            break
                        }
                    }
                    if !swapped {
                        print("[CoverBlur] retirement: source set not ready within blur fall, no swap")
                    }
                    // Wait for the overlay fade-out to complete. If the swap
                    // happened late in the blur fall, the fade-out (0.60 s)
                    // may extend past the blur fall (0.78 s); wait for the
                    // longer of the two so the fade-out is not cut short by
                    // cleanup.
                    let remainingBlur = bokehBlurFallDuration > elapsed
                        ? bokehBlurFallDuration - elapsed : 0
                    let remainingFade = swapped ? bokehOverlayFadeDuration : 0
                    let waitNanos = max(remainingBlur, remainingFade)
                    if waitNanos > 0 {
                        guard await waitForTransitionStage(nanoseconds: waitNanos) else { return }
                    }
                } else {
                    // No artwork change; just wait for the blur fall.
                    guard await waitForTransitionStage(nanoseconds: bokehBlurFallDuration) else { return }
                }
            } else {
                retireTransitionEffect()
                guard await waitForTransitionStage(nanoseconds: transitionCompletionDelay) else { return }
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Gaussian/unmasked paths have no optical fade, so the settled
                // floor is synced here at retirement. For Bokeh this is a
                // no-op: the floor was already synced above.
                settledCenteredLayerOpacity = targetPosition
                bokehSurfaceOpacity = 0
                isTransitionActive = false
            }
            BokehTransitionPerformancePolicy.shared.finish()
            // Sync the base surface to the latest prepared source set for the
            // next transition and clear the overlay. Both optical opacities
            // are zeroed (the surfaces are dormant); the next
            // startTransitionEffect raises the base again.
            bokehSourceSets[0] = bokehPreparedSourceSet
            bokehSourceSets[1] = nil
            withoutSwiftUIAnimation {
                bokehOpticalOpacities[0] = 0
                bokehOpticalOpacities[1] = 0
            }
        }
    }

    private func startTransitionEffect() {
        switch activeTransitionMode {
        case .bokeh:
            transitionBlurRadius = 0
            withoutSwiftUIAnimation {
                bokehSurfaceOpacity = 1
                // Raise the base surface; ensure the overlay is dark. The
                // overlay hosts the old artwork during a fade-out and must
                // start hidden.
                bokehOpticalOpacities[0] = 1
                bokehOpticalOpacities[1] = 0
                bokehRadius = BokehTransitionConfig.defaultRadiusAt1080
            }
        case .gaussianFallback:
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehOpticalOpacities = [0, 0]
            withAnimation(blurRiseAnimation) {
                transitionBlurRadius = 44
            }
        case .unmaskedFallback:
            bokehRadius = 0
            bokehSurfaceOpacity = 0
            bokehOpticalOpacities = [0, 0]
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

    /// Matches the renderer's blur-fall duration (TimedTransitionScalar
    /// `.blurFall` curve: 0.78 s normal, 0.28 s reduce-motion). The retirement
    /// waits this long so the full blur decrease is visible before the surface
    /// is hidden.
    private var bokehBlurFallDuration: UInt64 {
        context.theme.reduceMotion ? 280_000_000 : 780_000_000
    }

    /// Matches the renderer's optical-opacity fade-out duration (0.60 s normal,
    /// 0.10 s reduce-motion). The retirement waits this long after the overlay
    /// swap so the fade-out is not cut short by cleanup.
    private var bokehOverlayFadeDuration: UInt64 {
        context.theme.reduceMotion ? 100_000_000 : 600_000_000
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
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    @AppStorage("skin.coverGradientBlur.maxBlurRadius") private var maxBlurRadius: Double = 1600
    @AppStorage("skin.coverGradientBlur.edgeFillMode") private var edgeFillMode: String = CoverEdgeFillMode.pixelStretch.rawValue
    @AppStorage("fullscreenDimmingIntensity") private var fullscreenDimmingIntensity: Double = 0.15

    private var currentEdgeFillMode: CoverEdgeFillMode {
        CoverEdgeFillMode(rawValue: edgeFillMode) ?? .pixelStretch
    }

    private var slidingKnobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return presentationStyle.primaryTextColor
        }
        return themeStore.accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            edgeFillModePicker

            blurRadiusSlider

            dimmingIntensitySlider
        }
        .padding(.vertical, presentationStyle.scaled(6))
    }

    private var edgeFillModePicker: some View {
        HStack(spacing: presentationStyle.scaled(8)) {
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

    private var blurRadiusSlider: some View {
        HStack(spacing: presentationStyle.scaled(12)) {
            Text("模糊半径")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: presentationStyle.scaled(84), alignment: .leading)

            Slider(value: $maxBlurRadius, in: 100...2500, step: 100)
                .tint(presentationStyle.selectedTextColor(accentColor: themeStore.accentColor))
                .frame(maxWidth: .infinity)

            Text("\(Int(maxBlurRadius))")
                .font(presentationStyle.rowValueFont)
                .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                .lineLimit(1)
                // Don't let the value collapse into an ellipsis on narrower settings windows.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .frame(minWidth: presentationStyle.scaled(52), alignment: .trailing)
        }
    }

    private var dimmingIntensitySlider: some View {
        HStack(spacing: presentationStyle.scaled(12)) {
            Text("背景压暗强度")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
                .frame(width: presentationStyle.scaled(84), alignment: .leading)

            Slider(value: $fullscreenDimmingIntensity, in: 0.0...0.5, step: 0.05)
                .tint(presentationStyle.selectedTextColor(accentColor: themeStore.accentColor))
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

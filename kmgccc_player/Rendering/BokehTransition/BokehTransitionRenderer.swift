//
//  BokehTransitionRenderer.swift
//  myPlayer2
//
//  Every frame draws the panorama for the cover's current position from one
//  square cover, then lens-blurs it. Both ends of the movement are exactly
//  the settled leading and centered panoramas, so there is no second source
//  to cross-fade and nothing to line up.
//

@preconcurrency import Metal
@preconcurrency import MetalKit
import Foundation
import MotionKit
import os
import QuartzCore

enum BokehTransitionMotionTiming {
    static let riseSeconds: TimeInterval = 0.34
    static let blurFallSeconds: TimeInterval = 0.78
    static let fadeInSeconds: TimeInterval = 0.08
    static let resumeSeconds: TimeInterval = 0.12
    static let artworkDissolveSeconds: TimeInterval = 0.60
    static let handoffFadeOutSeconds: TimeInterval = 0.30

    static func phaseSpec(
        duration: TimeInterval,
        token: MotionToken,
        tokens: MotionTokens
    ) -> MotionSpec {
        tokens.phaseSpec(for: token, duration: duration)
    }
}

private struct MotionTransitionScalar {
    private(set) var value: CGFloat
    private var state: MotionRetargetState?

    init(_ value: CGFloat) {
        self.value = value
    }

    var isAnimating: Bool { state != nil }

    mutating func advance(to time: CFTimeInterval) {
        guard var state else { return }
        let frame = state.advance(to: time)
        if state.isSettled(at: time, positionEpsilon: 0.0001, velocityEpsilon: 0.001) {
            snap(to: CGFloat(state.target))
            return
        }
        self.state = state
        value = CGFloat(frame.value)
    }

    mutating func retarget(
        to target: CGFloat,
        at time: CFTimeInterval,
        spec: MotionSpec,
        policy: MotionPolicy
    ) {
        advance(to: time)
        guard abs(target - value) > 0.0001 else {
            snap(to: target)
            return
        }

        guard let resolvedSpec = policy.resolve(spec) else {
            snap(to: target)
            return
        }

        var next = MotionRetargetState(
            value: Double(value),
            velocity: state?.velocity ?? 0,
            spec: resolvedSpec
        )
        next.retarget(to: Double(target), at: time)
        state = next
    }

    mutating func snap(to target: CGFloat) {
        value = target
        state = nil
    }
}

private struct BokehTransitionPresentation {
    var position: CGFloat
    /// Sampled on the radius clock.
    var radius: CGFloat
    var alpha: CGFloat
    var handoffComplete: Bool
}

private struct BokehTransitionPresentationState {
    private(set) var target = BokehTransitionSnapshot.inactive
    private var position = MotionTransitionScalar(0)
    private var radius = MotionTransitionScalar(0)
    private var handoffOpacity = MotionTransitionScalar(0)
    /// The renderer's own dissolve into the settled layer during the fall.
    private var settleOpacity = MotionTransitionScalar(1)
    private var settleStarted = false
    /// A moving surface that is still translucent would show the static
    /// layer beneath as a ghost, so the cover moves only once it is opaque.
    private var pendingPosition: CGFloat?
    private var positionReleased = false
    private var radiusSample: CGFloat = 0
    private var radiusTick: Int64 = .min

    mutating func retarget(to newTarget: BokehTransitionSnapshot, at time: CFTimeInterval) {
        // A dormant surface follows the visible static layout exactly, so it
        // activates from where the cover already is.
        if target.surfaceOpacity <= 0.5, newTarget.surfaceOpacity <= 0.5 {
            target = newTarget
            position = MotionTransitionScalar(newTarget.transitionPosition)
            radius = MotionTransitionScalar(newTarget.bokehRadius)
            handoffOpacity = MotionTransitionScalar(newTarget.handoffOpacity)
            settleOpacity = MotionTransitionScalar(1)
            settleStarted = false
            pendingPosition = nil
            positionReleased = false
            radiusSample = newTarget.bokehRadius
            radiusTick = .min
            return
        }
        let policy = newTarget.motionPolicy
        let tokens = newTarget.motionTokens

        if target.keepsSurfaceOpaque, !newTarget.keepsSurfaceOpaque {
            // The fall was interrupted by a new movement: become opaque
            // again before the cover moves on.
            settleOpacity.retarget(
                to: 1, at: time,
                spec: BokehTransitionMotionTiming.phaseSpec(
                    duration: BokehTransitionMotionTiming.resumeSeconds,
                    token: .contentReplacement, tokens: tokens
                ),
                policy: policy
            )
            settleStarted = false
            positionReleased = false
        } else if !target.keepsSurfaceOpaque, newTarget.keepsSurfaceOpaque {
            settleStarted = false
        }

        if abs(newTarget.transitionPosition - target.transitionPosition) > 0.0001
            || pendingPosition != nil {
            if positionReleased {
                retargetPosition(to: newTarget.transitionPosition, at: time, target: newTarget)
            } else {
                pendingPosition = newTarget.transitionPosition
            }
        }
        if abs(newTarget.bokehRadius - target.bokehRadius) > 0.0001 {
            let rising = newTarget.bokehRadius > target.bokehRadius
            radius.retarget(
                to: newTarget.bokehRadius,
                at: time,
                spec: BokehTransitionMotionTiming.phaseSpec(
                    duration: rising
                        ? BokehTransitionMotionTiming.riseSeconds
                        : BokehTransitionMotionTiming.blurFallSeconds,
                    token: .backgroundTransition,
                    tokens: tokens
                ),
                policy: policy
            )
        }
        if abs(newTarget.handoffOpacity - target.handoffOpacity) > 0.0001 {
            let rising = newTarget.handoffOpacity > target.handoffOpacity
            handoffOpacity.retarget(
                to: newTarget.handoffOpacity,
                at: time,
                spec: BokehTransitionMotionTiming.phaseSpec(
                    duration: rising
                        ? BokehTransitionMotionTiming.fadeInSeconds
                        : BokehTransitionMotionTiming.handoffFadeOutSeconds,
                    token: .contentReplacement,
                    tokens: tokens
                ),
                policy: policy
            )
        }
        target = newTarget
    }

    mutating func frame(at time: CFTimeInterval) -> BokehTransitionPresentation {
        radius.advance(to: time)
        handoffOpacity.advance(to: time)
        settleOpacity.advance(to: time)

        // The radius changes on its own coarse clock; a settled radius is
        // taken at once so the last step is never late.
        let tick = Int64((time * BokehTransitionConfig.radiusUpdatesPerSecond).rounded(.down))
        if tick != radiusTick || !radius.isAnimating {
            radiusTick = tick
            radiusSample = radius.value
        }

        let visibility = target.keepsSurfaceOpaque
            ? 1
            : BokehTransitionConfig.opticalVisibility(forRadiusAt1080: radius.value)
        if let pendingPosition,
           visibility >= 0.999, handoffOpacity.value >= 0.999, settleOpacity.value >= 0.999 {
            positionReleased = true
            self.pendingPosition = nil
            retargetPosition(to: pendingPosition, at: time, target: target)
        }
        position.advance(to: time)

        if target.keepsSurfaceOpaque, !settleStarted,
           radius.value < CGFloat(BokehTransitionConfig.handoffRadiusAt1080) {
            settleStarted = true
            settleOpacity.retarget(
                to: 0, at: time,
                spec: BokehTransitionMotionTiming.phaseSpec(
                    duration: BokehTransitionMotionTiming.handoffFadeOutSeconds,
                    token: .contentReplacement, tokens: target.motionTokens
                ),
                policy: target.motionPolicy
            )
        }

        let alpha = handoffOpacity.value * settleOpacity.value * visibility
        return BokehTransitionPresentation(
            position: position.value,
            radius: radiusSample,
            alpha: min(max(alpha, 0), 1),
            handoffComplete: target.keepsSurfaceOpaque && settleStarted && !settleOpacity.isAnimating
        )
    }

    private mutating func retargetPosition(
        to value: CGFloat,
        at time: CFTimeInterval,
        target: BokehTransitionSnapshot
    ) {
        if target.motionPolicy != .full {
            position.snap(to: value)
        } else {
            position.retarget(
                to: value, at: time,
                spec: target.motionTokens[.backgroundTransition],
                policy: .full
            )
        }
    }
}

/// Reported to SwiftUI only when the value changes.
struct BokehTransitionSurfaceState: Equatable, Sendable {
    /// The surface fully covers the layers beneath it.
    var isOpaque = false
    /// The fall's dissolve into the settled layer has finished.
    var handoffComplete = false
}

/// Per-surface resource owner. It keeps allocations outside the hot frame
/// path and accepts only immutable SwiftUI snapshots during animation.
@MainActor
final class BokehTransitionRenderer: NSObject, MTKViewDelegate {
    private nonisolated final class TextureBox: @unchecked Sendable {
        let texture: MTLTexture
        init(_ texture: MTLTexture) { self.texture = texture }
    }

    private nonisolated struct ImageBox: @unchecked Sendable {
        let image: CGImage
    }

    private struct Intermediates {
        let width: Int
        let height: Int
        let panorama: MTLTexture
        let prepared: MTLTexture
        let bokeh: MTLTexture
    }

    /// Everything a frame's pixels depend on. An unchanged key reuses the
    /// presented drawable.
    private struct FrameKey: Equatable {
        var coverX0: Int
        var radius: Int
        var coverRevision: UInt64
        var dissolve: Int
        var width: Int
        var height: Int
        var viewport: SIMD2<Int>
    }

    private let context = BokehTransitionMetalContext.shared
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kmgccc.player",
        category: "BokehTransition"
    )
    private let inFlight = DispatchSemaphore(value: 2)

    private var live: CoverProgressiveBlurRenderer.Live?
    private var sourceSet: BokehTransitionSourceSet?
    private var cover: MTLTexture?
    private var previousCover: MTLTexture?
    private var dissolve = MotionTransitionScalar(0)
    private var coverRevision: UInt64 = 0
    private var uploadGeneration: UInt64 = 0
    private var feedGenerationConsumed: UInt64 = 0
    private var feedUploadInFlight = false
    private var intermediates: Intermediates?
    private var snapshot = BokehTransitionSnapshot.inactive
    private var presentationState = BokehTransitionPresentationState()
    private var lastFrameKey: FrameKey?
    private var surfaceState = BokehTransitionSurfaceState()
    private var diagnosticFrameCount = 0
    private(set) var failureReason: String?

    /// Latest video frames; replaces the cover while the transition runs.
    var liveFeed: BokehLiveCoverFeed?
    var onSurfaceStateChange: ((BokehTransitionSurfaceState) -> Void)?

    var isAvailable: Bool {
        context.availability.isReady && liveRenderer() != nil
    }

    func update(snapshot: BokehTransitionSnapshot) {
        let wasActive = self.snapshot.isActive
        self.snapshot = snapshot
        presentationState.retarget(to: snapshot, at: CACurrentMediaTime())
        if !snapshot.isActive {
            lastFrameKey = nil
            if wasActive { reportSurfaceState(BokehTransitionSurfaceState()) }
        }
    }

    func isReady(for identity: BokehTransitionSourceIdentity) -> Bool {
        sourceSet?.identity == identity && cover != nil
    }

    var hasCover: Bool { sourceSet != nil && cover != nil }

    /// Converts the cover off the display's main-actor clock. A different
    /// artwork arriving while the surface draws dissolves in from the old
    /// cover inside the same panorama.
    @discardableResult
    func install(_ newSourceSet: BokehTransitionSourceSet) async -> Bool {
        guard let live = liveRenderer() else {
            failureReason = "Bokeh renderer unavailable"
            return false
        }
        uploadGeneration &+= 1
        let generation = uploadGeneration
        let side = Self.coverSide(for: newSourceSet.identity, image: newSourceSet.cover)
        let image = ImageBox(image: newSourceSet.cover)
        let operation = Task.detached(priority: .userInitiated) { () -> TextureBox? in
            autoreleasepool {
                guard !Task.isCancelled,
                      let texture = live.makeCoverTexture(image.image, side: side) else { return nil }
                return TextureBox(texture)
            }
        }
        let uploaded = await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        guard !Task.isCancelled, uploadGeneration == generation else { return false }
        guard let uploaded else {
            failureReason = "Cover upload failed"
            logger.error("Bokeh cover upload failed")
            return false
        }

        let changesArtwork = sourceSet.map {
            $0.identity.artworkChecksum != newSourceSet.identity.artworkChecksum
        } ?? false
        if changesArtwork, snapshot.isActive, let cover {
            previousCover = cover
            dissolve.snap(to: 1)
            dissolve.retarget(
                to: 0, at: CACurrentMediaTime(),
                spec: BokehTransitionMotionTiming.phaseSpec(
                    duration: BokehTransitionMotionTiming.artworkDissolveSeconds,
                    token: .contentReplacement, tokens: snapshot.motionTokens
                ),
                policy: snapshot.motionPolicy
            )
        } else if changesArtwork {
            previousCover = nil
            dissolve.snap(to: 0)
        }
        if sourceSet?.identity.renderSize != newSourceSet.identity.renderSize {
            intermediates = nil
        }
        sourceSet = newSourceSet
        cover = uploaded.texture
        coverRevision &+= 1
        // A video's latest frame, even a paused one, replaces the poster.
        feedGenerationConsumed = 0
        failureReason = nil
        return true
    }

    func releaseTextures() {
        uploadGeneration &+= 1
        sourceSet = nil
        cover = nil
        previousCover = nil
        dissolve.snap(to: 0)
        intermediates = nil
        lastFrameKey = nil
        live?.releaseResources()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastFrameKey = nil
    }

    func draw(in view: MTKView) {
        guard snapshot.isActive,
              let live = liveRenderer(),
              let commandQueue = context.commandQueue,
              let preparePipeline = context.preparePipeline,
              let gatherPipeline = context.gatherPipeline,
              let presentPipeline = context.presentPipeline,
              let sourceSet else {
            return
        }

        let time = CACurrentMediaTime()
        pollLiveFeed(live: live, sourceSet: sourceSet)
        let presentation = presentationState.frame(at: time)
        dissolve.advance(to: time)
        if !dissolve.isAnimating, dissolve.value <= 0.0001 { previousCover = nil }

        // Opacity follows the display clock even when the pixels do not.
        view.alphaValue = presentation.alpha
        reportSurfaceState(BokehTransitionSurfaceState(
            isOpaque: presentation.alpha >= 0.999,
            handoffComplete: presentation.handoffComplete
        ))

        guard let cover else { return }
        let width = sourceSet.identity.renderSize.width
        let height = sourceSet.identity.renderSize.height
        // The square cover fills the height and position 1 centers it, both
        // in view points: the drawable's rounded size stretches onto the view
        // by a hair, and the cover must stay exactly as wide as it is tall.
        let viewport = view.bounds.width > 1 && view.bounds.height > 1
            ? view.bounds.size
            : sourceSet.identity.logicalViewportSize
        let pixelsPerPoint = Double(width) / max(1, Double(viewport.width))
        let coverSide = Double(viewport.height) * pixelsPerPoint
        let coverX0 = Double(presentation.position)
            * Double(viewport.width - viewport.height) * 0.5 * pixelsPerPoint
        let key = FrameKey(
            coverX0: Int((coverX0 * 8).rounded()),
            radius: Int((presentation.radius * 100).rounded()),
            coverRevision: coverRevision,
            dissolve: Int((dissolve.value * 1000).rounded()),
            width: width,
            height: height,
            viewport: SIMD2(Int((viewport.width * 4).rounded()), Int((viewport.height * 4).rounded()))
        )
        guard key != lastFrameKey else { return }

        guard inFlight.wait(timeout: .now()) == .success else {
            BokehTransitionPerformancePolicy.shared.recordDroppedFrame()
            return
        }
        guard let intermediates = makeIntermediates(width: width, height: height),
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        commandBuffer.label = "Fullscreen Cover Bokeh Transition"

        let style = sourceSet.style
        let coverX1 = coverX0 + coverSide
        let progress = Double(presentation.position)
        let frame = CoverProgressiveBlurRenderer.LiveFrame(
            pixelWidth: width,
            pixelHeight: height,
            pixelsPerPoint: pixelsPerPoint,
            coverX0: coverX0,
            coverSide: coverSide,
            edgeFill: style.edgeFill,
            profile: progress < 0.5 ? style.leading : style.centered,
            lut: CoverProgressiveBlurProfile.transitionLUT(
                leading: style.leading,
                centered: style.centered,
                progress: progress,
                width: width,
                coverX0: coverX0,
                coverX1: coverX1,
                pixelsPerPoint: pixelsPerPoint
            ),
            overlay: style.overlay,
            overlayLeftWeight: Float(min(max(progress, 0), 1))
        )
        guard live.encode(
            frame,
            cover: cover,
            previousCover: previousCover,
            previousWeight: Float(dissolve.value),
            output: intermediates.panorama,
            into: commandBuffer
        ) else {
            inFlight.signal()
            failureReason = "Unable to encode the transition panorama"
            return
        }

        var bokehUniforms = TransitionBokehUniforms(
            radiusAt1080: Float(presentation.radius),
            highlightPower: Float(BokehTransitionConfig.defaultHighlightPower),
            highlightThreshold: Float(BokehTransitionConfig.defaultHighlightThreshold),
            sampleBudget: snapshot.tier.sampleBudget,
            apertureBlades: BokehTransitionConfig.defaultApertureBlades,
            apertureRotationRadians: Float(BokehTransitionConfig.defaultApertureRotationRadians),
            apertureRoundness: Float(BokehTransitionConfig.defaultApertureRoundness)
        )

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Bokeh source"
            encoder.setComputePipelineState(preparePipeline)
            encoder.setTexture(intermediates.panorama, index: 0)
            encoder.setTexture(intermediates.prepared, index: 1)
            encoder.setBytes(&bokehUniforms, length: MemoryLayout<TransitionBokehUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: preparePipeline, width: width, height: height)
            encoder.endEncoding()
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "Bokeh source levels"
            blit.generateMipmaps(for: intermediates.prepared)
            blit.endEncoding()
        }
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Basic Bokeh gather"
            encoder.setComputePipelineState(gatherPipeline)
            encoder.setTexture(intermediates.prepared, index: 0)
            encoder.setTexture(intermediates.bokeh, index: 1)
            encoder.setTexture(intermediates.panorama, index: 2)
            encoder.setBytes(&bokehUniforms, length: MemoryLayout<TransitionBokehUniforms>.stride, index: 0)
            dispatch(
                encoder, pipeline: gatherPipeline,
                width: intermediates.bokeh.width, height: intermediates.bokeh.height
            )
            encoder.endEncoding()
        }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            encoder.label = "Bokeh transition present"
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(intermediates.bokeh, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        let completionSemaphore = inFlight
        commandBuffer.addCompletedHandler { [weak self, completionSemaphore] buffer in
            // Return the permit on the Metal completion thread. The renderer
            // may be dismantled before its main-actor metrics task runs.
            completionSemaphore.signal()
            let gpuSeconds = buffer.gpuEndTime - buffer.gpuStartTime
            Task { @MainActor [weak self] in
                self?.recordCompletedFrame(gpuSeconds: gpuSeconds)
            }
        }
        commandBuffer.commit()
        lastFrameKey = key

        diagnosticFrameCount &+= 1
        if diagnosticFrameCount % 12 == 0 {
            DebugUIHooks.record(String(
                format: "bokeh-frame pos=%.3f radius=%.1f alpha=%.2f dissolve=%.2f size=%dx%d keeps=%d",
                presentation.position,
                presentation.radius,
                presentation.alpha,
                dissolve.value,
                width,
                height,
                snapshot.keepsSurfaceOpaque ? 1 : 0
            ))
        }
    }

    // MARK: - Resources

    private func liveRenderer() -> CoverProgressiveBlurRenderer.Live? {
        if let live { return live }
        guard let device = context.device else { return nil }
        live = CoverProgressiveBlurRenderer.Live(device: device)
        return live
    }

    /// A cover never needs more pixels than the panorama draws it with.
    private nonisolated static func coverSide(
        for identity: BokehTransitionSourceIdentity,
        image: CGImage
    ) -> Int {
        max(8, min(identity.renderSize.height, min(image.width, image.height)))
    }

    /// Uploads the newest video frame off the main actor; frames arriving
    /// meanwhile are skipped, never queued.
    private func pollLiveFeed(
        live: CoverProgressiveBlurRenderer.Live,
        sourceSet: BokehTransitionSourceSet
    ) {
        guard !feedUploadInFlight,
              let frame = liveFeed?.latest(),
              frame.generation != feedGenerationConsumed,
              frame.artworkChecksum == sourceSet.identity.artworkChecksum else { return }
        feedGenerationConsumed = frame.generation
        feedUploadInFlight = true
        let generation = uploadGeneration
        let side = Self.coverSide(for: sourceSet.identity, image: frame.image)
        let image = ImageBox(image: frame.image)
        let checksum = frame.artworkChecksum
        Task { @MainActor [weak self] in
            let uploaded = await Task.detached(priority: .userInitiated) { () -> TextureBox? in
                autoreleasepool {
                    live.makeCoverTexture(image.image, side: side).map(TextureBox.init)
                }
            }.value
            guard let self else { return }
            self.feedUploadInFlight = false
            guard self.uploadGeneration == generation,
                  self.sourceSet?.identity.artworkChecksum == checksum,
                  let uploaded else { return }
            self.cover = uploaded.texture
            self.coverRevision &+= 1
        }
    }

    private func makeIntermediates(width: Int, height: Int) -> Intermediates? {
        if let intermediates, intermediates.width == width, intermediates.height == height {
            return intermediates
        }
        guard let device = context.device else { return nil }
        func texture(width: Int, height: Int, mipmapped: Bool) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: mipmapped
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        // The gather writes half the panorama's size; present enlarges it.
        guard let panorama = texture(width: width, height: height, mipmapped: false),
              let prepared = texture(width: width, height: height, mipmapped: true),
              let bokeh = texture(
                  width: max(1, (width + 1) / 2), height: max(1, (height + 1) / 2), mipmapped: false
              ) else {
            failureReason = "Unable to allocate Bokeh intermediate textures"
            return nil
        }
        let made = Intermediates(
            width: width, height: height, panorama: panorama, prepared: prepared, bokeh: bokeh
        )
        intermediates = made
        DebugUIHooks.record(
            "bokeh-intermediates \(width)x\(height) "
            + "bytes=\(panorama.allocatedSize + prepared.allocatedSize + bokeh.allocatedSize)"
        )
        return made
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = min(16, pipeline.threadExecutionWidth)
        let threadHeight = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    private func reportSurfaceState(_ state: BokehTransitionSurfaceState) {
        guard state != surfaceState else { return }
        surfaceState = state
        onSurfaceStateChange?(state)
    }

    private func recordCompletedFrame(gpuSeconds: Double) {
        BokehTransitionPerformancePolicy.shared.recordGPUFrame(gpuSeconds)
    }
}

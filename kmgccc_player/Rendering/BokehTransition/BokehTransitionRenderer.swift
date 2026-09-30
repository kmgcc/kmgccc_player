//
//  BokehTransitionRenderer.swift
//  myPlayer2
//

@preconcurrency import Metal
@preconcurrency import MetalKit
import Foundation
import MotionKit
import os
import QuartzCore

private enum BokehMotion {
    static func phase(
        duration: CFTimeInterval,
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

    mutating func advance(to time: CFTimeInterval) {
        guard var state else { return }
        let frame = state.advance(to: time)
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
        guard abs(target - value) > 0.0001 else { return }

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

private struct BokehTransitionPresentationState {
    private(set) var target = BokehTransitionSnapshot.inactive
    private var position = MotionTransitionScalar(0)
    private var centeredOpacity = MotionTransitionScalar(0)
    private var transitionOpacity = MotionTransitionScalar(0)
    private var radius = MotionTransitionScalar(0)
    private var opticalOpacity = MotionTransitionScalar(0)
    private var handoffOpacity = MotionTransitionScalar(0)

    mutating func retarget(to newTarget: BokehTransitionSnapshot, at time: CFTimeInterval) {
        // Keep the dormant renderer exactly aligned with whichever static layout
        // is currently visible. Otherwise a surface first activated from the
        // centered state would animate internally from the default leading state.
        if target.surfaceOpacity <= 0.5, newTarget.surfaceOpacity <= 0.5 {
            target = newTarget
            position = MotionTransitionScalar(newTarget.transitionPosition)
            centeredOpacity = MotionTransitionScalar(newTarget.centeredOpacity)
            transitionOpacity = MotionTransitionScalar(newTarget.transitionOpacity)
            radius = MotionTransitionScalar(newTarget.bokehRadius)
            opticalOpacity = MotionTransitionScalar(newTarget.opticalOpacity)
            handoffOpacity = MotionTransitionScalar(newTarget.handoffOpacity)
            return
        }
        let motionPolicy = newTarget.motionPolicy
        let reducedMotion = motionPolicy != .full
        if abs(newTarget.transitionPosition - target.transitionPosition) > 0.0001 {
            position.retarget(
                to: newTarget.transitionPosition,
                at: time,
                spec: newTarget.motionTokens[.backgroundTransition],
                policy: reducedMotion ? .disabled : .full
            )
        }
        if abs(newTarget.centeredOpacity - target.centeredOpacity) > 0.0001 {
            centeredOpacity.retarget(
                to: newTarget.centeredOpacity,
                at: time,
                spec: BokehMotion.phase(
                    duration: 0.72,
                    token: .backgroundTransition,
                    tokens: newTarget.motionTokens
                ),
                policy: motionPolicy
            )
        }
        if abs(newTarget.transitionOpacity - target.transitionOpacity) > 0.0001 {
            let rising = newTarget.transitionOpacity > target.transitionOpacity
            transitionOpacity.retarget(
                to: newTarget.transitionOpacity,
                at: time,
                spec: BokehMotion.phase(
                    duration: rising ? 0.08 : 0.42,
                    token: .contentReplacement,
                    tokens: newTarget.motionTokens
                ),
                policy: motionPolicy
            )
        }
        if abs(newTarget.bokehRadius - target.bokehRadius) > 0.0001 {
            let rising = newTarget.bokehRadius > target.bokehRadius
            radius.retarget(
                to: newTarget.bokehRadius,
                at: time,
                spec: BokehMotion.phase(
                    duration: rising ? 0.34 : 0.78,
                    token: .backgroundTransition,
                    tokens: newTarget.motionTokens
                ),
                policy: motionPolicy
            )
        }
        if abs(newTarget.opticalOpacity - target.opticalOpacity) > 0.0001 {
            let rising = newTarget.opticalOpacity > target.opticalOpacity
            opticalOpacity.retarget(
                to: newTarget.opticalOpacity,
                at: time,
                spec: BokehMotion.phase(
                    duration: rising ? 0.08 : 0.60,
                    token: .contentReplacement,
                    tokens: newTarget.motionTokens
                ),
                policy: motionPolicy
            )
        }
        if abs(newTarget.handoffOpacity - target.handoffOpacity) > 0.0001 {
            let rising = newTarget.handoffOpacity > target.handoffOpacity
            handoffOpacity.retarget(
                to: newTarget.handoffOpacity,
                at: time,
                spec: BokehMotion.phase(
                    duration: rising ? 0.08 : 0.60,
                    token: .contentReplacement,
                    tokens: newTarget.motionTokens
                ),
                policy: motionPolicy
            )
        }
        target = newTarget
    }

    /// Snap layout values to the current target and prepare the optical
    /// opacity for an instant-appear-then-fade-out. Called when a new source
    /// set is installed so:
    ///  1. The first draw does not animate from stale dormant position values
    ///     (which caused the new artwork to flash to a wrong position).
    ///  2. The overlay surface appears at full opacity instantly (no fade-in)
    ///     and, if the target opacity is below full, immediately begins fading
    ///     out - all in a single update, so the blur decrease and the overlay
    ///     fade-out start on the same frame.
    /// The blur radius is intentionally left alone so an in-flight blur
    /// animation is not interrupted.
    mutating func snapAfterInstall(
        targetOpticalOpacity: CGFloat,
        motionPolicy: MotionPolicy,
        at time: CFTimeInterval
    ) {
        let t = target
        position = MotionTransitionScalar(t.transitionPosition)
        centeredOpacity = MotionTransitionScalar(t.centeredOpacity)
        transitionOpacity = MotionTransitionScalar(t.transitionOpacity)
        // Snap to full so the surface is visible immediately (no fade-in).
        opticalOpacity = MotionTransitionScalar(1)
        // If the target is below full, set up the fade-out animation from
        // full to the target in the same update.
        if targetOpticalOpacity < 0.999 {
            opticalOpacity.retarget(
                to: targetOpticalOpacity,
                at: time,
                spec: BokehMotion.phase(
                    duration: 0.60,
                    token: .contentReplacement,
                    tokens: t.motionTokens
                ),
                policy: motionPolicy
            )
        }
    }

    mutating func snapshot(at time: CFTimeInterval) -> BokehTransitionSnapshot {
        if target.motionPolicy != .full {
            position.snap(to: target.transitionPosition)
        } else {
            position.advance(to: time)
        }
        centeredOpacity.advance(to: time)
        transitionOpacity.advance(to: time)
        radius.advance(to: time)
        opticalOpacity.advance(to: time)
        handoffOpacity.advance(to: time)
        var result = target
        result.transitionPosition = position.value
        result.centeredOpacity = centeredOpacity.value
        result.transitionOpacity = transitionOpacity.value
        result.bokehRadius = radius.value
        result.opticalOpacity = opticalOpacity.value
        result.handoffOpacity = handoffOpacity.value
        return result
    }
}

struct BokehTransitionRendererMetrics: Sendable {
    fileprivate(set) var completedFrames = 0
    fileprivate(set) var droppedFrames = 0
    fileprivate(set) var lastGPUSeconds: Double = 0
    fileprivate(set) var p95GPUSeconds: Double = 0
}

/// Per-surface resource owner. It keeps all allocations outside the hot frame
/// path and accepts only immutable SwiftUI snapshots during animation.
@MainActor
final class BokehTransitionRenderer: NSObject, MTKViewDelegate {
    private final class SourceTextures {
        let identity: BokehTransitionSourceIdentity
        let leading: MTLTexture
        let centered: MTLTexture
        let transition: MTLTexture
        let transitionCanvasSizeRatio: CGSize

        init(
            identity: BokehTransitionSourceIdentity,
            leading: MTLTexture,
            centered: MTLTexture,
            transition: MTLTexture,
            transitionCanvasSizeRatio: CGSize
        ) {
            self.identity = identity
            self.leading = leading
            self.centered = centered
            self.transition = transition
            self.transitionCanvasSizeRatio = transitionCanvasSizeRatio
        }
    }

    private struct IntermediateTextures {
        let size: MTLSize
        let composed: MTLTexture
        let bokeh: MTLTexture
    }

    private let context = BokehTransitionMetalContext.shared
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kmgccc.player",
        category: "BokehTransition"
    )
    private let sourceLock = NSLock()
    private let metricsLock = NSLock()
    private let inFlight = DispatchSemaphore(value: 2)

    private var sources: SourceTextures?
    private var intermediateTextures: IntermediateTextures?
    private var snapshot = BokehTransitionSnapshot.inactive
    private var presentationState = BokehTransitionPresentationState()
    /// Set by `install` so the next `update` snaps layout/opacity to the new
    /// target instead of animating from stale dormant values.
    private var needsSnapAfterInstall = false
    private var gpuSamples: [Double] = []
    private var rendererMetrics = BokehTransitionRendererMetrics()
    private(set) var failureReason: String?

    var isAvailable: Bool {
        if case .ready = context.availability { return true }
        return false
    }

    var metrics: BokehTransitionRendererMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return rendererMetrics
    }

    func update(snapshot: BokehTransitionSnapshot) {
        self.snapshot = snapshot
        let time = CACurrentMediaTime()
        presentationState.retarget(to: snapshot, at: time)
        if needsSnapAfterInstall {
            presentationState.snapAfterInstall(
                targetOpticalOpacity: snapshot.opticalOpacity,
                motionPolicy: snapshot.motionPolicy,
                at: time
            )
            needsSnapAfterInstall = false
        }
    }

    func isReady(for identity: BokehTransitionSourceIdentity) -> Bool {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        return sources?.identity == identity
    }

    /// Uploads a complete source set as one replacement. Called before a user
    /// transition, never from `draw(in:)`; a previous complete set stays live
    /// until all three textures have succeeded.
    func install(_ sourceSet: BokehTransitionPreparedSourceSet) {
        guard let device = context.device else {
            failureReason = "No Metal device"
            return
        }

        do {
            let loader = MTKTextureLoader(device: device)
            let options: [MTKTextureLoader.Option: Any] = [
                // Keep source bytes sRGB-encoded. The shader uses the same
                // explicit transfer function as the original SPBokeh engine.
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
            ]
            let uploaded = SourceTextures(
                identity: sourceSet.identity,
                leading: try loader.newTexture(cgImage: sourceSet.leading, options: options),
                centered: try loader.newTexture(cgImage: sourceSet.centered, options: options),
                transition: try loader.newTexture(cgImage: sourceSet.transition, options: options),
                transitionCanvasSizeRatio: sourceSet.transitionCanvasSizeRatio
            )
            sourceLock.lock()
            sources = uploaded
            sourceLock.unlock()
            // Snap layout/opacity to the current target on the next update so
            // the first frame after a source set change does not animate from
            // stale dormant values (position flash on the new artwork).
            needsSnapAfterInstall = true
            failureReason = nil
            #if DEBUG
            logger.debug("Bokeh source textures uploaded for \(sourceSet.identity.artworkChecksum, privacy: .public)")
            #endif
        } catch {
            failureReason = "Texture upload failed: \(error.localizedDescription)"
            logger.error("Bokeh texture upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func releaseTextures() {
        sourceLock.lock()
        sources = nil
        sourceLock.unlock()
        intermediateTextures = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // `BokehTransitionView` keeps this low-resolution and stable during a
        // transition. Drop intermediates only when the next source set changes
        // the size, never in response to a full-resolution view bounds update.
        if Int(size.width) == 0 || Int(size.height) == 0 {
            intermediateTextures = nil
        }
    }

    func draw(in view: MTKView) {
        guard snapshot.isActive,
              let device = context.device,
              let commandQueue = context.commandQueue,
              let composePipeline = context.composePipeline,
              let gatherPipeline = context.gatherPipeline,
              let presentPipeline = context.presentPipeline else {
            return
        }

        sourceLock.lock()
        let sourceTextures = sources
        sourceLock.unlock()
        guard let sourceTextures,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        guard inFlight.wait(timeout: .now()) == .success else {
            recordDroppedFrame()
            return
        }

        guard let intermediate = makeIntermediateTextures(
            device: device,
            size: MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1)
        ) else {
            inFlight.signal()
            failureReason = "Unable to allocate Bokeh intermediate textures"
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            failureReason = "Unable to create Bokeh command buffer"
            return
        }
        commandBuffer.label = "Fullscreen Cover Bokeh Transition"

        let presentation = presentationState.snapshot(at: CACurrentMediaTime())
        // On rise (and artwork-swap fall) the radius envelope prevents an
        // unblurred low-resolution frame. Same-artwork layout transitions
        // switch to the timed handoff exactly around radius 8, allowing its
        // last faint opacity to continue briefly after radius zero.
        let usesTimedHandoff = snapshot.handoffOpacity < 0.999
        let radiusVisibility = usesTimedHandoff
            ? 1
            : BokehTransitionConfig.opticalVisibility(
                forRadiusAt1080: presentation.bokehRadius
            )
        view.alphaValue = presentation.opticalOpacity
            * presentation.handoffOpacity
            * radiusVisibility
        let canvasRatio = presentation.transitionCanvasSizeRatio
        var composeUniforms = TransitionComposeUniforms(
            viewportSize: SIMD2(Float(intermediate.size.width), Float(intermediate.size.height)),
            transitionCanvasSizeRatio: SIMD2(Float(canvasRatio.width), Float(canvasRatio.height)),
            transitionCanvasOffsetRatio: SIMD2(Float(presentation.transitionCanvasOffsetRatio), 0),
            transitionPosition: Float(presentation.transitionPosition),
            centeredOpacity: Float(presentation.centeredOpacity),
            transitionOpacity: Float(presentation.transitionOpacity)
        )
        var bokehUniforms = TransitionBokehUniforms(
            radiusAt1080: Float(presentation.bokehRadius),
            highlightPower: Float(BokehTransitionConfig.defaultHighlightPower),
            highlightThreshold: Float(BokehTransitionConfig.defaultHighlightThreshold),
            sampleBudget: presentation.tier.sampleBudget,
            apertureBlades: BokehTransitionConfig.defaultApertureBlades,
            apertureRotationRadians: Float(BokehTransitionConfig.defaultApertureRotationRadians),
            apertureRoundness: Float(BokehTransitionConfig.defaultApertureRoundness)
        )

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Bokeh transition composition"
            encoder.setComputePipelineState(composePipeline)
            encoder.setTexture(sourceTextures.leading, index: 0)
            encoder.setTexture(sourceTextures.centered, index: 1)
            encoder.setTexture(sourceTextures.transition, index: 2)
            encoder.setTexture(intermediate.composed, index: 3)
            encoder.setBytes(&composeUniforms, length: MemoryLayout<TransitionComposeUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: composePipeline, width: intermediate.size.width, height: intermediate.size.height)
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Basic Bokeh gather"
            encoder.setComputePipelineState(gatherPipeline)
            encoder.setTexture(intermediate.composed, index: 0)
            encoder.setTexture(intermediate.bokeh, index: 1)
            encoder.setBytes(&bokehUniforms, length: MemoryLayout<TransitionBokehUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: gatherPipeline, width: intermediate.size.width, height: intermediate.size.height)
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            encoder.label = "Bokeh transition present"
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(intermediate.bokeh, index: 0)
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
    }

    private func makeIntermediateTextures(device: MTLDevice, size: MTLSize) -> IntermediateTextures? {
        if let existing = intermediateTextures,
           existing.size.width == size.width,
           existing.size.height == size.height {
            return existing
        }

        let composedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        composedDescriptor.usage = [.shaderRead, .shaderWrite]
        composedDescriptor.storageMode = .private

        let bokehDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        bokehDescriptor.usage = [.shaderRead, .shaderWrite]
        bokehDescriptor.storageMode = .private
        guard let composed = device.makeTexture(descriptor: composedDescriptor),
              let bokeh = device.makeTexture(descriptor: bokehDescriptor) else {
            return nil
        }
        let intermediate = IntermediateTextures(size: size, composed: composed, bokeh: bokeh)
        intermediateTextures = intermediate
        return intermediate
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

    private func recordDroppedFrame() {
        metricsLock.lock()
        rendererMetrics.droppedFrames += 1
        metricsLock.unlock()
        BokehTransitionPerformancePolicy.shared.recordDroppedFrame()
    }

    private func recordCompletedFrame(gpuSeconds: Double) {
        metricsLock.lock()
        rendererMetrics.completedFrames += 1
        rendererMetrics.lastGPUSeconds = max(0, gpuSeconds)
        if gpuSeconds > 0 {
            gpuSamples.append(gpuSeconds)
            if gpuSamples.count > 120 { gpuSamples.removeFirst(gpuSamples.count - 120) }
            let sorted = gpuSamples.sorted()
            let p95Index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))
            rendererMetrics.p95GPUSeconds = sorted[p95Index]
        }
        metricsLock.unlock()
        BokehTransitionPerformancePolicy.shared.recordGPUFrame(gpuSeconds)
    }
}

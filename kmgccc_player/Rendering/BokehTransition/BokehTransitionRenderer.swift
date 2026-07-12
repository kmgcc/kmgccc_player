//
//  BokehTransitionRenderer.swift
//  myPlayer2
//

@preconcurrency import Metal
@preconcurrency import MetalKit
import Foundation
import os
import QuartzCore

private struct TimedTransitionScalar {
    enum Curve {
        case easeInOut
        case blurRise
        case blurFall
        case background
        case layerFadeIn
        case layerFadeOut
    }

    private(set) var value: CGFloat
    private var startValue: CGFloat
    private var targetValue: CGFloat
    private var startTime: CFTimeInterval
    private var duration: CFTimeInterval
    private var curve: Curve

    init(_ value: CGFloat) {
        self.value = value
        startValue = value
        targetValue = value
        startTime = 0
        duration = 0
        curve = .easeInOut
    }

    mutating func advance(to time: CFTimeInterval) {
        guard duration > 0 else {
            value = targetValue
            return
        }
        let progress = CGFloat(min(max((time - startTime) / duration, 0), 1))
        value = startValue + (targetValue - startValue) * curve.value(at: progress)
        if progress >= 1 {
            startValue = targetValue
            duration = 0
        }
    }

    mutating func retarget(
        to target: CGFloat,
        at time: CFTimeInterval,
        duration newDuration: CFTimeInterval,
        curve newCurve: Curve
    ) {
        advance(to: time)
        guard abs(target - targetValue) > 0.0001 || duration > 0 else { return }
        startValue = value
        targetValue = target
        startTime = time
        duration = max(0, newDuration)
        curve = newCurve
        if newDuration <= 0 { value = target }
    }
}

private extension TimedTransitionScalar.Curve {
    func value(at x: CGFloat) -> CGFloat {
        switch self {
        case .easeInOut:
            return cubicBezier(x: x, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        case .blurRise:
            return cubicBezier(x: x, x1: 0.22, y1: 0, x2: 0.24, y2: 1)
        case .blurFall:
            return cubicBezier(x: x, x1: 0.20, y1: 0.78, x2: 0.22, y2: 1)
        case .background:
            return cubicBezier(x: x, x1: 0.36, y1: 0.0, x2: 0.64, y2: 1.0)
        case .layerFadeIn:
            return cubicBezier(x: x, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        case .layerFadeOut:
            return cubicBezier(x: x, x1: 0.24, y1: 0.72, x2: 0.22, y2: 1)
        }
    }

    private func cubicBezier(
        x: CGFloat,
        x1: CGFloat,
        y1: CGFloat,
        x2: CGFloat,
        y2: CGFloat
    ) -> CGFloat {
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<10 {
            let t = (low + high) * 0.5
            let sampledX = bezier(t, x1, x2)
            if sampledX < x { low = t } else { high = t }
        }
        return bezier((low + high) * 0.5, y1, y2)
    }

    private func bezier(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t
    }
}

private struct InterruptibleSpringScalar {
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private var target: CGFloat
    private var lastTime: CFTimeInterval?

    init(_ value: CGFloat) {
        self.value = value
        target = value
    }

    mutating func retarget(to newTarget: CGFloat, at time: CFTimeInterval, reduceMotion: Bool) {
        advance(to: time, reduceMotion: reduceMotion)
        target = newTarget
        if reduceMotion {
            value = newTarget
            velocity = 0
        }
    }

    mutating func advance(to time: CFTimeInterval, reduceMotion: Bool) {
        defer { lastTime = time }
        guard !reduceMotion, let lastTime else { return }
        var remaining = min(max(time - lastTime, 0), 1.0 / 15.0)
        let omega = 2.0 * Double.pi / 0.74
        let damping = 2.0 * 0.78 * omega
        let stiffness = omega * omega
        while remaining > 0 {
            let step = min(remaining, 1.0 / 120.0)
            let acceleration = stiffness * Double(target - value) - damping * Double(velocity)
            velocity += CGFloat(acceleration * step)
            value += velocity * CGFloat(step)
            remaining -= step
        }
        if abs(target - value) < 0.0002, abs(velocity) < 0.001 {
            value = target
            velocity = 0
        }
    }
}

private struct BokehTransitionPresentationState {
    private(set) var target = BokehTransitionSnapshot.inactive
    private var position = InterruptibleSpringScalar(0)
    private var centeredOpacity = TimedTransitionScalar(0)
    private var transitionOpacity = TimedTransitionScalar(0)
    private var radius = TimedTransitionScalar(0)
    private var opticalOpacity = TimedTransitionScalar(0)

    mutating func retarget(to newTarget: BokehTransitionSnapshot, at time: CFTimeInterval) {
        // Keep the dormant renderer exactly aligned with whichever static layout
        // is currently visible. Otherwise a surface first activated from the
        // centered state would animate internally from the default leading state.
        if target.surfaceOpacity <= 0.5, newTarget.surfaceOpacity <= 0.5 {
            target = newTarget
            position = InterruptibleSpringScalar(newTarget.transitionPosition)
            centeredOpacity = TimedTransitionScalar(newTarget.centeredOpacity)
            transitionOpacity = TimedTransitionScalar(newTarget.transitionOpacity)
            radius = TimedTransitionScalar(newTarget.bokehRadius)
            opticalOpacity = TimedTransitionScalar(newTarget.opticalOpacity)
            return
        }
        let reduceMotion = newTarget.reduceMotion
        if abs(newTarget.transitionPosition - target.transitionPosition) > 0.0001 {
            position.retarget(to: newTarget.transitionPosition, at: time, reduceMotion: reduceMotion)
        }
        if abs(newTarget.centeredOpacity - target.centeredOpacity) > 0.0001 {
            centeredOpacity.retarget(
                to: newTarget.centeredOpacity,
                at: time,
                duration: reduceMotion ? 0.34 : 0.72,
                curve: .background
            )
        }
        if abs(newTarget.transitionOpacity - target.transitionOpacity) > 0.0001 {
            let rising = newTarget.transitionOpacity > target.transitionOpacity
            transitionOpacity.retarget(
                to: newTarget.transitionOpacity,
                at: time,
                duration: reduceMotion ? (rising ? 0.16 : 0.22) : (rising ? 0.32 : 0.42),
                curve: rising ? .layerFadeIn : .layerFadeOut
            )
        }
        if abs(newTarget.bokehRadius - target.bokehRadius) > 0.0001 {
            let rising = newTarget.bokehRadius > target.bokehRadius
            radius.retarget(
                to: newTarget.bokehRadius,
                at: time,
                duration: reduceMotion ? (rising ? 0.16 : 0.28) : (rising ? 0.34 : 0.78),
                curve: rising ? .blurRise : .blurFall
            )
        }
        if abs(newTarget.opticalOpacity - target.opticalOpacity) > 0.0001 {
            let rising = newTarget.opticalOpacity > target.opticalOpacity
            opticalOpacity.retarget(
                to: newTarget.opticalOpacity,
                at: time,
                duration: reduceMotion ? 0.10 : (rising ? 0.08 : 0.20),
                curve: rising ? .layerFadeIn : .layerFadeOut
            )
        }
        target = newTarget
    }

    mutating func snapshot(at time: CFTimeInterval) -> BokehTransitionSnapshot {
        position.advance(to: time, reduceMotion: target.reduceMotion)
        centeredOpacity.advance(to: time)
        transitionOpacity.advance(to: time)
        radius.advance(to: time)
        opticalOpacity.advance(to: time)
        var result = target
        result.transitionPosition = position.value
        result.centeredOpacity = centeredOpacity.value
        result.transitionOpacity = transitionOpacity.value
        result.bokehRadius = radius.value
        result.opticalOpacity = opticalOpacity.value
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
        presentationState.retarget(to: snapshot, at: CACurrentMediaTime())
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
        view.alphaValue = presentation.opticalOpacity
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
            highlightPower: Float(presentation.configuration.highlightPower),
            highlightThreshold: Float(presentation.configuration.highlightThreshold),
            sampleBudget: presentation.tier.sampleBudget,
            apertureBlades: Int32(presentation.configuration.aperture.bladeCount),
            apertureRotationRadians: Float(presentation.configuration.apertureRotationDegrees * .pi / 180),
            apertureRoundness: Float(presentation.configuration.apertureRoundness)
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
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuSeconds = buffer.gpuEndTime - buffer.gpuStartTime
            Task { @MainActor [weak self] in
                self?.recordCompletedFrame(gpuSeconds: gpuSeconds)
                self?.inFlight.signal()
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

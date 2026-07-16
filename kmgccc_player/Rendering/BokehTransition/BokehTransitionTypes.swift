//
//  BokehTransitionTypes.swift
//  myPlayer2
//
//  Value-only contracts for the fullscreen Cover Gradient Blur transition.
//  Metal-specific uniforms live alongside the renderer.
//

import CoreGraphics
import Foundation
import simd

/// Bokeh's visual and performance parameters are intentionally fixed so every
/// installation uses the same transition result. Gaussian is only a runtime
/// fallback when the Metal renderer cannot be used.
struct BokehTransitionConfig: Equatable, Sendable {
    static let defaultRadiusAt1080 = 60.0
    static let defaultHighlightPower = 5.0
    static let defaultHighlightThreshold = 0.70
    static let defaultApertureBlades: Int32 = 0
    static let defaultApertureRotationRadians = 0.0
    static let defaultApertureRoundness = 0.0

    /// The Metal surface is intentionally low resolution while it is strongly
    /// blurred. Once the radius is nearly clear, dissolve it into the static
    /// high-resolution surface instead of exposing the upscaled source.
    static let opticalFadeInvisibleRadiusAt1080 = 2.0
    static let opticalFadeOpaqueRadiusAt1080 = 12.0

    static func opticalVisibility(forRadiusAt1080 radius: CGFloat) -> CGFloat {
        let lower = CGFloat(opticalFadeInvisibleRadiusAt1080)
        let upper = CGFloat(opticalFadeOpaqueRadiusAt1080)
        let progress = min(max((radius - lower) / (upper - lower), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

}

// MARK: - Metal contracts

enum BokehTransitionRenderTier: String, Sendable {
    case low
    case balanced

    nonisolated var sampleBudget: UInt32 {
        switch self {
        // Keep the gather kernel dense in both tiers. Sparse samples turn a
        // point highlight into a visible flower/dot pattern; lowering spatial
        // resolution is much less objectionable for an already-blurred layer.
        case .low, .balanced: 640
        }
    }

    nonisolated var pixelBudget: Int {
        switch self {
        case .low: 180_000
        case .balanced: 260_000
        }
    }

    nonisolated var shortEdgeRange: ClosedRange<Int> {
        switch self {
        case .low: 280...380
        case .balanced: 360...480
        }
    }
}

enum BokehTransitionMode: Equatable, Sendable {
    case bokeh
    case gaussianFallback(reason: String)
    case unmaskedFallback(reason: String)

    var usesBokeh: Bool {
        if case .bokeh = self { return true }
        return false
    }
}

struct BokehTransitionRenderSize: Hashable, Sendable {
    let width: Int
    let height: Int

    nonisolated var cgSize: CGSize { CGSize(width: width, height: height) }
    nonisolated var pixelCount: Int { width * height }

    /// Bounds a transition drawable by both short edge and total pixels. The
    /// returned dimensions are backing pixels and rounded down to Metal's
    /// 16-pixel threadgroup-friendly alignment.
    nonisolated static func make(backingPixelSize source: CGSize, tier: BokehTransitionRenderTier) -> Self? {
        guard source.width >= 2, source.height >= 2 else { return nil }

        var width = source.width * 0.25
        var height = source.height * 0.25
        let shortEdge = min(width, height)
        let targetShortEdge: CGFloat
        if shortEdge < CGFloat(tier.shortEdgeRange.lowerBound) {
            targetShortEdge = CGFloat(tier.shortEdgeRange.lowerBound)
        } else if shortEdge > CGFloat(tier.shortEdgeRange.upperBound) {
            targetShortEdge = CGFloat(tier.shortEdgeRange.upperBound)
        } else {
            targetShortEdge = shortEdge
        }

        let edgeScale = targetShortEdge / shortEdge
        width *= edgeScale
        height *= edgeScale

        let pixels = width * height
        if pixels > CGFloat(tier.pixelBudget) {
            let pixelScale = sqrt(CGFloat(tier.pixelBudget) / pixels)
            width *= pixelScale
            height *= pixelScale
        }

        width = min(width, source.width)
        height = min(height, source.height)
        let alignedWidth = max(16, Int(width.rounded(.down) / 16) * 16)
        let alignedHeight = max(16, Int(height.rounded(.down) / 16) * 16)
        return Self(width: alignedWidth, height: alignedHeight)
    }
}

struct BokehTransitionSourceIdentity: Hashable, Sendable {
    let artworkChecksum: UInt64
    let leadingRenderKey: String
    let centeredRenderKey: String
    let transitionRenderKey: String
    let renderSize: BokehTransitionRenderSize
    let tier: BokehTransitionRenderTier
}

/// This is the only per-frame value written by SwiftUI. It intentionally has
/// no images, GPU resources, tasks, or timing ownership.
struct BokehTransitionSnapshot: Equatable, Sendable {
    var transitionPosition: CGFloat
    var centeredOpacity: CGFloat
    var transitionOpacity: CGFloat
    var bokehRadius: CGFloat
    var surfaceOpacity: CGFloat
    var opticalOpacity: CGFloat
    var transitionCanvasSizeRatio: CGSize
    var transitionCanvasOffsetRatio: CGFloat
    var configuration: BokehTransitionConfig
    var tier: BokehTransitionRenderTier
    var reduceMotion: Bool

    static let inactive = Self(
        transitionPosition: 0,
        centeredOpacity: 0,
        transitionOpacity: 0,
        bokehRadius: 0,
        surfaceOpacity: 0,
        opticalOpacity: 0,
        transitionCanvasSizeRatio: CGSize(width: 1, height: 1),
        transitionCanvasOffsetRatio: 0,
        configuration: BokehTransitionConfig(),
        tier: .balanced,
        reduceMotion: false
    )

    var isActive: Bool { bokehRadius > 0.01 || surfaceOpacity > 0.01 }
}

/// Swift and Metal declarations are 40 and 32 bytes respectively. Keep fields in this order;
/// `BokehTransitionMetalContext` checks the strides before creating pipelines.
struct TransitionComposeUniforms {
    var viewportSize: SIMD2<Float>
    var transitionCanvasSizeRatio: SIMD2<Float>
    var transitionCanvasOffsetRatio: SIMD2<Float>
    var transitionPosition: Float
    var centeredOpacity: Float
    var transitionOpacity: Float
    var padding: Float = 0
}

struct TransitionBokehUniforms {
    var radiusAt1080: Float
    var highlightPower: Float
    var highlightThreshold: Float
    var sampleBudget: UInt32
    var apertureBlades: Int32
    var apertureRotationRadians: Float
    var apertureRoundness: Float
    var padding: Float = 0
}

/// Tracks completed Bokeh transitions without publishing UI state each frame.
/// The next transition, never the active one, consumes its decision so the
/// sampling budget and drawable size cannot visibly jump mid-animation.
@MainActor
final class BokehTransitionPerformancePolicy {
    struct Decision: Sendable {
        let tier: BokehTransitionRenderTier
        let reason: String
    }

    static let shared = BokehTransitionPerformancePolicy()

    private var activeTier: BokehTransitionRenderTier?
    private var activeGPUFrames: [Double] = []
    private var activeDroppedFrames = 0
    private var lastTier: BokehTransitionRenderTier?
    private var lastP95GPUSeconds: Double?
    private var lastDroppedFrameRatio: Double?
    private var consecutiveHealthyLowTransitions = 0

    private init() {}

    func begin(tier: BokehTransitionRenderTier) {
        activeTier = tier
        activeGPUFrames.removeAll(keepingCapacity: true)
        activeDroppedFrames = 0
    }

    func recordGPUFrame(_ seconds: Double) {
        guard activeTier != nil, seconds > 0 else { return }
        activeGPUFrames.append(seconds)
    }

    func recordDroppedFrame() {
        guard activeTier != nil else { return }
        activeDroppedFrames += 1
    }

    func finish() {
        guard let tier = activeTier else { return }
        defer {
            activeTier = nil
            activeGPUFrames.removeAll(keepingCapacity: true)
            activeDroppedFrames = 0
        }

        let sorted = activeGPUFrames.sorted()
        let p95: Double? = if sorted.isEmpty {
            nil
        } else {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))]
        }
        let totalFrames = activeGPUFrames.count + activeDroppedFrames
        let droppedRatio = totalFrames > 0 ? Double(activeDroppedFrames) / Double(totalFrames) : 0

        lastTier = tier
        lastP95GPUSeconds = p95
        lastDroppedFrameRatio = droppedRatio

        if tier == .low,
           let p95,
           p95 < 0.006,
           droppedRatio <= 0.01 {
            consecutiveHealthyLowTransitions += 1
        } else {
            consecutiveHealthyLowTransitions = 0
        }
    }

    func nextAutomaticDecision() -> Decision {
        if let lastP95GPUSeconds, lastP95GPUSeconds > 0.010 {
            return Decision(tier: .low, reason: "previous GPU P95 exceeded 10 ms")
        }
        if let lastDroppedFrameRatio, lastDroppedFrameRatio > 0.01 {
            return Decision(tier: .low, reason: "previous dropped-frame ratio exceeded 1%")
        }
        if lastTier == .low, consecutiveHealthyLowTransitions < 3 {
            return Decision(tier: .low, reason: "waiting for three healthy Low transitions before recovery")
        }
        return Decision(tier: .balanced, reason: "previous transition met budget")
    }
}

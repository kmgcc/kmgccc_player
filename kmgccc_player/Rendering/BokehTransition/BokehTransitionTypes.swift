//
//  BokehTransitionTypes.swift
//  myPlayer2
//
//  Value-only contracts for the fullscreen Cover Gradient Blur transition.
//  Metal-specific uniforms live alongside the renderer.
//

import CoreGraphics
import Foundation
import MotionKit
import simd

/// Bokeh's visual and performance parameters are intentionally fixed so every
/// installation uses the same transition result. Gaussian is only a runtime
/// fallback when the Metal renderer cannot be used.
struct BokehTransitionConfig: Equatable, Sendable {
    /// Every transition, layout or artwork change, uses this one radius.
    static let defaultRadiusAt1080 = 48.0
    static let defaultHighlightPower = 5.0
    static let defaultHighlightThreshold = 0.70
    static let defaultApertureBlades: Int32 = 0
    static let defaultApertureRotationRadians = 0.0
    static let defaultApertureRoundness = 0.0

    /// The surface fades in with the rising radius and is opaque from this
    /// radius on; the cover starts moving only once it is.
    static let opticalFadeInvisibleRadiusAt1080 = 0.0
    static let opticalFadeOpaqueRadiusAt1080 = 4.0

    /// While the radius falls, the surface dissolves into the settled
    /// high-resolution layer from this radius on: late enough that the
    /// image already matches it, early enough that the lower resolution
    /// never shows unblurred.
    static let handoffRadiusAt1080 = 7.0

    /// The radius advances on its own clock; position and opacity follow
    /// the display.
    static let radiusUpdatesPerSecond = 30.0

    static func opticalVisibility(forRadiusAt1080 radius: CGFloat) -> CGFloat {
        let lower = CGFloat(opticalFadeInvisibleRadiusAt1080)
        let upper = CGFloat(opticalFadeOpaqueRadiusAt1080)
        let progress = min(max((radius - lower) / (upper - lower), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

}

// MARK: - Metal contracts

nonisolated enum BokehTransitionRenderTier: String, Sendable {
    case low
    case balanced

    /// The gather runs at half the panorama's resolution, so it affords
    /// dense taps: each reads a level only a few pixels wide, and the
    /// power mean cannot reveal a coarse level's blocks as stair steps.
    nonisolated var sampleBudget: UInt32 {
        switch self {
        case .low: 448
        case .balanced: 768
        }
    }

    nonisolated var pixelBudget: Int {
        switch self {
        case .low: 380_000
        case .balanced: 600_000
        }
    }

    nonisolated var shortEdgeRange: ClosedRange<Int> {
        switch self {
        case .low: 360...560
        case .balanced: 480...720
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

nonisolated struct BokehTransitionRenderSize: Hashable, Sendable {
    let width: Int
    let height: Int

    nonisolated var cgSize: CGSize { CGSize(width: width, height: height) }
    nonisolated var pixelCount: Int { width * height }

    /// Bounds a transition drawable by both short edge and total pixels.
    /// The result keeps the viewport's aspect to the pixel, so the surface
    /// scales uniformly onto the view and lines up with the settled layer.
    nonisolated static func make(backingPixelSize source: CGSize, tier: BokehTransitionRenderTier) -> Self? {
        guard source.width >= 2, source.height >= 2 else { return nil }

        var width = source.width * 0.33
        var height = source.height * 0.33
        let shortEdge = min(width, height)
        let targetShortEdge = min(
            max(shortEdge, CGFloat(tier.shortEdgeRange.lowerBound)),
            CGFloat(tier.shortEdgeRange.upperBound)
        )

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
        return Self(width: max(16, Int(width.rounded())), height: max(16, Int(height.rounded())))
    }
}

nonisolated struct BokehTransitionSourceIdentity: Hashable, Sendable {
    let artworkChecksum: UInt64
    /// Distinguishes covers of one checksum, such as a video frame.
    let sourceKey: String
    let logicalViewportSize: CGSize
    let displayScale: CGFloat
    let renderSize: BokehTransitionRenderSize
    let tier: BokehTransitionRenderTier

    func matchesViewport(_ viewport: CGSize, tolerance: CGFloat = 12) -> Bool {
        viewport.width > 1 && viewport.height > 1
            && abs(logicalViewportSize.width - viewport.width) <= tolerance
            && abs(logicalViewportSize.height - viewport.height) <= tolerance
    }

    func matchesViewport(
        _ viewport: CGSize,
        displayScale: CGFloat,
        tolerance: CGFloat = 12
    ) -> Bool {
        matchesViewport(viewport, tolerance: tolerance)
            && abs(self.displayScale - displayScale) < 0.01
    }
}

/// This is the only per-frame value written by SwiftUI. It intentionally has
/// no images, GPU resources, tasks, or timing ownership.
struct BokehTransitionSnapshot: Equatable, Sendable {
    /// 0 leading, 1 centered. The renderer springs toward it.
    var transitionPosition: CGFloat
    var bokehRadius: CGFloat
    var surfaceOpacity: CGFloat
    /// A transition-wide dissolve into the settled background, for an
    /// artwork change whose replacement source is not ready.
    var handoffOpacity: CGFloat
    /// True from the blur-fall start until the surface retires. The surface
    /// stays opaque while the radius falls and dissolves into the settled
    /// layer on its own once the radius is small.
    var keepsSurfaceOpaque: Bool
    var configuration: BokehTransitionConfig
    var tier: BokehTransitionRenderTier
    var motionPolicy: MotionPolicy
    var motionTokens: MotionTokens

    static let inactive = Self(
        transitionPosition: 0,
        bokehRadius: 0,
        surfaceOpacity: 0,
        handoffOpacity: 0,
        keepsSurfaceOpaque: false,
        configuration: BokehTransitionConfig(),
        tier: .balanced,
        motionPolicy: .full,
        motionTokens: .standard
    )

    var isActive: Bool { bokehRadius > 0.01 || surfaceOpacity > 0.01 }
}

/// 32 bytes in both Swift and Metal. Keep fields in this order;
/// `BokehTransitionMetalContext` checks the stride before creating pipelines.
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

/// Latest decoded video frame for the transition surface. The video keeps
/// playing under the lens; frames reach the renderer without SwiftUI state.
nonisolated final class BokehLiveCoverFeed: @unchecked Sendable {
    struct Frame {
        let image: CGImage
        let artworkChecksum: UInt64
        let generation: UInt64
    }

    private let lock = NSLock()
    private var frame: Frame?
    private var generation: UInt64 = 0

    func publish(_ image: CGImage, artworkChecksum: UInt64) {
        lock.lock()
        generation &+= 1
        frame = Frame(image: image, artworkChecksum: artworkChecksum, generation: generation)
        lock.unlock()
    }

    func latest() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    func clear() {
        lock.lock()
        frame = nil
        lock.unlock()
    }
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

    /// Discard an interrupted transition without changing the last completed decision.
    func cancel() {
        activeTier = nil
        activeGPUFrames.removeAll(keepingCapacity: true)
        activeDroppedFrames = 0
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
           p95 < 0.004,
           droppedRatio <= 0.01 {
            consecutiveHealthyLowTransitions += 1
        } else {
            consecutiveHealthyLowTransitions = 0
        }
    }

    /// A 120 Hz display leaves 8.3 ms per frame for everything, so the
    /// transition's own GPU time stays well below that.
    func nextAutomaticDecision() -> Decision {
        if let lastP95GPUSeconds, lastP95GPUSeconds > 0.006 {
            return Decision(tier: .low, reason: "previous GPU P95 exceeded 6 ms")
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

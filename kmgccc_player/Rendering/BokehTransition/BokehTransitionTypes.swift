//
//  BokehTransitionTypes.swift
//  myPlayer2
//
//  User-facing configuration and value-only contracts for the fullscreen
//  Cover Gradient Blur transition. Metal-specific uniforms live alongside the
//  renderer so this file remains safe to use from settings views.
//

import CoreGraphics
import Foundation
import simd

enum CoverBlurTransitionEffect: String, CaseIterable, Sendable {
    case bokeh
    case gaussian

    var displayName: String {
        switch self {
        case .bokeh: "散景"
        case .gaussian: "高斯"
        }
    }
}

enum BokehTransitionQuality: String, CaseIterable, Sendable {
    case automatic
    case low
    case balanced

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .low: "低"
        case .balanced: "均衡"
        }
    }
}

enum BokehApertureShape: String, CaseIterable, Sendable {
    case circle
    case square
    case pentagon
    case hexagon
    case heptagon
    case octagon

    var displayName: String {
        switch self {
        case .circle: "圆形"
        case .square: "四边形"
        case .pentagon: "五边形"
        case .hexagon: "六边形"
        case .heptagon: "七边形"
        case .octagon: "八边形"
        }
    }

    var bladeCount: Int {
        switch self {
        case .circle: 0
        case .square: 4
        case .pentagon: 5
        case .hexagon: 6
        case .heptagon: 7
        case .octagon: 8
        }
    }

    var supportsPolygonControls: Bool { self != .circle }
}

/// Persisted settings for the temporary Metal transition surface. Static Cover
/// Gradient Blur rendering deliberately does not consult this type.
struct BokehTransitionConfig: Equatable, Sendable {
    static let defaultRadiusAt1080 = 44.0
    static let defaultHighlightPower = 3.0
    static let defaultHighlightThreshold = 0.70

    var effect: CoverBlurTransitionEffect
    var quality: BokehTransitionQuality
    var radiusAt1080: Double
    var highlightPower: Double
    var highlightThreshold: Double
    var aperture: BokehApertureShape
    var apertureRotationDegrees: Double
    var apertureRoundness: Double

    init(
        effect: CoverBlurTransitionEffect = .bokeh,
        quality: BokehTransitionQuality = .automatic,
        radiusAt1080: Double = BokehTransitionConfig.defaultRadiusAt1080,
        highlightPower: Double = BokehTransitionConfig.defaultHighlightPower,
        highlightThreshold: Double = BokehTransitionConfig.defaultHighlightThreshold,
        aperture: BokehApertureShape = .circle,
        apertureRotationDegrees: Double = 0,
        apertureRoundness: Double = 0
    ) {
        self.effect = effect
        self.quality = quality
        self.radiusAt1080 = radiusAt1080.clamped(to: 16...72)
        self.highlightPower = highlightPower.clamped(to: 1...5)
        self.highlightThreshold = highlightThreshold.clamped(to: 0.40...0.95)
        self.aperture = aperture
        self.apertureRotationDegrees = apertureRotationDegrees.clamped(to: 0...180)
        self.apertureRoundness = apertureRoundness.clamped(to: -1...1)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            effect: CoverBlurTransitionEffect(rawValue: defaults.string(forKey: Keys.effect) ?? "") ?? .bokeh,
            quality: BokehTransitionQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .automatic,
            radiusAt1080: defaults.doubleValue(forKey: Keys.radiusAt1080, fallback: defaultRadiusAt1080),
            highlightPower: defaults.doubleValue(forKey: Keys.highlightPower, fallback: defaultHighlightPower),
            highlightThreshold: defaults.doubleValue(forKey: Keys.highlightThreshold, fallback: defaultHighlightThreshold),
            aperture: BokehApertureShape(rawValue: defaults.string(forKey: Keys.aperture) ?? "") ?? .circle,
            apertureRotationDegrees: defaults.doubleValue(forKey: Keys.apertureRotationDegrees, fallback: 0),
            apertureRoundness: defaults.doubleValue(forKey: Keys.apertureRoundness, fallback: 0)
        )
    }

    enum Keys {
        static let effect = "skin.coverGradientBlur.transitionBokeh.effect"
        static let quality = "skin.coverGradientBlur.transitionBokeh.quality"
        static let radiusAt1080 = "skin.coverGradientBlur.transitionBokeh.radiusAt1080"
        static let highlightPower = "skin.coverGradientBlur.transitionBokeh.highlightPower"
        static let highlightThreshold = "skin.coverGradientBlur.transitionBokeh.highlightThreshold"
        static let aperture = "skin.coverGradientBlur.transitionBokeh.aperture"
        static let apertureRotationDegrees = "skin.coverGradientBlur.transitionBokeh.apertureRotationDegrees"
        static let apertureRoundness = "skin.coverGradientBlur.transitionBokeh.apertureRoundness"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension UserDefaults {
    func doubleValue(forKey key: String, fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }
}

// MARK: - Metal contracts

enum BokehTransitionRenderTier: String, Sendable {
    case low
    case balanced

    nonisolated var sampleBudget: UInt32 {
        switch self {
        case .low: 128
        case .balanced: 256
        }
    }

    nonisolated var pixelBudget: Int {
        switch self {
        case .low: 500_000
        case .balanced: 900_000
        }
    }

    nonisolated var shortEdgeRange: ClosedRange<Int> {
        switch self {
        case .low: 360...540
        case .balanced: 540...720
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

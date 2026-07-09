//
//  CapsuleSpectrumHostView.swift
//  myPlayer2
//
//  kmgccc_player - Shared capsule spectrum renderer.
//
//  One CALayer-backed NSView that every capsule spectrum surface (ClassicLED,
//  RotatingCover, MiniPlayer, Cassette) shares. Sampling and animation are
//  identical across surfaces; only geometry, stroke, and colors are configured
//  per surface.
//
//  Why this exists: the four surfaces previously each owned a near-identical
//  host that snapped capsule heights directly to the ≤30Hz published wave with
//  `CATransaction.setDisableActions(true)`. That produced visible stepping
//  (especially during quiet / flat passages, where the publish throttle drops
//  the effective rate to ~4Hz) and had no overshoot, so it never felt "bouncy".
//
//  This host decouples *rendering* from the *data* rate:
//   - The AudioVisualizationService wave (≤30Hz) only updates per-band targets.
//   - A CADisplayLink runs a per-band damped spring toward each target every
//     display frame (60/120Hz, ProMotion-aware), giving the elastic "Q弹" motion
//     and interpolating the ≤30Hz steps smoothly. The spring uses the CLOSED-FORM
//     solution so it stays stable at any response/damping. Tune via
//     CapsuleSpectrumDynamics.
//   - The link auto-pauses once every band has settled and wakes on new
//     targets / playback resume, so the idle-CPU gating still holds (no
//     always-on 60Hz tick while paused).
//

import AppKit
import QuartzCore

// MARK: - Configuration types

/// Mass-spring-damper for the per-band followers — the elastic "Q弹" motion.
/// A short `response` keeps it agile (fast rise AND fast contraction);
/// `dampingFraction < 1` gives a lively overshoot/bounce. Mirrors SwiftUI's
/// `.spring(response:dampingFraction:)` so the numbers are intuitive. The spring
/// only feels good when fed dense, lightly-compressed data (see the upstream
/// `publishEpsilon` / `cubicPower` settings) — otherwise the sparse low-volume
/// steps make it lurch.
struct CapsuleSpectrumDynamics: Equatable {
    /// Spring period (s). Smaller = faster, more agile rise and contraction.
    var response: CGFloat
    /// 0…1 underdamped → springy overshoot ("Q弹"); 1 = critical (no bounce).
    var dampingFraction: CGFloat

    /// Agile and elastic: a fast spring with a lively, controlled bounce.
    static let standard = CapsuleSpectrumDynamics(response: 0.05 , dampingFraction: 0.52)
    /// Tighter, less bounce — quick and composed.
    static let tight = CapsuleSpectrumDynamics(response: 0.10, dampingFraction: 0.80)
    /// Looser and bouncier — bigger overshoot.
    static let bouncy = CapsuleSpectrumDynamics(response: 0.18, dampingFraction: 0.50)
    /// Gentle, monotonic settle for the pause transition. Critically damped (no
    /// overshoot) and deliberately slow so the bars "缓缓落下" to their paused pose
    /// instead of snapping — the playback spring above is intentionally agile,
    /// which on its own would make the pause fall look instantaneous.
    static let pauseFall = CapsuleSpectrumDynamics(response: 0.62, dampingFraction: 1.0)
}

/// What the bars do while playback is paused.
enum CapsuleSpectrumPausedBehavior {
    /// Follow whatever the service publishes (it blends to a static idle pose).
    case idlePose
    /// Collapse every bar to its minimum dot (MiniPlayer behavior).
    case collapseToDots
}

/// Per-bar geometry, recomputed from the live bounds on every layout/render.
/// Each bar is a vertical capsule centered on `centerY`; height scales with the
/// band value. This single model covers both the absolute-point surfaces
/// (LED/RotatingCover/MiniPlayer) and the ratio-of-bounds surface (Cassette).
struct CapsuleSpectrumMetrics: Equatable {
    var barWidth: CGFloat
    var spacing: CGFloat
    var minHeight: CGFloat
    var maxBarHeight: CGFloat
    var originX: CGFloat
    var centerY: CGFloat
    var cornerRadius: CGFloat
}

struct CapsuleSpectrumConfiguration {
    var capsuleCount: Int
    var dynamics: CapsuleSpectrumDynamics
    /// Spring used only while paused, to ease the bars down to their paused pose.
    /// Separate from `dynamics` so the agile playback spring can stay agile
    /// without making the pause fall look like an instant snap.
    var pauseDynamics: CapsuleSpectrumDynamics
    var pausedBehavior: CapsuleSpectrumPausedBehavior
    /// Outline width; 0 disables the per-bar border entirely (Cassette).
    var strokeWidth: CGFloat
    /// Multiplies the normalized band value before mapping to height (Cassette
    /// uses this to lift its short bars). Default 1.0 = no change.
    var heightBoost: CGFloat
    /// Display-level dynamic-range shaping applied to the smoothed band value
    /// right before it maps to bar height (so it's purely visual and never
    /// affects the spring feel). `< 1` lifts quiet passages; the ceiling caps
    /// loud passages so they stop pegging the top. See `LevelShaping`.
    var levelShaping: LevelShaping
    /// Computes bar geometry from the current bounds. Pure / cheap.
    var metrics: (_ bounds: CGRect, _ count: Int) -> CapsuleSpectrumMetrics

    /// Compresses the displayed dynamic range: `out = ceiling · valueᵍᵃᵐᵐᵃ`.
    /// `gamma < 1` raises the quiet end (concave), `ceiling < 1` pulls the loud
    /// end down so bars stop slamming the top. Identity = `gamma 1, ceiling 1`.
    struct LevelShaping: Equatable {
        var gamma: CGFloat
        var ceiling: CGFloat
        var isIdentity: Bool { gamma == 1 && ceiling == 1 }
        /// Default: lift quiet (~0.7) and leave headroom at the top (~0.8) so
        /// ordinary songs don't peg while quiet passages stay visible.
        static let standard = LevelShaping(gamma: 0.7, ceiling: 0.8)
        static let identity = LevelShaping(gamma: 1, ceiling: 1)
    }

    init(
        capsuleCount: Int = 9,
        dynamics: CapsuleSpectrumDynamics = .standard,
        pauseDynamics: CapsuleSpectrumDynamics = .pauseFall,
        pausedBehavior: CapsuleSpectrumPausedBehavior = .idlePose,
        strokeWidth: CGFloat = 0,
        heightBoost: CGFloat = 1.0,
        levelShaping: LevelShaping = .standard,
        metrics: @escaping (_ bounds: CGRect, _ count: Int) -> CapsuleSpectrumMetrics
    ) {
        self.capsuleCount = capsuleCount
        self.dynamics = dynamics
        self.pauseDynamics = pauseDynamics
        self.pausedBehavior = pausedBehavior
        self.strokeWidth = strokeWidth
        self.heightBoost = heightBoost
        self.levelShaping = levelShaping
        self.metrics = metrics
    }

    /// Centered row of fixed-point-width capsules, vertically centered in the
    /// bounds. Shared by the LED / RotatingCover / MiniPlayer surfaces — they
    /// differ only in width / spacing / stroke / pause behavior.
    static func centeredBars(
        capsuleCount: Int = 9,
        capsuleWidth: CGFloat,
        capsuleSpacing: CGFloat,
        strokeWidth: CGFloat,
        maxHeightRatio: CGFloat = 0.95,
        dynamics: CapsuleSpectrumDynamics = .standard,
        pauseDynamics: CapsuleSpectrumDynamics = .pauseFall,
        pausedBehavior: CapsuleSpectrumPausedBehavior = .idlePose,
        levelShaping: LevelShaping = .standard
    ) -> CapsuleSpectrumConfiguration {
        CapsuleSpectrumConfiguration(
            capsuleCount: capsuleCount,
            dynamics: dynamics,
            pauseDynamics: pauseDynamics,
            pausedBehavior: pausedBehavior,
            strokeWidth: strokeWidth,
            heightBoost: 1.0,
            levelShaping: levelShaping
        ) { bounds, count in
            let totalWidth = CGFloat(count) * capsuleWidth
                + CGFloat(max(0, count - 1)) * capsuleSpacing
            return CapsuleSpectrumMetrics(
                barWidth: capsuleWidth,
                spacing: capsuleSpacing,
                minHeight: capsuleWidth,
                maxBarHeight: bounds.height * maxHeightRatio,
                originX: (bounds.width - totalWidth) * 0.5,
                centerY: bounds.height * 0.5,
                cornerRadius: capsuleWidth * 0.5
            )
        }
    }
}

// MARK: - Host view

@MainActor
final class CapsuleSpectrumHostView: NSView {

    /// Tracks the hash of the last applied PillSpectrumContainer.Identity
    /// so updateNSView can skip redundant configure/applyColors/setPlayback calls.
    var pillSpectrumIdentityHash: Int?

    private let service = AudioVisualizationService.shared
    private let rootLayer = CALayer()
    private var capsuleLayers: [CALayer] = []

    private var configuration: CapsuleSpectrumConfiguration

    // Follower state, one slot per band.
    private var targetWave: [CGFloat]
    private var position: [CGFloat]
    private var velocity: [CGFloat]

    // Rendering / display-link state.
    private var frameLink: CADisplayLink?
    private var lastTickTimestamp: CFTimeInterval = 0
    private var settledFrames = 0
    private static let settleHoldFrames = 4
    private static let velocityEpsilon: CGFloat = 0.0016
    private static let positionEpsilon: CGFloat = 0.0008
    private static let renderFrameRateCap: Float = 60
    // Geometry is constant between resizes/config changes; cache it so the
    // per-frame path only rewrites each bar's height, not its full frame.
    private var cachedMetrics: CapsuleSpectrumMetrics?

    // Lease / playback state.
    private var consumerID: UUID?
    private var hasServiceLease = false
    private var isActive = false
    private var isPlaying = false
    private var lastForwardedPlaybackState: Bool?

    private var lastLayoutSize: CGSize = .zero
    private var lastColorSignature: Int?
    private var fillColors: [CGColor] = []
    private var strokeColors: [CGColor]?

    // MARK: Init

    init(configuration: CapsuleSpectrumConfiguration) {
        self.configuration = configuration
        let count = max(1, configuration.capsuleCount)
        self.targetWave = Array(repeating: 0, count: count)
        self.position = Array(repeating: 0, count: count)
        self.velocity = Array(repeating: 0, count: count)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        rootLayer.masksToBounds = false
        layer?.addSublayer(rootLayer)
        rebuildCapsuleLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            frameLink?.invalidate()
            frameLink = nil
        }
    }

    private var count: Int { max(1, configuration.capsuleCount) }

    // MARK: Configuration

    /// Re-apply geometry / spring / stroke / pause config. Cheap; safe to call
    /// from `updateNSView` on every SwiftUI pass. Rebuilds layers only if the
    /// capsule count actually changed.
    func configure(_ newConfiguration: CapsuleSpectrumConfiguration) {
        let countChanged = newConfiguration.capsuleCount != configuration.capsuleCount
        configuration = newConfiguration
        if countChanged {
            resizeFollowerState()
            rebuildCapsuleLayers()
            lastColorSignature = nil // force color re-apply for the new layers
        }
        applyStrokeWidth()
        refreshGeometry()
        renderHeights()
    }

    /// Apply resolved colors, skipping the (potentially expensive) provider when
    /// the inputs are unchanged. `provider` returns fill colors and an optional
    /// stroke-color array (nil = reuse fill / no separate outline color).
    func updateColors(
        signature: Int,
        provider: () -> (fill: [CGColor], stroke: [CGColor]?)
    ) {
        guard signature != lastColorSignature else { return }
        lastColorSignature = signature
        let resolved = provider()
        fillColors = resolved.fill
        strokeColors = resolved.stroke
        applyColors()
    }

    // MARK: Lease / lifecycle

    /// Used by surfaces that gate the lease on visibility (MiniPlayer).
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            start()
        } else {
            stop()
        }
    }

    /// Acquire the shared visualization lease and start consuming waves.
    func start() {
        isActive = true
        guard consumerID == nil else { return }
        service.start()
        hasServiceLease = true
        consumerID = service.addConsumer { [weak self] wave in
            self?.applyWave(wave)
        }
        if let state = lastForwardedPlaybackState {
            service.updatePlaybackState(isPlaying: state)
        }
        wakeDisplayLink()
    }

    /// Release the lease and stop animating.
    func stop() {
        isActive = false
        if let consumerID {
            service.removeConsumer(consumerID)
            self.consumerID = nil
        }
        if hasServiceLease {
            hasServiceLease = false
            service.stop()
        }
        invalidateDisplayLink()
        for index in 0..<count {
            targetWave[index] = 0
            position[index] = 0
            velocity[index] = 0
        }
        renderHeights()
    }

    func setPlayback(isPlaying playing: Bool) {
        if lastForwardedPlaybackState != playing {
            lastForwardedPlaybackState = playing
            if hasServiceLease {
                service.updatePlaybackState(isPlaying: playing)
            }
        }

        guard isPlaying != playing else { return }
        isPlaying = playing

        if !playing, configuration.pausedBehavior == .collapseToDots {
            // Drive every bar down to its dot instead of freezing the wave.
            for index in 0..<count { targetWave[index] = 0 }
        }
        // Either direction needs the link running to animate the transition;
        // it will re-settle and self-pause once the bars stop moving.
        wakeDisplayLink()
    }

    /// Deep backing teardown for surfaces that recycle aggressively (Cassette).
    func teardownBacking() {
        invalidateDisplayLink()
        lastLayoutSize = .zero
        lastColorSignature = nil
        cachedMetrics = nil
        capsuleLayers.removeAll(keepingCapacity: false)
        rootLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        rootLayer.sublayers = nil
        rootLayer.removeFromSuperlayer()
        layer?.sublayers = nil
        layer = nil
        wantsLayer = false
    }

    // MARK: Wave intake

    private func applyWave(_ wave: [Float]) {
        // While paused in collapse-to-dots mode the bars stay down; ignore the
        // service's idle-pose frames so they don't fight the collapse target.
        if !isPlaying, configuration.pausedBehavior == .collapseToDots { return }

        var changed = false
        for index in 0..<count {
            let value: CGFloat = index < wave.count
                ? CGFloat(min(1, max(0, wave[index])))
                : 0
            if abs(value - targetWave[index]) > 0.0004 { changed = true }
            targetWave[index] = value
        }
        if changed { wakeDisplayLink() }
    }

    // MARK: Follower integration (display-link driven)

    @objc private func handleFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = lastTickTimestamp > 0 ? now - lastTickTimestamp : (1.0 / 60.0)
        lastTickTimestamp = now
        // The analytic spring step below is unconditionally stable, so this clamp
        // is only to keep a long hitch from snapping the bars in one visible jump.
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)

        advanceFollowers(dt: CGFloat(dt))
        renderHeights()

        if followersSettled() {
            settledFrames += 1
            if settledFrames >= Self.settleHoldFrames {
                // Snap exactly onto the targets so a paused pose is pixel-stable,
                // then stop ticking until something changes.
                for index in 0..<count {
                    position[index] = targetWave[index]
                    velocity[index] = 0
                }
                renderHeights()
                pauseDisplayLink()
            }
        } else {
            settledFrames = 0
        }
    }

    private func advanceFollowers(dt: CGFloat) {
        // Mass-spring-damper toward each target, integrated with the CLOSED-FORM
        // solution of the damped harmonic oscillator. Unlike explicit/semi-implicit
        // Euler (which blows up when `2ζω·dt > 1`, i.e. a stiff spring at a small
        // `response` — that caused the ping-pong/afterimage), this is exact and
        // unconditionally stable for ANY response / damping / frame time.
        // Paused → ease down with the gentle pause spring so the fall reads as a
        // graceful settle, not a snap; playing → the agile playback spring.
        let dynamics = isPlaying ? configuration.dynamics : configuration.pauseDynamics
        let omega = (2 * CGFloat.pi) / max(0.01, dynamics.response)
        let zeta = max(0, dynamics.dampingFraction)
        for index in 0..<count {
            let (newPos, newVel) = Self.dampedSpringStep(
                position: position[index],
                velocity: velocity[index],
                target: targetWave[index],
                omega: omega,
                zeta: zeta,
                dt: dt
            )
            position[index] = newPos
            velocity[index] = newVel
        }
    }

    /// Exact step of `d'' + 2ζω·d' + ω²·d = 0` (d = position − target) over `dt`.
    /// Handles under/critical/over-damped; always decays (factor `e^{-ζω·dt}`),
    /// so it can never diverge regardless of stiffness or frame time.
    private static func dampedSpringStep(
        position: CGFloat, velocity: CGFloat, target: CGFloat,
        omega: CGFloat, zeta: CGFloat, dt: CGFloat
    ) -> (CGFloat, CGFloat) {
        guard omega > 0, dt > 0 else { return (position, velocity) }
        let d0 = position - target          // displacement from equilibrium
        let v0 = velocity
        let edge: CGFloat = 0.0001

        if zeta < 1 - edge {
            // Underdamped — the springy / overshooting case ("Q弹").
            let omegaD = omega * sqrt(1 - zeta * zeta)
            let e = exp(-zeta * omega * dt)
            let cosw = cos(omegaD * dt)
            let sinw = sin(omegaD * dt)
            let a = d0
            let b = (v0 + zeta * omega * d0) / omegaD
            let d = e * (a * cosw + b * sinw)
            let v = e * (-zeta * omega * (a * cosw + b * sinw)
                         + omegaD * (-a * sinw + b * cosw))
            return (target + d, v)
        } else if zeta <= 1 + edge {
            // Critically damped.
            let e = exp(-omega * dt)
            let a = d0
            let b = v0 + omega * d0
            let d = (a + b * dt) * e
            let v = (b - omega * (a + b * dt)) * e
            return (target + d, v)
        } else {
            // Overdamped — two real roots.
            let s = sqrt(zeta * zeta - 1)
            let r1 = -omega * (zeta - s)
            let r2 = -omega * (zeta + s)
            let c2 = (v0 - r1 * d0) / (r2 - r1)
            let c1 = d0 - c2
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            let d = c1 * e1 + c2 * e2
            let v = c1 * r1 * e1 + c2 * r2 * e2
            return (target + d, v)
        }
    }

    private func followersSettled() -> Bool {
        for index in 0..<count {
            if abs(targetWave[index] - position[index]) > Self.positionEpsilon { return false }
            if abs(velocity[index]) > Self.velocityEpsilon { return false }
        }
        return true
    }

    // MARK: Display link management

    private func ensureDisplayLink() {
        guard frameLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(handleFrame(_:)))
        // Cap at 60Hz. The spring's motion is well below ~8Hz, so 60Hz samples it
        // ~8× — visually identical to 120Hz — but on a ProMotion display this
        // halves the per-frame Core Animation commits (the dominant cost).
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Self.renderFrameRateCap,
            maximum: Self.renderFrameRateCap,
            preferred: Self.renderFrameRateCap
        )
        link.add(to: .current, forMode: .common)
        lastTickTimestamp = 0
        settledFrames = 0
        frameLink = link
    }

    private func wakeDisplayLink() {
        if frameLink == nil { ensureDisplayLink() }
        settledFrames = 0
        frameLink?.isPaused = false
    }

    private func pauseDisplayLink() {
        frameLink?.isPaused = true
    }

    private func invalidateDisplayLink() {
        frameLink?.invalidate()
        frameLink = nil
        lastTickTimestamp = 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // The display link binds to the view's screen; (re)create it here.
            if hasServiceLease { wakeDisplayLink() }
        } else {
            invalidateDisplayLink()
        }
    }

    // MARK: Layout & render

    override func layout() {
        super.layout()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        refreshGeometry()
        renderHeights()
        // A resize may expose un-settled geometry; nudge the link so the bars
        // re-seat smoothly rather than waiting for the next wave.
        if hasServiceLease { wakeDisplayLink() }
    }

    private func resizeFollowerState() {
        targetWave = Array(repeating: 0, count: count)
        position = Array(repeating: 0, count: count)
        velocity = Array(repeating: 0, count: count)
    }

    private func rebuildCapsuleLayers() {
        cachedMetrics = nil // fresh layers always need geometry re-applied
        capsuleLayers.forEach { $0.removeFromSuperlayer() }
        capsuleLayers = (0..<count).map { _ in
            let layer = CALayer()
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            // Every visual property is driven imperatively each frame; suppress
            // implicit animations so the follower is the only motion source.
            layer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "frame": NSNull(),
                "backgroundColor": NSNull(),
                "borderColor": NSNull(),
                "borderWidth": NSNull(),
                "cornerRadius": NSNull(),
            ]
            rootLayer.addSublayer(layer)
            return layer
        }
        applyStrokeWidth()
        applyColors()
    }

    private func applyStrokeWidth() {
        let width = configuration.strokeWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in capsuleLayers {
            layer.borderWidth = width
        }
        CATransaction.commit()
    }

    private func applyColors() {
        guard !capsuleLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in capsuleLayers.enumerated() {
            if index < fillColors.count {
                layer.backgroundColor = fillColors[index]
            }
            if let strokeColors, index < strokeColors.count {
                layer.borderColor = strokeColors[index]
            } else if index < fillColors.count {
                layer.borderColor = fillColors[index]
            }
        }
        CATransaction.commit()
    }

    /// Write the per-bar *static* properties (center, width, cornerRadius) once.
    /// Recomputes only when the geometry actually changed, so SwiftUI's frequent
    /// `configure` passes are nearly free. NOT on the per-frame path.
    private func refreshGeometry() {
        guard bounds.width > 0, bounds.height > 0, !capsuleLayers.isEmpty else {
            cachedMetrics = nil
            return
        }
        let metrics = configuration.metrics(bounds, count)
        guard metrics != cachedMetrics else { return }
        cachedMetrics = metrics
        rootLayer.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<count {
            let centerX = metrics.originX
                + CGFloat(index) * (metrics.barWidth + metrics.spacing)
                + metrics.barWidth * 0.5
            let layer = capsuleLayers[index]
            // anchorPoint is (0.5, 0.5): the position fixes the center and the
            // bounds the size, so a height change grows the bar symmetrically
            // about centerY without touching position every frame.
            layer.position = CGPoint(x: centerX, y: metrics.centerY)
            layer.bounds = CGRect(x: 0, y: 0, width: metrics.barWidth, height: layer.bounds.height)
            layer.cornerRadius = metrics.cornerRadius
        }
        CATransaction.commit()
    }

    /// Per-frame hot path: only the height changes, so this rewrites nothing but
    /// each bar's `bounds` height. The display-level dynamic-range shaping is
    /// applied here (post-spring) so it's purely visual and never alters the
    /// spring feel.
    private func renderHeights() {
        guard let metrics = cachedMetrics, !capsuleLayers.isEmpty else { return }
        let boost = configuration.heightBoost
        let shaping = configuration.levelShaping
        let span = metrics.maxBarHeight - metrics.minHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<count {
            var value = min(1, max(0, position[index] * boost))
            if !shaping.isIdentity {
                value = shaping.ceiling * pow(value, shaping.gamma)
            }
            let height = metrics.minHeight + span * value
            let layer = capsuleLayers[index]
            if layer.bounds.height != height {
                layer.bounds = CGRect(x: 0, y: 0, width: metrics.barWidth, height: height)
            }
        }
        CATransaction.commit()
    }
}

//
//  AnimatedMediaControlButtons.swift
//  myPlayer2
//
//  kmgccc_player - Shared animated media control buttons for the Window Mini
//  Player and the Fullscreen Mini Player. Single implementation, two size
//  profiles. State motion uses MotionKit semantic tokens; the three-arrow
//  relay keeps its staged choreography while using the same Apple spring
//  vocabulary as the other control states.
//
//  All motion is driven by SwiftUI system springs and the relay state machine
//  — no per-frame timers, no display links. Idle cost is zero.
//

import SwiftUI
import MotionKit

// MARK: - Metrics

/// Lightweight size profile shared by every animated media control.
/// Hit targets and visual symbol sizes are deliberately separate: the hit
/// area stays generous even when the painted symbol is small.
struct AnimatedMediaControlMetrics: Equatable, Sendable {
    /// Square hit target (clickable area), points.
    var hitSize: CGFloat
    /// Side of the square stage the play/pause symbol is drawn into.
    var playSymbolSize: CGFloat
    /// Side of the square stage the skip (previous/next) arrows occupy.
    var navSymbolSize: CGFloat

    /// One arrow-lane pitch in the demo's 134-unit viewBox (arrows sit 40 apart).
    var navLaneWidth: CGFloat { navSymbolSize * (40 / 134) }
    /// Standby arrow entry inset (demo uses -15 units).
    var navStandbyEnterOffset: CGFloat { navSymbolSize * (15 / 134) }

    /// Window Mini Player: original 26 pt hit targets. Play stays the visual
    /// anchor; the skip stage is larger than the play stage because the demo
    /// arrows only fill ~60% of their viewBox.
    static let windowMiniPlayer = AnimatedMediaControlMetrics(
        hitSize: 26,
        playSymbolSize: 18,
        navSymbolSize: 28
    )

    /// Fullscreen Mini Player: derived from the responsive bar scale so it
    /// tracks the existing `controlSize` hit footprint exactly.
    static func fullscreenMiniPlayer(scale: CGFloat) -> AnimatedMediaControlMetrics {
        AnimatedMediaControlMetrics(
            hitSize: 36 * scale,
            playSymbolSize: 20 * scale,
            navSymbolSize: 35 * scale
        )
    }
}

// MARK: - Shared press/cancel/release hit area

/// Owns the pointer lifecycle shared by all media buttons:
/// - press while the pointer is inside,
/// - cancel the whole session once the pointer leaves (no command fires),
/// - release while still inside commits the action.
private struct AnimatedControlHitArea<Content: View>: View {
    let hitSize: CGFloat
    let enabled: Bool
    let label: Text
    let content: Content
    let onPress: () -> Void
    let onCancel: () -> Void
    let onRelease: () -> Void

    @State private var isHolding = false
    @State private var sessionCancelled = false

    private var bounds: CGRect {
        CGRect(origin: .zero, size: CGSize(width: hitSize, height: hitSize))
    }

    var body: some View {
        content
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .gesture(dragGesture, including: .all)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { commitFromKeyboard() }
            .accessibilityLabel(label)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard enabled else { return }
                if sessionCancelled { return }
                let slopBounds = bounds.insetBy(dx: -8, dy: -8)
                if slopBounds.contains(value.location) {
                    if !isHolding {
                        isHolding = true
                        onPress()
                    }
                } else if isHolding {
                    isHolding = false
                    sessionCancelled = true
                    onCancel()
                }
            }
            .onEnded { value in
                guard enabled else { return }
                if isHolding {
                    isHolding = false
                    if sessionCancelled {
                        onCancel()
                    } else {
                        onRelease()
                    }
                }
                sessionCancelled = false
            }
    }

    private func commitFromKeyboard() {
        guard enabled, !isHolding else { return }
        onRelease()
    }
}

// MARK: - Play / Pause

/// Animated play/pause button. The visible symbol follows the *source of
/// truth* `isPlaying`; the component never keeps a long-lived rival state.
/// Rapid re-clicks interrupt any in-flight animation cleanly because every
/// gesture phase retargets the same pair of state values.
struct AnimatedPlayPauseButton: View {
    let isPlaying: Bool
    let enabled: Bool
    let metrics: AnimatedMediaControlMetrics
    let color: Color
    let disabledColor: Color
    let blendMode: BlendMode
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    @State private var showingPlaySymbol: Bool
    @State private var symbolScale: CGFloat = 1
    @State private var symbolOpacity: CGFloat = 1
    @State private var handoffTask: Task<Void, Never>?
    @State private var isUserAnimating = false

    init(
        isPlaying: Bool,
        enabled: Bool,
        metrics: AnimatedMediaControlMetrics,
        color: Color,
        disabledColor: Color,
        blendMode: BlendMode = .normal,
        action: @escaping () -> Void
    ) {
        self.isPlaying = isPlaying
        self.enabled = enabled
        self.metrics = metrics
        self.color = color
        self.disabledColor = disabledColor
        self.blendMode = blendMode
        self.action = action
        // Playing shows the pause bars; paused shows the play triangle.
        _showingPlaySymbol = State(initialValue: !isPlaying)
    }

    var body: some View {
        AnimatedControlHitArea(
            hitSize: metrics.hitSize,
            enabled: enabled,
            label: Text(isPlaying ? "Pause" : "Play"),
            content: symbolStage
                .frame(width: metrics.playSymbolSize, height: metrics.playSymbolSize),
            onPress: press,
            onCancel: cancelPress,
            onRelease: release
        )
        .onChange(of: isPlaying) { _, newValue in
            syncToExternalState(newValue)
        }
        .onDisappear {
            handoffTask?.cancel()
            handoffTask = nil
            isUserAnimating = false
        }
    }

    // MARK: Symbol stage

    private var symbolStage: some View {
        ZStack {
            MediaControlPlaySymbol()
                .scaleEffect(showingPlaySymbol ? symbolScale : 0.001)
                .opacity(showingPlaySymbol ? symbolOpacity : 0)

            MediaControlPauseSymbol()
                .scaleEffect(showingPlaySymbol ? 0.001 : symbolScale)
                .opacity(showingPlaySymbol ? 0 : symbolOpacity)
        }
        .foregroundStyle(enabled ? color : disabledColor)
        .compositingGroup()
        .blendMode(enabled ? blendMode : .normal)
    }

    // MARK: Gesture phases

    private func press() {
        // A new press takes ownership of the symbol: any pending handoff from
        // a previous release must not fire mid-press and reset the values.
        cancelHandoff()
        isUserAnimating = true
        let targetScale: CGFloat = motionPolicy == .full ? 0.48 : 0.85
        let targetOpacity: CGFloat = motionPolicy == .full ? 0.88 : 0.9
        withAnimation(pressAnimation) {
            symbolScale = targetScale
            symbolOpacity = targetOpacity
        }
    }

    private func cancelPress() {
        cancelHandoff()
        isUserAnimating = false
        withAnimation(cancelAnimation) {
            symbolScale = 1
            symbolOpacity = 1
        }
    }

    private func release() {
        cancelHandoff()
        isUserAnimating = true

        // 1) Old symbol exits very fast.
        withAnimation(exitAnimation) {
            symbolScale = 0
            symbolOpacity = 0
        }
        // 2) The other symbol becomes the active one.
        showingPlaySymbol.toggle()

        if motionPolicy != .full {
            // Reduce Motion: gentle direct crossfade, no spring handoff.
            withAnimation(enterAnimation) {
                symbolScale = 1
                symbolOpacity = 1
            }
            isUserAnimating = false
        } else {
            // 3) 40 ms handoff delay, then the new symbol springs in from 0.05.
            handoffTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    symbolScale = 0.05
                    symbolOpacity = 0
                }
                withAnimation(enterAnimation) {
                    symbolScale = 1
                    symbolOpacity = 1
                }
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled else { return }
                isUserAnimating = false
            }
        }

        // 4) Let the exit transaction reach the render server before the
        // playback state changes trigger the rest of the UI graph.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func cancelHandoff() {
        handoffTask?.cancel()
        handoffTask = nil
    }

    /// External playback changes (other UI, system media keys) win only when
    /// the user is not actively animating the control locally.
    private func syncToExternalState(_ newValue: Bool) {
        guard !isUserAnimating else { return }
        let targetShowingPlay = !newValue
        guard targetShowingPlay != showingPlaySymbol else { return }
        cancelHandoff()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showingPlaySymbol = targetShowingPlay
            symbolScale = 1
            symbolOpacity = 1
        }
    }

    // MARK: MotionKit token parameters

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var pressAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.microInteraction])
    }

    private var cancelAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.gestureSettle])
    }

    private var exitAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.microInteraction])
    }

    private var enterAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.emphasis])
    }
}

// MARK: - Previous / Next

/// Animated previous/next button with a dual-channel ping-pong relay.
/// The command is handed off after one render opportunity so the first relay
/// frame is not competing with the track-switching state graph.
struct AnimatedSkipButton: View {
    enum Direction {
        case previous
        case next
    }

    let direction: Direction
    let enabled: Bool
    let metrics: AnimatedMediaControlMetrics
    let color: Color
    let disabledColor: Color
    let blendMode: BlendMode
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy

    @State private var symbolScale: CGFloat = 1
    @State private var symbolOpacity: CGFloat = 1

    // Dual-channel alternating relay state:
    // Channel A and Channel B alternate on every click so each animation
    // runs cleanly from a pristine initial state with zero transaction collisions.
    @State private var isChannelBActive: Bool = false
    @State private var channelAProgress: CGFloat = 0.0
    @State private var channelBProgress: CGFloat = 0.0

    init(
        direction: Direction,
        enabled: Bool,
        metrics: AnimatedMediaControlMetrics,
        color: Color,
        disabledColor: Color,
        blendMode: BlendMode = .normal,
        action: @escaping () -> Void
    ) {
        self.direction = direction
        self.enabled = enabled
        self.metrics = metrics
        self.color = color
        self.disabledColor = disabledColor
        self.blendMode = blendMode
        self.action = action
    }

    var body: some View {
        AnimatedControlHitArea(
            hitSize: metrics.hitSize,
            enabled: enabled,
            label: Text(direction == .previous ? "Previous Track" : "Next Track"),
            content: symbolStage
                .frame(width: metrics.navSymbolSize, height: metrics.navSymbolSize),
            onPress: press,
            onCancel: cancelPress,
            onRelease: release
        )
    }

    // MARK: Symbol stage

    private var symbolStage: some View {
        ZStack {
            if isChannelBActive {
                SingleRelayStage(
                    progress: channelBProgress,
                    direction: direction,
                    metrics: metrics
                )
                .transition(.identity)
            } else {
                SingleRelayStage(
                    progress: channelAProgress,
                    direction: direction,
                    metrics: metrics
                )
                .transition(.identity)
            }
        }
        .scaleEffect(symbolScale)
        .opacity(symbolOpacity)
        .foregroundStyle(enabled ? color : disabledColor)
        .compositingGroup()
        .blendMode(enabled ? blendMode : .normal)
    }

    // MARK: Gesture phases

    private func press() {
        let targetScale: CGFloat = motionPolicy == .full ? 0.62 : 0.85
        let targetOpacity: CGFloat = motionPolicy == .full ? 0.88 : 0.9
        withAnimation(pressAnimation) {
            symbolScale = targetScale
            symbolOpacity = targetOpacity
        }
    }

    private func cancelPress() {
        withAnimation(cancelAnimation) {
            symbolScale = 1
            symbolOpacity = 1
        }
    }

    private func release() {
        // 1. Immediate visual spring response on button:
        withAnimation(releaseAnimation) {
            symbolScale = 1
            symbolOpacity = 1
        }

        // 2. Immediate arrow relay on alternate channel:
        if motionPolicy == .full {
            if isChannelBActive {
                // Switching to Channel A:
                var resetTx = Transaction()
                resetTx.disablesAnimations = true
                withTransaction(resetTx) {
                    channelAProgress = 0.0
                    isChannelBActive = false
                }
                withAnimation(relayAnimation) {
                    channelAProgress = 1.0
                }
            } else {
                // Switching to Channel B:
                var resetTx = Transaction()
                resetTx.disablesAnimations = true
                withTransaction(resetTx) {
                    channelBProgress = 0.0
                    isChannelBActive = true
                }
                withAnimation(relayAnimation) {
                    channelBProgress = 1.0
                }
            }
        }

        // 3. Give the relay one render opportunity before entering the
        // track-switching pipeline.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    // MARK: Animation parameters

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private var pressAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.microInteraction])
    }

    private var cancelAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.gestureSettle])
    }

    private var releaseAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.emphasis])
    }

    /// Keeps the relay's deliberate 0.58s visual window while deriving its
    /// spring behavior and Reduce Motion response from the emphasis token.
    private var relayAnimation: Animation? {
        let relaySpec = motionTokens.phaseSpec(for: .emphasis, duration: 0.58)
        return motionPolicy.animation(for: relaySpec)
    }
}

// MARK: - Single Relay Stage

/// Renders the three arrows for a single relay run.
///
/// Geometric alignment:
/// - Arrow width on screen is exactly `navSymbolSize * (39.5677 / 134)`.
/// - Lane separation between arrows is `navSymbolSize * (40 / 134)`.
/// - The gliding arrow moves from `homeLane` to `awayLane`:
///     `glidingX = homeLane + progress * (awayLane - homeLane)`
/// - The standby arrow sits at `homeLane`, anchored at its flat vertical back edge:
///     `scaleEffect(progress, anchor: backAnchor)`
/// - Because the anchor is at the flat back edge, the standby arrow's sharp tip
///   expands forward at `homeLane - halfWidth + progress * arrowWidth`.
/// - The gliding arrow's flat back edge is at `glidingX - halfWidth = homeLane - halfWidth + progress * lane`.
///   Since `lane == arrowWidth`, `tip(standby) == back(gliding)` at EVERY frame!
///   The two triangles are in 100% gap-free contact across the entire animation!
/// - The exiting arrow shrinks to scale 0 and opacity 0 towards its tip in the first 35% of the duration (~0.2s),
///   matching the web demo's 0.2s ease-out exit.
/// - At the end of the animation (`progress == 1`), the gliding arrow settles at `awayLane` (scale 1.0),
///   the standby arrow settles at `homeLane` (scale 1.0), and the exiting arrow is invisible (scale 0.0).
private struct SingleRelayStage: View, Animatable {
    var progress: CGFloat
    let direction: AnimatedSkipButton.Direction
    let metrics: AnimatedMediaControlMetrics

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let lane = metrics.navLaneWidth
        let isNext = direction == .next

        let homeLane: CGFloat = isNext ? -lane / 2 : lane / 2
        let awayLane: CGFloat = -homeLane

        // Anchors inside the arrow stage:
        // Flat vertical back edge is at 0.35236 (or 0.64764 for mirrored).
        // Sharp tip is at 0.64764 (or 0.35236 for mirrored).
        let backAnchor = UnitPoint(x: isNext ? 0.35236 : 0.64764, y: 0.5)
        let tipAnchor = UnitPoint(x: isNext ? 0.64764 : 0.35236, y: 0.5)

        // Gliding arrow: starts at homeLane, glides to awayLane.
        let glidingX = homeLane + progress * (awayLane - homeLane)

        // Exiting arrow: shrinks from 1.0 to 0.0 towards tip in first 35% of motion (~200ms).
        let exitFraction = min(1.0, max(0.0, progress / 0.35))
        let exitingScale = 1.0 - exitFraction
        let exitingOpacity = 1.0 - exitFraction

        // Standby arrow: sits at homeLane.
        // Anchored at flat back edge. Tip stays touching the back edge of the gliding arrow!
        let standbyScale = max(0.0, progress)
        let standbyOpacity = min(1.0, progress * 3.0)

        ZStack {
            // 1. Standby arrow (emerges from behind at homeLane):
            MediaControlSkipArrowSymbol(mirrored: direction == .previous)
                .scaleEffect(standbyScale, anchor: backAnchor)
                .opacity(standbyOpacity)
                .offset(x: homeLane)

            // 2. Gliding arrow (moves from homeLane to awayLane):
            MediaControlSkipArrowSymbol(mirrored: direction == .previous)
                .offset(x: glidingX)

            // 3. Exiting arrow (shrinks away at awayLane):
            MediaControlSkipArrowSymbol(mirrored: direction == .previous)
                .scaleEffect(exitingScale, anchor: tipAnchor)
                .opacity(exitingOpacity)
                .offset(x: awayLane)
        }
    }
}

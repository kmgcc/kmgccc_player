//
//  PageTransitions.swift
//  myPlayer2
//
//  MotionKit-driven page switching and skeleton reveal wipe transitions.
//

import MotionKit
import SwiftUI

// MARK: - Page Switch Transition (Anti-Ghosting Sequential Upward Motion)

/// Animatable modifier for unified page switching across library destinations.
/// Implements "上移淡出" and "上移淡入" with staggered opacity timing:
/// - Outgoing view lifts up slightly (0 -> -10pt) and vanishes rapidly (1.0 -> 0.0 by progress 0.35),
///   completely dissolving before incoming content dominates.
/// - Incoming view rises from below (+14pt -> 0pt), softly appearing from progress 0.20 to 1.0.
/// This prevents overlapping 50% crossfade opacity, completely eliminating double-exposure ghosting.
public struct PageSwitchTransitionModifier: AnimatableModifier {
    public var progress: Double
    public var isIncoming: Bool

    public init(progress: Double, isIncoming: Bool) {
        self.progress = progress
        self.isIncoming = isIncoming
    }

    public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public func body(content: Content) -> some View {
        let (opacity, yOffset) = computeTransform()
        content
            .opacity(opacity)
            .offset(y: yOffset)
    }

    private func computeTransform() -> (opacity: Double, yOffset: Double) {
        let p = max(0, min(1, progress))
        if isIncoming {
            // Incoming: starts at progress = 0 (offset +14, opacity 0), settles at progress = 1 (offset 0, opacity 1)
            // Delays initial fade-in until progress >= 0.20 so outgoing content has dissolved.
            let fadeProgress = max(0, min(1, (p - 0.20) / 0.80))
            let yOffset = (1.0 - p) * 14.0
            return (fadeProgress, yOffset)
        } else {
            // Outgoing: starts at progress = 0 (offset 0, opacity 1), completes at progress = 1 (offset -10, opacity 0)
            // Rapid fade-out: fully transparent by progress 0.35 to eliminate ghosting!
            let fadeOutProgress = max(0, min(1, p / 0.35))
            let opacity = 1.0 - fadeOutProgress
            let yOffset = -p * 10.0
            return (opacity, yOffset)
        }
    }
}

// MARK: - Left to Right Wipe Transition

/// Animatable mask modifier that reveals incoming content from left to right,
/// or sweeps away outgoing placeholder content from left to right, with a soft gradient edge.
public struct LeftToRightWipeModifier: AnimatableModifier {
    public var progress: CGFloat
    public var isIncoming: Bool
    public var softEdgeWidth: CGFloat

    public init(progress: CGFloat, isIncoming: Bool, softEdgeWidth: CGFloat = 0.25) {
        self.progress = progress
        self.isIncoming = isIncoming
        self.softEdgeWidth = softEdgeWidth
    }

    public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    public func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        let span = 1.0 + softEdgeWidth
        let edgeStart = p * span - softEdgeWidth
        let edgeEnd = p * span

        let p1 = max(0, min(1, edgeStart))
        let p2 = max(0, min(1, edgeEnd))

        if isIncoming {
            // Incoming: sweeps revealed (.black) from left to right
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: p1),
                        .init(color: .clear, location: p2),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            // Outgoing: sweeps clear (.clear) from left to right
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: p1),
                        .init(color: .black, location: p2),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

// MARK: - AnyTransition Extensions

public extension AnyTransition {
    /// Left-to-right wipe mask transition for skeleton-to-content transitions.
    /// New content sweeps in from left to right while placeholder sweeps out from left to right.
    static var leftToRightWipe: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: LeftToRightWipeModifier(progress: 0, isIncoming: true),
                identity: LeftToRightWipeModifier(progress: 1, isIncoming: true)
            ),
            removal: .modifier(
                active: LeftToRightWipeModifier(progress: 1, isIncoming: false),
                identity: LeftToRightWipeModifier(progress: 0, isIncoming: false)
            )
        )
    }

    /// Unified page transition for navigating between library views.
    /// Features staggered upward-motion and non-overlapping fade to prevent ghosting.
    static var pageSwitchMotion: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PageSwitchTransitionModifier(progress: 0, isIncoming: true),
                identity: PageSwitchTransitionModifier(progress: 1, isIncoming: true)
            ),
            removal: .modifier(
                active: PageSwitchTransitionModifier(progress: 1, isIncoming: false),
                identity: PageSwitchTransitionModifier(progress: 0, isIncoming: false)
            )
        )
    }
}

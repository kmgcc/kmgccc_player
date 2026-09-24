//
//  PageTransitions.swift
//  myPlayer2
//
//  MotionKit-driven page switching and skeleton reveal wipe transitions.
//

import MotionKit
import SwiftUI

// MARK: - Left to Right Wipe Transition

/// Animatable mask modifier that reveals incoming content from left to right,
/// or vanishes outgoing content from left to right, with a smooth gradient boundary.
public struct LeftToRightWipeModifier: AnimatableModifier {
    public var progress: CGFloat
    public var isIncoming: Bool
    public var softEdgeWidth: CGFloat

    public init(progress: CGFloat, isIncoming: Bool, softEdgeWidth: CGFloat = 0.20) {
        self.progress = progress
        self.isIncoming = isIncoming
        self.softEdgeWidth = softEdgeWidth
    }

    public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    public func body(content: Content) -> some View {
        content.mask(
            GeometryReader { _ in
                let span = 1.0 + softEdgeWidth
                let effectiveProgress = max(0, min(1, progress))
                let edgeStart = effectiveProgress * span - softEdgeWidth
                let edgeEnd = effectiveProgress * span

                let p1 = max(0, min(1, edgeStart))
                let p2 = max(0, min(1, edgeEnd))

                if isIncoming {
                    // Left is revealed (.black), right is hidden (.clear)
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
                } else {
                    // Left is vanished (.clear), right is still visible (.black)
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
                }
            }
        )
    }
}

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

    /// Vertical slide + fade page transition for navigating between library views.
    /// Outgoing content slides up and fades out; incoming content slides in from below and fades in.
    static var pageSwitchMotion: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 18)),
            removal: .opacity.combined(with: .offset(y: -18))
        )
    }
}

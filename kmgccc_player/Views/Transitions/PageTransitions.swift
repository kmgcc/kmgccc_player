//
//  PageTransitions.swift
//  myPlayer2
//
//  MotionKit-driven page switching and skeleton reveal wipe transitions.
//

import AppKit
import MotionKit
import SwiftUI

extension MotionTokens {
    /// A compact, non-bouncy phase of the shared navigation motion.
    /// `phaseSpec` keeps custom Motion Kit speed scaling intact.
    var pageSwitch: MotionSpec {
        phaseSpec(
            for: .navigation,
            duration: 0.36,
            bounce: 0,
            blendDuration: 0.04
        )
    }
}

/// A fixed-size presentation surface shared by Home and center-pane routes.
/// The native compositor owns motion; descendant layout and interaction
/// animations stay independent of navigation.
struct PagePresentation<Content: View, Placeholder: View>: View {
    let revision: String
    var isPresented = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.self) private var environment
    @Environment(\.motionTokens) private var tokens
    @Environment(\.motionPolicy) private var policy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            NativePagePresentation(
                revision: revision,
                isPresented: isPresented,
                spec: policy.resolving(accessibilityReduceMotion: reduceMotion).resolve(tokens.pageSwitch),
                usesSpatialMotion: !reduceMotion && policy == .full,
                content: AnyView(content()
                    .environment(\.self, environment)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .ignoresSafeArea(.container, edges: .all)),
                placeholder: AnyView(placeholder()
                    .environment(\.self, environment)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .ignoresSafeArea(.container, edges: .all))
            )
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

}

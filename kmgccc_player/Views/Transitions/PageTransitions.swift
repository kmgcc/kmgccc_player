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
            duration: 0.30,
            bounce: 0,
            blendDuration: 0.04
        )
    }
}

/// One presentation boundary per page. Replacement never keeps a live outgoing
/// page around or animates the destination's initial size and column layout.
struct PagePresentation<Content: View, Placeholder: View>: View {
    let revision: String
    var isPresented = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.motionTokens) private var tokens
    @Environment(\.motionPolicy) private var policy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var laidOutRevision: String?

    private var isRevealed: Bool { isPresented && laidOutRevision == revision }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                placeholder()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(isRevealed ? 0 : 1)
                    .allowsHitTesting(false)

                content()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .background {
                        PageLayoutCompletion(revision: revision) { completedRevision in
                            guard isPresented, completedRevision == revision else { return }
                            laidOutRevision = completedRevision
                        }
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                        if !isRevealed { transaction.disablesAnimations = true }
                    }
                    .opacity(isRevealed ? 1 : 0)
                    .allowsHitTesting(isRevealed)
                    .accessibilityHidden(!isRevealed)
            }
            .clipped()
            .animation(
                isRevealed ? policy.resolvedAnimation(for: tokens.pageSwitch, accessibilityReduceMotion: reduceMotion) : nil,
                value: isRevealed
            )
        }
        .transaction { $0.animation = nil }
        .onChange(of: revision) { _, _ in laidOutRevision = nil }
        .onChange(of: isPresented) { _, presented in
            if !presented { laidOutRevision = nil }
        }
    }
}

/// Wait for the destination to receive its real AppKit bounds and finish a
/// layout turn. A revision check discards callbacks from rapid navigation.
private struct PageLayoutCompletion: NSViewRepresentable {
    let revision: String
    let onReady: (String) -> Void

    func makeNSView(context: Context) -> LayoutView { LayoutView() }

    func updateNSView(_ view: LayoutView, context: Context) {
        view.revision = revision
        view.onReady = onReady
        view.scheduleCompletion()
    }

    final class LayoutView: NSView {
        var revision = "" {
            didSet {
                guard oldValue != revision else { return }
                generation &+= 1
                deliveredRevision = nil
                scheduledRevision = nil
            }
        }
        var onReady: ((String) -> Void)?
        private var generation: UInt = 0
        private var scheduledRevision: String?
        private var deliveredRevision: String?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleCompletion()
        }

        override func layout() {
            super.layout()
            scheduleCompletion()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleCompletion()
        }

        func scheduleCompletion() {
            guard window != nil, bounds.width > 0, bounds.height > 0,
                  deliveredRevision != revision, scheduledRevision != revision else { return }
            let expected = revision
            let expectedGeneration = generation
            scheduledRevision = expected
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.superview?.layoutSubtreeIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, self.generation == expectedGeneration else { return }
                    self.deliveredRevision = expected
                    self.scheduledRevision = nil
                    self.onReady?(expected)
                }
            }
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

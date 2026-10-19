//
//  FullscreenBottomControlsAnimationPolicy.swift
//  myPlayer2
//
//  Keeps fullscreen bottom-control geometry animation separate from control
//  foreground rendering. Geometry may spring between layouts, while semantic
//  colors, AppKit-backed controls, and compositing buffers must resolve directly
//  to their final state instead of inheriting the layout transaction.
//

import MotionKit
import SwiftUI

extension MotionTokens {
    /// A little rebound for the player's compact controls, without changing
    /// navigation or the rest of the application's layout motion.
    var miniPlayerLayout: MotionSpec {
        phaseSpec(for: .layout, duration: 0.46, bounce: 0.24)
    }

    var miniPlayerControl: MotionSpec {
        phaseSpec(for: .control, duration: 0.30, bounce: 0.18)
    }
}

/// A presentation fraction, rather than a Boolean, owns all intermediate
/// geometry for the mini-player controls and progress row.
struct MiniPlayerInterpolatedContent<Content: View>: View, Animatable {
    var fraction: CGFloat
    let clampsFraction: Bool
    let isolatesGeometryAnimation: Bool
    let content: (CGFloat) -> Content

    init(
        _ fraction: CGFloat,
        clampsFraction: Bool = true,
        isolatesGeometryAnimation: Bool = true,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.fraction = fraction
        self.clampsFraction = clampsFraction
        self.isolatesGeometryAnimation = isolatesGeometryAnimation
        self.content = content
    }

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    @ViewBuilder
    var body: some View {
        // Layout keeps the spring's overshoot; opacity and masks still need a
        // bounded sample. Clamping layout here flattens the entire rebound.
        let sample = content(clampsFraction ? min(1, max(0, fraction)) : fraction)
        if isolatesGeometryAnimation {
            sample.isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
        } else {
            // Window Mini Player uses a regular HStack, so its interpolated
            // contents must receive the same transaction as the outer row.
            sample
        }
    }
}

private struct FullscreenBottomControlsGeometryAnimationKey: TransactionKey {
    static let defaultValue = false
}

enum FullscreenBottomControlsAnimationPolicy {
    static func animateGeometry(
        with animation: Animation?,
        _ updates: () -> Void
    ) {
        var transaction = Transaction()
        transaction.animation = animation
        transaction[FullscreenBottomControlsGeometryAnimationKey.self] = true
        withTransaction(transaction, updates)
    }

    static func isolateRendering(from transaction: inout Transaction) {
        guard transaction[FullscreenBottomControlsGeometryAnimationKey.self] else { return }
        transaction.animation = nil
    }
}

extension View {
    /// Prevents the fullscreen controls' layout spring from interpolating
    /// semantic colors or caching a transient AppKit/compositing appearance.
    /// Apply this inside the layout-owning frame, on fixed-size foreground
    /// leaves or fixed-footprint sections. Applying it to the Mini Player's
    /// root layout would make its contents jump to the final width while the
    /// outer glass pill is still animating.
    /// Explicit animations created inside the control remain intact because
    /// they do not carry the geometry-animation transaction key.
    func isolatesFullscreenBottomControlRenderingFromGeometryAnimation() -> some View {
        transaction { transaction in
            FullscreenBottomControlsAnimationPolicy.isolateRendering(from: &transaction)
        }
    }
}

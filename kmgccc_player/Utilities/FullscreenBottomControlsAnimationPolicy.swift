//
//  FullscreenBottomControlsAnimationPolicy.swift
//  myPlayer2
//
//  Keeps fullscreen bottom-control geometry animation separate from control
//  foreground rendering. Geometry may spring between layouts, while semantic
//  colors, AppKit-backed controls, and compositing buffers must resolve directly
//  to their final state instead of inheriting the layout transaction.
//

import SwiftUI

private struct FullscreenBottomControlsGeometryAnimationKey: TransactionKey {
    static let defaultValue = false
}

enum FullscreenBottomControlsAnimationPolicy {
    static func animateGeometry(
        with animation: Animation,
        _ updates: () -> Void
    ) {
        var transaction = Transaction(animation: animation)
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
    /// Explicit animations created inside the control remain intact because
    /// they do not carry the geometry-animation transaction key.
    func isolatesFullscreenBottomControlRenderingFromGeometryAnimation() -> some View {
        transaction { transaction in
            FullscreenBottomControlsAnimationPolicy.isolateRendering(from: &transaction)
        }
    }
}

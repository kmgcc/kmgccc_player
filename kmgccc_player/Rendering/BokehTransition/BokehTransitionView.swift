//
//  BokehTransitionView.swift
//  myPlayer2
//

import MetalKit
import SwiftUI

/// The narrow SwiftUI/AppKit boundary for the Bokeh surface. SwiftUI owns all
/// transition targets; the renderer advances presentation values on its own
/// 60 fps draw clock. `NSViewRepresentable` does not reliably receive SwiftUI's
/// intermediate Animatable values, so using it as the animation clock produces
/// one-frame jumps on macOS.
struct BokehTransitionSurface: NSViewRepresentable {
    var snapshot: BokehTransitionSnapshot
    var sourceSet: BokehTransitionPreparedSourceSet?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: BokehTransitionMetalContext.shared.device)
        // Match the reference SPBokeh pipeline exactly: shaders perform the
        // sRGB transfer explicitly and the drawable stores encoded sRGB bytes.
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.delegate = context.coordinator.renderer
        installSourceIfNeeded(in: view, coordinator: context.coordinator)
        context.coordinator.renderer.update(snapshot: snapshot)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        installSourceIfNeeded(in: view, coordinator: context.coordinator)
        context.coordinator.renderer.update(snapshot: snapshot)
        // surfaceOpacity is a lifecycle gate, not an optical animation. Bokeh
        // intensity is represented exclusively by the animated radius. The
        // renderer's draw(in:) sets view.alphaValue to the animated
        // opticalOpacity each frame; here we only ensure it is 0 when the
        // surface should be fully hidden (dormant or unavailable).
        if snapshot.surfaceOpacity <= 0.5 {
            view.alphaValue = 0
        }
        let shouldDraw = snapshot.isActive && context.coordinator.renderer.isAvailable
        if !shouldDraw {
            // A missing or rejected runtime library must never leave a stale
            // drawable above the Gaussian fallback.
            view.alphaValue = 0
        }
        view.isPaused = !shouldDraw
        if shouldDraw {
            view.setNeedsDisplay(view.bounds)
        }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer.releaseTextures()
    }

    private func installSourceIfNeeded(in view: MTKView, coordinator: Coordinator) {
        guard let sourceSet else { return }
        guard coordinator.sourceIdentity != sourceSet.identity else { return }
        coordinator.renderer.install(sourceSet)
        coordinator.sourceIdentity = sourceSet.identity
        view.drawableSize = sourceSet.identity.renderSize.cgSize
    }

    @MainActor
    final class Coordinator {
        let renderer = BokehTransitionRenderer()
        var sourceIdentity: BokehTransitionSourceIdentity?
    }
}

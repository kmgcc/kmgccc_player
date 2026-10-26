//
//  BokehTransitionView.swift
//  myPlayer2
//

import MetalKit
import SwiftUI

/// The narrow SwiftUI/AppKit boundary for the Bokeh surface. SwiftUI owns all
/// transition targets; the renderer advances presentation values on its own
/// draw clock, which follows the display's maximum refresh rate.
/// `NSViewRepresentable` does not reliably receive SwiftUI's intermediate
/// Animatable values, so using it as the animation clock produces one-frame
/// jumps on macOS.
struct BokehTransitionSurface: NSViewRepresentable {
    var snapshot: BokehTransitionSnapshot
    var sourceSet: BokehTransitionSourceSet?
    var liveFeed: BokehLiveCoverFeed?
    var onSourceReady: ((BokehTransitionSourceIdentity) -> Void)? = nil
    var onSurfaceStateChange: ((BokehTransitionSurfaceState) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BokehTransitionMTKView {
        let view = BokehTransitionMTKView(frame: .zero, device: BokehTransitionMetalContext.shared.device)
        // Display P3 shares the sRGB transfer curve used explicitly by the
        // shaders. Preserve the settled panorama's gamut through the drawable.
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        view.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        view.matchDisplayRefreshRate()
        view.delegate = context.coordinator.renderer
        configure(context.coordinator)
        installSourceIfNeeded(in: view, coordinator: context.coordinator)
        context.coordinator.renderer.update(snapshot: snapshot)
        return view
    }

    func updateNSView(_ view: BokehTransitionMTKView, context: Context) {
        configure(context.coordinator)
        installSourceIfNeeded(in: view, coordinator: context.coordinator)
        context.coordinator.renderer.update(snapshot: snapshot)
        // A cover being replaced keeps drawing until its successor is
        // uploaded; the renderer then dissolves between the two.
        let hasInstalledSource = sourceSet != nil && context.coordinator.renderer.hasCover
        let shouldDraw = snapshot.isActive
            && context.coordinator.renderer.isAvailable
            && hasInstalledSource
        if !shouldDraw || snapshot.surfaceOpacity <= 0.5 {
            // A dormant surface, or a missing or rejected runtime library,
            // must never leave a stale drawable above the settled layers.
            // While drawing, the renderer sets the opacity every frame.
            view.alphaValue = 0
        }
        if shouldDraw, view.isPaused { view.matchDisplayRefreshRate() }
        view.isPaused = !shouldDraw
        DebugUIHooks.record(
            "bokeh-surface draw=\(shouldDraw) source=\(hasInstalledSource) "
            + "ready=\(context.coordinator.renderer.isAvailable) "
            + "active=\(snapshot.isActive) surface=\(snapshot.surfaceOpacity) "
            + "pos=\(snapshot.transitionPosition) radius=\(snapshot.bokehRadius) "
            + "handoff=\(snapshot.handoffOpacity) holds=\(snapshot.keepsSurfaceOpaque) "
            + "fps=\(view.preferredFramesPerSecond)"
        )
    }

    static func dismantleNSView(_ view: BokehTransitionMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.installTask?.cancel()
        coordinator.installTask = nil
        coordinator.sourceIdentity = nil
        coordinator.onSourceReady = nil
        coordinator.renderer.onSurfaceStateChange = nil
        coordinator.renderer.liveFeed = nil
        coordinator.renderer.releaseTextures()
    }

    private func configure(_ coordinator: Coordinator) {
        coordinator.snapshot = snapshot
        coordinator.onSourceReady = onSourceReady
        coordinator.renderer.liveFeed = liveFeed
        coordinator.renderer.onSurfaceStateChange = onSurfaceStateChange
    }

    private func installSourceIfNeeded(in view: MTKView, coordinator: Coordinator) {
        guard let sourceSet else {
            let hadSource = coordinator.sourceIdentity != nil || coordinator.installTask != nil
            coordinator.installTask?.cancel()
            coordinator.installTask = nil
            coordinator.sourceIdentity = nil
            if hadSource {
                coordinator.renderer.releaseTextures()
            }
            return
        }

        if coordinator.sourceIdentity == sourceSet.identity {
            return
        }
        coordinator.installTask?.cancel()
        coordinator.sourceIdentity = sourceSet.identity
        if coordinator.renderer.isReady(for: sourceSet.identity) {
            view.drawableSize = sourceSet.identity.renderSize.cgSize
            coordinator.installTask = Task { @MainActor [weak coordinator] in
                guard !Task.isCancelled, let coordinator,
                      coordinator.sourceIdentity == sourceSet.identity else { return }
                coordinator.installTask = nil
                coordinator.onSourceReady?(sourceSet.identity)
            }
            return
        }
        coordinator.installTask = Task { @MainActor [weak coordinator, weak view] in
            guard let renderer = coordinator?.renderer else { return }
            let installed = await renderer.install(sourceSet)
            guard !Task.isCancelled, let coordinator, let view,
                  coordinator.sourceIdentity == sourceSet.identity else { return }
            coordinator.installTask = nil
            guard installed else {
                coordinator.sourceIdentity = nil
                return
            }
            // The drawable is exactly the source's render size; the cover
            // geometry is computed in view points, so it lines up with the
            // settled layer whatever the rounding.
            view.drawableSize = sourceSet.identity.renderSize.cgSize
            renderer.update(snapshot: coordinator.snapshot)
            view.isPaused = !coordinator.snapshot.isActive
            coordinator.onSourceReady?(sourceSet.identity)
        }
    }

    @MainActor
    final class Coordinator {
        let renderer = BokehTransitionRenderer()
        var sourceIdentity: BokehTransitionSourceIdentity?
        var installTask: Task<Void, Never>?
        var snapshot = BokehTransitionSnapshot.inactive
        var onSourceReady: ((BokehTransitionSourceIdentity) -> Void)?
    }
}

/// Follows the screen it is on: 60 Hz displays draw at 60, ProMotion and
/// other high-refresh displays at their maximum.
final class BokehTransitionMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchDisplayRefreshRate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchDisplayRefreshRate()
    }

    func matchDisplayRefreshRate() {
        let maximum = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        let target = max(60, maximum)
        if preferredFramesPerSecond != target { preferredFramesPerSecond = target }
    }
}

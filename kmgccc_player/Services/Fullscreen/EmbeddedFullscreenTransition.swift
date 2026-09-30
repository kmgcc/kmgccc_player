import AppKit
import MotionKit
import SwiftUI

/// Animates the complete native scene above the unchanged main window.
/// The original view remains live; there is no bitmap capture or resizing.
@MainActor
final class EmbeddedFullscreenTransition {
    private enum Direction { case entering, exiting }
    private weak var window: NSWindow?
    private var contentHost: NSHostingView<AnyView>?
    private var container: NSView?
    private var direction: Direction?
    private var generation = 0
    private var entryReady = false
    private var motionStarted = false
    private var stableLayoutCount = 0
    private var lastLayoutFingerprint: Int?
    private var completion: (() -> Void)?
    private var onEntered: (() -> Void)?
    private var spec: MotionSpec?
    private var spatial = true
    private var prepareToken: FirstUseHitchToken?

    func isAttached(to window: NSWindow) -> Bool { self.window === window }

    func beginEntry(in window: NSWindow, completion: @escaping () -> Void) {
        cancel()
        self.window = window
        direction = .entering
        self.completion = completion
        prepareToken = FirstUseHitchDiagnostics.begin("EmbeddedFullscreen.prepare")
        configureMotion(tokens: .standard, policy: .system(accessibilityReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    }

    func mount(_ host: NSHostingView<AnyView>, in window: NSWindow) {
        guard let content = window.contentView else { return }
        contentHost = host
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.opacity = 0
        host.autoresizingMask = [.width, .height]
        surface.addSubview(host)
        container = surface
        (content.superview ?? content).addSubview(surface, positioned: .above, relativeTo: nil)
        layoutContentHost()
    }

    func layoutContentHost() {
        guard let host = contentHost, let container, let content = window?.contentView,
              let root = container.superview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = content.convert(content.bounds, to: root)
        host.frame = container.bounds
        CATransaction.commit()
    }

    func entryDidLayout(tokens: MotionTokens, policy: MotionPolicy, onPresented: @escaping () -> Void) {
        guard direction == .entering, !entryReady else { return }
        configureMotion(tokens: tokens, policy: policy)
        onEntered = onPresented
        entryReady = true
        checkEntryLayout(generation: generation)
    }

    private func checkEntryLayout(generation expected: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected, self.direction == .entering,
                  !self.motionStarted, let host = self.contentHost else { return }
            self.layoutContentHost()
            host.layoutSubtreeIfNeeded()
            var hasher = Hasher()
            var pending: [NSView] = [host]
            while let view = pending.popLast() {
                guard !view.isHidden else { continue }
                let rect = view.convert(view.bounds, to: host)
                guard rect.intersects(host.bounds) else { continue }
                for value in [rect.minX, rect.minY, rect.width, rect.height] {
                    hasher.combine(Int((value * 2).rounded()))
                }
                pending.append(contentsOf: view.subviews)
            }
            let fingerprint = hasher.finalize()
            self.stableLayoutCount = fingerprint == self.lastLayoutFingerprint ? self.stableLayoutCount + 1 : 0
            self.lastLayoutFingerprint = fingerprint
            if self.stableLayoutCount >= 1 {
                self.endPreparation()
                self.animate(entering: true)
            } else {
                self.checkEntryLayout(generation: expected)
            }
        }
    }

    func beginExit(completion: @escaping () -> Void) {
        endPreparation()
        onEntered = nil
        if direction == .entering && !motionStarted {
            container?.removeFromSuperview()
            container = nil
            contentHost = nil
        }
        generation += 1
        direction = .exiting
        motionStarted = false
        self.completion = completion
    }

    func animateExit() {
        guard direction == .exiting, !motionStarted else { return }
        let expected = generation
        // Publish the restored toolbar/main visibility before moving the
        // fullscreen surface. The existing main views keep their final layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            self.animate(entering: false)
        }
    }

    private func configureMotion(tokens: MotionTokens, policy: MotionPolicy) {
        let resolved = policy.resolving(accessibilityReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        spec = resolved.resolve(tokens.phaseSpec(for: .navigation, duration: 0.58, bounce: 0, blendDuration: 0.04))
        spatial = resolved == .full
    }

    private func animate(entering: Bool) {
        motionStarted = true
        let expected = generation
        guard let container, let layer = container.layer, let spec else {
            completeMotion(generation: expected)
            return
        }
        let travel = container.bounds.height
        let radius: CGFloat = 32
        let startY = entering ? -travel : (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0)
        let startRadius = entering ? radius : (layer.presentation()?.cornerRadius ?? layer.cornerRadius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = true
        layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.cornerRadius = entering ? 0 : radius
        layer.setValue(spatial && !entering ? -travel : 0, forKeyPath: "transform.translation.y")
        layer.opacity = spatial || entering ? 1 : 0
        CATransaction.setCompletionBlock { [weak self] in self?.completeMotion(generation: expected) }
        if spatial {
            addSpring(spec, layer: layer, keyPath: "transform.translation.y", from: startY, to: entering ? 0 : -travel)
            addSpring(spec, layer: layer, keyPath: "cornerRadius", from: startRadius, to: entering ? 0 : radius)
        } else {
            addSpring(spec, layer: layer, keyPath: "opacity", from: entering ? 0 : 1, to: entering ? 1 : 0)
        }
        CATransaction.commit()
    }

    private func addSpring(_ spec: MotionSpec, layer: CALayer, keyPath: String, from: CGFloat, to: CGFloat) {
        let animation = spec.coreAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        layer.add(animation, forKey: "embedded.\(keyPath)")
    }

    private func completeMotion(generation expected: Int) {
        guard generation == expected else { return }
        if direction == .entering {
            onEntered?()
            onEntered = nil
        } else {
            container?.removeFromSuperview()
            container = nil
            contentHost = nil
            window = nil
        }
        direction = nil
        let done = completion
        completion = nil
        done?()
    }

    private func endPreparation() {
        if let prepareToken { FirstUseHitchDiagnostics.end(prepareToken) }
        prepareToken = nil
    }

    func cancel() {
        endPreparation()
        generation += 1
        container?.removeFromSuperview()
        container = nil
        contentHost = nil
        window = nil
        direction = nil
        completion = nil
        onEntered = nil
        entryReady = false
        motionStarted = false
        stableLayoutCount = 0
        lastLayoutFingerprint = nil
    }
}

/// Owns a native full-window host without changing the split-pane geometry.
struct EmbeddedFullscreenSurface<Content: View>: View {
    @Environment(\.self) private var environment
    @ViewBuilder var content: () -> Content

    var body: some View {
        NativeEmbeddedFullscreenSurface(content: AnyView(content().environment(\.self, environment)))
    }
}

private struct NativeEmbeddedFullscreenSurface: NSViewRepresentable {
    let content: AnyView
    func makeNSView(context: Context) -> Anchor { Anchor(content: content) }
    func updateNSView(_ view: Anchor, context: Context) { view.host.rootView = content }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {}

    final class Anchor: NSView {
        let host: NSHostingView<AnyView>
        init(content: AnyView) {
            host = NSHostingView(rootView: content)
            host.sizingOptions = []
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, host.superview == nil else { return }
            FullscreenWindowManager.shared.mountEmbeddedFullscreenHost(host, in: window)
        }
        override func layout() {
            super.layout()
            FullscreenWindowManager.shared.layoutEmbeddedFullscreenHost()
        }
    }
}

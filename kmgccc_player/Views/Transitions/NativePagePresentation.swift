import AppKit
import MotionKit
import SwiftUI

/// Keeps the destination at its final bounds while Core Animation reveals it.
/// A separate mask removes the placeholder at exactly the same moving edge.
struct NativePagePresentation: NSViewRepresentable {
    let revision: String
    let isPresented: Bool
    let spec: MotionSpec?
    let usesSpatialMotion: Bool
    let content: AnyView
    let placeholder: AnyView

    func makeNSView(context: Context) -> PageSurface {
        PageSurface()
    }

    func updateNSView(_ view: PageSurface, context: Context) {
        view.update(self)
    }

    static func dismantleNSView(_ view: PageSurface, coordinator: ()) {
        view.cancelPresentation()
    }

    @MainActor
    final class PageSurface: NSView {
        private let destinationClip = NSView()
        private let placeholderClip = NSView()
        private let destination = NSHostingView(rootView: AnyView(Color.clear))
        private let loading = NSHostingView(rootView: AnyView(Color.clear))
        private var configuration: NativePagePresentation?
        private var generation = 0
        private var isPreparing = true
        private var acceptsInteraction = false
        private var scheduledGeneration: Int?
        private var layoutFingerprint: Int?
        private var stableLayoutCount = 0
        private var topChromeInset: CGFloat = 0

        private var presentationBounds: CGRect {
            CGRect(x: bounds.minX, y: bounds.minY - topChromeInset,
                   width: bounds.width, height: bounds.height + topChromeInset)
        }

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // Lists draw above their layout viewport behind the toolbar.
            // The expanded child clips own that drawing boundary.
            clipsToBounds = false
            layer?.masksToBounds = false
            for (clip, host) in [(placeholderClip, loading), (destinationClip, destination)] {
                clip.wantsLayer = true
                clip.layer?.masksToBounds = true
                host.sizingOptions = []
                host.wantsLayer = true
                clip.addSubview(host)
                addSubview(clip)
            }
            destinationClip.layer?.opacity = 0
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard acceptsInteraction else { return nil }
            return super.hitTest(point)
        }

        func update(_ next: NativePagePresentation) {
            let startsPresentation = configuration?.revision != next.revision
                || configuration?.isPresented != next.isPresented
            configuration = next
            if startsPresentation {
                cancelPresentation()
                isPreparing = true
                acceptsInteraction = false
                layoutFingerprint = nil
                stableLayoutCount = 0
                withoutLayerActions {
                    destinationClip.layer?.opacity = 0
                    placeholderClip.layer?.opacity = 1
                }
            }
            installContent()
            installPlaceholder()
            needsLayout = true
            scheduleLayoutCheck()
        }

        private func installContent() {
            guard let configuration else { return }
            let preparing = isPreparing
            destination.rootView = AnyView(configuration.content
                .transaction { transaction in
                    if preparing {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .accessibilityHidden(preparing)
                .padding(.top, topChromeInset)
                .ignoresSafeArea(.container, edges: .all))
        }

        private func installPlaceholder() {
            guard let configuration else { return }
            loading.rootView = AnyView(configuration.placeholder
                .accessibilityHidden(true)
                .padding(.top, topChromeInset)
                .ignoresSafeArea(.container, edges: .all))
        }

        override func layout() {
            super.layout()
            if let contentView = window?.contentView {
                let frameInWindow = convert(bounds, to: contentView)
                let inset = max(0, contentView.bounds.maxY - frameInWindow.maxY)
                if abs(inset - topChromeInset) >= 0.5 {
                    topChromeInset = inset
                    installContent()
                    installPlaceholder()
                    layoutFingerprint = nil
                    stableLayoutCount = 0
                }
            }
            withoutLayerActions {
                destinationClip.frame = presentationBounds
                placeholderClip.frame = presentationBounds
                destination.frame = destinationClip.bounds
                loading.frame = placeholderClip.bounds
            }
            scheduleLayoutCheck()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                cancelPresentation()
            } else {
                scheduleLayoutCheck()
            }
        }

        private func scheduleLayoutCheck() {
            guard isPreparing, configuration?.isPresented == true,
                  window != nil, bounds.width > 0, bounds.height > 0,
                  scheduledGeneration != generation else { return }
            let expected = generation
            scheduledGeneration = expected
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                guard let self, self.generation == expected, self.isPreparing else { return }
                self.scheduledGeneration = nil
                guard self.window != nil, self.configuration?.isPresented == true else { return }
                self.layoutSubtreeIfNeeded()
                self.destination.layoutSubtreeIfNeeded()
                let fingerprint = self.visibleLayoutFingerprint()
                if let fingerprint, fingerprint == self.layoutFingerprint {
                    self.stableLayoutCount += 1
                } else {
                    self.layoutFingerprint = fingerprint
                    self.stableLayoutCount = 0
                }
                if fingerprint != nil, self.stableLayoutCount >= 2 {
                    self.reveal(expectedGeneration: expected)
                } else {
                    self.scheduleLayoutCheck()
                }
            }
        }

        /// Sample only visible native views, including table cells' hosting
        /// bounds. The outer SwiftUI frame alone cannot confirm row readiness.
        private func visibleLayoutFingerprint() -> Int? {
            var hasher = Hasher()
            var pending: [NSView] = [destination]
            while let view = pending.popLast() {
                let rect = view.convert(view.bounds, to: self)
                guard rect.intersects(presentationBounds), !view.isHidden else { continue }
                hasher.combine(ObjectIdentifier(view))
                for value in [rect.minX, rect.minY, rect.width, rect.height] {
                    hasher.combine(Int((value * 2).rounded()))
                }
                if let table = view as? NSTableView, table.numberOfRows > 0 {
                    let visible = table.rows(in: table.visibleRect)
                    // A restored scroll position may show only the bottom
                    // spacer. It has no visible rows and is already valid.
                    if visible.location != NSNotFound, visible.length > 0 {
                        for row in visible.location..<min(NSMaxRange(visible), table.numberOfRows) {
                            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
                                  let column = table.tableColumns.first,
                                  abs(cell.bounds.width - column.width) < 1 else { return nil }
                            cell.layoutSubtreeIfNeeded()
                        }
                    }
                }
                pending.append(contentsOf: view.subviews)
            }
            return hasher.finalize()
        }

        private func reveal(expectedGeneration: Int) {
            guard let configuration, let destinationLayer = destinationClip.layer,
                  let placeholderLayer = placeholderClip.layer else { return }
            isPreparing = false
            installContent()
            withoutLayerActions { destinationLayer.opacity = 1 }
            guard let spec = configuration.spec else {
                finishPresentation(expectedGeneration: expectedGeneration)
                return
            }

            if configuration.usesSpatialMotion {
                let incomingMask = CAGradientLayer()
                let outgoingMask = CAGradientLayer()
                let feather = min(112, max(64, bounds.width * 0.12))
                let travel = bounds.width + feather
                let maskWidth = travel * 2
                for mask in [incomingMask, outgoingMask] {
                    mask.anchorPoint = .zero
                    mask.bounds = CGRect(x: 0, y: 0, width: maskWidth, height: destinationClip.bounds.height)
                    mask.startPoint = CGPoint(x: 0, y: 0.5)
                    mask.endPoint = CGPoint(x: 1, y: 0.5)
                    mask.locations = [0, NSNumber(value: Double(bounds.width / maskWidth)), 0.5, 1]
                }
                let opaque = NSColor.black.cgColor
                let clear = NSColor.clear.cgColor
                incomingMask.colors = [opaque, opaque, clear, clear]
                outgoingMask.colors = [clear, clear, opaque, opaque]
                // Complementary gradients travel together. Only the feathered
                // edge blends the placeholder and destination; both are fully
                // opaque on their own side and final content is never faded.
                withoutLayerActions {
                    incomingMask.position = .zero
                    outgoingMask.position = .zero
                    destinationLayer.mask = incomingMask
                    placeholderLayer.mask = outgoingMask
                }
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    self?.finishPresentation(expectedGeneration: expectedGeneration)
                }
                addSpring(spec, to: incomingMask, keyPath: "position.x", from: -travel, toValue: 0)
                addSpring(spec, to: outgoingMask, keyPath: "position.x", from: -travel, toValue: 0)
                if let contentLayer = destination.layer {
                    addSpring(spec, to: contentLayer, keyPath: "transform.translation.x", from: 28, toValue: 0)
                }
                CATransaction.commit()
            } else {
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    self?.finishPresentation(expectedGeneration: expectedGeneration)
                }
                addSpring(spec, to: destinationLayer, keyPath: "opacity", from: 0, toValue: 1)
                withoutLayerActions { placeholderLayer.opacity = 0 }
                addSpring(spec, to: placeholderLayer, keyPath: "opacity", from: 1, toValue: 0)
                CATransaction.commit()
            }
        }

        private func addSpring(_ spec: MotionSpec, to layer: CALayer, keyPath: String, from: CGFloat, toValue: CGFloat) {
            let animation = spec.coreAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = toValue
            layer.add(animation, forKey: "page.\(keyPath)")
        }

        private func finishPresentation(expectedGeneration: Int) {
            guard generation == expectedGeneration, configuration?.isPresented == true else { return }
            withoutLayerActions {
                destinationClip.layer?.mask = nil
                placeholderClip.layer?.mask = nil
                placeholderClip.layer?.opacity = 0
                destinationClip.layer?.opacity = 1
            }
            acceptsInteraction = true
        }

        func cancelPresentation() {
            generation += 1
            scheduledGeneration = nil
            withoutLayerActions {
                destinationClip.layer?.mask = nil
                placeholderClip.layer?.mask = nil
                destinationClip.layer?.removeAllAnimations()
                placeholderClip.layer?.removeAllAnimations()
                destination.layer?.removeAllAnimations()
            }
        }

        private func withoutLayerActions(_ update: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            update()
            CATransaction.commit()
        }
    }
}

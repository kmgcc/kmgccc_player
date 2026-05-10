//
//  HomeWindowLayoutState.swift
//  myPlayer2
//
//  Slim observable state shared between the AppKit root view controller and
//  the full-window `HomeView` so that:
//    1. The root view controller publishes the window size.
//    2. The transparent center-pane placeholder publishes the live "center
//       content rect" (in window-content coordinates) — i.e. the rect bounded
//       by the sidebar and the right lyrics inspector.
//    3. The full-window `HomeView` reads that rect to decide which sections
//       align inside the center column (Hero / Playlists / Insights / footer)
//       and which extend to the full window width (album / artist carousels).
//
//  Architecture (one-way push, no two-way coupling):
//
//  ┌────────────────────────────┐  setWindowSize  ┌────────────────────────┐
//  │ AppKitMainSplitWindowCtrl  │ ──────────────▶ │ HomeWindowLayoutState  │
//  │ (root view did layout)     │                 │  .shared               │
//  └────────────────────────────┘                 │  geometry / isHomeMode │
//                                                  └───────────┬────────────┘
//                                                              │
//  ┌────────────────────────────┐  setCenterRect              │ read-only
//  │ AppKitMainContentPaneRoot  │ ─────────────────────────────┘
//  │ (transparent placeholder)  │
//  └────────────────────────────┘                              ▼
//                                                  ┌────────────────────────┐
//                                                  │ HomeView (full-window) │
//                                                  └────────────────────────┘
//

import AppKit
import Combine
import Foundation
import Observation

@MainActor
@Observable
final class HomeWindowLayoutState {
    static let shared = HomeWindowLayoutState()

    struct Geometry: Equatable {
        var windowWidth: CGFloat
        var windowHeight: CGFloat
        var centerMinXInWindow: CGFloat
        var centerMaxXInWindow: CGFloat
        var centerMinYInWindow: CGFloat
        var centerMaxYInWindow: CGFloat

        static let empty = Geometry(
            windowWidth: 0,
            windowHeight: 0,
            centerMinXInWindow: 0,
            centerMaxXInWindow: 0,
            centerMinYInWindow: 0,
            centerMaxYInWindow: 0
        )

        var hasValidLayout: Bool {
            windowWidth > 1 && centerMaxXInWindow > centerMinXInWindow + 1
        }

        var centerWidth: CGFloat {
            max(0, centerMaxXInWindow - centerMinXInWindow)
        }

        var centerHeight: CGFloat {
            max(0, centerMaxYInWindow - centerMinYInWindow)
        }

        /// Distance from the left window edge to the center pane's left edge
        /// (i.e. the visible width of the sidebar pane in window coordinates).
        var leftInset: CGFloat {
            max(0, centerMinXInWindow)
        }

        /// Distance from the center pane's right edge to the right window edge
        /// (i.e. the visible width of the right lyrics inspector pane).
        var rightInset: CGFloat {
            max(0, windowWidth - centerMaxXInWindow)
        }
    }

    /// Coarse, body-friendly snapshot of the layout. Mutates only when a
    /// discrete bucket changes, so SwiftUI views that read this property do
    /// NOT re-evaluate on every sub-pixel resize/divider-drag tick.
    /// Continuous geometry remains available via `geometry` for AppKit and
    /// CALayer consumers that must track pixels precisely.
    struct DiscreteSnapshot: Equatable {
        var hasValidLayout: Bool
        /// Center column width quantized to a coarse bucket (16pt steps), so
        /// content-mode-dependent paddings/font sizes only change in distinct
        /// jumps during resize, not every frame.
        var contentWidthBucket: Int
        var leftInset: Int
        var rightInset: Int
        var mode: ModeBucket

        enum ModeBucket: Int {
            case wide
            case medium
            case compact
            case narrow
        }

        static let empty = DiscreteSnapshot(
            hasValidLayout: false,
            contentWidthBucket: 0,
            leftInset: 0,
            rightInset: 0,
            mode: .wide
        )
    }

    /// Live window + center-pane geometry in window-content coordinates.
    var geometry: Geometry = .empty {
        didSet {
            geometryPublisher.send(geometry)
            let next = Self.makeDiscreteSnapshot(from: geometry)
            if next != discreteSnapshot {
                discreteSnapshot = next
            }
        }
    }

    /// Coarse layout snapshot for SwiftUI body consumers. Only changes when
    /// a discrete bucket flips (mode tier, integer pane insets, 16pt content
    /// width steps), so resize ticks within a bucket do not invalidate views.
    var discreteSnapshot: DiscreteSnapshot = .empty

    /// Continuous-geometry pipe for AppKit/CALayer consumers (e.g. the Home
    /// ambient shape layer host). Bypasses SwiftUI observation so live resize
    /// ticks do not propagate body invalidations.
    @ObservationIgnored
    let geometryPublisher = CurrentValueSubject<Geometry, Never>(.empty)

    private static let contentWidthBucketStep: CGFloat = 16

    private static func makeDiscreteSnapshot(from g: Geometry) -> DiscreteSnapshot {
        guard g.hasValidLayout else { return .empty }
        let centerW = g.centerWidth
        let modeBucket: DiscreteSnapshot.ModeBucket
        if centerW >= 980 {
            modeBucket = .wide
        } else if centerW >= 720 {
            modeBucket = .medium
        } else if centerW >= 560 {
            modeBucket = .compact
        } else {
            modeBucket = .narrow
        }
        return DiscreteSnapshot(
            hasValidLayout: true,
            contentWidthBucket: Int((centerW / contentWidthBucketStep).rounded()),
            leftInset: Int(g.leftInset.rounded()),
            rightInset: Int(g.rightInset.rounded()),
            mode: modeBucket
        )
    }

    /// True when the active library selection is `.home` and content mode is
    /// `.library`. This records navigation state only; AppKit hit-test
    /// routing must also check `allowsHomeInteraction` so modal/fullscreen
    /// surfaces can sit above Home without being bypassed.
    var isHomeMode: Bool = false

    /// True while the fullscreen player is hosted inside the main window's
    /// center pane. During this mode the full-window Home host may still exist
    /// in the AppKit hierarchy for background/sampling purposes, but it must
    /// not receive or be routed any mouse events.
    var isEmbeddedFullscreenActive: Bool = false

    /// True while the Home toolbar search field has text and the center pane
    /// is showing all-song search results instead of routing events to Home.
    var isHomeSearchActive: Bool = false

    var allowsHomeInteraction: Bool {
        isHomeMode && !isEmbeddedFullscreenActive && !isHomeSearchActive
    }

    /// Live frame of the Mini Player view in SwiftUI `.global` coordinates
    /// (top-left origin, matching the topmost `NSHostingView`'s bounds).
    /// Published by an `.onGeometryChange` probe wrapped around
    /// `MiniPlayerView()` in `AppKitMainContentPaneRoot`. Consumed by
    /// `HomeRoutingRootView.hitTest` and
    /// `CenterPanePassthroughHostingView.hitTest` to decide whether a click
    /// should be claimed by the Mini Player or routed to Home content.
    ///
    /// AppKit consumers must y-flip when comparing against window-content
    /// coordinates whose origin is bottom-left (i.e.
    /// `appkit_y = boundsHeight - swiftUI_maxY`).
    var miniPlayerFrameInWindow: CGRect = .zero

    private let layoutEpsilon: CGFloat = 1.5
    private let miniPlayerFrameEpsilon: CGFloat = 1

    private init() {}

    func setWindowSize(_ size: CGSize) {
        let quantizedSize = CGSize(
            width: quantize(size.width, step: layoutEpsilon),
            height: quantize(size.height, step: layoutEpsilon)
        )
        guard
            abs(geometry.windowWidth - quantizedSize.width) >= layoutEpsilon
                || abs(geometry.windowHeight - quantizedSize.height) >= layoutEpsilon
        else { return }
        var next = geometry
        next.windowWidth = quantizedSize.width
        next.windowHeight = quantizedSize.height
        geometry = next
    }

    func setGeometry(windowSize: CGSize, centerRect: CGRect) {
        let quantizedSize = CGSize(
            width: quantize(windowSize.width, step: layoutEpsilon),
            height: quantize(windowSize.height, step: layoutEpsilon)
        )
        let minX = quantize(centerRect.minX, step: layoutEpsilon)
        let maxX = quantize(centerRect.maxX, step: layoutEpsilon)
        let minY = quantize(centerRect.minY, step: layoutEpsilon)
        let maxY = quantize(centerRect.maxY, step: layoutEpsilon)
        guard
            abs(geometry.windowWidth - quantizedSize.width) >= layoutEpsilon
                || abs(geometry.windowHeight - quantizedSize.height) >= layoutEpsilon
                || abs(geometry.centerMinXInWindow - minX) >= layoutEpsilon
                || abs(geometry.centerMaxXInWindow - maxX) >= layoutEpsilon
                || abs(geometry.centerMinYInWindow - minY) >= layoutEpsilon
                || abs(geometry.centerMaxYInWindow - maxY) >= layoutEpsilon
        else { return }

        geometry = Geometry(
            windowWidth: quantizedSize.width,
            windowHeight: quantizedSize.height,
            centerMinXInWindow: minX,
            centerMaxXInWindow: maxX,
            centerMinYInWindow: minY,
            centerMaxYInWindow: maxY
        )
    }

    func setCenterRect(_ rect: CGRect) {
        let minX = quantize(rect.minX, step: layoutEpsilon)
        let maxX = quantize(rect.maxX, step: layoutEpsilon)
        let minY = quantize(rect.minY, step: layoutEpsilon)
        let maxY = quantize(rect.maxY, step: layoutEpsilon)
        guard
            abs(geometry.centerMinXInWindow - minX) >= layoutEpsilon
                || abs(geometry.centerMaxXInWindow - maxX) >= layoutEpsilon
                || abs(geometry.centerMinYInWindow - minY) >= layoutEpsilon
                || abs(geometry.centerMaxYInWindow - maxY) >= layoutEpsilon
        else { return }
        var next = geometry
        next.centerMinXInWindow = minX
        next.centerMaxXInWindow = maxX
        next.centerMinYInWindow = minY
        next.centerMaxYInWindow = maxY
        geometry = next
    }

    func setHomeMode(_ active: Bool) {
        guard isHomeMode != active else { return }
        isHomeMode = active
    }

    func setEmbeddedFullscreenActive(_ active: Bool) {
        guard isEmbeddedFullscreenActive != active else { return }
        isEmbeddedFullscreenActive = active
    }

    func setHomeSearchActive(_ active: Bool) {
        guard isHomeSearchActive != active else { return }
        isHomeSearchActive = active
    }

    func setMiniPlayerFrame(_ rect: CGRect) {
        guard
            abs(miniPlayerFrameInWindow.minX - rect.minX) >= miniPlayerFrameEpsilon
                || abs(miniPlayerFrameInWindow.minY - rect.minY) >= miniPlayerFrameEpsilon
                || abs(miniPlayerFrameInWindow.width - rect.width) >= miniPlayerFrameEpsilon
                || abs(miniPlayerFrameInWindow.height - rect.height) >= miniPlayerFrameEpsilon
        else { return }
        miniPlayerFrameInWindow = rect
    }

    private func quantize(_ value: CGFloat, step: CGFloat) -> CGFloat {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}

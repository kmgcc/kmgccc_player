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

    /// Live window + center-pane geometry in window-content coordinates.
    var geometry: Geometry = .empty

    /// True when the active library selection is `.home` and content mode is
    /// `.library`. The full-window Home host uses this to decide whether to
    /// display itself and accept events; the center-pane passthrough hosting
    /// view uses it as a hint that hits should fall through.
    var isHomeMode: Bool = false

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

    private init() {}

    func setWindowSize(_ size: CGSize) {
        guard
            abs(geometry.windowWidth - size.width) > 0.05
                || abs(geometry.windowHeight - size.height) > 0.05
        else { return }
        var next = geometry
        next.windowWidth = size.width
        next.windowHeight = size.height
        geometry = next
    }

    func setCenterRect(_ rect: CGRect) {
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        guard
            abs(geometry.centerMinXInWindow - minX) > 0.05
                || abs(geometry.centerMaxXInWindow - maxX) > 0.05
                || abs(geometry.centerMinYInWindow - minY) > 0.05
                || abs(geometry.centerMaxYInWindow - maxY) > 0.05
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

    func setMiniPlayerFrame(_ rect: CGRect) {
        guard
            abs(miniPlayerFrameInWindow.minX - rect.minX) > 0.05
                || abs(miniPlayerFrameInWindow.minY - rect.minY) > 0.05
                || abs(miniPlayerFrameInWindow.width - rect.width) > 0.05
                || abs(miniPlayerFrameInWindow.height - rect.height) > 0.05
        else { return }
        miniPlayerFrameInWindow = rect
    }
}

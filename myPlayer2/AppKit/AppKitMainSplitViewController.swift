//
//  AppKitMainSplitViewController.swift
//  myPlayer2
//
//  AppKit-driven three-column split that mirrors sidebar/lyrics visibility + widths
//  into UIStateViewModel (AppKit is source of truth; UIState is persistence/mirror).
//

import AppKit
import SwiftUI

@MainActor
final class AppKitMainSplitViewController: NSSplitViewController {
    static let mainLyricsDividerIndex = 1

    private let appSession: AppSessionHost
    let artBackgroundController = BKArtBackgroundController()
    let playlistPageController = PlaylistPageController()
    private let sidebarItem: NSSplitViewItem
    private let mainItem: NSSplitViewItem
    private let lyricsItem: NSSplitViewItem

    private var didApplyInitialLayout = false
    private(set) var isReadyForToolbarTracking = false
    var onToolbarTrackingReady: (() -> Void)?
    private var lastMirroredSidebarWidth: CGFloat = -1
    private var lastMirroredLyricsWidth: CGFloat = -1
    private var suspendedSidebarVisibilityForEmbeddedFullscreen: Bool?

    init(appSession: AppSessionHost) {
        self.appSession = appSession
        playlistPageController.rendersHeaderBackgroundInWindowLayer = true

        let sidebarController = NSHostingController(
            rootView: AppKitMainSidebarPaneRoot(appSession: appSession)
        )
        sidebarController.title = "sidebar"

        // Center pane uses a Home-aware hosting view: in Home mode hits
        // outside the actual Mini Player frame yield `nil` so the root
        // view's `HomeRoutingRootView` can divert clicks to the
        // full-window Home host. Hits inside the published Mini Player
        // rect (plus a tiny safety margin) keep standard SwiftUI
        // hit-testing so Mini Player buttons still work.
        //
        // We use a plain `NSViewController` subclass + a concrete
        // `NSHostingView` subclass instead of subclassing
        // `NSHostingController`. The latter pattern was *silently* not
        // honoring our `loadView()` override at runtime — the actual
        // pane view in the responder chain came back as a stock
        // `NSHostingView<AppKitMainContentPaneRoot>` (no subclass logs
        // ever fired). A plain `NSViewController` whose `loadView()`
        // assigns `view = CenterPanePassthroughHostingView(...)` is
        // a guaranteed install path.
        let mainController = CenterPanePassthroughViewController(
            rootView: AppKitMainContentPaneRoot(
                appSession: appSession,
                artBackgroundController: artBackgroundController,
                pageController: playlistPageController
            )
        )
        mainController.title = "main"

        let lyricsController = NSHostingController(
            rootView: AppKitMainLyricsPaneRoot(appSession: appSession)
        )
        lyricsController.title = "lyrics"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = Constants.Layout.sidebarMinWidth
        sidebarItem.maximumThickness = Constants.Layout.sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.18

        let mainItem = NSSplitViewItem(viewController: mainController)
        mainItem.minimumThickness = 560
        mainItem.canCollapse = false

        let lyricsItem = NSSplitViewItem(inspectorWithViewController: lyricsController)
        lyricsItem.minimumThickness = Constants.Layout.lyricsPanelMinWidth
        lyricsItem.maximumThickness = Constants.Layout.lyricsPanelMaxWidth
        lyricsItem.canCollapse = true
        lyricsItem.preferredThicknessFraction = 0.28

        self.sidebarItem = sidebarItem
        self.mainItem = mainItem
        self.lyricsItem = lyricsItem

        super.init(nibName: nil, bundle: nil)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
        addSplitViewItem(lyricsItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter
        splitView.autosaveName = "AppKitMainSplitView"
        splitView.delegate = self
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard !didApplyInitialLayout else { return }
        didApplyInitialLayout = true

        applyInitialLayoutFromMirroredState()
        mirrorSplitStateToUIState(reason: "initial")

        // Mark ready only after initial layout is applied and the split view has had a chance to lay out
        // its subviews, so tracking separator items can bind to divider indices without throwing.
        isReadyForToolbarTracking = true
        onToolbarTrackingReady?()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
        mirrorSplitStateToUIState(reason: "resize")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
    }

    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
        mirrorSplitStateToUIState(reason: "toggleSidebar")
    }

    override func toggleInspector(_ sender: Any?) {
        super.toggleInspector(sender)
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
        mirrorSplitStateToUIState(reason: "toggleInspector")
    }

    var isSidebarVisible: Bool {
        !sidebarItem.isCollapsed
    }

    var isLyricsVisible: Bool {
        !lyricsItem.isCollapsed
    }

    func setSidebarVisible(_ visible: Bool) {
        guard visible != isSidebarVisible else { return }
        sidebarItem.animator().isCollapsed = !visible
        splitView.adjustSubviews()
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
        mirrorSplitStateToUIState(reason: "setSidebarVisible")
    }

    func setLyricsVisible(_ visible: Bool) {
        guard visible != isLyricsVisible else { return }
        lyricsItem.animator().isCollapsed = !visible
        splitView.adjustSubviews()
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
        mirrorSplitStateToUIState(reason: "setLyricsVisible")
    }

    func setEmbeddedFullscreenActive(_ active: Bool) {
        if active {
            guard suspendedSidebarVisibilityForEmbeddedFullscreen == nil else { return }
            suspendedSidebarVisibilityForEmbeddedFullscreen = isSidebarVisible
            if isSidebarVisible {
                setSidebarVisible(false)
            }
            return
        }

        let shouldRestoreSidebar = suspendedSidebarVisibilityForEmbeddedFullscreen == true
        suspendedSidebarVisibilityForEmbeddedFullscreen = nil
        guard shouldRestoreSidebar else { return }
        setSidebarVisible(true)
    }

    private func applyInitialLayoutFromMirroredState() {
        let uiState = appSession.uiState

        sidebarItem.isCollapsed = !uiState.sidebarVisible
        lyricsItem.isCollapsed = !uiState.lyricsVisible

        if !sidebarItem.isCollapsed {
            let sidebarWidth = clampOrDefault(
                uiState.sidebarLastWidth,
                defaultValue: Constants.Layout.sidebarDefaultWidth,
                min: Constants.Layout.sidebarMinWidth,
                max: Constants.Layout.sidebarMaxWidth
            )
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }

        if !lyricsItem.isCollapsed {
            let sidebarWidth: CGFloat = sidebarItem.isCollapsed
                ? 0
                : (sidebarItem.viewController.view.frame.width)

            let maxLyricsGivenWindow = splitView.bounds.width
                - sidebarWidth
                - mainItem.minimumThickness

            let clampedMaxLyrics = Swift.max(
                Constants.Layout.lyricsPanelMinWidth,
                Swift.min(Constants.Layout.lyricsPanelMaxWidth, maxLyricsGivenWindow)
            )

            let lyricsWidth = clampOrDefault(
                uiState.lyricsWidth,
                defaultValue: Constants.Layout.lyricsPanelDefaultWidth,
                min: Constants.Layout.lyricsPanelMinWidth,
                max: clampedMaxLyrics
            )
            splitView.setPosition(splitView.bounds.width - lyricsWidth, ofDividerAt: Self.mainLyricsDividerIndex)
        }

        splitView.adjustSubviews()
        publishHomeLayoutGeometry(windowSize: view.bounds.size)
    }

    func publishHomeLayoutGeometry(windowSize: CGSize? = nil) {
        let mainView = mainItem.viewController.view
        let mainFrame = mainView.convert(mainView.bounds, to: splitView)
        let splitBounds = splitView.bounds
        guard splitBounds.width > 1, splitBounds.height > 1 else { return }

        let minX = Swift.max(0, mainFrame.minX)
        let maxX = Swift.min(splitBounds.width, mainFrame.maxX)
        guard maxX > minX + 1 else { return }

        let centerRect = CGRect(
            x: minX,
            y: 0,
            width: maxX - minX,
            height: splitBounds.height
        )

        if let windowSize {
            HomeWindowLayoutState.shared.setGeometry(windowSize: windowSize, centerRect: centerRect)
        } else {
            HomeWindowLayoutState.shared.setCenterRect(centerRect)
        }
    }

    private func mirrorSplitStateToUIState(reason: String) {
        let uiState = appSession.uiState

        let sidebarVisible = !sidebarItem.isCollapsed
        let lyricsVisible = !lyricsItem.isCollapsed
        if uiState.sidebarVisible != sidebarVisible {
            uiState.sidebarVisible = sidebarVisible
        }
        if uiState.lyricsVisible != lyricsVisible {
            uiState.lyricsVisible = lyricsVisible
        }

        if sidebarVisible {
            let width = sidebarItem.viewController.view.frame.width
            if abs(width - lastMirroredSidebarWidth) > 0.5 {
                lastMirroredSidebarWidth = width
                uiState.sidebarLastWidth = width
            }
        }

        if lyricsVisible {
            let width = lyricsItem.viewController.view.frame.width
            if abs(width - lastMirroredLyricsWidth) > 0.5 {
                lastMirroredLyricsWidth = width
                uiState.lyricsWidth = width
            }
        }
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    private func clampOrDefault(
        _ value: CGFloat,
        defaultValue: CGFloat,
        min: CGFloat,
        max: CGFloat
    ) -> CGFloat {
        let resolved = value > 0 ? value : defaultValue
        return clamp(resolved, min: min, max: max)
    }
}

// MARK: - Center pane hosting view

/// Concrete `NSHostingView` subclass installed as the split view's center
/// pane view. In Home mode, hits anywhere outside the actual Mini Player
/// rect yield `nil` so the parent root view's `HomeRoutingRootView` can
/// divert the click to the full-window Home host beneath the split view.
/// Hits inside the published Mini Player rect (plus a small safety
/// margin) keep standard SwiftUI hit-testing so Mini Player buttons still
/// receive clicks.
///
/// We use a *concrete* (non-generic) subclass paired with a plain
/// `NSViewController` (not `NSHostingController`) because the
/// `NSHostingController.loadView` override pattern was not actually
/// installing the subclass at runtime — the responder chain showed a
/// stock `NSHostingView<AppKitMainContentPaneRoot>` and our hit-test
/// logs never fired. With a plain `NSViewController` whose `loadView`
/// assigns `view = CenterPanePassthroughHostingView(rootView:)`, the
/// hosting view is guaranteed to be our subclass.
@MainActor
final class CenterPanePassthroughHostingView: NSHostingView<AppKitMainContentPaneRoot> {
    /// Small inset around the published Mini Player frame so micro
    /// hover-grow overshoot at its visible edges still routes to the
    /// Mini Player rather than falling through to Home.
    private let miniPlayerHitMargin: CGFloat = 6

    override func hitTest(_ point: NSPoint) -> NSView? {
        let layoutState = HomeWindowLayoutState.shared
        let allowsHomeInteraction = layoutState.allowsHomeInteraction

        guard allowsHomeInteraction else {
            // Non-interactive Home states, including Embedded Full Screen:
            // standard SwiftUI hit-testing so the visible center-pane
            // surface owns its controls.
            return super.hitTest(point)
        }

        // Home mode + inside Mini Player rect:
        // Return `super.hitTest(point)` UNCHANGED — including when it
        // returns `self`. SwiftUI Button gestures rely on `mouseDown`
        // being delivered to the hosting view itself; remapping `self`
        // to `nil` kills Button clicks (and is why volume sliders, which
        // use a real NSSlider NSView, kept working while every Button
        // was dead).
        if isPointInsideMiniPlayer(point, layoutState: layoutState) {
            let hit = super.hitTest(point)
            #if DEBUG
            MiniPlayerHitDiag.shared.log(
                "[CenterPaneHost] inside MP. point=\(MiniPlayerHitDiag.format(point))"
                + " super.hitTest=\(MiniPlayerHitDiag.describe(hit))"
                + " isSelf=\(hit === self)"
            )
            #endif
            return hit
        }

        // Home mode + outside Mini Player rect:
        // Yield entirely so the click can fall through to the
        // `homeFullWindowHost` via `HomeRoutingRootView.hitTest`.
        #if DEBUG
        MiniPlayerHitDiag.shared.log(
            "[CenterPaneHost] outside MP yield. point=\(MiniPlayerHitDiag.format(point))"
        )
        #endif
        return nil
    }

    /// Tests whether the AppKit hit-test point lies inside the published
    /// Mini Player frame. The published frame is in SwiftUI `.global`
    /// coordinates (top-left origin, in window-content bounds). We
    /// y-flip into AppKit's window-content (bottom-left) space and
    /// route the hit-test point through `convert(_:to:)` so the
    /// comparison is independent of which superview is asking.
    private func isPointInsideMiniPlayer(_ point: NSPoint, layoutState: HomeWindowLayoutState) -> Bool {
        let swiftUIRect = layoutState.miniPlayerFrameInWindow
        guard swiftUIRect.width > 0.5, swiftUIRect.height > 0.5 else { return false }
        guard let window = self.window else { return false }
        let contentBoundsHeight = window.contentView?.bounds.height ?? bounds.height

        let appkitWindowRect = CGRect(
            x: swiftUIRect.minX,
            y: contentBoundsHeight - swiftUIRect.maxY,
            width: swiftUIRect.width,
            height: swiftUIRect.height
        )

        // `point` is in our superview's coords; convert it into window
        // content coords so the comparison rect (also in window content
        // coords) matches.
        let parent = self.superview ?? self
        let pointInWindow = parent.convert(point, to: nil)

        return appkitWindowRect
            .insetBy(dx: -miniPlayerHitMargin, dy: -miniPlayerHitMargin)
            .contains(pointInWindow)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Plain `NSViewController` whose `loadView()` installs a
/// `CenterPanePassthroughHostingView`. We deliberately *do not* subclass
/// `NSHostingController` because the `loadView()` override on that class
/// did not propagate at runtime in this codebase — the actual pane view
/// in the responder chain came back as a stock
/// `NSHostingView<AppKitMainContentPaneRoot>` and our subclass's
/// `hitTest` was never invoked.
@MainActor
final class CenterPanePassthroughViewController: NSViewController {
    private let hostedRoot: AppKitMainContentPaneRoot

    init(rootView: AppKitMainContentPaneRoot) {
        self.hostedRoot = rootView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = CenterPanePassthroughHostingView(rootView: hostedRoot)
    }
}

// MARK: - Mini Player hit-test diagnostics (DEBUG only)

#if DEBUG
/// Targeted, narrow diagnostic for Mini Player click routing. OFF by
/// default after a fix is in place — flip `enabled` to `true` to surface
/// what `super.hitTest(_:)` returns inside the Mini Player rect when a
/// click misses (e.g. a Button doesn't fire).
@MainActor
final class MiniPlayerHitDiag {
    static let shared = MiniPlayerHitDiag()
    /// Toggle to enable/disable diagnostic prints without recompiling
    /// or removing call sites. Default `true` so the next launch
    /// surfaces the actual super.hitTest return type while we verify
    /// the Mini Player click fix.
    var enabled: Bool = true
    private init() {}

    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[MiniPlayerHit] \(message())")
    }

    static func format(_ point: NSPoint) -> String {
        String(format: "(%.1f, %.1f)", point.x, point.y)
    }

    static func format(_ rect: CGRect) -> String {
        String(
            format: "(%.1f, %.1f, %.1fx%.1f)",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        )
    }

    static func describe(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return "\(type(of: view))<0x\(String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 16))>"
    }
}
#endif

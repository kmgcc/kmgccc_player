//
//  AppKitMainSplitWindowController.swift
//  myPlayer2
//
//  AppKit-driven main window template (three-column split) with a
//  full-window Home layer mounted between the art background and the
//  split view. The full-window Home host renders the real `HomeView`
//  only when the active selection is `.home`; otherwise it yields all
//  hit-testing so events fall straight through.
//
//  Z-order in window-content coordinates:
//      1. backgroundView           – art / playlist halo background
//      2. fullWindowHomeHost       – real HomeView (when in Home mode)
//      3. splitView                – sidebar | center pane | inspector
//                                    (center pane uses a passthrough
//                                    hosting view so a transparent Home
//                                    placeholder forwards hits to the
//                                    full-window host below).
//

import AppKit
import SwiftUI

@MainActor
final class AppKitMainSplitWindowController: NSWindowController, NSWindowDelegate {
    private enum WindowMetrics {
        static let defaultSize = NSSize(width: 1280, height: 780)
        static let minimumContentSize = NSSize(width: 980, height: 520)
        static let frameAutosaveName = "AppKitMainSplitWindowFrame"
        static let frameAutosaveDefaultsKey = "NSWindow Frame \(frameAutosaveName)"

        static var hasSavedFrame: Bool {
            UserDefaults.standard.object(forKey: frameAutosaveDefaultsKey) != nil
        }

        /// Returns the first-launch default window frame, not a restoration policy.
        static func defaultFrame(on screen: NSScreen) -> NSRect {
            let vis = screen.visibleFrame
            let w = min(defaultSize.width, vis.width - 180)
            let h = min(defaultSize.height, vis.height - 140)
            let x = vis.midX - w / 2
            let y = vis.midY - h / 2
            return NSRect(x: x, y: y, width: w, height: h)
        }

        /// Fallback when no screen is available (shouldn't happen in practice).
        static var fallbackFrame: NSRect {
            NSRect(origin: .zero, size: defaultSize)
        }
    }

    private enum FeatureTips {
        static let externalPlaybackKey = "playbackSource.externalAppPlayback"
        static let externalPlaybackIntroducedVersion = AppVersion(major: 2, minor: 0, patch: 0)
        static let externalPlaybackMaxDisplayCount = 2
    }

    private static var sharedController: AppKitMainSplitWindowController?

    private let splitViewController: AppKitMainSplitViewController
    private let rootViewController: AppKitMainRootViewController
    private var toolbarController: AppKitMainToolbarController?
    private let appSession: AppSessionHost
    private var didInstallToolbar = false
    private var didReachPresentedState = false
    private var isClosingMainWindow = false

    private var externalPlaybackTipPopover: NSPopover?
    private var pendingTipDisplay: Bool = false

    static func show(appSession: AppSessionHost) -> AppKitMainSplitWindowController {
        let controller: AppKitMainSplitWindowController
        if let existing = sharedController {
            controller = existing
        } else {
            controller = AppKitMainSplitWindowController(appSession: appSession)
            sharedController = controller
        }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            controller.installToolbarIfReady(reason: "show.async")
        }
        return controller
    }

    @discardableResult
    static func reveal(appSession: AppSessionHost) -> AppKitMainSplitWindowController {
        let controller = show(appSession: appSession)
        _ = controller.bringToFrontIfPossible()
        return controller
    }

    @discardableResult
    static func bringToFrontIfPossible() -> Bool {
        guard let controller = sharedController else { return false }
        return controller.bringToFrontIfPossible()
    }

    static func toggleSidebar(appSession: AppSessionHost) {
        let controller = reveal(appSession: appSession)
        controller.splitViewController.toggleSidebar(nil)
    }

    static func toggleInspector(appSession: AppSessionHost) {
        let controller = reveal(appSession: appSession)
        controller.splitViewController.toggleInspector(nil)
    }

    static func toggleMultiselect(appSession: AppSessionHost) {
        let controller = reveal(appSession: appSession)
        controller.ensureToolbarController().toggleMultiselectFromCommand()
    }

    static func setLyricsVisible(_ visible: Bool) {
        sharedController?.splitViewController.setLyricsVisible(visible)
    }

    static func isLyricsVisible() -> Bool {
        sharedController?.splitViewController.isLyricsVisible ?? false
    }

    static func setSidebarVisible(_ visible: Bool) {
        sharedController?.splitViewController.setSidebarVisible(visible)
    }

    static func isSidebarVisible() -> Bool {
        sharedController?.splitViewController.isSidebarVisible ?? false
    }

    static func setEmbeddedFullscreenActive(_ active: Bool) {
        HomeWindowLayoutState.shared.setEmbeddedFullscreenActive(active)
        sharedController?.splitViewController.setEmbeddedFullscreenActive(active)
    }

    init(appSession: AppSessionHost) {
        self.appSession = appSession
        let splitViewController = AppKitMainSplitViewController(appSession: appSession)
        self.splitViewController = splitViewController
        self.rootViewController = AppKitMainRootViewController(
            appSession: appSession,
            splitViewController: splitViewController
        )

        let defaultFrame: NSRect
        if let screen = NSScreen.main {
            defaultFrame = WindowMetrics.defaultFrame(on: screen)
        } else {
            defaultFrame = WindowMetrics.fallbackFrame
        }
        let hasSavedFrame = WindowMetrics.hasSavedFrame

        let window = CustomZoomWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "kmgccc_player"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Important: avoid allowing the split content area (including dividers) to move the window.
        // Window dragging remains available via the titlebar/toolbar region.
        window.isMovableByWindowBackground = false
        window.toolbarStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = rootViewController
        window.isReleasedWhenClosed = false
        window.contentMinSize = WindowMetrics.minimumContentSize
        window.minSize = WindowMetrics.minimumContentSize

        // Use the default only as the construction baseline. Once an autosaved
        // frame exists, restoring it is the only startup sizing policy.
        window.setFrame(defaultFrame, display: false)
        window.setFrameAutosaveName(WindowMetrics.frameAutosaveName)
        if hasSavedFrame {
            _ = window.setFrameUsingName(WindowMetrics.frameAutosaveName)
        }
        window.delegate = self

        // Install the toolbar only after the split view has applied its initial layout (viewDidAppear),
        // otherwise tracking separator items may bind too early (or throw during setToolbar).
        splitViewController.onToolbarTrackingReady = { [weak self] in
            DispatchQueue.main.async {
                self?.installToolbarIfReady(reason: "splitVC.ready.async")
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        isClosingMainWindow = true
        if let closingWindow = notification.object as? NSWindow {
            closingWindow.saveFrame(usingName: WindowMetrics.frameAutosaveName)
            FullscreenWindowManager.shared.mainWindowWillClose(closingWindow)
            toolbarController?.detachFromWindow(closingWindow)
            closingWindow.toolbar = nil
            closingWindow.delegate = nil
        }
        toolbarController = nil
        didInstallToolbar = false
        didReachPresentedState = false
        if Self.sharedController === self {
            Self.sharedController = nil
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveMainWindowFrame(from: notification)
    }

    func windowDidMove(_ notification: Notification) {
        saveMainWindowFrame(from: notification)
    }

    private func saveMainWindowFrame(from notification: Notification) {
        guard !isClosingMainWindow else { return }
        guard let movedWindow = notification.object as? NSWindow, movedWindow === window else { return }
        movedWindow.saveFrame(usingName: WindowMetrics.frameAutosaveName)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        markPresented(reason: "windowDidBecomeMain")
        installToolbarIfReady(reason: "windowDidBecomeMain")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        markPresented(reason: "windowDidBecomeKey")
        installToolbarIfReady(reason: "windowDidBecomeKey")
    }

    var isPresentedForBootstrap: Bool {
        guard let window else { return false }
        return didReachPresentedState && window.isVisible && !window.isMiniaturized
    }

    private func markPresented(reason: String) {
        guard !isClosingMainWindow else { return }
        guard !didReachPresentedState else { return }
        didReachPresentedState = true
        scheduleExternalPlaybackTipIfNeeded()
    }

    // MARK: - External Playback Feature Tip

    /// Set by the NSViewRepresentable anchor probe placed behind the source switch.
    static weak var sourceSwitchAnchorView: NSView?

    private func scheduleExternalPlaybackTipIfNeeded() {
        guard !isClosingMainWindow else {
            print("[FeatureTip:externalPlayback] skip – window is closing")
            return
        }

        let gateResult = AppVersionGate.shared.shouldShowFeatureTip(
            featureKey: FeatureTips.externalPlaybackKey,
            introducedVersion: FeatureTips.externalPlaybackIntroducedVersion,
            maxDisplayCount: FeatureTips.externalPlaybackMaxDisplayCount
        )
        let dismissed = AppVersionGate.shared.isFeatureTipDismissed(featureKey: FeatureTips.externalPlaybackKey)
        let count = AppVersionGate.shared.featureTipDisplayCount(featureKey: FeatureTips.externalPlaybackKey)
        let upgraded = AppVersionGate.shared.wasUpgradedFromVersionBelow(FeatureTips.externalPlaybackIntroducedVersion)
        print("[FeatureTip:externalPlayback] gate result=\(gateResult) dismissed=\(dismissed) displayCount=\(count) upgraded=\(upgraded)")

        guard gateResult else {
            print("[FeatureTip:externalPlayback] skip – gate returned false")
            return
        }
        guard AppSettings.shared.showPlaybackSourceSwitcher else {
            print("[FeatureTip:externalPlayback] skip – showPlaybackSourceSwitcher is false")
            return
        }

        pendingTipDisplay = true
        // Give the sidebar layout time to settle, then try to find the anchor.
        tryShowExternalPlaybackTip(retryDelay: 0.5)
    }

    private func tryShowExternalPlaybackTip(retryDelay: TimeInterval) {
        guard pendingTipDisplay, !isClosingMainWindow else {
            print("[FeatureTip:externalPlayback] tryShow skip – pending=\(pendingTipDisplay) closing=\(isClosingMainWindow)")
            return
        }
        guard externalPlaybackTipPopover?.isShown != true else {
            print("[FeatureTip:externalPlayback] tryShow skip – popover already shown")
            return
        }

        print("[FeatureTip:externalPlayback] attempt findSourceSwitchAnchor (retryDelay=\(String(format: "%.2f", retryDelay))s)")

        if let anchor = findSourceSwitchAnchor() {
            print("[FeatureTip:externalPlayback] anchor found – view=\(type(of: anchor.view)) bounds=\(NSStringFromRect(anchor.view.bounds)) rect=\(NSStringFromRect(anchor.rect))")
            showExternalPlaybackTipPopover(anchor: anchor)
            pendingTipDisplay = false
        } else if retryDelay < 5.0 {
            print("[FeatureTip:externalPlayback] anchor not found – retry in \(String(format: "%.2f", retryDelay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                self?.tryShowExternalPlaybackTip(retryDelay: retryDelay * 1.5)
            }
        } else {
            print("[FeatureTip:externalPlayback] giving up after retries – anchor never appeared")
            pendingTipDisplay = false
        }
    }

    private func findSourceSwitchAnchor() -> (view: NSView, rect: NSRect)? {
        guard let switchView = Self.sourceSwitchAnchorView else {
            print("[FeatureTip:externalPlayback] findAnchor – sourceSwitchAnchorView is nil")
            return nil
        }
        guard switchView.window != nil else {
            print("[FeatureTip:externalPlayback] findAnchor – anchor view has no window")
            return nil
        }
        guard switchView.bounds.width > 0, switchView.bounds.height > 0 else {
            print("[FeatureTip:externalPlayback] findAnchor – anchor bounds zero: \(NSStringFromRect(switchView.bounds))")
            return nil
        }

        // Anchor to the middle-right edge of the switch's own bounds so the
        // popover arrow points directly at the source switch (not a container).
        let anchorRect = NSRect(
            x: switchView.bounds.maxX - 4,
            y: switchView.bounds.midY - 1,
            width: 8,
            height: 2
        )
        return (switchView, anchorRect)
    }

    private func showExternalPlaybackTipPopover(anchor: (view: NSView, rect: NSRect)) {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentSize = NSSize(width: 288, height: 118)
        popover.contentViewController = NSHostingController(
            rootView: ExternalPlaybackTipView { [weak self] in
                self?.externalPlaybackTipPopover?.performClose(nil)
                self?.externalPlaybackTipPopover = nil
            }
        )

        externalPlaybackTipPopover = popover
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxX)
        AppVersionGate.shared.recordFeatureTipDisplayed(
            featureKey: FeatureTips.externalPlaybackKey
        )
    }

    @discardableResult
    private func bringToFrontIfPossible() -> Bool {
        guard let window else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func installToolbarIfReady(reason: String) {
        guard let window else { return }
        guard !isClosingMainWindow else { return }
        guard !didInstallToolbar else { return }

        FullscreenWindowManager.shared.resetStaleEmbeddedFullscreenForMainWindowAttach(window)

        let splitInWindow = (splitViewController.view.window === window)
        let splitViewInWindow = (splitViewController.splitView.window === window)
        let splitLayoutReady = splitViewController.isReadyForToolbarTracking
        let splitSubviewCount = splitViewController.splitView.subviews.count

        guard splitInWindow, splitViewInWindow, splitLayoutReady, splitSubviewCount >= 3 else { return }

        let toolbarController = ensureToolbarController()
        let toolbar = toolbarController.makeFreshToolbarForWindowAttach()
        window.toolbar = toolbar
        toolbarController.attachToFreshToolbarWindow(window)
        didInstallToolbar = true
    }

    private func ensureToolbarController() -> AppKitMainToolbarController {
        if let toolbarController {
            return toolbarController
        }
        let toolbarController = AppKitMainToolbarController(
            splitViewController: splitViewController,
            appSession: appSession
        )
        self.toolbarController = toolbarController
        return toolbarController
    }
}

@MainActor
private final class AppKitMainRootViewController: NSViewController {
    private let appSession: AppSessionHost
    private let splitViewController: AppKitMainSplitViewController
    private let backgroundController: NSHostingController<AppKitMainWindowArtBackgroundLayer>
    private let homeFullWindowHost: PassthroughHostingView<HomeFullWindowRoot>
    private var didApplyPaneGlassBlendingMode = false

    init(appSession: AppSessionHost, splitViewController: AppKitMainSplitViewController) {
        self.appSession = appSession
        self.splitViewController = splitViewController
        self.backgroundController = NSHostingController(
            rootView: AppKitMainWindowArtBackgroundLayer(
                appSession: appSession,
                playlistPageController: splitViewController.playlistPageController,
                artBackgroundController: splitViewController.artBackgroundController
            )
        )
        let homeFullWindowHost = PassthroughHostingView(
            rootView: HomeFullWindowRoot(appSession: appSession)
        )
        homeFullWindowHost.shouldAcceptHitTest = {
            HomeWindowLayoutState.shared.allowsHomeInteraction
        }
        self.homeFullWindowHost = homeFullWindowHost
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Use a custom NSView subclass that performs smart hit-test routing
        // between `splitViewController.view` and `homeFullWindowHost`. This
        // is the primary mechanism that delivers clicks to Home content
        // while leaving sidebar / inspector / divider / Mini Player hits
        // untouched. The custom view is documented in detail near
        // `HomeRoutingRootView` below.
        let rootView = HomeRoutingRootView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(backgroundController)
        addChild(splitViewController)

        let backgroundView = backgroundController.view
        let splitView = splitViewController.view

        backgroundView.translatesAutoresizingMaskIntoConstraints = true
        splitView.translatesAutoresizingMaskIntoConstraints = true
        homeFullWindowHost.translatesAutoresizingMaskIntoConstraints = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitViewController.splitView.wantsLayer = true
        splitViewController.splitView.layer?.backgroundColor = NSColor.clear.cgColor
        homeFullWindowHost.wantsLayer = true
        homeFullWindowHost.layer?.backgroundColor = NSColor.clear.cgColor

        // Z-order: art background → full-window Home host → split view.
        // The Home host sits BELOW the split view in subview order so that
        // sidebar / inspector glass (rendered inside the split view) blur
        // Home content beneath them.
        //
        // Hit-test routing is done by `HomeRoutingRootView.hitTest(_:)`:
        // when the split view would have claimed itself (no real pane
        // child / divider / Mini Player / real content claimed), the root
        // view diverts the hit to `homeFullWindowHost` so Home cards and
        // buttons receive `mouseDown`. Sidebar / inspector / Mini Player /
        // dividers all return non-self subviews from the split view's
        // hit-test and are routed normally without diversion.
        view.addSubview(backgroundView)
        view.addSubview(homeFullWindowHost)
        view.addSubview(splitView)

        if let routingRoot = view as? HomeRoutingRootView {
            routingRoot.splitViewRef = splitView
            routingRoot.homeHostRef = homeFullWindowHost
        }

        backgroundView.frame = view.bounds
        homeFullWindowHost.frame = view.bounds
        splitView.frame = view.bounds
        backgroundView.autoresizingMask = [.width, .height]
        homeFullWindowHost.autoresizingMask = [.width, .height]
        splitView.autoresizingMask = [.width, .height]
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        backgroundController.view.frame = view.bounds
        homeFullWindowHost.frame = view.bounds
        splitViewController.view.frame = view.bounds

        splitViewController.publishHomeLayoutGeometry(windowSize: view.bounds.size)

        // Switch sidebar/inspector glass blendingMode to `.withinWindow` so
        // the Home content (rendered below the split view) shows through the
        // panes' translucent material. `.behindWindow` (the default) only
        // samples the desktop, which would hide the Home layer completely.
        if !didApplyPaneGlassBlendingMode {
            didApplyPaneGlassBlendingMode = applyWithinWindowBlendingModeToPaneGlass()
        }
    }

    private func applyWithinWindowBlendingModeToPaneGlass() -> Bool {
        let splitView = splitViewController.splitView
        var foundEffectView = false
        for subview in splitView.subviews {
            if let effect = subview as? NSVisualEffectView {
                foundEffectView = true
                if effect.blendingMode != .withinWindow {
                    effect.blendingMode = .withinWindow
                }
            }
            // Walk a shallow subtree to catch any nested visual-effect views
            // the system layers inside the sidebar / inspector wrappers.
            for nested in subview.subviews {
                if let effect = nested as? NSVisualEffectView,
                   effect.blendingMode != .withinWindow {
                    foundEffectView = true
                    effect.blendingMode = .withinWindow
                } else if nested is NSVisualEffectView {
                    foundEffectView = true
                }
            }
        }
        return foundEffectView
    }
}

// MARK: - Custom zoom window

/// Replaces the default macOS title-bar double-click zoom with a toggle
/// between the current frame and a screen-adaptive expanded frame.
/// The expansion primarily increases height to near-screen-height; width
/// increases only slightly so the three-column layout stays comfortable.
private final class CustomZoomWindow: NSWindow {
    private var isExpanded = false
    private var preExpandFrame: NSRect?

    override func performZoom(_ sender: Any?) {
        guard !styleMask.contains(.fullScreen) else { return }

        if isExpanded {
            if let restore = preExpandFrame {
                setFrame(restore, display: true, animate: true)
            }
            isExpanded = false
            preExpandFrame = nil
        } else {
            preExpandFrame = frame
            let expanded = computeExpandedFrame()
            setFrame(expanded, display: true, animate: true)
            isExpanded = true
        }
    }

    private func computeExpandedFrame() -> NSRect {
        guard let screen else {
            return NSRect(origin: frame.origin, size: NSSize(width: 1640, height: 940))
        }
        let vis = screen.visibleFrame
        // Width: just a nudge over the current frame — at most +80 pt,
        // capped to leave side margin and never exceed visible width.
        let width = min(frame.width + 80, vis.width - 80)
        // Height: fill nearly the entire visible area, keeping a small margin.
        let height = vis.height - 40
        // Center horizontally; vertically center within visible frame.
        let x = vis.midX - width / 2
        let y = vis.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Passthrough hosting view

/// `NSHostingView` subclass that returns nil from `hitTest(_:)` when SwiftUI
/// yields hit-testing for the queried point (i.e. when only the hosting view
/// itself would have claimed it). This lets AppKit cascade the click / scroll
/// to the next sibling in the parent view's subview list — used both:
///
/// 1. By the full-window Home host, so non-Home modes (where the SwiftUI
///    root renders an empty `Color.clear`) don't capture window clicks.
/// 2. By the center pane (`AppKitMainContentPaneRoot`), so when a transparent
///    `Color.clear.allowsHitTesting(false)` placeholder is rendered for the
///    Home selection, the click can fall through to the full-window Home
///    host underneath the split view.
@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var shouldAcceptHitTest: () -> Bool = { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shouldAcceptHitTest() else { return nil }
        let hit = super.hitTest(point)
        return (hit === self) ? nil : hit
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// `NSHostingController` whose backing view is a `PassthroughHostingView`.
/// Used for the split view's center pane so a transparent Home placeholder
/// can forward hits to the full-window Home host below.
@MainActor
final class PassthroughHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = PassthroughHostingView(rootView: rootView)
    }
}

// MARK: - Home routing root view

/// Custom NSView used as `AppKitMainRootViewController.view`. Its only job is
/// to redirect `mouseDown` / scroll hit-tests to the full-window Home host
/// when the click falls inside the center column AND outside the Mini Player
/// rect, while in Home mode. Sidebar / inspector / dividers / Mini Player
/// hits all pass through to the standard subview walk.
///
/// Why this layer exists:
///   • The split view sits ON TOP of `homeFullWindowHost` in the root view's
///     subview list (so sidebar / inspector glass can blur Home content
///     beneath them).
///   • When the active selection is `.home`, the center pane's
///     `CenterPanePassthroughHostingView` yields `nil` outside the actual
///     Mini Player rect. But `NSSplitView`'s default hit-test still walks
///     its own subviews — including the inner framework-built `NSSplitView`
///     that `NSSplitViewController` synthesizes — and ends up returning
///     a fall-through hit on that inner background. The click then dies
///     in an empty NSSplitView.
///   • This view's `hitTest` detects clicks that *are inside the Home
///     content area* (in Home mode + center column + outside the actual
///     Mini Player rect) and asks `homeFullWindowHost` to claim them
///     directly, bypassing the split view's default fall-through behavior.
///
/// Hits in sidebar / inspector / divider / Mini Player regions are *not*
/// diverted — they go through the standard subview walk, which lets the
/// split view route them normally to their respective SwiftUI subviews.
/// The Mini Player rect is the live frame published by an
/// `.onGeometryChange` probe wrapped around `MiniPlayerView()` (see
/// `HomeWindowLayoutState.miniPlayerFrameInWindow`), so the routing
/// matches the visible Mini Player exactly with only a small safety
/// margin around the edges.
@MainActor
final class HomeRoutingRootView: NSView {
    weak var splitViewRef: NSView?
    weak var homeHostRef: NSView?

    /// Small inset around the published Mini Player frame, in points. Acts as
    /// a tiny safety cushion (e.g. for hover-grow overshoot at the visible
    /// edges of the Mini Player) without re-introducing a wide invisible
    /// strip that would block Home content. The Mini Player owns hit-testing
    /// inside (frame ∪ this margin); Home owns everything outside it.
    private let miniPlayerHitMargin: CGFloat = 6

    override func hitTest(_ point: NSPoint) -> NSView? {
        let layoutState = HomeWindowLayoutState.shared
        let allowsHomeInteraction = layoutState.allowsHomeInteraction
        let geometry = layoutState.geometry

        let inMiniPlayer = isPointInsideMiniPlayer(point, layoutState: layoutState)

        // Home-mode region routing: when the point is inside the center
        // column AND outside the Mini Player's actual hit rect, ask the
        // Home host to claim the hit before the split view gets a chance.
        // The center pane host yields nil for these points anyway, so
        // without this diversion the click would die in the split view's
        // inner background.
        if allowsHomeInteraction,
           geometry.hasValidLayout,
           let host = homeHostRef {
            let inCenterX = point.x >= geometry.centerMinXInWindow
                         && point.x <= geometry.centerMaxXInWindow

            if inCenterX, !inMiniPlayer {
                if let homeHit = host.hitTest(point), homeHit !== host {
                    return homeHit
                }
            }
        }

        // Default reverse-z walk: last-added subview is topmost. Inside
        // the Mini Player rect we always end up here, which lets the
        // split view → center pane → CenterPanePassthroughHostingView
        // cascade claim the click for Mini Player.
        for sub in subviews.reversed() {
            if let hit = sub.hitTest(point) {
                return hit
            }
        }
        return nil
    }

    /// Tests whether the AppKit hit-test point (window-content, bottom-left
    /// origin on this non-flipped root view) lies inside the published
    /// Mini Player frame. The published frame is captured in SwiftUI
    /// `.global` coordinates (top-left origin), so we y-flip into the
    /// root view's bounds before comparing.
    private func isPointInsideMiniPlayer(_ point: NSPoint, layoutState: HomeWindowLayoutState) -> Bool {
        let swiftUIRect = layoutState.miniPlayerFrameInWindow
        guard swiftUIRect.width > 0.5, swiftUIRect.height > 0.5 else { return false }

        let appkitRect: CGRect
        if isFlipped {
            appkitRect = swiftUIRect
        } else {
            appkitRect = CGRect(
                x: swiftUIRect.minX,
                y: bounds.height - swiftUIRect.maxY,
                width: swiftUIRect.width,
                height: swiftUIRect.height
            )
        }

        return appkitRect.insetBy(dx: -miniPlayerHitMargin, dy: -miniPlayerHitMargin).contains(point)
    }
}

// MARK: - External Playback Tip View

private struct ExternalPlaybackTipView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("现已支持外部音乐 App")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            Text("授权必要权限后，可以在这里切换并使用其他音乐 App 的正在播放内容。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 288, alignment: .leading)
    }
}

// MARK: - Source Switch Anchor Probe

/// Transparent NSView that registers itself as the source-switch anchor on the
/// window controller so the NSPopover can be positioned precisely on the switch.
final class SourceSwitchAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            AppKitMainSplitWindowController.sourceSwitchAnchorView = self
        }
    }
}

/// NSViewRepresentable that places a `SourceSwitchAnchorView` in the view
/// hierarchy, matching the frame of the SwiftUI view it is attached to.
struct SourceSwitchAnchorProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> SourceSwitchAnchorView {
        SourceSwitchAnchorView()
    }
    func updateNSView(_ nsView: SourceSwitchAnchorView, context: Context) {}
}

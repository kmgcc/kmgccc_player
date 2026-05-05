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
        static let initialSize = NSSize(width: 1520, height: 860)
        static let minimumContentSize = NSSize(width: 980, height: 520)
        static let frameAutosaveName = "AppKitMainSplitWindowFrame"
    }

    private static var sharedController: AppKitMainSplitWindowController?

    private let splitViewController: AppKitMainSplitViewController
    private let rootViewController: AppKitMainRootViewController
    private lazy var toolbarController: AppKitMainToolbarController = {
        AppKitMainToolbarController(splitViewController: splitViewController, appSession: appSession)
    }()
    private let appSession: AppSessionHost
    private var didInstallToolbar = false
    private var didReachPresentedState = false

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
        controller.toolbarController.toggleMultiselectFromCommand()
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

    func windowWillStartLiveResize(_ notification: Notification) {
        HomeWindowLayoutState.shared.setLiveResizing(true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        HomeWindowLayoutState.shared.setLiveResizing(false)
    }

    init(appSession: AppSessionHost) {
        self.appSession = appSession
        let splitViewController = AppKitMainSplitViewController(appSession: appSession)
        self.splitViewController = splitViewController
        self.rootViewController = AppKitMainRootViewController(
            appSession: appSession,
            splitViewController: splitViewController
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowMetrics.initialSize),
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
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = WindowMetrics.minimumContentSize
        window.minSize = WindowMetrics.minimumContentSize
        window.setFrameAutosaveName(WindowMetrics.frameAutosaveName)
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(WindowMetrics.frameAutosaveName)") == nil {
            window.center()
        }

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
        Self.sharedController = nil
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
        guard !didReachPresentedState else { return }
        didReachPresentedState = true
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
        guard !didInstallToolbar else { return }

        let splitInWindow = (splitViewController.view.window === window)
        let splitViewInWindow = (splitViewController.splitView.window === window)
        let splitLayoutReady = splitViewController.isReadyForToolbarTracking
        let splitSubviewCount = splitViewController.splitView.subviews.count

        guard splitInWindow, splitViewInWindow, splitLayoutReady, splitSubviewCount >= 3 else { return }

        window.toolbar = toolbarController.toolbar
        window.toolbar?.validateVisibleItems()
        toolbarController.attachToWindow(window)
        didInstallToolbar = true
    }
}

@MainActor
private final class AppKitMainRootViewController: NSViewController {
    private let appSession: AppSessionHost
    private let splitViewController: AppKitMainSplitViewController
    private let backgroundController: NSHostingController<AppKitMainWindowArtBackgroundLayer>
    private let homeFullWindowHost: PassthroughHostingView<HomeFullWindowRoot>

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

        HomeWindowLayoutState.shared.setWindowSize(view.bounds.size)

        // Switch sidebar/inspector glass blendingMode to `.withinWindow` so
        // the Home content (rendered below the split view) shows through the
        // panes' translucent material. `.behindWindow` (the default) only
        // samples the desktop, which would hide the Home layer completely.
        applyWithinWindowBlendingModeToPaneGlass()
    }

    private func applyWithinWindowBlendingModeToPaneGlass() {
        let splitView = splitViewController.splitView
        for subview in splitView.subviews {
            if let effect = subview as? NSVisualEffectView {
                if effect.blendingMode != .withinWindow {
                    effect.blendingMode = .withinWindow
                }
            }
            // Walk a shallow subtree to catch any nested visual-effect views
            // the system layers inside the sidebar / inspector wrappers.
            for nested in subview.subviews {
                if let effect = nested as? NSVisualEffectView,
                   effect.blendingMode != .withinWindow {
                    effect.blendingMode = .withinWindow
                }
            }
        }
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

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        HomeWindowLayoutState.shared.setLiveResizing(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        HomeWindowLayoutState.shared.setLiveResizing(false)
    }

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
                #if DEBUG
                if inMiniPlayer {
                    MiniPlayerHitDiag.shared.log(
                        "[RoutingRoot] inside MP. point=\(MiniPlayerHitDiag.format(point))"
                        + " path=\(sub === splitViewRef ? "split" : (sub === homeHostRef ? "home" : "background"))"
                        + " hit=\(MiniPlayerHitDiag.describe(hit))"
                    )
                }
                #endif
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

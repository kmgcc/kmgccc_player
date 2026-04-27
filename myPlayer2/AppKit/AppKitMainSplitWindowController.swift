//
//  AppKitMainSplitWindowController.swift
//  myPlayer2
//
//  AppKit-driven main window template (three-column split).
//  Step 1: Root split only (no NSToolbar wiring yet).
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

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowMetrics.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.title = "kmgccc_player (AppKit Split Template)"
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
    private let splitViewController: AppKitMainSplitViewController
    private let backgroundController: NSHostingController<AppKitMainWindowArtBackgroundLayer>
    private let homeUnderlayHost: NonInteractiveUnderlayView

    init(appSession: AppSessionHost, splitViewController: AppKitMainSplitViewController) {
        self.splitViewController = splitViewController
        self.backgroundController = NSHostingController(
            rootView: AppKitMainWindowArtBackgroundLayer(
                appSession: appSession,
                playlistPageController: splitViewController.playlistPageController,
                artBackgroundController: splitViewController.artBackgroundController
            )
        )
        self.homeUnderlayHost = NonInteractiveUnderlayView()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView()
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
        homeUnderlayHost.translatesAutoresizingMaskIntoConstraints = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitViewController.splitView.wantsLayer = true
        splitViewController.splitView.layer?.backgroundColor = NSColor.clear.cgColor
        homeUnderlayHost.wantsLayer = true
        homeUnderlayHost.layer?.backgroundColor = NSColor.clear.cgColor

        // Z-order: art background → home carousel underlay → split view (with
        // its sidebar/main/inspector/mini player). The underlay must live
        // BELOW the split view so it never blocks pointer events or overlaps
        // sibling panes' interactive content.
        view.addSubview(backgroundView)
        view.addSubview(homeUnderlayHost)
        view.addSubview(splitView)

        backgroundView.frame = view.bounds
        homeUnderlayHost.frame = view.bounds
        splitView.frame = view.bounds
        backgroundView.autoresizingMask = [.width, .height]
        homeUnderlayHost.autoresizingMask = [.width, .height]
        splitView.autoresizingMask = [.width, .height]

        homeUnderlayHost.installRootView(
            HomeCarouselUnderlayView()
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        backgroundController.view.frame = view.bounds
        homeUnderlayHost.frame = view.bounds
        splitViewController.view.frame = view.bounds

        HomeCarouselUnderlayState.shared.setWindowWidth(view.bounds.width)

        // Switch sidebar/inspector glass blendingMode to `.withinWindow` so
        // the underlay sibling (rendered below the split view) shows through
        // the panes' translucent material. `.behindWindow` (the default) only
        // samples the desktop, which would hide the underlay completely.
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

/// AppKit container that hosts the SwiftUI `HomeCarouselUnderlayView` and
/// always passes pointer events through to whatever is below in the window
/// (i.e., the split view). This guarantees the underlay never intercepts
/// clicks from sidebar / main / inspector / mini player.
@MainActor
private final class NonInteractiveUnderlayView: NSView {
    private var hostingView: NSHostingView<HomeCarouselUnderlayView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installRootView(_ rootView: HomeCarouselUnderlayView) {
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(host)
        hostingView = host
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Passthrough: never claim hit-testing. Clicks on the sidebar /
        // inspector / mini player / center pane proceed normally.
        nil
    }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

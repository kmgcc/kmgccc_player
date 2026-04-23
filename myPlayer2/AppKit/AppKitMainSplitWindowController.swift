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
#if DEBUG
    private var hitTestMonitor: Any?
#endif

    static func show(appSession: AppSessionHost) -> AppKitMainSplitWindowController {
        print("[AppKitMainWindow] show.request mainThread=\(Thread.isMainThread)")
        let controller: AppKitMainSplitWindowController
        if let existing = sharedController {
            print("[AppKitMainWindow] show.reuse controller=\(ObjectIdentifier(existing).hashValue)")
            controller = existing
        } else {
            controller = AppKitMainSplitWindowController(appSession: appSession)
            sharedController = controller
            print("[AppKitMainWindow] show.create controller=\(ObjectIdentifier(controller).hashValue)")
        }

        print("[AppKitMainWindow] show.showWindow controller=\(ObjectIdentifier(controller).hashValue)")
        controller.showWindow(nil)
        print("[AppKitMainWindow] show.makeKey window=\(controller.window.map { ObjectIdentifier($0).hashValue } ?? -1)")
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            controller.installToolbarIfReady(reason: "show.async")
        }
        controller.printVerificationSnapshot()
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
        print("[AppKitMainWindow] init.begin session=\(ObjectIdentifier(appSession).hashValue)")
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

        print("[AppKitMainWindow] init.createWindow window=\(ObjectIdentifier(window).hashValue)")

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

#if DEBUG
        installHitTestMonitor()
#endif

        print("[AppKitMainWindow] init.end controller=\(ObjectIdentifier(self).hashValue) window=\(ObjectIdentifier(window).hashValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        print("[AppKitMainWindow] deinit controller=\(ObjectIdentifier(self).hashValue)")
    }

    func windowWillClose(_ notification: Notification) {
        print("[AppKitMainWindow] windowWillClose controller=\(ObjectIdentifier(self).hashValue)")
        Self.sharedController = nil
#if DEBUG
        if let hitTestMonitor {
            NSEvent.removeMonitor(hitTestMonitor)
            self.hitTestMonitor = nil
        }
#endif
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
        print(
            "[AppKitMainWindow] presented reason=\(reason) controller=\(ObjectIdentifier(self).hashValue) "
                + "window=\(window.map { ObjectIdentifier($0).hashValue } ?? -1)"
        )
    }

    private func printVerificationSnapshot() {
        let usesFullSizeContent = window?.styleMask.contains(.fullSizeContentView) == true
        let transparentTitlebar = window?.titlebarAppearsTransparent == true
        let movableByBackground = window?.isMovableByWindowBackground == true
        print("[AppKitMainWindow] \(splitViewController.runtimeVerificationSnapshot()) fullSizeContent=\(usesFullSizeContent) titlebarTransparent=\(transparentTitlebar) movableByBackground=\(movableByBackground) toolbarStyle=\(window?.toolbarStyle.rawValue ?? -1)")
        if didInstallToolbar {
            print("[AppKitMainToolbar] \(toolbarController.runtimeVerificationSnapshot())")
        } else {
            print("[AppKitMainToolbar] notInstalledYet")
        }
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

        print("[AppKitMainToolbar] installCheck reason=\(reason) splitInWindow=\(splitInWindow) splitViewInWindow=\(splitViewInWindow) splitLayoutReady=\(splitLayoutReady) splitSubviews=\(splitSubviewCount)")
        guard splitInWindow, splitViewInWindow, splitLayoutReady, splitSubviewCount >= 3 else { return }

        print("[AppKitMainToolbar] assignToolbar.begin")
        window.toolbar = toolbarController.toolbar
        print("[AppKitMainToolbar] assignToolbar.end")
        window.toolbar?.validateVisibleItems()
        toolbarController.attachToWindow(window)
        didInstallToolbar = true

        // Snapshot after install so we can verify tracking separator binding time.
        DispatchQueue.main.async {
            self.printVerificationSnapshot()
        }
    }

#if DEBUG
    private func installHitTestMonitor() {
        guard hitTestMonitor == nil else { return }
        hitTestMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let location = event.locationInWindow
            if let view = window.contentView?.hitTest(location) {
                print("[AppKitMainWindow] hitTest view=\(type(of: view)) mouseDownCanMoveWindow=\(view.mouseDownCanMoveWindow)")
            } else {
                print("[AppKitMainWindow] hitTest view=nil")
            }
            return event
        }
    }
#endif
}

@MainActor
private final class AppKitMainRootViewController: NSViewController {
    private let splitViewController: AppKitMainSplitViewController
    private let backgroundController: NSHostingController<AppKitMainWindowArtBackgroundLayer>

    init(appSession: AppSessionHost, splitViewController: AppKitMainSplitViewController) {
        self.splitViewController = splitViewController
        self.backgroundController = NSHostingController(
            rootView: AppKitMainWindowArtBackgroundLayer(
                appSession: appSession,
                playlistPageController: splitViewController.playlistPageController,
                artBackgroundController: splitViewController.artBackgroundController
            )
        )
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

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitViewController.splitView.wantsLayer = true
        splitViewController.splitView.layer?.backgroundColor = NSColor.clear.cgColor

        view.addSubview(backgroundView)
        view.addSubview(splitView)

        backgroundView.frame = view.bounds
        splitView.frame = view.bounds
        backgroundView.autoresizingMask = [.width, .height]
        splitView.autoresizingMask = [.width, .height]
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        backgroundController.view.frame = view.bounds
        splitViewController.view.frame = view.bounds
    }
}

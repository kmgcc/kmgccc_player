//
//  FullscreenWindowManager.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Window Manager
//  Coordinates fullscreen-player presentation across a separate fullscreen window
//  and an embedded main-window route.
//

import AppKit
import Combine
import SwiftUI

/// Coordinates fullscreen-player presentation state and the dedicated system fullscreen window.
/// The same fullscreen player UI can be hosted either in a separate fullscreen space
/// or inside the main window detail area.
@MainActor
final class FullscreenWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    enum PresentationMode: Equatable {
        case none
        case systemFullscreenSpace
        case embeddedInWindow

        var usesFullscreenPlayerUI: Bool {
            self != .none
        }
    }

    static let shared = FullscreenWindowManager()

    @Published private(set) var presentationMode: PresentationMode = .none

    private var fullscreenWindow: NSWindow?
    private(set) var isTransitioning = false
    private weak var previousKeyWindow: NSWindow?
    private var escapeEventMonitor: Any?
    private var fullscreenLyricsVM: LyricsViewModel?
    private let cursorAutoHideCoordinator = FullscreenCursorAutoHideCoordinator()

    // References to shared dependencies configured by the app session.
    weak var playerVM: PlayerViewModel?
    weak var libraryVM: LibraryViewModel?
    weak var playbackCoordinator: PlaybackCoordinator?
    weak var lyricsVM: LyricsViewModel?
    weak var ledMeterProvider: LEDMeterServiceProvider?
    weak var skinManager: SkinManager?
    weak var uiState: UIStateViewModel?
    weak var coverDownloadService: CoverDownloadService?
    weak var netEaseCoverService: NetEaseCoverService?

    private var suspendedMainLyricsVisibility: Bool?
    private var suspendedMainSidebarVisibility: Bool?
    private weak var embeddedHostWindow: NSWindow?
    private var embeddedHostWindowOriginalFrame: NSRect?
    private var embeddedHostWindowOriginalMinSize: NSSize?
    private var embeddedHostWindowOriginalContentMinSize: NSSize?

    private override init() {
        super.init()
    }

    var isFullscreenPlayerPresented: Bool {
        presentationMode.usesFullscreenPlayerUI
    }

    var usesFullscreenPlayerUI: Bool {
        presentationMode.usesFullscreenPlayerUI
    }

    var isSystemFullscreenActive: Bool {
        presentationMode == .systemFullscreenSpace
    }

    var isWindowedFullscreenActive: Bool {
        presentationMode == .embeddedInWindow
    }

    /// Configure the manager with shared dependencies.
    func configure(
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        playbackCoordinator: PlaybackCoordinator,
        lyricsVM: LyricsViewModel,
        ledMeterProvider: LEDMeterServiceProvider,
        skinManager: SkinManager,
        uiState: UIStateViewModel
    ) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.playbackCoordinator = playbackCoordinator
        self.lyricsVM = lyricsVM
        self.ledMeterProvider = ledMeterProvider
        self.skinManager = skinManager
        self.uiState = uiState
    }

    func configureEditorServices(
        coverDownloadService: CoverDownloadService,
        netEaseCoverService: NetEaseCoverService
    ) {
        self.coverDownloadService = coverDownloadService
        self.netEaseCoverService = netEaseCoverService
    }

    /// Show the fullscreen player window.
    func showFullscreenWindow() {
        guard !isTransitioning else {
            return
        }

        guard presentationMode != .embeddedInWindow else {
            return
        }

        if dismissMainWindowNowPlayingIfNeeded(before: { [weak self] in
            self?.showFullscreenWindow()
        }) {
            return
        }

        guard let playerVM = playerVM,
              let playbackCoordinator = playbackCoordinator,
              let ledMeterProvider = ledMeterProvider,
              let skinManager = skinManager else {
            print("[FullscreenWindowManager] Error: Dependencies not configured")
            return
        }

        // Request fullscreen mode - this is the single source of truth for surface switching
        LyricsSurfaceManager.shared.requestMode(.fullscreen)

        // If window already exists, just bring it to front and ensure fullscreen
        if let window = fullscreenWindow {
            suspendMainLyricsIfNeeded()
            previousKeyWindow = NSApp.keyWindow === window ? previousKeyWindow : NSApp.keyWindow
            presentationMode = .systemFullscreenSpace
            installEscapeMonitorIfNeeded()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if !window.styleMask.contains(.fullScreen) {
                isTransitioning = true
                window.toggleFullScreen(nil)
            } else {
                cursorAutoHideCoordinator.start(for: window)
            }
            return
        }

        isTransitioning = true
        presentationMode = .systemFullscreenSpace

        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let fullscreenLyricsVM = makeFullscreenLyricsViewModel()

        // Use a smaller initial frame so toggleFullScreen animates from current size to fullscreen
        let sourceWindow = NSApp.keyWindow
        let initialFrame: NSRect
        if let sourceWindow = sourceWindow, !sourceWindow.styleMask.contains(.fullScreen) {
            initialFrame = sourceWindow.frame
        } else if let screen = targetScreen {
            let width: CGFloat = min(900, screen.frame.width * 0.5)
            let height: CGFloat = min(700, screen.frame.height * 0.5)
            let x = screen.frame.midX - width / 2
            let y = screen.frame.midY - height / 2
            initialFrame = NSRect(x: x, y: y, width: width, height: height)
        } else {
            initialFrame = NSRect(x: 100, y: 100, width: 900, height: 700)
        }

        let window = FullscreenPlayerWindow(
            contentRect: initialFrame,
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "kmgccc_player - Fullscreen"
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces, .fullScreenAllowsTiling]

        // Create the content view with all necessary environment injected
        let baseContentView = FullscreenPlayerView(hostContext: .systemFullscreenSpace) {
            self.closeFullscreenWindow()
        }
        .environment(playerVM)
        .environment(playbackCoordinator)
        .environment(fullscreenLyricsVM)
        .environment(ledMeterProvider)
        .environment(AppSettings.shared)
        .environment(skinManager)
        .environmentObject(ThemeStore.shared)

        let contentView: AnyView
        if let libraryVM,
           let coverDownloadService,
           let netEaseCoverService,
           let uiState {
            contentView = AnyView(
                baseContentView
                    .environment(libraryVM)
                    .environment(uiState)
                    .environment(coverDownloadService)
                    .environment(netEaseCoverService)
            )
        } else {
            Log.error(
                "Fullscreen editor dependencies missing: libraryVM=\(libraryVM != nil), coverDownloadService=\(coverDownloadService != nil), netEaseCoverService=\(netEaseCoverService != nil), uiState=\(uiState != nil)",
                category: .fullscreen
            )
            contentView = AnyView(baseContentView)
        }

        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        suspendMainLyricsIfNeeded()

        previousKeyWindow = NSApp.keyWindow
        fullscreenWindow = window
        installEscapeMonitorIfNeeded()

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// Present the fullscreen player UI inside the main window detail area.
    func showFullscreenPlayerInWindow() {
        if EmbeddedFullscreenTrace.enabled {
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] showFullscreenPlayerInWindow.begin mode=\(presentationMode) transitioning=\(isTransitioning)",
                category: .fullscreen
            )
        }
        guard !isTransitioning else { return }
        guard presentationMode == .none else { return }

        if dismissMainWindowNowPlayingIfNeeded(before: { [weak self] in
            self?.showFullscreenPlayerInWindow()
        }) {
            return
        }

        guard playerVM != nil,
              playbackCoordinator != nil,
              ledMeterProvider != nil,
              skinManager != nil else {
            Log.error("Embedded fullscreen dependencies not configured", category: .fullscreen)
            return
        }

        captureEmbeddedHostWindowFrame()
        if EmbeddedFullscreenTrace.enabled {
            let frame = embeddedHostWindowOriginalFrame
            let minSize = embeddedHostWindowOriginalMinSize
            let contentMin = embeddedHostWindowOriginalContentMinSize
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] showFullscreenPlayerInWindow.captured frame=\(String(describing: frame)) min=\(String(describing: minSize)) contentMin=\(String(describing: contentMin))",
                category: .fullscreen
            )
        }
        LyricsSurfaceManager.shared.requestMode(.fullscreen)
        suspendMainLyricsIfNeeded()
        suspendMainSidebarForEmbeddedFullscreenIfNeeded()
        if EmbeddedFullscreenTrace.enabled {
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] showFullscreenPlayerInWindow.setMode embeddedInWindow",
                category: .fullscreen
            )
        }
        presentationMode = .embeddedInWindow
        installEscapeMonitorIfNeeded()
        if EmbeddedFullscreenTrace.enabled {
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] showFullscreenPlayerInWindow.end mode=\(presentationMode)",
                category: .fullscreen
            )
        }
    }

    func closeFullscreenPlayerInWindow() {
        guard presentationMode == .embeddedInWindow else { return }
        LyricsSurfaceManager.shared.requestMode(.main)
        presentationMode = .none
        removeEscapeMonitor()
        restoreEmbeddedHostWindowFrameIfNeeded()
        restoreSuspendedMainSidebarForEmbeddedFullscreenIfNeeded()
        restoreSuspendedMainLyricsIfNeeded()
    }

    func mainWindowWillClose(_ window: NSWindow) {
        guard presentationMode == .embeddedInWindow || embeddedHostWindow === window else { return }

        LyricsSurfaceManager.shared.requestMode(.main)
        presentationMode = .none
        removeEscapeMonitor()

        if embeddedHostWindow === window {
            embeddedHostWindowOriginalFrame = nil
            embeddedHostWindowOriginalMinSize = nil
            embeddedHostWindowOriginalContentMinSize = nil
            embeddedHostWindow = nil
        }

        let sidebarWasVisible = suspendedMainSidebarVisibility
        suspendedMainSidebarVisibility = nil
        AppKitMainSplitWindowController.setEmbeddedFullscreenActive(false)
        if let sidebarWasVisible {
            uiState?.sidebarVisible = sidebarWasVisible
        }

        let lyricsWereVisible = suspendedMainLyricsVisibility
        suspendedMainLyricsVisibility = nil
        if let lyricsWereVisible {
            uiState?.lyricsVisible = lyricsWereVisible
        }

        HomeWindowLayoutState.shared.setEmbeddedFullscreenActive(false)
    }

    func resetStaleEmbeddedFullscreenForMainWindowAttach(_ window: NSWindow) {
        guard presentationMode == .embeddedInWindow else { return }
        guard embeddedHostWindow !== window else { return }
        mainWindowWillClose(embeddedHostWindow ?? window)
    }

    /// Close the fullscreen window safely.
    func closeFullscreenWindow() {
        guard let window = fullscreenWindow else { return }

        guard !isTransitioning else { return }

        cursorAutoHideCoordinator.stop()

        if window.styleMask.contains(.fullScreen) {
            isTransitioning = true
            // First exit fullscreen, then order out in delegate callback
            window.toggleFullScreen(nil)
        } else {
            dismissFullscreenWindow(window)
        }
    }

    private func dismissFullscreenWindow(_ window: NSWindow) {
        guard fullscreenWindow === window else {
            isTransitioning = false
            return
        }

        // Request main mode before dismissing - this is the single source of truth
        LyricsSurfaceManager.shared.requestMode(.main)

        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        fullscreenWindow = nil
        isTransitioning = false
        presentationMode = .none
        cursorAutoHideCoordinator.stop()
        removeEscapeMonitor()
        teardownFullscreenLyricsIfNeeded()

        DispatchQueue.main.async {
            if let previousKeyWindow = self.previousKeyWindow, previousKeyWindow.isVisible {
                previousKeyWindow.makeKeyAndOrderFront(nil)
            } else {
                NSApp.windows.first(where: { $0 !== window && $0.isVisible })?.makeKeyAndOrderFront(
                    nil)
            }
            self.previousKeyWindow = nil
        }
        restoreSuspendedMainLyricsIfNeeded()
    }

    private func suspendMainLyricsIfNeeded() {
        let isVisible = AppKitMainSplitWindowController.isLyricsVisible() || uiState?.lyricsVisible == true
        suspendedMainLyricsVisibility = isVisible
        if isVisible {
            AppKitMainSplitWindowController.setLyricsVisible(false)
        }
    }

    private func restoreSuspendedMainLyricsIfNeeded() {
        let shouldRestoreLyrics = suspendedMainLyricsVisibility == true
        suspendedMainLyricsVisibility = nil

        guard shouldRestoreLyrics else { return }
        DispatchQueue.main.async {
            AppKitMainSplitWindowController.setLyricsVisible(true)
        }
    }

    private func suspendMainSidebarForEmbeddedFullscreenIfNeeded() {
        let isVisible = AppKitMainSplitWindowController.isSidebarVisible() || uiState?.sidebarVisible == true
        suspendedMainSidebarVisibility = isVisible
        AppKitMainSplitWindowController.setEmbeddedFullscreenActive(true)
    }

    private func restoreSuspendedMainSidebarForEmbeddedFullscreenIfNeeded() {
        let shouldRestoreSidebar = suspendedMainSidebarVisibility == true
        suspendedMainSidebarVisibility = nil
        AppKitMainSplitWindowController.setEmbeddedFullscreenActive(false)

        guard shouldRestoreSidebar else { return }
        DispatchQueue.main.async {
            AppKitMainSplitWindowController.setSidebarVisible(true)
        }
    }

    private func captureEmbeddedHostWindowFrame() {
        guard embeddedHostWindowOriginalFrame == nil else { return }
        let candidateWindow =
            NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { window in
                window.isVisible
                    && window.canBecomeMain
                    && !window.styleMask.contains(.fullScreen)
            })
        guard let window = candidateWindow else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        embeddedHostWindow = window
        embeddedHostWindowOriginalFrame = window.frame
        embeddedHostWindowOriginalMinSize = window.minSize
        embeddedHostWindowOriginalContentMinSize = window.contentMinSize
    }

    private func restoreEmbeddedHostWindowFrameIfNeeded() {
        defer {
            embeddedHostWindowOriginalFrame = nil
            embeddedHostWindowOriginalMinSize = nil
            embeddedHostWindowOriginalContentMinSize = nil
            embeddedHostWindow = nil
        }
        guard let frame = embeddedHostWindowOriginalFrame else { return }
        guard let window = embeddedHostWindow, window.isVisible else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        if let contentMin = embeddedHostWindowOriginalContentMinSize,
           window.contentMinSize != contentMin {
            window.contentMinSize = contentMin
        }
        if let minSize = embeddedHostWindowOriginalMinSize,
           window.minSize != minSize {
            window.minSize = minSize
        }
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }

    private func enterFullscreen() {
        guard let window = fullscreenWindow else { return }
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func dismissMainWindowNowPlayingIfNeeded(
        before retry: @escaping @MainActor () -> Void
    ) -> Bool {
        guard uiState?.dismissNowPlayingForFullscreenPresentation() == true else { return false }

        DispatchQueue.main.async {
            retry()
        }
        return true
    }

    private func installEscapeMonitorIfNeeded() {
        guard escapeEventMonitor == nil else { return }
        escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            guard event.keyCode == 53 else { return event }

            switch self.presentationMode {
            case .systemFullscreenSpace:
                guard let window = self.fullscreenWindow else { return event }
                guard window.isVisible, window.styleMask.contains(.fullScreen), window.isKeyWindow else {
                    return event
                }
                if FullscreenTransientDismissCoordinator.shared.dismissTopmost() {
                    return nil
                }
                self.closeFullscreenWindow()
                return nil
            case .embeddedInWindow:
                let window = self.embeddedHostWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
                guard let window else { return event }
                guard window.isVisible, window.isKeyWindow else { return event }
                if FullscreenTransientDismissCoordinator.shared.dismissTopmost() {
                    return nil
                }
                self.closeFullscreenPlayerInWindow()
                return nil
            case .none:
                return event
            }
        }
    }

    private func removeEscapeMonitor() {
        guard let monitor = escapeEventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeEventMonitor = nil
    }

    // MARK: - NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else {
            return
        }
        installEscapeMonitorIfNeeded()
        window.makeKey()
        isTransitioning = false
        cursorAutoHideCoordinator.start(for: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else {
            return
        }
        cursorAutoHideCoordinator.stop()
        dismissFullscreenWindow(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else {
            return
        }
        cursorAutoHideCoordinator.stop()
        dismissFullscreenWindow(window)
    }

    func window(
        _ window: NSWindow,
        didFailToEnterFullScreenWithError error: Error
    ) {
        guard window === fullscreenWindow else { return }
        print("[FullscreenWindowManager] Failed to enter fullscreen: \(error)")
        dismissFullscreenWindow(window)
    }

    private func makeFullscreenLyricsViewModel() -> LyricsViewModel {
        if let fullscreenLyricsVM {
            return fullscreenLyricsVM
        }

        let viewModel = LyricsViewModel(settings: AppSettings.shared)
        fullscreenLyricsVM = viewModel
        return viewModel
    }

    private func teardownFullscreenLyricsIfNeeded() {
        guard let fullscreenLyricsVM else { return }
        fullscreenLyricsVM.onSeekRequest = nil
        // Note: Surface switching is now handled by LyricsSurfaceManager.requestMode()
        // We just clean up the local ViewModel here
        self.fullscreenLyricsVM = nil
    }
}

private final class FullscreenPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class FullscreenCursorAutoHideCoordinator {
    private weak var window: NSWindow?
    private var eventMonitor: Any?
    private var pendingHide: DispatchWorkItem?
    private let hideDelay: TimeInterval = 2.0

    func start(for window: NSWindow) {
        guard window.styleMask.contains(.fullScreen) else {
            stop()
            return
        }

        if self.window !== window {
            stop()
            self.window = window
        }

        window.acceptsMouseMovedEvents = true
        showCursorUntilNextIdlePeriod()

        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseEntered,
                .mouseExited,
                .mouseMoved,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .scrollWheel
            ]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        pendingHide?.cancel()
        pendingHide = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        NSCursor.setHiddenUntilMouseMoves(false)
        window = nil
    }

    private func handle(_ event: NSEvent) {
        guard let window else {
            stop()
            return
        }
        guard event.window === window else { return }
        showCursorUntilNextIdlePeriod()
    }

    private func showCursorUntilNextIdlePeriod() {
        NSCursor.setHiddenUntilMouseMoves(false)
        scheduleHide()
    }

    private func scheduleHide() {
        pendingHide?.cancel()

        let hideWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideCursorIfStillIdleInFullscreen()
            }
        }
        pendingHide = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: hideWorkItem)
    }

    private func hideCursorIfStillIdleInFullscreen() {
        pendingHide = nil

        guard let window else { return }
        guard window.isVisible, window.isKeyWindow, window.styleMask.contains(.fullScreen) else {
            return
        }
        guard window.frame.contains(NSEvent.mouseLocation) else {
            scheduleHide()
            return
        }

        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

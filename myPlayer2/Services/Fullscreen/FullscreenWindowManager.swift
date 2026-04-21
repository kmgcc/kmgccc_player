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

    // References to shared dependencies (set from AppRootView)
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
           let netEaseCoverService {
            contentView = AnyView(
                baseContentView
                    .environment(libraryVM)
                    .environment(coverDownloadService)
                    .environment(netEaseCoverService)
            )
        } else {
            Log.error(
                "Fullscreen editor dependencies missing: libraryVM=\(libraryVM != nil), coverDownloadService=\(coverDownloadService != nil), netEaseCoverService=\(netEaseCoverService != nil)",
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
        guard !isTransitioning else { return }
        guard presentationMode == .none else { return }

        guard playerVM != nil,
              playbackCoordinator != nil,
              ledMeterProvider != nil,
              skinManager != nil else {
            Log.error("Embedded fullscreen dependencies not configured", category: .fullscreen)
            return
        }

        LyricsSurfaceManager.shared.requestMode(.fullscreen)
        suspendMainLyricsIfNeeded()
        presentationMode = .embeddedInWindow
    }

    func closeFullscreenPlayerInWindow() {
        guard presentationMode == .embeddedInWindow else { return }
        LyricsSurfaceManager.shared.requestMode(.main)
        presentationMode = .none
        restoreSuspendedMainLyricsIfNeeded()
    }

    /// Close the fullscreen window safely.
    func closeFullscreenWindow() {
        guard let window = fullscreenWindow else { return }

        guard !isTransitioning else { return }

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
        suspendedMainLyricsVisibility = uiState?.lyricsVisible
        if uiState?.lyricsVisible == true {
            uiState?.lyricsVisible = false
        }
    }

    private func restoreSuspendedMainLyricsIfNeeded() {
        let shouldRestoreLyrics = suspendedMainLyricsVisibility == true
        suspendedMainLyricsVisibility = nil

        guard shouldRestoreLyrics else { return }
        DispatchQueue.main.async {
            self.uiState?.lyricsVisible = true
        }
    }

    private func enterFullscreen() {
        guard let window = fullscreenWindow else { return }
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    private func installEscapeMonitorIfNeeded() {
        guard escapeEventMonitor == nil else { return }
        escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            guard let window = self.fullscreenWindow else { return event }
            guard window.isVisible, window.styleMask.contains(.fullScreen), window.isKeyWindow else {
                return event
            }
            if event.keyCode == 53 {
                if FullscreenTransientDismissCoordinator.shared.dismissTopmost() {
                    return nil
                }
                self.closeFullscreenWindow()
                return nil
            }
            return event
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
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else {
            return
        }
        dismissFullscreenWindow(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === fullscreenWindow else {
            return
        }
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

//
//  FullscreenWindowManager.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Window Manager
//  Manages a separate fullscreen window for the player.
//

import AppKit
import Combine
import SwiftUI

/// Manages a separate fullscreen window for the player.
/// Creates a new window that enters fullscreen mode automatically.
@MainActor
final class FullscreenWindowManager: NSObject, NSWindowDelegate, ObservableObject {

    static let shared = FullscreenWindowManager()

    @Published private(set) var isFullscreenActive = false

    private var fullscreenWindow: NSWindow?
    private var isTransitioning = false
    private weak var previousKeyWindow: NSWindow?
    private var escapeEventMonitor: Any?
    private var fullscreenLyricsVM: LyricsViewModel?

    // References to shared dependencies (set from AppRootView)
    weak var playerVM: PlayerViewModel?
    weak var lyricsVM: LyricsViewModel?
    weak var ledMeter: LEDMeterService?
    weak var skinManager: SkinManager?
    weak var uiState: UIStateViewModel?

    private var suspendedMainLyricsVisibility: Bool?

    private override init() {
        super.init()
    }

    /// Configure the manager with shared dependencies.
    func configure(
        playerVM: PlayerViewModel,
        lyricsVM: LyricsViewModel,
        ledMeter: LEDMeterService,
        skinManager: SkinManager,
        uiState: UIStateViewModel
    ) {
        self.playerVM = playerVM
        self.lyricsVM = lyricsVM
        self.ledMeter = ledMeter
        self.skinManager = skinManager
        self.uiState = uiState
    }

    /// Show the fullscreen player window.
    func showFullscreenWindow() {
        guard !isTransitioning else {
            return
        }

        guard let playerVM = playerVM,
              let ledMeter = ledMeter,
              let skinManager = skinManager else {
            print("[FullscreenWindowManager] Error: Dependencies not configured")
            return
        }

        // If window already exists, just bring it to front and ensure fullscreen
        if let window = fullscreenWindow {
            suspendMainLyricsIfNeeded()
            LyricsSurfaceManager.shared.activate(role: .fullscreen)
            previousKeyWindow = NSApp.keyWindow === window ? previousKeyWindow : NSApp.keyWindow
            isFullscreenActive = true
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
        isFullscreenActive = true

        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let fullscreenLyricsVM = makeFullscreenLyricsViewModel()
        LyricsSurfaceManager.shared.activate(role: .fullscreen)

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
        let contentView = FullscreenPlayerView {
            self.closeFullscreenWindow()
        }
        .environment(playerVM)
        .environment(fullscreenLyricsVM)
        .environment(ledMeter)
        .environment(AppSettings.shared)
        .environment(skinManager)
        .environmentObject(ThemeStore.shared)

        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        suspendMainLyricsIfNeeded()

        previousKeyWindow = NSApp.keyWindow
        fullscreenWindow = window
        installEscapeMonitorIfNeeded()

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
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

        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        fullscreenWindow = nil
        isTransitioning = false
        isFullscreenActive = false
        removeEscapeMonitor()
        teardownFullscreenLyricsIfNeeded()

        DispatchQueue.main.async {
            if let previousKeyWindow = self.previousKeyWindow, previousKeyWindow.isVisible {
                previousKeyWindow.makeKeyAndOrderFront(nil)
            } else {
                NSApp.windows.first(where: { $0 !== window && $0.isVisible })?.makeKeyAndOrderFront(
                    nil)
            }
            if self.suspendedMainLyricsVisibility == true {
                self.uiState?.lyricsVisible = true
            }
            self.suspendedMainLyricsVisibility = nil
            self.previousKeyWindow = nil
        }
    }

    private func suspendMainLyricsIfNeeded() {
        suspendedMainLyricsVisibility = uiState?.lyricsVisible
        if uiState?.lyricsVisible == true {
            uiState?.lyricsVisible = false
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

        let store = LyricsSurfaceManager.shared.fullscreenStore
        let viewModel = LyricsViewModel(settings: AppSettings.shared, store: store)
        fullscreenLyricsVM = viewModel
        return viewModel
    }

    private func teardownFullscreenLyricsIfNeeded() {
        guard let fullscreenLyricsVM else { return }
        fullscreenLyricsVM.onSeekRequest = nil
        LyricsSurfaceManager.shared.deactivate(role: .fullscreen)
        self.fullscreenLyricsVM = nil
    }
}

private final class FullscreenPlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

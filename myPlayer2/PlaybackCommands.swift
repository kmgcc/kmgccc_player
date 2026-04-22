//
//  PlaybackCommands.swift
//  myPlayer2
//
//  kmgccc_player - Playback menu commands (macOS menu bar)
//

import AppKit
import SwiftUI

@MainActor
struct PlaybackCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    let appSession: AppSessionHost

    var body: some Commands {
        // Append to the View (显示) menu.
        CommandGroup(after: .sidebar) {
            Divider()
            Button(NSLocalizedString("menu.enter_window_now_playing", comment: "Enter Now Playing (Window)")) {
                Task { @MainActor in
                    await appSession.setupIfNeeded()
                    PlaybackCommandActions.openWindowNowPlaying(appSession: appSession, openWindow: openWindow)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button(NSLocalizedString("menu.enter_windowed_fullscreen_now_playing", comment: "Enter Windowed Fullscreen (Now Playing)")) {
                Task { @MainActor in
                    await appSession.setupIfNeeded()
                    PlaybackCommandActions.enterWindowedFullscreenNowPlaying(appSession: appSession, openWindow: openWindow)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .control, .option])
        }
    }
}

@MainActor
enum PlaybackCommandActions {
    static func openWindowNowPlaying(
        appSession: AppSessionHost,
        openWindow: OpenWindowAction
    ) {
        MainWindowActivator.ensureMainWindow(openWindow: openWindow)

        let fullscreenManager = FullscreenWindowManager.shared
        if fullscreenManager.isWindowedFullscreenActive {
            fullscreenManager.closeFullscreenPlayerInWindow()
        }
        if fullscreenManager.isSystemFullscreenActive {
            fullscreenManager.closeFullscreenWindow()
        }

        if appSession.uiState.contentMode != .nowPlaying {
            appSession.uiState.showNowPlaying()
        }

        MainWindowActivator.bringMainWindowToFrontIfPossible()
    }

    static func enterWindowedFullscreenNowPlaying(
        appSession: AppSessionHost,
        openWindow: OpenWindowAction
    ) {
        MainWindowActivator.ensureMainWindow(openWindow: openWindow)

        let fullscreenManager = FullscreenWindowManager.shared
        if fullscreenManager.isWindowedFullscreenActive {
            MainWindowActivator.bringMainWindowToFrontIfPossible()
            return
        }

        if fullscreenManager.isSystemFullscreenActive {
            fullscreenManager.closeFullscreenWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                FullscreenWindowManager.shared.showFullscreenPlayerInWindow()
            }
            return
        }

        fullscreenManager.showFullscreenPlayerInWindow()
        MainWindowActivator.bringMainWindowToFrontIfPossible()
    }
}

@MainActor
private enum MainWindowActivator {
    static let mainWindowSceneID = "main"

    static func ensureMainWindow(openWindow: OpenWindowAction) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if bringMainWindowToFrontIfPossible() {
            return
        }

        openWindow(id: mainWindowSceneID)

        scheduleBringToFrontRetry()
    }

    @discardableResult
    static func bringMainWindowToFrontIfPossible() -> Bool {
        guard let window = candidateMainWindow() else { return false }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    private static func scheduleBringToFrontRetry() {
        // When invoked from menu while the app has no windows, the new WindowGroup
        // NSWindow may not exist until the next runloop. Retry a few times.
        let maxAttempts = 6
        let interval: TimeInterval = 0.05

        for attempt in 1...maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(attempt) * interval)) {
                _ = bringMainWindowToFrontIfPossible()
            }
        }
    }

    private static func candidateMainWindow() -> NSWindow? {
        // Prefer key/main window; otherwise choose any window that can become key.
        let windows = NSApp.windows

        if let key = NSApp.keyWindow, key.canBecomeKey, isLikelyMainWindow(key) {
            return key
        }
        if let main = NSApp.mainWindow, main.canBecomeKey, isLikelyMainWindow(main) {
            return main
        }

        if let visible = windows.first(where: { window in
            window.canBecomeKey
                && window.isVisible
                && !window.isMiniaturized
                && isLikelyMainWindow(window)
        }) {
            return visible
        }
        if let any = windows.first(where: { $0.canBecomeKey && isLikelyMainWindow($0) }) {
            return any
        }
        return nil
    }

    private static func isLikelyMainWindow(_ window: NSWindow) -> Bool {
        // Exclude the dedicated fullscreen player window (floating level) so menu commands
        // always target the primary app window.
        if window.level != .normal {
            return false
        }
        return true
    }
}

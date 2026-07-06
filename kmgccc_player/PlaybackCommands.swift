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
    let appSession: AppSessionHost

    var body: some Commands {
        // Append to the View (显示) menu.
        CommandGroup(after: .sidebar) {
            Divider()
            Button(NSLocalizedString("menu.enter_window_now_playing", comment: "Enter Now Playing (Window)")) {
                Task { @MainActor in
                    await appSession.setupIfNeeded()
                    PlaybackCommandActions.openWindowNowPlaying(appSession: appSession)
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button(NSLocalizedString("menu.enter_windowed_fullscreen_now_playing", comment: "Enter Windowed Fullscreen (Now Playing)")) {
                Task { @MainActor in
                    await appSession.setupIfNeeded()
                    PlaybackCommandActions.enterWindowedFullscreenNowPlaying(appSession: appSession)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .control, .option])
        }
    }
}

@MainActor
enum PlaybackCommandActions {
    static func openWindowNowPlaying(appSession: AppSessionHost) {
        MainWindowActivator.ensureMainWindow(appSession: appSession)

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

    static func enterWindowedFullscreenNowPlaying(appSession: AppSessionHost) {
        MainWindowActivator.ensureMainWindow(appSession: appSession)

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
    static func ensureMainWindow(appSession: AppSessionHost) {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if bringMainWindowToFrontIfPossible() {
            return
        }

        AppKitMainSplitWindowController.reveal(appSession: appSession)
    }

    @discardableResult
    static func bringMainWindowToFrontIfPossible() -> Bool {
        AppKitMainSplitWindowController.bringToFrontIfPossible()
    }
}

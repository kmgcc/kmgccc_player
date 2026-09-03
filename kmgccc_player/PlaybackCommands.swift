//
//  PlaybackCommands.swift
//  myPlayer2
//
//  kmgccc_player - Playback menu commands (macOS menu bar)
//

import AppKit
import SwiftUI

enum AppPlaybackCommand: Sendable {
    case play
    case pause
    case playPause
    case next
    case previous
    case seekRelative(TimeInterval)
    case seekTo(TimeInterval)
}

struct PlaybackSeekStep: Equatable, Sendable {
    let seconds: Double
    let continuesFromPreviousTarget: Bool
}

/// Converts rapid discrete arrow-key taps into progressively larger relative
/// seeks. Key-repeat events are filtered by AppDelegate so holding an arrow
/// does not create an unbounded stream of helper-process commands.
struct PlaybackSeekAcceleration {
    enum Direction: Sendable, Equatable {
        case backward
        case forward
    }

    static let rapidPressWindow: TimeInterval = 0.45
    private static let stepDurations: [Double] = [3, 6, 10, 15, 20, 30]

    private(set) var pressCount = 0
    private var lastDirection: Direction?
    private var lastPressUptime: TimeInterval?

    mutating func nextStep(
        direction: Direction,
        at uptime: TimeInterval
    ) -> PlaybackSeekStep {
        let isRapidContinuation: Bool
        if let lastDirection,
           let lastPressUptime,
           lastDirection == direction,
           uptime >= lastPressUptime,
           uptime - lastPressUptime <= Self.rapidPressWindow {
            isRapidContinuation = true
        } else {
            isRapidContinuation = false
        }

        pressCount = isRapidContinuation
            ? min(pressCount + 1, Self.stepDurations.count)
            : 1
        lastDirection = direction
        lastPressUptime = uptime

        return PlaybackSeekStep(
            seconds: Self.stepDurations[pressCount - 1],
            continuesFromPreviousTarget: isRapidContinuation
        )
    }

    mutating func reset() {
        pressCount = 0
        lastDirection = nil
        lastPressUptime = nil
    }
}

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

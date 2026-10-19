//
//  DebugUIHooks.swift
//  kmgccc_player
//
//  Repeatable UI actions for local memory measurement.
//

import AppKit
import Foundation
import OSLog

/// Lets a measurement script repeat the navigation, fullscreen and skin actions
/// that drive memory, without accessibility access. Inactive unless the process
/// is launched with `KMGCCC_DEBUG_UI_HOOKS=1`. Each action is a Darwin
/// notification, for example `notifyutil -p kmgccc.player.debug.route.home`;
/// it calls the same entry point as the sidebar row, menu command or setting it
/// stands for, then logs the resulting state in the `ui` category.
@MainActor
enum DebugUIHooks {
    fileprivate static let prefix = "kmgccc.player.debug."
    private static let actions = [
        "state",
        "route.home", "route.allsongs", "route.playlist.1", "route.playlist.2", "route.playlist.3",
        "fullscreen.embedded.enter", "fullscreen.embedded.exit",
        "fullscreen.system.enter", "fullscreen.system.exit",
        "fullscreen.lyrics.toggle",
        "nowplaying.enter", "nowplaying.exit",
        "lyrics.toggle",
        "skin.fullscreen.next", "skin.window.next",
        "track.next", "track.previous",
        "memory.relief",
    ]
    private nonisolated static let isEnabled = ProcessInfo.processInfo.environment["KMGCCC_DEBUG_UI_HOOKS"] == "1"
    private static weak var appSession: AppSessionHost?
    private static var isInstalled = false
    static let fullscreenLyricsToggleNotification = Notification.Name("kmgccc.player.debug.fullscreen.lyrics.toggle")
    // The `ui` log category with public text: the measurement script reads
    // these lines from `log stream`, where `Log` interpolations are redacted.
    private nonisolated static let logger = Logger(subsystem: "kmg.myplayer2", category: LogCategory.ui.rawValue)

    /// Logs a measurement from any thread when the hooks are enabled, such as
    /// how long an offscreen render took.
    nonisolated static func record(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = "debug-ui " + line()
        logger.notice("\(text, privacy: .public)")
    }

    static func installIfEnabled(appSession: AppSessionHost) {
        guard isEnabled, !isInstalled else { return }
        isInstalled = true
        self.appSession = appSession
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for action in actions {
            CFNotificationCenterAddObserver(
                center,
                nil,
                debugUIHookReceived,
                (prefix + action) as CFString,
                nil,
                .deliverImmediately
            )
        }
        let line = "debug-ui installed prefix=\(prefix) actions=\(actions.joined(separator: ","))"
        logger.notice("\(line, privacy: .public)")
    }

    static func perform(_ name: String) {
        guard name.hasPrefix(prefix), let appSession else { return }
        let action = String(name.dropFirst(prefix.count))
        switch action {
        case "route.home":
            select(.home, in: appSession)
        case "route.allsongs":
            select(.allSongs, in: appSession)
        case let route where route.hasPrefix("route.playlist."):
            guard let libraryVM = appSession.libraryVM,
                  let position = Int(route.dropFirst("route.playlist.".count)) else { break }
            let playlists = libraryVM.sortedPlaylistsForDisplay()
            guard playlists.indices.contains(position - 1) else { break }
            select(.playlist(playlists[position - 1].id), in: appSession)
        case "fullscreen.embedded.enter":
            PlaybackCommandActions.enterWindowedFullscreenNowPlaying(appSession: appSession)
        case "fullscreen.embedded.exit":
            FullscreenWindowManager.shared.closeFullscreenPlayerInWindow()
        case "fullscreen.system.enter":
            AppKitMainSplitWindowController.reveal(appSession: appSession)
            FullscreenWindowManager.shared.showFullscreenWindow()
        case "fullscreen.system.exit":
            FullscreenWindowManager.shared.closeFullscreenWindow()
        case "fullscreen.lyrics.toggle":
            NotificationCenter.default.post(name: fullscreenLyricsToggleNotification, object: nil)
        case "nowplaying.enter":
            PlaybackCommandActions.openWindowNowPlaying(appSession: appSession)
        case "nowplaying.exit":
            appSession.uiState.showLibrary()
        case "lyrics.toggle":
            AppKitMainSplitWindowController.toggleInspector(appSession: appSession)
        case "skin.fullscreen.next":
            let fullscreen = AppSettings.shared.fullscreen
            fullscreen.setSkinID(nextID(after: fullscreen.skinID, in: SkinRegistry.fullscreenOptions))
        case "skin.window.next":
            let settings = AppSettings.shared
            settings.selectedNowPlayingSkinID = nextID(
                after: settings.selectedNowPlayingSkinID,
                in: SkinRegistry.nowPlayingOptions
            )
        case "track.next":
            Task { await appSession.performPlaybackCommand(.next) }
        case "track.previous":
            Task { await appSession.performPlaybackCommand(.previous) }
        case "memory.relief":
            // Measures how much the routine malloc relief returns at this moment.
            measure("relief") { CacheManager.trimProcessMemory() }
        default:
            break
        }
        logState(action: action, appSession: appSession)
    }

    /// Mirrors the sidebar row action.
    private static func select(_ selection: LibrarySelection, in appSession: AppSessionHost) {
        guard let libraryVM = appSession.libraryVM else { return }
        appSession.uiState.clearHomeNavigationContext()
        libraryVM.selectOrResetCurrentSelection(selection)
        appSession.uiState.showLibrary()
    }

    private static func measure(_ name: String, _ operation: () -> Void) {
        let before = physicalFootprint()
        let start = ContinuousClock.now
        operation()
        let elapsed = start.duration(to: .now)
        let after = physicalFootprint()
        let line = String(
            format: "debug-ui %@ before=%.1f after=%.1f ms=%.1f",
            name,
            Double(before) / 1_048_576,
            Double(after) / 1_048_576,
            Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        )
        logger.notice("\(line, privacy: .public)")
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func nextID(after current: String, in options: [SkinOption]) -> String {
        guard let index = options.firstIndex(where: { $0.id == current }) else {
            return options.first?.id ?? current
        }
        return options[(index + 1) % options.count].id
    }

    private static func logState(action: String, appSession: AppSessionHost) {
        let selection = appSession.libraryVM.map { String(describing: $0.currentSelection) } ?? "nil"
        var line = "debug-ui action=\(action) selection=\(selection) "
            + "content=\(appSession.uiState.contentMode) "
            + "fullscreen=\(FullscreenWindowManager.shared.presentationMode) "
            + "fullscreenSkin=\(AppSettings.shared.fullscreen.skinID) "
            + "windowSkin=\(AppSettings.shared.selectedNowPlayingSkinID) "
            + "lyrics=\(AppKitMainSplitWindowController.isLyricsVisible()) "
            + "track=\(appSession.playerVM?.currentTrack?.title ?? "nil")"
        if action == "state" {
            let playlists = appSession.libraryVM?.sortedPlaylistsForDisplay().prefix(3).map(\.name) ?? []
            line += " | playlists=\(playlists) fullscreenSkins=\(SkinRegistry.fullscreenOptions.map(\.id))"
                + " windowSkins=\(SkinRegistry.nowPlayingOptions.map(\.id))"
        }
        logger.notice("\(line, privacy: .public)")
    }
}

private nonisolated func debugUIHookReceived(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let rawName = name?.rawValue else { return }
    let action = rawName as String
    Task { @MainActor in DebugUIHooks.perform(action) }
}

//
//  AppDelegate.swift
//  myPlayer2
//
//  kmgccc_player - App Delegate for Menu Configuration
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    static var launchMainWindowHandler: (@MainActor () -> Void)?
    static var playbackCommandHandler: (@MainActor (AppPlaybackCommand) -> Void)?
    static var applicationShouldTerminateHandler:
        ((@escaping @MainActor @Sendable () -> Void) -> Void)?
    static var shouldCancelTerminationForPendingUpdateHandler: (@MainActor () -> Bool)?
    static var applicationWillTerminateHandler: (@MainActor () -> Void)?

    static func showMainWindow() {
        Task { @MainActor in
            launchMainWindowHandler?()
        }
    }

    private let dockController = DockController()
    private weak var playbackCoordinator: PlaybackCoordinator?
    private var keyboardPlaybackMonitor: Any?
    private var seekAcceleration = PlaybackSeekAcceleration()
    private var seekTarget: Double?
    private var seekPresentationIdentity: String?
    private var terminationReplyPending = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.debug("[AppDelegate] didFinishLaunching", category: .ui)
        disableWindowTabbing()
        configureMainMenu()
        installKeyboardPlaybackMonitor()
        dockController.installDockTile()
        DispatchQueue.main.async {
            Log.debug("[AppDelegate] launchMainWindowHandler.invoke", category: .ui)
            Self.showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PaneLayoutTrace.log("AppDelegate.applicationWillTerminate")
        Self.applicationWillTerminateHandler?()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.shouldCancelTerminationForPendingUpdateHandler?() == true {
            Log.info("[Lifecycle] Cancelled ordinary quit while Sparkle install reply is pending", category: .ui)
            return .terminateCancel
        }
        guard let handler = Self.applicationShouldTerminateHandler else {
            return .terminateNow
        }
        guard !terminationReplyPending else {
            return .terminateLater
        }

        terminationReplyPending = true
        handler { [weak self, weak sender] in
            Task { @MainActor in
                self?.terminationReplyPending = false
                sender?.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func configureDockPlayback(playbackCoordinator: PlaybackCoordinator) {
        self.playbackCoordinator = playbackCoordinator
        resetKeyboardSeekState()
        dockController.configure(playbackCoordinator: playbackCoordinator)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockController.makeDockMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dockController.applicationShouldHandleReopen(hasVisibleWindows: flag)
    }

    private func disableWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // MARK: - Keyboard playback monitor

    /// Intercepts bare playback keys app-wide so they work even when an
    /// `NSTableView` (backing SwiftUI `List`) has keyboard focus. Without this,
    /// `NSTableView.keyDown` consumes space/arrow keys before the menu bar
    /// shortcut can fire.
    private func installKeyboardPlaybackMonitor() {
        keyboardPlaybackMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let dominated = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard dominated.isEmpty else { return event }

            // Don't intercept when a text input is the first responder — the
            // user is typing or moving the caret in a text field.
            guard let self, !self.isTextInputFirstResponder(in: event.window) else {
                return event
            }

            switch event.keyCode {
            case 49: // Space
                return self.dispatchPlaybackCommand(.playPause) ? nil : event
            case 123: // Left arrow
                guard !event.isARepeat else {
                    return self.canHandleSeekKey ? nil : event
                }
                return self.handleSeekKey(.backward) ? nil : event
            case 124: // Right arrow
                guard !event.isARepeat else {
                    return self.canHandleSeekKey ? nil : event
                }
                return self.handleSeekKey(.forward) ? nil : event
            default:
                return event
            }
        }
    }

    private func dispatchPlaybackCommand(_ command: AppPlaybackCommand) -> Bool {
        if let playbackCoordinator {
            switch command {
            case .play:
                playbackCoordinator.resume()
            case .pause:
                playbackCoordinator.pause()
            case .playPause:
                playbackCoordinator.playPause()
            case .next:
                playbackCoordinator.next()
            case .previous:
                playbackCoordinator.previous()
            case .seekRelative(let offset):
                playbackCoordinator.seek(by: offset)
            case .seekTo(let position):
                playbackCoordinator.seek(to: position)
            }
            return true
        }

        guard let handler = Self.playbackCommandHandler else { return false }
        handler(command)
        return true
    }

    private func handleSeekKey(_ direction: PlaybackSeekAcceleration.Direction) -> Bool {
        guard let playbackCoordinator,
              playbackCoordinator.presentation.hasTrack,
              playbackCoordinator.presentation.isSeekEnabled else {
            resetKeyboardSeekState()
            return false
        }

        let identity = seekIdentity(for: playbackCoordinator.presentation)
        if seekPresentationIdentity != identity {
            resetKeyboardSeekState()
            seekPresentationIdentity = identity
        }

        let step = seekAcceleration.nextStep(
            direction: direction,
            at: ProcessInfo.processInfo.systemUptime
        )
        let reference = step.continuesFromPreviousTarget
            ? (seekTarget ?? playbackCoordinator.presentation.currentTime)
            : playbackCoordinator.presentation.currentTime
        let signedOffset = direction == .forward ? step.seconds : -step.seconds
        let duration = playbackCoordinator.presentation.duration
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let target = min(max(reference + signedOffset, 0), upperBound)
        seekTarget = target
        playbackCoordinator.seek(to: target)
        return true
    }

    private var canHandleSeekKey: Bool {
        guard let playbackCoordinator else { return false }
        return playbackCoordinator.presentation.hasTrack
            && playbackCoordinator.presentation.isSeekEnabled
    }

    private func seekIdentity(for presentation: NowPlayingPresentation) -> String {
        let trackIdentity = presentation.externalStableKey
            ?? presentation.localTrack?.id.uuidString
            ?? "\(presentation.title)|\(presentation.artist)|\(presentation.duration)"
        return "\(presentation.source.rawValue)|\(trackIdentity)"
    }

    private func resetKeyboardSeekState() {
        seekAcceleration.reset()
        seekTarget = nil
        seekPresentationIdentity = nil
    }

    private func isTextInputFirstResponder(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField {
            return true
        }
        return String(describing: type(of: responder)).contains("FieldEditor")
    }

    private func configureMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for menuItem in mainMenu.items {
            if menuItem.title == "View" || menuItem.title == "视图" {
                configureViewMenu(menuItem.submenu)
            }
            if menuItem.title == "Window" || menuItem.title == "窗口" {
                configureWindowMenu(menuItem.submenu)
            }
        }
    }

    private func configureViewMenu(_ viewMenu: NSMenu?) {
        // View menu now managed by SwiftUI CommandGroup(replacing: .sidebar)
        // This avoids duplication with the system-provided View menu items
    }

    private func configureWindowMenu(_ windowMenu: NSMenu?) {
        guard let windowMenu else { return }

        let itemsToRemove = windowMenu.items.filter { item in
            let title = item.title
            return title.contains("Tab Bar")
                || title.contains("标签页栏")
                || title.contains("Show All Tabs")
                || title.contains("显示所有标签页")
        }

        for item in itemsToRemove {
            windowMenu.removeItem(item)
        }
    }

    @objc private func showToolbarCustomization() {
        if let window = NSApp.mainWindow, let toolbar = window.toolbar {
            toolbar.runCustomizationPalette(nil)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

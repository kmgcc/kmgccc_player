//
//  kmgccc_playerApp.swift
//  myPlayer2
//
//  kmgccc_player - App Entry Point
//

import AppKit
import SwiftData
import SwiftUI

// MARK: - Playback Order Menu Content

@MainActor
private struct PlaybackOrderMenuContent: View {
    @State private var currentMode: PlaybackOrderMode = AppSettings.shared.playbackOrderMode

    var body: some View {
        Button {
            setPlaybackMode(.sequence)
        } label: {
            if currentMode == .sequence {
                Label(NSLocalizedString("menu.sequence", comment: "Sequence"), systemImage: "checkmark")
            } else {
                Text(NSLocalizedString("menu.sequence", comment: "Sequence"))
            }
        }

        Button {
            setPlaybackMode(.shuffle)
        } label: {
            if currentMode == .shuffle {
                Label(NSLocalizedString("menu.shuffle", comment: "Shuffle"), systemImage: "checkmark")
            } else {
                Text(NSLocalizedString("menu.shuffle", comment: "Shuffle"))
            }
        }

        Button {
            setPlaybackMode(.repeatOne)
        } label: {
            if currentMode == .repeatOne {
                Label(NSLocalizedString("menu.repeat_one", comment: "Repeat One"), systemImage: "checkmark")
            } else {
                Text(NSLocalizedString("menu.repeat_one", comment: "Repeat One"))
            }
        }

        Button {
            setPlaybackMode(.stopAfterTrack)
        } label: {
            if currentMode == .stopAfterTrack {
                Label(NSLocalizedString("menu.stop_after_track", comment: "Stop After Track"), systemImage: "checkmark")
            } else {
                Text(NSLocalizedString("menu.stop_after_track", comment: "Stop After Track"))
            }
        }
        .onAppear {
            updateCurrentMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackModeChanged)) { _ in
            updateCurrentMode()
        }
    }

    private func updateCurrentMode() {
        currentMode = AppSettings.shared.playbackOrderMode
    }

    private func setPlaybackMode(_ mode: PlaybackOrderMode) {
        AppSettings.shared.setPlaybackOrderMode(mode, announceChange: true)
        currentMode = mode
    }
}

@main
struct KmgcccPlayerApp: App {

    // MARK: - AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appSession: AppSessionHost

    // MARK: - SwiftData Container

    let sharedModelContainer: ModelContainer

    init() {
        UpdatePreferences.migrateIfNeeded()

        // Register the bundled Inter family before any settings preview or
        // lyric surface asks CoreText/SwiftUI to resolve it.
        BundledFontRegistrar.register()

        // Install the crash handler before SwiftData or the main window is
        // created. The handler only writes PLCrashReporter's pending file;
        // parsing, redaction and all network work happen on a later launch.
        CrashReporterBootstrap.shared.enable()
        CrashBreadcrumbRecorder.shared.record(.appLaunchStarted)

        // Phase 2 colour-system self-check. No-op unless invoked via
        // `COLOR_SYSTEM_SELF_CHECK=1`, in which case the process exits
        // here after printing the report.
        #if DEBUG
        ColorSystemSelfCheck.runIfRequested()
        #endif

        let sharedModelContainer = Self.makeSharedModelContainer()

        self.sharedModelContainer = sharedModelContainer
        let appSessionHost = AppSessionHost(
            modelContainer: sharedModelContainer
        )
        _appSession = StateObject(wrappedValue: appSessionHost)
        AppDelegate.launchMainWindowHandler = { @MainActor in
            Log.debug("[AppLaunch] mainWindowHandler.begin", category: .ui)
            Task { @MainActor in
                await appSessionHost.setupIfNeeded()
                Log.debug("[AppLaunch] mainWindowHandler.setupComplete", category: .ui)
                _ = AppKitMainSplitWindowController.show(appSession: appSessionHost)
            }
        }
    }

    private static func makeSharedModelContainer() -> ModelContainer {
        let schema = Schema([TrackIndexEntry.self])
        let storeURL = TrackIndexStorePaths.storeURL

        let initialAttempt = makePersistentModelContainer(schema: schema, storeURL: storeURL)
        if let container = initialAttempt.container {
            return container
        }

        if let error = initialAttempt.error,
           isConfirmedStoreCorruption(error),
           isolateDamagedStore(at: storeURL, label: "TrackIndex"),
           let container = makePersistentModelContainer(schema: schema, storeURL: storeURL).container {
            Log.warning("[TrackIndex] recovered by rebuilding a damaged cache store", category: .library)
            return container
        }

        Log.error("[TrackIndex] using an in-memory cache for this launch", category: .library)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makePersistentModelContainer(
        schema: Schema,
        storeURL: URL
    ) -> (container: ModelContainer?, error: Error?) {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return (try ModelContainer(for: schema, configurations: [configuration]), nil)
        } catch {
            Log.error("[TrackIndex] persistent store unavailable: \(error)", category: .library)
            return (nil, error)
        }
    }

    private static func isConfirmedStoreCorruption(_ error: Error) -> Bool {
        var pending = [error as NSError]
        var inspected = 0
        while let current = pending.popLast(), inspected < 16 {
            inspected += 1
            if current.domain == "NSSQLiteErrorDomain",
               [11, 24, 26].contains(current.code) {
                return true
            }

            let description = [
                current.localizedDescription,
                current.localizedFailureReason ?? ""
            ].joined(separator: " ").lowercased()
            if description.contains("database disk image is malformed")
                || description.contains("file is not a database")
                || description.contains("database corruption") {
                return true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                pending.append(contentsOf: detailed)
            }
        }
        return false
    }

    @discardableResult
    private static func isolateDamagedStore(at storeURL: URL, label: String) -> Bool {
        let fileManager = FileManager.default
        let recoveryID = UUID().uuidString.lowercased()
        var movedStore = false
        var movedFiles: [(source: URL, isolated: URL)] = []

        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let isolatedURL = URL(fileURLWithPath: storeURL.path + ".corrupt-\(recoveryID)\(suffix)")
            do {
                try fileManager.moveItem(at: sourceURL, to: isolatedURL)
                movedStore = true
                movedFiles.append((sourceURL, isolatedURL))
            } catch {
                for movedFile in movedFiles.reversed() {
                    try? fileManager.moveItem(at: movedFile.isolated, to: movedFile.source)
                }
                Log.error("[\(label)] could not isolate \(sourceURL.lastPathComponent): \(error)", category: .library)
                return false
            }
        }

        return movedStore
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // 0. 移除默认设置菜单
            CommandGroup(replacing: .appSettings) {}

            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    UpdateCoordinator.shared.checkManually()
                }
            }

            // 1. 文件菜单
            CommandGroup(replacing: .newItem) {
                Button(NSLocalizedString("menu.import_music", comment: "Import Music")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        let contentMode = appSession.uiState.contentMode
                        await appSession.libraryVM?.importToCurrentContext(contentMode: contentMode)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(NSLocalizedString("menu.new_playlist", comment: "New Playlist")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        _ = await appSession.libraryVM?.createNewPlaylist()
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button(NSLocalizedString("menu.toggle_multiselect", comment: "Enter Multi-Select Mode")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        AppKitMainSplitWindowController.toggleMultiselect(appSession: appSession)
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // 2. 显示菜单 - 替换系统默认的侧边栏命令，添加歌词和全屏播放器
            CommandGroup(replacing: .sidebar) {
                Button(NSLocalizedString("menu.toggle_sidebar", comment: "Toggle Sidebar")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        AppKitMainSplitWindowController.toggleSidebar(appSession: appSession)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button(NSLocalizedString("menu.toggle_lyrics", comment: "Toggle Lyrics Panel")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        AppKitMainSplitWindowController.toggleInspector(appSession: appSession)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Divider()

                Button(NSLocalizedString("menu.open_fullscreen_player", comment: "Open Fullscreen Player")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        AppKitMainSplitWindowController.reveal(appSession: appSession)
                        FullscreenWindowManager.shared.showFullscreenWindow()
                    }
                }
                .keyboardShortcut("f", modifiers: [])
            }

            // 3. 播放控制菜单（新增顶级菜单）
            CommandMenu(NSLocalizedString("menu.playback", comment: "Playback")) {
                Button(NSLocalizedString("menu.play_pause", comment: "Play/Pause")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        appSession.playbackCoordinator?.playPause()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(NSLocalizedString("menu.next_track", comment: "Next Track")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        appSession.playbackCoordinator?.next()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button(NSLocalizedString("menu.previous_track", comment: "Previous Track")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        appSession.playbackCoordinator?.previous()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button(NSLocalizedString("menu.toggle_queue", comment: "Toggle Queue")) {
                    Task { @MainActor in
                        await appSession.setupIfNeeded()
                        if FullscreenWindowManager.shared.usesFullscreenPlayerUI {
                            NotificationCenter.default.post(name: .toggleQueuePanel, object: nil)
                        } else {
                            appSession.uiState.toggleWindowPlaybackQueue()
                        }
                    }
                }
                .keyboardShortcut("q", modifiers: [.command, .option])

                Divider()

                // 播放顺序模式 - 使用 Button 配合 checkmark 实现单选效果
                PlaybackOrderMenuContent()
            }

            // 3.1 显示菜单追加项（窗口播放 / 窗口模拟全屏）
            PlaybackCommands(appSession: appSession)

            // 4. 帮助菜单
            CommandGroup(replacing: .help) {
                Button(NSLocalizedString("menu.help_center", comment: "Help Center")) {
                    if let url = URL(string: "https://player.kmgccc.cn/help") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(NSLocalizedString("menu.submit_feedback", comment: "Submit Feedback")) {
                    if let url = URL(string: "https://github.com/kmgcc/kmgccc_player/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(NSLocalizedString("menu.github", comment: "GitHub")) {
                    if let url = URL(string: "https://github.com/kmgcc/kmgccc_player") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let playbackTrackDidChange = Notification.Name("kmgccc_player.playbackTrackDidChange")
    static let libraryTrackDidUpdate = Notification.Name("kmgccc_player.libraryTrackDidUpdate")
    static let toggleQueuePanel = Notification.Name("kmgccc_player.toggleQueuePanel")
    static let playbackModeChanged = Notification.Name("kmgccc_player.playbackModeChanged")
    static let dockProgressVisibilityChanged = Notification.Name("kmgccc_player.dockProgressVisibilityChanged")
}

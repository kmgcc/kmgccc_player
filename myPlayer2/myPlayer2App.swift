//
//  myPlayer2App.swift
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
    @StateObject private var settingsSceneDependencies: SettingsSceneDependencies
    @StateObject private var appSession: AppSessionHost

    // MARK: - SwiftData Container

    let sharedModelContainer: ModelContainer

    init() {
        let sharedModelContainer: ModelContainer = {
            let schema = Schema([
                TrackIndexEntry.self
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                url: TrackIndexStorePaths.storeURL
            )

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }()

        let settingsSceneDependencies = SettingsSceneDependencies()

        self.sharedModelContainer = sharedModelContainer
        _settingsSceneDependencies = StateObject(wrappedValue: settingsSceneDependencies)
        _appSession = StateObject(
            wrappedValue: AppSessionHost(
                modelContainer: sharedModelContainer,
                settingsSceneDependencies: settingsSceneDependencies
            )
        )
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup("", id: "main") {
            AppRootView(appSession: appSession)
                .frame(minWidth: 1100, minHeight: 600)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 680)
        .commands {
            // 1. 文件菜单
            CommandGroup(replacing: .newItem) {
                Button(NSLocalizedString("menu.import_music", comment: "Import Music")) {
                    NotificationCenter.default.post(name: .importMusic, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(NSLocalizedString("menu.new_playlist", comment: "New Playlist")) {
                    NotificationCenter.default.post(name: .newPlaylist, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button(NSLocalizedString("menu.toggle_multiselect", comment: "Enter Multi-Select Mode")) {
                    NotificationCenter.default.post(name: .toggleMultiselectMode, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // 2. 显示菜单 - 替换系统默认的侧边栏命令，添加歌词和全屏播放器
            CommandGroup(replacing: .sidebar) {
                Button(NSLocalizedString("menu.toggle_sidebar", comment: "Toggle Sidebar")) {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Button(NSLocalizedString("menu.toggle_lyrics", comment: "Toggle Lyrics Panel")) {
                    NotificationCenter.default.post(name: .toggleLyrics, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Divider()

                Button(NSLocalizedString("menu.open_fullscreen_player", comment: "Open Fullscreen Player")) {
                    NotificationCenter.default.post(name: .enterFullscreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: [])
            }

            // 3. 播放控制菜单（新增顶级菜单）
            CommandMenu(NSLocalizedString("menu.playback", comment: "Playback")) {
                Button(NSLocalizedString("menu.play_pause", comment: "Play/Pause")) {
                    NotificationCenter.default.post(name: .togglePlayPause, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(NSLocalizedString("menu.next_track", comment: "Next Track")) {
                    NotificationCenter.default.post(name: .nextTrack, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button(NSLocalizedString("menu.previous_track", comment: "Previous Track")) {
                    NotificationCenter.default.post(name: .previousTrack, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button(NSLocalizedString("menu.toggle_queue", comment: "Toggle Queue")) {
                    NotificationCenter.default.post(name: .toggleQueuePanel, object: nil)
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
                    if let url = URL(string: "https://github.com/kmgcc/kmgccc_player/blob/main/README.md") {
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

            CommandMenu("Prototype") {
                Button("Open AppKit Split Toolbar Prototype") {
                    AppKitSplitToolbarPrototypeWindowController.showPrototypeWindow()
                }

                Button("Open AppKit Main Split Template (Step 1)") {
                    AppKitMainSplitWindowController.show(appSession: appSession)
                }
            }
        }

        Settings {
            Group {
                if let libraryVM = settingsSceneDependencies.libraryVM,
                   let playerVM = settingsSceneDependencies.playerVM,
                   let lyricsVM = settingsSceneDependencies.lyricsVM,
                   let ledMeterProvider = settingsSceneDependencies.ledMeterProvider {
                    SettingsRootView(
                        libraryVM: libraryVM,
                        playerVM: playerVM,
                        lyricsVM: lyricsVM,
                        ledMeterProvider: ledMeterProvider
                    )
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("加载设置中...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 400, height: 200)
                }
            }
            .modelContainer(sharedModelContainer)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let togglePlayPause = Notification.Name("kmgccc_player.togglePlayPause")
    static let nextTrack = Notification.Name("kmgccc_player.nextTrack")
    static let previousTrack = Notification.Name("kmgccc_player.previousTrack")
    static let toggleLyrics = Notification.Name("kmgccc_player.toggleLyrics")
    static let playbackTrackDidChange = Notification.Name("kmgccc_player.playbackTrackDidChange")
    static let libraryTrackDidUpdate = Notification.Name("kmgccc_player.libraryTrackDidUpdate")
    static let aboutEasterEggTriggered = Notification.Name("kmgccc_player.aboutEasterEggTriggered")
    static let enterFullscreen = Notification.Name("kmgccc_player.enterFullscreen")
    static let mainLayoutReady = Notification.Name("kmgccc_player.mainLayoutReady")
    static let toggleMultiselectMode = Notification.Name("kmgccc_player.toggleMultiselectMode")
    static let toggleQueuePanel = Notification.Name("kmgccc_player.toggleQueuePanel")
    static let importMusic = Notification.Name("kmgccc_player.importMusic")
    static let newPlaylist = Notification.Name("kmgccc_player.newPlaylist")
    static let toggleSidebar = Notification.Name("kmgccc_player.toggleSidebar")
    static let playbackModeChanged = Notification.Name("kmgccc_player.playbackModeChanged")
    static let dockProgressVisibilityChanged = Notification.Name("kmgccc_player.dockProgressVisibilityChanged")
}

//
//  myPlayer2App.swift
//  myPlayer2
//
//  kmgccc_player - App Entry Point
//

import SwiftData
import SwiftUI

@main
struct KmgcccPlayerApp: App {

    // MARK: - SwiftData Container

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Track.self,
            Playlist.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    // MARK: - Body

    var body: some Scene {
        WindowGroup("") {
            AppRootView()
                .frame(minWidth: 1100, minHeight: 600)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 680)
        .commands {
            // Playback commands
            CommandGroup(after: .appSettings) {
                Divider()

                Button(NSLocalizedString("alert.play_pause", comment: "")) {
                    NotificationCenter.default.post(name: .togglePlayPause, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button(NSLocalizedString("alert.next", comment: "")) {
                    NotificationCenter.default.post(name: .nextTrack, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Button(NSLocalizedString("alert.previous", comment: "")) {
                    NotificationCenter.default.post(name: .previousTrack, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            }

            // View commands
            CommandGroup(after: .sidebar) {
                Button(NSLocalizedString("alert.toggle_lyrics", comment: "")) {
                    NotificationCenter.default.post(name: .toggleLyrics, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
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
    static let aboutEasterEggTriggered = Notification.Name("kmgccc_player.aboutEasterEggTriggered")
}

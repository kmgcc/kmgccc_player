//
//  AppRootView.swift
//  myPlayer2
//
//  TrueMusic - App Root View
//  Creates and injects all dependencies.
//

import SwiftData
import SwiftUI

/// Root view that sets up dependency injection.
/// Creates real services for production, stubs for previews.
struct AppRootView: View {

    @Environment(\.modelContext) private var modelContext

    // MARK: - App Globals (live updates)

    @AppStorage("appearance") private var appearance: String = "system"
    @AppStorage("accentColorHex") private var accentColorHex: String = "#007AFF"

    // MARK: - State Objects

    @State private var uiState = UIStateViewModel()
    @State private var libraryVM: LibraryViewModel?
    @State private var playerVM: PlayerViewModel?
    @State private var lyricsVM: LyricsViewModel?

    var body: some View {
        Group {
            if let libraryVM, let playerVM, let lyricsVM {
                MainLayoutView()
                    .environment(uiState)
                    .environment(libraryVM)
                    .environment(playerVM)
                    .environment(lyricsVM)
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            setupDependencies()
        }
        // Appearance
        .preferredColorScheme(currentColorScheme)
        .tint(currentAccentColor)
        // Command Handling
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayPause)) { _ in
            playerVM?.togglePlayPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextTrack)) { _ in
            playerVM?.next()
        }
        .onReceive(NotificationCenter.default.publisher(for: .previousTrack)) { _ in
            playerVM?.previous()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLyrics)) { _ in
            uiState.toggleLyrics()
        }
    }

    // MARK: - Setup

    private func setupDependencies() {
        // Create repository with SwiftData
        let repository = SwiftDataLibraryRepository(modelContext: modelContext)

        // Create real playback service (AVAudioEngine)
        let playbackService = AVAudioPlaybackService()

        // Create real level meter and attach to playback engine
        let levelMeter = AudioLevelMeterService()
        levelMeter.attachToMixer(playbackService.mainMixerNode)

        // Create file import service
        let fileImportService = FileImportService(repository: repository)

        // Create ViewModels
        let libVM = LibraryViewModel(repository: repository)
        libVM.setImportService(fileImportService)

        libraryVM = libVM
        playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
        lyricsVM = LyricsViewModel()
    }

    // MARK: - Appearance Helpers

    private var currentColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var currentAccentColor: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }
}

// MARK: - Preview

#Preview("App Root") {
    AppRootView()
        .modelContainer(for: [Track.self, Playlist.self], inMemory: true)
        .frame(width: 1200, height: 800)
}

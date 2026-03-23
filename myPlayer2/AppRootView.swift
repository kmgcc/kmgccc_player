//
//  AppRootView.swift
//  myPlayer2
//
//  kmgccc_player - App Root View
//  Creates and injects all dependencies.
//

import SwiftData
import SwiftUI

/// Root view that sets up dependency injection.
/// Creates real services for production, stubs for previews.
@MainActor
struct AppRootView: View {

    @Environment(\.modelContext) private var modelContext

    // MARK: - App Globals (live updates via AppSettings)
    @State private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var swiftUIColorScheme
    @StateObject private var themeStore = ThemeStore.shared

    // MARK: - State Objects

    @State private var uiState = UIStateViewModel()
    @State private var libraryVM: LibraryViewModel?
    @State private var playerVM: PlayerViewModel?
    @State private var lyricsVM: LyricsViewModel?
    @State private var ledMeter: LEDMeterService?
    @State private var skinManager: SkinManager?
    @State private var easterEggSFX: EasterEggSFXService?
    @StateObject private var artBackgroundController = BKArtBackgroundController()
    @StateObject private var fullscreenWindowManager = FullscreenWindowManager.shared
    
    // MARK: - Cover Services
    @State private var coverDownloadService = CoverDownloadService()
    @State private var netEaseCoverService = NetEaseCoverService()

    var body: some View {
        Group {
            if let libraryVM, let playerVM, let lyricsVM, let ledMeter, let skinManager {
                ZStack {
                    if uiState.contentMode == .nowPlaying
                        && settings.nowPlayingArtBackgroundEnabled
                        && !fullscreenWindowManager.isFullscreenActive
                    {
                        BKArtBackgroundView(
                            controller: artBackgroundController,
                            trackID: playerVM.currentTrack?.id,
                            artworkData: playerVM.currentTrack?.artworkData,
                            isPlaying: playerVM.isPlaying
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }

                    MainLayoutView()
                }
                .onAppear {
                    if uiState.contentMode == .nowPlaying && settings.nowPlayingArtBackgroundEnabled
                    {
                        artBackgroundController.triggerTransition()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
                    print("[AppRoot] Track changed notification received")
                    Task { @MainActor in
                        await themeStore.updateTheme(for: playerVM.currentTrack)
                    }
                }
                .onChange(of: uiState.contentMode) { _, newValue in
                    if newValue == .nowPlaying && settings.nowPlayingArtBackgroundEnabled {
                        artBackgroundController.triggerTransition()
                    }
                }
                .onChange(of: playerVM.currentTrack?.id) { _, _ in
                    if uiState.contentMode == .nowPlaying && settings.nowPlayingArtBackgroundEnabled
                    {
                        artBackgroundController.triggerTransition()
                    }
                }
                .onChange(of: settings.nowPlayingArtBackgroundEnabled) { _, enabled in
                    if enabled && uiState.contentMode == .nowPlaying {
                        artBackgroundController.triggerTransition()
                    }
                }
                .onChange(of: fullscreenWindowManager.isFullscreenActive) { _, isActive in
                    if !isActive && uiState.contentMode == .nowPlaying && settings.nowPlayingArtBackgroundEnabled {
                        artBackgroundController.triggerTransition()
                    }
                }
                .environment(settings)
                .environment(uiState)
                .environment(libraryVM)
                .environment(playerVM)
                .environment(lyricsVM)
                .environment(ledMeter)
                .environment(skinManager)
                .environment(coverDownloadService)
                .environment(netEaseCoverService)
                .environmentObject(themeStore)
            } else {
                ProgressView(NSLocalizedString("alert.loading", comment: ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .onAppear {
            setupDependencies()
        }
        // Appearance
        .preferredColorScheme(currentColorScheme)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        // Global Sync for Appearance Changes
        .onChange(of: settings.followSystemAppearance) { _, _ in
            applyAppearanceToWindows()
        }
        .onChange(of: settings.manualAppearance) { _, _ in
            applyAppearanceToWindows()
        }
        .onChange(of: settings.globalArtworkTintEnabled) { _, _ in
            Task { @MainActor in
                await themeStore.refreshPalette(reason: "global_artwork_tint_toggle")
            }
        }
        // Theme Update Strategy: Follow effective SwiftUI ColorScheme
        .onChange(of: swiftUIColorScheme) { _, newScheme in
            syncThemeStoreWithSwiftUIColorScheme(newScheme)
        }
        .onAppear {
            applyAppearanceToWindows()
            syncThemeStoreWithSwiftUIColorScheme(swiftUIColorScheme)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .aboutEasterEggTriggered)) { _ in
            easterEggSFX?.playRandomIfAllowed()
        }
    }

    // MARK: - Setup

    @MainActor
    private func setupDependencies() {
        let libraryService = LocalLibraryService.shared
        libraryService.ensureLibraryFolders()

        // Create repository with SwiftData
        let repository = SwiftDataLibraryRepository(
            modelContext: modelContext,
            libraryService: libraryService
        )

        // Create real playback service (AVAudioEngine)
        let playbackService = AVAudioPlaybackService()

        // Create LED meter and attach to playback engine
        let ledMeter = LEDMeterService(
            config: LEDMeterConfig(
                ledCount: AppSettings.shared.ledCount,
                levels: AppSettings.shared.ledBrightnessLevels,
                cutoffHz: Float(AppSettings.shared.ledCutoffHz),
                preGain: Float(AppSettings.shared.ledPreGain),
                sensitivity: AppSettings.shared.ledSensitivity,
                speed: Float(AppSettings.shared.ledSpeed),
                targetHz: AppSettings.shared.ledTargetHz,
                transientThreshold: Float(AppSettings.shared.ledTransientThreshold)
            ))
        ledMeter.attachToMixer(playbackService.mainMixerNode)

        // Create file import service
        let fileImportService = FileImportService(
            repository: repository,
            libraryService: libraryService
        )

        // Create ViewModels
        let libVM = LibraryViewModel(
            repository: repository,
            libraryService: libraryService
        )
        libVM.setImportService(fileImportService)

        libraryVM = libVM
        playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: ledMeter)
        lyricsVM = LyricsViewModel(
            settings: AppSettings.shared,
            store: LyricsSurfaceManager.shared.mainStore
        )
        self.ledMeter = ledMeter
        skinManager = SkinManager()
        easterEggSFX = EasterEggSFXService()

        // Configure fullscreen window manager with dependencies
        FullscreenWindowManager.shared.configure(
            playerVM: playerVM!,
            lyricsVM: lyricsVM!,
            ledMeter: ledMeter,
            skinManager: skinManager!,
            uiState: uiState
        )

        libraryService.startMonitoring(repository: repository)
    }

    // MARK: - Appearance Helpers

    private var currentColorScheme: ColorScheme? {
        settings.colorScheme
    }

    private func applyAppearanceToWindows() {
        if settings.followSystemAppearance {
            print("[Appearance] Apply mode: system")
            NSApp.appearance = nil
            for window in NSApp.windows {
                window.appearance = nil
            }
        } else {
            let mode = settings.manualAppearance
            print("[Appearance] Apply mode: \(mode.rawValue)")
            let appearanceName: NSAppearance.Name = mode == .dark ? .darkAqua : .aqua
            let appearance = NSAppearance(named: appearanceName)
            NSApp.appearance = appearance
            for window in NSApp.windows {
                window.appearance = appearance
            }
        }
    }

    private func syncThemeStoreWithSwiftUIColorScheme(_ newScheme: ColorScheme) {
        print("[AppRoot] swiftUIColorScheme changed to \(newScheme)")
        themeStore.colorScheme = newScheme
        Task { @MainActor in
            await themeStore.refreshPalette(reason: "swiftui_colorScheme_changed")
        }
    }
}

// MARK: - Preview

#Preview("App Root") {
    AppRootView()
        .modelContainer(for: [TrackIndexEntry.self], inMemory: true)
        .frame(width: 1200, height: 800)
}

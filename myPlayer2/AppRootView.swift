//
//  AppRootView.swift
//  myPlayer2
//
//  kmgccc_player - App Root View
//  Creates and injects all dependencies.
//

import SwiftData
import SwiftUI

private struct DebugLaunchScenario {
    let trackID: UUID?
    let fullscreenSkinID: String?
    let showFullscreen: Bool
    let quitAfterSeconds: TimeInterval?

    var isEnabled: Bool {
        trackID != nil || fullscreenSkinID != nil || showFullscreen || quitAfterSeconds != nil
    }

    static var current: DebugLaunchScenario? {
        let environment = ProcessInfo.processInfo.environment
        let trackID = environment["KMGCCC_DEBUG_PROOF_TRACK_ID"].flatMap(UUID.init(uuidString:))
        let fullscreenSkinID = environment["KMGCCC_DEBUG_PROOF_FULLSCREEN_SKIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let showFullscreen = environment["KMGCCC_DEBUG_PROOF_SHOW_FULLSCREEN"].map {
            ["1", "true", "yes", "on"].contains($0.lowercased())
        } ?? false
        let quitAfterSeconds = environment["KMGCCC_DEBUG_PROOF_QUIT_AFTER_SECONDS"].flatMap {
            Double($0)
        }

        let scenario = DebugLaunchScenario(
            trackID: trackID,
            fullscreenSkinID: fullscreenSkinID,
            showFullscreen: showFullscreen,
            quitAfterSeconds: quitAfterSeconds
        )
        return scenario.isEnabled ? scenario : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

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

    @State private var hasSetupDependencies = false

    var body: some View {
        Group {
            if let libraryVM, let playerVM, let lyricsVM, let ledMeter, let skinManager {
                ZStack {
                    if uiState.contentMode == .nowPlaying
                        && settings.nowPlayingArtBackgroundEnabled
                        && playerVM.currentTrack != nil
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
                .id("app-main-content")
                .onAppear {
                    if uiState.contentMode == .nowPlaying
                        && settings.nowPlayingArtBackgroundEnabled
                        && playerVM.currentTrack != nil
                    {
                        artBackgroundController.triggerTransition()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
                    Log.debug("Track changed notification received", category: .ui)
                    Task { @MainActor in
                        await themeStore.updateTheme(for: playerVM.currentTrack)
                    }
                }
                .onChange(of: uiState.contentMode) { _, newValue in
                    if newValue == .nowPlaying
                        && settings.nowPlayingArtBackgroundEnabled
                        && playerVM.currentTrack != nil
                    {
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
                    if enabled && uiState.contentMode == .nowPlaying && playerVM.currentTrack != nil {
                        artBackgroundController.triggerTransition()
                    }
                }
                .onChange(of: fullscreenWindowManager.isFullscreenActive) { _, isActive in
                    if !isActive
                        && uiState.contentMode == .nowPlaying
                        && settings.nowPlayingArtBackgroundEnabled
                        && playerVM.currentTrack != nil
                    {
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
        .task {
            await setupAppOnLaunch()
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
        .onReceive(NotificationCenter.default.publisher(for: .enterFullscreen)) { _ in
            Log.debug("F-Key: Notification received", category: .fullscreen)
            let manager = FullscreenWindowManager.shared
            Log.trace("F-Key: isFullscreenActive=\(manager.isFullscreenActive), isTransitioning=\(manager.isTransitioning)", category: .fullscreen)
            guard !manager.isFullscreenActive else {
                Log.debug("F-Key: Already in fullscreen, ignoring", category: .fullscreen)
                return
            }
            guard !manager.isTransitioning else {
                Log.debug("F-Key: Transition in progress, ignoring", category: .fullscreen)
                return
            }
            Log.debug("F-Key: Dispatching to next runloop", category: .fullscreen)
            DispatchQueue.main.async {
                Log.info("F-Key: Executing showFullscreenWindow()", category: .fullscreen)
                manager.showFullscreenWindow()
            }
        }
    }

    // MARK: - Setup

    @MainActor
    private func setupAppOnLaunch() async {
        guard !hasSetupDependencies else { return }
        hasSetupDependencies = true
        print("[Lifecycle] AppRootView initial setup")
        setupDependencies()
        
        WhatsNewWindowManager.shared.showIfNeeded()
        print("[Lifecycle] WhatsNew window check completed")
        
        Task {
            await UpdateWindowManager.shared.checkAndShowIfNeeded()
        }
    }

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

        print("[Lifecycle] setupDependencies: libraryVM created, id: \(ObjectIdentifier(libVM))")
        libraryVM = libVM
        print("[Lifecycle] setupDependencies: libraryVM assigned, id: \(libraryVM.map { String(describing: ObjectIdentifier($0)) } ?? "nil")")
        playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: ledMeter)
        lyricsVM = LyricsViewModel(settings: AppSettings.shared)
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

        if let scenario = DebugLaunchScenario.current {
            Task { @MainActor in
                await runDebugLaunchScenarioIfNeeded(
                    scenario,
                    repository: repository,
                    playerVM: playerVM!
                )
            }
        }
    }

    // MARK: - Appearance Helpers

    private var currentColorScheme: ColorScheme? {
        settings.colorScheme
    }

    private func applyAppearanceToWindows() {
        if settings.followSystemAppearance {
            Log.trace("Apply appearance mode: system", category: .ui)
            NSApp.appearance = nil
            for window in NSApp.windows {
                window.appearance = nil
            }
        } else {
            let mode = settings.manualAppearance
            Log.trace("Apply appearance mode: \(mode.rawValue)", category: .ui)
            let appearanceName: NSAppearance.Name = mode == .dark ? .darkAqua : .aqua
            let appearance = NSAppearance(named: appearanceName)
            NSApp.appearance = appearance
            for window in NSApp.windows {
                window.appearance = appearance
            }
        }
    }

    private func syncThemeStoreWithSwiftUIColorScheme(_ newScheme: ColorScheme) {
        Log.debug("swiftUIColorScheme changed to \(newScheme)", category: .ui)
        themeStore.colorScheme = newScheme
        Task { @MainActor in
            await themeStore.refreshPalette(reason: "swiftui_colorScheme_changed")
        }
    }

    @MainActor
    private func runDebugLaunchScenarioIfNeeded(
        _ scenario: DebugLaunchScenario,
        repository: LibraryRepositoryProtocol,
        playerVM: PlayerViewModel
    ) async {
        Log.debug(
            "DebugLaunch scenario: trackID=\(scenario.trackID?.uuidString ?? "nil"), fullscreenSkin=\(scenario.fullscreenSkinID ?? "nil"), showFullscreen=\(scenario.showFullscreen), quitAfter=\(scenario.quitAfterSeconds ?? -1)",
            category: .ui
        )

        if let fullscreenSkinID = scenario.fullscreenSkinID {
            AppSettings.shared.selectedFullscreenSkinID = fullscreenSkinID
        }

        if let trackID = scenario.trackID {
            await repository.reloadFromLibrary()
            let tracks = await repository.fetchTracks(in: nil)
            guard let track = tracks.first(where: { $0.id == trackID }) else {
                Log.warning("DebugLaunch: track not found: \(trackID.uuidString)", category: .ui)
                scheduleDebugTerminationIfNeeded(after: scenario.quitAfterSeconds)
                return
            }

            uiState.showNowPlaying()
            playerVM.play(track: track)
            await themeStore.updateTheme(for: track)
            Log.debug("DebugLaunch: playing track \(track.title) (\(track.id.uuidString))", category: .ui)
        }

        if scenario.showFullscreen {
            let openDelay: TimeInterval = scenario.trackID == nil ? 0.25 : 0.9
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
                Log.debug("DebugLaunch: opening fullscreen window", category: .ui)
                FullscreenWindowManager.shared.showFullscreenWindow()
            }
        }

        scheduleDebugTerminationIfNeeded(after: scenario.quitAfterSeconds)
    }

    private func scheduleDebugTerminationIfNeeded(after seconds: TimeInterval?) {
        guard let seconds, seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Log.debug("DebugLaunch: terminating app after \(seconds)s", category: .ui)
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Preview

#Preview("App Root") {
    AppRootView()
        .modelContainer(for: [TrackIndexEntry.self], inMemory: true)
        .frame(width: 1200, height: 800)
}

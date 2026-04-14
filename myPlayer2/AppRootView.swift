//
//  AppRootView.swift
//  myPlayer2
//
//  kmgccc_player - App Root View
//  Creates and injects all dependencies.
//

import AppKit
import AVFoundation
import Combine
import SwiftData
import SwiftUI

private struct DebugLaunchScenario {
    enum LibrarySelectionMode: String {
        case allSongs
        case firstPlaylist
        case largestPlaylist
        case smallestPlaylist
    }

    let trackID: UUID?
    let fullscreenSkinID: String?
    let showFullscreen: Bool
    let quitAfterSeconds: TimeInterval?
    let autoNextInterval: TimeInterval?
    let autoNextCount: Int?
    let librarySelectionMode: LibrarySelectionMode?
    let forceLyricsVisible: Bool
    let resizePulseCount: Int?
    let resizePulseInterval: TimeInterval?

    var isEnabled: Bool {
        trackID != nil
            || fullscreenSkinID != nil
            || showFullscreen
            || quitAfterSeconds != nil
            || autoNextInterval != nil
            || autoNextCount != nil
            || librarySelectionMode != nil
            || forceLyricsVisible
            || resizePulseCount != nil
    }

    static var current: DebugLaunchScenario? {
        let environment = ProcessInfo.processInfo.environment
        let trackID = environment["KMGCCC_DEBUG_PROOF_TRACK_ID"].flatMap(UUID.init(uuidString:))
        let fullscreenSkinID = environment["KMGCCC_DEBUG_PROOF_FULLSCREEN_SKIN"]?
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
        let showFullscreen = environment["KMGCCC_DEBUG_PROOF_SHOW_FULLSCREEN"].map {
            ["1", "true", "yes", "on"].contains($0.lowercased())
        } ?? false
        let quitAfterSeconds = environment["KMGCCC_DEBUG_PROOF_QUIT_AFTER_SECONDS"].flatMap {
            Double($0)
        }
        let autoNextInterval = environment["KMGCCC_DEBUG_PROOF_AUTO_NEXT_INTERVAL"].flatMap {
            Double($0)
        }
        let autoNextCount = environment["KMGCCC_DEBUG_PROOF_AUTO_NEXT_COUNT"].flatMap {
            Int($0)
        }
        let librarySelectionMode = environment["KMGCCC_DEBUG_PROOF_LIBRARY_SELECTION"]
            .flatMap { LibrarySelectionMode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let forceLyricsVisible = environment["KMGCCC_DEBUG_PROOF_SHOW_LYRICS"].map {
            ["1", "true", "yes", "on"].contains($0.lowercased())
        } ?? (librarySelectionMode != nil)
        let resizePulseCount = environment["KMGCCC_DEBUG_PROOF_RESIZE_PULSES"].flatMap(Int.init)
        let resizePulseInterval = environment["KMGCCC_DEBUG_PROOF_RESIZE_INTERVAL"].flatMap(Double.init)

        let scenario = DebugLaunchScenario(
            trackID: trackID,
            fullscreenSkinID: fullscreenSkinID,
            showFullscreen: showFullscreen,
            quitAfterSeconds: quitAfterSeconds,
            autoNextInterval: autoNextInterval,
            autoNextCount: autoNextCount,
            librarySelectionMode: librarySelectionMode,
            forceLyricsVisible: forceLyricsVisible,
            resizePulseCount: resizePulseCount,
            resizePulseInterval: resizePulseInterval
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
    @ObservedObject var settingsSceneDependencies: SettingsSceneDependencies

    @Environment(\.modelContext) private var modelContext

    // MARK: - App Globals (live updates via AppSettings)
    @State private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var swiftUIColorScheme
    @StateObject private var themeStore = ThemeStore.shared
    @State private var presentedAccentColor = ThemeStore.shared.accentColor
    @State private var accentPresentationTask: Task<Void, Never>?

    // MARK: - State Objects

    @State private var uiState = UIStateViewModel()
    @State private var libraryVM: LibraryViewModel?
    @State private var playerVM: PlayerViewModel?
    @State private var lyricsVM: LyricsViewModel?
    @State private var ledMeterProvider: LEDMeterServiceProvider?
    @State private var importEnrichmentService: ImportEnrichmentService?
    @State private var skinManager: SkinManager?
    @State private var easterEggSFX: EasterEggSFXService?
    @StateObject private var artBackgroundController = BKArtBackgroundController()
    @StateObject private var fullscreenWindowManager = FullscreenWindowManager.shared

    // MARK: - Cover Services
    @State private var coverDownloadService = CoverDownloadService()
    @State private var netEaseCoverService = NetEaseCoverService()

    @State private var hasSetupDependencies = false

    var body: some View {
        let rootContent = AppRootContentView(
            libraryVM: libraryVM,
            playerVM: playerVM,
            lyricsVM: lyricsVM,
            ledMeterProvider: ledMeterProvider,
            importEnrichmentService: importEnrichmentService,
            skinManager: skinManager,
            settings: settings,
            uiState: uiState,
            artBackgroundController: artBackgroundController,
            fullscreenWindowManager: fullscreenWindowManager,
            coverDownloadService: coverDownloadService,
            netEaseCoverService: netEaseCoverService,
            themeStore: themeStore
        )
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .task {
                await setupAppOnLaunch()
            }
            .preferredColorScheme(currentColorScheme)
            .tint(presentedAccentColor)
            .accentColor(presentedAccentColor)
            .environment(\.libraryPresentedAccentColor, presentedAccentColor)

        let appearanceSyncView = rootContent
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
            .onChange(of: swiftUIColorScheme) { _, newScheme in
                syncThemeStoreWithSwiftUIColorScheme(newScheme)
            }
            .onAppear {
                applyAppearanceToWindows()
                syncThemeStoreWithSwiftUIColorScheme(swiftUIColorScheme)
                presentedAccentColor = themeStore.accentColor
                TintTimelineProbe.noteHeaderPublish(source: "AppRoot.onAppear")
            }
            .onReceive(themeStore.$accentColor) { newValue in
                TintTimelineProbe.noteRootReceive(source: "AppRoot.onReceive")
                schedulePresentedAccentColorUpdate(newValue)
            }

        let commandHandlersView = appearanceSyncView
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
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                uiState.toggleSidebar()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importMusic)) { _ in
                Task {
                    await libraryVM?.importToCurrentPlaylist()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newPlaylist)) { _ in
                Task {
                    _ = await libraryVM?.createNewPlaylist()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackModeChanged)) { _ in
                playerVM?.setShuffleEnabled(AppSettings.shared.shuffleEnabled)
            }

        return commandHandlersView
    }

    // MARK: - Setup

    private var mainWindowMinimumWidth: CGFloat {
        let baseWindowMinimumWidth: CGFloat = 1100
        let sidebarWidth =
            uiState.sidebarVisible
            ? max(uiState.sidebarLastWidth, Constants.Layout.sidebarMinWidth)
            : 0
        let lyricsWidth =
            (uiState.lyricsVisible
                && !uiState.lyricsPanelSuppressedByModal
                && !fullscreenWindowManager.isFullscreenActive)
            ? Constants.Layout.lyricsPanelMinWidth
            : 0
        let detailMinimumWidth = Constants.Layout.detailContentMinWidth

        return max(baseWindowMinimumWidth, sidebarWidth + detailMinimumWidth + lyricsWidth)
    }

    private func applyMainWindowMinimumSize(to window: NSWindow) {
        let minSize = NSSize(width: mainWindowMinimumWidth, height: 600)
        if window.contentMinSize != minSize {
            window.contentMinSize = minSize
        }
        if window.minSize != minSize {
            window.minSize = minSize
        }
    }

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

        // Create LED meter provider (lazy initialization)
        let ledMeterProvider = LEDMeterServiceProvider(
            config: LEDMeterConfig(
                ledCount: AppSettings.shared.ledCount,
                levels: AppSettings.shared.ledBrightnessLevels,
                cutoffHz: Float(AppSettings.shared.ledCutoffHz),
                preGain: Float(AppSettings.shared.ledPreGain),
                sensitivity: AppSettings.shared.ledSensitivity,
                speed: Float(AppSettings.shared.ledSpeed),
                targetHz: AppSettings.shared.ledTargetHz,
                transientThreshold: Float(AppSettings.shared.ledTransientThreshold)
            ),
            mixerProvider: { [weak playbackService] in
                playbackService?.mainMixerNode ?? AVAudioEngine().mainMixerNode
            }
        )

        let importEnrichmentService = ImportEnrichmentService(repository: repository)

        // Create file import service
        let fileImportService = FileImportService(
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: importEnrichmentService
        )

        // Create ViewModels
        let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: ledMeterProvider)
        let libVM = LibraryViewModel(
            repository: repository,
            libraryService: libraryService
        )
        libVM.setImportService(fileImportService)
        libVM.currentTrackIDProvider = { [weak playerVM] in
            playerVM?.currentTrack?.id
        }
        libVM.onTracksDeleted = { [weak playerVM] deletedTrackIDs in
            guard let playerVM, !deletedTrackIDs.isEmpty else { return }

            if let currentTrackID = playerVM.currentTrack?.id, deletedTrackIDs.contains(currentTrackID) {
                playerVM.stop()
                return
            }

            let remainingQueue = playerVM.currentQueueTracks.filter { !deletedTrackIDs.contains($0.id) }
            guard remainingQueue.count != playerVM.currentQueueTracks.count else { return }

            if remainingQueue.isEmpty {
                playerVM.stop()
            } else {
                playerVM.updateQueueTracks(remainingQueue)
            }
        }

        libraryVM = libVM
        self.playerVM = playerVM
        lyricsVM = LyricsViewModel(settings: AppSettings.shared)
        self.ledMeterProvider = ledMeterProvider
        self.importEnrichmentService = importEnrichmentService
        skinManager = SkinManager()
        easterEggSFX = EasterEggSFXService()

        // Configure fullscreen window manager with dependencies
        FullscreenWindowManager.shared.configure(
            playerVM: playerVM,
            lyricsVM: lyricsVM!,
            ledMeterProvider: ledMeterProvider,
            skinManager: skinManager!,
            uiState: uiState
        )

        settingsSceneDependencies.configure(
            libraryVM: libVM,
            playerVM: playerVM,
            lyricsVM: lyricsVM!,
            ledMeterProvider: ledMeterProvider
        )

        libraryService.startMonitoring(repository: repository)

        if let scenario = DebugLaunchScenario.current {
            Task { @MainActor in
                await runDebugLaunchScenarioIfNeeded(
                    scenario,
                    repository: repository,
                    libraryVM: libVM,
                    playerVM: playerVM
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

    private func schedulePresentedAccentColorUpdate(_ color: Color) {
        accentPresentationTask?.cancel()

        guard shouldDeferAccentPresentation else {
            presentedAccentColor = color
            TintTimelineProbe.noteRootCommit(source: "AppRoot.immediate")
            TintTimelineProbe.noteHeaderPublish(source: "AppRoot.immediate")
            return
        }

        accentPresentationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            presentedAccentColor = color
            TintTimelineProbe.noteRootCommit(source: "AppRoot.deferred")
            TintTimelineProbe.noteHeaderPublish(source: "AppRoot.deferred")
        }
    }

    private var shouldDeferAccentPresentation: Bool {
        guard uiState.contentMode == .library else { return false }
        guard uiState.lyricsVisible, !uiState.lyricsPanelSuppressedByModal else { return false }
        guard !fullscreenWindowManager.isFullscreenActive else { return false }

        switch libraryVM?.currentSelection {
        case .playlist, .artist, .album:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func runDebugLaunchScenarioIfNeeded(
        _ scenario: DebugLaunchScenario,
        repository: LibraryRepositoryProtocol,
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel
    ) async {
        Log.debug(
            "DebugLaunch scenario: trackID=\(scenario.trackID?.uuidString ?? "nil"), fullscreenSkin=\(scenario.fullscreenSkinID ?? "nil"), showFullscreen=\(scenario.showFullscreen), quitAfter=\(scenario.quitAfterSeconds ?? -1), autoNextInterval=\(scenario.autoNextInterval ?? -1), autoNextCount=\(scenario.autoNextCount ?? -1), librarySelection=\(scenario.librarySelectionMode?.rawValue ?? "nil"), forceLyricsVisible=\(scenario.forceLyricsVisible), resizePulses=\(scenario.resizePulseCount ?? -1), resizeInterval=\(scenario.resizePulseInterval ?? -1)",
            category: .ui
        )

        if let fullscreenSkinID = scenario.fullscreenSkinID {
            AppSettings.shared.selectedFullscreenSkinID = fullscreenSkinID
        }

        if scenario.forceLyricsVisible {
            uiState.lyricsVisible = true
        }

        if let librarySelectionMode = scenario.librarySelectionMode {
            await libraryVM.load()
            uiState.showLibrary()
            AppSettings.shared.shuffleEnabled = false

            let playlists = await repository.fetchPlaylists()
            let nonEmptyQueues = await nonEmptyPlaylistQueues(
                from: playlists,
                repository: repository
            )

            guard let queueSeed = debugQueueSeed(
                for: librarySelectionMode,
                from: nonEmptyQueues
            ) else {
                Log.warning("DebugLaunch: no non-empty playlist available for queue seed", category: .ui)
                scheduleDebugTerminationIfNeeded(after: scenario.quitAfterSeconds)
                return
            }

            switch librarySelectionMode {
            case .allSongs:
                libraryVM.currentSelection = .allSongs
            case .firstPlaylist, .largestPlaylist, .smallestPlaylist:
                libraryVM.currentSelection = .playlist(queueSeed.playlist.id)
            }

            let startIndex: Int
            if let trackID = scenario.trackID,
                let matchedIndex = queueSeed.tracks.firstIndex(where: { $0.id == trackID })
            {
                startIndex = matchedIndex
            } else {
                startIndex = 0
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
            playerVM.playTracks(queueSeed.tracks, startingAt: startIndex)
            Log.info(
                "DebugLaunch: library page=\(librarySelectionMode.rawValue), queueSeedPlaylist=\(queueSeed.playlist.name), queueCount=\(queueSeed.tracks.count), startIndex=\(startIndex)",
                category: .ui
            )
        } else if let trackID = scenario.trackID {
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

        scheduleDebugAutoNextIfNeeded(scenario: scenario, playerVM: playerVM)
        scheduleDebugResizeIfNeeded(scenario: scenario, libraryVM: libraryVM, playerVM: playerVM)
        scheduleDebugTerminationIfNeeded(after: scenario.quitAfterSeconds)
    }

    private func nonEmptyPlaylistQueues(
        from playlists: [Playlist],
        repository: LibraryRepositoryProtocol
    ) async -> [(playlist: Playlist, tracks: [Track])] {
        var result: [(playlist: Playlist, tracks: [Track])] = []
        for playlist in playlists {
            let tracks = await repository.fetchTracks(in: playlist)
            if !tracks.isEmpty {
                result.append((playlist, tracks))
            }
        }
        return result
    }

    private func debugQueueSeed(
        for selectionMode: DebugLaunchScenario.LibrarySelectionMode,
        from queues: [(playlist: Playlist, tracks: [Track])]
    ) -> (playlist: Playlist, tracks: [Track])? {
        guard !queues.isEmpty else { return nil }

        switch selectionMode {
        case .allSongs, .firstPlaylist:
            return queues.first
        case .largestPlaylist:
            return queues.max { lhs, rhs in lhs.tracks.count < rhs.tracks.count }
        case .smallestPlaylist:
            return queues.min { lhs, rhs in lhs.tracks.count < rhs.tracks.count }
        }
    }

    private func scheduleDebugAutoNextIfNeeded(
        scenario: DebugLaunchScenario,
        playerVM: PlayerViewModel
    ) {
        guard let autoNextCount = scenario.autoNextCount, autoNextCount > 0 else { return }

        let interval = max(scenario.autoNextInterval ?? 1.5, 0.25)
        let startDelay: TimeInterval = scenario.showFullscreen
            ? (scenario.trackID == nil ? 1.0 : 1.8)
            : (scenario.trackID == nil ? 0.6 : 1.0)

        for step in 0..<autoNextCount {
            let fireDelay = startDelay + (Double(step) * interval)
            DispatchQueue.main.asyncAfter(deadline: .now() + fireDelay) {
                Log.info(
                    "DebugLaunch: auto next \(step + 1)/\(autoNextCount), interval=\(interval)",
                    category: .ui
                )
                playerVM.next()
            }
        }
    }

    private func scheduleDebugTerminationIfNeeded(after seconds: TimeInterval?) {
        guard let seconds, seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Log.debug("DebugLaunch: terminating app after \(seconds)s", category: .ui)
            NSApp.terminate(nil)
        }
    }

    private func scheduleDebugResizeIfNeeded(
        scenario: DebugLaunchScenario,
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel
    ) {
        guard let resizePulseCount = scenario.resizePulseCount, resizePulseCount > 0 else { return }

        let interval = max(scenario.resizePulseInterval ?? 0.11, 0.04)
        let startDelay: TimeInterval = 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }

            let selectionLabel: String
            let hasHeader: Bool
            switch libraryVM.currentSelection {
            case .allSongs:
                selectionLabel = "allSongs"
                hasHeader = false
            case .playlist(let id):
                selectionLabel = "playlist:\(id.uuidString)"
                hasHeader = true
            case .artist(let key):
                selectionLabel = "artist:\(key)"
                hasHeader = true
            case .album(let key):
                selectionLabel = "album:\(key)"
                hasHeader = true
            }

            _ = LyricsRuntimeProfile.beginSession(
                trigger: "windowResize",
                selection: selectionLabel,
                hasHeader: hasHeader,
                contentMode: "library",
                trackID: playerVM.currentTrack?.id,
                trackTitle: playerVM.currentTrack?.title
            )
            LyricsRuntimeProfile.setMetadata("resize.pulse.count", value: "\(resizePulseCount)")
            LyricsRuntimeProfile.setMetadata("resize.pulse.intervalMs", value: "\(Int((interval * 1000).rounded()))")

            let originalFrame = window.frame
            let widthDelta = min(max(originalFrame.width * 0.16, 160), 280)
            let heightDelta = min(max(originalFrame.height * 0.08, 48), 120)

            for step in 0..<resizePulseCount {
                let isExpanded = step.isMultiple(of: 2)
                let targetSize = NSSize(
                    width: max(980, originalFrame.width + (isExpanded ? widthDelta : -widthDelta)),
                    height: max(620, originalFrame.height + (isExpanded ? heightDelta : -heightDelta))
                )
                let origin = NSPoint(
                    x: originalFrame.maxX - targetSize.width,
                    y: originalFrame.maxY - targetSize.height
                )
                let targetFrame = NSRect(origin: origin, size: targetSize)

                DispatchQueue.main.asyncAfter(deadline: .now() + (Double(step) * interval)) {
                    window.setFrame(targetFrame, display: true)
                }
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Double(resizePulseCount) * interval) + 0.08
            ) {
                window.setFrame(originalFrame, display: true)
            }
        }
    }
}

// MARK: - Content View

private struct AppRootContentView: View {
    let libraryVM: LibraryViewModel?
    let playerVM: PlayerViewModel?
    let lyricsVM: LyricsViewModel?
    let ledMeterProvider: LEDMeterServiceProvider?
    let importEnrichmentService: ImportEnrichmentService?
    let skinManager: SkinManager?

    let settings: AppSettings
    let uiState: UIStateViewModel
    let artBackgroundController: BKArtBackgroundController
    let fullscreenWindowManager: FullscreenWindowManager
    let coverDownloadService: CoverDownloadService
    let netEaseCoverService: NetEaseCoverService
    let themeStore: ThemeStore

    var body: some View {
        Group {
            if let libraryVM = libraryVM,
               let playerVM = playerVM,
               let lyricsVM = lyricsVM,
               let ledMeterProvider = ledMeterProvider,
               let importEnrichmentService = importEnrichmentService,
               let skinManager = skinManager {

                let showArtBackground = uiState.contentMode == .nowPlaying
                    && settings.nowPlayingArtBackgroundEnabled
                    && playerVM.currentTrack != nil
                    && !fullscreenWindowManager.isFullscreenActive

                MainAppContentView(
                    libraryVM: libraryVM,
                    playerVM: playerVM,
                    lyricsVM: lyricsVM,
                    ledMeterProvider: ledMeterProvider,
                    importEnrichmentService: importEnrichmentService,
                    skinManager: skinManager,
                    settings: settings,
                    uiState: uiState,
                    artBackgroundController: artBackgroundController,
                    fullscreenWindowManager: fullscreenWindowManager,
                    coverDownloadService: coverDownloadService,
                    netEaseCoverService: netEaseCoverService,
                    themeStore: themeStore,
                    showArtBackground: showArtBackground
                )
            } else {
                ProgressView(NSLocalizedString("alert.loading", comment: ""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct MainAppContentView: View {
    let libraryVM: LibraryViewModel
    let playerVM: PlayerViewModel
    let lyricsVM: LyricsViewModel
    let ledMeterProvider: LEDMeterServiceProvider
    let importEnrichmentService: ImportEnrichmentService
    let skinManager: SkinManager

    let settings: AppSettings
    let uiState: UIStateViewModel
    let artBackgroundController: BKArtBackgroundController
    let fullscreenWindowManager: FullscreenWindowManager
    let coverDownloadService: CoverDownloadService
    let netEaseCoverService: NetEaseCoverService
    let themeStore: ThemeStore
    let showArtBackground: Bool
    @State private var hasPresentedNowPlayingArtBackground = false

    var body: some View {
        mainContentView
    }

    private var contentView: some View {
        ZStack {
            artBackgroundView
            MainLayoutView()
        }
        .id("app-main-content")
    }

    @ViewBuilder
    private var artBackgroundView: some View {
        if showArtBackground {
            BKArtBackgroundView(
                controller: artBackgroundController,
                trackID: playerVM.currentTrack?.id,
                artworkData: playerVM.currentTrack?.artworkData,
                isPlaying: playerVM.isPlaying,
                resourceProfile: settings.selectedNowPlayingSkinID == "kmgccc.cassette"
                    ? .cassetteForeground
                    : .standard
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var mainContentView: some View {
        contentView
            .onAppear {
                handleOnAppear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
                handleTrackDidChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
                handleLibraryTrackDidUpdate(notification)
            }
            .onChange(of: uiState.contentMode) { _, newValue in
                handleContentModeChange(newValue)
            }
            .onChange(of: playerVM.currentTrack?.id) { _, _ in
                handleTrackIdChange()
            }
            .onChange(of: settings.nowPlayingArtBackgroundEnabled) { _, enabled in
                handleArtBackgroundEnabledChange(enabled)
            }
            .onChange(of: fullscreenWindowManager.isFullscreenActive) { _, isActive in
                handleFullscreenActiveChange(isActive)
            }
            .environment(settings)
            .environment(uiState)
            .environment(libraryVM)
            .environment(playerVM)
            .environment(lyricsVM)
            .environment(ledMeterProvider)
            .environment(importEnrichmentService)
            .environment(skinManager)
            .environment(coverDownloadService)
            .environment(netEaseCoverService)
            .environmentObject(themeStore)
            .background(
                WindowToolbarAccessor(
                    configure: applyMainWindowMinimumSize(to:),
                    configureContinuously: true
                )
            )
    }

    private func handleOnAppear() {
        guard shouldTriggerArtBackgroundTransition else { return }
        if markNowPlayingArtBackgroundPresentationIfNeeded() {
            return
        }
        artBackgroundController.triggerTransition()
    }

    private func handleTrackDidChange() {
        Log.debug("Track changed notification received", category: .ui)
        startLyricsRuntimeProfileIfNeeded(trigger: "playbackTrackDidChange")
        Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            await themeStore.updateTheme(for: playerVM.currentTrack)
            LyricsRuntimeProfile.increment("theme.updateTheme.count")
            LyricsRuntimeProfile.addDuration(
                "theme.updateTheme",
                ms: (ProcessInfo.processInfo.systemUptime - start) * 1000
            )
        }
    }

    private func handleLibraryTrackDidUpdate(_ notification: Notification) {
        guard let trackID = notification.userInfo?["trackID"] as? UUID else { return }
        guard let refreshedTrack = libraryVM.allTracks.first(where: { $0.id == trackID }) else {
            return
        }
        playerVM.refreshTracks([refreshedTrack])
        if playerVM.currentTrack?.id == trackID {
            Log.info(
                "[ImportEnrichmentReload] current detail/lyrics refreshed for current track if applicable",
                category: .library
            )
        }
    }

    private func handleContentModeChange(_ newValue: ContentMode) {
        guard newValue == .nowPlaying, shouldTriggerArtBackgroundTransition else { return }
        if markNowPlayingArtBackgroundPresentationIfNeeded() {
            return
        }
        artBackgroundController.triggerTransition()
    }

    private func handleTrackIdChange() {
        if uiState.contentMode == .nowPlaying && settings.nowPlayingArtBackgroundEnabled {
            artBackgroundController.triggerTransition()
        }
    }

    private func handleArtBackgroundEnabledChange(_ enabled: Bool) {
        if enabled && uiState.contentMode == .nowPlaying && playerVM.currentTrack != nil {
            artBackgroundController.triggerTransition()
        }
    }

    private func handleFullscreenActiveChange(_ isActive: Bool) {
        if !isActive && shouldTriggerArtBackgroundTransition {
            artBackgroundController.triggerTransition()
        }
    }

    private var shouldTriggerArtBackgroundTransition: Bool {
        uiState.contentMode == .nowPlaying
            && settings.nowPlayingArtBackgroundEnabled
            && playerVM.currentTrack != nil
    }

    @discardableResult
    private func markNowPlayingArtBackgroundPresentationIfNeeded() -> Bool {
        let isFirstPresentation = !hasPresentedNowPlayingArtBackground
        if isFirstPresentation {
            hasPresentedNowPlayingArtBackground = true
        }
        return isFirstPresentation
    }

    private func startLyricsRuntimeProfileIfNeeded(trigger: String) {
        guard LyricsRuntimeProfile.enabled else { return }
        guard uiState.contentMode == .library else { return }
        guard uiState.lyricsVisible, !uiState.lyricsPanelSuppressedByModal else { return }
        guard !fullscreenWindowManager.isFullscreenActive else { return }

        let selectionLabel: String
        let hasHeader: Bool
        switch libraryVM.currentSelection {
        case .allSongs:
            selectionLabel = "allSongs"
            hasHeader = false
        case .playlist(let id):
            selectionLabel = "playlist:\(id.uuidString)"
            hasHeader = true
        case .artist(let key):
            selectionLabel = "artist:\(key)"
            hasHeader = true
        case .album(let key):
            selectionLabel = "album:\(key)"
            hasHeader = true
        }

        _ = LyricsRuntimeProfile.beginSession(
            trigger: trigger,
            selection: selectionLabel,
            hasHeader: hasHeader,
            contentMode: "library",
            trackID: playerVM.currentTrack?.id,
            trackTitle: playerVM.currentTrack?.title
        )
    }

    private func applyMainWindowMinimumSize(to window: NSWindow) {
        let sidebarWidth =
            uiState.sidebarVisible
            ? max(uiState.sidebarLastWidth, Constants.Layout.sidebarMinWidth)
            : 0
        let lyricsWidth =
            (uiState.lyricsVisible
                && !uiState.lyricsPanelSuppressedByModal
                && !fullscreenWindowManager.isFullscreenActive)
            ? Constants.Layout.lyricsPanelMinWidth
            : 0
        let detailMinimumWidth = Constants.Layout.detailContentMinWidth
        let minWidth = max(1100, sidebarWidth + detailMinimumWidth + lyricsWidth)
        let minSize = NSSize(width: minWidth, height: 600)

        if window.contentMinSize != minSize {
            window.contentMinSize = minSize
        }
        if window.minSize != minSize {
            window.minSize = minSize
        }
    }
}

// MARK: - Preview

#Preview("App Root") {
    AppRootView(settingsSceneDependencies: SettingsSceneDependencies())
        .modelContainer(for: [TrackIndexEntry.self], inMemory: true)
        .frame(width: 1200, height: 800)
}

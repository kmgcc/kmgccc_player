//
//  AppSessionHost.swift
//  myPlayer2
//
//  kmgccc_player - App-wide shared dependency host
//  Keeps playback and queue state alive independently from window lifecycle.
//

import AppKit
import AVFoundation
import Combine
import SwiftData

@MainActor
final class AppSessionHost: ObservableObject {
    @Published private(set) var libraryVM: LibraryViewModel?
    @Published private(set) var playerVM: PlayerViewModel?
    @Published private(set) var playbackCoordinator: PlaybackCoordinator?
    @Published private(set) var lyricsVM: LyricsViewModel?
    @Published private(set) var ledMeterProvider: LEDMeterServiceProvider?
    @Published private(set) var importEnrichmentService: ImportEnrichmentService?
    @Published private(set) var skinManager: SkinManager?

    let uiState = UIStateViewModel()
    /// Stable across HomeView lifetime so the random Hero pick survives navigation.
    let homeVM = HomeViewModel()

    private let modelContainer: ModelContainer
    private let settingsSceneDependencies: SettingsSceneDependencies
    private var hasSetupDependencies = false
    private var playbackModeObserver: NSObjectProtocol?
    private var libraryLocationObserver: NSObjectProtocol?
    private var libraryService: LocalLibraryService?
    private var repository: LibraryRepositoryProtocol?
    private var playbackMemoryTimer: Timer?
    private let mainThreadStallMonitor = MainThreadStallMonitor()
    private var firstUsePrewarmTask: Task<Void, Never>?
    private var didAttemptPlaybackMemoryRestore = false

    init(
        modelContainer: ModelContainer,
        settingsSceneDependencies: SettingsSceneDependencies
    ) {
        self.modelContainer = modelContainer
        self.settingsSceneDependencies = settingsSceneDependencies
    }

    var sharedModelContainer: ModelContainer {
        modelContainer
    }

    func setupIfNeeded() async {
        guard !hasSetupDependencies else { return }
        hasSetupDependencies = true

        print("[Lifecycle] AppSessionHost initial setup")
        mainThreadStallMonitor.start()
        setupDependencies()
        await restorePlaybackMemoryIfNeeded()

        AppVersionGate.shared.recordCurrentAppLaunch()
        WhatsNewWindowManager.shared.showIfNeeded()
        print("[Lifecycle] WhatsNew window check completed")

        if UpdateCheckPreferences.checkForUpdatesOnLaunch {
            Task {
                await UpdateWindowManager.shared.checkAndShowIfNeeded()
            }
        } else {
            print("[UpdateWindowManager] Skipping launch update check by user preference")
        }
    }

    private func setupDependencies() {
        let libraryService = LocalLibraryService.shared
        libraryService.ensureLibraryFolders()

        let repository = SwiftDataLibraryRepository(
            modelContext: modelContainer.mainContext,
            libraryService: libraryService
        )

        let playbackService = AVAudioPlaybackService()

        let ledMeterProvider = LEDMeterServiceProvider(
            config: LEDMeterConfig(
                ledCount: AppSettings.shared.ledCount,
                levels: AppSettings.shared.ledBrightnessLevels,
                cutoffHz: Float(AppSettings.shared.ledCutoffHz),
                sensitivity: AppSettings.shared.ledSensitivity,
                speed: Float(AppSettings.shared.ledSpeed),
                targetHz: AppSettings.shared.ledTargetHz
            ),
            mixerProvider: { [weak playbackService] in
                playbackService?.mainMixerNode ?? AVAudioEngine().mainMixerNode
            }
        )

        let importEnrichmentService = ImportEnrichmentService(repository: repository)
        let fileImportService = FileImportService(
            repository: repository,
            libraryService: libraryService,
            importEnrichmentService: importEnrichmentService
        )

        let playerVM = PlayerViewModel(
            playbackService: playbackService,
            levelMeter: ledMeterProvider
        )
        let libraryVM = LibraryViewModel(
            repository: repository,
            libraryService: libraryService
        )
        PreferenceStatsLifecycleHandler.shared.configure { [weak libraryVM] trackID in
            libraryVM?.allTracks.first { $0.id == trackID }
        }
        let appleMusicAdapter = AppleMusicPlaybackAdapter(libraryVM: libraryVM)
        let systemNowPlayingProvider = SystemNowPlayingProvider(libraryVM: libraryVM)
        let playbackCoordinator = PlaybackCoordinator(
            playerVM: playerVM,
            appleMusicAdapter: appleMusicAdapter,
            systemNowPlayingProvider: systemNowPlayingProvider,
            meterProvider: ledMeterProvider
        )

        let lyricsVM = LyricsViewModel(settings: AppSettings.shared)
        lyricsVM.setPlaybackSourceProvider { [weak playbackCoordinator] in
            playbackCoordinator?.activeSource ?? .local
        }

        playbackCoordinator.onActiveSourceChanged = { [weak ledMeterProvider, weak lyricsVM] source in
            ledMeterProvider?.playbackSource = source
            AudioVisualizationService.shared.setExternalMode(source.isExternal)
            lyricsVM?.refreshConfigFromSettings()
        }
        TelemetryService.shared.configure(playbackCoordinator: playbackCoordinator)
        ledMeterProvider.playbackSource = playbackCoordinator.activeSource
        AudioVisualizationService.shared.setExternalMode(playbackCoordinator.activeSource.isExternal)
        libraryVM.setImportService(fileImportService)
        libraryVM.currentTrackIDProvider = { [weak playerVM] in
            playerVM?.currentTrack?.id
        }
        libraryVM.onTracksDeleted = { [weak playerVM] deletedTrackIDs in
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

        let skinManager = SkinManager()
        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.playbackCoordinator = playbackCoordinator
        self.lyricsVM = lyricsVM
        self.ledMeterProvider = ledMeterProvider
        self.importEnrichmentService = importEnrichmentService
        self.skinManager = skinManager
        self.libraryService = libraryService
        self.repository = repository

        FullscreenWindowManager.shared.configure(
            libraryVM: libraryVM,
            playerVM: playerVM,
            playbackCoordinator: playbackCoordinator,
            lyricsVM: lyricsVM,
            ledMeterProvider: ledMeterProvider,
            skinManager: skinManager,
            uiState: uiState
        )
        AppDelegate.shared?.configureDockPlayback(playbackCoordinator: playbackCoordinator)
        AppDelegate.applicationWillTerminateHandler = { [weak self] in
            TelemetryService.shared.endSession(reason: .appTerminated)
            self?.savePlaybackMemory()
            if let libraryVM = self?.libraryVM {
                PreferenceStatsService.shared.saveAllPendingNow(
                    trackProvider: { trackID in
                        libraryVM.allTracks.first { $0.id == trackID }
                    },
                    synchronously: true
                )
            }
            Task {
                await QQMusicHelperProcess.shared.terminate()
            }
        }

        settingsSceneDependencies.configure(
            libraryVM: libraryVM,
            playerVM: playerVM,
            lyricsVM: lyricsVM,
            ledMeterProvider: ledMeterProvider
        )

        if playbackModeObserver == nil {
            playbackModeObserver = NotificationCenter.default.addObserver(
                forName: .playbackModeChanged,
                object: nil,
                queue: .main
            ) { [weak playerVM] _ in
                let playerViewModel = playerVM
                Task { @MainActor in
                    playerViewModel?.syncPlaybackOrderModeFromSettings()
                }
            }
        }

        libraryService.startMonitoring(repository: repository)
        startPlaybackMemoryAutosave()
        scheduleFirstUsePrewarm(
            libraryVM: libraryVM,
            playerVM: playerVM,
            playbackCoordinator: playbackCoordinator
        )

        if libraryLocationObserver == nil {
            libraryLocationObserver = NotificationCenter.default.addObserver(
                forName: .libraryLocationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // NotificationCenter delivers this observer on .main; keep the restart synchronous.
                MainActor.assumeIsolated {
                    guard let self, let repository = self.repository else { return }
                    self.libraryService?.restartMonitoring(repository: repository)
                    Log.info(
                        "[AppSessionHost] Restarted library monitoring after location change",
                        category: .library
                    )
                }
            }
        }

        if let scenario = DebugLaunchScenario.current {
            Task { @MainActor in
                await runDebugLaunchScenarioIfNeeded(
                    scenario,
                    repository: repository,
                    libraryVM: libraryVM,
                    playerVM: playerVM
                )
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let playbackModeObserver {
                NotificationCenter.default.removeObserver(playbackModeObserver)
            }
            if let libraryLocationObserver {
                NotificationCenter.default.removeObserver(libraryLocationObserver)
            }
            playbackMemoryTimer?.invalidate()
            firstUsePrewarmTask?.cancel()
            AppDelegate.applicationWillTerminateHandler = nil
        }
    }

    private func scheduleFirstUsePrewarm(
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel,
        playbackCoordinator: PlaybackCoordinator
    ) {
        firstUsePrewarmTask?.cancel()
        firstUsePrewarmTask = Task(priority: .background) { @MainActor [weak self, weak libraryVM, weak playerVM, weak playbackCoordinator] in
            guard let self else { return }

            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            LyricsSurfaceManager.shared.prewarm(role: .main, reason: "app-start-idle")

            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled, let libraryVM else { return }

            let isPlaying = (playerVM?.isPlaying ?? false)
                || (playbackCoordinator?.presentation.isPlaying ?? false)
            if isPlaying {
                Log.info(
                    "[FirstUsePrewarm] deferring Home snapshot prewarm while playback is active",
                    category: .perf
                )
            } else {
                let token = FirstUseHitchDiagnostics.begin(
                    "FirstUsePrewarm.homeSnapshot",
                    detail: "tracks=\(libraryVM.allTracks.count)"
                )
                await self.homeVM.loadCachedStartupSnapshot()
                if !libraryVM.allTracks.isEmpty {
                    self.homeVM.refresh(from: libraryVM)
                }
                FirstUseHitchDiagnostics.end(token)
            }

            try? await Task.sleep(for: .milliseconds(isPlaying ? 3_000 : 1_800))
            guard !Task.isCancelled else { return }

            LyricsSurfaceManager.shared.prewarm(role: .fullscreen, reason: "app-start-idle")
        }
    }

    private func startPlaybackMemoryAutosave() {
        playbackMemoryTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePlaybackMemory()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackMemoryTimer = timer
    }

    private func savePlaybackMemory() {
        guard playbackCoordinator?.activeSource == .local else {
            PlaybackMemoryStore.clear()
            return
        }
        guard let playerVM, let currentTrack = playerVM.currentTrack else {
            PlaybackMemoryStore.clear()
            return
        }

        let currentTime = playerVM.currentTime.isFinite ? max(0, playerVM.currentTime) : 0
        let duration = playerVM.duration.isFinite ? max(0, playerVM.duration) : 0

        PlaybackMemoryStore.save(
            PlaybackMemory(
                savedAt: Date(),
                trackID: currentTrack.id,
                currentTime: currentTime,
                duration: duration
            )
        )
    }

    private func restorePlaybackMemoryIfNeeded() async {
        guard !didAttemptPlaybackMemoryRestore else { return }
        didAttemptPlaybackMemoryRestore = true

        guard DebugLaunchScenario.current == nil else { return }
        guard let memory = PlaybackMemoryStore.loadValid() else { return }
        guard let repository, let playbackCoordinator else { return }

        await repository.reloadFromLibrary()

        let restoredQueue = await repository.fetchTracks(in: nil)
            .filter { $0.availability != .missing }
        guard let startIndex = restoredQueue.firstIndex(where: { $0.id == memory.trackID }) else {
            PlaybackMemoryStore.clear()
            return
        }

        playbackCoordinator.playTracks(restoredQueue, startingAt: startIndex)

        let seekTime = PlaybackMemoryStore.restorableTime(from: memory)
        if seekTime > 0 {
            playbackCoordinator.seek(to: seekTime)
        }
        playbackCoordinator.pause()
    }

    private func runDebugLaunchScenarioIfNeeded(
        _ scenario: DebugLaunchScenario,
        repository: LibraryRepositoryProtocol,
        libraryVM: LibraryViewModel,
        playerVM: PlayerViewModel
    ) async {
        Log.debug(
            "DebugLaunch scenario: trackID=\(scenario.trackID?.uuidString ?? "nil"), fullscreenSkin=\(scenario.fullscreenSkinID ?? "nil"), showFullscreen=\(scenario.showFullscreen), showEmbeddedFullscreen=\(scenario.showEmbeddedFullscreen), quitAfter=\(scenario.quitAfterSeconds ?? -1), autoNextInterval=\(scenario.autoNextInterval ?? -1), autoNextCount=\(scenario.autoNextCount ?? -1), librarySelection=\(scenario.librarySelectionMode?.rawValue ?? "nil"), forceLyricsVisible=\(scenario.forceLyricsVisible), resizePulses=\(scenario.resizePulseCount ?? -1), resizeInterval=\(scenario.resizePulseInterval ?? -1)",
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
            await ThemeStore.shared.updateTheme(for: track)
            Log.debug("DebugLaunch: playing track \(track.title) (\(track.id.uuidString))", category: .ui)
        }

        if scenario.showFullscreen {
            let openDelay: TimeInterval = scenario.trackID == nil ? 0.25 : 0.9
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
                Log.debug("DebugLaunch: opening fullscreen window", category: .ui)
                FullscreenWindowManager.shared.showFullscreenWindow()
            }
        }

        if scenario.showEmbeddedFullscreen {
            let openDelay: TimeInterval = scenario.trackID == nil ? 0.25 : 0.9
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) {
                Log.info("DebugLaunch: opening embedded fullscreen", category: .ui)
                FullscreenWindowManager.shared.showFullscreenPlayerInWindow()
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
            case .home:
                selectionLabel = "home"
                hasHeader = false
            case .allSongs:
                selectionLabel = "allSongs"
                hasHeader = false
            case .allAlbums:
                selectionLabel = "allAlbums"
                hasHeader = false
            case .allArtists:
                selectionLabel = "allArtists"
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
            LyricsRuntimeProfile.setMetadata(
                "resize.pulse.intervalMs",
                value: "\(Int((interval * 1000).rounded()))"
            )

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

@MainActor
private final class MainThreadStallMonitor {
    private var timer: DispatchSourceTimer?
    private var expectedFireTime = DispatchTime.now()

    private let interval: DispatchTimeInterval = .milliseconds(50)
    private let intervalNanoseconds: UInt64 = 50_000_000
    private let warningThresholdMs = 50.0
    private let criticalThresholdMs = 100.0

    func start() {
        guard timer == nil else { return }

        expectedFireTime = .now() + interval

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: expectedFireTime, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer
        timer.resume()

        if LogConfig.perfDebugEnabled {
            Log.info("[MainThreadStall] monitor started thresholdMs=50", category: .perf)
        }
    }

    private func tick() {
        let now = DispatchTime.now()
        let delayNs = now.uptimeNanoseconds > expectedFireTime.uptimeNanoseconds
            ? now.uptimeNanoseconds - expectedFireTime.uptimeNanoseconds
            : 0
        let delayMs = Double(delayNs) / 1_000_000.0

        if delayMs >= warningThresholdMs {
            let severity = delayMs >= criticalThresholdMs ? "critical" : "warning"
            let operation = FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none"
            Log.warning(
                "[MainThreadStall] delayMs=\(String(format: "%.1f", delayMs)) severity=\(severity) operation=\(operation)",
                category: .perf
            )
        }

        expectedFireTime = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + intervalNanoseconds)
    }
}

private struct PlaybackMemory: Codable {
    let savedAt: Date
    let trackID: UUID
    let currentTime: Double
    let duration: Double
}

private enum PlaybackMemoryStore {
    private static let key = "playback.memory.v1"
    private static let expirationInterval: TimeInterval = 18 * 60 * 60

    static func save(_ memory: PlaybackMemory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func loadValid(now: Date = Date()) -> PlaybackMemory? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let memory = try? JSONDecoder().decode(PlaybackMemory.self, from: data) else {
            clear()
            return nil
        }

        guard now.timeIntervalSince(memory.savedAt) <= expirationInterval else {
            clear()
            return nil
        }

        return memory
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func restorableTime(from memory: PlaybackMemory) -> Double {
        guard memory.currentTime.isFinite else { return 0 }
        let lowerBoundedTime = max(0, memory.currentTime)
        guard memory.duration.isFinite, memory.duration > 1 else {
            return lowerBoundedTime
        }
        return min(lowerBoundedTime, memory.duration - 1)
    }
}

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
    let showEmbeddedFullscreen: Bool
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
            || showEmbeddedFullscreen
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
        let showEmbeddedFullscreen = environment["KMGCCC_DEBUG_PROOF_SHOW_EMBEDDED_FULLSCREEN"].map {
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
            showEmbeddedFullscreen: showEmbeddedFullscreen,
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

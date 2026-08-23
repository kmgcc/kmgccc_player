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

/// Raised when a user-initiated library switch is rejected because background
/// metadata enrichment is still running for the active library. Switching
/// sessions would tear down the in-flight enrichment work.
nonisolated enum LibrarySwitchBlockedError: Error, Equatable {
    case enrichmentInProgress
}

@MainActor
final class AppSessionHost: ObservableObject {
    @Published private(set) var libraryVM: LibraryViewModel?
    @Published private(set) var playerVM: PlayerViewModel?
    @Published private(set) var playbackCoordinator: PlaybackCoordinator?
    @Published private(set) var lyricsVM: LyricsViewModel?
    @Published private(set) var ledMeterProvider: LEDMeterServiceProvider?
    @Published private(set) var importEnrichmentService: ImportEnrichmentService?
    @Published private(set) var skinManager: SkinManager?
    /// True once the first `setupIfNeeded()` pass finished. Lets the window
    /// distinguish "still loading the initial library" from "no library
    /// configured" instead of showing an indefinite spinner.
    @Published private(set) var hasCompletedInitialSetup = false
    private var didAutoPresentLibrarySetup = false
    /// Set when this launch auto-created the factory-default library because
    /// the machine had no library at all (true fresh install / full reset).
    /// Drives the first-run setup wizard after What's New is dismissed.
    private var shouldPresentFirstRunLibrarySetup = false
    private var whatsNewDismissalCancellable: AnyCancellable?

    let uiState: UIStateViewModel
    let librarySetupFlow = LibrarySetupViewModel()
    let activeLibraryBinding: ActiveLibraryBinding

    var cacheServices: LibraryCacheServices? {
        activeLibraryBinding.activeSession?.cacheServices
    }

    var homeVM: HomeViewModel {
        activeLibraryBinding.activeSession?.homeViewModel ?? placeholderHomeViewModel
    }

    var playbackHistoryStore: PlaybackHistoryStore {
        activeLibraryBinding.activeSession?.playbackHistoryStore ?? placeholderPlaybackHistoryStore
    }

    /// Shared by the history page and AppKit's main-window toolbar so search,
    /// range, multiselect, and destructive actions have one source of truth.
    var playbackHistoryViewModel: PlaybackHistoryViewModel {
        activeLibraryBinding.activeSession?.playbackHistoryViewModel
            ?? placeholderPlaybackHistoryViewModel
    }

    private let placeholderHomeViewModel: HomeViewModel
    private let placeholderPlaybackHistoryStore: PlaybackHistoryStore
    private let placeholderPlaybackHistoryViewModel: PlaybackHistoryViewModel
    private let initialLibraryContext: LibraryContext?
    private let sessionController: LibrarySessionController
    private let sessionValidator: LibrarySessionFactoryValidator
    private let registryStore: MusicLibraryRegistryStore?
    private let libraryLifecycleGate = LibraryLifecycleTransactionGate()

    private(set) lazy var libraryOpenService: LibraryOpenService? = registryStore.map {
        LibraryOpenService(
            registryStore: $0,
            sessionController: sessionController,
            gate: libraryLifecycleGate
        )
    }
    private(set) lazy var libraryCreationService: LibraryCreationService? = {
        guard let registryStore, let libraryOpenService else { return nil }
        return LibraryCreationService(
            registryStore: registryStore,
            openService: libraryOpenService,
            gate: libraryLifecycleGate
        )
    }()
    private(set) lazy var libraryRelocationService: LibraryRelocationService? = registryStore.map {
        LibraryRelocationService(
            registryStore: $0,
            sessionController: sessionController,
            sessionValidator: sessionValidator,
            gate: libraryLifecycleGate
        )
    }
    private(set) lazy var libraryRemovalService: LibraryRemovalService? = registryStore.map {
        LibraryRemovalService(
            registryStore: $0,
            sessionController: sessionController,
            gate: libraryLifecycleGate
        )
    }

    private var hasSetupDependencies = false
    private var playbackModeObserver: NSObjectProtocol?
    private var workspaceLibraryObservers: [NSObjectProtocol] = []
    private var appActiveLibraryObserver: NSObjectProtocol?
    private var activeLibraryRescanTask: Task<Void, Never>?
    private var playbackMemoryTimer: Timer?
    private let mainThreadStallMonitor = MainThreadStallMonitor()
    private var firstUsePrewarmTask: Task<Void, Never>?
    private var lyricsPlaybackPipeline: LyricsPlaybackPipeline?
    private var didAttemptPlaybackMemoryRestore = false
    private var didScheduleDeferredLaunchPrompts = false

    init(
        modelContainer: ModelContainer,
        initialLibraryContext: LibraryContext?,
        registryStore: MusicLibraryRegistryStore? = try? MusicLibraryRegistryStore(),
        sessionFactory: LibrarySessionFactory = LibrarySessionFactory(),
        playbackHistoryStore: PlaybackHistoryStore? = nil,
        playbackHistoryViewModel: PlaybackHistoryViewModel = PlaybackHistoryViewModel()
    ) {
        let uiState = UIStateViewModel()
        self.uiState = uiState
        sessionFactory.referencedSourceNoticePublisher = SidebarReferencedSourceNoticePublisher { [weak uiState] notice in
            guard let uiState else { return }
            AppSessionHost.presentReferencedSourceNotice(notice, in: uiState)
        }

        let activeLibraryBinding = ActiveLibraryBinding(
            placeholderModelContainer: modelContainer
        )
        self.activeLibraryBinding = activeLibraryBinding
        self.initialLibraryContext = initialLibraryContext
        self.sessionController = LibrarySessionController(factory: sessionFactory)
        self.sessionValidator = LibrarySessionFactoryValidator(factory: sessionFactory)
        self.registryStore = registryStore
        let placeholderPaths = initialLibraryContext?.paths ?? LibraryPaths(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "kmgccc-player-placeholder-library",
                isDirectory: true
            )
        )
        self.placeholderHomeViewModel = HomeViewModel(paths: placeholderPaths)
        self.placeholderPlaybackHistoryStore = playbackHistoryStore ?? .inMemory()
        self.placeholderPlaybackHistoryViewModel = playbackHistoryViewModel
        self.skinManager = SkinManager()

        sessionController.willReleaseActiveSession = { [weak self] in
            await self?.releaseActiveSessionBindings()
        }
        sessionController.didActivateSession = { [weak self] session in
            guard let self, let session = session as? LibrarySession else { return }
            self.publishActiveSession(session)
            do {
                try await self.registryStore?.setActiveLibrary(
                    id: session.context.id,
                    manifestMode: session.context.mode
                )
            } catch {
                Log.error(
                    "[LibrarySession] failed to update active registry pointer library=\(session.context.id): \(error)",
                    category: .library
                )
            }
        }
    }

    private static func presentReferencedSourceNotice(
        _ notice: ReferencedSourceNotice,
        in uiState: UIStateViewModel
    ) {
        switch notice {
        case .filesImported(_, let count):
            uiState.showSidebarNotice(
                "来源文件夹新增 \(count) 首歌曲，正在补全信息",
                duration: 4
            )
        case .unavailable(_, _):
            uiState.showSidebarNotice(
                "来源文件夹暂时不可用",
                style: .warning,
                actionTitle: "打开设置"
            )
        case .fileFailures(_, let count):
            uiState.showSidebarNotice(
                "来源文件夹中有 \(count) 个文件未能导入",
                style: .warning,
                actionTitle: "打开设置"
            )
        case .reconcileFailures(_, let trackIDs):
            uiState.showSidebarNotice(
                "有 \(trackIDs.count) 首歌曲未能更新",
                style: .warning,
                actionTitle: "打开设置"
            )
        case .monitorFailure:
            uiState.showSidebarNotice(
                "来源文件夹扫描失败，请检查来源设置",
                style: .warning,
                actionTitle: "打开设置"
            )
        }
    }

    var sharedModelContainer: ModelContainer {
        activeLibraryBinding.modelContainer
    }

    /// True while the active library still has background enrichment work.
    /// User-initiated library switches are rejected in this state so the
    /// in-flight completion of song metadata is not interrupted.
    var isLibrarySwitchBlocked: Bool {
        importEnrichmentService?.hasOutstandingWork == true
    }

    private func guardLibrarySwitchAllowed() throws {
        guard isLibrarySwitchBlocked else { return }
        uiState.showSidebarNotice(
            "正在后台补全歌曲信息，完成后才能切换资料库",
            style: .warning
        )
        throw LibrarySwitchBlockedError.enrichmentInProgress
    }

    func musicLibraryRegistrySnapshot() async -> MusicLibraryRegistry {
        await registryStore?.snapshot() ?? MusicLibraryRegistry()
    }

    func openMusicLibrary(at url: URL) async throws -> [UUID] {
        try guardLibrarySwitchAllowed()
        guard let libraryOpenService else { throw LibraryOpenError.libraryNotFound }
        let selectedURL = url.standardizedFileURL
        let defaultRoot = LibraryLocationStore.defaultLibraryRootURL.standardizedFileURL
        let isDefaultLibrarySelection = selectedURL == defaultRoot
            || selectedURL.appendingPathComponent(LibraryPaths.rootDirectoryName, isDirectory: true)
                .standardizedFileURL == defaultRoot
        _ = try await libraryOpenService.open(
            selectedURL: selectedURL,
            allowStalePathConflictRepair: isDefaultLibrarySelection
        )
        return try await unavailableReferencedSourceIDs()
    }

    func openInspectedMusicLibrary(_ context: LibraryContext) async throws -> [UUID] {
        try guardLibrarySwitchAllowed()
        let lease = try LibraryRootAccessLease(
            context: context,
            resolver: SystemBookmarkResolver(),
            requiresSecurityScope: false
        )
        defer { lease.release() }
        return try await openMusicLibrary(at: context.rootURL)
    }

    func activateRegisteredLibrary(id: UUID) async throws -> [UUID] {
        try guardLibrarySwitchAllowed()
        guard let registryStore else { throw RegisteredLibraryActivationError.notRegistered }
        let context = try await LibraryStartupContextResolver(registryStore: registryStore)
            .resolveRegistered(libraryID: id, generation: activeLibraryBinding.generation &+ 1)
        try await sessionController.switchToLibrary(context)
        return try await unavailableReferencedSourceIDs()
    }

    func reconnectRegisteredLibrary(id: UUID, at url: URL) async throws -> [UUID] {
        try guardLibrarySwitchAllowed()
        guard let libraryOpenService else { throw LibraryOpenError.libraryNotFound }
        _ = try await libraryOpenService.reconnectRegisteredLibrary(id: id, selectedURL: url)
        return try await unavailableReferencedSourceIDs()
    }

    func prepareSourceReconnect(
        sourceID: UUID,
        candidateRoots: [URL]
    ) async throws -> SourceReconnectPreparation {
        guard let session = activeLibraryBinding.activeSession else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        return try await session.prepareSourceReconnect(
            sourceID: sourceID,
            candidateRoots: candidateRoots
        )
    }

    func reconnectSource(
        preparation: SourceReconnectPreparation,
        planID: String,
        conflictSelections: [UUID: URL]
    ) async throws {
        guard let session = activeLibraryBinding.activeSession,
              session.context.id == activeLibraryBinding.context?.id else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        try await session.reconnectSource(
            preparation: preparation,
            planID: planID,
            conflictSelections: conflictSelections
        )
    }

    func createMusicLibrary(
        mode: MusicLibraryMode,
        parentURL: URL,
        displayName: String,
        initialImportSelection: LibraryInitialImportSelection?,
        allowAlternateDestinationWhenOccupied: Bool = false
    ) async throws -> CreateMusicLibraryResult {
        let selectedMusicURLs = initialImportSelection?.urls ?? []
        guard let libraryCreationService else { throw LibraryCreationError.stagingFailed }
        // Creating a library activates it, so it is also a library switch.
        try guardLibrarySwitchAllowed()
        let result = try await libraryCreationService.create(
            mode: mode,
            parentURL: parentURL,
            displayName: displayName,
            initialImport: LibraryInitialImportPayload(selectedURLs: selectedMusicURLs),
            allowAlternateDestinationWhenOccupied: allowAlternateDestinationWhenOccupied
        )
        switch result {
        case .created(let context, _):
            var initialResult: LibraryInitialImportResult?
            if let initialImportSelection,
               !initialImportSelection.urls.isEmpty,
               let session = activeLibraryBinding.activeSession {
                initialResult = try await session.importInitialSelection(initialImportSelection)
            }
            return .created(context, initialImport: initialResult)
        case .existingLibrary(let context):
            return .existingLibrary(context)
        case .existingLibraryModeMismatch(let context, let requestedMode):
            return .existingLibraryModeMismatch(context, requestedMode: requestedMode)
        }
    }

    func importMusicSelection(_ selection: LibraryInitialImportSelection) async throws -> LibraryInitialImportResult {
        guard let session = activeLibraryBinding.activeSession else {
            let result = LibraryInitialImportResult(
                requested: selection.urls.count,
                planned: 0,
                imported: 0,
                failures: selection.urls.map {
                    ImportInputFailure(url: $0, message: "No active library")
                },
                sourceIDs: []
            )
            throw LibraryInitialImportError.initialImportFailed(result)
        }
        return try await session.importInitialSelection(selection)
    }

    func relocateMusicLibrary(id: UUID, to parentURL: URL) async throws {
        guard let libraryRelocationService else { throw LibraryRelocationError.libraryNotRegistered }
        _ = try await libraryRelocationService.relocate(libraryID: id, toParent: parentURL)
    }

    func removeMusicLibrary(id: UUID) async throws {
        guard let libraryRemovalService else { throw LibraryRemovalError.libraryNotRegistered }
        _ = try await libraryRemovalService.moveToTrash(libraryID: id)
    }

    func referencedSourceScanStates() async -> [UUID: ReferencedSourceScanState] {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced,
              let monitor = session.libraryChangeMonitor
        else { return [:] }
        var states = await monitor.sourceStateSnapshot()
        states.removeValue(forKey: session.context.id)
        return states
    }

    func referencedSources() async throws -> [ReferencedSourceDescriptor] {
        guard let store = activeLibraryBinding.activeSession?.referencedSourceStore else { return [] }
        return try await store.loadAll()
    }

    func removeReferencedSource(id: UUID) async throws {
        try await activeLibraryBinding.activeSession?.removeReferencedSource(id)
    }

    private func unavailableReferencedSourceIDs() async throws -> [UUID] {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced,
              let store = session.referencedSourceStore else {
            return []
        }
        return try await store.loadAll()
            .filter { $0.status != .available }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    func libraryScopedSettings() async throws -> LibraryScopedSettings {
        guard let context = activeLibraryBinding.context else { return LibraryScopedSettings() }
        return try await LibraryScopedSettingsStore(paths: context.paths).load()
    }

    func setReferencedTrackDeletePolicy(_ policy: ReferencedTrackDeletePolicy) async throws {
        guard let context = activeLibraryBinding.context, context.mode == .referenced else { return }
        try await LibraryScopedSettingsStore(paths: context.paths).setReferencedTrackDeletePolicy(policy)
    }

    func setupIfNeeded() async {
        guard !hasSetupDependencies else { return }
        hasSetupDependencies = true

        Log.debug("[Lifecycle] AppSessionHost initial setup", category: .ui)
        mainThreadStallMonitor.start()
        installProcessLifecycleHandlers()
        var lifecycleRecoverySucceeded = true
        var successorModeAfterRemoval: MusicLibraryMode?
        if let libraryRelocationService {
            do { _ = try await libraryRelocationService.replayPendingRepair() }
            catch {
                lifecycleRecoverySucceeded = false
                Log.error("[LibraryLifecycle] pending relocation repair failed", category: .library)
            }
        }
        if lifecycleRecoverySucceeded, let libraryRemovalService {
            do {
                let replay = try await libraryRemovalService.replayPendingRepair()
                if case .removed(let mode, didRemoveActive: true) = replay {
                    successorModeAfterRemoval = mode
                }
            } catch {
                lifecycleRecoverySucceeded = false
                Log.error("[LibraryLifecycle] pending removal repair failed", category: .library)
            }
        }
        let startupResolution: LibraryStartupResolution
        if lifecycleRecoverySucceeded, let registryStore {
            startupResolution = await LibraryStartupContextResolver(registryStore: registryStore)
                .resolve(allowSuccessorAfterRemoval: successorModeAfterRemoval)
        } else if lifecycleRecoverySucceeded, let initialLibraryContext {
            startupResolution = .context(initialLibraryContext)
        } else if lifecycleRecoverySucceeded {
            startupResolution = .noActive
        } else {
            startupResolution = .unavailable
        }
        switch startupResolution {
        case .context(let startupContext):
            do {
                try await sessionController.switchToLibrary(startupContext)
                await restorePlaybackMemoryIfNeeded()
            } catch {
                Log.error(
                    "[LibrarySession] initial load failed library=\(startupContext.id): \(error)",
                    category: .library
                )
                await releaseActiveSessionBindings()
            }
        case .noActive:
            if let defaultContext = await ensureFactoryDefaultLibraryIfNeeded() {
                // The default-library path is either opened or created by the
                // lifecycle service. Both paths activate the session before
                // returning, so the normal empty-library UI can render.
                await restorePlaybackMemoryIfNeeded()
                _ = defaultContext
            } else {
                Log.info("[LibrarySession] no active library; waiting for chooser", category: .library)
            }
        case .unavailable:
            if let defaultContext = await ensureFactoryDefaultLibraryIfNeeded(
                allowUnreachableActiveLibrary: true
            ) {
                await restorePlaybackMemoryIfNeeded()
                _ = defaultContext
            } else {
                Log.info("[LibrarySession] active library unavailable; waiting for reconnect", category: .library)
            }
        }

        LegacyCacheCleanupCoordinator.shared.captureBuild7UpgradeEligibilityBeforeLaunchRecord()
        AppVersionGate.shared.recordCurrentAppLaunch()
        let crashReportInstallID = await TelemetryService.shared.prepareAnonymousInstallIDForSignedUpload()
        await CrashReportService.shared.start(
            anonymousInstallID: crashReportInstallID
        )
        MetricKitDiagnosticService.shared.start(anonymousInstallID: crashReportInstallID)
#if DEBUG
        DebugCrashTrigger.scheduleIfRequested()
#endif
        if CrashReportService.shared.hasPendingPrompt {
            CrashReportService.shared.setPromptQueueDrainedHandler { [weak self] in
                self?.scheduleDeferredLaunchPromptsIfNeeded()
            }
        } else {
            scheduleDeferredLaunchPromptsIfNeeded()
        }
        hasCompletedInitialSetup = true
        // Covers the path where deferred prompts ran before
        // `hasCompletedInitialSetup` flipped (no crash-report prompt
        // queued); when prompts are crash-gated the drained handler calls
        // this again after What's New appears.
        autoPresentLibrarySetupIfNeeded()
    }

    /// Restores the pre-multi-library startup invariant: when there is no
    /// active, reachable library, the default managed library is opened or
    /// created at `~/Music/kmgccc_player Library` before the main window is
    /// shown. This keeps the normal empty-library shell available while the
    /// setup wizard floats above it.
    private func ensureFactoryDefaultLibraryIfNeeded(
        allowUnreachableActiveLibrary: Bool = false
    ) async -> LibraryContext? {
        guard let registryStore,
              let libraryOpenService,
              let libraryCreationService else { return nil }
        let registry = await registryStore.snapshot()

        // A nil active pointer can also be left behind by an interrupted
        // removal or by an older registry reset. Do not create a second
        // default library when another registered library is still usable.
        guard allowUnreachableActiveLibrary || registry.activeLibraryID == nil else { return nil }
        if !registry.libraries.isEmpty {
            let resolver = LibraryStartupContextResolver(registryStore: registryStore)
            for descriptor in registry.libraries {
                if (try? await resolver.resolveRegistered(libraryID: descriptor.id)) != nil {
                    return nil
                }
            }
        }

        let defaultRoot = LibraryLocationStore.defaultLibraryRootURL
        if FileManager.default.fileExists(atPath: defaultRoot.path) {
            do {
                // This also repairs a stale registry row that still claims
                // the default path for a different library identifier. The
                // physical library is never removed by this recovery path.
                return try await libraryOpenService.open(
                    selectedURL: defaultRoot,
                    allowStalePathConflictRepair: true
                ).context
            } catch {
                Log.debug(
                    "[LibrarySession] default library is not openable; trying creation: \(error)",
                    category: .library
                )
            }
        }

        let parentURL = defaultRoot.deletingLastPathComponent()
        do {
            let result = try await libraryCreationService.create(
                mode: .managed,
                parentURL: parentURL,
                displayName: "音乐资料库",
                allowStalePathConflictRepair: true
            )
            switch result {
            case .created(let context, _):
                shouldPresentFirstRunLibrarySetup = true
                return context
            case .existingLibrary(let context):
                // `create` deliberately leaves an already existing library
                // unactivated for the setup flow. Startup must explicitly
                // activate it before returning a context to the window.
                return try await libraryOpenService.open(
                    selectedURL: context.rootURL,
                    allowStalePathConflictRepair: true
                ).context
            case .existingLibraryModeMismatch:
                return nil
            }
        } catch {
            Log.error(
                "[LibrarySession] factory-default library ensure failed: \(error)",
                category: .library
            )
            return nil
        }
    }

    /// First-launch onboarding: after a fresh install the factory-default
    /// library is already open, so present the setup wizard once the
    /// What's New window has been dismissed. The panel floats above the
    /// main window and never blocks its loading or rendering.
    func autoPresentLibrarySetupIfNeeded() {
        guard hasCompletedInitialSetup, !didAutoPresentLibrarySetup else { return }
        didAutoPresentLibrarySetup = true
        guard shouldPresentFirstRunLibrarySetup,
              librarySetupFlow.presentation == .none else { return }
        let whatsNew = WhatsNewWindowManager.shared
        if whatsNew.isPresented {
            whatsNewDismissalCancellable = whatsNew.$isPresented
                .filter { !$0 }
                .first()
                .sink { [weak self] _ in
                    self?.presentFirstRunLibrarySetupPanel()
                }
        } else {
            presentFirstRunLibrarySetupPanel()
        }
    }

    private func presentFirstRunLibrarySetupPanel() {
        Task { @MainActor in
            // Let the main window finish its first render before floating
            // the panel above it.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard librarySetupFlow.presentation == .none else { return }
            librarySetupFlow.present(.setup(.managed))
            LibrarySetupPanelPresenter.present(appSession: self)
        }
    }

    private func scheduleDeferredLaunchPromptsIfNeeded() {
        guard !didScheduleDeferredLaunchPrompts else { return }
        didScheduleDeferredLaunchPrompts = true
        LegacyCacheCleanupCoordinator.shared.schedulePromptIfNeeded {
            LegacyCacheCleanupDialogPresenter.present()
        }
        WhatsNewWindowManager.shared.showIfNeeded()
        Log.debug("[Lifecycle] WhatsNew window check completed", category: .ui)

        if UpdateCheckPreferences.checkForUpdatesOnLaunch {
            Task {
                await UpdateWindowManager.shared.checkAndShowIfNeeded()
            }
        } else {
            Log.debug("[UpdateWindowManager] Skipping launch update check by user preference", category: .ui)
        }

        // Deferred prompts are settled (What's New is already visible when
        // applicable); the first-run wizard can queue behind them now.
        autoPresentLibrarySetupIfNeeded()
    }

    func switchLibrary(to context: LibraryContext) async throws {
        savePlaybackMemory()
        try await sessionController.switchToLibrary(context)
        didAttemptPlaybackMemoryRestore = false
        await restorePlaybackMemoryIfNeeded()
    }

    private func publishActiveSession(_ session: LibrarySession) {
        activeLibraryBinding.publish(session)
        CrashReportService.shared.bindLibraryRoot(session.context.rootURL)
        if session.didCompleteLegacyUpgrade {
            uiState.showSidebarNotice("资料库已更新")
        }

        let libraryVM = session.libraryViewModel
        let playerVM = session.playerViewModel
        let playbackCoordinator = session.playbackCoordinator
        let lyricsVM = session.lyricsViewModel
        let ledMeterProvider = session.ledMeterProvider
        let importEnrichmentService = session.importEnrichmentService
        libraryVM.onTrackDeletionPreparationFailures = { [weak self] failures in
            guard let self, !failures.isEmpty else { return }
            let message = failures.count == 1
                ? "原文件未移到废纸篓，歌曲已保留"
                : "\(failures.count) 首歌曲未删除"
            self.uiState.showSidebarNotice(
                message,
                style: .warning,
                actionTitle: "打开设置"
            )
        }

        self.libraryVM = libraryVM
        self.playerVM = playerVM
        self.playbackCoordinator = playbackCoordinator
        self.lyricsVM = lyricsVM
        self.ledMeterProvider = ledMeterProvider
        self.importEnrichmentService = importEnrichmentService

        PreferenceStatsLifecycleHandler.shared.configure(
            statsService: session.preferenceStatsService
        ) { [weak libraryVM] trackID in
            libraryVM?.allTracks.first { $0.id == trackID }
        }

        let lyricsPlaybackPipeline = LyricsPlaybackPipeline(
            lyricsVM: lyricsVM,
            playbackCoordinator: playbackCoordinator
        )
        self.lyricsPlaybackPipeline = lyricsPlaybackPipeline
        LyricsSurfaceManager.shared.setMainSurfaceSnapshotRefreshHandler {
            [weak lyricsPlaybackPipeline] reason in
            lyricsPlaybackPipeline?.refreshCurrent(
                reason: "surface snapshot refresh: \(reason)",
                forceLyricsReload: true
            )
        }
        lyricsPlaybackPipeline.start()

        playbackCoordinator.onActiveSourceChanged = { [weak ledMeterProvider, weak lyricsVM] source in
            ledMeterProvider?.playbackSource = source
            AudioVisualizationService.shared.setExternalMode(source.isExternal)
            lyricsVM?.refreshConfigFromSettings()
        }
        TelemetryService.shared.configure(playbackCoordinator: playbackCoordinator)
        CrashBreadcrumbRecorder.shared.updateAppContext { context in
            context.playbackSourceCategory = TelemetryPlaybackMode(
                source: playbackCoordinator.activeSource
            ).rawValue
            context.isPlaying = playerVM.isPlaying
            context.lastOperationCategory = "library_session_active"
        }
        CrashBreadcrumbRecorder.shared.record(.dependenciesReady)
        ledMeterProvider.playbackSource = playbackCoordinator.activeSource
        AudioVisualizationService.shared.setExternalMode(playbackCoordinator.activeSource.isExternal)

        mainThreadStallMonitor.playbackStateProvider = { [weak playerVM] in
            let isPlaying = playerVM?.isPlaying ?? false
            let trackPrefix = FirstUseHitchDiagnostics.trackIDPrefix(playerVM?.currentTrack?.id)
            let surface = LyricsSurfaceManager.shared.activeSurfaceDescription
            return (isPlaying, trackPrefix, surface)
        }

        guard let skinManager else { return }
        FullscreenWindowManager.shared.configure(
            libraryVM: libraryVM,
            playerVM: playerVM,
            playbackCoordinator: playbackCoordinator,
            lyricsVM: lyricsVM,
            ledMeterProvider: ledMeterProvider,
            cacheServices: session.cacheServices,
            skinManager: skinManager,
            uiState: uiState
        )
        AppDelegate.shared?.configureDockPlayback(playbackCoordinator: playbackCoordinator)
        AppKitMainSplitWindowController.rebuildAfterLibrarySwitchIfNeeded(appSession: self)
        startPlaybackMemoryAutosave()
        scheduleFirstUsePrewarm(
            libraryVM: libraryVM,
            playerVM: playerVM,
            playbackCoordinator: playbackCoordinator
        )

        if let scenario = DebugLaunchScenario.current {
            Task { @MainActor in
                await runDebugLaunchScenarioIfNeeded(
                    scenario,
                    repository: session.repository,
                    libraryVM: libraryVM,
                    playerVM: playerVM
                )
            }
        }
    }

    private func releaseActiveSessionBindings() async {
        activeLibraryRescanTask?.cancel()
        activeLibraryRescanTask = nil
        playbackMemoryTimer?.invalidate()
        playbackMemoryTimer = nil
        firstUsePrewarmTask?.cancel()
        firstUsePrewarmTask = nil
        lyricsPlaybackPipeline = nil
        LyricsSurfaceManager.shared.setMainSurfaceSnapshotRefreshHandler(nil)
        PreferenceStatsLifecycleHandler.shared.releaseLibrarySession()
        await FullscreenWindowManager.shared.releaseLibrarySession()
        AppKitMainSplitWindowController.releaseActiveLibraryReferences()
        activeLibraryBinding.releaseActiveSession()
        CrashReportService.shared.bindLibraryRoot(nil)

        libraryVM = nil
        playerVM = nil
        playbackCoordinator = nil
        lyricsVM = nil
        ledMeterProvider = nil
        importEnrichmentService = nil
        mainThreadStallMonitor.playbackStateProvider = nil
    }

    private func installProcessLifecycleHandlers() {
        if playbackModeObserver == nil {
            playbackModeObserver = NotificationCenter.default.addObserver(
                forName: .playbackModeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.playerVM?.syncPlaybackOrderModeFromSettings()
                }
            }
        }

        if workspaceLibraryObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            workspaceLibraryObservers = [
                NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification,
            ].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleActiveLibraryRescan()
                    }
                }
            }
        }

        if appActiveLibraryObserver == nil {
            appActiveLibraryObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleActiveLibraryRescan()
                }
            }
        }

        AppDelegate.applicationWillTerminateHandler = { [weak self] in
            guard let self else { return }
            TelemetryService.shared.endSession(reason: .appTerminated)
            self.savePlaybackMemory()
            if let session = self.activeLibraryBinding.activeSession {
                session.preferenceStatsService.saveAllPendingNow(
                    trackProvider: { trackID in
                        session.libraryViewModel.allTracks.first { $0.id == trackID }
                    },
                    synchronously: true
                )
            }
            Task {
                if let monitor = self.activeLibraryBinding.activeSession?.libraryChangeMonitor {
                    await monitor.stopAndWait()
                }
                await QQMusicHelperProcess.shared.terminate()
            }
        }
    }

    private func scheduleActiveLibraryRescan() {
        activeLibraryRescanTask?.cancel()
        activeLibraryRescanTask = Task { @MainActor [weak self] in
            guard let self, let session = activeLibraryBinding.activeSession else { return }
            let libraryID = session.context.id
            if session.context.mode == .referenced {
                do {
                    _ = try await session.refreshReferencedSources()
                } catch {
                    Log.warning(
                        "[LibrarySession] lifecycle source refresh failed library=\(libraryID)",
                        category: .library
                    )
                }
            } else if let monitor = session.libraryChangeMonitor {
                await monitor.markDirty(sourceIDs: [libraryID], fullScan: true)
            }
        }
    }


    deinit {
        MainActor.assumeIsolated {
            if let playbackModeObserver {
                NotificationCenter.default.removeObserver(playbackModeObserver)
            }
            if let appActiveLibraryObserver {
                NotificationCenter.default.removeObserver(appActiveLibraryObserver)
            }
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            for observer in workspaceLibraryObservers {
                workspaceCenter.removeObserver(observer)
            }
            playbackMemoryTimer?.invalidate()
            firstUsePrewarmTask?.cancel()
            activeLibraryRescanTask?.cancel()
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

            // Front-load the macOS text-input cold start (field editor + TSM/IMK
            // session + AppleSpell XPC). The first time any text control becomes
            // first responder these system services spin up and block the main
            // thread for hundreds of ms — which freezes the UI (scrubber, spectrum,
            // lyrics) when the song-Info editor is first opened during playback and
            // is misperceived as an audio hitch. AVAudioEngine rendering is immune
            // to main-thread stalls, so paying this cost off the interaction path at
            // launch idle is safe and leaves the open-to-edit experience untouched.
            // Distinct from the SwiftUI-host prewarm tried earlier: that warmed the
            // view, not the system text services that actually cost the first frame.
            TextInputSystemPrewarmer.prewarmOnce()
            guard !Task.isCancelled else { return }

            await self.prewarmLyricsSurfaceWhenPlaybackQuiet(
                role: .main,
                playerVM: playerVM,
                playbackCoordinator: playbackCoordinator
            )

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

            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled else { return }

            await self.prewarmLyricsSurfaceWhenPlaybackQuiet(
                role: .fullscreen,
                playerVM: playerVM,
                playbackCoordinator: playbackCoordinator
            )
        }
    }

    private func prewarmLyricsSurfaceWhenPlaybackQuiet(
        role: LyricsSurfaceRole,
        playerVM: PlayerViewModel?,
        playbackCoordinator: PlaybackCoordinator?
    ) async {
        while !Task.isCancelled {
            let isPlaying = (playerVM?.isPlaying ?? false)
                || (playbackCoordinator?.presentation.isPlaying ?? false)
            guard !isPlaying else {
                Log.info(
                    "[FirstUsePrewarm] deferring \(role.rawValue) lyrics prewarm while playback is active",
                    category: .perf
                )
                try? await Task.sleep(for: .milliseconds(1_500))
                continue
            }

            LyricsSurfaceManager.shared.prewarm(role: role, reason: "app-start-idle")
            return
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
        guard let libraryID = activeLibraryBinding.activeSession?.context.id else { return }
        guard playbackCoordinator?.activeSource == .local else {
            PlaybackMemoryStore.clear(libraryID: libraryID)
            return
        }
        guard let playerVM, let currentTrack = playerVM.currentTrack else {
            PlaybackMemoryStore.clear(libraryID: libraryID)
            return
        }

        let currentTime = playerVM.currentTime.isFinite ? max(0, playerVM.currentTime) : 0
        let duration = playerVM.duration.isFinite ? max(0, playerVM.duration) : 0
        let playbackOrderMode = AppSettings.shared.playbackOrderMode
        let queueTrackIDs = playbackOrderMode == .shuffle
            ? []
            : playerVM.currentQueueTracks.map { $0.id }

        PlaybackMemoryStore.save(
            PlaybackMemory(
                savedAt: Date(),
                trackID: currentTrack.id,
                currentTime: currentTime,
                duration: duration,
                queueTrackIDs: queueTrackIDs.isEmpty ? nil : queueTrackIDs,
                playbackOrderMode: playbackOrderMode.rawValue
            ),
            libraryID: libraryID
        )
    }

    /// Restore the last session at launch **in a paused state**.
    ///
    /// This rebuilds the queue, current track, position, and
    /// UI without auto-playing. The audio is prepared and scheduled at the saved
    /// position but the player node is never started — the final state is paused,
    /// and the user resumes from the restored position with one tap.
    ///
    /// The launch auto-play chain (`playTracks -> seek -> pause`) intentionally
    /// stays disabled; this path never calls `playerNode.play()`. The saved
    /// memory is **not** cleared on restore so repeated relaunches keep working
    /// (the autosave timer keeps it current). It is only cleared when the saved
    /// track is genuinely no longer present in the library.
    private func restorePlaybackMemoryIfNeeded() async {
        guard !didAttemptPlaybackMemoryRestore else { return }
        didAttemptPlaybackMemoryRestore = true

        guard DebugLaunchScenario.current == nil else { return }
        guard let session = activeLibraryBinding.activeSession else { return }
        guard let memory = PlaybackMemoryStore.loadValid(libraryID: session.context.id) else { return }
        let repository = session.repository
        guard let playerVM else { return }

        // No `repository.reloadFromLibrary()` here: every call site invokes
        // this right after the session controller finished `load()`, which
        // already performed the full disk scan and rebuild. Reloading again
        // doubled startup/switch cost for large libraries.

        let availableTracks = await repository.fetchTracks(in: nil)
            .filter { $0.availability != .missing }
        guard !availableTracks.isEmpty else { return }

        // Rebuild the exact saved queue when present; fall back to the full
        // library (matching legacy behavior) for v1 payloads without a queue.
        let tracksByID = Dictionary(availableTracks.map { ($0.id, $0) }) { first, _ in first }
        let savedPlaybackOrderMode = memory.playbackOrderMode.flatMap(PlaybackOrderMode.init(rawValue:))
        let shouldUseFullLibraryQueue = savedPlaybackOrderMode == .shuffle
            || AppSettings.shared.playbackOrderMode == .shuffle

        let restoredQueue: [Track]
        if shouldUseFullLibraryQueue {
            restoredQueue = availableTracks
        } else if let savedQueueIDs = memory.queueTrackIDs, !savedQueueIDs.isEmpty {
            let rebuilt = savedQueueIDs.compactMap { tracksByID[$0] }
            restoredQueue = rebuilt.isEmpty ? availableTracks : rebuilt
        } else {
            restoredQueue = availableTracks
        }

        guard let startIndex = restoredQueue.firstIndex(where: { $0.id == memory.trackID }) else {
            // The saved track is gone (deleted/unavailable): drop stale memory.
            PlaybackMemoryStore.clear(libraryID: session.context.id)
            return
        }

        let restorableTime = PlaybackMemoryStore.restorableTime(from: memory)
        let restoredTrack = restoredQueue[startIndex]
        Log.info(
            "[PlaybackMemory] restoring paused session track=\(restoredTrack.id.uuidString) title=\(restoredTrack.title) index=\(startIndex)/\(restoredQueue.count) savedTime=\(String(format: "%.1f", restorableTime)) mode=\(AppSettings.shared.playbackOrderMode.rawValue)",
            category: .playback
        )

        // Paused restore: builds queue + current track + position + UI and
        // prepares/schedules audio without playing. Ends paused (hard constraint).
        playerVM.restorePausedPlayback(
            restoredQueue,
            startingAt: startIndex,
            positionSeconds: restorableTime
        )
        playbackCoordinator?.refreshPresentation()
        lyricsPlaybackPipeline?.refreshCurrent(
            reason: "playback memory restored",
            forceLyricsReload: true
        )
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
            case .allPlaylists:
                selectionLabel = "allPlaylists"
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

    /// Closure that returns the current playback state for stall diagnostics.
    /// Set by AppSessionHost after dependencies are ready.
    var playbackStateProvider: (() -> (isPlaying: Bool, trackIDPrefix: String, activeSurface: String))?

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

        if LogConfig.mainThreadStallLoggingEnabled {
            Log.info("[MainThreadStall] monitor started thresholdMs=50", category: .perf)
        }
    }

    private func tick() {
        let now = DispatchTime.now()
        let delayNs = now.uptimeNanoseconds > expectedFireTime.uptimeNanoseconds
            ? now.uptimeNanoseconds - expectedFireTime.uptimeNanoseconds
            : 0
        let delayMs = Double(delayNs) / 1_000_000.0

        if LogConfig.mainThreadStallLoggingEnabled, delayMs >= warningThresholdMs {
            let severity = delayMs >= criticalThresholdMs ? "critical" : "warning"
            let stack = FirstUseHitchDiagnostics.currentOperationStack()
            let recent = FirstUseHitchDiagnostics.recentEvents()

            let state = playbackStateProvider?()
            let isPlaying = state?.isPlaying ?? false
            let trackPrefix = state?.trackIDPrefix ?? "n/a"
            let surface = state?.activeSurface ?? "n/a"
            let contextMenu = ContextMenuDiagnostics.currentStateDescription()

            Log.warning(
                "[MainThreadStall] delayMs=\(String(format: "%.1f", delayMs)) severity=\(severity) thread=main operationStack=[\(stack)] recentEvents=[\(recent)] isPlaying=\(isPlaying) trackID=\(trackPrefix) surface=\(surface) contextMenu=[\(contextMenu)]",
                category: .perf
            )
        }

        expectedFireTime = DispatchTime(uptimeNanoseconds: now.uptimeNanoseconds + intervalNanoseconds)
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

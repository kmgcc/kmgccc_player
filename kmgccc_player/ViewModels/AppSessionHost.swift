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
import Dispatch
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
    /// True once the first `setupIfNeeded()` pass finished. Lets the window
    /// distinguish "still loading the initial library" from "no library
    /// configured" instead of showing an indefinite spinner.
    @Published private(set) var hasCompletedInitialSetup = false
    /// True while a user-initiated retry is trying to establish the startup
    /// library after an exceptional open failure.
    @Published private(set) var isRetryingLibraryStartup = false
    /// Pushed referenced-source scan states for the active library (the
    /// library root itself is excluded). Fed by `LibraryChangeMonitor`
    /// transitions and the manual rescan wrappers below so views can read a
    /// published snapshot instead of running their own poll loops.
    @Published private(set) var referencedSourceScanStatesSnapshot: [UUID: ReferencedSourceScanState] = [:]
    /// Manual rescans run while the monitor is stopped, so their transient
    /// states are overlaid here until the operation settles.
    private var manualScanStateOverrides: [UUID: ReferencedSourceScanState] = [:]
    /// Live library-task descriptors pushed from the active session's
    /// operation coordinator (plan §14). Views read this published snapshot
    /// instead of polling task state.
    @Published private(set) var activeLibraryTasks: [LibraryOperationTaskDescriptor] = []
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
    private lazy var automationIPCServer: AutomationIPCServer? = {
        do {
            return try AutomationIPCServer(appSession: self)
        } catch {
            Log.error(
                "[Automation] failed to create IPC server: \(error.localizedDescription)",
                category: .library
            )
            return nil
        }
    }()
    /// Coalesces launch/reopen/menu callers while the first library session is
    /// being opened. The old boolean guard was set before the async work and
    /// let a second caller show the window with a nil session in between.
    private var setupTask: Task<Void, Never>?
    private var playbackModeObserver: NSObjectProtocol?
    private var workspaceLibraryObservers: [NSObjectProtocol] = []
    private var appActiveLibraryObserver: NSObjectProtocol?
    private var activeLibraryRescanTask: Task<Void, Never>?
    private var playbackMemoryTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let mainThreadStallMonitor = MainThreadStallMonitor()
    private var firstUsePrewarmTask: Task<Void, Never>?
    private var lyricsPlaybackPipeline: LyricsPlaybackPipeline?
    private var didAttemptPlaybackMemoryRestore = false
    private var didScheduleDeferredLaunchPrompts = false
    private var didPrepareTerminationSynchronously = false
    private var didFinishTerminationPreparation = false
    private var terminationPreparationStarted = false
    private var terminationPreparationGeneration = 0
    private var terminationCompletions: [@MainActor @Sendable () -> Void] = []

    init(
        modelContainer: ModelContainer,
        initialLibraryContext: LibraryContext?,
        registryStore: MusicLibraryRegistryStore? = nil,
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
        self.registryStore = registryStore ?? MusicLibraryRegistryStore.makeApplicationStore()
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
            await self.publishActiveSession(session)
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
        case .fileFailures(_, let failures):
            uiState.recordLibraryImportFailures(
                failures.map { failure in
                    ImportInputFailure(
                        url: URL(fileURLWithPath: failure.relativePath ?? "来源文件"),
                        message: failure.summary
                    )
                },
                origin: .sourceMonitor
            )
            uiState.showSidebarNotice(
                "来源文件夹中有 \(failures.count) 个文件未能导入",
                style: .warning,
                actionTitle: "查看失败"
            )
        case .scanFailures(_, let failures):
            uiState.recordLibraryImportFailures(
                failures.map { failure in
                    ImportInputFailure(
                        url: URL(fileURLWithPath: failure.relativePath ?? "来源文件"),
                        message: failure.summary
                    )
                },
                origin: .sourceMonitor
            )
            uiState.showSidebarNotice(
                "来源扫描失败 \(failures.count) 项",
                style: .warning,
                actionTitle: "查看失败"
            )
        case .reconcileFailures(_, let failures):
            uiState.recordLibraryImportFailures(
                failures.map { failure in
                    ImportInputFailure(
                        url: URL(fileURLWithPath: failure.relativePath ?? "来源歌曲"),
                        message: failure.summary
                    )
                },
                origin: .sourceMonitor
            )
            uiState.showSidebarNotice(
                "有 \(failures.count) 首歌曲未能更新",
                style: .warning,
                actionTitle: "查看失败"
            )
        case .monitorFailure(_, let summary):
            uiState.recordLibraryImportFailures(
                [ImportInputFailure(url: URL(fileURLWithPath: "来源扫描"), message: summary)],
                origin: .sourceMonitor
            )
            uiState.showSidebarNotice(
                "来源文件夹扫描失败，请检查来源设置",
                style: .warning,
                actionTitle: "查看失败"
            )
        }
    }

    var sharedModelContainer: ModelContainer {
        activeLibraryBinding.modelContainer
    }

    func musicLibraryRegistrySnapshot() async -> MusicLibraryRegistry {
        await registryStore?.snapshot() ?? MusicLibraryRegistry()
    }

    func openMusicLibrary(at url: URL) async throws -> [UUID] {
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
        let lease = try LibraryRootAccessLease(
            context: context,
            resolver: SystemBookmarkResolver(),
            requiresSecurityScope: false
        )
        defer { lease.release() }
        return try await openMusicLibrary(at: context.rootURL)
    }

    func activateRegisteredLibrary(id: UUID) async throws -> [UUID] {
        guard let registryStore else { throw RegisteredLibraryActivationError.notRegistered }
        let context = try await LibraryStartupContextResolver(registryStore: registryStore)
            .resolveRegistered(libraryID: id, generation: activeLibraryBinding.generation &+ 1)
        try await sessionController.switchToLibrary(context)
        return try await unavailableReferencedSourceIDs()
    }

    func reconnectRegisteredLibrary(id: UUID, at url: URL) async throws -> [UUID] {
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
        return try await session.runLibraryOperation {
            try await session.prepareSourceReconnect(
                sourceID: sourceID,
                candidateRoots: candidateRoots
            )
        }
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
        try await session.runLibraryOperation {
            try await session.reconnectSource(
                preparation: preparation,
                planID: planID,
                conflictSelections: conflictSelections
            )
        }
    }

    func createMusicLibrary(
        mode: MusicLibraryMode,
        parentURL: URL,
        displayName: String,
        initialImportSelection: LibraryInitialImportSelection?,
        initialImportPolicy: LibraryInitialImportPolicy = .waitForCompletion,
        allowAlternateDestinationWhenOccupied: Bool = false
    ) async throws -> CreateMusicLibraryResult {
        let selectedMusicURLs = initialImportSelection?.urls ?? []
        guard let libraryCreationService else { throw LibraryCreationError.stagingFailed }
        // Creating a library activates it, so it is also a library switch. The
        // session controller quiesces the previous session before activation.
        let backgroundSelection: LibraryInitialImportSelection?
        if initialImportPolicy == .background,
           let initialImportSelection,
           !selectedMusicURLs.isEmpty {
            backgroundSelection = initialImportSelection.retainedCopy()
        } else {
            backgroundSelection = nil
        }

        let result: LibraryCreationResult
        do {
            result = try await libraryCreationService.create(
                mode: mode,
                parentURL: parentURL,
                displayName: displayName,
                initialImport: LibraryInitialImportPayload(selectedURLs: selectedMusicURLs),
                allowAlternateDestinationWhenOccupied: allowAlternateDestinationWhenOccupied
            )
        } catch {
            backgroundSelection?.release()
            throw error
        }
        switch result {
        case .created(let context, _):
            if initialImportPolicy == .background {
                scheduleBackgroundInitialImport(
                    context: context,
                    selection: backgroundSelection
                )
                return .created(context, initialImport: nil)
            }
            var initialResult: LibraryInitialImportResult?
            if let initialImportSelection,
               !initialImportSelection.urls.isEmpty,
               let session = activeLibraryBinding.activeSession {
                initialResult = try await session.runLibraryOperation {
                    try await session.importInitialSelection(initialImportSelection)
                }
            }
            return .created(context, initialImport: initialResult)
        case .existingLibrary(let context):
            backgroundSelection?.release()
            return .existingLibrary(context)
        case .existingLibraryModeMismatch(let context, let requestedMode):
            backgroundSelection?.release()
            return .existingLibraryModeMismatch(context, requestedMode: requestedMode)
        }
    }

    private func scheduleBackgroundInitialImport(
        context: LibraryContext,
        selection: LibraryInitialImportSelection?
    ) {
        guard let selection, !selection.urls.isEmpty,
              let session = activeLibraryBinding.activeSession,
              session.context.id == context.id else {
            selection?.release()
            return
        }

        let started = session.startBackgroundLibraryOperation { [weak self, session, selection] in
            defer { selection.release() }
            guard !Task.isCancelled else { return }
            do {
                let result = try await session.importInitialSelection(selection)
                guard !Task.isCancelled, let self else { return }
                if result.isPartial {
                    self.uiState.showSidebarNotice(
                        "部分音乐未导入",
                        style: .warning,
                        actionTitle: "查看失败"
                    )
                } else if result.imported > 0 {
                    self.uiState.showSidebarNotice("新增 \(result.imported) 首歌曲")
                }
            } catch LibraryInitialImportError.initialImportFailed(let result) {
                guard !Task.isCancelled else { return }
                self?.uiState.showSidebarNotice(
                    result.imported > 0 ? "部分音乐未导入" : "初始音乐导入失败",
                    style: .warning,
                    actionTitle: "查看失败"
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.uiState.showSidebarNotice(
                    "初始音乐导入失败",
                    style: .warning,
                    actionTitle: "查看失败"
                )
            }
        }
        guard started else {
            selection.release()
            return
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
        return try await session.runLibraryOperation {
            try await session.importInitialSelection(selection)
        }
    }

    func relocateMusicLibrary(id: UUID, to parentURL: URL) async throws {
        guard let libraryRelocationService else { throw LibraryRelocationError.libraryNotRegistered }
        _ = try await libraryRelocationService.relocate(libraryID: id, toParent: parentURL)
    }

    func removeMusicLibrary(id: UUID) async throws {
        guard let libraryRemovalService else { throw LibraryRemovalError.libraryNotRegistered }
        do {
            let nextAction = try await libraryRemovalService.moveToTrash(libraryID: id)
            if case .chooseLibrary = nextAction {
                // The removal service has already released its transaction gate by
                // the time this returns. Re-run the normal successor/default
                // policy so deletion can never leave the app with an empty shell.
                _ = await ensureFactoryDefaultLibraryIfNeeded(allowUnreachableActiveLibrary: true)
            }
        } catch {
            // A registry commit can fail after the active session has already
            // been closed and the recycle intent has been written. The repair
            // journal will finish the registry cleanup on the next launch, but
            // the current process still needs a usable session now.
            if activeLibraryBinding.activeSession == nil {
                _ = await ensureFactoryDefaultLibraryIfNeeded(allowUnreachableActiveLibrary: true)
            }
            throw error
        }
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

    /// One-shot refresh of the published snapshot from the live monitor.
    func refreshReferencedSourceScanStatesSnapshot() async {
        applyReferencedScanStates(await referencedSourceScanStates())
    }

    private func bindReferencedScanStatePush(for session: LibrarySession) async {
        manualScanStateOverrides.removeAll()
        guard let monitor = session.libraryChangeMonitor else {
            referencedSourceScanStatesSnapshot = [:]
            return
        }
        await monitor.setScanStateChangeHandler { [weak self] states in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var filtered = states
                filtered.removeValue(forKey: session.context.id)
                self.applyManualScanOverrides(to: &filtered)
                if filtered != self.referencedSourceScanStatesSnapshot {
                    self.referencedSourceScanStatesSnapshot = filtered
                }
            }
        }
    }

    private func unbindReferencedScanStatePush(of session: LibrarySession?) async {
        await session?.libraryChangeMonitor?.setScanStateChangeHandler(nil)
        manualScanStateOverrides.removeAll()
        referencedSourceScanStatesSnapshot = [:]
    }

    private func bindLibraryTaskStatePush(for session: LibrarySession) {
        activeLibraryTasks = session.libraryTaskDescriptorsSnapshot()
        session.bindLibraryTaskStateObserver { [weak self, weak session] in
            guard let self, let session else { return }
            self.activeLibraryTasks = session.libraryTaskDescriptorsSnapshot()
        }
    }

    private func unbindLibraryTaskStatePush(of session: LibrarySession?) {
        session?.bindLibraryTaskStateObserver(nil)
        activeLibraryTasks = []
    }

    private func applyReferencedScanStates(_ states: [UUID: ReferencedSourceScanState]) {
        var merged = states
        applyManualScanOverrides(to: &merged)
        if merged != referencedSourceScanStatesSnapshot {
            referencedSourceScanStatesSnapshot = merged
        }
    }

    private func applyManualScanOverrides(to states: inout [UUID: ReferencedSourceScanState]) {
        let supersededFailureIDs = manualScanStateOverrides
            .filter { id, override in override == .failed && states[id] != nil }
            .map(\.key)
        for id in supersededFailureIDs {
            // A monitor transition arrived for a source whose failure flag came
            // from a manual rescan; the automatic state is now authoritative.
            manualScanStateOverrides.removeValue(forKey: id)
        }
        for (id, state) in manualScanStateOverrides {
            states[id] = state
        }
    }

    private func beginManualScanOverride(sourceIDs: [UUID]) {
        for id in sourceIDs { manualScanStateOverrides[id] = .scanning }
        Task { @MainActor [weak self] in
            await self?.refreshReferencedSourceScanStatesSnapshot()
        }
    }

    private func endManualScanOverride(sourceIDs: [UUID], markFailed: Bool) {
        for id in sourceIDs {
            manualScanStateOverrides.removeValue(forKey: id)
            if markFailed { manualScanStateOverrides[id] = .failed }
        }
        Task { @MainActor [weak self] in
            await self?.refreshReferencedSourceScanStatesSnapshot()
        }
    }

    func referencedSources() async throws -> [ReferencedSourceDescriptor] {
        guard let store = activeLibraryBinding.activeSession?.referencedSourceStore else { return [] }
        return try await store.loadAll()
    }

    func refreshReferencedSource(
        id: UUID,
        libraryID: UUID? = nil
    ) async throws -> [ReferencedSourceScopeIssue] {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced else { return [] }
        if let libraryID, session.context.id != libraryID {
            throw LibraryOperationError.sessionQuiescing
        }
        beginManualScanOverride(sourceIDs: [id])
        do {
            let issues = try await session.runLibraryOperation {
                try await session.refreshReferencedSource(id)
            }
            endManualScanOverride(sourceIDs: [id], markFailed: false)
            return issues
        } catch {
            endManualScanOverride(sourceIDs: [id], markFailed: true)
            throw error
        }
    }

    /// User-initiated full scan across every referenced source of the active
    /// library (spec 12.1 / 18.1). Scan progress is published through
    /// `referencedSourceScanStatesSnapshot`.
    func refreshAllReferencedSources(libraryID: UUID? = nil) async throws {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced,
              let store = session.referencedSourceStore else { return }
        if let libraryID, session.context.id != libraryID {
            throw LibraryOperationError.sessionQuiescing
        }
        let sourceIDs = try await store.loadAll().map(\.id)
        guard !sourceIDs.isEmpty else { return }
        beginManualScanOverride(sourceIDs: sourceIDs)
        do {
            _ = try await session.runLibraryOperation {
                try await session.refreshReferencedSources()
            }
            endManualScanOverride(sourceIDs: sourceIDs, markFailed: false)
        } catch {
            endManualScanOverride(sourceIDs: sourceIDs, markFailed: true)
            throw error
        }
    }

    func setReferencedSourceExcludedPath(
        id: UUID,
        relativePath: String,
        excluded: Bool,
        libraryID: UUID? = nil
    ) async throws {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        if let libraryID, session.context.id != libraryID {
            throw LibraryOperationError.sessionQuiescing
        }
        try await session.runLibraryOperation {
            try await session.setReferencedSourceExcludedPath(
                sourceID: id,
                relativePath: relativePath,
                excluded: excluded
            )
        }
    }

    func bindReferencedSource(
        id: UUID,
        to playlistID: UUID,
        libraryID: UUID? = nil
    ) async throws {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced,
              let reconciler = session.referencedSourceReconciler else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        if let libraryID, session.context.id != libraryID {
            throw LibraryOperationError.sessionQuiescing
        }
        try await session.runLibraryOperation {
            try await reconciler.bindSourcesToPlaylist([id], playlistID: playlistID)
        }
        await session.libraryViewModel.reloadLibrary()
    }

    @discardableResult
    func unbindReferencedSource(
        id: UUID,
        bindingID: UUID,
        libraryID: UUID? = nil
    ) async throws -> Int {
        guard let session = activeLibraryBinding.activeSession,
              session.context.mode == .referenced,
              let reconciler = session.referencedSourceReconciler else {
            throw LibrarySessionFactoryError.missingReferencedSourceServices
        }
        if let libraryID, session.context.id != libraryID {
            throw LibraryOperationError.sessionQuiescing
        }
        let removedCount = try await session.runLibraryOperation {
            try await reconciler.unbindSourceFromPlaylist(
                sourceID: id,
                bindingID: bindingID
            )
        }
        await session.libraryViewModel.reloadLibrary()
        return removedCount
    }

    func removeReferencedSource(id: UUID) async throws {
        guard let session = activeLibraryBinding.activeSession else { return }
        try await session.runLibraryOperation {
            try await session.removeReferencedSource(id)
        }
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

    func setReferencedTrackDeletePolicy(
        _ policy: ReferencedTrackDeletePolicy,
        libraryID: UUID
    ) async throws {
        guard let session = activeLibraryBinding.activeSession,
              session.context.id == libraryID,
              session.context.mode == .referenced else {
            throw LibraryOperationError.sessionQuiescing
        }
        let store = LibraryScopedSettingsStore(paths: session.context.paths)
        let _: Void = try await session.runLibraryOperation {
            try await store.setReferencedTrackDeletePolicy(policy)
        }
    }

    func setupIfNeeded() async {
        if let setupTask {
            await setupTask.value
            return
        }
        if hasSetupDependencies { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialSetup()
        }
        setupTask = task
        await task.value
        setupTask = nil
    }

    /// Performs the one-time launch work. Callers must enter through
    /// `setupIfNeeded()` so concurrent launch/reopen events share one task.
    private func performInitialSetup() async {
        guard !hasSetupDependencies else { return }
        hasSetupDependencies = true

        Log.debug("[Lifecycle] AppSessionHost initial setup", category: .ui)
        mainThreadStallMonitor.start()
        startMemoryPressureMonitoring()
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
                if LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(after: error) {
                    if let defaultContext = await ensureFactoryDefaultLibraryIfNeeded(
                        allowUnreachableActiveLibrary: true
                    ) {
                        await restorePlaybackMemoryIfNeeded()
                        _ = defaultContext
                    }
                } else {
                    Log.warning(
                        "[LibrarySession] active library writer lease unavailable; default creation suppressed",
                        category: .library
                    )
                }
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

        // A normal launch must never publish a completed setup with a nil
        // session. This bounded retry also covers a short-lived contention
        // window when a previous instance is still releasing its writer lease.
        if activeLibraryBinding.activeSession == nil {
            _ = await ensureFactoryDefaultLibraryWithRetries()
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
        do {
            try await automationIPCServer?.start()
        } catch {
            // Automation is an optional control plane. A stale socket or a
            // transient listener failure must not prevent normal playback and
            // library UI startup; the CLI receives a bounded unavailable
            // result until the next App launch.
            Log.error(
                "[Automation] failed to start IPC server: \(error.localizedDescription)",
                category: .library
            )
        }
        // Covers the path where deferred prompts ran before
        // `hasCompletedInitialSetup` flipped (no crash-report prompt
        // queued); when prompts are crash-gated the drained handler calls
        // this again after What's New appears.
        autoPresentLibrarySetupIfNeeded()
    }

    /// Re-attempts the factory-default recovery path without repeating all
    /// process-wide dependency installation. This is used by the exceptional
    /// recovery surface after startup has finished but no session could be
    /// published.
    func retryLibraryStartup() async {
        guard activeLibraryBinding.activeSession == nil,
              !isRetryingLibraryStartup else { return }
        isRetryingLibraryStartup = true
        defer { isRetryingLibraryStartup = false }
        if await ensureFactoryDefaultLibraryWithRetries() != nil {
            await restorePlaybackMemoryIfNeeded()
            autoPresentLibrarySetupIfNeeded()
        }
    }

    private func ensureFactoryDefaultLibraryWithRetries() async -> LibraryContext? {
        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let context = await ensureFactoryDefaultLibraryIfNeeded(
                allowUnreachableActiveLibrary: true
            ) {
                return context
            }
        }
        return nil
    }

    /// Restores the startup invariant: when there is no active, reachable
    /// library, the default empty library is opened or created at
    /// `~/Music/kmgccc_player Library` before the main window is shown. This
    /// keeps the normal empty-library shell available while the setup wizard
    /// floats above it.
    private func ensureFactoryDefaultLibraryIfNeeded(
        allowUnreachableActiveLibrary: Bool = false
    ) async -> LibraryContext? {
        guard let registryStore,
              let libraryOpenService,
              let libraryCreationService else { return nil }
        let registry = await registryStore.snapshot()

        // A nil active pointer can also be left behind by an interrupted
        // removal or by an older registry reset. Prefer activating any
        // reachable registered library before falling back to the default.
        guard allowUnreachableActiveLibrary || registry.activeLibraryID == nil else { return nil }
        let resolver = LibraryStartupContextResolver(registryStore: registryStore)
        var candidateIDs: [UUID] = []
        if let activeID = registry.activeLibraryID { candidateIDs.append(activeID) }
        candidateIDs.append(contentsOf: [registry.recentManagedLibraryID, registry.recentReferencedLibraryID].compactMap { $0 })
        candidateIDs.append(contentsOf: registry.libraries.map(\.id))
        var seen = Set<UUID>()
        for candidateID in candidateIDs where seen.insert(candidateID).inserted {
            guard let context = try? await resolver.resolveRegistered(libraryID: candidateID) else { continue }
            do {
                try await sessionController.switchToLibrary(context)
                try await registryStore.setActiveLibrary(id: context.id, manifestMode: context.mode)
                return context
            } catch {
                guard LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(after: error) else {
                    Log.warning(
                        "[LibrarySession] registered library writer lease unavailable; default creation suppressed",
                        category: .library
                    )
                    return nil
                }
                continue
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
                guard LibraryStartupFailurePolicy.permitsFactoryDefaultFallback(after: error) else {
                    Log.warning(
                        "[LibrarySession] default library writer lease unavailable; alternate creation suppressed",
                        category: .library
                    )
                    return nil
                }
                Log.debug(
                    "[LibrarySession] default library is not openable; trying creation: \(error)",
                    category: .library
                )
            }
        }

        let parentURL = defaultRoot.deletingLastPathComponent()
        do {
            let result = try await libraryCreationService.create(
                mode: .referenced,
                parentURL: parentURL,
                displayName: "音乐资料库",
                allowAlternateDestinationWhenOccupied: true,
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
            librarySetupFlow.present(.setup(.referenced))
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

        UpdateCoordinator.shared.startAutomaticUpdatesIfNeeded()
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

    private func publishActiveSession(_ session: LibrarySession) async {
        uiState.clearLibraryImportFailureReports()
        activeLibraryBinding.publish(session)
        await bindReferencedScanStatePush(for: session)
        bindLibraryTaskStatePush(for: session)
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
        session.fileImportService.onImportFailures = { [weak uiState] failures, origin in
            uiState?.recordLibraryImportFailures(failures, origin: origin)
        }
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
        libraryVM.onImportRejectedNotice = { [weak self] message in
            guard let self else { return }
            self.uiState.showSidebarNotice(message, style: .warning)
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
        UpdateCoordinator.shared.terminationPreparationHandler = { [weak self] completion in
            guard let self else {
                completion()
                return
            }
            self.prepareForTermination(reason: "update-relaunch", completion: completion)
        }
        UpdateCoordinator.shared.installationDidAbortHandler = { [weak self] in
            self?.resetTerminationPreparationAfterAbortedUpdate()
        }
        AppDelegate.shouldCancelTerminationForPendingUpdateHandler = {
            UpdateCoordinator.shared.isInstallReplyPending
        }
        AppDelegate.applicationShouldTerminateHandler = { [weak self] completion in
            guard let self else {
                completion()
                return
            }
            self.prepareForTermination(reason: "normal-quit", completion: completion)
        }
        AppDelegate.applicationWillTerminateHandler = { [weak self] in
            UpdateCoordinator.shared.handleApplicationWillTerminate()
            self?.prepareForTermination(reason: "app-termination")
        }
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
        unbindLibraryTaskStatePush(of: activeLibraryBinding.activeSession)
        await unbindReferencedScanStatePush(of: activeLibraryBinding.releaseActiveSession())
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
                await self.automationIPCServer?.stop()
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
                    try await refreshAllReferencedSources()
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
            memoryPressureSource?.cancel()
            firstUsePrewarmTask?.cancel()
            activeLibraryRescanTask?.cancel()
            AppDelegate.applicationWillTerminateHandler = nil
            AppDelegate.shouldCancelTerminationForPendingUpdateHandler = nil
            UpdateCoordinator.shared.terminationPreparationHandler = nil
            UpdateCoordinator.shared.installationDidAbortHandler = nil
        }
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard self != nil, let event = source?.data else { return }
            let reason = event.contains(.critical) ? "critical" : "warning"
            Task { @MainActor in
                await CacheManager.purgeRebuildableMemoryCaches(
                    reason: "system-memory-pressure-\(reason)",
                    cacheServices: self?.activeLibraryBinding.activeSession?.cacheServices
                )
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func prepareForTermination(
        reason: String,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        if let completion {
            if didFinishTerminationPreparation {
                completion()
                return
            }
            terminationCompletions.append(completion)
        }

        if !didPrepareTerminationSynchronously {
            didPrepareTerminationSynchronously = true
            Log.info("[Lifecycle] Preparing for termination reason=\(reason)", category: .ui)
            TelemetryService.shared.endSession(reason: .appTerminated)
            playerVM?.prepareForTermination()
            activeLibraryBinding.activeSession?.preferenceStatsService.checkpointPendingStats()
            savePlaybackMemory()
        }

        guard !terminationPreparationStarted else { return }
        terminationPreparationStarted = true
        terminationPreparationGeneration += 1
        let generation = terminationPreparationGeneration

        let libraryVM = self.libraryVM
        let preferenceStatsService = activeLibraryBinding.activeSession?.preferenceStatsService
        Task { @MainActor [weak self, weak libraryVM] in
            async let helperTermination: Void = QQMusicHelperProcess.shared.terminate()
            if let libraryVM, let preferenceStatsService {
                let tracksByID = Dictionary(
                    uniqueKeysWithValues: libraryVM.allTracks.map { ($0.id, $0) }
                )
                await preferenceStatsService.saveAllPending { trackID in
                    tracksByID[trackID]
                }
            }
            await helperTermination
            self?.finishTerminationPreparation(generation: generation)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finishTerminationPreparation(generation: generation)
        }
    }

    private func finishTerminationPreparation(generation: Int) {
        guard generation == terminationPreparationGeneration,
              !didFinishTerminationPreparation else { return }
        didFinishTerminationPreparation = true
        let completions = terminationCompletions
        terminationCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func resetTerminationPreparationAfterAbortedUpdate() {
        terminationPreparationGeneration += 1
        didPrepareTerminationSynchronously = false
        didFinishTerminationPreparation = false
        terminationPreparationStarted = false
        terminationCompletions.removeAll()
        Log.info("[Lifecycle] Reset termination preparation after aborted update", category: .ui)
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
            case .folders:
                selectionLabel = "folders"
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

/// Shared "reveal in Finder" validation for settings, the folder view and the
/// duplicate review (spec 18.1: validate the resolved path before opening).
nonisolated enum FinderRevealHelper {
    /// Resolves `path` (optionally through its bookmark data first), checks
    /// existence, and asks Finder to select it. Returns `false` when the
    /// target no longer resolves so callers can show gentle feedback instead
    /// of opening a stale location.
    @discardableResult
    static func reveal(path: String, bookmarkData: Data? = nil) -> Bool {
        guard let url = resolvedURL(path: path, bookmarkData: bookmarkData) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    static func fileExists(atPath path: String) -> Bool {
        resolvedURL(path: path, bookmarkData: nil) != nil
    }

    private static func resolvedURL(path: String, bookmarkData: Data?) -> URL? {
        var candidate = path
        if let bookmarkData, !bookmarkData.isEmpty {
            var bookmarkDataIsStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkDataIsStale
            ) {
                candidate = resolved.path
            }
        }
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        guard !standardized.isEmpty, FileManager.default.fileExists(atPath: standardized) else {
            return nil
        }
        return URL(fileURLWithPath: standardized)
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

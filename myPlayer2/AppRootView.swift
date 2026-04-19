//
//  AppRootView.swift
//  myPlayer2
//
//  kmgccc_player - App Root View
//  Creates and injects all dependencies.
//

import AppKit
import SwiftData
import SwiftUI

/// Root view that sets up dependency injection.
/// Creates real services for production, stubs for previews.
@MainActor
struct AppRootView: View {
    @ObservedObject var appSession: AppSessionHost

    // MARK: - App Globals (live updates via AppSettings)
    @State private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var swiftUIColorScheme
    @StateObject private var themeStore = ThemeStore.shared
    @State private var presentedAccentColor = ThemeStore.shared.accentColor
    @State private var accentPresentationTask: Task<Void, Never>?

    // MARK: - State Objects

    @StateObject private var artBackgroundController = BKArtBackgroundController()
    @StateObject private var fullscreenWindowManager = FullscreenWindowManager.shared

    // MARK: - Cover Services
    @State private var coverDownloadService = CoverDownloadService()
    @State private var netEaseCoverService = NetEaseCoverService()

    var body: some View {
        let uiState = appSession.uiState
        let rootContent = AppRootContentView(
            libraryVM: appSession.libraryVM,
            playerVM: appSession.playerVM,
            playbackCoordinator: appSession.playbackCoordinator,
            lyricsVM: appSession.lyricsVM,
            ledMeterProvider: appSession.ledMeterProvider,
            importEnrichmentService: appSession.importEnrichmentService,
            skinManager: appSession.skinManager,
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
                await appSession.setupIfNeeded()
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
                appSession.playbackCoordinator?.playPause()
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextTrack)) { _ in
                appSession.playbackCoordinator?.next()
            }
            .onReceive(NotificationCenter.default.publisher(for: .previousTrack)) { _ in
                appSession.playbackCoordinator?.previous()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLyrics)) { _ in
                uiState.toggleLyrics()
            }
            .onReceive(NotificationCenter.default.publisher(for: .aboutEasterEggTriggered)) { _ in
                appSession.easterEggSFX?.playRandomIfAllowed()
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
                    await appSession.libraryVM?.importToCurrentPlaylist()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newPlaylist)) { _ in
                Task {
                    _ = await appSession.libraryVM?.createNewPlaylist()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackModeChanged)) { _ in
                appSession.playerVM?.syncPlaybackOrderModeFromSettings()
            }

        return commandHandlersView
    }

    // MARK: - Layout

    private var mainWindowMinimumWidth: CGFloat {
        let uiState = appSession.uiState
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
        let uiState = appSession.uiState
        guard uiState.contentMode == .library else { return false }
        guard uiState.lyricsVisible, !uiState.lyricsPanelSuppressedByModal else { return false }
        guard !fullscreenWindowManager.isFullscreenActive else { return false }

        switch appSession.libraryVM?.currentSelection {
        case .playlist, .artist, .album:
            return true
        default:
            return false
        }
    }

}

// MARK: - Content View

private struct AppRootContentView: View {
    let libraryVM: LibraryViewModel?
    let playerVM: PlayerViewModel?
    let playbackCoordinator: PlaybackCoordinator?
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
               let playbackCoordinator = playbackCoordinator,
               let lyricsVM = lyricsVM,
               let ledMeterProvider = ledMeterProvider,
               let importEnrichmentService = importEnrichmentService,
               let skinManager = skinManager {

                let showArtBackground = uiState.contentMode == .nowPlaying
                    && settings.nowPlayingArtBackgroundEnabled
                    && playbackCoordinator.presentation.hasTrack
                    && !fullscreenWindowManager.isFullscreenActive

                MainAppContentView(
                    libraryVM: libraryVM,
                    playerVM: playerVM,
                    playbackCoordinator: playbackCoordinator,
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
    let playbackCoordinator: PlaybackCoordinator
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
                trackID: playbackCoordinator.presentation.localTrack?.id,
                artworkData: playbackCoordinator.presentation.artworkData,
                isPlaying: playbackCoordinator.presentation.isPlaying,
                resourceProfile: settings.selectedNowPlayingSkinID == "kmgccc.cassette"
                    ? .cassetteForeground
                    : .standard,
                initialPalette: [themeStore.accentNSColor]
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
            .environment(playbackCoordinator)
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
        if enabled && uiState.contentMode == .nowPlaying && playbackCoordinator.presentation.hasTrack {
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
            && playbackCoordinator.presentation.hasTrack
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
    let settingsSceneDependencies = SettingsSceneDependencies()
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TrackIndexEntry.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create preview ModelContainer: \(error)")
        }
    }()

    return AppRootView(
        appSession: AppSessionHost(
            modelContainer: sharedModelContainer,
            settingsSceneDependencies: settingsSceneDependencies
        )
    )
    .modelContainer(sharedModelContainer)
    .frame(width: 1200, height: 800)
}

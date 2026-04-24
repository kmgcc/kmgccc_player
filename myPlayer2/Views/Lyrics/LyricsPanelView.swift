//
//  LyricsPanelView.swift
//  myPlayer2
//
//  kmgccc_player - Lyrics Panel View
//  Right-side panel hosting AMLL lyrics with player state binding.
//  Uses LyricsWebViewStore singleton for stable WebView lifecycle.
//

import SwiftUI

/// Right-side lyrics panel with AMLL WebView.
/// The WebView is attached only when a track exists, to avoid eager WebKit startup.
struct LyricsPanelView: View {

    enum HostContainer: Sendable {
        /// Hosted inside the SwiftUI main detail column, where we may need to provide
        /// our own background separation.
        case swiftUIDetailColumn

        /// Hosted inside an AppKit `NSSplitViewItem(inspectorWithViewController:)`.
        /// In this mode we should not paint our own Liquid Glass/materials or fake separators,
        /// and instead let the system inspector container provide them.
        case appKitInspector
    }

    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    private let hostContainer: HostContainer
    @State private var attachAnimationToken = 0

    init(hostContainer: HostContainer = .swiftUIDetailColumn) {
        self.hostContainer = hostContainer
    }

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("LyricsPanelView.body")
        ZStack(alignment: .top) {
            lyricsBackgroundLayer
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
            .onAppear {
                Log.info("LyricsPanelView appeared", category: .webview)

                // Report visibility to manager - let manager decide if switch is needed
                LyricsSurfaceManager.shared.reportMainVisible(true)

                setupSeekCallback()
                reloadLyricsSurface(
                    reason: "lyrics panel appear",
                    forceWebReload: false,
                    forceLyricsReload: false
                )
            }
            .onDisappear {
                Log.info("LyricsPanelView disappeared", category: .webview)
                // Report visibility to manager - manager will debounce/handle transient states
                LyricsSurfaceManager.shared.reportMainVisible(false)
            }
            .onChange(of: playbackCoordinator.presentation.lyricsIdentity, handleTrackIdentityChange)
            .onChange(of: uiState.lyricsVisible) { _, isVisible in
                guard isVisible else { return }
                attachAnimationToken &+= 1
                LyricsSurfaceManager.shared.reportMainVisible(true)
                reloadLyricsSurface(
                    reason: "lyrics inspector expanded",
                    forceWebReload: false,
                    forceLyricsReload: false
                )
            }
            .onChange(of: playbackCoordinator.presentation.lyricsText) { _, _ in
                guard playbackCoordinator.presentation.source.isExternal else { return }
                reloadLyricsSurface(reason: "external lyrics updated", forceLyricsReload: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
                reloadLyricsSurface(reason: "playback track notification", forceLyricsReload: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
                guard
                    let trackID = notification.userInfo?["trackID"] as? UUID,
                    trackID == playbackCoordinator.presentation.localTrack?.id
                else { return }
                reloadLyricsSurface(reason: "library track enrichment update", forceLyricsReload: true)
            }
            .onChange(of: themeStore.colorScheme) { _, _ in
                // Theme mode switches must immediately re-push AMLL config,
                // so light/dark dedicated font weights take effect without waiting for settings edits.
                lyricsVM.refreshConfigFromSettings()
            }
            // Settings observation moved to modifier to reduce compiler complexity
            .modifier(LyricsSettingsObserver(lyricsVM: lyricsVM))
            .overlay {
                LyricsRealtimeSyncObserver {
                    reloadLyricsSurface(reason: "playback restarted", forceLyricsReload: true)
                }
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private var lyricsBackgroundLayer: some View {
        switch hostContainer {
        case .appKitInspector:
            appKitInspectorBackgroundLayer
        case .swiftUIDetailColumn:
            swiftUIDetailColumnBackgroundLayer
        }
    }

    @ViewBuilder
    private var appKitInspectorBackgroundLayer: some View {
        switch settings.lyricsBackgroundMode {
        case .sidebar:
            Color.clear
                .allowsHitTesting(false)
        case .clear:
            Rectangle()
                .fill(.ultraThinMaterial)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var swiftUIDetailColumnBackgroundLayer: some View {
        switch settings.lyricsBackgroundMode {
        case .sidebar:
            ZStack(alignment: .leading) {
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))

                themeStore.backgroundColor.opacity(0.10)

                Rectangle()
                    .fill(themeStore.secondaryTextColor.opacity(0.14))
                    .frame(width: 1)
            }
            .allowsHitTesting(false)
        case .clear:
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)

                if themeStore.colorScheme == .dark {
                    Color.black.opacity(0.3)
                } else {
                    Color.white.opacity(0.3)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        ZStack {
            if !playbackCoordinator.presentation.hasTrack {
                emptyStateView
            }

            if playbackCoordinator.presentation.hasTrack {
                AMLLWebView(store: lyricsVM.webViewStore, animatesAttachment: true)
                    .id(attachAnimationToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
            }

            if playbackCoordinator.presentation.hasTrack,
               let message = emptyLyricsMessage {
                lyricsUnavailableOverlay(message: message)
            }
        }
    }

    // MARK: - Actions

    private func setupSeekCallback() {
        lyricsVM.onSeekRequest = { seconds in
            playbackCoordinator.seek(to: seconds)
        }
    }

    private func handleTrackIdentityChange(_ oldId: String?, _ newId: String?) {
        guard oldId != newId else { return }
        LyricsRuntimeProfile.increment("LyricsPanelView.trackIDChange")
        switch libraryVM.currentSelection {
        case .allSongs:
            LyricsRuntimeProfile.setMetadata("lyrics.selectionKind", value: "allSongs")
        case .playlist:
            LyricsRuntimeProfile.setMetadata("lyrics.selectionKind", value: "playlist-header")
        case .artist:
            LyricsRuntimeProfile.setMetadata("lyrics.selectionKind", value: "artist-header")
        case .album:
            LyricsRuntimeProfile.setMetadata("lyrics.selectionKind", value: "album-header")
        }
        print(
            "[LyricsPanelView] Track changed: \(oldId?.prefix(8) ?? "nil") -> \(newId?.prefix(8) ?? "nil")"
        )
        reloadLyricsSurface(reason: "track changed", forceLyricsReload: true)
    }

    private func reloadLyricsSurface(
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false
    ) {
        let presentation = playbackCoordinator.presentation
        switch presentation.source {
        case .local:
            lyricsVM.ensureAMLLLoaded(
                track: presentation.localTrack,
                currentTime: presentation.currentTime,
                isPlaying: presentation.isPlaying,
                reason: reason,
                forceWebReload: forceWebReload,
                forceLyricsReload: forceLyricsReload
            )
        case .appleMusic, .systemNowPlaying:
            lyricsVM.ensureExternalAMLLLoaded(
                presentation: presentation,
                reason: reason,
                forceWebReload: forceWebReload,
                forceLyricsReload: forceLyricsReload
            )
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image("EmptyLyric")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            Text("lyrics.empty_state")
                .font(.subheadline)
                .foregroundStyle(themeStore.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, 12)
    }

    private var emptyLyricsMessage: String? {
        guard playbackCoordinator.presentation.source.isExternal else { return nil }
        let lyricsText = playbackCoordinator.presentation.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard lyricsText.isEmpty else { return nil }
        if let externalMessage = playbackCoordinator.presentation.externalLyricsStatusMessage {
            return externalMessage
        }
        return NSLocalizedString("lyrics.empty_state", comment: "")
    }

    private func lyricsUnavailableOverlay(message: String) -> some View {
        VStack(spacing: 8) {
            Image("EmptyLyric")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(themeStore.secondaryTextColor)
                .frame(maxWidth: 280)
        }
        .padding(.top, 12)
        .allowsHitTesting(false)
    }
}

// MARK: - Preview

#Preview("Lyrics Panel") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let libraryVM = LibraryViewModel(repository: StubLibraryRepository())
    let appleMusicAdapter = AppleMusicPlaybackAdapter(libraryVM: libraryVM)
    let playbackCoordinator = PlaybackCoordinator(
        playerVM: playerVM,
        appleMusicAdapter: appleMusicAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider(libraryVM: libraryVM)
    )
    let lyricsVM = LyricsViewModel()

    HStack(spacing: 0) {
        Color.gray.opacity(0.3)
            .frame(width: 400)

        LyricsPanelView()
            .environment(playerVM)
            .environment(playbackCoordinator)
            .environment(libraryVM)
            .environment(lyricsVM)
            .environmentObject(ThemeStore.shared)
    }
    .frame(width: 800, height: 600)
    .preferredColorScheme(.dark)
}

private struct LyricsRealtimeSyncObserver: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LyricsViewModel.self) private var lyricsVM

    let onPlaybackRestart: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: playbackCoordinator.presentation.currentTime) { oldTime, newTime in
                lyricsVM.syncTime(newTime)
                if oldTime > 1.0, newTime < 0.2 {
                    onPlaybackRestart()
                }
            }
            .onChange(of: playbackCoordinator.presentation.isPlaying) { _, newValue in
                lyricsVM.setPlaying(newValue)
            }
    }
}

// MARK: - Settings Observer Modifier

struct LyricsSettingsObserver: ViewModifier {
    var lyricsVM: LyricsViewModel

    @AppStorage("lyricsFontSize") private var lyricsFontSize: Double = 24.0
    @AppStorage("lyricsFontNameZh") private var lyricsFontNameZh: String = "PingFang SC"
    @AppStorage("lyricsFontNameEn") private var lyricsFontNameEn: String = "SF Pro Text"
    @AppStorage("lyricsTranslationFontName") private var lyricsTranslationFontName: String =
        "SF Pro Text"
    @AppStorage("lyricsFontWeightLight") private var lyricsFontWeightLight: Int = 600
    @AppStorage("lyricsFontWeightDark") private var lyricsFontWeightDark: Int = 600
    @AppStorage("lyricsTranslationFontSize") private var lyricsTranslationFontSize: Double = 18.0
    @AppStorage("lyricsTranslationFontWeightLight") private var lyricsTranslationFontWeightLight:
        Int = 400
    @AppStorage("lyricsTranslationFontWeightDark") private var lyricsTranslationFontWeightDark:
        Int = 400
    @AppStorage("lyricsLeadInMs") private var lyricsLeadInMs: Double = 300
    @AppStorage("lyricsNearSwitchGapMs") private var lyricsNearSwitchGapMs: Double = 70
    @AppStorage("lyricsGlobalAdvanceMs") private var lyricsGlobalAdvanceMs: Double = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: lyricsFontSize) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsFontNameZh) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsFontNameEn) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsTranslationFontName) { _, _ in lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsFontWeightLight) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsFontWeightDark) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsLeadInMs) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsNearSwitchGapMs) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsGlobalAdvanceMs) { _, _ in lyricsVM.refreshConfigFromSettings() }
            .onChange(of: lyricsTranslationFontSize) { _, _ in lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontWeightLight) { _, _ in
                lyricsVM.refreshConfigFromSettings()
            }
            .onChange(of: lyricsTranslationFontWeightDark) { _, _ in
                lyricsVM.refreshConfigFromSettings()
            }
    }
}

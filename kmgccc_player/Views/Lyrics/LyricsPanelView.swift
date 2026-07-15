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
    @ObservedObject private var fullscreenWindowManager = FullscreenWindowManager.shared

    private let hostContainer: HostContainer
    @State private var shouldHostLyricsWebView = false
    @State private var pendingWebViewUnmount: DispatchWorkItem?

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
                let token = FirstUseHitchDiagnostics.begin(
                    "LyricsPanelView.onAppear",
                    detail: "hasTrack=\(playbackCoordinator.presentation.hasTrack), visible=\(uiState.lyricsVisible)"
                )
                Log.info("LyricsPanelView appeared", category: .webview)

                setupSeekCallback()
                syncMainLyricsSurfaceVisibility(
                    isVisible: isLyricsSurfaceActive,
                    reason: "lyrics panel appear"
                )
                FirstUseHitchDiagnostics.end(token)
            }
            .onDisappear {
                let token = FirstUseHitchDiagnostics.begin(
                    "LyricsPanelView.onDisappear",
                    detail: "hasTrack=\(playbackCoordinator.presentation.hasTrack)"
                )
                Log.info("LyricsPanelView disappeared", category: .webview)
                // Report visibility to manager - manager will debounce/handle transient states
                LyricsSurfaceManager.shared.reportMainVisible(false)
                pendingWebViewUnmount?.cancel()
                pendingWebViewUnmount = nil
                shouldHostLyricsWebView = false
                FirstUseHitchDiagnostics.end(token)
            }
            .onChange(of: playbackCoordinator.presentation.lyricsIdentity, handleTrackIdentityChange)
            .onChange(of: playbackCoordinator.presentation.hasTrack) { _, hasTrack in
                syncMainLyricsSurfaceVisibility(
                    isVisible: isLyricsSurfaceActive,
                    reason: "presentation hasTrack changed",
                    hasTrackOverride: hasTrack
                )
            }
            .onChange(of: uiState.lyricsVisible) { _, isVisible in
                syncMainLyricsSurfaceVisibility(
                    isVisible: isVisible && !uiState.isWindowPlaybackQueueVisible,
                    reason: isVisible ? "lyrics inspector expanded" : "lyrics inspector collapsed"
                )
            }
            .onChange(of: uiState.isWindowPlaybackQueueVisible) { _, isQueueVisible in
                syncMainLyricsSurfaceVisibility(
                    isVisible: uiState.lyricsVisible && !isQueueVisible,
                    reason: isQueueVisible ? "window queue opened" : "window queue closed"
                )
            }
            .onChange(of: fullscreenWindowManager.presentationMode) { _, mode in
                syncMainLyricsSurfaceVisibility(
                    isVisible: mode == .none
                        && uiState.lyricsVisible
                        && !uiState.isWindowPlaybackQueueVisible,
                    reason: "fullscreen presentation changed to \(String(describing: mode))"
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
                guard isLyricsSurfaceActive else { return }
                guard
                    let trackID = notification.userInfo?["trackID"] as? UUID,
                    trackID == playbackCoordinator.presentation.localTrack?.id
                else { return }
                reloadLyricsSurface(reason: "library track enrichment update", forceLyricsReload: true)
            }
            .onChange(of: themeStore.colorScheme) { _, _ in
                guard isLyricsSurfaceActive else { return }
                // Theme mode switches must immediately re-push AMLL config,
                // so light/dark dedicated font weights take effect without waiting for settings edits.
                lyricsVM.refreshConfigFromSettings()
            }
            // Settings observation moved to modifier to reduce compiler complexity
            .modifier(LyricsSettingsObserver(lyricsVM: lyricsVM, isActive: isLyricsSurfaceActive))
            .overlay {
                LyricsRealtimeSyncObserver(isActive: isLyricsSurfaceActive) {
                    reloadLyricsSurface(reason: "playback restarted", forceLyricsReload: true)
                }
                .allowsHitTesting(false)
            }
    }

    private var isLyricsSurfaceActive: Bool {
        LyricsSurfaceManager.shared.targetMode == .main
            && uiState.lyricsVisible
            && !uiState.isWindowPlaybackQueueVisible
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
        if uiState.isWindowPlaybackQueueVisible {
            WindowPlaybackQueuePanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack {
                if !playbackCoordinator.presentation.hasTrack {
                    emptyStateView
                } else if shouldHostLyricsWebView {
                    AMLLWebView(store: lyricsVM.webViewStore, animatesAttachment: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                }

                if playbackCoordinator.presentation.hasTrack,
                   let message = emptyLyricsMessage {
                    lyricsUnavailableOverlay(message: message)
                }
            }
        }
    }

    // MARK: - Actions

    private func setupSeekCallback() {
        lyricsVM.onSeekRequest = { seconds in
            playbackCoordinator.seek(to: seconds)
        }
    }

    private func syncMainLyricsSurfaceVisibility(
        isVisible: Bool,
        reason: String,
        hasTrackOverride: Bool? = nil
    ) {
        guard LyricsSurfaceManager.shared.targetMode == .main else {
            pendingWebViewUnmount?.cancel()
            pendingWebViewUnmount = nil
            if shouldHostLyricsWebView {
                Log.debug("LyricsPanelView host WebView: false immediately, reason=\(reason).fullscreenTarget", category: .webview)
            }
            shouldHostLyricsWebView = false
            LyricsSurfaceManager.shared.reportMainVisible(false)
            return
        }
        let hasTrack = hasTrackOverride ?? playbackCoordinator.presentation.hasTrack
        let shouldRevealExistingLyrics =
            LyricsSurfaceManager.shared.currentMode == .main
            && LyricsSurfaceManager.shared.switchState == .idle
            && LyricsSurfaceManager.shared.existingStore(for: .main)?.isReady == true
        updateLyricsWebViewHosting(
            shouldHost: isVisible && hasTrack,
            reason: reason
        )

        guard isVisible, hasTrack else {
            LyricsSurfaceManager.shared.reportMainVisible(false)
            return
        }

        LyricsSurfaceManager.shared.reportMainVisible(true)
        reloadLyricsSurface(reason: reason)
        // A mode switch/new WebView already receives the native AMLL loading
        // entrance from LyricsSurfaceManager's snapshot replay. Only ask for
        // the existing-line reveal when this main surface was already ready
        // and stable; otherwise it would animate the same lyric twice.
        if shouldRevealExistingLyrics {
            lyricsVM.revealExistingLyrics(reason: reason)
        }
    }

    private func updateLyricsWebViewHosting(shouldHost: Bool, reason: String) {
        pendingWebViewUnmount?.cancel()
        pendingWebViewUnmount = nil

        if shouldHost {
            if !shouldHostLyricsWebView {
                Log.debug("LyricsPanelView host WebView: true, reason=\(reason)", category: .webview)
            }
            shouldHostLyricsWebView = true
            return
        }

        let workItem = DispatchWorkItem {
            Log.debug("LyricsPanelView host WebView: false, reason=\(reason)", category: .webview)
            shouldHostLyricsWebView = false
            pendingWebViewUnmount = nil
        }
        pendingWebViewUnmount = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(900), execute: workItem)
    }

    private func handleTrackIdentityChange(_ oldId: String?, _ newId: String?) {
        guard oldId != newId else { return }
        LyricsRuntimeProfile.increment("LyricsPanelView.trackIDChange")
        switch libraryVM.currentSelection {
        case .home, .allPlaylists, .allAlbums, .allArtists:
            LyricsRuntimeProfile.setMetadata("lyrics.selectionKind", value: "home")
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
                currentTime: presentation.lyricsCurrentTime,
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
            ArtAssetImages.image(
                named: ArtAssetImages.emptyLyricsName,
                maxPixel: 720,
                fallbackSystemName: "text.quote"
            )
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
            ArtAssetImages.image(
                named: ArtAssetImages.emptyLyricsName,
                maxPixel: 560,
                fallbackSystemName: "text.quote"
            )
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

// MARK: - Window Playback Queue

struct WindowPlaybackQueuePanelView: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var hasPerformedInitialScroll = false

    private var tracks: [Track] {
        playerVM.currentQueueTracks
    }

    private var currentTrackID: UUID? {
        playerVM.currentTrack?.id
    }

    private var playbackMode: PlaybackOrderMode {
        playbackCoordinator.presentation.localPlaybackOrderMode ?? settings.playbackOrderMode
    }

    var body: some View {
        if uiState.isWindowPlaybackQueueVisible {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                if tracks.isEmpty {
                    emptyQueueView
                } else {
                    queueList
                        .padding(.horizontal, 14)
                        .padding(.bottom, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture {}
        } else {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: modeIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondaryForegroundColor)

            Text(titleText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(primaryForegroundColor)

            Text("\(tracks.count) 首")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(secondaryForegroundColor)

            Spacer(minLength: 8)

            Button {
                uiState.hideWindowPlaybackQueue()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(secondaryForegroundColor)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭播放队列")
        }
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 4) {
                    Color.clear
                        .frame(height: 8)
                        .accessibilityHidden(true)

                    ForEach(tracks) { track in
                        WindowPlaybackQueueRow(
                            track: track,
                            isPlaying: track.id == currentTrackID,
                            primaryColor: primaryForegroundColor,
                            secondaryColor: secondaryForegroundColor,
                            tertiaryColor: tertiaryForegroundColor,
                            hoverFillColor: hoverFillColor
                        )
                        .id(track.id)
                        .onTapGesture {
                            playbackCoordinator.playTrackFromQueue(track)
                        }
                    }

                    Color.clear
                        .frame(height: 8)
                        .accessibilityHidden(true)
                }
            }
            .mask(queueListMask)
            .onAppear {
                revealCurrentTrack(using: proxy, animated: false)
                hasPerformedInitialScroll = true
            }
            .onChange(of: currentTrackID) { _, newTrackID in
                guard hasPerformedInitialScroll, let newTrackID else { return }
                scrollToTrack(newTrackID, using: proxy, animated: true)
            }
            .onChange(of: tracks.map(\.id)) { _, _ in
                guard hasPerformedInitialScroll else { return }
                revealCurrentTrack(using: proxy, animated: true)
            }
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(tertiaryForegroundColor)

            Text("当前没有播放队列")
                .font(.subheadline)
                .foregroundStyle(secondaryForegroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, 30)
    }

    private var queueListMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
        }
    }

    private var titleText: String {
        switch playbackMode {
        case .sequence:
            return "播放列表"
        case .shuffle:
            return "随机队列"
        case .repeatOne:
            return "单曲循环队列"
        case .stopAfterTrack:
            return "当前队列"
        }
    }

    private var modeIcon: String {
        switch playbackMode {
        case .shuffle:
            return "shuffle"
        case .sequence:
            return "list.bullet"
        case .repeatOne:
            return "repeat.1"
        case .stopAfterTrack:
            return "pause.circle"
        }
    }

    private var primaryForegroundColor: Color {
        themeStore.appForegroundPalette.primaryColor.opacity(0.96)
    }

    private var secondaryForegroundColor: Color {
        themeStore.appForegroundPalette.secondaryColor.opacity(0.82)
    }

    private var tertiaryForegroundColor: Color {
        themeStore.appForegroundPalette.tertiaryColor.opacity(0.72)
    }

    private var hoverFillColor: Color {
        Color.primary.opacity(0.08)
    }

    private var queueScrollAnimation: Animation {
        .timingCurve(0.22, 0.88, 0.24, 1.0, duration: 0.42)
    }

    private func revealCurrentTrack(using proxy: ScrollViewProxy, animated: Bool) {
        guard let currentTrackID, tracks.contains(where: { $0.id == currentTrackID }) else { return }
        scrollToTrack(currentTrackID, using: proxy, animated: animated)
    }

    private func scrollToTrack(_ trackID: UUID, using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            guard tracks.contains(where: { $0.id == trackID }) else { return }
            if animated {
                withAnimation(queueScrollAnimation) {
                    proxy.scrollTo(trackID, anchor: UnitPoint(x: 0.5, y: 0.16))
                }
            } else {
                proxy.scrollTo(trackID, anchor: UnitPoint(x: 0.5, y: 0.16))
            }
        }
    }
}

private struct WindowPlaybackQueueRow: View {
    let track: Track
    let isPlaying: Bool
    let primaryColor: Color
    let secondaryColor: Color
    let tertiaryColor: Color
    let hoverFillColor: Color

    @State private var isHovering = false
    @State private var artworkImage: NSImage?

    private let artworkSize: CGFloat = 38

    var body: some View {
        HStack(spacing: 10) {
            artworkView
                .frame(width: artworkSize, height: artworkSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? primaryColor : primaryColor.opacity(0.94))
                    .lineLimit(1)

                Text(artistText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(primaryColor)
                    .frame(width: 24)
            } else {
                Text(formatDuration(track.duration))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tertiaryColor)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtwork()
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ArtworkPlaceholderView.queueRow(
                artworkSize: artworkSize,
                scale: 1,
                themeColor: isPlaying ? primaryColor : secondaryColor
            )
        }
    }

    private var rowFill: Color {
        if isPlaying {
            return primaryColor.opacity(0.13)
        }
        return isHovering ? hoverFillColor : Color.clear
    }

    private var artistText: String {
        track.artist.isEmpty ? "未知艺人" : track.artist
    }

    private var currentArtworkTaskKey: String {
        track.trackArtworkSource()?.sourceKey ?? "none-\(track.id.uuidString)"
    }

    private func loadArtwork() async {
        guard let source = track.trackArtworkSource() else {
            await MainActor.run {
                artworkImage = nil
            }
            return
        }

        let image = await TrackArtworkCache.shared.thumbnail(for: source)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            artworkImage = image
        }
    }

    private func formatDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
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

    let isActive: Bool
    let onPlaybackRestart: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: playbackCoordinator.presentation.currentTime) { oldTime, newTime in
                guard isActive else { return }
                lyricsVM.syncTime(playbackCoordinator.presentation.lyricsCurrentTime)
                if oldTime > 1.0, newTime < 0.2 {
                    onPlaybackRestart()
                }
            }
            .onChange(of: playbackCoordinator.presentation.isPlaying) { _, newValue in
                guard isActive else { return }
                if !newValue {
                    lyricsVM.syncTime(playbackCoordinator.presentation.lyricsCurrentTime)
                }
                lyricsVM.setPlaying(newValue)
            }
    }
}

// MARK: - Settings Observer Modifier

struct LyricsSettingsObserver: ViewModifier {
    var lyricsVM: LyricsViewModel
    var isActive: Bool = true

    @AppStorage("lyricsFontSize") private var lyricsFontSize: Double = 32.0
    @AppStorage("lyricsFontNameZh") private var lyricsFontNameZh: String = "SF Pro Text"
    @AppStorage("lyricsFontNameEn") private var lyricsFontNameEn: String = "SF Pro Text"
    @AppStorage("lyricsTranslationFontName") private var lyricsTranslationFontName: String =
        "SF Pro Text"
    @AppStorage("lyricsFontWeightLight") private var lyricsFontWeightLight: Int = 600
    @AppStorage("lyricsFontWeightDark") private var lyricsFontWeightDark: Int = 100
    @AppStorage("lyricsTranslationFontSize") private var lyricsTranslationFontSize: Double = 18.0
    @AppStorage("lyricsTranslationFontWeightLight") private var lyricsTranslationFontWeightLight:
        Int = 500
    @AppStorage("lyricsTranslationFontWeightDark") private var lyricsTranslationFontWeightDark:
        Int = 100
    @AppStorage("lyricsLeadInMs") private var lyricsLeadInMs: Double = 300
    @AppStorage("lyricsNearSwitchGapMs") private var lyricsNearSwitchGapMs: Double = 70
    @AppStorage("lyricsGlobalAdvanceMs") private var lyricsGlobalAdvanceMs: Double = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: lyricsFontSize) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsFontNameZh) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsFontNameEn) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsTranslationFontName) { _, _ in refreshConfigIfActive()
            }
            .onChange(of: lyricsFontWeightLight) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsFontWeightDark) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsLeadInMs) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsNearSwitchGapMs) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsGlobalAdvanceMs) { _, _ in refreshConfigIfActive() }
            .onChange(of: lyricsTranslationFontSize) { _, _ in refreshConfigIfActive()
            }
            .onChange(of: lyricsTranslationFontWeightLight) { _, _ in
                refreshConfigIfActive()
            }
            .onChange(of: lyricsTranslationFontWeightDark) { _, _ in
                refreshConfigIfActive()
            }
    }

    private func refreshConfigIfActive() {
        guard isActive else { return }
        lyricsVM.refreshConfigFromSettings()
    }
}

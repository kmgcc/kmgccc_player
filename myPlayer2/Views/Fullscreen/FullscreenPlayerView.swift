import AppKit
import Foundation
import SwiftUI

@MainActor
struct FullscreenPlayerView: View {
    static let baseCanvasWidth: CGFloat = 1470
    static let baseCanvasHeight: CGFloat = 923

    private enum RightPanelDisplayState {
        case hidden
        case lyrics
        case queue
    }

    private let topContentHorizontalPadding: CGFloat = 0
    private let topContentLeftShift: CGFloat = 44
    private let artworkLyricsColumnSpacing: CGFloat = -58
    private let lyricsColumnLeftNudge: CGFloat = 80
    private let lyricsRightMarginReserve: CGFloat = 88
    private let lyricsViewportTopLift: CGFloat = 22
    private let coverSkinLyricsRightShift: CGFloat = 30

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(AppSettings.self) private var settings
    @Environment(SkinManager.self) private var skinManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var themeStore: ThemeStore
    private let miniPlayerSpectrumService = AudioVisualizationService.shared
    private let lyricsThemeEngine = FullscreenLyricsThemeEngine()
    @StateObject private var bkController = BKArtBackgroundController()
    @State private var lyricsController = FullscreenLyricsController()
    @State private var bottomControlsController = FullscreenBottomControlsController()
    @State private var skinRevision = 0
    @State private var rightPanelDisplayState: RightPanelDisplayState = .lyrics
    @State private var artworkSnapshot: ArtworkAssetSnapshot?
    @State private var currentFullscreenScale: CGFloat = 1.0
    @State private var didHandleFullscreenAppear = false
    @State private var hasPresentedFullscreenArtBackground = false
    @State private var isFullscreenMiniPlayerSpectrumLeaseActive = false

    let windowedArtBackgroundController: BKArtBackgroundController?
    var onExitFullscreen: (() -> Void)?

    private var selectedFullscreenSkin: any FullscreenSkin {
        skinManager.fullscreenSkin(for: settings.fullscreen.skinID)
    }

    private var isCoverBlurFullscreenSkin: Bool {
        selectedFullscreenSkin.wantsCoverBlurLyricsTreatment
    }

    private var isFullscreenArtBackgroundActive: Bool {
        ArtBackgroundPolicy.fullscreenIsActive(
            isEnabled: settings.fullscreenArtBackgroundEnabled,
            hasTrack: playerVM.currentTrack != nil,
            allowsHostArtBackground: selectedFullscreenSkin.allowsHostArtBackground
        )
    }

    private var fullscreenStore: LyricsWebViewStore {
        LyricsSurfaceManager.shared.store(for: .fullscreen)
    }

    private var existingFullscreenStore: LyricsWebViewStore? {
        LyricsSurfaceManager.shared.existingStore(for: .fullscreen)
    }

    private var coverBlurHighlightStore: LyricsWebViewStore {
        LyricsSurfaceManager.shared.store(for: .fullscreenCoverBlurHighlight)
    }

    private var existingCoverBlurHighlightStore: LyricsWebViewStore? {
        LyricsSurfaceManager.shared.existingStore(for: .fullscreenCoverBlurHighlight)
    }

    private var shouldRenderCoverBlurHighlightOverlay: Bool {
        // A second AMLL surface introduces timing drift and visible ghosting.
        // Keep cover-blur fullscreen on a single AMLL surface only.
        false
    }

    private var effectiveDimmingIntensity: Double {
        let base = settings.fullscreenDimmingIntensity
        if colorScheme == .light {
            return min(0.55, base * 1.40)
        }
        return base
    }

    private var selectedSkinID: String {
        settings.fullscreen.skinID
    }

    var body: some View {
        GeometryReader { proxy in
            fullscreenCanvas(for: proxy)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                forceRefreshFullscreenLyricsColors(reason: "context-menu-refresh")
            } label: {
                Label(
                    NSLocalizedString(
                        "fullscreen.refresh_lyrics_colors",
                        comment: "Refresh fullscreen lyrics color sampling"
                    ),
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .onAppear {
            guard !didHandleFullscreenAppear else { return }
            didHandleFullscreenAppear = true
            Log.info("FullscreenPlayerView appeared", category: .webview)

            LyricsSurfaceManager.shared.reportFullscreenVisible(true)

            syncCoverBlurHighlightActivation()
            lyricsController.resetBackgroundSnapshot()
            lyricsController.scheduleBackgroundCapture(
                isArtBackgroundActive: isFullscreenArtBackgroundActive,
                currentTrackID: playerVM.currentTrack?.id
            )
            lyricsController.handleAppear(
                isShowingLyricsPanel: isShowingLyricsPanel,
                currentTrackID: playerVM.currentTrack?.id
            )
            setupSeekCallback()
            reloadLyricsSurface(reason: "fullscreen appear")
            resetFullscreenBottomControlsAutoHideState()
            syncFullscreenMiniPlayerSpectrumLease()
            seedFullscreenArtBackgroundControllerFromWindowMode()
            _ = markFullscreenArtBackgroundPresentationIfNeeded()

            if isLedEnabledForFullscreenSkin() {
                ledMeterProvider.getOrCreate().start()
            }
        }
        .onDisappear {
            Log.info("FullscreenPlayerView disappeared", category: .webview)
            didHandleFullscreenAppear = false
            ledMeterProvider.releaseNowPlayingResources()
            artworkSnapshot = nil
            existingFullscreenStore?.onUserSeek = nil
            lyricsController.handleDisappear()
            releaseFullscreenMiniPlayerSpectrumLease()
            bottomControlsController.cancelAutoHide()
            deactivateCoverBlurHighlightSurface()
            clearFullscreenLyricsTheme()
            Task {
                await ArtworkAssetStore.shared.purgeHydratedImages()
                await CassetteArtworkCache.shared.removeAll()
            }

            LyricsSurfaceManager.shared.reportFullscreenVisible(false)
        }
        .onChange(of: selectedSkinID) { oldValue, newValue in
            skinRevision &+= 1
            if oldValue == "kmgccc.cassette", newValue != oldValue {
                Task {
                    await CassetteArtworkCache.shared.removeAll()
                }
            }
            if newValue != "fullscreen.coverGradientBlur" {
                lyricsController.coverBlurTheme = nil
            }
            let coverBlurTransition = oldValue == "fullscreen.coverGradientBlur"
                || newValue == "fullscreen.coverGradientBlur"
            syncCoverBlurHighlightActivation()
            handleFullscreenArtBackgroundChange(reason: "fullscreen skin changed")
            guard coverBlurTransition else { return }
            reloadLyricsSurface(reason: "fullscreen skin changed")
        }
        .onChange(of: settings.fullscreen.skinID) { _, newValue in
            if isLedEnabledForFullscreenSkin() {
                ledMeterProvider.getOrCreate().start()
            } else {
                ledMeterProvider.releaseNowPlayingResources()
            }

        }
        .onChange(of: settings.fullscreenArtBackgroundEnabled) { _, _ in
            handleFullscreenArtBackgroundChange(reason: "fullscreen art background toggle")
        }
        .onChange(of: settings.fullscreen.isMiniPlayerSpectrumEnabled) { _, _ in
            syncFullscreenMiniPlayerSpectrumLease()
        }
        .onChange(of: playerVM.currentTime, handleCurrentTimeChange)
        .onChange(of: playerVM.isPlaying) { _, newValue in
            LyricsSurfaceManager.shared.updatePlayingState(newValue)
            fullscreenStore.setPlaying(newValue)
            if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
                coverBlurHighlightStore.setPlaying(newValue)
            }
            if isFullscreenMiniPlayerSpectrumLeaseActive {
                miniPlayerSpectrumService.updatePlaybackState(isPlaying: newValue)
            }
        }
        .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
        .onChange(of: rightPanelDisplayState) { _, newValue in
            handleRightPanelDisplayStateChange(newValue)
        }
        .onChange(of: bottomControlsController.isVisible) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                applyFullscreenLyricsTheme(reason: "bottomControlsVisibility-changed")
            }
        }
        .onChange(of: fullscreenLyricsConfigSignature) { _, _ in
            applyFullscreenLyricsTheme()
        }
        .onChange(of: colorScheme) { _, _ in
            forceRefreshFullscreenLyricsColors(reason: "colorScheme-change")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleQueuePanel)) { _ in
            // Cycle through right panel states: lyrics -> queue -> hidden -> lyrics
            let nextState: RightPanelDisplayState
            switch rightPanelDisplayState {
            case .queue:
                nextState = .hidden
            case .lyrics:
                nextState = .queue
            case .hidden:
                nextState = .lyrics
            }
            setRightPanelDisplayState(nextState)
        }
        .onChange(of: settings.fullscreenMiniPlayerAutoHideSeconds) { _, _ in
            resetFullscreenBottomControlsAutoHideState()
        }
        .onChange(of: bkController.lyricsColorSampleRevision) { _, _ in
            guard lyricsController.pendingBackgroundCapture else { return }
            guard bkController.lyricsColorTrackID == playerVM.currentTrack?.id else { return }
            lyricsController.scheduleLyricsRefresh(
                preferLiveSurface: true,
                captureSnapshot: captureFullscreenLyricsBackgroundSnapshot,
                applyTheme: { applyFullscreenLyricsTheme() }
            )
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkSnapshot()
        }
    }

    @ViewBuilder
    private func fullscreenCanvas(for proxy: GeometryProxy) -> some View {
        let selectedSkin = selectedFullscreenSkin

        FullscreenPlayerCanvasView(
            proxySize: proxy.size,
            selectedSkin: selectedSkin,
            skinUsesCustomBackground: !selectedSkin.allowsHostArtBackground,
            effectiveDimmingIntensity: effectiveDimmingIntensity,
            isFullscreenArtBackgroundActive: isFullscreenArtBackgroundActive,
            currentTrack: playerVM.currentTrack,
            isPlaying: playerVM.isPlaying,
            currentTrackID: playerVM.currentTrack?.id,
            currentQueueTracks: playerVM.currentQueueTracks,
            playbackMode: currentPlaybackMode,
            glassStyle: fullscreenControlsGlassStyle,
            usesBrightTextPalette: fullscreenQueueUsesBrightTextPalette,
            fullscreenStore: fullscreenStore,
            coverBlurHighlightStore: coverBlurHighlightStore,
            bkController: bkController,
            bottomControlsController: bottomControlsController,
            baseCanvasSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
            topContentHorizontalPadding: topContentHorizontalPadding,
            topContentLeftShift: topContentLeftShift,
            artworkLyricsColumnSpacing: artworkLyricsColumnSpacing,
            lyricsColumnLeftNudge: lyricsColumnLeftNudge,
            lyricsRightMarginReserve: lyricsRightMarginReserve,
            lyricsViewportTopLift: lyricsViewportTopLift,
            coverSkinLyricsRightShift: coverSkinLyricsRightShift,
            bottomControlsAnimation: bottomControlsAnimation,
            coverDropAnimation: coverDropAnimation,
            isCoverBlurFullscreenSkin: isCoverBlurFullscreenSkin,
            shouldRenderCoverBlurHighlightOverlay: shouldRenderCoverBlurHighlightOverlay,
            coverBlurBaseBlendMode: coverBlurBaseBlendMode,
            coverBlurHighlightBlendMode: coverBlurHighlightBlendMode,
            keepLyricsHostMounted: shouldKeepFullscreenLyricsHostMounted,
            isShowingLyricsPanel: isShowingLyricsPanel,
            isShowingQueuePanel: isShowingQueuePanel,
            hostOpacity: fullscreenLyricsHostOpacity,
            isHostVisible: isFullscreenLyricsHostVisible,
            viewportOpacity: fullscreenLyricsViewportOpacity,
            volume: volumeBinding,
            primaryColor: fullscreenMiniPlayerPrimaryColor,
            controlsColorScheme: fullscreenControlsColorScheme,
            effectiveAppearance: effectiveFullscreenAppearance,
            artworkScale: settings.fullscreenArtworkScale,
            canToggleLyrics: playerVM.currentTrack != nil,
            autoHideSeconds: settings.fullscreenMiniPlayerAutoHideSeconds,
            shouldKeepControlsVisible: isShowingQueuePanel,
            makeSkinContext: { artworkColumnWidth, fullscreenScale in
                makeContext(
                    windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
                    artworkColumnWidth: artworkColumnWidth,
                    fullscreenScale: fullscreenScale
                )
            },
            onScaleChange: { currentFullscreenScale = $0 },
            onExitFullscreen: { onExitFullscreen?() },
            onToggleLyrics: handleLyricsButtonTap,
            onCycleAppearance: {
                cycleFullscreenAppearance(to: nextFullscreenAppearanceTarget())
            },
            onPlaybackModeChange: handlePlaybackModeChange,
            onCurrentPlaybackModeRetap: handleCurrentPlaybackModeRetap,
            onQueueTrackTap: handleQueueTrackTap,
            onDismissQueue: { setRightPanelDisplayState(.lyrics) }
        )
    }

    // MARK: - Bottom Controls

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { playerVM.volume },
            set: { playerVM.setVolume($0) }
        )
    }

    private var bottomControlsAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.18)
        }
        return .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }

    private var coverDropAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.28)
        }
        return .spring(response: 0.55, dampingFraction: 0.82, blendDuration: 0.08)
    }

    private func handleRightPanelDisplayStateChange(_ newState: RightPanelDisplayState) {
        lyricsController.syncHostMount(
            isShowingLyricsPanel: newState == .lyrics,
            currentTrackID: playerVM.currentTrack?.id,
            reduceMotion: reduceMotion
        )
        bottomControlsController.handleRightPanelStateChange(
            isQueueVisible: newState == .queue,
            autoHideSeconds: settings.fullscreenMiniPlayerAutoHideSeconds,
            animation: bottomControlsAnimation
        )
    }

    private func resetFullscreenBottomControlsAutoHideState() {
        bottomControlsController.resetAutoHideState(
            autoHideSeconds: settings.fullscreenMiniPlayerAutoHideSeconds,
            shouldKeepVisible: isShowingQueuePanel,
            animation: bottomControlsAnimation
        )
    }

    // MARK: - Helpers

    private var isShowingLyricsPanel: Bool {
        rightPanelDisplayState == .lyrics
    }

    private var isShowingQueuePanel: Bool {
        rightPanelDisplayState == .queue
    }

    private var isShowingRightPanel: Bool {
        rightPanelDisplayState != .hidden
    }

    private var currentPlaybackMode: PlaybackOrderMode {
        if settings.stopAfterTrack { return .stopAfterTrack }
        if settings.repeatMode == "one" { return .repeatOne }
        if settings.shuffleEnabled { return .shuffle }
        return .sequence
    }

    private var lyricsLayoutAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        return .spring(response: 0.62, dampingFraction: 0.84, blendDuration: 0.18)
    }

    private var fullscreenMiniPlayerPrimaryColor: Color {
        FullscreenMiniPlayerView.resolveControlPrimaryColor(from: themeStore.accentNSColor)
    }

    private var fullscreenControlsGlassStyle: FullscreenControlsGlassStyle {
        FullscreenControlsGlassStyle(
            colorScheme: fullscreenControlsColorScheme,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            materialStyle: settings.fullscreenMiniPlayerGlassMaterial == .darkGlass ? .darkGlass : .clear
        )
    }

    private var fullscreenQueueUsesBrightTextPalette: Bool {
        let skinID = settings.fullscreen.skinID
        return skinID == "coverLed" || skinID == "rotatingCover" || skinID == "kmgccc.cassette"
    }

    private var fullscreenControlsColorScheme: ColorScheme {
        isCoverBlurFullscreenSkin ? .dark : colorScheme
    }

    private var shouldKeepFullscreenMiniPlayerSpectrumAlive: Bool {
        settings.fullscreen.isMiniPlayerSpectrumEnabled && playerVM.currentTrack != nil
    }

    private var coverBlurBaseBlendMode: BlendMode {
        guard isCoverBlurFullscreenSkin else { return .normal }
        guard lyricsController.coverBlurTheme?.trackID == playerVM.currentTrack?.id else { return .normal }
        switch lyricsController.coverBlurTheme?.profile {
        case .lighter:
            return .plusLighter
        case .darker:
            return .plusDarker
        case .none:
            return .normal
        }
    }

    private var coverBlurHighlightBlendMode: BlendMode {
        guard shouldRenderCoverBlurHighlightOverlay else { return .normal }
        switch lyricsController.coverBlurTheme?.profile {
        case .lighter:
            return .normal
        case .darker:
            return .plusDarker
        case .none:
            return .normal
        }
    }

    private var effectiveFullscreenAppearance: AppSettings.ManualAppearance {
        if settings.followSystemAppearance {
            return colorScheme == .dark ? .dark : .light
        }
        return settings.manualAppearance
    }

    private var fullscreenLyricsConfigSignature: String {
        [
            settings.fullscreenLyricsFontNameZh,
            settings.fullscreenLyricsFontNameEn,
            settings.fullscreenLyricsTranslationFontName,
            String(format: "%.2f", settings.fullscreenLyricsFontSize),
            String(format: "%.2f", settings.fullscreenLyricsTranslationFontSize),
            String(settings.fullscreenLyricsFontWeight),
            String(settings.fullscreenLyricsTranslationFontWeight),
            String(format: "%.0f", settings.lyricsLeadInMs),
            String(format: "%.0f", settings.lyricsNearSwitchGapMs),
            String(format: "%.0f", settings.lyricsGlobalAdvanceMs),
        ].joined(separator: "|")
    }

    private func setupSeekCallback() {
        fullscreenStore.onUserSeek = { seconds in
            playerVM.seek(to: seconds)
        }
    }

    private func isLedEnabledForFullscreenSkin() -> Bool {
        guard settings.fullscreen.isSkinVisualizerEnabled else { return false }

        return SkinContextFactory.isLedEnabled(
            skinID: settings.fullscreen.skinID,
            isFullscreen: true
        )
    }

    private func cycleFullscreenAppearance(to target: AppSettings.ManualAppearance) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            if settings.followSystemAppearance {
                settings.followSystemAppearance = false
            }
            settings.manualAppearance = target
        }
        applyFullscreenAppearanceToAllWindows()
    }

    private func nextFullscreenAppearanceTarget() -> AppSettings.ManualAppearance {
        effectiveFullscreenAppearance == .dark ? .light : .dark
    }

    private func applyFullscreenAppearanceToAllWindows() {
        if settings.followSystemAppearance {
            NSApp.appearance = nil
            for window in NSApp.windows {
                window.appearance = nil
            }
            return
        }

        let appearanceName: NSAppearance.Name = settings.manualAppearance == .dark ? .darkAqua : .aqua
        let appearance = NSAppearance(named: appearanceName)
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    private func handleLyricsButtonTap() {
        let nextState: RightPanelDisplayState
        switch rightPanelDisplayState {
        case .queue:
            nextState = .lyrics
        case .lyrics:
            nextState = .hidden
        case .hidden:
            nextState = .lyrics
        }
        setRightPanelDisplayState(nextState)
    }

    private func handlePlaybackModeChange(_ tappedMode: PlaybackOrderMode) {
        applyPlaybackMode(tappedMode)
    }

    private func handleCurrentPlaybackModeRetap(_ currentMode: PlaybackOrderMode) {
        guard currentMode == currentPlaybackMode else { return }

        let nextState: RightPanelDisplayState
        switch rightPanelDisplayState {
        case .lyrics:
            nextState = .queue
        case .queue:
            nextState = .lyrics
        case .hidden:
            nextState = .queue
        }
        setRightPanelDisplayState(nextState)
    }

    private func setRightPanelDisplayState(_ newState: RightPanelDisplayState) {
        if newState == .lyrics, playerVM.currentTrack != nil {
            lyricsController.prepareForShowingLyrics(hasTrack: true)
        }

        withAnimation(lyricsLayoutAnimation) {
            rightPanelDisplayState = newState
        }
    }

    private func applyPlaybackMode(_ mode: PlaybackOrderMode) {
        let shuffleEnabled = mode == .shuffle
        settings.repeatMode = mode == .repeatOne ? "one" : "off"
        settings.stopAfterTrack = mode == .stopAfterTrack
        playerVM.setShuffleEnabled(shuffleEnabled)
    }

    private func handleQueueTrackTap(_ track: Track) {
        playerVM.playTrackFromQueue(track)
    }

    private func handleCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        LyricsSurfaceManager.shared.updatePlaybackTime(newTime)
        fullscreenStore.setCurrentTime(newTime)
        if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
            coverBlurHighlightStore.setCurrentTime(newTime)
        }

        if oldTime > 1.0, newTime < 0.2 {
            reloadLyricsSurface(reason: "fullscreen playback restarted")
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }

        artworkSnapshot = nil
        syncFullscreenMiniPlayerSpectrumLease()
        handleFullscreenArtBackgroundChange(reason: "fullscreen track changed")
        lyricsController.syncHostMount(
            isShowingLyricsPanel: isShowingLyricsPanel,
            currentTrackID: newId,
            reduceMotion: reduceMotion
        )
        reloadLyricsSurface(reason: "fullscreen track changed")
    }

    private func handleFullscreenArtBackgroundChange(reason: String) {
        if isFullscreenArtBackgroundActive {
            seedFullscreenArtBackgroundControllerFromWindowMode()
            if markFullscreenArtBackgroundPresentationIfNeeded() == false {
                bkController.triggerTransition()
            }
        } else {
            hasPresentedFullscreenArtBackground = false
        }

        lyricsController.resetBackgroundSnapshot()
        lyricsController.scheduleBackgroundCapture(
            isArtBackgroundActive: isFullscreenArtBackgroundActive,
            currentTrackID: playerVM.currentTrack?.id
        )
        applyFullscreenLyricsTheme(force: true, reason: reason)
    }

    private func seedFullscreenArtBackgroundControllerFromWindowMode() {
        guard let windowedArtBackgroundController else { return }
        bkController.seedPresentationState(
            from: windowedArtBackgroundController,
            for: playerVM.currentTrack?.id
        )
    }

    @discardableResult
    private func markFullscreenArtBackgroundPresentationIfNeeded() -> Bool {
        guard isFullscreenArtBackgroundActive else {
            hasPresentedFullscreenArtBackground = false
            return false
        }

        let isFirstPresentation = !hasPresentedFullscreenArtBackground
        if isFirstPresentation {
            hasPresentedFullscreenArtBackground = true
        }
        return isFirstPresentation
    }

    private func syncFullscreenMiniPlayerSpectrumLease() {
        let shouldKeepAlive = shouldKeepFullscreenMiniPlayerSpectrumAlive
        guard shouldKeepAlive != isFullscreenMiniPlayerSpectrumLeaseActive else {
            if shouldKeepAlive {
                miniPlayerSpectrumService.updatePlaybackState(isPlaying: playerVM.isPlaying)
            }
            return
        }

        isFullscreenMiniPlayerSpectrumLeaseActive = shouldKeepAlive
        if shouldKeepAlive {
            miniPlayerSpectrumService.start()
            miniPlayerSpectrumService.updatePlaybackState(isPlaying: playerVM.isPlaying)
        } else {
            miniPlayerSpectrumService.stop()
        }
    }

    private func releaseFullscreenMiniPlayerSpectrumLease() {
        guard isFullscreenMiniPlayerSpectrumLeaseActive else { return }
        isFullscreenMiniPlayerSpectrumLeaseActive = false
        miniPlayerSpectrumService.stop()
    }

    private func reloadLyricsSurface(
        reason: String,
        forceWebReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false
    ) {
        syncCoverBlurHighlightActivation()

        let store = fullscreenStore
        if forceWebReload {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }

        let track = playerVM.currentTrack
        let lyricsText = resolvedFullscreenLyricsText(for: track)
        let ttmlForStore: String? = track == nil ? nil : lyricsText
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: track?.id,
            lyricsTTML: ttmlForStore ?? "",
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying
        )
        store.applyTrack(
            trackID: track?.id,
            ttml: ttmlForStore,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying
        )

        if let palette = ThemeStore.shared.palette {
            store.applyTheme(palette)
        }

        syncCoverBlurHighlightSurface(
            forceWebReload: forceWebReload,
            recreateWebViewOnForceReload: recreateWebViewOnForceReload
        )
        if !lyricsController.pendingBackgroundCapture {
            captureFullscreenLyricsBackgroundSnapshot()
        }
        applyFullscreenLyricsTheme()
    }

    private func resolvedFullscreenLyricsText(for track: Track?) -> String {
        guard let track else { return "" }

        let userText = track.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !userText.isEmpty, let original = track.lyricsText {
            return original
        }

        let ttmlText = track.ttmlLyricText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ttmlText.isEmpty, let original = track.ttmlLyricText {
            return original
        }

        return ""
    }

    private func activateCoverBlurHighlightSurface() {
        LyricsSurfaceManager.shared.activate(role: .fullscreenCoverBlurHighlight)
    }

    private func deactivateCoverBlurHighlightSurface() {
        LyricsSurfaceManager.shared.deactivate(role: .fullscreenCoverBlurHighlight)
    }

    private func syncCoverBlurHighlightActivation() {
        if shouldRenderCoverBlurHighlightOverlay {
            activateCoverBlurHighlightSurface()
        } else {
            deactivateCoverBlurHighlightSurface()
        }
    }

    private func syncCoverBlurHighlightSurface(
        forceWebReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false
    ) {
        guard shouldRenderCoverBlurHighlightOverlay else { return }

        let store = coverBlurHighlightStore
        if forceWebReload {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }

        if let palette = ThemeStore.shared.palette {
            store.applyTheme(palette)
        }

        let track = playerVM.currentTrack
        let lyricsText = resolvedFullscreenLyricsText(for: track)
        let ttmlForStore: String? = track == nil ? nil : lyricsText
        store.applyTrack(
            trackID: track?.id,
            ttml: ttmlForStore,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying
        )
    }
    private var fullscreenLyricsHostOpacity: Double {
        lyricsController.hostOpacity(
            isShowingLyricsPanel: isShowingLyricsPanel,
            currentTrackID: playerVM.currentTrack?.id,
            coverBlurThemeReady: !isCoverBlurFullscreenSkin
                || lyricsController.coverBlurTheme?.trackID == playerVM.currentTrack?.id
        )
    }

    private var shouldKeepFullscreenLyricsHostMounted: Bool {
        lyricsController.shouldKeepHostMounted(currentTrackID: playerVM.currentTrack?.id)
    }

    private var isFullscreenLyricsHostVisible: Bool {
        fullscreenLyricsHostOpacity > 0.001
    }

    private var fullscreenLyricsViewportOpacity: Double {
        lyricsController.viewportOpacity(
            currentTrackID: playerVM.currentTrack?.id,
            coverBlurThemeReady: !isCoverBlurFullscreenSkin
                || lyricsController.coverBlurTheme?.trackID == playerVM.currentTrack?.id
        )
    }

    private func applyFullscreenLyricsTheme(force: Bool = false, reason: String = "") {
        let baseStore = fullscreenStore
        let surfaceRole = LyricsSurfaceRole.fullscreen
        let currentTrack = playerVM.currentTrack
        let readyCoverBlurTheme = isCoverBlurFullscreenSkin
            ? lyricsThemeEngine.updateCoverBlurLyricsThemeIfReady(
                for: currentTrack,
                currentTheme: lyricsController.coverBlurTheme,
                artworkSnapshot: artworkSnapshot
            )
            : nil
        if let readyCoverBlurTheme {
            let previousTrackID = lyricsController.coverBlurTheme?.trackID
            let previousProfile = lyricsController.coverBlurTheme?.profile
            let previousLightness = lyricsController.coverBlurTheme?.themeLightness ?? -1
            let themeChanged = previousTrackID != readyCoverBlurTheme.trackID
                || previousProfile != readyCoverBlurTheme.profile
                || abs(previousLightness - readyCoverBlurTheme.themeLightness) > 0.000_1

            if themeChanged {
                lyricsController.coverBlurTheme = readyCoverBlurTheme
            }
        }
        let heldCoverBlurTheme = lyricsController.coverBlurTheme
        let activeCoverBlurTheme: FullscreenCoverBlurLyricsTheme? = {
            guard isCoverBlurFullscreenSkin else { return nil }
            if let readyCoverBlurTheme {
                return readyCoverBlurTheme
            }
            guard heldCoverBlurTheme?.trackID == currentTrack?.id else {
                return nil
            }
            return heldCoverBlurTheme
        }()
        let colorSet = activeCoverBlurTheme?.colors
            ?? lyricsThemeEngine.makeFullscreenLyricsColorSet(
                for: currentTrack,
                artworkSnapshot: artworkSnapshot,
                colorScheme: colorScheme,
                lockedBackgroundColor: lyricsController.lockedBackgroundColor,
                lockedUltraDark: lyricsController.lockedUltraDark,
                pendingBackgroundCapture: lyricsController.pendingBackgroundCapture,
                bkPrimaryBackgroundColor: bkController.primaryBackgroundColor,
                bkSurfaceBackgroundColor: bkController.currentSurfaceBackgroundColor,
                bkLyricsColorTrackID: bkController.lyricsColorTrackID,
                artBackgroundEnabled: isFullscreenArtBackgroundActive
            )

        if isCoverBlurFullscreenSkin, readyCoverBlurTheme == nil {
            if activeCoverBlurTheme == nil {
                LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(nil, for: .fullscreen)
                baseStore.setThemePaletteOverride(nil)
                deactivateCoverBlurHighlightSurface()
                if let highlightStore = existingCoverBlurHighlightStore {
                    LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                        nil,
                        for: .fullscreenCoverBlurHighlight
                    )
                    highlightStore.setThemePaletteOverride(nil)
                }
                return
            }
        }

        let activePalette = activeCoverBlurTheme.map {
            lyricsThemeEngine.makeCoverBlurLyricsPalette(from: $0)
        } ?? lyricsThemeEngine.makeFullscreenLyricsPalette(from: colorSet)
        LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(activePalette, for: .fullscreen)
        baseStore.setThemePaletteOverride(activePalette)
        if shouldRenderCoverBlurHighlightOverlay, let highlightStore = existingCoverBlurHighlightStore {
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                activePalette,
                for: .fullscreenCoverBlurHighlight
            )
            highlightStore.setThemePaletteOverride(activePalette)
        }
        var config = lyricsThemeEngine.buildFullscreenLyricsConfig(
            surfaceRole: surfaceRole,
            settings: settings,
            currentTrack: currentTrack,
            colorSet: colorSet,
            activeCoverBlurTheme: activeCoverBlurTheme,
            isCoverBlurFullscreenSkin: isCoverBlurFullscreenSkin,
            currentFullscreenScale: currentFullscreenScale,
            isFullscreenBottomControlsVisible: bottomControlsController.isVisible
        )

        let shouldUseHighlightOverlay = shouldRenderCoverBlurHighlightOverlay
        if shouldUseHighlightOverlay {
            activateCoverBlurHighlightSurface()
            syncCoverBlurHighlightSurface()
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                activePalette,
                for: .fullscreenCoverBlurHighlight
            )
            coverBlurHighlightStore.setThemePaletteOverride(activePalette)
        } else {
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                nil,
                for: .fullscreenCoverBlurHighlight
            )
            deactivateCoverBlurHighlightSurface()
        }

        let probeMode = activeCoverBlurTheme?.profile.rawValue
            ?? (isCoverBlurFullscreenSkin ? "coverBlurPending" : "generic")
        let probeReason = reason.isEmpty ? "config" : reason
        let probeDelay: TimeInterval
        if isCoverBlurFullscreenSkin {
            probeDelay = activeCoverBlurTheme == nil ? 1.1 : 2.25
        } else {
            probeDelay = 0.9
        }

        var baseConfig = config
        if shouldUseHighlightOverlay {
            baseConfig["coverBlurSuppressEmphasisGlow"] = true
        }
        lyricsThemeEngine.pushFullscreenLyricsConfig(
            baseConfig,
            to: baseStore,
            force: force,
            reason: reason,
            probeLabel: "fullscreen-\(probeMode)-base-\(probeReason)",
            probeDelay: probeDelay
        )

        guard shouldUseHighlightOverlay else { return }

        config["coverBlurSuppressEmphasisGlow"] = false
        lyricsThemeEngine.pushFullscreenLyricsConfig(
            config,
            to: coverBlurHighlightStore,
            force: force,
            reason: reason,
            probeLabel: "fullscreen-\(probeMode)-highlight-\(probeReason)",
            probeDelay: probeDelay
        )
    }

    private func clearFullscreenLyricsTheme() {
        LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(nil, for: .fullscreen)
        existingFullscreenStore?.setThemePaletteOverride(nil)
        if let highlightStore = existingCoverBlurHighlightStore {
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                nil,
                for: .fullscreenCoverBlurHighlight
            )
            highlightStore.setThemePaletteOverride(nil)
        }
    }

    private func captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: Bool = false) {
        lyricsController.captureBackgroundSnapshot(
            isArtBackgroundActive: isFullscreenArtBackgroundActive,
            currentTrackID: playerVM.currentTrack?.id,
            bkLyricsColorTrackID: bkController.lyricsColorTrackID,
            primaryBackgroundColor: bkController.primaryBackgroundColor,
            surfaceBackgroundColor: bkController.currentSurfaceBackgroundColor,
            isUltraDarkActive: bkController.isUltraDarkActive,
            preferLiveSurface: preferLiveSurface
        )
    }

    private func forceRefreshFullscreenLyricsColors(reason: String) {
        lyricsController.forceRefreshColors(
            reason: reason,
            captureSnapshot: captureFullscreenLyricsBackgroundSnapshot,
            applyTheme: applyFullscreenLyricsTheme
        )
    }

    private func makeContext(windowSize: CGSize, artworkColumnWidth: CGFloat, fullscreenScale: CGFloat = 1.0) -> SkinContext {
        let contentBounds = CGRect(
            origin: .zero,
            size: CGSize(width: artworkColumnWidth, height: windowSize.height * 0.62)
        )

        return SkinContextFactory.makeContext(
            track: playerVM.currentTrack,
            artworkSnapshot: artworkSnapshot,
            isPlaying: playerVM.isPlaying,
            currentTime: playerVM.currentTime,
            duration: playerVM.duration,
            ledMeterProvider: ledMeterProvider,
            accentColor: themeStore.accentColor,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: fullscreenScale,
            lyricsVisible: isShowingRightPanel,
            artBackgroundActive: isFullscreenArtBackgroundActive,
            visualizerMode: FullscreenPresentationCoordinator.shared.visualizerMode,
            audioSpectrumProvider: AudioVisualizationService.shared
        )
    }

    private var currentArtworkTaskKey: String {
        guard let track = playerVM.currentTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: track.artworkData)
        return "\(track.id.uuidString)-\(checksum)-px:\(preferredArtworkFullImageMaxPixel)"
    }
    
    private func loadArtworkSnapshot() async {
        let taskKey = currentArtworkTaskKey
        artworkSnapshot = await FullscreenArtworkLoader.loadSnapshot(
            track: playerVM.currentTrack,
            currentTaskKey: taskKey,
            preferredFullImageMaxPixel: preferredArtworkFullImageMaxPixel,
            currentTrackID: { playerVM.currentTrack?.id },
            currentTaskKeyProvider: { currentArtworkTaskKey }
        )
        guard artworkSnapshot != nil else { return }

        applyFullscreenLyricsTheme(reason: "artworkSnapshot-loaded")
    }

    private var preferredArtworkFullImageMaxPixel: Int {
        1_400
    }
}

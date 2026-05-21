//
//  FullscreenPlayerView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Player View
//  Fullscreen mode with enlarged skin, lyrics (overlay on background), and controls.
//

import AppKit
import Foundation
import SwiftUI

/// Reusable fullscreen-player content view with enlarged skin artwork (left),
/// AMLL lyrics (right, no material), and enlarged miniplayer controls at bottom.
/// The same content can be hosted in a system fullscreen space or embedded in the main window.
@MainActor
struct FullscreenPlayerView: View {
    enum HostContext: String {
        case systemFullscreenSpace = "system-fullscreen-space"
        case embeddedWindow = "embedded-window"
    }

    // MARK: - Fullscreen Base Canvas Constants
    // Base canvas size: 1470 x 923 is the reference design
    // The entire canvas is scaled as one unit using scaleEffect
    private static let baseCanvasWidth: CGFloat = 1470
    private static let baseCanvasHeight: CGFloat = 923
    private static let fallbackExternalTrackID = UUID(
        uuidString: "E4D3575E-97CA-41EF-8322-FC3D845E7F28"
    )!

    private typealias FullscreenLyricsColorSet = LyricsSurfaceColorSet
    private typealias FullscreenCoverBlurBlendProfile = LyricsCoverBlurBlendProfile

    private struct FullscreenCoverBlurLyricsTheme {
        let trackID: UUID
        let themeColor: NSColor
        let themeLightness: CGFloat
        let profile: FullscreenCoverBlurBlendProfile
        let colors: FullscreenLyricsColorSet
    }

    private struct FullscreenLyricsThemeIdentity: Equatable {
        let source: PlaybackSource
        let displayTrackID: UUID?
        let artworkTrackID: UUID?
        let artworkSignature: String
        let themeGeneration: UInt64
        let hostContext: HostContext
    }

    private enum FullscreenCoverBlurRenderLayer: String {
        case base
        case highlight
    }

    private enum FeatureTips {
        static let playbackModeRetapKey = "fullscreen.playbackModeRetap"
        static let playbackModeRetapIntroducedVersion = AppVersion(major: 2, minor: 0, patch: 0)
        static let playbackModeRetapMaxDisplayCount = 2
    }

    private enum RightPanelDisplayState {
        case hidden
        case lyrics
        case queue
    }

    private let topContentHorizontalPadding: CGFloat = 0
    private let lyricsViewportTopLift: CGFloat = 22
    private let fullscreenBackgroundLyricsAvoidanceHorizontalInset: CGFloat = 28
    private let fullscreenBackgroundLyricsAvoidanceTopInset: CGFloat = 36
    private let fullscreenBackgroundLyricsAvoidanceBottomInset: CGFloat = 60
    private let fullscreenLyricsAlignPosition: Double = 0.18  // Current line higher in viewport (was 0.28)
    private let coverBlurLegacyTopContentLeftShift: CGFloat = 44
    private let coverBlurLegacyArtworkLyricsColumnSpacing: CGFloat = -58
    private let coverBlurLegacyLyricsColumnLeftNudge: CGFloat = 80
    private let coverBlurLegacyLyricsRightShift: CGFloat = 30
    private let coverBlurLegacyLeftExpansion: CGFloat = 80

    private struct FullscreenHorizontalSplitLayout {
        let artworkWidth: CGFloat
        let lyricsWidth: CGFloat
        let safeGap: CGFloat
        let artworkLeadingX: CGFloat
        let lyricsLeadingX: CGFloat

        private static let baseCanvasWidth: CGFloat = 1470
        private static let sideInset: CGFloat = 24
        private static let rightReserve: CGFloat = 88
        private static let artworkIdealRatio: CGFloat = 0.54
        private static let artworkMinWidth: CGFloat = 360
        private static let artworkIdealMinWidth: CGFloat = 540
        private static let artworkMaxRatio: CGFloat = 0.65
        private static let lyricsIdealRatio: CGFloat = 0.34
        private static let lyricsIdealMinWidth: CGFloat = 420
        private static let lyricsMinReadableWidth: CGFloat = 340
        private static let lyricsMaxRatio: CGFloat = 0.52
        private static let safeGapRatio: CGFloat = 0.024
        private static let safeGapMin: CGFloat = 12
        private static let safeGapFloor: CGFloat = 4
        private static let artworkVisualTrimWhenLyricsVisible: CGFloat = 32

        static func resolve(
            showLyricsColumn: Bool,
            windowWidth: CGFloat? = nil
        ) -> FullscreenHorizontalSplitLayout {
            let canvasWidth = max(0, windowWidth ?? baseCanvasWidth)
            let availableWidth = max(0, canvasWidth - sideInset * 2 - rightReserve)

            if !showLyricsColumn {
                let centeredAvailableWidth = max(0, canvasWidth - sideInset * 2)
                let artworkWidth = min(
                    max(centeredAvailableWidth * 0.78, lyricsIdealMinWidth),
                    centeredAvailableWidth
                )
                let artworkLeadingX = sideInset + max(0, (centeredAvailableWidth - artworkWidth) * 0.5)
                return FullscreenHorizontalSplitLayout(
                    artworkWidth: artworkWidth,
                    lyricsWidth: 0,
                    safeGap: 0,
                    artworkLeadingX: artworkLeadingX,
                    lyricsLeadingX: artworkLeadingX + artworkWidth
                )
            }

            let maxArtworkWidth = max(artworkMinWidth, availableWidth * artworkMaxRatio)
            let maxLyricsWidth = max(
                lyricsMinReadableWidth,
                availableWidth * lyricsMaxRatio
            )
            var artworkWidth = min(
                max(availableWidth * artworkIdealRatio, artworkIdealMinWidth),
                maxArtworkWidth
            )
            var lyricsWidth = min(
                max(availableWidth * lyricsIdealRatio, lyricsIdealMinWidth),
                maxLyricsWidth
            )
            var safeGap = max(safeGapMin, availableWidth * safeGapRatio)

            var overflow = artworkWidth + safeGap + lyricsWidth - availableWidth
            if overflow > 0 {
                let gapShrink = min(overflow, safeGap - safeGapFloor)
                safeGap -= gapShrink
                overflow -= gapShrink
            }
            if overflow > 0 {
                let artworkShrink = min(overflow, artworkWidth - artworkMinWidth)
                artworkWidth -= artworkShrink
                overflow -= artworkShrink
            }
            if overflow > 0 {
                let lyricsShrink = min(overflow, lyricsWidth - lyricsMinReadableWidth)
                lyricsWidth -= lyricsShrink
                overflow -= lyricsShrink
            }
            if overflow > 0 {
                artworkWidth = max(artworkMinWidth, artworkWidth - overflow)
            }

            var remaining = availableWidth - (artworkWidth + safeGap + lyricsWidth)
            if remaining > 0 {
                let artworkGrowth = min(remaining * 0.40, maxArtworkWidth - artworkWidth)
                artworkWidth += artworkGrowth
                remaining -= artworkGrowth
            }
            if remaining > 0 {
                let lyricsGrowth = min(remaining * 0.60, maxLyricsWidth - lyricsWidth)
                lyricsWidth += lyricsGrowth
                remaining -= lyricsGrowth
            }

            let effectiveArtworkZoneWidth = max(
                artworkMinWidth,
                artworkWidth - artworkVisualTrimWhenLyricsVisible
            )
            let groupWidth = effectiveArtworkZoneWidth + safeGap + lyricsWidth
            let outerSlack = max(0, availableWidth - groupWidth)
            let wideWindowLeftBias = outerSlack > 1 ? min(196, 36 + outerSlack * 0.60) : 0
            let artworkLeadingX = max(
                0,
                sideInset + outerSlack * 0.5 - wideWindowLeftBias
            )
            let lyricsLeadingX = artworkLeadingX + effectiveArtworkZoneWidth + safeGap

            return FullscreenHorizontalSplitLayout(
                artworkWidth: artworkWidth,
                lyricsWidth: lyricsWidth,
                safeGap: safeGap,
                artworkLeadingX: artworkLeadingX,
                lyricsLeadingX: lyricsLeadingX
            )
        }
    }

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var themeStore: ThemeStore
    private let miniPlayerSpectrumService = AudioVisualizationService.shared
    @StateObject private var bkController = BKArtBackgroundController()
    @State private var skinRevision = 0
    @State private var rightPanelDisplayState: RightPanelDisplayState = .lyrics
    @State private var lockedFullscreenLyricsBackgroundColor: NSColor?
    @State private var lockedFullscreenLyricsUltraDark: Bool = false
    @State private var pendingFullscreenLyricsBackgroundCapture: Bool = false
    @State private var pendingFullscreenLyricsRefresh: DispatchWorkItem?
    @State private var pendingFullscreenLyricsReveal: DispatchWorkItem?
    @State private var pendingFullscreenLyricsHostDetach: DispatchWorkItem?
    @State private var pendingFullscreenTrackRefresh: DispatchWorkItem?
    @State private var pendingFullscreenThemeReapply: DispatchWorkItem?
    @State private var artworkSnapshot: ArtworkAssetSnapshot?
    @State private var coverBlurLyricsTheme: FullscreenCoverBlurLyricsTheme?
    @State private var deferredTrackUpdateDeadline: Date?
    @State private var autoHiddenFullscreenLyricsForEmptyContent = false
    @State private var suppressFullscreenLyricsViewport = false
    @State private var fullscreenLyricsHostMounted = false
    @State private var isLeftActionsExpanded = false
    @State private var isQuickAppearancePanelPresented = false
    @State private var currentFullscreenScale: CGFloat = 1.0
    @State private var fullscreenViewportSize: CGSize = .zero
    @State private var embeddedInitialThemeUnlocked = false
    @State private var didHandleFullscreenAppear = false
    @State private var isFullscreenMiniPlayerSpectrumLeaseActive = false
    @State private var isFullscreenBottomControlsVisible = true
    @State private var isFullscreenBottomControlsHovered = false
    @State private var isFullscreenBottomControlsHotZoneHovered = false
    @State private var isFullscreenBottomControlsAppearancePanelHovered = false
    @State private var isFullscreenBottomControlsLeadingHovered = false
    @State private var isFullscreenBottomControlsCenterHovered = false
    @State private var isFullscreenBottomControlsTrailingHovered = false
    @State private var isFullscreenBottomControlsProgressDragging = false
    @State private var isFullscreenBottomControlsVolumeAdjusting = false
    @State private var isPointerOverMiniPlayerOcclusion = false
    @State private var trackToEdit: Track?
    @State private var isShowingExternalMatchEditor = false
    @State private var showPlaybackModeRetapTip = false
    @State private var pendingFullscreenBottomControlsHideTask: Task<Void, Never>?
    @State private var pendingLeftActionsCollapseTask: Task<Void, Never>?
    @State private var pendingVolumeCollapseTask: Task<Void, Never>?
    @State private var fullscreenPointerOcclusionMonitor = FullscreenPointerOcclusionMonitor()
    @Namespace private var fullscreenLayoutNamespace

    // Fullscreen per-skin visualizer mode keys — observed for reactive LED service
    // lifecycle (start/stop sampling when the user toggles LED in settings).
    @AppStorage("skin.classicLED.fullscreen.visualizerMode") private var classicLedFullscreenMode: String = "led"
    @AppStorage("skin.appleStyle.fullscreen.visualizerMode") private var appleStyleFullscreenMode: String = "led"
    @AppStorage("skin.rotatingCover.fullscreen.visualizerMode") private var rotatingCoverLedFullscreenMode: String = "led"
    @AppStorage("skin.kmgcccCassette.fullscreen.visualizerMode") private var cassetteLedFullscreenMode: String = "off"

    let hostContext: HostContext
    let onExitFullscreen: (() -> Void)?

    init(
        hostContext: HostContext = .systemFullscreenSpace,
        onExitFullscreen: (() -> Void)? = nil
    ) {
        self.hostContext = hostContext
        self.onExitFullscreen = onExitFullscreen
    }

    private var isCoverBlurFullscreenSkin: Bool {
        settings.fullscreen.skinID == "fullscreen.coverGradientBlur"
    }

    private var isAppleStyleFullscreenSkin: Bool {
        settings.fullscreen.skinID == AppleStyleSkin.skinID
    }

    private var usesCoverBlurLyricsRenderingPath: Bool {
        isCoverBlurFullscreenSkin || isAppleStyleFullscreenSkin
    }

    private var fullscreenSkinUsesCustomBackground: Bool {
        isCoverBlurFullscreenSkin || isAppleStyleFullscreenSkin
    }

    /// Cover-element skins (classic, rotating, cassette) get a slight vertical
    /// drop when the fullscreen miniplayer auto-hides, and return when it reappears.
    private var isCoverSkinWithMiniplayerMotion: Bool {
        let id = settings.fullscreen.skinID
        return id == "coverLed" || id == AppleStyleSkin.skinID || id == "rotatingCover" || id == "kmgccc.cassette"
    }

    private var fullscreenLedServiceSignature: String {
        [
            settings.fullscreen.skinID,
            classicLedFullscreenMode,
            appleStyleFullscreenMode,
            rotatingCoverLedFullscreenMode,
            cassetteLedFullscreenMode,
        ].joined(separator: "|")
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

    private var currentDisplayContext: NowPlayingDisplayContext {
        playbackCoordinator.presentation.displayContext
    }

    private var currentArtworkTrackID: UUID? {
        currentDisplayContext.artworkTrackID
    }

    private var currentFullscreenLyricsThemeIdentity: FullscreenLyricsThemeIdentity {
        let display = currentDisplayContext
        let artworkChecksum = ArtworkAssetStore.checksum(for: display.artworkData)
        let artworkSignature = [
            display.artworkIdentity ?? "nil",
            display.lyricsIdentity ?? "nil",
            "\(artworkChecksum)",
            "\(display.isArtworkLoading ? 1 : 0)",
        ].joined(separator: "|")
        return FullscreenLyricsThemeIdentity(
            source: display.source,
            displayTrackID: display.trackID,
            artworkTrackID: display.artworkTrackID,
            artworkSignature: artworkSignature,
            themeGeneration: themeStore.themeGeneration,
            hostContext: hostContext
        )
    }

    private func isCurrentFullscreenLyricsThemeIdentity(
        _ identity: FullscreenLyricsThemeIdentity
    ) -> Bool {
        currentFullscreenLyricsThemeIdentity == identity
    }

    private var shouldRenderCoverBlurHighlightOverlay: Bool {
        // A second AMLL surface introduces timing drift and visible ghosting.
        // Keep cover-blur fullscreen on a single AMLL surface only.
        false
    }

    private var allowsDirectEmbeddedSurfaceUpdates: Bool {
        hostContext != .embeddedWindow || embeddedInitialThemeUnlocked
    }

    /// Effective dimming intensity adjusted for color scheme.
    /// Light mode requires stronger dimming for readability.
    private var effectiveDimmingIntensity: Double {
        let base = settings.fullscreenDimmingIntensity
        if colorScheme == .light {
            // Light mode: increase dimming by ~40% for better contrast
            return min(0.55, base * 1.40)
        }
        return base
    }

    var body: some View {
        GeometryReader { proxy in
            fullscreenContent(for: proxy)
        }
        .background(
            WindowToolbarAccessor(
                configure: { window in
                    fullscreenPointerOcclusionMonitor.setWindow(window)
                    if hostContext == .embeddedWindow {
                        let contentSize = window.contentLayoutRect.size
                        if contentSize.width > 1, contentSize.height > 1 {
                            DispatchQueue.main.async {
                                handleEmbeddedFullscreenViewportChange(
                                    contentSize,
                                    reason: "embedded-window-content-layout"
                                )
                            }
                        }
                    }
                },
                configureContinuously: true
            )
        )
        .contentShape(Rectangle())
        .contextMenu(menuItems: fullscreenContextMenu)
        .sheet(item: $trackToEdit, content: trackEditSheet)
        .sheet(isPresented: $isShowingExternalMatchEditor, content: externalMatchEditorSheet)
        .onAppear(perform: handleFullscreenAppear)
        .onDisappear(perform: handleFullscreenDisappear)
        .onChange(of: settings.fullscreen.skinID) { oldValue, newValue in
            skinRevision &+= 1
            if oldValue == "kmgccc.cassette", newValue != oldValue {
                Task {
                    await CassetteArtworkCache.shared.removeAll()
                }
            }
            let coverBlurTransition = oldValue == "fullscreen.coverGradientBlur"
                || newValue == "fullscreen.coverGradientBlur"
            syncCoverBlurHighlightActivation()
            if coverBlurTransition {
                reloadLyricsSurface(reason: "fullscreen skin changed", forceLyricsReload: true)
            } else {
                applyFullscreenLyricsTheme(force: true, reason: "fullscreen skin changed")
            }
        }
        .onChange(of: fullscreenLedServiceSignature) { _, _ in
            syncFullscreenLedService()
        }
        .onChange(of: settings.fullscreen.isMiniPlayerSpectrumEnabled) { _, _ in
            syncFullscreenMiniPlayerSpectrumLease()
        }
        .onChange(of: playerVM.currentTime, handleCurrentTimeChange)
        .onChange(of: playerVM.isPlaying) { _, newValue in
            guard playbackCoordinator.presentation.source == .local else { return }
            LyricsSurfaceManager.shared.updatePlayingState(newValue)
            guard allowsDirectEmbeddedSurfaceUpdates else { return }
            fullscreenStore.setPlaying(newValue)
            if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
                coverBlurHighlightStore.setPlaying(newValue)
            }
            if isFullscreenMiniPlayerSpectrumLeaseActive {
                miniPlayerSpectrumService.updatePlaybackState(isPlaying: newValue)
            }
        }
        .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
        .onChange(of: playbackCoordinator.presentation.currentTime, handlePresentationCurrentTimeChange)
        .onChange(of: playbackCoordinator.presentation.isPlaying) { _, newValue in
            guard playbackCoordinator.presentation.source.isExternal else { return }
            LyricsSurfaceManager.shared.updatePlayingState(newValue)
            guard allowsDirectEmbeddedSurfaceUpdates else { return }
            fullscreenStore.setPlaying(newValue)
            if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
                coverBlurHighlightStore.setPlaying(newValue)
            }
        }
        .onChange(of: playbackCoordinator.presentation.lyricsIdentity, handlePresentationLyricsIdentityChange)
        .onChange(of: playbackCoordinator.presentation.lyricsText) { _, _ in
            guard playbackCoordinator.presentation.hasTrack else { return }
            let reason = playbackCoordinator.presentation.source.isExternal
                ? "fullscreen external lyrics updated"
                : "fullscreen local lyrics hydrated"
            reloadLyricsSurface(reason: reason, forceLyricsReload: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
            handleLibraryTrackDidUpdate(notification)
        }
        .onChange(of: rightPanelDisplayState) { _, newValue in
            handleRightPanelDisplayStateChange(newValue)
        }
        .onChange(of: fullscreenLyricsConfigSignature) { _, _ in
            applyFullscreenLyricsTheme()
        }
        .onChange(of: themeStore.themeGeneration) { _, _ in
            applyFullscreenLyricsTheme(force: true, reason: "theme-generation-change")
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
            guard pendingFullscreenLyricsBackgroundCapture else { return }
            guard bkController.lyricsColorTrackID == currentArtworkTrackID else { return }
            scheduleFullscreenLyricsRefresh(preferLiveSurface: true)
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkSnapshot()
        }
    }

    private func handleFullscreenAppear() {
        guard !didHandleFullscreenAppear else { return }
        didHandleFullscreenAppear = true
        Log.info(
            "FullscreenPlayerView appeared context=\(hostContext.rawValue)",
            category: .webview
        )
        fullscreenPointerOcclusionMonitor.start { isOccluded in
            setPointerOverMiniPlayerOcclusion(isOccluded, reason: "mouse-location")
        }

        syncCoverBlurHighlightActivation()
        resetFullscreenLyricsBackgroundSnapshot()
        scheduleFullscreenLyricsBackgroundCapture()
        fullscreenLyricsHostMounted = isShowingLyricsPanel && playbackCoordinator.presentation.hasTrack
        setupSeekCallback()
        if hostContext == .embeddedWindow {
            embeddedInitialThemeUnlocked = false
        } else {
            startFullscreenLyricsSurface(reason: "fullscreen appear")
        }
        resetFullscreenBottomControlsAutoHideState()
        syncFullscreenMiniPlayerSpectrumLease()
        syncFullscreenLedService()
        showPlaybackModeRetapTipIfNeeded()
    }

    private func handleFullscreenDisappear() {
        let shouldReportFullscreenHidden =
            hostContext != .embeddedWindow || embeddedInitialThemeUnlocked
        Log.info(
            "FullscreenPlayerView disappeared context=\(hostContext.rawValue)",
            category: .webview
        )
        didHandleFullscreenAppear = false
        fullscreenPointerOcclusionMonitor.stop()
        setPointerOverMiniPlayerOcclusion(false, reason: "fullscreen disappear")
        ledMeterProvider.releaseNowPlayingResources()
        artworkSnapshot = nil
        existingFullscreenStore?.onUserSeek = nil
        pendingFullscreenLyricsRefresh?.cancel()
        pendingFullscreenLyricsRefresh = nil
        pendingFullscreenLyricsReveal?.cancel()
        pendingFullscreenLyricsReveal = nil
        pendingFullscreenLyricsHostDetach?.cancel()
        pendingFullscreenLyricsHostDetach = nil
        pendingFullscreenTrackRefresh?.cancel()
        pendingFullscreenTrackRefresh = nil
        pendingFullscreenThemeReapply?.cancel()
        pendingFullscreenThemeReapply = nil
        deferredTrackUpdateDeadline = nil
        suppressFullscreenLyricsViewport = false
        fullscreenLyricsHostMounted = false
        embeddedInitialThemeUnlocked = false
        isQuickAppearancePanelPresented = false
        isFullscreenBottomControlsAppearancePanelHovered = false
        releaseFullscreenMiniPlayerSpectrumLease()
        cancelFullscreenBottomControlsAutoHide()
        cancelFullscreenSideControlCollapses()
        setLeftActionsExpanded(false, reason: "fullscreen-disappear")
        setVolumeExpanded(false, reason: "fullscreen-disappear")
        deactivateCoverBlurHighlightSurface()
        clearFullscreenLyricsTheme()
        Task {
            await ArtworkAssetStore.shared.purgeHydratedImages()
            await CassetteArtworkCache.shared.removeAll()
        }

        if shouldReportFullscreenHidden {
            // Report visibility to manager - manager will debounce to handle transient disappears
            LyricsSurfaceManager.shared.reportFullscreenVisible(false)
        }
    }

    @ViewBuilder
    private func fullscreenContextMenu() -> some View {
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

    private func trackEditSheet(for track: Track) -> some View {
        TrackEditSheet(track: track)
            .environmentObject(themeStore)
    }

    private func externalMatchEditorSheet() -> some View {
        ExternalPlaybackInfoEditorView(
            presentation: playbackCoordinator.presentation,
            onSaved: {
                playbackCoordinator.invalidateExternalPlaybackResolution()
            }
        )
        .environmentObject(themeStore)
    }

    // MARK: - Fullscreen Content (Extracted to simplify body type checking)

    private var fullscreenArtBackgroundSeedPalette: [NSColor] {
        if let snapshot = currentArtworkSnapshotForDisplay() {
            let palette = !snapshot.richPalette.isEmpty ? snapshot.richPalette : snapshot.palette
            if !palette.isEmpty {
                return palette
            }
            if let accent = snapshot.accentColor {
                return [accent]
            }
            if let average = snapshot.averageColor {
                return [average]
            }
            if let dominant = snapshot.dominantColor {
                return [dominant]
            }
        }

        if let snapshot = currentArtworkSnapshot(forTrackID: currentArtworkTrackID) {
            let palette = !snapshot.richPalette.isEmpty ? snapshot.richPalette : snapshot.palette
            if !palette.isEmpty {
                return palette
            }
            if let accent = snapshot.accentColor {
                return [accent]
            }
            if let average = snapshot.averageColor {
                return [average]
            }
            if let dominant = snapshot.dominantColor {
                return [dominant]
            }
        }

        return [themeStore.accentNSColor]
    }

    @ViewBuilder
    private func fullscreenContent(for proxy: GeometryProxy) -> some View {
        let selectedSkin = SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID)
        let scaleX = proxy.size.width / Self.baseCanvasWidth
        let scaleY = proxy.size.height / Self.baseCanvasHeight
        let scale = min(scaleX, scaleY)
        let miniPlayerOcclusionRegion = fullscreenMiniPlayerOcclusionRegion(
            scale: scale,
            screenSize: proxy.size
        )
        let hasRenderableGeometry = isRenderableFullscreenGeometry(proxy.size, scale: scale)

        ZStack {
            if hasRenderableGeometry {
                fullscreenBackgroundLayer(selectedSkin: selectedSkin, scale: scale)

                // Layer 1: AMLL lyrics at actual resolution
                fullscreenLyricsLayer(scale: scale, screenWidth: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // Layer 2: Scaled container for artwork only
                fullscreenScaledContainer(selectedSkin: selectedSkin, scale: scale)
                    .frame(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight)
                    .scaleEffect(scale, anchor: .center)

                // Layer 3: Bottom bar at actual resolution - on top
                fullscreenBottomBarLayer(
                    scale: scale,
                    screenWidth: proxy.size.width,
                    screenHeight: proxy.size.height
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                Color.clear
            }
        }
        .id("fullscreen_\(settings.fullscreen.skinID)_\(skinRevision)")
        .frame(width: proxy.size.width, height: proxy.size.height)
        .onAppear {
            currentFullscreenScale = scale
            fullscreenViewportSize = proxy.size
            updateFullscreenMiniPlayerOcclusionRegion(miniPlayerOcclusionRegion)
            if EmbeddedFullscreenTrace.enabled, hostContext == .embeddedWindow {
                Log.info(
                    "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.appear embedded proxy=\(proxy.size) scale=\(String(format: "%.4f", scale))",
                    category: .fullscreen
                )
            }
            handleEmbeddedFullscreenViewportChange(proxy.size, reason: "embedded-initial-layout")
        }
        .onChange(of: scale) { _, newScale in
            currentFullscreenScale = newScale
            if EmbeddedFullscreenTrace.enabled, hostContext == .embeddedWindow {
                Log.info(
                    "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.scaleChanged embedded scale=\(String(format: "%.4f", newScale))",
                    category: .fullscreen
                )
            }
        }
        .onChange(of: proxy.size) { _, newSize in
            handleEmbeddedFullscreenViewportChange(newSize, reason: "embedded-viewport-size-change")
        }
        .onChange(of: miniPlayerOcclusionRegion) { _, newRegion in
            updateFullscreenMiniPlayerOcclusionRegion(newRegion)
        }
    }

    @ViewBuilder
    private func fullscreenBackgroundLayer(selectedSkin: any NowPlayingSkin, scale: CGFloat) -> some View {
        let context = makeContext(
            windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
            artworkColumnWidth: layoutMetrics.artworkWidth,
            fullscreenScale: scale
        )

        if fullscreenSkinUsesCustomBackground {
            selectedSkin.makeBackground(context: context)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if !isAppleStyleFullscreenSkin {
                Color.black.opacity(effectiveDimmingIntensity * 0.7)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        } else if settings.fullscreenArtBackgroundEnabled && currentDisplayContext.hasTrack {
            BKArtBackgroundView(
                controller: bkController,
                trackID: currentArtworkTrackID,
                artworkData: currentDisplayContext.artworkData,
                isPlaying: currentDisplayContext.isPlaying,
                avoidanceRect: nil,
                resourceProfile: settings.fullscreen.skinID == "kmgccc.cassette"
                    ? .cassetteForeground
                    : .standard,
                dotRenderStyle: .solidCircles,
                initialPalette: fullscreenArtBackgroundSeedPalette
            )
            .ignoresSafeArea()

            Color.black.opacity(effectiveDimmingIntensity)
                .ignoresSafeArea()
        } else {
            selectedSkin.makeBackground(context: context)
                .ignoresSafeArea()

            Color.black.opacity(effectiveDimmingIntensity * 0.7)
                .ignoresSafeArea()
        }
    }

    // MARK: - Fullscreen Scaled Container (Artwork + Controls Only)

    @ViewBuilder
    private func fullscreenScaledContainer(selectedSkin: any NowPlayingSkin, scale: CGFloat) -> some View {
        // Cover-element skins drop slightly when the miniplayer auto-hides
        let coverDropY: CGFloat = isCoverSkinWithMiniplayerMotion && !isFullscreenBottomControlsVisible ? 20 : 0

        ZStack {
            VStack(spacing: 0) {
                artworkAndControlsArea(selectedSkin: selectedSkin, scale: scale)
                    .padding(.horizontal, topContentHorizontalPadding)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .offset(y: coverDropY)
                    .animation(coverDropAnimation, value: isFullscreenBottomControlsVisible)

                Spacer(minLength: fullscreenControlsBottomPadding + fullscreenControlButtonSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Fullscreen Lyrics Layer (Actual Resolution - Crisp)

    private func fullscreenLyricsLayer(scale: CGFloat, screenWidth: CGFloat) -> some View {
        let hostLayout = layoutMetrics(showLyricsColumn: true)
        let lyricsPanelVisible = isShowingLyricsPanel
        let keepLyricsHostMounted = shouldKeepFullscreenLyricsHostMounted

        let baseLyricsLeadingX: CGFloat
        let minReadableLyricsWidth: CGFloat
        if isCoverBlurFullscreenSkin {
            let legacyLayout = coverBlurLegacyLayoutMetrics(showLyricsColumn: true)
            let scaleX = screenWidth / Self.baseCanvasWidth
            let hostBaseContentOffsetX = -coverBlurLegacyTopContentLeftShift
            let hostArtworkColumnCenterX = hostBaseContentOffsetX + legacyLayout.artworkWidth / 2
            let hostArtworkHorizCorrection: CGFloat
            if scale.isFinite, scale > .leastNonzeroMagnitude, scaleX.isFinite {
                hostArtworkHorizCorrection =
                    (hostArtworkColumnCenterX - Self.baseCanvasWidth / 2) * (scaleX - scale) / scale
            } else {
                hostArtworkHorizCorrection = 0
            }
            let hostArtworkX = hostBaseContentOffsetX + hostArtworkHorizCorrection
            let legacyBaseLyricsX =
                hostArtworkX
                + legacyLayout.artworkWidth
                + coverBlurLegacyArtworkLyricsColumnSpacing
                - coverBlurLegacyLyricsColumnLeftNudge
            baseLyricsLeadingX =
                legacyBaseLyricsX
                - coverBlurLegacyLeftExpansion
                + coverBlurLegacyLyricsRightShift
            minReadableLyricsWidth = legacyLayout.lyricsWidth
        } else {
            baseLyricsLeadingX = hostLayout.lyricsLeadingX
            minReadableLyricsWidth = hostLayout.lyricsWidth
        }

        // Canvas horizontal centering margin: on 16:9 screens the canvas is narrower than
        // the screen; add the side margin so the lyrics block stays aligned to the
        // shared artwork+lyrics split, not to the left screen edge.
        let canvasCenteringX = max(0, (screenWidth - Self.baseCanvasWidth * scale) / 2)
        let visibleLyricsX = baseLyricsLeadingX * scale + canvasCenteringX
        let hiddenLyricsX = visibleLyricsX + 92 * scale
        let actualLyricsX = lyricsPanelVisible ? visibleLyricsX : hiddenLyricsX

        // Keep a readable minimum (layout split width), while still letting the right
        // column breathe on wide windows.
        let lyricsRightScreenPad = max(44 * scale, minReadableLyricsWidth * scale * 0.08)
        let layoutWidth = minReadableLyricsWidth * scale
        let fillWidth = screenWidth - visibleLyricsX - lyricsRightScreenPad
        let actualLyricsWidth = max(100, max(layoutWidth, fillWidth))

        // Fixed AMLL frame — always the full base canvas height. AMLL's DOM never resizes
        // during miniplayer hide/show, so setAlignPosition never chases a moving target.
        let actualLyricsHeight = Self.baseCanvasHeight * scale  // 923*scale, constant

        // Visible clip boundary — Swift-only. Animates 851↔923*scale via bottomControlsAnimation.
        // Only the mask window changes; the WebView content space stays stable.
        let visibleBottomReserve: CGFloat = isFullscreenBottomControlsVisible ? fullscreenControlsBottomPadding : 0
        let visibleClipHeight = (Self.baseCanvasHeight - visibleBottomReserve) * scale

        // Debug logging for first layout
        let _ = {
            if keepLyricsHostMounted {
                Log.debug("fullscreenLyricsLayer: scale=\(scale), width=\(actualLyricsWidth), height=\(actualLyricsHeight), visible=\(lyricsPanelVisible)", category: .webview)
            }
        }()

        return ZStack(alignment: .topLeading) {
            if keepLyricsHostMounted {
                fullscreenLyricsCrispView(scale: scale, visibleClipHeight: visibleClipHeight)
                    .frame(width: actualLyricsWidth, height: actualLyricsHeight, alignment: .topLeading)
                    .offset(x: actualLyricsX)
                    .opacity(fullscreenLyricsHostOpacity)
                    .allowsHitTesting(isFullscreenLyricsHostVisible)
                    .accessibilityHidden(!isFullscreenLyricsHostVisible)
            }

            if isShowingQueuePanel {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            setRightPanelDisplayState(.lyrics)
                        }

                    fullscreenQueuePanel(
                        scale: scale,
                        visibleHeight: visibleClipHeight
                    )
                    .padding(.trailing, 118 * scale)
                    .padding(.top, 72 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
                .accessibilityHidden(false)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 92 * scale)),
                    removal: .opacity.combined(with: .offset(x: 92 * scale))
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // REMOVED: .animation(lyricsLayoutAnimation, value: lyricsVisible)
        // The container animation was causing the entire AMLL block to animate in
        // from above, making it look like a falling block. The correct behavior
        // is for AMLL to handle the animation internally via setAlignPosition,
        // keeping the current line fixed while other lines converge.
        .animation(bottomControlsAnimation, value: isFullscreenBottomControlsVisible)  // mask only
        .onChange(of: isFullscreenBottomControlsVisible) { oldValue, newValue in
            // ISSUE 1 FIX: The "jerk" was caused by overlapping animations.
            // Swift-side animates: mask (0.34s spring), scaleEffect (0.34s), artwork position (0.62s)
            // AMLL-side animates: setAlignPosition reposition (internal spring)
            // When these animate simultaneously, they fight each other.
            //
            // ROOT CAUSE: The 0.02s delay sent AMLL config while Swift animation was still
            // in progress (spring response 0.34s, settling ~0.5s). AMLL repositioned during
            // Swift geometry change, causing visible discontinuity.
            //
            // FIX: Hold alignPosition/alignOffset CONSTANT during animation by waiting
            // until after the longest Swift animation settles (lyricsLayoutAnimation = 0.62s).
            // This proves the remaining jerk is AMLL-side timing vs Swift-side timing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                applyFullscreenLyricsTheme(reason: "bottomControlsVisibility-changed")
            }
        }
    }

    @ViewBuilder
    private func fullscreenLyricsCrispView(scale: CGFloat, visibleClipHeight: CGFloat) -> some View {
        GeometryReader { proxy in
            let topFade: CGFloat = 58 * scale
            // Bottom feather shape: controls where the fade-out starts within the visible clip region.
            // Does NOT affect expandedHeight — WebView size is pinned to 420pt overbleed always.
            // visible: larger fade → bottom fade starts higher, giving lyrics breathing room
            //          above the miniplayer bar.
            // hidden:  smaller fade → bottom fade starts lower, revealing more solid content
            //          in the expanded view before the edge softens.
            let baseBottomFadeVisible: CGFloat = 60
            let baseBottomFadeHidden: CGFloat = 380
            let bottomFade = (isFullscreenBottomControlsVisible ? baseBottomFadeVisible : baseBottomFadeHidden) * scale
            let horizontalInset: CGFloat = 10 * scale
            // Fixed expanded height: always allocate the maximum bottom overbleed (420pt) so
            // AMLL's DOM height never changes during miniplayer hide/show. Previously this used
            // the variable `bottomFade`, which caused expandedHeight to jump from ~947 to ~1407
            // and AMLL to recompute its entire line layout on every state change.
            let expandedHeight = proxy.size.height + topFade + 420 * scale + 6 * scale
            ZStack {
                let webViewWidth = max(0, proxy.size.width - horizontalInset * 2)

                if shouldRenderCoverBlurHighlightOverlay {
                    fullscreenMaskedLyricsSurface(
                        scale: scale,
                        width: webViewWidth,
                        height: expandedHeight,
                        visibleHeight: visibleClipHeight,  // mask clip; independent of WebView height
                        topFade: topFade,
                        bottomFade: bottomFade,
                        blendMode: coverBlurBaseBlendMode,
                        useCompositingGroup: false
                    ) {
                        AMLLWebView(
                            store: fullscreenStore,
                            forcedAppearanceMode: .dark
                        )
                    }

                    fullscreenMaskedLyricsSurface(
                        scale: scale,
                        width: webViewWidth,
                        height: expandedHeight,
                        visibleHeight: visibleClipHeight,
                        topFade: topFade,
                        bottomFade: bottomFade,
                        blendMode: coverBlurHighlightBlendMode,
                        useCompositingGroup: false
                    ) {
                        AMLLWebView(
                            store: coverBlurHighlightStore,
                            forcedAppearanceMode: .dark
                        )
                    }
                    .allowsHitTesting(false)
                } else {
                    fullscreenMaskedLyricsSurface(
                        scale: scale,
                        width: webViewWidth,
                        height: expandedHeight,
                        visibleHeight: visibleClipHeight,
                        topFade: topFade,
                        bottomFade: bottomFade,
                        blendMode: usesCoverBlurLyricsRenderingPath ? coverBlurBaseBlendMode : .normal,
                        useCompositingGroup: !usesCoverBlurLyricsRenderingPath
                    ) {
                        AMLLWebView(store: fullscreenStore, forcedAppearanceMode: .dark)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Motion feel: subtle y-scale anchored at top creates "pushing down" feel during expansion
            .scaleEffect(
                y: isFullscreenBottomControlsVisible ? 0.97 : 1.0,
                anchor: .top
            )
            .animation(bottomControlsAnimation, value: isFullscreenBottomControlsVisible)
        }
    }

    private func fullscreenQueuePanel(
        scale: CGFloat,
        visibleHeight: CGFloat
    ) -> some View {
        FullscreenQueueView(
            tracks: playerVM.currentQueueTracks,
            currentTrackID: playerVM.currentTrack?.id,
            playbackMode: currentPlaybackMode,
            glassStyle: fullscreenControlsGlassStyle,
            usesBrightTextPalette: fullscreenQueueUsesBrightTextPalette,
            scale: scale,
            visibleHeight: visibleHeight,
            onTrackTap: { track in
                handleQueueTrackTap(track)
            }
        )
    }

    @ViewBuilder
    private func fullscreenMaskedLyricsSurface<Content: View>(
        scale: CGFloat,
        width: CGFloat,
        height: CGFloat,
        visibleHeight: CGFloat,
        topFade: CGFloat,
        bottomFade: CGFloat,
        blendMode: BlendMode,
        useCompositingGroup: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let maskedContent = content()
            .frame(width: width, height: height)
            .offset(y: -lyricsViewportTopLift * scale)
            .opacity(fullscreenLyricsViewportOpacity)
            .environment(\.colorScheme, .dark)
            .mask(
                ZStack(alignment: .top) {
                    fullscreenLyricsMask(
                        visibleHeight: visibleHeight,
                        topFade: topFade,
                        bottomFade: bottomFade
                    )
                }
                .frame(height: height, alignment: .top)  // Align mask to top of expanded content
                .offset(y: (isFullscreenBottomControlsVisible ? 42 : 58) * scale)  // Mask moves down
            )

        if useCompositingGroup {
            maskedContent
                .compositingGroup()
                .blendMode(blendMode)
        } else {
            maskedContent
                .blendMode(blendMode)
        }
    }

    // MARK: - Shared Horizontal Split Metrics

    private var layoutMetrics: FullscreenHorizontalSplitLayout {
        layoutMetrics(showLyricsColumn: isShowingRightPanel)
    }

    private func layoutMetrics(
        showLyricsColumn: Bool,
        windowWidth: CGFloat? = nil
    ) -> FullscreenHorizontalSplitLayout {
        FullscreenHorizontalSplitLayout.resolve(
            showLyricsColumn: showLyricsColumn,
            windowWidth: windowWidth
        )
    }

    private func coverBlurLegacyLayoutMetrics(
        showLyricsColumn: Bool,
        windowWidth: CGFloat? = nil
    ) -> (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        let resolvedWindowWidth = windowWidth ?? Self.baseCanvasWidth
        let availableWidth = max(0, resolvedWindowWidth - topContentHorizontalPadding * 2)
        if showLyricsColumn {
            let constrainedWidth = max(0, availableWidth - 88)
            let lyricsWidth = min(max(constrainedWidth * 0.30, 320), 560)
            let artworkWidth = max(constrainedWidth - lyricsWidth - (-58), 360)
            return (artworkWidth, lyricsWidth)
        }
        let lyricsWidth = min(max(availableWidth * 0.35, 340), 580)
        let centeredArtworkWidth = min(max(availableWidth * 0.78, 420), availableWidth)
        return (centeredArtworkWidth, lyricsWidth)
    }

    // MARK: - Bottom Controls

    @State private var isVolumeExpanded = false
    private let fullscreenControlButtonSize: CGFloat = 60
    private let fullscreenControlSpacing: CGFloat = 20
    private let fullscreenControlsHorizontalPadding: CGFloat = 80
    private let fullscreenControlsBottomPadding: CGFloat = 72
    private let fullscreenMiniPlayerMaxWidth: CGFloat = 1200
    /// Width to remove from the collapsed mini-player pill. Taken entirely from the
    /// progress-bar area (which uses maxWidth: .infinity). Outer button spacing is
    /// unaffected; the group re-centers automatically.
    private let fullscreenMiniPlayerPillWidthReduction: CGFloat = 160
    private let leadingControlsExpandedWidth: CGFloat = 180  // 3 buttons × 60pt
    private let leadingControlsCollapsedWidth: CGFloat = 120  // 2 buttons × 60pt
    private let volumeExpandedWidth: CGFloat = 180
    private let volumeCollapsedWidth: CGFloat = 60
    private let fullscreenSideControlsCollapseDelayNanoseconds: UInt64 = 180_000_000

    private func fullscreenMiniPlayerOcclusionRegion(
        scale: CGFloat,
        screenSize: CGSize
    ) -> FullscreenMiniPlayerOcclusionRegion {
        guard isFullscreenBottomControlsVisible else {
            return .inactive
        }

        let buttonSize = fullscreenControlButtonSize
        let spacing = fullscreenControlSpacing
        let windowWidth = Self.baseCanvasWidth

        let leadingControlsWidth = isLeftActionsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth
        let leadingControlsExtraWidth = leadingControlsWidth - leadingControlsCollapsedWidth
        let volumeWidth = isVolumeExpanded ? volumeExpandedWidth : volumeCollapsedWidth
        let volumeExtraWidth = volumeWidth - volumeCollapsedWidth
        let leadingMiniPlayerOriginX = leadingControlsCollapsedWidth + spacing
        let fixedControlWidth = leadingControlsCollapsedWidth + spacing + spacing + volumeCollapsedWidth
        let availableGroupWidth = max(0, windowWidth - fullscreenControlsHorizontalPadding * 2)
        let collapsedMiniPlayerWidth = max(
            0,
            min(availableGroupWidth - fixedControlWidth, fullscreenMiniPlayerMaxWidth)
                - fullscreenMiniPlayerPillWidthReduction
        )
        let groupWidth = fixedControlWidth + collapsedMiniPlayerWidth
        let currentMiniPlayerWidth = max(
            0,
            collapsedMiniPlayerWidth - leadingControlsExtraWidth - volumeExtraWidth
        )
        let groupOriginX = max(0, (windowWidth - groupWidth) * 0.5)
        let miniPlayerOriginX = groupOriginX + leadingMiniPlayerOriginX + leadingControlsExtraWidth

        let scaledButtonSize = buttonSize * scale
        let scaledMiniPlayerOriginX = miniPlayerOriginX * scale
        let scaledMiniPlayerWidth = currentMiniPlayerWidth * scale
        let scaledWindowWidth = windowWidth * scale
        let canvasLeftMargin = max(0, (screenSize.width - scaledWindowWidth) * 0.5)
        let canvasBottomMargin = max(0, (screenSize.height - Self.baseCanvasHeight * scale) * 0.5)
        let scaledBottomPadding = fullscreenControlsBottomPadding * scale + canvasBottomMargin

        guard scaledMiniPlayerWidth > 1, scaledButtonSize > 1 else {
            return .inactive
        }

        return FullscreenMiniPlayerOcclusionRegion(
            rect: CGRect(
                x: canvasLeftMargin + scaledMiniPlayerOriginX,
                y: scaledBottomPadding,
                width: scaledMiniPlayerWidth,
                height: scaledButtonSize
            ),
            cornerRadius: scaledButtonSize * 0.5,
            isEnabled: true
        )
    }

    private func bottomControlsRow() -> some View {
        // Fixed layout for 1470x923 base canvas
        let buttonSize = fullscreenControlButtonSize
        let spacing = fullscreenControlSpacing
        let windowWidth = Self.baseCanvasWidth
        let leadingControlsWidth = isLeftActionsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth
        let leadingControlsExtraWidth = leadingControlsWidth - leadingControlsCollapsedWidth
        let volumeWidth = isVolumeExpanded ? volumeExpandedWidth : volumeCollapsedWidth
        let volumeExtraWidth = volumeWidth - volumeCollapsedWidth
        let leadingMiniPlayerOriginX = leadingControlsCollapsedWidth + spacing
        let fixedControlWidth = leadingControlsCollapsedWidth + spacing + spacing + volumeCollapsedWidth
        let availableGroupWidth = max(0, windowWidth - fullscreenControlsHorizontalPadding * 2)
        let collapsedMiniPlayerWidth = max(
            0,
            min(availableGroupWidth - fixedControlWidth, fullscreenMiniPlayerMaxWidth)
                - fullscreenMiniPlayerPillWidthReduction
        )
        let groupWidth = fixedControlWidth + collapsedMiniPlayerWidth
        let currentMiniPlayerWidth = max(
            0,
            collapsedMiniPlayerWidth - leadingControlsExtraWidth - volumeExtraWidth
        )
        let groupOriginX = max(0, (windowWidth - groupWidth) * 0.5)
        let leadingControlsOriginX = groupOriginX
        let miniPlayerOriginX = groupOriginX + leadingMiniPlayerOriginX + leadingControlsExtraWidth
        let volumeOriginX = max(0, groupOriginX + groupWidth - volumeWidth)

        return ZStack(alignment: .leading) {
            leadingControlsPill(
                size: buttonSize,
                materialStyle: fullscreenControlsGlassStyle.materialStyle
            )
                .frame(width: leadingControlsWidth, height: buttonSize)
                .offset(x: leadingControlsOriginX)

            FullscreenMiniPlayerView(
                glassStyle: fullscreenControlsGlassStyle,
                playbackMode: currentPlaybackMode,
                onPlaybackModeChange: handlePlaybackModeChange,
                onCurrentPlaybackModeRetap: handleCurrentPlaybackModeRetap,
                onEditTrackRequested: { track in
                    trackToEdit = track
                },
                onEditExternalInfoRequested: {
                    isShowingExternalMatchEditor = true
                }
            )
                .frame(width: currentMiniPlayerWidth, height: buttonSize)
                .overlay(alignment: .top) {
                    if showPlaybackModeRetapTip {
                        PlaybackModeRetapTipView(onClose: dismissPlaybackModeRetapTip)
                            .offset(y: -12)
                    }
                }
                .animation(bottomControlsAnimation, value: showPlaybackModeRetapTip)
                .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)
                .offset(x: miniPlayerOriginX)

            ExpandableVolumeControl(
                volume: volumeBinding,
                isExpanded: $isVolumeExpanded,
                isEnabled: playbackCoordinator.presentation.isVolumeControlEnabled,
                usesAdaptiveForeground: isCoverBlurFullscreenSkin
            )
            .frame(width: volumeWidth, height: buttonSize)
            .environment(\.colorScheme, fullscreenControlsColorScheme)
            .offset(x: volumeOriginX)
        }
        .frame(width: windowWidth, height: buttonSize, alignment: .leading)
        .padding(.bottom, fullscreenControlsBottomPadding)
        .animation(bottomControlsAnimation, value: isLeftActionsExpanded)
        .animation(bottomControlsAnimation, value: isVolumeExpanded)
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { playbackCoordinator.presentation.volume },
            set: { playbackCoordinator.setVolume($0) }
        )
    }

    private var bottomControlsAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.18)
        }
        return .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }

    private var quickAppearancePanelAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.14)
        }
        return .spring(response: 0.24, dampingFraction: 0.88, blendDuration: 0.05)
    }

    /// Slower spring used specifically for the cover-element drop/rise when the
    /// fullscreen miniplayer hides or shows. Same damping and character as
    /// bottomControlsAnimation but a longer response so the motion feels
    /// deliberate and consistent with the lyrics-region expansion.
    private var coverDropAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.28)
        }
        return .spring(response: 0.55, dampingFraction: 0.82, blendDuration: 0.08)
    }

    private var isFullscreenBottomControlsAutoHideEnabled: Bool {
        settings.fullscreenMiniPlayerAutoHideSeconds > 0
    }

    private var shouldBlockFullscreenBottomControlsAutoHide: Bool {
        shouldKeepFullscreenBottomControlsVisible
            || isFullscreenBottomControlsHovered
            || isLeftActionsExpanded
            || isQuickAppearancePanelPresented
            || isVolumeExpanded
            || isFullscreenBottomControlsProgressDragging
            || isFullscreenBottomControlsVolumeAdjusting
    }

    private var shouldKeepFullscreenBottomControlsVisible: Bool {
        isShowingQueuePanel || isQuickAppearancePanelPresented
    }

    private func updateFullscreenMiniPlayerOcclusionRegion(_ region: FullscreenMiniPlayerOcclusionRegion) {
        fullscreenPointerOcclusionMonitor.updateRegion(region)
    }

    private func setPointerOverMiniPlayerOcclusion(_ isOccluded: Bool, reason: String) {
        guard isPointerOverMiniPlayerOcclusion != isOccluded else { return }
        isPointerOverMiniPlayerOcclusion = isOccluded
        applyFullscreenLyricsMouseGate(reason: reason)
    }

    private func applyFullscreenLyricsMouseGate(reason: String) {
        fullscreenStore.setMouseInteractionSuppressed(isPointerOverMiniPlayerOcclusion, reason: reason)
        existingCoverBlurHighlightStore?.setMouseInteractionSuppressed(
            isPointerOverMiniPlayerOcclusion,
            reason: reason
        )
    }

    private func handleFullscreenBottomControlsHover(_ hovering: Bool) {
        isFullscreenBottomControlsHovered = hovering
        if hovering {
            cancelFullscreenBottomControlsAutoHide()
            if isFullscreenBottomControlsVisible == false {
                withAnimation(bottomControlsAnimation) {
                    isFullscreenBottomControlsVisible = true
                }
            }
        } else {
            scheduleFullscreenBottomControlsAutoHideIfNeeded()
        }
    }

    private func updateFullscreenBottomControlsHoverGate(
        hotZone: Bool? = nil,
        appearancePanel: Bool? = nil,
        leading: Bool? = nil,
        center: Bool? = nil,
        trailing: Bool? = nil
    ) {
        if let hotZone {
            isFullscreenBottomControlsHotZoneHovered = hotZone
        }
        if let appearancePanel {
            isFullscreenBottomControlsAppearancePanelHovered = appearancePanel
        }
        if let leading {
            isFullscreenBottomControlsLeadingHovered = leading
        }
        if let center {
            isFullscreenBottomControlsCenterHovered = center
        }
        if let trailing {
            isFullscreenBottomControlsTrailingHovered = trailing
        }

        let isPointerInsideFullscreenBottomControls =
            isFullscreenBottomControlsHotZoneHovered
            || isFullscreenBottomControlsAppearancePanelHovered
            || isFullscreenBottomControlsLeadingHovered
            || isFullscreenBottomControlsCenterHovered
            || isFullscreenBottomControlsTrailingHovered

        guard isPointerInsideFullscreenBottomControls != isFullscreenBottomControlsHovered else {
            if isPointerInsideFullscreenBottomControls {
                cancelFullscreenBottomControlsAutoHide()
                if isFullscreenBottomControlsVisible == false {
                    withAnimation(bottomControlsAnimation) {
                        isFullscreenBottomControlsVisible = true
                    }
                }
            }
            return
        }

        handleFullscreenBottomControlsHover(isPointerInsideFullscreenBottomControls)
    }

    private func registerFullscreenBottomControlsInteraction() {
        if isFullscreenBottomControlsVisible == false {
            withAnimation(bottomControlsAnimation) {
                isFullscreenBottomControlsVisible = true
            }
        }
        guard isFullscreenBottomControlsHovered == false else {
            cancelFullscreenBottomControlsAutoHide()
            return
        }
        scheduleFullscreenBottomControlsAutoHideIfNeeded()
    }

    private func setQuickAppearancePanelPresented(_ isPresented: Bool) {
        guard isQuickAppearancePanelPresented != isPresented else { return }

        withAnimation(quickAppearancePanelAnimation) {
            isQuickAppearancePanelPresented = isPresented
        }

        if isPresented {
            cancelFullscreenBottomControlsAutoHide()
            if isFullscreenBottomControlsVisible == false {
                withAnimation(bottomControlsAnimation) {
                    isFullscreenBottomControlsVisible = true
                }
            }
        } else {
            updateFullscreenBottomControlsHoverGate(appearancePanel: false)
            scheduleFullscreenBottomControlsAutoHideIfNeeded()
        }
    }

    private func handleRightPanelDisplayStateChange(_ newState: RightPanelDisplayState) {
        syncFullscreenLyricsHostMount()

        if newState == .queue {
            cancelFullscreenBottomControlsAutoHide()
            if isFullscreenBottomControlsVisible == false {
                withAnimation(bottomControlsAnimation) {
                    isFullscreenBottomControlsVisible = true
                }
            }
            return
        }

        scheduleFullscreenBottomControlsAutoHideIfNeeded()
    }

    private func resetFullscreenBottomControlsAutoHideState() {
        cancelFullscreenBottomControlsAutoHide()
        cancelFullscreenSideControlCollapses()
        isFullscreenBottomControlsVisible = true
        isFullscreenBottomControlsProgressDragging = false
        isFullscreenBottomControlsVolumeAdjusting = false
        isFullscreenBottomControlsHovered = false
        isFullscreenBottomControlsHotZoneHovered = false
        isFullscreenBottomControlsAppearancePanelHovered = false
        isFullscreenBottomControlsLeadingHovered = false
        isFullscreenBottomControlsCenterHovered = false
        isFullscreenBottomControlsTrailingHovered = false
        setLeftActionsExpanded(false, reason: "reset")
        setVolumeExpanded(false, reason: "reset")
        scheduleFullscreenBottomControlsAutoHideIfNeeded()
    }

    private func scheduleFullscreenBottomControlsAutoHideIfNeeded() {
        cancelFullscreenBottomControlsAutoHide()
        guard isFullscreenBottomControlsAutoHideEnabled else {
            if isFullscreenBottomControlsVisible == false {
                withAnimation(bottomControlsAnimation) {
                    isFullscreenBottomControlsVisible = true
                }
            }
            return
        }
        guard shouldBlockFullscreenBottomControlsAutoHide == false else { return }

        let delay = settings.fullscreenMiniPlayerAutoHideSeconds
        guard delay > 0 else { return }

        pendingFullscreenBottomControlsHideTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard shouldBlockFullscreenBottomControlsAutoHide == false else {
                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                return
            }

            withAnimation(bottomControlsAnimation) {
                isFullscreenBottomControlsVisible = false
            }
            setLeftActionsExpanded(false, reason: "auto-hide")
            setVolumeExpanded(false, reason: "auto-hide")
            pendingFullscreenBottomControlsHideTask = nil
        }
    }

    private func cancelFullscreenBottomControlsAutoHide() {
        pendingFullscreenBottomControlsHideTask?.cancel()
        pendingFullscreenBottomControlsHideTask = nil
    }

    private func scheduleLeftActionsCollapseIfNeeded(reason: String) {
        cancelLeftActionsCollapse()
        guard isFullscreenBottomControlsLeadingHovered == false else {
            logFullscreenMiniPlayerHover("left collapse skipped reason=\(reason) still-hovered")
            return
        }

        pendingLeftActionsCollapseTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: fullscreenSideControlsCollapseDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard isFullscreenBottomControlsLeadingHovered == false else {
                logFullscreenMiniPlayerHover("left collapse cancelled reason=\(reason) hovered-after-delay")
                return
            }

            setLeftActionsExpanded(false, reason: reason)
            scheduleFullscreenBottomControlsAutoHideIfNeeded()
            pendingLeftActionsCollapseTask = nil
        }
    }

    private func cancelLeftActionsCollapse() {
        pendingLeftActionsCollapseTask?.cancel()
        pendingLeftActionsCollapseTask = nil
    }

    private func scheduleVolumeCollapseIfNeeded(reason: String) {
        cancelVolumeCollapse()
        guard isFullscreenBottomControlsTrailingHovered == false,
              isFullscreenBottomControlsVolumeAdjusting == false else {
            logFullscreenMiniPlayerHover("volume collapse skipped reason=\(reason) still-active")
            return
        }

        pendingVolumeCollapseTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: fullscreenSideControlsCollapseDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard isFullscreenBottomControlsTrailingHovered == false,
                  isFullscreenBottomControlsVolumeAdjusting == false else {
                logFullscreenMiniPlayerHover("volume collapse cancelled reason=\(reason) active-after-delay")
                return
            }

            setVolumeExpanded(false, reason: reason)
            scheduleFullscreenBottomControlsAutoHideIfNeeded()
            pendingVolumeCollapseTask = nil
        }
    }

    private func cancelVolumeCollapse() {
        pendingVolumeCollapseTask?.cancel()
        pendingVolumeCollapseTask = nil
    }

    private func cancelFullscreenSideControlCollapses() {
        cancelLeftActionsCollapse()
        cancelVolumeCollapse()
    }

    private func setLeftActionsExpanded(_ expanded: Bool, reason: String) {
        guard isLeftActionsExpanded != expanded else {
            logFullscreenMiniPlayerHover("left unchanged reason=\(reason) expanded=\(expanded)")
            return
        }

        logFullscreenMiniPlayerHover(
            "left reason=\(reason) \(isLeftActionsExpanded)->\(expanded) hot=\(isFullscreenBottomControlsHotZoneHovered) center=\(isFullscreenBottomControlsCenterHovered) leadingHover=\(isFullscreenBottomControlsLeadingHovered) trailing=\(isFullscreenBottomControlsTrailingHovered)"
        )
        withAnimation(bottomControlsAnimation) {
            isLeftActionsExpanded = expanded
        }
    }

    private func setVolumeExpanded(_ expanded: Bool, reason: String) {
        let nextValue = expanded && playbackCoordinator.presentation.isVolumeControlEnabled
        guard isVolumeExpanded != nextValue else {
            logFullscreenMiniPlayerHover("volume unchanged reason=\(reason) expanded=\(nextValue)")
            return
        }

        logFullscreenMiniPlayerHover(
            "volume reason=\(reason) \(isVolumeExpanded)->\(nextValue) hot=\(isFullscreenBottomControlsHotZoneHovered) center=\(isFullscreenBottomControlsCenterHovered) leadingHover=\(isFullscreenBottomControlsLeadingHovered) trailing=\(isFullscreenBottomControlsTrailingHovered) adjusting=\(isFullscreenBottomControlsVolumeAdjusting)"
        )
        withAnimation(bottomControlsAnimation) {
            isVolumeExpanded = nextValue
        }
    }

    private func logFullscreenMiniPlayerHover(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "Debug.fullscreenMiniPlayerHover") else { return }
        Log.info("FullscreenMiniPlayerHover: \(message())", category: .fullscreen)
    }

    // MARK: - Fullscreen Bottom Bar Layer (Actual Resolution - Crisp)
    
    @ViewBuilder
    private func fullscreenBottomBarLayer(
        scale: CGFloat,
        screenWidth: CGFloat,
        screenHeight: CGFloat
    ) -> some View {
        // Use the same base calculations as bottomControlsRow, then multiply by scale
        let baseScale = scale
        let buttonSize = fullscreenControlButtonSize
        let spacing = fullscreenControlSpacing
        let windowWidth = Self.baseCanvasWidth
        
        let leadingControlsWidth = isLeftActionsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth
        let leadingControlsExtraWidth = leadingControlsWidth - leadingControlsCollapsedWidth
        let volumeWidth = isVolumeExpanded ? volumeExpandedWidth : volumeCollapsedWidth
        let volumeExtraWidth = volumeWidth - volumeCollapsedWidth
        let leadingMiniPlayerOriginX = leadingControlsCollapsedWidth + spacing
        let fixedControlWidth = leadingControlsCollapsedWidth + spacing + spacing + volumeCollapsedWidth
        let availableGroupWidth = max(0, windowWidth - fullscreenControlsHorizontalPadding * 2)
        let collapsedMiniPlayerWidth = max(
            0,
            min(availableGroupWidth - fixedControlWidth, fullscreenMiniPlayerMaxWidth)
                - fullscreenMiniPlayerPillWidthReduction
        )
        let groupWidth = fixedControlWidth + collapsedMiniPlayerWidth
        let currentMiniPlayerWidth = max(
            0,
            collapsedMiniPlayerWidth - leadingControlsExtraWidth - volumeExtraWidth
        )
        let groupOriginX = max(0, (windowWidth - groupWidth) * 0.5)
        let leadingControlsOriginX = groupOriginX
        let miniPlayerOriginX = groupOriginX + leadingMiniPlayerOriginX + leadingControlsExtraWidth
        let volumeOriginX = max(0, groupOriginX + groupWidth - volumeWidth)
        
        // Apply scale to all positions for actual resolution rendering
        let scaledButtonSize = buttonSize * baseScale
        let scaledLeadingControlsOriginX = leadingControlsOriginX * baseScale
        let scaledLeadingControlsWidth = leadingControlsWidth * baseScale
        let scaledMiniPlayerOriginX = miniPlayerOriginX * baseScale
        let scaledMiniPlayerWidth = currentMiniPlayerWidth * baseScale
        let scaledVolumeOriginX = volumeOriginX * baseScale
        let scaledVolumeWidth = volumeWidth * baseScale
        let scaledWindowWidth = windowWidth * baseScale
        // Canvas-bottom-relative bottom padding: on displays where the canvas has vertical
        // margins (scale = scaleX, e.g. portrait-aspect MacBooks), anchor the controls bar
        // to the canvas bottom rather than the screen bottom so the visual spacing is stable.
        let canvasBottomMargin = max(0, (screenHeight - Self.baseCanvasHeight * baseScale) / 2)
        let scaledBottomPadding = fullscreenControlsBottomPadding * baseScale + canvasBottomMargin
        let scaledGroupWidth = groupWidth * baseScale
        let hotZoneWidth = min(scaledWindowWidth, scaledGroupWidth + 120 * baseScale)
        let hotZoneHeight = scaledButtonSize + 34 * baseScale
        let controlsRowHeight = max(scaledButtonSize, hotZoneHeight)
        let controlsCenterY = controlsRowHeight * 0.5
        let adjustedBottomPadding = max(
            0,
            scaledBottomPadding - (controlsRowHeight - scaledButtonSize) * 0.5
        )
        let canvasLeadingMargin = max(0, (screenWidth - scaledWindowWidth) * 0.5)
        let quickPanelSize = FullscreenQuickAppearancePanel.panelSize(for: baseScale)
        let quickPanelWidth = quickPanelSize.width
        let quickPanelHeight = quickPanelSize.height
        let quickPanelSafeMargin = 20 * baseScale
        // Keep it close to the Mini Player, but never overlapping it.
        let quickPanelGap = 22 * baseScale
        let quickPanelBottomY = screenHeight - adjustedBottomPadding - controlsRowHeight - quickPanelGap
        // Anchor the panel above the bottom-left controls group (not centered on screen).
        let quickPanelHorizontalInset = 10 * baseScale
        let quickPanelIdealCenterX =
            canvasLeadingMargin + scaledLeadingControlsOriginX - quickPanelHorizontalInset + quickPanelWidth * 0.5
        let quickPanelCenterX = min(
            max(quickPanelIdealCenterX, quickPanelSafeMargin + quickPanelWidth * 0.5),
            max(
                quickPanelSafeMargin + quickPanelWidth * 0.5,
                screenWidth - quickPanelSafeMargin - quickPanelWidth * 0.5
            )
        )
        let quickPanelCenterY = max(
            quickPanelSafeMargin + quickPanelHeight * 0.5,
            quickPanelBottomY - quickPanelHeight * 0.5
        )
        
        ZStack(alignment: .topLeading) {
            if isQuickAppearancePanelPresented {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        setQuickAppearancePanelPresented(false)
                    }
                    .transition(.opacity)
                    .zIndex(0)
            }

            VStack {
            Spacer()
            ZStack(alignment: .leading) {
                Color.white.opacity(0.001)
                    .frame(width: hotZoneWidth, height: hotZoneHeight)
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: hotZoneHeight * 0.5,
                            style: .continuous
                        )
                    )
                    .position(x: scaledWindowWidth * 0.5, y: controlsCenterY)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            updateFullscreenBottomControlsHoverGate(hotZone: true)
                        case .ended:
                            updateFullscreenBottomControlsHoverGate(hotZone: false)
                        }
                    }

                ZStack(alignment: .leading) {
                    leadingControlsPill(
                        size: scaledButtonSize,
                        materialStyle: fullscreenControlsGlassStyle.materialStyle
                    )
                        .glassEffectTransition(.materialize)
                        .frame(width: scaledLeadingControlsWidth, height: scaledButtonSize)
                        .position(
                            x: scaledLeadingControlsOriginX + scaledLeadingControlsWidth / 2,
                            y: controlsCenterY
                        )

                    FullscreenMiniPlayerView(
                        scale: scale,
                        glassStyle: fullscreenControlsGlassStyle,
                        playbackMode: currentPlaybackMode,
                        onPlaybackModeChange: handlePlaybackModeChange,
                        onCurrentPlaybackModeRetap: handleCurrentPlaybackModeRetap,
                        onInteraction: {
                            registerFullscreenBottomControlsInteraction()
                        },
                        onHoverStateChanged: { hovering in
                            updateFullscreenBottomControlsHoverGate(center: hovering)
                            if hovering {
                                registerFullscreenBottomControlsInteraction()
                            }
                        },
                        onProgressDraggingChanged: { dragging in
                            isFullscreenBottomControlsProgressDragging = dragging
                            if dragging {
                                registerFullscreenBottomControlsInteraction()
                            } else {
                                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                            }
                        },
                        onEditTrackRequested: { track in
                            registerFullscreenBottomControlsInteraction()
                            trackToEdit = track
                        },
                        onEditExternalInfoRequested: {
                            registerFullscreenBottomControlsInteraction()
                            isShowingExternalMatchEditor = true
                        }
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledMiniPlayerWidth, height: scaledButtonSize)
                    .overlay(alignment: .top) {
                        if showPlaybackModeRetapTip {
                            PlaybackModeRetapTipView(onClose: dismissPlaybackModeRetapTip)
                                .offset(y: -12 * scale)
                        }
                    }
                    .animation(bottomControlsAnimation, value: showPlaybackModeRetapTip)
                    .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)
                    .position(
                        x: scaledMiniPlayerOriginX + scaledMiniPlayerWidth / 2,
                        y: controlsCenterY
                    )

                    ExpandableVolumeControl(
                        volume: volumeBinding,
                        isExpanded: $isVolumeExpanded,
                        scale: scale,
                        onInteraction: {
                            registerFullscreenBottomControlsInteraction()
                        },
                        onHoverStateChanged: { hovering in
                            updateFullscreenBottomControlsHoverGate(trailing: hovering)
                            if hovering {
                                cancelVolumeCollapse()
                                setVolumeExpanded(true, reason: "volume-hover-enter")
                                registerFullscreenBottomControlsInteraction()
                            } else {
                                scheduleVolumeCollapseIfNeeded(reason: "volume-hover-exit")
                                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                            }
                        },
                        onAdjustingChanged: { adjusting in
                            isFullscreenBottomControlsVolumeAdjusting = adjusting
                            if adjusting {
                                registerFullscreenBottomControlsInteraction()
                            } else {
                                scheduleVolumeCollapseIfNeeded(reason: "volume-adjust-end")
                                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                            }
                        },
                        materialStyle: fullscreenControlsGlassStyle.materialStyle,
                        isEnabled: playbackCoordinator.presentation.isVolumeControlEnabled,
                        usesAdaptiveForeground: isCoverBlurFullscreenSkin,
                        usesInternalHoverExpansion: false
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledVolumeWidth, height: scaledButtonSize)
                    .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)
                    .position(
                        x: scaledVolumeOriginX + scaledVolumeWidth / 2,
                        y: controlsCenterY
                    )
                }
                .opacity(isFullscreenBottomControlsVisible ? 1 : 0)
                .allowsHitTesting(isFullscreenBottomControlsVisible)
                .accessibilityHidden(!isFullscreenBottomControlsVisible)
            }
            .frame(width: scaledWindowWidth, height: controlsRowHeight, alignment: .leading)
            .padding(.bottom, adjustedBottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)

            if isQuickAppearancePanelPresented {
                FullscreenQuickAppearancePanel(
                    scale: scale,
                    onDismiss: { setQuickAppearancePanelPresented(false) }
                )
                .frame(width: quickPanelWidth, height: quickPanelHeight)
                .position(x: quickPanelCenterX, y: quickPanelCenterY)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        updateFullscreenBottomControlsHoverGate(appearancePanel: true)
                    case .ended:
                        updateFullscreenBottomControlsHoverGate(appearancePanel: false)
                    }
                }
                .transition(
                    .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomLeading))
                )
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(quickAppearancePanelAnimation, value: isQuickAppearancePanelPresented)
        .animation(bottomControlsAnimation, value: isLeftActionsExpanded)
        .animation(bottomControlsAnimation, value: isVolumeExpanded)
        .animation(bottomControlsAnimation, value: isFullscreenBottomControlsVisible)
    }

    // MARK: - Artwork and Controls Area (No Lyrics - Lyrics are in crisp layer)

    @ViewBuilder
    private func artworkAndControlsArea(selectedSkin: any NowPlayingSkin, scale: CGFloat) -> some View {
        let splitLayout = layoutMetrics
        let artworkOffsetX =
            splitLayout.artworkLeadingX
            + splitLayout.artworkWidth * 0.5
            - Self.baseCanvasWidth * 0.5

        skinArtworkArea(
            selectedSkin: selectedSkin,
            artworkColumnWidth: splitLayout.artworkWidth,
            scale: scale
        )
        .frame(width: splitLayout.artworkWidth)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: artworkOffsetX)
    }

    @ViewBuilder
    private func skinArtworkArea(
        selectedSkin: any NowPlayingSkin,
        artworkColumnWidth: CGFloat,
        scale: CGFloat
    ) -> some View {
        let context = makeContext(
            windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
            artworkColumnWidth: artworkColumnWidth,
            fullscreenScale: scale  // Pass scale for crisp rendering
        )

        ZStack {
            // Main artwork - using user configurable scale
            selectedSkin.makeArtwork(context: context)
                .scaleEffect(settings.fullscreenArtworkScale)

            // Overlay if any
            if let overlay = selectedSkin.makeOverlay(context: context) {
                overlay
                    .scaleEffect(settings.fullscreenArtworkScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Lyrics Area (No Material Background)

    private var lyricsArea: some View {
        ZStack {
            fullscreenLyricsViewport

            // Empty state
            if !currentDisplayContext.hasTrack {
                VStack(spacing: 16) {
                    Image(systemName: "music.note")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("lyrics.empty_state")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else if let message = fullscreenEmptyLyricsMessage {
                VStack(spacing: 14) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.55))

                    Text(message)
                        .font(.system(size: 20, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: 520)
                }
                .padding(.horizontal, 32)
            }
        }
    }

    private var fullscreenEmptyLyricsMessage: String? {
        guard playbackCoordinator.presentation.source.isExternal else { return nil }
        let lyricsText = playbackCoordinator.presentation.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard lyricsText.isEmpty else { return nil }
        if let externalMessage = playbackCoordinator.presentation.externalLyricsStatusMessage {
            return externalMessage
        }
        return NSLocalizedString("lyrics.empty_state", comment: "")
    }

    private var fullscreenLyricsViewport: some View {
        GeometryReader { proxy in
            let topFade = min(12, max(5, proxy.size.height * 0.015))
            let bottomFade = min(90, max(52, proxy.size.height * 0.12))
            let horizontalInset: CGFloat = 10
            let expandedHeight = proxy.size.height + topFade + bottomFade + 6

            AMLLWebView(store: fullscreenStore, forcedAppearanceMode: .dark)
                .frame(
                    width: max(0, proxy.size.width - horizontalInset * 2),
                    height: expandedHeight
                )
                .offset(y: -lyricsViewportTopLift)
                .opacity(fullscreenLyricsViewportOpacity)
                .environment(\.colorScheme, .dark)
                .mask(
                    fullscreenLyricsMask(
                        visibleHeight: proxy.size.height,
                        topFade: topFade,
                        bottomFade: bottomFade
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Leading Controls Pill

    private func leadingControlsPill(
        size: CGFloat,
        materialStyle: LiquidGlassPillMaterialStyle
    ) -> some View {
        // Scale factor relative to base button size (60)
        let scaleFactor = size / fullscreenControlButtonSize
        // When dark glass is selected, the capsule must use a dark colorScheme
        // so .glassEffect renders dark material; otherwise respect ambient.
        let controlColorScheme: ColorScheme =
            materialStyle == .darkGlass ? .dark : fullscreenControlsColorScheme

        return HStack(spacing: 0) {
            leadingControlButton(size: size, help: "fullscreen.exit") {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
                    .compositingGroup()
                    .blendMode(fullscreenMiniPlayerIconBlendMode)
            } action: {
                onExitFullscreen?()
            }

            lyricsVisibilityButton(size: size)

            quickAppearanceButton(size: size)
                .opacity(isLeftActionsExpanded ? 1 : 0)
                .allowsHitTesting(isLeftActionsExpanded)
                .accessibilityHidden(!isLeftActionsExpanded)
        }
        .frame(
            width: isLeftActionsExpanded ? leadingControlsExpandedWidth * scaleFactor : leadingControlsCollapsedWidth * scaleFactor,
            height: size,
            alignment: .leading
        )
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: controlColorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, controlColorScheme)
        .onHover { hovering in
            updateFullscreenBottomControlsHoverGate(leading: hovering)
            if hovering {
                cancelLeftActionsCollapse()
                setLeftActionsExpanded(true, reason: "left-hover-enter")
                registerFullscreenBottomControlsInteraction()
            } else {
                scheduleLeftActionsCollapseIfNeeded(reason: "left-hover-exit")
                scheduleFullscreenBottomControlsAutoHideIfNeeded()
            }
        }
    }

    private func leadingControlButton<Label: View>(
        size: CGFloat,
        help: LocalizedStringKey,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            registerFullscreenBottomControlsInteraction()
            action()
        } label: {
            label()
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func quickAppearanceButton(size: CGFloat) -> some View {
        let icon = isQuickAppearancePanelPresented ? "paintpalette.fill" : "paintpalette"

        return leadingControlButton(size: size, help: "快速外观") {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
                .compositingGroup()
                .blendMode(fullscreenMiniPlayerIconBlendMode)
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .animation(.snappy(duration: 0.20), value: icon)
        } action: {
            setQuickAppearancePanelPresented(!isQuickAppearancePanelPresented)
        }
    }

    private func lyricsVisibilityButton(size: CGFloat) -> some View {
        let isShowingLyrics = rightPanelDisplayState == .lyrics
        let icon = isShowingLyrics ? "quote.bubble.fill" : "quote.bubble"
        let helpText: LocalizedStringKey = isShowingLyrics ? "Hide Lyrics" : "Show Lyrics"
        let canToggle = currentDisplayContext.hasTrack

        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(fullscreenMiniPlayerPrimaryColor.opacity(canToggle ? 1 : 0.45))
                .compositingGroup()
                .blendMode(fullscreenMiniPlayerIconBlendMode)
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .animation(.snappy(duration: 0.22), value: icon)
        } action: {
            handleLyricsButtonTap()
        }
        .disabled(!canToggle)
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
        settings.playbackOrderMode
    }

    private var lyricsLayoutAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        // Non-linear, spring-like layout movement for artwork/lyrics transitions.
        return .spring(response: 0.62, dampingFraction: 0.84, blendDuration: 0.18)
    }

    private var fullscreenMiniPlayerPrimaryColor: Color {
        Color(nsColor: fullscreenMiniPlayerPrimaryNSColor).opacity(0.96)
    }

    private var fullscreenMiniPlayerPrimaryNSColor: NSColor {
        let palette = themeStore.semanticPalette
        if isCoverBlurFullscreenSkin,
           fullscreenControlsGlassStyle.materialStyle == .clear,
           themeStore.hasArtworkThemeColor,
           FullscreenMiniPlayerView.shouldUseDarkArtworkForeground(
                for: palette.analysis
           ) {
            return palette.readabilityProfile.foregroundPrimary
        }
        return palette.miniPlayerControl.primary
    }

    private var fullscreenMiniPlayerIconBlendMode: BlendMode {
        if isCoverBlurFullscreenSkin,
           fullscreenControlsGlassStyle.materialStyle == .clear,
           themeStore.hasArtworkThemeColor,
           FullscreenMiniPlayerView.shouldUseDarkArtworkForeground(
                for: themeStore.semanticPalette.analysis
           ),
           ColorMath.relativeLuminance(of: fullscreenMiniPlayerPrimaryNSColor) < 0.58 {
            return .normal
        }
        return .screen
    }

    private var fullscreenControlsGlassStyle: FullscreenControlsGlassStyle {
        let materialStyle: LiquidGlassPillMaterialStyle =
            settings.fullscreenMiniPlayerGlassMaterial == .darkGlass ? .darkGlass : .clear
        // Dark glass requires a dark colorScheme for the material
        // to render correctly regardless of ambient mode.
        let effectiveColorScheme: ColorScheme =
            materialStyle == .darkGlass ? .dark : fullscreenControlsColorScheme
        return FullscreenControlsGlassStyle(
            colorScheme: effectiveColorScheme,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            materialStyle: materialStyle
        )
    }

    private var fullscreenQueueUsesBrightTextPalette: Bool {
        let skinID = settings.fullscreen.skinID
        return skinID == "coverLed"
            || skinID == AppleStyleSkin.skinID
            || skinID == "rotatingCover"
            || skinID == "kmgccc.cassette"
    }

    private var fullscreenControlsColorScheme: ColorScheme {
        isCoverBlurFullscreenSkin ? .dark : colorScheme
    }

    private var shouldKeepFullscreenMiniPlayerSpectrumAlive: Bool {
        guard settings.fullscreen.isMiniPlayerSpectrumEnabled else { return false }
        if playbackCoordinator.activeSource.isExternal {
            return playbackCoordinator.presentation.hasTrack
        }
        return playerVM.currentTrack != nil
    }

    private var coverBlurBaseBlendMode: BlendMode {
        if isAppleStyleFullscreenSkin {
            return .plusLighter
        }
        guard isCoverBlurFullscreenSkin else { return .normal }
        switch coverBlurLyricsTheme?.profile {
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
        switch coverBlurLyricsTheme?.profile {
        case .lighter:
            return .normal
        case .darker:
            return .plusDarker
        case .none:
            return .normal
        }
    }

    private var fullscreenLyricsConfigSignature: String {
        let overlayContext: LyricsRuntimePresentationContext =
            hostContext == .embeddedWindow ? .fullscreenEmbedded : .fullscreenSystem
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: overlayContext,
            playbackSource: playbackCoordinator.presentation.source
        )
        return [
            settings.fullscreen.skinID,
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
            settings.amllDiscreteWordHighlightEnabled ? "wordDiscrete" : "wordSmooth",
            "amllQuality:\(settings.amllLyricsRenderQuality.rawValue)",
            playbackCoordinator.presentation.source.rawValue,
            hostContext.rawValue,
            overlay.signature,
        ].joined(separator: "|")
    }

    private func setupSeekCallback() {
        fullscreenStore.onUserSeek = { seconds in
            playbackCoordinator.seek(to: seconds)
        }
    }

    private func startFullscreenLyricsSurface(reason: String) {
        // Report visibility to manager first so a newly materialized surface can
        // replay the latest snapshot, then push the same payload directly through
        // the fullscreen reload path. Embedded fullscreen calls this after its
        // geometry gate opens; system fullscreen calls it on appear.
        LyricsSurfaceManager.shared.reportFullscreenVisible(true)
        reloadLyricsSurface(reason: reason, forceLyricsReload: true)
    }

    private func isLedEnabledForFullscreenSkin() -> Bool {
        // Drive LED service start/stop from the real per-skin visualizerMode key
        // (the same key the skin's display gate reads). `hasLedMeter` only
        // describes whether the skin *supports* an LED meter — it must NOT be
        // used to decide whether one is currently *enabled*. Cassette in
        // particular keeps its key at "off" by default and must not auto-start
        // the meter on fullscreen entry.
        let skinID = settings.fullscreen.skinID
        guard let skin = FullscreenSkinID(rawValue: skinID), skin.hasLedMeter else {
            return false
        }
        let defaults = UserDefaults.standard
        switch skin {
        case .coverLed:
            return defaults.string(forKey: "skin.classicLED.fullscreen.visualizerMode") == "led"
        case .appleStyle:
            return defaults.string(forKey: "skin.appleStyle.fullscreen.visualizerMode") == "led"
        case .rotatingCover:
            return defaults.string(forKey: "skin.rotatingCover.fullscreen.visualizerMode") == "led"
        case .kmgcccCassette:
            return defaults.string(forKey: "skin.kmgcccCassette.fullscreen.visualizerMode") == "led"
        case .coverGradientBlur:
            return false
        }
    }

    private func syncFullscreenLedService() {
        let enabled = isLedEnabledForFullscreenSkin()
        if enabled {
            ledMeterProvider.getOrCreate().start()
        } else {
            ledMeterProvider.stop()
        }
    }

    private func handleLyricsButtonTap() {
        autoHiddenFullscreenLyricsForEmptyContent = false

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

    private func syncFullscreenLyricsAvailability(with payload: FullscreenPlaybackPayload) {
        guard currentDisplayContext.hasTrack else {
            autoHiddenFullscreenLyricsForEmptyContent = false
            return
        }

        if payload.hasDisplayableLyrics {
            if autoHiddenFullscreenLyricsForEmptyContent && rightPanelDisplayState == .hidden {
                handleLyricsButtonTap()
            } else {
                autoHiddenFullscreenLyricsForEmptyContent = false
            }
            return
        }

        guard rightPanelDisplayState == .lyrics else { return }
        handleLyricsButtonTap()
        autoHiddenFullscreenLyricsForEmptyContent = true
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
        if newState == .lyrics, playbackCoordinator.presentation.hasTrack {
            pendingFullscreenLyricsHostDetach?.cancel()
            pendingFullscreenLyricsHostDetach = nil
            fullscreenLyricsHostMounted = true
        }

        withAnimation(lyricsLayoutAnimation) {
            rightPanelDisplayState = newState
        }
    }

    private func applyPlaybackMode(_ mode: PlaybackOrderMode) {
        playbackCoordinator.setPlaybackOrderMode(mode)
    }

    private func showPlaybackModeRetapTipIfNeeded() {
        guard showPlaybackModeRetapTip == false else { return }
        guard AppVersionGate.shared.shouldShowFeatureTip(
            featureKey: FeatureTips.playbackModeRetapKey,
            introducedVersion: FeatureTips.playbackModeRetapIntroducedVersion,
            maxDisplayCount: FeatureTips.playbackModeRetapMaxDisplayCount
        ) else { return }

        withAnimation(bottomControlsAnimation) {
            showPlaybackModeRetapTip = true
        }
        AppVersionGate.shared.recordFeatureTipDisplayed(
            featureKey: FeatureTips.playbackModeRetapKey
        )
    }

    private func dismissPlaybackModeRetapTip() {
        withAnimation(bottomControlsAnimation) {
            showPlaybackModeRetapTip = false
        }
    }

    private func handleQueueTrackTap(_ track: Track) {
        playbackCoordinator.playTrackFromQueue(track)
    }

    private func handleCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        guard playbackCoordinator.presentation.source == .local else { return }
        LyricsSurfaceManager.shared.updatePlaybackTime(newTime)
        guard allowsDirectEmbeddedSurfaceUpdates else { return }
        fullscreenStore.setCurrentTime(newTime)
        if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
            coverBlurHighlightStore.setCurrentTime(newTime)
        }

        if oldTime > 1.0, newTime < 0.2 {
            reloadLyricsSurface(reason: "fullscreen playback restarted", forceLyricsReload: true)
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }

        cancelPendingFullscreenLyricsThemeWork()
        coverBlurLyricsTheme = nil
        if shouldClearDisplayedArtworkSnapshotOnTrackChange {
            artworkSnapshot = nil
        }
        syncFullscreenMiniPlayerSpectrumLease()

        // Simplified track change handling - matches window mode behavior
        // Apply track immediately without deferred scheduling
        syncFullscreenLyricsHostMount()
        reloadLyricsSurface(reason: "fullscreen track changed", forceLyricsReload: true)
    }

    private func handlePresentationCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        guard playbackCoordinator.presentation.source.isExternal else { return }
        LyricsSurfaceManager.shared.updatePlaybackTime(newTime)
        guard allowsDirectEmbeddedSurfaceUpdates else { return }
        fullscreenStore.setCurrentTime(newTime)
        if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
            coverBlurHighlightStore.setCurrentTime(newTime)
        }

        if oldTime > 1.0, newTime < 0.2 {
            reloadLyricsSurface(reason: "fullscreen external playback restarted", forceLyricsReload: true)
        }
    }

    private func handlePresentationLyricsIdentityChange(_ oldId: String?, _ newId: String?) {
        guard playbackCoordinator.presentation.source.isExternal else { return }
        guard oldId != newId else { return }
        cancelPendingFullscreenLyricsThemeWork()
        coverBlurLyricsTheme = nil
        if shouldClearDisplayedArtworkSnapshotOnTrackChange {
            artworkSnapshot = nil
        }
        syncFullscreenLyricsHostMount()
        reloadLyricsSurface(reason: "fullscreen external track changed", forceLyricsReload: true)
    }

    private func handleLibraryTrackDidUpdate(_ notification: Notification) {
        guard let trackID = notification.userInfo?["trackID"] as? UUID else {
            Log.info("[FullscreenLyricsReload] libraryTrackDidUpdate missing trackID", category: .webview)
            return
        }

        let currentTrackID = playerVM.currentTrack?.id ?? playbackCoordinator.presentation.localTrack?.id
        Log.info(
            "[FullscreenLyricsReload] libraryTrackDidUpdate received trackID=\(trackID.uuidString.prefix(8)), currentTrackID=\(currentTrackID?.uuidString.prefix(8) ?? "nil"), source=\(playbackCoordinator.presentation.source.rawValue), host=\(hostContext.rawValue)",
            category: .webview
        )

        guard playbackCoordinator.presentation.source == .local else { return }
        guard trackID == currentTrackID else { return }

        let refreshedTrack = FullscreenWindowManager.shared.libraryVM?.allTracks.first { $0.id == trackID }
        let playerLyricsLen = resolvedFullscreenLyricsText(for: playerVM.currentTrack).count
        let refreshedLyricsLen = refreshedTrack.map { resolvedFullscreenLyricsText(for: $0).count } ?? -1
        Log.info(
            "[FullscreenLyricsReload] matched current track refreshedTrack=\(refreshedTrack != nil), playerLyricsLen=\(playerLyricsLen), refreshedLyricsLen=\(refreshedLyricsLen)",
            category: .webview
        )

        syncFullscreenLyricsHostMount()
        reloadLyricsSurface(
            reason: "fullscreen library track update",
            forceLyricsReload: true,
            preferredLocalTrack: refreshedTrack,
            forceLocalLyricsReload: true
        )
    }

    private func cancelPendingFullscreenLyricsThemeWork() {
        pendingFullscreenLyricsRefresh?.cancel()
        pendingFullscreenLyricsRefresh = nil
        pendingFullscreenThemeReapply?.cancel()
        pendingFullscreenThemeReapply = nil
    }

    private func syncFullscreenMiniPlayerSpectrumLease() {
        let shouldKeepAlive = shouldKeepFullscreenMiniPlayerSpectrumAlive
        guard shouldKeepAlive != isFullscreenMiniPlayerSpectrumLeaseActive else {
            if shouldKeepAlive {
                let isPlaying = playbackCoordinator.activeSource.isExternal
                    ? playbackCoordinator.presentation.isPlaying
                    : playerVM.isPlaying
                miniPlayerSpectrumService.updatePlaybackState(isPlaying: isPlaying)
            }
            return
        }

        isFullscreenMiniPlayerSpectrumLeaseActive = shouldKeepAlive
        if shouldKeepAlive {
            miniPlayerSpectrumService.start()
            let isPlaying = playbackCoordinator.activeSource.isExternal
                ? playbackCoordinator.presentation.isPlaying
                : playerVM.isPlaying
            miniPlayerSpectrumService.updatePlaybackState(isPlaying: isPlaying)
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
        forceLyricsReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false,
        preferredLocalTrack: Track? = nil,
        forceLocalLyricsReload: Bool = false
    ) {
        syncCoverBlurHighlightActivation()

        let playbackPayload = updateFullscreenPlaybackSnapshot(
            preferredLocalTrack: preferredLocalTrack,
            forceLocalLyricsReload: forceLyricsReload || forceLocalLyricsReload
        )
        Log.info(
            "[FullscreenLyricsReload] reload reason=\(reason), forceLyricsReload=\(forceLyricsReload), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil"), ttmlLen=\(playbackPayload.ttml?.count ?? 0), ttmlHash=\(playbackPayload.ttml?.hashValue ?? 0), time=\(String(format: "%.3f", playbackPayload.currentTime)), playing=\(playbackPayload.isPlaying), host=\(hostContext.rawValue)",
            category: .webview
        )
        syncFullscreenLyricsAvailability(with: playbackPayload)
        if hostContext == .embeddedWindow && !embeddedInitialThemeUnlocked {
            Log.info(
                "[FullscreenLyricsReload] skipped embedded startup gate reason=\(reason), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil")",
                category: .webview
            )
            return
        }

        // Apply to fullscreen store directly
        let store = fullscreenStore
        if forceWebReload {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }
        setupSeekCallback()

        store.applyTrack(
            trackID: playbackPayload.trackID,
            ttml: playbackPayload.ttml,
            currentTime: playbackPayload.currentTime,
            isPlaying: playbackPayload.isPlaying
        )
        setupSeekCallback()

        if let palette = ThemeStore.shared.palette {
            store.applyTheme(palette)
        }

        syncCoverBlurHighlightSurface(
            playbackPayload: playbackPayload,
            forceWebReload: forceWebReload,
            recreateWebViewOnForceReload: recreateWebViewOnForceReload
        )
        if !pendingFullscreenLyricsBackgroundCapture {
            captureFullscreenLyricsBackgroundSnapshot()
        }
        applyFullscreenLyricsTheme()
    }

    private struct FullscreenPlaybackPayload {
        let trackID: UUID?
        let ttml: String?
        let currentTime: Double
        let isPlaying: Bool

        var hasDisplayableLyrics: Bool {
            ttml?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func updateFullscreenPlaybackSnapshot(
        preferredLocalTrack: Track? = nil,
        forceLocalLyricsReload: Bool = false
    ) -> FullscreenPlaybackPayload {
        let presentation = playbackCoordinator.presentation
        let payload: FullscreenPlaybackPayload

        switch presentation.source {
        case .local:
            let track = preferredLocalTrack ?? playerVM.currentTrack
            let lyricsText = resolvedFullscreenLyricsText(
                for: track,
                forceDiskReload: forceLocalLyricsReload
            )
            payload = FullscreenPlaybackPayload(
                trackID: track?.id,
                ttml: track == nil ? nil : lyricsText,
                currentTime: playerVM.currentTime,
                isPlaying: playerVM.isPlaying
            )
        case .appleMusic, .systemNowPlaying:
            let lyricsText = presentation.lyricsText
            payload = FullscreenPlaybackPayload(
                trackID: presentation.displayTrackID,
                ttml: lyricsText == nil ? nil : (lyricsText ?? ""),
                currentTime: presentation.currentTime,
                isPlaying: presentation.isPlaying
            )
        }

        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: payload.trackID,
            lyricsTTML: payload.ttml ?? "",
            currentTime: payload.currentTime,
            isPlaying: payload.isPlaying
        )

        return payload
    }

    private func resolvedFullscreenLyricsText(
        for track: Track?,
        forceDiskReload: Bool = false
    ) -> String {
        guard let track else { return "" }

        if forceDiskReload, !playerVM.isPlaying,
           let fileText = resolvedFullscreenLyricsTextFromDisk(for: track) {
            return fileText
        }

        let plain = track.lyricsText ?? track.loadLyricsIfNeeded()
        let userText = plain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !userText.isEmpty {
            return plain!
        }

        let ttml = track.ttmlLyricText ?? track.loadTTMLLyricsIfNeeded()
        let ttmlText = ttml?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ttmlText.isEmpty {
            return ttml!
        }

        return ""
    }

    private func resolvedFullscreenLyricsTextFromDisk(for track: Track) -> String? {
        if let lyricsURL = track.resolvedLyricsURL(),
           let text = try? String(contentsOf: lyricsURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let ttmlURL = track.resolvedTTMLURL(),
           let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return nil
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
        playbackPayload: FullscreenPlaybackPayload? = nil,
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

        let payload = playbackPayload ?? updateFullscreenPlaybackSnapshot()
        store.applyTrack(
            trackID: payload.trackID,
            ttml: payload.ttml,
            currentTime: payload.currentTime,
            isPlaying: payload.isPlaying
        )
    }


    private var fullscreenLyricsHostOpacity: Double {
        guard isShowingLyricsPanel, playbackCoordinator.presentation.hasTrack else { return 0 }
        if playbackCoordinator.presentation.source == .local,
           isCoverBlurFullscreenSkin && coverBlurLyricsTheme?.trackID != currentArtworkTrackID {
            return 0
        }
        return 1
    }

    private var shouldKeepFullscreenLyricsHostMounted: Bool {
        fullscreenLyricsHostMounted && playbackCoordinator.presentation.hasTrack
    }

    private var isFullscreenLyricsHostVisible: Bool {
        fullscreenLyricsHostOpacity > 0.001
    }

    private var fullscreenLyricsHostDetachDelay: TimeInterval {
        reduceMotion ? 0.22 : 0.72
    }

    private func syncFullscreenLyricsHostMount() {
        let shouldShowLyricsHost = isShowingLyricsPanel && playbackCoordinator.presentation.hasTrack

        pendingFullscreenLyricsHostDetach?.cancel()
        pendingFullscreenLyricsHostDetach = nil

        if shouldShowLyricsHost {
            fullscreenLyricsHostMounted = true
            return
        }

        guard fullscreenLyricsHostMounted else { return }
        scheduleFullscreenLyricsHostDetach(after: fullscreenLyricsHostDetachDelay)
    }

    private func scheduleFullscreenLyricsHostDetach(after delay: TimeInterval) {
        pendingFullscreenLyricsHostDetach?.cancel()

        let detachTrackID = currentDisplayContext.trackID
        let workItem = DispatchWorkItem {
            if isShowingLyricsPanel {
                pendingFullscreenLyricsHostDetach = nil
                return
            }
            if currentDisplayContext.trackID != detachTrackID {
                pendingFullscreenLyricsHostDetach = nil
                return
            }
            fullscreenLyricsHostMounted = false
            pendingFullscreenLyricsHostDetach = nil
        }
        pendingFullscreenLyricsHostDetach = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private var fullscreenLyricsViewportOpacity: Double {
        guard currentDisplayContext.hasTrack else { return 0 }
        if playbackCoordinator.presentation.source == .local,
           isCoverBlurFullscreenSkin && coverBlurLyricsTheme?.trackID != currentArtworkTrackID {
            return 0
        }
        return suppressFullscreenLyricsViewport ? 0 : 1
    }
    private func scheduleFullscreenLyricsViewportReveal(after delay: TimeInterval) {
        pendingFullscreenLyricsReveal?.cancel()

        let revealTrackID = currentDisplayContext.trackID
        let workItem = DispatchWorkItem {
            guard currentDisplayContext.trackID == revealTrackID else { return }
            withAnimation(lyricsLayoutAnimation) {
                suppressFullscreenLyricsViewport = false
            }
            pendingFullscreenLyricsReveal = nil
        }
        pendingFullscreenLyricsReveal = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func scheduleFullscreenTrackRefresh(
        layoutWillChange: Bool,
        revealLyricsAfterRefresh: Bool
    ) {
        pendingFullscreenTrackRefresh?.cancel()
        pendingFullscreenLyricsReveal?.cancel()
        pendingFullscreenLyricsReveal = nil

        let delay: TimeInterval = layoutWillChange ? (reduceMotion ? 0.20 : 0.34) : 0
        let workItem = DispatchWorkItem {
            reloadLyricsSurface(reason: "fullscreen track changed", forceLyricsReload: true)
            if revealLyricsAfterRefresh {
                let revealTrackID = currentDisplayContext.trackID
                let revealWorkItem = DispatchWorkItem {
                    guard currentDisplayContext.trackID == revealTrackID else { return }
                    suppressFullscreenLyricsViewport = false
                    pendingFullscreenLyricsReveal = nil
                }
                pendingFullscreenLyricsReveal = revealWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + (reduceMotion ? 0 : 1.0/60.0),
                    execute: revealWorkItem
                )
            } else {
                suppressFullscreenLyricsViewport = false
            }
            pendingFullscreenTrackRefresh = nil
        }

        pendingFullscreenTrackRefresh = workItem

        if delay <= 0 {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func applyFullscreenLyricsTheme(force: Bool = false, reason: String = "") {
        let themeIdentity = currentFullscreenLyricsThemeIdentity

        if hostContext == .embeddedWindow && !embeddedInitialThemeUnlocked {
            if EmbeddedFullscreenTrace.enabled {
                Log.info(
                    "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.skipTheme embedded-startup-pending reason=\(reason) currentScale=\(String(format: "%.4f", currentFullscreenScale)) viewport=\(fullscreenViewportSize)",
                    category: .fullscreen
                )
            }
            return
        }

        if EmbeddedFullscreenTrace.enabled, hostContext == .embeddedWindow {
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.applyTheme embedded force=\(force) reason=\(reason) currentScale=\(String(format: "%.4f", currentFullscreenScale)) viewport=\(fullscreenViewportSize)",
                category: .fullscreen
            )
        }
        let baseStore = fullscreenStore
        let surfaceRole = LyricsSurfaceRole.fullscreen
        let effectiveTrack = playbackCoordinator.presentation.localTrack
        let displayTrackID = currentArtworkTrackID
        let overlayContext: LyricsRuntimePresentationContext =
            hostContext == .embeddedWindow ? .fullscreenEmbedded : .fullscreenSystem
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: overlayContext,
            playbackSource: playbackCoordinator.presentation.source
        )
        let readyCoverBlurTheme = isCoverBlurFullscreenSkin
            ? updateCoverBlurLyricsThemeIfReady(forTrackID: displayTrackID)
            : nil
        let heldCoverBlurTheme = coverBlurLyricsTheme
        let appleStyleCoverBlurTheme = isAppleStyleFullscreenSkin
            ? makeAppleStyleCoverBlurLyricsTheme(forTrackID: displayTrackID)
            : nil
        let activeCoverBlurTheme: FullscreenCoverBlurLyricsTheme? = {
            if isAppleStyleFullscreenSkin {
                return appleStyleCoverBlurTheme
            }
            guard isCoverBlurFullscreenSkin else { return nil }
            if let readyCoverBlurTheme {
                return readyCoverBlurTheme
            }
            if let heldCoverBlurTheme {
                if heldCoverBlurTheme.trackID == displayTrackID {
                    return heldCoverBlurTheme
                }
            }
            return nil
        }()
        let colorSet = activeCoverBlurTheme?.colors
            ?? makeFullscreenLyricsColorSet(forTrackID: displayTrackID)

        if isCoverBlurFullscreenSkin, readyCoverBlurTheme == nil {
            if activeCoverBlurTheme == nil {
                guard isCurrentFullscreenLyricsThemeIdentity(themeIdentity) else {
                    Log.debug("FullscreenPlayerView: skipped stale lyrics theme clear reason=\(reason)", category: .webview)
                    return
                }
                LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                    nil,
                    for: .fullscreen,
                    trackID: themeIdentity.displayTrackID,
                    trackGuarded: true
                )
                baseStore.setThemePaletteOverride(nil)
                deactivateCoverBlurHighlightSurface()
                if let highlightStore = existingCoverBlurHighlightStore {
                    LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                        nil,
                        for: .fullscreenCoverBlurHighlight,
                        trackID: themeIdentity.displayTrackID,
                        trackGuarded: true
                    )
                    highlightStore.setThemePaletteOverride(nil)
                }
                return
            }
        }

        let activePalette = activeCoverBlurTheme.map { makeCoverBlurLyricsPalette(from: $0) }
            ?? makeFullscreenLyricsPalette(from: colorSet)
        guard isCurrentFullscreenLyricsThemeIdentity(themeIdentity) else {
            Log.debug("FullscreenPlayerView: skipped stale lyrics theme reason=\(reason)", category: .webview)
            return
        }

        LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
            activePalette,
            for: .fullscreen,
            trackID: themeIdentity.displayTrackID,
            trackGuarded: true
        )
        baseStore.setThemePaletteOverride(activePalette)
        if shouldRenderCoverBlurHighlightOverlay, let highlightStore = existingCoverBlurHighlightStore {
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                activePalette,
                for: .fullscreenCoverBlurHighlight,
                trackID: themeIdentity.displayTrackID,
                trackGuarded: true
            )
            highlightStore.setThemePaletteOverride(activePalette)
        }
        let mainFontFamily = cssFontFamily([
            settings.fullscreenLyricsFontNameEn,
            settings.fullscreenLyricsFontNameZh,
        ])
        let translationFontFamily = cssFontFamily([
            settings.fullscreenLyricsTranslationFontName
        ])
        let mainActiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.mainActive,
            alpha: 1.0
        )
        let mainInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.mainInactive,
            alpha: 1.0
        )
        let subActiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.subActive,
            alpha: 1.0
        )
        let subInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.subInactive,
            alpha: 1.0
        )
        let lineTimingMainInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.lineTimingMainInactive,
            alpha: 1.0
        )
        let lineTimingSubInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.lineTimingSubInactive,
            alpha: 1.0
        )
        let backgroundColor = ArtworkColorExtractor.cssRGBA(
            colorSet.subActive,
            alpha: 1.0
        )
        let coverBlurThemeColor = activeCoverBlurTheme.map {
            ArtworkColorExtractor.cssRGBA($0.themeColor, alpha: 1.0)
        }
        let trackOffsetMs = max(-15000, min(15000, effectiveTrack?.lyricsTimeOffsetMs ?? 0))
        let effectiveGlobalAdvanceMs = max(
            -5000,
            min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
        )
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - effectiveGlobalAdvanceMs))

        

        // Scale base sizes with fullscreen metrics first, then apply runtime presentation overlay.
        // For embedded fullscreen, this keeps +6/+4 as a visible on-screen delta instead of being
        // attenuated by the scale factor.
        let scaledBaseFontSize = settings.fullscreenLyricsFontSize * currentFullscreenScale
        let scaledBaseTranslationFontSize =
            settings.fullscreenLyricsTranslationFontSize * currentFullscreenScale
        let scaledFontSize = scaledBaseFontSize + overlay.mainFontSizeDeltaPx
        let scaledTranslationFontSize =
            scaledBaseTranslationFontSize + overlay.translationFontSizeDeltaPx

        if EmbeddedFullscreenTrace.enabled, hostContext == .embeddedWindow {
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.embeddedFont overlay=(\(String(format: "%.1f", overlay.mainFontSizeDeltaPx)),\(String(format: "%.1f", overlay.translationFontSizeDeltaPx))) baseSetting=(\(String(format: "%.1f", settings.fullscreenLyricsFontSize)),\(String(format: "%.1f", settings.fullscreenLyricsTranslationFontSize))) scaledBase=(\(String(format: "%.2f", scaledBaseFontSize)),\(String(format: "%.2f", scaledBaseTranslationFontSize))) scaled=(\(String(format: "%.2f", scaledFontSize)),\(String(format: "%.2f", scaledTranslationFontSize)))",
                category: .fullscreen
            )
        }

        var config: [String: Any] = [
            "fontSize": scaledFontSize,
            "fontWeight": max(100, min(900, settings.fullscreenLyricsFontWeight)),
            "fontFamilyMain": mainFontFamily,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": scaledTranslationFontSize,
            "translationFontWeight": max(
                100,
                min(900, settings.fullscreenLyricsTranslationFontWeight)
            ),
            "renderScale": surfaceRole.renderScale,
            "enableBlur": surfaceRole.enableBlur,
            "enableSpring": surfaceRole.enableSpring,
            "fpsCap": surfaceRole.fpsCap,
            "overscanPx": surfaceRole.overscanPx,
            "wordFadeWidth": surfaceRole.wordFadeWidth,
            "wordHighlightMode": settings.amllDiscreteWordHighlightEnabled ? "discrete" : "smooth",
            "mixBlendMode": "normal",
            "blendOpacity": 1.0,
            "fullscreenActiveColor": mainActiveColor,
            "fullscreenInactiveColor": mainInactiveColor,
            "fullscreenSubActiveColor": subActiveColor,
            "fullscreenSubInactiveColor": subInactiveColor,
            "fullscreenBackgroundColor": backgroundColor,
            "fullscreenLineTimingInactiveColor": lineTimingMainInactiveColor,
            "fullscreenLineTimingSubInactiveColor": lineTimingSubInactiveColor,
            "alignAnchor": "top",
            // Hidden-state fix: Restore to higher position (was 0.32, too low).
            // Visible state left unchanged at 0.18 (already correct).
            "alignPosition": isFullscreenBottomControlsVisible ? 0.18 : 0.20,
            "alignOffset": 0,
            "lineHeight": 1.8,
            "activeScale": 1.2,
            "leadInMs": max(0, settings.lyricsLeadInMs),
            "nearSwitchGapMs": max(0, min(500, settings.lyricsNearSwitchGapMs)),
            "timeOffsetMs": combinedOffsetMs,
            "seekTimeOffsetMs": trackOffsetMs,
        ]

        config["fullscreenLyricDodgeMode"] = true
        config["fullscreenAppleStyleMode"] = false
        config["fullscreenCoverBlurMode"] = false
        config["coverBlurFullscreenGenericMode"] = usesCoverBlurLyricsRenderingPath && activeCoverBlurTheme != nil
        config["coverBlurFullscreenGenericProfile"] = activeCoverBlurTheme?.profile.rawValue ?? NSNull()
        config["coverBlurFullscreenThemeColor"] = coverBlurThemeColor ?? NSNull()
        if activeCoverBlurTheme != nil {
            config["coverBlurMainActiveColor"] = mainActiveColor
            config["coverBlurMainInactiveColor"] = mainInactiveColor
            config["coverBlurSubActiveColor"] = subActiveColor
            config["coverBlurSubInactiveColor"] = subInactiveColor
            config["coverBlurBackgroundColor"] = backgroundColor
            config["coverBlurLineTimingInactiveColor"] = lineTimingMainInactiveColor
            config["coverBlurLineTimingSubInactiveColor"] = lineTimingSubInactiveColor
        }

        let shouldUseHighlightOverlay = shouldRenderCoverBlurHighlightOverlay
        if shouldUseHighlightOverlay {
            activateCoverBlurHighlightSurface()
            syncCoverBlurHighlightSurface()
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                activePalette,
                for: .fullscreenCoverBlurHighlight,
                trackID: themeIdentity.displayTrackID,
                trackGuarded: true
            )
            coverBlurHighlightStore.setThemePaletteOverride(activePalette)
        } else {
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                nil,
                for: .fullscreenCoverBlurHighlight,
                trackID: themeIdentity.displayTrackID,
                trackGuarded: true
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
        pushFullscreenLyricsConfig(
            baseConfig,
            to: baseStore,
            identity: themeIdentity,
            force: force,
            reason: reason,
            probeLabel: "fullscreen-\(probeMode)-base-\(probeReason)",
            probeDelay: probeDelay
        )

        guard shouldUseHighlightOverlay else { return }

        config["coverBlurSuppressEmphasisGlow"] = false
        pushFullscreenLyricsConfig(
            config,
            to: coverBlurHighlightStore,
            identity: themeIdentity,
            force: force,
            reason: reason,
            probeLabel: "fullscreen-\(probeMode)-highlight-\(probeReason)",
            probeDelay: probeDelay
        )
    }

    private func pushFullscreenLyricsConfig(
        _ config: [String: Any],
        to store: LyricsWebViewStore,
        identity: FullscreenLyricsThemeIdentity,
        force: Bool,
        reason: String,
        probeLabel: String,
        probeDelay: TimeInterval
    ) {
        guard isCurrentFullscreenLyricsThemeIdentity(identity) else {
            Log.debug("FullscreenPlayerView: skipped stale lyrics config role=\(store.role) reason=\(reason)", category: .webview)
            return
        }

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            if let role = LyricsSurfaceRole(rawValue: store.role) {
                LyricsSurfaceManager.shared.updateSurfaceConfigSnapshot(
                    json,
                    for: role,
                    trackID: identity.displayTrackID,
                    trackGuarded: true
                )
            }
            guard isCurrentFullscreenLyricsThemeIdentity(identity) else {
                Log.debug("FullscreenPlayerView: skipped stale lyrics config delivery role=\(store.role) reason=\(reason)", category: .webview)
                return
            }
            if force {
                store.forceSetConfigJSON(json, reason: reason)
            } else {
                store.setConfigJSON(json)
            }
            store.scheduleDebugVisibleLayerProbe(label: probeLabel, delay: probeDelay)
        }
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

    private func resetFullscreenLyricsBackgroundSnapshot() {
        lockedFullscreenLyricsBackgroundColor = nil
        lockedFullscreenLyricsUltraDark = false
        pendingFullscreenLyricsBackgroundCapture = false
    }

    private func scheduleFullscreenLyricsBackgroundCapture() {
        pendingFullscreenLyricsBackgroundCapture =
            settings.fullscreenArtBackgroundEnabled && currentDisplayContext.hasTrack
    }

    private func captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: Bool = false) {
        guard settings.fullscreenArtBackgroundEnabled else {
            resetFullscreenLyricsBackgroundSnapshot()
            return
        }

        guard bkController.lyricsColorTrackID == currentArtworkTrackID else {
            pendingFullscreenLyricsBackgroundCapture = currentDisplayContext.hasTrack
            return
        }

        if preferLiveSurface {
            lockedFullscreenLyricsBackgroundColor =
                bkController.currentSurfaceBackgroundColor ?? bkController.primaryBackgroundColor
        } else {
            lockedFullscreenLyricsBackgroundColor =
                bkController.primaryBackgroundColor ?? bkController.currentSurfaceBackgroundColor
        }
        lockedFullscreenLyricsUltraDark = bkController.isUltraDarkActive
        pendingFullscreenLyricsBackgroundCapture = false
    }

    private func refreshFullscreenLyricsColors() {
        pendingFullscreenLyricsRefresh?.cancel()
        pendingFullscreenLyricsRefresh = nil
        resetFullscreenLyricsBackgroundSnapshot()
        captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)
        applyFullscreenLyricsTheme()
    }

    private func forceRefreshFullscreenLyricsColors(reason: String) {
        pendingFullscreenLyricsRefresh?.cancel()
        pendingFullscreenLyricsRefresh = nil

        resetFullscreenLyricsBackgroundSnapshot()
        captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)
        applyFullscreenLyricsTheme(force: true, reason: reason)

        let delayedReason = reason
        let delayedWorkItem = DispatchWorkItem {
            resetFullscreenLyricsBackgroundSnapshot()
            captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)
            applyFullscreenLyricsTheme(force: true, reason: "\(delayedReason)-delayed")
            pendingFullscreenLyricsRefresh = nil
        }

        pendingFullscreenLyricsRefresh = delayedWorkItem
        let delay: TimeInterval = 0.22
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: delayedWorkItem)
    }

    private func scheduleFullscreenLyricsRefresh(preferLiveSurface: Bool) {
        pendingFullscreenLyricsRefresh?.cancel()

        let workItem = DispatchWorkItem { [preferLiveSurface] in
            captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: preferLiveSurface)
            applyFullscreenLyricsTheme()
            pendingFullscreenLyricsRefresh = nil
        }

        pendingFullscreenLyricsRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func handleEmbeddedFullscreenViewportChange(_ size: CGSize, reason: String) {
        let previousViewportSize = fullscreenViewportSize
        fullscreenViewportSize = size

        guard hostContext == .embeddedWindow else { return }
        guard size.width > 1, size.height > 1 else { return }

        currentFullscreenScale = min(
            size.width / Self.baseCanvasWidth,
            size.height / Self.baseCanvasHeight
        )

        if !embeddedInitialThemeUnlocked {
            if !isValidEmbeddedFullscreenGeometry(size, scale: currentFullscreenScale) {
                if let fallbackSize = currentEmbeddedHostWindowContentSize(),
                   fallbackSize != size
                {
                    let fallbackScale = min(
                        fallbackSize.width / Self.baseCanvasWidth,
                        fallbackSize.height / Self.baseCanvasHeight
                    )
                    if isValidEmbeddedFullscreenGeometry(fallbackSize, scale: fallbackScale) {
                        fullscreenViewportSize = fallbackSize
                        currentFullscreenScale = fallbackScale
                        beginEmbeddedFullscreenStartupIfNeeded(reason: "embedded-first-valid-window-size")
                    }
                }
                return
            }
            beginEmbeddedFullscreenStartupIfNeeded(reason: "embedded-first-valid-geometry")
            return
        }

        guard isValidEmbeddedFullscreenGeometry(size, scale: currentFullscreenScale) else {
            return
        }

        let sizeChanged =
            abs(size.width - previousViewportSize.width) > 0.5
            || abs(size.height - previousViewportSize.height) > 0.5
        guard sizeChanged else { return }

        pendingFullscreenThemeReapply?.cancel()

        let workItem = DispatchWorkItem {
            applyFullscreenLyricsTheme(force: true, reason: reason)
            pendingFullscreenThemeReapply = nil
        }

        pendingFullscreenThemeReapply = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func currentEmbeddedHostWindowContentSize() -> CGSize? {
        guard hostContext == .embeddedWindow else { return nil }

        let candidateWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard let window = candidateWindow else { return nil }
        let contentSize = window.contentLayoutRect.size
        guard contentSize.width > 1, contentSize.height > 1 else { return nil }
        return contentSize
    }

    private func beginEmbeddedFullscreenStartupIfNeeded(reason: String) {
        guard hostContext == .embeddedWindow else { return }
        guard !embeddedInitialThemeUnlocked else { return }
        guard isValidEmbeddedFullscreenGeometry(fullscreenViewportSize, scale: currentFullscreenScale) else {
            return
        }

        syncCoverBlurHighlightActivation()
        resetFullscreenLyricsBackgroundSnapshot()
        scheduleFullscreenLyricsBackgroundCapture()
        captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)

        if let palette = ThemeStore.shared.palette {
            fullscreenStore.applyTheme(palette)
        }

        embeddedInitialThemeUnlocked = true
        startFullscreenLyricsSurface(reason: reason)
    }

    private func isValidEmbeddedFullscreenGeometry(_ size: CGSize, scale: CGFloat) -> Bool {
        guard hostContext == .embeddedWindow else { return true }

        let minimumWidth = Constants.Layout.detailContentMinWidth
        let minimumHeight = minimumWidth * (Self.baseCanvasHeight / Self.baseCanvasWidth)
        let minimumScale = minimumWidth / Self.baseCanvasWidth

        return size.width >= minimumWidth
            && size.height >= minimumHeight
            && scale >= minimumScale
    }

    private func isRenderableFullscreenGeometry(_ size: CGSize, scale: CGFloat) -> Bool {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite else { return false }
        guard size.width > 1, size.height > 1, scale > 0 else { return false }
        return isValidEmbeddedFullscreenGeometry(size, scale: scale)
    }

    private func makeContext(windowSize: CGSize, artworkColumnWidth: CGFloat, fullscreenScale: CGFloat = 1.0) -> SkinContext {
        let display = currentDisplayContext

        let trackMeta: SkinContext.TrackMetadata? = display.hasTrack
            ? SkinContext.TrackMetadata(
                id: display.artworkTrackID ?? display.trackID ?? Self.fallbackExternalTrackID,
                title: display.title,
                artist: display.artist,
                album: display.album ?? "",
                duration: display.duration,
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: display.artworkData,
                artworkImage: artworkSnapshot?.fullImage
            )
            : nil

        let playback = SkinContext.PlaybackState(
            isPlaying: display.isPlaying,
            currentTime: display.currentTime,
            duration: display.duration,
            progress: display.duration > 0 ? display.currentTime / display.duration : 0
        )

        let theme = SkinContext.ThemeTokens(
            accentColor: themeStore.accentColor,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            glassIntensity: AppSettings.shared.liquidGlassIntensity,
            backgroundBlur: AppSettings.shared.nowPlayingBackgroundBlur,
            backgroundBrightness: AppSettings.shared.nowPlayingBackgroundBrightness,
            backgroundSaturation: AppSettings.shared.nowPlayingBackgroundSaturation,
            meshAmplitude: AppSettings.shared.nowPlayingMeshAmplitude,
            meshFlowSpeed: AppSettings.shared.nowPlayingMeshFlowSpeed,
            meshSharpness: AppSettings.shared.nowPlayingMeshSharpness,
            meshSoftness: AppSettings.shared.nowPlayingMeshSoftness,
            meshColorBoost: AppSettings.shared.nowPlayingMeshColorBoost,
            meshContrast: AppSettings.shared.nowPlayingMeshContrast,
            meshBassImpact: AppSettings.shared.nowPlayingMeshBassImpact,
            artworkAccentColor: artworkSnapshot?.accentColor.map { Color(nsColor: $0) },
            artworkPalette: artworkSnapshot?.palette ?? [],
            artworkRichPalette: artworkSnapshot?.richPalette ?? [],
            artworkAverageColor: artworkSnapshot?.averageColor,
            artBackgroundIsUltraDark: settings.fullscreenArtBackgroundEnabled
                && bkController.isUltraDarkActive,
            kickToBrightnessMix: AppSettings.shared.bgKickToBrightnessMix,
            kickDisplaceAmount: AppSettings.shared.bgKickDisplaceAmount,
            kickScaleAmount: AppSettings.shared.bgKickScaleAmount
        )

        let contentBounds = CGRect(
            origin: .zero,
            size: CGSize(width: artworkColumnWidth, height: windowSize.height * 0.62)
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            audio: ledMeterProvider.getOrCreate().audioMetrics,
            led: ledMeterProvider.getOrCreate().metrics,
            theme: theme,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: fullscreenScale,
            lyricsVisible: isShowingRightPanel,
            presentationMode: .fullscreenPlayer,
            fullscreenHostMode: hostContext == .embeddedWindow ? .embeddedWindow : .systemFullscreen
        )
    }

    private func fullscreenLyricsMask(
        visibleHeight: CGFloat,
        topFade: CGFloat,
        bottomFade: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: topFade)

            Rectangle()
                .fill(.black)
                .frame(height: max(0, visibleHeight - topFade - bottomFade))

            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottomFade)
        }
    }

    private func cssFontFamily(_ names: [String]) -> String {
        let sanitized =
            names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { name in
                "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
        let fallbacks = ["-apple-system", "\"Helvetica Neue\"", "sans-serif"]
        return (sanitized + fallbacks).joined(separator: ", ")
    }

    private func layoutMetrics(for windowSize: CGSize) -> FullscreenHorizontalSplitLayout {
        layoutMetrics(showLyricsColumn: isShowingRightPanel, windowWidth: windowSize.width)
    }

    private func fullscreenBackgroundAvoidanceRect(in windowSize: CGSize) -> CGRect? {
        guard isShowingRightPanel else { return nil }

        let splitLayout = layoutMetrics(for: windowSize)
        let rectX = splitLayout.lyricsLeadingX + fullscreenBackgroundLyricsAvoidanceHorizontalInset
        let rectY = fullscreenBackgroundLyricsAvoidanceTopInset
        let rectWidth = max(
            0,
            splitLayout.lyricsWidth - fullscreenBackgroundLyricsAvoidanceHorizontalInset * 2
        )
        let rectHeight = max(
            0,
            windowSize.height
                - fullscreenBackgroundLyricsAvoidanceTopInset
                - fullscreenBackgroundLyricsAvoidanceBottomInset
        )

        guard rectWidth > 1, rectHeight > 1 else { return nil }
        return CGRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight)
    }

    private func makeLyricsPalette(
        from colors: FullscreenLyricsColorSet,
        scheme: ColorScheme
    ) -> ThemePalette {
        let active = ArtworkColorExtractor.cssRGBA(colors.mainActive, alpha: 1.0)
        let inactive = ArtworkColorExtractor.cssRGBA(colors.mainInactive, alpha: 1.0)

        return ThemePalette(
            scheme: scheme,
            background: "rgba(0,0,0,0)",
            text: active,
            activeLine: active,
            inactiveLine: inactive
        )
    }

    private func makeFullscreenLyricsPalette(from colors: FullscreenLyricsColorSet) -> ThemePalette {
        makeLyricsPalette(from: colors, scheme: .dark)
    }

    private func makeCoverBlurLyricsPalette(from theme: FullscreenCoverBlurLyricsTheme) -> ThemePalette {
        let active = ArtworkColorExtractor.cssRGBA(theme.colors.mainActive, alpha: 1.0)
        let inactive = ArtworkColorExtractor.cssRGBA(
            theme.colors.mainInactive,
            alpha: 1.0
        )
        return ThemePalette(
            scheme: theme.profile.paletteScheme,
            background: "rgba(0,0,0,0)",
            text: active,
            activeLine: active,
            inactiveLine: inactive
        )
    }

    private func makeFullscreenLyricsColorSet(forTrackID trackID: UUID?) -> FullscreenLyricsColorSet {
        SemanticPaletteFactory.fullscreenLyricsColorSet(
            analysis: resolveLyricsAnalysis(forTrackID: trackID),
            scheme: colorScheme,
            highlightBaseColor: resolveFullscreenLyricsBaseColor(forTrackID: trackID),
            inactiveBaseColor: resolveFullscreenLyricsInactiveBaseColor(forTrackID: trackID),
            isUltraDark: lockedFullscreenLyricsUltraDark,
            usesArtisticBackground: settings.fullscreenArtBackgroundEnabled
        )
    }

    private func makeCoverBlurLyricsColorSet(
        from themeColor: NSColor,
        profile: FullscreenCoverBlurBlendProfile
    ) -> FullscreenLyricsColorSet {
        SemanticPaletteFactory.coverBlurLyricsColorSet(
            analysis: resolveLyricsAnalysis(forTrackID: currentArtworkTrackID),
            themeColor: themeColor,
            profile: profile
        )
    }

    private func currentArtworkSnapshot(for track: Track?) -> ArtworkAssetSnapshot? {
        guard let track else { return nil }
        return currentArtworkSnapshot(forTrackID: track.id)
    }

    private func currentArtworkSnapshot(forTrackID trackID: UUID?) -> ArtworkAssetSnapshot? {
        guard let trackID, let snapshot = artworkSnapshot, snapshot.trackID == trackID else {
            return nil
        }
        return snapshot
    }

    private func currentArtworkSnapshotForDisplay() -> ArtworkAssetSnapshot? {
        guard let trackID = currentArtworkTrackID,
              let snapshot = artworkSnapshot,
              snapshot.trackID == trackID else {
            return nil
        }
        return snapshot
    }

    private func resolveCoverBlurThemeColor(forTrackID trackID: UUID?) -> NSColor? {
        guard let snapshot = currentArtworkSnapshot(forTrackID: trackID) else {
            return nil
        }

        return snapshot.averageColor ?? snapshot.dominantColor ?? snapshot.accentColor
    }

    private func makeCoverBlurLyricsTheme(forTrackID trackID: UUID?) -> FullscreenCoverBlurLyricsTheme? {
        guard let trackID, let themeColor = resolveCoverBlurThemeColor(forTrackID: trackID) else {
            return nil
        }

        let themeHSL = ColorMath.hsl(of: themeColor)
        let profile: FullscreenCoverBlurBlendProfile = themeHSL.l > 0.72
            ? .darker
            : .lighter

        return FullscreenCoverBlurLyricsTheme(
            trackID: trackID,
            themeColor: themeColor,
            themeLightness: themeHSL.l,
            profile: profile,
            colors: makeCoverBlurLyricsColorSet(from: themeColor, profile: profile)
        )
    }

    private func makeAppleStyleCoverBlurLyricsTheme(forTrackID trackID: UUID?) -> FullscreenCoverBlurLyricsTheme {
        let resolvedTrackID = trackID ?? Self.fallbackExternalTrackID
        let themeColor = resolveFullscreenLyricsBaseColor(forTrackID: trackID)
        let themeHSL = ColorMath.hsl(of: themeColor)
        let profile: FullscreenCoverBlurBlendProfile = .lighter

        return FullscreenCoverBlurLyricsTheme(
            trackID: resolvedTrackID,
            themeColor: themeColor,
            themeLightness: themeHSL.l,
            profile: profile,
            colors: makeCoverBlurLyricsColorSet(from: themeColor, profile: profile)
        )
    }

    private func updateCoverBlurLyricsThemeIfReady(
        forTrackID trackID: UUID?
    ) -> FullscreenCoverBlurLyricsTheme? {
        guard let resolvedTheme = makeCoverBlurLyricsTheme(forTrackID: trackID) else {
            return nil
        }

        let previousTrackID = coverBlurLyricsTheme?.trackID
        let previousProfile = coverBlurLyricsTheme?.profile
        let previousLightness = coverBlurLyricsTheme?.themeLightness ?? -1
        let themeChanged = previousTrackID != resolvedTheme.trackID
            || previousProfile != resolvedTheme.profile
            || abs(previousLightness - resolvedTheme.themeLightness) > 0.000_1

        if themeChanged {
            coverBlurLyricsTheme = resolvedTheme
        }

        return resolvedTheme
    }

    private func resolveFullscreenLyricsBaseColor(forTrackID trackID: UUID?) -> NSColor {
        if themeStorePaletteMatchesCurrentArtwork(forTrackID: trackID) {
            return themeStore.semanticPalette.fullscreenLyricBase
        }

        if let snapshot = currentArtworkSnapshot(forTrackID: trackID) ?? currentArtworkSnapshotForDisplay() {
            return snapshot.accentColor ?? snapshot.averageColor ?? snapshot.dominantColor
                ?? NSColor(AppSettings.shared.accentColor)
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    private func resolveFullscreenLyricsInactiveBaseColor(forTrackID trackID: UUID?) -> NSColor {
        // Phase 6 v2 contract: art surface background colours
        // (`bkController.currentSurfaceBackgroundColor`,
        // `primaryBackgroundColor`, `lockedFullscreenLyricsBackgroundColor`)
        // are readability calibration inputs only — they must NOT be used as
        // the seed for inactive lyric colours. Doing so collapses inactive
        // chroma toward neutral and was the root cause of the Phase 6 v1
        // "grey-wash" regression. Inactive lyric colour is now derived from
        // the artwork semantic palette in the same way as the Phase 5 path.

        if themeStorePaletteMatchesCurrentArtwork(forTrackID: trackID) {
            return themeStore.semanticPalette.fullscreenLyricInactiveBase
        }

        if let snapshot = currentArtworkSnapshot(forTrackID: trackID) ?? currentArtworkSnapshotForDisplay() {
            return snapshot.averageColor ?? snapshot.dominantColor ?? snapshot.accentColor
                ?? NSColor(AppSettings.shared.accentColor)
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    private func resolveLyricsAnalysis(forTrackID trackID: UUID?) -> ArtworkColorAnalysis {
        if themeStorePaletteMatchesCurrentArtwork(forTrackID: trackID) {
            return themeStore.semanticPalette.analysis
        }
        return .neutralFallback
    }

    private func themeStorePaletteMatchesCurrentArtwork(forTrackID trackID: UUID?) -> Bool {
        let display = currentDisplayContext
        let checksum = ArtworkAssetStore.checksum(for: display.artworkData)
        let identity = display.artworkIdentity ?? display.lyricsIdentity
        let expectedTrackID = trackID ?? display.artworkTrackID ?? display.trackID
        return themeStore.paletteMatches(
            trackID: expectedTrackID,
            artworkIdentity: identity,
            artworkChecksum: checksum
        )
    }
    
    private var currentArtworkTaskKey: String {
        let display = currentDisplayContext
        guard display.hasTrack, let trackID = display.artworkTrackID else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: display.artworkData)
        let identity = display.artworkIdentity ?? display.lyricsIdentity ?? trackID.uuidString
        return "\(trackID.uuidString)-\(identity)-\(checksum)-px:\(preferredArtworkFullImageMaxPixel)"
    }
    
    private func loadArtworkSnapshot() async {
        let display = currentDisplayContext
        guard let trackID = display.artworkTrackID,
              let artworkData = display.artworkData,
              !artworkData.isEmpty
        else {
            if shouldClearDisplayedArtworkSnapshotOnTrackChange {
                artworkSnapshot = nil
            }
            return
        }

        let expectedTrackID = trackID
        let expectedTaskKey = currentArtworkTaskKey
        let snapshot = await ArtworkAssetStore.shared.snapshot(
            trackID: trackID,
            artworkData: artworkData,
            fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
        )
        guard !Task.isCancelled else { return }
        guard currentArtworkTrackID == expectedTrackID else { return }
        guard currentArtworkTaskKey == expectedTaskKey else { return }
        guard snapshot?.trackID == expectedTrackID else { return }

        artworkSnapshot = snapshot

        // CRITICAL: Trigger AMLL theme refresh after artwork colors are loaded
        // Without this, fullscreen lyrics colors would not update when track changes
        applyFullscreenLyricsTheme(reason: "artworkSnapshot-loaded")
    }

    private var preferredArtworkFullImageMaxPixel: Int {
        1_400
    }

    private var shouldClearDisplayedArtworkSnapshotOnTrackChange: Bool {
        let presentation = playbackCoordinator.presentation
        guard presentation.source.isExternal else { return true }
        return !presentation.isArtworkLoading
    }

}

private struct PlaybackModeRetapTipView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("播放队列")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            Text("再次点击已选择的播放顺序按钮，可快速展开播放队列")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 288, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct FullscreenMiniPlayerOcclusionRegion: Equatable {
    static let inactive = FullscreenMiniPlayerOcclusionRegion(
        rect: .zero,
        cornerRadius: 0,
        isEnabled: false
    )

    let rect: CGRect
    let cornerRadius: CGFloat
    let isEnabled: Bool

    func contains(_ point: CGPoint) -> Bool {
        guard isEnabled, rect.contains(point) else { return false }

        let radius = min(cornerRadius, rect.width * 0.5, rect.height * 0.5)
        guard radius > 0 else { return true }

        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ).contains(point)
    }
}

@MainActor
private final class FullscreenPointerOcclusionMonitor {
    private weak var window: NSWindow?
    private var region: FullscreenMiniPlayerOcclusionRegion = .inactive
    private var eventMonitor: Any?
    private var onOcclusionChanged: ((Bool) -> Void)?
    private var isOccluded = false

    func setWindow(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.acceptsMouseMovedEvents = true
        refreshFromCurrentMouseLocation()
    }

    func start(onOcclusionChanged: @escaping (Bool) -> Void) {
        self.onOcclusionChanged = onOcclusionChanged
        if window == nil, let keyWindow = NSApp.keyWindow {
            setWindow(keyWindow)
        }
        guard eventMonitor == nil else {
            refreshFromCurrentMouseLocation()
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseEntered,
                .mouseExited,
                .mouseMoved,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged
            ]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }

        refreshFromCurrentMouseLocation()
    }

    func stop() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        updateOcclusion(false)
        onOcclusionChanged = nil
        window = nil
        region = .inactive
    }

    func updateRegion(_ region: FullscreenMiniPlayerOcclusionRegion) {
        self.region = region
        refreshFromCurrentMouseLocation()
    }

    private func handle(_ event: NSEvent) {
        if window == nil, let eventWindow = event.window {
            setWindow(eventWindow)
        }
        guard let window, event.window === window else {
            updateOcclusion(false)
            return
        }
        updateOcclusion(region.contains(event.locationInWindow))
    }

    private func refreshFromCurrentMouseLocation() {
        guard let window else {
            updateOcclusion(false)
            return
        }
        updateOcclusion(region.contains(window.mouseLocationOutsideOfEventStream))
    }

    private func updateOcclusion(_ nextValue: Bool) {
        guard nextValue != isOccluded else { return }
        isOccluded = nextValue
        onOcclusionChanged?(nextValue)
    }
}

// MARK: - Preview

#Preview("Fullscreen Player") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let lyricsVM = LyricsViewModel()
    let ledMeter = LEDMeterService()
    let skinManager = SkinManager()

    let track = Track(
        title: "Blinding Lights",
        artist: "The Weeknd",
        album: "After Hours",
        duration: 203,
        fileBookmarkData: Data()
    )

    FullscreenPlayerView {
        print("Exit fullscreen")
    }
    .environment(playerVM)
    .environment(lyricsVM)
    .environment(ledMeter)
    .environment(skinManager)
    .environmentObject(ThemeStore.shared)
    .frame(width: 1600, height: 1000)
    .onAppear {
        playerVM.playTracks([track])
    }
}

//
//  FullscreenPlayerView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Player View
//  Fullscreen mode with enlarged skin, lyrics (overlay on background), and controls.
//

import AppKit
import Combine
import Foundation
import MotionKit
import SwiftUI

/// Reusable fullscreen-player content view with enlarged skin artwork (left),
/// Native lyrics (right, no material), and enlarged miniplayer controls at bottom.
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
    private typealias FullscreenLyricPalette = FullscreenLyricSemanticPalette
    private typealias FullscreenCoverBlurBlendProfile = LyricsCoverBlurBlendProfile

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

    /// Value signature for the event-driven local-readability cache. Keeping it
    /// as a small Equatable value avoids allocating and concatenating a long
    /// string on every high-frequency SwiftUI body evaluation.
    private struct LocalPolarityInputSignature: Equatable {
        let isCoverBlurSkin: Bool
        let artworkChecksum: UInt64
        let leadingRenderKey: String?
        let centeredRenderKey: String?
        let transitionRenderKey: String?
        let viewportSize: CGSize
        let fullscreenScale: CGFloat
        let darkForegroundHash: Int
        let lightForegroundHash: Int
        let overlayDarkForegroundHash: Int
        let overlayLightForegroundHash: Int
    }

    private enum RightPanelDisplayState {
        case hidden
        case lyrics
        case queue
    }

    private let topContentHorizontalPadding: CGFloat = 0
    private let lyricsViewportTopLift: CGFloat = 32 // Compensated 10pt upward (was 22)
    private let lyricsViewportTopCropDown: CGFloat = 38 // Shift the top edge of the mask down by 38pt
    private let fullscreenBackgroundLyricsAvoidanceHorizontalInset: CGFloat = 28
    private let fullscreenBackgroundLyricsAvoidanceTopInset: CGFloat = 36
    private let fullscreenBackgroundLyricsAvoidanceBottomInset: CGFloat = 60
    private let fullscreenLyricsAlignPosition: Double = 0.18  // Current line higher in viewport (was 0.28)
    private let fullscreenLyricsAutoHideTrailingGap: TimeInterval = 15.0
    private let fullscreenLyricsAutoHideDelayAfterFinalLine: TimeInterval = 2.0
    private let fullscreenLyricsAutoRestoreReason = "fullscreen lyrics auto-restored after ending"
    private let coverBlurLegacyTopContentLeftShift: CGFloat = 44
    private let coverBlurLegacyArtworkLyricsColumnSpacing: CGFloat = -58
    private let coverBlurLegacyLyricsColumnLeftNudge: CGFloat = 80
    private let coverBlurLegacyLyricsRightShift: CGFloat = 30
    private let coverBlurLegacyLeftExpansion: CGFloat = 80
    private let duplicateLyricsReloadCoalesceInterval: TimeInterval = 0.75

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LibraryViewModel.self) private var libraryVM: LibraryViewModel?
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(LEDMeterServiceProvider.self) private var ledMeterProvider
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.motionTokens) private var motionTokens
    @Environment(\.motionPolicy) private var configuredMotionPolicy
    @EnvironmentObject private var themeStore: ThemeStore
    @StateObject private var bkController = BKArtBackgroundController()
    @State private var skinSession = SkinSession()
    @State private var rightPanelDisplayState: RightPanelDisplayState = .lyrics
    @State private var lastRightPanelDisplayStateBeforeQueue: RightPanelDisplayState = .lyrics
    @State private var lyricsCoordinator = FullscreenLyricsCoordinator()
    @State private var lastFullscreenLyricsReloadSignature: FullscreenLyricsReloadSignature?
    @State private var lastFullscreenLyricsReloadAt: TimeInterval = 0
    /// Last fully decoded artwork committed to the skin layer. Track metadata
    /// can advance ahead of artwork decoding, so this remains stable until a
    /// complete image for the current display track is ready.
    @State private var artworkSnapshot: ArtworkAssetSnapshot?
    @State private var preparedArtworkTaskKey: String?
    @State private var embeddedPresentationComplete = false
    @State private var bottomControls = FullscreenBottomControlsCoordinator()
    @State private var isDetailReaderPanelPresented = false
    @State private var detailReaderTrack: Track? = nil
    /// Cover Blur fullscreen background readability maps, written by the skin
    /// background bridge and read here to resolve the local control polarity.
    @State private var backdropReadabilityState = FullscreenBackdropReadabilityState()
    /// Cached Cover Blur local polarity. The contrast engine samples up to three
    /// backdrop maps across three control regions and sorts per-pixel luma /
    /// contrast arrays per region — far too expensive to run on every body
    /// evaluation (this view re-evaluates at meter / playback-time / animation
    /// frequency, and the engine was invoked once per
    /// `fullscreenMiniPlayerForegroundProfile` access, ~many per body). The
    /// getter returns this cached value; `.onChange(of: localPolarityInputSignature)`
    /// refreshes it only when the decision inputs actually change.
    @State private var resolvedLocalPolarity: ArtworkForegroundPolarity?
    @State private var resolvedQueueLocalPolarity: ArtworkForegroundPolarity?
    @State private var resolvedQuickPanelLocalPolarity: ArtworkForegroundPolarity?
    @State private var localPolarityRecomputeTask: Task<Void, Never>?
    @State private var currentFullscreenScale: CGFloat = 1.0
    @State private var fullscreenViewportSize: CGSize = .zero
    @State private var embeddedInitialThemeUnlocked = false
    @State private var didHandleFullscreenAppear = false
    @State private var isPointerOverMiniPlayerOcclusion = false
    @State private var trackToEdit: Track?
    @State private var isShowingExternalMatchEditor = false
    @State private var showPlaybackModeRetapTip = false
    @State private var showScrollWheelVolumeTip = false
    @State private var pendingPanoramicVolumeHUDHideTask: Task<Void, Never>?
    @State private var isPanoramicVolumeHUDVisible = false
    @State private var panoramicVolumeHUDValue = AppSettings.defaultVolume
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

    private var usesCoverBlurBackdrop: Bool {
        fullscreenSkinDescriptor.presentation.artworkLayout == .backdrop
            && fullscreenSkinDescriptor.presentation.lyricsBackdrop == .coverBlur
    }

    private var usesMeshLyricsBackdrop: Bool {
        fullscreenSkinDescriptor.presentation.artworkLayout == .foreground
            && fullscreenSkinDescriptor.presentation.lyricsBackdrop == .mesh
    }

    private var usesCoverBlurLyricsRenderingPath: Bool {
        usesCoverBlurBackdrop || usesMeshLyricsBackdrop
    }

    private var fullscreenSkinUsesCustomBackground: Bool {
        fullscreenSkinDescriptor.presentation.backgroundOwner == .skin
    }

    /// Cover-element skins (classic, rotating, cassette) get a slight vertical
    /// drop when the fullscreen miniplayer auto-hides, and return when it reappears.
    private var isCoverSkinWithMiniplayerMotion: Bool {
        fullscreenSkinDescriptor.presentation.movesArtworkWithControls
    }

    private var fullscreenSkinDescriptor: SkinDescriptor {
        SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID).descriptor
    }

    private var fullscreenLedServiceSignature: String {
        [
            settings.fullscreen.skinID,
            String(AudioVisualizationPreferences.shared.revision),
            String(SkinRegistry.catalog.revision(for: settings.fullscreen.skinID)),
            classicLedFullscreenMode,
            appleStyleFullscreenMode,
            rotatingCoverLedFullscreenMode,
            cassetteLedFullscreenMode,
        ].joined(separator: "|")
    }

    /// Fullscreen artwork/layout only depends on track metadata and play state.
    /// Keep the 4 Hz playback clock out of this root view; the bottom mini-player
    /// has its own live presentation reader for the seek/progress row.
    private var currentDisplayContext: NowPlayingDisplayContext {
        playbackCoordinator.stablePresentation.displayContext
    }

    private var currentArtworkTrackID: UUID? {
        currentDisplayContext.artworkTrackID
    }

    private var currentFullscreenLyricsThemeIdentity: FullscreenLyricsThemeIdentity {
        let display = currentDisplayContext
        let artworkSignature = [
            display.artworkIdentity ?? "nil",
            display.lyricsIdentity ?? "nil",
            ArtworkDataFingerprint.sampledString(for: display.artworkData),
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

    /// Effective dimming intensity adjusted for color scheme.
    /// Light mode requires stronger dimming for readability.
    private var effectiveDimmingIntensity: Double {
        let base: Double
        if UserDefaults.standard.object(forKey: "fullscreenDimmingIntensity") == nil {
            base = AppSettings.defaultFullscreenDimmingIntensity(for: settings.fullscreen.skinID)
        } else {
            base = settings.fullscreenDimmingIntensity
        }
        if colorScheme == .light {
            // Light mode: increase dimming by ~40% for better contrast
            return min(0.55, base * 1.40)
        }
        return base
    }

    private var artisticBackgroundDimmingIntensity: Double {
        colorScheme == .light ? 0 : effectiveDimmingIntensity
    }

    private var fullscreenScene: some View {
        GeometryReader { proxy in
            fullscreenContent(for: proxy)
        }
        .ignoresSafeArea()
        .background(
            WindowToolbarAccessor(
                configure: { window in
                    fullscreenPointerOcclusionMonitor.setWindow(window)
                    if hostContext == .embeddedWindow {
                        let contentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
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
        .onChange(
            of: fullscreenLocalArtworkPolarity,
            initial: false,
            handleFullscreenLocalArtworkPolarityChange
        )
        .onChange(of: localPolarityInputSignature, initial: true) { _, _ in
            scheduleLocalPolarityRecompute()
        }
        .onChange(of: settings.fullscreen.skinID) { oldValue, newValue in
            skinSession.activate(newValue, revision: SkinRegistry.catalog.revision(for: newValue))
            FSDiagnostics.emit(
                "onChange(skinID) old=\(oldValue) new=\(newValue) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            skinSession.perform {
                await CacheManager.purgePresentationMemoryCaches(
                    reason: "fullscreen-skin-changed-\(oldValue)-to-\(newValue)",
                    cacheServices: cacheServices
                )
            }
            let oldDescriptor = SkinRegistry.fullscreenSkin(for: oldValue).descriptor
            let newDescriptor = SkinRegistry.fullscreenSkin(for: newValue).descriptor
            let coverBlurTransition = oldDescriptor.presentation.lyricsBackdrop == .coverBlur
                || newDescriptor.presentation.lyricsBackdrop == .coverBlur
            FSDiagnostics.emit(
                "onChange(skinID) syncCoverBlurHighlight BEGIN external=\(playbackCoordinator.presentation.source.isExternal) coverBlurTransition=\(coverBlurTransition) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            if coverBlurTransition {
                FSDiagnostics.emit(
                    "onChange(skinID) reloadLyricsSurface CALL external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                    category: .fullscreen
                )
                reloadLyricsSurface(reason: "fullscreen skin changed", forceLyricsReload: true)
            } else {
                applyFullscreenLyricsTheme(force: true, reason: "fullscreen skin changed")
            }
            reassertFullscreenLyricsPresentation(reason: "fullscreen skin changed")
        }
        .onChange(of: SkinRegistry.catalog.revision(for: settings.fullscreen.skinID)) { _, revision in
            skinSession.activate(settings.fullscreen.skinID, revision: revision)
            applyFullscreenLyricsTheme(force: true, reason: "skin package reloaded")
        }
        .onChange(of: fullscreenLedServiceSignature) { _, _ in
            FSDiagnostics.emit(
                "onChange(skinID) syncFullscreenLedService CALL external=\(playbackCoordinator.presentation.source.isExternal) sig=\(fullscreenLedServiceSignature) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            syncFullscreenLedService()
        }
        .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
        .onChange(of: playbackCoordinator.stablePresentation.lyricsIdentity, handlePresentationLyricsIdentityChange)
        .onChange(of: playbackCoordinator.stablePresentation.lyricsText) { _, _ in
            guard playbackCoordinator.stablePresentation.hasTrack else { return }
            let reason = playbackCoordinator.stablePresentation.source.isExternal
                ? "fullscreen external lyrics updated"
                : "fullscreen local lyrics hydrated"
            reloadLyricsSurface(reason: reason, forceLyricsReload: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
            handleLibraryTrackDidUpdate(notification)
        }
        .onChange(of: rightPanelDisplayState) { oldValue, newValue in
            handleRightPanelDisplayStateChange(oldValue, newValue)
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
        .onReceive(NotificationCenter.default.publisher(for: .lyricSpringSettingsDidSettle)) { _ in
            applyFullscreenLyricsTheme(reason: "lyric spring settings settled")
        }
        .onReceive(NotificationCenter.default.publisher(for: .lyricHighlightModeDidChange)) { _ in
            // AppStorage-backed highlight settings are intentionally ignored
            // by AppSettings observation. The quick fullscreen panel sends an
            // explicit event so the live native surface is updated immediately
            // instead of waiting for a reopen or track change.
            applyFullscreenLyricsTheme(reason: "lyric highlight mode changed")
        }
        .onChange(of: settings.fullscreenMiniPlayerAutoHideSeconds) { _, _ in
            resetFullscreenBottomControlsAutoHideState()
        }
        .onChange(of: bkController.lyricsColorSampleRevision) { _, _ in
            guard lyricsCoordinator.pendingBackgroundCapture else { return }
            guard bkController.lyricsColorTrackID == currentArtworkTrackID else { return }
            scheduleFullscreenLyricsRefresh(preferLiveSurface: true)
        }
    }

    var body: some View {
        fullscreenScene
        .overlayPreferenceValue(SkinControlRegionKey.self) { anchors in
            GeometryReader { proxy in
                FullscreenHostControlRegions(rectangles: anchors.map { proxy[$0] })
                    .allowsHitTesting(false)
            }
        }
        .task(id: embeddedArtworkPreparationKey) {
            await prepareFullscreenArtwork()
        }
        .task(id: embeddedPresentationPreparationKey) {
            await prepareEmbeddedFullscreenPresentation()
        }
        .transaction(configureEmbeddedPresentationTransaction)
    }

    private func configureEmbeddedPresentationTransaction(_ transaction: inout Transaction) {
        guard hostContext == .embeddedWindow, !embeddedPresentationComplete else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }

    private var embeddedArtworkPreparationKey: String {
        "\(currentArtworkTaskKey)-\(currentDisplayContext.isArtworkLoading)-skin:\(skinSession.generation)"
    }

    private var embeddedPresentationPreparationKey: String {
        "\(embeddedArtworkPreparationKey)-\(embeddedInitialThemeUnlocked)-\(preparedArtworkTaskKey ?? "pending")"
    }

    private func prepareFullscreenArtwork() async {
        let generation = skinSession.generation
        let key = currentArtworkTaskKey
        await loadArtworkSnapshot()
        guard !Task.isCancelled, generation == skinSession.generation,
              key == currentArtworkTaskKey,
              !currentDisplayContext.isArtworkLoading else { return }
        preparedArtworkTaskKey = key
    }

    private func prepareEmbeddedFullscreenPresentation() async {
        guard isEmbeddedFullscreenPresentationActive, embeddedInitialThemeUnlocked,
              preparedArtworkTaskKey == currentArtworkTaskKey else { return }
        // Native lyric installation is synchronous. Wait for its mounted host
        // and final canvas before allowing the complete frame to rise.
        while !Task.isCancelled && isEmbeddedFullscreenPresentationActive {
            let lyricsReady = !lyricsCoordinator.hostMounted
                || (!lyricsCoordinator.suppressViewport
                    && NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)?.isRenderingActive == true)
            if lyricsReady && isValidEmbeddedFullscreenGeometry(fullscreenViewportSize, scale: currentFullscreenScale) {
                FullscreenWindowManager.shared.revealPreparedEmbeddedFullscreen(tokens: motionTokens, policy: motionPolicy) {
                    embeddedPresentationComplete = true
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func handleFullscreenAppear() {
        skinSession.activate(settings.fullscreen.skinID, revision: SkinRegistry.catalog.revision(for: settings.fullscreen.skinID))
        guard !didHandleFullscreenAppear else { return }
        FSDiagnostics.emit(
            "handleFullscreenAppear ENTER host=\(hostContext.rawValue) skin=\(settings.fullscreen.skinID) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        didHandleFullscreenAppear = true
        Log.info(
            "FullscreenPlayerView appeared context=\(hostContext.rawValue)",
            category: .lyrics
        )
        fullscreenPointerOcclusionMonitor.start { isOccluded in
            setPointerOverMiniPlayerOcclusion(isOccluded, reason: "mouse-location")
        }

        FSDiagnostics.emit(
            "handleFullscreenAppear syncCoverBlurHighlight BEGIN t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        resetFullscreenLyricsBackgroundSnapshot()
        scheduleFullscreenLyricsBackgroundCapture()
        lyricsCoordinator.hostMounted = isShowingLyricsPanel && playbackCoordinator.presentation.hasTrack
        setupSeekCallback()
        if hostContext == .embeddedWindow {
            embeddedInitialThemeUnlocked = false
        } else {
            startFullscreenLyricsSurface(reason: "fullscreen appear")
        }
        resetFullscreenBottomControlsAutoHideState()
        FSDiagnostics.emit(
            "handleFullscreenAppear syncFullscreenLedService CALL t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        syncFullscreenLedService()
    }

    private func handleFullscreenDisappear() {
        FeatureTipPresentationCoordinator.shared.cancelPending(
            key: FeatureTipCatalog.PlaybackModeRetap.key
        )
        if showPlaybackModeRetapTip {
            AppVersionGate.shared.markPlaybackModeRetapFeatureTipDismissed()
            showPlaybackModeRetapTip = false
            finishPlaybackModeRetapTipPresentation()
        }
        FeatureTipPresentationCoordinator.shared.cancelPending(
            key: FeatureTipCatalog.ScrollWheelVolume.key
        )
        if showScrollWheelVolumeTip {
            showScrollWheelVolumeTip = false
            finishScrollWheelVolumeTipPresentation()
        }
        Log.info(
            "FullscreenPlayerView disappeared context=\(hostContext.rawValue)",
            category: .lyrics
        )
        didHandleFullscreenAppear = false
        fullscreenPointerOcclusionMonitor.stop()
        setPointerOverMiniPlayerOcclusion(false, reason: "fullscreen disappear")
        ledMeterProvider.releaseNowPlayingResources()
        artworkSnapshot = nil
        NativeLyricsSurfaceManager.shared.setSeekHandler(nil, for: .fullscreen)
        lyricsCoordinator.resetForDisappear()
        localPolarityRecomputeTask?.cancel()
        localPolarityRecomputeTask = nil
        pendingPanoramicVolumeHUDHideTask?.cancel()
        pendingPanoramicVolumeHUDHideTask = nil
        isPanoramicVolumeHUDVisible = false
        embeddedInitialThemeUnlocked = false
        bottomControls.isQuickAppearancePanelPresented = false
        isDetailReaderPanelPresented = false
        detailReaderTrack = nil
        bottomControls.isAppearancePanelHovered = false
        bottomControls.cancelAllScheduledWork()
        setLeftActionsExpanded(false, reason: "fullscreen-disappear")
        setVolumeExpanded(false, reason: "fullscreen-disappear")
        clearFullscreenLyricsTheme()
        skinSession.deactivate()

        // Embedded fullscreen shares the current track with the still-mounted
        // main player. Its bounded artwork caches must survive this handoff.
        // Destroying them here both reloads the next entry and invalidates the
        // main cover while it is returning to view.
        if hostContext == .systemFullscreenSpace {
            let cacheServices = self.cacheServices
            skinSession.perform {
                await CacheManager.purgePresentationMemoryCaches(
                    reason: "fullscreen-player-view-disappeared-\(hostContext.rawValue)",
                    cacheServices: cacheServices
                )
            }
        }

        // Always report disappearance, including an embedded surface that was
        // removed before its initial geometry/theme gate completed. The
        // manager updates the native surface state before the next appearance.
        LyricsSurfaceManager.shared.reportFullscreenVisible(false)
    }

    private var fullscreenDetailReaderTargetTrack: Track? {
        detailReaderTrack ?? playbackCoordinator.presentation.localTrack
    }

    private var fullscreenResolvedDetail: TrackDetailContent {
        if let track = fullscreenDetailReaderTargetTrack {
            return TrackDetailResolver.resolve(for: track, libraryVM: libraryVM)
        }
        let title = playbackCoordinator.presentation.title
        let artist = playbackCoordinator.presentation.artist
        let subtitle: String
        if !title.isEmpty, !artist.isEmpty {
            subtitle = "\(title) - \(artist)"
        } else {
            subtitle = title.isEmpty ? (artist.isEmpty ? "歌曲详情" : artist) : title
        }
        return TrackDetailContent(
            title: "歌曲详情",
            subtitle: subtitle,
            attributionNote: nil,
            text: ""
        )
    }

    private var fullscreenDetailReaderTitle: String {
        fullscreenResolvedDetail.subtitle
    }

    private var fullscreenDetailReaderAttributionNote: String? {
        fullscreenResolvedDetail.attributionNote
    }

    private var fullscreenDetailReaderText: String {
        fullscreenResolvedDetail.text
    }

    private func showDetailReader(for track: Track?) {
        detailReaderTrack = track
        setDetailReaderPanelPresented(true)
    }

    private func setDetailReaderPanelPresented(_ presented: Bool) {
        guard isDetailReaderPanelPresented != presented else { return }
        if presented {
            if bottomControls.isQuickAppearancePanelPresented {
                setQuickAppearancePanelPresented(false)
            }
            if rightPanelDisplayState == .queue {
                setRightPanelDisplayState(lastRightPanelDisplayStateBeforeQueue == .hidden ? .hidden : .lyrics)
            }
            setFullscreenBottomControlsVisible(true)
        } else {
            detailReaderTrack = nil
        }
        withAnimation(motionPolicy.animation(for: motionTokens[.navigation])) {
            isDetailReaderPanelPresented = presented
        }
    }

    private func fullscreenContextMenu() -> some View {
        FullscreenSkinContextMenu(
            onShowDetails: {
                showDetailReader(for: playbackCoordinator.presentation.localTrack)
            },
            onRefreshLyricsColors: {
                forceRefreshFullscreenLyricsColors(reason: "context-menu-refresh")
            }
        )
    }

    private func trackEditSheet(for track: Track) -> some View {
        TrackEditSheet(track: track)
            .environmentObject(themeStore)
    }

    private func externalMatchEditorSheet() -> some View {
        ExternalPlaybackInfoEditorView(
            presentation: playbackCoordinator.presentation,
            metadataStore: cacheServices.externalPlaybackMetadataStore,
            onSaved: { onlyOffsetChanged in
                playbackCoordinator.invalidateExternalPlaybackResolution(onlyOffsetChanged: onlyOffsetChanged)
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

        // The lyrics layer owns a persistent native surface. Keep it outside
        // the skin-keyed subtree: only skin-specific visual layers (background,
        // scaled artwork container, bottom bar) should be recreated on a skin
        // switch. This preserves the lyrics surface and avoids unnecessary
        // layout and glyph-mask work while the skin changes.
        let skinIdentity = "fullscreen_\(skinSession.identity(for: settings.fullscreen.skinID))"

        ZStack {
            // Keep the 4 Hz playback clock in a leaf view. Native lyrics and the
            // fullscreen lyrics state still receive live time, while the
            // artwork/background/control tree remains on the stable projection.
            FullscreenPlaybackSyncView(
                onLocalTimeChange: handleCurrentTimeChange,
                onLocalPlayingChange: handleLocalPlayingChange,
                onExternalTimeChange: handlePresentationCurrentTimeChange,
                onExternalPlayingChange: handleExternalPlayingChange
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            // Embedded fullscreen is composited over the live main-window
            // content (no opaque black NSWindow behind it, unlike the system
            // fullscreen space). Without a guaranteed opaque base, any transient
            // transparency in the layers above — `hasRenderableGeometry == false`
            // moments, skin background first-frame/re-render gaps during a track
            // switch — lets the window content underneath show through. Pin an
            // opaque base (tinted to the current cover, black fallback) so the
            // embedded surface is never see-through. System fullscreen is
            // unaffected (its NSWindow already provides the opaque backing).
            fullscreenEmbeddedOpaqueBase

            if hasRenderableGeometry {
                if let scene = selectedSkin.scene {
                    SkinSceneHost(
                        skin: selectedSkin, scene: scene,
                        context: makeContext(windowSize: proxy.size, artworkColumnWidth: proxy.size.width, fullscreenScale: 1),
                        session: skinSession,
                        viewport: .init(size: proxy.size, surface: .fullscreen,
                                        fullscreenHost: hostContext == .embeddedWindow ? .embeddedWindow : .systemFullscreen),
                        lyricsVisible: isShowingLyricsPanel,
                        onExit: onExitFullscreen,
                        onToggleLyrics: { handleLyricsButtonTap() },
                        onRestore: { settings.fullscreen.setSkinID(SkinRegistry.defaultFullscreenSkinID) }
                    )
                    .id(skinIdentity)
                } else {
                    fullscreenBackgroundLayer(
                        selectedSkin: selectedSkin,
                        scale: scale,
                        viewportSize: proxy.size
                    )
                        .id("\(skinIdentity)_bg")
                        .environment(\.fullscreenBackdropReadabilityState, backdropReadabilityState)
                        .onAppear { FSDiagnostics.emit("skinBg onAppear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
                        .onDisappear { FSDiagnostics.emit("skinBg onDisappear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }

                    // Layer 1: native lyrics at actual resolution. Keep it outside
                    // the skin-keyed `.id()` so the surface stays mounted across
                    // skin switches.
                    FullscreenNativeLyricsLayer(
                        layout: FullscreenNativeLyricsLayoutSnapshot(
                            scale: scale,
                            screenWidth: proxy.size.width,
                            hostLayout: layoutMetrics(showLyricsColumn: true),
                            coverBlurLegacyArtworkWidth: coverBlurLegacyLayoutMetrics(showLyricsColumn: true).artworkWidth,
                            coverBlurLegacyLyricsWidth: coverBlurLegacyLayoutMetrics(showLyricsColumn: true).lyricsWidth
                        ),
                        presentation: FullscreenNativeLyricsPresentationSnapshot(
                            usesCoverBlurBackdrop: usesCoverBlurBackdrop,
                            isShowingLyricsPanel: isShowingLyricsPanel,
                            isShowingRightPanel: isShowingRightPanel,
                            isShowingQueuePanel: isShowingQueuePanel,
                            shouldKeepFullscreenLyricsHostMounted: shouldKeepFullscreenLyricsHostMounted,
                            fullscreenLyricsHostOpacity: fullscreenLyricsHostOpacity,
                            isFullscreenLyricsHostVisible: isFullscreenLyricsHostVisible,
                            fullscreenLyricsViewportOpacity: fullscreenLyricsViewportOpacity,
                            isFullscreenBottomControlsVisible: bottomControls.isVisible,
                            fullscreenControlsBottomPadding: fullscreenControlsBottomPadding,
                            lyricsViewportTopLift: lyricsViewportTopLift,
                            lyricsViewportTopCropDown: lyricsViewportTopCropDown,
                            usesCoverBlurLyricsRenderingPath: usesCoverBlurLyricsRenderingPath,
                            coverBlurBaseBlendMode: coverBlurBaseBlendMode
                        ),
                        queue: FullscreenNativeLyricsQueueSnapshot(
                            tracks: playerVM.currentQueueTracks,
                            currentTrackID: playerVM.currentTrack?.id,
                            playbackMode: currentPlaybackMode,
                            glassStyle: fullscreenQueueGlassStyle,
                            foregroundProfile: fullscreenQueueForegroundProfile
                        ),
                        actions: FullscreenNativeLyricsActions(
                            showLyrics: { setRightPanelDisplayState(.lyrics) },
                            queueTrackTap: handleQueueTrackTap
                        )
                    )
                        .frame(width: proxy.size.width, height: proxy.size.height)

                    // Layer 2: Scaled container for artwork only. Cover Blur uses
                    // its background as the artwork and returns EmptyView here, so
                    // do not keep a redundant 1470×923 layout surface in embedded
                    // fullscreen. Its unscaled layout footprint can otherwise
                    // resist compression even though scaleEffect looks smaller.
                    if !usesCoverBlurBackdrop {
                        fullscreenScaledContainer(selectedSkin: selectedSkin, scale: scale)
                            .frame(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight)
                            .scaleEffect(scale, anchor: .center)
                            .frame(width: Self.baseCanvasWidth * scale, height: Self.baseCanvasHeight * scale)
                            .id("\(skinIdentity)_scaled")
                            .onAppear { FSDiagnostics.emit("skinScaled onAppear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
                            .onDisappear { FSDiagnostics.emit("skinScaled onDisappear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
                    }

                    // Layer 3: Bottom bar at actual resolution - on top
                    fullscreenBottomBarLayer(
                        scale: scale,
                        screenWidth: proxy.size.width,
                        screenHeight: proxy.size.height
                    )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id("\(skinIdentity)_controls")
                        .onAppear { FSDiagnostics.emit("skinBottom onAppear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
                        .task(id: playbackModeRetapTipTaskID) {
                            await schedulePlaybackModeRetapTipIfNeeded()
                        }
                        .task(id: scrollWheelVolumeTipTaskID) {
                            await scheduleScrollWheelVolumeTipIfNeeded()
                        }

                    panoramicArtworkVolumeLayer(viewportSize: proxy.size, scale: scale)

                    if isDetailReaderPanelPresented {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                setDetailReaderPanelPresented(false)
                            }
                            .transition(.opacity)
                            .zIndex(10)

                        FullscreenDetailReaderPanel(
                            title: fullscreenDetailReaderTitle,
                            attributionNote: fullscreenDetailReaderAttributionNote,
                            text: fullscreenDetailReaderText,
                            scale: scale,
                            foregroundProfile: fullscreenQuickPanelForegroundProfile,
                            onDismiss: { setDetailReaderPanelPresented(false) }
                        )
                        .skinControlRegion()
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
                        .transition(
                            .opacity.combined(with: .offset(x: 0, y: 8))
                        )
                        .zIndex(11)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .motionAnimation(.navigation, value: isDetailReaderPanelPresented)
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
        .onChange(of: showPlaybackModeRetapTip) { _, isPresented in
            if !isPresented {
                finishPlaybackModeRetapTipPresentation()
            }
        }
        .onChange(of: showScrollWheelVolumeTip) { _, isPresented in
            if !isPresented {
                finishScrollWheelVolumeTipPresentation()
            }
        }
    }

    /// Opaque backing for embedded fullscreen so the surface is never
    /// see-through during track-switch transients. No-op in the system
    /// fullscreen space (its NSWindow already paints an opaque black backing).
    @ViewBuilder
    private var fullscreenEmbeddedOpaqueBase: some View {
        if hostContext == .embeddedWindow {
            ColorRenderingAdapter.makeSwiftUIColor(fullscreenEmbeddedOpaqueBaseColor)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// Tint the embedded opaque base toward the current cover so a transient gap
    /// blends with the artwork background instead of flashing black. Falls back
    /// to black before any artwork snapshot exists. During a track-switch gap the
    /// previous snapshot is still held, so the base matches the outgoing cover
    /// until the new one resolves.
    private var fullscreenEmbeddedOpaqueBaseColor: NSColor {
        guard let color = artworkSnapshot?.averageColor
            ?? artworkSnapshot?.dominantColor
            ?? artworkSnapshot?.accentColor
        else { return .black }
        return (color.usingColorSpace(.deviceRGB) ?? color).withAlphaComponent(1)
    }

    @ViewBuilder
    private func fullscreenBackgroundLayer(
        selectedSkin: any NowPlayingSkin,
        scale: CGFloat,
        viewportSize: CGSize
    ) -> some View {
        let context = makeContext(
            windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
            artworkColumnWidth: layoutMetrics.artworkWidth,
            fullscreenScale: scale
        )

        if fullscreenSkinUsesCustomBackground {
            if usesCoverBlurBackdrop {
                selectedSkin.makeBackground(context: context)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .clipped()
                    .allowsHitTesting(false)
            } else {
                selectedSkin.makeBackground(context: context)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if fullscreenSkinDescriptor.presentation.backgroundDimming == .host {
                Color.black.opacity(effectiveDimmingIntensity * 0.7)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        } else if settings.fullscreenArtBackgroundEnabled && currentDisplayContext.hasTrack {
            let renderingArtworkData = currentRenderingArtworkData
            BKArtBackgroundView(
                controller: bkController,
                trackID: currentArtworkTrackID,
                artworkData: renderingArtworkData,
                isPlaying: currentDisplayContext.isPlaying,
                artworkFileURL: currentDisplayContext.source == .local
                    ? playbackCoordinator.presentation.localTrack?.existingArtworkURL()
                    : nil,
                avoidanceRect: nil,
                resourceProfile: BKArtBackgroundView.ResourceProfile(
                    skinProfile: fullscreenSkinDescriptor.presentation.artBackgroundResourceProfile
                ),
                dotRenderStyle: .solidCircles,
                motionProfile: .fullscreenBalanced,
                initialPalette: fullscreenArtBackgroundSeedPalette,
                isArtworkLoading: currentDisplayContext.isArtworkLoading
            )
            .ignoresSafeArea()

            if fullscreenSkinDescriptor.presentation.backgroundDimming == .host {
                Color.black.opacity(artisticBackgroundDimmingIntensity)
                    .ignoresSafeArea()
            }
        } else {
            selectedSkin.makeBackground(context: context)
                .ignoresSafeArea()

            if fullscreenSkinDescriptor.presentation.backgroundDimming == .host {
                Color.black.opacity(effectiveDimmingIntensity * 0.7)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Fullscreen Scaled Container (Artwork + Controls Only)

    @ViewBuilder
    private func fullscreenScaledContainer(selectedSkin: any NowPlayingSkin, scale: CGFloat) -> some View {
        FullscreenScaledArtworkContainer(
            movesArtworkWithControls: isCoverSkinWithMiniplayerMotion,
            areControlsVisible: bottomControls.isVisible,
            horizontalPadding: topContentHorizontalPadding,
            controlsBottomPadding: fullscreenControlsBottomPadding,
            controlButtonSize: fullscreenControlButtonSize
        ) {
            artworkAndControlsArea(selectedSkin: selectedSkin, scale: scale)
        }
    }

    // MARK: - Fullscreen Lyrics Layer (Actual Resolution - Crisp)

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

    private var fullscreenBottomControlsGeometryConfiguration: FullscreenBottomControlsGeometry.Configuration {
        FullscreenBottomControlsGeometry.Configuration(
            buttonSize: fullscreenControlButtonSize,
            spacing: fullscreenControlSpacing,
            horizontalPadding: fullscreenControlsHorizontalPadding,
            miniPlayerMaxWidth: fullscreenMiniPlayerMaxWidth,
            miniPlayerPillWidthReduction: fullscreenMiniPlayerPillWidthReduction,
            leadingExpandedWidth: leadingControlsExpandedWidth,
            leadingCollapsedWidth: leadingControlsCollapsedWidth,
            volumeExpandedWidth: volumeExpandedWidth,
            volumeCollapsedWidth: volumeCollapsedWidth,
            canvasWidth: Self.baseCanvasWidth,
            canvasHeight: Self.baseCanvasHeight,
            bottomPadding: fullscreenControlsBottomPadding
        )
    }

    private func fullscreenBottomControlsGeometry(
        isLeftActionsExpanded: Bool? = nil,
        isVolumeExpanded: Bool? = nil
    ) -> FullscreenBottomControlsGeometry {
        FullscreenBottomControlsGeometry.make(
            isLeftActionsExpanded: isLeftActionsExpanded ?? bottomControls.isLeftActionsExpanded,
            isVolumeExpanded: isVolumeExpanded ?? bottomControls.isVolumeExpanded,
            configuration: fullscreenBottomControlsGeometryConfiguration
        )
    }

    private func fullscreenMiniPlayerOcclusionRegion(
        scale: CGFloat,
        screenSize: CGSize
    ) -> FullscreenMiniPlayerOcclusionRegion {
        guard bottomControls.isVisible else {
            return .inactive
        }

        let geometry = fullscreenBottomControlsGeometry()
        let scaledButtonSize = fullscreenControlButtonSize * scale
        let scaledMiniPlayerOriginX = geometry.miniPlayerRect.minX * scale
        let scaledMiniPlayerWidth = geometry.miniPlayerRect.width * scale
        let scaledWindowWidth = Self.baseCanvasWidth * scale
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

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { playbackCoordinator.stablePresentation.volume },
            set: { playbackCoordinator.setVolume($0) }
        )
    }

    private var isArtworkVolumeControlEnabled: Bool {
        playbackCoordinator.stablePresentation.isVolumeControlEnabled
            && !bottomControls.isQuickAppearancePanelPresented
            && !isShowingExternalMatchEditor
            && trackToEdit == nil
            && !isDetailReaderPanelPresented
    }

    @ViewBuilder
    private func panoramicArtworkVolumeLayer(
        viewportSize: CGSize,
        scale: CGFloat
    ) -> some View {
        let artworkBounds: (size: CGSize, center: CGPoint, scale: CGFloat) = {
            if usesCoverBlurBackdrop {
                let artworkSide = min(viewportSize.width, viewportSize.height)
                let artworkCenterX = isShowingRightPanel
                    ? artworkSide * 0.5
                    : viewportSize.width * 0.5
                let artworkScale = artworkSide / Self.baseCanvasHeight
                return (
                    size: CGSize(width: artworkSide, height: artworkSide),
                    center: CGPoint(x: artworkCenterX, y: viewportSize.height * 0.5),
                    scale: artworkScale
                )
            } else {
                let splitLayout = layoutMetrics
                let artworkOffsetX =
                    splitLayout.artworkLeadingX
                    + splitLayout.artworkWidth * 0.5
                    - Self.baseCanvasWidth * 0.5
                let groupLeftShift: CGFloat =
                    isShowingRightPanel
                        ? FullscreenCoverHorizontalOffset.groupLeftBias
                        : 0
                let coverDropY: CGFloat =
                    isCoverSkinWithMiniplayerMotion && !bottomControls.isVisible
                        ? 20
                        : 0
                let artworkCenterX = viewportSize.width * 0.5 + (artworkOffsetX - groupLeftShift) * scale
                let artworkCenterY = viewportSize.height * 0.5 + coverDropY * scale
                let artworkWidth = splitLayout.artworkWidth * scale
                let artworkHeight = min(viewportSize.height, Self.baseCanvasHeight * scale)
                return (
                    size: CGSize(width: artworkWidth, height: artworkHeight),
                    center: CGPoint(x: artworkCenterX, y: artworkCenterY),
                    scale: scale
                )
            }
        }()

        ZStack {
            ZStack {
                PanoramicArtworkVolumeScrollArea(
                    volume: volumeBinding,
                    isEnabled: isArtworkVolumeControlEnabled,
                    onAdjustment: handlePanoramicArtworkVolumeAdjustment
                )

                if isPanoramicVolumeHUDVisible {
                    panoramicVolumeHUD(scale: artworkBounds.scale)
                        .transition(
                            motionPolicy != .full
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.92))
                        )
                }

                if showScrollWheelVolumeTip {
                    ScrollWheelVolumeTipView(
                        onClose: dismissScrollWheelVolumeTip,
                        scale: artworkBounds.scale,
                        glassStyle: fullscreenControlsGlassStyle,
                        foregroundColor: fullscreenMiniPlayerPrimaryColor,
                        blendMode: fullscreenMiniPlayerIconBlendMode
                    )
                    .transition(
                        motionPolicy != .full
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.94))
                    )
                    .zIndex(5)
                }
            }
            .frame(width: artworkBounds.size.width, height: artworkBounds.size.height)
            .position(x: artworkBounds.center.x, y: artworkBounds.center.y)
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .motionAnimation(.microInteraction, value: isPanoramicVolumeHUDVisible)
    }

    private func panoramicVolumeHUD(scale: CGFloat) -> some View {
        let percentage = Int((panoramicVolumeHUDValue * 100).rounded())

        return HStack(spacing: 12 * scale) {
            Image(systemName: panoramicVolumeIcon)
                .font(.system(size: 22 * scale, weight: .semibold))
                .frame(width: 32 * scale)

            Text("\(percentage)%")
                .font(.system(size: 24 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .motionAnimation(.contentReplacement, value: percentage)
                .frame(width: 86 * scale)
        }
        .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
        .compositingGroup()
        .blendMode(fullscreenMiniPlayerIconBlendMode)
        .frame(width: 184 * scale, height: 58 * scale)
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: fullscreenControlsGlassStyle.colorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: fullscreenControlsGlassStyle.materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
        .accessibilityValue(Text("\(percentage)%"))
    }

    private var panoramicVolumeIcon: String {
        switch panoramicVolumeHUDValue {
        case ...0:
            return "speaker.slash.fill"
        case ..<0.34:
            return "speaker.wave.1.fill"
        case ..<0.67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    private func handlePanoramicArtworkVolumeAdjustment(_ adjustment: Double) {
        guard playbackCoordinator.presentation.isVolumeControlEnabled else { return }

        FeatureTipPresentationCoordinator.shared.cancelPending(
            key: FeatureTipCatalog.ScrollWheelVolume.key
        )
        if showScrollWheelVolumeTip {
            dismissScrollWheelVolumeTip()
        }

        let currentVolume = playbackCoordinator.presentation.volume
        let newVolume = VolumeControlBehavior.clamped(currentVolume + adjustment)
        guard abs(newVolume - currentVolume) > 0.0001 else { return }

        panoramicVolumeHUDValue = newVolume
        playbackCoordinator.setVolume(newVolume)

        pendingPanoramicVolumeHUDHideTask?.cancel()
        withAnimation(motionPolicy.animation(for: motionTokens[.microInteraction])) {
            isPanoramicVolumeHUDVisible = true
        }

        pendingPanoramicVolumeHUDHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(motionPolicy.animation(for: motionTokens[.microInteraction])) {
                isPanoramicVolumeHUDVisible = false
            }
            pendingPanoramicVolumeHUDHideTask = nil
        }
    }

    private var motionPolicy: MotionPolicy {
        configuredMotionPolicy.resolving(accessibilityReduceMotion: reduceMotion)
    }

    private func motionDelay(full: TimeInterval, reduced: TimeInterval) -> TimeInterval {
        switch motionPolicy {
        case .full:
            full
        case .reduced:
            reduced
        case .disabled:
            0
        }
    }

    private var bottomControlsAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.layout])
    }

    private func animateFullscreenBottomControlsGeometry(_ updates: () -> Void) {
        FullscreenBottomControlsAnimationPolicy.animateGeometry(
            with: bottomControlsAnimation,
            updates
        )
    }

    private func setFullscreenBottomControlsVisible(_ visible: Bool) {
        bottomControls.setVisible(visible, animate: animateFullscreenBottomControlsGeometry)
    }

    private var quickAppearancePanelAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.control])
    }

    private var isFullscreenBottomControlsAutoHideEnabled: Bool {
        settings.fullscreenMiniPlayerAutoHideSeconds > 0
    }

    private var shouldBlockFullscreenBottomControlsAutoHide: Bool {
        shouldKeepFullscreenBottomControlsVisible
            || bottomControls.isHovered
            || bottomControls.isLeftActionsExpanded
            || bottomControls.isQuickAppearancePanelPresented
            || bottomControls.isVolumeExpanded
            || bottomControls.isProgressDragging
            || bottomControls.isVolumeAdjusting
            || isDetailReaderPanelPresented
    }

    private var shouldKeepFullscreenBottomControlsVisible: Bool {
        isShowingQueuePanel || bottomControls.isQuickAppearancePanelPresented || isDetailReaderPanelPresented
    }

    private func updateFullscreenMiniPlayerOcclusionRegion(_ region: FullscreenMiniPlayerOcclusionRegion) {
        fullscreenPointerOcclusionMonitor.updateRegion(
            SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID).scene == nil ? region : .inactive
        )
    }

    private func setPointerOverMiniPlayerOcclusion(_ isOccluded: Bool, reason: String) {
        if isPointerOverMiniPlayerOcclusion != isOccluded {
            isPointerOverMiniPlayerOcclusion = isOccluded
        }
        // Apply even when the state is unchanged. A native surface can be
        // created after the monitor already observed the pointer, so a
        // transition-only callback would leave that new surface ungated.
        applyFullscreenLyricsMouseGate(reason: reason)
    }

    private func applyFullscreenLyricsMouseGate(reason: String) {
        NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)?
            .setMouseInteractionSuppressed(SkinRegistry.fullscreenSkin(for: settings.fullscreen.skinID).scene == nil && isPointerOverMiniPlayerOcclusion)
    }

    private func handleFullscreenBottomControlsHover(_ hovering: Bool) {
        bottomControls.isHovered = hovering
        if hovering {
            cancelFullscreenBottomControlsAutoHide()
            setFullscreenBottomControlsVisible(true)
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
        if let hoverState = bottomControls.updateHoverGate(
            hotZone: hotZone,
            appearancePanel: appearancePanel,
            leading: leading,
            center: center,
            trailing: trailing
        ) {
            handleFullscreenBottomControlsHover(hoverState)
        }
    }

    private func registerFullscreenBottomControlsInteraction() {
        setFullscreenBottomControlsVisible(true)
        guard bottomControls.isHovered == false else {
            cancelFullscreenBottomControlsAutoHide()
            return
        }
        scheduleFullscreenBottomControlsAutoHideIfNeeded()
    }

    private func setQuickAppearancePanelPresented(_ isPresented: Bool) {
        guard bottomControls.isQuickAppearancePanelPresented != isPresented else { return }

        withAnimation(quickAppearancePanelAnimation) {
            bottomControls.isQuickAppearancePanelPresented = isPresented
        }

        if isPresented {
            cancelFullscreenBottomControlsAutoHide()
            setFullscreenBottomControlsVisible(true)
        } else {
            updateFullscreenBottomControlsHoverGate(appearancePanel: false)
            scheduleFullscreenBottomControlsAutoHideIfNeeded()
        }
    }

    private func handleRightPanelDisplayStateChange(
        _ oldState: RightPanelDisplayState,
        _ newState: RightPanelDisplayState
    ) {
        syncFullscreenLyricsHostMount()

        syncNativeFullscreenRenderingState()

        if newState == .lyrics, oldState != .lyrics {
            let trackID = currentDisplayContext.trackID
            let canRevealExistingLyrics =
                LyricsSurfaceManager.shared.currentMode == .fullscreen
                && LyricsSurfaceManager.shared.switchState == .idle
                && LyricsSurfaceManager.shared.hasReadySurface(for: .fullscreen)
            let isEndingAutoRestore = trackID != nil && lyricsCoordinator.restoreInitialZeroTrackID == trackID
            if isEndingAutoRestore {
                if lyricsCoordinator.pendingAutoRestoreTrackID == trackID {
                    scheduleFullscreenLyricsAutoRestorePreload(trackID: trackID)
                } else {
                    if canRevealExistingLyrics {
                        revealFullscreenExistingLyrics(reason: fullscreenLyricsAutoRestoreReason)
                    }
                    scheduleFullscreenLyricsAutoRestoreMarkerClear(trackID: trackID)
                }
            } else {
                let reason = "fullscreen lyrics shown"
                reloadLyricsSurface(reason: reason, forceLyricsReload: false)
                if canRevealExistingLyrics {
                    revealFullscreenExistingLyrics(reason: reason)
                }
            }
        }

        if newState == .queue {
            cancelFullscreenBottomControlsAutoHide()
            setFullscreenBottomControlsVisible(true)
            return
        }

        scheduleFullscreenBottomControlsAutoHideIfNeeded()
    }

    private func resetFullscreenBottomControlsAutoHideState() {
        bottomControls.cancelAutoHide()
        bottomControls.cancelSideControlCollapses()
        bottomControls.isVisible = true
        bottomControls.isProgressDragging = false
        bottomControls.isVolumeAdjusting = false
        bottomControls.isHovered = false
        bottomControls.isHotZoneHovered = false
        bottomControls.isAppearancePanelHovered = false
        bottomControls.isLeadingHovered = false
        bottomControls.isCenterHovered = false
        bottomControls.isTrailingHovered = false
        setLeftActionsExpanded(false, reason: "reset")
        setVolumeExpanded(false, reason: "reset")
        scheduleFullscreenBottomControlsAutoHideIfNeeded()
    }

    private func scheduleFullscreenBottomControlsAutoHideIfNeeded() {
        bottomControls.scheduleAutoHide(
            after: settings.fullscreenMiniPlayerAutoHideSeconds,
            shouldBlock: { shouldBlockFullscreenBottomControlsAutoHide },
            setVisible: { setFullscreenBottomControlsVisible($0) },
            setLeftActionsExpanded: { setLeftActionsExpanded($0, reason: $1) },
            setVolumeExpanded: { setVolumeExpanded($0, reason: $1) },
            scheduleAgain: { scheduleFullscreenBottomControlsAutoHideIfNeeded() }
        )
    }

    private func cancelFullscreenBottomControlsAutoHide() {
        bottomControls.cancelAutoHide()
    }

    private func scheduleLeftActionsCollapseIfNeeded(reason: String) {
        bottomControls.scheduleLeftCollapse(
            reason: reason,
            setLeftActionsExpanded: { setLeftActionsExpanded($0, reason: $1) },
            scheduleAutoHide: { scheduleFullscreenBottomControlsAutoHideIfNeeded() }
        )
    }

    private func cancelLeftActionsCollapse() {
        bottomControls.cancelLeftCollapse()
    }

    private func scheduleVolumeCollapseIfNeeded(reason: String) {
        bottomControls.scheduleVolumeCollapse(
            reason: reason,
            setVolumeExpanded: { setVolumeExpanded($0, reason: $1) },
            scheduleAutoHide: { scheduleFullscreenBottomControlsAutoHideIfNeeded() }
        )
    }

    private func cancelVolumeCollapse() {
        bottomControls.cancelVolumeCollapse()
    }

    private func cancelFullscreenSideControlCollapses() {
        bottomControls.cancelSideControlCollapses()
    }

    private func setLeftActionsExpanded(_ expanded: Bool, reason: String) {
        bottomControls.setLeftActionsExpanded(
            expanded,
            reason: reason,
            animate: animateFullscreenBottomControlsGeometry
        )
    }

    private func setVolumeExpanded(_ expanded: Bool, reason: String) {
        bottomControls.setVolumeExpanded(
            expanded,
            reason: reason,
            volumeControlEnabled: playbackCoordinator.presentation.isVolumeControlEnabled,
            animate: animateFullscreenBottomControlsGeometry
        )
    }

    // MARK: - Fullscreen Bottom Bar Layer (Actual Resolution - Crisp)
    
    @ViewBuilder
    private func fullscreenBottomBarLayer(
        scale: CGFloat,
        screenWidth: CGFloat,
        screenHeight: CGFloat
    ) -> some View {
        let geometry = fullscreenBottomControlsGeometry()
        let foregroundProfile = fullscreenMiniPlayerForegroundProfile
        let glassStyle = fullscreenControlsGlassStyle
        FullscreenBottomBarView(
            metrics: FullscreenBottomBarMetrics(
                scale: scale,
                screenSize: CGSize(width: screenWidth, height: screenHeight),
                canvasSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
                buttonSize: fullscreenControlButtonSize,
                bottomPadding: fullscreenControlsBottomPadding,
                geometryConfiguration: fullscreenBottomControlsGeometryConfiguration,
                controlsGeometry: geometry,
                quickAppearancePanelFrame: quickAppearancePanelFrame(
                    scale: scale,
                    screenSize: CGSize(width: screenWidth, height: screenHeight),
                    leadingControlsOriginX: geometry.leadingControlsRect.minX
                )
            ),
            presentation: FullscreenBottomBarPresentation(
                glassStyle: glassStyle,
                miniPlayerForegroundProfile: foregroundProfile,
                quickPanelForegroundProfile: fullscreenQuickPanelForegroundProfile,
                primaryColor: fullscreenMiniPlayerPrimaryColor,
                iconBlendMode: fullscreenMiniPlayerIconBlendMode,
                playbackMode: currentPlaybackMode,
                hasTrack: currentDisplayContext.hasTrack,
                isShowingLyrics: isShowingLyricsPanel,
                isVolumeControlEnabled: playbackCoordinator.stablePresentation.isVolumeControlEnabled,
                usesAdaptiveVolumeForeground:
                    fullscreenSkinDescriptor.presentation.controlForeground == .artworkAdaptive,
                showsPlaybackModeRetapTip: showPlaybackModeRetapTip
            ),
            actions: FullscreenBottomBarActions(
                exitFullscreen: { onExitFullscreen?() },
                toggleLyrics: { handleLyricsButtonTap() },
                setQuickAppearancePanelPresented: setQuickAppearancePanelPresented,
                hotZoneHoverChanged: { updateFullscreenBottomControlsHoverGate(hotZone: $0) },
                centerHoverChanged: { hovering in
                    updateFullscreenBottomControlsHoverGate(center: hovering)
                    if hovering { registerFullscreenBottomControlsInteraction() }
                },
                leadingHoverChanged: { hovering in
                    updateFullscreenBottomControlsHoverGate(leading: hovering)
                    if hovering {
                        cancelLeftActionsCollapse()
                        setLeftActionsExpanded(true, reason: "left-hover-enter")
                        registerFullscreenBottomControlsInteraction()
                    } else {
                        scheduleLeftActionsCollapseIfNeeded(reason: "left-hover-exit")
                        scheduleFullscreenBottomControlsAutoHideIfNeeded()
                    }
                },
                trailingHoverChanged: { hovering in
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
                appearancePanelHoverChanged: {
                    updateFullscreenBottomControlsHoverGate(appearancePanel: $0)
                },
                progressDraggingChanged: { dragging in
                    bottomControls.isProgressDragging = dragging
                    if dragging {
                        registerFullscreenBottomControlsInteraction()
                    } else {
                        scheduleFullscreenBottomControlsAutoHideIfNeeded()
                    }
                },
                volumeAdjustingChanged: { adjusting in
                    bottomControls.isVolumeAdjusting = adjusting
                    if adjusting {
                        registerFullscreenBottomControlsInteraction()
                    } else {
                        scheduleVolumeCollapseIfNeeded(reason: "volume-adjust-end")
                        scheduleFullscreenBottomControlsAutoHideIfNeeded()
                    }
                },
                interaction: registerFullscreenBottomControlsInteraction,
                playbackModeChanged: handlePlaybackModeChange,
                currentPlaybackModeRetapped: handleCurrentPlaybackModeRetap,
                editTrackRequested: { track in
                    registerFullscreenBottomControlsInteraction()
                    trackToEdit = track
                },
                editExternalInfoRequested: {
                    registerFullscreenBottomControlsInteraction()
                    isShowingExternalMatchEditor = true
                },
                showDetailRequested: { track in
                    registerFullscreenBottomControlsInteraction()
                    showDetailReader(for: track)
                },
                dismissPlaybackModeRetapTip: dismissPlaybackModeRetapTip
            ),
            controls: bottomControls,
            volume: volumeBinding
        )
    }

    // MARK: - Artwork and Controls Area (No Lyrics - Lyrics are in crisp layer)

    @ViewBuilder
    private func artworkAndControlsArea(selectedSkin: any NowPlayingSkin, scale: CGFloat) -> some View {
        let splitLayout = layoutMetrics
        let artworkOffsetX =
            splitLayout.artworkLeadingX
            + splitLayout.artworkWidth * 0.5
            - Self.baseCanvasWidth * 0.5
        let context = makeContext(
            windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
            artworkColumnWidth: splitLayout.artworkWidth,
            fullscreenScale: scale
        )
        let artworkScale = usesCoverBlurBackdrop ? 1.0 : settings.fullscreenArtworkScale
        let groupLeftShift: CGFloat =
            (!usesCoverBlurBackdrop && context.lyricsVisible)
                ? FullscreenCoverHorizontalOffset.groupLeftBias
                : 0

        FullscreenSkinArtworkArea(
            skin: selectedSkin,
            context: context,
            artworkScale: artworkScale,
            groupLeftShift: groupLeftShift,
            onShowDetails: { showDetailReader(for: playbackCoordinator.presentation.localTrack) },
            onRefreshLyricsColors: {
                forceRefreshFullscreenLyricsColors(reason: "context-menu-refresh")
            }
        )
        .frame(width: splitLayout.artworkWidth)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: artworkOffsetX)
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
        guard playbackCoordinator.stablePresentation.source.isExternal else { return nil }
        let lyricsText = playbackCoordinator.stablePresentation.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard lyricsText.isEmpty else { return nil }
        if let externalMessage = playbackCoordinator.stablePresentation.externalLyricsStatusMessage {
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

                NativeLyricsViewRepresentable(
                    surface: NativeLyricsSurfaceManager.shared.surface(for: .fullscreen)
                )
                    .frame(
                        width: max(0, proxy.size.width - horizontalInset * 2),
                        height: expandedHeight
                    )
                    .offset(y: -lyricsViewportTopLift)
                    .opacity(fullscreenLyricsViewportOpacity)
                    .environment(\.colorScheme, .dark)
                    .mask(
                        ZStack(alignment: .top) {
                            fullscreenLyricsMask(
                                visibleHeight: proxy.size.height - lyricsViewportTopCropDown,
                                topFade: topFade,
                                bottomFade: bottomFade
                            )
                        }
                        .frame(height: expandedHeight, alignment: .top)
                        .offset(y: lyricsViewportTopCropDown)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
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
        playbackCoordinator.stablePresentation.localPlaybackOrderMode ?? settings.playbackOrderMode
    }

    private var lyricsLayoutAnimation: Animation? {
        motionPolicy.animation(for: motionTokens[.navigation])
    }

    private var fullscreenMiniPlayerPrimaryColor: Color {
        fullscreenMiniPlayerForegroundProfile.primaryColor.opacity(0.96)
    }

    private var fullscreenMiniPlayerPrimaryNSColor: NSColor {
        fullscreenMiniPlayerForegroundProfile.primary
    }

    private var fullscreenMiniPlayerIconBlendMode: BlendMode {
        fullscreenMiniPlayerForegroundProfile.iconBlendMode
    }

    private var fullscreenMiniPlayerForegroundProfile: FullscreenMiniPlayerForegroundProfile {
        let materialStyle: LiquidGlassPillMaterialStyle =
            settings.fullscreenMiniPlayerGlassMaterial == .normal ? .normal : .clear
        return FullscreenMiniPlayerForegroundStrategy.resolve(
            palette: themeStore.semanticPalette,
            localArtworkPolarity: fullscreenLocalArtworkPolarity,
            hasArtworkThemeColor: themeStore.hasArtworkThemeColor,
            controlForeground: fullscreenSkinDescriptor.presentation.controlForeground,
            colorScheme: colorScheme,
            materialStyle: materialStyle,
            fullscreenArtBackgroundEnabled: settings.fullscreenArtBackgroundEnabled
        )
    }

    /// Local rendered-region polarity for the Cover Blur fullscreen controls.
    /// Returns a cached value (`resolvedLocalPolarity`); the contrast engine is
    /// too expensive to run per body evaluation. `recomputeLocalPolarity()`
    /// refreshes the cache only when the decision inputs change, driven by
    /// `.onChange(of: localPolarityInputSignature)`. Nil (fall back to the
    /// global gate) until a map arrives or for non-Cover-Blur skins.
    private var fullscreenLocalArtworkPolarity: ArtworkForegroundPolarity? {
        guard usesCoverBlurBackdrop else { return nil }
        return resolvedLocalPolarity
    }

    private func handleFullscreenLocalArtworkPolarityChange(
        _ oldValue: ArtworkForegroundPolarity?,
        _ newValue: ArtworkForegroundPolarity?
    ) {
        #if DEBUG
        let source: String
        if newValue == nil {
            source = usesCoverBlurBackdrop ? "fallback-global" : "n/a"
        } else {
            source = "cover-blur-local"
        }
        let polarity = newValue?.rawValue ?? "nil"
        let timestamp = String(format: "%.4f", ProcessInfo.processInfo.systemUptime)
        FSDiagnostics.emit(
            "readability polarity source=\(source) polarity=\(polarity) skin=\(settings.fullscreen.skinID) t=\(timestamp)",
            category: .fullscreen
        )
        #endif
    }

    /// Cheap value signature over every polarity-decision input: skin, artwork,
    /// render keys, viewport geometry and candidate colours. Pointer-driven
    /// expansion is deliberately excluded because all interaction layouts are
    /// scored together by `stableReadabilityRegions`.
    /// Compared between body evaluations so the expensive engine only re-runs
    /// on a real input change instead of on every body / every profile access.
    private var localPolarityInputSignature: LocalPolarityInputSignature {
        let state = backdropReadabilityState
        let candidates = FullscreenMiniPlayerForegroundStrategy.artworkCandidateProfiles(
            palette: themeStore.semanticPalette
        )
        let overlayCandidates = FullscreenMiniPlayerForegroundStrategy.overlayCandidateProfiles(
            palette: themeStore.semanticPalette
        )
        return LocalPolarityInputSignature(
            isCoverBlurSkin: usesCoverBlurBackdrop,
            artworkChecksum: state.artworkChecksum,
            leadingRenderKey: state.leading?.renderKey,
            centeredRenderKey: state.centered?.renderKey,
            transitionRenderKey: state.transition?.renderKey,
            viewportSize: fullscreenViewportSize,
            fullscreenScale: currentFullscreenScale,
            darkForegroundHash: candidates.dark.primary.hash,
            lightForegroundHash: candidates.light.primary.hash,
            overlayDarkForegroundHash: overlayCandidates.dark.primary.hash,
            overlayLightForegroundHash: overlayCandidates.light.primary.hash
        )
    }

    /// Recompute and cache the local polarity from the current readability
    /// maps. Called from `.onChange(of: localPolarityInputSignature, initial: true)`,
    /// so it runs on the main actor only on artwork / render / viewport / skin
    /// changes - never per frame. The engine work is bounded (a few region
    /// sorts) and only happens a handful of times per track switch.
    private func recomputeLocalPolarity() {
        let state = backdropReadabilityState
        guard usesCoverBlurBackdrop else {
            commitLocalPolarities(bottom: nil, queue: nil, quickPanel: nil)
            return
        }
        // Hold the last complete decision while the new artwork's three maps
        // render independently. Partial commits are the source of the visible
        // light/dark/light flashing during track and layout transitions.
        guard state.hasCompleteMapSet else { return }

        let viewportSize = fullscreenViewportSize
        let regions = FullscreenBottomControlsGeometry.stableReadabilityRegions(
            viewportSize: viewportSize,
            baseCanvasSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
            expansionPoints: ColorSystemTokens.ReadabilityForeground.regionExpansionPoints,
            configuration: fullscreenBottomControlsGeometryConfiguration
        )
        let referenceGeometry = fullscreenBottomControlsGeometry(
            isLeftActionsExpanded: false,
            isVolumeExpanded: false
        )

        let miniPlayerCandidates = FullscreenMiniPlayerForegroundStrategy.artworkCandidateProfiles(
            palette: themeStore.semanticPalette
        )
        let overlayCandidates = FullscreenMiniPlayerForegroundStrategy.overlayCandidateProfiles(
            palette: themeStore.semanticPalette
        )

        let bottomPolarity = localPolarity(
            regions: regions,
            darkForeground: miniPlayerCandidates.dark.primary,
            lightForeground: miniPlayerCandidates.light.primary,
            state: state,
            viewportSize: viewportSize
        )
        let queuePolarity = localPolarity(
            regions: fullscreenQueueReadabilityRegions(
                viewportSize: viewportSize,
                scale: currentFullscreenScale
            ),
            darkForeground: overlayCandidates.dark.primary,
            lightForeground: overlayCandidates.light.primary,
            state: state,
            viewportSize: viewportSize
        )
        let quickPanelPolarity = localPolarity(
            regions: quickAppearancePanelReadabilityRegions(
                viewportSize: viewportSize,
                scale: currentFullscreenScale,
                leadingControlsOriginX: referenceGeometry.leadingControlsRect.minX
            ),
            darkForeground: overlayCandidates.dark.primary,
            lightForeground: overlayCandidates.light.primary,
            state: state,
            viewportSize: viewportSize
        )

        commitLocalPolarities(
            bottom: bottomPolarity,
            queue: queuePolarity,
            quickPanel: quickPanelPolarity
        )
    }

    private func scheduleLocalPolarityRecompute() {
        localPolarityRecomputeTask?.cancel()
        guard usesCoverBlurBackdrop else {
            recomputeLocalPolarity()
            return
        }
        let scheduledSignature = localPolarityInputSignature
        localPolarityRecomputeTask = Task { @MainActor in
            // Rendering placements publish independently. Wait for a short
            // quiet window so a resize/config update also commits once, after
            // all related render-key changes have arrived.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  scheduledSignature == localPolarityInputSignature else { return }
            recomputeLocalPolarity()
        }
    }

    private func localPolarity(
        regions: [NormalizedReadabilityRegion],
        darkForeground: NSColor,
        lightForeground: NSColor,
        state: FullscreenBackdropReadabilityState,
        viewportSize: CGSize
    ) -> ArtworkForegroundPolarity? {
        guard !regions.isEmpty else { return nil }
        var samples: [(map: RenderedBackdropReadabilityMap, regions: [NormalizedReadabilityRegion])] = []
        if let leading = state.leading {
            samples.append((leading.readabilityMap, regions))
        }
        if let centered = state.centered {
            samples.append((centered.readabilityMap, regions))
        }
        if let transition = state.transition {
            for frame in transition.transitionFrames
            where abs(frame.height - viewportSize.height) < 1 {
                let mappedRegions = regions.compactMap {
                    BackdropFrameReadabilityMapping.map(
                        viewportRegion: $0,
                        viewportSize: viewportSize,
                        backdropFrame: frame
                    )
                }
                if !mappedRegions.isEmpty {
                    samples.append((transition.readabilityMap, mappedRegions))
                }
            }
        }
        guard !samples.isEmpty else { return nil }
        let decision = RenderedBackdropReadability.decide(
            darkForeground: darkForeground,
            lightForeground: lightForeground,
            samples: samples
        )
        return decision.reason == .noValidSamples ? nil : decision.polarity
    }

    private func fullscreenQueueReadabilityRegions(
        viewportSize: CGSize,
        scale: CGFloat
    ) -> [NormalizedReadabilityRegion] {
        guard viewportSize.width > 0, viewportSize.height > 0, scale > 0 else { return [] }
        let visibleBottomReserve: CGFloat = bottomControls.isVisible
            ? fullscreenControlsBottomPadding
            : 0
        let visibleHeight = (Self.baseCanvasHeight - visibleBottomReserve) * scale
        let width = 520 * scale
        let height = min(visibleHeight * 0.92, 660 * scale)
        let rect = CGRect(
            x: viewportSize.width - 118 * scale - width,
            y: 72 * scale,
            width: width,
            height: height
        )
        return normalizedReadabilityRegions(for: rect, viewportSize: viewportSize, scale: scale)
    }

    private func quickAppearancePanelReadabilityRegions(
        viewportSize: CGSize,
        scale: CGFloat,
        leadingControlsOriginX: CGFloat
    ) -> [NormalizedReadabilityRegion] {
        let rect = quickAppearancePanelFrame(
            scale: scale,
            screenSize: viewportSize,
            leadingControlsOriginX: leadingControlsOriginX
        )
        return normalizedReadabilityRegions(for: rect, viewportSize: viewportSize, scale: scale)
    }

    private func normalizedReadabilityRegions(
        for rect: CGRect,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> [NormalizedReadabilityRegion] {
        guard viewportSize.width > 0, viewportSize.height > 0,
              rect.width > 0, rect.height > 0 else { return [] }
        let expansion = ColorSystemTokens.ReadabilityForeground.regionExpansionPoints * scale
        let expanded = rect.insetBy(dx: -expansion, dy: -expansion)
        let x0 = max(0, expanded.minX)
        let y0 = max(0, expanded.minY)
        let x1 = min(viewportSize.width, expanded.maxX)
        let y1 = min(viewportSize.height, expanded.maxY)
        guard x1 > x0, y1 > y0 else { return [] }
        return [NormalizedReadabilityRegion(
            x: x0 / viewportSize.width,
            y: y0 / viewportSize.height,
            width: (x1 - x0) / viewportSize.width,
            height: (y1 - y0) / viewportSize.height
        )]
    }

    private func commitLocalPolarities(
        bottom: ArtworkForegroundPolarity?,
        queue: ArtworkForegroundPolarity?,
        quickPanel: ArtworkForegroundPolarity?
    ) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            resolvedLocalPolarity = bottom
            resolvedQueueLocalPolarity = queue
            resolvedQuickPanelLocalPolarity = quickPanel
        }
    }

    private func quickAppearancePanelFrame(
        scale: CGFloat,
        screenSize: CGSize,
        leadingControlsOriginX: CGFloat
    ) -> CGRect {
        guard scale > 0, screenSize.width > 0, screenSize.height > 0 else { return .zero }
        let scaledButtonSize = fullscreenControlButtonSize * scale
        let scaledWindowWidth = Self.baseCanvasWidth * scale
        let canvasBottomMargin = max(0, (screenSize.height - Self.baseCanvasHeight * scale) / 2)
        let scaledBottomPadding = fullscreenControlsBottomPadding * scale + canvasBottomMargin
        let hotZoneHeight = scaledButtonSize + 34 * scale
        let controlsRowHeight = max(scaledButtonSize, hotZoneHeight)
        let adjustedBottomPadding = max(
            0,
            scaledBottomPadding - (controlsRowHeight - scaledButtonSize) * 0.5
        )
        let canvasLeadingMargin = max(0, (screenSize.width - scaledWindowWidth) * 0.5)
        let panelSize = FullscreenQuickAppearancePanel.panelSize(for: scale)
        let safeMargin = 20 * scale
        let gap = 22 * scale
        let panelBottomY = screenSize.height - adjustedBottomPadding - controlsRowHeight - gap
        let horizontalInset = 10 * scale
        let idealCenterX =
            canvasLeadingMargin
            + leadingControlsOriginX * scale
            - horizontalInset
            + panelSize.width * 0.5
        let centerX = min(
            max(idealCenterX, safeMargin + panelSize.width * 0.5),
            max(
                safeMargin + panelSize.width * 0.5,
                screenSize.width - safeMargin - panelSize.width * 0.5
            )
        )
        let centerY = max(
            safeMargin + panelSize.height * 0.5,
            panelBottomY - panelSize.height * 0.5
        )
        return CGRect(
            x: centerX - panelSize.width * 0.5,
            y: centerY - panelSize.height * 0.5,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private var fullscreenControlsGlassStyle: FullscreenControlsGlassStyle {
        let materialStyle: LiquidGlassPillMaterialStyle =
            settings.fullscreenMiniPlayerGlassMaterial == .normal ? .normal : .clear

        // The glass surface uses the polarity complementary to the resolved
        // foreground ink, for both Clear and Normal Glass. This value is also
        // forced onto the GlassEffectContainer via `.environment(\.colorScheme, …)`
        // (see fullscreenBottomBarLayer) so the Liquid Glass material itself
        // renders in that polarity, independent of the app appearance. The
        // per-pill `.environment(\.colorScheme, …)` overrides that were added
        // before did NOT reach the material - the GlassEffectContainer resolves
        // the glass tint at its own scope, so the override must sit on the
        // container, not on the pills inside it. Clear Glass previously forced
        // `.dark` for Cover Blur / Apple Style, which left Cover Blur Clear
        // Glass dark-tinted even on bright covers (dark ink); complementary
        // makes it follow the cover. For every other skin complementary equals
        // the app appearance, so they are unchanged.
        let effectiveColorScheme: ColorScheme =
            fullscreenMiniPlayerForegroundProfile.complementaryGlassColorScheme

        return FullscreenControlsGlassStyle(
            colorScheme: effectiveColorScheme,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            materialStyle: materialStyle
        )
    }

    private var fullscreenQueueForegroundProfile: FullscreenOverlayForegroundProfile {
        FullscreenMiniPlayerForegroundStrategy.resolveOverlaySurface(
            palette: themeStore.semanticPalette,
            localArtworkPolarity: resolvedQueueLocalPolarity,
            controlForeground: fullscreenSkinDescriptor.presentation.controlForeground,
            colorScheme: colorScheme
        )
    }

    private var fullscreenQueueGlassStyle: FullscreenControlsGlassStyle {
        let materialStyle: LiquidGlassPillMaterialStyle =
            settings.fullscreenMiniPlayerGlassMaterial == .normal ? .normal : .clear
        return FullscreenControlsGlassStyle(
            colorScheme: fullscreenQueueForegroundProfile.colorScheme,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            materialStyle: materialStyle
        )
    }

    private var fullscreenQuickPanelForegroundProfile: FullscreenOverlayForegroundProfile {
        FullscreenMiniPlayerForegroundStrategy.resolveOverlaySurface(
            palette: themeStore.semanticPalette,
            localArtworkPolarity: resolvedQuickPanelLocalPolarity,
            controlForeground: fullscreenSkinDescriptor.presentation.controlForeground,
            colorScheme: colorScheme
        )
    }

    private var coverBlurBaseBlendMode: BlendMode {
        if usesMeshLyricsBackdrop {
            return .plusLighter
        }
        guard usesCoverBlurBackdrop else { return .normal }
        switch lyricsCoordinator.coverBlurTheme?.profile {
        case .lighter:
            return .plusLighter
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
        let trackOffsetMs: Double
        if playbackCoordinator.presentation.source.isExternal {
            trackOffsetMs = max(-15000, min(15000, playbackCoordinator.presentation.externalLyricsTimeOffsetMs ?? 0))
        } else {
            trackOffsetMs = max(-15000, min(15000, playbackCoordinator.presentation.localTrack?.lyricsTimeOffsetMs ?? 0))
        }
        let typography = settings.effectiveFullscreenLyricsTypography
        return [
            settings.fullscreen.skinID,
            String(settings.fullscreenLyricsTypographyRevision),
            typography.mainFontNameZh,
            typography.mainFontNameEn,
            typography.translationFontName,
            String(format: "%.2f", typography.mainFontSize),
            String(format: "%.2f", typography.translationFontSize),
            String(typography.mainFontWeight),
            String(typography.translationFontWeight),
            String(format: "%.0f", settings.lyricsLeadInMs),
            String(format: "%.0f", settings.lyricsNearSwitchGapMs),
            String(format: "%.0f", settings.lyricsGlobalAdvanceMs),
            String(format: "%.2f", settings.amllLyricsRenderQualityScale),
            settings.amllDiscreteWordHighlightEnabled ? "wordDiscrete" : "wordSmooth",
            playbackCoordinator.presentation.source.rawValue,
            hostContext.rawValue,
            overlay.signature,
            String(format: "%.0f", trackOffsetMs),
        ].joined(separator: "|")
    }

    private func setupSeekCallback() {
        let seekHandler: (Double) -> Void = { seconds in
            playbackCoordinator.seekAndResumeIfNeeded(to: seconds)
        }
        NativeLyricsSurfaceManager.shared.setSeekHandler(seekHandler, for: .fullscreen)
    }

    private func startFullscreenLyricsSurface(reason: String) {
        // Publish the concrete playback snapshot before asking the surface
        // manager to switch modes. A newly prepared fullscreen page can report
        // `onReady` before this view reaches its reload call; if the manager
        // still holds its initial empty snapshot, the ready-gated replay would
        // legitimately clear the page and the queued startup apply would be
        // discarded as stale. Seeding the shared snapshot first keeps the
        // switch atomic without creating or retaining another lyrics renderer.
        // Preinstall the role-specific layout, timing and motion contract;
        // activation can then materialize the view with its final config.
        applyFullscreenLyricsTheme(force: true, reason: "native pre-activation")

        // Report visibility to manager first so a newly materialized surface can
        // replay the latest snapshot. The reload path still refreshes the
        // fullscreen payload/theme. Embedded startup explicitly forces one
        // concrete track apply below because the manager may have completed
        // against the pre-startup empty snapshot before the SwiftUI host had a
        // valid viewport.
        LyricsSurfaceManager.shared.reportFullscreenVisible(true)
        reloadLyricsSurface(
            reason: reason,
            forceLyricsReload: hostContext == .embeddedWindow
        )
    }

    private func revealFullscreenExistingLyrics(reason: String) {
        let currentTime = fullscreenLyricsRevealCurrentTime()
        synchronizeAndRevealFullscreenLyrics(at: currentTime, reason: reason)
    }

    private func scheduleFullscreenLyricsAutoRestorePreload(trackID: UUID?) {
        guard let trackID else { return }
        lyricsCoordinator.cancel(.autoRestoreReload)
        lyricsCoordinator.cancel(.autoRestoreReveal)
        lyricsCoordinator.cancel(.hostDetach)
        lyricsCoordinator.hostMounted = true
        lyricsCoordinator.suppressViewport = true

        let delay = motionDelay(full: 0.28, reduced: 0.18)
        lyricsCoordinator.schedule(.autoRestoreReload, after: delay) {
            guard currentDisplayContext.trackID == trackID else {
                return
            }
            guard rightPanelDisplayState == .hidden else {
                return
            }

            reloadLyricsSurface(
                reason: fullscreenLyricsAutoRestoreReason,
                forceLyricsReload: true,
                forcedCurrentTime: 0
            )

            synchronizeAndRevealFullscreenLyrics(
                at: 0,
                reason: fullscreenLyricsAutoRestoreReason
            )

            lyricsCoordinator.schedule(.autoRestoreReload, after: motionDelay(full: 0.78, reduced: 0.42)) {
                guard currentDisplayContext.trackID == trackID else {
                    return
                }
                guard rightPanelDisplayState == .hidden else {
                    return
                }
                lyricsCoordinator.pendingAutoRestoreTrackID = nil
                setRightPanelDisplayState(.lyrics)
                synchronizeAndRevealFullscreenLyrics(
                    at: 0,
                    reason: fullscreenLyricsAutoRestoreReason
                )

                lyricsCoordinator.schedule(.autoRestoreReveal, after: motionDelay(full: 0.44, reduced: 0.24)) {
                    guard currentDisplayContext.trackID == trackID else {
                        return
                    }
                    guard rightPanelDisplayState == .lyrics else {
                        return
                    }
                    synchronizeAndRevealFullscreenLyrics(
                        at: 0,
                        reason: fullscreenLyricsAutoRestoreReason
                    )
                    let revealAnimation = motionPolicy.animation(
                        for: motionTokens[.contentReplacement]
                    )
                    withAnimation(revealAnimation) {
                        lyricsCoordinator.suppressViewport = false
                    }
                    scheduleFullscreenLyricsAutoRestoreMarkerClear(trackID: trackID)
                }
            }
        }
    }

    private func synchronizeAndRevealFullscreenLyrics(at time: Double, reason: String) {
        let surface = NativeLyricsSurfaceManager.shared.surface(for: .fullscreen)
        surface.setCurrentTime(time, force: true)
        surface.followCurrentLyrics()
        syncNativeFullscreenRenderingState()
    }

    private func scheduleFullscreenLyricsAutoRestoreMarkerClear(trackID: UUID?) {
        guard let trackID else { return }
        lyricsCoordinator.schedule(.autoRestoreReload, after: motionDelay(full: 0.18, reduced: 0)) {
            guard currentDisplayContext.trackID == trackID else { return }
            if lyricsCoordinator.restoreInitialZeroTrackID == trackID {
                lyricsCoordinator.restoreInitialZeroTrackID = nil
            }
            if lyricsCoordinator.pendingAutoRestoreTrackID == trackID {
                lyricsCoordinator.pendingAutoRestoreTrackID = nil
            }
        }
    }

    private func fullscreenLyricsRevealCurrentTime() -> TimeInterval {
        if let trackID = currentDisplayContext.trackID,
           lyricsCoordinator.restoreInitialZeroTrackID == trackID
        {
            return 0
        }
        return playbackCoordinator.presentation.lyricsCurrentTime
    }

    private func fullscreenLyricsSurfaceTime(
        _ currentTime: TimeInterval,
        trackID: UUID?
    ) -> TimeInterval {
        lyricsCoordinator.lyricsSurfaceTime(currentTime, trackID: trackID)
    }

    private func isLedEnabledForFullscreenSkin() -> Bool {
        // The legacy key remains the source of the user's enabled/off choice;
        // the descriptor supplies this skin's capability and key namespace.
        guard let descriptor = SkinRegistry.registeredDescriptor(for: settings.fullscreen.skinID),
              descriptor.audio.hasLedMeter else {
            return false
        }
        let key = descriptor.legacy?.visualizerKey(scope: .fullscreen)
            ?? "skin.\(descriptor.id).fullscreen.visualizerMode"
        return UserDefaults.standard.string(forKey: key) == "led"
    }

    private func syncFullscreenLedService() {
        let enabled = isLedEnabledForFullscreenSkin()
        if enabled {
        let _fsLedEnabled = enabled
        let _fsLedGetOrCreateNil = ledMeterProvider.getOrCreate() == nil
        FSDiagnostics.emit(
            "syncFullscreenLedService BODY ledEnabled=\(_fsLedEnabled) getOrCreateNil=\(_fsLedGetOrCreateNil) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
            ledMeterProvider.getOrCreate()?
                .updatePlaybackState(isPlaying: playbackCoordinator.presentation.isPlaying)
        } else {
            ledMeterProvider.releaseNowPlayingResources()
        }
    }

    private func handleLyricsButtonTap(isAutomatic: Bool = false) {
        lyricsCoordinator.prepareForLyricsButtonTap(
            isAutomatic: isAutomatic,
            trackID: currentDisplayContext.trackID
        )

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
            lyricsCoordinator.autoHiddenForEmptyContent = false
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: false,
                preserveRestoreEligibility: shouldPreserveFullscreenLyricsEndingAutoHideRestore()
            )
            return
        }

        if payload.hasDisplayableLyrics {
            if lyricsCoordinator.autoHiddenForEmptyContent && rightPanelDisplayState == .hidden {
                handleLyricsButtonTap(isAutomatic: true)
            } else {
                lyricsCoordinator.autoHiddenForEmptyContent = false
            }
            return
        }

        guard rightPanelDisplayState == .lyrics else { return }
        handleLyricsButtonTap(isAutomatic: true)
        lyricsCoordinator.autoHiddenForEmptyContent = true
    }

    private func syncFullscreenLyricsAutoHideTiming(with payload: FullscreenPlaybackPayload) {
        let effects = lyricsCoordinator.updateAutoHide(
            FullscreenLyricsAutoHideSnapshot(
                trackID: payload.trackID,
                displayTrackID: currentDisplayContext.trackID,
                hasDisplayableLyrics: payload.hasDisplayableLyrics,
                ttml: payload.ttml,
                currentTime: payload.currentTime,
                duration: playbackCoordinator.presentation.duration,
                isPlaying: payload.isPlaying,
                isLyricsPanelVisible: rightPanelDisplayState == .lyrics,
                isRightPanelHidden: rightPanelDisplayState == .hidden,
                displayHasTrack: currentDisplayContext.hasTrack,
                visualOffsetSeconds: fullscreenLyricsVisualOffsetSeconds()
            ),
            trailingGapThreshold: fullscreenLyricsAutoHideTrailingGap,
            delayAfterFinalLine: fullscreenLyricsAutoHideDelayAfterFinalLine
        )
        if let trackID = effects.preloadTrackID {
            scheduleFullscreenLyricsAutoRestorePreload(trackID: trackID)
        }
        if let event = effects.autoHide {
            logFullscreenLyricsAutoHide(event)
            handleLyricsButtonTap(isAutomatic: true)
        }
    }

    private func evaluateFullscreenLyricsAutoHide(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        let snapshot = FullscreenLyricsAutoHideSnapshot(
            trackID: lyricsCoordinator.autoHideTrackID,
            displayTrackID: currentDisplayContext.trackID,
            hasDisplayableLyrics: lyricsCoordinator.lastEndTime != nil,
            ttml: nil,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            isLyricsPanelVisible: rightPanelDisplayState == .lyrics,
            isRightPanelHidden: rightPanelDisplayState == .hidden,
            displayHasTrack: currentDisplayContext.hasTrack,
            visualOffsetSeconds: 0
        )
        guard let event = lyricsCoordinator.evaluateAutoHide(
            snapshot,
            trailingGapThreshold: fullscreenLyricsAutoHideTrailingGap,
            delayAfterFinalLine: fullscreenLyricsAutoHideDelayAfterFinalLine
        ) else { return }
        logFullscreenLyricsAutoHide(event)
        handleLyricsButtonTap(isAutomatic: true)
    }

    private func logFullscreenLyricsAutoHide(_ event: FullscreenLyricsAutoHideEvent) {
        Log.debug(
            "[FullscreenLyricsAutoHide] hiding lyrics after final line gap=\(String(format: "%.2f", event.trailingGap))s threshold=\(String(format: "%.2f", fullscreenLyricsAutoHideTrailingGap))s visualEnd=\(String(format: "%.2f", event.visualLastEnd)) delay=\(String(format: "%.2f", fullscreenLyricsAutoHideDelayAfterFinalLine))s track=\(event.trackID?.uuidString.prefix(8) ?? "nil")",
            category: .lyrics
        )
    }

    private func resetFullscreenLyricsEndingAutoHide(
        restoreIfNeeded: Bool,
        nextTrackHasDisplayableLyrics: Bool = false,
        nextTrackID: UUID? = nil,
        preserveRestoreEligibility: Bool = false
    ) {
        if let trackID = lyricsCoordinator.resetEndingAutoHide(
            restoreIfNeeded: restoreIfNeeded,
            nextTrackHasDisplayableLyrics: nextTrackHasDisplayableLyrics,
            nextTrackID: nextTrackID,
            preserveRestoreEligibility: preserveRestoreEligibility,
            rightPanelIsHidden: rightPanelDisplayState == .hidden,
            displayHasTrack: currentDisplayContext.hasTrack
        ) {
            scheduleFullscreenLyricsAutoRestorePreload(trackID: trackID)
        }
    }

    private func shouldStartFullscreenLyricsAtZero(for payload: FullscreenPlaybackPayload) -> Bool {
        lyricsCoordinator.shouldStartAtZero(
            trackID: payload.trackID,
            hasDisplayableLyrics: payload.hasDisplayableLyrics
        )
    }

    private func shouldDeferFullscreenLyricsAutoRestoreApply(
        for payload: FullscreenPlaybackPayload,
        reason: String
    ) -> Bool {
        lyricsCoordinator.shouldDeferAutoRestoreApply(
            trackID: payload.trackID,
            hasDisplayableLyrics: payload.hasDisplayableLyrics,
            reason: reason,
            autoRestoreReason: fullscreenLyricsAutoRestoreReason
        )
    }

    private func shouldPreserveFullscreenLyricsEndingAutoHideRestore() -> Bool {
        lyricsCoordinator.shouldPreserveEndingAutoHideRestore(
            rightPanelIsHidden: rightPanelDisplayState == .hidden
        )
    }

    private func fullscreenLyricsVisualOffsetSeconds() -> TimeInterval {
        let presentation = playbackCoordinator.presentation
        let overlayContext: LyricsRuntimePresentationContext =
            hostContext == .embeddedWindow ? .fullscreenEmbedded : .fullscreenSystem
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: overlayContext,
            playbackSource: presentation.source
        )
        let trackOffsetMs: Double
        if presentation.source.isExternal {
            trackOffsetMs = max(-15000, min(15000, presentation.externalLyricsTimeOffsetMs ?? 0))
        } else {
            trackOffsetMs = max(-15000, min(15000, presentation.localTrack?.lyricsTimeOffsetMs ?? 0))
        }
        let effectiveGlobalAdvanceMs = max(
            -5000,
            min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
        )
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - effectiveGlobalAdvanceMs))
        return TimeInterval(combinedOffsetMs) / 1000.0
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
        if newState == .queue && rightPanelDisplayState != .queue {
            lastRightPanelDisplayStateBeforeQueue = rightPanelDisplayState
        }

        let needsSystemFullscreenBlendPreflight = newState == .lyrics
            && playbackCoordinator.presentation.hasTrack
            && hostContext == .systemFullscreenSpace
            && usesCoverBlurBackdrop
            && !lyricsCoordinator.suppressViewport

        if newState == .lyrics, playbackCoordinator.presentation.hasTrack {
            if needsSystemFullscreenBlendPreflight {
                // Materialize the lyrics surface under opacity zero for two
                // display frames. True system fullscreen can otherwise present the
                // newly reattached layer once with normal compositing before
                // SwiftUI installs plusLighter / plusDarker.
                lyricsCoordinator.cancel(.reveal)
                lyricsCoordinator.suppressViewport = true
            }
            // A detached/suspended fullscreen surface can otherwise remount for
            // one frame with the default palette and normal blend, then switch
            // to the cover-aware profile after reload. Publish the
            // final config and blend profile before making the host visible.
            if usesCoverBlurLyricsRenderingPath {
                applyFullscreenLyricsTheme(
                    force: true,
                    reason: "fullscreen lyrics pre-show"
                )
            }
            lyricsCoordinator.cancel(.hostDetach)
            lyricsCoordinator.hostMounted = true
        }

        withAnimation(lyricsLayoutAnimation) {
            rightPanelDisplayState = newState
        }

        if needsSystemFullscreenBlendPreflight {
            scheduleSystemFullscreenLyricsBlendReveal(
                after: motionDelay(full: 2.0 / 60.0, reduced: 0)
            )
        }
    }

    private func applyPlaybackMode(_ mode: PlaybackOrderMode) {
        playbackCoordinator.setPlaybackOrderMode(mode)
    }

    private var playbackModeRetapTipTaskID: String {
        let presentation = playbackCoordinator.stablePresentation
        guard presentation.source == .local,
              presentation.hasTrack,
              presentation.isPlaying
        else {
            return "inactive"
        }
        return presentation.localTrack?.id.uuidString ?? "local-track-unknown"
    }

    @MainActor
    private func schedulePlaybackModeRetapTipIfNeeded() async {
        guard playbackModeRetapTipTaskID != "inactive" else { return }
        do {
            try await Task.sleep(for: .seconds(FeatureTipCatalog.PlaybackModeRetap.playbackStartDelay))
        } catch {
            return
        }
        guard !Task.isCancelled,
              playbackModeRetapTipTaskID != "inactive",
              showPlaybackModeRetapTip == false
        else { return }

        FeatureTipPresentationCoordinator.shared.requestPresentation(
            key: FeatureTipCatalog.PlaybackModeRetap.key
        ) { [self] in
            presentPlaybackModeRetapTipNow()
        }
    }

    private func presentPlaybackModeRetapTipNow() -> Bool {
        guard playbackModeRetapTipTaskID != "inactive",
              showPlaybackModeRetapTip == false,
              AppVersionGate.shared.claimPlaybackModeRetapFeatureTipDisplay()
        else { return false }

        withAnimation(bottomControlsAnimation) {
            showPlaybackModeRetapTip = true
        }
        return true
    }

    private func finishPlaybackModeRetapTipPresentation() {
        FeatureTipPresentationCoordinator.shared.endPresentation(
            key: FeatureTipCatalog.PlaybackModeRetap.key
        )
    }

    private func dismissPlaybackModeRetapTip() {
        AppVersionGate.shared.markPlaybackModeRetapFeatureTipDismissed()
        withAnimation(bottomControlsAnimation) {
            showPlaybackModeRetapTip = false
        }
        finishPlaybackModeRetapTipPresentation()
    }

    private var scrollWheelVolumeTipTaskID: String {
        let presentation = playbackCoordinator.stablePresentation
        guard presentation.hasTrack,
              presentation.isPlaying
        else {
            return "inactive"
        }
        return presentation.localTrack?.id.uuidString ?? "active"
    }

    @MainActor
    private func scheduleScrollWheelVolumeTipIfNeeded() async {
        guard scrollWheelVolumeTipTaskID != "inactive" else { return }
        do {
            try await Task.sleep(
                for: .seconds(FeatureTipCatalog.ScrollWheelVolume.presentationDelay)
            )
        } catch {
            return
        }
        guard !Task.isCancelled,
              scrollWheelVolumeTipTaskID != "inactive",
              showScrollWheelVolumeTip == false
        else { return }

        FeatureTipPresentationCoordinator.shared.requestPresentation(
            key: FeatureTipCatalog.ScrollWheelVolume.key
        ) { [self] in
            presentScrollWheelVolumeTipNow()
        }
    }

    private func presentScrollWheelVolumeTipNow() -> Bool {
        let key = FeatureTipCatalog.ScrollWheelVolume.key
        guard scrollWheelVolumeTipTaskID != "inactive",
              showScrollWheelVolumeTip == false,
              isArtworkVolumeControlEnabled,
              AppVersionGate.shared.claimFeatureTipDisplay(
                featureKey: key,
                introducedBuild: FeatureTipCatalog.ScrollWheelVolume.introducedBuild,
                maxDisplayCount: FeatureTipCatalog.ScrollWheelVolume.maxDisplayCount
              )
        else { return false }

        withAnimation(bottomControlsAnimation) {
            showScrollWheelVolumeTip = true
        }
        return true
    }

    private func finishScrollWheelVolumeTipPresentation() {
        FeatureTipPresentationCoordinator.shared.endPresentation(
            key: FeatureTipCatalog.ScrollWheelVolume.key
        )
    }

    private func dismissScrollWheelVolumeTip() {
        withAnimation(bottomControlsAnimation) {
            showScrollWheelVolumeTip = false
        }
        finishScrollWheelVolumeTipPresentation()
    }

    private func handleQueueTrackTap(_ track: Track) {
        playbackCoordinator.playTrackFromQueue(track)
    }

    private func handleLocalPlayingChange(_ newValue: Bool) {
        guard currentDisplayContext.source == .local else { return }
        LyricsSurfaceManager.shared.updatePlayingState(newValue)
    }

    private func handleExternalPlayingChange(_ newValue: Bool) {
        guard currentDisplayContext.source.isExternal else { return }
        LyricsSurfaceManager.shared.updatePlayingState(newValue)
    }

    private func handleCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        guard currentDisplayContext.source == .local else { return }
        let trackID = playerVM.currentTrack?.id
        let rawLyricsTime = playerVM.lyricsCurrentTime
        let lyricsTime = fullscreenLyricsSurfaceTime(rawLyricsTime, trackID: trackID)
        LyricsSurfaceManager.shared.updatePlaybackTime(lyricsTime)
        evaluateFullscreenLyricsAutoHide(
            currentTime: rawLyricsTime,
            duration: playerVM.duration,
            isPlaying: playerVM.isPlaying
        )
        if oldTime > 1.0, newTime < 0.2 {
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: false,
                preserveRestoreEligibility: shouldPreserveFullscreenLyricsEndingAutoHideRestore()
            )
            // A manual track switch also resets the playback clock. The
            // track-id observer will perform the required full reload for the
            // new song; reloading here as well duplicates the WebKit layer
            // commit and was the main fullscreen hitch during next/previous.
            let currentTrackID = playerVM.currentTrack?.id ?? currentDisplayContext.trackID
            if lastFullscreenLyricsReloadSignature?.trackID == currentTrackID {
                reloadLyricsSurface(reason: "fullscreen playback restarted", forceLyricsReload: true)
            }
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }

        cancelPendingFullscreenLyricsThemeWork()
        lyricsCoordinator.coverBlurTheme = nil

        // Simplified track change handling - matches window mode behavior
        // Apply track immediately without deferred scheduling
        syncFullscreenLyricsHostMount()
        reloadLyricsSurface(reason: "fullscreen track changed", forceLyricsReload: true)
    }

    private func handlePresentationCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        guard playbackCoordinator.presentation.source.isExternal else { return }
        let trackID = playbackCoordinator.presentation.displayTrackID
        let rawLyricsTime = playbackCoordinator.presentation.lyricsCurrentTime
        let lyricsTime = fullscreenLyricsSurfaceTime(rawLyricsTime, trackID: trackID)
        LyricsSurfaceManager.shared.updatePlaybackTime(lyricsTime)
        evaluateFullscreenLyricsAutoHide(
            currentTime: rawLyricsTime,
            duration: playbackCoordinator.presentation.duration,
            isPlaying: playbackCoordinator.presentation.isPlaying
        )
        if oldTime > 1.0, newTime < 0.2 {
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: false,
                preserveRestoreEligibility: shouldPreserveFullscreenLyricsEndingAutoHideRestore()
            )
            // External track identity changes have their own observer below;
            // only reload here when the identity is still the one already
            // delivered to the fullscreen surface (true same-track replay).
            let currentTrackID = playbackCoordinator.presentation.displayTrackID
            if lastFullscreenLyricsReloadSignature?.trackID == currentTrackID {
                reloadLyricsSurface(reason: "fullscreen external playback restarted", forceLyricsReload: true)
            }
        }
    }

    private func handlePresentationLyricsIdentityChange(_ oldId: String?, _ newId: String?) {
        guard playbackCoordinator.presentation.source.isExternal else { return }
        guard oldId != newId else { return }
        cancelPendingFullscreenLyricsThemeWork()
        lyricsCoordinator.coverBlurTheme = nil
        syncFullscreenLyricsHostMount()
        reloadLyricsSurface(reason: "fullscreen external track changed", forceLyricsReload: true)
    }

    private func handleLibraryTrackDidUpdate(_ notification: Notification) {
        guard let trackID = notification.userInfo?["trackID"] as? UUID else {
            Log.info("[FullscreenLyricsReload] libraryTrackDidUpdate missing trackID", category: .lyrics)
            return
        }

        let currentTrackID = playerVM.currentTrack?.id ?? playbackCoordinator.presentation.localTrack?.id
        Log.info(
            "[FullscreenLyricsReload] libraryTrackDidUpdate received trackID=\(trackID.uuidString.prefix(8)), currentTrackID=\(currentTrackID?.uuidString.prefix(8) ?? "nil"), source=\(playbackCoordinator.presentation.source.rawValue), host=\(hostContext.rawValue)",
            category: .lyrics
        )

        guard playbackCoordinator.presentation.source == .local else { return }
        guard trackID == currentTrackID else { return }

        let refreshedTrack = FullscreenWindowManager.shared.libraryVM?.allTracks.first { $0.id == trackID }
        let playerLyricsLen = resolvedFullscreenLyricsText(for: playerVM.currentTrack).count
        let refreshedLyricsLen = refreshedTrack.map { resolvedFullscreenLyricsText(for: $0).count } ?? -1
        Log.info(
            "[FullscreenLyricsReload] matched current track refreshedTrack=\(refreshedTrack != nil), playerLyricsLen=\(playerLyricsLen), refreshedLyricsLen=\(refreshedLyricsLen)",
            category: .lyrics
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
        lyricsCoordinator.cancelThemeWork()
    }

    private func reloadLyricsSurface(
        reason: String,
        forceLyricsReload: Bool = false,
        preferredLocalTrack: Track? = nil,
        forceLocalLyricsReload: Bool = false,
        forcedCurrentTime: Double? = nil
    ) {
        FSDiagnostics.emit(
            "reloadLyricsSurface ENTER reason=\(reason) forceLyricsReload=\(forceLyricsReload) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        var playbackPayload = makeFullscreenPlaybackPayload(
            preferredLocalTrack: preferredLocalTrack,
            forceLocalLyricsReload: forceLyricsReload || forceLocalLyricsReload
        )
        let reloadLogMessage = "[FullscreenLyricsReload] reload reason=\(reason), forceLyricsReload=\(forceLyricsReload), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil"), ttmlLen=\(playbackPayload.ttml?.count ?? 0), ttmlHash=\(playbackPayload.ttml?.hashValue ?? 0), time=\(String(format: "%.3f", playbackPayload.currentTime)), playing=\(playbackPayload.isPlaying), host=\(hostContext.rawValue)"
        Log.debug(reloadLogMessage, category: .lyrics)
        syncFullscreenLyricsAvailability(with: playbackPayload)
        syncFullscreenLyricsAutoHideTiming(with: playbackPayload)

        if let forcedCurrentTime, forcedCurrentTime.isFinite {
            playbackPayload = FullscreenPlaybackPayload(
                trackID: playbackPayload.trackID,
                ttml: playbackPayload.ttml,
                currentTime: max(0, forcedCurrentTime),
                isPlaying: playbackPayload.isPlaying
            )
        } else if shouldStartFullscreenLyricsAtZero(for: playbackPayload) {
            playbackPayload = FullscreenPlaybackPayload(
                trackID: playbackPayload.trackID,
                ttml: playbackPayload.ttml,
                currentTime: 0,
                isPlaying: playbackPayload.isPlaying
            )
        }
        publishFullscreenPlaybackSnapshot(playbackPayload)

        if shouldDeferFullscreenLyricsAutoRestoreApply(for: playbackPayload, reason: reason) {
            Log.debug(
                "[FullscreenLyricsAutoHide] deferring auto-restore reload track=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil"), time=\(String(format: "%.3f", playbackPayload.currentTime)), host=\(hostContext.rawValue)",
                category: .lyrics
            )
            scheduleFullscreenLyricsAutoRestorePreload(trackID: playbackPayload.trackID)
            return
        }

        if hostContext == .embeddedWindow && !embeddedInitialThemeUnlocked {
            Log.info(
                "[FullscreenLyricsReload] skipped embedded startup gate reason=\(reason), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil")",
                category: .lyrics
            )
            return
        }

        let reloadSignature = FullscreenLyricsReloadSignature(
            payload: playbackPayload,
            hostContext: hostContext
        )
        let now = ProcessInfo.processInfo.systemUptime
        if !reason.lowercased().contains("theme"),
           reloadSignature == lastFullscreenLyricsReloadSignature,
           now - lastFullscreenLyricsReloadAt < duplicateLyricsReloadCoalesceInterval
        {
            Log.debug(
                "[FullscreenLyricsReload] coalesced duplicate payload reason=\(reason), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil"), ttmlLen=\(playbackPayload.ttml?.count ?? 0), host=\(hostContext.rawValue)",
                category: .lyrics
            )
            publishFullscreenPlaybackSnapshot(playbackPayload)
            syncNativeFullscreenRenderingState()
            return
        }
        lastFullscreenLyricsReloadSignature = reloadSignature
        lastFullscreenLyricsReloadAt = now

        setupSeekCallback()

        // The native surface uses the spring/font/alignment config active at
        // materialization time. Apply the final fullscreen config first
        // so a newly materialized surface does not animate once with defaults
        // and then jump when setConfig arrives.
        applyFullscreenLyricsTheme()

        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: playbackPayload.trackID,
            lyricsTTML: playbackPayload.ttml ?? "",
            currentTime: playbackPayload.currentTime,
            isPlaying: playbackPayload.isPlaying,
            forceLyricsReload: forceLyricsReload
        )
        setupSeekCallback()
        if !lyricsCoordinator.pendingBackgroundCapture {
            captureFullscreenLyricsBackgroundSnapshot()
        }
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

    private struct FullscreenLyricsReloadSignature: Equatable {
        let trackID: UUID?
        let ttmlLength: Int
        let ttmlHash: Int
        let hostContext: HostContext

        init(
            payload: FullscreenPlaybackPayload,
            hostContext: HostContext
        ) {
            self.trackID = payload.trackID
            self.ttmlLength = payload.ttml?.count ?? 0
            self.ttmlHash = payload.ttml?.hashValue ?? 0
            self.hostContext = hostContext
        }
    }

    private func makeFullscreenPlaybackPayload(
        preferredLocalTrack: Track? = nil,
        forceLocalLyricsReload: Bool = false
    ) -> FullscreenPlaybackPayload {
        let presentation = playbackCoordinator.presentation

        switch presentation.source {
        case .local:
            let track = preferredLocalTrack ?? playerVM.currentTrack
            let lyricsText = resolvedFullscreenLyricsText(
                for: track,
                forceDiskReload: forceLocalLyricsReload
            )
            return FullscreenPlaybackPayload(
                trackID: track?.id,
                ttml: track == nil ? nil : lyricsText,
                currentTime: fullscreenLyricsSurfaceTime(
                    playerVM.lyricsCurrentTime,
                    trackID: track?.id
                ),
                isPlaying: playerVM.isPlaying
            )
        case .appleMusic, .systemNowPlaying:
            let lyricsText = LyricsFormatSupport.normalizedTTMLText(presentation.lyricsText)
            return FullscreenPlaybackPayload(
                trackID: presentation.displayTrackID,
                ttml: lyricsText == nil ? nil : (lyricsText ?? ""),
                currentTime: fullscreenLyricsSurfaceTime(
                    presentation.lyricsCurrentTime,
                    trackID: presentation.displayTrackID
                ),
                isPlaying: presentation.effectiveLyricsIsPlaying
            )
        }
    }

    private func publishFullscreenPlaybackSnapshot(_ payload: FullscreenPlaybackPayload) {
        LyricsSurfaceManager.shared.updatePlaybackSnapshot(
            trackID: payload.trackID,
            lyricsTTML: payload.ttml ?? "",
            currentTime: payload.currentTime,
            isPlaying: payload.isPlaying
        )
    }

    private func updateFullscreenPlaybackSnapshot(
        preferredLocalTrack: Track? = nil,
        forceLocalLyricsReload: Bool = false
    ) -> FullscreenPlaybackPayload {
        let payload = makeFullscreenPlaybackPayload(
            preferredLocalTrack: preferredLocalTrack,
            forceLocalLyricsReload: forceLocalLyricsReload
        )
        publishFullscreenPlaybackSnapshot(payload)
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

        if let ttml = LyricsFormatSupport.normalizedTTMLText(track.ttmlLyricText ?? track.loadTTMLLyricsIfNeeded()) {
            return ttml
        }

        return ""
    }

    private func resolvedFullscreenLyricsTextFromDisk(for track: Track) -> String? {
        if let ttmlURL = track.resolvedTTMLURL(),
           let text = try? String(contentsOf: ttmlURL, encoding: .utf8),
           let ttml = LyricsFormatSupport.normalizedTTMLText(text) {
            return ttml
        }

        return nil
    }

    private var fullscreenLyricsHostOpacity: Double {
        guard isShowingLyricsPanel, playbackCoordinator.stablePresentation.hasTrack else { return 0 }
        return 1
    }

    private var shouldKeepFullscreenLyricsHostMounted: Bool {
        // The latch defers the detach so a hide/show cycle does not remount the
        // native surface. It must not outlive its reason though: while the lyrics
        // column is shown with a track, the host stays mounted regardless of a
        // stale latch, so a remount of the surrounding presentation layers can
        // never leave the column empty until the next fullscreen entry.
        guard playbackCoordinator.stablePresentation.hasTrack else { return false }
        return lyricsCoordinator.hostMounted || isShowingLyricsPanel
    }

    private var isFullscreenLyricsHostVisible: Bool {
        fullscreenLyricsHostOpacity > 0.001
    }

    private var fullscreenLyricsHostDetachDelay: TimeInterval {
        motionDelay(full: 0.72, reduced: 0.22)
    }

    private func syncFullscreenLyricsHostMount() {
        let shouldShowLyricsHost = isShowingLyricsPanel && playbackCoordinator.presentation.hasTrack

        lyricsCoordinator.cancel(.hostDetach)

        if shouldShowLyricsHost {
            lyricsCoordinator.hostMounted = true
            return
        }

        guard lyricsCoordinator.hostMounted else { return }
        scheduleFullscreenLyricsHostDetach(after: fullscreenLyricsHostDetachDelay)
    }

    private func scheduleFullscreenLyricsHostDetach(after delay: TimeInterval) {
        lyricsCoordinator.cancel(.hostDetach)

        let detachTrackID = currentDisplayContext.trackID
        lyricsCoordinator.schedule(.hostDetach, after: delay) {
            if isShowingLyricsPanel {
                return
            }
            if currentDisplayContext.trackID != detachTrackID {
                return
            }
            lyricsCoordinator.hostMounted = false
        }
    }

    private var fullscreenLyricsViewportOpacity: Double {
        guard currentDisplayContext.hasTrack else { return 0 }
        return lyricsCoordinator.suppressViewport ? 0 : 1
    }

    private func scheduleSystemFullscreenLyricsBlendReveal(after delay: TimeInterval) {
        lyricsCoordinator.cancel(.reveal)

        lyricsCoordinator.schedule(.reveal, after: delay) {
            guard isShowingLyricsPanel else {
                lyricsCoordinator.suppressViewport = false
                return
            }
            let revealAnimation = motionPolicy.animation(
                for: motionTokens[.contentReplacement]
            )
            withAnimation(revealAnimation) {
                lyricsCoordinator.suppressViewport = false
            }
        }
    }

    private func scheduleFullscreenLyricsViewportReveal(after delay: TimeInterval) {
        lyricsCoordinator.cancel(.reveal)

        let revealTrackID = currentDisplayContext.trackID
        lyricsCoordinator.schedule(.reveal, after: delay) {
            guard currentDisplayContext.trackID == revealTrackID else { return }
            withAnimation(lyricsLayoutAnimation) {
                lyricsCoordinator.suppressViewport = false
            }
        }
    }

    private func scheduleFullscreenTrackRefresh(
        layoutWillChange: Bool,
        revealLyricsAfterRefresh: Bool
    ) {
        lyricsCoordinator.cancel(.trackRefresh)
        lyricsCoordinator.cancel(.reveal)

        let delay = layoutWillChange
            ? motionDelay(full: 0.34, reduced: 0.20)
            : 0
        lyricsCoordinator.schedule(.trackRefresh, after: delay, runImmediately: true) {
            reloadLyricsSurface(reason: "fullscreen track changed", forceLyricsReload: true)
            if revealLyricsAfterRefresh {
                let revealTrackID = currentDisplayContext.trackID
                lyricsCoordinator.schedule(.reveal, after: motionDelay(full: 1.0 / 60.0, reduced: 0)) {
                    guard currentDisplayContext.trackID == revealTrackID else { return }
                    lyricsCoordinator.suppressViewport = false
                }
            } else {
                lyricsCoordinator.suppressViewport = false
            }
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
        let surfaceRole = LyricsSurfaceRole.fullscreen
        let effectiveTrack = playbackCoordinator.presentation.localTrack
        let displayTrackID = currentArtworkTrackID
        let overlayContext: LyricsRuntimePresentationContext =
            hostContext == .embeddedWindow ? .fullscreenEmbedded : .fullscreenSystem
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: overlayContext,
            playbackSource: playbackCoordinator.presentation.source
        )
        let readyCoverBlurTheme = usesCoverBlurBackdrop
            ? updateCoverBlurLyricsThemeIfReady(forTrackID: displayTrackID)
            : nil
        let heldCoverBlurTheme = lyricsCoordinator.coverBlurTheme
        let appleStyleCoverBlurTheme = usesMeshLyricsBackdrop
            ? makeAppleStyleCoverBlurLyricsTheme(forTrackID: displayTrackID)
            : nil
        let activeCoverBlurTheme: FullscreenCoverBlurLyricsTheme? = {
            if usesMeshLyricsBackdrop {
                return appleStyleCoverBlurTheme
            }
            guard usesCoverBlurBackdrop else { return nil }
            if let readyCoverBlurTheme {
                return readyCoverBlurTheme
            }
            if let heldCoverBlurTheme {
                if heldCoverBlurTheme.trackID == displayTrackID
                    || themeStoreArtworkThemePending(forTrackID: displayTrackID) {
                    return heldCoverBlurTheme
                }
            }
            return nil
        }()
        if shouldHoldFullscreenArtisticThemeWhilePalettePending(
            forTrackID: displayTrackID,
            activeCoverBlurTheme: activeCoverBlurTheme
        ) {
            Log.debug(
                "[OKLCH] hold fullscreen artistic lyrics palette pending reason=\(reason) track=\(displayTrackID?.uuidString.prefix(8) ?? "nil")",
                category: .theme
            )
            return
        }
        let semanticPalette = activeCoverBlurTheme?.palette
            ?? makeFullscreenLyricSemanticPalette(forTrackID: displayTrackID)
        let colorSet = semanticPalette.foregroundColorSet

        // The cover artwork palette is an enhancement, not a prerequisite for
        // showing lyrics. During a fresh fullscreen attach the artwork worker
        // can legitimately still be pending. Keep the generic semantic
        // palette below active in that window; once artwork arrives this method
        // is called again and upgrades the same native surface in place. Hiding the
        // entire host until the palette is ready made the first fullscreen
        // frame permanently blank when no later theme callback arrived.
        let activePalette = activeCoverBlurTheme.map { makeCoverBlurLyricsPalette(from: $0) }
            ?? makeFullscreenLyricsPalette(from: colorSet)
        guard isCurrentFullscreenLyricsThemeIdentity(themeIdentity) else {
            Log.debug("FullscreenPlayerView: skipped stale lyrics theme reason=\(reason)", category: .lyrics)
            return
        }

        LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
            activePalette,
            for: .fullscreen,
            trackID: themeIdentity.displayTrackID,
            trackGuarded: true
        )
        NativeLyricsSurfaceManager.shared.applyPalette(activePalette, for: .fullscreen)
        let typography = settings.effectiveFullscreenLyricsTypography
        let mainFontFamily = LyricsFontResolver.cssMainFontFamily(
            english: typography.mainFontNameEn,
            chinese: typography.mainFontNameZh
        )
        let translationFontFamily = LyricsFontResolver.cssFontFamily([
            typography.translationFontName
        ])
        let mainActiveColor = LyricRenderingAdapter.cssPayload(semanticPalette.mainActive)
        let mainInactiveColor = LyricRenderingAdapter.cssPayload(semanticPalette.mainInactive)
        let subActiveColor = LyricRenderingAdapter.cssPayload(semanticPalette.subActive)
        let subInactiveColor = LyricRenderingAdapter.cssPayload(semanticPalette.subInactive)
        let subColor = LyricRenderingAdapter.cssPayload(semanticPalette.subColor)
        let lineTimingMainInactiveColor = LyricRenderingAdapter.cssPayload(
            semanticPalette.lineTimingMainInactive
        )
        let lineTimingSubInactiveColor = LyricRenderingAdapter.cssPayload(
            semanticPalette.lineTimingSubInactive
        )
        let emphasisGlowColor = LyricRenderingAdapter.cssPayload(semanticPalette.emphasisGlow)
        let backgroundColor = LyricRenderingAdapter.cssPayload(semanticPalette.backgroundActive)
        let backgroundInactiveColor = LyricRenderingAdapter.cssPayload(
            semanticPalette.backgroundInactive
        )
        let backgroundKaraokeActiveColor = LyricRenderingAdapter.cssPayload(
            semanticPalette.backgroundKaraokeActive
        )
        let coverBlurMainGlowColor = LyricRenderingAdapter.cssPayload(
            semanticPalette.coverBlurMainGlow
        )
        let coverBlurSubGlowColor = LyricRenderingAdapter.cssPayload(
            semanticPalette.coverBlurSubGlow
        )
        let coverBlurThemeColor = activeCoverBlurTheme.map {
            ArtworkColorExtractor.cssRGBA($0.themeColor, alpha: 1.0)
        }
        if ProcessInfo.processInfo.environment["COLOR_SYSTEM_LYRICS_DEBUG"] == "1" {
            let analysis = resolveLyricsAnalysis(forTrackID: displayTrackID)
            let highlightBase = resolveFullscreenLyricsBaseColor(forTrackID: displayTrackID)
            let inactiveBase = resolveFullscreenLyricsInactiveBaseColor(forTrackID: displayTrackID)
            Log.debug(
                "[OKLCH] artisticLyrics theme reason=\(reason) "
                + "usesArtisticBackground=\(settings.fullscreenArtBackgroundEnabled) "
                + "analysis.isNearMonochrome=\(analysis.isNearMonochrome) "
                + "analysis.colorfulness=\(String(format: "%.3f", analysis.colorfulness)) "
                + "highlightBase=\(ColorSystemDiagnostic.describe(highlightBase)) "
                + "inactiveBase=\(ColorSystemDiagnostic.describe(inactiveBase)) "
                + "mainActive=\(ColorSystemDiagnostic.describe(colorSet.mainActive)) "
                + "mainInactive=\(ColorSystemDiagnostic.describe(colorSet.mainInactive)) "
                + "subActive=\(ColorSystemDiagnostic.describe(colorSet.subActive)) "
                + "subInactive=\(ColorSystemDiagnostic.describe(colorSet.subInactive)) "
                + "lineTimingMainInactive=\(ColorSystemDiagnostic.describe(colorSet.lineTimingMainInactive)) "
                + "lineTimingSubInactive=\(ColorSystemDiagnostic.describe(colorSet.lineTimingSubInactive))",
                category: .theme
            )
        }
        let trackOffsetMs: Double
        if playbackCoordinator.presentation.source.isExternal {
            trackOffsetMs = max(-15000, min(15000, playbackCoordinator.presentation.externalLyricsTimeOffsetMs ?? 0))
        } else {
            trackOffsetMs = max(-15000, min(15000, effectiveTrack?.lyricsTimeOffsetMs ?? 0))
        }
        let effectiveGlobalAdvanceMs = max(
            -5000,
            min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
        )
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - effectiveGlobalAdvanceMs))

        

        // Scale base sizes with fullscreen metrics first, then apply runtime presentation overlay.
        // For embedded fullscreen, this keeps +6/+4 as a visible on-screen delta instead of being
        // attenuated by the scale factor.
        let scaledBaseFontSize = typography.mainFontSize * currentFullscreenScale
        let scaledBaseTranslationFontSize =
            typography.translationFontSize * currentFullscreenScale
        let scaledFontSize = scaledBaseFontSize + overlay.mainFontSizeDeltaPx
        let scaledTranslationFontSize =
            scaledBaseTranslationFontSize + overlay.translationFontSizeDeltaPx
        let springSettings = settings.lyricSpringUserSettings

        if EmbeddedFullscreenTrace.enabled, hostContext == .embeddedWindow {
            Log.info(
                "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.embeddedFont overlay=(\(String(format: "%.1f", overlay.mainFontSizeDeltaPx)),\(String(format: "%.1f", overlay.translationFontSizeDeltaPx))) baseSetting=(\(String(format: "%.1f", typography.mainFontSize)),\(String(format: "%.1f", typography.translationFontSize))) scaledBase=(\(String(format: "%.2f", scaledBaseFontSize)),\(String(format: "%.2f", scaledBaseTranslationFontSize))) scaled=(\(String(format: "%.2f", scaledFontSize)),\(String(format: "%.2f", scaledTranslationFontSize)))",
                category: .fullscreen
            )
        }

        var config: [String: Any] = [
            "fontSize": scaledFontSize,
            "fontWeight": max(100, min(900, typography.mainFontWeight)),
            "fontFamilyMain": mainFontFamily,
            // MelismaKit reads these explicit families so Chinese and Latin
            // font controls do not collapse into the first family in the list.
            "fontFamilyLatin": typography.mainFontNameEn,
            "fontFamilyCJK": typography.mainFontNameZh,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": scaledTranslationFontSize,
            "translationFontWeight": max(
                100,
                min(900, typography.translationFontWeight)
            ),
            "renderScale": settings.amllLyricsRenderQualityScale,
            "enableBlur": surfaceRole.enableBlur,
            "enableSpring": surfaceRole.enableSpring,
            "springDuration": springSettings.duration,
            "springBounce": springSettings.bounce,
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
            "fullscreenSubColor": subColor,
            "fullscreenBackgroundColor": backgroundColor,
            "fullscreenBackgroundInactiveColor": backgroundInactiveColor,
            "fullscreenBackgroundKaraokeActiveColor": backgroundKaraokeActiveColor,
            "fullscreenEmphasisGlowColor": emphasisGlowColor,
            "fullscreenLineTimingInactiveColor": lineTimingMainInactiveColor,
            "fullscreenLineTimingSubInactiveColor": lineTimingSubInactiveColor,
            "fullscreenBackgroundBaseOpacity": Double(semanticPalette.alpha.backgroundBaseOpacity),
            "fullscreenBackgroundKaraokeOpacity": Double(semanticPalette.alpha.backgroundKaraokeOpacity),
            "alignAnchor": "top",
            "alignPosition": 0.18,
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
            config["coverBlurSubColor"] = subColor
            config["coverBlurBackgroundColor"] = backgroundColor
            config["coverBlurBackgroundInactiveColor"] = backgroundInactiveColor
            config["coverBlurBackgroundKaraokeActiveColor"] = backgroundKaraokeActiveColor
            config["coverBlurMainGlowColor"] = coverBlurMainGlowColor
            config["coverBlurSubGlowColor"] = coverBlurSubGlowColor
            config["coverBlurLineTimingInactiveColor"] = lineTimingMainInactiveColor
            config["coverBlurLineTimingSubInactiveColor"] = lineTimingSubInactiveColor
            config["coverBlurBackgroundBaseOpacity"] = Double(
                semanticPalette.alpha.dedicatedCoverBlurBackgroundBaseOpacity
            )
            config["coverBlurBackgroundKaraokeOpacity"] = Double(
                semanticPalette.alpha.dedicatedCoverBlurBackgroundKaraokeOpacity
            )
        }

        let baseConfig = config
        pushFullscreenLyricsConfig(
            baseConfig,
            role: .fullscreen,
            identity: themeIdentity,
            reason: reason
        )
        syncNativeFullscreenRenderingState()
    }

    private func syncNativeFullscreenRenderingState() {
        let manager = NativeLyricsSurfaceManager.shared
        let shouldRenderLyrics = rightPanelDisplayState == .lyrics
        manager.existingSurface(for: .fullscreen)?.setRenderingActive(
            shouldRenderLyrics && manager.isActive(.fullscreen)
        )
        // Re-apply the occlusion gate after activation/materialization. The
        // mini-player may already be under the pointer when the surface is
        // attached to the embedded fullscreen host.
        applyFullscreenLyricsMouseGate(reason: "native rendering state sync")
    }

    /// Re-assert the fullscreen lyrics presentation after a change that rebuilds
    /// the surrounding presentation layers (a skin switch remounts every
    /// skin-keyed layer). The lyrics host is deliberately not skin-keyed, so it
    /// keeps its identity across that rebuild and nothing else re-arms it: the
    /// mount latch, the viewport gate and the native rendering state can all
    /// survive a remount in a stale state until the next fullscreen entry.
    /// Idempotent, so it is safe to run on every skin switch.
    private func reassertFullscreenLyricsPresentation(reason: String) {
        guard FullscreenWindowManager.shared.presentationMode != .none else { return }
        guard isShowingLyricsPanel, playbackCoordinator.stablePresentation.hasTrack else { return }
        // Embedded fullscreen materializes the surface once its startup gate is
        // open; activating earlier would show a frame with default styling.
        guard hostContext != .embeddedWindow || embeddedInitialThemeUnlocked else { return }

        lyricsCoordinator.cancel(.hostDetach)
        lyricsCoordinator.cancel(.autoRestoreReload)
        lyricsCoordinator.cancel(.autoRestoreReveal)
        lyricsCoordinator.pendingAutoRestoreTrackID = nil
        lyricsCoordinator.suppressViewport = false
        lyricsCoordinator.hostMounted = true

        LyricsSurfaceManager.shared.reportFullscreenVisible(true)
        syncNativeFullscreenRenderingState()
        let surface = NativeLyricsSurfaceManager.shared.existingSurface(for: .fullscreen)
        surface?.reassertRendering()

        Log.debug(
            "[FullscreenLyrics] reasserted presentation reason=\(reason), host=\(hostContext.rawValue), mounted=\(lyricsCoordinator.hostMounted), suppressed=\(lyricsCoordinator.suppressViewport), rendering=\(surface?.isRenderingActive ?? false), ready=\(surface?.isReady ?? false)",
            category: .lyrics
        )
    }

    private func pushFullscreenLyricsConfig(
        _ config: [String: Any],
        role: LyricsSurfaceRole,
        identity: FullscreenLyricsThemeIdentity,
        reason: String
    ) {
        guard isCurrentFullscreenLyricsThemeIdentity(identity) else {
            Log.debug("FullscreenPlayerView: skipped stale lyrics config role=\(role.rawValue) reason=\(reason)", category: .lyrics)
            return
        }

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            LyricsSurfaceManager.shared.updateSurfaceConfigSnapshot(
                json,
                for: role,
                trackID: identity.displayTrackID,
                trackGuarded: true
            )
            guard isCurrentFullscreenLyricsThemeIdentity(identity) else {
                Log.debug("FullscreenPlayerView: skipped stale lyrics config delivery role=\(role.rawValue) reason=\(reason)", category: .lyrics)
                return
            }
            NativeLyricsSurfaceManager.shared.applyConfigurationJSON(json, for: role)
        }
    }

    private func clearFullscreenLyricsTheme() {
        LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(nil, for: .fullscreen)
        if let palette = ThemeStore.shared.palette {
            NativeLyricsSurfaceManager.shared.applyPalette(palette, for: .fullscreen)
        }
    }

    private func resetFullscreenLyricsBackgroundSnapshot() {
        lyricsCoordinator.lockedBackgroundColor = nil
        lyricsCoordinator.lockedBackgroundIsUltraDark = false
        lyricsCoordinator.pendingBackgroundCapture = false
    }

    private func scheduleFullscreenLyricsBackgroundCapture() {
        lyricsCoordinator.pendingBackgroundCapture =
            settings.fullscreenArtBackgroundEnabled && currentDisplayContext.hasTrack
    }

    private func captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: Bool = false) {
        guard settings.fullscreenArtBackgroundEnabled else {
            resetFullscreenLyricsBackgroundSnapshot()
            return
        }

        guard bkController.lyricsColorTrackID == currentArtworkTrackID else {
            lyricsCoordinator.pendingBackgroundCapture = currentDisplayContext.hasTrack
            return
        }

        if preferLiveSurface {
            lyricsCoordinator.lockedBackgroundColor =
                bkController.currentSurfaceBackgroundColor ?? bkController.primaryBackgroundColor
        } else {
            lyricsCoordinator.lockedBackgroundColor =
                bkController.primaryBackgroundColor ?? bkController.currentSurfaceBackgroundColor
        }
        lyricsCoordinator.lockedBackgroundIsUltraDark = bkController.isUltraDarkActive
        lyricsCoordinator.pendingBackgroundCapture = false
    }

    private func refreshFullscreenLyricsColors() {
        lyricsCoordinator.cancel(.refresh)
        resetFullscreenLyricsBackgroundSnapshot()
        captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)
        applyFullscreenLyricsTheme()
    }

    private func forceRefreshFullscreenLyricsColors(reason: String) {
        lyricsCoordinator.cancel(.refresh)

        resetFullscreenLyricsBackgroundSnapshot()
        captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)
        applyFullscreenLyricsTheme(force: true, reason: reason)

        let delayedReason = reason
        let delay: TimeInterval = 0.22
        lyricsCoordinator.schedule(.refresh, after: delay) {
            resetFullscreenLyricsBackgroundSnapshot()
            captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)
            applyFullscreenLyricsTheme(force: true, reason: "\(delayedReason)-delayed")
        }
    }

    private func scheduleFullscreenLyricsRefresh(preferLiveSurface: Bool) {
        lyricsCoordinator.cancel(.refresh)

        lyricsCoordinator.schedule(.refresh, after: 0.22) { [preferLiveSurface] in
            captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: preferLiveSurface)
            applyFullscreenLyricsTheme()
        }
    }

    private func handleEmbeddedFullscreenViewportChange(_ size: CGSize, reason: String) {
        let previousViewportSize = fullscreenViewportSize
        guard hostContext == .embeddedWindow else {
            fullscreenViewportSize = size
            return
        }
        guard isEmbeddedFullscreenPresentationActive else {
            if EmbeddedFullscreenTrace.enabled {
                Log.info(
                    "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.ignoreViewport reason=\(reason) mode=\(FullscreenWindowManager.shared.presentationMode)",
                    category: .fullscreen
                )
            }
            return
        }
        // The outgoing scene remains alive while it slides down. Restoring
        // the main toolbar must not publish its smaller layout rect into that
        // scene and rebuild the cover/theme halfway through the exit.
        fullscreenViewportSize = size
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
                        return
                    }
                }
                scheduleEmbeddedFullscreenStartupRetry(reason: reason)
                return
            }
            lyricsCoordinator.cancel(.embeddedStartupRetry)
            lyricsCoordinator.embeddedStartupRetryCount = 0
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

        lyricsCoordinator.cancel(.themeReapply)

        lyricsCoordinator.schedule(.themeReapply) {
            applyFullscreenLyricsTheme(force: true, reason: reason)
        }
    }

    private func currentEmbeddedHostWindowContentSize() -> CGSize? {
        guard isEmbeddedFullscreenPresentationActive else { return nil }

        let candidateWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard let window = candidateWindow else { return nil }
        let contentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        guard contentSize.width > 1, contentSize.height > 1 else { return nil }
        return contentSize
    }

    private func beginEmbeddedFullscreenStartupIfNeeded(reason: String) {
        guard isEmbeddedFullscreenPresentationActive else { return }
        guard !embeddedInitialThemeUnlocked else { return }
        guard isValidEmbeddedFullscreenGeometry(fullscreenViewportSize, scale: currentFullscreenScale) else {
            return
        }

        lyricsCoordinator.cancel(.embeddedStartupRetry)
        lyricsCoordinator.embeddedStartupRetryCount = 0
        syncFullscreenLyricsHostMount()

        resetFullscreenLyricsBackgroundSnapshot()
        scheduleFullscreenLyricsBackgroundCapture()
        captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: true)

        if let palette = ThemeStore.shared.palette {
            NativeLyricsSurfaceManager.shared.applyPalette(palette, for: .fullscreen)
        }

        embeddedInitialThemeUnlocked = true
        startFullscreenLyricsSurface(reason: reason)
    }

    private func scheduleEmbeddedFullscreenStartupRetry(reason: String) {
        guard isEmbeddedFullscreenPresentationActive else { return }
        guard lyricsCoordinator.embeddedStartupRetryCount < 20 else { return }
        lyricsCoordinator.cancel(.embeddedStartupRetry)
        lyricsCoordinator.embeddedStartupRetryCount += 1

        lyricsCoordinator.schedule(.embeddedStartupRetry, after: 0.05) {
            guard isEmbeddedFullscreenPresentationActive else { return }
            if let fallbackSize = currentEmbeddedHostWindowContentSize() {
                handleEmbeddedFullscreenViewportChange(fallbackSize, reason: "\(reason)-retry")
            } else {
                beginEmbeddedFullscreenStartupIfNeeded(reason: "\(reason)-retry")
            }
        }
    }

    private var isEmbeddedFullscreenPresentationActive: Bool {
        hostContext == .embeddedWindow
            && (FullscreenWindowManager.shared.isPreparingEmbeddedFullscreen
                || FullscreenWindowManager.shared.presentationMode == .embeddedInWindow)
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
        let displayArtworkTrackID = display.artworkTrackID ?? display.trackID ?? Self.fallbackExternalTrackID
        let renderingArtworkData = currentRenderingArtworkData

        let trackMeta: SkinContext.TrackMetadata? = display.hasTrack
            ? SkinContext.TrackMetadata(
                id: displayArtworkTrackID,
                title: display.title,
                artist: display.artist,
                album: display.album ?? "",
                duration: display.duration,
                // Keep the skin cache key atomic with the committed artwork
                // image: both come from `artworkSnapshot`. The presentation's
                // artworkData advances before the new full image decodes, so a
                // presentation-derived checksum would let skins render the held
                // previous cover under the next track's key and stay stuck on it.
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: renderingArtworkData,
                artworkFileURL: display.source == .local
                    && display.artworkData?.isEmpty != false
                    ? playbackCoordinator.stablePresentation.localTrack?.existingArtworkURL()
                    : nil,
                artworkImage: artworkSnapshot?.fullImage,
                displayedArtworkID: artworkSnapshot?.trackID
            )
            : nil

        let playback = SkinContext.PlaybackState(
            isPlaying: display.isPlaying
        )

        let analysis = themeStore.semanticPalette.analysis
        let fgProfile = fullscreenMiniPlayerForegroundProfile
        let spectrumArtworkColors: [NSColor]
        if fgProfile.role == .coverBlurDarkForeground || fgProfile.role == .coverBlurLightForeground {
            let primary: [NSColor]
            if !analysis.displayPalette.isEmpty {
                primary = analysis.displayPalette
            } else if !analysis.topPalette.isEmpty {
                primary = analysis.topPalette
            } else {
                primary = [
                    themeStore.semanticPalette.artBackgroundPrimary,
                    themeStore.semanticPalette.artBackgroundSecondary,
                ]
            }
            let chosen = Array(primary.prefix(2))
            spectrumArtworkColors = SpectrumColorResolver.prepareSpectrumColors(chosen, analysis: analysis)
        } else {
            spectrumArtworkColors = []
        }
        let spectrumUsesDarkForeground = fgProfile.spectrumUsesDarkForeground

        let theme = SkinContext.ThemeTokens(
            accentColor: themeStore.accentColor,
            colorScheme: colorScheme,
            artworkAccentColor: artworkSnapshot?.accentColor.map {
                ColorRenderingAdapter.makeSwiftUIColor($0)
            },
            artworkPalette: artworkSnapshot?.palette ?? [],
            artworkAverageColor: artworkSnapshot?.averageColor,
            artBackgroundIsUltraDark: colorScheme == .dark
                && settings.fullscreenArtBackgroundEnabled
                && bkController.isUltraDarkActive,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: spectrumUsesDarkForeground
        )

        let contentBounds = CGRect(
            origin: .zero,
            size: CGSize(width: artworkColumnWidth, height: windowSize.height * 0.62)
        )

        return SkinContext(
            track: trackMeta,
            playback: playback,
            theme: theme,
            motionTokens: motionTokens,
            motionPolicy: motionPolicy,
            windowSize: windowSize,
            contentBounds: contentBounds,
            fullscreenScale: fullscreenScale,
            lyricsVisible: isShowingRightPanel,
            presentationMode: .fullscreenPlayer,
            fullscreenHostMode: hostContext == .embeddedWindow ? .embeddedWindow : .systemFullscreen
        )
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

    private func makeFullscreenLyricSemanticPalette(forTrackID trackID: UUID?) -> FullscreenLyricPalette {
        SemanticPaletteFactory.fullscreenLyricSemanticPalette(
            analysis: resolveLyricsAnalysis(forTrackID: trackID),
            scheme: colorScheme,
            highlightBaseColor: resolveFullscreenLyricsBaseColor(forTrackID: trackID),
            inactiveBaseColor: resolveFullscreenLyricsInactiveBaseColor(forTrackID: trackID),
            isUltraDark: colorScheme == .dark && lyricsCoordinator.lockedBackgroundIsUltraDark,
            usesArtisticBackground: settings.fullscreenArtBackgroundEnabled,
            skinID: settings.fullscreen.skinID,
            backgroundType: settings.fullscreenArtBackgroundEnabled ? .artisticBackground : .standardSkin
        )
    }

    private func shouldHoldFullscreenArtisticThemeWhilePalettePending(
        forTrackID trackID: UUID?,
        activeCoverBlurTheme: FullscreenCoverBlurLyricsTheme?
    ) -> Bool {
        guard settings.fullscreenArtBackgroundEnabled,
              activeCoverBlurTheme == nil,
              currentDisplayContext.hasTrack,
              currentDisplayContext.artworkData?.isEmpty == false
        else {
            return false
        }

        if themeStorePaletteMatchesCurrentArtwork(forTrackID: trackID) {
            return false
        }

        if let snapshot = currentArtworkSnapshot(forTrackID: trackID) ?? currentArtworkSnapshotForDisplay(),
           snapshot.analysis != nil {
            return false
        }

        return true
    }

    private func makeCoverBlurLyricSemanticPalette(
        from themeColor: NSColor,
        profile: FullscreenCoverBlurBlendProfile,
        mode: LyricSurfaceMode,
        skinID: String
    ) -> FullscreenLyricPalette {
        SemanticPaletteFactory.coverBlurLyricSemanticPalette(
            analysis: resolveLyricsAnalysis(forTrackID: currentArtworkTrackID),
            themeColor: themeColor,
            profile: profile,
            mode: mode,
            skinID: skinID
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

        let themeLightness = OKColor.nsColorToOKLCH(themeColor)?.l ?? 0.50
        let profile: FullscreenCoverBlurBlendProfile = themeLightness > 0.72
            ? .darker
            : .lighter

        return FullscreenCoverBlurLyricsTheme(
            trackID: trackID,
            themeColor: themeColor,
            themeLightness: themeLightness,
            profile: profile,
            palette: makeCoverBlurLyricSemanticPalette(
                from: themeColor,
                profile: profile,
                mode: .coverBlur,
                skinID: "fullscreen.coverGradientBlur"
            )
        )
    }

    private func makeAppleStyleCoverBlurLyricsTheme(forTrackID trackID: UUID?) -> FullscreenCoverBlurLyricsTheme {
        let resolvedTrackID = trackID ?? Self.fallbackExternalTrackID
        let themeColor = resolveFullscreenLyricsBaseColor(forTrackID: trackID)
        let themeLightness = OKColor.nsColorToOKLCH(themeColor)?.l ?? 0.62
        let profile: FullscreenCoverBlurBlendProfile = .lighter

        return FullscreenCoverBlurLyricsTheme(
            trackID: resolvedTrackID,
            themeColor: themeColor,
            themeLightness: themeLightness,
            profile: profile,
            palette: makeCoverBlurLyricSemanticPalette(
                from: themeColor,
                profile: profile,
                mode: .appleStyle,
                skinID: AppleStyleSkin.skinID
            )
        )
    }

    private func updateCoverBlurLyricsThemeIfReady(
        forTrackID trackID: UUID?
    ) -> FullscreenCoverBlurLyricsTheme? {
        guard let resolvedTheme = makeCoverBlurLyricsTheme(forTrackID: trackID) else {
            return nil
        }

        let previousTrackID = lyricsCoordinator.coverBlurTheme?.trackID
        let previousProfile = lyricsCoordinator.coverBlurTheme?.profile
        let previousLightness = lyricsCoordinator.coverBlurTheme?.themeLightness ?? -1
        let themeChanged = previousTrackID != resolvedTheme.trackID
            || previousProfile != resolvedTheme.profile
            || abs(previousLightness - resolvedTheme.themeLightness) > 0.000_1

        if themeChanged {
            lyricsCoordinator.coverBlurTheme = resolvedTheme
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

        if themeStoreArtworkThemePending(forTrackID: trackID) {
            return themeStore.semanticPalette.fullscreenLyricBase
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    private func resolveFullscreenLyricsInactiveBaseColor(forTrackID trackID: UUID?) -> NSColor {
        // Phase 6 v2 contract: art surface background colours
        // (`bkController.currentSurfaceBackgroundColor`,
        // `primaryBackgroundColor`, `lyricsCoordinator.lockedBackgroundColor`)
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

        if themeStoreArtworkThemePending(forTrackID: trackID) {
            return themeStore.semanticPalette.fullscreenLyricInactiveBase
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    private func resolveLyricsAnalysis(forTrackID trackID: UUID?) -> ArtworkColorAnalysis {
        if themeStorePaletteMatchesCurrentArtwork(forTrackID: trackID) {
            return themeStore.semanticPalette.analysis
        }
        if let snapshot = currentArtworkSnapshot(forTrackID: trackID) ?? currentArtworkSnapshotForDisplay(),
           let analysis = snapshot.analysis {
            return analysis
        }
        return themeStore.semanticPalette.analysis
    }

    private func themeStoreArtworkThemePending(forTrackID trackID: UUID?) -> Bool {
        let display = currentDisplayContext
        guard let checksum = (
            currentArtworkSnapshot(forTrackID: trackID) ?? currentArtworkSnapshotForDisplay()
        )?.artworkChecksum else {
            return false
        }
        let identity = display.artworkIdentity ?? display.lyricsIdentity
        let expectedTrackID = trackID ?? display.artworkTrackID ?? display.trackID
        return themeStore.artworkThemePending(
            trackID: expectedTrackID,
            artworkIdentity: identity,
            artworkChecksum: checksum
        )
    }

    private func themeStorePaletteMatchesCurrentArtwork(forTrackID trackID: UUID?) -> Bool {
        let display = currentDisplayContext
        guard let checksum = (
            currentArtworkSnapshot(forTrackID: trackID) ?? currentArtworkSnapshotForDisplay()
        )?.artworkChecksum else {
            return false
        }
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
        // The local-track artwork source shortcut is only valid for local
        // playback. For external playback the provider resolves artwork into the
        // presentation; using the local track's own source here would disagree
        // with `artworkDisplayTrackID` and get rejected by the snapshot guard.
        if display.source == .local,
           let source = playbackCoordinator.stablePresentation.localTrack?.trackArtworkSource(fallbackData: display.artworkData) {
            return "\(trackID.uuidString)-local-\(source.sourceKey)-px:\(preferredArtworkFullImageMaxPixel)"
        }
        if ArtworkRenderingFallback.shouldUse(
            for: display.artworkData,
            isArtworkLoading: display.isArtworkLoading
        ) {
            let identity = display.artworkIdentity ?? display.lyricsIdentity ?? trackID.uuidString
            return "\(trackID.uuidString)-\(identity)-\(ArtworkRenderingFallback.identity(for: trackID))-px:\(preferredArtworkFullImageMaxPixel)"
        }
        let identity = display.artworkIdentity ?? display.lyricsIdentity ?? trackID.uuidString
        return "\(trackID.uuidString)-\(identity)-\(ArtworkDataFingerprint.sampledString(for: display.artworkData))-px:\(preferredArtworkFullImageMaxPixel)"
    }

    private var currentRenderingArtworkData: Data? {
        let display = currentDisplayContext
        if let artworkData = display.artworkData, !artworkData.isEmpty {
            return artworkData
        }
        if display.source == .local, playbackCoordinator.presentation.localTrack?.existingArtworkURL() != nil {
            return nil
        }
        let fallbackTrackID = display.artworkTrackID
        guard artworkSnapshot?.artworkChecksum == ArtworkRenderingFallback.checksum(for: fallbackTrackID) else {
            return nil
        }
        return ArtworkRenderingFallback.data(for: fallbackTrackID)
    }
    
    private func loadArtworkSnapshot() async {
        let expectedSkinGeneration = skinSession.generation
        let display = currentDisplayContext
        guard let trackID = display.artworkTrackID else {
            return
        }

        let expectedTrackID = trackID
        let expectedTaskKey = currentArtworkTaskKey
        let snapshot: ArtworkAssetSnapshot?
        if display.source == .local,
           let source = playbackCoordinator.presentation.localTrack?.trackArtworkSource(fallbackData: display.artworkData) {
            snapshot = await cacheServices.trackArtworkCache.snapshot(
                for: source,
                fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
            )
        } else if let artworkData = display.artworkData, !artworkData.isEmpty {
            snapshot = await ArtworkAssetStore.shared.snapshot(
                trackID: trackID,
                artworkData: artworkData,
                fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
            )
        } else if ArtworkRenderingFallback.shouldUse(
            for: display.artworkData,
            isArtworkLoading: display.isArtworkLoading
        ) {
            snapshot = await ArtworkAssetStore.shared.renderingFallbackSnapshot(
                trackID: trackID,
                fullImageMaxPixelSize: preferredArtworkFullImageMaxPixel
            )
        } else {
            return
        }
        guard !Task.isCancelled else { return }
        guard skinSession.generation == expectedSkinGeneration else { return }
        guard currentArtworkTrackID == expectedTrackID else { return }
        guard currentArtworkTaskKey == expectedTaskKey else { return }
        guard let snapshot, snapshot.trackID == expectedTrackID, Self.isValidDisplayArtworkSnapshot(snapshot) else {
            if !display.isArtworkLoading {
                artworkSnapshot = nil
            }
            return
        }

        artworkSnapshot = snapshot

        // CRITICAL: Trigger the native lyrics theme refresh after artwork colors are loaded
        // Without this, fullscreen lyrics colors would not update when track changes
        applyFullscreenLyricsTheme(reason: "artworkSnapshot-loaded")
    }

    private var preferredArtworkFullImageMaxPixel: Int {
        1_024
    }

    private static func isValidDisplayArtworkSnapshot(_ snapshot: ArtworkAssetSnapshot?) -> Bool {
        guard let image = snapshot?.fullImage else { return false }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return image.size.width > 1 && image.size.height > 1
        }
        return cgImage.width > 1 && cgImage.height > 1
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

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
    private typealias FullscreenLyricPalette = FullscreenLyricSemanticPalette
    private typealias FullscreenCoverBlurBlendProfile = LyricsCoverBlurBlendProfile

    private struct FullscreenCoverBlurLyricsTheme {
        let trackID: UUID
        let themeColor: NSColor
        let themeLightness: CGFloat
        let profile: FullscreenCoverBlurBlendProfile
        let palette: FullscreenLyricPalette

        var colors: FullscreenLyricsColorSet {
            palette.foregroundColorSet
        }
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

    private enum FeatureTips {
        static let playbackModeRetapKey = "fullscreen.playbackModeRetap"
        static let playbackModeRetapIntroducedBuild = AppBuild(1)
        static let playbackModeRetapMaxDisplayCount = 2
    }

    private nonisolated enum BottomControlGlassID: Hashable, Sendable {
        case leading
        case miniPlayer
        case volume
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
    private let fullscreenLyricsAutoHideTrailingGap: TimeInterval = 15.0
    private let fullscreenLyricsAutoHideDelayAfterFinalLine: TimeInterval = 2.0
    private let fullscreenLyricsAutoRestoreReason = "fullscreen lyrics auto-restored after ending"
    private let coverBlurLegacyTopContentLeftShift: CGFloat = 44
    private let coverBlurLegacyArtworkLyricsColumnSpacing: CGFloat = -58
    private let coverBlurLegacyLyricsColumnLeftNudge: CGFloat = 80
    private let coverBlurLegacyLyricsRightShift: CGFloat = 30
    private let coverBlurLegacyLeftExpansion: CGFloat = 80
    private let duplicateLyricsReloadCoalesceInterval: TimeInterval = 0.75

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
    @StateObject private var bkController = BKArtBackgroundController()
    @State private var skinRevision = 0
    @State private var rightPanelDisplayState: RightPanelDisplayState = .lyrics
    @State private var lockedFullscreenLyricsBackgroundColor: NSColor?
    @State private var lockedFullscreenLyricsUltraDark: Bool = false
    @State private var pendingFullscreenLyricsBackgroundCapture: Bool = false
    @State private var pendingFullscreenLyricsRefresh: DispatchWorkItem?
    @State private var pendingFullscreenLyricsReveal: DispatchWorkItem?
    @State private var pendingFullscreenLyricsAutoRestoreReload: DispatchWorkItem?
    @State private var pendingFullscreenLyricsAutoRestoreReveal: DispatchWorkItem?
    @State private var pendingFullscreenLyricsHostDetach: DispatchWorkItem?
    @State private var pendingFullscreenTrackRefresh: DispatchWorkItem?
    @State private var pendingFullscreenThemeReapply: DispatchWorkItem?
    @State private var pendingEmbeddedStartupRetry: DispatchWorkItem?
    @State private var embeddedStartupRetryCount = 0
    @State private var lastFullscreenLyricsReloadSignature: FullscreenLyricsReloadSignature?
    @State private var lastFullscreenLyricsReloadAt: TimeInterval = 0
    /// Last fully decoded artwork committed to the skin layer. Track metadata
    /// can advance ahead of artwork decoding, so this remains stable until a
    /// complete image for the current display track is ready.
    @State private var artworkSnapshot: ArtworkAssetSnapshot?
    @State private var coverBlurLyricsTheme: FullscreenCoverBlurLyricsTheme?
    @State private var deferredTrackUpdateDeadline: Date?
    @State private var autoHiddenFullscreenLyricsForEmptyContent = false
    @State private var autoHiddenFullscreenLyricsAfterEnding = false
    @State private var autoHiddenFullscreenLyricsAfterEndingCanRestore = false
    @State private var autoHideFullscreenLyricsTrackID: UUID?
    @State private var fullscreenLyricsLastEndTime: TimeInterval?
    @State private var fullscreenLyricsLastVisualEndTime: TimeInterval?
    @State private var fullscreenLyricsEndingAutoHideSuppressedTrackID: UUID?
    @State private var fullscreenLyricsRestoreInitialZeroTrackID: UUID?
    @State private var pendingFullscreenLyricsAutoRestoreTrackID: UUID?
    @State private var suppressFullscreenLyricsViewport = false
    @State private var fullscreenLyricsHostMounted = false
    @State private var isLeftActionsExpanded = false
    @State private var isQuickAppearancePanelPresented = false
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
    @Namespace private var fullscreenBottomControlsGlassNamespace
    @State private var embeddedInitialThemeUnlocked = false
    @State private var didHandleFullscreenAppear = false
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

    private var artisticBackgroundDimmingIntensity: Double {
        colorScheme == .light ? 0 : effectiveDimmingIntensity
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
        .onChange(of: fullscreenLocalArtworkPolarity) { _, newValue in
            #if DEBUG
            let source = newValue == nil
                ? (isCoverBlurFullscreenSkin ? "fallback-global" : "n/a")
                : "cover-blur-local"
            FSDiagnostics.emit(
                "readability polarity source=\(source) polarity=\(newValue?.rawValue ?? "nil") skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            #endif
        }
        .onChange(of: localPolarityInputSignature, initial: true) { _, _ in
            scheduleLocalPolarityRecompute()
        }
        .onChange(of: settings.fullscreen.skinID) { oldValue, newValue in
            skinRevision &+= 1
            FSDiagnostics.emit(
                "onChange(skinID) old=\(oldValue) new=\(newValue) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            if oldValue == "kmgccc.cassette", newValue != oldValue {
                Task {
                    await CassetteArtworkCache.shared.removeAll()
                }
            }
            let coverBlurTransition = oldValue == "fullscreen.coverGradientBlur"
                || newValue == "fullscreen.coverGradientBlur"
            FSDiagnostics.emit(
                "onChange(skinID) syncCoverBlurHighlight BEGIN external=\(playbackCoordinator.presentation.source.isExternal) coverBlurTransition=\(coverBlurTransition) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            syncCoverBlurHighlightActivation()
            if coverBlurTransition {
                FSDiagnostics.emit(
                    "onChange(skinID) reloadLyricsSurface CALL external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                    category: .fullscreen
                )
                reloadLyricsSurface(reason: "fullscreen skin changed", forceLyricsReload: true)
            } else {
                applyFullscreenLyricsTheme(force: true, reason: "fullscreen skin changed")
            }
        }
        .onChange(of: fullscreenLedServiceSignature) { _, _ in
            FSDiagnostics.emit(
                "onChange(skinID) syncFullscreenLedService CALL external=\(playbackCoordinator.presentation.source.isExternal) sig=\(fullscreenLedServiceSignature) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
                category: .fullscreen
            )
            syncFullscreenLedService()
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
        }
        .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
        .onChange(of: playbackCoordinator.presentation.currentTime, handlePresentationCurrentTimeChange)
        .onChange(of: playbackCoordinator.presentation.effectiveLyricsIsPlaying) { _, newValue in
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
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // No-op unless KMGCCC_AMLL_FULLSCREEN_LAYER_DIAGNOSTICS=1; used to
            // correlate WebView layer state with markAllLayersVolatile floods.
            FullscreenLyricsLayerDiagnostics.logPeriodicSnapshot(
                store: existingFullscreenStore,
                hostOpacity: fullscreenLyricsHostOpacity,
                viewportOpacity: fullscreenLyricsViewportOpacity,
                hostMounted: shouldKeepFullscreenLyricsHostMounted,
                controlsVisible: isFullscreenBottomControlsVisible,
                disableWrapper: LyricsDebugFlags.fullscreenDisableSwiftUIWrapper,
                skinID: settings.fullscreen.skinID,
                hostContext: hostContext.rawValue
            )
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
        FSDiagnostics.emit(
            "handleFullscreenAppear ENTER host=\(hostContext.rawValue) skin=\(settings.fullscreen.skinID) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        didHandleFullscreenAppear = true
        Log.info(
            "FullscreenPlayerView appeared context=\(hostContext.rawValue)",
            category: .webview
        )
        fullscreenPointerOcclusionMonitor.start { isOccluded in
            setPointerOverMiniPlayerOcclusion(isOccluded, reason: "mouse-location")
        }

        FSDiagnostics.emit(
            "handleFullscreenAppear syncCoverBlurHighlight BEGIN t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
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
        FSDiagnostics.emit(
            "handleFullscreenAppear syncFullscreenLedService CALL t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        syncFullscreenLedService()
        showPlaybackModeRetapTipIfNeeded()
        FullscreenLyricsLayerDiagnostics.logEvent(
            "appear",
            store: existingFullscreenStore,
            hostOpacity: fullscreenLyricsHostOpacity,
            viewportOpacity: fullscreenLyricsViewportOpacity,
            hostMounted: shouldKeepFullscreenLyricsHostMounted,
            controlsVisible: isFullscreenBottomControlsVisible,
            disableWrapper: LyricsDebugFlags.fullscreenDisableSwiftUIWrapper,
            skinID: settings.fullscreen.skinID,
            hostContext: hostContext.rawValue
        )
    }

    private func handleFullscreenDisappear() {
        let shouldReportFullscreenHidden =
            hostContext != .embeddedWindow || embeddedInitialThemeUnlocked
        Log.info(
            "FullscreenPlayerView disappeared context=\(hostContext.rawValue)",
            category: .webview
        )
        FullscreenLyricsLayerDiagnostics.logEvent(
            "disappear",
            store: existingFullscreenStore,
            hostOpacity: fullscreenLyricsHostOpacity,
            viewportOpacity: fullscreenLyricsViewportOpacity,
            hostMounted: shouldKeepFullscreenLyricsHostMounted,
            controlsVisible: isFullscreenBottomControlsVisible,
            disableWrapper: LyricsDebugFlags.fullscreenDisableSwiftUIWrapper,
            skinID: settings.fullscreen.skinID,
            hostContext: hostContext.rawValue
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
        pendingFullscreenLyricsAutoRestoreReload?.cancel()
        pendingFullscreenLyricsAutoRestoreReload = nil
        pendingFullscreenLyricsAutoRestoreReveal?.cancel()
        pendingFullscreenLyricsAutoRestoreReveal = nil
        pendingFullscreenLyricsHostDetach?.cancel()
        pendingFullscreenLyricsHostDetach = nil
        pendingFullscreenTrackRefresh?.cancel()
        pendingFullscreenTrackRefresh = nil
        pendingFullscreenThemeReapply?.cancel()
        pendingFullscreenThemeReapply = nil
        pendingEmbeddedStartupRetry?.cancel()
        pendingEmbeddedStartupRetry = nil
        localPolarityRecomputeTask?.cancel()
        localPolarityRecomputeTask = nil
        embeddedStartupRetryCount = 0
        deferredTrackUpdateDeadline = nil
        suppressFullscreenLyricsViewport = false
        fullscreenLyricsHostMounted = false
        autoHiddenFullscreenLyricsAfterEnding = false
        autoHiddenFullscreenLyricsAfterEndingCanRestore = false
        autoHideFullscreenLyricsTrackID = nil
        fullscreenLyricsLastEndTime = nil
        fullscreenLyricsLastVisualEndTime = nil
        fullscreenLyricsEndingAutoHideSuppressedTrackID = nil
        fullscreenLyricsRestoreInitialZeroTrackID = nil
        pendingFullscreenLyricsAutoRestoreTrackID = nil
        embeddedInitialThemeUnlocked = false
        isQuickAppearancePanelPresented = false
        isFullscreenBottomControlsAppearancePanelHovered = false
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

        // The lyrics layer hosts AMLLWebView, which itself owns a persistent
        // WKWebView via LyricsWebViewStore. The previous structure put a
        // skin-keyed `.id()` on the outer ZStack, which forced SwiftUI to tear
        // down the entire subtree on every skin switch — including the lyrics
        // layer. That triggered dismantleNSView/makeNSView storms, made two
        // Coordinator instances briefly contend for the same store's WKWebView
        // (ping-pong reparenting), and produced an addSubview/requestLayoutResync
        // feedback loop under embedded fullscreen.
        //
        // Fix: only the skin-specific visual layers (background, scaled artwork
        // container, bottom bar) carry the skin-keyed `.id()`. The lyrics layer
        // stays outside that scope so the AMLLWebView/WKWebView identity is
        // preserved across skin switches and is updated in place rather than
        // recreated.
        let skinIdentity = "fullscreen_\(settings.fullscreen.skinID)_\(skinRevision)"

        ZStack {
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
                fullscreenBackgroundLayer(selectedSkin: selectedSkin, scale: scale)
                    .id("\(skinIdentity)_bg")
                    .environment(\.fullscreenBackdropReadabilityState, backdropReadabilityState)
                    .onAppear { FSDiagnostics.emit("skinBg onAppear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
                    .onDisappear { FSDiagnostics.emit("skinBg onDisappear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }

                // Layer 1: AMLL lyrics at actual resolution.
                // NOT under the skin-keyed `.id()` — stays mounted across
                // skin switches so WKWebView is not reparented.
                fullscreenLyricsLayer(scale: scale, screenWidth: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                // Layer 2: Scaled container for artwork only
                fullscreenScaledContainer(selectedSkin: selectedSkin, scale: scale)
                    .frame(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight)
                    .scaleEffect(scale, anchor: .center)
                    .id("\(skinIdentity)_scaled")
                    .onAppear { FSDiagnostics.emit("skinScaled onAppear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
                    .onDisappear { FSDiagnostics.emit("skinScaled onDisappear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }

                // Layer 3: Bottom bar at actual resolution - on top
                fullscreenBottomBarLayer(
                    scale: scale,
                    screenWidth: proxy.size.width,
                    screenHeight: proxy.size.height
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .id("\(skinIdentity)_bottom")
                    .onAppear { FSDiagnostics.emit("skinBottom onAppear skin=\(settings.fullscreen.skinID) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))", category: .fullscreen) }
            } else {
                Color.clear
            }
        }
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
            let renderingArtworkData = currentRenderingArtworkData
            BKArtBackgroundView(
                controller: bkController,
                trackID: currentArtworkTrackID,
                artworkData: renderingArtworkData,
                isPlaying: currentDisplayContext.isPlaying,
                avoidanceRect: nil,
                resourceProfile: settings.fullscreen.skinID == "kmgccc.cassette"
                    ? .cassetteForeground
                    : .standard,
                dotRenderStyle: .solidCircles,
                motionProfile: .fullscreenBalanced,
                initialPalette: fullscreenArtBackgroundSeedPalette,
                holdPaletteWhenArtworkMissing: currentDisplayContext.isArtworkLoading
                    && renderingArtworkData == nil
            )
            .ignoresSafeArea()

            Color.black.opacity(artisticBackgroundDimmingIntensity)
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
            // Mirror the cover group left-bias (Classic / Rotating Cover /
            // Cassette / AppleStyle) so cover + visualizer + lyrics translate
            // together without altering their relative spacing. This branch
            // already excludes the cover-blur skin (which uses the legacy
            // layout above). `groupLeftBias` is subtracted here to match the
            // artwork area's `-groupLeftShift` offset.
            let groupLeftShift: CGFloat = isShowingRightPanel
                ? FullscreenCoverHorizontalOffset.groupLeftBias
                : 0
            baseLyricsLeadingX = hostLayout.lyricsLeadingX - groupLeftShift
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
            // Motion feel: subtle y-scale anchored at top creates "pushing down" feel during expansion.
            // Neutralized in the DEBUG no-wrapper A/B so no transform layer wraps the WebView.
            .scaleEffect(
                y: LyricsDebugFlags.fullscreenDisableSwiftUIWrapper
                    ? 1.0
                    : (isFullscreenBottomControlsVisible ? 0.97 : 1.0),
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
            glassStyle: fullscreenQueueGlassStyle,
            foregroundProfile: fullscreenQueueForegroundProfile,
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
        // DEBUG A/B (KMGCCC_AMLL_FULLSCREEN_NO_WRAPPER): render the WebView with
        // no SwiftUI compositing wrapper, mirroring the window flat host that does
        // not flood, to confirm the wrapper is the markAllLayersVolatile trigger.
        // Fade/scale/opacity are intentionally dropped in this diagnostic mode.
        if LyricsDebugFlags.fullscreenDisableSwiftUIWrapper {
            content()
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark)
        } else {
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

            // `.compositingGroup()` + `.blendMode(.normal)` is a visual no-op that
            // only forces the WKWebView subtree into an offscreen rasterization
            // group. Skip it so the WebView's layer stays directly in the host
            // layer tree, matching the window flat host (which does not flood).
            // Real blend modes (cover-blur / apple style) keep their rasterization.
            if blendMode == .normal {
                maskedContent
            } else if useCompositingGroup {
                maskedContent
                    .compositingGroup()
                    .blendMode(blendMode)
            } else {
                maskedContent
                    .blendMode(blendMode)
            }
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
            isLeftActionsExpanded: isLeftActionsExpanded ?? self.isLeftActionsExpanded,
            isVolumeExpanded: isVolumeExpanded ?? self.isVolumeExpanded,
            configuration: fullscreenBottomControlsGeometryConfiguration
        )
    }

    private func fullscreenMiniPlayerOcclusionRegion(
        scale: CGFloat,
        screenSize: CGSize
    ) -> FullscreenMiniPlayerOcclusionRegion {
        guard isFullscreenBottomControlsVisible else {
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

    private func animateFullscreenBottomControlsGeometry(_ updates: () -> Void) {
        FullscreenBottomControlsAnimationPolicy.animateGeometry(
            with: bottomControlsAnimation,
            updates
        )
    }

    private func setFullscreenBottomControlsVisible(_ visible: Bool) {
        guard isFullscreenBottomControlsVisible != visible else { return }
        animateFullscreenBottomControlsGeometry {
            isFullscreenBottomControlsVisible = visible
        }
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
                setFullscreenBottomControlsVisible(true)
            }
            return
        }

        handleFullscreenBottomControlsHover(isPointerInsideFullscreenBottomControls)
    }

    private func registerFullscreenBottomControlsInteraction() {
        setFullscreenBottomControlsVisible(true)
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

        if newState == .lyrics {
            fullscreenStore.resumeRendererIfNeeded(reason: "fullscreen lyrics panel shown")
        } else {
            fullscreenStore.suspendRendererPreservingSnapshot(
                reason: "fullscreen lyrics panel hidden: \(String(describing: newState))"
            )
        }

        if newState == .lyrics, oldState != .lyrics {
            let trackID = currentDisplayContext.trackID
            let canRevealExistingLyrics =
                LyricsSurfaceManager.shared.currentMode == .fullscreen
                && LyricsSurfaceManager.shared.switchState == .idle
                && LyricsSurfaceManager.shared.existingStore(for: .fullscreen)?.isReady == true
            let isEndingAutoRestore = trackID != nil && fullscreenLyricsRestoreInitialZeroTrackID == trackID
            if isEndingAutoRestore {
                if pendingFullscreenLyricsAutoRestoreTrackID == trackID {
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
            setFullscreenBottomControlsVisible(true)
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

            setFullscreenBottomControlsVisible(false)
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
        animateFullscreenBottomControlsGeometry {
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
        animateFullscreenBottomControlsGeometry {
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
        let baseScale = scale
        let buttonSize = fullscreenControlButtonSize
        let windowWidth = Self.baseCanvasWidth
        let geometry = fullscreenBottomControlsGeometry()
        
        // Apply scale to all positions for actual resolution rendering
        let scaledButtonSize = buttonSize * baseScale
        let scaledLeadingControlsOriginX = geometry.leadingControlsRect.minX * baseScale
        let scaledLeadingControlsWidth = geometry.leadingControlsRect.width * baseScale
        let scaledMiniPlayerOriginX = geometry.miniPlayerRect.minX * baseScale
        let scaledMiniPlayerWidth = geometry.miniPlayerRect.width * baseScale
        let scaledVolumeOriginX = geometry.volumeRect.minX * baseScale
        let scaledVolumeWidth = geometry.volumeRect.width * baseScale
        let scaledWindowWidth = windowWidth * baseScale
        // Canvas-bottom-relative bottom padding: on displays where the canvas has vertical
        // margins (scale = scaleX, e.g. portrait-aspect MacBooks), anchor the controls bar
        // to the canvas bottom rather than the screen bottom so the visual spacing is stable.
        let canvasBottomMargin = max(0, (screenHeight - Self.baseCanvasHeight * baseScale) / 2)
        let scaledBottomPadding = fullscreenControlsBottomPadding * baseScale + canvasBottomMargin
        let scaledGroupWidth = geometry.fullGroupRect.width * baseScale
        let hotZoneWidth = min(scaledWindowWidth, scaledGroupWidth + 120 * baseScale)
        let hotZoneHeight = scaledButtonSize + 34 * baseScale
        let controlsRowHeight = max(scaledButtonSize, hotZoneHeight)
        let controlsCenterY = controlsRowHeight * 0.5
        let adjustedBottomPadding = max(
            0,
            scaledBottomPadding - (controlsRowHeight - scaledButtonSize) * 0.5
        )
        let quickPanelFrame = quickAppearancePanelFrame(
            scale: baseScale,
            screenSize: CGSize(width: screenWidth, height: screenHeight),
            leadingControlsOriginX: geometry.leadingControlsRect.minX
        )
        let quickPanelWidth = quickPanelFrame.width
        let quickPanelHeight = quickPanelFrame.height
        let quickPanelCenterX = quickPanelFrame.midX
        let quickPanelCenterY = quickPanelFrame.midY
        
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

                GlassEffectContainer(spacing: 0) {
                    ZStack(alignment: .leading) {
                        leadingControlsPill(
                            size: scaledButtonSize,
                            materialStyle: fullscreenControlsGlassStyle.materialStyle
                        )
                        .glassEffectID(
                            BottomControlGlassID.leading,
                            in: fullscreenBottomControlsGlassNamespace
                        )
                        .frame(width: scaledLeadingControlsWidth, height: scaledButtonSize)
                        .position(
                            x: scaledLeadingControlsOriginX + scaledLeadingControlsWidth / 2,
                            y: controlsCenterY
                        )

                    FullscreenMiniPlayerView(
                        scale: scale,
                        isSpectrumActive: isFullscreenBottomControlsVisible,
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
                        },
                        foregroundProfile: fullscreenMiniPlayerForegroundProfile
                    )
                    .glassEffectID(
                        BottomControlGlassID.miniPlayer,
                        in: fullscreenBottomControlsGlassNamespace
                    )
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
                        forceDarkForegroundProfile: false,
                        usesInternalHoverExpansion: false,
                        foregroundProfile: fullscreenMiniPlayerForegroundProfile
                    )
                    .glassEffectID(
                        BottomControlGlassID.volume,
                        in: fullscreenBottomControlsGlassNamespace
                    )
                    .frame(width: scaledVolumeWidth, height: scaledButtonSize)
                    .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)
                    .position(
                        x: scaledVolumeOriginX + scaledVolumeWidth / 2,
                        y: controlsCenterY
                    )
                    }
                }
                .opacity(isFullscreenBottomControlsVisible ? 1 : 0)
                .allowsHitTesting(isFullscreenBottomControlsVisible)
                .accessibilityHidden(!isFullscreenBottomControlsVisible)
                // Force the Liquid Glass material polarity at the container scope.
                // The material resolves its tint here, not from the per-pill
                // `.environment(\.colorScheme, …)` overrides inside the closure,
                // so the override must sit on the container to take effect. This
                // is what makes Cover Blur / Apple Style glass track the
                // complementary polarity instead of the app appearance.
                .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)
            }
            .frame(width: scaledWindowWidth, height: controlsRowHeight, alignment: .leading)
            .padding(.bottom, adjustedBottomPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1)

            if isQuickAppearancePanelPresented {
                FullscreenQuickAppearancePanel(
                    scale: scale,
                    foregroundProfile: fullscreenQuickPanelForegroundProfile,
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
                // No `.scale` here: the panel hosts AppKit-backed controls
                // (Slider/Picker), and a fractional scaleEffect during the
                // insertion/removal animation resizes their platform-view
                // hosts every frame, spamming "min <= max" length warnings
                // under the embedded-window hosting hierarchy. Offset keeps
                // the motion without touching platform-view sizes.
                .transition(
                    .opacity.combined(with: .offset(x: -8, y: 8))
                )
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(quickAppearancePanelAnimation, value: isQuickAppearancePanelPresented)
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

        let artworkScale = isCoverBlurFullscreenSkin ? 1.0 : settings.fullscreenArtworkScale

        // Shared group left-bias for cover + visualizer + overlay. The lyrics
        // column (`fullscreenLyricsLayer`) subtracts the same value so the
        // whole group translates together without changing relative spacing.
        // Cover-blur is excluded (its artwork is `EmptyView`, cover lives in
        // the background). Only active when the lyrics column is visible.
        let groupLeftShift: CGFloat =
            (!isCoverBlurFullscreenSkin && context.lyricsVisible)
                ? FullscreenCoverHorizontalOffset.groupLeftBias
                : 0

        ZStack {
            // Main artwork - using user configurable scale
            selectedSkin.makeArtwork(context: context)
                .scaleEffect(artworkScale)

            // Overlay if any
            if let overlay = selectedSkin.makeOverlay(context: context) {
                overlay
                    .scaleEffect(artworkScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .offset(x: -groupLeftShift)
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

            // DEBUG A/B (KMGCCC_AMLL_FULLSCREEN_NO_WRAPPER): drop the
            // .mask/.opacity/.offset wrapper to mirror the window flat host.
            if LyricsDebugFlags.fullscreenDisableSwiftUIWrapper {
                AMLLWebView(store: fullscreenStore, forcedAppearanceMode: .dark)
                    .frame(
                        width: max(0, proxy.size.width - horizontalInset * 2),
                        height: expandedHeight
                    )
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
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
    }

    // MARK: - Leading Controls Pill

    private func leadingControlsPill(
        size: CGFloat,
        materialStyle: LiquidGlassPillMaterialStyle
    ) -> some View {
        // Scale factor relative to base button size (60)
        let scaleFactor = size / fullscreenControlButtonSize
        let controlColorScheme = fullscreenControlsGlassStyle.colorScheme
        let foregroundProfile = fullscreenMiniPlayerForegroundProfile

        return HStack(spacing: 0) {
            leadingControlButton(size: size, help: "fullscreen.exit") {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
                    .compositingGroup()
                    .blendMode(fullscreenMiniPlayerIconBlendMode)
                    .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
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
        .animation(nil, value: foregroundProfile)
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
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
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
                .isolatesFullscreenBottomControlRenderingFromGeometryAnimation()
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
        playbackCoordinator.presentation.localPlaybackOrderMode ?? settings.playbackOrderMode
    }

    private var lyricsLayoutAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        // Non-linear, spring-like layout movement for artwork/lyrics transitions.
        return .spring(response: 0.62, dampingFraction: 0.84, blendDuration: 0.18)
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
            skinID: settings.fullscreen.skinID,
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
        guard isCoverBlurFullscreenSkin else { return nil }
        return resolvedLocalPolarity
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
            isCoverBlurSkin: isCoverBlurFullscreenSkin,
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
        guard isCoverBlurFullscreenSkin else {
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
        guard isCoverBlurFullscreenSkin else {
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
        let visibleBottomReserve: CGFloat = isFullscreenBottomControlsVisible
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
            skinID: settings.fullscreen.skinID,
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
            skinID: settings.fullscreen.skinID,
            colorScheme: colorScheme
        )
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
            settings.amllDiscreteWordHighlightEnabled ? "wordDiscrete" : "wordSmooth",
            "amllQuality:\(settings.amllLyricsRenderQuality.rawValue)",
            playbackCoordinator.presentation.source.rawValue,
            hostContext.rawValue,
            overlay.signature,
            String(format: "%.0f", trackOffsetMs),
        ].joined(separator: "|")
    }

    private func setupSeekCallback() {
        fullscreenStore.onUserSeek = { seconds in
            playbackCoordinator.seek(to: seconds)
        }
    }

    private func startFullscreenLyricsSurface(reason: String) {
        // Report visibility to manager first so a newly materialized surface can
        // replay the latest snapshot. The reload path still refreshes the
        // fullscreen payload/theme, but must not force a second AMLL lyric
        // entrance after the manager has replayed the snapshot.
        LyricsSurfaceManager.shared.reportFullscreenVisible(true)
        reloadLyricsSurface(reason: reason, forceLyricsReload: false)
    }

    private func revealFullscreenExistingLyrics(reason: String) {
        let targetStore = fullscreenStore
        let currentTime = fullscreenLyricsRevealCurrentTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            targetStore.revealExistingLyrics(reason: reason, currentTime: currentTime)
        }
    }

    private func scheduleFullscreenLyricsAutoRestorePreload(trackID: UUID?) {
        guard let trackID else { return }
        pendingFullscreenLyricsAutoRestoreReload?.cancel()
        pendingFullscreenLyricsAutoRestoreReveal?.cancel()
        pendingFullscreenLyricsHostDetach?.cancel()
        pendingFullscreenLyricsHostDetach = nil
        fullscreenLyricsHostMounted = true
        suppressFullscreenLyricsViewport = true

        let delay: TimeInterval = reduceMotion ? 0.18 : 0.28
        let workItem = DispatchWorkItem {
            guard currentDisplayContext.trackID == trackID else {
                pendingFullscreenLyricsAutoRestoreReload = nil
                return
            }
            guard rightPanelDisplayState == .hidden else {
                pendingFullscreenLyricsAutoRestoreReload = nil
                return
            }

            reloadLyricsSurface(
                reason: fullscreenLyricsAutoRestoreReason,
                forceLyricsReload: true,
                forcedCurrentTime: 0
            )

            let targetStore = fullscreenStore
            targetStore.setCurrentTime(0, force: true)
            targetStore.revealExistingLyrics(
                reason: fullscreenLyricsAutoRestoreReason,
                currentTime: 0
            )

            let showWorkItem = DispatchWorkItem {
                guard currentDisplayContext.trackID == trackID else {
                    pendingFullscreenLyricsAutoRestoreReload = nil
                    return
                }
                guard rightPanelDisplayState == .hidden else {
                    pendingFullscreenLyricsAutoRestoreReload = nil
                    return
                }
                pendingFullscreenLyricsAutoRestoreTrackID = nil
                setRightPanelDisplayState(.lyrics)
                targetStore.setCurrentTime(0, force: true)
                targetStore.revealExistingLyrics(
                    reason: fullscreenLyricsAutoRestoreReason,
                    currentTime: 0
                )

                let revealWorkItem = DispatchWorkItem {
                    guard currentDisplayContext.trackID == trackID else {
                        pendingFullscreenLyricsAutoRestoreReveal = nil
                        return
                    }
                    guard rightPanelDisplayState == .lyrics else {
                        pendingFullscreenLyricsAutoRestoreReveal = nil
                        return
                    }
                    targetStore.setCurrentTime(0, force: true)
                    targetStore.revealExistingLyrics(
                        reason: fullscreenLyricsAutoRestoreReason,
                        currentTime: 0
                    )
                    let revealAnimation: Animation = reduceMotion
                        ? .easeInOut(duration: 0.08)
                        : .easeInOut(duration: 0.24)
                    withAnimation(revealAnimation) {
                        suppressFullscreenLyricsViewport = false
                    }
                    scheduleFullscreenLyricsAutoRestoreMarkerClear(trackID: trackID)
                    pendingFullscreenLyricsAutoRestoreReveal = nil
                }

                pendingFullscreenLyricsAutoRestoreReveal = revealWorkItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + (reduceMotion ? 0.24 : 0.44),
                    execute: revealWorkItem
                )
            }

            pendingFullscreenLyricsAutoRestoreReload = showWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (reduceMotion ? 0.42 : 0.78),
                execute: showWorkItem
            )
        }

        pendingFullscreenLyricsAutoRestoreReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleFullscreenLyricsAutoRestoreMarkerClear(trackID: UUID?) {
        guard let trackID else { return }
        let clearWorkItem = DispatchWorkItem {
            guard currentDisplayContext.trackID == trackID else { return }
            if fullscreenLyricsRestoreInitialZeroTrackID == trackID {
                fullscreenLyricsRestoreInitialZeroTrackID = nil
            }
            if pendingFullscreenLyricsAutoRestoreTrackID == trackID {
                pendingFullscreenLyricsAutoRestoreTrackID = nil
            }
            pendingFullscreenLyricsAutoRestoreReload = nil
        }
        pendingFullscreenLyricsAutoRestoreReload = clearWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: clearWorkItem)
    }

    private func fullscreenLyricsRevealCurrentTime() -> TimeInterval {
        if let trackID = currentDisplayContext.trackID,
           fullscreenLyricsRestoreInitialZeroTrackID == trackID
        {
            return 0
        }
        return playbackCoordinator.presentation.lyricsCurrentTime
    }

    private func fullscreenLyricsSurfaceTime(
        _ currentTime: TimeInterval,
        trackID: UUID?
    ) -> TimeInterval {
        guard currentTime.isFinite else { return 0 }
        guard let trackID,
              fullscreenLyricsRestoreInitialZeroTrackID == trackID
        else { return currentTime }
        return 0
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
        autoHiddenFullscreenLyricsForEmptyContent = false
        if !isAutomatic {
            autoHiddenFullscreenLyricsAfterEndingCanRestore = false
            fullscreenLyricsEndingAutoHideSuppressedTrackID = currentDisplayContext.trackID
            fullscreenLyricsRestoreInitialZeroTrackID = nil
            pendingFullscreenLyricsAutoRestoreTrackID = nil
            pendingFullscreenLyricsAutoRestoreReload?.cancel()
            pendingFullscreenLyricsAutoRestoreReload = nil
            pendingFullscreenLyricsAutoRestoreReveal?.cancel()
            pendingFullscreenLyricsAutoRestoreReveal = nil
            suppressFullscreenLyricsViewport = false
        }

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
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: false,
                preserveRestoreEligibility: shouldPreserveFullscreenLyricsEndingAutoHideRestore()
            )
            return
        }

        if payload.hasDisplayableLyrics {
            if autoHiddenFullscreenLyricsForEmptyContent && rightPanelDisplayState == .hidden {
                handleLyricsButtonTap(isAutomatic: true)
            } else {
                autoHiddenFullscreenLyricsForEmptyContent = false
            }
            return
        }

        guard rightPanelDisplayState == .lyrics else { return }
        handleLyricsButtonTap(isAutomatic: true)
        autoHiddenFullscreenLyricsForEmptyContent = true
    }

    private func syncFullscreenLyricsAutoHideTiming(with payload: FullscreenPlaybackPayload) {
        let trackChanged = autoHideFullscreenLyricsTrackID != payload.trackID
        if trackChanged {
            if payload.trackID == nil, shouldPreserveFullscreenLyricsEndingAutoHideRestore() {
                fullscreenLyricsLastEndTime = nil
                fullscreenLyricsLastVisualEndTime = nil
                return
            }
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: true,
                nextTrackHasDisplayableLyrics: payload.hasDisplayableLyrics,
                nextTrackID: payload.trackID
            )
            autoHideFullscreenLyricsTrackID = payload.trackID
        }

        guard payload.hasDisplayableLyrics, let ttml = payload.ttml else {
            fullscreenLyricsLastEndTime = nil
            fullscreenLyricsLastVisualEndTime = nil
            return
        }

        let rawLastEndTime = FullscreenTTMLTimingExtractor.lastMainLineEndTime(in: ttml)
        fullscreenLyricsLastEndTime = rawLastEndTime
        fullscreenLyricsLastVisualEndTime = rawLastEndTime.map {
            max(0, $0 + fullscreenLyricsVisualOffsetSeconds())
        }

        evaluateFullscreenLyricsAutoHide(
            currentTime: payload.currentTime,
            duration: playbackCoordinator.presentation.duration,
            isPlaying: payload.isPlaying
        )
    }

    private func evaluateFullscreenLyricsAutoHide(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) {
        guard isPlaying else { return }
        guard rightPanelDisplayState == .lyrics else { return }
        guard !autoHiddenFullscreenLyricsAfterEnding else { return }
        guard fullscreenLyricsEndingAutoHideSuppressedTrackID != currentDisplayContext.trackID else {
            return
        }
        guard let lastEnd = fullscreenLyricsLastEndTime, lastEnd.isFinite else { return }
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return }
        let trailingGap = duration - lastEnd
        guard trailingGap >= fullscreenLyricsAutoHideTrailingGap else { return }
        let visualLastEnd = fullscreenLyricsLastVisualEndTime ?? lastEnd
        let hideTime = visualLastEnd + fullscreenLyricsAutoHideDelayAfterFinalLine
        guard currentTime >= hideTime else { return }

        autoHiddenFullscreenLyricsAfterEnding = true
        autoHiddenFullscreenLyricsAfterEndingCanRestore = true
        Log.debug(
            "[FullscreenLyricsAutoHide] hiding lyrics after final line gap=\(String(format: "%.2f", trailingGap))s threshold=\(String(format: "%.2f", fullscreenLyricsAutoHideTrailingGap))s visualEnd=\(String(format: "%.2f", visualLastEnd)) delay=\(String(format: "%.2f", fullscreenLyricsAutoHideDelayAfterFinalLine))s track=\(autoHideFullscreenLyricsTrackID?.uuidString.prefix(8) ?? "nil")",
            category: .webview
        )
        handleLyricsButtonTap(isAutomatic: true)
    }

    private func resetFullscreenLyricsEndingAutoHide(
        restoreIfNeeded: Bool,
        nextTrackHasDisplayableLyrics: Bool = false,
        nextTrackID: UUID? = nil,
        preserveRestoreEligibility: Bool = false
    ) {
        var scheduledAutoRestore = false
        if restoreIfNeeded,
           autoHiddenFullscreenLyricsAfterEnding,
           autoHiddenFullscreenLyricsAfterEndingCanRestore,
           rightPanelDisplayState == .hidden,
           currentDisplayContext.hasTrack
        {
            if nextTrackHasDisplayableLyrics {
                fullscreenLyricsRestoreInitialZeroTrackID = nextTrackID
                pendingFullscreenLyricsAutoRestoreTrackID = nextTrackID
                scheduledAutoRestore = true
                scheduleFullscreenLyricsAutoRestorePreload(trackID: nextTrackID)
            } else {
                autoHiddenFullscreenLyricsForEmptyContent = true
                fullscreenLyricsRestoreInitialZeroTrackID = nil
                pendingFullscreenLyricsAutoRestoreTrackID = nil
                suppressFullscreenLyricsViewport = false
            }
        }
        if preserveRestoreEligibility {
            fullscreenLyricsLastEndTime = nil
            fullscreenLyricsLastVisualEndTime = nil
            return
        }
        autoHiddenFullscreenLyricsAfterEnding = false
        autoHiddenFullscreenLyricsAfterEndingCanRestore = false
        fullscreenLyricsLastEndTime = nil
        fullscreenLyricsLastVisualEndTime = nil
        fullscreenLyricsEndingAutoHideSuppressedTrackID = nil
        if !scheduledAutoRestore {
            fullscreenLyricsRestoreInitialZeroTrackID = nil
            pendingFullscreenLyricsAutoRestoreTrackID = nil
            suppressFullscreenLyricsViewport = false
        }
    }

    private func shouldStartFullscreenLyricsAtZero(for payload: FullscreenPlaybackPayload) -> Bool {
        guard payload.hasDisplayableLyrics,
              let trackID = payload.trackID,
              fullscreenLyricsRestoreInitialZeroTrackID == trackID
        else { return false }
        return true
    }

    private func shouldDeferFullscreenLyricsAutoRestoreApply(
        for payload: FullscreenPlaybackPayload,
        reason: String
    ) -> Bool {
        guard payload.hasDisplayableLyrics,
              let trackID = payload.trackID,
              pendingFullscreenLyricsAutoRestoreTrackID == trackID
        else { return false }
        return reason != fullscreenLyricsAutoRestoreReason
    }

    private func shouldPreserveFullscreenLyricsEndingAutoHideRestore() -> Bool {
        autoHiddenFullscreenLyricsAfterEnding
            && autoHiddenFullscreenLyricsAfterEndingCanRestore
            && rightPanelDisplayState == .hidden
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
        let needsSystemFullscreenBlendPreflight = newState == .lyrics
            && playbackCoordinator.presentation.hasTrack
            && hostContext == .systemFullscreenSpace
            && isCoverBlurFullscreenSkin
            && !suppressFullscreenLyricsViewport

        if newState == .lyrics, playbackCoordinator.presentation.hasTrack {
            if needsSystemFullscreenBlendPreflight {
                // Materialize the WKWebView under opacity zero for two display
                // frames. True system fullscreen can otherwise present the
                // newly reattached layer once with normal compositing before
                // SwiftUI installs plusLighter / plusDarker.
                pendingFullscreenLyricsReveal?.cancel()
                pendingFullscreenLyricsReveal = nil
                suppressFullscreenLyricsViewport = true
            }
            // A detached/suspended fullscreen WebView can otherwise remount
            // for one frame with the default AMLL palette and normal blend,
            // then switch to the cover-aware profile after reload. Publish the
            // final config and blend profile before making the host visible.
            if usesCoverBlurLyricsRenderingPath {
                applyFullscreenLyricsTheme(
                    force: true,
                    reason: "fullscreen lyrics pre-show"
                )
            }
            pendingFullscreenLyricsHostDetach?.cancel()
            pendingFullscreenLyricsHostDetach = nil
            fullscreenLyricsHostMounted = true
        }

        withAnimation(lyricsLayoutAnimation) {
            rightPanelDisplayState = newState
        }

        if needsSystemFullscreenBlendPreflight {
            scheduleSystemFullscreenLyricsBlendReveal(
                after: reduceMotion ? 0 : 2.0 / 60.0
            )
        }
    }

    private func applyPlaybackMode(_ mode: PlaybackOrderMode) {
        playbackCoordinator.setPlaybackOrderMode(mode)
    }

    private func showPlaybackModeRetapTipIfNeeded() {
        guard showPlaybackModeRetapTip == false else { return }
        guard AppVersionGate.shared.shouldShowFeatureTip(
            featureKey: FeatureTips.playbackModeRetapKey,
            introducedBuild: FeatureTips.playbackModeRetapIntroducedBuild,
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
        let trackID = playerVM.currentTrack?.id
        let rawLyricsTime = playerVM.lyricsCurrentTime
        let lyricsTime = fullscreenLyricsSurfaceTime(rawLyricsTime, trackID: trackID)
        LyricsSurfaceManager.shared.updatePlaybackTime(lyricsTime)
        evaluateFullscreenLyricsAutoHide(
            currentTime: rawLyricsTime,
            duration: playerVM.duration,
            isPlaying: playerVM.isPlaying
        )
        guard allowsDirectEmbeddedSurfaceUpdates else { return }
        fullscreenStore.setCurrentTime(lyricsTime)
        if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
            coverBlurHighlightStore.setCurrentTime(lyricsTime)
        }

        if oldTime > 1.0, newTime < 0.2 {
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: false,
                preserveRestoreEligibility: shouldPreserveFullscreenLyricsEndingAutoHideRestore()
            )
            reloadLyricsSurface(reason: "fullscreen playback restarted", forceLyricsReload: true)
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }

        cancelPendingFullscreenLyricsThemeWork()
        coverBlurLyricsTheme = nil

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
        guard allowsDirectEmbeddedSurfaceUpdates else { return }
        fullscreenStore.setCurrentTime(lyricsTime)
        if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
            coverBlurHighlightStore.setCurrentTime(lyricsTime)
        }

        if oldTime > 1.0, newTime < 0.2 {
            resetFullscreenLyricsEndingAutoHide(
                restoreIfNeeded: false,
                preserveRestoreEligibility: shouldPreserveFullscreenLyricsEndingAutoHideRestore()
            )
            reloadLyricsSurface(reason: "fullscreen external playback restarted", forceLyricsReload: true)
        }
    }

    private func handlePresentationLyricsIdentityChange(_ oldId: String?, _ newId: String?) {
        guard playbackCoordinator.presentation.source.isExternal else { return }
        guard oldId != newId else { return }
        cancelPendingFullscreenLyricsThemeWork()
        coverBlurLyricsTheme = nil
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

    private func reloadLyricsSurface(
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false,
        preferredLocalTrack: Track? = nil,
        forceLocalLyricsReload: Bool = false,
        forcedCurrentTime: Double? = nil
    ) {
        FSDiagnostics.emit(
            "reloadLyricsSurface ENTER reason=\(reason) forceLyricsReload=\(forceLyricsReload) external=\(playbackCoordinator.presentation.source.isExternal) t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .fullscreen
        )
        syncCoverBlurHighlightActivation()

        var playbackPayload = makeFullscreenPlaybackPayload(
            preferredLocalTrack: preferredLocalTrack,
            forceLocalLyricsReload: forceLyricsReload || forceLocalLyricsReload
        )
        let reloadLogMessage = "[FullscreenLyricsReload] reload reason=\(reason), forceLyricsReload=\(forceLyricsReload), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil"), ttmlLen=\(playbackPayload.ttml?.count ?? 0), ttmlHash=\(playbackPayload.ttml?.hashValue ?? 0), time=\(String(format: "%.3f", playbackPayload.currentTime)), playing=\(playbackPayload.isPlaying), host=\(hostContext.rawValue)"
        if LogConfig.webviewVerbose {
            Log.info(reloadLogMessage, category: .webview)
        } else {
            Log.debug(reloadLogMessage, category: .webview)
        }
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
                category: .webview
            )
            scheduleFullscreenLyricsAutoRestorePreload(trackID: playbackPayload.trackID)
            return
        }

        if hostContext == .embeddedWindow && !embeddedInitialThemeUnlocked {
            Log.info(
                "[FullscreenLyricsReload] skipped embedded startup gate reason=\(reason), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil")",
                category: .webview
            )
            return
        }

        // Apply to fullscreen store directly
        let store = fullscreenStore
        let reloadSignature = FullscreenLyricsReloadSignature(
            payload: playbackPayload,
            hostContext: hostContext,
            coverBlurHighlightOverlay: shouldRenderCoverBlurHighlightOverlay
        )
        let now = ProcessInfo.processInfo.systemUptime
        if !forceWebReload,
           !reason.lowercased().contains("theme"),
           reloadSignature == lastFullscreenLyricsReloadSignature,
           now - lastFullscreenLyricsReloadAt < duplicateLyricsReloadCoalesceInterval
        {
            Log.debug(
                "[FullscreenLyricsReload] coalesced duplicate payload reason=\(reason), trackID=\(playbackPayload.trackID?.uuidString.prefix(8) ?? "nil"), ttmlLen=\(playbackPayload.ttml?.count ?? 0), host=\(hostContext.rawValue)",
                category: .webview
            )
            store.setCurrentTime(playbackPayload.currentTime)
            store.setPlaying(playbackPayload.isPlaying)
            if shouldRenderCoverBlurHighlightOverlay {
                let highlightStore = coverBlurHighlightStore
                highlightStore.setCurrentTime(playbackPayload.currentTime)
                highlightStore.setPlaying(playbackPayload.isPlaying)
            }
            return
        }
        lastFullscreenLyricsReloadSignature = reloadSignature
        lastFullscreenLyricsReloadAt = now

        if forceWebReload {
            store.forceReload(recreateWebView: recreateWebViewOnForceReload)
        }
        setupSeekCallback()

        if let palette = ThemeStore.shared.palette {
            store.applyTheme(palette)
        }

        // AMLL's setLyricLines entrance uses the spring/font/alignment config
        // that is active at call time. Apply the final fullscreen config first
        // so a newly materialized surface does not animate once with defaults
        // and then jump when setConfig arrives.
        applyFullscreenLyricsTheme()

        store.applyTrack(
            trackID: playbackPayload.trackID,
            ttml: playbackPayload.ttml,
            currentTime: playbackPayload.currentTime,
            isPlaying: playbackPayload.isPlaying,
            forceLyricsReload: forceLyricsReload || forceWebReload
        )
        setupSeekCallback()

        syncCoverBlurHighlightSurface(
            playbackPayload: playbackPayload,
            forceWebReload: forceWebReload,
            recreateWebViewOnForceReload: recreateWebViewOnForceReload
        )
        if !pendingFullscreenLyricsBackgroundCapture {
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
        let coverBlurHighlightOverlay: Bool

        init(
            payload: FullscreenPlaybackPayload,
            hostContext: HostContext,
            coverBlurHighlightOverlay: Bool
        ) {
            self.trackID = payload.trackID
            self.ttmlLength = payload.ttml?.count ?? 0
            self.ttmlHash = payload.ttml?.hashValue ?? 0
            self.hostContext = hostContext
            self.coverBlurHighlightOverlay = coverBlurHighlightOverlay
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
            isPlaying: payload.isPlaying,
            forceLyricsReload: forceWebReload
        )
    }


    private var fullscreenLyricsHostOpacity: Double {
        guard isShowingLyricsPanel, playbackCoordinator.presentation.hasTrack else { return 0 }
        guard coverBlurLyricsThemeMatchesCurrentArtwork else { return 0 }
        return 1
    }

    private var coverBlurLyricsThemeMatchesCurrentArtwork: Bool {
        guard isCoverBlurFullscreenSkin else { return true }
        // A transient nil artwork identity is not a valid ready state while an
        // artwork-backed theme is loading. This is common while the true
        // fullscreen host is being attached and was the hole that allowed one
        // visible frame with BlendMode.normal. A genuine no-artwork track may
        // still use the normal fallback lyrics path.
        let display = currentDisplayContext
        let expectsArtworkTheme = display.artworkData != nil
            || display.artworkIdentity != nil
            || display.isArtworkLoading
        guard expectsArtworkTheme else { return true }
        guard let currentArtworkTrackID else { return false }
        return coverBlurLyricsTheme?.trackID == currentArtworkTrackID
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
        guard coverBlurLyricsThemeMatchesCurrentArtwork else { return 0 }
        return suppressFullscreenLyricsViewport ? 0 : 1
    }

    private func scheduleSystemFullscreenLyricsBlendReveal(after delay: TimeInterval) {
        pendingFullscreenLyricsReveal?.cancel()

        let workItem = DispatchWorkItem {
            pendingFullscreenLyricsReveal = nil
            guard isShowingLyricsPanel else {
                suppressFullscreenLyricsViewport = false
                return
            }
            let revealAnimation: Animation = reduceMotion
                ? .linear(duration: 0)
                : .easeOut(duration: 0.12)
            withAnimation(revealAnimation) {
                suppressFullscreenLyricsViewport = false
            }
        }
        pendingFullscreenLyricsReveal = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
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
        let typography = settings.effectiveFullscreenLyricsTypography
        let mainFontFamily = cssFontFamily([
            typography.mainFontNameEn,
            typography.mainFontNameZh,
        ])
        let translationFontFamily = cssFontFamily([
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
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": scaledTranslationFontSize,
            "translationFontWeight": max(
                100,
                min(900, typography.translationFontWeight)
            ),
            "renderScale": surfaceRole.renderScale,
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
        guard isEmbeddedFullscreenPresentationActive else {
            if EmbeddedFullscreenTrace.enabled {
                Log.info(
                    "[EFS t=\(EmbeddedFullscreenTrace.stamp())] FullscreenPlayerView.ignoreViewport reason=\(reason) mode=\(FullscreenWindowManager.shared.presentationMode)",
                    category: .fullscreen
                )
            }
            return
        }
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
            pendingEmbeddedStartupRetry?.cancel()
            pendingEmbeddedStartupRetry = nil
            embeddedStartupRetryCount = 0
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
        guard isEmbeddedFullscreenPresentationActive else { return nil }

        let candidateWindow = NSApp.keyWindow ?? NSApp.mainWindow
        guard let window = candidateWindow else { return nil }
        let contentSize = window.contentLayoutRect.size
        guard contentSize.width > 1, contentSize.height > 1 else { return nil }
        return contentSize
    }

    private func beginEmbeddedFullscreenStartupIfNeeded(reason: String) {
        guard isEmbeddedFullscreenPresentationActive else { return }
        guard !embeddedInitialThemeUnlocked else { return }
        guard isValidEmbeddedFullscreenGeometry(fullscreenViewportSize, scale: currentFullscreenScale) else {
            return
        }

        pendingEmbeddedStartupRetry?.cancel()
        pendingEmbeddedStartupRetry = nil
        embeddedStartupRetryCount = 0
        syncFullscreenLyricsHostMount()

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

    private func scheduleEmbeddedFullscreenStartupRetry(reason: String) {
        guard isEmbeddedFullscreenPresentationActive else { return }
        guard embeddedStartupRetryCount < 20 else { return }
        pendingEmbeddedStartupRetry?.cancel()
        embeddedStartupRetryCount += 1

        let workItem = DispatchWorkItem {
            pendingEmbeddedStartupRetry = nil
            guard isEmbeddedFullscreenPresentationActive else { return }
            if let fallbackSize = currentEmbeddedHostWindowContentSize() {
                handleEmbeddedFullscreenViewportChange(fallbackSize, reason: "\(reason)-retry")
            } else {
                beginEmbeddedFullscreenStartupIfNeeded(reason: "\(reason)-retry")
            }
        }
        pendingEmbeddedStartupRetry = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private var isEmbeddedFullscreenPresentationActive: Bool {
        hostContext == .embeddedWindow
            && FullscreenWindowManager.shared.presentationMode == .embeddedInWindow
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
                artworkImage: artworkSnapshot?.fullImage,
                displayedArtworkID: artworkSnapshot?.trackID
            )
            : nil

        let playback = SkinContext.PlaybackState(
            isPlaying: display.isPlaying,
            currentTime: display.currentTime,
            duration: display.duration,
            progress: display.duration > 0 ? display.currentTime / display.duration : 0
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
            artworkAccentColor: artworkSnapshot?.accentColor.map {
                ColorRenderingAdapter.makeSwiftUIColor($0)
            },
            artworkPalette: artworkSnapshot?.palette ?? [],
            artworkRichPalette: artworkSnapshot?.richPalette ?? [],
            artworkAverageColor: artworkSnapshot?.averageColor,
            artBackgroundIsUltraDark: colorScheme == .dark
                && settings.fullscreenArtBackgroundEnabled
                && bkController.isUltraDarkActive,
            spectrumArtworkColors: spectrumArtworkColors,
            spectrumUsesDarkForeground: spectrumUsesDarkForeground,
            cassetteTint: themeStore.semanticPalette.cassetteTint,
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
            // High-frequency LED/audio frames are consumed by the visualizer host
            // itself. Keeping SkinContext stable prevents 30Hz audio metrics from
            // invalidating the whole fullscreen SwiftUI tree.
            audio: .zero,
            led: LEDMeterMetrics.zero(count: AppSettings.shared.ledCount),
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

    private func makeFullscreenLyricSemanticPalette(forTrackID trackID: UUID?) -> FullscreenLyricPalette {
        SemanticPaletteFactory.fullscreenLyricSemanticPalette(
            analysis: resolveLyricsAnalysis(forTrackID: trackID),
            scheme: colorScheme,
            highlightBaseColor: resolveFullscreenLyricsBaseColor(forTrackID: trackID),
            inactiveBaseColor: resolveFullscreenLyricsInactiveBaseColor(forTrackID: trackID),
            isUltraDark: colorScheme == .dark && lockedFullscreenLyricsUltraDark,
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

        if themeStoreArtworkThemePending(forTrackID: trackID) {
            return themeStore.semanticPalette.fullscreenLyricBase
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
           let source = playbackCoordinator.presentation.localTrack?.trackArtworkSource(fallbackData: display.artworkData) {
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
        let fallbackTrackID = display.artworkTrackID
        guard artworkSnapshot?.artworkChecksum == ArtworkRenderingFallback.checksum(for: fallbackTrackID) else {
            return nil
        }
        return ArtworkRenderingFallback.data(for: fallbackTrackID)
    }
    
    private func loadArtworkSnapshot() async {
        let display = currentDisplayContext
        guard let trackID = display.artworkTrackID else {
            return
        }

        let expectedTrackID = trackID
        let expectedTaskKey = currentArtworkTaskKey
        let snapshot: ArtworkAssetSnapshot?
        if display.source == .local,
           let source = playbackCoordinator.presentation.localTrack?.trackArtworkSource(fallbackData: display.artworkData) {
            snapshot = await TrackArtworkCache.shared.snapshot(
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
        guard currentArtworkTrackID == expectedTrackID else { return }
        guard currentArtworkTaskKey == expectedTaskKey else { return }
        guard let snapshot, snapshot.trackID == expectedTrackID, Self.isValidDisplayArtworkSnapshot(snapshot) else {
            if !display.isArtworkLoading {
                artworkSnapshot = nil
            }
            return
        }

        artworkSnapshot = snapshot

        // CRITICAL: Trigger AMLL theme refresh after artwork colors are loaded
        // Without this, fullscreen lyrics colors would not update when track changes
        applyFullscreenLyricsTheme(reason: "artworkSnapshot-loaded")
    }

    private var preferredArtworkFullImageMaxPixel: Int {
        1_400
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

private enum FullscreenTTMLTimingExtractor {
    static func lastMainLineEndTime(in ttml: String) -> TimeInterval? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = FullscreenTTMLTimingParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse() else { return nil }
        return delegate.lastMainLineEndTime
    }
}

private final class FullscreenTTMLTimingParser: NSObject, XMLParserDelegate {
    private(set) var lastMainLineEndTime: TimeInterval?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.localName(qName ?? elementName)
        guard name == "p" else { return }
        guard !Self.isBackgroundLine(attributeDict) else { return }

        let begin = Self.timeValue(forLocalName: "begin", in: attributeDict)
        let explicitEnd = Self.timeValue(forLocalName: "end", in: attributeDict)
        let duration = Self.timeValue(forLocalName: "dur", in: attributeDict)
        let endTime = explicitEnd ?? begin.flatMap { start in duration.map { start + $0 } }
        guard let endTime, endTime.isFinite, endTime >= 0 else { return }
        lastMainLineEndTime = max(lastMainLineEndTime ?? 0, endTime)
    }

    private static func isBackgroundLine(_ attributes: [String: String]) -> Bool {
        attributes.contains { key, value in
            localName(key) == "role" && value.lowercased().contains("x-bg")
        }
    }

    private static func timeValue(
        forLocalName targetName: String,
        in attributes: [String: String]
    ) -> TimeInterval? {
        guard let raw = attributes.first(where: { localName($0.key) == targetName })?.value else {
            return nil
        }
        return parseTimeExpression(raw)
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    private static func parseTimeExpression(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .lowercased()
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("ms"),
           let milliseconds = Double(value.dropLast(2)) {
            return milliseconds / 1000.0
        }
        if value.hasSuffix("s"),
           let seconds = Double(value.dropLast()) {
            return seconds
        }
        if value.hasSuffix("m"),
           let minutes = Double(value.dropLast()) {
            return minutes * 60.0
        }
        if value.hasSuffix("h"),
           let hours = Double(value.dropLast()) {
            return hours * 3600.0
        }

        let parts = value.split(separator: ":").map(String.init)
        if parts.count == 2 || parts.count == 3 {
            guard let seconds = Double(parts[parts.count - 1]) else { return nil }
            guard let minutes = Double(parts[parts.count - 2]) else { return nil }
            let hours = parts.count == 3 ? (Double(parts[0]) ?? .nan) : 0
            guard hours.isFinite, minutes.isFinite, seconds.isFinite else { return nil }
            return hours * 3600.0 + minutes * 60.0 + seconds
        }

        return Double(value)
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

// MARK: - Fullscreen AMLL layer-volatility diagnostics

/// DEBUG-only logging for correlating the fullscreen AMLL WKWebView's AppKit
/// layer state with `WebProcess::markAllLayersVolatile` floods. All entry
/// points are no-ops unless `KMGCCC_AMLL_FULLSCREEN_LAYER_DIAGNOSTICS=1`.
fileprivate enum FullscreenLyricsLayerDiagnostics {
    static func logEvent(
        _ event: String,
        store: LyricsWebViewStore?,
        hostOpacity: Double,
        viewportOpacity: Double,
        hostMounted: Bool,
        controlsVisible: Bool,
        disableWrapper: Bool,
        skinID: String,
        hostContext: String
    ) {
        guard LyricsDebugFlags.fullscreenLayerDiagnosticsEnabled else { return }
        emit(
            event: event,
            store: store,
            hostOpacity: hostOpacity,
            viewportOpacity: viewportOpacity,
            hostMounted: hostMounted,
            controlsVisible: controlsVisible,
            disableWrapper: disableWrapper,
            skinID: skinID,
            hostContext: hostContext
        )
    }

    /// Periodic snapshot used to line up WebView layer state with Console.app
    /// flood timestamps. Fires every 2s from the fullscreen view body.
    static func logPeriodicSnapshot(
        store: LyricsWebViewStore?,
        hostOpacity: Double,
        viewportOpacity: Double,
        hostMounted: Bool,
        controlsVisible: Bool,
        disableWrapper: Bool,
        skinID: String,
        hostContext: String
    ) {
        guard LyricsDebugFlags.fullscreenLayerDiagnosticsEnabled else { return }
        emit(
            event: "periodic",
            store: store,
            hostOpacity: hostOpacity,
            viewportOpacity: viewportOpacity,
            hostMounted: hostMounted,
            controlsVisible: controlsVisible,
            disableWrapper: disableWrapper,
            skinID: skinID,
            hostContext: hostContext
        )
    }

    private static func emit(
        event: String,
        store: LyricsWebViewStore?,
        hostOpacity: Double,
        viewportOpacity: Double,
        hostMounted: Bool,
        controlsVisible: Bool,
        disableWrapper: Bool,
        skinID: String,
        hostContext: String
    ) {
        let webViewState = store?.debugLayerStateSnapshot ?? "noStore"
        AMLLLifecycleDiagnostics.emit(
            "fullscreen.\(event) host=\(hostContext) skin=\(skinID) wrapperDisabled=\(disableWrapper) hostOpacity=\(String(format: "%.2f", hostOpacity)) viewportOpacity=\(String(format: "%.2f", viewportOpacity)) hostMounted=\(hostMounted) controlsVisible=\(controlsVisible) fullscreenWebView=[\(webViewState)]"
        )
        store?.logLifecycleDiagnostics(reason: "fullscreen.\(event)")
        LyricsSurfaceManager.shared.existingStore(for: .main)?
            .logLifecycleDiagnostics(reason: "fullscreen.\(event).main")
        Log.warning(
            "[FS-LAYER-DIAG] \(event) host=\(hostContext) skin=\(skinID) wrapper=\(disableWrapper ? "DISABLED" : "on") hostOpacity=\(String(format: "%.2f", hostOpacity)) viewportOpacity=\(String(format: "%.2f", viewportOpacity)) hostMounted=\(hostMounted) controlsVisible=\(controlsVisible) | webView[\(webViewState)] t=\(String(format: "%.4f", ProcessInfo.processInfo.systemUptime))",
            category: .webview
        )
    }
}

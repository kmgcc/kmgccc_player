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

/// Fullscreen player view with enlarged skin artwork (left), AMLL lyrics (right, no material),
/// and enlarged miniplayer controls at bottom. Uses artbk background.
/// Includes exit buttons at top-right and bottom-right.
@MainActor
struct FullscreenPlayerView: View {
    // MARK: - Fullscreen Base Canvas Constants
    // Base canvas size: 1470 x 923 is the reference design
    // The entire canvas is scaled as one unit using scaleEffect
    private static let baseCanvasWidth: CGFloat = 1470
    private static let baseCanvasHeight: CGFloat = 923

    private struct FullscreenLyricsColorSet {
        let mainActive: NSColor
        let mainInactive: NSColor
        let lineTimingMainInactive: NSColor
        let subActive: NSColor
        let subInactive: NSColor
        let lineTimingSubInactive: NSColor
    }

    private enum FullscreenCoverBlurBlendProfile: String {
        case lighter
        case darker

        var paletteScheme: ColorScheme {
            switch self {
            case .lighter:
                return .dark
            case .darker:
                return .light
            }
        }
    }

    private struct FullscreenCoverBlurLyricsTheme {
        let trackID: UUID
        let themeColor: NSColor
        let themeLightness: CGFloat
        let profile: FullscreenCoverBlurBlendProfile
        let colors: FullscreenLyricsColorSet
    }

    private enum FullscreenCoverBlurRenderLayer: String {
        case base
        case highlight
    }

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
    private let fullscreenBackgroundLyricsAvoidanceHorizontalInset: CGFloat = 28
    private let fullscreenBackgroundLyricsAvoidanceTopInset: CGFloat = 36
    private let fullscreenBackgroundLyricsAvoidanceBottomInset: CGFloat = 60
    private let fullscreenLyricsAlignPosition: Double = 0.18  // Current line higher in viewport (was 0.28)
    private let coverSkinLyricsRightShift: CGFloat = 30
    private let fullscreenLyricsMinimumBaseLightness: CGFloat = 0.52
    private let fullscreenLyricsMaximumBaseLightness: CGFloat = 0.66
    private let fullscreenLyricsMinimumSubActiveLightness: CGFloat = 0.88
    private let fullscreenLyricsMaximumSubActiveLightness: CGFloat = 0.94
    private let fullscreenLyricsMinimumMainActiveLightness: CGFloat = 0.95
    private let fullscreenLyricsMaximumMainActiveLightness: CGFloat = 0.98
    private let fullscreenLyricsSaturationFloor: CGFloat = 0.10
    private let fullscreenLyricsSaturationCeiling: CGFloat = 0.58

    @Environment(PlayerViewModel.self) private var playerVM
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
    @State private var pendingFullscreenTrackRefresh: DispatchWorkItem?
    @State private var artworkSnapshot: ArtworkAssetSnapshot?
    @State private var coverBlurLyricsTheme: FullscreenCoverBlurLyricsTheme?
    @State private var deferredTrackUpdateDeadline: Date?
    @State private var suppressFullscreenLyricsViewport = false
    @State private var isLeadingControlsExpanded = false
    @State private var appearanceRotateTrigger = 0
    @State private var currentFullscreenScale: CGFloat = 1.0
    @State private var didHandleFullscreenAppear = false
    @State private var isFullscreenBottomControlsVisible = true
    @State private var isFullscreenBottomControlsHovered = false
    @State private var isFullscreenBottomControlsHotZoneHovered = false
    @State private var isFullscreenBottomControlsLeadingHovered = false
    @State private var isFullscreenBottomControlsCenterHovered = false
    @State private var isFullscreenBottomControlsTrailingHovered = false
    @State private var isFullscreenBottomControlsProgressDragging = false
    @State private var isFullscreenBottomControlsVolumeAdjusting = false
    @State private var pendingFullscreenBottomControlsHide: DispatchWorkItem?
    @Namespace private var fullscreenLayoutNamespace

    var onExitFullscreen: (() -> Void)?

    private var isCoverBlurFullscreenSkin: Bool {
        settings.fullscreen.skinID == "fullscreen.coverGradientBlur"
    }

    /// Cover-element skins (classic, rotating, cassette) get a slight vertical
    /// drop when the fullscreen miniplayer auto-hides, and return when it reappears.
    private var isCoverSkinWithMiniplayerMotion: Bool {
        let id = settings.fullscreen.skinID
        return id == "coverLed" || id == "rotatingCover" || id == "kmgccc.cassette"
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
        let selectedSkinID = settings.fullscreen.skinID
        let selectedSkin = SkinRegistry.fullscreenSkin(for: selectedSkinID)
        let usesCustomBg = selectedSkinID == "fullscreen.coverGradientBlur"

        GeometryReader { proxy in
            fullscreenContent(for: proxy, selectedSkin: selectedSkin, skinUsesCustomBackground: usesCustomBg)
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

            // Report visibility to manager - manager handles the switch with debouncing
            LyricsSurfaceManager.shared.reportFullscreenVisible(true)

            syncCoverBlurHighlightActivation()
            resetFullscreenLyricsBackgroundSnapshot()
            scheduleFullscreenLyricsBackgroundCapture()
            setupSeekCallback()
            reloadLyricsSurface(reason: "fullscreen appear", forceLyricsReload: true)
            resetFullscreenBottomControlsAutoHideState()

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
            pendingFullscreenLyricsRefresh?.cancel()
            pendingFullscreenLyricsRefresh = nil
            pendingFullscreenLyricsReveal?.cancel()
            pendingFullscreenLyricsReveal = nil
            pendingFullscreenTrackRefresh?.cancel()
            pendingFullscreenTrackRefresh = nil
            deferredTrackUpdateDeadline = nil
            suppressFullscreenLyricsViewport = false
            cancelFullscreenBottomControlsAutoHide()
            deactivateCoverBlurHighlightSurface()
            clearFullscreenLyricsTheme()
            Task {
                await ArtworkAssetStore.shared.purgeHydratedImages()
                await CassetteArtworkCache.shared.removeAll()
            }

            // Report visibility to manager - manager will debounce to handle transient disappears
            LyricsSurfaceManager.shared.reportFullscreenVisible(false)
        }
        .onChange(of: selectedSkinID) { oldValue, newValue in
            skinRevision &+= 1
            let coverBlurTransition = oldValue == "fullscreen.coverGradientBlur"
                || newValue == "fullscreen.coverGradientBlur"
            syncCoverBlurHighlightActivation()
            guard coverBlurTransition else { return }
            reloadLyricsSurface(reason: "fullscreen skin changed", forceLyricsReload: true)
        }
        .onChange(of: settings.fullscreen.skinID) { _, newValue in
            if isLedEnabledForFullscreenSkin() {
                ledMeterProvider.getOrCreate().start()
            } else {
                ledMeterProvider.releaseNowPlayingResources()
            }

            // Note: Mutual exclusivity is now handled by FullscreenPresentationCoordinator
            // When skin is set to kmgccc.cassette, Coordinator automatically disables MiniPlayer spectrum
        }
        .onChange(of: playerVM.currentTime, handleCurrentTimeChange)
        .onChange(of: playerVM.isPlaying) { _, newValue in
            LyricsSurfaceManager.shared.updatePlayingState(newValue)
            fullscreenStore.setPlaying(newValue)
            if LyricsSurfaceManager.shared.isActive(.fullscreenCoverBlurHighlight) {
                coverBlurHighlightStore.setPlaying(newValue)
            }
        }
        .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
        .onChange(of: rightPanelDisplayState) { _, newValue in
            handleRightPanelDisplayStateChange(newValue)
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
            guard pendingFullscreenLyricsBackgroundCapture else { return }
            guard bkController.lyricsColorTrackID == playerVM.currentTrack?.id else { return }
            scheduleFullscreenLyricsRefresh(preferLiveSurface: true)
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkSnapshot()
        }
    }

    // MARK: - Fullscreen Content (Extracted to simplify body type checking)
    
    @ViewBuilder
    private func fullscreenContent(for proxy: GeometryProxy, selectedSkin: any NowPlayingSkin, skinUsesCustomBackground: Bool) -> some View {
        let scaleX = proxy.size.width / Self.baseCanvasWidth
        let scaleY = proxy.size.height / Self.baseCanvasHeight
        let scale = min(scaleX, scaleY)

        ZStack {
            if skinUsesCustomBackground {
                selectedSkin.makeBackground(
                    context: makeContext(
                        windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
                        artworkColumnWidth: layoutMetrics.artworkWidth
                    )
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                Color.black.opacity(effectiveDimmingIntensity * 0.7)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else if settings.nowPlayingArtBackgroundEnabled && playerVM.currentTrack != nil {
                BKArtBackgroundView(
                    controller: bkController,
                    trackID: playerVM.currentTrack?.id,
                    artworkData: playerVM.currentTrack?.artworkData,
                    isPlaying: playerVM.isPlaying,
                    avoidanceRect: nil
                )
                .ignoresSafeArea()

                Color.black.opacity(effectiveDimmingIntensity)
                    .ignoresSafeArea()
            } else {
                selectedSkin.makeBackground(
                    context: makeContext(
                        windowSize: CGSize(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight),
                        artworkColumnWidth: layoutMetrics.artworkWidth
                    )
                )
                .ignoresSafeArea()

                Color.black.opacity(effectiveDimmingIntensity * 0.7)
                    .ignoresSafeArea()
            }

            // Layer 1: AMLL lyrics at actual resolution
            fullscreenLyricsLayer(scale: scale, screenWidth: proxy.size.width)
                .frame(width: proxy.size.width, height: proxy.size.height)

            // Layer 2: Scaled container for artwork only
            fullscreenScaledContainer(selectedSkin: selectedSkin, scale: scale, screenWidth: proxy.size.width)
                .frame(width: Self.baseCanvasWidth, height: Self.baseCanvasHeight)
                .scaleEffect(scale, anchor: .center)

            // Layer 3: Bottom bar at actual resolution - on top
            fullscreenBottomBarLayer(scale: scale, screenHeight: proxy.size.height)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .id("fullscreen_\(settings.fullscreen.skinID)_\(skinRevision)")
        .frame(width: proxy.size.width, height: proxy.size.height)
        .onAppear {
            currentFullscreenScale = scale
        }
        .onChange(of: scale) { _, newScale in
            currentFullscreenScale = newScale
        }
    }

    // MARK: - Fullscreen Scaled Container (Artwork + Controls Only)

    @ViewBuilder
    private func fullscreenScaledContainer(selectedSkin: any NowPlayingSkin, scale: CGFloat, screenWidth: CGFloat) -> some View {
        // Cover-element skins drop slightly when the miniplayer auto-hides
        let coverDropY: CGFloat = isCoverSkinWithMiniplayerMotion && !isFullscreenBottomControlsVisible ? 20 : 0

        ZStack {
            VStack(spacing: 0) {
                artworkAndControlsArea(selectedSkin: selectedSkin, scale: scale, screenWidth: screenWidth)
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

    @ViewBuilder
    private func fullscreenLyricsLayer(scale: CGFloat, screenWidth: CGFloat) -> some View {
        let hostMetrics = layoutMetrics(showLyricsColumn: true)
        let rightPanelVisible = isShowingRightPanel

        let scaleX = screenWidth / Self.baseCanvasWidth
        let hostBaseContentOffsetX: CGFloat = -topContentLeftShift
        let hostArtworkColumnCenterX = hostBaseContentOffsetX + hostMetrics.artworkWidth / 2
        let hostArtworkHorizCorrection =
            (hostArtworkColumnCenterX - Self.baseCanvasWidth / 2) * (scaleX - scale) / scale
        let hostArtworkX = hostBaseContentOffsetX + hostArtworkHorizCorrection
        let baseLyricsX =
            hostArtworkX + hostMetrics.artworkWidth + artworkLyricsColumnSpacing - lyricsColumnLeftNudge

        // Expand left by 80pt (moves block left) for the lyrics viewport.
        // Skin-specific right shift for the cover-gradient-blur skin.
        let leftExpansion: CGFloat = 80
        let coverSkinOffset: CGFloat = settings.fullscreen.skinID == "fullscreen.coverGradientBlur" ? coverSkinLyricsRightShift : 0
        let finalLyricsX = baseLyricsX - leftExpansion + coverSkinOffset

        // Canvas horizontal centering margin: on 16:9 screens the canvas is narrower than
        // the screen; add the side margin so the lyrics block stays anchored to the cover
        // image, not to the left screen edge.
        let canvasCenteringX = max(0, (screenWidth - Self.baseCanvasWidth * scale) / 2)
        let visibleLyricsX = finalLyricsX * scale + canvasCenteringX
        let hiddenLyricsX = visibleLyricsX + 92 * scale
        let actualLyricsX = rightPanelVisible ? visibleLyricsX : hiddenLyricsX

        // Right boundary: span to screen-edge minus an adaptive padding rather than a
        // fixed canvas-fraction, so the region fills available space on all displays.
        let lyricsRightScreenPad: CGFloat = 44 * scale
        let actualLyricsWidth = max(100, screenWidth - visibleLyricsX - lyricsRightScreenPad)

        // Fixed AMLL frame — always the full base canvas height. AMLL's DOM never resizes
        // during miniplayer hide/show, so setAlignPosition never chases a moving target.
        let actualLyricsHeight = Self.baseCanvasHeight * scale  // 923*scale, constant

        // Visible clip boundary — Swift-only. Animates 851↔923*scale via bottomControlsAnimation.
        // Only the mask window changes; the WebView content space stays stable.
        let visibleBottomReserve: CGFloat = isFullscreenBottomControlsVisible ? fullscreenControlsBottomPadding : 0
        let visibleClipHeight = (Self.baseCanvasHeight - visibleBottomReserve) * scale

        // Debug logging for first layout
        let _ = {
            if rightPanelVisible {
                Log.debug("fullscreenLyricsLayer: scale=\(scale), width=\(actualLyricsWidth), height=\(actualLyricsHeight), visible=\(rightPanelVisible)", category: .webview)
            }
        }()

        ZStack(alignment: .topLeading) {
            if isShowingQueuePanel {
                // 队列面板：位置微调：更靠左、更宽、稍微下移
                fullscreenQueuePanel(
                    scale: scale,
                    visibleHeight: visibleClipHeight
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 118 * scale)
                .padding(.top, 72 * scale)  // 稍微往下移一点（原来是60）
                .allowsHitTesting(true)
                .accessibilityHidden(false)
            } else if isShowingLyricsPanel {
                // Top-left anchored. Height is fixed; only the visible clip region changes.
                fullscreenLyricsCrispView(scale: scale, visibleClipHeight: visibleClipHeight)
                    .frame(width: actualLyricsWidth, height: actualLyricsHeight, alignment: .topLeading)
                    .offset(x: actualLyricsX)
                    .allowsHitTesting(true)
                    .accessibilityHidden(false)
            } else {
                Color.clear
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
                        blendMode: isCoverBlurFullscreenSkin ? coverBlurBaseBlendMode : .normal,
                        useCompositingGroup: !isCoverBlurFullscreenSkin
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

    // MARK: - Fixed Layout Metrics (for 1470x923 base canvas)

    private var layoutMetrics: (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        layoutMetrics(showLyricsColumn: isShowingRightPanel)
    }

    private func layoutMetrics(
        showLyricsColumn: Bool,
        windowWidth: CGFloat? = nil
    ) -> (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        let resolvedWindowWidth = windowWidth ?? Self.baseCanvasWidth
        let availableWidth = max(0, resolvedWindowWidth - topContentHorizontalPadding * 2)

        if showLyricsColumn {
            let constrainedWidth = max(0, availableWidth - lyricsRightMarginReserve)
            let lyricsWidth = min(max(constrainedWidth * 0.30, 320), 560)
            let artworkWidth = max(constrainedWidth - lyricsWidth - artworkLyricsColumnSpacing, 360)
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
    private let leadingControlsExpandedWidth: CGFloat = 180
    private let leadingControlsCollapsedWidth: CGFloat = 120  // 2 buttons × 60pt
    private let volumeExpandedWidth: CGFloat = 180
    private let volumeCollapsedWidth: CGFloat = 60

    private func bottomControlsRow() -> some View {
        // Fixed layout for 1470x923 base canvas
        let buttonSize = fullscreenControlButtonSize
        let spacing = fullscreenControlSpacing
        let windowWidth = Self.baseCanvasWidth
        let leadingControlsWidth = isLeadingControlsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth
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
                materialStyle: fullscreenBottomControlsGlassMaterialStyle
            )
                .frame(width: leadingControlsWidth, height: buttonSize)
                .offset(x: leadingControlsOriginX)

            FullscreenMiniPlayerView(
                playbackMode: currentPlaybackMode,
                onPlaybackModeChange: handlePlaybackModeChange,
                onCurrentPlaybackModeRetap: handleCurrentPlaybackModeRetap
            )
                .frame(width: currentMiniPlayerWidth, height: buttonSize)
                .environment(\.colorScheme, fullscreenControlsColorScheme)
                .offset(x: miniPlayerOriginX)

            ExpandableVolumeControl(
                volume: volumeBinding,
                isExpanded: $isVolumeExpanded
            )
            .frame(width: volumeWidth, height: buttonSize)
            .environment(\.colorScheme, fullscreenControlsColorScheme)
            .offset(x: volumeOriginX)
        }
        .frame(width: windowWidth, height: buttonSize, alignment: .leading)
        .padding(.bottom, fullscreenControlsBottomPadding)
        .animation(bottomControlsAnimation, value: isLeadingControlsExpanded)
        .animation(bottomControlsAnimation, value: isVolumeExpanded)
    }

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

    private var fullscreenBottomControlsGlassMaterialStyle: LiquidGlassPillMaterialStyle {
        switch settings.fullscreenMiniPlayerGlassMaterial {
        case .clear:
            return .clear
        case .darkGlass:
            return .darkGlass
        }
    }

    private var shouldBlockFullscreenBottomControlsAutoHide: Bool {
        shouldKeepFullscreenBottomControlsVisible
            || isFullscreenBottomControlsHovered
            || isLeadingControlsExpanded
            || isVolumeExpanded
            || isFullscreenBottomControlsProgressDragging
            || isFullscreenBottomControlsVolumeAdjusting
    }

    private var shouldKeepFullscreenBottomControlsVisible: Bool {
        isShowingQueuePanel
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
        leading: Bool? = nil,
        center: Bool? = nil,
        trailing: Bool? = nil
    ) {
        if let hotZone {
            isFullscreenBottomControlsHotZoneHovered = hotZone
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

    private func handleRightPanelDisplayStateChange(_ newState: RightPanelDisplayState) {
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
        isFullscreenBottomControlsVisible = true
        isFullscreenBottomControlsProgressDragging = false
        isFullscreenBottomControlsVolumeAdjusting = false
        isFullscreenBottomControlsHovered = false
        isFullscreenBottomControlsHotZoneHovered = false
        isFullscreenBottomControlsLeadingHovered = false
        isFullscreenBottomControlsCenterHovered = false
        isFullscreenBottomControlsTrailingHovered = false
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

        let hideWorkItem = DispatchWorkItem { @MainActor in
            guard shouldBlockFullscreenBottomControlsAutoHide == false else {
                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                return
            }
            withAnimation(bottomControlsAnimation) {
                isFullscreenBottomControlsVisible = false
            }
        }
        pendingFullscreenBottomControlsHide = hideWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + settings.fullscreenMiniPlayerAutoHideSeconds,
            execute: hideWorkItem
        )
    }

    private func cancelFullscreenBottomControlsAutoHide() {
        pendingFullscreenBottomControlsHide?.cancel()
        pendingFullscreenBottomControlsHide = nil
    }

    // MARK: - Fullscreen Bottom Bar Layer (Actual Resolution - Crisp)
    
    @ViewBuilder
    private func fullscreenBottomBarLayer(scale: CGFloat, screenHeight: CGFloat) -> some View {
        // Use the same base calculations as bottomControlsRow, then multiply by scale
        let baseScale = scale
        let buttonSize = fullscreenControlButtonSize
        let spacing = fullscreenControlSpacing
        let windowWidth = Self.baseCanvasWidth
        
        let leadingControlsWidth = isLeadingControlsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth
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
        
        VStack {
            Spacer()
            ZStack(alignment: .leading) {
                Color.clear
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

                if isFullscreenBottomControlsVisible {
                    leadingControlsPill(
                        size: scaledButtonSize,
                        materialStyle: fullscreenBottomControlsGlassMaterialStyle
                    )
                        .glassEffectTransition(.materialize)
                        .frame(width: scaledLeadingControlsWidth, height: scaledButtonSize)
                        .position(
                            x: scaledLeadingControlsOriginX + scaledLeadingControlsWidth / 2,
                            y: controlsCenterY
                        )
                    
                    FullscreenMiniPlayerView(
                        scale: scale,
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
                        }
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledMiniPlayerWidth, height: scaledButtonSize)
                    .environment(\.colorScheme, fullscreenControlsColorScheme)
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
                                registerFullscreenBottomControlsInteraction()
                            } else {
                                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                            }
                        },
                        onAdjustingChanged: { adjusting in
                            isFullscreenBottomControlsVolumeAdjusting = adjusting
                            if adjusting {
                                registerFullscreenBottomControlsInteraction()
                            } else {
                                scheduleFullscreenBottomControlsAutoHideIfNeeded()
                            }
                        },
                        materialStyle: fullscreenBottomControlsGlassMaterialStyle
                    )
                    .glassEffectTransition(.materialize)
                    .frame(width: scaledVolumeWidth, height: scaledButtonSize)
                    .environment(\.colorScheme, fullscreenControlsColorScheme)
                    .position(
                        x: scaledVolumeOriginX + scaledVolumeWidth / 2,
                        y: controlsCenterY
                    )
                }
            }
            .frame(width: scaledWindowWidth, height: controlsRowHeight, alignment: .leading)
            .padding(.bottom, adjustedBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(bottomControlsAnimation, value: isLeadingControlsExpanded)
        .animation(bottomControlsAnimation, value: isVolumeExpanded)
        .animation(bottomControlsAnimation, value: isFullscreenBottomControlsVisible)
    }

    // MARK: - Artwork and Controls Area (No Lyrics - Lyrics are in crisp layer)

    @ViewBuilder
    private func artworkAndControlsArea(selectedSkin: any NowPlayingSkin, scale: CGFloat, screenWidth: CGFloat) -> some View {
        let metrics = layoutMetrics
        let windowWidth = Self.baseCanvasWidth
        let rightPanelVisible = isShowingRightPanel

        let artworkToCenterOffset = max(0, (windowWidth - metrics.artworkWidth) * 0.5)
        let contentOffsetX: CGFloat = rightPanelVisible ? -topContentLeftShift : artworkToCenterOffset

        // Shift the artwork column left to compensate for the canvas horizontal centering
        // margin on screens wider than the 1470:923 aspect ratio (e.g. 16:9 at 1080p).
        // Without this, the canvas margin shifts the cover right relative to the baseline
        // composition.  On baseline displays (canvas ≈ fills width) the correction is ~0.
        let scaleX = screenWidth / Self.baseCanvasWidth
        let artworkColumnCenterX = contentOffsetX + metrics.artworkWidth / 2
        let artworkHorizCorrection: CGFloat = rightPanelVisible
            ? (artworkColumnCenterX - Self.baseCanvasWidth / 2) * (scaleX - scale) / scale
            : 0
        let adjustedContentOffsetX = contentOffsetX + artworkHorizCorrection

        skinArtworkArea(
            selectedSkin: selectedSkin,
            artworkColumnWidth: metrics.artworkWidth,
            scale: scale
        )
        .frame(width: metrics.artworkWidth)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .offset(x: adjustedContentOffsetX)
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
            if playerVM.currentTrack == nil {
                VStack(spacing: 16) {
                    Image(systemName: "music.note")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("lyrics.empty_state")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
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
        
        return HStack(spacing: 0) {
            leadingControlButton(size: size, help: "fullscreen.exit") {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
                    .compositingGroup()
                    .blendMode(.screen)
            } action: {
                onExitFullscreen?()
            }

            lyricsVisibilityButton(size: size)

            appearanceSwitchButton(size: size)
                .opacity(isLeadingControlsExpanded ? 1 : 0)
                .allowsHitTesting(isLeadingControlsExpanded)
                .accessibilityHidden(!isLeadingControlsExpanded)
        }
        .frame(
            width: isLeadingControlsExpanded ? leadingControlsExpandedWidth * scaleFactor : leadingControlsCollapsedWidth * scaleFactor,
            height: size,
            alignment: .leading
        )
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: fullscreenControlsColorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            materialStyle: materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, fullscreenControlsColorScheme)
        .onHover { hovering in
            updateFullscreenBottomControlsHoverGate(leading: hovering)
            isLeadingControlsExpanded = hovering
            if hovering {
                registerFullscreenBottomControlsInteraction()
            } else {
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

    private func appearanceSwitchButton(size: CGFloat) -> some View {
        let icon = effectiveFullscreenAppearance == .dark ? "moon" : "sun.max"
        let helpText: LocalizedStringKey =
            effectiveFullscreenAppearance == .dark ? "sidebar.appearance_dark" : "sidebar.appearance_light"

        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
                .compositingGroup()
                .blendMode(.screen)
                .symbolEffect(.rotate, value: appearanceRotateTrigger)
                .contentTransition(
                    .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                )
                .animation(.snappy(duration: 0.24), value: icon)
        } action: {
            let target = nextFullscreenAppearanceTarget()
            if target == .light {
                appearanceRotateTrigger += 1
            }
            cycleFullscreenAppearance(to: target)
        }
    }

    private func lyricsVisibilityButton(size: CGFloat) -> some View {
        let isShowingLyrics = rightPanelDisplayState == .lyrics
        let icon = isShowingLyrics ? "quote.bubble.fill" : "quote.bubble"
        let helpText: LocalizedStringKey = isShowingLyrics ? "Hide Lyrics" : "Show Lyrics"
        let canToggle = playerVM.currentTrack != nil

        return leadingControlButton(size: size, help: helpText) {
            Image(systemName: icon)
                .id(icon)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(fullscreenMiniPlayerPrimaryColor.opacity(canToggle ? 1 : 0.45))
                .compositingGroup()
                .blendMode(.screen)
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
        if settings.stopAfterTrack { return .stopAfterTrack }
        if settings.repeatMode == "one" { return .repeatOne }
        if settings.shuffleEnabled { return .shuffle }
        return .sequence
    }

    private var lyricsLayoutAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.2)
        }
        // Non-linear, spring-like layout movement for artwork/lyrics transitions.
        return .spring(response: 0.62, dampingFraction: 0.84, blendDuration: 0.18)
    }

    private var fullscreenMiniPlayerPrimaryColor: Color {
        FullscreenMiniPlayerView.resolveControlPrimaryColor(from: themeStore.accentNSColor)
    }

    private var fullscreenControlsColorScheme: ColorScheme {
        isCoverBlurFullscreenSkin ? .dark : colorScheme
    }

    private var coverBlurBaseBlendMode: BlendMode {
        guard isCoverBlurFullscreenSkin else { return .normal }
        guard coverBlurLyricsTheme?.trackID == playerVM.currentTrack?.id else { return .normal }
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
        // Note: LED state is now managed by FullscreenPresentationCoordinator
        // This method checks if the current configuration has skin visualizer enabled
        guard settings.fullscreen.isSkinVisualizerEnabled else { return false }

        let skinID = settings.fullscreen.skinID
        switch skinID {
        case "coverLed", "rotatingCover":
            return true
        case "kmgccc.cassette":
            return false // Cassette doesn't support visualizer
        default:
            return false
        }
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
            reloadLyricsSurface(reason: "fullscreen playback restarted", forceLyricsReload: true)
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }

        // Clear artwork snapshot to prevent stale colors
        artworkSnapshot = nil

        // Simplified track change handling - matches window mode behavior
        // Apply track immediately without deferred scheduling
        reloadLyricsSurface(reason: "fullscreen track changed", forceLyricsReload: true)
    }

    private func reloadLyricsSurface(
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false,
        recreateWebViewOnForceReload: Bool = false
    ) {
        syncCoverBlurHighlightActivation()

        // Apply to fullscreen store directly
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
        if !pendingFullscreenLyricsBackgroundCapture {
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


    private var fullscreenLyricsViewportOpacity: Double {
        guard playerVM.currentTrack != nil else { return 0 }
        if isCoverBlurFullscreenSkin && coverBlurLyricsTheme?.trackID != playerVM.currentTrack?.id {
            return 0
        }
        return suppressFullscreenLyricsViewport ? 0 : 1
    }
    private func scheduleFullscreenLyricsViewportReveal(after delay: TimeInterval) {
        pendingFullscreenLyricsReveal?.cancel()

        let revealTrackID = playerVM.currentTrack?.id
        let workItem = DispatchWorkItem {
            guard playerVM.currentTrack?.id == revealTrackID else { return }
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
                let revealTrackID = playerVM.currentTrack?.id
                let revealWorkItem = DispatchWorkItem {
                    guard playerVM.currentTrack?.id == revealTrackID else { return }
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
        let baseStore = fullscreenStore
        let surfaceRole = LyricsSurfaceRole.fullscreen
        let currentTrack = playerVM.currentTrack
        let readyCoverBlurTheme = isCoverBlurFullscreenSkin
            ? updateCoverBlurLyricsThemeIfReady(for: currentTrack)
            : nil
        let heldCoverBlurTheme = coverBlurLyricsTheme
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
        let colorSet = activeCoverBlurTheme?.colors ?? makeFullscreenLyricsColorSet(for: currentTrack)

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

        let activePalette = activeCoverBlurTheme.map { makeCoverBlurLyricsPalette(from: $0) }
            ?? makeFullscreenLyricsPalette(from: colorSet)
        LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(activePalette, for: .fullscreen)
        baseStore.setThemePaletteOverride(activePalette)
        if shouldRenderCoverBlurHighlightOverlay, let highlightStore = existingCoverBlurHighlightStore {
            LyricsSurfaceManager.shared.updateThemeOverrideSnapshot(
                activePalette,
                for: .fullscreenCoverBlurHighlight
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
        let trackOffsetMs = max(-15000, min(15000, currentTrack?.lyricsTimeOffsetMs ?? 0))
        let globalAdvanceMs = max(-5000, min(5000, settings.lyricsGlobalAdvanceMs))
        let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - globalAdvanceMs))

        

        // Scale font sizes based on fullscreen scale for crisp rendering at all resolutions
        let scaledFontSize = settings.fullscreenLyricsFontSize * currentFullscreenScale
        let scaledTranslationFontSize = settings.fullscreenLyricsTranslationFontSize * currentFullscreenScale

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
        ]

        config["fullscreenLyricDodgeMode"] = true
        config["fullscreenCoverBlurMode"] = false
        config["coverBlurFullscreenGenericMode"] = isCoverBlurFullscreenSkin && activeCoverBlurTheme != nil
        config["coverBlurFullscreenGenericProfile"] = activeCoverBlurTheme?.profile.rawValue ?? NSNull()
        config["coverBlurFullscreenThemeColor"] = coverBlurThemeColor ?? NSNull()

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
        pushFullscreenLyricsConfig(
            baseConfig,
            to: baseStore,
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
            force: force,
            reason: reason,
            probeLabel: "fullscreen-\(probeMode)-highlight-\(probeReason)",
            probeDelay: probeDelay
        )
    }

    private func pushFullscreenLyricsConfig(
        _ config: [String: Any],
        to store: LyricsWebViewStore,
        force: Bool,
        reason: String,
        probeLabel: String,
        probeDelay: TimeInterval
    ) {
        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            if let role = LyricsSurfaceRole(rawValue: store.role) {
                LyricsSurfaceManager.shared.updateSurfaceConfigSnapshot(json, for: role)
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
            settings.nowPlayingArtBackgroundEnabled && playerVM.currentTrack != nil
    }

    private func captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: Bool = false) {
        guard settings.nowPlayingArtBackgroundEnabled else {
            resetFullscreenLyricsBackgroundSnapshot()
            return
        }

        guard bkController.lyricsColorTrackID == playerVM.currentTrack?.id else {
            pendingFullscreenLyricsBackgroundCapture = playerVM.currentTrack != nil
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

    private func makeContext(windowSize: CGSize, artworkColumnWidth: CGFloat, fullscreenScale: CGFloat = 1.0) -> SkinContext {
        let track = playerVM.currentTrack

        let trackMeta: SkinContext.TrackMetadata? = track.map {
            SkinContext.TrackMetadata(
                id: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration,
                artworkChecksum: artworkSnapshot?.artworkChecksum ?? 0,
                artworkData: $0.artworkData,
                artworkImage: artworkSnapshot?.fullImage
            )
        }

        let playback = SkinContext.PlaybackState(
            isPlaying: playerVM.isPlaying,
            currentTime: playerVM.currentTime,
            duration: playerVM.duration,
            progress: playerVM.duration > 0 ? playerVM.currentTime / playerVM.duration : 0
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
            lyricsVisible: isShowingRightPanel
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

    private func layoutMetrics(for windowSize: CGSize) -> (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        layoutMetrics(showLyricsColumn: isShowingRightPanel, windowWidth: windowSize.width)
    }

    private func fullscreenBackgroundAvoidanceRect(in windowSize: CGSize) -> CGRect? {
        guard isShowingRightPanel else { return nil }

        let metrics = layoutMetrics(for: windowSize)
        let rectX =
            metrics.artworkWidth
            + artworkLyricsColumnSpacing
            - lyricsColumnLeftNudge
            + fullscreenBackgroundLyricsAvoidanceHorizontalInset
        let rectY = fullscreenBackgroundLyricsAvoidanceTopInset
        let rectWidth = max(
            0,
            metrics.lyricsWidth - fullscreenBackgroundLyricsAvoidanceHorizontalInset * 2
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
            inactiveLine: inactive,
            accent: active,
            shadow: "rgba(0,0,0,0)"
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
            inactiveLine: inactive,
            accent: active,
            shadow: "rgba(0,0,0,0)"
        )
    }

    private func makeFullscreenLyricsColorSet(for track: Track?) -> FullscreenLyricsColorSet {
        let highlightBaseColor = resolveFullscreenLyricsBaseColor(for: track)
        let highlightHSL = hslComponents(from: highlightBaseColor)
        let inactiveBaseColor = resolveFullscreenLyricsInactiveBaseColor(for: track)
        let inactiveHSL = hslComponents(from: inactiveBaseColor)
        let inactiveDarkModeShift: CGFloat = colorScheme == .dark ? 0.08 : 0
        let inactiveUltraDarkShift: CGFloat = lockedFullscreenLyricsUltraDark
            ? (colorScheme == .dark ? 0.22 : 0.17)
            : 0
        let totalInactiveShift = inactiveDarkModeShift + inactiveUltraDarkShift
        let activeLightnessShift: CGFloat = lockedFullscreenLyricsUltraDark
            ? (colorScheme == .dark ? 0.10 : 0.06)
            : (colorScheme == .dark ? 0.02 : 0)
        let inactiveSaturationScale: CGFloat = lockedFullscreenLyricsUltraDark
            ? (colorScheme == .dark ? 0.34 : 0.40)
            : (colorScheme == .dark ? 0.42 : 0.48)
        let inactiveSaturationBias: CGFloat = colorScheme == .dark ? 0.015 : 0.02
        let tunedSaturation = clamp(
            highlightHSL.saturation * 0.70 + 0.06,
            min: fullscreenLyricsSaturationFloor,
            max: fullscreenLyricsSaturationCeiling
        )
        let baseLightness = clamp(
            max(
                inactiveHSL.lightness - 0.02 - totalInactiveShift,
                fullscreenLyricsMinimumBaseLightness - totalInactiveShift * 0.55
            ),
            min: max(0.24, fullscreenLyricsMinimumBaseLightness - totalInactiveShift),
            max: max(0.40, fullscreenLyricsMaximumBaseLightness - totalInactiveShift * 0.95)
        )
        let subActiveLightness = clamp(
            max(highlightHSL.lightness + 0.04 - activeLightnessShift * 0.75, baseLightness + 0.04),
            min: max(0.64, fullscreenLyricsMinimumSubActiveLightness - 0.08 - activeLightnessShift * 0.9),
            max: max(0.74, fullscreenLyricsMaximumSubActiveLightness - 0.08 - activeLightnessShift * 0.75)
        )
        let activeLightness = clamp(
            max(highlightHSL.lightness + 0.18 - activeLightnessShift * 0.6, subActiveLightness + 0.08),
            min: max(0.84, fullscreenLyricsMinimumMainActiveLightness - activeLightnessShift * 0.55),
            max: max(0.90, fullscreenLyricsMaximumMainActiveLightness - activeLightnessShift * 0.45)
        )
        let mainInactiveColor = colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: clamp(inactiveHSL.saturation * inactiveSaturationScale + inactiveSaturationBias, min: 0, max: 1),
            lightness: baseLightness
        )
        let lineTimingMainInactiveColor = colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: clamp(
                inactiveHSL.saturation * max(0.28, inactiveSaturationScale - 0.03) + max(0.01, inactiveSaturationBias - 0.005),
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )
        let subActiveColor = colorFromHSL(
            hue: highlightHSL.hue,
            saturation: clamp(tunedSaturation * 0.78, min: 0, max: 1),
            lightness: subActiveLightness
        )
        let subInactiveColor = colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: clamp(
                inactiveHSL.saturation * max(0.26, inactiveSaturationScale - 0.05) + max(0.01, inactiveSaturationBias - 0.005),
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )
        let lineTimingSubInactiveColor = colorFromHSL(
            hue: inactiveHSL.hue,
            saturation: clamp(
                inactiveHSL.saturation * max(0.24, inactiveSaturationScale - 0.08) + max(0.008, inactiveSaturationBias - 0.008),
                min: 0,
                max: 1
            ),
            lightness: baseLightness
        )

        return FullscreenLyricsColorSet(
            mainActive: colorFromHSL(
                hue: highlightHSL.hue,
                saturation: clamp(tunedSaturation * 1.12 + 0.02, min: 0, max: 1),
                lightness: activeLightness
            ),
            mainInactive: mainInactiveColor,
            lineTimingMainInactive: lineTimingMainInactiveColor,
            // Translation lines stay in a readable light tier on fullscreen dark surface.
            subActive: subActiveColor,
            subInactive: subInactiveColor,
            lineTimingSubInactive: lineTimingSubInactiveColor
        )
    }

    private func makeCoverBlurLyricsColorSet(
        from themeColor: NSColor,
        profile: FullscreenCoverBlurBlendProfile
    ) -> FullscreenLyricsColorSet {
        let themeHSL = hslComponents(from: themeColor)

        switch profile {
        case .lighter:
            let inputLightness = themeHSL.lightness
            let nonHighlightMaxLightness: CGFloat = 0.20
            let isVeryDarkTheme = inputLightness < 0.05
            let isVeryBrightButStillLighter = inputLightness > 0.70
            let activeSaturation: CGFloat
            let activeLightness: CGFloat

            if inputLightness >= 0.64 {
                // Bright lighter-profile artwork should stay bright, but a step below the
                // previous cap so the plus-lighter result does not wash out.
                activeLightness = clamp(
                    max(inputLightness + 0.01, 0.90),
                    min: 0.90,
                    max: 0.935
                )
                activeSaturation = clamp(
                    themeHSL.saturation * 0.70 + 0.04,
                    min: 0.06,
                    max: 0.48
                )
            } else if inputLightness >= 0.46 {
                // Slightly bright input still needs a visible lift, but one notch lower
                // than the bright branch above.
                activeLightness = clamp(
                    max(inputLightness + 0.08, 0.85),
                    min: 0.85,
                    max: 0.89
                )
                activeSaturation = clamp(
                    themeHSL.saturation * 0.54 + 0.04,
                    min: 0.06,
                    max: 0.38
                )
            } else if inputLightness >= 0.18 {
                // Neutral input remains clearly highlighted, but another step down from
                // the brighter bands above.
                activeLightness = clamp(
                    max(inputLightness + 0.06, 0.80),
                    min: 0.80,
                    max: 0.84
                )
                activeSaturation = clamp(
                    themeHSL.saturation * 0.48 + 0.04,
                    min: 0.05,
                    max: 0.34
                )
            } else {
                // Very dark inputs must still render as a visible plus-lighter highlight.
                activeLightness = clamp(
                    max(inputLightness + 0.38, 0.67),
                    min: 0.67,
                    max: 0.78
                )
                activeSaturation = clamp(
                    themeHSL.saturation * 0.14 + 0.06,
                    min: 0.05,
                    max: 0.18
                )
            }

            let veryDarkInactiveBoost: CGFloat = isVeryDarkTheme ? 0.090 : 0
            let brightInactiveTrim: CGFloat = isVeryBrightButStillLighter ? 0.015 : 0
            let inactiveSaturation = clamp(
                themeHSL.saturation * 0.34 + 0.03,
                min: 0.03,
                max: 0.18
            )
            let subInactiveSaturation = clamp(
                themeHSL.saturation * 0.28 + 0.03,
                min: 0.02,
                max: 0.14
            )
            let baseLightness = clamp(
                inputLightness * 0.08 + 0.09 + veryDarkInactiveBoost - brightInactiveTrim,
                min: isVeryDarkTheme ? 0.13 : 0.08,
                max: nonHighlightMaxLightness
            )
            let lineTimingBaseLightness = clamp(
                baseLightness - (isVeryDarkTheme ? 0.025 : 0.04),
                min: isVeryDarkTheme ? 0.10 : 0.05,
                max: nonHighlightMaxLightness
            )
            let subActiveLightness = clamp(
                baseLightness + (isVeryDarkTheme ? 0.035 : 0.045),
                min: isVeryDarkTheme ? 0.15 : 0.13,
                max: 0.24
            )

            return FullscreenLyricsColorSet(
                mainActive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: activeSaturation,
                    lightness: activeLightness
                ),
                mainInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: inactiveSaturation,
                    lightness: baseLightness
                ),
                lineTimingMainInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: clamp(inactiveSaturation * 0.92, min: 0.02, max: 0.24),
                    lightness: lineTimingBaseLightness
                ),
                subActive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: clamp(activeSaturation * 0.82, min: 0.08, max: 0.52),
                    lightness: subActiveLightness
                ),
                subInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: subInactiveSaturation,
                    lightness: clamp(baseLightness - 0.02, min: isVeryDarkTheme ? 0.09 : 0.07, max: 0.18)
                ),
                lineTimingSubInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: clamp(subInactiveSaturation * 0.92, min: 0.02, max: 0.12),
                    lightness: clamp(lineTimingBaseLightness - 0.01, min: isVeryDarkTheme ? 0.07 : 0.04, max: 0.14)
                )
            )
        case .darker:
            // In darker mode the active layer stays in a darker band, but not so low that
            // the highlight disappears entirely.
            let highlightSaturation = clamp(
                themeHSL.saturation * 0.34 + 0.08,
                min: 0.05,
                max: 0.24
            )
            let inactiveSaturation = clamp(
                themeHSL.saturation * 0.18 + 0.02,
                min: 0.01,
                max: 0.10
            )
            let subInactiveSaturation = clamp(
                inactiveSaturation * 0.90,
                min: 0.01,
                max: 0.09
            )
            let baseLightness = clamp(
                0.82 - (1 - themeHSL.lightness) * 0.18,
                min: 0.76,
                max: 0.88
            )
            let lineTimingBaseLightness = clamp(baseLightness - 0.05, min: 0.70, max: 0.82)
            let subActiveLightness = clamp(baseLightness - 0.10, min: 0.62, max: 0.76)
            let highlightLightness = clamp(
                themeHSL.lightness * 0.14 + 0.32,
                min: 0.34,
                max: 0.50
            )

            return FullscreenLyricsColorSet(
                mainActive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: highlightSaturation,
                    lightness: highlightLightness
                ),
                mainInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: inactiveSaturation,
                    lightness: baseLightness
                ),
                lineTimingMainInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: clamp(inactiveSaturation * 0.9, min: 0.06, max: 0.30),
                    lightness: lineTimingBaseLightness
                ),
                subActive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: clamp(highlightSaturation * 0.78, min: 0.04, max: 0.18),
                    lightness: subActiveLightness
                ),
                subInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: subInactiveSaturation,
                    lightness: clamp(baseLightness - 0.02, min: 0.74, max: 0.88)
                ),
                lineTimingSubInactive: colorFromHSL(
                    hue: themeHSL.hue,
                    saturation: clamp(subInactiveSaturation * 0.95, min: 0.01, max: 0.08),
                    lightness: clamp(lineTimingBaseLightness - 0.01, min: 0.68, max: 0.82)
                )
            )
        }
    }

    private func currentArtworkSnapshot(for track: Track?) -> ArtworkAssetSnapshot? {
        guard let track, let snapshot = artworkSnapshot, snapshot.trackID == track.id else {
            return nil
        }
        return snapshot
    }

    private func resolveCoverBlurThemeColor(for track: Track?) -> NSColor? {
        guard let snapshot = currentArtworkSnapshot(for: track) else {
            return nil
        }

        return snapshot.averageColor ?? snapshot.dominantColor ?? snapshot.accentColor
    }

    private func makeCoverBlurLyricsTheme(for track: Track?) -> FullscreenCoverBlurLyricsTheme? {
        guard let track, let themeColor = resolveCoverBlurThemeColor(for: track) else {
            return nil
        }

        let themeHSL = hslComponents(from: themeColor)
        let profile: FullscreenCoverBlurBlendProfile = themeHSL.lightness > 0.82
            ? .darker
            : .lighter

        return FullscreenCoverBlurLyricsTheme(
            trackID: track.id,
            themeColor: themeColor,
            themeLightness: themeHSL.lightness,
            profile: profile,
            colors: makeCoverBlurLyricsColorSet(from: themeColor, profile: profile)
        )
    }

    private func updateCoverBlurLyricsThemeIfReady(
        for track: Track?
    ) -> FullscreenCoverBlurLyricsTheme? {
        guard let resolvedTheme = makeCoverBlurLyricsTheme(for: track) else {
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

    private func resolveFullscreenLyricsBaseColor(for track: Track?) -> NSColor {
        if let accent = currentArtworkSnapshot(for: track)?.accentColor {
            return accent
        }
        if let base = currentArtworkSnapshot(for: track)?.averageColor {
            return base
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    private func resolveFullscreenLyricsInactiveBaseColor(for track: Track?) -> NSColor {
        if let backgroundColor = lockedFullscreenLyricsBackgroundColor {
            return backgroundColor
        }

        if settings.nowPlayingArtBackgroundEnabled, bkController.lyricsColorTrackID == track?.id {
            if pendingFullscreenLyricsBackgroundCapture,
                let backgroundColor = bkController.primaryBackgroundColor
            {
                return backgroundColor
            }

            if let backgroundColor = bkController.currentSurfaceBackgroundColor {
                return backgroundColor
            }

            if let backgroundColor = bkController.primaryBackgroundColor {
                return backgroundColor
            }
        }

        return resolveFullscreenLyricsBaseColor(for: track)
    }
    
    private var currentArtworkTaskKey: String {
        guard let track = playerVM.currentTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: track.artworkData)
        return "\(track.id.uuidString)-\(checksum)"
    }
    
    private func loadArtworkSnapshot() async {
        guard let track = playerVM.currentTrack, let artworkData = track.artworkData, !artworkData.isEmpty
        else {
            artworkSnapshot = nil
            return
        }

        let expectedTrackID = track.id
        let expectedTaskKey = currentArtworkTaskKey
        let snapshot = await ArtworkAssetStore.shared.snapshot(trackID: track.id, artworkData: artworkData)
        guard !Task.isCancelled else { return }
        guard playerVM.currentTrack?.id == expectedTrackID else { return }
        guard currentArtworkTaskKey == expectedTaskKey else { return }
        guard snapshot?.trackID == expectedTrackID else { return }

        artworkSnapshot = snapshot

        // CRITICAL: Trigger AMLL theme refresh after artwork colors are loaded
        // Without this, fullscreen lyrics colors would not update when track changes
        applyFullscreenLyricsTheme(reason: "artworkSnapshot-loaded")
    }

    private func hslComponents(from color: NSColor) -> (hue: CGFloat, saturation: CGFloat, lightness: CGFloat)
    {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        let lightness = (maxValue + minValue) * 0.5

        var hue: CGFloat = 0
        var saturation: CGFloat = 0

        if delta > 0.000_1 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = ((blue - red) / delta) + 2
            } else {
                hue = ((red - green) / delta) + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }

        return (
            hue: clamp(hue, min: 0, max: 1),
            saturation: clamp(saturation, min: 0, max: 1),
            lightness: clamp(lightness, min: 0, max: 1)
        )
    }

    private func colorFromHSL(hue: CGFloat, saturation: CGFloat, lightness: CGFloat) -> NSColor {
        let h = clamp(hue, min: 0, max: 1)
        let s = clamp(saturation, min: 0, max: 1)
        let l = clamp(lightness, min: 0, max: 1)

        if s < 0.000_1 {
            return NSColor(calibratedRed: l, green: l, blue: l, alpha: 1)
        }

        let chroma = (1 - abs(2 * l - 1)) * s
        let scaledHue = h * 6
        let secondary = chroma * (1 - abs(scaledHue.truncatingRemainder(dividingBy: 2) - 1))
        let match = l - chroma * 0.5

        let redPrime: CGFloat
        let greenPrime: CGFloat
        let bluePrime: CGFloat

        switch scaledHue {
        case 0..<1:
            redPrime = chroma
            greenPrime = secondary
            bluePrime = 0
        case 1..<2:
            redPrime = secondary
            greenPrime = chroma
            bluePrime = 0
        case 2..<3:
            redPrime = 0
            greenPrime = chroma
            bluePrime = secondary
        case 3..<4:
            redPrime = 0
            greenPrime = secondary
            bluePrime = chroma
        case 4..<5:
            redPrime = secondary
            greenPrime = 0
            bluePrime = chroma
        default:
            redPrime = chroma
            greenPrime = 0
            bluePrime = secondary
        }

        return NSColor(
            calibratedRed: clamp(redPrime + match, min: 0, max: 1),
            green: clamp(greenPrime + match, min: 0, max: 1),
            blue: clamp(bluePrime + match, min: 0, max: 1),
            alpha: 1
        )
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(upper, Swift.max(lower, value))
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

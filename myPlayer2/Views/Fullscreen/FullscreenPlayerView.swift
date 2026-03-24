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
    private struct FullscreenLyricsColorSet {
        let mainActive: NSColor
        let mainInactive: NSColor
        let lineTimingMainInactive: NSColor
        let subActive: NSColor
        let subInactive: NSColor
        let lineTimingSubInactive: NSColor
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
    private let fullscreenLyricsAlignPosition: Double = 0.28
    private let fullscreenLyricsMinimumBaseLightness: CGFloat = 0.52
    private let fullscreenLyricsMaximumBaseLightness: CGFloat = 0.66
    private let fullscreenLyricsMinimumSubActiveLightness: CGFloat = 0.88
    private let fullscreenLyricsMaximumSubActiveLightness: CGFloat = 0.94
    private let fullscreenLyricsMinimumMainActiveLightness: CGFloat = 0.95
    private let fullscreenLyricsMaximumMainActiveLightness: CGFloat = 0.98
    private let fullscreenLyricsSaturationFloor: CGFloat = 0.10
    private let fullscreenLyricsSaturationCeiling: CGFloat = 0.58

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(LEDMeterService.self) private var ledMeter
    @Environment(AppSettings.self) private var settings
    @Environment(SkinManager.self) private var skinManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var themeStore: ThemeStore
    @StateObject private var bkController = BKArtBackgroundController()
    @State private var skinRevision = 0
    @State private var lyricsColumnVisible: Bool?
    @State private var lockedFullscreenLyricsBackgroundColor: NSColor?
    @State private var lockedFullscreenLyricsUltraDark: Bool = false
    @State private var pendingFullscreenLyricsBackgroundCapture: Bool = false
    @State private var pendingFullscreenLyricsRefresh: DispatchWorkItem?
    @State private var pendingFullscreenLyricsReveal: DispatchWorkItem?
    @State private var pendingFullscreenTrackRefresh: DispatchWorkItem?
    @State private var artworkSnapshot: ArtworkAssetSnapshot?
    @State private var deferredTrackUpdateDeadline: Date?
    @State private var suppressFullscreenLyricsViewport = false
    @State private var isLeadingControlsExpanded = false
    @State private var isLyricsManuallyHidden = false
    @State private var appearanceRotateTrigger = 0
    @Namespace private var fullscreenLayoutNamespace

    var onExitFullscreen: (() -> Void)?

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
        let selectedSkinID = settings.selectedNowPlayingSkinID
        let selectedSkin = skinManager.skin(for: selectedSkinID)

        GeometryReader { proxy in
            ZStack {
                // Background: artbk
                if settings.nowPlayingArtBackgroundEnabled && playerVM.currentTrack != nil {
                    BKArtBackgroundView(
                        controller: bkController,
                        trackID: playerVM.currentTrack?.id,
                        artworkData: playerVM.currentTrack?.artworkData,
                        isPlaying: playerVM.isPlaying,
                        avoidanceRect: fullscreenBackgroundAvoidanceRect(in: proxy.size)
                    )
                    .ignoresSafeArea()
                    
                    // Dimming overlay for better readability - using user setting
                    Color.black.opacity(effectiveDimmingIntensity)
                        .ignoresSafeArea()
                } else {
                    selectedSkin.makeBackground(
                        context: makeContext(
                            windowSize: proxy.size,
                            artworkColumnWidth: layoutMetrics(for: proxy.size).artworkWidth
                        )
                    )
                        .ignoresSafeArea()
                    
                    // Dimming overlay for better readability - using user setting
                    Color.black.opacity(effectiveDimmingIntensity * 0.7)
                        .ignoresSafeArea()
                }

                // Main content layout
                VStack(spacing: 0) {
                    topContentArea(selectedSkin: selectedSkin, windowSize: proxy.size)
                        .padding(.horizontal, topContentHorizontalPadding)
                        .padding(.top, 6)
                        .padding(.bottom, 12)

                    // Bottom: Exit button + miniplayer controls
                    bottomControlsRow(windowSize: proxy.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id("fullscreen_\(selectedSkinID)_\(skinRevision)")
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                refreshFullscreenLyricsColors()
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
            resetFullscreenLyricsBackgroundSnapshot()
            scheduleFullscreenLyricsBackgroundCapture()
            setupSeekCallback()
            syncLyricsColumnVisibility(animated: false)
            reloadLyricsSurface(
                reason: "fullscreen appear",
                forceWebReload: true,
                forceLyricsReload: true
            )
        }
        .onDisappear {
            lyricsVM.onSeekRequest = nil
            pendingFullscreenLyricsRefresh?.cancel()
            pendingFullscreenLyricsRefresh = nil
            pendingFullscreenLyricsReveal?.cancel()
            pendingFullscreenLyricsReveal = nil
            pendingFullscreenTrackRefresh?.cancel()
            pendingFullscreenTrackRefresh = nil
            deferredTrackUpdateDeadline = nil
            suppressFullscreenLyricsViewport = false
            clearFullscreenLyricsTheme()
        }
        .onChange(of: selectedSkinID) { _, _ in
            skinRevision &+= 1
        }
        .onChange(of: playerVM.currentTime, handleCurrentTimeChange)
        .onChange(of: playerVM.isPlaying) { _, newValue in
            lyricsVM.setPlaying(newValue)
        }
        .onChange(of: playerVM.currentTrack?.id, handleTrackIdChange)
        .onChange(of: hasLyricsForCurrentTrack) { _, _ in
            if syncLyricsColumnVisibility(animated: true) {
                deferredTrackUpdateDeadline = Date().addingTimeInterval(trackUpdateDeferralDuration)
            }
        }
        .onChange(of: fullscreenLyricsConfigSignature) { _, _ in
            applyFullscreenLyricsTheme()
        }
        .onChange(of: bkController.lyricsColorSampleRevision) { _, _ in
            guard pendingFullscreenLyricsBackgroundCapture else { return }
            scheduleFullscreenLyricsRefresh(preferLiveSurface: true)
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkSnapshot()
        }
    }

    // MARK: - Bottom Controls

    @State private var isVolumeExpanded = false
    private let fullscreenControlButtonSize: CGFloat = 60
    private let fullscreenControlSpacing: CGFloat = 20
    private let fullscreenControlsHorizontalPadding: CGFloat = 80
    private let fullscreenControlsBottomPadding: CGFloat = 72
    private let fullscreenMiniPlayerMaxWidth: CGFloat = 1200
    private let leadingControlsExpandedWidth: CGFloat = 180
    private let leadingControlsCollapsedWidth: CGFloat = 120
    private let volumeExpandedWidth: CGFloat = 180
    private let volumeCollapsedWidth: CGFloat = 60

    private func bottomControlsRow(windowSize: CGSize) -> some View {
        let buttonSize = fullscreenControlButtonSize
        let spacing = fullscreenControlSpacing
        let leadingControlsWidth =
            isLeadingControlsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth
        let leadingControlsExtraWidth = leadingControlsWidth - leadingControlsCollapsedWidth
        let volumeWidth = isVolumeExpanded ? volumeExpandedWidth : volumeCollapsedWidth
        let volumeExtraWidth = volumeWidth - volumeCollapsedWidth
        let leadingMiniPlayerOriginX = leadingControlsCollapsedWidth + spacing
        let fixedControlWidth = leadingControlsCollapsedWidth + spacing + spacing + volumeCollapsedWidth
        let availableGroupWidth = max(0, windowSize.width - fullscreenControlsHorizontalPadding * 2)
        let collapsedMiniPlayerWidth = max(
            0,
            min(availableGroupWidth - fixedControlWidth, fullscreenMiniPlayerMaxWidth)
        )
        let groupWidth = fixedControlWidth + collapsedMiniPlayerWidth
        let currentMiniPlayerWidth = max(
            0,
            collapsedMiniPlayerWidth - leadingControlsExtraWidth - volumeExtraWidth
        )
        let groupOriginX = max(0, (windowSize.width - groupWidth) * 0.5)
        let leadingControlsOriginX = groupOriginX
        let miniPlayerOriginX = groupOriginX + leadingMiniPlayerOriginX + leadingControlsExtraWidth
        let volumeOriginX = max(0, groupOriginX + groupWidth - volumeWidth)

        return ZStack(alignment: .leading) {
            leadingControlsPill(size: buttonSize)
                .frame(width: leadingControlsWidth, height: buttonSize)
                .offset(x: leadingControlsOriginX)

            FullscreenMiniPlayerView()
                .frame(width: currentMiniPlayerWidth, height: buttonSize)
                .offset(x: miniPlayerOriginX)

            ExpandableVolumeControl(
                volume: volumeBinding,
                isExpanded: $isVolumeExpanded
            )
            .frame(width: volumeWidth, height: buttonSize)
            .offset(x: volumeOriginX)
        }
        .frame(width: windowSize.width, height: buttonSize, alignment: .leading)
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

    // MARK: - Skin Artwork Area

    @ViewBuilder
    private func topContentArea(selectedSkin: any NowPlayingSkin, windowSize: CGSize) -> some View {
        let metrics = layoutMetrics(for: windowSize)
        let lyricsVisible = shouldShowLyricsColumn
        let artworkToCenterOffset = max(0, (windowSize.width - metrics.artworkWidth) * 0.5)
        let contentOffsetX = lyricsVisible ? -topContentLeftShift : artworkToCenterOffset
        let columnSpacing = lyricsVisible ? artworkLyricsColumnSpacing : 0

        HStack(spacing: columnSpacing) {
            skinArtworkArea(
                selectedSkin: selectedSkin,
                windowSize: windowSize,
                artworkColumnWidth: metrics.artworkWidth
            )
            .frame(width: metrics.artworkWidth)
            .frame(maxHeight: .infinity)

            lyricsArea
                .padding(.leading, lyricsVisible ? -lyricsColumnLeftNudge : 0)
                .frame(width: lyricsVisible ? metrics.lyricsWidth : 0, alignment: .leading)
                .opacity(lyricsVisible ? 1 : 0)
                .allowsHitTesting(lyricsVisible)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .offset(x: contentOffsetX)
        .animation(lyricsLayoutAnimation, value: lyricsVisible)
    }

    @ViewBuilder
    private func skinArtworkArea(
        selectedSkin: any NowPlayingSkin,
        windowSize: CGSize,
        artworkColumnWidth: CGFloat
    ) -> some View {
        let context = makeContext(windowSize: windowSize, artworkColumnWidth: artworkColumnWidth)

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

            AMLLWebView(store: lyricsVM.webViewStore, forcedAppearanceMode: .dark)
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

    private func leadingControlsPill(size: CGFloat) -> some View {
        HStack(spacing: 0) {
            leadingControlButton(help: "fullscreen.exit") {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(fullscreenMiniPlayerPrimaryColor)
                    .compositingGroup()
                    .blendMode(.screen)
            } action: {
                onExitFullscreen?()
            }

            appearanceSwitchButton(size: size)

            lyricsVisibilityButton(size: size)
                .opacity(isLeadingControlsExpanded ? 1 : 0)
                .allowsHitTesting(isLeadingControlsExpanded)
                .accessibilityHidden(!isLeadingControlsExpanded)
        }
        .frame(
            width: isLeadingControlsExpanded ? leadingControlsExpandedWidth : leadingControlsCollapsedWidth,
            height: size,
            alignment: .leading
        )
        .contentShape(Capsule())
        .liquidGlassPill(
            colorScheme: colorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            isFloating: true
        )
        .onHover { hovering in
            isLeadingControlsExpanded = hovering
        }
    }

    private func leadingControlButton<Label: View>(
        help: LocalizedStringKey,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: fullscreenControlButtonSize, height: fullscreenControlButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func appearanceSwitchButton(size: CGFloat) -> some View {
        let icon = effectiveFullscreenAppearance == .dark ? "moon" : "sun.max"
        let helpText: LocalizedStringKey =
            effectiveFullscreenAppearance == .dark ? "sidebar.appearance_dark" : "sidebar.appearance_light"

        return leadingControlButton(help: helpText) {
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
        let lyricsVisible = shouldShowLyricsColumn
        let icon = lyricsVisible ? "quote.bubble.fill" : "quote.bubble"
        let helpText: LocalizedStringKey = lyricsVisible ? "Hide Lyrics" : "Show Lyrics"
        let canToggle = hasLyricsForCurrentTrack

        return leadingControlButton(help: helpText) {
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
            toggleFullscreenLyricsVisibility()
        }
        .disabled(!canToggle)
    }

    // MARK: - Helpers

    private var shouldShowLyricsColumn: Bool {
        lyricsColumnVisible ?? desiredLyricsColumnVisibility
    }

    private var hasLyricsForCurrentTrack: Bool {
        hasLyrics(for: playerVM.currentTrack)
    }

    private var desiredLyricsColumnVisibility: Bool {
        hasLyricsForCurrentTrack && !isLyricsManuallyHidden
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
        ].joined(separator: "|")
    }

    private func setupSeekCallback() {
        lyricsVM.onSeekRequest = { seconds in
            playerVM.seek(to: seconds)
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

    private func toggleFullscreenLyricsVisibility() {
        guard hasLyricsForCurrentTrack else { return }
        isLyricsManuallyHidden.toggle()
        let didChangeLayout = syncLyricsColumnVisibility(animated: true)
        guard didChangeLayout else { return }
        deferredTrackUpdateDeadline = Date().addingTimeInterval(trackUpdateDeferralDuration)
        if !isLyricsManuallyHidden {
            suppressFullscreenLyricsViewport = false
            reloadLyricsSurface(reason: "fullscreen manual lyrics visibility toggled")
        }
    }

    private func handleCurrentTimeChange(_ oldTime: Double, _ newTime: Double) {
        lyricsVM.syncTime(newTime)

        if oldTime > 1.0, newTime < 0.2 {
            reloadLyricsSurface(reason: "fullscreen playback restarted", forceLyricsReload: true)
        }
    }

    private func handleTrackIdChange(_ oldId: UUID?, _ newId: UUID?) {
        guard oldId != newId else { return }
        let targetVisible = desiredLyricsColumnVisibility
        let currentVisible = lyricsColumnVisible ?? targetVisible
        let layoutWillChange = currentVisible != targetVisible
        let lyricsEntering = layoutWillChange && !currentVisible && targetVisible
        deferredTrackUpdateDeadline =
            layoutWillChange ? Date().addingTimeInterval(trackUpdateDeferralDuration) : nil
        pendingFullscreenLyricsReveal?.cancel()
        pendingFullscreenLyricsReveal = nil
        suppressFullscreenLyricsViewport = lyricsEntering
        resetFullscreenLyricsBackgroundSnapshot()
        scheduleFullscreenLyricsBackgroundCapture()
        scheduleFullscreenTrackRefresh(layoutWillChange: layoutWillChange, revealLyricsAfterRefresh: lyricsEntering)
    }

    private func reloadLyricsSurface(
        reason: String,
        forceWebReload: Bool = false,
        forceLyricsReload: Bool = false
    ) {
        lyricsVM.ensureAMLLLoaded(
            track: playerVM.currentTrack,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            reason: reason,
            forceWebReload: forceWebReload,
            forceLyricsReload: forceLyricsReload
        )
        if !pendingFullscreenLyricsBackgroundCapture {
            captureFullscreenLyricsBackgroundSnapshot()
        }
        applyFullscreenLyricsTheme()
    }

    @discardableResult
    private func syncLyricsColumnVisibility(animated: Bool) -> Bool {
        let targetVisible = desiredLyricsColumnVisibility
        let currentVisible = lyricsColumnVisible ?? targetVisible

        // Ensure state is initialized even when there's no visual change.
        if lyricsColumnVisible == nil {
            lyricsColumnVisible = targetVisible
            return false
        }

        guard currentVisible != targetVisible else { return false }

        if animated {
            withAnimation(lyricsLayoutAnimation) {
                lyricsColumnVisible = targetVisible
            }
        } else {
            lyricsColumnVisible = targetVisible
        }

        return true
    }

    private var trackUpdateDeferralDuration: TimeInterval {
        reduceMotion ? 0.20 : 0.34
    }

    private func currentTrackUpdateDeferral() -> TimeInterval {
        max(0, deferredTrackUpdateDeadline?.timeIntervalSinceNow ?? 0)
    }

    private var fullscreenLyricsRevealDelay: TimeInterval {
        reduceMotion ? 0.02 : 0.08
    }

    private var fullscreenLyricsViewportOpacity: Double {
        guard playerVM.currentTrack != nil else { return 0 }
        return suppressFullscreenLyricsViewport ? 0 : 1
    }

    private func scheduleFullscreenTrackRefresh(
        layoutWillChange: Bool,
        revealLyricsAfterRefresh: Bool
    ) {
        pendingFullscreenTrackRefresh?.cancel()
        pendingFullscreenLyricsReveal?.cancel()
        pendingFullscreenLyricsReveal = nil

        let delay = layoutWillChange ? max(trackUpdateDeferralDuration, currentTrackUpdateDeferral()) : 0
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
                    deadline: .now() + fullscreenLyricsRevealDelay,
                    execute: revealWorkItem
                )
            } else {
                suppressFullscreenLyricsViewport = false
            }
            pendingFullscreenTrackRefresh = nil
            if currentTrackUpdateDeferral() <= 0.01 {
                deferredTrackUpdateDeadline = nil
            }
        }

        pendingFullscreenTrackRefresh = workItem

        if delay <= 0 {
            workItem.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func applyFullscreenLyricsTheme() {
        let store = lyricsVM.webViewStore
        let surfaceRole = LyricsSurfaceRole.fullscreen
        let colorSet = makeFullscreenLyricsColorSet(for: playerVM.currentTrack)
        store.setThemePaletteOverride(makeFullscreenLyricsPalette(from: colorSet))
        let mainFontFamily = cssFontFamily([
            settings.fullscreenLyricsFontNameEn,
            settings.fullscreenLyricsFontNameZh,
        ])
        let translationFontFamily = cssFontFamily([
            settings.fullscreenLyricsTranslationFontName
        ])
        let mainActiveColor = ArtworkColorExtractor.cssRGBA(colorSet.mainActive, alpha: 1.0)
        let mainInactiveColor = ArtworkColorExtractor.cssRGBA(colorSet.mainInactive, alpha: 1.0)
        let subActiveColor = ArtworkColorExtractor.cssRGBA(colorSet.subActive, alpha: 1.0)
        let subInactiveColor = ArtworkColorExtractor.cssRGBA(colorSet.subInactive, alpha: 1.0)
        let lineTimingMainInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.lineTimingMainInactive,
            alpha: 1.0
        )
        let lineTimingSubInactiveColor = ArtworkColorExtractor.cssRGBA(
            colorSet.lineTimingSubInactive,
            alpha: 1.0
        )
        let backgroundColor = subActiveColor

        let config: [String: Any] = [
            "fontSize": settings.fullscreenLyricsFontSize,
            "fontWeight": max(100, min(900, settings.fullscreenLyricsFontWeight)),
            "fontFamilyMain": mainFontFamily,
            "fontFamilyTranslation": translationFontFamily,
            "translationFontSize": settings.fullscreenLyricsTranslationFontSize,
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
            "fullscreenLyricDodgeMode": true,
            "fullscreenActiveColor": mainActiveColor,
            "fullscreenInactiveColor": mainInactiveColor,
            "fullscreenSubActiveColor": subActiveColor,
            "fullscreenSubInactiveColor": subInactiveColor,
            "fullscreenBackgroundColor": backgroundColor,
            "fullscreenLineTimingInactiveColor": lineTimingMainInactiveColor,
            "fullscreenLineTimingSubInactiveColor": lineTimingSubInactiveColor,
            "alignAnchor": "top",
            "alignPosition": fullscreenLyricsAlignPosition,
            "lineHeight": 1.8,
            "activeScale": 1.2,
            "leadInMs": 180,
            "nearSwitchGapMs": 120,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config),
            let json = String(data: data, encoding: .utf8)
        {
            store.setConfigJSON(json)
        }
    }

    private func clearFullscreenLyricsTheme() {
        let store = lyricsVM.webViewStore
        store.setThemePaletteOverride(nil)
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

    private func scheduleFullscreenLyricsRefresh(preferLiveSurface: Bool) {
        pendingFullscreenLyricsRefresh?.cancel()

        let workItem = DispatchWorkItem { [preferLiveSurface] in
            captureFullscreenLyricsBackgroundSnapshot(preferLiveSurface: preferLiveSurface)
            applyFullscreenLyricsTheme()
            pendingFullscreenLyricsRefresh = nil
        }

        pendingFullscreenLyricsRefresh = workItem
        let delay = max(0.22, currentTrackUpdateDeferral())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeContext(windowSize: CGSize, artworkColumnWidth: CGFloat) -> SkinContext {
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
            audio: ledMeter.audioMetrics,
            led: ledMeter.metrics,
            theme: theme,
            windowSize: windowSize,
            contentBounds: contentBounds
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

    private func hasLyrics(for track: Track?) -> Bool {
        guard let track else { return false }

        let lyricsText = track.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lyricsText, !lyricsText.isEmpty {
            return true
        }

        let ttmlText = track.ttmlLyricText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ttmlText?.isEmpty == false
    }

    private func layoutMetrics(for windowSize: CGSize) -> (artworkWidth: CGFloat, lyricsWidth: CGFloat) {
        let availableWidth = max(0, windowSize.width - topContentHorizontalPadding * 2)

        if shouldShowLyricsColumn {
            let constrainedWidth = max(0, availableWidth - lyricsRightMarginReserve)
            let lyricsWidth = min(max(constrainedWidth * 0.30, 320), 560)
            let artworkWidth = max(constrainedWidth - lyricsWidth - artworkLyricsColumnSpacing, 360)
            return (artworkWidth, lyricsWidth)
        }

        let lyricsWidth = min(max(availableWidth * 0.35, 340), 580)
        let centeredArtworkWidth = min(max(availableWidth * 0.78, 420), availableWidth)
        return (centeredArtworkWidth, lyricsWidth)
    }

    private func fullscreenBackgroundAvoidanceRect(in windowSize: CGSize) -> CGRect? {
        guard shouldShowLyricsColumn else { return nil }

        let metrics = layoutMetrics(for: windowSize)
        let rectX =
            metrics.artworkWidth
            + artworkLyricsColumnSpacing
            - lyricsColumnLeftNudge
            - topContentLeftShift
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

    private func makeFullscreenLyricsPalette(from colors: FullscreenLyricsColorSet) -> ThemePalette {
        let active = ArtworkColorExtractor.cssRGBA(colors.mainActive, alpha: 1.0)
        let inactive = ArtworkColorExtractor.cssRGBA(colors.mainInactive, alpha: 1.0)

        return ThemePalette(
            scheme: .dark,
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
            max(highlightHSL.lightness + 0.12 - activeLightnessShift * 0.75, baseLightness + 0.12),
            min: max(0.72, fullscreenLyricsMinimumSubActiveLightness - activeLightnessShift * 0.9),
            max: max(0.82, fullscreenLyricsMaximumSubActiveLightness - activeLightnessShift * 0.75)
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

    private func resolveFullscreenLyricsBaseColor(for track: Track?) -> NSColor {
        if let accent = artworkSnapshot?.accentColor {
            return accent
        }
        if let base = artworkSnapshot?.averageColor {
            return base
        }

        return NSColor(AppSettings.shared.accentColor)
    }

    private func resolveFullscreenLyricsInactiveBaseColor(for track: Track?) -> NSColor {
        if let backgroundColor = lockedFullscreenLyricsBackgroundColor {
            return backgroundColor
        }

        if settings.nowPlayingArtBackgroundEnabled {
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
        
        let snapshot = await ArtworkAssetStore.shared.snapshot(trackID: track.id, artworkData: artworkData)
        guard !Task.isCancelled else { return }
        let deferral = currentTrackUpdateDeferral()
        if deferral > 0 {
            try? await Task.sleep(nanoseconds: UInt64(deferral * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        artworkSnapshot = snapshot
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

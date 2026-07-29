//
//  MiniPlayerView.swift
//  myPlayer2
//
//  kmgccc_player - Mini Player View
//  Uses native SwiftUI .glassEffect() for true macOS 26 Liquid Glass capsule.
//

import AppKit
import SwiftUI

/// Mini player bar with true Liquid Glass capsule effect.
/// Layout: Cover+Title | Controls | Playback Mode | Progress
struct MiniPlayerView: View {
    private static let appleMusicArtworkCacheTrackID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject private var fullscreenWindowManager = FullscreenWindowManager.shared

    @State private var settings = AppSettings.shared
    @State private var visualizationPreferences = AudioVisualizationPreferences.shared

    /// For drag-to-seek
    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var trackToEdit: Track?
    @State private var trackDeletionRequest: TrackDeletionConfirmationRequest?
    @State private var isProgressHovering = false
    @State private var previousSymbolEffectTrigger = 0
    @State private var playPauseSymbolEffectTrigger = 0
    @State private var nextSymbolEffectTrigger = 0
    @State private var artworkImage: NSImage?
    @State private var isPlaybackModeExpanded = false
    @State private var isShowingExternalMatchEditor = false
    @State private var showPlaybackModeRetapTip = false

    private var playbackModeExpandedWidth: CGFloat { 168 }
    private var playbackModeCollapsedWidth: CGFloat { 44 }
    private var playbackModeWidth: CGFloat {
        let expandedWidth = playbackCoordinator.presentation.source.isExternal ? 150 : playbackModeExpandedWidth
        return isPlaybackModeExpanded ? expandedWidth : playbackModeCollapsedWidth
    }
    private var layoutAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }
    private var trackInfoIdealWidth: CGFloat { 100 }
    private var trackInfoMinWidth: CGFloat { 32 }
    private var trackInfoMaxWidth: CGFloat { 136 }
    private var progressAreaMinWidth: CGFloat { 96 }

    var body: some View {
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.miniPlayerBodyUpdate",
            detail: "surface=MiniPlayerView, track=\(FirstUseHitchDiagnostics.trackIDPrefix(playbackCoordinator.presentation.localTrack?.id)), isPlaying=\(playbackCoordinator.presentation.isPlaying)"
        )
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
            // MARK: - Left: Cover enters embedded fullscreen player, text keeps library/now playing toggle
            MiniPlayerLeftSection(
                hasTrack: playbackCoordinator.presentation.hasTrack,
                isArtworkLoading: playbackCoordinator.presentation.isArtworkLoading,
                displayTitle: playbackCoordinator.presentation.title,
                displayArtist: playbackCoordinator.presentation.artist,
                emptyTitleKey: playbackCoordinator.presentation.emptyTitleKey,
                artworkImage: artworkImage,
                contextMenuRefreshTrigger: libraryVM.refreshTrigger,
                isFullscreenPresented: fullscreenWindowManager.isFullscreenPlayerPresented,
                isRefetchingLyrics: playbackCoordinator.presentation.isRefetchingLyrics,
                textForegroundProfile: miniPlayerTextForegroundProfile,
                trackToEdit: $trackToEdit,
                isShowingExternalMatchEditor: $isShowingExternalMatchEditor,
                onDeleteTrack: { track in
                    trackDeletionRequest = TrackDeletionConfirmationRequest(tracks: [track])
                },
                onFullscreen: { fullscreenWindowManager.showFullscreenPlayerInWindow() },
                onToggleNowPlaying: {
                    if uiState.contentMode == .nowPlaying {
                        uiState.returnToLibraryFromNowPlaying()
                    } else {
                        uiState.showNowPlaying()
                    }
                }
            )
            .equatable()
            .layoutPriority(1)

            // MARK: - Controls
            controlsView
                .layoutPriority(2)

            // MARK: - Playback Mode
            playbackModeView
                .frame(width: playbackModeWidth, height: 24)
                .popover(
                    isPresented: $showPlaybackModeRetapTip,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    PlaybackModeRetapTipView(
                        onClose: dismissPlaybackModeRetapTip,
                        usesStandaloneBackground: false
                    )
                }
                .layoutPriority(2)

            // MARK: - Progress bar (draggable + hover time labels)
            progressArea
                .frame(minWidth: progressAreaMinWidth, maxWidth: .infinity)
                .layoutPriority(0)

            // MARK: - Right: Volume Slider
            volumeView
                .layoutPriority(2)
        }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(height: GlassStyleTokens.miniPlayerHeight)
            .liquidGlassPill(
                colorScheme: colorScheme,
                accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
                prominence: .prominent,
                materialStyle: .regular,
                isFloating: true
            )
            .contentShape(Capsule())
            .onTapGesture {}
        }
        .animation(layoutAnimation, value: isPlaybackModeExpanded)
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $isShowingExternalMatchEditor) {
            ExternalPlaybackInfoEditorView(
                presentation: playbackCoordinator.presentation,
                metadataStore: cacheServices.externalPlaybackMetadataStore,
                onSaved: { onlyOffsetChanged in
                    playbackCoordinator.invalidateExternalPlaybackResolution(onlyOffsetChanged: onlyOffsetChanged)
                }
            )
            .environmentObject(themeStore)
        }
        .trackDeletionConfirmation(item: $trackDeletionRequest) { tracks in
            Task {
                await libraryVM.deleteTracks(tracks)
            }
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkThumbnail()
        }
        .task(id: playbackModeRetapTipTaskID) {
            await schedulePlaybackModeRetapTipIfNeeded()
        }
        .onDisappear {
            guard showPlaybackModeRetapTip else { return }
            AppVersionGate.shared.markPlaybackModeRetapFeatureTipDismissed()
            showPlaybackModeRetapTip = false
        }
        .onChange(of: showPlaybackModeRetapTip) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            AppVersionGate.shared.markPlaybackModeRetapFeatureTipDismissed()
        }
    }

    // MARK: - Subviews

    private var controlsView: some View {
        let presentation = playbackCoordinator.presentation
        let isEnabled = presentation.isControlEnabled
        let isTrackControlEnabled = isEnabled && presentation.hasTrack
        return HStack(spacing: 14) {
            // Previous
            Button {
                previousSymbolEffectTrigger += 1
                playbackCoordinator.previous()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .foregroundStyle(isTrackControlEnabled ? controlPrimaryColor : controlDisabledColor)
                        .symbolEffect(.wiggle, value: previousSymbolEffectTrigger)
                }
                .frame(width: controlHitSize, height: controlHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
            .disabled(!isTrackControlEnabled)

            // Play/Pause
            Button {
                playPauseSymbolEffectTrigger += 1
                playbackCoordinator.playPause()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: presentation.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                        .symbolEffect(.bounce, value: playPauseSymbolEffectTrigger)
                }
                .frame(width: controlHitSize, height: controlHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
            .disabled(!isEnabled)

            // Next
            Button {
                nextSymbolEffectTrigger += 1
                playbackCoordinator.next()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .foregroundStyle(isTrackControlEnabled ? controlPrimaryColor : controlDisabledColor)
                        .symbolEffect(.wiggle, value: nextSymbolEffectTrigger)
                }
                .frame(width: controlHitSize, height: controlHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
            .disabled(!isTrackControlEnabled)
        }
    }

    private var controlHitSize: CGFloat { 26 }

    private var currentPlaybackMode: PlaybackOrderMode {
        playbackCoordinator.presentation.localPlaybackOrderMode ?? settings.playbackOrderMode
    }

    private var playbackModeView: some View {
        let presentation = playbackCoordinator.presentation
        let isEnabled = presentation.isPlaybackModeControlEnabled && presentation.hasTrack
        return Group {
            switch presentation.source {
            case .local:
                PlaybackModeSlider(
                    mode: currentPlaybackMode,
                    isEnabled: isEnabled,
                    isExpanded: isPlaybackModeExpanded,
                    selectedColor: controlPrimaryColor,
                    unselectedColor: controlPrimaryColor.opacity(0.62),
                    pillTintColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
                    scale: 0.75,
                    onModeChange: { mode in
                        uiState.hideWindowPlaybackQueue()
                        playbackCoordinator.setPlaybackOrderMode(mode)
                    },
                    onCurrentModeRetap: handleCurrentPlaybackModeRetap
                )
            case .appleMusic, .systemNowPlaying:
                AppleMusicPlaybackModeSlider(
                    mode: presentation.appleMusicPlaybackMode ?? .sequence,
                    isEnabled: isEnabled,
                    isExpanded: isPlaybackModeExpanded,
                    selectedColor: controlPrimaryColor,
                    unselectedColor: controlPrimaryColor.opacity(0.62),
                    pillTintColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
                    scale: 0.75,
                    onModeChange: { mode in
                        uiState.hideWindowPlaybackQueue()
                        playbackCoordinator.setAppleMusicPlaybackMode(mode)
                    }
                )
            }
        }
        .contentShape(Capsule())
        .onHover { hovering in
            guard isEnabled else {
                if isPlaybackModeExpanded {
                    isPlaybackModeExpanded = false
                }
                return
            }
            withAnimation(layoutAnimation) {
                isPlaybackModeExpanded = hovering
            }
        }
    }

    private func handleCurrentPlaybackModeRetap(_ currentMode: PlaybackOrderMode) {
        guard currentMode == currentPlaybackMode else { return }

        if uiState.isWindowPlaybackQueueVisible {
            uiState.hideWindowPlaybackQueue()
        } else {
            AppKitMainSplitWindowController.setLyricsVisible(true, animated: true)
            uiState.lyricsVisible = true
            uiState.showWindowPlaybackQueue()
        }
    }

    private var playbackModeRetapTipTaskID: String {
        let presentation = playbackCoordinator.presentation
        guard !fullscreenWindowManager.isFullscreenPlayerPresented,
              presentation.source == .local,
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
              showPlaybackModeRetapTip == false,
              AppVersionGate.shared.claimPlaybackModeRetapFeatureTipDisplay()
        else { return }

        withAnimation(layoutAnimation) {
            showPlaybackModeRetapTip = true
        }
    }

    private func dismissPlaybackModeRetapTip() {
        AppVersionGate.shared.markPlaybackModeRetapFeatureTipDismissed()
        withAnimation(layoutAnimation) {
            showPlaybackModeRetapTip = false
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            let barHeight: CGFloat = 5
            let fill = progressFillColor
            let track = progressTrackColor
            let isSeekEnabled = playbackCoordinator.presentation.isSeekEnabled

            ZStack {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(track)
                        .frame(height: barHeight)

                    Capsule()
                        .fill(fill)
                        .frame(width: progressWidth(in: geometry.size.width), height: barHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSeekEnabled else { return }
                        isDragging = true
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        dragProgress = progress * playbackCoordinator.presentation.duration
                    }
                    .onEnded { value in
                        guard isSeekEnabled else {
                            isDragging = false
                            return
                        }
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        let seekTime = progress * playbackCoordinator.presentation.duration
                        playbackCoordinator.seek(to: seekTime)
                        isDragging = false
                    }
            )
        }
        .frame(height: 18)
        .opacity(playbackCoordinator.presentation.isSeekEnabled ? 1 : 0.55)
    }

    private var progressArea: some View {
        MiniPlayerProgressSpectrumRow(
            scale: 0.66,
            visualization: windowMiniPlayerVisualization,
            isPlaying: playbackCoordinator.presentation.isPlaying,
            accentColor: themeStore.usesFallbackThemeColor ? nil : themeStore.accentColor,
            foregroundColor: controlPrimaryColor,
            enforceBrightForeground: false,
            spectrumUsesDarkForeground: colorScheme == .light,
            ledToneVariant: settings.selectedNowPlayingSkinID == AppleStyleSkin.skinID
                ? .appleStyleBright
                : .miniPlayer,
            adaptsWideVisualizationSegments: true,
            usesVisualizationAsCompactProgress: true,
            progress: progressDisplayTime,
            duration: playbackCoordinator.presentation.duration,
            isSeekEnabled: playbackCoordinator.presentation.isSeekEnabled,
            onSeek: { dragProgress = $0 },
            onDragStart: { isDragging = true },
            onDragEnd: {
                playbackCoordinator.seek(to: dragProgress)
                isDragging = false
            }
        )
        .frame(height: 34)
    }

    private var windowMiniPlayerVisualization: AudioVisualizationKind {
        visualizationPreferences.selection(
            for: settings.selectedNowPlayingSkinID,
            scope: .window
        ).miniPlayerKind
    }

    private var progressDisplayTime: Double {
        isDragging ? dragProgress : playbackCoordinator.presentation.currentTime
    }
    
    private var currentArtworkTaskKey: String {
        let presentation = playbackCoordinator.presentation
        // Local-track artwork source shortcut is local-playback only; for
        // external playback the provider-resolved `artworkData` is authoritative.
        if presentation.source == .local,
           let source = presentation.localTrack?.trackArtworkSource(fallbackData: presentation.artworkData) {
            return "local-\(source.sourceKey)-thumb"
        }
        let identity = presentation.artworkIdentity
            ?? presentation.lyricsIdentity
            ?? presentation.localTrack?.id.uuidString
            ?? "none"
        return "\(identity)-\(ArtworkDataFingerprint.sampledString(for: presentation.artworkData))"
    }

    private func loadArtworkThumbnail() async {
        let presentation = playbackCoordinator.presentation
        if presentation.source == .local,
           let source = presentation.localTrack?.trackArtworkSource(fallbackData: presentation.artworkData) {
            let image = await cacheServices.trackArtworkCache.thumbnail(for: source)
            guard !Task.isCancelled else { return }
            if let image {
                artworkImage = image
            } else if !presentation.isArtworkLoading {
                artworkImage = nil
            }
            return
        }

        guard
            let artworkData = presentation.artworkData,
            !artworkData.isEmpty
        else {
            if !presentation.hasTrack || !presentation.isArtworkLoading {
                artworkImage = nil
            }
            return
        }
        
        let snapshot = await ArtworkAssetStore.shared.snapshotMetadata(
            trackID: presentation.artworkDisplayTrackID
                ?? presentation.displayTrackID
                ?? presentation.localTrack?.id
                ?? Self.appleMusicArtworkCacheTrackID,
            artworkData: artworkData
        )
        guard !Task.isCancelled else { return }
        if let image = snapshot?.thumbnailImage ?? snapshot?.fullImage {
            artworkImage = image
        } else if !presentation.isArtworkLoading {
            artworkImage = nil
        }
    }

    private var progressFillColor: Color {
        controlPrimaryColor.opacity(0.88)
    }

    private var progressTrackColor: Color {
        controlPrimaryColor.opacity(colorScheme == .dark ? 0.24 : 0.18)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        let presentation = playbackCoordinator.presentation
        guard presentation.duration > 0 else { return 0 }
        let time = isDragging ? dragProgress : presentation.currentTime
        let progress = time / presentation.duration
        return totalWidth * CGFloat(max(0, min(1, progress)))
    }

    private var volumeView: some View {
        let isEnabled = playbackCoordinator.presentation.isVolumeControlEnabled
        return HStack(spacing: 6) {
            Button(action: toggleMute) {
                Image(systemName: volumeIcon)
                    .font(.caption)
                    .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.4))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(volume == 0 ? "Unmute" : "Mute")

            VolumeSlider(
                volume: Binding(
                    get: { playbackCoordinator.presentation.volume },
                    set: { playbackCoordinator.setVolume($0) }
                ),
                markerColor: themeStore.accentColor.opacity(0.85),
                hidesMarkerAtDefault: true
            )
            .frame(width: 80)
            .controlSize(.small)
            .tint(themeStore.accentColor)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
        }
    }

    private var volume: Double {
        playbackCoordinator.presentation.volume
    }

    private func toggleMute() {
        guard playbackCoordinator.presentation.isVolumeControlEnabled else { return }
        playbackCoordinator.setVolume(VolumeControlBehavior.volumeAfterMuteToggle(volume))
    }

    private var volumeIcon: String {
        let volume = playbackCoordinator.presentation.volume
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var controlPrimaryColor: Color {
        let base = themeStore.accentNSColor
        let tuned = AccentColorPolicy.productionMiniPlayerControlColor(
            base: base,
            scheme: colorScheme
        )
        return ColorRenderingAdapter.makeSwiftUIColor(tuned).opacity(colorScheme == .dark ? 0.98 : 0.92)
    }

    private var controlDisabledColor: Color {
        Color.secondary.opacity(0.5)
    }

    private var miniPlayerTextForegroundProfile: PlusBlendTextForegroundProfile {
        themeStore.plusBlendTextPalette.profile(
            for: colorScheme == .dark
                ? .lightOnDarkBackground
                : .darkOnLightBackground
        )
    }
}

// MARK: - Left section (isolated from high-frequency presentation ticks)

private struct MiniPlayerLeftSection: View, Equatable {

    let hasTrack: Bool
    let isArtworkLoading: Bool
    let displayTitle: String
    let displayArtist: String
    let emptyTitleKey: String
    let artworkImage: NSImage?
    let contextMenuRefreshTrigger: Int
    let isFullscreenPresented: Bool
    let isRefetchingLyrics: Bool
    let textForegroundProfile: PlusBlendTextForegroundProfile

    @Binding var trackToEdit: Track?
    @Binding var isShowingExternalMatchEditor: Bool

    let onDeleteTrack: (Track) -> Void
    let onFullscreen: () -> Void
    let onToggleNowPlaying: () -> Void

    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    @State private var isArtworkHovering = false

    private var trackInfoMinWidth: CGFloat { 32 }
    private var trackInfoIdealWidth: CGFloat { 100 }
    private var trackInfoMaxWidth: CGFloat { 136 }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasTrack == rhs.hasTrack
            && lhs.isArtworkLoading == rhs.isArtworkLoading
            && lhs.displayTitle == rhs.displayTitle
            && lhs.displayArtist == rhs.displayArtist
            && lhs.emptyTitleKey == rhs.emptyTitleKey
            && lhs.artworkImage === rhs.artworkImage
            && lhs.contextMenuRefreshTrigger == rhs.contextMenuRefreshTrigger
            && lhs.isFullscreenPresented == rhs.isFullscreenPresented
            && lhs.isRefetchingLyrics == rhs.isRefetchingLyrics
            && lhs.textForegroundProfile == rhs.textForegroundProfile
    }

    var body: some View {
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.miniPlayerBodyUpdate",
            detail: "surface=MiniPlayerLeftSection"
        )
        HStack(spacing: 10) {
            Button { onFullscreen() } label: {
                artworkButtonContent
            }
            .buttonStyle(.plain)
            .disabled(!hasTrack || isFullscreenPresented)

            Button { onToggleNowPlaying() } label: {
                trackInfoContainer
                    .frame(height: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(
                minWidth: trackInfoMinWidth,
                idealWidth: trackInfoIdealWidth,
                maxWidth: trackInfoMaxWidth,
                minHeight: 36,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .offset(x: 4, y: 0)
        .contextMenu {
            // Closure is lazy — evaluated only when NSMenu appears, not during body computation.
            nowPlayingInfoContextMenu
        }
    }

    @ViewBuilder
    private var artworkButtonContent: some View {
        let isEnabled = hasTrack && !isFullscreenPresented
        ZStack {
            artworkView

            if isArtworkHovering && isEnabled {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.95))
                    )
                    .transition(.opacity)
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            isArtworkHovering = hovering && isEnabled
        }
        .animation(.easeOut(duration: 0.15), value: isArtworkHovering)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if isArtworkLoading {
            ZStack {
                ArtworkPlaceholderView.miniPlayer()
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            }
            .frame(width: 36, height: 36)
        } else {
            ArtworkPlaceholderView.miniPlayer()
        }
    }

    @ViewBuilder
    private var trackInfoContainer: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                if hasTrack {
                    SeamlessMarqueeText(
                        text: displayTitle,
                        style: .subheadline,
                        fontWeight: .medium,
                        color: textForegroundProfile.primaryColor,
                        enablesContentTransition: true
                    )
                    .compositingGroup()
                    .blendMode(textForegroundProfile.blendMode)

                    SeamlessMarqueeText(
                        text: displayArtist.isEmpty
                            ? NSLocalizedString("library.unknown_artist", comment: "")
                            : displayArtist,
                        style: .caption,
                        fontWeight: .regular,
                        color: textForegroundProfile.secondaryColor,
                        enablesContentTransition: true
                    )
                    .compositingGroup()
                    .blendMode(textForegroundProfile.blendMode)
                } else {
                    Text(LocalizedStringKey(emptyTitleKey))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, isRefetchingLyrics ? 20 : 0)

            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
                .opacity(isRefetchingLyrics ? 1 : 0)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(
            minWidth: trackInfoMinWidth,
            idealWidth: trackInfoIdealWidth,
            maxWidth: trackInfoMaxWidth,
            alignment: .leading
        )
        .clipped()
        .animation(.easeInOut(duration: 0.15), value: isRefetchingLyrics)
    }

    @ViewBuilder
    private var nowPlayingInfoContextMenu: some View {
        let token = ContextMenuDiagnostics.beginBuild(
            surface: "MiniPlayerContextMenu",
            detail: "surface=window, track=\(FirstUseHitchDiagnostics.trackIDPrefix(playbackCoordinator.presentation.localTrack?.id))"
        )
        let _ = ContextMenuDiagnostics.end(token)
        let presentation = playbackCoordinator.presentation
        if let track = presentation.localTrack {
            TrackActionMenuContent(
                track: track,
                onPlay: {
                    playbackCoordinator.play(track: track)
                },
                onEditTrack: { t in
                    trackToEdit = t
                },
                onDeleteFromLibraryRequest: onDeleteTrack,
                showsPlay: false,
                diagnosticSurface: "MiniPlayerContextMenu"
            )
            Divider()
            MiniPlayerRefetchLyricsButton()
            if presentation.source.isExternal, presentation.externalStableKey != nil {
                Button {
                    let actionToken = ContextMenuDiagnostics.beginActionInvoke(
                        surface: "MiniPlayerContextMenu",
                        detail: "action=editExternalInfo, surface=window"
                    )
                    isShowingExternalMatchEditor = true
                    ContextMenuDiagnostics.end(actionToken)
                } label: {
                    Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
                }
            }
        } else if presentation.source.isExternal, presentation.externalStableKey != nil {
            MiniPlayerRefetchLyricsButton()
            Divider()
            Button {
                let actionToken = ContextMenuDiagnostics.beginActionInvoke(
                    surface: "MiniPlayerContextMenu",
                    detail: "action=editExternalInfo, surface=window"
                )
                isShowingExternalMatchEditor = true
                ContextMenuDiagnostics.end(actionToken)
            } label: {
                Label("编辑外部播放覆盖信息", systemImage: "slider.horizontal.3")
            }
        }
    }
}

// Playback mode slider shared with FullscreenMiniPlayerView
struct PlaybackModeSlider: View {
    let mode: PlaybackOrderMode
    let isEnabled: Bool
    let isExpanded: Bool
    let iconSize: CGFloat
    let selectedColor: Color
    let unselectedColor: Color
    let useScreenBlend: Bool
    let pillTintColor: Color?
    let pillTintBlendMode: BlendMode?
    let onModeChange: (PlaybackOrderMode) -> Void
    let onCurrentModeRetap: (PlaybackOrderMode) -> Void
    let onInteraction: (() -> Void)?
    let scale: CGFloat

    init(
        mode: PlaybackOrderMode,
        isEnabled: Bool,
        isExpanded: Bool = true,
        iconSize: CGFloat = 12,
        selectedColor: Color = .primary,
        unselectedColor: Color = .secondary,
        useScreenBlend: Bool = false,
        pillTintColor: Color? = nil,
        pillTintBlendMode: BlendMode? = nil,
        onInteraction: (() -> Void)? = nil,
        scale: CGFloat = 1.0,
        onModeChange: @escaping (PlaybackOrderMode) -> Void,
        onCurrentModeRetap: @escaping (PlaybackOrderMode) -> Void = { _ in }
    ) {
        self.mode = mode
        self.isEnabled = isEnabled
        self.isExpanded = isExpanded
        self.iconSize = iconSize
        self.selectedColor = selectedColor
        self.unselectedColor = unselectedColor
        self.useScreenBlend = useScreenBlend
        self.pillTintColor = pillTintColor
        self.pillTintBlendMode = pillTintBlendMode
        self.onInteraction = onInteraction
        self.scale = scale
        self.onModeChange = onModeChange
        self.onCurrentModeRetap = onCurrentModeRetap
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var animatedModeIndex: Int?
    @State private var modeAnimationTrigger = 0

    private var modeIndex: Int {
        switch mode {
        case .shuffle: return 0
        case .sequence: return 1
        case .repeatOne: return 2
        case .stopAfterTrack: return 3
        }
    }

    private func index(for mode: PlaybackOrderMode) -> Int {
        switch mode {
        case .shuffle: return 0
        case .sequence: return 1
        case .repeatOne: return 2
        case .stopAfterTrack: return 3
        }
    }

    private func modeForIndex(_ index: Int) -> PlaybackOrderMode {
        switch index {
        case 0: return .shuffle
        case 1: return .sequence
        case 2: return .repeatOne
        default: return .stopAfterTrack
        }
    }

    private var visibleModes: [PlaybackOrderMode] {
        if isExpanded {
            return [.shuffle, .sequence, .repeatOne, .stopAfterTrack]
        }
        return [mode]
    }

    private func symbol(for mode: PlaybackOrderMode) -> String {
        switch mode {
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

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 2 * scale
            let totalWidth = geometry.size.width - inset * 2
            let segmentCount = max(1, visibleModes.count)
            let segmentWidth = max(1, totalWidth / CGFloat(segmentCount))
            let baseOffset = isExpanded ? CGFloat(modeIndex) * segmentWidth : 0
            let effectiveDrag = (isDragging && isExpanded) ? dragTranslation : 0
            let knobOffset = clampOffset(baseOffset + effectiveDrag, maxValue: totalWidth - segmentWidth)
            let snap = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .overlay(Capsule().stroke(trackBorder, lineWidth: 1 * scale))
                    .compositingGroup()
                    .blendMode(pillTintBlendMode ?? .normal)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(knobFill)
                    .overlay(Capsule().stroke(knobBorder, lineWidth: 1 * scale))
                    .compositingGroup()
                    .blendMode(pillTintBlendMode ?? .normal)
                    .frame(width: segmentWidth, height: geometry.size.height - inset * 2)
                    .offset(x: knobOffset + inset)
                    .allowsHitTesting(false)
                    .animation((reduceMotion || isDragging) ? .none : snap, value: modeIndex)
                    .animation((reduceMotion || isDragging) ? .none : snap, value: isExpanded)

                HStack(spacing: 0) {
                    ForEach(Array(visibleModes.enumerated()), id: \.offset) { pair in
                        let modeValue = pair.element
                        segmentButton(
                            systemImage: symbol(for: modeValue),
                            mode: modeValue,
                            isSelected: mode == modeValue,
                            width: segmentWidth,
                            snap: snap
                        )
                    }
                }
                .padding(.horizontal, inset)
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isExpanded else { return }
                        onInteraction?()
                        isDragging = true
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        guard isExpanded else { return }
                        onInteraction?()
                        let raw = baseOffset + value.translation.width
                        let index = Int(round(raw / segmentWidth))
                        let clampedIndex = max(0, min(3, index))
                        let targetMode = modeForIndex(clampedIndex)
                        finishDrag(at: targetMode, snap: snap)
                    }
            )
        }
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .onChange(of: modeIndex) { oldValue, newValue in
            guard oldValue != newValue else { return }
            animatedModeIndex = newValue
            DispatchQueue.main.async {
                modeAnimationTrigger += 1
            }
        }
    }

    private func commitModeChange(_ newMode: PlaybackOrderMode, snap: Animation) {
        onInteraction?()
        if reduceMotion {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                onModeChange(newMode)
            }
        } else {
            withAnimation(snap) {
                onModeChange(newMode)
            }
        }
    }

    /// Finish a drag in one transaction so the knob animates directly from
    /// the release position to the selected segment. Resetting the drag state
    /// before changing `mode` makes the knob briefly jump back to its old
    /// segment before the mode animation starts.
    private func finishDrag(at newMode: PlaybackOrderMode, snap: Animation) {
        if newMode != mode {
            // Keep the existing interaction pulse for a drag that commits a
            // new mode; `onEnded` already emitted the first interaction event.
            onInteraction?()
        }

        let update = {
            dragTranslation = 0
            isDragging = false
            if newMode != mode {
                onModeChange(newMode)
            }
        }

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            withAnimation(snap, update)
        }
    }

    private func handleSegmentTap(_ tappedMode: PlaybackOrderMode, snap: Animation) {
        if tappedMode == mode {
            onInteraction?()
            onCurrentModeRetap(tappedMode)
            return
        }

        commitModeChange(tappedMode, snap: snap)
    }

    private func segmentButton(
        systemImage: String,
        mode: PlaybackOrderMode,
        isSelected: Bool,
        width: CGFloat,
        snap: Animation
    ) -> some View {
        Button {
            handleSegmentTap(mode, snap: snap)
        } label: {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                segmentIcon(systemImage: systemImage, index: index(for: mode), isSelected: isSelected)
            }
            .frame(width: width, height: 28 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 28 * scale)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func segmentIcon(systemImage: String, index: Int, isSelected: Bool) -> some View {
        let icon = Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(isSelected ? selectedColor : unselectedColor)

        if isSelected, animatedModeIndex == index {
            if useScreenBlend {
                icon
                    .symbolEffect(.bounce, value: modeAnimationTrigger)
                    .compositingGroup()
                    .blendMode(.screen)
            } else {
                icon.symbolEffect(.bounce, value: modeAnimationTrigger)
            }
        } else {
            if useScreenBlend {
                icon
                    .compositingGroup()
                    .blendMode(.screen)
            } else {
                icon
            }
        }
    }

    private var trackFill: Color {
        if let pillTintColor {
            return pillTintColor.opacity(0.12)
        }
        return Color.secondary.opacity(0.2)
    }

    private var trackBorder: Color {
        selectedColor.opacity(0.16)
    }

    private var knobFill: Color {
        if let pillTintColor {
            return pillTintColor.opacity(0.24)
        }
        return Color.primary.opacity(0.2)
    }

    private var knobBorder: Color {
        selectedColor.opacity(0.24)
    }

    private func clampOffset(_ value: CGFloat, maxValue: CGFloat) -> CGFloat {
        min(max(0, value), maxValue)
    }
}

struct AppleMusicPlaybackModeSlider: View {
    let mode: AppleMusicPlaybackMode
    let isEnabled: Bool
    let isExpanded: Bool
    let iconSize: CGFloat
    let selectedColor: Color
    let unselectedColor: Color
    let useScreenBlend: Bool
    let pillTintColor: Color?
    let pillTintBlendMode: BlendMode?
    let onInteraction: (() -> Void)?
    let scale: CGFloat
    let onModeChange: (AppleMusicPlaybackMode) -> Void

    init(
        mode: AppleMusicPlaybackMode,
        isEnabled: Bool,
        isExpanded: Bool = true,
        iconSize: CGFloat = 12,
        selectedColor: Color = .primary,
        unselectedColor: Color = .secondary,
        useScreenBlend: Bool = false,
        pillTintColor: Color? = nil,
        pillTintBlendMode: BlendMode? = nil,
        onInteraction: (() -> Void)? = nil,
        scale: CGFloat = 1.0,
        onModeChange: @escaping (AppleMusicPlaybackMode) -> Void
    ) {
        self.mode = mode
        self.isEnabled = isEnabled
        self.isExpanded = isExpanded
        self.iconSize = iconSize
        self.selectedColor = selectedColor
        self.unselectedColor = unselectedColor
        self.useScreenBlend = useScreenBlend
        self.pillTintColor = pillTintColor
        self.pillTintBlendMode = pillTintBlendMode
        self.onInteraction = onInteraction
        self.scale = scale
        self.onModeChange = onModeChange
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var animatedMode: AppleMusicPlaybackMode?
    @State private var modeAnimationTrigger = 0

    private var modeIndex: Int {
        index(for: mode)
    }

    private var visibleModes: [AppleMusicPlaybackMode] {
        isExpanded ? AppleMusicPlaybackMode.allCases : [mode]
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 2 * scale
            let totalWidth = geometry.size.width - inset * 2
            let segmentCount = max(1, visibleModes.count)
            let segmentWidth = max(1, totalWidth / CGFloat(segmentCount))
            let baseOffset = isExpanded ? CGFloat(modeIndex) * segmentWidth : 0
            let effectiveDrag = (isDragging && isExpanded) ? dragTranslation : 0
            let knobOffset = clampOffset(baseOffset + effectiveDrag, maxValue: totalWidth - segmentWidth)
            let snap = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .overlay(Capsule().stroke(trackBorder, lineWidth: 1 * scale))
                    .compositingGroup()
                    .blendMode(pillTintBlendMode ?? .normal)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(knobFill)
                    .overlay(Capsule().stroke(knobBorder, lineWidth: 1 * scale))
                    .compositingGroup()
                    .blendMode(pillTintBlendMode ?? .normal)
                    .frame(width: segmentWidth, height: geometry.size.height - inset * 2)
                    .offset(x: knobOffset + inset)
                    .allowsHitTesting(false)
                    .animation((reduceMotion || isDragging) ? .none : snap, value: modeIndex)
                    .animation((reduceMotion || isDragging) ? .none : snap, value: isExpanded)

                HStack(spacing: 0) {
                    ForEach(Array(visibleModes.enumerated()), id: \.offset) { pair in
                        let modeValue = pair.element
                        segmentButton(
                            systemImage: symbol(for: modeValue),
                            mode: modeValue,
                            isSelected: mode == modeValue,
                            width: segmentWidth,
                            snap: snap
                        )
                    }
                }
                .padding(.horizontal, inset)
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isExpanded else { return }
                        onInteraction?()
                        isDragging = true
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        guard isExpanded else { return }
                        onInteraction?()
                        let raw = baseOffset + value.translation.width
                        let index = Int(round(raw / segmentWidth))
                        dragTranslation = 0
                        isDragging = false
                        let clampedIndex = max(0, min(AppleMusicPlaybackMode.allCases.count - 1, index))
                        let targetMode = modeForIndex(clampedIndex)
                        guard targetMode != mode else { return }
                        commitModeChange(targetMode, snap: snap)
                    }
            )
        }
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .onChange(of: mode) { oldValue, newValue in
            guard oldValue != newValue else { return }
            animatedMode = newValue
            DispatchQueue.main.async {
                modeAnimationTrigger += 1
            }
        }
    }

    private func commitModeChange(_ newMode: AppleMusicPlaybackMode, snap: Animation) {
        onInteraction?()
        if reduceMotion {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                onModeChange(newMode)
            }
        } else {
            withAnimation(snap) {
                onModeChange(newMode)
            }
        }
    }

    private func handleSegmentTap(_ tappedMode: AppleMusicPlaybackMode, snap: Animation) {
        onInteraction?()
        guard tappedMode != mode else { return }
        commitModeChange(tappedMode, snap: snap)
    }

    private func segmentButton(
        systemImage: String,
        mode: AppleMusicPlaybackMode,
        isSelected: Bool,
        width: CGFloat,
        snap: Animation
    ) -> some View {
        Button {
            handleSegmentTap(mode, snap: snap)
        } label: {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                segmentIcon(systemImage: systemImage, mode: mode, isSelected: isSelected)
            }
            .frame(width: width, height: 28 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 28 * scale)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func segmentIcon(
        systemImage: String,
        mode: AppleMusicPlaybackMode,
        isSelected: Bool
    ) -> some View {
        let icon = Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(isSelected ? selectedColor : unselectedColor)

        if isSelected, animatedMode == mode {
            if useScreenBlend {
                icon
                    .symbolEffect(.bounce, value: modeAnimationTrigger)
                    .compositingGroup()
                    .blendMode(.screen)
            } else {
                icon.symbolEffect(.bounce, value: modeAnimationTrigger)
            }
        } else {
            if useScreenBlend {
                icon
                    .compositingGroup()
                    .blendMode(.screen)
            } else {
                icon
            }
        }
    }

    private func symbol(for mode: AppleMusicPlaybackMode) -> String {
        switch mode {
        case .sequence:
            return "list.bullet"
        case .shuffle:
            return "shuffle"
        case .repeatAll:
            return "repeat"
        case .repeatOne:
            return "repeat.1"
        }
    }

    private func index(for mode: AppleMusicPlaybackMode) -> Int {
        switch mode {
        case .sequence: return 0
        case .shuffle: return 1
        case .repeatAll: return 2
        case .repeatOne: return 3
        }
    }

    private func modeForIndex(_ index: Int) -> AppleMusicPlaybackMode {
        switch index {
        case 0: return .sequence
        case 1: return .shuffle
        case 2: return .repeatAll
        default: return .repeatOne
        }
    }

    private var trackFill: Color {
        if let pillTintColor {
            return pillTintColor.opacity(0.12)
        }
        return Color.secondary.opacity(0.2)
    }

    private var trackBorder: Color {
        selectedColor.opacity(0.16)
    }

    private var knobFill: Color {
        if let pillTintColor {
            return pillTintColor.opacity(0.24)
        }
        return Color.primary.opacity(0.2)
    }

    private var knobBorder: Color {
        selectedColor.opacity(0.24)
    }

    private func clampOffset(_ value: CGFloat, maxValue: CGFloat) -> CGFloat {
        min(max(0, value), maxValue)
    }
}

// MARK: - Preview

#Preview("Mini Player") { @MainActor in
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)
    let libraryVM = LibraryViewModel(repository: StubLibraryRepository())
    let appleMusicAdapter = AppleMusicPlaybackAdapter(previewLibraryVM: libraryVM)
    let playbackCoordinator = PlaybackCoordinator(
        playerVM: playerVM,
        appleMusicAdapter: appleMusicAdapter,
        systemNowPlayingProvider: SystemNowPlayingProvider(previewLibraryVM: libraryVM)
    )
    let uiState = UIStateViewModel()

    let track = Track(
        title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
        fileBookmarkData: Data())

    VStack {
        Spacer()
        MiniPlayerView()
            .environment(playerVM)
            .environment(playbackCoordinator)
            .environment(libraryVM)
            .environment(uiState)
            .environmentObject(ThemeStore.shared)
            .padding()
    }
    .frame(width: 800, height: 200)
    .background(Color.black.opacity(0.8))
    .onAppear {
        playerVM.playTracks([track])
    }
}

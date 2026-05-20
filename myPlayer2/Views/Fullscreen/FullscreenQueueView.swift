//
//  FullscreenQueueView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Queue View
//  Displays current playback queue in fullscreen mode.
//  Uses the same Liquid Glass material system as FullscreenMiniPlayerView.
//

import SwiftUI

// MARK: - Fullscreen Queue View

/// Queue view for fullscreen player with Liquid Glass styling
struct FullscreenQueueView: View {
    let tracks: [Track]
    let currentTrackID: UUID?
    let playbackMode: PlaybackOrderMode
    let glassStyle: FullscreenControlsGlassStyle
    let usesBrightTextPalette: Bool
    let scale: CGFloat
    let visibleHeight: CGFloat
    let onTrackTap: (Track) -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var hasPerformedInitialScroll = false

    init(
        tracks: [Track],
        currentTrackID: UUID?,
        playbackMode: PlaybackOrderMode,
        glassStyle: FullscreenControlsGlassStyle,
        usesBrightTextPalette: Bool,
        scale: CGFloat = 1.0,
        visibleHeight: CGFloat = 600,
        onTrackTap: @escaping (Track) -> Void
    ) {
        self.tracks = tracks
        self.currentTrackID = currentTrackID
        self.playbackMode = playbackMode
        self.glassStyle = glassStyle
        self.usesBrightTextPalette = usesBrightTextPalette
        self.scale = scale
        self.visibleHeight = visibleHeight
        self.onTrackTap = onTrackTap
    }

    // MARK: - Layout Constants (all scale-aware)

    /// Panel width - wider for more comfortable content display
    private var panelWidth: CGFloat { 520 * scale }

    /// Panel height - expanded downward to show more items, keeping top position stable
    private var panelHeight: CGFloat { min(visibleHeight * 0.92, 660 * scale) }

    /// Corner radius - macOS 26 standard window corner radius (28pt at base scale)
    /// Reference: UpdateWindowManager.swift uses 28pt for macOS 26 windows
    private var cornerRadius: CGFloat { 28 * scale }

    /// Content padding inside panel - increased for more breathing room
    private var contentPadding: CGFloat { 28 * scale }

    /// Row height for queue items
    private var rowHeight: CGFloat { 58 * scale }

    /// Artwork size in each row
    private var artworkSize: CGFloat { 44 * scale }

    /// Spacing between rows
    private var rowSpacing: CGFloat { 4 * scale }

    private static let scrollCoordinateSpaceName = "fullscreen.queue.scroll"

    // MARK: - Theme Color (Phase 4 — semantic mini-player control palette)

    /// Theme-tinted accent for the currently-playing queue row indicator.
    /// Phase 4: consumes the semantic `miniPlayerControl.primary` so the
    /// near-mono neutralisation is shared with FullscreenMiniPlayerView
    /// and ExpandableVolumeControl instead of being re-derived locally.
    private var processedThemeColor: Color {
        Color(nsColor: themeStore.semanticPalette.miniPlayerControl.primary)
            .opacity(0.96)
    }

    // MARK: - Title Text (mode-appropriate Chinese labels)

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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Title header
            titleHeader
                .padding(.horizontal, contentPadding)
                .padding(.top, contentPadding)
                .padding(.bottom, 12 * scale)

            // Track list
            trackList
                .padding(.horizontal, contentPadding)
                .padding(.bottom, contentPadding)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .top)
        .liquidGlassRect(
            cornerRadius: cornerRadius,
            colorScheme: glassStyle.colorScheme,
            accentColor: glassStyle.accentColor,
            prominence: .prominent,
            materialStyle: glassStyle.materialStyle,
            isFloating: true
        )
        .environment(\.colorScheme, glassStyle.colorScheme)
    }

    // MARK: - Title Header

    private var titleHeader: some View {
        HStack(spacing: 10 * scale) {
            // Mode icon
            Image(systemName: modeIcon)
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(secondaryForegroundColor)

            Text(titleText)
                .font(.system(size: 16 * scale, weight: .semibold))
                .foregroundStyle(primaryForegroundColor)

            Spacer()

            Text("\(tracks.count) 首")
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(secondaryForegroundColor)
        }
    }

    /// Top safe spacing to prevent first item being eaten by fade overlay - reduced for tighter layout
    private var listTopSafeSpacing: CGFloat { 14 * scale }

    // MARK: - Track List

    private var trackList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: rowSpacing) {
                    // Top spacer: ensures first item starts below fade region
                    Color.clear
                        .frame(height: listTopSafeSpacing)
                        .accessibilityHidden(true)

                    ForEach(tracks) { track in
                        QueueRow(
                            track: track,
                            isPlaying: track.id == currentTrackID,
                            textPalette: textPalette,
                            scale: scale,
                            artworkSize: artworkSize,
                            rowHeight: rowHeight,
                            accentColor: processedThemeColor
                        )
                        .id(track.id)
                        .onTapGesture {
                            onTrackTap(track)
                        }
                    }

                    // Bottom spacer: ensures last item doesn't get eaten by bottom fade
                    Color.clear
                        .frame(height: listTopSafeSpacing)
                        .accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .mask(trackListMask)
            .onAppear {
                revealCurrentTrack(using: proxy, animated: false)
                hasPerformedInitialScroll = true
            }
            .onChange(of: currentTrackID) { _, newTrackID in
                guard hasPerformedInitialScroll else { return }
                guard let newTrackID, tracks.contains(where: { $0.id == newTrackID }) else { return }
                scrollToTrack(newTrackID, using: proxy, animated: true)
            }
            .onChange(of: tracks.map(\.id)) { oldTrackIDs, newTrackIDs in
                handleTrackIDsChange(
                    oldTrackIDs: oldTrackIDs,
                    newTrackIDs: newTrackIDs,
                    using: proxy
                )
            }
        }
    }

    /// Mask that creates true alpha fade at top and bottom edges
    private var trackListMask: some View {
        VStack(spacing: 0) {
            // Top fade: from transparent to opaque
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: listTopSafeSpacing)

            // Middle: fully opaque
            Rectangle()
                .fill(.black)

            // Bottom fade: from opaque to transparent
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: listTopSafeSpacing)
        }
    }

    // MARK: - Mode Icon

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
        usesBrightTextPalette ? Color.white.opacity(0.96) : Color.primary.opacity(0.96)
    }

    private var secondaryForegroundColor: Color {
        usesBrightTextPalette ? Color.white.opacity(0.74) : Color.secondary.opacity(0.82)
    }

    private var tertiaryForegroundColor: Color {
        usesBrightTextPalette ? Color.white.opacity(0.58) : Color.secondary.opacity(0.72)
    }

    private var hoverFillColor: Color {
        usesBrightTextPalette ? Color.white.opacity(0.08) : Color.primary.opacity(0.08)
    }

    private var textPalette: FullscreenQueueTextPalette {
        FullscreenQueueTextPalette(
            primary: primaryForegroundColor,
            secondary: secondaryForegroundColor,
            tertiary: tertiaryForegroundColor,
            hoverFill: hoverFillColor
        )
    }

    private var queueScrollAnimation: Animation {
        .timingCurve(0.22, 0.88, 0.24, 1.0, duration: 0.42)
    }

    private func scrollToTrack(
        _ trackID: UUID,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        DispatchQueue.main.async {
            guard tracks.contains(where: { $0.id == trackID }) else { return }

            if animated {
                withAnimation(queueScrollAnimation) {
                    proxy.scrollTo(trackID, anchor: UnitPoint(x: 0.5, y: 0.14))
                }
            } else {
                proxy.scrollTo(trackID, anchor: UnitPoint(x: 0.5, y: 0.14))
            }
        }
    }

    private func revealCurrentTrack(using proxy: ScrollViewProxy, animated: Bool) {
        guard let currentTrackID, tracks.contains(where: { $0.id == currentTrackID }) else { return }
        scrollToTrack(currentTrackID, using: proxy, animated: animated)
    }

    private func handleTrackIDsChange(
        oldTrackIDs: [UUID],
        newTrackIDs: [UUID],
        using proxy: ScrollViewProxy
    ) {
        let trigger = classifyQueueMutation(from: oldTrackIDs, to: newTrackIDs)

        guard hasPerformedInitialScroll else { return }
        guard trigger == .queueRebuildOrReplace else { return }
        revealCurrentTrack(using: proxy, animated: true)
    }

    private func classifyQueueMutation(
        from oldTrackIDs: [UUID],
        to newTrackIDs: [UUID]
    ) -> QueueScrollTrigger {
        guard oldTrackIDs != newTrackIDs else { return .none }
        guard !oldTrackIDs.isEmpty else { return .queueRebuildOrReplace }

        if newTrackIDs.count > oldTrackIDs.count,
           Array(newTrackIDs.prefix(oldTrackIDs.count)) == oldTrackIDs {
            return .queueAppend
        }

        return .queueRebuildOrReplace
    }
}

private enum QueueScrollTrigger: Equatable {
    case none
    case queueAppend
    case queueRebuildOrReplace
}

private struct FullscreenQueueTextPalette {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let hoverFill: Color
}

// MARK: - Queue Row

private struct QueueRow: View {
    let track: Track
    let isPlaying: Bool
    let textPalette: FullscreenQueueTextPalette
    let scale: CGFloat
    let artworkSize: CGFloat
    let rowHeight: CGFloat
    let accentColor: Color

    @State private var isHovering = false
    @State private var artworkImage: NSImage?

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Artwork
            artworkView
                .frame(width: artworkSize, height: artworkSize)

            // Track info
            VStack(alignment: .leading, spacing: 2 * scale) {
                SeamlessMarqueeText(
                    text: track.title,
                    fontSize: 14 * scale,
                    fontWeight: isPlaying ? .semibold : .medium,
                    color: isPlaying ? accentColor : textPalette.primary,
                    shouldAnimate: isPlaying
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(artistText)
                    .font(.system(size: 12 * scale, weight: .regular))
                    .foregroundStyle(textPalette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Playing indicator or duration
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 24 * scale)
            } else {
                Text(formatDuration(track.duration))
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(textPalette.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12 * scale)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8 * scale)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: track.id) {
            await loadArtwork()
        }
    }

    // MARK: - Artwork View

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
        } else {
            ArtworkPlaceholderView.queueRow(
                artworkSize: 44,
                scale: scale,
                themeColor: accentColor
            )
        }
    }

    // MARK: - Background Fill

    private var backgroundFill: Color {
        if isPlaying {
            return accentColor.opacity(0.15)
        }
        return isHovering ? textPalette.hoverFill : Color.clear
    }

    // MARK: - Artist Text

    private var artistText: String {
        track.artist.isEmpty ? "未知艺人" : track.artist
    }

    // MARK: - Format Duration

    private func formatDuration(_ duration: Double) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Load Artwork

    private func loadArtwork() async {
        let artworkData = track.loadArtworkDataIfNeeded()
        guard let artworkData, !artworkData.isEmpty else {
            await MainActor.run {
                artworkImage = nil
            }
            return
        }

        let snapshot = await ArtworkAssetStore.shared.snapshot(
            trackID: track.id,
            artworkData: artworkData
        )

        guard !Task.isCancelled else { return }
        let image = snapshot?.thumbnailImage ?? snapshot?.fullImage
        await MainActor.run {
            artworkImage = image
        }
    }
}

extension FullscreenQueueView: Equatable {
    static func == (lhs: FullscreenQueueView, rhs: FullscreenQueueView) -> Bool {
        lhs.currentTrackID == rhs.currentTrackID
            && lhs.playbackMode == rhs.playbackMode
            && lhs.glassStyle.colorScheme == rhs.glassStyle.colorScheme
            && lhs.glassStyle.materialStyle == rhs.glassStyle.materialStyle
            && lhs.usesBrightTextPalette == rhs.usesBrightTextPalette
            && lhs.scale == rhs.scale
            && lhs.visibleHeight == rhs.visibleHeight
            && lhs.tracks.map(\.id) == rhs.tracks.map(\.id)
    }
}

// MARK: - Preview

#Preview("Fullscreen Queue View - Fixed Dark") {
    let tracks = [
        Track(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 200, fileBookmarkData: Data()),
        Track(title: "Save Your Tears", artist: "The Weeknd", album: "After Hours", duration: 215, fileBookmarkData: Data()),
        Track(title: "Levitating", artist: "Dua Lipa", album: "Future Nostalgia", duration: 203, fileBookmarkData: Data()),
        Track(title: "Peaches", artist: "Justin Bieber", album: "Justice", duration: 198, fileBookmarkData: Data()),
        Track(title: "Good 4 U", artist: "Olivia Rodrigo", album: "SOUR", duration: 178, fileBookmarkData: Data()),
        Track(title: "Montero", artist: "Lil Nas X", album: "Montero", duration: 137, fileBookmarkData: Data()),
        Track(title: "Kiss Me More", artist: "Doja Cat", album: "Planet Her", duration: 208, fileBookmarkData: Data()),
    ]

    FullscreenQueueView(
        tracks: tracks,
        currentTrackID: tracks[0].id,
        playbackMode: .shuffle,
        glassStyle: FullscreenControlsGlassStyle(
            colorScheme: .dark,
            accentColor: ThemeStore.shared.accentColor,
            materialStyle: .clear
        ),
        usesBrightTextPalette: true,
        scale: 1.0,
        visibleHeight: 650,
        onTrackTap: { _ in }
    )
    .environmentObject(ThemeStore.shared)
    .frame(width: 700, height: 800)
    .background(Color.black)
}

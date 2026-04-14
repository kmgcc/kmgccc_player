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
    @State private var visibleRowFrames: [UUID: CGRect] = [:]
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var lastObservedTrackIDs: [UUID] = []
    @State private var pendingQueueMutation: QueueScrollTrigger?
    @State private var pendingScrollCommand: QueueScrollCommand?

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

    // MARK: - Theme Color Processing (same as FullscreenMiniPlayerView)

    /// Minimum lightness for fullscreen theme colors (0.0-1.0)
    /// Ensures text remains visible against dark backgrounds
    private static let fullscreenThemeMinLightness: CGFloat = 0.90

    /// Maximum lightness to prevent washed-out colors
    private static let fullscreenThemeMaxLightness: CGFloat = 0.98

    /// Minimum saturation for vibrant theme colors
    private static let fullscreenThemeMinSaturation: CGFloat = 0.88

    /// Processed theme color for high visibility against dark backgrounds
    /// Same processing chain as FullscreenMiniPlayerView.controlPrimaryColor
    private var processedThemeColor: Color {
        Self.resolveControlPrimaryColor(from: themeStore.accentNSColor)
    }

    /// Resolve and enhance accent color for fullscreen visibility
    /// Ensures minimum saturation, minimum lightness, and maximum lightness
    static func resolveControlAccentColor(from color: NSColor) -> NSColor {
        let saturated = enforceMinimumHslSaturation(
            color,
            minimumSaturation: fullscreenThemeMinSaturation
        )
        let lifted = enforceMinimumHslLightness(
            saturated,
            minimumLightness: fullscreenThemeMinLightness
        )
        return enforceMaximumHslLightness(
            lifted,
            maximumLightness: fullscreenThemeMaxLightness
        )
    }

    static func resolveControlPrimaryColor(from color: NSColor) -> Color {
        Color(nsColor: resolveControlAccentColor(from: color)).opacity(0.96)
    }

    private static func enforceMinimumHslLightness(_ color: NSColor, minimumLightness: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = max(hsl.l, minimumLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func enforceMaximumHslLightness(_ color: NSColor, maximumLightness: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = min(hsl.l, maximumLightness)
        if targetL >= hsl.l - 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func enforceMinimumHslSaturation(_ color: NSColor, minimumSaturation: CGFloat) -> NSColor {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetS = max(hsl.s, minimumSaturation)
        if targetS <= hsl.s + 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: targetS, l: hsl.l)
    }

    private static func hslComponents(from color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat)? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }

        let r = clamp01(rgb.redComponent)
        let g = clamp01(rgb.greenComponent)
        let b = clamp01(rgb.blueComponent)

        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let delta = maxV - minV
        let l = (maxV + minV) * 0.5

        var h: CGFloat = 0
        if delta > 0.000_001 {
            if maxV == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }

        var s: CGFloat = 0
        if delta > 0.000_001 {
            s = delta / (1 - abs(2 * l - 1))
        }

        return (h: h, s: s, l: l)
    }

    private static func rgbColorFromHsl(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))

        var rp: CGFloat = 0
        var gp: CGFloat = 0
        var bp: CGFloat = 0

        switch hPrime {
        case 0..<1: rp = c; gp = x; bp = 0
        case 1..<2: rp = x; gp = c; bp = 0
        case 2..<3: rp = 0; gp = c; bp = x
        case 3..<4: rp = 0; gp = x; bp = c
        case 4..<5: rp = x; gp = 0; bp = c
        default: rp = c; gp = 0; bp = x
        }

        let m = l - c * 0.5
        return NSColor(
            calibratedRed: clamp01(rp + m),
            green: clamp01(gp + m),
            blue: clamp01(bp + m),
            alpha: 1.0
        )
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
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

                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        QueueRow(
                            track: track,
                            index: index,
                            isPlaying: track.id == currentTrackID,
                            textPalette: textPalette,
                            scale: scale,
                            artworkSize: artworkSize,
                            rowHeight: rowHeight,
                            accentColor: processedThemeColor
                        )
                        .id(track.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: QueueRowFramePreferenceKey.self,
                                    value: [track.id: geometry.frame(in: .named(Self.scrollCoordinateSpaceName))]
                                )
                            }
                        }
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
            .animation(.spring(response: 0.52, dampingFraction: 0.80, blendDuration: 0.15), value: tracks.map(\.id))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: QueueViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onAppear {
                handleQueueTrigger(.openQueue, using: proxy, animatedOverride: false)
                hasPerformedInitialScroll = true
                lastObservedTrackIDs = tracks.map(\.id)
            }
            .onChange(of: currentTrackID) { oldTrackID, newTrackID in
                handleCurrentTrackChange(
                    oldTrackID: oldTrackID,
                    newTrackID: newTrackID,
                    using: proxy
                )
            }
            .onChange(of: tracks.map(\.id)) { oldTrackIDs, newTrackIDs in
                handleTrackIDsChange(
                    oldTrackIDs: oldTrackIDs,
                    newTrackIDs: newTrackIDs,
                    using: proxy
                )
            }
            .onPreferenceChange(QueueRowFramePreferenceKey.self) { frames in
                visibleRowFrames = frames
            }
            .onPreferenceChange(QueueViewportHeightPreferenceKey.self) { height in
                scrollViewportHeight = height
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

    private var playbackAdvanceTriggerBottomEdge: CGFloat {
        max(rowHeight * 4.0, scrollViewportHeight - rowHeight * 1.15)
    }

    private var playbackAdvanceComfortBottomEdge: CGFloat {
        max(rowHeight * 4.4, scrollViewportHeight - rowHeight * 0.55)
    }

    private var queueScrollAnimation: Animation {
        .timingCurve(0.22, 0.88, 0.24, 1.0, duration: 0.42)
    }

    private func executeScrollCommand(
        _ command: QueueScrollCommand,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        pendingScrollCommand = command

        DispatchQueue.main.async {
            guard pendingScrollCommand == command else { return }
            pendingScrollCommand = nil

            let targetTrackID = command.targetTrackID
            guard tracks.contains(where: { $0.id == targetTrackID }) else { return }

            if animated {
                withAnimation(queueScrollAnimation) {
                    proxy.scrollTo(targetTrackID, anchor: command.anchor)
                }
            } else {
                proxy.scrollTo(targetTrackID, anchor: command.anchor)
            }
        }
    }

    private func handleQueueTrigger(
        _ trigger: QueueScrollTrigger,
        using proxy: ScrollViewProxy,
        animatedOverride: Bool? = nil
    ) {
        let command: QueueScrollCommand?
        let animated: Bool

        switch trigger {
        case .none:
            command = nil
            animated = false
        case .openQueue:
            guard let currentTrackID else { return }
            command = .revealCurrentTop(currentTrackID)
            animated = animatedOverride ?? false
        case .queueRebuildOrReplace:
            guard let currentTrackID else { return }
            command = .revealCurrentTop(currentTrackID)
            animated = animatedOverride ?? hasPerformedInitialScroll
        case .queueAppend:
            command = nil
            animated = false
        case .playbackAdvance(let currentTrackID):
            command = playbackAdvanceCommand(for: currentTrackID)
            animated = animatedOverride ?? true
        }

        guard let command else { return }
        guard pendingScrollCommand != command else { return }
        executeScrollCommand(command, using: proxy, animated: animated)
    }

    private func handleCurrentTrackChange(
        oldTrackID: UUID?,
        newTrackID: UUID?,
        using proxy: ScrollViewProxy
    ) {
        guard hasPerformedInitialScroll else {
            handleQueueTrigger(.openQueue, using: proxy, animatedOverride: false)
            return
        }
        guard let newTrackID, tracks.contains(where: { $0.id == newTrackID }) else { return }

        let liveTrackIDs = tracks.map(\.id)
        let queueMutation = pendingQueueMutation ?? classifyQueueMutation(
            from: lastObservedTrackIDs,
            to: liveTrackIDs
        )

        guard queueMutation != .queueRebuildOrReplace else { return }

        if let oldTrackID,
           let oldFrame = visibleRowFrames[oldTrackID],
           oldFrame.maxY < playbackAdvanceTriggerBottomEdge {
            return
        }

        if let command = playbackAdvanceCommand(for: newTrackID),
           pendingScrollCommand != command {
            handleQueueTrigger(.playbackAdvance(currentTrackID: newTrackID), using: proxy)
        }
    }

    private func handleTrackIDsChange(
        oldTrackIDs: [UUID],
        newTrackIDs: [UUID],
        using proxy: ScrollViewProxy
    ) {
        let trigger = classifyQueueMutation(from: oldTrackIDs, to: newTrackIDs)
        lastObservedTrackIDs = newTrackIDs

        guard trigger != .none else { return }
        pendingQueueMutation = trigger
        DispatchQueue.main.async {
            pendingQueueMutation = nil
        }

        handleQueueTrigger(trigger, using: proxy)
    }

    private func playbackAdvanceCommand(for currentTrackID: UUID) -> QueueScrollCommand? {
        guard let currentIndex = tracks.firstIndex(where: { $0.id == currentTrackID }) else { return nil }

        let currentFrame = visibleRowFrames[currentTrackID]
        let nextTrackID = tracks[safe: currentIndex + 1]?.id
        let nextFrame = nextTrackID.flatMap { visibleRowFrames[$0] }

        if let nextFrame,
           nextFrame.minY >= 0,
           nextFrame.maxY <= playbackAdvanceComfortBottomEdge {
            return nil
        }

        if let currentFrame,
           currentFrame.maxY < playbackAdvanceTriggerBottomEdge {
            return nil
        }

        if let nextTrackID {
            return .keepTrackVisibleNearBottom(nextTrackID)
        }

        guard let currentFrame, currentFrame.maxY > scrollViewportHeight else { return nil }
        return .keepTrackVisibleNearBottom(currentTrackID)
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
    case openQueue
    case playbackAdvance(currentTrackID: UUID)
    case queueAppend
    case queueRebuildOrReplace
}

private enum QueueScrollCommand: Equatable {
    case revealCurrentTop(UUID)
    case keepTrackVisibleNearBottom(UUID)

    var targetTrackID: UUID {
        switch self {
        case .revealCurrentTop(let trackID), .keepTrackVisibleNearBottom(let trackID):
            return trackID
        }
    }

    var anchor: UnitPoint {
        switch self {
        case .revealCurrentTop:
            return UnitPoint(x: 0.5, y: 0.10)
        case .keepTrackVisibleNearBottom:
            return UnitPoint(x: 0.5, y: 0.94)
        }
    }
}

private struct FullscreenQueueTextPalette {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let hoverFill: Color
}

private struct QueueRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct QueueViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - Queue Row

private struct QueueRow: View {
    let track: Track
    let index: Int
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
                Text(track.title)
                    .font(.system(size: 14 * scale, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? accentColor : textPalette.primary)
                    .lineLimit(1)

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
            ArtworkPlaceholderView.queueRow(artworkSize: 44, scale: scale)
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
        guard let artworkData = track.artworkData, !artworkData.isEmpty else {
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

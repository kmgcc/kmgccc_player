//
//  MiniPlayerView.swift
//  myPlayer2
//
//  kmgccc_player - Mini Player View
//  Uses native SwiftUI .glassEffect() for true macOS 26 Liquid Glass capsule.
//

import AppKit
import SwiftUI

// Playback mode enum shared with FullscreenMiniPlayerView
enum PlaybackOrderMode {
    case sequence
    case shuffle
    case repeatOne
    case stopAfterTrack
}

/// Mini player bar with true Liquid Glass capsule effect.
/// Layout: Cover+Title | Controls | Playback Mode | Progress
struct MiniPlayerView: View {

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    @AppStorage("shuffleEnabled") private var shuffleEnabled: Bool = false
    @AppStorage("repeatMode") private var repeatMode: String = "off"
    @AppStorage("stopAfterTrack") private var stopAfterTrack: Bool = false

    /// For drag-to-seek
    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    @State private var trackToEdit: Track?
    @State private var isProgressHovering = false
    @State private var previousSymbolEffectTrigger = 0
    @State private var playPauseSymbolEffectTrigger = 0
    @State private var nextSymbolEffectTrigger = 0
    @State private var artworkImage: NSImage?
    @State private var isPlaybackModeExpanded = false

    private var playbackModeExpandedWidth: CGFloat { 168 }
    private var playbackModeCollapsedWidth: CGFloat { 44 }
    private var playbackModeWidth: CGFloat {
        isPlaybackModeExpanded ? playbackModeExpandedWidth : playbackModeCollapsedWidth
    }
    private var layoutAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)
    }
    private var trackInfoIdealWidth: CGFloat { 100 }
    private var trackInfoMinWidth: CGFloat { 56 }
    private var trackInfoMaxWidth: CGFloat { 136 }
    private var progressAreaMinWidth: CGFloat { 120 }

    var body: some View {
        return HStack(spacing: 12) {
            // MARK: - Left: Cover + Title/Artist (tappable)
            Button {
                if uiState.contentMode == .nowPlaying {
                    uiState.returnToLibraryFromNowPlaying()
                } else {
                    uiState.showNowPlaying()
                }
            } label: {
                HStack(spacing: 10) {
                    artworkView

                    VStack(alignment: .leading, spacing: 4) {
                        if let track = playerVM.currentTrack {
                            MarqueeText(
                                text: track.title,
                                style: .subheadline,
                                fontWeight: .medium,
                                color: .primary,
                                enablesContentTransition: true
                            )

                            MarqueeText(
                                text: track.artist.isEmpty
                                    ? NSLocalizedString("library.unknown_artist", comment: "")
                                    : track.artist,
                                style: .caption,
                                fontWeight: .regular,
                                color: .secondary,
                                enablesContentTransition: true
                            )
                        } else {
                            Text("mini.not_playing")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(
                        minWidth: trackInfoMinWidth,
                        idealWidth: trackInfoIdealWidth,
                        maxWidth: trackInfoMaxWidth,
                        alignment: .leading
                    )
                    .clipped()

                }
                .contentShape(Rectangle())
                .offset(x: 4, y: 0)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .contextMenu {
                nowPlayingInfoContextMenu
            }

            // MARK: - Controls
            controlsView
                .layoutPriority(2)

            // MARK: - Playback Mode
            playbackModeView
                .frame(width: playbackModeWidth, height: 26)
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
            isFloating: true
        )
        .contentShape(Capsule())
        .onTapGesture {}
        .animation(layoutAnimation, value: isPlaybackModeExpanded)
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
                .environmentObject(themeStore)
        }
        .task(id: currentArtworkTaskKey) {
            await loadArtworkThumbnail()
        }
    }

    // MARK: - Subviews

    private var controlsView: some View {
        let isEnabled = playerVM.currentTrack != nil
        return HStack(spacing: 14) {
            // Previous
            Button {
                previousSymbolEffectTrigger += 1
                playerVM.previous()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                        .symbolEffect(.wiggle, value: previousSymbolEffectTrigger)
                }
                .frame(width: controlHitSize, height: controlHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
            .disabled(playerVM.currentTrack == nil)

            // Play/Pause
            Button {
                playPauseSymbolEffectTrigger += 1
                playerVM.togglePlayPause()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
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
            .disabled(playerVM.currentTrack == nil)

            // Next
            Button {
                nextSymbolEffectTrigger += 1
                playerVM.next()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
                        .symbolEffect(.wiggle, value: nextSymbolEffectTrigger)
                }
                .frame(width: controlHitSize, height: controlHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
            .disabled(playerVM.currentTrack == nil)
        }
    }

    private var controlHitSize: CGFloat { 26 }

    @ViewBuilder
    private var nowPlayingInfoContextMenu: some View {
        if let track = playerVM.currentTrack {
            Button {
                trackToEdit = track
            } label: {
                Label(
                    "context.get_info", systemImage: "info.circle")
            }
        }
    }

    private var currentPlaybackMode: PlaybackOrderMode {
        if stopAfterTrack { return .stopAfterTrack }
        if repeatMode == "one" { return .repeatOne }
        if shuffleEnabled { return .shuffle }
        return .sequence
    }

    private var playbackModeView: some View {
        let isEnabled = playerVM.currentTrack != nil
        return PlaybackModeSlider(
            mode: currentPlaybackMode,
            isEnabled: isEnabled,
            isExpanded: isPlaybackModeExpanded,
            onModeChange: { mode in
                switch mode {
                case .sequence:
                    shuffleEnabled = false
                    repeatMode = "off"
                    stopAfterTrack = false
                case .shuffle:
                    shuffleEnabled = true
                    repeatMode = "off"
                    stopAfterTrack = false
                case .repeatOne:
                    shuffleEnabled = false
                    repeatMode = "one"
                    stopAfterTrack = false
                case .stopAfterTrack:
                    shuffleEnabled = false
                    repeatMode = "off"
                    stopAfterTrack = true
                }
            },
            onCurrentModeRetap: { _ in }
        )
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

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.4), .blue.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            let barHeight: CGFloat = 5
            let fill = progressFillColor
            let track = progressTrackColor

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
                        isDragging = true
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        dragProgress = progress * playerVM.duration
                    }
                    .onEnded { value in
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        let seekTime = progress * playerVM.duration
                        playerVM.seek(to: seekTime)
                        isDragging = false
                    }
            )
        }
        .frame(height: 18)
    }

    private var progressArea: some View {
        ZStack {
            progressBar
        }
        .overlay(alignment: .top) {
            HStack {
                NumericTimeText(
                    time: progressDisplayTime,
                    fontSize: 10,
                    fontWeight: .medium,
                    color: .secondary
                )
                .opacity(isProgressHovering ? 1 : 0)

                Spacer()

                NumericTimeText(
                    time: playerVM.duration,
                    fontSize: 10,
                    fontWeight: .medium,
                    color: .secondary
                )
                .opacity(isProgressHovering ? 1 : 0)
            }
            .offset(y: -8)
            .animation(.easeInOut(duration: 0.12), value: isProgressHovering)
        }
        .frame(height: 18)
        .onHover { hovering in
            isProgressHovering = hovering
        }
    }

    private var progressDisplayTime: Double {
        isDragging ? dragProgress : playerVM.currentTime
    }
    
    private var currentArtworkTaskKey: String {
        guard let track = playerVM.currentTrack else { return "none" }
        let checksum = ArtworkAssetStore.checksum(for: track.artworkData)
        return "\(track.id.uuidString)-\(checksum)"
    }
    
    private func loadArtworkThumbnail() async {
        guard let track = playerVM.currentTrack, let artworkData = track.artworkData, !artworkData.isEmpty
        else {
            artworkImage = nil
            return
        }
        
        let snapshot = await ArtworkAssetStore.shared.snapshotMetadata(
            trackID: track.id,
            artworkData: artworkData
        )
        guard !Task.isCancelled else { return }
        artworkImage = snapshot?.thumbnailImage ?? snapshot?.fullImage
    }

    private var progressFillColor: Color {
        Color.primary.opacity(0.8)
    }

    private var progressTrackColor: Color {
        Color.secondary.opacity(0.25)
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard playerVM.duration > 0 else { return 0 }
        let time = isDragging ? dragProgress : playerVM.currentTime
        let progress = time / playerVM.duration
        return totalWidth * CGFloat(max(0, min(1, progress)))
    }

    private var volumeView: some View {
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .frame(width: 14)

            Slider(
                value: Binding(
                    get: { playerVM.volume },
                    set: { playerVM.setVolume($0) }
                ),
                in: 0...1
            )
            .frame(width: 80)
            .controlSize(.small)
            .tint(themeStore.accentColor)
        }
    }

    private var volumeIcon: String {
        if playerVM.volume == 0 {
            return "speaker.slash.fill"
        } else if playerVM.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if playerVM.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var controlPrimaryColor: Color {
        let base = themeStore.accentNSColor
        let tuned: NSColor
        if colorScheme == .dark {
            tuned = Self.enforceMinimumHslLightness(base, minimumLightness: 0.70)
        } else {
            tuned = Self.enforceMaximumHslLightness(base, maximumLightness: 0.45)
        }
        return Color(nsColor: tuned).opacity(colorScheme == .dark ? 0.98 : 0.92)
    }

    private var controlDisabledColor: Color {
        Color.secondary.opacity(0.5)
    }

    private static func enforceMinimumHslLightness(_ color: NSColor, minimumLightness: CGFloat)
        -> NSColor
    {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = max(hsl.l, minimumLightness)
        if targetL <= hsl.l + 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
    }

    private static func enforceMaximumHslLightness(_ color: NSColor, maximumLightness: CGFloat)
        -> NSColor
    {
        guard let hsl = hslComponents(from: color) else { return color }
        let targetL = min(hsl.l, maximumLightness)
        if targetL >= hsl.l - 0.000_001 { return color }
        return rgbColorFromHsl(h: hsl.h, s: hsl.s, l: targetL)
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
        case 0..<1:
            rp = c; gp = x; bp = 0
        case 1..<2:
            rp = x; gp = c; bp = 0
        case 2..<3:
            rp = 0; gp = c; bp = x
        case 3..<4:
            rp = 0; gp = x; bp = c
        case 4..<5:
            rp = x; gp = 0; bp = c
        default:
            rp = c; gp = 0; bp = x
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
        Swift.min(Swift.max(value, 0), 1)
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

    @Environment(\.colorScheme) private var colorScheme
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
            let knobOffset = clampOffset(
                baseOffset + effectiveDrag, maxValue: totalWidth - segmentWidth)
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
                        let clampedIndex = max(0, min(3, index))
                        let targetMode = modeForIndex(clampedIndex)
                        guard targetMode != mode else { return }
                        commitModeChange(targetMode, snap: snap)
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
            return pillTintColor.opacity(0.18)
        }
        return Color.secondary.opacity(0.2)
    }

    private var trackBorder: Color {
        Color.primary.opacity(0.16)
    }

    private var knobFill: Color {
        if let pillTintColor {
            return pillTintColor.opacity(0.34)
        }
        return Color.primary.opacity(0.2)
    }

    private var knobBorder: Color {
        Color.primary.opacity(0.24)
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
    let uiState = UIStateViewModel()

    let track = Track(
        title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
        fileBookmarkData: Data())

    VStack {
        Spacer()
        MiniPlayerView()
            .environment(playerVM)
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

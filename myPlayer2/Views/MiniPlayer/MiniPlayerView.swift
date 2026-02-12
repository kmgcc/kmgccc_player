//
//  MiniPlayerView.swift
//  myPlayer2
//
//  TrueMusic - Mini Player View
//  Uses native SwiftUI .glassEffect() for true macOS 26 Liquid Glass capsule.
//

import SwiftUI

private enum PlaybackMode {
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
                                color: .primary
                            )

                            MarqueeText(
                                text: track.artist.isEmpty
                                    ? NSLocalizedString("library.unknown_artist", comment: "")
                                    : track.artist,
                                style: .caption,
                                fontWeight: .regular,
                                color: .secondary
                            )
                        } else {
                            Text("mini.not_playing")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 136, alignment: .leading)
                    .clipped()

                }
                .contentShape(Rectangle())
                .offset(x: 4, y: 0)
            }
            .buttonStyle(.plain)
            .contextMenu {
                nowPlayingInfoContextMenu
            }

            // MARK: - Controls
            controlsView

            // MARK: - Playback Mode
            playbackModeView

            // MARK: - Progress bar (draggable + hover time labels)
            progressArea
                .frame(minWidth: 200, maxWidth: .infinity)

            // MARK: - Right: Volume Slider
            volumeView
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(height: Constants.Layout.miniPlayerHeight)
        .glassEffect(.clear, in: .capsule)
        .overlay(
            Capsule()
                .fill(miniPlayerTintColor)
                .allowsHitTesting(false)
        )
        .shadow(
            color: colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
            radius: 6,
            x: 0,
            y: 2
        )
        .contentShape(Capsule())
        .onTapGesture {}
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
                .environmentObject(themeStore)
        }
    }

    // MARK: - Subviews

    private var controlsView: some View {
        let isEnabled = playerVM.currentTrack != nil
        return HStack(spacing: 14) {
            // Previous
            Button {
                playerVM.previous()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
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
                playerVM.togglePlayPause()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
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
                playerVM.next()
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .foregroundStyle(isEnabled ? controlPrimaryColor : controlDisabledColor)
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

    private var currentPlaybackMode: PlaybackMode {
        if stopAfterTrack { return .stopAfterTrack }
        if repeatMode == "one" { return .repeatOne }
        if shuffleEnabled { return .shuffle }
        return .sequence
    }

    private var playbackModeView: some View {
        PlaybackModeSlider(
            mode: currentPlaybackMode,
            isEnabled: playerVM.currentTrack != nil,
            onSelect: { mode in
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
            }
        )
        .frame(width: 168, height: 26)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkData = playerVM.currentTrack?.artworkData,
            let nsImage = NSImage(data: artworkData)
        {
            Image(nsImage: nsImage)
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

                    Circle()
                        .fill(Color.clear)
                        .frame(width: 14, height: 14)
                        .offset(x: progressWidth(in: geometry.size.width) - 7)
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
        ZStack(alignment: .top) {
            progressBar

            HStack {
                Text(formattedTime(progressDisplayTime))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .opacity(isProgressHovering ? 1 : 0)

                Spacer()

                Text(formattedTime(playerVM.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .opacity(isProgressHovering ? 1 : 0)
            }
            .offset(y: -11)
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

    private func formattedTime(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let total = Int(time.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
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
        Color.primary.opacity(0.9)
    }

    private var controlDisabledColor: Color {
        Color.secondary.opacity(0.5)
    }

    private var miniPlayerTintColor: Color {
        guard !themeStore.usesFallbackThemeColor else { return .clear }
        if colorScheme == .dark {
            return themeStore.accentColor.opacity(0.045)
        }
        return themeStore.accentColor.opacity(0.03)
    }
}

private struct PlaybackModeSlider: View {
    let mode: PlaybackMode
    let isEnabled: Bool
    let onSelect: (PlaybackMode) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging: Bool = false

    private var modeIndex: Int {
        switch mode {
        case .shuffle: return 0
        case .sequence: return 1
        case .repeatOne: return 2
        case .stopAfterTrack: return 3
        }
    }

    private func modeForIndex(_ index: Int) -> PlaybackMode {
        switch index {
        case 0: return .shuffle
        case 1: return .sequence
        case 2: return .repeatOne
        default: return .stopAfterTrack
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 2
            let totalWidth = geometry.size.width - inset * 2
            let segmentWidth = max(1, totalWidth / 4)
            let baseOffset = CGFloat(modeIndex) * segmentWidth
            let effectiveDrag = isDragging ? dragTranslation : 0
            let knobOffset = clampOffset(
                baseOffset + effectiveDrag, maxValue: totalWidth - segmentWidth)
            let snap = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .overlay(Capsule().stroke(trackBorder, lineWidth: 1))
                    .allowsHitTesting(false)

                Capsule()
                    .fill(knobFill)
                    .overlay(Capsule().stroke(knobBorder, lineWidth: 1))
                    .frame(width: segmentWidth, height: geometry.size.height - inset * 2)
                    .offset(x: knobOffset + inset)
                    .allowsHitTesting(false)
                    .animation((reduceMotion || isDragging) ? .none : snap, value: modeIndex)

                HStack(spacing: 0) {
                    segmentButton(
                        systemImage: "shuffle", isSelected: modeIndex == 0, width: segmentWidth
                    ) {
                        selectMode(.shuffle, snap: snap)
                    }
                    segmentButton(
                        systemImage: "list.bullet", isSelected: modeIndex == 1, width: segmentWidth
                    ) {
                        selectMode(.sequence, snap: snap)
                    }
                    segmentButton(
                        systemImage: "repeat.1", isSelected: modeIndex == 2, width: segmentWidth
                    ) {
                        selectMode(.repeatOne, snap: snap)
                    }
                    segmentButton(
                        systemImage: "pause.circle", isSelected: modeIndex == 3,
                        width: segmentWidth
                    ) {
                        selectMode(.stopAfterTrack, snap: snap)
                    }
                }
                .padding(.horizontal, inset)
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        let raw = baseOffset + value.translation.width
                        let index = Int(round(raw / segmentWidth))
                        dragTranslation = 0
                        isDragging = false
                        let clampedIndex = max(0, min(3, index))
                        selectMode(modeForIndex(clampedIndex), snap: snap)
                    }
            )
        }
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
    }

    private func selectMode(_ newMode: PlaybackMode, snap: Animation) {
        if reduceMotion {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                onSelect(newMode)
            }
        } else {
            withAnimation(snap) {
                onSelect(newMode)
            }
        }
    }

    private func segmentButton(
        systemImage: String,
        isSelected: Bool,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(Color.clear)
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(width: width, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 28)
        .contentShape(Rectangle())
    }

    private var trackFill: Color {
        Color.secondary.opacity(0.2)
    }

    private var trackBorder: Color {
        Color.primary.opacity(0.16)
    }

    private var knobFill: Color {
        Color.primary.opacity(0.2)
    }

    private var knobBorder: Color {
        Color.primary.opacity(0.24)
    }

    private func clampOffset(_ value: CGFloat, maxValue: CGFloat) -> CGFloat {
        min(max(0, value), maxValue)
    }
}

// MARK: - Preview

#Preview("Mini Player") {
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

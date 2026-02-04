//
//  MiniPlayerView.swift
//  myPlayer2
//
//  TrueMusic - Mini Player View
//  Uses native SwiftUI .glassEffect() for true macOS 26 Liquid Glass capsule.
//

import SwiftUI

/// Mini player bar with true Liquid Glass capsule effect.
/// Layout: Controls | Cover | Title+Progress | Volume
struct MiniPlayerView: View {

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState

    /// For drag-to-seek
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    var body: some View {
        HStack(spacing: 16) {
            // MARK: - Left: Playback Controls
            controlsView

            // MARK: - Cover Art (tappable)
            Button {
                uiState.showNowPlaying()
            } label: {
                artworkView
            }
            .buttonStyle(.plain)

            // MARK: - Center: Title + Progress (tappable)
            Button {
                uiState.showNowPlaying()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    // Track info
                    if let track = playerVM.currentTrack {
                        Text(track.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Not Playing")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 200, alignment: .leading)

            // MARK: - Progress bar (draggable)
            progressBar
                .frame(maxWidth: .infinity)

            // MARK: - Right: Volume Slider
            volumeView
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(height: 68)
        .glassPill()  // macOS 26 native Liquid Glass capsule
    }

    // MARK: - Subviews

    private var controlsView: some View {
        HStack(spacing: 14) {
            // Previous
            Button {
                playerVM.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(playerVM.currentTrack == nil)

            // Play/Pause
            Button {
                playerVM.togglePlayPause()
            } label: {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(playerVM.currentTrack == nil)

            // Next
            Button {
                playerVM.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(playerVM.currentTrack == nil)
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artworkData = playerVM.currentTrack?.artworkData,
            let nsImage = NSImage(data: artworkData)
        {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.4), .blue.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: 6)

                // Progress fill
                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: progressWidth(in: geometry.size.width), height: 6)

                // Drag handle (invisible but interactive)
                Circle()
                    .fill(Color.clear)
                    .frame(width: 16, height: 16)
                    .offset(x: progressWidth(in: geometry.size.width) - 8)
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
        .frame(height: 6)
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
                .foregroundStyle(.secondary)
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
            .padding()
    }
    .frame(width: 800, height: 200)
    .background(Color.black.opacity(0.8))
    .onAppear {
        playerVM.playTracks([track])
    }
}

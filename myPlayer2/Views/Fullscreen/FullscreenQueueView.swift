//
//  FullscreenQueueView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Queue View
//  Displays current playback queue in fullscreen mode with Liquid Glass styling.
//

import SwiftUI

// MARK: - Enums

/// Right panel mode for fullscreen player
public enum FullscreenRightPanelMode {
    case lyrics
    case queue
}

/// Queue view for fullscreen player with Liquid Glass styling
struct FullscreenQueueView: View {
    let tracks: [Track]
    let currentTrackID: UUID?
    let playbackMode: PlaybackMode
    let onTrackTap: (Track) -> Void
    let scale: CGFloat

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    init(
        tracks: [Track],
        currentTrackID: UUID?,
        playbackMode: PlaybackMode,
        scale: CGFloat = 1.0,
        onTrackTap: @escaping (Track) -> Void
    ) {
        self.tracks = tracks
        self.currentTrackID = currentTrackID
        self.playbackMode = playbackMode
        self.scale = scale
        self.onTrackTap = onTrackTap
    }

    private var titleText: String {
        switch playbackMode {
        case .shuffle:
            return "随机播放队列"
        case .sequence, .stopAfterTrack:
            return "播放队列"
        case .repeatOne:
            return "单曲循环"
        }
    }

    // MARK: - Layout Constants

    private var cornerRadius: CGFloat { 20 * scale }
    private var panelWidth: CGFloat { 380 * scale }
    private var panelMaxHeight: CGFloat { 520 * scale }
    private var contentPadding: CGFloat { 20 * scale }
    private var rowHeight: CGFloat { 56 * scale }
    private var artworkSize: CGFloat { 40 * scale }
    private var rowSpacing: CGFloat { 4 * scale }

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
        .frame(width: panelWidth)
        .frame(maxHeight: panelMaxHeight, alignment: .top)
        .liquidGlassRect(
            cornerRadius: cornerRadius,
            colorScheme: colorScheme,
            accentColor: nil as Color?,
            prominence: .standard,
            isFloating: true
        )
    }

    private var titleHeader: some View {
        HStack(spacing: 12 * scale) {
            // Mode icon
            Image(systemName: modeIcon)
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(titleText)
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Text("\(tracks.count) 首")
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var trackList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: rowSpacing) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    QueueRow(
                        track: track,
                        index: index,
                        isPlaying: track.id == currentTrackID,
                        scale: scale,
                        artworkSize: artworkSize,
                        rowHeight: rowHeight,
                        accentColor: themeStore.accentColor
                    )
                    .id(track.id)
                    .onTapGesture {
                        onTrackTap(track)
                    }
                }
            }
        }
    }

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
}

// MARK: - Queue Row

private struct QueueRow: View {
    let track: Track
    let index: Int
    let isPlaying: Bool
    let scale: CGFloat
    let artworkSize: CGFloat
    let rowHeight: CGFloat
    let accentColor: Color

    @State private var isHovering = false
    @State private var artworkImage: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Artwork
            artworkView
                .frame(width: artworkSize, height: artworkSize)

            // Track info
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(track.title)
                    .font(.system(size: 13 * scale, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? accentColor : .primary)
                    .lineLimit(1)

                Text(artistText)
                    .font(.system(size: 11 * scale, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Playing indicator or duration
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(width: 24 * scale)
            } else {
                Text(formatDuration(track.duration))
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous))
        } else {
            // Placeholder
            RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.4), .blue.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: artworkSize, height: artworkSize)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(.white.opacity(0.6))
                }
        }
    }

    private var backgroundFill: Color {
        if isPlaying {
            return accentColor.opacity(colorScheme == .dark ? 0.15 : 0.12)
        }
        return isHovering ? Color.primary.opacity(0.05) : Color.clear
    }

    private var artistText: String {
        track.artist.isEmpty ? "未知艺人" : track.artist
    }

    private func formatDuration(_ duration: Double) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @MainActor
    private func loadArtwork() async {
        guard let artworkData = track.artworkData, !artworkData.isEmpty else {
            artworkImage = nil
            return
        }

        // Load artwork snapshot
        let snapshot = await ArtworkAssetStore.shared.snapshot(
            trackID: track.id,
            artworkData: artworkData
        )

        guard !Task.isCancelled else { return }
        artworkImage = snapshot?.thumbnailImage ?? snapshot?.fullImage
    }
}

// MARK: - Preview

#Preview("Fullscreen Queue View") {
    let tracks = [
        Track(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 200, fileBookmarkData: Data()),
        Track(title: "Save Your Tears", artist: "The Weeknd", album: "After Hours", duration: 215, fileBookmarkData: Data()),
        Track(title: "Levitating", artist: "Dua Lipa", album: "Future Nostalgia", duration: 203, fileBookmarkData: Data()),
        Track(title: "Peaches", artist: "Justin Bieber", album: "Justice", duration: 198, fileBookmarkData: Data()),
        Track(title: "Good 4 U", artist: "Olivia Rodrigo", album: "SOUR", duration: 178, fileBookmarkData: Data()),
        Track(title: "Montero", artist: "Lil Nas X", album: "Montero", duration: 137, fileBookmarkData: Data()),
    ]

    FullscreenQueueView(
        tracks: tracks,
        currentTrackID: tracks[0].id,
        playbackMode: .shuffle,
        scale: 1.0,
        onTrackTap: { _ in }
    )
    .environmentObject(ThemeStore.shared)
    .frame(width: 600, height: 700)
    .background(Color.black.opacity(0.8))
}

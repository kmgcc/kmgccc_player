//
//  FullscreenQueueView.swift
//  myPlayer2
//
//  kmgccc_player - Fullscreen Queue View
//  Displays current playback queue in fullscreen mode.
//

import SwiftUI

// MARK: - Enums

/// Right panel mode for fullscreen player
public enum FullscreenRightPanelMode {
    case lyrics
    case queue
}

/// Queue view for fullscreen player - simplified track list without complex interactions
struct FullscreenQueueView: View {
    let tracks: [Track]
    let currentTrackID: UUID?
    let playbackMode: PlaybackMode
    let onTrackTap: (Track) -> Void
    
    @State private var scrollPosition: UUID?
    @State private var hasPerformedInitialScroll = false
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    
    private var titleText: String {
        switch playbackMode {
        case .shuffle:
            return NSLocalizedString("fullscreen.queue.title_shuffle", comment: "Current Shuffle Queue")
        case .sequence, .stopAfterTrack:
            return NSLocalizedString("fullscreen.queue.title_sequence", comment: "Current Queue")
        case .repeatOne:
            return NSLocalizedString("fullscreen.queue.title_repeat", comment: "Current Queue")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Title header
            titleHeader
            
            // Track list
            trackList
        }
        .onAppear {
            if !hasPerformedInitialScroll {
                scrollToCurrentTrack()
                hasPerformedInitialScroll = true
            }
        }
        .onChange(of: currentTrackID) { _, _ in
            // When track changes, scroll to it if it's far from current view
            if !tracks.isEmpty {
                scrollToCurrentTrack()
            }
        }
    }
    
    private var titleHeader: some View {
        HStack {
            Text(titleText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text("\(tracks.count) \(NSLocalizedString("fullscreen.queue.songs", comment: "songs"))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
    
    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    FullscreenQueueRow(
                        track: track,
                        index: index,
                        isPlaying: track.id == currentTrackID,
                        accentColor: themeStore.accentColor
                    )
                    .id(track.id)
                    .onTapGesture {
                        onTrackTap(track)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollPosition(id: $scrollPosition)
    }
    
    private func scrollToCurrentTrack() {
        guard let currentID = currentTrackID else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            scrollPosition = currentID
        }
    }
}

/// Simplified row for fullscreen queue - no context menu, no multi-selection
private struct FullscreenQueueRow: View {
    let track: Track
    let index: Int
    let isPlaying: Bool
    let accentColor: Color
    
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            // Index or playing indicator
            indexIndicator
            
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? accentColor : .primary)
                    .lineLimit(1)
                
                Text(track.artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Duration
            Text(formatDuration(track.duration))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
    
    @ViewBuilder
    private var indexIndicator: some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(accentColor)
                .frame(width: 24, height: 24)
        } else {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }
    
    private var backgroundFill: Color {
        if isPlaying {
            return accentColor.opacity(colorScheme == .dark ? 0.15 : 0.12)
        }
        return isHovering ? Color.primary.opacity(0.05) : Color.clear
    }
    
    private func formatDuration(_ duration: Double) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#Preview("Fullscreen Queue View") {
    let tracks = [
        Track(title: "Song 1", artist: "Artist 1", album: "Album 1", duration: 180, fileBookmarkData: Data()),
        Track(title: "Song 2", artist: "Artist 2", album: "Album 2", duration: 240, fileBookmarkData: Data()),
        Track(title: "Song 3", artist: "Artist 3", album: "Album 3", duration: 200, fileBookmarkData: Data()),
    ]
    
    FullscreenQueueView(
        tracks: tracks,
        currentTrackID: tracks[1].id,
        playbackMode: .shuffle,
        onTrackTap: { _ in }
    )
    .environmentObject(ThemeStore.shared)
    .frame(width: 400, height: 600)
    .background(Color.black.opacity(0.8))
}

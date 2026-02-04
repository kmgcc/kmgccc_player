//
//  TrackRowView.swift
//  myPlayer2
//
//  TrueMusic - Track Row View
//  Displays a single track in a list.
//

import SwiftUI

/// Row view for displaying a track in a list.
struct TrackRowView: View {

    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 12) {
                // Artwork
                artworkView

                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(isPlaying ? .semibold : .regular)
                        .foregroundStyle(textPrimaryColor)
                        .lineLimit(1)

                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(textSecondaryColor)
                        .lineLimit(1)
                }

                Spacer()

                // Playing indicator or Missing icon
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("File missing")
                } else if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative)
                }

                // Duration
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundStyle(textTertiaryColor)
                    .monospacedDigit()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .opacity(isMissing ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isMissing && !isPlaying)  // specific behavior
    }

    // MARK: - Computed Properties

    private var isMissing: Bool {
        track.availability == .missing
    }

    private var textPrimaryColor: Color {
        if isMissing { return .secondary }
        return isPlaying ? Color.accentColor : ColorTokens.textPrimary
    }

    private var textSecondaryColor: Color {
        if isMissing { return Color.gray.opacity(0.6) }
        return ColorTokens.textSecondary
    }

    private var textTertiaryColor: Color {
        ColorTokens.textTertiary
    }

    // MARK: - Subviews

    @ViewBuilder
    private var artworkView: some View {
        if let artworkData = track.artworkData,
            let nsImage = NSImage(data: artworkData)
        {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(
                    width: Constants.Layout.artworkSmallSize,
                    height: Constants.Layout.artworkSmallSize
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .grayscale(isMissing ? 1.0 : 0.0)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.6), .blue.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(
                    width: Constants.Layout.artworkSmallSize,
                    height: Constants.Layout.artworkSmallSize
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .grayscale(isMissing ? 1.0 : 0.0)
        }
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func handleTap() {
        if !isMissing {
            onTap()
        }
    }
}

// MARK: - Preview

#Preview("Track Row") {
    VStack(spacing: 0) {
        TrackRowView(
            track: Track(
                title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
                fileBookmarkData: Data()),
            isPlaying: false,
            onTap: {}
        )

        Divider()

        TrackRowView(
            track: Track(
                title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera",
                duration: 354, fileBookmarkData: Data()),
            isPlaying: true,
            onTap: {}
        )

        Divider()

        // Missing track
        TrackRowView(
            track: Track(
                title: "Missing Song", artist: "Unknown", album: "Lost",
                duration: 120, fileBookmarkData: Data(), availability: .missing),
            isPlaying: false,
            onTap: {}
        )
    }
    .frame(width: 400)
    .padding()
}

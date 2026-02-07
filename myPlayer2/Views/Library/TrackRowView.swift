//
//  TrackRowView.swift
//  myPlayer2
//
//  TrueMusic - Track Row View
//  Displays a single track in a list.
//  Supports responsive layout (Side-by-side vs Stacked) and inline Menu.
//

import SwiftUI

/// Row view for displaying a track in a list.
struct TrackRowView<MenuContent: View>: View {

    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            artworkView

            // Track info (Responsive)
            ViewThatFits(in: .horizontal) {
                // 1. Horizontal Layout (Title left, Artist center)
                HStack(alignment: .center, spacing: 8) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(isPlaying ? .semibold : .regular)
                        .foregroundStyle(textPrimaryColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if track.artist.isEmpty {
                        Text("library.unknown_artist")
                            .font(.subheadline)
                            .foregroundStyle(textSecondaryColor)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundStyle(textSecondaryColor)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // 2. Vertical Layout (Stacked)
                // Fallback when width is small
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(isPlaying ? .semibold : .regular)
                        .foregroundStyle(textPrimaryColor)
                        .lineLimit(1)

                    Text(
                        track.artist.isEmpty
                            ? NSLocalizedString("library.unknown_artist", comment: "")
                            : track.artist
                    )
                    .font(.subheadline)
                    .foregroundStyle(textSecondaryColor)
                    .lineLimit(1)
                }
            }
            .contentShape(Rectangle())

            // Playing indicator or Missing icon
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("library.file_missing")
            } else if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(themeStore.accentColor)
                    .symbolEffect(.variableColor.iterative)
            }

            // Duration
            Text(formattedDuration)
                .font(.caption)
                .foregroundStyle(textTertiaryColor)
                .monospacedDigit()

            // Menu Button (Three dots - pure ellipsis)
            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover in
            isHovering = hover
        }
        .onTapGesture {
            handleTap()
        }
    }

    // MARK: - Computed Properties

    private var isMissing: Bool {
        track.availability == .missing
    }

    private var textPrimaryColor: Color {
        if isMissing { return .secondary }
        return isPlaying ? themeStore.accentColor : ColorTokens.textPrimary
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
        ) {
            Button("Play") {}
            Button("Add to Playlist") {}
        }
        .environmentObject(ThemeStore.shared)

        Divider()

        TrackRowView(
            track: Track(
                title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera",
                duration: 354, fileBookmarkData: Data()),
            isPlaying: true,
            onTap: {}
        ) {
            Button("Play") {}
        }
        .environmentObject(ThemeStore.shared)
    }
    .frame(width: 400)
    .padding()
}

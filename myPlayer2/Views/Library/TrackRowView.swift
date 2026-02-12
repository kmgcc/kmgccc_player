//
//  TrackRowView.swift
//  myPlayer2
//
//  TrueMusic - Track Row View
//  Displays a single track in a list.
//  Supports responsive layout (Side-by-side vs Stacked) and inline Menu.
//

import SwiftUI

private final class TrackArtworkThumbnailCache {
    static let shared = TrackArtworkThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// Row view for displaying a track in a list.
struct TrackRowView<MenuContent: View>: View {

    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void
    @ViewBuilder let menuContent: () -> MenuContent

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isHovering = false
    @State private var artworkImage: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            artworkView

            // Track info (Responsive)
            ViewThatFits(in: .horizontal) {
                // 1. Horizontal Layout (Title left, Artist center)
                HStack(alignment: .center, spacing: 8) {
                    MarqueeText(
                        text: track.title,
                        font: .body,
                        fontWeight: isPlaying ? .semibold : .regular,
                        color: textPrimaryColor
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)

                    MarqueeText(
                        text: artistDisplayText,
                        font: .subheadline,
                        fontWeight: .regular,
                        color: textSecondaryColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 2. Vertical Layout (Stacked)
                // Fallback when width is small
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: track.title,
                        font: .body,
                        fontWeight: isPlaying ? .semibold : .regular,
                        color: textPrimaryColor
                    )

                    MarqueeText(
                        text: artistDisplayText,
                        font: .subheadline,
                        fontWeight: .regular,
                        color: textSecondaryColor
                    )
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
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(height: Constants.Layout.trackRowHeight)
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
        .task(id: track.id) {
            await loadArtworkIfNeeded()
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

    private var artistDisplayText: String {
        track.artist.isEmpty
            ? NSLocalizedString("library.unknown_artist", comment: "")
            : track.artist
    }

    // MARK: - Subviews

    @ViewBuilder
    private var artworkView: some View {
        if let artworkImage {
            Image(nsImage: artworkImage)
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

    private func loadArtworkIfNeeded() async {
        let key = track.id.uuidString

        if let cached = TrackArtworkThumbnailCache.shared.image(for: key) {
            if artworkImage !== cached {
                artworkImage = cached
            }
            return
        }

        guard let artworkData = track.artworkData else {
            artworkImage = nil
            return
        }

        let decoded = await Task.detached(priority: .utility) {
            NSImage(data: artworkData)
        }.value

        guard let decoded else {
            artworkImage = nil
            return
        }

        TrackArtworkThumbnailCache.shared.setImage(decoded, for: key)
        artworkImage = decoded
    }
}

extension TrackRowView: Equatable where MenuContent: View {
    static func == (lhs: TrackRowView<MenuContent>, rhs: TrackRowView<MenuContent>) -> Bool {
        lhs.track.id == rhs.track.id
            && lhs.track.title == rhs.track.title
            && lhs.track.artist == rhs.track.artist
            && lhs.track.duration == rhs.track.duration
            && lhs.track.availability == rhs.track.availability
            && lhs.track.artworkData?.count == rhs.track.artworkData?.count
            && lhs.isPlaying == rhs.isPlaying
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

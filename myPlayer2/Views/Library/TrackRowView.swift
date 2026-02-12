//
//  TrackRowView.swift
//  myPlayer2
//
//  TrueMusic - Track Row View
//  Displays a single track row using pure row data.
//

import AppKit
import SwiftUI

struct TrackRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let artist: String
    let durationText: String
    let artworkData: Data?
    let artworkCacheKey: String
    let isMissing: Bool

    static func == (lhs: TrackRowModel, rhs: TrackRowModel) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.durationText == rhs.durationText
            && lhs.artworkCacheKey == rhs.artworkCacheKey
            && lhs.isMissing == rhs.isMissing
    }
}

/// Row view for displaying a track in a list.
struct TrackRowView<MenuContent: View>: View {
    let model: TrackRowModel
    let isPlaying: Bool
    let onTap: () -> Void
    let onRowAppear: (() -> Void)?
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false
    @State private var artworkImage: NSImage?
    @State private var isArtworkReady = false

    init(
        model: TrackRowModel,
        isPlaying: Bool,
        onTap: @escaping () -> Void,
        onRowAppear: (() -> Void)? = nil,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.model = model
        self.isPlaying = isPlaying
        self.onTap = onTap
        self.onRowAppear = onRowAppear
        self.menuContent = menuContent
    }

    var body: some View {
        let _ = PlaylistPerfDiagnostics.markRowBodyRecompute()

        HStack(spacing: 12) {
            artworkView

            HStack(spacing: 10) {
                MarqueeText(
                    text: model.title,
                    style: .body,
                    fontWeight: isPlaying ? .semibold : .regular,
                    color: textPrimaryColor
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                MarqueeText(
                    text: artistText,
                    style: .subheadline,
                    fontWeight: .regular,
                    color: textSecondaryColor
                )
                .frame(width: 220, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)

            if model.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("library.file_missing")
            } else if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            Text(model.durationText)
                .font(.caption)
                .foregroundStyle(ColorTokens.textTertiary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)

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
            if !model.isMissing {
                onTap()
            }
        }
        .onAppear {
            onRowAppear?()
        }
        .task(id: model.artworkCacheKey) {
            await loadArtwork()
        }
    }

    private var artistText: String {
        model.artist.isEmpty
            ? NSLocalizedString("library.unknown_artist", comment: "")
            : model.artist
    }

    private var textPrimaryColor: Color {
        if model.isMissing { return .secondary }
        return isPlaying ? Color.accentColor : ColorTokens.textPrimary
    }

    private var textSecondaryColor: Color {
        if model.isMissing { return Color.gray.opacity(0.6) }
        return ColorTokens.textSecondary
    }

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
                .grayscale(model.isMissing ? 1.0 : 0.0)
                .opacity(isArtworkReady ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.20), value: isArtworkReady)
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
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
            .grayscale(model.isMissing ? 1.0 : 0.0)
    }

    @MainActor
    private func loadArtwork() async {
        guard let data = model.artworkData, !data.isEmpty else {
            artworkImage = nil
            isArtworkReady = false
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * scale,
            height: Constants.Layout.artworkSmallSize * scale
        )

        let image = await ArtworkLoader.loadImage(
            artworkData: data,
            cacheKey: model.artworkCacheKey,
            targetPixelSize: targetPixels
        )

        guard !Task.isCancelled else { return }

        if let image {
            artworkImage = image
            isArtworkReady = false
            withAnimation(.easeInOut(duration: 0.20)) {
                isArtworkReady = true
            }
        } else {
            artworkImage = nil
            isArtworkReady = false
        }
    }
}

extension TrackRowView: Equatable where MenuContent: View {
    static func == (lhs: TrackRowView<MenuContent>, rhs: TrackRowView<MenuContent>) -> Bool {
        lhs.model == rhs.model
            && lhs.isPlaying == rhs.isPlaying
    }
}

// MARK: - Preview

#Preview("Track Row") {
    VStack(spacing: 0) {
        TrackRowView(
            model: TrackRowModel(
                id: UUID(),
                title: "Blinding Lights",
                artist: "The Weeknd",
                durationText: "3:23",
                artworkData: nil,
                artworkCacheKey: "demo",
                isMissing: false
            ),
            isPlaying: true,
            onTap: {}
        ) {
            Button("Play") {}
            Button("Delete", role: .destructive) {}
        }

        Divider()

        TrackRowView(
            model: TrackRowModel(
                id: UUID(),
                title: "Missing Track",
                artist: "Unknown Artist",
                durationText: "0:00",
                artworkData: nil,
                artworkCacheKey: "missing",
                isMissing: true
            ),
            isPlaying: false,
            onTap: {}
        ) {
            Button("Info") {}
        }
    }
    .padding()
}

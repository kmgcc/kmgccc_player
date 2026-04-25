//
//  TrackRowView.swift
//  myPlayer2
//
//  kmgccc_player - Track Row View
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
    let artworkFileURL: URL?
    let artworkIdentity: String
    let isMissing: Bool

    static func == (lhs: TrackRowModel, rhs: TrackRowModel) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.durationText == rhs.durationText
            && lhs.artworkIdentity == rhs.artworkIdentity
            && lhs.isMissing == rhs.isMissing
    }
}

/// Row view for displaying a track in a list.
struct TrackRowView<MenuContent: View>: View {
    let model: TrackRowModel
    let isPlaying: Bool
    let isSelected: Bool
    let enableSecondaryInteractions: Bool
    let enableArtworkLoading: Bool
    let onTap: () -> Void
    let onRowAppear: (() -> Void)?
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false
    @State private var artworkImage: NSImage?
    @State private var isArtworkReady = false

    @Environment(\.colorScheme) private var colorScheme

    private var artistColumnWidth: CGFloat { 164 }
    private var playingIndicatorColumnWidth: CGFloat { 20 }

    init(
        model: TrackRowModel,
        isPlaying: Bool,
        isSelected: Bool = false,
        enableSecondaryInteractions: Bool = true,
        enableArtworkLoading: Bool = true,
        onTap: @escaping () -> Void,
        onRowAppear: (() -> Void)? = nil,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.model = model
        self.isPlaying = isPlaying
        self.isSelected = isSelected
        self.enableSecondaryInteractions = enableSecondaryInteractions
        self.enableArtworkLoading = enableArtworkLoading
        self.onTap = onTap
        self.onRowAppear = onRowAppear
        self.menuContent = menuContent
    }

    var body: some View {
        let _ = PlaylistPerfDiagnostics.markRowBodyRecompute()
        let _ = LyricsRuntimeProfile.increment("TrackRowView.body")
        let _ = LyricsRuntimeProfile.insertUniqueValue("TrackRowView.body.trackID", value: model.id.uuidString)
        if isPlaying {
            let _ = TintTimelineProbe.noteRootConsumer("TrackRowView.isPlaying")
        }
        if isSelected {
            let _ = TintTimelineProbe.noteRootConsumer("TrackRowView.isSelected")
        }

        HStack(spacing: 12) {
            artworkView

            HStack(spacing: 10) {
                SeamlessMarqueeText(
                    text: model.title,
                    style: .body,
                    fontWeight: isPlaying ? .semibold : .regular,
                    color: textPrimaryColor,
                    shouldAnimate: isPlaying || isHovering
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                SeamlessMarqueeText(
                    text: artistText,
                    style: .subheadline,
                    fontWeight: .regular,
                    color: textSecondaryColor,
                    shouldAnimate: isPlaying || isHovering
                )
                .frame(width: artistColumnWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)

            if model.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("library.file_missing")
                    .frame(width: playingIndicatorColumnWidth)
            } else if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: playingIndicatorColumnWidth)
            } else {
                Color.clear
                    .frame(width: playingIndicatorColumnWidth)
            }

            Text(model.durationText)
                .font(.caption)
                .foregroundStyle(ColorTokens.textTertiary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)

            if enableSecondaryInteractions {
                Menu {
                    menuContent()
                } label: {
                    trailingMenuGlyph
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                trailingMenuGlyph
                    .opacity(0.72)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(height: Constants.Layout.trackRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        .onHover { hover in
            guard enableSecondaryInteractions else { return }
            isHovering = hover
        }
        .onTapGesture {
            if !model.isMissing {
                onTap()
            }
        }
        .onAppear {
            LyricsRuntimeProfile.increment("TrackRowView.onAppear")
            LyricsRuntimeProfile.insertUniqueValue("TrackRowView.onAppear.trackID", value: model.id.uuidString)
            onRowAppear?()
        }
        .task(id: artworkTaskIdentity) {
            await loadArtwork()
        }
        .onChange(of: enableSecondaryInteractions) { _, enabled in
            if !enabled {
                isHovering = false
            }
        }
    }

    private var artworkTaskIdentity: String {
        enableArtworkLoading ? model.artworkIdentity : "paused-\(model.id.uuidString)"
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

    private var backgroundFill: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }

    private var trailingMenuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
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
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
        ArtworkPlaceholderView.trackRow(isGrayscale: model.isMissing)
    }

    @MainActor
    private func loadArtwork() async {
        guard enableArtworkLoading else { return }

        let hasData = model.artworkData != nil && !model.artworkData!.isEmpty
        let hasFileURL = model.artworkFileURL != nil
        guard hasData || hasFileURL else {
            artworkImage = nil
            isArtworkReady = false
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let lowRequest = PlaylistArtworkPipeline.rowLowRequest(
            trackID: model.id,
            artworkData: model.artworkData,
            artworkFileURL: model.artworkFileURL,
            artworkIdentity: model.artworkIdentity,
            logicalSize: Constants.Layout.artworkSmallSize,
            scale: scale
        )
        let highRequest = PlaylistArtworkPipeline.rowHighRequest(
            trackID: model.id,
            artworkData: model.artworkData,
            artworkFileURL: model.artworkFileURL,
            artworkIdentity: model.artworkIdentity,
            logicalSize: Constants.Layout.artworkSmallSize,
            scale: scale
        )

        if let cachedHigh = await PlaylistArtworkPipeline.shared.cachedImage(for: highRequest) {
            artworkImage = cachedHigh
            isArtworkReady = true
            return
        }

        guard !Task.isCancelled else { return }

        if let lowImage = await PlaylistArtworkPipeline.shared.load(lowRequest) {
            artworkImage = lowImage
            isArtworkReady = true
        }

        guard !Task.isCancelled else { return }

        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }

        if let highImage = await PlaylistArtworkPipeline.shared.load(highRequest) {
            artworkImage = highImage
            withAnimation(.easeInOut(duration: 0.05)) {
                isArtworkReady = true
            }
        } else if artworkImage == nil {
            artworkImage = nil
            isArtworkReady = false
        }
    }
}

extension TrackRowView: Equatable where MenuContent: View {
    static func == (lhs: TrackRowView<MenuContent>, rhs: TrackRowView<MenuContent>) -> Bool {
        lhs.model == rhs.model
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isSelected == rhs.isSelected
            && lhs.enableSecondaryInteractions == rhs.enableSecondaryInteractions
            && lhs.enableArtworkLoading == rhs.enableArtworkLoading
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
                artworkFileURL: nil,
                artworkIdentity: "demo",
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
                artworkFileURL: nil,
                artworkIdentity: "missing",
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

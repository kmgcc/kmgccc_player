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
    let lyricSnippetLine: String?
    let lyricHighlightRanges: [SearchHighlightRange]
    let durationText: String
    let artworkData: Data?
    let artworkFileURL: URL?
    let artworkIdentity: String
    let isMissing: Bool

    static func == (lhs: TrackRowModel, rhs: TrackRowModel) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.lyricSnippetLine == rhs.lyricSnippetLine
            && lhs.lyricHighlightRanges == rhs.lyricHighlightRanges
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
    let onTap: (_ isShiftPressed: Bool) -> Void
    let onRowAppear: (() -> Void)?
    /// Optional palette override from parent. Defaults to system colors so
    /// callers that have no ThemeStore access still work correctly.
    var rowPrimaryColor: Color = ColorTokens.textPrimary
    var rowSecondaryColor: Color = ColorTokens.textSecondary
    var rowTertiaryColor: Color = ColorTokens.textTertiary
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
        onTap: @escaping (_ isShiftPressed: Bool) -> Void,
        onRowAppear: (() -> Void)? = nil,
        rowPrimaryColor: Color = ColorTokens.textPrimary,
        rowSecondaryColor: Color = ColorTokens.textSecondary,
        rowTertiaryColor: Color = ColorTokens.textTertiary,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.model = model
        self.isPlaying = isPlaying
        self.isSelected = isSelected
        self.enableSecondaryInteractions = enableSecondaryInteractions
        self.enableArtworkLoading = enableArtworkLoading
        self.onTap = onTap
        self.onRowAppear = onRowAppear
        self.rowPrimaryColor = rowPrimaryColor
        self.rowSecondaryColor = rowSecondaryColor
        self.rowTertiaryColor = rowTertiaryColor
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

        HStack(spacing: Constants.Layout.TrackRow.horizontalSpacing) {
            artworkView

            VStack(alignment: .leading, spacing: Constants.Layout.TrackRow.textVerticalSpacing) {
                HStack(spacing: Constants.Layout.TrackRow.textColumnSpacing) {
                    SeamlessMarqueeText(
                        text: model.title,
                        fontSize: Constants.Layout.TrackRow.titleFontSize,
                        fontWeight: isPlaying ? .semibold : .regular,
                        color: textPrimaryColor,
                        shouldAnimate: isPlaying || isHovering
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    SeamlessMarqueeText(
                        text: artistText,
                        fontSize: Constants.Layout.TrackRow.subtitleFontSize,
                        fontWeight: .regular,
                        color: textSecondaryColor,
                        shouldAnimate: isPlaying || isHovering
                    )
                    .frame(width: artistColumnWidth, alignment: .leading)
                }
                .frame(height: Constants.Layout.TrackRow.titleLineHeight)

                if let lyricSnippetAttributedString {
                    Text(lyricSnippetAttributedString)
                        .font(.system(size: Constants.Layout.TrackRow.lyricSnippetFontSize))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(lyricSnippetPlainText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("library.file_missing")
                    .frame(width: playingIndicatorColumnWidth)
            } else if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: Constants.Layout.TrackRow.playingIndicatorFontSize, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: playingIndicatorColumnWidth)
            } else {
                Color.clear
                    .frame(width: playingIndicatorColumnWidth)
            }

            Text(model.durationText)
                .font(.system(size: Constants.Layout.TrackRow.durationFontSize, weight: .regular))
                .foregroundStyle(rowTertiaryColor)
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
        .padding(.vertical, Constants.Layout.TrackRow.verticalPadding)
        .padding(.horizontal, Constants.Layout.TrackRow.horizontalPadding)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.cornerRadius)
                .fill(backgroundFill)
        )
        .contentShape(Rectangle())
        .onHover { hover in
            guard enableSecondaryInteractions else { return }
            isHovering = hover
        }
        .onTapGesture {
            if !model.isMissing {
                onTap(Self.isShiftPressed)
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
        return isPlaying ? Color.accentColor : rowPrimaryColor
    }

    private var textSecondaryColor: Color {
        if model.isMissing { return Color.gray.opacity(0.6) }
        return rowSecondaryColor
    }

    private var rowHeight: CGFloat {
        hasLyricSnippet ? Constants.Layout.TrackRow.lyricSnippetHeight : Constants.Layout.TrackRow.height
    }

    private var hasLyricSnippet: Bool {
        !lyricSnippetPlainText.isEmpty
    }

    private var lyricSnippetPlainText: String {
        model.lyricSnippetLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var lyricSnippetAttributedString: AttributedString? {
        let snippet = lyricSnippetPlainText
        guard !snippet.isEmpty else { return nil }

        var attributed = AttributedString(snippet)
        attributed.foregroundColor = rowTertiaryColor
        attributed.font = .system(size: Constants.Layout.TrackRow.lyricSnippetFontSize)

        for highlightRange in model.lyricHighlightRanges {
            guard let stringRange = characterRange(
                location: highlightRange.location,
                length: highlightRange.length,
                in: snippet
            ),
            let attributedRange = Range(stringRange, in: attributed)
            else { continue }

            attributed[attributedRange].foregroundColor = Color.accentColor
            attributed[attributedRange].font = Font
                .system(size: Constants.Layout.TrackRow.lyricSnippetFontSize)
                .weight(.semibold)
        }

        return attributed
    }

    private func characterRange(location: Int, length: Int, in value: String) -> Range<String.Index>? {
        guard location >= 0, length > 0, location < value.count else { return nil }
        let start = value.index(value.startIndex, offsetBy: location)
        let upperBound = min(value.count, location + length)
        guard upperBound > location else { return nil }
        let end = value.index(value.startIndex, offsetBy: upperBound)
        return start..<end
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }

    private var trailingMenuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: Constants.Layout.TrackRow.trailingMenuGlyphSize, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(
                width: Constants.Layout.TrackRow.trailingMenuHitSize,
                height: Constants.Layout.TrackRow.trailingMenuHitSize
            )
            .contentShape(Rectangle())
    }

    private static var isShiftPressed: Bool {
        if let currentEvent = NSApp.currentEvent {
            return currentEvent.modifierFlags.contains(.shift)
        }
        return NSEvent.modifierFlags.contains(.shift)
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
                .clipShape(RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius))
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
            && lhs.rowPrimaryColor == rhs.rowPrimaryColor
            && lhs.rowSecondaryColor == rhs.rowSecondaryColor
            && lhs.rowTertiaryColor == rhs.rowTertiaryColor
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
                lyricSnippetLine: "I said, ooh, I'm blinded by the lights",
                lyricHighlightRanges: [SearchHighlightRange(location: 18, length: 7)],
                durationText: "3:23",
                artworkData: nil,
                artworkFileURL: nil,
                artworkIdentity: "demo",
                isMissing: false
            ),
            isPlaying: true,
            onTap: { _ in }
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
                lyricSnippetLine: nil,
                lyricHighlightRanges: [],
                durationText: "0:00",
                artworkData: nil,
                artworkFileURL: nil,
                artworkIdentity: "missing",
                isMissing: true
            ),
            isPlaying: false,
            onTap: { _ in }
        ) {
            Button("Info") {}
        }
    }
    .padding()
}

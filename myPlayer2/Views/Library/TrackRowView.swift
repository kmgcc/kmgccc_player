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
    let lyricSnippetStartTime: Double?
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
            && lhs.lyricSnippetStartTime == rhs.lyricSnippetStartTime
            && lhs.lyricHighlightRanges == rhs.lyricHighlightRanges
            && lhs.durationText == rhs.durationText
            && lhs.artworkIdentity == rhs.artworkIdentity
            && lhs.isMissing == rhs.isMissing
    }
}

struct TrackRowSelectionContinuity: Equatable {
    let connectsToPrevious: Bool
    let connectsToNext: Bool

    static let isolated = TrackRowSelectionContinuity(
        connectsToPrevious: false,
        connectsToNext: false
    )
}

/// Row view for displaying a track in a list.
struct TrackRowView<MenuContent: View>: View {
    let model: TrackRowModel
    let isPlaying: Bool
    let isSelected: Bool
    let selectionContinuity: TrackRowSelectionContinuity
    let showsSelectionBackground: Bool
    let enableSecondaryInteractions: Bool
    let enableArtworkLoading: Bool
    let onTap: (_ isShiftPressed: Bool) -> Void
    let onLyricSnippetTap: (() -> Void)?
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
        selectionContinuity: TrackRowSelectionContinuity = .isolated,
        showsSelectionBackground: Bool = true,
        enableSecondaryInteractions: Bool = true,
        enableArtworkLoading: Bool = true,
        onTap: @escaping (_ isShiftPressed: Bool) -> Void,
        onLyricSnippetTap: (() -> Void)? = nil,
        onRowAppear: (() -> Void)? = nil,
        rowPrimaryColor: Color = ColorTokens.textPrimary,
        rowSecondaryColor: Color = ColorTokens.textSecondary,
        rowTertiaryColor: Color = ColorTokens.textTertiary,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.model = model
        self.isPlaying = isPlaying
        self.isSelected = isSelected
        self.selectionContinuity = selectionContinuity
        self.showsSelectionBackground = showsSelectionBackground
        self.enableSecondaryInteractions = enableSecondaryInteractions
        self.enableArtworkLoading = enableArtworkLoading
        self.onTap = onTap
        self.onLyricSnippetTap = onLyricSnippetTap
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
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.rowBodyUpdate",
            detail: "track=\(FirstUseHitchDiagnostics.trackIDPrefix(model.id)), isPlaying=\(isPlaying), isHovering=\(isHovering), isSelected=\(isSelected)"
        )
        if isPlaying {
            let _ = TintTimelineProbe.noteRootConsumer("TrackRowView.isPlaying")
        }
        if isSelected {
            let _ = TintTimelineProbe.noteRootConsumer("TrackRowView.isSelected")
        }

        HStack(spacing: Constants.Layout.TrackRow.horizontalSpacing) {
            artworkView

            HStack(alignment: .center, spacing: Constants.Layout.TrackRow.textColumnSpacing) {
                VStack(alignment: .leading, spacing: Constants.Layout.TrackRow.textVerticalSpacing) {
                    SeamlessMarqueeText(
                        text: model.title,
                        fontSize: Constants.Layout.TrackRow.titleFontSize,
                        fontWeight: isPlaying ? .semibold : .regular,
                        color: textPrimaryColor,
                        shouldAnimate: isPlaying || isHovering
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    lyricSnippetView
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SeamlessMarqueeText(
                    text: artistText,
                    fontSize: Constants.Layout.TrackRow.subtitleFontSize,
                    fontWeight: .regular,
                    color: textSecondaryColor,
                    shouldAnimate: isPlaying || isHovering
                )
                .frame(width: artistColumnWidth, alignment: .leading)
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
        .background(rowBackground)
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

    private var canJumpToLyricSnippet: Bool {
        onLyricSnippetTap != nil && model.lyricSnippetStartTime != nil
    }

    private var lyricSnippetPlainText: String {
        model.lyricSnippetLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    @ViewBuilder
    private var lyricSnippetView: some View {
        if let lyricSnippetAttributedString {
            if canJumpToLyricSnippet {
                Button {
                    onLyricSnippetTap?()
                } label: {
                    lyricSnippetText(lyricSnippetAttributedString)
                }
                .buttonStyle(.plain)
                .help("从这句歌词开始播放")
            } else {
                lyricSnippetText(lyricSnippetAttributedString)
            }
        }
    }

    private func lyricSnippetText(_ attributedString: AttributedString) -> some View {
        Text(attributedString)
            .font(.system(size: Constants.Layout.TrackRow.lyricSnippetFontSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityLabel(lyricSnippetPlainText)
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
        if isSelected && showsSelectionBackground {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
        }
        if isSelected {
            return Color.clear
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected && showsSelectionBackground {
            let radius = Constants.Layout.TrackRow.cornerRadius
            TrackRowSelectionBackgroundShape(
                continuity: selectionContinuity,
                cornerRadius: radius
            )
            .fill(backgroundFill)
            .padding(.top, selectionContinuity.connectsToPrevious ? -0.75 : 0)
            .padding(.bottom, selectionContinuity.connectsToNext ? -0.75 : 0)
        } else {
            RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.cornerRadius)
                .fill(backgroundFill)
        }
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

private struct TrackRowSelectionBackgroundShape: Shape {
    let continuity: TrackRowSelectionContinuity
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topRadius = continuity.connectsToPrevious ? 0 : radius
        let bottomRadius = continuity.connectsToNext ? 0 : radius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        addCorner(
            to: &path,
            radius: topRadius,
            lineEnd: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        addCorner(
            to: &path,
            radius: bottomRadius,
            lineEnd: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        addCorner(
            to: &path,
            radius: bottomRadius,
            lineEnd: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        addCorner(
            to: &path,
            radius: topRadius,
            lineEnd: CGPoint(x: rect.minX + topRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    private func addCorner(
        to path: inout Path,
        radius: CGFloat,
        lineEnd: CGPoint,
        control: CGPoint
    ) {
        if radius > 0 {
            path.addQuadCurve(to: lineEnd, control: control)
        } else {
            path.addLine(to: control)
        }
    }
}

extension TrackRowView: Equatable where MenuContent: View {
    static func == (lhs: TrackRowView<MenuContent>, rhs: TrackRowView<MenuContent>) -> Bool {
            lhs.model == rhs.model
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isSelected == rhs.isSelected
            && lhs.selectionContinuity == rhs.selectionContinuity
            && lhs.showsSelectionBackground == rhs.showsSelectionBackground
            && lhs.enableSecondaryInteractions == rhs.enableSecondaryInteractions
            && lhs.enableArtworkLoading == rhs.enableArtworkLoading
            && (lhs.onLyricSnippetTap == nil) == (rhs.onLyricSnippetTap == nil)
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
                lyricSnippetStartTime: 42.1,
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
                lyricSnippetStartTime: nil,
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

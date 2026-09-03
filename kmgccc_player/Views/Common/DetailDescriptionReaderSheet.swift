//
//  DetailDescriptionReaderSheet.swift
//  myPlayer2
//
//  kmgccc_player - Detail Description Reader Sheet
//  Window-attached macOS modal sheet for viewing long description text with
//  minimalist metadata styling, refined typography, and generous line spacing.
//

import AppKit
import SwiftUI

struct DetailDescriptionReaderSheet: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    let text: String
    var artworkImage: NSImage? = nil
    var artworkData: Data? = nil
    var isCircleArtwork: Bool = false
    var paletteOverride: AppForegroundPalette? = nil
    var accentColorOverride: Color? = nil
    var attributionNote: String? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

    private var foregroundPalette: AppForegroundPalette {
        paletteOverride ?? themeStore.appForegroundPalette
    }

    private var accentColor: Color {
        accentColorOverride ?? themeStore.accentColor
    }

    private var resolvedArtwork: NSImage? {
        if let artworkImage { return artworkImage }
        if let artworkData { return NSImage(data: artworkData) }
        return nil
    }

    private var paragraphs: [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let split = normalized.components(separatedBy: "\n\n")
        let trimmed = split.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? [text] : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if hasEntitySummary {
                        minimalEntityHeader
                    }

                    textContentSection
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 580, height: 580)
        .tint(accentColor)
    }

    // MARK: - Top Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(foregroundPalette.primaryColor)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foregroundPalette.secondaryColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
            .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Minimal Entity Header

    private var hasEntitySummary: Bool {
        resolvedArtwork != nil || (subtitle != nil && !subtitle!.isEmpty) || (attributionNote != nil && !attributionNote!.isEmpty)
    }

    @ViewBuilder
    private var minimalEntityHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            if let image = resolvedArtwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(
                        isCircleArtwork
                            ? AnyShape(Circle())
                            : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    )
                    .overlay {
                        if isCircleArtwork {
                            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(foregroundPalette.primaryColor)
                        .lineLimit(2)
                }

                if let attributionNote, !attributionNote.isEmpty {
                    Text(attributionNote)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(foregroundPalette.secondaryColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Text Content

    private var textContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyStateView
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 15, weight: .regular))
                        .lineSpacing(8.5)
                        .foregroundStyle(foregroundPalette.primaryColor.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 32))
                .foregroundStyle(foregroundPalette.secondaryColor.opacity(0.6))

            Text("暂无详细介绍")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foregroundPalette.secondaryColor)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

// MARK: - Track Detail Content & Resolver

struct TrackDetailContent {
    let title: String
    let subtitle: String
    let attributionNote: String?
    let text: String
}

enum TrackDetailResolver {
    static func resolve(for track: Track, libraryVM: LibraryViewModel?) -> TrackDetailContent {
        let title = "歌曲详情"
        let subtitle: String
        if !track.title.isEmpty, !track.artist.isEmpty {
            subtitle = "\(track.title) - \(track.artist)"
        } else if !track.title.isEmpty {
            subtitle = track.title
        } else if !track.artist.isEmpty {
            subtitle = track.artist
        } else {
            subtitle = "未知歌曲"
        }

        let desc = track.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            return TrackDetailContent(
                title: title,
                subtitle: subtitle,
                attributionNote: nil,
                text: desc
            )
        }

        if let album = libraryVM?.albumEntries.first(where: { $0.canonicalKey == track.albumGroupKey }) {
            let albumDesc = album.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !albumDesc.isEmpty {
                return TrackDetailContent(
                    title: title,
                    subtitle: subtitle,
                    attributionNote: "来自 \(album.displayTitle)",
                    text: albumDesc
                )
            }
        }

        let artistKey = LibraryNormalization.artistComponents(for: track).first?.canonicalName
            ?? LibraryNormalization.artistComponents(track.artist).first?.canonicalName
            ?? ""
        if let artistEntry = libraryVM?.artistEntries.first(where: { $0.canonicalName == artistKey }) {
            let artistDesc = artistEntry.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !artistDesc.isEmpty {
                return TrackDetailContent(
                    title: title,
                    subtitle: subtitle,
                    attributionNote: "来自 \(artistEntry.displayName)",
                    text: artistDesc
                )
            }
        }

        return TrackDetailContent(
            title: title,
            subtitle: subtitle,
            attributionNote: nil,
            text: ""
        )
    }
}

// MARK: - Track Detail Sheet Helper

struct TrackDetailDescriptionSheet: View {
    let track: Track
    @Environment(LibraryViewModel.self) private var libraryVM: LibraryViewModel?
    @EnvironmentObject private var themeStore: ThemeStore

    private var resolvedDetail: TrackDetailContent {
        TrackDetailResolver.resolve(for: track, libraryVM: libraryVM)
    }

    var body: some View {
        DetailDescriptionReaderSheet(
            title: resolvedDetail.title,
            systemImage: "music.note",
            subtitle: resolvedDetail.subtitle,
            text: resolvedDetail.text,
            artworkData: track.artworkData,
            attributionNote: resolvedDetail.attributionNote
        )
        .environmentObject(themeStore)
    }
}

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

            GlassIconButton(
                systemImage: "xmark",
                size: GlassStyleTokens.headerControlHeight,
                iconSize: GlassStyleTokens.headerStandardIconSize,
                isPrimary: false,
                help: "关闭",
                surfaceVariant: .defaultToolbar
            ) {
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Minimal Entity Header

    private var hasEntitySummary: Bool {
        resolvedArtwork != nil || (subtitle != nil && !subtitle!.isEmpty)
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

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(foregroundPalette.primaryColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Text Content

    private var textContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
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

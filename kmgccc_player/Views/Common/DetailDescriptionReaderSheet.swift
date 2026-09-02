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

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

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
                VStack(alignment: .leading, spacing: 20) {
                    if hasEntitySummary {
                        minimalEntityHeader
                    }

                    textContentSection
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footerBar
        }
        .frame(width: 580, height: 600)
        .tint(themeStore.accentColor)
    }

    // MARK: - Top Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

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
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 6)
    }

    // MARK: - Text Content

    private var textContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(8.5)
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack {
            Spacer()

            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .keyboardShortcut(.escape)
            .keyboardShortcut(.return)
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

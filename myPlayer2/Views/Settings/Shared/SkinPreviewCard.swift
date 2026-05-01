//
//  SkinPreviewCard.swift
//  myPlayer2
//
//  kmgccc_player - Reusable skin selection card with preview and title.
//

import SwiftUI

/// A selectable card showing a skin preview thumbnail and its name.
/// Used in horizontal skin selectors for both window and fullscreen playback settings.
struct SkinPreviewCard<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let cardSize: CGSize
    let previewSize: CGFloat
    let cornerRadius: CGFloat
    let titleFontSize: CGFloat
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    private var selectionAccentColor: Color {
        FullscreenSelectionAccentStyle.adjustedAccentColor(from: themeStore.accentNSColor)
    }

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var contentPaddingH: CGFloat { 12 }
    private var contentPaddingV: CGFloat { 12 }
    private var innerSpacing: CGFloat { 10 }

    private var titleMinHeight: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinTitleMinHeight : 16
    }

    private var outerStrokeLineWidth: CGFloat {
        isSelected ? 2 : 1
    }

    init(
        title: String,
        isSelected: Bool,
        cardSize: CGSize = CGSize(width: 104, height: 124),
        previewSize: CGFloat = 80,
        cornerRadius: CGFloat = 12,
        titleFontSize: CGFloat = 11,
        @ViewBuilder preview: @escaping () -> Preview,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.cardSize = cardSize
        self.previewSize = previewSize
        self.cornerRadius = cornerRadius
        self.titleFontSize = titleFontSize
        self.preview = preview
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                outerShape
                    .fill(Color.clear)
                    .glassEffect(.clear, in: outerShape)
                    .overlay(
                        outerShape
                            .fill(isSelected ? selectionAccentColor.opacity(0.10) : Color.clear)
                            .allowsHitTesting(false)
                    )

                VStack(spacing: innerSpacing) {
                    preview()
                        .frame(width: previewSize, height: previewSize)

                    Text(title)
                        .font(.system(size: titleFontSize, weight: .medium))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: titleMinHeight)
                }
                .padding(.horizontal, contentPaddingH)
                .padding(.vertical, contentPaddingV)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(outerShape)
            .overlay(
                outerShape
                    .inset(by: outerStrokeLineWidth / 2)
                    .stroke(outerStrokeColor, lineWidth: outerStrokeLineWidth)
                    .allowsHitTesting(false)
            )
            .contentShape(outerShape)
        }
        .buttonStyle(SkinCardButtonStyle())
    }

    // MARK: - Appearance

    private var titleColor: Color {
        // Always neutral gray; never theme-tinted.
        if colorScheme == .dark {
            return Color.white.opacity(0.82)
        }
        return Color.black.opacity(0.62)
    }

    private var outerStrokeColor: Color {
        if isSelected {
            return selectionAccentColor.opacity(0.98)
        }
        if colorScheme == .dark {
            return Color.white.opacity(0.10)
        }
        return Color.black.opacity(0.08)
    }

}

// MARK: - Button Style

/// Removes default button styling while preserving hover/pressed feedback via opacity.
private struct SkinCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

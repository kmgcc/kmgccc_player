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

    private var innerInset: CGFloat {
        // Keep the inner surface clearly separated from the outer frame to avoid "double frame" dirt.
        presentationStyle.isCompact ? max(12, cornerRadius * 0.58) : max(12, cornerRadius * 0.62)
    }

    private var innerCornerRadius: CGFloat {
        max(10, cornerRadius - innerInset * 0.55)
    }

    private var innerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
    }

    private var innerPaddingH: CGFloat { 12 }
    private var innerPaddingV: CGFloat { 12 }
    private var innerSpacing: CGFloat { 10 }

    private var titleMinHeight: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinTitleMinHeight : 16
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
                    .overlay(
                        outerShape
                            .strokeBorder(outerStrokeColor, lineWidth: isSelected ? 2 : 1)
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
                .padding(.horizontal, innerPaddingH)
                .padding(.vertical, innerPaddingV)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(innerSurface)
                .clipShape(innerShape)
                .padding(innerInset)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(outerShape)
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

    private var innerSurface: some View {
        innerShape
            .fill(.ultraThinMaterial)
            .overlay(
                innerShape
                    .strokeBorder(innerStrokeColor, lineWidth: 0.6)
                    .allowsHitTesting(false)
            )
    }

    private var innerStrokeColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color.black.opacity(0.10)
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

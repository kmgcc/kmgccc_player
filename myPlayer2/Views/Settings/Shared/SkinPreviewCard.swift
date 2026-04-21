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

    private var contentInset: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinContentInset : max(4, cornerRadius * 0.28)
    }

    private var contentCornerRadius: CGFloat {
        max(8, cornerRadius - contentInset)
    }

    private var contentVerticalPadding: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinContentVerticalPadding : max(8, previewSize * 0.18)
    }

    private var contentHorizontalPadding: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinContentHorizontalPadding : max(8, previewSize * 0.16)
    }

    private var contentSpacing: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinContentSpacing : max(6, previewSize * 0.125)
    }

    private var titleMinHeight: CGFloat {
        presentationStyle.isCompact ? presentationStyle.skinTitleMinHeight : 16
    }

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var contentShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: contentCornerRadius, style: .continuous)
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
                background

                VStack(spacing: contentSpacing) {
                    preview()
                        .frame(width: 80, height: 80)
                        .scaleEffect((isSelected ? 1.07 : 1.0) * previewSize / 80)
                        .frame(width: previewSize, height: previewSize)
                        .shadow(
                            color: isSelected ? selectionAccentColor.opacity(0.24) : .clear,
                            radius: isSelected ? 12 : 0,
                            x: 0,
                            y: isSelected ? 4 : 0
                        )

                    Text(title)
                        .font(.system(size: titleFontSize, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(
                            presentationStyle.skinTitleColor(
                                selected: isSelected,
                                accentColor: selectionAccentColor,
                                colorScheme: colorScheme
                            )
                        )
                        .shadow(
                            color: isSelected ? Color.black.opacity(0.18) : .clear,
                            radius: 6,
                            x: 0,
                            y: 1
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: titleMinHeight)
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.vertical, contentVerticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(contentSurface)
                .clipShape(contentShape)
                .padding(contentInset)
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .background(
                outerShape
                    .fill(Color.clear)
            )
            .liquidGlassRect(
                cornerRadius: cornerRadius,
                colorScheme: colorScheme,
                accentColor: isSelected ? selectionAccentColor : nil,
                prominence: isSelected ? .prominent : .standard,
                materialStyle: presentationStyle.glassMaterialStyle,
                isFloating: false
            )
            .overlay(
                outerShape
                    .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(outerShape)
            .shadow(
                color: isSelected ? selectionAccentColor.opacity(0.20) : .clear,
                radius: isSelected ? 16 : 0,
                x: 0,
                y: isSelected ? 7 : 0
            )
        }
        .buttonStyle(SkinCardButtonStyle())
    }

    // MARK: - Appearance

    private var contentSurface: some View {
        contentShape
            .fill(contentSurfaceFill)
            .overlay(
                contentShape
                    .strokeBorder(contentSurfaceStroke, lineWidth: isSelected ? 1.3 : 0.7)
            )
            .overlay(
                contentShape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isSelected ? 0.08 : 0.04),
                                Color.white.opacity(0.018),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
    }

    private var contentSurfaceFill: Color {
        let base = GlassStyleTokens.pillOverlay(
            for: colorScheme,
            materialStyle: presentationStyle.glassMaterialStyle
        )
        if isSelected {
            return selectionAccentColor.opacity(0.09)
        }
        return base.opacity(presentationStyle.forcesWhiteText ? 0.84 : 0.68)
    }

    private var contentSurfaceStroke: Color {
        isSelected ? selectionAccentColor.opacity(0.42) : Color.white.opacity(0.10)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                isSelected
                    ? selectionAccentColor.opacity(colorScheme == .dark ? 0.16 : 0.12)
                    : Color.clear
            )
            .overlay(
                outerShape
                    .fill(
                        presentationStyle.forcesWhiteText
                            ? Color.white.opacity(isSelected ? 0.11 : 0.04)
                            : Color.secondary.opacity(0.04)
                    )
            )
            .overlay(
                outerShape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isSelected ? 0.12 : 0.05),
                                Color.white.opacity(0.02),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
    }

    private var borderColor: Color {
        if isSelected {
            return selectionAccentColor.opacity(0.96)
        }
        return Color.clear
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

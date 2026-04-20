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
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                preview()
                    .frame(width: 80, height: 80)

                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? themeStore.accentColor : Color.primary.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 104, height: 124)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SkinCardButtonStyle())
    }

    // MARK: - Appearance

    private var background: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? themeStore.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.08) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.04))
            )
    }

    private var borderColor: Color {
        if isSelected {
            return themeStore.accentColor.opacity(0.65)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.10)
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

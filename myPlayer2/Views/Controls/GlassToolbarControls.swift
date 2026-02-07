//
//  GlassToolbarControls.swift
//  myPlayer2
//
//  Liquid Glass toolbar controls (macOS 26)
//  - Glass is background only; content stays crisp above it.
//

import SwiftUI

/// Base icon button with Liquid Glass background and crisp foreground content.
struct GlassIconButtonLabel: View {
    enum SurfaceVariant {
        case defaultToolbar
        case sidebarBottom
    }

    let systemImage: String
    let size: CGFloat
    let iconSize: CGFloat
    let isPrimary: Bool
    let surfaceVariant: SurfaceVariant

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(isPrimary ? themeStore.accentColor : themeStore.textColor)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background(glassBackground)
            .overlay(
                Circle()
                    .strokeBorder(outlineColor, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [highlightColor, Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            )
    }

    @ViewBuilder
    private var glassBackground: some View {
        switch surfaceVariant {
        case .defaultToolbar:
            Circle()
                .glassEffect(.clear, in: .circle)
                .allowsHitTesting(false)
        case .sidebarBottom:
            // Skills: $macos-appkit-liquid-glass-controls + $macos-appkit-liquid-glass-guide
            // Keep icon crisp above glass; apply tint on top of glass layer so Light/Dark variance is visible.
            Circle()
                .glassEffect(.clear, in: .circle)
                .overlay(Circle().fill(sidebarBottomFill))
                .compositingGroup()
                .allowsHitTesting(false)
        }
    }

    private var sidebarBottomFill: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.26)
        }
        return Color.white.opacity(0.32)
    }

    private var outlineColor: Color {
        switch surfaceVariant {
        case .defaultToolbar:
            return Color.primary.opacity(0.12)
        case .sidebarBottom:
            return colorScheme == .dark
                ? Color.white.opacity(0.07)
                : Color.black.opacity(0.12)
        }
    }

    private var highlightColor: Color {
        switch surfaceVariant {
        case .defaultToolbar:
            return themeStore.textColor.opacity(0.16)
        case .sidebarBottom:
            return colorScheme == .dark
                ? themeStore.accentColor.opacity(0.08)
                : Color.white.opacity(0.20)
        }
    }
}

/// Base icon button with Liquid Glass background and crisp foreground content.
struct GlassIconButton: View {
    let systemImage: String
    let size: CGFloat
    let iconSize: CGFloat
    let isPrimary: Bool
    let help: LocalizedStringKey?
    let surfaceVariant: GlassIconButtonLabel.SurfaceVariant
    let action: () -> Void

    init(
        systemImage: String,
        size: CGFloat,
        iconSize: CGFloat,
        isPrimary: Bool,
        help: LocalizedStringKey? = nil,
        surfaceVariant: GlassIconButtonLabel.SurfaceVariant = .defaultToolbar,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.size = size
        self.iconSize = iconSize
        self.isPrimary = isPrimary
        self.help = help
        self.surfaceVariant = surfaceVariant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            GlassIconButtonLabel(
                systemImage: systemImage,
                size: size,
                iconSize: iconSize,
                isPrimary: isPrimary,
                surfaceVariant: surfaceVariant
            )
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .accessibilityLabel(help != nil ? Text(help!) : Text(systemImage))
    }
}

/// Toolbar-styled icon button with Liquid Glass sizing defaults.
struct GlassToolbarButton: View {
    enum Style {
        case standard
        case primary
    }

    let systemImage: String
    let help: LocalizedStringKey
    let style: Style
    let action: () -> Void

    static func iconSize(for style: Style) -> CGFloat {
        style == .primary
            ? GlassStyleTokens.headerPrimaryIconSize
            : GlassStyleTokens.headerStandardIconSize
    }

    var body: some View {
        GlassIconButton(
            systemImage: systemImage,
            size: style == .primary
                ? GlassStyleTokens.headerPrimaryControlHeight
                : GlassStyleTokens.headerControlHeight,
            iconSize: Self.iconSize(for: style),
            isPrimary: style == .primary,
            help: help,
            surfaceVariant: .defaultToolbar,
            action: action
        )
    }
}

/// Toolbar-styled menu button with Liquid Glass sizing defaults.
struct GlassToolbarMenuButton<Content: View>: View {
    let systemImage: String
    let help: LocalizedStringKey
    let style: GlassToolbarButton.Style
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            GlassIconButtonLabel(
                systemImage: systemImage,
                size: style == .primary
                    ? GlassStyleTokens.headerPrimaryControlHeight
                    : GlassStyleTokens.headerControlHeight,
                iconSize: GlassToolbarButton.iconSize(for: style),
                isPrimary: style == .primary,
                surfaceVariant: .defaultToolbar
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Unified pill for Play + Import in the header bar.
struct GlassToolbarPlayImportPill: View {
    let canPlay: Bool
    let onPlay: () -> Void
    let onImport: () -> Void
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(
                        .system(
                            size: GlassToolbarButton.iconSize(for: .primary),
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        canPlay ? themeStore.accentColor : themeStore.secondaryTextColor
                    )
                    .frame(
                        width: GlassStyleTokens.headerControlHeight,
                        height: GlassStyleTokens.headerControlHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .help("context.play_all")

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(
                    width: 0.5,
                    height: GlassStyleTokens.headerControlHeight - 12
                )

            Button(action: onImport) {
                Image(systemName: "plus")
                    .font(
                        .system(
                            size: GlassToolbarButton.iconSize(for: .standard),
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.primary)
                    .frame(
                        width: GlassStyleTokens.headerControlHeight,
                        height: GlassStyleTokens.headerControlHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("context.import")
        }
        .frame(height: GlassStyleTokens.headerControlHeight)
        // Skills: $macos-appkit-liquid-glass-toolbar + $macos-appkit-liquid-glass-controls
        // One grouped pill container, with separate hit regions for each action.
        .background(
            Capsule()
                .glassEffect(.clear, in: .capsule)
                .allowsHitTesting(false)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.16), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        )
        .clipShape(Capsule())
    }
}

/// Toolbar search field with Liquid Glass background.
struct GlassToolbarSearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .focused(focused)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("context.clear_search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: GlassStyleTokens.headerControlHeight)
        .frame(
            minWidth: GlassStyleTokens.headerSearchMinWidth,
            maxWidth: GlassStyleTokens.headerSearchMaxWidth
        )
        .background(
            RoundedRectangle(
                cornerRadius: GlassStyleTokens.headerControlCornerRadius,
                style: .continuous
            )
            .glassEffect(
                .clear,
                in: .rect(cornerRadius: GlassStyleTokens.headerControlCornerRadius)
            )
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: GlassStyleTokens.headerControlCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: GlassStyleTokens.headerControlCornerRadius,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.16),
                        Color.clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.5
            )
            .allowsHitTesting(false)
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: GlassStyleTokens.headerControlCornerRadius,
                style: .continuous
            )
        )
        .onTapGesture {
            focused.wrappedValue = true
        }
    }
}

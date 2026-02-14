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
            .foregroundStyle(iconForeground)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .liquidGlassCircle(
                colorScheme: colorScheme,
                accentColor: nil as Color?
            )
    }

    private var iconForeground: Color {
        if isPrimary {
            return themeStore.accentColor.opacity(colorScheme == .dark ? 0.98 : 0.90)
        }
        return themeStore.accentColor.opacity(colorScheme == .dark ? 0.94 : 0.84)
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

struct GlassToolbarTriplePill: View {
    let isMultiselectActive: Bool
    let onToggleMultiselect: () -> Void
    let canPlay: Bool
    let onPlay: () -> Void
    let onImport: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 0) {
            // Multiselect Button
            Button {
                onToggleMultiselect()
            } label: {
                Image(systemName: isMultiselectActive ? "checkmark.circle.fill" : "checkmark.circle")
                    .id(isMultiselectActive ? "multiselect-fill" : "multiselect-outline")
                    .font(
                        .system(
                            size: GlassToolbarButton.iconSize(for: .standard),
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(activeIconColor)
                    .contentTransition(
                        .symbolEffect(.replace.magic(fallback: .offUp.byLayer), options: .nonRepeating)
                    )
                    .animation(.snappy(duration: 0.22), value: isMultiselectActive)
                    .frame(
                        width: GlassStyleTokens.headerControlHeight,
                        height: GlassStyleTokens.headerControlHeight
                    )
                    .contentShape(Rectangle())
                    .background(
                        isMultiselectActive
                            ? themeStore.accentColor.opacity(0.1)
                            : Color.clear
                    )
            }
            .buttonStyle(.plain)
            .help("context.multiselect")

            divider

            // Play Button
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(
                        .system(
                            size: GlassToolbarButton.iconSize(for: .primary),
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        canPlay ? activeIconColor : themeStore.secondaryTextColor
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

            divider

            // Import Button
            Button(action: onImport) {
                Image(systemName: "plus")
                    .font(
                        .system(
                            size: GlassToolbarButton.iconSize(for: .standard),
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        activeIconColor
                    )
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
        .liquidGlassPill(colorScheme: colorScheme, accentColor: nil as Color?)
        .clipShape(Capsule())
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(
                width: 0.5,
                height: GlassStyleTokens.headerControlHeight - 12
            )
    }

    private var activeIconColor: Color {
        themeStore.accentColor.opacity(colorScheme == .dark ? 0.96 : 0.88)
    }
}

/// Unified pill for Play + Import in the header bar.
struct GlassToolbarPlayImportPill: View {
    let canPlay: Bool
    let onPlay: () -> Void
    let onImport: () -> Void
    @Environment(\.colorScheme) private var colorScheme
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
                        canPlay ? activeIconColor : themeStore.secondaryTextColor
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
                    .foregroundStyle(
                        activeIconColor
                    )
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
        .liquidGlassPill(colorScheme: colorScheme, accentColor: nil as Color?)
        .clipShape(Capsule())
    }

    private var activeIconColor: Color {
        themeStore.accentColor.opacity(colorScheme == .dark ? 0.96 : 0.88)
    }
}

/// Toolbar search field with Liquid Glass background.
struct GlassToolbarSearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
    let onClear: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

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
                        .foregroundStyle(themeStore.accentColor.opacity(colorScheme == .dark ? 0.92 : 0.84))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("context.clear_search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: GlassStyleTokens.headerControlHeight)
        .liquidGlassRect(
            cornerRadius: GlassStyleTokens.headerControlCornerRadius,
            colorScheme: colorScheme,
            accentColor: nil as Color?
        )
        .onTapGesture {
            focused.wrappedValue = true
        }
    }
}

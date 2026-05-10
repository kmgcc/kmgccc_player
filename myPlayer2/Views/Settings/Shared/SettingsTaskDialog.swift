//
//  SettingsTaskDialog.swift
//  myPlayer2
//
//  Shared settings task dialog components.
//

import SwiftUI

struct SettingsTaskDialog<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let iconColor: Color
    private let content: Content
    private let footer: Footer

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTaskDialogHeader(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                iconColor: iconColor
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.25)

            content
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 18)

            Divider()
                .opacity(0.25)

            footer
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 30)
        }
    }
}

private struct SettingsTaskDialogHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let iconColor: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .liquidGlassCircle(
                colorScheme: colorScheme,
                accentColor: iconColor,
                prominence: .prominent,
                isFloating: true
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

struct SettingsTaskPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let accentColor: Color?
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        cornerRadius: CGFloat = 18,
        accentColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassRect(
                cornerRadius: cornerRadius,
                colorScheme: colorScheme,
                accentColor: accentColor,
                prominence: .standard
            )
    }
}

struct SettingsTaskSummaryCard: View {
    let title: String
    let items: [String]
    var symbolName = "checkmark.circle.fill"

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        SettingsTaskPanel(accentColor: themeStore.accentColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                ForEach(items, id: \.self) { item in
                    HStack(spacing: 10) {
                        Image(systemName: symbolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(themeStore.accentColor)
                        Text(item)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}

struct SettingsTaskOptionToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .toggleStyle(.checkbox)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassRect(
            cornerRadius: 16,
            colorScheme: colorScheme,
            accentColor: isOn ? themeStore.accentColor : nil,
            prominence: isOn ? .prominent : .standard
        )
    }
}

enum SettingsTaskDialogButtonKind: Equatable {
    case secondary
    case primary
    case destructive

    var foregroundColor: Color {
        switch self {
        case .secondary:
            return .primary
        case .primary, .destructive:
            return .white
        }
    }

    var fillColor: Color {
        switch self {
        case .secondary:
            return Color.black.opacity(0.08)
        case .primary:
            return ThemeStore.shared.accentColor.opacity(0.88)
        case .destructive:
            return Color.red.opacity(0.88)
        }
    }

    var isProminent: Bool {
        self == .primary || self == .destructive
    }
}

struct SettingsTaskDialogButton: View {
    let title: String
    let kind: SettingsTaskDialogButtonKind
    let disabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        kind: SettingsTaskDialogButtonKind,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind.isProminent ? .semibold : .medium))
                .foregroundStyle(kind.foregroundColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .background(
            Capsule()
                .fill(kind.fillColor)
        )
        .overlay(
            Capsule()
                .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: GlassStyleTokens.hairlineWidth)
        )
        .glassEffect(.clear, in: Capsule())
        .clipShape(Capsule())
        .if(kind.isProminent) { view in
            view.subtleFloatingShadow()
        }
    }
}

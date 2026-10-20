//
//  SettingsTaskDialog.swift
//  myPlayer2
//
//  Shared settings task dialog components.
//

import PopupKit
import SwiftUI

struct SettingsTaskDialog<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let iconColor: Color
    let floatsActions: Bool
    let onClose: (() -> Void)?
    private let content: Content
    private let footer: Footer

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        iconColor: Color,
        floatsActions: Bool = false,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.floatsActions = floatsActions
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        AppPopupFrame(
            title: title, subtitle: subtitle, systemImage: systemImage,
            onClose: onClose, showsFooter: !floatsActions, showsCloseButton: false, accent: iconColor
        ) {
            if floatsActions {
                AppPopupScrollRegion {
                    content
                } actions: {
                    AppPopupActionGroup { footer }
                }
            } else {
                content
            }
        } footer: {
            AppPopupActionGroup { footer }
        }
    }
}

struct SettingsTaskPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let accentColor: Color?
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

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
            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
            .background(
                (accentColor ?? themeStore.appForegroundPalette.secondaryColor).opacity(0.06),
                in: RoundedRectangle(cornerRadius: cornerRadius))
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
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

                ForEach(items, id: \.self) { item in
                    HStack(spacing: 10) {
                        Image(systemName: symbolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(themeStore.accentColor)
                        Text(item)
                            .font(.system(size: 13))
                            .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
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
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
            }
            .toggleStyle(.checkbox)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPopupContentBackground(cornerRadius: 16, tint: isOn ? themeStore.accentColor : nil)
    }
}

enum SettingsTaskDialogButtonKind: Equatable {
    case secondary
    case primary
    case destructive
}

struct SettingsTaskDialogButton: View {
    let title: String
    let kind: SettingsTaskDialogButtonKind
    let disabled: Bool
    let action: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

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
        }
        .buttonStyle(
            AppDialogGlassButtonStyle(
                kind: glassKind,
                tint: themeStore.accentColor
            )
        )
        // Return confirms the dialog through its primary action. Destructive
        // and secondary actions stay pointer-only.
        .keyboardShortcut(kind == .primary ? .defaultAction : nil)
        .disabled(disabled)
    }

    private var glassKind: AppDialogGlassButtonStyle.Kind {
        switch kind {
        case .secondary: return .secondary
        case .primary: return .primary
        case .destructive: return .destructive
        }
    }
}

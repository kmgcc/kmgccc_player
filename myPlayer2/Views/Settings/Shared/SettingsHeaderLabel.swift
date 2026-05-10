//
//  SettingsHeaderLabel.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Settings Section Header Label
//

import SwiftUI

enum SettingsStyleTokens {
    static let sectionTitleFontSize: CGFloat = 15
    static let rowFontSize: CGFloat = 13
    static let rowValueFontSize: CGFloat = 13
    static let descriptionFontSize: CGFloat = 12
    static let descriptionLineSpacing: CGFloat = 2
    static let groupPadding: CGFloat = 12
    static let groupSpacing: CGFloat = 14
    static let sectionSpacing: CGFloat = 20
    static let sectionCornerRadius: CGFloat = 14
    static let inlineSpacing: CGFloat = 8
}

/// A reusable header label for settings sections with icon and title.
struct SettingsHeaderLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Image(systemName: systemImage)
                .foregroundStyle(themeStore.accentColor)
                .font(.system(size: presentationStyle.headerIconSize, weight: .bold))
            Text(title)
                .font(.system(size: presentationStyle.headerTitleFontSize, weight: .bold))
                .foregroundStyle(presentationStyle.primaryTextColor)
        }
        .padding(.bottom, presentationStyle.headerBottomPadding)
    }
}

/// Convenience initializer with String title for non-localized cases.
extension SettingsHeaderLabel {
    init(_ title: String, systemImage: String) {
        self.init(title: LocalizedStringKey(title), systemImage: systemImage)
    }
}

struct SettingsSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    init(_ title: String) {
        self.title = LocalizedStringKey(title)
    }

    var body: some View {
        Text(title)
            .settingsSectionTitleStyle()
    }
}

struct SettingsSection<Content: View>: View {
    private let title: LocalizedStringKey?
    private let content: Content
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = LocalizedStringKey(title)
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
                .padding(presentationStyle.groupPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            if let title {
                SettingsSectionTitle(title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSectionTitleStyleModifier: ViewModifier {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    func body(content: Content) -> some View {
        content
            .font(presentationStyle.sectionTitleFont)
            .foregroundStyle(presentationStyle.secondaryTextColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDescriptionStyleModifier: ViewModifier {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    func body(content: Content) -> some View {
        content
            .font(presentationStyle.captionFont)
            .foregroundStyle(presentationStyle.secondaryTextColor)
            .lineSpacing(SettingsStyleTokens.descriptionLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsRowLabelStyleModifier: ViewModifier {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    func body(content: Content) -> some View {
        content
            .font(presentationStyle.rowLabelFont)
            .foregroundStyle(presentationStyle.primaryTextColor)
    }
}

extension View {
    func settingsSectionTitleStyle() -> some View {
        modifier(SettingsSectionTitleStyleModifier())
    }

    func settingsDescriptionStyle() -> some View {
        modifier(SettingsDescriptionStyleModifier())
    }

    func settingsRowLabelStyle() -> some View {
        modifier(SettingsRowLabelStyleModifier())
    }
}

struct SettingsSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?
    var titleFont: Font?
    var detailFont: Font?
    var titleColor: Color?
    var detailColor: Color?

    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: detail == nil ? 0 : 6) {
            HStack(spacing: 12) {
                Text(title)
                    .font(titleFont ?? presentationStyle.rowLabelFont)
                    .foregroundStyle(titleColor ?? presentationStyle.primaryTextColor)

                Spacer(minLength: 16)

                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if let detail {
                Text(detail)
                    .font(detailFont ?? presentationStyle.captionFont)
                    .foregroundStyle(detailColor ?? presentationStyle.secondaryTextColor)
                    .lineSpacing(SettingsStyleTokens.descriptionLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

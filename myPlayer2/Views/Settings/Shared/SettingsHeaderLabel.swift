//
//  SettingsHeaderLabel.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Settings Section Header Label
//

import SwiftUI

enum SettingsStyleTokens {
    static let sectionTitleFontSize: CGFloat = 14
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

/// Phase 4.5 — bundle of pre-resolved tinted-neutral foreground colors for the
/// Settings detail pages. Injected via `\.settingsAppForegroundColors`; nil on
/// surfaces whose presentation style forces white text (fullscreen overlay).
struct SettingsAppForegroundColors: Equatable {
    let primary: Color
    let secondary: Color
    let tertiary: Color
}

private struct SettingsAppForegroundColorsKey: EnvironmentKey {
    static let defaultValue: SettingsAppForegroundColors? = nil
}

extension EnvironmentValues {
    var settingsAppForegroundColors: SettingsAppForegroundColors? {
        get { self[SettingsAppForegroundColorsKey.self] }
        set { self[SettingsAppForegroundColorsKey.self] = newValue }
    }
}

/// A reusable header label for settings sections with icon and title.
struct SettingsHeaderLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Image(systemName: systemImage)
                .foregroundStyle(themeStore.accentColor)
                .font(.system(size: presentationStyle.headerIconSize, weight: .bold))
            Text(title)
                .font(.system(size: presentationStyle.headerTitleFontSize, weight: .bold))
                .foregroundStyle(resolvedTitleColor)
        }
        .padding(.bottom, presentationStyle.headerBottomPadding)
    }

    private var resolvedTitleColor: Color {
        // The white-text hierarchy (fullscreen quick panel) intentionally bypasses
        // the tinted palette so it stays high-contrast on artwork.
        if let appColors, !presentationStyle.forcesWhiteText {
            return appColors.primary
        }
        return presentationStyle.primaryTextColor
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

struct CollapsibleSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var isExpanded: Bool

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        isExpanded: Binding<Bool>
    ) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = isExpanded
    }

    init(
        _ title: String,
        systemImage: String,
        isExpanded: Binding<Bool>
    ) {
        self.init(LocalizedStringKey(title), systemImage: systemImage, isExpanded: isExpanded)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSectionTitleStyleModifier: ViewModifier {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    func body(content: Content) -> some View {
        let base: Color
        if let appColors, !presentationStyle.forcesWhiteText {
            // Section labels read as "softened primary"; the palette already
            // ladders L by tier, so use secondary instead of opacity-fading
            // primary (opacity on a tinted color compounds against background
            // material and looks dirty).
            base = appColors.secondary
        } else {
            base = presentationStyle.primaryTextColor.opacity(0.82)
        }
        return content
            .font(presentationStyle.sectionTitleFont)
            .foregroundStyle(base)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsDescriptionStyleModifier: ViewModifier {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    func body(content: Content) -> some View {
        let base: Color
        if let appColors, !presentationStyle.forcesWhiteText {
            base = appColors.tertiary
        } else {
            base = presentationStyle.secondaryTextColor
        }
        return content
            .font(presentationStyle.captionFont)
            .foregroundStyle(base)
            .lineSpacing(SettingsStyleTokens.descriptionLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsRowLabelStyleModifier: ViewModifier {
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    func body(content: Content) -> some View {
        let base: Color
        if let appColors, !presentationStyle.forcesWhiteText {
            base = appColors.primary
        } else {
            base = presentationStyle.primaryTextColor
        }
        return content
            .font(presentationStyle.rowLabelFont)
            .foregroundStyle(base)
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
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        VStack(alignment: .leading, spacing: detail == nil ? 0 : 6) {
            HStack(spacing: 12) {
                Text(title)
                    .font(titleFont ?? presentationStyle.rowLabelFont)
                    .foregroundStyle(titleColor ?? resolvedTitleColor)

                Spacer(minLength: 16)

                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if let detail {
                Text(detail)
                    .font(detailFont ?? presentationStyle.captionFont)
                    .foregroundStyle(detailColor ?? resolvedDetailColor)
                    .lineSpacing(SettingsStyleTokens.descriptionLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedTitleColor: Color {
        if let appColors, !presentationStyle.forcesWhiteText {
            return appColors.primary
        }
        return presentationStyle.primaryTextColor
    }

    private var resolvedDetailColor: Color {
        if let appColors, !presentationStyle.forcesWhiteText {
            return appColors.tertiary
        }
        return presentationStyle.secondaryTextColor
    }
}

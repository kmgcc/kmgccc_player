//
//  SettingsHeaderLabel.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Settings Section Header Label
//

import SwiftUI

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

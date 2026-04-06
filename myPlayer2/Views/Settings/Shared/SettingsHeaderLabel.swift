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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(themeStore.accentColor)
                .font(.title3.bold())
            Text(title)
                .font(.title2.bold())
        }
        .padding(.bottom, 4)
    }
}

/// Convenience initializer with String title for non-localized cases.
extension SettingsHeaderLabel {
    init(_ title: String, systemImage: String) {
        self.init(title: LocalizedStringKey(title), systemImage: systemImage)
    }
}
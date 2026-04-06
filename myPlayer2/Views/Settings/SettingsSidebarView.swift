//
//  SettingsSidebarView.swift
//  myPlayer2
//
//  kmgccc_player - Settings Sidebar Navigation View
//

import SwiftUI

/// Settings sidebar with category navigation.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            Text("设置")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)

            List(SettingsCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.systemImage)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 20)
                            .foregroundStyle(
                                selection == category ? themeStore.accentColor : .primary)

                        Text(category.title)
                            .font(.body)
                            .fontWeight(selection == category ? .medium : .regular)
                            .foregroundStyle(.primary)

                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                .listRowBackground(
                    Capsule()
                        .fill(selection == category ? themeStore.selectionFill : Color.clear)
                        .padding(.horizontal, 14)
                )
            }
            .listStyle(.sidebar)
        }
        .background(Material.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
//
//  SettingsTabSelector.swift
//  myPlayer2
//
//  kmgccc_player - Reusable Tab Selector for Settings Pages
//

import SwiftUI

/// A lightweight tab selector for settings pages with capsule-style buttons.
/// Matches the Liquid Glass aesthetic used throughout the app.
struct SettingsTabSelector: View {
    let tabs: [String]
    @Binding var selectedTab: Int
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs.indices, id: \.self) { index in
                let isSelected = selectedTab == index
                Text(tabs[index])
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                    .frame(minWidth: 72)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule()
                            .fill(isSelected ? themeStore.accentColor.opacity(0.18) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedTab = index
                    }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selectedTab = 0
        
        var body: some View {
            SettingsTabSelector(tabs: ["常规", "歌词"], selectedTab: $selectedTab)
                .environmentObject(ThemeStore.shared)
                .padding()
        }
    }
    return PreviewWrapper()
}
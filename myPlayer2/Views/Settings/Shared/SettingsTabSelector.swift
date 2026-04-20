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
    let fillsWidth: Bool
    @Binding var selectedTab: Int
    @EnvironmentObject private var themeStore: ThemeStore

    init(tabs: [String], selectedTab: Binding<Int>, fillsWidth: Bool = false) {
        self.tabs = tabs
        self._selectedTab = selectedTab
        self.fillsWidth = fillsWidth
    }

    @ViewBuilder
    var body: some View {
        if fillsWidth {
            selector
                .frame(maxWidth: .infinity)
        } else {
            selector
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var selector: some View {
        SlidingSelector(
            segments: Array(tabs.indices),
            selection: $selectedTab,
            animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
            hSpacing: 0,
            background: {
                Color.clear
            },
            knob: {
                Capsule()
                    .fill(themeStore.accentColor.opacity(0.18))
            },
            content: { index, isSelected in
                Text(tabs[index])
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? themeStore.accentColor : .secondary)
                    .frame(minWidth: 72, maxWidth: fillsWidth ? .infinity : nil)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
        )
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

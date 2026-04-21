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
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

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
                    .font(.system(size: presentationStyle.tabFontSize, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(
                        isSelected
                            ? presentationStyle.selectedTextColor(accentColor: themeStore.accentColor)
                            : presentationStyle.secondaryTextColor
                    )
                    .frame(
                        minWidth: presentationStyle.tabMinWidth,
                        maxWidth: fillsWidth ? .infinity : nil,
                        minHeight: presentationStyle.tabHeight
                    )
                    .padding(.horizontal, presentationStyle.tabHorizontalPadding)
                    .padding(.vertical, presentationStyle.tabVerticalPadding)
                    .contentShape(Rectangle())
            }
        )
        .padding(.horizontal, presentationStyle.tabTrackHorizontalPadding)
        .padding(.vertical, presentationStyle.tabTrackVerticalPadding)
        .background(tabTrackBackground)
    }

    @ViewBuilder
    private var tabTrackBackground: some View {
        if presentationStyle.usesGlassSectionCards {
            Capsule()
                .fill(Color.clear)
                .liquidGlassPill(
                    colorScheme: .dark,
                    accentColor: nil,
                    prominence: .standard,
                    materialStyle: presentationStyle.glassMaterialStyle,
                    isFloating: false
                )
                .overlay(
                    Capsule()
                        .fill(Color.white.opacity(0.02))
                )
        } else {
            Capsule()
                .fill(presentationStyle.segmentedTrackColor)
        }
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

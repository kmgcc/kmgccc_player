//
//  AudioVisualizationSelectorRow.swift
//  myPlayer2
//

import SwiftUI

struct AudioVisualizationSelectorRow: View {
    let title: String
    @Binding var selection: AudioVisualizationKind

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    private var knobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return presentationStyle.primaryTextColor
        }
        return themeStore.accentColor
    }

    var body: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))
            Spacer()
            SlidingSelector(
                segments: AudioVisualizationKind.allCases,
                selection: $selection,
                hSpacing: 0,
                background: { Color.clear },
                knob: { Capsule().fill(knobColor.opacity(0.18)) },
                content: { option, isSelected in
                    Text(option.displayName)
                        // Keep typography invariant across selection states.
                        // In particular, "LED" has different advances at
                        // regular and medium weights, which shifts the glyphs
                        // and can perturb the capsule's intrinsic width.
                        .font(presentationStyle.segmentedLabelFont)
                        .padding(.horizontal, presentationStyle.segmentedHorizontalPadding)
                        .padding(.vertical, presentationStyle.segmentedVerticalPadding)
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.settingsSelectedTextColor(
                                    accentColor: themeStore.accentColor,
                                    appColors: appColors
                                )
                                : presentationStyle.settingsSecondaryTextColor(appColors: appColors)
                        )
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(trackBackground)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var trackBackground: some View {
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
                .overlay(Capsule().fill(Color.white.opacity(0.018)))
        } else {
            Capsule().fill(presentationStyle.settingsSegmentedTrackColor(appColors: appColors))
        }
    }
}

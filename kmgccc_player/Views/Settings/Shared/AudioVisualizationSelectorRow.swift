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

    private var knobColor: Color {
        if presentationStyle.usesMaterialSectionCards {
            return FullscreenSelectionAccentStyle.dimmedAccentColor(
                from: themeStore.accentNSColor,
                lightnessDelta: 0.30
            )
        }
        return themeStore.accentColor
    }

    var body: some View {
        HStack(spacing: presentationStyle.compactInlineSpacing) {
            Text(title)
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)
            Spacer()
            SlidingSelector(
                segments: AudioVisualizationKind.allCases,
                selection: $selection,
                hSpacing: 0,
                background: { Color.clear },
                knob: { Capsule().fill(knobColor.opacity(0.18)) },
                content: { option, isSelected in
                    Text(option.displayName)
                        .font(.system(
                            size: presentationStyle.segmentedFontSize,
                            weight: isSelected ? .medium : .regular
                        ))
                        .padding(.horizontal, presentationStyle.segmentedHorizontalPadding)
                        .padding(.vertical, presentationStyle.segmentedVerticalPadding)
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.selectedTextColor(accentColor: themeStore.accentColor)
                                : presentationStyle.secondaryTextColor
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
            Capsule().fill(presentationStyle.segmentedTrackColor)
        }
    }
}

//
//  AMLLLyricsRenderQualitySlider.swift
//  myPlayer2
//
//  kmgccc_player - Shared AMLL lyrics render quality control
//

import SwiftUI

struct AMLLLyricsRenderQualitySlider: View {
    @Binding var quality: AppSettings.AMLLLyricsRenderQuality
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        HStack(spacing: 12) {
            Text("歌词渲染质量")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)

            Spacer(minLength: 12)

            SlidingSelector(
                segments: AppSettings.AMLLLyricsRenderQuality.allCases,
                selection: $quality,
                animation: .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08),
                hSpacing: 0,
                background: {
                    Color.clear
                },
                knob: {
                    Capsule()
                        .fill(selectionTint.opacity(0.18))
                },
                content: { option, isSelected in
                    Text(option.title)
                        .font(.system(size: presentationStyle.segmentedFontSize, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(
                            isSelected
                                ? presentationStyle.selectedTextColor(accentColor: themeStore.accentColor)
                                : presentationStyle.secondaryTextColor
                        )
                        .frame(minWidth: 30, minHeight: max(22, presentationStyle.tabHeight - 4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
            )
            .padding(.horizontal, presentationStyle.segmentedTrackHorizontalPadding)
            .padding(.vertical, presentationStyle.segmentedTrackVerticalPadding)
            .background(segmentedTrackBackground)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var selectionTint: Color {
        if presentationStyle.usesMaterialSectionCards {
            return FullscreenSelectionAccentStyle.dimmedAccentColor(
                from: themeStore.accentNSColor,
                lightnessDelta: 0.30
            )
        }
        return themeStore.accentColor
    }

    @ViewBuilder
    private var segmentedTrackBackground: some View {
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
            ZStack {
                if presentationStyle.usesMaterialSectionCards {
                    Capsule()
                        .fill(.ultraThinMaterial)
                }

                Capsule()
                    .fill(presentationStyle.segmentedTrackColor)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                presentationStyle.segmentedTrackStrokeColor,
                                lineWidth: presentationStyle.segmentedTrackStrokeColor == .clear ? 0 : 0.5
                            )
                            .allowsHitTesting(false)
                    )
            }
        }
    }
}

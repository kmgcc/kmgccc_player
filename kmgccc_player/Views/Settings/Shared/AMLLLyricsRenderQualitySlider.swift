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
        HStack(spacing: presentationStyle.scaled(12)) {
            Text("歌词渲染质量")
                .font(presentationStyle.rowLabelFont)
                .foregroundStyle(presentationStyle.primaryTextColor)

            Spacer(minLength: presentationStyle.scaled(12))

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
                        .frame(
                            minWidth: presentationStyle.scaled(30),
                            minHeight: max(
                                presentationStyle.scaled(22),
                                presentationStyle.tabHeight - presentationStyle.scaled(4)
                            )
                        )
                        .padding(.horizontal, presentationStyle.scaled(8))
                        .padding(.vertical, presentationStyle.scaled(2))
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
            return presentationStyle.primaryTextColor
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
                                lineWidth: presentationStyle.segmentedTrackStrokeColor == .clear
                                    ? 0
                                    : presentationStyle.scaledHairlineWidth
                            )
                            .allowsHitTesting(false)
                    )
            }
        }
    }
}

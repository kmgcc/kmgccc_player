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

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { quality.sliderValue },
            set: { quality = AppSettings.AMLLLyricsRenderQuality(sliderValue: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text("歌词渲染质量")
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.primaryTextColor)
                Spacer()
                Text("\(quality.title) · \(quality.resolutionDescription)")
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
                    .font(presentationStyle.rowValueFont)
            }

            Slider(value: sliderBinding, in: 0...2, step: 1)
                .frame(height: presentationStyle.tabHeight)

            HStack {
                ForEach(Array(AppSettings.AMLLLyricsRenderQuality.allCases.enumerated()), id: \.element.id) { index, option in
                    Text(option.title)
                        .font(presentationStyle.captionFont)
                        .foregroundStyle(
                            option == quality
                                ? presentationStyle.primaryTextColor
                                : presentationStyle.tertiaryTextColor
                        )
                    if index < AppSettings.AMLLLyricsRenderQuality.allCases.count - 1 {
                        Spacer()
                    }
                }
            }

            Text("低为 0.5x，中为 0.75x，高为原生分辨率。质量越高，GPU 占用通常越高。")
                .settingsDescriptionStyle()
        }
    }
}

//
//  AMLLLyricSpringSettingsControls.swift
//  myPlayer2
//
//  kmgccc_player - Shared AMLL lyric spring controls
//

import SwiftUI

struct AMLLLyricSpringSettingsControls: View {
    @Binding var enabled: Bool
    @Binding var duration: Double
    @Binding var bounce: Double

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            SettingsSwitchRow(
                title: "使用弹簧动画",
                isOn: $enabled,
                detail: "关闭后歌词回到普通 transition 动画",
                titleFont: presentationStyle.rowLabelFont,
                detailFont: presentationStyle.captionFont
            )

            sliderBlock(
                title: "持续时间",
                valueText: String(format: "%.2f s", duration),
                value: $duration,
                range: AppSettings.lyricSpringDurationRange,
                labels: ("更快", "默认", "更慢")
            )

            sliderBlock(
                title: "反弹",
                valueText: bounceValueText,
                value: $bounce,
                range: AppSettings.lyricSpringBounceRange,
                labels: ("更平稳", "默认", "更活泼")
            )
        }
    }

    private var bounceValueText: String {
        if abs(bounce - AppSettings.defaultLyricSpringBounce) < 0.005 {
            return "默认"
        }
        return String(format: "%+.2f", bounce)
    }

    private func sliderBlock(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        labels: (String, String, String)
    ) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text(title)
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.primaryTextColor)

                Spacer()

                Text(valueText)
                    .font(presentationStyle.rowValueFont)
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
            }

            Slider(value: value, in: range)
                .disabled(!enabled)
                .frame(height: presentationStyle.tabHeight)

            HStack {
                Text(labels.0)
                Spacer()
                Text(labels.1)
                Spacer()
                Text(labels.2)
            }
            .font(presentationStyle.captionFont)
            .foregroundStyle(presentationStyle.tertiaryTextColor)
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

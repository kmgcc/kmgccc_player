//
//  AMLLLyricSpringSettingsControls.swift
//  myPlayer2
//
//  kmgccc_player - Shared AMLL lyric spring controls
//

import SwiftUI

struct AMLLLyricSpringSettingsControls: View {
    @Binding var duration: Double
    @Binding var bounce: Double

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    sliderPane(
                        title: "持续时间",
                        valueText: String(format: "%.2f", duration),
                        value: $duration,
                        range: AppSettings.lyricSpringDurationRange
                    )
                    .frame(maxWidth: .infinity)

                    sliderPane(
                        title: "反弹",
                        valueText: String(format: "%.2f", bounce),
                        value: $bounce,
                        range: AppSettings.lyricSpringBounceRange
                    )
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    sliderPane(
                        title: "持续时间",
                        valueText: String(format: "%.2f", duration),
                        value: $duration,
                        range: AppSettings.lyricSpringDurationRange
                    )
                    sliderPane(
                        title: "反弹",
                        valueText: String(format: "%.2f", bounce),
                        value: $bounce,
                        range: AppSettings.lyricSpringBounceRange
                    )
                }
            }

            HStack {
                Spacer()
                Button {
                    duration = AppSettings.defaultLyricSpringDuration
                    bounce = AppSettings.defaultLyricSpringBounce
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(presentationStyle.primaryTextColor)
                }
                .controlSize(.small)
                .disabled(isDefaultSpringSettings)
            }
        }
    }

    private var isDefaultSpringSettings: Bool {
        abs(duration - AppSettings.defaultLyricSpringDuration) < 0.005
            && abs(bounce - AppSettings.defaultLyricSpringBounce) < 0.005
    }

    private func sliderPane(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
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
                .frame(height: presentationStyle.tabHeight)
        }
    }
}

//
//  AMLLLyricSpringSettingsControls.swift
//  myPlayer2
//
//  kmgccc_player - Shared AMLL lyric spring controls
//

import AppKit
import SwiftUI

struct AMLLLyricSpringSettingsControls: View {
    @Binding var duration: Double
    @Binding var bounce: Double

    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: presentationStyle.scaled(14)) {
                    sliderPane(
                        title: "持续时间",
                        valueText: String(format: "%.2f", duration),
                        value: $duration,
                        range: AppSettings.lyricSpringDurationRange,
                        defaultValue: AppSettings.defaultLyricSpringDuration
                    )
                    .frame(maxWidth: .infinity)

                    sliderPane(
                        title: "反弹",
                        valueText: String(format: "%.2f", bounce),
                        value: $bounce,
                        range: AppSettings.lyricSpringBounceRange,
                        defaultValue: AppSettings.defaultLyricSpringBounce
                    )
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: presentationStyle.groupSpacing) {
                    sliderPane(
                        title: "持续时间",
                        valueText: String(format: "%.2f", duration),
                        value: $duration,
                        range: AppSettings.lyricSpringDurationRange,
                        defaultValue: AppSettings.defaultLyricSpringDuration
                    )
                    sliderPane(
                        title: "反弹",
                        valueText: String(format: "%.2f", bounce),
                        value: $bounce,
                        range: AppSettings.lyricSpringBounceRange,
                        defaultValue: AppSettings.defaultLyricSpringBounce
                    )
                }
            }
        }
    }

    private var markerColor: Color {
        presentationStyle.valueTextColor(accentColor: themeStore.accentColor).opacity(0.85)
    }

    private func sliderPane(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: presentationStyle.sliderBlockSpacing) {
            HStack {
                Text(title)
                    .font(presentationStyle.rowLabelFont)
                    .foregroundStyle(presentationStyle.settingsPrimaryTextColor(appColors: appColors))

                Spacer()

                Text(valueText)
                    .font(presentationStyle.rowValueFont)
                    .foregroundStyle(presentationStyle.valueTextColor(accentColor: themeStore.accentColor))
            }

            DefaultSnappingSlider(
                value: value,
                range: range,
                defaultValue: defaultValue,
                markerColor: markerColor
            )
            .frame(height: presentationStyle.tabHeight)
        }
    }
}

private struct DefaultSnappingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var snapToleranceFraction: Double = 0.04
    var markerColor: Color = .secondary.opacity(0.72)

    @State private var isEditing = false
    @State private var movedAwayFromDefault = false
    @State private var hasSnappedDuringEditing = false

    private var snapTolerance: Double {
        (range.upperBound - range.lowerBound) * snapToleranceFraction
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { proposedValue in
                let clampedValue = min(max(proposedValue, range.lowerBound), range.upperBound)
                let isNearDefault = abs(clampedValue - defaultValue) <= snapTolerance

                if isNearDefault {
                    if isEditing,
                       movedAwayFromDefault,
                       !hasSnappedDuringEditing {
                        hasSnappedDuringEditing = true
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .alignment,
                            performanceTime: .drawCompleted
                        )
                    }
                    value = defaultValue
                } else {
                    movedAwayFromDefault = true
                    hasSnappedDuringEditing = false
                    value = clampedValue
                }
            }
        )
    }

    var body: some View {
        Slider(
            value: sliderBinding,
            in: range
        ) { editing in
            isEditing = editing
            if editing {
                movedAwayFromDefault = abs(value - defaultValue) > snapTolerance
                hasSnappedDuringEditing = false
            } else {
                movedAwayFromDefault = false
                hasSnappedDuringEditing = false
            }
        }
        .overlay {
            if shouldShowMarker {
                GeometryReader { geometry in
                    Circle()
                        .fill(markerColor)
                        .frame(width: 4, height: 4)
                        .position(
                            x: defaultMarkerX(in: geometry.size),
                            y: geometry.size.height / 2
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var shouldShowMarker: Bool {
        abs(value - defaultValue) > snapTolerance
    }

    private func defaultMarkerX(in size: CGSize) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return size.width / 2 }
        let normalizedDefault = (defaultValue - range.lowerBound) / span
        let horizontalInset = min(size.height / 2, size.width / 2)
        return horizontalInset + (size.width - horizontalInset * 2) * CGFloat(normalizedDefault)
    }
}

//
//  DSPRangeSliderRow.swift
//  myPlayer2
//
//  Unified slider and scrubbable numeric row for DSP and audio settings.
//  Left: parameter title. Center: compact slider. Right: scrubbable/editable number.
//

import SwiftUI

struct DSPRangeSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = "dB"
    var fractionDigits: Int = 1
    var onCommit: (() -> Void)? = nil

    private var sliderStep: Double {
        if unit == "ms" {
            return max(step, 50.0)
        } else if unit == "dB" || unit == "dBTP" || unit == "LUFS" {
            return max(step, 0.5)
        } else {
            return step
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .settingsRowLabelStyle()
                .frame(minWidth: 84, alignment: .leading)

            Spacer(minLength: 8)

            Slider(
                value: $value,
                in: range,
                step: sliderStep,
                onEditingChanged: { isEditing in
                    if !isEditing { onCommit?() }
                }
            )
            .frame(width: 140)
            .accessibilityLabel(title)

            ScrubbableNumberField(
                value: $value,
                range: range,
                step: step,
                unit: unit,
                fractionDigits: fractionDigits,
                alignment: .trailing,
                onCommit: onCommit
            )
            .frame(minWidth: 70, alignment: .trailing)
        }
    }
}

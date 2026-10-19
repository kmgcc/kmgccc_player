//
//  DSPRangeSliderRow.swift
//  myPlayer2
//
//  Unified slider and scrubbable numeric row for DSP and audio settings.
//  Left: parameter title. Right: fixed-width slider and scrubbable number, so
//  the controls of consecutive rows share one column.
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

    static let sliderWidth: CGFloat = 168
    static let valueWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .settingsRowLabelStyle()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(title)

            // The slider stays continuous and snaps through the same quantizer
            // as the number field, so both controls land on identical values.
            Slider(
                value: sliderBinding,
                in: range,
                onEditingChanged: { isEditing in
                    if !isEditing { onCommit?() }
                }
            )
            .frame(width: Self.sliderWidth)
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
            .frame(width: Self.valueWidth, alignment: .trailing)
            .accessibilityLabel(title)
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { raw in
                let next = ScrubbableNumberField.quantize(
                    raw,
                    range: range,
                    step: step,
                    fractionDigits: fractionDigits
                )
                if next != value { value = next }
            }
        )
    }
}

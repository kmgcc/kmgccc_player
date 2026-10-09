//
//  ScrubbableNumberField.swift
//  myPlayer2
//
//  Adobe-style scrubbable numeric field.
//  Supports horizontal drag-scrubbing for fine adjustments,
//  and single-click switching to direct text input.
//

import AppKit
import SwiftUI

struct ScrubbableNumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var fractionDigits: Int = 1
    var alignment: TextAlignment = .trailing
    var onCommit: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isEditingText = false
    @State private var textInput = ""
    @State private var dragStartValue: Double = 0
    @State private var hasDragged = false

    var body: some View {
        Group {
            if isEditingText {
                TextField("", text: $textInput)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(alignment)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .onSubmit {
                        commitText()
                    }
                    .onExitCommand {
                        isEditingText = false
                    }
            } else {
                displayBadge
                    .contentShape(Rectangle())
                    .highPriorityGesture(dragGesture)
                    .onHover { hovering in
                        updateHover(hovering)
                    }
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }

    private var displayBadge: some View {
        HStack(spacing: 2) {
            Text(formattedNumber(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)

            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: alignment == .center ? .infinity : nil, alignment: frameAlignment)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0.04))
        )
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if !hasDragged {
                    hasDragged = true
                    dragStartValue = value
                }
                let deltaX = gesture.translation.width
                let span = range.upperBound - range.lowerBound
                let isShiftPressed = NSEvent.modifierFlags.contains(.shift)
                let fineFactor: Double = isShiftPressed ? 0.2 : 1.0

                let raw: Double
                if span > 1000 && range.lowerBound > 0 {
                    // Audio frequency exponential scrubbing (equal physical drag per octave)
                    let exponent = (deltaX * 0.0035) * fineFactor
                    raw = dragStartValue * pow(10.0, exponent)
                } else {
                    let steps = (deltaX / 3.0) * fineFactor
                    raw = dragStartValue + steps * step
                }
                let clamped = min(max(raw, range.lowerBound), range.upperBound)
                value = roundedToFraction(clamped)
            }
            .onEnded { gesture in
                let travel = abs(gesture.translation.width) + abs(gesture.translation.height)
                hasDragged = false
                if travel < 3 {
                    if isHovering {
                        NSCursor.pop()
                        isHovering = false
                    }
                    textInput = formattedNumber(value)
                    isEditingText = true
                } else {
                    onCommit?()
                }
            }
    }

    private func updateHover(_ hovering: Bool) {
        if hovering && !isHovering {
            isHovering = true
            NSCursor.resizeLeftRight.push()
        } else if !hovering && isHovering {
            isHovering = false
            NSCursor.pop()
        }
    }

    private func commitText() {
        let trimmed = textInput.trimmingCharacters(in: .whitespaces)
        if let parsed = Double(trimmed) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = roundedToFraction(clamped)
            onCommit?()
        }
        isEditingText = false
    }

    private func formattedNumber(_ val: Double) -> String {
        if fractionDigits == 0 {
            return "\(Int(val.rounded()))"
        }
        return val.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    private func roundedToFraction(_ val: Double) -> Double {
        if fractionDigits == 0 {
            return val.rounded()
        }
        let factor = pow(10.0, Double(fractionDigits))
        return (val * factor).rounded() / factor
    }
}

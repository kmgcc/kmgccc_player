//
//  ScrubbableNumberField.swift
//  myPlayer2
//
//  Adobe-style scrubbable numeric field.
//  Drag horizontally to scrub (Shift for fine steps); click once to type.
//
//  The bound value only changes on intentional input: a click never nudges the
//  value, scrubbing waits for a small dead zone and snaps to `step`, and typed
//  text is applied once on Return, on focus loss or when the user clicks
//  anywhere outside the field.
//

import AppKit
import SwiftUI

/// How horizontal pointer travel maps to value changes while scrubbing.
enum ScrubScale: Equatable {
    /// Logarithmic for wide positive ranges such as frequency, otherwise one
    /// step per three points.
    case automatic
    case linear(perPoint: Double)
    case logarithmic(decadesPerPoint: Double)
}

struct ScrubbableNumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    var fractionDigits: Int = 1
    var alignment: TextAlignment = .trailing
    var scrubScale: ScrubScale = .automatic
    var onCommit: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isEditingText = false
    @State private var textInput = ""
    @State private var dragStartValue: Double?
    @FocusState private var isTextFieldFocused: Bool

    /// Pointer travel that still counts as a click rather than a scrub.
    private let clickTolerance: CGFloat = 3

    var body: some View {
        Group {
            if isEditingText {
                textEditor
            } else {
                displayBadge
                    .contentShape(Rectangle())
                    .highPriorityGesture(dragGesture)
                    .onHover(perform: setHovering)
                    .accessibilityElement(children: .ignore)
                    .accessibilityValue(Text(accessibilityValueText))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { beginTextEditing() }
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: nudge(by: step)
                        case .decrement: nudge(by: -step)
                        @unknown default: break
                        }
                    }
            }
        }
        .onDisappear {
            setHovering(false)
        }
    }

    // MARK: - Subviews

    private var textEditor: some View {
        TextField("", text: $textInput)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(alignment)
            .textFieldStyle(.plain)
            .focused($isTextFieldFocused)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            )
            .background(OutsideClickProbe(onOutsideClick: commitText))
            .onSubmit(commitText)
            .onExitCommand(perform: cancelText)
            .onChange(of: isTextFieldFocused) { _, focused in
                if !focused, isEditingText { commitText() }
            }
            .onAppear {
                // The field enters the window in this update; focusing on the
                // next main-actor turn makes a single click enough to type.
                Task { @MainActor in isTextFieldFocused = true }
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
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering || dragStartValue != nil ? 0.08 : 0.04))
        )
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    // MARK: - Scrubbing

    private enum ResolvedScale {
        case linear(Double)
        case logarithmic(Double)
    }

    private var resolvedScale: ResolvedScale {
        switch scrubScale {
        case .linear(let perPoint):
            return .linear(perPoint)
        case .logarithmic(let decadesPerPoint) where range.lowerBound > 0:
            return .logarithmic(decadesPerPoint)
        case .logarithmic:
            return .linear(step / 3)
        case .automatic:
            return range.lowerBound > 0 && range.upperBound - range.lowerBound > 1_000
                ? .logarithmic(0.0035)
                : .linear(step / 3)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let deltaX = gesture.translation.width
                if dragStartValue == nil {
                    guard abs(deltaX) >= clickTolerance else { return }
                    dragStartValue = value
                }
                guard let start = dragStartValue else { return }
                let fineFactor = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                // Measure from the edge of the dead zone so scrubbing starts at
                // the current value instead of jumping by the tolerance.
                let travel = Double(deltaX - (deltaX > 0 ? clickTolerance : -clickTolerance)) * fineFactor
                switch resolvedScale {
                case .linear(let perPoint):
                    assign(start + travel * perPoint, snapsToStep: true)
                case .logarithmic(let decadesPerPoint):
                    // A fixed grid would be coarse at the low end of a ratio
                    // scale, so only display precision applies.
                    assign(start * pow(10, travel * decadesPerPoint), snapsToStep: false)
                }
            }
            .onEnded { gesture in
                if dragStartValue != nil {
                    dragStartValue = nil
                    onCommit?()
                } else if abs(gesture.translation.width) < clickTolerance,
                          abs(gesture.translation.height) < clickTolerance {
                    beginTextEditing()
                }
            }
    }

    private func nudge(by delta: Double) {
        assign(value + delta, snapsToStep: true)
        onCommit?()
    }

    /// Clamps, quantizes and writes only when the value changes.
    private func assign(_ raw: Double, snapsToStep: Bool) {
        let next = Self.quantize(
            raw,
            range: range,
            step: snapsToStep ? step : 0,
            fractionDigits: fractionDigits
        )
        if next != value { value = next }
    }

    static func quantize(
        _ raw: Double,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int
    ) -> Double {
        guard raw.isFinite else { return range.lowerBound }
        var result = min(max(raw, range.lowerBound), range.upperBound)
        if step > 0 {
            result = range.lowerBound + ((result - range.lowerBound) / step).rounded() * step
        }
        let factor = pow(10, Double(max(0, fractionDigits)))
        result = (result * factor).rounded() / factor
        return min(max(result, range.lowerBound), range.upperBound)
    }

    // MARK: - Text Editing

    private func beginTextEditing() {
        setHovering(false)
        textInput = value.formatted(
            .number.grouping(.never).precision(.fractionLength(fractionDigits))
        )
        isEditingText = true
    }

    private func commitText() {
        guard isEditingText else { return }
        isEditingText = false
        guard let parsed = Self.parse(textInput, unit: unit) else { return }
        // Typed values keep their precision; only the range and display digits apply.
        let next = Self.quantize(parsed, range: range, step: 0, fractionDigits: fractionDigits)
        if next != value { value = next }
        onCommit?()
    }

    private func cancelText() {
        isEditingText = false
    }

    static func parse(_ input: String, unit: String) -> Double? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !unit.isEmpty, text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        text = text
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "+", with: "")
        if !text.contains("."), text.filter({ $0 == "," }).count == 1 {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        guard let parsed = Double(text), parsed.isFinite else { return nil }
        return parsed
    }

    // MARK: - Hover

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
    }

    // MARK: - Formatting

    private var accessibilityValueText: String {
        unit.isEmpty ? formattedNumber(value) : "\(formattedNumber(value)) \(unit)"
    }

    private func formattedNumber(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.fractionLength(fractionDigits)))
    }
}

// MARK: - Outside Click

/// Reports mouse-down events in the same window that land outside the view it
/// backs. macOS does not end text editing when a click lands on a
/// non-focusable area, so the field ends it explicitly. The probe never
/// consumes events and is transparent to hit testing.
private struct OutsideClickProbe: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> OutsideClickProbeView {
        OutsideClickProbeView()
    }

    func updateNSView(_ view: OutsideClickProbeView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: OutsideClickProbeView, coordinator: ()) {
        view.stopMonitoring()
    }
}

private final class OutsideClickProbeView: NSView {
    var onOutsideClick: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            if !bounds.contains(point) { onOutsideClick?() }
            return event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

//
//  LedMeterView.swift
//  myPlayer2
//
//  kmgccc_player - 11-Dot LED Level Meter with Liquid Glass
//  Center dot (6th) lights first, then symmetrically outward.
//  Each dot has configurable brightness levels (default 5).
//  Liquid Glass material for unlit state and outline.
//

import AppKit
import SwiftUI

/// 11-dot LED level meter with symmetric lighting from center.
/// Uses Liquid Glass material for unlit dots and outline highlights.
struct LedMeterView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    /// Normalized level (0.0 to 1.0)
    let level: Double

    /// Optional per-LED brightness values (0.0 to 1.0)
    var ledValues: [Float]? = nil

    /// Dot size
    var dotSize: CGFloat = 10

    /// Spacing between dots
    var spacing: CGFloat = 5

    /// Optional pill tint (very subtle, above glass)
    var pillTint: Color? = nil

    var isPlaying: Bool = false

    // MARK: - Settings (from AppSettings)

    private var numLEDs: Int {
        ledValues?.count ?? AppSettings.shared.ledCount
    }

    private var brightnessLevels: Int {
        AppSettings.shared.ledBrightnessLevels
    }

    // MARK: - Resolver

    private var resolver: LEDColorResolver {
        LEDColorResolver(
            accentColor: themeStore.accentColor,
            colorScheme: colorScheme,
            brightnessLevels: brightnessLevels,
            palette: themeStore.semanticPalette
        )
    }

    // MARK: - Discrete Breath Timing

    private let breathHoldTime: Double = 0.32
    private let peakHoldTime: Double   = 0.30
    private let zeroHoldTime: Double   = 0.30

    private func breathStep(at date: Date) -> Int {
        guard isPlaying, brightnessLevels > 1 else { return 0 }
        let maxStep = brightnessLevels - 1
        let riseDuration  = Double(maxStep) * breathHoldTime
        let fallDuration  = Double(maxStep) * breathHoldTime
        let cycleDuration = riseDuration + peakHoldTime + fallDuration + zeroHoldTime

        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)

        if t < riseDuration {
            let step = Int(t / breathHoldTime)
            return min(maxStep, step)
        } else if t < riseDuration + peakHoldTime {
            return maxStep
        } else if t < riseDuration + peakHoldTime + fallDuration {
            let dt = t - (riseDuration + peakHoldTime)
            let step = Int(dt / breathHoldTime)
            return max(0, maxStep - step)
        } else {
            return 0
        }
    }

    var body: some View {
        let horizontalPadding: CGFloat = 14
        let verticalPadding: CGFloat = 10

        TimelineView(.animation(minimumInterval: 0.05, paused: false)) { timeline in
            let breath = breathStep(at: timeline.date)

            HStack(spacing: spacing) {
                statusLed(level: breath)
                divider
                ForEach(0..<numLEDs, id: \.self) { index in
                    ledDot(at: index, breathLevel: breath)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule()
                    .fill(Color.clear)
                    .liquidGlassPill(
                        colorScheme: colorScheme,
                        accentColor: pillTint,
                        prominence: pillTint != nil ? .prominent : .standard,
                        isFloating: false
                    )
            )
        }
        .animation(.easeInOut(duration: 0.25), value: numLEDs)
    }

    // MARK: - Status Light (Breath LED)

    private func statusLed(level: Int) -> some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: dotSize, height: dotSize)

            if resolver.usePlusLighter {
                Circle()
                    .fill(resolver.statusLightColor(level: level))
                    .frame(width: dotSize, height: dotSize)
                    .blendMode(.plusLighter)
            } else {
                Circle()
                    .fill(resolver.statusLightColor(level: level))
                    .frame(width: dotSize, height: dotSize)
            }

            Circle()
                .stroke(resolver.statusLightStrokeColor(level: level), lineWidth: 0.7)
                .frame(width: dotSize, height: dotSize)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: dotSize * 0.6)
    }

    // MARK: - LED Dot

    @ViewBuilder
    private func ledDot(at index: Int, breathLevel breath: Int) -> some View {
        let brightnessState = calculateBrightnessState(for: index)
        let ledColor = resolver.volumeLEDColor(index: index, count: numLEDs, level: brightnessState)
        let strokeColor = resolver.volumeLEDStrokeColor(index: index, count: numLEDs, level: brightnessState)

        ZStack {
            // Unlit glass base
            Circle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: dotSize, height: dotSize)

            // Lit LED fill with optional plusLighter
            if resolver.usePlusLighter {
                Circle()
                    .fill(ledColor)
                    .frame(width: dotSize, height: dotSize)
                    .blendMode(.plusLighter)
            } else {
                Circle()
                    .fill(ledColor)
                    .frame(width: dotSize, height: dotSize)
            }

            // Subtle stroke
            Circle()
                .stroke(strokeColor, lineWidth: 0.7)
                .frame(width: dotSize, height: dotSize)
        }
        .animation(.easeOut(duration: 0.03), value: brightnessState)
    }

    // MARK: - Brightness Calculation

    /// Brightness state: 0 = off (glass only), 1..brightnessLevels-1 = lit levels
    private func calculateBrightnessState(for index: Int) -> Int {
        if let ledValues, index < ledValues.count {
            let value = max(0, min(1, Double(ledValues[index])))
            let step = 1.0 / Double(max(1, brightnessLevels - 1))
            return min(brightnessLevels - 1, Int(round(value / step)))
        }

        let centerIndex = numLEDs / 2
        let distanceFromCenter = abs(index - centerIndex)
        let ledsFromCenterToEdge = numLEDs / 2 + 1
        let totalSlots = ledsFromCenterToEdge * brightnessLevels
        let currentSlot = level * Double(totalSlots)
        let ledStartSlot = Double(distanceFromCenter * brightnessLevels)

        if currentSlot < ledStartSlot {
            return 0
        } else if currentSlot >= ledStartSlot + Double(brightnessLevels) {
            return brightnessLevels - 1
        } else {
            let slotWithinLed = currentSlot - ledStartSlot
            let level = Int(slotWithinLed)
            return min(level, brightnessLevels - 1)
        }
    }
}

// MARK: - Preview

#Preview("LED Meter - 11 LEDs") {
    VStack(spacing: 20) {
        ForEach([0.0, 0.15, 0.3, 0.5, 0.7, 0.85, 1.0], id: \.self) { level in
            HStack {
                Text(String(format: "%.0f%%", level * 100))
                    .frame(width: 40)
                    .font(.caption)
                    .foregroundStyle(.white)

                LedMeterView(level: level, dotSize: 10, spacing: 5, isPlaying: true)
            }
        }
    }
    .padding(30)
    .background(Color.black.opacity(0.8))
}

#Preview("LED Meter - Light Mode") {
    VStack(spacing: 20) {
        LedMeterView(level: 0.0, dotSize: 10, spacing: 5, isPlaying: true)
        LedMeterView(level: 0.5, dotSize: 10, spacing: 5, isPlaying: true)
        LedMeterView(level: 1.0, dotSize: 10, spacing: 5, isPlaying: true)
    }
    .padding(30)
    .background(Color.gray.opacity(0.2))
    .preferredColorScheme(.light)
}

#Preview("LED Meter - Animated") {
    struct AnimatedPreview: View {
        @State private var level: Double = 0

        var body: some View {
            VStack(spacing: 30) {
                LedMeterView(level: level, dotSize: 10, spacing: 5, isPlaying: true)

                Slider(value: $level, in: 0...1)
                    .frame(width: 250)

                Text(String(format: "Level: %.2f", level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .background(.ultraThinMaterial)
        }
    }

    return AnimatedPreview()
}

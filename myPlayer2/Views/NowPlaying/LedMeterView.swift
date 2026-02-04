//
//  LedMeterView.swift
//  myPlayer2
//
//  TrueMusic - 11-Dot LED Level Meter with Liquid Glass
//  Center dot (6th) lights first, then symmetrically outward.
//  Each dot has configurable brightness levels (default 5).
//  Liquid Glass material for unlit state and outline.
//

import SwiftUI

/// 11-dot LED level meter with symmetric lighting from center.
/// Uses Liquid Glass material for unlit dots and outline highlights.
struct LedMeterView: View {

    /// Normalized level (0.0 to 1.0)
    let level: Double

    /// Dot size
    var dotSize: CGFloat = 12

    /// Spacing between dots
    var spacing: CGFloat = 8

    // MARK: - Settings (from AppSettings)

    private var numLEDs: Int {
        AppSettings.shared.ledCount
    }

    private var brightnessLevels: Int {
        AppSettings.shared.ledBrightnessLevels
    }

    private var glassOutlineIntensity: Double {
        AppSettings.shared.ledGlassOutlineIntensity
    }

    // MARK: - Colors

    /// Colors from center (index 0) to edge
    /// Brighter, more vivid colors (no glow effect)
    private var dotColors: [Color] {
        [
            Color(hue: 0.35, saturation: 0.65, brightness: 0.95),  // Center: bright green
            Color(hue: 0.30, saturation: 0.60, brightness: 0.92),  // Yellow-green
            Color(hue: 0.18, saturation: 0.70, brightness: 0.90),  // Yellow
            Color(hue: 0.10, saturation: 0.75, brightness: 0.88),  // Orange-yellow
            Color(hue: 0.05, saturation: 0.80, brightness: 0.85),  // Orange
            Color(hue: 0.00, saturation: 0.85, brightness: 0.82),  // Red-orange
        ]
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<numLEDs, id: \.self) { index in
                ledDot(at: index)
            }
        }
    }

    // MARK: - LED Dot

    @ViewBuilder
    private func ledDot(at index: Int) -> some View {
        let brightnessState = calculateBrightnessState(for: index)
        let color = colorForDot(at: index)
        let opacity = opacityForState(brightnessState)

        ZStack {
            // Base: Liquid Glass material (always visible)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: dotSize, height: dotSize)

            // LED color overlay (opacity based on brightness)
            if brightnessState > 0 {
                Circle()
                    .fill(color.opacity(opacity))
                    .frame(width: dotSize, height: dotSize)
            }

            // Liquid Glass outline highlight
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.4 * glassOutlineIntensity),
                            .clear,
                            .white.opacity(0.15 * glassOutlineIntensity),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .frame(width: dotSize, height: dotSize)
        }
        .animation(.easeOut(duration: 0.03), value: brightnessState)
    }

    // MARK: - Brightness Calculation

    /// Brightness state: 0 = off (glass only), 1..brightnessLevels-1 = lit levels
    private func calculateBrightnessState(for index: Int) -> Int {
        let centerIndex = numLEDs / 2

        // Calculate distance from center
        let distanceFromCenter = abs(index - centerIndex)

        // Total slots = (LEDs from center to edge + 1) * brightness levels
        let ledsFromCenterToEdge = numLEDs / 2 + 1
        let totalSlots = ledsFromCenterToEdge * brightnessLevels
        let currentSlot = level * Double(totalSlots)

        // This LED starts at slot = distanceFromCenter * brightnessLevels
        let ledStartSlot = Double(distanceFromCenter * brightnessLevels)

        if currentSlot < ledStartSlot {
            // Not reached this LED yet
            return 0
        } else if currentSlot >= ledStartSlot + Double(brightnessLevels) {
            // This LED is fully lit
            return brightnessLevels - 1
        } else {
            // Partially lit - calculate which brightness level
            let slotWithinLed = currentSlot - ledStartSlot
            let level = Int(slotWithinLed)
            return min(level, brightnessLevels - 1)
        }
    }

    /// Map brightness state to opacity (0 = glass only, max = full brightness).
    private func opacityForState(_ state: Int) -> Double {
        guard state > 0, brightnessLevels > 1 else { return 0 }

        // Map state 1..(brightnessLevels-1) to 0.3..1.0
        let minOpacity = 0.3
        let maxOpacity = 1.0
        let fraction = Double(state) / Double(brightnessLevels - 1)
        return minOpacity + fraction * (maxOpacity - minOpacity)
    }

    /// Get color for LED based on distance from center.
    private func colorForDot(at index: Int) -> Color {
        let centerIndex = numLEDs / 2
        let distanceFromCenter = abs(index - centerIndex)

        // Clamp to available colors
        let colorIndex = min(distanceFromCenter, dotColors.count - 1)
        return dotColors[colorIndex]
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

                LedMeterView(level: level, dotSize: 14, spacing: 8)
            }
        }
    }
    .padding(30)
    .background(Color.black.opacity(0.8))
}

#Preview("LED Meter - Light Mode") {
    VStack(spacing: 20) {
        LedMeterView(level: 0.0, dotSize: 14, spacing: 8)
        LedMeterView(level: 0.5, dotSize: 14, spacing: 8)
        LedMeterView(level: 1.0, dotSize: 14, spacing: 8)
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
                LedMeterView(level: level, dotSize: 16, spacing: 10)

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

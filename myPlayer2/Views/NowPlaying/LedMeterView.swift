//
//  LedMeterView.swift
//  myPlayer2
//
//  kmgccc_player - 11-Dot LED Level Meter with Liquid Glass
//  Center dot (6th) lights first, then symmetrically outward.
//  Each dot has configurable brightness levels (default 5).
//  Liquid Glass material for unlit state and outline.
//

import SwiftUI

/// 11-dot LED level meter with symmetric lighting from center.
/// Uses Liquid Glass material for unlit dots and outline highlights.
struct LedMeterView: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Normalized level (0.0 to 1.0)
    let level: Double

    /// Optional per-LED brightness values (0.0 to 1.0)
    var ledValues: [Float]? = nil

    /// Dot size
    var dotSize: CGFloat = 12

    /// Spacing between dots
    var spacing: CGFloat = 8

    /// Optional pill tint (very subtle, above glass)
    var pillTint: Color? = nil

    // MARK: - Settings (from AppSettings)

    private var numLEDs: Int {
        ledValues?.count ?? AppSettings.shared.ledCount
    }

    private var brightnessLevels: Int {
        AppSettings.shared.ledBrightnessLevels
    }

    private var outlineIntensity: Double {
        colorScheme == .dark ? 0.55 : 0.35
    }

    // MARK: - Colors

    /// Colors from center (index 0) to edge
    /// Brighter, more vivid colors (no glow effect)
    private var dotColors: [Color] {
        [
            Color(hue: 0.24, saturation: 0.10, brightness: 1.00),  // Center: Green (Low Sat)
            Color(hue: 0.19, saturation: 0.15, brightness: 1.00),  // Yellow-Green (Low-Mid)
            Color(hue: 0.17, saturation: 0.5, brightness: 1.00),  // Yellow (High Sat transition)
            Color(hue: 0.12, saturation: 0.63, brightness: 1.00),  // Orange-Yellow (Peak Sat ~80%+)
            Color(hue: 0.08, saturation: 0.68, brightness: 1.00),  // Orange (Sides ~70%+)
            Color(hue: 0.05, saturation: 0.67, brightness: 1.00),  // Red (Sides ~70%)
        ]
    }

    var body: some View {
        let baseOffsetY: CGFloat = 4
        ZStack {
            LEDPillBase(
                ledCount: numLEDs,
                dotSize: dotSize,
                dotSpacing: spacing,
                horizontalPadding: 14,
                heightPadding: 14,
                tint: pillTint
            )
            .offset(y: baseOffsetY)
            .zIndex(0)

            HStack(spacing: spacing) {
                ForEach(0..<numLEDs, id: \.self) { index in
                    ledDot(at: index)
                }
            }
            .offset(y: baseOffsetY)
            .zIndex(1)
        }
        .animation(.easeInOut(duration: 0.25), value: numLEDs)
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
                            .white.opacity(0.4 * outlineIntensity),
                            .clear,
                            .white.opacity(0.15 * outlineIntensity),
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
        if let ledValues, index < ledValues.count {
            let value = max(0, min(1, Double(ledValues[index])))
            let step = 1.0 / Double(max(1, brightnessLevels - 1))
            return min(brightnessLevels - 1, Int(round(value / step)))
        }

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

// MARK: - LED Pill Base

private struct LEDPillBase: View {
    @Environment(\.colorScheme) private var colorScheme

    let ledCount: Int
    let dotSize: CGFloat
    let dotSpacing: CGFloat
    let horizontalPadding: CGFloat
    let heightPadding: CGFloat
    let tint: Color?

    /// For capsule harmony, keep horizontal/vertical padding in sync so end-cap radius
    /// matches the end LED geometry (end LED centers align with cap centers).
    private var capAlignedPadding: CGFloat {
        max(horizontalPadding, heightPadding)
    }

    private var pillWidth: CGFloat {
        CGFloat(ledCount) * dotSize
            + CGFloat(max(0, ledCount - 1)) * dotSpacing
            + capAlignedPadding * 2
    }

    private var pillHeight: CGFloat {
        dotSize + capAlignedPadding * 2
    }

    var body: some View {
        Capsule()
            .fill(Color.clear)
            .frame(width: pillWidth, height: pillHeight)
            .liquidGlassPill(
                colorScheme: colorScheme,
                accentColor: tint,
                prominence: tint != nil ? .prominent : .standard,
                isFloating: false
            )
            .animation(.easeInOut(duration: 0.25), value: ledCount)
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

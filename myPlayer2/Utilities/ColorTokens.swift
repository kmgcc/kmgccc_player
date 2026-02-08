//
//  ColorTokens.swift
//  myPlayer2
//
//  TrueMusic - Color Design Tokens
//  Low-saturation LED colors and Glass styling.
//

import SwiftUI

/// Color design tokens for TrueMusic.
enum ColorTokens {

    // MARK: - LED Colors (Low Saturation, 6 Brightness Levels)

    /// LED off state
    static let ledOff = Color.white.opacity(0.1)

    /// LED brightness levels (1-6, low saturation teal/cyan)
    static func ledBrightness(_ level: Int) -> Color {
        let clampedLevel = max(0, min(level, 6))

        switch clampedLevel {
        case 0:
            return ledOff
        case 1:
            return Color(hue: 0.5, saturation: 0.2, brightness: 0.3)
        case 2:
            return Color(hue: 0.5, saturation: 0.25, brightness: 0.45)
        case 3:
            return Color(hue: 0.5, saturation: 0.3, brightness: 0.6)
        case 4:
            return Color(hue: 0.5, saturation: 0.35, brightness: 0.75)
        case 5:
            return Color(hue: 0.5, saturation: 0.4, brightness: 0.85)
        case 6:
            return Color(hue: 0.5, saturation: 0.45, brightness: 1.0)
        default:
            return ledOff
        }
    }

    /// All LED brightness levels as array
    static let ledLevels: [Color] = (0...6).map { ledBrightness($0) }

    // MARK: - Glass Material

    /// Glass background for Liquid Glass style
    static let glassBackground = Color.white.opacity(0.1)

    /// Glass border
    static let glassBorder = Color.white.opacity(0.2)

    /// Glass shadow
    static let glassShadow = Color.black.opacity(0.2)

    // MARK: - Text Colors

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.7)

    // MARK: - Accent

    static let accent = Color.accentColor

    // MARK: - Backgrounds

    static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)

    // MARK: - Player Controls

    static let controlActive = Color.primary
    static let controlInactive = Color.secondary.opacity(0.6)

    // MARK: - Progress Bar

    static let progressTrack = Color.white.opacity(0.2)
    static let progressFill = Color.accentColor
    static let progressKnob = Color.white
}

// MARK: - View Extension for Glass Effect

extension View {
    /// Apply Liquid Glass material effect.
    func glassBackground(
        cornerRadius: CGFloat = 16,
        intensity: Double = 0.8
    ) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(ColorTokens.glassBorder, lineWidth: 0.5)
            )
            .shadow(color: ColorTokens.glassShadow, radius: 10, x: 0, y: 5)
    }
}

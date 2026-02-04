//
//  GlassStyleTokens.swift
//  myPlayer2
//
//  TrueMusic - Centralized glass/material style tokens
//  Following Apple's Liquid Glass design language
//

import SwiftUI

/// Centralized style tokens for glass effects
enum GlassStyleTokens {

    // MARK: - Hairline Borders

    /// Ultra-thin separator line opacity
    static let hairlineOpacity: Double = 0.12

    /// Hairline border for glass containers
    static let hairlineBorderOpacity: Double = 0.15

    /// Hairline stroke width
    static let hairlineWidth: CGFloat = 0.5

    // MARK: - Glass Highlights

    /// Subtle top highlight for glass depth
    static let highlightOpacity: Double = 0.04

    /// Inner glow/highlight gradient stops
    static let highlightGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.06),
            Color.white.opacity(0.02),
            Color.clear,
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Shadows

    /// Very subtle shadow for floating elements
    static let subtleShadowOpacity: Double = 0.08
    static let subtleShadowRadius: CGFloat = 8

    // MARK: - Sidebar Specific

    /// Sidebar minimum width
    static let sidebarMinWidth: CGFloat = 220

    /// Sidebar default width
    static let sidebarWidth: CGFloat = 240

    /// Sidebar row vertical padding
    static let sidebarRowPadding: CGFloat = 6

    /// Sidebar selection background opacity
    static let sidebarSelectionOpacity: Double = 0.12

    // MARK: - Mini Player (Pill)

    /// Mini player height
    static let miniPlayerHeight: CGFloat = 68

    /// Mini player horizontal margin
    static let miniPlayerHorizontalPadding: CGFloat = 16

    /// Mini player bottom margin
    static let miniPlayerBottomPadding: CGFloat = 12

    // MARK: - Colors

    /// Hairline color for light/dark adaptive
    static var hairlineColor: Color {
        Color.primary.opacity(hairlineOpacity)
    }

    /// Border color for glass containers
    static var glassBorderColor: Color {
        Color.white.opacity(hairlineBorderOpacity)
    }

    /// Subtle shadow color
    static var subtleShadowColor: Color {
        Color.black.opacity(subtleShadowOpacity)
    }
}

// MARK: - View Modifiers

extension View {
    /// Apply hairline border for glass containers
    func glassHairlineBorder(cornerRadius: CGFloat = 0) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    GlassStyleTokens.glassBorderColor,
                    lineWidth: GlassStyleTokens.hairlineWidth
                )
        )
    }

    /// Apply capsule hairline border for pill shapes
    func pillHairlineBorder() -> some View {
        self.overlay(
            Capsule()
                .strokeBorder(
                    GlassStyleTokens.glassBorderColor,
                    lineWidth: GlassStyleTokens.hairlineWidth
                )
        )
    }

    /// Apply subtle highlight gradient for glass depth
    func glassHighlight() -> some View {
        self.overlay(
            GlassStyleTokens.highlightGradient
                .allowsHitTesting(false)
        )
    }

    /// Apply very subtle shadow for floating elements
    func subtleFloatingShadow() -> some View {
        self.shadow(
            color: GlassStyleTokens.subtleShadowColor,
            radius: GlassStyleTokens.subtleShadowRadius,
            x: 0,
            y: 2
        )
    }
}

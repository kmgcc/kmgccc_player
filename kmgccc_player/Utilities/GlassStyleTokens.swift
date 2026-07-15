//
//  GlassStyleTokens.swift
//  myPlayer2
//

import SwiftUI

nonisolated enum GlassPillOverlayTone: Equatable, Sendable {
    case clear
    case light
    case dark
}

nonisolated struct GlassPillOverlayRecipe: Equatable, Sendable {
    let tone: GlassPillOverlayTone
    let opacity: Double
}

struct GlassStyleTokens {
    // MARK: - Prominence
    enum Prominence {
        case standard
        case prominent
    }

    // MARK: - Sizing
    static let headerBarHeight: CGFloat = 60
    static let headerControlHeight: CGFloat = 36
    static let headerPrimaryControlHeight: CGFloat = 36
    static let headerStandardIconSize: CGFloat = 12
    static let headerPrimaryIconSize: CGFloat = 14
    static let miniPlayerHeight: CGFloat = 50

    static var headerControlCornerRadius: CGFloat {
        headerControlHeight / 2
    }

    // MARK: - Opacity
    static let hairlineOpacity: Double = 0.12
    static let hairlineBorderOpacity: Double = 0.15
    static let hairlineWidth: CGFloat = 0.5

    static let highlightOpacity: Double = 0.04
    static let highlightGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.06),
            Color.white.opacity(0.02),
            Color.clear,
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let subtleShadowOpacity: Double = 0.08
    static let subtleShadowRadius: CGFloat = 8

    // MARK: - Colors
    static var glassBorderColor: Color {
        Color.white.opacity(hairlineBorderOpacity)
    }

    static func glassBorderColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(hairlineBorderOpacity)
            : Color.primary.opacity(0.07)
    }

    static var subtleShadowColor: Color {
        Color.black.opacity(subtleShadowOpacity)
    }

    // MARK: - Adaptive
    static func tintOpacity(for colorScheme: ColorScheme, prominence: Prominence = .standard)
        -> Double
    {
        switch prominence {
        case .standard:
            return colorScheme == .dark ? 0.026 : 0.024
        case .prominent:
            return colorScheme == .dark ? 0.045 : 0.03
        }
    }

    static func darkNeutralOverlay(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.18) : .clear
    }

    nonisolated static func pillOverlayRecipe(
        for colorScheme: ColorScheme,
        materialStyle: LiquidGlassPillMaterialStyle
    ) -> GlassPillOverlayRecipe {
        switch materialStyle {
        case .clear:
            return colorScheme == .dark
                ? GlassPillOverlayRecipe(tone: .dark, opacity: 0.18)
                : GlassPillOverlayRecipe(tone: .clear, opacity: 0)
        case .regular:
            return GlassPillOverlayRecipe(tone: .clear, opacity: 0)
        case .normal:
            // Normal is an explicitly legible material. Dark foreground must
            // sit on a light neutral glass; light foreground sits on a dark
            // neutral glass. Never use a dark overlay for both polarities.
            return colorScheme == .dark
                ? GlassPillOverlayRecipe(tone: .dark, opacity: 0.30)
                : GlassPillOverlayRecipe(tone: .light, opacity: 0.24)
        }
    }

    static func pillOverlay(for colorScheme: ColorScheme, materialStyle: LiquidGlassPillMaterialStyle)
        -> Color
    {
        let recipe = pillOverlayRecipe(for: colorScheme, materialStyle: materialStyle)
        switch recipe.tone {
        case .clear:
            return .clear
        case .light:
            return Color.white.opacity(recipe.opacity)
        case .dark:
            return Color.black.opacity(recipe.opacity)
        }
    }

    // MARK: - Sidebar & Layout
    static let headerGroupSpacing: CGFloat = 14
    static let headerControlSpacing: CGFloat = 8
    static let headerHorizontalPadding: CGFloat = 16

    static let headerSearchMinWidth: CGFloat = 180
    static let headerSearchMaxWidth: CGFloat = 300

    static let sidebarWidth: CGFloat = 200
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarRowPadding: CGFloat = 6  // Matches Main Interface inset
    static let sidebarContentPadding: CGFloat = 10  // Matches Main Interface content padding
    static let sidebarSelectionCornerRadius: CGFloat = 8  // Matches Main Interface radius
    static let sidebarSelectionOpacity: Double = 0.12

    static let miniPlayerHorizontalPadding: CGFloat = 16
    static let miniPlayerBottomPadding: CGFloat = 12
}

// Legacy Compatibility Typealias
typealias LiquidGlassTokens = GlassStyleTokens

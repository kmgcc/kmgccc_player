//
//  GlassPillView.swift
//  myPlayer2
//

import SwiftUI

enum LiquidGlassPillMaterialStyle {
    case clear
    case darkGlass
}

extension View {
    func subtleFloatingShadow() -> some View {
        self.shadow(
            color: GlassStyleTokens.subtleShadowColor,
            radius: GlassStyleTokens.subtleShadowRadius,
            x: 0,
            y: 2
        )
    }

    func liquidGlassPill(
        colorScheme: ColorScheme,
        accentColor: Color? = nil,
        prominence: GlassStyleTokens.Prominence = .standard,
        materialStyle: LiquidGlassPillMaterialStyle = .clear,
        isFloating: Bool = false
    ) -> some View {
        self
            .glassEffect(materialStyle == .darkGlass ? .regular : .clear, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor,
                        lineWidth: GlassStyleTokens.hairlineWidth
                    )
                    .allowsHitTesting(false)
            )
            .background(
                Capsule()
                    .fill(GlassStyleTokens.pillOverlay(for: colorScheme, materialStyle: materialStyle))
                    .allowsHitTesting(false)
            )
            .background {
                if let accentColor {
                    Capsule()
                        .fill(
                            accentColor.opacity(
                                GlassStyleTokens.tintOpacity(
                                    for: colorScheme, prominence: prominence))
                        )
                        .allowsHitTesting(false)
                }
            }
            .modifier(FloatingShadowModifier(isEnabled: isFloating))
    }

    func liquidGlassRect(
        cornerRadius: CGFloat = 12,
        colorScheme: ColorScheme,
        accentColor: Color? = nil,
        prominence: GlassStyleTokens.Prominence = .standard,
        materialStyle: LiquidGlassPillMaterialStyle = .clear,
        isFloating: Bool = false
    ) -> some View {
        self
            .glassEffect(
                materialStyle == .darkGlass ? .regular : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor,
                        lineWidth: GlassStyleTokens.hairlineWidth
                    )
                    .allowsHitTesting(false)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(GlassStyleTokens.pillOverlay(for: colorScheme, materialStyle: materialStyle))
                    .allowsHitTesting(false)
            )
            .background {
                if let accentColor {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            accentColor.opacity(
                                GlassStyleTokens.tintOpacity(
                                    for: colorScheme, prominence: prominence))
                        )
                        .allowsHitTesting(false)
                }
            }
            .modifier(FloatingShadowModifier(isEnabled: isFloating))
    }

    func liquidGlassCircle(
        colorScheme: ColorScheme,
        accentColor: Color? = nil,
        prominence: GlassStyleTokens.Prominence = .standard,
        isFloating: Bool = false
    ) -> some View {
        self
            .glassEffect(.clear, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor,
                        lineWidth: GlassStyleTokens.hairlineWidth
                    )
                    .allowsHitTesting(false)
            )
            .background(
                Circle()
                    .fill(GlassStyleTokens.darkNeutralOverlay(for: colorScheme))
                    .allowsHitTesting(false)
            )
            .background {
                if let accentColor {
                    Circle()
                        .fill(
                            accentColor.opacity(
                                GlassStyleTokens.tintOpacity(
                                    for: colorScheme, prominence: prominence))
                        )
                        .allowsHitTesting(false)
                }
            }
            .modifier(FloatingShadowModifier(isEnabled: isFloating))
    }
}

private struct FloatingShadowModifier: ViewModifier {
    let isEnabled: Bool
    func body(content: Content) -> some View {
        if isEnabled {
            content.subtleFloatingShadow()
        } else {
            content
        }
    }
}

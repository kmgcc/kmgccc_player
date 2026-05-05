//
//  GlassPillView.swift
//  myPlayer2
//

import SwiftUI

private struct HomeLiveResizeRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var homeLiveResizeRendering: Bool {
        get { self[HomeLiveResizeRenderingKey.self] }
        set { self[HomeLiveResizeRenderingKey.self] = newValue }
    }
}

enum LiquidGlassPillMaterialStyle {
    case clear
    case regular
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
            .glassEffect(materialStyle == .clear ? .clear : .regular, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor(for: colorScheme),
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
                materialStyle == .clear ? .clear : .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor(for: colorScheme),
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
        materialStyle: LiquidGlassPillMaterialStyle = .clear,
        isFloating: Bool = false
    ) -> some View {
        self
            .glassEffect(materialStyle == .clear ? .clear : .regular, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor(for: colorScheme),
                        lineWidth: GlassStyleTokens.hairlineWidth
                    )
                    .allowsHitTesting(false)
            )
            .background(
                Circle()
                    .fill(GlassStyleTokens.pillOverlay(for: colorScheme, materialStyle: materialStyle))
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

    @ViewBuilder
    func homeGlassCardBackground(
        cornerRadius: CGFloat = 18,
        colorScheme: ColorScheme,
        prominence: GlassStyleTokens.Prominence = .standard,
        isFloating: Bool = true
    ) -> some View {
        self.homeUnifiedGlassCard(
            cornerRadius: cornerRadius,
            colorScheme: colorScheme,
            prominence: prominence,
            isFloating: isFloating
        )
    }

    func homeUnifiedGlassCard(
        cornerRadius: CGFloat = 18,
        colorScheme: ColorScheme,
        prominence: GlassStyleTokens.Prominence = .standard,
        isFloating: Bool = true
    ) -> some View {
        self.modifier(
            HomeUnifiedGlassCardModifier(
                cornerRadius: cornerRadius,
                colorScheme: colorScheme,
                prominence: prominence,
                isFloating: isFloating
            )
        )
    }

    fileprivate func homeGlassCardEdgeTreatment(
        shape: RoundedRectangle,
        colorScheme: ColorScheme
    ) -> some View {
        self
            .overlay(
                shape
                    .strokeBorder(
                        GlassStyleTokens.highlightGradient,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(
                        GlassStyleTokens.glassBorderColor(for: colorScheme),
                        lineWidth: GlassStyleTokens.hairlineWidth
                    )
                    .allowsHitTesting(false)
            )
    }
}

private struct HomeUnifiedGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let colorScheme: ColorScheme
    let prominence: GlassStyleTokens.Prominence
    let isFloating: Bool
    @Environment(AppSettings.self) private var settings

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var stabilizingTreatment: Color {
        colorScheme == .dark
            ? GlassStyleTokens.darkNeutralOverlay(for: colorScheme)
            : Color.primary.opacity(0.028)
    }

    private var solidTreatment: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch settings.homeCardMaterialMode {
        case .liquidGlass:
            content
                .background(
                    shape
                        .fill(stabilizingTreatment)
                        .allowsHitTesting(false)
                )
                .glassEffect(colorScheme == .dark ? .clear : .regular, in: shape)
                .homeGlassCardEdgeTreatment(shape: shape, colorScheme: colorScheme)
                .modifier(HomeGlassCardShadowModifier(isEnabled: isFloating, colorScheme: colorScheme))
                .contentShape(shape)
        case .frostedGlass:
            content
                .background(.ultraThinMaterial, in: shape)
                .homeGlassCardEdgeTreatment(shape: shape, colorScheme: colorScheme)
                .modifier(HomeGlassCardShadowModifier(isEnabled: isFloating, colorScheme: colorScheme))
                .contentShape(shape)
        case .solid:
            content
                .background(
                    shape
                        .fill(solidTreatment)
                        .allowsHitTesting(false)
                )
                .homeGlassCardEdgeTreatment(shape: shape, colorScheme: colorScheme)
                .modifier(HomeGlassCardShadowModifier(isEnabled: isFloating, colorScheme: colorScheme))
                .contentShape(shape)
        }
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

private struct HomeGlassCardShadowModifier: ViewModifier {
    let isEnabled: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if isEnabled {
            content.shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.028 : 0.016),
                radius: colorScheme == .dark ? 4 : 2.5,
                x: 0,
                y: colorScheme == .dark ? 0.75 : 0.5
            )
        } else {
            content
        }
    }
}

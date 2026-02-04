//
//  GlassPillView.swift
//  myPlayer2
//
//  TrueMusic - True Liquid Glass Helpers
//  Uses macOS 26 native SwiftUI .glassEffect() modifier.
//

import SwiftUI

// MARK: - Glass Effect Extensions

extension View {
    /// Apply Liquid Glass capsule effect (pill shape)
    func glassPill() -> some View {
        self.glassEffect(.regular, in: .capsule)
    }

    /// Apply Liquid Glass rectangle with corner radius
    func glassRect(cornerRadius: CGFloat = 12) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// Apply Liquid Glass with custom shape
    func liquidGlass<S: Shape>(in shape: S) -> some View {
        self.glassEffect(.regular, in: shape)
    }
}

// MARK: - Glass Container View

/// A container that applies Liquid Glass with GlassEffectContainer for
/// proper blending when multiple glass elements overlap.
struct LiquidGlassContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer {
            content
        }
    }
}

// MARK: - Glass Pill Content

/// Wraps content in a Liquid Glass capsule (pill) shape.
struct GlassPill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Glass Card

/// Wraps content in a Liquid Glass rounded rectangle.
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    init(cornerRadius: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

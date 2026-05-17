//
//  SkinPreviewViews.swift
//  myPlayer2
//
//  kmgccc_player - Minimal vector skin preview thumbnails for settings.
//

import SwiftUI

// MARK: - Preview Style Constants

enum SkinPreviewStyle {
    static let strokeWidth: CGFloat = 1.5
    static let cornerRadius: CGFloat = 8

    static func stroke(_ scheme: ColorScheme, emphasis: Double = 1.0) -> Color {
        let alpha = scheme == .dark ? 0.26 * emphasis : 0.22 * emphasis
        return (scheme == .dark ? Color.white : Color.black).opacity(alpha)
    }

    static func fill(_ scheme: ColorScheme, emphasis: Double = 1.0) -> Color {
        let alpha = scheme == .dark ? 0.08 * emphasis : 0.06 * emphasis
        return (scheme == .dark ? Color.white : Color.black).opacity(alpha)
    }

    static func glyph(_ scheme: ColorScheme, emphasis: Double = 1.0) -> Color {
        let alpha = scheme == .dark ? 0.36 * emphasis : 0.28 * emphasis
        return (scheme == .dark ? Color.white : Color.black).opacity(alpha)
    }
}

// MARK: - Classic Skin Preview

/// Classic LED skin fingerprint: square cover + bottom LED dots.
struct ClassicSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    private var strokeColor: Color {
        SkinPreviewStyle.stroke(colorScheme, emphasis: isSelected ? 1.15 : 1.0)
    }
    private var fillColor: Color {
        SkinPreviewStyle.fill(colorScheme, emphasis: isSelected ? 1.10 : 1.0)
    }
    private var dotColorBase: Double {
        isSelected ? 0.18 : 0.12
    }

    var body: some View {
        VStack(spacing: 8) {
            // Cover
            RoundedRectangle(cornerRadius: SkinPreviewStyle.cornerRadius, style: .continuous)
                .fill(fillColor)
                .stroke(strokeColor, lineWidth: SkinPreviewStyle.strokeWidth)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(SkinPreviewStyle.glyph(colorScheme, emphasis: isSelected ? 1.10 : 1.0))
                )

            // LED dots
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(SkinPreviewStyle.glyph(colorScheme).opacity(dotColorBase + Double(index) * 0.06))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .offset(y: 4)
    }
}

// MARK: - Apple Style Skin Preview

/// Apple style fingerprint: abstract fluid field + classic cover geometry.
struct AppleStyleSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    private var strokeColor: Color {
        SkinPreviewStyle.stroke(colorScheme, emphasis: isSelected ? 1.15 : 1.0)
    }
    private var fillColor: Color {
        SkinPreviewStyle.fill(colorScheme, emphasis: isSelected ? 1.10 : 1.0)
    }
    private var glyphColor: Color {
        SkinPreviewStyle.glyph(colorScheme, emphasis: isSelected ? 1.10 : 1.0)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SkinPreviewStyle.cornerRadius, style: .continuous)
                .fill(fillColor)
                .stroke(strokeColor, lineWidth: SkinPreviewStyle.strokeWidth)
                .frame(width: 56, height: 56)

            AppleFluidPreviewLines()
                .stroke(strokeColor.opacity(0.72), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: 42, height: 42)

            AppleFluidPreviewLines(offset: 9)
                .stroke(strokeColor.opacity(0.38), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                .frame(width: 42, height: 42)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((colorScheme == .dark ? Color.black : Color.white).opacity(0.10))
                .stroke(strokeColor, lineWidth: 1)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(glyphColor)
                )
        }
    }
}

private struct AppleFluidPreviewLines: Shape {
    var offset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y1 = rect.minY + rect.height * 0.30 + offset * 0.08
        let y2 = rect.minY + rect.height * 0.62 - offset * 0.05

        path.move(to: CGPoint(x: rect.minX + 2, y: y1))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 2, y: y1 + 5),
            control1: CGPoint(x: rect.minX + rect.width * 0.28, y: y1 - 9 - offset * 0.12),
            control2: CGPoint(x: rect.minX + rect.width * 0.70, y: y1 + 12 + offset * 0.08)
        )

        path.move(to: CGPoint(x: rect.minX + 4, y: y2))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 4, y: y2 - 4),
            control1: CGPoint(x: rect.minX + rect.width * 0.32, y: y2 + 8 + offset * 0.08),
            control2: CGPoint(x: rect.minX + rect.width * 0.68, y: y2 - 11 - offset * 0.12)
        )

        return path
    }
}

// MARK: - Rotating Skin Preview

/// Rotating cover skin fingerprint: disc with label ring + center hole.
struct RotatingSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    private var strokeColor: Color {
        SkinPreviewStyle.stroke(colorScheme, emphasis: isSelected ? 1.15 : 1.0)
    }
    private var fillColor: Color {
        SkinPreviewStyle.fill(colorScheme, emphasis: isSelected ? 1.10 : 1.0)
    }

    var body: some View {
        ZStack {
            // Outer disc
            Circle()
                .stroke(strokeColor, lineWidth: SkinPreviewStyle.strokeWidth)
                .frame(width: 54, height: 54)

            // Groove ring
            Circle()
                .stroke(strokeColor.opacity(0.5), lineWidth: 0.5)
                .frame(width: 42, height: 42)

            // Label ring
            Circle()
                .stroke(strokeColor, lineWidth: 1)
                .frame(width: 26, height: 26)

            // Label fill
            Circle()
                .fill(fillColor)
                .frame(width: 26, height: 26)

            // Center hole
            Circle()
                .fill(SkinPreviewStyle.glyph(colorScheme, emphasis: isSelected ? 1.10 : 1.0))
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - Cassette Skin Preview

/// Cassette skin fingerprint: tape body + capsule window wrapping twin reels.
struct CassetteSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    private var strokeColor: Color {
        SkinPreviewStyle.stroke(colorScheme, emphasis: isSelected ? 1.15 : 1.0)
    }
    private var fillColor: Color {
        SkinPreviewStyle.fill(colorScheme, emphasis: isSelected ? 1.10 : 1.0)
    }

    var body: some View {
        ZStack {
            // Shell
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fillColor)
                .stroke(strokeColor, lineWidth: SkinPreviewStyle.strokeWidth)
                .frame(width: 56, height: 36)

            // Capsule window — snug wrapper with equal padding around twin reels
            Capsule()
                .fill(SkinPreviewStyle.fill(colorScheme, emphasis: 0.65))
                .stroke(strokeColor.opacity(0.60), lineWidth: 1)
                .frame(width: 32, height: 15)

            // Twin reels inside window
            HStack(spacing: 10) {
                Circle()
                    .stroke(strokeColor, lineWidth: 1)
                    .frame(width: 7, height: 7)

                Circle()
                    .stroke(strokeColor, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
        }
    }
}

// MARK: - Cover Gradient Blur Skin Preview

/// Fullscreen cover-gradient-blur skin fingerprint: soft concentric cover with blur halo.
struct CoverGradientBlurSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "photo")
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(SkinPreviewStyle.glyph(colorScheme, emphasis: isSelected ? 1.10 : 1.0))
            .frame(width: 46, height: 46)
    }
}

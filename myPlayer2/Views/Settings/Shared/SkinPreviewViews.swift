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
    static let primaryStroke = Color.primary.opacity(0.22)
    static let primaryFill = Color.primary.opacity(0.06)
    static let accentFill = Color.primary.opacity(0.14)
    static let cornerRadius: CGFloat = 8
}

// MARK: - Classic Skin Preview

/// Classic LED skin fingerprint: square cover + bottom LED dots.
struct ClassicSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color

    private var strokeColor: Color {
        isSelected ? accentColor.opacity(0.40) : SkinPreviewStyle.primaryStroke
    }
    private var fillColor: Color {
        isSelected ? accentColor.opacity(0.10) : SkinPreviewStyle.primaryFill
    }
    private var dotColorBase: Double {
        isSelected ? 0.22 : 0.12
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
                        .foregroundStyle(isSelected ? accentColor.opacity(0.45) : Color.primary.opacity(0.25))
                )

            // LED dots
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    Circle()
                        .fill((isSelected ? accentColor : Color.primary).opacity(dotColorBase + Double(index) * 0.06))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .offset(y: 4)
    }
}

// MARK: - Rotating Skin Preview

/// Rotating cover skin fingerprint: disc with label ring + center hole.
struct RotatingSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color

    private var strokeColor: Color {
        isSelected ? accentColor.opacity(0.40) : SkinPreviewStyle.primaryStroke
    }
    private var fillColor: Color {
        isSelected ? accentColor.opacity(0.10) : SkinPreviewStyle.primaryFill
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
                .fill(isSelected ? accentColor.opacity(0.50) : Color.primary.opacity(0.35))
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - Cassette Skin Preview

/// Cassette skin fingerprint: tape body + capsule window wrapping twin reels.
struct CassetteSkinPreview: View {
    let isSelected: Bool
    let accentColor: Color

    private var strokeColor: Color {
        isSelected ? accentColor.opacity(0.40) : SkinPreviewStyle.primaryStroke
    }
    private var fillColor: Color {
        isSelected ? accentColor.opacity(0.10) : SkinPreviewStyle.primaryFill
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
                .fill(Color.primary.opacity(0.03))
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

    private var strokeColor: Color {
        isSelected ? accentColor.opacity(0.40) : SkinPreviewStyle.primaryStroke
    }
    private var fillColor: Color {
        isSelected ? accentColor.opacity(0.10) : SkinPreviewStyle.primaryFill
    }

    var body: some View {
        ZStack {
            // Outer blur halo
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .frame(width: 62, height: 62)

            // Mid soft layer
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 56, height: 56)

            // Sharp cover
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fillColor)
                .stroke(strokeColor, lineWidth: SkinPreviewStyle.strokeWidth)
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(isSelected ? accentColor.opacity(0.45) : Color.primary.opacity(0.25))
                )
        }
    }
}

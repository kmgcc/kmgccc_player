//
//  ArtworkPlaceholderView.swift
//  myPlayer2
//
//  kmgccc_player - Unified Artwork Placeholder View
//  Provides a consistent placeholder style across the app for missing/empty artwork.
//

import SwiftUI

/// Unified placeholder view for artwork across the app.
/// Uses theme-colored background with a music note icon.
struct ArtworkPlaceholderView: View {

    // MARK: - Configuration

    let size: CGFloat
    let cornerRadius: CGFloat
    let clipShape: ArtworkPlaceholderClipShape
    let iconSize: CGFloat
    let iconOpacity: Double
    let isGrayscale: Bool
    let themeColor: Color?

    // MARK: - Environment

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Initialization

    /// Creates a unified artwork placeholder view.
    /// - Parameters:
    ///   - size: The width/height of the placeholder
    ///   - cornerRadius: Corner radius for rounded rectangle shapes
    ///   - clipShape: The clip shape style (.rounded, .continuous, .circle)
    ///   - iconSize: Size of the music note icon (nil = proportional to size)
    ///   - iconOpacity: Opacity of the icon (0.0-1.0)
    ///   - isGrayscale: Whether to apply grayscale (for missing tracks)
    ///   - themeColor: Optional explicit theme color (nil = use ThemeStore.accentColor)
    init(
        size: CGFloat,
        cornerRadius: CGFloat? = nil,
        clipShape: ArtworkPlaceholderClipShape = .continuous,
        iconSize: CGFloat? = nil,
        iconOpacity: Double = 0.8,
        isGrayscale: Bool = false,
        themeColor: Color? = nil
    ) {
        self.size = size
        self.cornerRadius = cornerRadius ?? (size * 0.15)
        self.clipShape = clipShape
        self.iconSize = iconSize ?? max(12, size * 0.35)
        self.iconOpacity = iconOpacity
        self.isGrayscale = isGrayscale
        self.themeColor = themeColor
    }

    // MARK: - Body

    var body: some View {
        applyClipShape(to: placeholderContent
            .frame(width: size, height: size))
            .grayscale(isGrayscale ? 1.0 : 0.0)
    }

    // MARK: - Content

    @ViewBuilder
    private var placeholderContent: some View {
        ZStack {
            // Theme-colored background
            themeBackgroundColor
                .frame(width: size, height: size)

            // Music note icon
            Image(systemName: "music.note")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(iconColor)
                .opacity(iconOpacity)
        }
    }

    // MARK: - Clip Shape Modifier

    @ViewBuilder
    private func applyClipShape<Content: View>(to content: Content) -> some View {
        switch clipShape {
        case .rounded:
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        case .continuous:
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .circle:
            content.clipShape(Circle())
        }
    }

    // MARK: - Colors

    /// The background color - uses theme accent color from ThemeStore
    private var themeBackgroundColor: Color {
        let baseColor = themeColor ?? ThemeStore.shared.accentColor
        return baseColor.opacity(colorScheme == .dark ? 0.6 : 0.5)
    }

    /// Icon color - white with adaptive opacity for contrast
    private var iconColor: Color {
        Color.white
    }

    // MARK: - Convenience Presets

    /// Small placeholder for track rows.
    static func trackRow(isGrayscale: Bool = false, themeColor: Color? = nil) -> ArtworkPlaceholderView {
        ArtworkPlaceholderView(
            size: Constants.Layout.TrackRow.artworkSize,
            cornerRadius: Constants.Layout.TrackRow.artworkCornerRadius,
            clipShape: .rounded,
            iconSize: max(16, Constants.Layout.TrackRow.artworkSize * 0.36),
            isGrayscale: isGrayscale,
            themeColor: themeColor
        )
    }

    /// Medium placeholder for mini player (36x36)
    static func miniPlayer(themeColor: Color? = nil) -> ArtworkPlaceholderView {
        ArtworkPlaceholderView(
            size: 36,
            cornerRadius: 8,
            clipShape: .rounded,
            iconSize: 14,
            iconOpacity: 0.6,
            themeColor: themeColor
        )
    }

    /// Large placeholder for Now Playing skins (variable size)
    static func nowPlaying(size: CGFloat, cornerRadius: CGFloat, isCircle: Bool = false, themeColor: Color? = nil) -> ArtworkPlaceholderView {
        ArtworkPlaceholderView(
            size: size,
            cornerRadius: isCircle ? size / 2 : cornerRadius,
            clipShape: isCircle ? .circle : .continuous,
            iconSize: max(24, size * 0.25),
            iconOpacity: 0.35,
            themeColor: themeColor
        )
    }

    /// Header placeholder for playlist/artist/album detail (220x220)
    static func header(size: CGFloat = 220, isCircle: Bool = false, themeColor: Color? = nil) -> ArtworkPlaceholderView {
        ArtworkPlaceholderView(
            size: size,
            cornerRadius: isCircle ? size / 2 : 14,
            clipShape: isCircle ? .circle : .continuous,
            iconSize: max(44, size * 0.2),
            iconOpacity: 0.6,
            themeColor: themeColor
        )
    }

    /// Fullscreen mini player placeholder (44x44 at scale 1.0)
    static func fullscreenMiniPlayer(artworkSize: CGFloat, scale: CGFloat = 1.0, themeColor: Color? = nil) -> ArtworkPlaceholderView {
        let scaledSize = artworkSize * scale
        return ArtworkPlaceholderView(
            size: scaledSize,
            cornerRadius: 12 * scale,
            clipShape: .continuous,
            iconSize: 22 * scale,
            iconOpacity: 0.6,
            themeColor: themeColor
        )
    }

    /// Queue row placeholder (44x44 at scale 1.0)
    static func queueRow(artworkSize: CGFloat, scale: CGFloat = 1.0, themeColor: Color? = nil) -> ArtworkPlaceholderView {
        let scaledSize = artworkSize * scale
        return ArtworkPlaceholderView(
            size: scaledSize,
            cornerRadius: 6 * scale,
            clipShape: .continuous,
            iconSize: 16 * scale,
            iconOpacity: 0.4,
            themeColor: themeColor
        )
    }
}

// MARK: - Clip Shape Enum

enum ArtworkPlaceholderClipShape {
    case rounded        // Standard rounded rectangle
    case continuous     // Continuous corner style (iOS/macOS modern)
    case circle         // Circular clip
}

// MARK: - Preview

#Preview("Artwork Placeholder Variants") {
    VStack(spacing: 20) {
        HStack(spacing: 20) {
            ArtworkPlaceholderView.trackRow()

            ArtworkPlaceholderView.miniPlayer()

            ArtworkPlaceholderView.trackRow(isGrayscale: true)
        }

        HStack(spacing: 20) {
            ArtworkPlaceholderView.nowPlaying(size: 180, cornerRadius: 12)

            ArtworkPlaceholderView.nowPlaying(size: 180, cornerRadius: 90, isCircle: true)
        }

        HStack(spacing: 20) {
            ArtworkPlaceholderView.header(size: 120, isCircle: false)

            ArtworkPlaceholderView.header(size: 120, isCircle: true)
        }

        HStack(spacing: 20) {
            ArtworkPlaceholderView.fullscreenMiniPlayer(artworkSize: 44, scale: 1.0)

            ArtworkPlaceholderView.queueRow(artworkSize: 44, scale: 1.0)
        }
    }
    .padding()
    .environmentObject(ThemeStore.shared)
}

//
//  ArtistArtworkGenerator.swift
//  myPlayer2
//
//  Stable artist placeholder artwork generation.
//

import AppKit
import Foundation

actor ArtistArtworkGenerator {
    static let shared = ArtistArtworkGenerator()

    private final class PlaceholderCacheBox: @unchecked Sendable {
        let cache: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 128
            cache.totalCostLimit = 40 * 1024 * 1024
            return cache
        }()
    }

    private struct GradientSpec {
        let startColor: NSColor
        let endColor: NSColor
        let textColor: NSColor
        let angle: CGFloat
    }

    private nonisolated static let placeholderCache = PlaceholderCacheBox()
    private nonisolated static let placeholderPixelSide = 640

    func generateArtwork(artistName: String, tracks: [Track]) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            Self.placeholderArtwork(artistName: artistName, tracks: tracks)
        }.value
    }

    nonisolated static func placeholderArtwork(artistName: String, tracks: [Track]) -> NSImage? {
        let cacheKey = placeholderCacheKey(artistName: artistName, tracks: tracks) as NSString
        if let cached = placeholderCache.cache.object(forKey: cacheKey) {
            return cached
        }

        guard let image = renderArtwork(
            artistName: artistName,
            tracks: tracks,
            pixelSide: placeholderPixelSide
        ) else {
            return nil
        }

        placeholderCache.cache.setObject(
            image,
            forKey: cacheKey,
            cost: placeholderPixelSide * placeholderPixelSide * 4
        )
        return image
    }

    private nonisolated static func renderArtwork(
        artistName: String,
        tracks: [Track],
        pixelSide: Int
    ) -> NSImage? {
        let side = CGFloat(max(256, pixelSide))
        let canvasSize = CGSize(width: side, height: side)
        let gradient = resolveGradientSpec(artistName: artistName, tracks: tracks)

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        if let backgroundGradient = NSGradient(colors: [gradient.startColor, gradient.endColor]) {
            backgroundGradient.draw(in: canvasRect, angle: gradient.angle)
        } else {
            gradient.startColor.setFill()
            NSBezierPath(rect: canvasRect).fill()
        }

        let highlight = NSColor.white.withAlphaComponent(0.08)
        if let highlightGradient = NSGradient(colors: [highlight, .clear]) {
            let highlightRect = canvasRect.insetBy(dx: -canvasSize.width * 0.18, dy: -canvasSize.height * 0.18)
            highlightGradient.draw(
                in: NSBezierPath(ovalIn: highlightRect),
                relativeCenterPosition: NSPoint(x: -0.35, y: 0.42)
            )
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping

        let fontSize = suggestedFontSize(for: artistName, canvasWidth: canvasSize.width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: gradient.textColor,
            .paragraphStyle: paragraphStyle,
            .kern: -0.4,
        ]

        let text = artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LibraryNormalization.unknownArtist
            : artistName
        let insetX = canvasSize.width * 0.14
        let maxTextWidth = canvasSize.width - insetX * 2
        let bounding = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: maxTextWidth, height: canvasSize.height * 0.6),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textRect = CGRect(
            x: insetX,
            y: (canvasSize.height - bounding.height) / 2.0,
            width: maxTextWidth,
            height: ceil(bounding.height)
        )

        NSAttributedString(string: text, attributes: attributes).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return image
    }

    private nonisolated static func placeholderCacheKey(
        artistName: String,
        tracks: [Track]
    ) -> String {
        let text = artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LibraryNormalization.unknownArtist
            : artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedTracks = tracks.sorted { $0.id.uuidString < $1.id.uuidString }

        if let representative = sortedTracks.first(where: {
            let artworkData = $0.loadArtworkDataIfNeeded()
            guard let artworkData else { return false }
            return !artworkData.isEmpty
        }) {
            let checksum = ArtworkLoader.checksum(for: representative.loadArtworkDataIfNeeded())
            return "\(text)|\(representative.id.uuidString)|\(checksum)|\(sortedTracks.count)"
        }

        return "\(text)|fallback|\(sortedTracks.count)"
    }

    private nonisolated static func resolveGradientSpec(
        artistName: String,
        tracks: [Track]
    ) -> GradientSpec {
        let sortedTracks = tracks.sorted { $0.id.uuidString < $1.id.uuidString }

        for track in sortedTracks {
            let artworkData = track.loadArtworkDataIfNeeded()
            guard let artworkData, !artworkData.isEmpty else { continue }
            let palette = ArtworkColorExtractor.uiThemePalette(from: artworkData, maxColors: 3)
            if let spec = gradientSpec(from: palette, artistName: artistName) {
                return spec
            }
            if let average = ArtworkColorExtractor.averageColor(from: artworkData) {
                return gradientSpec(fromAverageColor: average, artistName: artistName)
            }
        }

        return fallbackGradient(for: artistName)
    }

    private nonisolated static func gradientSpec(
        from palette: [NSColor],
        artistName: String
    ) -> GradientSpec? {
        let normalized = palette.compactMap(normalizeGradientColor(_:))
        guard let startColor = normalized.first else { return nil }
        let endColor = normalized.dropFirst().first
            ?? deriveGradientPair(from: startColor, artistName: artistName)
        return GradientSpec(
            startColor: startColor,
            endColor: endColor,
            textColor: contrastingTextColor(for: blend(startColor, endColor)),
            angle: gradientAngle(for: artistName)
        )
    }

    private nonisolated static func gradientSpec(
        fromAverageColor color: NSColor,
        artistName: String
    ) -> GradientSpec {
        let startColor = normalizeGradientColor(color) ?? fallbackGradient(for: artistName).startColor
        let endColor = deriveGradientPair(from: startColor, artistName: artistName)
        return GradientSpec(
            startColor: startColor,
            endColor: endColor,
            textColor: contrastingTextColor(for: blend(startColor, endColor)),
            angle: gradientAngle(for: artistName)
        )
    }

    private nonisolated static func normalizeGradientColor(_ color: NSColor) -> NSColor? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation, 0.24), 0.62),
            brightness: min(max(brightness, 0.34), 0.84),
            alpha: 1
        )
    }

    private nonisolated static func deriveGradientPair(
        from color: NSColor,
        artistName: String
    ) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return fallbackGradient(for: artistName).endColor
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let hash = PlaylistArtworkGenerator.stableHash(for: artistName)
        let hueShift = CGFloat((hash % 19) + 9) / 360.0
        let shiftedHue = (hue + hueShift).truncatingRemainder(dividingBy: 1)
        return NSColor(
            calibratedHue: shiftedHue,
            saturation: min(max(saturation * 0.86, 0.20), 0.56),
            brightness: min(max(brightness * 1.12, 0.42), 0.90),
            alpha: 1
        )
    }

    private nonisolated static func fallbackGradient(for artistName: String) -> GradientSpec {
        let hash = PlaylistArtworkGenerator.stableHash(for: artistName)
        let hue = CGFloat(hash % 360) / 360.0
        let startColor = NSColor(
            calibratedHue: hue,
            saturation: 0.34,
            brightness: 0.48,
            alpha: 1
        )
        let endColor = NSColor(
            calibratedHue: (hue + 0.10).truncatingRemainder(dividingBy: 1),
            saturation: 0.26,
            brightness: 0.72,
            alpha: 1
        )
        return GradientSpec(
            startColor: startColor,
            endColor: endColor,
            textColor: contrastingTextColor(for: blend(startColor, endColor)),
            angle: gradientAngle(for: artistName)
        )
    }

    private nonisolated static func contrastingTextColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .white }
        let luminance =
            0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.56
            ? NSColor(calibratedWhite: 0.10, alpha: 0.95)
            : NSColor(calibratedWhite: 0.98, alpha: 0.98)
    }

    private nonisolated static func blend(_ lhs: NSColor, _ rhs: NSColor) -> NSColor {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return lhs
        }

        return NSColor(
            calibratedRed: (left.redComponent + right.redComponent) / 2,
            green: (left.greenComponent + right.greenComponent) / 2,
            blue: (left.blueComponent + right.blueComponent) / 2,
            alpha: 1
        )
    }

    private nonisolated static func gradientAngle(for artistName: String) -> CGFloat {
        CGFloat(20 + (PlaylistArtworkGenerator.stableHash(for: artistName) % 55))
    }

    private nonisolated static func suggestedFontSize(
        for artistName: String,
        canvasWidth: CGFloat
    ) -> CGFloat {
        let length = max(1, artistName.count)
        if length <= 6 { return canvasWidth * 0.15 }
        if length <= 12 { return canvasWidth * 0.12 }
        if length <= 18 { return canvasWidth * 0.10 }
        return canvasWidth * 0.08
    }
}

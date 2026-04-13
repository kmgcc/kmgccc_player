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

    func generateArtwork(artistName: String, tracks: [Track]) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            Self.renderArtwork(artistName: artistName, tracks: tracks)
        }.value
    }

    private nonisolated static func renderArtwork(
        artistName: String,
        tracks: [Track]
    ) -> NSImage? {
        let canvasSize = CGSize(width: 1024, height: 1024)
        let backgroundColor = resolveBackgroundColor(artistName: artistName, tracks: tracks)
        let foregroundColor = contrastingTextColor(for: backgroundColor)

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        backgroundColor.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: canvasSize)).fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping

        let fontSize = suggestedFontSize(for: artistName, canvasWidth: canvasSize.width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: foregroundColor,
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

    private nonisolated static func resolveBackgroundColor(
        artistName: String,
        tracks: [Track]
    ) -> NSColor {
        let sortedTracks = tracks.sorted { $0.id.uuidString < $1.id.uuidString }
        let candidateColors = sortedTracks.compactMap { track -> NSColor? in
            guard let artworkData = track.artworkData, !artworkData.isEmpty else { return nil }
            return ArtworkColorExtractor.averageColor(from: artworkData)
                ?? ArtworkColorExtractor.uiThemePalette(from: artworkData, maxColors: 2).first
        }

        if let averaged = average(colors: Array(candidateColors.prefix(16))) {
            return normalizeBackgroundColor(averaged)
        }

        return fallbackColor(for: artistName)
    }

    private nonisolated static func average(colors: [NSColor]) -> NSColor? {
        guard !colors.isEmpty else { return nil }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        for color in colors {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { continue }
            red += rgb.redComponent
            green += rgb.greenComponent
            blue += rgb.blueComponent
            count += 1
        }

        guard count > 0 else { return nil }
        return NSColor(
            calibratedRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: 1
        )
    }

    private nonisolated static func normalizeBackgroundColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return fallbackColor(for: "") }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: min(max(saturation, 0.20), 0.42),
            brightness: min(max(brightness, 0.38), 0.68),
            alpha: 1
        )
    }

    private nonisolated static func fallbackColor(for artistName: String) -> NSColor {
        let hash = PlaylistArtworkGenerator.stableHash(for: artistName)
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(
            calibratedHue: hue,
            saturation: 0.28,
            brightness: 0.54,
            alpha: 1
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
